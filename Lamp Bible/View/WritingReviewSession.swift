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

    /// Kept by core, by writing and document (`LampWritingReviewTexts`).
    private let texts = LampWritingReviewTexts()

    func remember(_ text: String, for writingID: String, document: String? = nil) {
        texts.remember(text, for: LampWritingReviewPlace(writingID: writingID, document: document))
    }

    func known(for writingID: String, document: String? = nil) -> [String] {
        texts.known(for: LampWritingReviewPlace(writingID: writingID, document: document))
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
        /// Its passages not yet recorded, by mark: a save may hold some and
        /// not others, and each is written down as one holds it.
        var pending: Set<UUID>
    }

    /// Passages of a restore a save holds, to write down.
    private struct Recording: Sendable {
        let restore: Owed
        let marks: Set<UUID>
    }

    private var owed: [String: [Owed]] = [:]

    /// Owed from now. The passages of one owed before that this one puts
    /// back too (made again after an undo, say) are this one's now.
    @discardableResult
    func owe(
        _ plan: LampWritingReview.RestorePlan, from base: String, to restored: String,
        carryingFrom known: [String], in place: WritingReviewWork.Reservation?, for writingID: String
    ) -> UUID {
        let marks = Set(plan.marks)
        var pending = owed[writingID, default: []]
        // The same passages restored again are this one's to record, not an
        // older one's too: recorded twice, the marks a restore makes would
        // be made twice. An older one keeps what it alone put back.
        for index in pending.indices { pending[index].pending.subtract(marks) }
        for replaced in pending where replaced.pending.isEmpty { replaced.place?.giveUp() }
        pending.removeAll { $0.pending.isEmpty }
        let restore = Owed(
            id: UUID(), plan: plan, base: base, restored: restored, known: known, place: place,
            pending: Set(plan.marks)
        )
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

    /// A save of the writing committed `saved`, the writer's text being
    /// `current` (nil where it isn't known): each passage owed that the save holds is
    /// recorded, in its restore's own place in line where it still has one,
    /// else after the save's carry; one the save doesn't hold but the
    /// writing still does, or that the words can't answer for, waits; one in
    /// neither the writer has undone, and is owed no longer
    /// (`RestorePlan.settlement`). Returns once a place is filled, so the
    /// save made for a restore knows when it returns.
    func settle(writingID: String, saved: String, current: String? = nil, owedThen: Set<UUID>? = nil) async {
        // One at a time, in the order the saves asked: one finishing its
        // comparison first could drop a restore an earlier save holds.
        // Those owed as this save committed (`owedThen`, where the caller
        // took them with the writer's text), not any made while it waits
        // its turn.
        let eligible = owedThen ?? owedNow(for: writingID)
        let previous = settling
        let settlement = Task { [previous] in
            await previous?.value
            await self.settleNow(writingID: writingID, saved: saved, current: current, eligible: eligible)
        }
        settling = settlement
        await settlement.value
    }

    private var settling: Task<Void, Never>?

    /// The restores owed for a writing now, for a caller settling later to
    /// take with the writer's text, in the same turn.
    func owedNow(for writingID: String) -> Set<UUID> {
        Set(owed[writingID, default: []].map(\.id))
    }

    private func settleNow(writingID: String, saved: String, current: String?, eligible: Set<UUID>) async {
        guard let pending = owed[writingID]?.filter({ eligible.contains($0.id) }), !pending.isEmpty else { return }
        let store = LibrarySyncPass.reviewStore
        // Asked off the main actor: the whole writing is compared.
        let decided = await Task.detached(priority: .userInitiated) {
            pending.map { restore -> (id: UUID, asked: Set<UUID>, record: Set<UUID>, waiting: Set<UUID>) in
                let inSaved = restore.plan.standingByMark(from: restore.restored, in: saved)
                // The writer's text unknown: nothing is taken as undone.
                let inCurrent: [UUID: LampWritingReview.RestorePlan.Standing] = current.map {
                    $0 == saved ? inSaved : restore.plan.standingByMark(from: restore.restored, in: $0)
                } ?? [:]
                let settled = LampWritingReview.RestorePlan.settlement(
                    pending: restore.pending, inSaved: inSaved, inCurrent: inCurrent
                )
                return (restore.id, restore.pending, settled.record, settled.waiting)
            }
        }.value
        var inPlace: [(WritingReviewWork.Reservation, Recording)] = []
        var atEnd: [Recording] = []
        for decision in decided {
            // Still owed: a settle meanwhile may have recorded it.
            guard let index = owed[writingID]?.firstIndex(where: { $0.id == decision.id }),
                  let restore = owed[writingID]?[index] else { continue }
            let marks = decision.record.intersection(restore.pending)
            if !marks.isEmpty {
                let recording = Recording(restore: restore, marks: marks)
                if let place = restore.place { inPlace.append((place, recording)) } else { atEnd.append(recording) }
                owed[writingID]?[index].place = nil
            }
            // Only what this settle weighed is decided: a passage owed again
            // meanwhile (its record failed) is still owed.
            let waiting = restore.pending.subtracting(decision.asked.subtracting(decision.waiting))
            if waiting.isEmpty {
                // Undone, nothing recorded: the line doesn't wait on it.
                if marks.isEmpty { restore.place?.giveUp() }
                owed[writingID]?.remove(at: index)
            } else {
                owed[writingID]?[index].pending = waiting
            }
        }
        for (place, recording) in inPlace {
            let filled = place.fill {
                await Self.record([recording], writingID: writingID, saved: saved, store: store)
            }
            // Its place gone by meanwhile: recorded at the end of the line.
            if !filled { atEnd.append(recording) }
        }
        guard !atEnd.isEmpty else { return }
        WritingReviewWork.shared.run {
            await Self.record(atEnd, writingID: writingID, saved: saved, store: store)
        }
    }

    /// Writes these passages to the marks file, each restore's in its whole
    /// plan's places (`only:`); any it couldn't write are owed again, for
    /// the next save.
    nonisolated private static func record(
        _ recordings: [Recording], writingID: String, saved: String, store: LampWritingReviewStore
    ) async {
        guard !recordings.isEmpty else { return }
        let written = try? store.updating(writingID: writingID) { review in
            recordings.reduce(review) {
                $0.restoringWording(
                    $1.restore.plan, from: $1.restore.base, to: $1.restore.restored, only: $1.marks,
                    remarkingUnread: !$1.restore.clearedSince, carryingFrom: $1.restore.known
                )
            }
        }
        await MainActor.run {
            guard written != nil else {
                // Owed again: into what's still owed of the same restore, if
                // any of it waits, never a second of the same.
                for recording in recordings {
                    let obligations = WritingRestoreObligations.shared
                    if let index = obligations.owed[writingID]?.firstIndex(where: { $0.id == recording.restore.id }) {
                        obligations.owed[writingID]?[index].pending.formUnion(recording.marks)
                    } else {
                        var restore = recording.restore
                        restore.place = nil
                        restore.pending = recording.marks
                        obligations.owed[writingID, default: []].append(restore)
                    }
                }
                return
            }
            WritingReviewTexts.shared.remember(saved, for: writingID)
            WritingReviewWork.marksChanged()
        }
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
    /// How many of the marked ranges sent the page couldn't place (it drew
    /// the rest): a warning beside the count, not a number, since ranges
    /// aren't the count's changes; not sent again, since the same marks
    /// would split the same way. Zero once a set is drawn whole.
    @Published private(set) var unshownMarks = 0

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
    /// For one of a writing's files instead (`document`): writes the
    /// restored text over the file and records the restore with it, as one,
    /// since a file is written as it's saved, not through the writing's
    /// save. False where it couldn't be.
    var saveRestoredDocument: (@MainActor (
        _ plan: LampWritingReview.RestorePlan, _ base: String, _ restored: String, _ known: [String]
    ) async -> Bool)?
    /// One restore at a time: two pressed together would go through one
    /// save, and the page refuse the second's text.
    private var restoring = false

    private var writingID: String?
    /// One of the writing's files, followed in place of its prose.
    private var document: String?
    /// Counts each follow, so a reload from one superseded (marks turned
    /// off on leaving Edit) isn't drawn.
    private var following = 0
    private var store: LampWritingReviewStore?
    private var review: LampWritingReview?
    private var text = ""
    private var fileDate: Date?
    private var settleTask: Task<Void, Never>?
    private var drawGeneration = 0
    /// The marks are owed to the page (it refused the last set, or took a
    /// passage's marks off itself), so the next draw sends them. Counted,
    /// so a draw begun before a newer ask settles only what it began with.
    private var needsResend: Bool {
        get { resendAsked > resendSent }
        set { if newValue { resendAsked += 1 } else { resendSent = resendAsked } }
    }
    private var resendAsked = 0
    private var resendSent = 0
    /// The text a refused set of marks was last sent again for. Refused
    /// again for the same text, they wait for the text to change.
    private var resentFor: String?

    static let checkInterval: Duration = .seconds(1)
    static let settleDelay: Duration = .milliseconds(300)

    /// Keeps the writing's marks current until the task is cancelled: the
    /// view's `.task(id:)`, keyed on the writing and on whether marks are
    /// shown at all. Shown off, everything is cleared and nothing is read.
    /// `document`: one of the writing's files, whose own marks are followed,
    /// rather than the writing's prose.
    func follow(writingID: String, document: String? = nil, text: String, isShown: Bool) async {
        // Nothing drawn for the writing before may land now.
        settleTask?.cancel()
        drawGeneration += 1
        self.writingID = writingID
        self.document = document
        following += 1
        let follow = following
        self.text = text
        WritingReviewTexts.shared.remember(text, for: writingID, document: document)
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
                await self.reloadIfMoved(for: follow)
            }
        }
        defer { listening.cancel() }
        while !Task.isCancelled {
            await reloadIfMoved(for: follow)
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
    /// The page drew some of the marks and couldn't place `unshown`.
    func marksPartlyDrawn(unshown: Int) {
        if unshownMarks != unshown { unshownMarks = unshown }
    }

    func marksDrawn() {
        if unshownMarks != 0 { unshownMarks = 0 }
    }

    func marksRejected() {
        // Refused whole: the page's text wasn't this one's, so what it
        // couldn't place before says nothing about the marks resent.
        if unshownMarks != 0 { unshownMarks = 0 }
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
    private func clear(range: NSRange, in text: String, writingID: String, answersPage: Bool = false, answerIn pageText: String? = nil) {
        WritingReviewTexts.shared.remember(text, for: writingID, document: document)
        let known = WritingReviewTexts.shared.known(for: writingID, document: document)
        change(answersPage: answersPage, answerIn: pageText ?? text, heldAtPress: self.text) { $0.clearing(range, in: text, carryingFrom: known) }
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
    ///
    /// `answersPage`: the page has already taken the passage's marks off
    /// (a ✓ pressed there), so the clear is answered with the marks as they
    /// stand however it goes (`resendMarks`). Not for the selection's
    /// action, which takes nothing off the page.
    ///
    /// `wholeBlock`: a block's own ✓, as against a selection. The page
    /// draws a line's syntax apart from the block's words, so its ✓ asks for
    /// the words alone; it reaches to the line's ends over that syntax, a
    /// footnote's `[^1]:` and the emphasis the words open and close with, or
    /// a passage running through the label kept a sliver no ✓ could clear
    /// (owner, 2026-11-26; core's `wholeBlock`). A selection never reaches.
    /// As on the Mac.
    func clear(
        markedMarkdown marked: String, pageText: String? = nil, answersPage: Bool = false, wholeBlock: Bool = false
    ) {
        guard let writingID else { return }
        func asked(_ range: NSRange, of text: String) -> NSRange {
            wholeBlock
                ? LampWritingReviewMarkdown.wholeBlock(range, of: text)
                : LampWritingReviewMarkdown.takingInSyntax(range, of: text)
        }
        if let range = LampWritingReview.markedRange(in: marked, of: text) {
            // Answered in the page's own text where it sent one: matched
            // here across markup it wrote differently, it can still be
            // ahead.
            clear(
                range: asked(range, of: text), in: text, writingID: writingID,
                answersPage: answersPage, answerIn: pageText
            )
        } else if let pageText, let range = LampWritingReview.markedRange(in: marked, of: pageText) {
            // The page's text is ahead of (or behind) the one held here:
            // the answer is drawn in it, so marks the page moved for typing
            // not yet reported aren't put back where they were. The text
            // held stays the editor's last report.
            clear(range: asked(range, of: pageText), in: pageText, writingID: writingID, answersPage: answersPage)
        } else if answersPage {
            // Placed nowhere: the page has already taken the passage's
            // marks off, so it's sent back what stands, in its own text
            // where it sent one.
            resendMarks(in: pageText)
        }
    }

    /// The marks drawn and sent to the page now, whether or not the record
    /// changed. The page takes a ✓'s marks off at once, cut to what
    /// `clearing` keeps; at a block's edge (a heading's `#`, a fence, a
    /// blank line) it can't always tell, so every clear it makes is answered
    /// with the marks as they stand, which puts back anything it took off
    /// that the record keeps. As on the Mac.
    private func resendMarks(in pageText: String? = nil) {
        needsResend = true
        draw(sendsMarks: true, in: pageText)
    }

    func clearAll() {
        if let writingID, document == nil { WritingRestoreObligations.shared.clearedAll(for: writingID) }
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
            range = LampWritingReviewMarkdown.takingInSyntax(found, of: pageText)
        } else if let found = LampWritingReview.markedRange(in: marked, of: text) {
            base = text
            range = LampWritingReviewMarkdown.takingInSyntax(found, of: text)
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
        WritingReviewTexts.shared.remember(base, for: writingID, document: document)
        let known = WritingReviewTexts.shared.known(for: writingID, document: document)
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
        let document = self.document
        let planned = await Task.detached(priority: .userInitiated) {
            planning(review.carryingToText(base, from: known), base)
        }.value
        guard self.writingID == writingID, self.document == document else { return }
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
        WritingReviewTexts.shared.remember(restored, for: writingID, document: document)
        if document != nil {
            // A file: written and recorded as one, not owed to a save, in the
            // place taken before the edit, so a clear asked for meanwhile is
            // made after it, and clears what it marks.
            let save = saveRestoredDocument
            let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let filled = place.fill {
                    let done = await save?(plan, base, restored, known) ?? false
                    continuation.resume(returning: done)
                }
                if !filled { continuation.resume(returning: false) }
            }
            if !saved, self.writingID == writingID, self.document == document { restoreUnsaved = true }
            return
        }
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
    /// nil (`Drawing.changes`), none where no wording was kept.
    nonisolated static func changes(of review: LampWritingReview, _ drawing: LampWritingReview.Drawing) -> [LampWritingReview.Change?] {
        guard !review.wordings.isEmpty else { return drawing.ranges.map { _ in nil } }
        return drawing.changes
    }

    // MARK: - Internals

    /// Changes the marks file in line with the saves' carries, off the main
    /// actor, and takes up what was written, with the file's date read under
    /// the same lock.
    /// `answersPage`: made for a clear the page has already drawn, so the
    /// marks are sent back however it went (`resendMarks`): written, the
    /// same as before, or not written at all.
    private func change(
        answersPage: Bool = false, answerIn pressText: String? = nil, heldAtPress: String? = nil,
        _ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview) {
        guard let store, let writingID else { return }
        let document = self.document
        WritingReviewWork.shared.run { [weak self] in
            // Answered in the text the press was made in, unless the editor
            // has reported a newer one since: that's the page's now.
            @MainActor func answerText(_ session: WritingReviewSession) -> String? {
                session.text == heldAtPress ? pressText : nil
            }
            guard let written = try? store.updating(writingID: writingID, document: document, edit) else {
                guard answersPage else { return }
                await MainActor.run {
                    guard let self, self.writingID == writingID, self.document == document, self.store != nil else { return }
                    self.resendMarks(in: answerText(self))
                }
                return
            }
            await MainActor.run {
                WritingReviewWork.marksChanged()
                // A file's counts are shown in the Files list, which reads them
                // again on this.
                if document != nil { NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) }
                // Not for a writing left since, nor once marks were turned off.
                guard let self, self.writingID == writingID, self.document == document, self.store != nil else { return }
                // Drawn if the record moved; answered either way. Owed
                // from here, so typing settling before the draw lands
                // doesn't make it a count only.
                if answersPage { self.needsResend = true }
                let answerIn = answersPage ? answerText(self) : nil
                if !self.apply(written.review, date: written.modified, in: answerIn), answersPage {
                    self.resendMarks(in: answerIn)
                }
            }
        }
    }

    /// Reads the marks file again if its date has moved since it was last
    /// read: the record and its date together, under the file's lock, so a
    /// write can never be taken for the one before it.
    private func reloadIfMoved(for follow: Int) async {
        guard following == follow, let store, let writingID else { return }
        let document = self.document
        let read = await Task.detached(priority: .utility) {
            try? store.snapshot(writingID: writingID, document: document)
        }.value
        guard let read, read.modified != fileDate, self.writingID == writingID, self.document == document,
              following == follow, self.store != nil, !Task.isCancelled else { return }
        apply(read.modified == nil ? nil : read.review, date: read.modified)
    }

    /// Whether it drew: not when the record is as it was.
    @discardableResult
    private func apply(_ review: LampWritingReview?, date: Date?, in drawnText: String? = nil) -> Bool {
        fileDate = date
        guard review != self.review else { return false }
        self.review = review
        draw(sendsMarks: true, in: drawnText)
        return true
    }

    private func scheduleDraw() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            if let writingID = self.writingID {
                WritingReviewTexts.shared.remember(self.text, for: writingID, document: self.document)
            }
            // Sent too while none are shown and some stand: marks that placed
            // nowhere in the text before (a newer body arrived) may place in
            // this one. All cleared, nothing goes to the page each settle.
            let unplaced = self.markedMarkdown == nil && self.review?.isEmpty == false
            self.draw(sendsMarks: self.needsResend || unplaced)
        }
    }

    /// `drawnText`: the page's own text, for an answer to its clear, where
    /// it isn't the one held here; the count is then drawn again from the
    /// held text, which stays the editor's last report.
    private func draw(sendsMarks: Bool, in drawnText: String? = nil) {
        drawGeneration += 1
        let generation = drawGeneration
        let asked = resendAsked
        guard let review, !review.isEmpty else {
            publish(count: 0, marked: nil, changes: [], sendsMarks: sendsMarks, settling: asked)
            return
        }
        let text = drawnText ?? self.text
        // Drawn from the marks carried into the text as it is now, each from
        // the text it's anchored in: typed into since they were saved, a
        // marked passage would otherwise be found nowhere until the next save
        // carries it.
        let known = writingID.map { WritingReviewTexts.shared.known(for: $0, document: document) } ?? []
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                let live = review.carryingToText(text, from: known)
                // Only the count while typing: nothing to place, nor what
                // could be put back.
                guard sendsMarks else { return (live.passageCount(in: text), String?.none, [LampWritingReview.Change?]()) }
                // Everything drawn from one finding of the marks (core's
                // `drawing(in:)`), not each from its own. Placed where the
                // Markdown still reads as it did, each passage's place
                // written after its marker, which the page pairs `changes`
                // by: placing can put two in another order.
                let drawing = live.drawing(in: text)
                let marked = drawing.markedMarkdown.map { LampWritingReviewMarkdown.drawable($0) }
                let changes = marked == nil ? [] : Self.changes(of: live, drawing)
                // Passages as drawn, not marks, as the Mac counts them: see
                // `passageCount`.
                return (drawing.passageCount, marked, changes)
            }.value
            guard let self, self.drawGeneration == generation else { return }
            // An answer drawn in the page's text where the text held here
            // has since moved: drawn and sent again in the held one once it
            // settles, which the editor's report moves on to. None sent
            // from the page's text: the page takes no marks at all without
            // checking its text, and the newer one may hold some.
            let snapshotMoved = drawnText != nil && text != self.text
            if snapshotMoved {
                self.needsResend = true
                self.scheduleDraw()
                if drawn.1 == nil { return }
            }
            self.publish(count: drawn.0, marked: drawn.1, changes: drawn.2, sendsMarks: sendsMarks, settling: asked)
        }
    }

    /// `settling`: the asks to resend made before the draw began, which a
    /// sending draw has answered. Owed no longer only once sent: a draw
    /// overtaken by another (typing settling, a count only) leaves them
    /// owed, and one asked for during the draw is still owed after it.
    private func publish(
        count: Int, marked: String?, changes: [LampWritingReview.Change?], sendsMarks: Bool, settling asked: Int? = nil
    ) {
        if self.count != count { self.count = count }
        if sendsMarks {
            resendSent = max(resendSent, asked ?? resendAsked)
            markedMarkdown = marked
            markedChanges = changes
            if marked == nil, unshownMarks != 0 { unshownMarks = 0 }
            let restorable = changes.contains { $0 != nil }
            if canRestore != restorable { canRestore = restorable }
            onMarksChanged?(marked, changes)
        }
    }
}
