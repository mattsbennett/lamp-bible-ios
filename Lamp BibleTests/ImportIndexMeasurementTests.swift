//
//  ImportIndexMeasurementTests.swift
//  Lamp BibleTests
//
//  Item 3d of lamp-bible-core/Documentation/ScalabilityPlan.md: whether a
//  bulk import should drop its search index and rebuild it afterwards,
//  instead of paying a trigger per row. The plan left it open "only if a
//  measurement says import time matters", and this is that measurement.
//
//  It runs with the suite, at a size small enough to cost nothing and large
//  enough to show a ratio, and it asserts that the index ends up saying the
//  same thing whichever way it was filled. Nothing asserts a timing. The
//  SCALE line goes to a file as well as to the console, because a
//  simulator test's output does not reach xcodebuild.
//

import GRDB
import XCTest
@testable import Lamp_Bible

final class ImportIndexMeasurementTests: XCTestCase {
    private var url: URL!
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-index-\(UUID().uuidString).sqlite")
        queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
    }

    override func tearDownWithError() throws {
        guard queue != nil else { return }
        try queue.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// The verses table and its external-content index, as the migrations
    /// make them — the same shape `ExternalContentSearchIndex.all` names.
    private func makeSchema() throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_verses (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    translation_id TEXT NOT NULL,
                    reference INTEGER NOT NULL,
                    text TEXT NOT NULL);
                CREATE VIRTUAL TABLE translation_verses_fts USING fts5(
                    text, content='translation_verses', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2');
                """)
            try Self.index.installTriggers(in: db)
        }
    }

    private static let index = ExternalContentSearchIndex(
        name: "translation_verses_fts", content: "translation_verses", rowid: "id",
        columns: ["text"], tokenize: "unicode61 remove_diacritics 2"
    )

    private func verses(_ count: Int) -> [(Int, String)] {
        // A verse of about the length of a real one, varied enough that the
        // tokeniser has real work: the same sentence everywhere would index
        // one set of terms and flatter the result.
        let words = [
            "lamp", "unto", "feet", "light", "path", "shepherd", "pastures", "waters",
            "restoreth", "soul", "paths", "righteousness", "valley", "shadow", "death",
            "comfort", "table", "enemies", "anointest", "oil", "cup", "runneth", "mercy",
        ]
        return (0..<count).map { index in
            var text = ""
            for step in 0..<18 { text += words[(index &* 7 &+ step &* 3) % words.count] + " " }
            return (index, text.trimmingCharacters(in: .whitespaces))
        }
    }

    private func insert(_ rows: [(Int, String)]) throws {
        try queue.write { db in
            for (reference, text) in rows {
                try db.execute(
                    sql: "INSERT INTO translation_verses (translation_id, reference, text) VALUES (?, ?, ?)",
                    arguments: ["t1", reference, text]
                )
            }
        }
    }

    private func timed(_ body: () throws -> Void) rethrows -> Double {
        let started = ContinuousClock.now
        try body()
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    func testMeasuresWhatTheSearchIndexCostsABulkImport() throws {
        // Not gated behind an environment variable, because a simulator test
        // does not inherit one — neither `LAMP_SCALE=1 xcodebuild` nor
        // `TEST_RUNNER_LAMP_SCALE=1` reaches the test process here. So it
        // runs always, at a size that measures a ratio without costing the
        // suite anything: it asserts the index says the same thing either
        // way, which is worth a test on its own.
        let count = 4_000
        let rows = verses(count)

        // As it is now: a trigger per row, inserting into the index as the
        // import goes.
        try makeSchema()
        let withTriggers = try timed { try insert(rows) }
        let indexedRows = try queue.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM translation_verses_fts") ?? -1
        }
        let bytesWithTriggers = try fileBytes()

        // What 3d proposes: no triggers while the rows go in, then the index
        // made in one pass and the triggers put back.
        try queue.write { db in
            try db.execute(sql: "DELETE FROM translation_verses")
            try db.execute(sql: "INSERT INTO translation_verses_fts(translation_verses_fts) VALUES ('rebuild')")
            for suffix in ["insert", "update", "delete"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS translation_verses_fts_\(suffix)")
            }
        }
        let withoutTriggers = try timed { try insert(rows) }
        let rebuilt = try timed {
            try queue.write { db in
                try Self.index.installTriggers(in: db)
                try db.execute(sql: "INSERT INTO translation_verses_fts(translation_verses_fts) VALUES ('rebuild')")
            }
        }
        let rebuiltRows = try queue.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM translation_verses_fts") ?? -1
        }

        // The index has to end up saying the same thing either way.
        XCTAssertEqual(indexedRows, count)
        XCTAssertEqual(rebuiltRows, count)
        let hits = try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM translation_verses_fts WHERE translation_verses_fts MATCH ?",
                arguments: ["shepherd"]
            ) ?? -1
        }
        XCTAssertGreaterThan(hits, 0)

        // To standard error, which `xcodebuild` shows: it keeps a test's
        // standard output in the result bundle instead.
        report("""
            SCALE verses=\(count) \
            insertWithTriggers=\(String(format: "%.0f", withTriggers))ms \
            insertWithoutTriggers=\(String(format: "%.0f", withoutTriggers))ms \
            rebuildAfterwards=\(String(format: "%.0f", rebuilt))ms \
            dropAndRebuildTotal=\(String(format: "%.0f", withoutTriggers + rebuilt))ms \
            bytes=\(bytesWithTriggers) matches=\(hits)
            """)
    }

    /// Written to a file as well as printed, because neither a test's
    /// standard output nor its standard error reaches `xcodebuild`'s console
    /// from a simulator — they go into the result bundle. The file is in the
    /// test host's temporary directory, which on the host is under
    /// `~/Library/Developer/CoreSimulator/Devices`.
    private func report(_ line: String) {
        print(line)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-import-index-scale.txt")
        try? Data((line + "\n").utf8).write(to: file)
    }

    /// Item 3b: the writing list draws the meta and an excerpt, and used to
    /// parse every writing's body twice over to get there.
    ///
    /// What this holds is the pair of claims the change rests on: a row has
    /// what it draws, and a reader opening one gets the whole writing.
    func testTheListCarriesWhatARowDrawsAndNoMore() throws {
        let database = ModuleDatabase.shared
        let moduleID = "list-\(UUID().uuidString.prefix(6))"
        try database.saveModule(Module(
            id: moduleID, type: .devotional, name: "Writings", filePath: "writings.lamp"
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }

        // A Markdown writing, which is the ordinary kind, with the fields a
        // list never draws.
        let id = UUID().uuidString.lowercased()
        var meta = DevotionalMeta(id: id, title: "Living Hope", subtitle: "A study")
        meta.tags = ["hope", "peter"]
        let whole = Devotional(
            meta: meta,
            content: .blocks([]),
            footnotes: [DevotionalFootnote(id: "f1", content: .plain("A note"))],
            markdownContent: "# Living Hope\n\nBlessed be the God and Father of our Lord."
        )
        try database.saveDevotionalEntry(DevotionalEntry(from: whole, moduleId: moduleID))

        let listed = try XCTUnwrap(
            try DevotionalStorage.shared.getDevotionalsForList(moduleId: moduleID).first
        )
        // What a row draws.
        XCTAssertEqual(listed.meta.id, id)
        XCTAssertEqual(listed.meta.title, "Living Hope")
        XCTAssertEqual(listed.meta.subtitle, "A study")
        XCTAssertEqual(listed.meta.tags, ["hope", "peter"])
        XCTAssertEqual(
            listed.markdownContent,
            "# Living Hope\n\nBlessed be the God and Father of our Lord.",
            "the row needs the body's text to quote an excerpt from it"
        )
        // And no more: these are the decoders the list no longer runs.
        XCTAssertNil(listed.footnotes)
        XCTAssertNil(listed.media)
        XCTAssertNil(listed.summary)

        // A reader opening it gets the whole writing.
        let opened = try XCTUnwrap(try DevotionalStorage.shared.getDevotional(id: id))
        XCTAssertEqual(opened.footnotes?.map(\.plainText), ["A note"])
        XCTAssertEqual(opened.meta.title, "Living Hope")
    }

    /// A writing kept as blocks rather than Markdown still has something for
    /// a row to quote: those are sniffed and decoded as before, because a
    /// block schema has to be converted before it can be excerpted.
    func testABlockSchemaWritingStillHasTextForItsRow() throws {
        let database = ModuleDatabase.shared
        let moduleID = "blocks-\(UUID().uuidString.prefix(6))"
        try database.saveModule(Module(
            id: moduleID, type: .devotional, name: "Writings", filePath: "writings.lamp"
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }
        let id = UUID().uuidString.lowercased()
        try database.saveDevotionalEntry(DevotionalEntry(
            from: Devotional(
                meta: DevotionalMeta(id: id, title: "As Blocks"),
                content: .blocks([.paragraph("The opening of the writing.")])
            ),
            moduleId: moduleID
        ))

        let listed = try XCTUnwrap(
            try DevotionalStorage.shared.getDevotionalsForList(moduleId: moduleID).first
        )
        XCTAssertEqual(listed.meta.title, "As Blocks")
        let quotable = listed.markdownContent
            ?? MarkdownDevotionalConverter.contentToMarkdown(listed)
        XCTAssertTrue(
            quotable.contains("The opening of the writing."),
            "a block-schema row has nothing to quote: \(quotable)"
        )
        // And it is prose, not the stored JSON. Handing the raw column
        // straight through would also "contain" the words, while a row drew
        // `{"blocks":[{"type":"paragraph"...` at the reader.
        XCTAssertFalse(
            quotable.contains("\"type\"") || quotable.hasPrefix("{") || quotable.hasPrefix("["),
            "a row would quote the stored JSON: \(quotable.prefix(120))"
        )
    }

    private func fileBytes() throws -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal"] {
            let values = try? URL(fileURLWithPath: url.path + suffix)
                .resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
