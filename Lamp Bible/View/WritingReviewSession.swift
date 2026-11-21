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

/// What restoring a marked passage would do, for the page to show before
/// it's pressed: the words standing there now and the ones that would stand
/// instead, each as Markdown, the spaces the assistant put in with its words
/// included. Or, where it can't be put back for something the writer did,
/// the reason, and no `before`. `id` names the marks it puts back, so a
/// press restores those and nothing beside them.
struct WritingReviewChange: Encodable, Equatable, Sendable {
    let id: String
    let now: String
    var before: String?
    var reason: String?

    static let edited = "edited"

    /// The id of a passage holding these marks.
    static func id(of marks: [UUID]) -> String {
        marks.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func marks(in id: String) -> Set<UUID> {
        Set(id.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}

/// What a writer is told when a restore can't be made, in the Mac's words.
enum WritingRestoreRefusal {
    static let edited = "This passage has been edited since the assistant changed it, so putting its wording back would take your own words with it. Mark it as reviewed instead."
    static let notKept = "Lamp did not keep what this change replaced, so there is nothing to put back. It was made before Lamp kept it, or on a device whose Lamp does not."
    static let caretOutside = "Put the caret in a passage the assistant changed, or select one, and try again."
    static let nothingSelected = "Nothing the assistant changed is inside what you have selected."
    static let moved = "The wording couldn’t be put back on the page as it stands now. Try again, or mark it as reviewed instead."

    static func text(for outcome: LampWritingReview.RestoreOutcome, selecting range: NSRange) -> String? {
        switch outcome {
        case .plan: nil
        case .notExact: edited
        case .notKept: notKept
        case .nothingTouched: range.length == 0 ? caretOutside : nothingSelected
        }
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
    /// Whether any of them can be put back as it stood, as last sent.
    @Published private(set) var canRestore = false
    /// Why a restore asked for couldn't be made, nothing having changed.
    @Published var restoreRefusal: String?

    /// The marks as the page takes them, each time they change: the
    /// writing's Markdown with markers, or nil for none, and what each
    /// marked range would put back. The page keeps them through the
    /// writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?, [WritingReviewChange?]) -> Void)?
    /// The marks last sent, for an editor that's ready late.
    private(set) var markedMarkdown: String?
    private(set) var markedChanges: [WritingReviewChange?] = []
    /// Has the page take in the text a restore worked out, as an edit of its
    /// own, if it still holds the text given second: answers with what it
    /// holds afterwards, or nil where it changed nothing.
    var applyRestore: (@MainActor (_ text: String, _ expected: String) async -> String?)?

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
        publish(count: 0, marked: nil, changes: [], sendsMarks: true)
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

    /// The page's marks may no longer say what can be put back (an undo
    /// took its text back to words a change was made in), so they go again
    /// once the text settles.
    func refreshMarks() {
        needsResend = true
        resentFor = nil
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

    // MARK: - Restoring

    /// Puts back the change the page's preview showed, by its id: exactly
    /// the marks it names, found in the page's own text (`pageText`), the
    /// text the press was made in, or else in the writing as held here.
    /// Never by a range the page marked, which a link round the change
    /// would widen to take a change beside it too.
    func restore(changeID: String, pageText: String?) {
        let wanted = WritingReviewChange.marks(in: changeID)
        guard !wanted.isEmpty else { return }
        restore(in: pageText ?? text) { live, base in
            switch live.restoring(marks: wanted, in: base) {
            case let .plan(plan): .plan(plan)
            case .notKept: .refused(WritingRestoreRefusal.notKept)
            // A change named that's gone, or holds another between its
            // marks: the words have moved since it was offered.
            case .notExact, .nothingTouched: .refused(WritingRestoreRefusal.edited)
            }
        }
    }

    /// Puts back every change the range the page marked touches, or none
    /// (`restoring(_:in:)`): for the selection, where the writer chose the
    /// range themselves.
    func restore(markedMarkdown marked: String, pageText: String?) {
        let base: String
        let range: NSRange
        if let pageText, let found = LampWritingReview.markedRange(in: marked, of: pageText) {
            base = pageText
            range = found
        } else if let found = LampWritingReview.markedRange(in: marked, of: text) {
            base = text
            range = found
        } else {
            return refuseRestore(WritingRestoreRefusal.moved)
        }
        restore(in: base) { live, base in
            let outcome = live.restoring(range, in: base)
            if case let .plan(plan) = outcome { return .plan(plan) }
            return .refused(WritingRestoreRefusal.text(for: outcome, selecting: range) ?? WritingRestoreRefusal.edited)
        }
    }

    private enum Planned: Sendable {
        case plan(LampWritingReview.RestorePlan)
        case refused(String)
    }

    /// Plans a restore in `base` with the marks carried there, then has the
    /// page make the edit itself, so it undoes as any edit does and nothing
    /// typed meanwhile is written over: it refuses if its text has moved on
    /// from `base`. Only once it has is the restore recorded, against what
    /// the page ended up holding, in a place in line taken before the edit,
    /// so the save that follows carries after it.
    private func restore(
        in base: String,
        planning: @escaping @Sendable (LampWritingReview, String) -> Planned
    ) {
        guard let writingID, let store, let review, let applyRestore else { return }
        WritingReviewTexts.shared.remember(base, for: writingID)
        let known = WritingReviewTexts.shared.known(for: writingID)
        Task { [weak self] in
            let planned = await Task.detached(priority: .userInitiated) {
                planning(review.carryingToText(base, from: known), base)
            }.value
            guard let self, self.writingID == writingID else { return }
            guard case let .plan(plan) = planned else {
                if case let .refused(why) = planned { self.refuseRestore(why) }
                return
            }
            let place = WritingReviewWork.shared.reserve()
            guard let restored = await applyRestore(Self.applying(plan, to: base), base) else {
                place.giveUp()
                if self.writingID == writingID { self.refuseRestore(WritingRestoreRefusal.moved) }
                return
            }
            WritingReviewTexts.shared.remember(restored, for: writingID)
            // Recorded in the file it was planned from, though marks were
            // turned off meanwhile: the edit is made, and the record must say so.
            self.change(in: place, store: store, writingID: writingID) {
                $0.restoringWording(plan, from: base, to: restored, carryingFrom: known)
            }
        }
    }

    /// The selection stood in no change, as the page has them.
    func refuseNothingSelected(caret: Bool) {
        refuseRestore(caret ? WritingRestoreRefusal.caretOutside : WritingRestoreRefusal.nothingSelected)
    }

    /// Said to the writer, and the marks sent again, so a change the page
    /// still offered that can't be put back is offered no longer.
    private func refuseRestore(_ why: String) {
        restoreRefusal = why
        needsResend = true
        scheduleDraw()
    }

    /// `text` with the plan's edits made, last first as it lists them.
    nonisolated static func applying(_ plan: LampWritingReview.RestorePlan, to text: String) -> String {
        let edited = NSMutableString(string: text)
        for edit in plan.edits {
            edited.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return edited as String
    }

    /// For each marked range the page is sent, in order, what restoring it
    /// would put back: the span the restore replaces, as it stands and with
    /// the old wording in; or that it can't be, for something the writer did
    /// (`.notExact`); or nil. As `restoring(_:in:)` answers for them all at
    /// once, each with the marks it stands in, which name it.
    nonisolated static func changes(in review: LampWritingReview, text: String) -> [WritingReviewChange?] {
        let ranges = review.highlightedRanges(in: text)
        guard !review.wordings.isEmpty else { return ranges.map { _ in nil } }
        let source = text as NSString
        return zip(ranges, review.restoring(ranges, in: text)).map { range, answer in
            let id = WritingReviewChange.id(of: answer.marks)
            switch answer.outcome {
            case let .plan(plan):
                guard let first = plan.edits.first else { return nil }
                let span = plan.edits.dropFirst().reduce(first.range) { NSUnionRange($0, $1.range) }
                let now = source.substring(with: span)
                let before = NSMutableString(string: now)
                // Last first, as the plan lists them.
                for edit in plan.edits {
                    before.replaceCharacters(
                        in: NSRange(location: edit.range.location - span.location, length: edit.range.length),
                        with: edit.replacement
                    )
                }
                return WritingReviewChange(id: id, now: now, before: before as String)
            case .notExact:
                return WritingReviewChange(id: id, now: source.substring(with: range), reason: WritingReviewChange.edited)
            case .notKept, .nothingTouched:
                return nil
            }
        }
    }

    // MARK: - Internals

    /// Changes the marks file in line with the saves' carries, off the main
    /// actor, and takes up what was written, with the file's date read under
    /// the same lock.
    ///
    /// In `place`, where one was taken for it, rather than at the end.
    /// `store` and `writingID`, where given, stand in for the session's own.
    private func change(
        in place: WritingReviewWork.Reservation? = nil,
        store: LampWritingReviewStore? = nil,
        writingID: String? = nil,
        _ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview
    ) {
        guard let store = store ?? self.store, let writingID = writingID ?? self.writingID else {
            place?.giveUp()
            return
        }
        let work: @Sendable () async -> Void = { [weak self] in
            guard let written = try? store.updating(writingID: writingID, edit) else { return }
            await MainActor.run {
                WritingReviewWork.marksChanged()
                // Not for a writing left since, nor once marks were turned off.
                guard let self, self.writingID == writingID, self.store != nil else { return }
                self.apply(written.review, date: written.modified)
            }
        }
        if let place { place.fill(work) } else { WritingReviewWork.shared.run(work) }
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
            publish(count: 0, marked: nil, changes: [], sendsMarks: sendsMarks)
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
                let marked = sendsMarks ? live.markedMarkdown(in: text) : nil
                let changes = marked == nil ? [] : Self.changes(in: live, text: text)
                return (live.located(in: text).count, marked, changes)
            }.value
            guard let self, self.drawGeneration == generation else { return }
            self.publish(count: drawn.0, marked: drawn.1, changes: drawn.2, sendsMarks: sendsMarks)
        }
    }

    private func publish(count: Int, marked: String?, changes: [WritingReviewChange?], sendsMarks: Bool) {
        if self.count != count { self.count = count }
        if sendsMarks {
            markedMarkdown = marked
            markedChanges = changes
            let restorable = changes.contains { $0 != nil }
            if canRestore != restorable { canRestore = restorable }
            onMarksChanged?(marked, changes)
        }
    }
}
