//
//  EditableModuleRoundTripTests.swift
//  Lamp BibleTests
//
//  The other two kinds of module this device publishes: notes and highlight
//  sets. Writings have their own suite; these travel by the same road and had
//  nothing checking they arrive unchanged.
//

import CryptoKit
import GRDB
import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class EditableModuleRoundTripTests: XCTestCase {
    private var moduleId: String!
    private var database: ModuleDatabase!

    override func setUpWithError() throws {
        moduleId = "editable-round-trip-\(UUID().uuidString)"
        database = ModuleDatabase.shared
    }

    override func tearDownWithError() throws {
        try? database.deleteAllEntriesForModule(moduleId: moduleId)
        try? database.deleteModule(id: moduleId)
        // Item ids repeat across these tests; a deletion recorded by one must
        // not drop the next one's import.
        try? database.write { try $0.execute(sql: "DELETE FROM personal_sync_ledger") }
    }

    private func saveModule(type: ModuleType, name: String) throws {
        try database.saveModule(Module(
            id: moduleId,
            type: type,
            name: name,
            filePath: "\(moduleId!).lamp",
            isEditable: true
        ))
    }

    /// Publish, then offer the same bytes back under a revision this device
    /// has not seen — what a second device republishing looks like from here.
    private func publishAndPullBack(type: ModuleType) async throws -> ModuleShelf {
        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: type)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        // Otherwise a suite that published nothing, and so read nothing back,
        // would pass by having left everything alone.
        let published = await shelf.names()
        XCTAssertEqual(published, ["\(moduleId!).lamp"])
        await shelf.reissueRevision(for: "\(moduleId!).lamp")
        try await ModuleSyncManager.shared.syncModuleType(type, using: storage)
        return shelf
    }

    // MARK: - Notes

    private func saveNote(
        id: String = "note-1",
        verseId: Int = 43_001_001,
        title: String? = "On the Word",
        content: String = "The Word was with God.[^1]",
        lastModified: Int = 1_788_132_249
    ) throws {
        let entry = NoteEntry(
            id: id,
            moduleId: moduleId,
            verseId: verseId,
            title: title,
            content: content,
            verseRefs: [43_001_001, 43_001_002],
            lastModified: lastModified,
            footnotes: [UserNotesFootnote(id: "1", content: .text("First"))]
        )
        try database.saveNoteEntry(entry)
    }

    private func storedNotes() throws -> [String] {
        let entries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .order(Column("id"))
                .fetchAll(db)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    }

    /// A sync in which nobody edited anything must leave every column alone —
    /// the same guarantee writings now have, for the kind of record there are
    /// far more of.
    func testASyncThatChangesNothingLeavesANoteExactlyAsItWas() async throws {
        try saveModule(type: .notes, name: "My Notes")
        try saveNote()
        let before = try storedNotes()

        _ = try await publishAndPullBack(type: .notes)

        XCTAssertEqual(try storedNotes(), before)
        XCTAssertFalse(try database.hasPendingModuleConflicts(moduleId: moduleId))
    }

    func testEveryNoteComesBackWholeWhenThisDeviceHasNone() async throws {
        try saveModule(type: .notes, name: "My Notes")
        try saveNote(id: "note-1", verseId: 43_001_001)
        try saveNote(id: "note-2", verseId: 1_031_000, title: nil, content: "A chapter introduction.")
        try saveNote(id: "note-3", verseId: 19_023_001, content: "The Lord is my shepherd.")
        let before = try storedNotes()
        XCTAssertEqual(before.count, 3)

        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .notes)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        try database.deleteAllEntriesForModule(moduleId: moduleId)
        XCTAssertEqual(try storedNotes(), [])
        await shelf.reissueRevision(for: "\(moduleId!).lamp")

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)

        XCTAssertEqual(try storedNotes(), before)
    }

    /// A note's footnotes are a separate column from its text, and the one
    /// most easily dropped on the way through.
    func testANotesFootnotesSurviveTheRoundTrip() async throws {
        try saveModule(type: .notes, name: "My Notes")
        try saveNote()

        _ = try await publishAndPullBack(type: .notes)

        let stored = try XCTUnwrap(try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId).fetchOne(db)
        })
        XCTAssertEqual(stored.footnotes?.map(\.id), ["1"])
        XCTAssertEqual(stored.footnotes?.map(\.plainText), ["First"])
        XCTAssertEqual(stored.verseRefs, [43_001_001, 43_001_002])
        XCTAssertEqual(stored.title, "On the Word")
    }

    // MARK: - Highlights

    private func saveHighlightSet(lastModified: Int) throws -> String {
        let set = HighlightSet(
            id: "\(moduleId!)-set",
            moduleId: moduleId,
            name: "My Highlights",
            translationId: "KJV",
            created: 1_769_317_935,
            lastModified: lastModified
        )
        try database.saveHighlightSet(set)
        for (index, reference) in [43_003_016, 19_023_001, 45_008_028].enumerated() {
            _ = try database.saveHighlight(HighlightEntry(
                setId: set.id, ref: reference, sc: 0, ec: 10 + index
            ))
        }
        return set.id
    }

    private func storedHighlights(setId: String) throws -> [String] {
        let entries = try database.read { db in
            try HighlightEntry
                .filter(Column("set_id") == setId)
                .order(Column("ref"))
                .fetchAll(db)
        }
        return entries.map { "\($0.ref):\($0.sc)-\($0.ec):\($0.style)" }
    }

    /// Highlights are the one kind that keeps the local copy when the remote
    /// is no newer, so reading back what this device just published must
    /// leave the set alone rather than replace it with a copy of itself.
    func testReadingBackOwnHighlightsLeavesTheSetAlone() async throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        let before = try storedHighlights(setId: setId)
        XCTAssertEqual(before.count, 3)

        _ = try await publishAndPullBack(type: .highlights)

        XCTAssertEqual(try storedHighlights(setId: setId), before)
        XCTAssertEqual(
            try database.getHighlightSets(forModule: moduleId).map(\.name), ["My Highlights"]
        )
    }

    /// And when this device has nothing, the published set is what it gets.
    func testAHighlightSetComesBackWhenThisDeviceHasNone() async throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        let before = try storedHighlights(setId: setId)

        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .highlights)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        try database.deleteAllEntriesForModule(moduleId: moduleId)
        XCTAssertEqual(try storedHighlights(setId: setId), [])
        await shelf.reissueRevision(for: "\(moduleId!).lamp")

        try await ModuleSyncManager.shared.syncModuleType(.highlights, using: storage)

        XCTAssertEqual(try storedHighlights(setId: setId), before)
        XCTAssertEqual(try database.getHighlightCount(setId: setId), 3)
    }

    // MARK: - Export stability

    /// Whether to upload is decided by comparing this device's own export with
    /// what it last uploaded. Bytes that follow storage order rather than
    /// content would re-upload the module on every pass.
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testANotesExportIsTheSameBytesUntilANoteChanges() throws {
        try saveModule(type: .notes, name: "My Notes")
        for (offset, id) in ["note-a", "note-b", "note-c"].enumerated() {
            try saveNote(id: id, verseId: 43_001_001 + offset)
        }
        let module = try XCTUnwrap(database.getModule(id: moduleId))
        let export = { [self] in digest(try ModuleSyncManager.shared.exportNoteModuleToSQLite(module)) }
        let first = try export()
        XCTAssertEqual(try export(), first)

        // Saved again unchanged: it moves in storage, not in content. More
        // than once, because a key order that is not fixed can still repeat.
        for _ in 0..<5 {
            try database.deleteNoteEntry(id: "note-a")
            try saveNote(id: "note-a", verseId: 43_001_001)
            XCTAssertEqual(try export(), first)
        }

        try saveNote(id: "note-b", verseId: 43_001_002, content: "Edited.")
        XCTAssertNotEqual(try export(), first)
    }

    func testAHighlightsExportIsTheSameBytesUntilAHighlightChanges() throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        // Three that start at the same place, which the old order left to storage.
        let tied = try database.saveHighlight(HighlightEntry(setId: setId, ref: 43_003_016, sc: 0, ec: 4))
        _ = try database.saveHighlight(HighlightEntry(setId: setId, ref: 43_003_016, sc: 0, ec: 30))
        let module = try XCTUnwrap(database.getModule(id: moduleId))
        let export = { [self] in digest(try ModuleSyncManager.shared.exportHighlightModuleToSQLite(module)) }
        let first = try export()
        XCTAssertEqual(try export(), first)

        try database.deleteHighlight(id: try XCTUnwrap(tied.id))
        _ = try database.saveHighlight(HighlightEntry(setId: setId, ref: 43_003_016, sc: 0, ec: 4))
        XCTAssertEqual(try export(), first)

        _ = try database.saveHighlight(HighlightEntry(setId: setId, ref: 1_001_001, sc: 0, ec: 2))
        XCTAssertNotEqual(try export(), first)
    }

    // MARK: - Deletions

    private func storedNoteIDs() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note_entries WHERE module_id = ? ORDER BY id", arguments: [moduleId])
        }
    }

    /// Publish, change something here, then sync with the published copy:
    /// pull it back, and publish again whatever that leaves to send.
    @discardableResult
    private func publishThenPull(_ change: () throws -> Void) async throws -> ModuleShelf {
        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .notes)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        try change()
        await shelf.reissueRevision(for: "\(moduleId!).lamp")
        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        return shelf
    }

    private func publishedNoteIDs(on shelf: ModuleShelf) async throws -> [String] {
        let stored = await shelf.data(named: "\(moduleId!).lamp")
        let packed = try XCTUnwrap(stored)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        try LampZlib.decompress(packed, to: url)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try await queue.read { try String.fetchAll($0, sql: "SELECT id FROM note_entries ORDER BY id") }
    }

    /// The import merge is a union, so before the ledger a note deleted here
    /// came straight back from any copy that still had it.
    func testANoteDeletedHereIsNotBroughtBackByAnOlderCopy() async throws {
        try saveModule(type: .notes, name: "My Notes")
        try saveNote(id: "gone", verseId: 43_001_001)
        try saveNote(id: "stays", verseId: 43_001_002)

        let shelf = try await publishThenPull { try database.deleteNoteEntry(id: "gone") }

        XCTAssertEqual(try storedNoteIDs(), ["stays"])
        // And the copy on the server, which still had it, was replaced.
        let published = try await publishedNoteIDs(on: shelf)
        XCTAssertEqual(published, ["stays"])
    }

    /// An edit made elsewhere after the deletion is newer than it, and wins.
    func testAnEditMadeAfterADeletionComesBack() async throws {
        try saveModule(type: .notes, name: "My Notes")
        let later = Int(Date().timeIntervalSince1970) + 3_600
        try saveNote(id: "edited", verseId: 43_001_001, lastModified: later)

        try await publishThenPull { try database.deleteNoteEntry(id: "edited") }

        XCTAssertEqual(try storedNoteIDs(), ["edited"])
    }

    /// A deletion another device made arrives as a ledger, and takes the
    /// note away here too.
    func testADeletionRecordedElsewhereRemovesTheNoteHere() throws {
        try saveModule(type: .notes, name: "My Notes")
        try saveNote(id: "theirs", verseId: 43_001_001)
        try saveNote(id: "kept", verseId: 43_001_002)
        try database.clearPendingModulePublication(moduleId: moduleId)
        var incoming = LampPersonalDeletionLedger()
        incoming.set(.init(deletedAt: ModuleDatabase.nowMilliseconds() + 1_000), kind: .note, key: "theirs")

        try database.mergePersonalDeletionLedger(incoming)
        let touched = try database.applyPersonalDeletionLedger()

        XCTAssertEqual(touched, [moduleId])
        XCTAssertEqual(try storedNoteIDs(), ["kept"])
        XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
        // Applying it records nothing new: the note is not deleted again here.
        XCTAssertEqual(try database.personalDeletionLedger().entry(.note, "theirs")?.deletedAt,
                       incoming.entry(.note, "theirs")?.deletedAt)
    }

    // MARK: - Highlight deletions

    private func storedHighlightKeys(setId: String) throws -> [String] {
        try database.getAllHighlights(setId: setId).map(ModuleDatabase.ledgerKey)
    }

    func testAHighlightDeletedElsewhereIsRemovedHere() throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        let all = try storedHighlightKeys(setId: setId)
        XCTAssertEqual(all.count, 3)
        var incoming = LampPersonalDeletionLedger()
        incoming.recordDeletion(.highlight, all[0], at: ModuleDatabase.nowMilliseconds() + 1_000)

        try database.mergePersonalDeletionLedger(incoming)
        XCTAssertEqual(try database.applyPersonalDeletionLedger(), [moduleId])

        XCTAssertEqual(try storedHighlightKeys(setId: setId), Array(all.dropFirst()))
    }

    func testHighlightingTheSameWordsAgainAfterDeletingThemKeepsIt() throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        let first = try XCTUnwrap(database.getAllHighlights(setId: setId).first)
        try database.deleteHighlight(id: try XCTUnwrap(first.id))
        Thread.sleep(forTimeInterval: 0.005)  // a person cannot do both in one millisecond
        _ = try database.saveHighlight(HighlightEntry(setId: setId, ref: first.ref, sc: first.sc, ec: first.ec))

        try database.applyPersonalDeletionLedger()

        XCTAssertTrue(try storedHighlightKeys(setId: setId).contains(ModuleDatabase.ledgerKey(first)))
    }

    /// A highlight is known by where it is: moving one is, to another device,
    /// deleting it there and highlighting here.
    func testMovingAHighlightRecordsTheOldPlaceAsDeleted() throws {
        try saveModule(type: .highlights, name: "My Highlights")
        let setId = try saveHighlightSet(lastModified: 1_788_132_249)
        let moved = try XCTUnwrap(database.getAllHighlights(setId: setId).first)
        Thread.sleep(forTimeInterval: 0.005)
        try database.updateHighlight(id: try XCTUnwrap(moved.id), sc: moved.sc + 1, ec: moved.ec + 1)

        let ledger = try database.personalDeletionLedger()
        XCTAssertTrue(ledger.isDeleted(.highlight, ModuleDatabase.ledgerKey(moved), itemModified: nil))
        var now = moved
        now.sc += 1
        now.ec += 1
        XCTAssertFalse(ledger.isDeleted(.highlight, ModuleDatabase.ledgerKey(now), itemModified: nil))
    }
}
