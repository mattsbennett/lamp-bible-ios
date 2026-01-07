//
//  SearchResult.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import Foundation

struct SearchResult: Identifiable {
    let id: Int
    let verse: Verse
    let bookName: String

    var chapter: Int { verse.c }
    var verseNumber: Int { verse.v }
    var text: String {
        verse.cleanText.isEmpty ? stripStrongsAnnotations(verse.t) : verse.cleanText
    }

    var referenceText: String {
        "\(bookName) \(chapter):\(verseNumber)"
    }

    init(verse: Verse, bookName: String) {
        self.id = verse.id
        self.verse = verse
        self.bookName = bookName
    }
}
