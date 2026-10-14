//
//  SearchQueryGrammarTests.swift
//  Lamp BibleTests
//
//  iOS searches seven kinds of content through five code paths. Three of them
//  used to escape their own FTS5 queries, wrapping the whole query in one
//  quoted phrase, so a verse search for two words asked for them adjacent
//  while commentary, notes, books and devotionals all matched them separately.
//  Searching "faith works" found the commentary on Romans but not the verse.
//
//  The grammar now lives once, in LampSearchQuery. These tests pin the
//  behaviour that depends on that, and guard against a path growing its own
//  escaping again — which would not fail to compile and would not look wrong.
//

import GRDB
import LampCore
import XCTest

final class SearchQueryGrammarTests: XCTestCase {

    // MARK: - The grammar, against a real FTS5 index

    /// Two words must match wherever they both appear, not only side by side.
    func testSeparateWordsAreNotSearchedAsAPhrase() throws {
        let index = try FTS5Index(texts: [
            "faith without works is dead",
            "faith works through love",
        ])
        let matches = try index.matches(for: "faith works")
        XCTAssertEqual(matches.count, 2, "Got: \(matches)")
    }

    /// Quoting is how the reader asks for them together.
    func testQuotingAsksForThePhrase() throws {
        let index = try FTS5Index(texts: [
            "faith without works is dead",
            "faith works through love",
        ])
        XCTAssertEqual(try index.matches(for: "\"faith works\""), ["faith works through love"])
    }

    /// A hyphen separates rather than closing the words up, so a hyphenated
    /// word finds the hyphenated text.
    func testAHyphenatedWordFindsTheHyphenatedText() throws {
        let index = try FTS5Index(texts: ["temperance, self-control, and patience"])
        XCTAssertEqual(try index.matches(for: "self-control").count, 1)
    }

    /// FTS5 reads these as operators, and a malformed MATCH argument throws
    /// rather than returning nothing — which, behind a `try?`, is a search that
    /// silently finds no results whatever is typed.
    func testPunctuationNeverBreaksTheQuery() throws {
        let index = try FTS5Index(texts: ["grace and peace to you"])
        for typed in ["grace*", "grace^", "grace:", "(grace)", "gra\"ce",
                      "NOT grace", "grace OR peace", "grace NEAR peace"] {
            XCTAssertNoThrow(
                try index.matches(for: typed),
                "\(typed) produced \(LampSearchQuery(typed).fts5Query)"
            )
        }
    }

    /// Nothing searchable means an empty query, which is how each caller knows
    /// to skip the search rather than ask SQLite for nothing.
    func testAQueryWithNoWordsIsEmpty() {
        for typed in ["", "   ", "***", "()"] {
            XCTAssertTrue(
                LampSearchQuery(typed).fts5Query.isEmpty,
                "\(typed.debugDescription) produced a query"
            )
        }
    }

    // MARK: - No path may escape its own

    /// The three local escapers all had this chain in them. Checking the source
    /// is blunt, but a reintroduced escaper compiles cleanly and the only
    /// symptom is search quietly behaving differently in one place.
    func testNoSearchPathEscapesFTSOperatorsItself() throws {
        for (name, source) in try Self.dataSources() {
            XCTAssertFalse(
                source.contains(#"replacingOccurrences(of: "^""#),
                """
                \(name) strips FTS5 operator characters itself. Build the query \
                with LampSearchQuery so every kind of content answers the same \
                grammar.
                """
            )
        }
    }

    /// Every table queried with `MATCH` has to be handed a query built from the
    /// shared grammar, so no searcher can invent its own.
    func testEveryMatchQueryComesFromTheSharedGrammar() throws {
        var checked = 0
        for (name, source) in try Self.dataSources() where source.contains("MATCH ?") {
            checked += 1
            XCTAssertTrue(
                source.contains("LampSearchQuery("),
                "\(name) runs an FTS5 MATCH without building the query from LampSearchQuery"
            )
        }
        XCTAssertGreaterThan(checked, 2, "Only \(checked) files matched — this guard is not looking at the search code")
    }

    // MARK: - Helpers

    /// Every Swift file under `Lamp Bible/Data`, where the searchers live.
    private static func dataSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lamp Bible/Data")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(sources.count, 10, "Did not find the Data sources")
        return sources
    }
}

/// A real FTS5 table, so the queries are judged by SQLite rather than by how
/// their strings look.
private struct FTS5Index {
    private let queue: DatabaseQueue

    init(texts: [String]) throws {
        queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE v USING fts5(text)")
            for text in texts {
                try db.execute(sql: "INSERT INTO v(text) VALUES (?)", arguments: [text])
            }
        }
    }

    /// Takes the query as the reader typed it, and applies the shared grammar.
    func matches(for typed: String) throws -> [String] {
        let query = LampSearchQuery(typed).fts5Query
        guard !query.isEmpty else { return [] }
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM v WHERE v MATCH ?", arguments: [query])
        }
    }
}
