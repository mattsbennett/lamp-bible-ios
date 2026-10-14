import XCTest
@testable import Lamp_Bible

/// Verifies the separate iOS notes and translation adapters using their real
/// databases and the public search path. Grammar edge cases belong in core.
final class SearchQueryGrammarTests: XCTestCase {
    private let notesID = "search-notes-\(UUID().uuidString)"
    private let translationID = "search-translation-\(UUID().uuidString)"

    override func setUpWithError() throws {
        let database = ModuleDatabase.shared
        try database.saveModule(Module(id: notesID, type: .notes,
            name: "Search fixture", filePath: "fixture.lamp", isEditable: true))
        try database.saveTranslation(TranslationModule(id: translationID,
            name: "Search fixture", abbreviation: "TEST", language: "en"))
        for (index, text) in [
            "faith without works is dead", "faith works through love", "self-control and patience",
        ].enumerated() {
            let reference = 43_001_001 + index
            try database.saveNoteEntry(NoteEntry(id: "\(notesID):\(index)", moduleId: notesID,
                verseId: reference, title: "Fixture", content: text))
            try database.saveTranslationVerse(TranslationVerse(translationId: translationID,
                ref: reference, book: 43, chapter: 1, verse: index + 1, text: text))
        }
    }

    override func tearDownWithError() throws {
        let database = ModuleDatabase.shared
        try database.deleteAllEntriesForModule(moduleId: notesID)
        try database.deleteModule(id: notesID)
        try database.deleteTranslation(id: translationID)
    }

    private func search(_ query: String) throws -> [ModuleSearchResult] {
        var filter = ModuleSearchFilter()
        filter.types = [.notes, .translation]
        filter.moduleIds = [notesID, translationID]
        filter.translationIds = [translationID]
        filter.includeBundledDictionaries = false
        return try ModuleSearch.shared.search(query: query, filter: filter)
    }

    func testNotesAndVersesAgreeOnWordsAndQuotedPhrases() throws {
        for type in [ModuleType.notes, .translation] {
            XCTAssertEqual(Set(try search("faith works").filter { $0.moduleType == type }.compactMap(\.verseId)),
                [43_001_001, 43_001_002])
            XCTAssertEqual(try search("\"faith works\"").filter { $0.moduleType == type }.compactMap(\.verseId),
                [43_001_002])
        }
    }

    func testHyphenatedSearchReachesBothContentAdapters() throws {
        let results = try search("self-control")
        XCTAssertEqual(Set(results.map(\.moduleType)), [.notes, .translation])
        XCTAssertEqual(results.compactMap(\.verseId), [43_001_003, 43_001_003])
    }

    func testTypedOperatorCharactersDoNotSilentlyLoseResults() throws {
        for typed in ["faith*", "faith^", "faith:", "(faith)"] {
            XCTAssertEqual(try search(typed).count, 4, typed)
        }
        XCTAssertTrue(try search("***").isEmpty)
    }
}
