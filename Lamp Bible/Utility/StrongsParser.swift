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
