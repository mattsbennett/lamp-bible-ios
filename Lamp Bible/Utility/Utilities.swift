//
//  Utilities.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import Foundation
import GRDB

func countWords(source: String) -> Int {
    let components = source.components(separatedBy: .whitespacesAndNewlines)
    let wordCount = components.filter { !$0.isEmpty }.count

    return wordCount
}

func splitVerseId(_ number: Int) -> (Int, Int, Int) {
    let verse = number % 1000
    let chapter = (number / 1000) % 1000
    let book = number / 1000000

    return (verse, chapter, book)
}

// MARK: - URL Building

/// Build a human-readable lampbible:// URL from verse ID(s)
/// Format: lampbible://gen1:1 or lampbible://gen1:1-5 with optional ?translation=NIV
func buildVerseURL(verseId: Int, endVerseId: Int? = nil, translationId: String? = nil) -> URL? {
    let (verse, chapter, book) = splitVerseId(verseId)
    let osisId = BookOsisCache.shared.getOsisId(for: book).lowercased()
    guard !osisId.isEmpty else { return nil }

    var urlString = "lampbible://\(osisId)\(chapter):\(verse)"

    // Add end verse if in same chapter
    if let endId = endVerseId {
        let (endVerse, endChapter, endBook) = splitVerseId(endId)
        if endBook == book && endChapter == chapter && endVerse > verse {
            urlString += "-\(endVerse)"
        }
    }

    // Add translation as query param if specified
    if let translation = translationId {
        urlString += "?translation=\(translation)"
    }

    return URL(string: urlString)
}

// MARK: - Module Visibility Helpers

/// Parses a comma-separated string of hidden translation IDs into a Set (String IDs for GRDB)
func parseHiddenTranslationIds(_ hiddenString: String) -> Set<String> {
    Set(hiddenString.split(separator: ",").map { String($0) })
}

/// Parses a comma-separated string of hidden lexicon keys into a Set
func parseHiddenLexiconKeys(_ hiddenString: String) -> Set<String> {
    Set(hiddenString.split(separator: ",").map { String($0) })
}

/// Returns visible translations (excluding hidden ones), optionally ordered - uses GRDB
func visibleTranslations(hiddenString: String, orderString: String? = nil) -> [TranslationModule] {
    let hiddenIds = parseHiddenTranslationIds(hiddenString)
    let all = (try? TranslationDatabase.shared.getAllTranslations()) ?? []
    let visible = all.filter { !hiddenIds.contains($0.id) }

    guard let orderString = orderString, !orderString.isEmpty else {
        return visible
    }

    let storedOrder = orderString.split(separator: ",").map { String($0) }
    var ordered: [TranslationModule] = []

    // First add items from stored order that still exist and are visible
    for id in storedOrder {
        if let translation = visible.first(where: { $0.id == id }) {
            ordered.append(translation)
        }
    }

    // Then append any visible items not in stored order
    for translation in visible {
        if !ordered.contains(where: { $0.id == translation.id }) {
            ordered.append(translation)
        }
    }

    return ordered
}

/// Returns visible lexicon entries for a Strong's number, filtered by hidden keys and ordered
func visibleLexiconEntries(
    for strongsNum: String,
    orderString: String,
    hiddenString: String
) -> [LexiconEntry] {
    let hiddenKeys = parseHiddenLexiconKeys(hiddenString)
    let allEntries = LexiconLookup.sortedEntries(for: strongsNum, orderString: orderString)
    return allEntries.filter { !hiddenKeys.contains($0.lexiconKey) }
}

/// Returns whether a lexicon key is hidden
func isLexiconHidden(_ lexiconKey: String, hiddenString: String) -> Bool {
    let hiddenKeys = parseHiddenLexiconKeys(hiddenString)
    return hiddenKeys.contains(lexiconKey)
}
