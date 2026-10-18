//
//  DevotionalModuleRoundTripTests.swift
//  Lamp BibleTests
//
//  Publishing a module of writings and reading the same bytes back must change
//  nothing. Every disagreement this app has had to ask someone to settle began
//  with a round trip that quietly altered a column while the change time stayed
//  where it was, which leaves two devices holding different text and no way to
//  tell which came later.
//

import GRDB
import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class DevotionalModuleRoundTripTests: XCTestCase {
    private var moduleId: String!
    private var database: ModuleDatabase!

    /// A body with no blocks of its own: everything here is Markdown the editor
    /// wrote, including the shapes a block tree cannot hold.
    private let authoredBody = """
        ## A heading

        This is a test. Test. Another test.

        ![Caption](lamp-media://B7FAA5A6/32D89C7E.png)

        | One | Two |
        | --- | --- |
        | a | b |
        """

    override func setUpWithError() throws {
        moduleId = "round-trip-\(UUID().uuidString)"
        database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .devotional,
            name: "Round trip",
            description: "A module that goes out and comes back",
            filePath: "\(moduleId!).lamp",
            isEditable: true
        ))
    }

    override func tearDownWithError() throws {
        try? database.deleteAllEntriesForModule(moduleId: moduleId)
        try? database.deleteModule(id: moduleId)
    }

    // MARK: - Helpers

    private func saveEntry(
        id: String = "entry-1",
        title: String = "Cantata Narration",
        contentJson: String,
        lastModified: Int = 1_788_132_249
    ) throws {
        var entry = DevotionalEntry(
            from: Devotional(
                meta: DevotionalMeta(
                    id: id,
                    title: title,
                    subtitle: "A morning reflection",
                    author: "John Smith",
                    date: "2026-01-18",
                    tags: ["faith", "prayer"],
                    category: .devotional,
                    keyScriptures: [DevotionalKeyScripture(sv: 43_001_001, ev: nil, label: "John 1:1")],
                    created: 1_769_317_935,
                    lastModified: lastModified
                ),
                summary: .plain("What this one is about"),
                footnotes: [DevotionalFootnote(id: "1", content: .plain("First"))]
            ),
            moduleId: moduleId
        )
        entry.contentJson = contentJson
        try database.saveDevotionalEntry(entry)
    }

    /// Every stored column of every entry, in a form two states can be compared
    /// by. Naming the columns one by one would quietly stop covering a column
    /// added later, which is exactly where this kind of damage hides.
    private func storedEntries() throws -> [String] {
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .order(Column("id"))
                .fetchAll(db)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    }

    /// Publish the module, then hand the same bytes back as though another
    /// device had uploaded them: same content, a revision this device has not
    /// seen, which is what makes sync read the file rather than skip it.
    private func publishAndPullBack() async throws {
        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        let writes = await shelf.writeCount()
        XCTAssertEqual(writes, 1, "the module should have been published once")
        await shelf.reissueRevision(for: "\(moduleId!).lamp")
        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)
    }

    // MARK: - Fidelity

    /// The regression behind every phantom conflict: a sync in which nobody
    /// edited anything must leave every column where it was.
    func testASyncThatChangesNothingLeavesAWritingExactlyAsItWas() async throws {
        try saveEntry(contentJson: authoredBody)
        let before = try storedEntries()

        try await publishAndPullBack()

        XCTAssertEqual(try storedEntries(), before)
        XCTAssertFalse(try database.hasPendingModuleConflicts(moduleId: moduleId))
    }

    /// The same bytes read back when there is nothing local to merge with, which
    /// is what a second device sees the first time it syncs.
    func testAWritingComesBackWholeWhenThisDeviceHasNoCopy() async throws {
        try saveEntry(contentJson: authoredBody)
        let before = try storedEntries()

        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)
        try database.deleteAllEntriesForModule(moduleId: moduleId)
        XCTAssertEqual(try storedEntries(), [])
        await shelf.reissueRevision(for: "\(moduleId!).lamp")

        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)

        XCTAssertEqual(try storedEntries(), before)
    }

    /// Named on its own because this is the column that has twice been rewritten
    /// in place: authored Markdown must still be text, not a block tree.
    func testAnAuthoredBodyIsStillTextAfterTheRoundTrip() async throws {
        try saveEntry(contentJson: authoredBody)

        try await publishAndPullBack()

        let stored = try XCTUnwrap(try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId).fetchOne(db)
        })
        XCTAssertEqual(stored.contentJson, authoredBody)
        let devotional = try XCTUnwrap(stored.toDevotional())
        XCTAssertEqual(devotional.markdownContent, authoredBody)
    }

    /// And the other shape: a writing that really is blocks stays blocks.
    func testStructuredBlocksAreStillBlocksAfterTheRoundTrip() async throws {
        let blocks = """
            [{"type":"heading","level":2,"content":{"text":"A heading"}},\
            {"type":"paragraph","content":{"text":"Body."}}]
            """
        try saveEntry(contentJson: blocks)

        try await publishAndPullBack()

        let stored = try XCTUnwrap(try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId).fetchOne(db)
        })
        XCTAssertEqual(stored.contentJson, blocks)
        let devotional = try XCTUnwrap(stored.toDevotional())
        XCTAssertNil(devotional.markdownContent)
        XCTAssertEqual(devotional.content.allBlocks.count, 2)
    }

    /// A module of several writings keeps all of them, in the state each was in.
    func testEveryWritingInTheModuleSurvivesTogether() async throws {
        try saveEntry(id: "entry-1", title: "First", contentJson: authoredBody)
        try saveEntry(id: "entry-2", title: "Second", contentJson: "Plain body.")
        try saveEntry(id: "entry-3", title: "Third", contentJson: "# Third\n\nAnother.")
        let before = try storedEntries()
        XCTAssertEqual(before.count, 3)

        try await publishAndPullBack()

        XCTAssertEqual(try storedEntries(), before)
    }

    /// The legacy JSON module form, which the Mac and older releases publish
    /// and this app still reads. Unlike the SQLite form, which carries the
    /// stored column across untouched, this one rebuilds each writing from a
    /// decoded model — the step that twice turned an authored body into a
    /// block tree.
    func testAJSONModuleWithAnAuthoredBodyStoresItAsText() async throws {
        let shelf = ModuleShelf()
        let name = "\(moduleId!).json"
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, fileName: name)
        let file = DevotionalModuleFile(
            id: moduleId,
            name: "Round trip",
            isEditable: true,
            entries: [Devotional(
                meta: DevotionalMeta(
                    id: "entry-1", title: "Cantata Narration",
                    created: 1_769_317_935, lastModified: 1_788_132_249
                ),
                content: .blocks([.paragraph(authoredBody)])
            )]
        )
        await shelf.write(try JSONEncoder().encode(file), named: name)

        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)

        let stored = try XCTUnwrap(try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId).fetchOne(db)
        })
        XCTAssertEqual(stored.contentJson, authoredBody)
        XCTAssertEqual(try XCTUnwrap(stored.toDevotional()).markdownContent, authoredBody)
    }

    /// The module record travels with its entries; losing its name or its
    /// editability would strand the writings in a module nobody can write to.
    func testTheModuleItselfComesBackWithItsNameAndEditability() async throws {
        try saveEntry(contentJson: authoredBody)

        try await publishAndPullBack()

        let module = try XCTUnwrap(try database.getModule(id: moduleId))
        XCTAssertEqual(module.name, "Round trip")
        XCTAssertEqual(module.description, "A module that goes out and comes back")
        XCTAssertTrue(module.isEditable)
        XCTAssertEqual(module.filePath, "\(moduleId!).lamp")
    }
}

// MARK: - Storage double

/// Somewhere to put a published module and read it back. Revisions behave the
/// way a real backend's do: a new one on every write, and `reissueRevision`
/// for the case this suite cares about — the same bytes offered under a
/// revision this device has not recorded.
private actor ModuleShelf {
    private var files: [String: Data] = [:]
    private var revisions: [String: String] = [:]
    private var issued = 0
    private var writes = 0

    func write(_ data: Data, named name: String) {
        writes += 1
        files[name] = data
        revisions[name] = nextRevision()
    }

    func reissueRevision(for name: String) {
        guard files[name] != nil else { return }
        revisions[name] = nextRevision()
    }

    func data(named name: String) -> Data? { files[name] }
    func revision(named name: String) -> String? { revisions[name] }
    func names() -> [String] { files.keys.sorted() }
    func writeCount() -> Int { writes }

    private func nextRevision() -> String {
        issued += 1
        return "revision-\(issued)"
    }
}

private struct ShelfStorage: ModuleStorage {
    let shelf: ModuleShelf
    let moduleID: String
    /// The one file this backend offers. Publishing writes `<id>.lamp`, so a
    /// test serving the legacy JSON form says so rather than having the
    /// listing pick up whatever a publish left behind.
    var fileName: String? = nil

    func isAvailable() async -> Bool { true }

    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == .devotional else { return [] }
        let name = fileName ?? "\(moduleID).lamp"
        guard await shelf.data(named: name) != nil else { return [] }
        return [ModuleFileInfo(
            id: moduleID,
            type: .devotional,
            filePath: name,
            fileHash: await shelf.revision(named: name),
            modificationDate: nil
        )]
    }

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        guard let data = await shelf.data(named: fileName) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return data
    }

    func readModuleSnapshot(
        type: ModuleType, fileName: String
    ) async throws -> LampSyncRemoteFile {
        LampSyncRemoteFile(
            data: try await readModuleFile(type: type, fileName: fileName),
            revision: await shelf.revision(named: fileName)
        )
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        await shelf.write(data, named: fileName)
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        XCTFail("A round trip must not delete the module")
    }

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await shelf.revision(named: fileName)
    }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }

    func readFile(path: String) async throws -> Data {
        guard let data = await shelf.data(named: path) else {
            throw ModuleStorageError.fileNotFound(path)
        }
        return data
    }

    func writeFile(path: String, data: Data) async throws {
        await shelf.write(data, named: path)
    }
}
