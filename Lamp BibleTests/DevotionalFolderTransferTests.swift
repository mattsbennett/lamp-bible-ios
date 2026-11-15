//
//  DevotionalFolderTransferTests.swift
//  Lamp BibleTests
//
//  The folder way in and out: writings dropped into an Import folder as
//  Markdown, and written back out to an Export folder. What the Import folder
//  holds is planned by core's writing import and offered for review; nothing
//  in it is written or deleted, and importing it again updates what it made.
//

import GRDB
import LampCore
import XCTest
@testable import Lamp_Bible

final class DevotionalFolderTransferTests: XCTestCase {
    private var manager: DevotionalImportExportManager!
    private var folder: URL!
    private var moduleId: String!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        manager = DevotionalImportExportManager.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("devotional-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "folder-transfer-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        moduleId = "folder-transfer-\(UUID().uuidString)"
        try ModuleDatabase.shared.saveModule(Module(
            id: moduleId,
            type: .devotional,
            name: "Folder transfers",
            filePath: "\(moduleId!).lamp",
            isEditable: true
        ))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleId)
        try? ModuleDatabase.shared.deleteModule(id: moduleId)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// What the folder offers now.
    private func offered() async -> PendingWritingImport? {
        await WritingDropFolder.pendingImport(in: folder, defaults: defaults)
    }

    /// What the folder offers now, which a test expects there to be.
    private func offeredImport(file: StaticString = #filePath, line: UInt = #line) async throws -> PendingWritingImport {
        let pending = await offered()
        return try XCTUnwrap(pending, "The folder offered nothing", file: file, line: line)
    }

    /// Imports what the sheet ticks to begin with.
    @discardableResult
    private func importTicked(_ pending: PendingWritingImport) async throws -> LampWritingImportResult {
        try await WritingImporter.apply(
            pending, selecting: Set(pending.plan.items.filter(\.importsByDefault).map(\.id)), into: moduleId
        )
    }

    // MARK: - Helpers

    private func write(_ contents: String, named name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func storedEntries() throws -> [DevotionalEntry] {
        try ModuleDatabase.shared.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    private func makeDevotional(title: String = "Walking by Faith") -> Devotional {
        Devotional(
            meta: DevotionalMeta(
                id: "folder-\(title.replacingOccurrences(of: " ", with: "-"))",
                title: title,
                author: "John Smith",
                date: "2026-01-18",
                tags: ["faith"]
            ),
            content: .blocks([.paragraph("The journey of faith is not always easy.")])
        )
    }

    // MARK: - Import

    func testAMarkdownFileInTheFolderIsOfferedAndBecomesAWriting() async throws {
        let url = try write("""
            ---
            title: "Dropped In"
            author: "John Smith"
            tags: ["hope"]
            ---

            Hope begins here.
            """, named: "dropped.md")

        let pending = try await offeredImport()
        XCTAssertEqual(pending.plan.items.map(\.action), [.create])
        XCTAssertEqual(pending.plan.items.map(\.title), ["Dropped In"])
        XCTAssertTrue(try storedEntries().isEmpty, "Nothing is written until the person imports")

        let result = try await importTicked(pending)

        XCTAssertEqual(result.imported.count, 1)
        let stored = try storedEntries()
        XCTAssertEqual(stored.map(\.title), ["Dropped In"])
        XCTAssertEqual(stored.first?.author, "John Smith")
        XCTAssertEqual(stored.first?.tags, "hope")
        XCTAssertEqual(stored.first?.id, pending.plan.items.first?.writingID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The person's file is left where it is")
    }

    /// The point of a path's id: the same file imported again, changed, is
    /// the same writing changed, not a second one.
    func testAFileChangedAndImportedAgainUpdatesItsWriting() async throws {
        let url = try write("---\ntitle: \"Once\"\nlastModified: 2026-01-01\n---\n\nFirst draft.", named: "once.md")
        try await importTicked(try await offeredImport())

        try "---\ntitle: \"Once\"\nlastModified: 2026-02-01\n---\n\nSecond draft.".write(to: url, atomically: true, encoding: .utf8)
        let pending = try await offeredImport()
        XCTAssertEqual(pending.plan.items.map(\.action), [.update])
        XCTAssertEqual(pending.plan.items.first?.changes, ["text"])
        try await importTicked(pending)

        let stored = try storedEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].contentJson.contains("Second draft."))
    }

    /// A folder already seen as it is isn't put in front of the person again,
    /// imported from or cancelled; one with nothing new is never shown.
    func testAFolderAlreadySeenIsNotOfferedAgain() async throws {
        _ = try write("---\ntitle: \"Seen\"\n---\n\nBody.", named: "seen.md")
        let pending = try await offeredImport()
        WritingDropFolder.reviewed(pending, defaults: defaults)
        let again = await offered()
        XCTAssertNil(again)

        // Imported, then looked at afresh: everything is unchanged.
        try await importTicked(pending)
        defaults.removeObject(forKey: WritingDropFolder.reviewedKey)
        let afresh = await offered()
        XCTAssertNil(afresh)
    }

    /// A file that cannot be imported is shown, with why, and stops nothing
    /// beside it.
    func testAFileThatCannotBeImportedIsShownAndStopsNothing() async throws {
        let broken = try write("---\nid: bad/id\ntitle: \"Broken\"\n---\n\nBody.", named: "broken.md")
        _ = try write("---\ntitle: \"Good\"\n---\n\nBody.", named: "good.md")

        let pending = try await offeredImport()
        let byTitle = Dictionary(uniqueKeysWithValues: pending.plan.items.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Good"]?.action, .create)
        XCTAssertEqual(byTitle["Broken"]?.action, .rejected)
        XCTAssertFalse(byTitle["Broken"]?.errors.isEmpty ?? true)
        try await importTicked(pending)

        XCTAssertEqual(try storedEntries().map(\.title), ["Good"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
    }

    /// A writing kept as blocks, headings among them, written out and dropped
    /// back unchanged, still reads as unchanged, and keeps its blocks.
    func testABlockWritingComesBackUnchanged() async throws {
        let devotional = Devotional(
            meta: DevotionalMeta(id: "folder-blocks", title: "Grace", lastModified: 1_700_000_000),
            content: .blocks([.heading("Grace Abounds", level: 2), .paragraph("Where sin increased.")])
        )
        try ModuleDatabase.shared.saveDevotionalEntry(DevotionalEntry(from: devotional, moduleId: moduleId))
        _ = try manager.exportDevotional(devotional, moduleId: moduleId, to: folder)

        let files = try LampWritingImport.files(at: folder)
        let store = try PhoneWritingImportStore(newWritingModuleID: moduleId)
        let plan = try await LampWritingImport.plan(files, in: store, comparingWithLibrary: true)

        XCTAssertEqual(plan.items.map(\.action), [.unchanged], "\(plan.items.map(\.changes))")
    }

    /// A change core's model can't see — a link added to the summary by
    /// sync, its text the same — still stops an import planned before it.
    func testAChangeOnlyTheStoredRowShowsIsKept() async throws {
        let url = try write("---\ntitle: \"Draft\"\nsummary: \"In short.\"\nlastModified: 2026-01-01\n---\n\nFirst.", named: "draft.md")
        try await importTicked(try await offeredImport())
        try "---\ntitle: \"Draft\"\nsummary: \"In short.\"\nlastModified: 2026-02-01\n---\n\nFrom the file.".write(to: url, atomically: true, encoding: .utf8)
        let pending = try await offeredImport()
        XCTAssertEqual(pending.plan.items.map(\.action), [.update])

        var edited = try XCTUnwrap(try storedEntries().first)
        edited.summaryJson = #"{"text":"In short.","annotations":[{"type":"link","start":3,"end":8,"data":{"url":"https://example.org"}}]}"#
        try ModuleDatabase.shared.saveDevotionalEntry(edited)
        let result = try await importTicked(pending)

        XCTAssertEqual(result.refused.map(\.title), ["Draft"])
        XCTAssertEqual(try storedEntries().first?.summaryJson, edited.summaryJson)
    }

    /// A subscription's writing is someone else's: a file carrying its id
    /// never writes over it.
    func testASubscriptionsWritingIsNeverWrittenOver() async throws {
        var entry = DevotionalEntry(from: makeDevotional(title: "Their Words"), moduleId: moduleId)
        entry.subscriptionId = "someone-else"
        entry.isReadOnly = 1
        try ModuleDatabase.shared.saveDevotionalEntry(entry)
        defer { try? ModuleDatabase.shared.deleteDevotionalEntry(id: entry.id) }
        _ = try write("---\nid: \(entry.id)\ntitle: \"Mine Now\"\n---\n\nOverwritten.", named: "theirs.md")

        // Planned as Writing's import would: the drop folder doesn't put a
        // sheet up for a file there's nothing to choose about.
        let offered = await offered()
        XCTAssertNil(offered)
        let pending = try await WritingImporter.plan([folder])
        XCTAssertEqual(pending.plan.items.map(\.action), [.rejected])
        XCTAssertTrue(pending.plan.items.first?.errors.first?.contains("subscription") ?? false)
        try await WritingImporter.apply(pending, selecting: Set(pending.plan.items.map(\.id)), into: moduleId)

        let stored = try XCTUnwrap(try ModuleDatabase.shared.getDevotionalEntry(id: entry.id))
        XCTAssertEqual(stored.title, "Their Words")
        XCTAssertEqual(stored.subscriptionId, "someone-else")
    }

    /// An edit made after the plan, by sync or in the editor, is kept: the
    /// import refuses to write over a copy it didn't compare with.
    func testAnEditMadeWhileTheSheetIsOpenIsKept() async throws {
        let url = try write("---\ntitle: \"Draft\"\nlastModified: 2026-01-01\n---\n\nFirst.", named: "draft.md")
        try await importTicked(try await offeredImport())
        try "---\ntitle: \"Draft\"\nlastModified: 2026-02-01\n---\n\nFrom the file.".write(to: url, atomically: true, encoding: .utf8)
        let pending = try await offeredImport()
        XCTAssertEqual(pending.plan.items.map(\.action), [.update])

        var edited = try XCTUnwrap(try storedEntries().first)
        edited.contentJson = "Edited meanwhile."
        try ModuleDatabase.shared.saveDevotionalEntry(edited)
        let result = try await importTicked(pending)

        XCTAssertEqual(result.imported.count, 0)
        XCTAssertEqual(result.refused.map(\.title), ["Draft"])
        XCTAssertEqual(try storedEntries().first?.contentJson, "Edited meanwhile.")
    }

    /// A footnote in the file stays a footnote: core keeps it in the body,
    /// which the phone reads back as the Markdown it was.
    func testAFootnoteInTheFileStaysAFootnote() async throws {
        _ = try write("---\ntitle: \"Noted\"\n---\n\n## Grace\n\nGrace abounds.[^1]\n\n[^1]: Romans 5:20.", named: "noted.md")

        try await importTicked(try await offeredImport())

        let devotional = try XCTUnwrap(try storedEntries().first?.toDevotional())
        let markdown = MarkdownDevotionalConverter.contentToMarkdown(devotional)
        XCTAssertTrue(markdown.contains("## Grace"), markdown)
        XCTAssertTrue(markdown.contains("[^1]: Romans 5:20."), markdown)
    }

    /// The Mac's footnotes, which core stores apart from the body as one
    /// string of definitions, read as footnotes rather than being dropped.
    func testTheMacsStoredFootnotesAreRead() throws {
        let stored = try XCTUnwrap(LampPersonalFile.jsonFragment(
            "[^b]: Romans 5:20.\n    Where sin increased.\n[^a]: Ephesians 2:8."
        ))
        let footnotes = try XCTUnwrap(Devotional.footnotes(fromStoredJSON: stored))
        XCTAssertEqual(footnotes.map(\.id), ["b", "a"])
        XCTAssertEqual(footnotes.first?.content, .plain("Romans 5:20.\nWhere sin increased."))
    }

    /// A picture whose file iCloud hasn't brought down yet doesn't settle the
    /// folder as seen: once it's here, the writing is offered.
    func testAFolderStillDownloadingIsNotSettled() async throws {
        _ = try write("---\ntitle: \"Pictured\"\n---\n\n![](media/photo.png)", named: "pictured.md")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("media/.photo.png.icloud"))

        let early = await offered()
        XCTAssertNil(defaults.string(forKey: WritingDropFolder.reviewedKey), "Not settled while a file is on its way")
        _ = early
    }

    /// Anything that is not Markdown is left alone — the folder is shared with
    /// whatever else the person keeps there.
    func testFilesThatAreNotMarkdownAreLeftAlone() async throws {
        let other = try write("{}", named: "notes.json")

        let pending = await offered()

        XCTAssertNil(pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testAnEmptyFolderOffersNothing() async throws {
        let pending = await offered()
        XCTAssertNil(pending)
    }

    /// A folder that is not there yet is made, so the person has somewhere to
    /// drop files next time.
    func testAMissingFolderIsCreatedRatherThanFailing() async throws {
        let missing = folder.appendingPathComponent("Import", isDirectory: true)

        let pending = await WritingDropFolder.pendingImport(in: missing, defaults: defaults)

        XCTAssertNil(pending)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: missing.path, isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Export

    func testAWritingIsWrittenOutAsMarkdownNamedAfterIt() throws {
        let url = try manager.exportDevotional(
            makeDevotional(), moduleId: moduleId, to: folder
        )

        XCTAssertEqual(url.lastPathComponent, "Walking by Faith.md")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("title: \"Walking by Faith\""))
        XCTAssertTrue(contents.contains("The journey of faith is not always easy."))
    }

    func testEveryWritingIsWrittenOutAsItsOwnFile() throws {
        let devotionals = ["First Light", "Second Wind", "Third Day"].map {
            makeDevotional(title: $0)
        }

        let urls = try manager.exportAllDevotionals(
            devotionals, moduleId: moduleId, to: folder
        )

        XCTAssertEqual(
            urls.map(\.lastPathComponent).sorted(),
            ["First Light.md", "Second Wind.md", "Third Day.md"]
        )
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The combined document is what someone reads outside the app: every
    /// writing in order, separated by rules.
    func testTheCombinedDocumentHoldsEveryWritingInOrder() throws {
        let devotionals = ["First Light", "Second Wind"].map { makeDevotional(title: $0) }

        let url = try manager.exportAllToSingleFile(devotionals, to: folder)

        XCTAssertEqual(url.lastPathComponent, "All_Writing.md")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# My Writing"))
        let first = try XCTUnwrap(contents.range(of: "First Light"))
        let second = try XCTUnwrap(contents.range(of: "Second Wind"))
        XCTAssertTrue(first.lowerBound < second.lowerBound)
        XCTAssertTrue(contents.hasSuffix("---\n"))
    }

    func testWritingOutNothingIsAnErrorRatherThanAnEmptyFile() throws {
        XCTAssertThrowsError(try manager.exportAllToSingleFile([], to: folder))
        XCTAssertThrowsError(
            try manager.exportAllDevotionals([], moduleId: moduleId, to: folder)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("All_Writing.md").path
        ))
    }

    /// A title with a colon or a slash in it still names one file.
    func testATitleWithPathCharactersStillNamesOneFile() throws {
        let url = try manager.exportDevotional(
            makeDevotional(title: "Psalm 23: The Lord/My Shepherd"),
            moduleId: moduleId, to: folder
        )

        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Out and back

    /// The whole point of the folder: a writing taken out of the app and put
    /// back in is the same writing.
    func testAWritingWrittenOutAndDroppedBackInIsTheSame() async throws {
        _ = try manager.exportDevotional(makeDevotional(), moduleId: moduleId, to: folder)

        try await importTicked(try await offeredImport())

        let stored = try XCTUnwrap(try storedEntries().first)
        XCTAssertEqual(stored.id, "folder-Walking-by-Faith")
        XCTAssertEqual(stored.title, "Walking by Faith")
        XCTAssertEqual(stored.author, "John Smith")
        XCTAssertEqual(stored.date, "2026-01-18")
        XCTAssertEqual(stored.tags, "faith")
        XCTAssertTrue(stored.contentJson.contains("The journey of faith is not always easy."))
    }

    /// A writing still in Lamp, written out and dropped back unchanged, reads
    /// as unchanged: the phone's writing compares as the Mac reads it.
    func testAWritingStillInLampComesBackUnchanged() async throws {
        let devotional = makeDevotional()
        try ModuleDatabase.shared.saveDevotionalEntry(DevotionalEntry(from: devotional, moduleId: moduleId))
        _ = try manager.exportDevotional(devotional, moduleId: moduleId, to: folder)

        let files = try LampWritingImport.files(at: folder)
        let store = try PhoneWritingImportStore(newWritingModuleID: moduleId)
        let plan = try await LampWritingImport.plan(files, in: store, comparingWithLibrary: true)

        XCTAssertEqual(plan.items.map(\.action), [.unchanged], "\(plan.items.map(\.changes))")
    }
}
