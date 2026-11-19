import Foundation
import LampCore
import UIKit

/// The versions of each writing this device has lately seen: the editor's
/// text as it settles, and each body saved. A mark is anchored in a text and
/// carried exactly from that text; a clear made while the editor holds text
/// not yet saved anchors what is left there, and the save that follows
/// carries from the last saved body. Kept here, a carry can take each mark
/// from its own (`LampWritingReview.carryingToText`), which hashes them off
/// the main actor. One that has gone is still found by its words and
/// context, so this only makes carries exact more often. As on the Mac.
@MainActor
final class WritingReviewTexts {
    static let shared = WritingReviewTexts()
    /// How many versions of a writing are kept: enough to span a clear and
    /// the saves after it, few enough that a long manuscript costs little.
    static let kept = 24

    private var texts: [String: [String]] = [:]

    func remember(_ text: String, for writingID: String) {
        var kept = texts[writingID, default: []]
        guard kept.last != text else { return }
        kept.append(text)
        texts[writingID] = Array(kept.suffix(Self.kept))
    }

    func known(for writingID: String) -> [String] {
        texts[writingID, default: []]
    }
}

/// Where the marks are changed, by a save's carry and by the writer's
/// clears: one at a time, in the order they were asked for, off the main
/// actor. In order, a carry asked for before a clear is done before it, so
/// neither writes over the other; off the main actor, the whole manuscript
/// compared, and the wait on the marks file's lock, aren't the writer's to
/// feel. Each holds the app open in the background until it's done, as
/// quitting waits for one on the Mac.
@MainActor
final class WritingReviewWork {
    static let shared = WritingReviewWork()
    private var last: Task<Void, Never>?

    /// How many saves of each writing have asked for a carry, counted as
    /// each takes its place in line: dates can't order them, since saves are
    /// stored to the second.
    private var saveGenerations: [String: Int] = [:]
    /// The latest of those saves that went through. A carry runs only while
    /// no later save did: one that failed or was refused carries nothing, and
    /// supersedes nothing.
    private(set) var savedGenerations: [String: Int] = [:]

    func run(_ work: @escaping @Sendable () async -> Void) {
        let previous = last
        let background = UIApplication.shared.beginBackgroundTask(withName: "Review marks")
        last = Task.detached(priority: .utility) {
            await previous?.value
            await work()
            await MainActor.run {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
        }
    }

    /// A place in line taken now, for work only known later: a save takes
    /// its place before it waits on the database, so a clear asked for
    /// meanwhile is done after its carry, never before. Filled with the work
    /// once known, or given up, and either way the line moves on.
    struct Reservation: Sendable {
        fileprivate let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

        func fill(_ work: @escaping @Sendable () async -> Void) {
            continuation.yield(work)
            continuation.finish()
        }

        func giveUp() {
            continuation.finish()
        }
    }

    /// A save's place in line, with the generation it carries for.
    struct Carry: Sendable {
        let reservation: Reservation
        let generation: Int
        let writingID: String
    }

    /// How long a place in line waits to be filled before the line moves
    /// on without it: far past any save, and short of a queue stopped for
    /// good by a place nobody fills. Work filled in after that is dropped,
    /// not run late, behind what was queued after it.
    var reservationPatience: Duration = .seconds(120)

    func reserve() -> Reservation {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        let patience = reservationPatience
        run {
            let work = await withTaskGroup(of: (@Sendable () async -> Void)?.self) { group in
                group.addTask {
                    for await work in stream { return work }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: patience)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                continuation.finish()
                return first
            }
            await work?()
        }
        return Reservation(continuation: continuation)
    }

    /// A save's carry, its place taken and its generation counted before the
    /// save waits on the database.
    func reserveCarry(for writingID: String) -> Carry {
        let generation = (saveGenerations[writingID] ?? 0) + 1
        saveGenerations[writingID] = generation
        return Carry(reservation: reserve(), generation: generation, writingID: writingID)
    }

    /// Carries the writing's review marks across a save, from `previous` (the
    /// body it replaced) to `current`, so the rest of a marked passage the
    /// writer typed into stays marked and their own words don't. Run only if
    /// no later save of the writing has asked since, and only where the
    /// writing has marks, asked when it runs: a clear still in line may be
    /// the file's first write.
    ///
    /// `revision` is the revision the save stored: a body sync brought since
    /// is newer, and its marks aren't this save's to carry.
    func carry(_ carry: Carry, from previous: String, to current: String, savedAs revision: Int) {
        let known = WritingReviewTexts.shared.known(for: carry.writingID)
        let store = LibrarySyncPass.reviewStore
        savedGenerations[carry.writingID] = max(savedGenerations[carry.writingID] ?? 0, carry.generation)
        carry.reservation.fill {
            let overtaken = await MainActor.run {
                (WritingReviewWork.shared.savedGenerations[carry.writingID] ?? 0) > carry.generation
            }
            let stored = (try? ModuleDatabase.shared.getDevotionalEntry(id: carry.writingID))??.lastModified
            guard !overtaken, stored == revision,
                  let url = try? store.url(writingID: carry.writingID),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            // Carried even when this save's body didn't move (its details
            // did): it may have overtaken a carry still in line for a text
            // save, whose marks then come from the texts known.
            let before = try? store.snapshot(writingID: carry.writingID).review
            let after = try? store.update(writingID: carry.writingID) {
                $0.carryingToText(current, from: known + [previous])
            }
            let wrote = after != nil && after != before
            await MainActor.run {
                WritingReviewTexts.shared.remember(current, for: carry.writingID)
                if wrote { WritingReviewWork.marksChanged() }
            }
        }
    }

    /// Marks changed here go to the other devices with the next pass.
    static func marksChanged() {
        Task { await ModuleSyncManager.shared.scheduleLibraryPass() }
    }

    /// Returns once everything asked for so far is done.
    func drained() async {
        await last?.value
    }
}

/// The review marks of the writing a view has open (`LampWritingReview`):
/// what's drawn, how many passages are still to read, and the writer's
/// clears. One per writing view, held apart from the view so none of this
/// is worked out in its body, which is on the typing path. As on the Mac
/// (WritingReviewSession), whose shape this keeps.
///
/// The marks file is read again when its date moves (a turn on the Mac
/// marked something, or another device's clears arrived by sync), checked
/// about once a second while the writing is open and at once when sync says
/// so. What to draw is worked out off the main actor, once the text settles.
@MainActor
final class WritingReviewSession: ObservableObject {
    /// How many passages are still to read, places words were taken out
    /// among them.
    @Published private(set) var count = 0

    /// The marks as the page takes them, each time they change: the
    /// writing's Markdown with markers, or nil for none. The page keeps them
    /// through the writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?) -> Void)?
    /// The marks last sent, for an editor that's ready late.
    private(set) var markedMarkdown: String?

    private var writingID: String?
    private var store: LampWritingReviewStore?
    private var review: LampWritingReview?
    private var text = ""
    private var fileDate: Date?
    private var settleTask: Task<Void, Never>?
    private var drawGeneration = 0
    /// The page refused the last marks sent (its text was a moment ahead of
    /// this one's), so the next draw sends them again.
    private var needsResend = false
    /// The text a refused set of marks was last sent again for. Refused
    /// again for the same text, they wait for the text to change.
    private var resentFor: String?

    static let checkInterval: Duration = .seconds(1)
    static let settleDelay: Duration = .milliseconds(300)

    /// Keeps the writing's marks current until the task is cancelled: the
    /// view's `.task(id:)`, keyed on the writing and on whether marks are
    /// shown at all. Shown off, everything is cleared and nothing is read.
    func follow(writingID: String, text: String, isShown: Bool) async {
        // Nothing drawn for the writing before may land now.
        settleTask?.cancel()
        drawGeneration += 1
        self.writingID = writingID
        self.text = text
        WritingReviewTexts.shared.remember(text, for: writingID)
        review = nil
        fileDate = nil
        needsResend = false
        resentFor = nil
        store = isShown ? LibrarySyncPass.reviewStore : nil
        publish(count: 0, marked: nil, sendsMarks: true)
        guard isShown else { return }
        let changes = NotificationCenter.default.notifications(named: .writingReviewsDidChange)
        // Sync's word, as it lands, alongside the steady check.
        let listening = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.reloadIfMoved()
            }
        }
        defer { listening.cancel() }
        while !Task.isCancelled {
            await reloadIfMoved()
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// The writing's text moved: what to draw is worked out again once it
    /// settles. The page isn't sent the marks again for it, unless it
    /// refused the last ones.
    func textChanged(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        guard review != nil else { return }
        scheduleDraw()
    }

    /// The page couldn't place the marks it was sent: its text wasn't this
    /// one. They go again once the text settles.
    func marksRejected() {
        needsResend = true
        guard resentFor != text else { return }
        resentFor = text
        scheduleDraw()
    }

    // MARK: - Clearing

    /// Clears what of the marks `range` of the writing covers. A caret with
    /// nothing selected clears the mark it stands in.
    ///
    /// The marks are carried to the text as it is now first: typed into
    /// since they were read, a marked passage would otherwise not be found
    /// and the clear would do nothing.
    func clear(range: NSRange) {
        guard let writingID else { return }
        clear(range: range, in: text, writingID: writingID)
    }

    /// Made in `text` with the marks carried there, changing only the marks
    /// it touches (`clearing(_:in:carryingFrom:)`): `text` can be a moment
    /// behind the latest marks, and carried whole into it, a mark with no
    /// words there would be retired by a clear of some other passage.
    private func clear(range: NSRange, in text: String, writingID: String) {
        WritingReviewTexts.shared.remember(text, for: writingID)
        let known = WritingReviewTexts.shared.known(for: writingID)
        change { $0.clearing(range, in: text, carryingFrom: known) }
    }

    /// Clears the range the page marked in the Markdown it sent.
    ///
    /// Where that's the writing as held here, the clear is made in it.
    /// Otherwise the page was ahead or behind (typed into within the
    /// editor's report of it, or pressed before new marks reached it), and
    /// the clear is made in the page's own text, `pageText`, sent unmarked
    /// beside the marked: that text is then known, so the next draw and
    /// save carry the clear on from it. None waits on a report that may
    /// never match.
    ///
    /// Never made in the marked Markdown with its markers taken out: a
    /// marker can change how the page writes what's round it, so that's
    /// text the page never held. A page that sends no text of its own clears
    /// only where it matches the writing here. As on the Mac.
    func clear(markedMarkdown marked: String, pageText: String? = nil) {
        guard let writingID else { return }
        if let range = LampWritingReview.markedRange(in: marked, of: text) {
            clear(range: range, in: text, writingID: writingID)
        } else if let pageText, let range = LampWritingReview.markedRange(in: marked, of: pageText) {
            clear(range: range, in: pageText, writingID: writingID)
        }
    }

    func clearAll() {
        change { $0.clearingAll() }
    }

    // MARK: - Internals

    /// Changes the marks file in line with the saves' carries, off the main
    /// actor, and takes up what was written, with the file's date read under
    /// the same lock.
    private func change(_ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview) {
        guard let store, let writingID else { return }
        WritingReviewWork.shared.run { [weak self] in
            guard let written = try? store.updating(writingID: writingID, edit) else { return }
            await MainActor.run {
                WritingReviewWork.marksChanged()
                // Not for a writing left since, nor once marks were turned off.
                guard let self, self.writingID == writingID, self.store != nil else { return }
                self.apply(written.review, date: written.modified)
            }
        }
    }

    /// Reads the marks file again if its date has moved since it was last
    /// read: the record and its date together, under the file's lock, so a
    /// write can never be taken for the one before it.
    private func reloadIfMoved() async {
        guard let store, let writingID else { return }
        let read = await Task.detached(priority: .utility) {
            try? store.snapshot(writingID: writingID)
        }.value
        guard let read, read.modified != fileDate, self.writingID == writingID, !Task.isCancelled else { return }
        apply(read.modified == nil ? nil : read.review, date: read.modified)
    }

    private func apply(_ review: LampWritingReview?, date: Date?) {
        fileDate = date
        guard review != self.review else { return }
        self.review = review
        draw(sendsMarks: true)
    }

    private func scheduleDraw() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            if let writingID = self.writingID { WritingReviewTexts.shared.remember(self.text, for: writingID) }
            // Sent too while none are shown and some stand: marks that placed
            // nowhere in the text before (a newer body arrived) may place in
            // this one. All cleared, nothing goes to the page each settle.
            let unplaced = self.markedMarkdown == nil && self.review?.isEmpty == false
            self.draw(sendsMarks: self.needsResend || unplaced)
        }
    }

    private func draw(sendsMarks: Bool) {
        drawGeneration += 1
        let generation = drawGeneration
        if sendsMarks { needsResend = false }
        guard let review, !review.isEmpty else {
            publish(count: 0, marked: nil, sendsMarks: sendsMarks)
            return
        }
        let text = self.text
        // Drawn from the marks carried into the text as it is now, each from
        // the text it's anchored in: typed into since they were saved, a
        // marked passage would otherwise be found nowhere until the next save
        // carries it.
        let known = writingID.map { WritingReviewTexts.shared.known(for: $0) } ?? []
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                let live = review.carryingToText(text, from: known)
                return (live.located(in: text).count, sendsMarks ? live.markedMarkdown(in: text) : nil)
            }.value
            guard let self, self.drawGeneration == generation else { return }
            self.publish(count: drawn.0, marked: drawn.1, sendsMarks: sendsMarks)
        }
    }

    private func publish(count: Int, marked: String?, sendsMarks: Bool) {
        if self.count != count { self.count = count }
        if sendsMarks {
            markedMarkdown = marked
            onMarksChanged?(marked)
        }
    }
}
