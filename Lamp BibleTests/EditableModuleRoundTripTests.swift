//
//  EditableModuleRoundTripTests.swift
//  Lamp BibleTests
//
//  The other two kinds of module this device publishes: notes and highlight
//  sets. Writings have their own suite; these travel by the same road and had
//  nothing checking they arrive unchanged.
//

import GRDB
import LampCore
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
}
