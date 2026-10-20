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

// MARK: - Temporary Files

/// Clears what earlier runs of the app left in its temporary directory.
///
/// Every temporary database and staging folder the app makes is removed by a
/// `defer`, which never runs when iOS kills the app — and sync is where it gets
/// killed. A phone was found holding 24 of them, 720 MB, going back months.
///
/// Only names this app gives its own files are touched, and only those older
/// than `cutoff`: a pass that starts while this runs keeps what it is making.
enum TemporaryFileSweeper {
    struct Result: Equatable {
        var removed = 0
        var bytes: Int64 = 0
    }

    @discardableResult
    static func removeLeftovers(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan cutoff: Date
    ) -> Result {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return Result() }

        var result = Result()
        for entry in entries where isLeftover(named: entry.lastPathComponent) {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < cutoff else { continue }
            let bytes = allocatedSize(of: entry)
            do {
                try fileManager.removeItem(at: entry)
                result.removed += 1
                result.bytes += bytes
            } catch {
                print("[TemporaryFiles] could not remove \(entry.lastPathComponent): \(error)")
            }
        }
        return result
    }

    /// Names the app and its sync code give their own scratch files:
    /// `<UUID>.db` and SQLite's companions to it, `lamp-<purpose>-<UUID>`
    /// files and folders, bare UUID folders, and the replacement folders
    /// Foundation leaves when a swap is cut short.
    static func isLeftover(named name: String) -> Bool {
        if name.hasPrefix("NSIRD_") { return true }
        if name.hasPrefix("lamp-") {
            let stem = (name as NSString).deletingPathExtension
            return UUID(uuidString: String(stem.suffix(36))) != nil
        }
        for suffix in [".db", ".db-wal", ".db-shm", ".db-journal"] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil
        }
        return UUID(uuidString: name) != nil
    }

    private static func allocatedSize(of url: URL) -> Int64 {
        let key: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: key) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        let contents = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        )
        var total: Int64 = 0
        while let item = contents?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
