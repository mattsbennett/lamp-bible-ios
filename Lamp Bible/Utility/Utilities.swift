//
//  Utilities.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import Foundation
import GRDB
import StoreKit

extension Notification.Name {
    /// Posted whenever the App Store storefront changes the availability of
    /// first-party content with territorial restrictions.
    static let bundledContentTerritoryDidChange = Notification.Name("bundledContentTerritoryDidChange")
}

/// Pure storefront rules for first-party content shipped by Lamp Bible.
///
/// User-created/imported modules are deliberately outside this policy. The
/// unified translation database only applies the rule when an ID resolves to
/// the read-only bundled database.
enum BundledContentTerritoryRules {
    static let unitedKingdomCountryCodes: Set<String> = ["GBR", "GB", "UK"]
    static let restrictedTranslationIds: Set<String> = ["KJV", "KJVs"]

    /// A missing storefront fails closed for territorially restricted bundled
    /// content. Other bundled content remains available while StoreKit loads.
    static func allowsBundledTranslation(id: String, countryCode: String?) -> Bool {
        guard restrictedTranslationIds.contains(id) else { return true }
        guard let countryCode else { return false }
        return !unitedKingdomCountryCodes.contains(countryCode.uppercased())
    }
}

/// Thread-safe runtime view of the customer's current App Store storefront.
/// StoreKit can change storefronts while the app is installed, so the policy
/// refreshes on launch and monitors `Storefront.updates` for the rest of the
/// process lifetime.
final class BundledContentTerritoryPolicy: @unchecked Sendable {
    static let shared = BundledContentTerritoryPolicy()

    private let lock = NSLock()
    private var countryCode: String?
    private var resolved = false
    private var monitoringTask: Task<Void, Never>?

    private init() {}

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    func allowsBundledTranslation(id: String) -> Bool {
        lock.lock()
        let currentCountryCode = resolved ? countryCode : nil
        lock.unlock()
        return BundledContentTerritoryRules.allowsBundledTranslation(
            id: id,
            countryCode: currentCountryCode
        )
    }

    func restrictsBundledTranslation(id: String) -> Bool {
        BundledContentTerritoryRules.restrictedTranslationIds.contains(id)
            && !allowsBundledTranslation(id: id)
    }

    /// Resolve the initial storefront before constructing content-bearing UI.
    func refresh() async {
        let storefront = await Storefront.current
        apply(countryCode: storefront?.countryCode)
    }

    func startMonitoring() {
        lock.lock()
        guard monitoringTask == nil else {
            lock.unlock()
            return
        }

        monitoringTask = Task { [weak self] in
            for await storefront in Storefront.updates {
                guard !Task.isCancelled else { return }
                self?.apply(countryCode: storefront.countryCode)
            }
        }
        lock.unlock()
    }

    private func apply(countryCode newCountryCode: String?) {
        let normalizedCountryCode = newCountryCode?.uppercased()

        lock.lock()
        let availabilityChanged = !resolved || countryCode != normalizedCountryCode
        countryCode = normalizedCountryCode
        resolved = true
        lock.unlock()

        guard availabilityChanged else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .bundledContentTerritoryDidChange, object: nil)
        }
    }
}

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
