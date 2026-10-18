//
//  DevotionalFolderTransferTests.swift
//  Lamp BibleTests
//
//  The folder way in and out: writings dropped into an Import folder as
//  Markdown, and written back out to an Export folder. It is the one sharing
//  route with no confirmation step — whatever is in the folder is taken at its
//  word and the file is deleted — and it had no coverage at all.
//

import GRDB
import XCTest
@testable import Lamp_Bible

final class DevotionalFolderTransferTests: XCTestCase {
    private var manager: DevotionalImportExportManager!
    private var folder: URL!
    private var moduleId: String!

    override func setUpWithError() throws {
        manager = DevotionalImportExportManager.shared
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("devotional-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    func testAMarkdownFileInTheFolderBecomesAWriting() async throws {
        _ = try write("""
            ---
            title: "Dropped In"
            author: "John Smith"
            tags: ["hope"]
            ---

            Hope begins here.
            """, named: "dropped.md")

        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertEqual(results.map(\.devotionalTitle), ["Dropped In"])
        XCTAssertEqual(results.map(\.success), [true])
        let stored = try storedEntries()
        XCTAssertEqual(stored.map(\.title), ["Dropped In"])
        XCTAssertEqual(stored.first?.author, "John Smith")
    }

    /// A file that was imported is removed, because leaving it would import it
    /// again on the next pass and leave two copies.
    func testAnImportedFileIsTakenOutOfTheFolder() async throws {
        let url = try write("---\ntitle: \"Once\"\n---\n\nBody.", named: "once.md")

        _ = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A file that could not be read is reported and left where it is, rather
    /// than quietly deleted.
    func testAFileThatCannotBeReadIsKeptAndReported() async throws {
        // Frontmatter that opens and never closes: the parser gives up.
        let url = try write("---\ntitle: \"Broken\"\n\nNo closing marker.", named: "broken.md")

        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertEqual(results.map(\.success), [false])
        XCTAssertEqual(results.map(\.fileName), ["broken.md"])
        XCTAssertNotNil(results.first?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try storedEntries().count, 0)
    }

    /// One unreadable file must not stop the ones beside it.
    func testOneBadFileDoesNotStopTheRest() async throws {
        _ = try write("---\ntitle: \"Broken\"\n\nNo closing marker.", named: "broken.md")
        _ = try write("---\ntitle: \"Good\"\n---\n\nBody.", named: "good.md")

        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try storedEntries().map(\.title), ["Good"])
    }

    /// Anything that is not Markdown is left alone — the folder is shared with
    /// whatever else the person keeps there.
    func testFilesThatAreNotMarkdownAreLeftAlone() async throws {
        let other = try write("{}", named: "notes.json")

        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testAnEmptyFolderImportsNothing() async throws {
        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try storedEntries().count, 0)
    }

    /// A folder that is not there yet is made, so the person has somewhere to
    /// drop files next time.
    func testAMissingFolderIsCreatedRatherThanFailing() async throws {
        let missing = folder.appendingPathComponent("Import", isDirectory: true)

        let results = try await manager.processImports(in: missing, moduleId: moduleId)

        XCTAssertTrue(results.isEmpty)
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

        XCTAssertEqual(url.lastPathComponent, "All_Devotionals.md")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# My Devotionals"))
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
            atPath: folder.appendingPathComponent("All_Devotionals.md").path
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

        let results = try await manager.processImports(in: folder, moduleId: moduleId)

        XCTAssertEqual(results.map(\.success), [true])
        let stored = try XCTUnwrap(try storedEntries().first)
        XCTAssertEqual(stored.title, "Walking by Faith")
        XCTAssertEqual(stored.author, "John Smith")
        XCTAssertEqual(stored.date, "2026-01-18")
        XCTAssertEqual(stored.tags, "faith")
        XCTAssertTrue(stored.contentJson.contains("The journey of faith is not always easy."))
    }
}
