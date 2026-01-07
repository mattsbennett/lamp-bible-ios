//
//  ReferenceParsingTests.swift
//  Lamp BibleTests
//
//  Tests for dictionary reference parsing with annotated format
//

import XCTest

// Local VerseRef struct for testing (matches main app's structure)
struct VerseRef: Equatable {
    let sv: Int  // start verse ID
    let ev: Int? // end verse ID (for ranges)
}

/// Test cases for dictionary reference parsing with annotated format
/// Format:
///   - Bible refs: ⟦Matt. 4:23⟧ - nth match maps to references[n]
///   - Strong's refs: ⟨G932⟩
final class ReferenceParsingTests: XCTestCase {

    // MARK: - Parser Implementation (for isolated testing)

    enum ParsedSegment: CustomStringConvertible, Equatable {
        case text(String)
        case strongs(String)
        case verseRef(display: String, verseId: Int, fullRef: String?)

        var description: String {
            switch self {
            case .text(let s): return "text(\"\(s)\")"
            case .strongs(let s): return "strongs(\"\(s)\")"
            case .verseRef(let d, let v, let f):
                return f != nil ? "ref(\"\(d)\" id:\(v) -> \"\(f!)\")" : "ref(\"\(d)\" id:\(v))"
            }
        }
    }

    /// Parses text with annotated references
    func parseAnnotatedText(_ text: String, references: [VerseRef]?) -> [ParsedSegment] {
        var segments: [ParsedSegment] = []
        var refIndex = 0
        let refs = references ?? []

        // Combined pattern for annotated references
        // ⟦...⟧ = Bible reference, ⟨...⟩ = Strong's reference
        let pattern = #"⟦([^⟧]+)⟧|⟨([GH]\d+)⟩"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        var lastEnd = text.startIndex

        for match in regex.matches(in: text, range: nsRange) {
            guard let matchRange = Range(match.range, in: text) else { continue }

            // Add any text before this match
            if lastEnd < matchRange.lowerBound {
                let plainText = String(text[lastEnd..<matchRange.lowerBound])
                if !plainText.isEmpty {
                    segments.append(.text(plainText))
                }
            }

            // Check which group matched
            if let bibleRefRange = Range(match.range(at: 1), in: text) {
                // Bible reference: ⟦...⟧
                let displayText = String(text[bibleRefRange])
                if refIndex < refs.count {
                    segments.append(.verseRef(display: displayText, verseId: refs[refIndex].sv, fullRef: displayText))
                    refIndex += 1
                } else {
                    // No refs available, treat as plain text
                    segments.append(.text(displayText))
                }
            } else if let strongsRange = Range(match.range(at: 2), in: text) {
                // Strong's reference: ⟨G/H...⟩
                let strongsNum = String(text[strongsRange])
                segments.append(.strongs(strongsNum))
            }

            lastEnd = matchRange.upperBound
        }

        // Add any remaining text
        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...])
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments.isEmpty ? [.text(text)] : segments
    }

    // MARK: - Test Cases

    func testSimpleBibleRef() {
        let input = "See ⟦Matt. 4:23⟧ for details"
        let refs = [VerseRef(sv: 40004023, ev: nil)]

        let result = parseAnnotatedText(input, references: refs)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .text("See "))
        XCTAssertEqual(result[1], .verseRef(display: "Matt. 4:23", verseId: 40004023, fullRef: "Matt. 4:23"))
        XCTAssertEqual(result[2], .text(" for details"))
    }

    func testMultipleBibleRefs() {
        let input = "(⟦Matt. 4:23⟧; ⟦9:35⟧; ⟦24:14⟧)"
        let refs = [
            VerseRef(sv: 40004023, ev: nil),
            VerseRef(sv: 40009035, ev: nil),
            VerseRef(sv: 40024014, ev: nil)
        ]

        let result = parseAnnotatedText(input, references: refs)

        let verseRefs = result.filter { if case .verseRef = $0 { return true }; return false }
        XCTAssertEqual(verseRefs.count, 3)
    }

    func testStrongsRef() {
        let input = "The word ⟨G932⟩ means kingdom"
        let result = parseAnnotatedText(input, references: nil)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], .text("The word "))
        XCTAssertEqual(result[1], .strongs("G932"))
        XCTAssertEqual(result[2], .text(" means kingdom"))
    }

    func testMixedRefs() {
        let input = "⟨G932⟩ kingdom (⟦Matt. 4:23⟧)"
        let refs = [VerseRef(sv: 40004023, ev: nil)]

        let result = parseAnnotatedText(input, references: refs)

        XCTAssertEqual(result[0], .strongs("G932"))
        XCTAssertEqual(result[1], .text(" kingdom ("))
        XCTAssertEqual(result[2], .verseRef(display: "Matt. 4:23", verseId: 40004023, fullRef: "Matt. 4:23"))
        XCTAssertEqual(result[3], .text(")"))
    }

    func testNoAnnotations() {
        let input = "Plain text with no annotations"
        let result = parseAnnotatedText(input, references: nil)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], .text("Plain text with no annotations"))
    }

    func testComplexText() {
        let input = "truth (⟦John 8:46⟧ where it stands... See also ⟦John 16:8⟧, ⟦9⟧)"
        let refs = [
            VerseRef(sv: 43008046, ev: nil),
            VerseRef(sv: 43016008, ev: nil),
            VerseRef(sv: 43016009, ev: nil)
        ]

        let result = parseAnnotatedText(input, references: refs)

        let verseRefs = result.filter { if case .verseRef = $0 { return true }; return false }
        XCTAssertEqual(verseRefs.count, 3)

        // Check that the displays are correct
        if case .verseRef(let d1, let v1, _) = verseRefs[0] {
            XCTAssertEqual(d1, "John 8:46")
            XCTAssertEqual(v1, 43008046)
        }
        if case .verseRef(let d2, let v2, _) = verseRefs[1] {
            XCTAssertEqual(d2, "John 16:8")
            XCTAssertEqual(v2, 43016008)
        }
        if case .verseRef(let d3, let v3, _) = verseRefs[2] {
            XCTAssertEqual(d3, "9")
            XCTAssertEqual(v3, 43016009)
        }
    }

    func testHebrewStrongs() {
        let input = "The Hebrew word ⟨H1234⟩ in ⟦Gen. 1:1⟧"
        let refs = [VerseRef(sv: 1001001, ev: nil)]

        let result = parseAnnotatedText(input, references: refs)

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], .text("The Hebrew word "))
        XCTAssertEqual(result[1], .strongs("H1234"))
        XCTAssertEqual(result[2], .text(" in "))
        XCTAssertEqual(result[3], .verseRef(display: "Gen. 1:1", verseId: 1001001, fullRef: "Gen. 1:1"))
    }
}
