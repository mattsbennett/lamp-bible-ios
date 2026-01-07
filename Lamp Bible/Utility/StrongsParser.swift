//
//  StrongsParser.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-29.
//

import Foundation

/// Represents a word or segment from an annotated verse
struct AnnotatedWord: Identifiable {
    let id = UUID()
    let text: String              // The displayed word (e.g., "created")
    let strongs: [String]         // Strong's numbers (e.g., ["H853", "H1254"])
    let morphology: String?       // Morphology code (e.g., "TH8804")
    let isAnnotated: Bool         // true if has Strong's numbers
}

/// Parses verse text containing Strong's annotations
/// Format: {word|strongs} or {word|strongs|morph} or plain text
/// Example: {In the beginning|H7225} {God|H430} {created|H853,H1254|TH8804}
func parseAnnotatedVerse(_ rawText: String) -> [AnnotatedWord] {
    var words: [AnnotatedWord] = []

    // Pattern: {word|strongs} or {word|strongs|morph}
    let pattern = #"\{([^|]+)\|([^|}]+)(?:\|([^}]+))?\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        // If regex fails, return the whole text as unannotated
        return [AnnotatedWord(text: rawText, strongs: [], morphology: nil, isAnnotated: false)]
    }

    var lastEnd = rawText.startIndex
    let nsRange = NSRange(rawText.startIndex..., in: rawText)

    regex.enumerateMatches(in: rawText, range: nsRange) { match, _, _ in
        guard let match = match else { return }
        guard let matchRange = Range(match.range, in: rawText) else { return }

        // Add any plain text before this match
        if lastEnd < matchRange.lowerBound {
            let plainText = String(rawText[lastEnd..<matchRange.lowerBound])
            if !plainText.isEmpty {
                words.append(AnnotatedWord(text: plainText, strongs: [], morphology: nil, isAnnotated: false))
            }
        }

        // Extract groups
        guard let wordRange = Range(match.range(at: 1), in: rawText),
              let strongsRange = Range(match.range(at: 2), in: rawText) else {
            return
        }

        let word = String(rawText[wordRange])
        let strongsList = String(rawText[strongsRange]).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let morph: String? = match.range(at: 3).location != NSNotFound
            ? Range(match.range(at: 3), in: rawText).map { String(rawText[$0]) }
            : nil

        words.append(AnnotatedWord(text: word, strongs: strongsList, morphology: morph, isAnnotated: true))

        lastEnd = matchRange.upperBound
    }

    // Add any trailing plain text (punctuation, etc.)
    if lastEnd < rawText.endIndex {
        let plainText = String(rawText[lastEnd...])
        if !plainText.isEmpty {
            words.append(AnnotatedWord(text: plainText, strongs: [], morphology: nil, isAnnotated: false))
        }
    }

    // If no annotations found, return whole text as unannotated
    if words.isEmpty {
        return [AnnotatedWord(text: rawText, strongs: [], morphology: nil, isAnnotated: false)]
    }

    return words
}

/// Check if a verse text contains Strong's annotations
func hasStrongsAnnotations(_ text: String) -> Bool {
    return text.contains("{") && text.contains("|")
}

/// Strip Strong's annotations from text, returning plain text
func stripStrongsAnnotations(_ text: String) -> String {
    guard hasStrongsAnnotations(text) else { return text }

    let words = parseAnnotatedVerse(text)
    return words.map { $0.text }.joined()
}

// MARK: - Search Query Parsing

/// Represents a search term - either quoted (exact word match) or unquoted (substring match)
struct SearchTerm {
    let text: String
    let isExact: Bool  // true if quoted (requires word boundary match)
}

/// Parse a search query into terms, handling quoted phrases as exact match terms
/// - Parameter query: The raw search query string
/// - Returns: Array of search terms
func parseSearchQuery(_ query: String) -> [SearchTerm] {
    var terms: [SearchTerm] = []
    let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return [] }

    // All quote characters we recognize (straight and smart/curly quotes)
    let openingDoubleQuotes: Set<Character> = ["\"", "\u{201C}"]  // " and "
    let closingDoubleQuotes: Set<Character> = ["\"", "\u{201D}"]  // " and "
    let openingSingleQuotes: Set<Character> = ["'", "\u{2018}"]   // ' and '
    let closingSingleQuotes: Set<Character> = ["'", "\u{2019}"]   // ' and '

    var currentIndex = input.startIndex
    var currentWord = ""
    var inQuote = false
    var isDoubleQuote = true  // Track if we're in double or single quotes

    while currentIndex < input.endIndex {
        let char = input[currentIndex]

        if !inQuote {
            // Not inside a quote - check for opening quotes
            if openingDoubleQuotes.contains(char) {
                // Starting a double-quoted phrase
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    terms.append(SearchTerm(text: trimmed, isExact: false))
                }
                currentWord = ""
                inQuote = true
                isDoubleQuote = true
            } else if openingSingleQuotes.contains(char) {
                // Starting a single-quoted phrase
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    terms.append(SearchTerm(text: trimmed, isExact: false))
                }
                currentWord = ""
                inQuote = true
                isDoubleQuote = false
            } else if char.isWhitespace {
                // End of unquoted word
                let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    terms.append(SearchTerm(text: trimmed, isExact: false))
                }
                currentWord = ""
            } else {
                currentWord.append(char)
            }
        } else {
            // Inside a quote - check for closing quotes
            let closingQuotes = isDoubleQuote ? closingDoubleQuotes : closingSingleQuotes
            if closingQuotes.contains(char) {
                // End of quoted phrase
                if !currentWord.isEmpty {
                    terms.append(SearchTerm(text: currentWord, isExact: true))
                }
                currentWord = ""
                inQuote = false
            } else {
                currentWord.append(char)
            }
        }

        currentIndex = input.index(after: currentIndex)
    }

    // Handle remaining text
    let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty {
        // If we ended while still in a quote (unmatched quote), treat as exact match
        terms.append(SearchTerm(text: trimmed, isExact: inQuote))
    }

    return terms
}

/// Check if text matches a search term
/// - Parameters:
///   - text: The text to search in
///   - term: The search term to match
/// - Returns: true if the text matches the term
func textMatches(_ text: String, term: SearchTerm) -> Bool {
    if term.isExact {
        // Word boundary match - the term must appear as a complete word
        // Use regex with word boundaries
        let escapedTerm = NSRegularExpression.escapedPattern(for: term.text)
        let pattern = "\\b\(escapedTerm)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            // Fallback to contains if regex fails
            return text.localizedCaseInsensitiveContains(term.text)
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: nsRange) != nil
    } else {
        // Substring match (original behavior)
        return text.localizedCaseInsensitiveContains(term.text)
    }
}

/// Check if text matches all search terms
/// - Parameters:
///   - text: The text to search in
///   - terms: Array of search terms to match
/// - Returns: true if all terms match
func textMatchesAllTerms(_ text: String, terms: [SearchTerm]) -> Bool {
    for term in terms {
        if !textMatches(text, term: term) {
            return false
        }
    }
    return true
}

/// Get the raw search string for Realm pre-filtering (strips quotes, returns first term)
/// This is used for the initial Realm CONTAINS query before post-filtering
func getRealmSearchString(from query: String) -> String {
    // Remove all quote types (straight and smart/curly) for CONTAINS matching
    return query
        .replacingOccurrences(of: "\"", with: "")   // straight double
        .replacingOccurrences(of: "'", with: "")    // straight single
        .replacingOccurrences(of: "\u{201C}", with: "")  // " left double
        .replacingOccurrences(of: "\u{201D}", with: "")  // " right double
        .replacingOccurrences(of: "\u{2018}", with: "")  // ' left single
        .replacingOccurrences(of: "\u{2019}", with: "")  // ' right single
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
