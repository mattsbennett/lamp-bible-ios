//
//  DevotionalBlockRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation

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
        guard url.scheme == "lampbible" else {
            return .external(url: url)
        }

        // Extract translation from query string
        let translationId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "translation" })?
            .value

        let urlString = url.absoluteString
        // Remove query string for path parsing
        let pathOnly = urlString.split(separator: "?").first.map(String.init) ?? urlString

        // Extract query parameters
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let openExternal = queryItems?.first(where: { $0.name == "external" })?.value == "1"

        // Handle reading plan format: lampbible://reading/SV/EV?external=1
        if pathOnly.hasPrefix("lampbible://reading/") {
            let pathParts = pathOnly.dropFirst("lampbible://reading/".count).split(separator: "/")
            if let first = pathParts.first, let sv = Int(first) {
                let ev = pathParts.count > 1 ? Int(pathParts[1]) : nil
                return .reading(verseId: sv, endVerseId: ev, openExternal: openExternal)
            }
        }

        // Handle legacy format: lampbible://verse/43003016
        if pathOnly.hasPrefix("lampbible://verse/") {
            let pathParts = pathOnly.dropFirst("lampbible://verse/".count).split(separator: "/")
            if let first = pathParts.first, let verseId = Int(first) {
                let endVerseId = pathParts.count > 1 ? Int(pathParts[1]) : nil
                return .verse(verseId: verseId, endVerseId: endVerseId, translationId: translationId)
            }
        }

        // Handle strongs format: lampbible://strongs/G1234
        if pathOnly.hasPrefix("lampbible://strongs/") {
            let key = String(pathOnly.dropFirst("lampbible://strongs/".count))
            if !key.isEmpty {
                return .strongs(key: key)
            }
        }

        // Handle human-readable format: lampbible://gen1:1 or lampbible://gen1:1-5
        // Pattern: bookOsisId + chapter + ":" + verse + optional("-" + endVerse)
        let path = String(pathOnly.dropFirst("lampbible://".count)).lowercased()

        // Use NSRegularExpression for compatibility
        let pattern = "^([a-z0-9]+)(\\d+):(\\d+)(?:-(\\d+))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) else {
            return nil
        }

        // Extract capture groups
        guard match.numberOfRanges >= 4,
              let osisRange = Range(match.range(at: 1), in: path),
              let chapterRange = Range(match.range(at: 2), in: path),
              let verseRange = Range(match.range(at: 3), in: path) else {
            return nil
        }

        let osisId = String(path[osisRange])
        guard let chapter = Int(path[chapterRange]),
              let verse = Int(path[verseRange]) else { return nil }

        // Look up book ID from OSIS ID
        guard let bookId = lookupBookId(osisId: osisId) else { return nil }

        let verseId = bookId * 1000000 + chapter * 1000 + verse
        var endVerseId: Int? = nil

        // Check for end verse (optional capture group 4)
        if match.numberOfRanges >= 5 && match.range(at: 4).location != NSNotFound,
           let endVerseRange = Range(match.range(at: 4), in: path),
           let endVerse = Int(path[endVerseRange]), endVerse > verse {
            endVerseId = bookId * 1000000 + chapter * 1000 + endVerse
        }

        return .verse(verseId: verseId, endVerseId: endVerseId, translationId: translationId)
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
