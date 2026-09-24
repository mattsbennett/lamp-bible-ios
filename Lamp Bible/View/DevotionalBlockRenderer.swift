//
//  DevotionalBlockRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import LampCore

// MARK: - Lampbible URL Parser

/// Parses lampbible:// URLs in both formats:
/// - Human-readable: lampbible://gen1:1 or lampbible://gen1:1-5?translation=NIV
/// - Legacy numeric: lampbible://verse/43003016 or lampbible://verse/43003016/43003020?translation=NIV
enum LampbibleURL {
    case verse(verseId: Int, endVerseId: Int?, translationId: String?)
    case reading(verseId: Int, endVerseId: Int?, openExternal: Bool)
    case strongs(key: String)
    case external(url: URL)

    /// Parse a URL into a LampbibleURL
    static func parse(_ url: URL) -> LampbibleURL? {
        guard url.scheme?.lowercased() == "lampbible" else {
            return .external(url: url)
        }
        guard let link = LampApplicationLink(url: url, bookNumberForOSIS: lookupBookId) else {
            return nil
        }
        switch link {
        case .verse(let reference, let endReference, let translationID):
            return .verse(verseId: reference, endVerseId: endReference, translationId: translationID)
        case .reading(let reference, let endReference, let openExternal):
            return .reading(verseId: reference, endVerseId: endReference, openExternal: openExternal)
        case .strongs(let key):
            return .strongs(key: key)
        case .reader(let reference?, let translationID):
            return .verse(verseId: reference, endVerseId: nil, translationId: translationID)
        case .reader, .book, .section, .moduleFile, .dataFile:
            return nil
        }
    }

    /// Parse a URL string into a LampbibleURL
    static func parse(_ urlString: String) -> LampbibleURL? {
        guard let url = URL(string: urlString) else { return nil }
        return parse(url)
    }

    /// Look up book ID from OSIS ID
    private static func lookupBookId(osisId: String) -> Int? {
        // Cache for OSIS ID to book ID mapping
        struct Cache {
            static var osisToBookId: [String: Int]? = nil
        }

        if Cache.osisToBookId == nil {
            Cache.osisToBookId = [:]
            if let books = try? BundledModuleDatabase.shared.getAllBooks() {
                for book in books {
                    Cache.osisToBookId?[book.osisId.lowercased()] = book.id
                }
            }
        }

        return Cache.osisToBookId?[osisId.lowercased()]
    }
}
