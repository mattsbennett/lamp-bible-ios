//
//  SearchResult.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import Foundation

struct SearchResult: Identifiable {
    let id: Int
    let bookName: String
    let rawText: String  // Raw text with annotations for Strong's highlighting
    let snippet: String?  // FTS snippet with highlights
    private let _chapter: Int
    private let _verse: Int
    private let _text: String

    var chapter: Int { _chapter }
    var verseNumber: Int { _verse }
    var text: String { _text }

    var referenceText: String {
        "\(bookName) \(chapter):\(verseNumber)"
    }

    // GRDB TranslationVerse initializer
    init(verse: TranslationVerse, bookName: String, rawText: String? = nil) {
        self.id = verse.ref
        self.bookName = bookName
        self.rawText = rawText ?? verse.text
        self.snippet = nil
        self._chapter = verse.chapter
        self._verse = verse.verse
        self._text = verse.text
    }

    // GRDB TranslationSearchResult initializer (for FTS results and Strong's search)
    init(searchResult: TranslationSearchResult, bookName: String) {
        self.id = searchResult.ref
        self.bookName = bookName
        // Use rawText if available (Strong's search), otherwise snippet
        self.rawText = searchResult.rawText ?? searchResult.snippet
        self.snippet = searchResult.snippet
        self._chapter = searchResult.chapter
        self._verse = searchResult.verse
        // Strip FTS <mark> tags from text for display
        self._text = searchResult.snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
    }
}
