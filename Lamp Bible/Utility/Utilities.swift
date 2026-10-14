//
//  Utilities.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import Foundation
import GRDB
import LampCore

func countWords(source: String) -> Int {
    LampReadingTimeEstimator.wordCount(in: source)
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
    LampApplicationLink.verseURL(
        reference: verseId,
        endReference: endVerseId,
        translationID: translationId
    ) { book in
        let osisID = BookOsisCache.shared.getOsisId(for: book)
        return osisID.isEmpty ? nil : osisID
    }
}

// MARK: - Module Visibility Helpers

/// Parses a comma-separated string of hidden translation IDs into a Set (String IDs for GRDB)
func parseHiddenTranslationIds(_ hiddenString: String) -> Set<String> {
    Set(LampModuleSelection.identifiers(in: hiddenString))
}

/// Parses a comma-separated string of hidden lexicon keys into a Set
func parseHiddenLexiconKeys(_ hiddenString: String) -> Set<String> {
    Set(LampModuleSelection.identifiers(in: hiddenString))
}

/// Returns visible translations (excluding hidden ones), optionally ordered - uses GRDB
func visibleTranslations(hiddenString: String, orderString: String? = nil) -> [TranslationModule] {
    LampModuleSelection.visible(
        (try? TranslationDatabase.shared.getAllTranslations()) ?? [],
        hiddenIDs: parseHiddenTranslationIds(hiddenString),
        preferredIDs: LampModuleSelection.identifiers(in: orderString ?? ""), id: \.id
    )
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
