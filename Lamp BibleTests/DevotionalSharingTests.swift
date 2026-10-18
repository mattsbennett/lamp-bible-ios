//
//  DevotionalSharingTests.swift
//  Lamp BibleTests
//
//  Tests for sharing individual devotionals: export/import round-trip and the
//  identity rules that keep an import from overwriting existing entries.
//

import XCTest
@testable import Lamp_Bible

final class DevotionalSharingTests: XCTestCase {
    private var manager: DevotionalSharingManager!
    private var createdFiles: [URL] = []

    override func setUpWithError() throws {
        manager = DevotionalSharingManager.shared
        createdFiles = []
    }

    override func tearDownWithError() throws {
        for url in createdFiles {
            try? FileManager.default.removeItem(at: url)
        }
        createdFiles = []
    }

    // MARK: - Helpers

    private func makeDevotional(
        id: String = "fixed-id-0001",
        title: String = "Walking by Faith"
    ) -> Devotional {
        Devotional(
            meta: DevotionalMeta(
                id: id,
                title: title,
                subtitle: "A morning reflection",
                author: "John Smith",
                date: "2025-01-18",
                tags: ["faith", "prayer"],
                category: .devotional
            ),
            content: .blocks([.paragraph("The journey of faith is not always easy.")])
        )
    }

    private func track(_ url: URL) -> URL {
        createdFiles.append(url)
        return url
    }

    /// Write a multi-entry collection file, the shape that used to lose everything
    /// after the first entry on import.
    private func writeCollection(titles: [String]) throws -> URL {
        let moduleFile = DevotionalModuleFile(
            id: "shared-collection",
            name: "Lenten Readings",
            description: "A short series",
            author: "John Smith",
            entries: titles.enumerated().map { index, title in
                makeDevotional(id: "entry-\(index)", title: title)
            }
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lamp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(moduleFile).write(to: url)
        return track(url)
    }

    // MARK: - Round-trip

    func testExportImportRoundTripPreservesContent() throws {
        let original = makeDevotional()
        let exported = try track(manager.exportForSharing(original))

        let imported = try XCTUnwrap(manager.importFromFile(exported).first)

        XCTAssertEqual(imported.meta.title, original.meta.title)
        XCTAssertEqual(imported.meta.subtitle, original.meta.subtitle)
        XCTAssertEqual(imported.meta.author, original.meta.author)
        XCTAssertEqual(imported.meta.date, original.meta.date)
        XCTAssertEqual(imported.meta.category, original.meta.category)
        XCTAssertEqual(imported.meta.tags, original.meta.tags)
        XCTAssertEqual(
            imported.content.allBlocks.first?.content?.text,
            "The journey of faith is not always easy."
        )
    }

    func testSingleDevotionalFileImportsExactlyOneEntry() throws {
        let exported = try track(manager.exportForSharing(makeDevotional()))

        XCTAssertEqual(try manager.importFromFile(exported).count, 1)
    }

    // MARK: - Collections

    /// Importing a collection used to keep only `entries.first` and silently drop the
    /// rest, even though the preview advertised the full count.
    func testImportingCollectionKeepsEveryEntry() throws {
        let titles = ["First Light", "Second Wind", "Third Day", "Fourth Watch"]
        let url = try writeCollection(titles: titles)

        let imported = try manager.importFromFile(url)

        XCTAssertEqual(imported.count, titles.count)
        XCTAssertEqual(imported.map(\.meta.title), titles)
    }

    func testCollectionEntriesEachGetDistinctIdentities() throws {
        let url = try writeCollection(titles: ["One", "Two", "Three"])

        let imported = try manager.importFromFile(url)
        let ids = Set(imported.map(\.meta.id))

        XCTAssertEqual(ids.count, imported.count, "Entries must not share an ID")
        // None may keep the sender's IDs, which would upsert over existing entries
        XCTAssertTrue(ids.isDisjoint(with: ["entry-0", "entry-1", "entry-2"]))
    }

    /// The count the preview shows must match what the import actually writes.
    func testPreviewCountMatchesImportedCount() throws {
        let titles = ["One", "Two", "Three", "Four", "Five"]
        let url = try writeCollection(titles: titles)

        let preview = try manager.previewFile(url)

        XCTAssertEqual(preview.type, .devotionalModule)
        XCTAssertEqual(preview.devotionalCount, titles.count)
        XCTAssertEqual(try manager.importFromFile(url).count, preview.devotionalCount)
    }

    /// A collection carrying a single entry is presented as a plain devotional
    func testSingleEntryCollectionPreviewsAsDevotional() throws {
        let url = try writeCollection(titles: ["Only One"])

        let preview = try manager.previewFile(url)

        XCTAssertEqual(preview.type, .devotional)
        XCTAssertEqual(preview.devotionalCount, 1)
        XCTAssertEqual(try manager.importFromFile(url).count, 1)
    }

    // MARK: - Identity

    /// Saving upserts on `meta.id`. If an import kept the sender's ID it would silently
    /// replace a recipient entry that happened to share it.
    func testImportAssignsNewIdentity() throws {
        let original = makeDevotional()
        let exported = try track(manager.exportForSharing(original))

        let imported = try XCTUnwrap(manager.importFromFile(exported).first)

        XCTAssertNotEqual(imported.meta.id, original.meta.id)
        XCTAssertFalse(imported.meta.id.isEmpty)
    }

    /// Importing the same file twice should produce two separate devotionals rather
    /// than the second import overwriting the first.
    func testImportingSameFileTwiceProducesDistinctDevotionals() throws {
        let exported = try track(manager.exportForSharing(makeDevotional()))

        let first = try XCTUnwrap(manager.importFromFile(exported).first)
        let second = try XCTUnwrap(manager.importFromFile(exported).first)

        XCTAssertNotEqual(first.meta.id, second.meta.id)
        XCTAssertEqual(first.meta.title, second.meta.title)
    }

    func testImportStampsFreshTimestamps() throws {
        let stale = 1_000_000
        var original = makeDevotional()
        original.meta.created = stale
        original.meta.lastModified = stale

        let exported = try track(manager.exportForSharing(original))
        let imported = try XCTUnwrap(manager.importFromFile(exported).first)

        XCTAssertNotEqual(imported.meta.created, stale)
        XCTAssertNotEqual(imported.meta.lastModified, stale)
    }

    // MARK: - Preview

    func testPreviewReportsDevotionalWithoutImporting() throws {
        let original = makeDevotional()
        let exported = try track(manager.exportForSharing(original))

        let preview = try manager.previewFile(exported)

        XCTAssertEqual(preview.type, .devotional)
        XCTAssertEqual(preview.title, original.meta.title)
        XCTAssertEqual(preview.author, original.meta.author)
        XCTAssertFalse(preview.hasMedia)
        // Preview must not mutate identity - that only happens on import
        XCTAssertEqual(preview.devotional?.meta.id, original.meta.id)
    }

    func testPreviewRejectsUnrecognisedFile() throws {
        let url = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".lamp")
        )
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: url)

        XCTAssertThrowsError(try manager.previewFile(url))
    }

    // MARK: - Authored Markdown

    /// Everything a block tree cannot hold: a heading, an image, a table.
    private static let authoredBody = """
        ## A heading

        This is a test. Test. Another test.

        ![Caption](lamp-media://B7FAA5A6/32D89C7E.png)

        | One | Two |
        | --- | --- |
        | a | b |
        """

    /// The document the Mac writes when a writing is shared, built by hand so
    /// this test fails if that shape stops matching. A writing with no blocks
    /// of its own travels as a single paragraph holding its authored Markdown,
    /// because the portable format has nowhere else to put it — and it carries
    /// no `markdownContent` key to say so.
    private func writeMacDocument(
        body: String, title: String = "Cantata Narration"
    ) throws -> URL {
        let root: [String: Any] = [
            "meta": [
                "schemaVersion": "1.1",
                "id": "B7FAA5A6",
                "type": "devotional",
                "title": title,
                "tags": [],
                "keyScriptures": [],
                "created": 1_769_317_935,
                "lastModified": 1_788_132_249,
            ],
            "content": [["type": "paragraph", "content": ["text": body]]],
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lamp")
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: url)
        return track(url)
    }

    /// The body must land as authored text, character for character. Taken at
    /// face value the wrapper becomes a block tree instead, and the body reads
    /// back as one paragraph of literal text: the heading keeps its hashes and
    /// the image stays written out as link syntax rather than appearing.
    func testWritingSharedFromAMacKeepsItsAuthoredBody() throws {
        let url = try writeMacDocument(body: Self.authoredBody)

        let devotional = try XCTUnwrap(manager.importFromFile(url).first)

        XCTAssertEqual(devotional.markdownContent, Self.authoredBody)
        let entry = DevotionalEntry(from: devotional, moduleId: "devotionals")
        XCTAssertEqual(entry.contentJson, Self.authoredBody)
        XCTAssertEqual(try XCTUnwrap(entry.toDevotional()).markdownContent, Self.authoredBody)
    }

    /// The rest of the import is untouched: the body moves, the identity rules
    /// still apply.
    func testUnwrappingAnAuthoredBodyStillAssignsAFreshIdentity() throws {
        let url = try writeMacDocument(body: Self.authoredBody)

        let devotional = try XCTUnwrap(manager.importFromFile(url).first)

        XCTAssertNotEqual(devotional.meta.id, "B7FAA5A6")
        XCTAssertNotEqual(devotional.meta.lastModified, 1_788_132_249)
        XCTAssertEqual(devotional.meta.title, "Cantata Narration")
    }

    /// A collection shared as one file carries the same wrapper per entry.
    func testEveryEntryInASharedCollectionKeepsItsAuthoredBody() throws {
        let bodies = ["# First\n\nOne.", "# Second\n\nTwo.", "# Third\n\nThree."]
        let root: [String: Any] = [
            "id": "shared-collection",
            "name": "Lenten Readings",
            "type": "devotional",
            "entries": bodies.enumerated().map { index, body -> [String: Any] in
                [
                    "meta": [
                        "schemaVersion": "1.1", "type": "devotional",
                        "id": "entry-\(index)", "title": "Entry \(index)",
                        "created": 1_769_317_935, "lastModified": 1_788_132_249,
                    ],
                    "content": [["type": "paragraph", "content": ["text": body]]],
                ]
            },
        ]
        let url = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".lamp")
        )
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)

        let imported = try manager.importFromFile(url)

        XCTAssertEqual(imported.compactMap(\.markdownContent), bodies)
    }

    /// The unwrap must only catch a body that was never blocks to begin with.
    func testGenuineBlocksAreStillImportedAsBlocks() throws {
        var devotional = makeDevotional()
        devotional.content = .blocks([
            .heading("A heading", level: 2), .paragraph("Body."),
        ])
        let exported = try track(manager.exportForSharing(devotional))

        let imported = try XCTUnwrap(manager.importFromFile(exported).first)

        XCTAssertNil(imported.markdownContent)
        XCTAssertEqual(imported.content.allBlocks.count, 2)
    }

    // MARK: - Staging

    /// Staging exists so an import can outlive the security-scoped access of the
    /// incoming file, i.e. survive until the user picks a destination module.
    func testStagedCopyIsIndependentOfTheOriginal() throws {
        let exported = try track(manager.exportForSharing(makeDevotional()))
        let staged = try manager.stageForImport(exported)

        try FileManager.default.removeItem(at: exported)
        createdFiles.removeAll { $0 == exported }

        let imported = try XCTUnwrap(manager.importFromFile(staged).first)
        XCTAssertEqual(imported.meta.title, "Walking by Faith")

        manager.discardStagedImport(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
