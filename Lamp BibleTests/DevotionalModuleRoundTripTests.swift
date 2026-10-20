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
import CryptoKit
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
        try? FileManager.default.removeItem(
            at: DevotionalMediaStorage.shared.mediaDirectory(moduleId: moduleId)
        )
    }

    // MARK: - Helpers

    private func saveEntry(
        id: String = "entry-1",
        title: String = "Cantata Narration",
        contentJson: String,
        media: [DevotionalMediaReference]? = nil,
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
                footnotes: [DevotionalFootnote(id: "1", content: .plain("First"))],
                media: media
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
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .devotional)
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
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .devotional)
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
        let storage = ShelfStorage(
            shelf: shelf, moduleID: moduleId, moduleType: .devotional, fileName: name
        )
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

    /// An attachment is not in the module file at all — it travels beside it,
    /// and a writing whose image did not make the trip is a writing with a
    /// hole in it.
    func testAnAttachmentTravelsBesideItsWriting() async throws {
        let reference = DevotionalMediaReference(
            id: "A1", type: .image, filename: "A1.png", mimeType: "image/png"
        )
        try saveEntry(contentJson: authoredBody, media: [reference])
        let bytes = Data((0..<2048).map { UInt8($0 % 251) })
        try DevotionalMediaStorage.shared.ensureMediaDirectory(
            devotionalId: "entry-1", moduleId: moduleId
        )
        let localURL = DevotionalMediaStorage.shared.expectedMediaURL(
            for: reference, devotionalId: "entry-1", moduleId: moduleId
        )
        try bytes.write(to: localURL)

        let shelf = ModuleShelf()
        let storage = ShelfStorage(shelf: shelf, moduleID: moduleId, moduleType: .devotional)
        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)

        // The other device has the file; this one loses it.
        try FileManager.default.removeItem(at: localURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        await shelf.reissueRevision(for: "\(moduleId!).lamp")

        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)

        XCTAssertEqual(try Data(contentsOf: localURL), bytes)
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

    /// See EditableModuleRoundTripTests: this device's export is compared with
    /// its own last upload, so storage order must not reach the bytes.
    func testAWritingsExportIsTheSameBytesUntilAWritingChanges() throws {
        let body = #"{"blocks":[{"type":"paragraph","text":"In the beginning"}]}"#
        for id in ["entry-a", "entry-b", "entry-c"] {
            // Untitled drafts on one date: tied on everything a reader sorts by.
            try saveEntry(id: id, title: "", contentJson: body)
        }
        let module = try XCTUnwrap(database.getModule(id: moduleId))
        let digest = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let export = { digest(try ModuleSyncManager.shared.exportDevotionalModuleToSQLite(module)) }
        let first = try export()
        XCTAssertEqual(try export(), first)

        for _ in 0..<5 {
            try database.deleteDevotionalEntry(id: "entry-a")
            try saveEntry(id: "entry-a", title: "", contentJson: body)
            XCTAssertEqual(try export(), first)
        }

        try saveEntry(id: "entry-b", title: "Named now", contentJson: body)
        XCTAssertNotEqual(try export(), first)
    }
}
