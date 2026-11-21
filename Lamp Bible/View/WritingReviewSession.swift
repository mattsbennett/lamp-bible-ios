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

        /// False, the work dropped, where the line has already moved on
        /// without it.
        @discardableResult
        func fill(_ work: @escaping @Sendable () async -> Void) -> Bool {
            if case .terminated = continuation.yield(work) { return false }
            continuation.finish()
            return true
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

extension LampWritingReview.Change {
    /// The marks a change's id names (`id(of:)`).
    static func marks(in id: String) -> Set<UUID> {
        Set(id.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}

/// Restores the page has made and the marks file doesn't say yet, by
/// writing. Each is recorded once a save of its writing commits a text that
/// still holds it (`RestorePlan.stands(from:in:)`): the save made for it, or
/// any after, whichever editor of the writing makes it. Never on a save's
/// word alone: one already in flight took the text before the restore, and
/// a later one may hold another body. Kept apart from the view, so leaving
/// the writing before a save lands doesn't drop one. As on the Mac.
///
/// A restore keeps the place in line it took before the page made it, and
/// is recorded there: ahead of its save's carry, which then carries a mark
/// it makes on unread words it put back, and of a clear asked for since,
/// which a mark made after it would undo.
@MainActor
final class WritingRestoreObligations {
    static let shared = WritingRestoreObligations()
    /// How many restores of a writing wait at once: far past any a writer
    /// makes between two saves.
    static let kept = 20

    struct Owed: Sendable {
        let id: UUID
        let plan: LampWritingReview.RestorePlan
        /// The text the restore was planned in, and the page's text after it.
        let base: String
        let restored: String
        let known: [String]
        /// Its place in line, until spent or given up.
        var place: WritingReviewWork.Reservation?
        /// Every mark was cleared while it was owed: its record doesn't mark
        /// unread words it put back, which that clear answered.
        var clearedSince = false
    }

    private var owed: [String: [Owed]] = [:]

    /// Owed from now. One owed before for only marks this one puts back too
    /// (made again after an undo, say) is this one's now: both recorded, the
    /// marks the restore makes would be made twice. One that also put back
    /// others stays owed for them.
    @discardableResult
    func owe(
        _ plan: LampWritingReview.RestorePlan, from base: String, to restored: String,
        carryingFrom known: [String], in place: WritingReviewWork.Reservation?, for writingID: String
    ) -> UUID {
        let marks = Set(plan.marks)
        var pending = owed[writingID, default: []]
        for replaced in pending where marks.isSuperset(of: replaced.plan.marks) { replaced.place?.giveUp() }
        pending.removeAll { marks.isSuperset(of: $0.plan.marks) }
        let restore = Owed(id: UUID(), plan: plan, base: base, restored: restored, known: known, place: place)
        pending.append(restore)
        for dropped in pending.dropLast(Self.kept) { dropped.place?.giveUp() }
        owed[writingID] = Array(pending.suffix(Self.kept))
        return restore.id
    }

    func isOwed(_ id: UUID, for writingID: String) -> Bool {
        owed[writingID]?.contains { $0.id == id } ?? false
    }

    /// Every mark of the writing was cleared.
    func clearedAll(for writingID: String) {
        guard let pending = owed[writingID] else { return }
        owed[writingID] = pending.map { restore in
            var restore = restore
            restore.clearedSince = true
            return restore
        }
    }

    /// Its save didn't commit: its place in line goes, and it waits, owed,
    /// for a later save.
    func release(_ id: UUID, for writingID: String) {
        guard let index = owed[writingID]?.firstIndex(where: { $0.id == id }) else { return }
        owed[writingID]?[index].place?.giveUp()
        owed[writingID]?[index].place = nil
    }

    /// A save of the writing committed `saved`: each restore owed that it
    /// holds is recorded, in its own place in line where it still has one,
    /// else after the save's carry. Returns once those holding a place are
    /// in it, so the save made for a restore knows when it returns.
    func settle(writingID: String, saved: String) async {
        guard let pending = owed[writingID], !pending.isEmpty else { return }
        let store = LibrarySyncPass.reviewStore
        // Asked before its place is spent, so a save without it (one in
        // flight when it was made) doesn't spend it; off the main actor,
        // since the whole writing is compared.
        let placed = pending.filter { $0.place != nil }
        let holding = placed.isEmpty ? [] : await Task.detached(priority: .userInitiated) {
            placed.filter { $0.plan.stands(from: $0.restored, in: saved) }.map(\.id)
        }.value
        for id in holding {
            guard let restore = claim([id], for: writingID).first else { continue }
            let filled = restore.place?.fill {
                await Self.record([restore], writingID: writingID, saved: saved, store: store)
            } ?? false
            // Its place gone by meanwhile: recorded at the end of the line.
            if !filled {
                WritingReviewWork.shared.run {
                    await Self.record([restore], writingID: writingID, saved: saved, store: store)
                }
            }
        }
        // Those owed as this save committed, not any made after it.
        let eligible = Set(owed[writingID, default: []].filter { $0.place == nil }.map(\.id))
        guard !eligible.isEmpty else { return }
        WritingReviewWork.shared.run {
            // Still owed when its turn comes: a settle before it in line may
            // have recorded some.
            let unplaced = await MainActor.run {
                WritingRestoreObligations.shared.owed[writingID, default: []].filter { eligible.contains($0.id) }
            }
            let holding = unplaced.filter { $0.plan.stands(from: $0.restored, in: saved) }
            guard !holding.isEmpty else { return }
            let claimed = await MainActor.run {
                WritingRestoreObligations.shared.claim(Set(holding.map(\.id)), for: writingID)
            }
            await Self.record(claimed, writingID: writingID, saved: saved, store: store)
        }
    }

    /// Writes these restores to the marks file; any it couldn't are owed
    /// again, for the next save.
    nonisolated private static func record(
        _ restores: [Owed], writingID: String, saved: String, store: LampWritingReviewStore
    ) async {
        guard !restores.isEmpty else { return }
        let written = try? store.updating(writingID: writingID) { review in
            restores.reduce(review) {
                $0.restoringWording(
                    $1.plan, from: $1.base, to: $1.restored,
                    remarkingUnread: !$1.clearedSince, carryingFrom: $1.known
                )
            }
        }
        await MainActor.run {
            guard written != nil else {
                let unplaced = restores.map { restore -> Owed in
                    var restore = restore
                    restore.place = nil
                    return restore
                }
                WritingRestoreObligations.shared.owed[writingID, default: []].append(contentsOf: unplaced)
                return
            }
            WritingReviewTexts.shared.remember(saved, for: writingID)
            WritingReviewWork.marksChanged()
        }
    }

    /// Takes these out of what's owed, answering with those still there.
    private func claim(_ ids: Set<UUID>, for writingID: String) -> [Owed] {
        let claimed = owed[writingID, default: []].filter { ids.contains($0.id) }
        owed[writingID]?.removeAll { ids.contains($0.id) }
        return claimed
    }
}

/// What a writer is told when a restore can't be made, in the Mac's words.
enum WritingRestoreRefusal {
    static let edited = "This passage has been edited since the assistant changed it, so putting its wording back would take your own words with it. Mark it as reviewed instead."
    static let notKept = "Lamp did not keep what this change replaced, so there is nothing to put back. It was made before Lamp kept it, or on a device whose Lamp does not."
    static let caretOutside = "Put the caret in a passage the assistant changed, or select one, and try again."
    static let nothingSelected = "Nothing the assistant changed is inside what you have selected."
    static let moved = "The wording couldn’t be put back on the page as it stands now. Try again, or mark it as reviewed instead."
    static let unsaved = "The original wording is back, but the writing couldn’t be saved, so the assistant hasn’t been told yet. It will be once the writing saves."

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
    /// A restore was made and couldn't be saved yet, so it isn't recorded:
    /// it will be once a save of the writing holds it.
    @Published var restoreUnsaved = false

    /// The marks as the page takes them, each time they change: the
    /// writing's Markdown with markers, or nil for none, and what each
    /// marked range would put back. The page keeps them through the
    /// writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?, [LampWritingReview.Change?]) -> Void)?
    /// The marks last sent, for an editor that's ready late.
    private(set) var markedMarkdown: String?
    private(set) var markedChanges: [LampWritingReview.Change?] = []
    /// Has the page take in the text a restore worked out, as an edit of its
    /// own, if it still holds the text given second: answers with what it
    /// holds afterwards, or nil where it changed nothing.
    var applyRestore: (@MainActor (_ text: String, _ expected: String) async -> String?)?
    /// Saves the writing now, the restore in it: false where it couldn't be
    /// saved. A save that commits records the restore if it holds it
    /// (`WritingRestoreObligations`).
    var saveRestored: (@MainActor () async -> Bool)?
    /// One restore at a time: two pressed together would go through one
    /// save, and the page refuse the second's text.
    private var restoring = false

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
        if let writingID { WritingRestoreObligations.shared.clearedAll(for: writingID) }
        change { $0.clearingAll() }
    }

    // MARK: - Restoring

    /// Puts back the change the page's preview showed, by its id: exactly
    /// the marks it names, found in the page's own text (`pageText`), the
    /// text the press was made in, or else in the writing as held here.
    /// Never by a range the page marked, which a link round the change
    /// would widen to take a change beside it too.
    func restore(changeID: String, pageText: String?) {
        let wanted = LampWritingReview.Change.marks(in: changeID)
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
    /// from `base`. Once it has, the restore is owed and the writing saved:
    /// it's recorded when a save commits a text that holds it. Not put back
    /// where that save fails: the writer is told it isn't recorded yet, and
    /// the restore stays theirs to undo.
    ///
    /// The app is held open in the background until then, so quitting
    /// between the press and the save doesn't leave it made and unsaved.
    private func restore(
        in base: String,
        planning: @escaping @Sendable (LampWritingReview, String) -> Planned
    ) {
        guard !restoring, let writingID, store != nil, let review, let applyRestore else { return }
        restoring = true
        WritingReviewTexts.shared.remember(base, for: writingID)
        let known = WritingReviewTexts.shared.known(for: writingID)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Restore wording")
        Task { [weak self] in
            await self?.restore(
                in: base, writingID: writingID, review: review, known: known,
                applyRestore: applyRestore, planning: planning
            )
            self?.restoring = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
    }

    private func restore(
        in base: String, writingID: String, review: LampWritingReview, known: [String],
        applyRestore: @MainActor (String, String) async -> String?,
        planning: @escaping @Sendable (LampWritingReview, String) -> Planned
    ) async {
        let planned = await Task.detached(priority: .userInitiated) {
            planning(review.carryingToText(base, from: known), base)
        }.value
        guard self.writingID == writingID else { return }
        guard case let .plan(plan) = planned else {
            if case let .refused(why) = planned { refuseRestore(why) }
            return
        }
        // A place in line taken before the edit, so the save that follows
        // carries after the record, and a clear asked for meanwhile comes
        // after it too.
        let place = WritingReviewWork.shared.reserve()
        guard let restored = await applyRestore(plan.applied(to: base), base) else {
            place.giveUp()
            if self.writingID == writingID { refuseRestore(WritingRestoreRefusal.moved) }
            return
        }
        WritingReviewTexts.shared.remember(restored, for: writingID)
        // Owed before the save is asked for, so whichever save holds it first
        // records it: recorded in the file it was planned from, though marks
        // are turned off meanwhile, since the edit is made.
        let owed = WritingRestoreObligations.shared.owe(
            plan, from: base, to: restored, carryingFrom: known, in: place, for: writingID
        )
        let saved = await saveRestored?() ?? false
        guard WritingRestoreObligations.shared.isOwed(owed, for: writingID) else { return }
        // Not recorded by its own save: the line doesn't wait on it.
        WritingRestoreObligations.shared.release(owed, for: writingID)
        if !saved, self.writingID == writingID { restoreUnsaved = true }
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

    /// For each marked range the page is sent, in order, what restoring it
    /// would put back, or that it can't be for something the writer did, or
    /// nil (`changes(in:ranges:)`).
    nonisolated static func changes(in review: LampWritingReview, text: String) -> [LampWritingReview.Change?] {
        let ranges = review.highlightedRanges(in: text)
        guard !review.wordings.isEmpty else { return ranges.map { _ in nil } }
        return review.changes(in: text, ranges: ranges)
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

    private func publish(count: Int, marked: String?, changes: [LampWritingReview.Change?], sendsMarks: Bool) {
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
