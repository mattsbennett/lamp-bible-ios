//
//  LexiconView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-29.
//

import SwiftUI
import GRDB

// MARK: - First Match Scroll Offset

/// Preference key to collect first match offset from text views for scroll-to-match
private struct FirstMatchOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        // Take the first non-nil value (we only want the first match)
        if value == nil {
            value = nextValue()
        }
    }
}

/// Helper to find UIScrollView in the view hierarchy and scroll to offset
private struct ScrollToOffsetHelper {
    static func scrollToOffset(_ offset: CGFloat, in view: UIView?, animated: Bool = true) {
        guard let scrollView = findScrollView(in: view) else { return }
        // Clamp to max scroll offset to avoid scrolling past content
        let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let targetY = min(max(0, offset - 120), maxScrollY)
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
    }

    private static func findScrollView(in view: UIView?) -> UIScrollView? {
        guard let view = view else { return nil }
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// UIViewRepresentable to capture the hosting view for scroll access
private struct ScrollViewFinder: UIViewRepresentable {
    var onScrollViewFound: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    onScrollViewFound(scrollView)
                    return
                }
                current = view.superview
            }
            onScrollViewFound(nil)
        }
    }
}

// MARK: - Strong's Reference Linked Text

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Linked Text Segment Parsing

/// A segment of parsed text - either plain text, a Strong's reference, a verse reference, or a BDB cross-reference
private enum LinkedTextSegment: Identifiable {
    case text(String)
    case strongs(String)  // e.g., "H1234", "G5678"
    case verseRef(display: String, verseId: Int, endVerseId: Int? = nil, fullRef: String? = nil)  // parsed verse reference
    case bdbRef(String)  // e.g., "BDB871" - cross-reference to another BDB entry

    var id: String {
        switch self {
        case .text(let s): return "t_\(s.hashValue)"
        case .strongs(let s): return "s_\(s)"
        case .verseRef(let d, let v, _, _): return "v_\(d)_\(v)"
        case .bdbRef(let b): return "b_\(b)"
        }
    }
}


/// Parses text into segments, identifying Strong's numbers and verse references
private func parseLinkedTextSegments(_ text: String) -> [LinkedTextSegment] {
    var segments: [LinkedTextSegment] = []

    // Combined pattern for Strong's numbers and verse references
    // Strong's: H1234, G5678 (with optional angle brackets ⟨H1234⟩)
    // Verse refs: Book chapter:verse (handles parentheses, various book name formats)
    let strongsPattern = #"⟨[GH]\d+⟩|[GH]\d+"#
    let verseRefPattern = #"\(?\b([1-3]?\s*[A-Z][a-z]+\.?)\s+(\d+):(\d+)\)?"#

    let combinedPattern = "(\(strongsPattern))|(\(verseRefPattern))"

    guard let regex = try? NSRegularExpression(pattern: combinedPattern, options: []) else {
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

        let matchedText = String(text[matchRange])

        // Check if it's a bracketed Strong's number ⟨H1234⟩
        if matchedText.hasPrefix("⟨") && matchedText.hasSuffix("⟩") {
            let strongsNum = String(matchedText.dropFirst().dropLast())
            segments.append(.strongs(strongsNum))
        }
        // Check if it's a bare Strong's number H1234 or G5678
        else if (matchedText.first == "H" || matchedText.first == "G"),
           matchedText.dropFirst().allSatisfy({ $0.isNumber }) {
            segments.append(.strongs(matchedText))
        }
        // Otherwise try parsing as a verse reference
        else if let parsed = parseVerseReference(matchedText) {
            segments.append(.verseRef(display: matchedText, verseId: parsed.verseId, endVerseId: nil, fullRef: nil))
        } else {
            // Couldn't parse as verse ref, treat as plain text
            segments.append(.text(matchedText))
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

/// Result of parsing a verse reference, including context for continuation refs (lexicon-specific)
private struct LexiconVerseRefContext {
    let verseId: Int
    let bookId: Int
    let chapter: Int
    let verse: Int
}

/// Parses a verse reference string into a verse ID, with optional context from previous reference
/// Context allows parsing continuation references like "14" when previous was "Daniel (4:12"
private func parseVerseReference(_ ref: String, context: LexiconVerseRefContext? = nil) -> LexiconVerseRefContext? {
    // Clean up: remove outer parentheses but preserve internal ones
    var cleaned = ref.trimmingCharacters(in: .whitespaces)
    if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
        cleaned = String(cleaned.dropFirst().dropLast())
    }
    // Also handle trailing ) without leading (
    cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ")"))

    // Pattern 1: Full reference - BookName (chapter:verse or BookName chapter:verse
    // Allows optional ( between book and chapter for patterns like "Daniel (4:12"
    let fullPattern = #"^([1-3]?\s*[A-Z][a-z]+\.?)\s*\(?\s*(\d+):(\d+)"#
    if let regex = try? NSRegularExpression(pattern: fullPattern),
       let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
       let bookRange = Range(match.range(at: 1), in: cleaned),
       let chapterRange = Range(match.range(at: 2), in: cleaned),
       let verseRange = Range(match.range(at: 3), in: cleaned) {

        let bookName = String(cleaned[bookRange]).trimmingCharacters(in: .whitespaces)
        if let chapter = Int(cleaned[chapterRange]),
           let verse = Int(cleaned[verseRange]),
           let bookId = lookupBookId(from: bookName) {
            let verseId = bookId * 1000000 + chapter * 1000 + verse
            return LexiconVerseRefContext(verseId: verseId, bookId: bookId, chapter: chapter, verse: verse)
        }
    }

    // Pattern 2: Chapter:verse only (uses book from context)
    let chapterVersePattern = #"^(\d+):(\d+)$"#
    if let ctx = context,
       let regex = try? NSRegularExpression(pattern: chapterVersePattern),
       let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
       let chapterRange = Range(match.range(at: 1), in: cleaned),
       let verseRange = Range(match.range(at: 2), in: cleaned),
       let chapter = Int(cleaned[chapterRange]),
       let verse = Int(cleaned[verseRange]) {
        let verseId = ctx.bookId * 1000000 + chapter * 1000 + verse
        return LexiconVerseRefContext(verseId: verseId, bookId: ctx.bookId, chapter: chapter, verse: verse)
    }

    // Pattern 3: Verse number only (uses book and chapter from context)
    let verseOnlyPattern = #"^(\d+)(?:-\d+)?$"#  // Also handles ranges like "14-15"
    if let ctx = context,
       let regex = try? NSRegularExpression(pattern: verseOnlyPattern),
       let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
       let verseRange = Range(match.range(at: 1), in: cleaned),
       let verse = Int(cleaned[verseRange]) {
        let verseId = ctx.bookId * 1000000 + ctx.chapter * 1000 + verse
        return LexiconVerseRefContext(verseId: verseId, bookId: ctx.bookId, chapter: ctx.chapter, verse: verse)
    }

    return nil
}

/// Legacy wrapper for code that just needs the verse ID
private func parseVerseReferenceId(_ ref: String) -> Int? {
    return parseVerseReference(ref)?.verseId
}

/// Looks up a book ID from various name formats (full name, OSIS, abbreviation)
private func lookupBookId(from name: String) -> Int? {
    let normalizedName = name.lowercased().replacingOccurrences(of: ".", with: "")
    let allBooks = (try? BundledModuleDatabase.shared.getAllBooks()) ?? []

    // Try exact match on various fields (case insensitive)
    if let book = allBooks.first(where: {
        $0.name.lowercased() == name.lowercased() ||
        $0.osisId.lowercased() == name.lowercased() ||
        $0.osisParatextAbbreviation.lowercased() == name.lowercased()
    }) {
        return book.id
    }

    // Try partial/fuzzy match for common abbreviations
    let abbreviationMap: [String: String] = [
        "gen": "Gen", "exod": "Exod", "exo": "Exod", "lev": "Lev", "num": "Num", "deut": "Deut",
        "josh": "Josh", "judg": "Judg", "ruth": "Ruth", "1sam": "1Sam", "2sam": "2Sam",
        "1kgs": "1Kgs", "2kgs": "2Kgs", "1chr": "1Chr", "2chr": "2Chr",
        "ezra": "Ezra", "neh": "Neh", "esth": "Esth", "job": "Job",
        "ps": "Ps", "psa": "Ps", "prov": "Prov", "eccl": "Eccl", "eccles": "Eccl",
        "song": "Song", "isa": "Isa", "jer": "Jer", "lam": "Lam",
        "ezek": "Ezek", "eze": "Ezek", "dan": "Dan", "hos": "Hos", "joel": "Joel",
        "amos": "Amos", "obad": "Obad", "jonah": "Jonah", "mic": "Mic",
        "nah": "Nah", "hab": "Hab", "zeph": "Zeph", "zep": "Zeph",
        "hag": "Hag", "zech": "Zech", "zec": "Zech", "mal": "Mal",
        "matt": "Matt", "mark": "Mark", "luke": "Luke", "john": "John",
        "acts": "Acts", "rom": "Rom", "1cor": "1Cor", "2cor": "2Cor",
        "gal": "Gal", "eph": "Eph", "phil": "Phil", "col": "Col",
        "1thess": "1Thess", "2thess": "2Thess", "1tim": "1Tim", "2tim": "2Tim",
        "titus": "Titus", "phlm": "Phlm", "heb": "Heb",
        "jas": "Jas", "1pet": "1Pet", "2pet": "2Pet",
        "1john": "1John", "2john": "2John", "3john": "3John",
        "jude": "Jude", "rev": "Rev",
        // Full names
        "genesis": "Gen", "exodus": "Exod", "leviticus": "Lev", "numbers": "Num",
        "deuteronomy": "Deut", "joshua": "Josh", "judges": "Judg",
        "samuel": "1Sam", "kings": "1Kgs", "chronicles": "1Chr",
        "nehemiah": "Neh", "esther": "Esth", "psalms": "Ps", "proverbs": "Prov",
        "ecclesiastes": "Eccl", "isaiah": "Isa", "jeremiah": "Jer",
        "lamentations": "Lam", "ezekiel": "Ezek", "daniel": "Dan",
        "hosea": "Hos", "obadiah": "Obad", "micah": "Mic", "nahum": "Nah",
        "habakkuk": "Hab", "zephaniah": "Zeph", "haggai": "Hag",
        "zechariah": "Zech", "malachi": "Mal", "matthew": "Matt",
        "romans": "Rom", "corinthians": "1Cor", "galatians": "Gal",
        "ephesians": "Eph", "philippians": "Phil", "colossians": "Col",
        "thessalonians": "1Thess", "timothy": "1Tim", "philemon": "Phlm",
        "hebrews": "Heb", "james": "Jas", "peter": "1Pet",
        "revelation": "Rev"
    ]

    if let osisId = abbreviationMap[normalizedName],
       let book = allBooks.first(where: { $0.osisId == osisId }) {
        return book.id
    }

    return nil
}

// MARK: - Enhanced Reference Parsing for User Dictionaries

/// Constructs a full reference string from a verse ID (e.g., 45007012 -> "Rom. 7:12")
private func formatVerseReference(verseId: Int) -> String {
    let bookId = verseId / 1000000
    let chapter = (verseId % 1000000) / 1000
    let verse = verseId % 1000

    // Look up book abbreviation
    let bookName: String
    if let book = try? BundledModuleDatabase.shared.getBook(id: bookId) {
        // Capitalize properly: "ROM" -> "Rom", "1SAM" -> "1Sam"
        let raw = book.osisId
        if let firstLetter = raw.first(where: { $0.isLetter }) {
            let idx = raw.firstIndex(of: firstLetter)!
            let prefix = raw[..<idx]  // e.g., "1" or ""
            let rest = raw[idx...]    // e.g., "SAM" or "ROM"
            let capitalized = rest.prefix(1).uppercased() + rest.dropFirst().lowercased()
            bookName = String(prefix) + capitalized
        } else {
            bookName = raw
        }
    } else {
        bookName = "?"
    }

    return "\(bookName). \(chapter):\(verse)"
}

/// Splits verse reference display text into optional prefix text and button display
/// For patterns like "Daniel (4:12", returns (prefix: "Daniel (", display: "4:12", fullRef: "Dan. 4:12")
/// For patterns like "Matt. 4:23", returns (prefix: nil, display: "Matt. 4:23", fullRef: "Matt. 4:23")
/// For continuation patterns like "14", returns (prefix: nil, display: "14", fullRef: "Dan. 4:14")
private func splitVerseRefDisplay(_ rawText: String, verseId: Int) -> (prefix: String?, display: String, fullRef: String) {
    // Always use formatted reference for popover title
    let fullRef = formatVerseReference(verseId: verseId)

    // Check if it's a continuation ref (just numbers, dashes, colons)
    let isContinuationRef = rawText.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "–" || $0 == ":" })
    if isContinuationRef {
        return (nil, rawText, fullRef)
    }

    // Check for pattern like "BookName (chapter:verse" - split into prefix and button
    // Pattern matches: "Daniel (4:12", "Genesis (1:1", etc.
    let parenPattern = #"^([1-3]?\s*[A-Za-z]+\.?\s*\()(\d+:\d+)"#
    if let regex = try? NSRegularExpression(pattern: parenPattern),
       let match = regex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..., in: rawText)),
       let prefixRange = Range(match.range(at: 1), in: rawText),
       let chapterVerseRange = Range(match.range(at: 2), in: rawText) {
        let prefix = String(rawText[prefixRange])
        let chapterVerse = String(rawText[chapterVerseRange])
        return (prefix, chapterVerse, fullRef)
    }

    // Default: use the raw text as-is for display, formatted ref for popover
    return (nil, rawText, fullRef)
}

/// Parses text with annotated references for accurate linking
/// Format:
///   - Bible refs: ⟦Matt. 4:23⟧ - nth match maps to references[n]
///   - Strong's refs: ⟨G932⟩
///   - BDB cross-refs: ⦃BDB871⦄
/// The markers are stripped for display.
private func parseLinkedTextWithReferences(_ text: String, references: [VerseRef]?) -> [LinkedTextSegment] {
    var segments: [LinkedTextSegment] = []
    var refIndex = 0
    let refs = references ?? []

    // Combined pattern for annotated references
    // ⟦...⟧ = Bible reference, ⟨...⟩ = Strong's reference, ⦃...⦄ = BDB cross-reference
    // Using non-greedy .+? instead of negated character class for better Unicode handling
    let pattern = #"⟦(.+?)⟧|⟨([GH]\d+)⟩|⦃(BDB\d+)⦄"#

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
            let rawDisplayText = String(text[bibleRefRange])
            if refIndex < refs.count {
                let ref = refs[refIndex]
                let verseId = ref.sv
                let endVerseId = ref.ev

                // Split into optional prefix text and button display
                let (prefix, buttonDisplay, fullRef) = splitVerseRefDisplay(rawDisplayText, verseId: verseId)

                // Add prefix as plain text if present (e.g., "Daniel (")
                if let prefix = prefix {
                    segments.append(.text(prefix))
                }

                segments.append(.verseRef(display: buttonDisplay, verseId: verseId, endVerseId: endVerseId, fullRef: fullRef))
                refIndex += 1
            } else {
                // Fallback: try to parse the reference text directly
                if let parsed = parseVerseReference(rawDisplayText) {
                    let (prefix, buttonDisplay, fullRef) = splitVerseRefDisplay(rawDisplayText, verseId: parsed.verseId)
                    if let prefix = prefix {
                        segments.append(.text(prefix))
                    }
                    segments.append(.verseRef(display: buttonDisplay, verseId: parsed.verseId, endVerseId: nil, fullRef: fullRef))
                } else {
                    segments.append(.text(rawDisplayText))
                }
            }
        } else if let strongsRange = Range(match.range(at: 2), in: text) {
            // Strong's reference: ⟨G/H...⟩
            let strongsNum = String(text[strongsRange])
            segments.append(.strongs(strongsNum))
        } else if let bdbRange = Range(match.range(at: 3), in: text) {
            // BDB cross-reference: ⦃BDB...⦄
            let bdbId = String(text[bdbRange])
            segments.append(.bdbRef(bdbId))
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

/// Counts the number of popover items (Strong's refs + verse refs + BDB refs) in a text string
/// Used for computing offsets in cross-segment swipe navigation
func countPopoverItemsInText(_ text: String, references: [VerseRef]? = nil) -> Int {
    let segments = references != nil
        ? parseLinkedTextWithReferences(text, references: references)
        : parseLinkedTextSegments(text)

    var count = 0
    for segment in segments {
        switch segment {
        case .strongs, .verseRef, .bdbRef:
            count += 1
        case .text:
            break
        }
    }
    return count
}

/// Counts popover items in a user dictionary sense
func countPopoverItemsInSense(_ sense: DictionarySense) -> Int {
    var count = 0
    if let def = sense.definitionText, !def.isEmpty {
        count += countPopoverItemsInText(def, references: sense.references)
    }
    if let deriv = sense.derivationText, !deriv.isEmpty {
        count += countPopoverItemsInText(deriv)
    }
    return count
}

/// Parse senses from JSON for user dictionaries (thread-safe, no Realm access)
private func parseUserSensesStatic(_ json: String?) -> [DictionarySense] {
    guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
    if let senses = try? JSONDecoder().decode([DictionarySense].self, from: data), !senses.isEmpty {
        // Return senses if any sense has meaningful content (definition, shortDefinition, or gloss)
        let hasContent = senses.contains { sense in
            (sense.definitionText != nil && !sense.definitionText!.isEmpty) ||
            (sense.shortDefinitionText != nil && !sense.shortDefinitionText!.isEmpty) ||
            (sense.gloss != nil && !sense.gloss!.isEmpty)
        }
        if hasContent {
            return senses
        }
    }
    return []
}

/// Parse senses based on lexicon type
private func parseSensesForEntry(_ entry: LexiconEntry) -> [DictionarySense] {
    // All dictionaries (including BDB) now use the same schema
    return parseUserSensesStatic(entry.sensesJson)
}

/// Thread-safe popover count that doesn't require Realm access
/// Uses simple regex counting instead of full verse reference parsing
private func countPopoverItemsInTextThreadSafe(_ text: String) -> Int {
    // Count Strong's numbers: H1234, G5678, or bracketed ⟨H1234⟩
    let strongsPattern = #"⟨[GH]\d+⟩|(?<![A-Za-z])[GH]\d+(?![A-Za-z0-9])"#
    // Count annotated verse refs: ⟦...⟧
    let annotatedRefPattern = #"⟦[^⟧]+⟧"#
    // Count BDB cross-refs: ⦃BDB...⦄
    let bdbRefPattern = #"⦃BDB\d+⦄"#
    // Count plain verse refs: Book chapter:verse
    let plainRefPattern = #"\(?\b([1-3]?\s*[A-Z][a-z]+\.?)\s+(\d+):(\d+)\)?"#

    var count = 0

    // Count Strong's numbers
    if let regex = try? NSRegularExpression(pattern: strongsPattern) {
        count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // Count annotated verse refs
    if let regex = try? NSRegularExpression(pattern: annotatedRefPattern) {
        count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // Count BDB cross-refs
    if let regex = try? NSRegularExpression(pattern: bdbRefPattern) {
        count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // Count plain verse refs (only if no annotated refs, to avoid double-counting)
    if count == 0, let regex = try? NSRegularExpression(pattern: plainRefPattern) {
        count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    return count
}

/// Thread-safe popover count for a user dictionary sense
private func countPopoverItemsInSenseThreadSafe(_ sense: DictionarySense) -> Int {
    var count = 0
    if let def = sense.definitionText, !def.isEmpty {
        count += countPopoverItemsInTextThreadSafe(def)
    }
    if let deriv = sense.derivationText, !deriv.isEmpty {
        count += countPopoverItemsInTextThreadSafe(deriv)
    }
    return count
}

/// Thread-safe popover count for an entry (no Realm access)
private func countPopoverItemsInEntryThreadSafe(_ entry: LexiconEntry, hasSenses: Bool, senses: [DictionarySense]) -> Int {
    var count = 0

    // Top-level definition (only for entries without multiple senses)
    if let def = entry.def, !def.isEmpty, !hasSenses {
        count += countPopoverItemsInTextThreadSafe(def)
    }

    // Derivation (only for entries without multiple senses)
    if let deriv = entry.deriv, !deriv.isEmpty, !hasSenses {
        count += countPopoverItemsInTextThreadSafe(deriv)
    }

    // Senses (BDB and user dictionaries use same format)
    if hasSenses {
        for sense in senses {
            count += countPopoverItemsInSenseThreadSafe(sense)
        }
    }

    return count
}

/// Counts all popover items in a lexicon entry (for cross-segment swipe navigation)
func countPopoverItemsInEntry(_ entry: LexiconEntry, hasSenses: Bool, senses: [DictionarySense]) -> Int {
    var count = 0

    // Top-level definition (only for entries without multiple senses)
    if let def = entry.def, !def.isEmpty, !hasSenses {
        count += countPopoverItemsInText(def)
    }

    // Derivation (only for entries without multiple senses)
    if let deriv = entry.deriv, !deriv.isEmpty, !hasSenses {
        count += countPopoverItemsInText(deriv)
    }

    // Senses (BDB and user dictionaries use same format)
    if hasSenses {
        for sense in senses {
            count += countPopoverItemsInSense(sense)
        }
    }

    return count
}

/// Consolidated flow item - text segments combined, interactive elements separate
/// A view that displays text with tappable Strong's references, verse references, and BDB cross-references
/// Uses UITextView for proper text wrapping and link handling
/// Data for tappable items (stored for popover display)
struct LexiconTappableItem: Equatable, Identifiable {
    let index: Int
    let type: TappableItemType

    var id: Int { index }

    enum TappableItemType: Equatable {
        case strongs(String)
        case verseRef(display: String, verseId: Int, endVerseId: Int?, fullRef: String?)
        case bdbRef(String)  // BDB cross-reference (e.g., "BDB871")
        case lexiconRef(String)  // Lexicon entry cross-reference (e.g., "CWSD_G1234")
    }
}

struct LexiconSheetState: Equatable, Identifiable {
    let currentItem: LexiconTappableItem
    let allItems: [LexiconTappableItem]

    // Use a stable id so the sheet doesn't dismiss/reopen on navigation
    var id: String { "sheet" }

    var currentIndex: Int {
        allItems.firstIndex(where: { $0.index == currentItem.index }) ?? 0
    }

    var canNavigatePrev: Bool {
        currentIndex > 0
    }

    var canNavigateNext: Bool {
        currentIndex < allItems.count - 1
    }

    func withPrev() -> LexiconSheetState? {
        guard canNavigatePrev else { return nil }
        return LexiconSheetState(currentItem: allItems[currentIndex - 1], allItems: allItems)
    }

    func withNext() -> LexiconSheetState? {
        guard canNavigateNext else { return nil }
        return LexiconSheetState(currentItem: allItems[currentIndex + 1], allItems: allItems)
    }
}

// Type aliases for internal use
private typealias TappableItem = LexiconTappableItem
private typealias SheetState = LexiconSheetState

// MARK: - Dictionary Definition View (v2.0 Annotated Text Support)

/// Renders a dictionary definition field, supporting both plain text (v1.0) and annotated text (v2.0)
/// For annotated text, uses AnnotatedDefinitionTextView with sheet integration
/// For plain text, falls back to LinkedDefinitionText which parses inline patterns
struct DictionaryDefinitionView: View {
    let field: FlexibleTextField?
    let font: Font
    var fontSize: CGFloat? = nil
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var references: [VerseRef]? = nil
    var isCurrentPage: Bool = true
    var baseOffset: Int = 0
    var sharedSheetState: Binding<LexiconSheetState?>? = nil
    var sharedAllItems: Binding<[LexiconTappableItem]>? = nil
    var searchTerms: [String] = []  // Search terms to highlight
    var shouldReportMatchOffset: Bool = false  // Whether to report first match offset for scroll-to-match
    var scrollCoordinateSpace: String = "lexiconScroll"

    // Track local state for annotated text (used when shared state not provided)
    @State private var tappableItems: [LexiconTappableItem] = []
    @State private var localSheetState: LexiconSheetState? = nil
    @State private var localMatchOffset: CGFloat? = nil  // Local Y offset of first match within text view

    // Use shared state if available, otherwise local
    private var effectiveSheetState: Binding<LexiconSheetState?> {
        if let shared = sharedSheetState {
            return shared
        }
        return $localSheetState
    }

    private var effectiveFontSize: CGFloat {
        fontSize ?? 15
    }

    var body: some View {
        if let field = field {
            if field.hasAnnotations, isCurrentPage {
                // Use AnnotatedDefinitionTextView for annotated text (v2.0 format) with sheet integration
                AnnotatedDefinitionTextView(
                    annotatedText: field.asAnnotatedText,
                    fontSize: effectiveFontSize,
                    baseOffset: baseOffset,
                    searchTerms: searchTerms,
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    onLinkTap: { index in
                        // Find the tapped item
                        let allItems = sharedAllItems?.wrappedValue ?? tappableItems
                        if let item = allItems.first(where: { $0.index == index }) {
                            effectiveSheetState.wrappedValue = LexiconSheetState(currentItem: item, allItems: allItems)
                        }
                    },
                    onItemsParsed: { items in
                        tappableItems = items
                        // Update shared items if using shared state
                        if let sharedItems = sharedAllItems {
                            let otherItems = sharedItems.wrappedValue.filter { item in
                                item.index < baseOffset || item.index >= baseOffset + items.count
                            }
                            sharedItems.wrappedValue = (otherItems + items).sorted { $0.index < $1.index }
                        }
                    },
                    onFirstMatchOffset: shouldReportMatchOffset ? { offset in
                        localMatchOffset = offset
                    } : nil
                )
                // Report absolute match offset via preference when we have both local offset and geometry
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: FirstMatchOffsetPreferenceKey.self,
                                value: shouldReportMatchOffset && localMatchOffset != nil
                                    ? geometry.frame(in: .named(scrollCoordinateSpace)).minY + (localMatchOffset ?? 0)
                                    : nil
                            )
                    }
                )
                // Only show sheet locally if not using shared state
                .sheet(item: sharedSheetState == nil ? $localSheetState : .constant(nil)) { state in
                    annotatedSheetContent(state: state)
                        .presentationDetents([.fraction(0.3), .medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationContentInteraction(.scrolls)
                }
            } else if field.hasAnnotations {
                // Lightweight placeholder for non-current pages
                Text(field.plainText)
                    .font(font)
                    .foregroundStyle(.primary)
            } else {
                // Use existing LinkedDefinitionText for plain text (v1.0 backwards compatibility)
                LinkedDefinitionText(
                    text: field.plainText,
                    font: font,
                    fontSize: fontSize,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    references: references,
                    isCurrentPage: isCurrentPage,
                    baseOffset: baseOffset,
                    sharedSheetState: sharedSheetState,
                    sharedAllItems: sharedAllItems,
                    searchTerms: searchTerms,
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
            }
        }
    }

    @ViewBuilder
    private func annotatedSheetContent(state: LexiconSheetState) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                LexiconSheetItemContent(
                    itemType: item.type,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse
                )
                .padding()
            }
            .navigationTitle(sheetTitle(for: item))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        effectiveSheetState.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let navigateAction = sheetNavigateAction(for: item) {
                        Button {
                            navigateAction()
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button(action: { navigateToPrev(state) }) {
                            Image(systemName: "chevron.left")
                                .font(.title3)
                                .padding(12)
                                .background(Circle().fill(Color.clear))
                                .contentShape(Circle())
                        }
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.allItems.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button(action: { navigateToNext(state) }) {
                            Image(systemName: "chevron.right")
                                .font(.title3)
                                .padding(12)
                                .background(Circle().fill(Color.clear))
                                .contentShape(Circle())
                        }
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
    }

    private func navigateToPrev(_ state: LexiconSheetState) {
        guard let newState = state.withPrev() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    private func navigateToNext(_ state: LexiconSheetState) {
        guard let newState = state.withNext() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    private func sheetTitle(for item: LexiconTappableItem) -> String {
        switch item.type {
        case .strongs(let ref):
            return ref
        case .verseRef(let display, _, _, let fullRef):
            let ref = fullRef ?? display
            return ref.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        case .bdbRef(let bdbId):
            return bdbId
        case .lexiconRef(let lexiconId):
            return lexiconId
        }
    }

    private func sheetNavigateAction(for item: LexiconTappableItem) -> (() -> Void)? {
        switch item.type {
        case .strongs(let ref):
            if let onSearch = onSearchStrongs {
                return { onSearch(ref) }
            }
        case .verseRef(_, let verseId, _, _):
            if let onNavigate = onNavigateToVerse {
                return { onNavigate(verseId) }
            }
        case .bdbRef:
            return nil  // BDB entries don't have external navigation
        case .lexiconRef:
            return nil  // Lexicon entries don't have external navigation yet
        }
        return nil
    }
}

struct LinkedDefinitionText: View {
    let text: String
    let font: Font
    var fontSize: CGFloat? = nil  // Explicit font size (for UIKit rendering)
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var references: [VerseRef]? = nil
    var isCurrentPage: Bool = true

    // Base offset for indexing (global index for cross-segment navigation)
    var baseOffset: Int = 0

    // Shared state for cross-segment navigation (optional)
    // When provided, this view contributes to shared navigation instead of standalone
    var sharedSheetState: Binding<LexiconSheetState?>? = nil
    var sharedAllItems: Binding<[LexiconTappableItem]>? = nil

    // Search terms to highlight
    var searchTerms: [String] = []

    // Whether this view should report its first match offset for scroll-to-match
    var shouldReportMatchOffset: Bool = false
    var scrollCoordinateSpace: String = "lexiconScroll"

    // Track local state (used only when shared state is not provided)
    @State private var tappableItems: [TappableItem] = []
    @State private var localSheetState: SheetState? = nil
    @State private var localMatchOffset: CGFloat? = nil  // Local Y offset of first match within text view

    // Use shared state if available, otherwise local
    private var effectiveSheetState: Binding<SheetState?> {
        if let shared = sharedSheetState {
            return shared
        }
        return $localSheetState
    }

    private func displayTitle(for fullRef: String?, display: String) -> String {
        let ref = fullRef ?? display
        return ref.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    private func navigateToPrev() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withPrev() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    private func navigateToNext() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withNext() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    var body: some View {
        // isCurrentPage is now debounced at parent level - only true when swipe finishes
        if isCurrentPage {
            LinkedTextView(
                text: text,
                font: font,
                fontSize: fontSize,
                references: references,
                baseOffset: baseOffset,
                searchTerms: searchTerms,
                shouldReportMatchOffset: shouldReportMatchOffset,
                onLinkTap: { index in
                    // Find the tapped item
                    if let item = tappableItems.first(where: { $0.index == index }) {
                        // Use shared items if available, otherwise local items
                        let allItems = sharedAllItems?.wrappedValue ?? tappableItems
                        effectiveSheetState.wrappedValue = SheetState(currentItem: item, allItems: allItems)
                    }
                },
                onItemsParsed: { items in
                    tappableItems = items
                    // Update shared items if using shared state
                    if let sharedItems = sharedAllItems {
                        // Remove old items from this segment and add new ones
                        let otherItems = sharedItems.wrappedValue.filter { item in
                            item.index < baseOffset || item.index >= baseOffset + items.count
                        }
                        sharedItems.wrappedValue = (otherItems + items).sorted { $0.index < $1.index }
                    }
                },
                onFirstMatchOffset: shouldReportMatchOffset ? { offset in
                    localMatchOffset = offset
                } : nil
            )
            // Report absolute match offset via preference when we have both local offset and geometry
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: FirstMatchOffsetPreferenceKey.self,
                            value: shouldReportMatchOffset && localMatchOffset != nil
                                ? geometry.frame(in: .named(scrollCoordinateSpace)).minY + (localMatchOffset ?? 0)
                                : nil
                        )
                }
            )
            // Only show sheet locally if not using shared state
            .sheet(item: sharedSheetState == nil ? $localSheetState : .constant(nil)) { state in
                sheetContent(state: state)
                    .presentationDetents([.fraction(0.3), .medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.scrolls)
            }
        }
        // No placeholder - parent view handles loading state
    }

    @ViewBuilder
    private func sheetContent(state: SheetState) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                LexiconSheetItemContent(
                    itemType: item.type,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse
                )
                .padding()
            }
            .navigationTitle(sheetTitle(for: item))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        effectiveSheetState.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let navigateAction = sheetNavigateAction(for: item) {
                        Button {
                            navigateAction()
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button(action: navigateToPrev) {
                            Image(systemName: "chevron.left")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.allItems.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button(action: navigateToNext) {
                            Image(systemName: "chevron.right")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
    }

    private func sheetTitle(for item: TappableItem) -> String {
        switch item.type {
        case .strongs(let ref):
            return ref
        case .verseRef(let display, _, _, let fullRef):
            return displayTitle(for: fullRef, display: display)
        case .bdbRef(let bdbId):
            return bdbId
        case .lexiconRef(let lexiconId):
            return lexiconId
        }
    }

    private func sheetNavigateAction(for item: TappableItem) -> (() -> Void)? {
        switch item.type {
        case .strongs:
            return nil  // Strong's entries don't navigate
        case .verseRef(_, let verseId, _, _):
            guard onNavigateToVerse != nil else { return nil }
            return {
                effectiveSheetState.wrappedValue = nil
                onNavigateToVerse?(verseId)
            }
        case .bdbRef:
            return nil  // BDB entries don't navigate externally
        case .lexiconRef:
            return nil  // Lexicon entries don't navigate externally
        }
    }

}

/// Popover view for BDB cross-references
/// Unified content view for lexicon sheet items (Strong's, verse refs, BDB refs)
/// Used consistently across all sheet contexts for uniform styling
private struct LexiconSheetItemContent: View {
    let itemType: LexiconTappableItem.TappableItemType
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    private var userSettings: UserSettings {
        UserDatabase.shared.getSettings()
    }

    /// Base font size at 90% of user's reader font size
    private var baseFontSize: CGFloat {
        CGFloat(userSettings.readerFontSize) * 0.85
    }

    // Scaled fonts (matching LexiconEntryView +5% scaling)
    private var titleFont: Font { .system(size: baseFontSize * 1.47) }
    private var headlineFont: Font { .system(size: baseFontSize * 1.155) }
    private var bodyFont: Font { .system(size: baseFontSize * 1.024) }
    private var subheadlineFont: Font { .system(size: baseFontSize * 0.924) }
    private var captionFont: Font { .system(size: baseFontSize * 0.798) }
    private var caption2Font: Font { .system(size: baseFontSize * 0.735) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch itemType {
            case .strongs(let ref):
                StrongsRefContent(
                    strongsNum: ref,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    baseFontSize: baseFontSize
                )

            case .verseRef(let display, let verseId, let endVerseId, let fullRef):
                VerseRefContent(
                    display: display,
                    verseId: verseId,
                    endVerseId: endVerseId,
                    fullRef: fullRef,
                    translationId: translationId,
                    onNavigate: onNavigateToVerse != nil ? { onNavigateToVerse?(verseId) } : nil,
                    baseFontSize: baseFontSize
                )

            case .bdbRef(let bdbId):
                BDBRefContent(
                    bdbId: bdbId,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    baseFontSize: baseFontSize
                )

            case .lexiconRef(let lexiconId):
                LexiconRefContent(
                    lexiconId: lexiconId,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    baseFontSize: baseFontSize
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Strong's reference content for sheet display
private struct StrongsRefContent: View {
    let strongsNum: String
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var baseFontSize: CGFloat = 17

    @State private var hitCount: Int? = nil

    // Scaled fonts
    private var titleFont: Font { .system(size: baseFontSize * 1.47) }
    private var subheadlineFont: Font { .system(size: baseFontSize * 0.924) }
    private var bodyFont: Font { .system(size: baseFontSize * 1.024) }
    private var caption2Font: Font { .system(size: baseFontSize * 0.735) }

    private func loadHitCount() {
        guard let transId = translationId else { return }
        // Search for Strong's number in annotations_json using GRDB
        hitCount = (try? TranslationDatabase.shared.countStrongsOccurrences(
            translationId: transId,
            strongsNum: strongsNum
        )) ?? 0
    }

    var body: some View {
        let entries = LexiconLookup.allEntries(for: strongsNum)

        if let entry = entries.first {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(alignment: .center, spacing: 8) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(entry.lemma)
                            .font(titleFont)
                        if let homographNum = LexiconLookup.homographLabel(entry.homograph) {
                            Text(homographNum)
                                .font(subheadlineFont)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(entry.strongsId)
                        .font(subheadlineFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())

                    if let bdbId = entry.bdbId {
                        Text(bdbId)
                            .font(subheadlineFont)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if let onSearch = onSearchStrongs, let count = hitCount, count > 0 {
                        Button {
                            onSearch(entry.strongsId)
                        } label: {
                            HStack(spacing: 1) {
                                Image(systemName: "magnifyingglass")
                                    .font(caption2Font)
                                Text(entry.bdbId != nil ? "\(count)x (Strong's)" : "\(count)x")
                            }
                            .font(subheadlineFont)
                            .foregroundStyle(.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let xlit = entry.xlit, !xlit.isEmpty {
                    Text(xlit)
                        .font(subheadlineFont)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                if let def = entry.def, !def.isEmpty {
                    LinkedDefinitionText(
                        text: def,
                        font: bodyFont,
                        fontSize: baseFontSize * 1.024,
                        translationId: translationId,
                        onSearchStrongs: onSearchStrongs,
                        onNavigateToVerse: onNavigateToVerse
                    )
                }
            }
            .onAppear { loadHitCount() }
        } else {
            Text("Entry not found: \(strongsNum)")
                .foregroundStyle(.secondary)
        }
    }
}

/// Verse reference content for sheet display
private struct VerseRefContent: View {
    let display: String
    let verseId: Int
    let endVerseId: Int?
    let fullRef: String?
    var translationId: String? = nil
    var onNavigate: (() -> Void)? = nil
    var baseFontSize: CGFloat = 17

    // Scaled fonts
    private var bodyFont: Font { .system(size: baseFontSize * 1.024) }
    private var captionFont: Font { .system(size: baseFontSize * 0.798) }

    private var verses: [TranslationVerse] {
        guard let transId = translationId else { return [] }
        let startId = verseId
        let endId = endVerseId ?? verseId
        return (try? TranslationDatabase.shared.getVerseRange(
            translationId: transId,
            startRef: startId,
            endRef: endId
        )) ?? []
    }

    private var versesText: AttributedString {
        if verses.isEmpty {
            var notFound = AttributedString("Verse not found")
            notFound.foregroundColor = .secondary
            return notFound
        }

        var result = AttributedString()
        for (index, verse) in verses.enumerated() {
            var verseNum = AttributedString("\(verse.verse)")
            verseNum.font = captionFont
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4

            var text = AttributedString(" " + verse.text)
            text.font = bodyFont

            result.append(verseNum)
            result.append(text)

            if index < verses.count - 1 {
                result.append(AttributedString("  "))
            }
        }
        return result
    }

    var body: some View {
        Text(versesText)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// BDB reference content for sheet display
private struct BDBRefContent: View {
    let bdbId: String
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var baseFontSize: CGFloat = 17

    var body: some View {
        if let entry = LexiconLookup.lookupBDB(bdbId) {
            let senses = parseUserSensesStatic(entry.sensesJson)
            LexiconEntryView(
                entry: entry,
                senses: senses,
                translationId: translationId,
                onSearchStrongs: onSearchStrongs,
                onNavigateToVerse: onNavigateToVerse,
                baseFontSize: baseFontSize
            )
        } else {
            Text("BDB entry not found: \(bdbId)")
                .foregroundStyle(.secondary)
        }
    }
}

/// Lexicon cross-reference content for sheet display (user dictionary entries)
private struct LexiconRefContent: View {
    let lexiconId: String
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var baseFontSize: CGFloat = 17

    var body: some View {
        if let entry = LexiconLookup.lookupUserDictionary(lexiconId) {
            let senses = parseUserSensesStatic(entry.sensesJson)
            LexiconEntryView(
                entry: entry,
                senses: senses,
                translationId: translationId,
                onSearchStrongs: onSearchStrongs,
                onNavigateToVerse: onNavigateToVerse,
                baseFontSize: baseFontSize
            )
        } else {
            Text("Lexicon entry not found: \(lexiconId)")
                .foregroundStyle(.secondary)
        }
    }
}

// Legacy wrapper for backward compatibility (popover contexts)
private struct BDBPopoverForRef: View {
    let bdbId: String
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    var body: some View {
        BDBRefContent(
            bdbId: bdbId,
            translationId: translationId,
            onSearchStrongs: onSearchStrongs,
            onNavigateToVerse: onNavigateToVerse
        )
    }
}

/// Custom attribute key for tappable item index
private let TappableIndexAttributeKey = NSAttributedString.Key("tappableIndex")

/// UIKit UITextView wrapper using TextKit 1 for proper text wrapping and link handling
private struct LinkedTextView: UIViewRepresentable {
    let text: String
    let font: Font
    let fontSize: CGFloat?  // Explicit font size (preferred over deriving from Font)
    let references: [VerseRef]?
    let baseOffset: Int
    let searchTerms: [String]  // Search terms to highlight with yellow background
    var shouldReportMatchOffset: Bool = false  // Whether to report first match offset for scrolling
    let onLinkTap: (Int) -> Void
    let onItemsParsed: ([TappableItem]) -> Void
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil  // Callback to report first match Y offset

    func makeUIView(context: Context) -> TappableTextView {
        let textView = TappableTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.onTappableIndexTap = context.coordinator.handleTap
        return textView
    }

    func updateUIView(_ textView: TappableTextView, context: Context) {
        // Only update if text or search terms changed
        if context.coordinator.lastText != text || context.coordinator.lastSearchTerms != searchTerms {
            context.coordinator.lastText = text
            context.coordinator.lastSearchTerms = searchTerms
            let (attrString, items) = buildAttributedString()
            textView.attributedText = attrString
            context.coordinator.onLinkTap = onLinkTap
            textView.invalidateIntrinsicContentSize()

            DispatchQueue.main.async {
                onItemsParsed(items)
            }
        }

        // Report first match offset if requested
        if shouldReportMatchOffset, let callback = onFirstMatchOffset, !searchTerms.isEmpty {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()
                if let matchRange = self.findFirstMatchRange(in: text) {
                    // Calculate rect for the match
                    if let start = textView.position(from: textView.beginningOfDocument, offset: matchRange.location),
                       let end = textView.position(from: start, offset: matchRange.length),
                       let textRange = textView.textRange(from: start, to: end) {
                        let rect = textView.firstRect(for: textRange)
                        if !rect.isNull && !rect.isInfinite {
                            callback(rect.origin.y)
                        }
                    }
                }
            }
        }
    }

    /// Find the first match range in the text
    private func findFirstMatchRange(in content: String) -> NSRange? {
        let contentLower = content.lowercased()
        var earliestRange: NSRange? = nil
        for term in searchTerms {
            let termLower = term.lowercased()
            if let range = contentLower.range(of: termLower) {
                let nsRange = NSRange(range, in: content)
                if earliestRange == nil || nsRange.location < earliestRange!.location {
                    earliestRange = nsRange
                }
            }
        }
        return earliestRange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    private func buildAttributedString() -> (NSAttributedString, [TappableItem]) {
        let segments = references != nil
            ? parseLinkedTextWithReferences(text, references: references)
            : parseLinkedTextSegments(text)

        let result = NSMutableAttributedString()
        var tappableItems: [TappableItem] = []
        var popoverIndex = baseOffset
        // Use explicit fontSize if provided, otherwise derive from Font
        let effectiveFontSize = fontSize ?? fontPointSize(from: font)
        let uiFont = UIFont.systemFont(ofSize: effectiveFontSize)

        // Add paragraph style for better line/paragraph spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = effectiveFontSize * 0.4  // 40% of font size
        paragraphStyle.paragraphSpacing = effectiveFontSize * 0.5  // 50% of font size between paragraphs
        // Force LTR base direction to prevent RTL Hebrew from reordering mixed content
        paragraphStyle.baseWritingDirection = .leftToRight

        for segment in segments {
            switch segment {
            case .text(let str):
                result.append(NSAttributedString(string: str, attributes: [
                    .font: uiFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraphStyle
                ]))

            case .strongs(let ref):
                result.append(NSAttributedString(string: ref, attributes: [
                    .font: uiFont,
                    .foregroundColor: UIColor.tintColor,
                    .paragraphStyle: paragraphStyle,
                    TappableIndexAttributeKey: popoverIndex
                ]))
                tappableItems.append(TappableItem(index: popoverIndex, type: .strongs(ref)))
                popoverIndex += 1

            case .verseRef(let display, let verseId, let endVerseId, let fullRef):
                result.append(NSAttributedString(string: display, attributes: [
                    .font: uiFont,
                    .foregroundColor: UIColor.tintColor,
                    .paragraphStyle: paragraphStyle,
                    TappableIndexAttributeKey: popoverIndex
                ]))
                tappableItems.append(TappableItem(index: popoverIndex, type: .verseRef(display: display, verseId: verseId, endVerseId: endVerseId, fullRef: fullRef)))
                popoverIndex += 1

            case .bdbRef(let bdbId):
                result.append(NSAttributedString(string: bdbId, attributes: [
                    .font: uiFont,
                    .foregroundColor: UIColor.tintColor,
                    .paragraphStyle: paragraphStyle,
                    TappableIndexAttributeKey: popoverIndex
                ]))
                tappableItems.append(TappableItem(index: popoverIndex, type: .bdbRef(bdbId)))
                popoverIndex += 1
            }
        }

        // Apply search term highlighting with yellow background
        if !searchTerms.isEmpty {
            let fullString = result.string
            let fullStringLower = fullString.lowercased()

            for term in searchTerms {
                let termLower = term.lowercased()
                var searchStartIndex = fullStringLower.startIndex

                while let range = fullStringLower.range(of: termLower, range: searchStartIndex..<fullStringLower.endIndex) {
                    let nsRange = NSRange(range, in: fullString)
                    result.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.4), range: nsRange)
                    searchStartIndex = range.upperBound
                }
            }
        }

        return (result, tappableItems)
    }

    private func fontPointSize(from font: Font) -> CGFloat {
        switch font {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }

    class Coordinator {
        var onLinkTap: (Int) -> Void
        var lastText: String = ""
        var lastSearchTerms: [String] = []

        init(onLinkTap: @escaping (Int) -> Void) {
            self.onLinkTap = onLinkTap
        }

        func handleTap(_ index: Int) {
            onLinkTap(index)
        }
    }
}

/// Custom UITextView subclass using TextKit 1 with tap handling
private class TappableTextView: UITextView {
    var onTappableIndexTap: ((Int) -> Void)?

    // Use TextKit 1
    private let textKit1LayoutManager = NSLayoutManager()
    private let textKit1TextContainer = NSTextContainer()
    private let textKit1TextStorage = NSTextStorage()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        // Set up TextKit 1 stack
        textKit1TextStorage.addLayoutManager(textKit1LayoutManager)
        textKit1LayoutManager.addTextContainer(textKit1TextContainer)
        textKit1TextContainer.widthTracksTextView = true
        textKit1TextContainer.heightTracksTextView = false

        super.init(frame: frame, textContainer: textKit1TextContainer)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        // Adjust for text container inset
        let textContainerOffset = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        let locationInTextContainer = CGPoint(
            x: location.x - textContainerOffset.x,
            y: location.y - textContainerOffset.y
        )

        // Get character index at tap location
        let characterIndex = textKit1LayoutManager.characterIndex(
            for: locationInTextContainer,
            in: textKit1TextContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard characterIndex < textKit1TextStorage.length else { return }

        let attributes = textKit1TextStorage.attributes(at: characterIndex, effectiveRange: nil)
        if let tappableIndex = attributes[TappableIndexAttributeKey] as? Int {
            onTappableIndexTap?(tappableIndex)
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

// MARK: - Annotated Definition Text View (v2.0 Schema Support)

/// UIKit-based view for rendering v2.0 annotated text with sheet integration
/// Uses CommentaryRenderer for attributed string generation, with tappable items for sheet navigation
private struct AnnotatedDefinitionTextView: UIViewRepresentable {
    let annotatedText: AnnotatedText
    let fontSize: CGFloat
    let baseOffset: Int
    let searchTerms: [String]
    var shouldReportMatchOffset: Bool = false  // Whether to report first match offset for scrolling
    let onLinkTap: (Int) -> Void
    let onItemsParsed: ([TappableItem]) -> Void
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil  // Callback to report first match Y offset

    func makeUIView(context: Context) -> TappableTextView {
        let textView = TappableTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.onTappableIndexTap = context.coordinator.handleTap
        return textView
    }

    func updateUIView(_ textView: TappableTextView, context: Context) {
        // Only update if text or search terms changed
        let textId = "\(annotatedText.text.hashValue)_\(fontSize)"
        if context.coordinator.lastTextId != textId || context.coordinator.lastSearchTerms != searchTerms {
            context.coordinator.lastTextId = textId
            context.coordinator.lastSearchTerms = searchTerms
            let (attrString, items) = buildAttributedString()
            textView.attributedText = attrString
            context.coordinator.onLinkTap = onLinkTap
            textView.invalidateIntrinsicContentSize()

            DispatchQueue.main.async {
                onItemsParsed(items)
            }
        }

        // Report first match offset if requested
        if shouldReportMatchOffset, let callback = onFirstMatchOffset, !searchTerms.isEmpty {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()
                if let matchRange = self.findFirstMatchRange(in: annotatedText.text) {
                    // Calculate rect for the match
                    if let start = textView.position(from: textView.beginningOfDocument, offset: matchRange.location),
                       let end = textView.position(from: start, offset: matchRange.length),
                       let textRange = textView.textRange(from: start, to: end) {
                        let rect = textView.firstRect(for: textRange)
                        if !rect.isNull && !rect.isInfinite {
                            callback(rect.origin.y)
                        }
                    }
                }
            }
        }
    }

    /// Find the first match range in the text
    private func findFirstMatchRange(in content: String) -> NSRange? {
        let contentLower = content.lowercased()
        var earliestRange: NSRange? = nil
        for term in searchTerms {
            let termLower = term.lowercased()
            if let range = contentLower.range(of: termLower) {
                let nsRange = NSRange(range, in: content)
                if earliestRange == nil || nsRange.location < earliestRange!.location {
                    earliestRange = nsRange
                }
            }
        }
        return earliestRange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let constraintSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let fittingSize = uiView.sizeThatFits(constraintSize)
        return CGSize(width: width, height: fittingSize.height)
    }

    private func buildAttributedString() -> (NSAttributedString, [TappableItem]) {
        var tappableItems: [TappableItem] = []
        var itemIndex = baseOffset

        // Use CommentaryRenderer style
        let style = CommentaryRenderer.Style(
            uiBodyFont: UIFont.systemFont(ofSize: fontSize),
            scriptureColor: .blue,
            strongsColor: .purple,
            footnoteColor: Color.secondary,
            abbreviationColor: Color.secondary
        )

        // Get the base attributed string from CommentaryRenderer
        let baseAttrString = CommentaryRenderer.renderUIKit(annotatedText, style: style)
        let mutableAttrString = NSMutableAttributedString(attributedString: baseAttrString)

        // Add tappable index attributes and collect items
        if let annotations = annotatedText.annotations {
            for annotation in annotations {
                guard annotation.start >= 0, annotation.start < annotation.end else { continue }

                // Create tappable item based on annotation type
                let tappableType: TappableItem.TappableItemType?
                switch annotation.type {
                case .strongs:
                    let strongsNum = annotation.data?.strongs ?? annotation.id ?? ""
                    if !strongsNum.isEmpty {
                        tappableType = .strongs(strongsNum)
                    } else {
                        tappableType = nil
                    }
                case .scripture:
                    if let sv = annotation.data?.sv {
                        let display = annotation.text ?? String(annotatedText.text.dropFirst(annotation.start).prefix(annotation.end - annotation.start))
                        tappableType = .verseRef(display: display, verseId: sv, endVerseId: annotation.data?.ev, fullRef: nil)
                    } else {
                        tappableType = nil
                    }
                case .lexiconRef:
                    let lexiconId = annotation.data?.lexiconId ?? annotation.id ?? ""
                    if !lexiconId.isEmpty {
                        tappableType = .lexiconRef(lexiconId)
                    } else {
                        tappableType = nil
                    }
                default:
                    tappableType = nil
                }

                if let itemType = tappableType {
                    tappableItems.append(TappableItem(index: itemIndex, type: itemType))

                    // Add tappable index attribute to the range
                    let nsRange = NSRange(location: annotation.start, length: annotation.end - annotation.start)
                    if nsRange.location + nsRange.length <= mutableAttrString.length {
                        mutableAttrString.addAttribute(TappableIndexAttributeKey, value: itemIndex, range: nsRange)
                    }

                    itemIndex += 1
                }
            }
        }

        // Apply search term highlighting with yellow background
        if !searchTerms.isEmpty {
            let fullString = mutableAttrString.string
            let fullStringLower = fullString.lowercased()

            for term in searchTerms {
                let termLower = term.lowercased()
                var searchStartIndex = fullStringLower.startIndex

                while let range = fullStringLower.range(of: termLower, range: searchStartIndex..<fullStringLower.endIndex) {
                    let nsRange = NSRange(range, in: fullString)
                    mutableAttrString.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.4), range: nsRange)
                    searchStartIndex = range.upperBound
                }
            }
        }

        return (mutableAttrString, tappableItems)
    }

    class Coordinator {
        var onLinkTap: (Int) -> Void
        var lastTextId: String = ""
        var lastSearchTerms: [String] = []

        init(onLinkTap: @escaping (Int) -> Void) {
            self.onLinkTap = onLinkTap
        }

        func handleTap(_ index: Int) {
            onLinkTap(index)
        }
    }
}

// MARK: - Lexicon Entry Data

struct LexiconEntry: Identifiable {
    let id: String  // e.g., "H1-strongs" or "G18-dodson" or "BDB871-bdb"
    let strongsId: String
    let lemma: String
    let xlit: String?
    let pron: String?
    let def: String?
    let kjv: String?
    let deriv: String?
    let lexiconKey: String  // "strongs", "bdb", "dodson"
    let lexiconName: String  // Display name

    // Extended fields (used by BDB and user dictionaries)
    let pos: String?  // Part of speech
    let gloss: String?  // Short gloss/meaning
    let sensesJson: String?  // Full senses data as JSON (DictionarySense schema for all dictionaries)
    let referencesJson: String?  // Verse references as JSON [{"sv": verseId, "ev": endVerseId}]

    // BDB-specific fields
    let bdbId: String?  // BDB entry ID (e.g., "BDB871")
    let homograph: Int?  // Homograph number for display as Roman numeral (1=I, 2=II, etc.)

    init(
        id: String,
        strongsId: String,
        lemma: String,
        xlit: String? = nil,
        pron: String? = nil,
        def: String? = nil,
        kjv: String? = nil,
        deriv: String? = nil,
        lexiconKey: String,
        lexiconName: String,
        pos: String? = nil,
        gloss: String? = nil,
        sensesJson: String? = nil,
        referencesJson: String? = nil,
        bdbId: String? = nil,
        homograph: Int? = nil
    ) {
        self.id = id
        self.strongsId = strongsId
        self.lemma = lemma
        self.xlit = xlit
        self.pron = pron
        self.def = def
        self.kjv = kjv
        self.deriv = deriv
        self.lexiconKey = lexiconKey
        self.lexiconName = lexiconName
        self.pos = pos
        self.gloss = gloss
        self.sensesJson = sensesJson
        self.referencesJson = referencesJson
        self.bdbId = bdbId
        self.homograph = homograph
    }
}

// MARK: - Lexicon Entry Display

struct LexiconEntryView: View {
    let entry: LexiconEntry
    // Pre-parsed senses passed from parent (BDB and user dictionaries use same format)
    let senses: [DictionarySense]
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var baseFontSize: CGFloat = 17  // Base font size (scaled from user's reader font size)
    var hitCount: Int? = nil  // Number of occurrences in the translation
    var isCurrentPage: Bool = true
    var searchTerms: [String] = []  // Search terms to highlight

    // Shared state for cross-segment navigation
    var baseOffset: Int = 0
    var sharedSheetState: Binding<LexiconSheetState?>? = nil
    var sharedAllItems: Binding<[LexiconTappableItem]>? = nil

    // Scroll-to-match support: which sense/field should report its match offset
    var reportMatchForSense: Int? = nil  // Sense index (0-based) that should report
    var reportMatchForField: String? = nil  // Field name within that sense
    var scrollCoordinateSpace: String = "lexiconScroll"

    // Scaled fonts relative to base size
    private var titleFont: Font { .system(size: baseFontSize * 1.4) }  // ~title2 (+5%)
    private var headlineFont: Font { .system(size: baseFontSize * 1.155) }  // ~headline (+5%)
    private var bodyFont: Font { .system(size: baseFontSize) }  // definition text (+5%)
    private var calloutFont: Font { .system(size: baseFontSize * 0.987) }  // ~callout (+5%)
    private var subheadlineFont: Font { .system(size: baseFontSize * 0.924) }  // ~subheadline (+5%)
    private var captionFont: Font { .system(size: baseFontSize * 0.798) }  // ~caption (+5%)
    private var caption2Font: Font { .system(size: baseFontSize * 0.735) }  // ~caption2 (+5%)

    /// True if this entry has multiple senses
    private var hasSenses: Bool {
        !senses.isEmpty
    }

    /// Parse top-level references from referencesJson for annotated text linking
    private var topLevelReferences: [VerseRef]? {
        guard let json = entry.referencesJson, !json.isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([VerseRef].self, from: data)
    }

    /// Count items in the top-level definition for offset calculation
    private var topLevelDefItemCount: Int {
        guard let def = entry.def, !def.isEmpty, !hasSenses else { return 0 }
        return countPopoverItemsInText(def, references: topLevelReferences)
    }

    /// Part of speech lifted from first sense (when only first sense has POS)
    private var liftedPartOfSpeech: String? {
        guard hasSenses else { return nil }

        // Check if only the first sense has a non-empty POS
        guard let firstPos = senses.first?.partOfSpeech, !firstPos.isEmpty else { return nil }

        // Verify no other senses have a POS
        let otherSensesHavePos = senses.dropFirst().contains {
            if let pos = $0.partOfSpeech, !pos.isEmpty { return true }
            return false
        }

        return otherSensesHavePos ? nil : firstPos
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Lemma (with optional homograph Roman numeral) and ID
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(entry.lemma)
                        .font(titleFont)
                    // Show homograph Roman numeral for BDB entries
                    if let homographNum = LexiconLookup.homographLabel(entry.homograph) {
                        Text(homographNum)
                            .font(subheadlineFont)
                            .foregroundStyle(.secondary)
                    }
                }

                // Strong's ID badge (no search button)
                if !entry.strongsId.isEmpty {
                    Text(entry.strongsId)
                        .font(subheadlineFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                // BDB ID badge (when available)
                if let bdbId = entry.bdbId {
                    Text(bdbId)
                        .font(subheadlineFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Separate search button with occurrence count
                if let onSearch = onSearchStrongs, let count = hitCount, count > 0 {
                    Button {
                        onSearch(entry.strongsId)
                    } label: {
                        HStack(spacing: 1) {
                            Image(systemName: "magnifyingglass")
                                .font(captionFont)
                            // Show "(Strong's)" suffix when BDB ID is also shown to clarify what's being searched
                            Text(entry.bdbId != nil ? "\(count)x (Strong's)" : "\(count)x")
                        }
                        .font(subheadlineFont)
                        .foregroundStyle(.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Lexicon source
            Text(entry.lexiconName)
                .font(caption2Font)
                .foregroundStyle(.tertiary)

            // Transliteration + part of speech
            if let xlit = entry.xlit, !xlit.isEmpty {
                HStack(spacing: 6) {
                    Text(xlit)
                        .font(subheadlineFont)
                        .italic()
                        .foregroundStyle(.secondary)
                    if let pos = entry.pos ?? liftedPartOfSpeech, !pos.isEmpty {
                        Text("·")
                            .font(subheadlineFont)
                            .foregroundStyle(.tertiary)
                        Text(pos)
                            .font(subheadlineFont)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
            } else if let pos = entry.pos ?? liftedPartOfSpeech, !pos.isEmpty {
                // Show POS even without transliteration
                Text(pos)
                    .font(subheadlineFont)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if let pron = entry.pron, !pron.isEmpty, pron != entry.xlit {
                Text(pron)
                    .font(captionFont)
                    .foregroundStyle(.tertiary)
            }

            // Gloss (short meaning) - show if no senses and no top-level definition
            if let gloss = entry.gloss, !gloss.isEmpty, !hasSenses, entry.def == nil {
                LinkedDefinitionText(
                    text: gloss,
                    font: bodyFont,
                    fontSize: baseFontSize,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    isCurrentPage: isCurrentPage,
                    searchTerms: searchTerms,
                    shouldReportMatchOffset: reportMatchForSense == nil && reportMatchForField == "entry-gloss",
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
                .id("\(entry.id)-entry-gloss")
            }

            // Top-level definition (for entries without multiple senses)
            if let def = entry.def, !def.isEmpty, !hasSenses {
                LinkedDefinitionText(
                    text: def,
                    font: bodyFont,
                    fontSize: baseFontSize,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    references: topLevelReferences,
                    isCurrentPage: isCurrentPage,
                    baseOffset: baseOffset,
                    sharedSheetState: sharedSheetState,
                    sharedAllItems: sharedAllItems,
                    searchTerms: searchTerms,
                    shouldReportMatchOffset: reportMatchForSense == nil && reportMatchForField == "entry-def",
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
                .id("\(entry.id)-entry-def")
            }

            // Senses (BDB and user dictionaries use same format)
            if hasSenses {
                // Pre-compute offsets for each sense
                let senseOffsets = senses.enumerated().reduce(into: [Int: Int]()) { result, item in
                    let (index, _) = item
                    if index == 0 {
                        result[index] = baseOffset + topLevelDefItemCount
                    } else {
                        let prevSense = senses[index - 1]
                        result[index] = (result[index - 1] ?? 0) + countPopoverItemsInSense(prevSense)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Senses")
                        .font(captionFont)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(senses.enumerated()), id: \.offset) { index, sense in
                            UserDictionarySenseView(
                                sense: sense,
                                senseNumber: index + 1,
                                entryId: entry.id,
                                hidePartOfSpeech: index == 0 && liftedPartOfSpeech != nil,
                                baseFontSize: baseFontSize,
                                translationId: translationId,
                                onSearchStrongs: onSearchStrongs,
                                onNavigateToVerse: onNavigateToVerse,
                                isCurrentPage: isCurrentPage,
                                searchTerms: searchTerms,
                                baseOffset: senseOffsets[index] ?? 0,
                                sharedSheetState: sharedSheetState,
                                sharedAllItems: sharedAllItems,
                                reportMatchForField: reportMatchForSense == index ? reportMatchForField : nil,
                                scrollCoordinateSpace: scrollCoordinateSpace
                            )
                            .id("\(entry.id)-sense-\(index)")

                            if index < senses.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }

            // KJV Usage - only show for single-sense entries
            if let kjv = entry.kjv, !kjv.isEmpty, !hasSenses {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KJV Usage")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                    Text(kjv)
                        .font(captionFont)
                        .foregroundStyle(.primary)
                }
                .padding(.top, 4)
                .id("\(entry.id)-entry-kjv")
            }

            // Derivation - only show for single-sense entries
            if let deriv = entry.deriv, !deriv.isEmpty, !hasSenses {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Derivation")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                    LinkedDefinitionText(
                        text: deriv,
                        font: captionFont,
                        fontSize: baseFontSize * 0.798,
                        translationId: translationId,
                        onSearchStrongs: onSearchStrongs,
                        onNavigateToVerse: onNavigateToVerse,
                        isCurrentPage: isCurrentPage,
                        searchTerms: searchTerms,
                        shouldReportMatchOffset: reportMatchForSense == nil && reportMatchForField == "entry-deriv",
                        scrollCoordinateSpace: scrollCoordinateSpace
                    )
                }
                .id("\(entry.id)-entry-deriv")
            }
        }
    }
}

// MARK: - Sense View (used by BDB and user dictionaries)

struct UserDictionarySenseView: View {
    let sense: DictionarySense
    let senseNumber: Int
    var entryId: String = ""  // Entry ID for generating field-specific scroll IDs
    var hidePartOfSpeech: Bool = false  // True when POS was lifted to top level
    var baseFontSize: CGFloat = 17
    var translationId: String? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var isCurrentPage: Bool = true
    var searchTerms: [String] = []  // Search terms to highlight

    // Shared state for cross-segment navigation
    var baseOffset: Int = 0
    var sharedSheetState: Binding<LexiconSheetState?>? = nil
    var sharedAllItems: Binding<[LexiconTappableItem]>? = nil

    // Scroll-to-match support: which field (if any) should report its match offset
    var reportMatchForField: String? = nil  // "gloss", "definition", "usage", "derivation", or "translationUsage-{version}"
    var scrollCoordinateSpace: String = "lexiconScroll"

    // Sense index (0-based) for scroll ID generation
    private var senseIndex: Int { senseNumber - 1 }

    // Scaled fonts
    private var bodyFont: Font { .system(size: baseFontSize) }  // definition text (+5%)
    private var calloutFont: Font { .system(size: baseFontSize * 0.987) }  // (+5%)
    private var subheadlineFont: Font { .system(size: baseFontSize * 0.924) }  // (+5%)
    private var captionFont: Font { .system(size: baseFontSize * 0.798) }  // (+5%)
    private var caption2Font: Font { .system(size: baseFontSize * 0.735) }  // (+5%)

    // Count items in definition for offset calculation
    private var definitionItemCount: Int {
        guard let def = sense.definitionText, !def.isEmpty else { return 0 }
        return countPopoverItemsInText(def, references: sense.references)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                // Sense number
                Text("\(senseNumber).")
                    .font(bodyFont)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    // Part of speech (if present and not lifted to top level)
                    if !hidePartOfSpeech, let pos = sense.partOfSpeech, !pos.isEmpty {
                        Text(pos)
                            .font(calloutFont)
                            .italic()
                            .foregroundStyle(.tertiary)
                    }

                    // Gloss only (short definitions are subsets of full definition)
                    if let gloss = sense.gloss, !gloss.isEmpty {
                        LinkedDefinitionText(
                            text: gloss,
                            font: bodyFont,
                            fontSize: baseFontSize,
                            translationId: translationId,
                            onSearchStrongs: onSearchStrongs,
                            onNavigateToVerse: onNavigateToVerse,
                            isCurrentPage: isCurrentPage,
                            searchTerms: searchTerms,
                            shouldReportMatchOffset: reportMatchForField == "gloss",
                            scrollCoordinateSpace: scrollCoordinateSpace
                        )
                        .id("\(entryId)-sense-\(senseIndex)-gloss")
                    }

                    // Full definition - supports both v1.0 plain text and v2.0 annotated text
                    if sense.definition != nil {
                        DictionaryDefinitionView(
                            field: sense.definition,
                            font: bodyFont,
                            fontSize: baseFontSize,
                            translationId: translationId,
                            onSearchStrongs: onSearchStrongs,
                            onNavigateToVerse: onNavigateToVerse,
                            references: sense.references,
                            isCurrentPage: isCurrentPage,
                            baseOffset: baseOffset,
                            sharedSheetState: sharedSheetState,
                            sharedAllItems: sharedAllItems,
                            searchTerms: searchTerms,
                            shouldReportMatchOffset: reportMatchForField == "definition",
                            scrollCoordinateSpace: scrollCoordinateSpace
                        )
                        .id("\(entryId)-sense-\(senseIndex)-definition")
                    }

                    // Usage - plain text, no scroll-to-match needed (short field)
                    if let usage = sense.usage, !usage.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usage")
                                .font(caption2Font)
                                .foregroundStyle(.tertiary)
                            Text(usage)
                                .font(captionFont)
                                .foregroundStyle(.secondary)
                        }
                        .id("\(entryId)-sense-\(senseIndex)-usage")
                    }

                    // Derivation - may also contain Strong's refs
                    if sense.derivation != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Derivation")
                                .font(caption2Font)
                                .foregroundStyle(.tertiary)
                            DictionaryDefinitionView(
                                field: sense.derivation,
                                font: captionFont,
                                fontSize: baseFontSize * 0.798,
                                translationId: translationId,
                                onSearchStrongs: onSearchStrongs,
                                onNavigateToVerse: onNavigateToVerse,
                                isCurrentPage: isCurrentPage,
                                baseOffset: baseOffset + definitionItemCount,
                                sharedSheetState: sharedSheetState,
                                sharedAllItems: sharedAllItems,
                                searchTerms: searchTerms,
                                shouldReportMatchOffset: reportMatchForField == "derivation",
                                scrollCoordinateSpace: scrollCoordinateSpace
                            )
                        }
                        .id("\(entryId)-sense-\(senseIndex)-derivation")
                    }

                    // Translation usages from Bible versions
                    if let usages = sense.translationUsages, !usages.isEmpty {
                        ForEach(usages, id: \.version) { usage in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(usage.version) Usages")
                                    .font(caption2Font)
                                    .foregroundStyle(.tertiary)
                                LinkedDefinitionText(
                                    text: formatTranslationUsage(usage),
                                    font: captionFont,
                                    fontSize: baseFontSize * 0.798,
                                    translationId: translationId,
                                    onSearchStrongs: onSearchStrongs,
                                    onNavigateToVerse: onNavigateToVerse,
                                    isCurrentPage: isCurrentPage,
                                    searchTerms: searchTerms,
                                    shouldReportMatchOffset: reportMatchForField == "translationUsage-\(usage.version)",
                                    scrollCoordinateSpace: scrollCoordinateSpace
                                )
                                .foregroundStyle(.secondary)
                            }
                            .id("\(entryId)-sense-\(senseIndex)-translationUsage-\(usage.version)")
                        }
                    }
                }
            }
        }
    }

    /// Formats translation usage as comma-separated "word (count)" items
    private func formatTranslationUsage(_ usage: TranslationUsage) -> String {
        usage.translations.map { translation in
            if let count = translation.count {
                return "\(translation.word) (\(count))"
            } else {
                return translation.word
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Lexicon Lookup Helper

struct LexiconLookup {
    /// Returns all available lexicon entries for a Strong's number
    static func allEntries(for num: String) -> [LexiconEntry] {
        var entries: [LexiconEntry] = []
        let bundledDb = BundledModuleDatabase.shared

        if num.hasPrefix("H") {
            // Hebrew - Strong's Hebrew from bundled database
            if let entry = try? bundledDb.getDictionaryEntry(moduleId: "strongs_hebrew", key: num) {
                let senses = entry.senses
                let firstSense = senses.first
                entries.append(LexiconEntry(
                    id: "\(num)-strongs",
                    strongsId: num,
                    lemma: entry.lemma,
                    xlit: entry.transliteration,
                    pron: entry.pronunciation,
                    def: firstSense?.definition?.plainText,
                    kjv: firstSense?.usage,
                    deriv: firstSense?.derivation?.plainText,
                    lexiconKey: "strongs",
                    lexiconName: "Strong's Hebrew",
                    sensesJson: entry.sensesJson
                ))
            }
            // Look up BDB via lexicon mapping
            if let bdbIds = try? bundledDb.getLexiconMappings(sourceKey: num), !bdbIds.isEmpty {
                for bdbId in bdbIds {
                    if let bdbEntry = try? bundledDb.getDictionaryEntry(moduleId: "bdb", key: bdbId) {
                        let senses = bdbEntry.senses
                        let firstSense = senses.first
                        entries.append(LexiconEntry(
                            id: "\(bdbId)-bdb",
                            strongsId: num,
                            lemma: bdbEntry.lemma,
                            def: firstSense?.definition?.plainText,
                            lexiconKey: "bdb",
                            lexiconName: "Brown-Driver-Briggs",
                            pos: firstSense?.partOfSpeech,
                            gloss: firstSense?.gloss,
                            sensesJson: bdbEntry.sensesJson,
                            bdbId: bdbId
                        ))
                    }
                }
            }
        } else if num.hasPrefix("G") {
            // Greek - Strong's Greek from bundled database
            if let entry = try? bundledDb.getDictionaryEntry(moduleId: "strongs_greek", key: num) {
                let senses = entry.senses
                let firstSense = senses.first
                entries.append(LexiconEntry(
                    id: "\(num)-strongs",
                    strongsId: num,
                    lemma: entry.lemma,
                    xlit: entry.transliteration,
                    def: firstSense?.definition?.plainText,
                    kjv: firstSense?.usage,
                    deriv: firstSense?.derivation?.plainText,
                    lexiconKey: "strongs",
                    lexiconName: "Strong's Greek",
                    sensesJson: entry.sensesJson
                ))
            }
            // Dodson Greek from bundled database
            if let entry = try? bundledDb.getDictionaryEntry(moduleId: "dodson_greek", key: num) {
                let senses = entry.senses
                let firstSense = senses.first
                let definition = firstSense?.definition?.plainText ?? firstSense?.shortDefinition?.plainText
                entries.append(LexiconEntry(
                    id: "\(num)-dodson",
                    strongsId: num,
                    lemma: entry.lemma,
                    def: definition,
                    lexiconKey: "dodson",
                    lexiconName: "Dodson",
                    sensesJson: entry.sensesJson
                ))
            }
        }

        // Also check user dictionaries from SQLite
        entries.append(contentsOf: userDictionaryEntries(for: num))

        return entries
    }

    /// Look up entries in user dictionary modules
    private static func userDictionaryEntries(for num: String) -> [LexiconEntry] {
        var entries: [LexiconEntry] = []
        let database = ModuleDatabase.shared

        do {
            // Get all dictionary modules
            let modules = try database.getAllModules(type: .dictionary)

            for module in modules {
                // Look up entry by key (Strong's number)
                if let dictEntry = try database.getDictionaryEntry(moduleId: module.id, key: num) {
                    // Always pass sensesJson to ensure references are available for annotated parsing
                    entries.append(LexiconEntry(
                        id: "\(num)-user-\(module.id)",
                        strongsId: num,
                        lemma: dictEntry.lemma,
                        xlit: dictEntry.transliteration,
                        pron: dictEntry.pronunciation,
                        def: nil,  // Use senses path for all user dictionaries
                        kjv: nil,
                        deriv: nil,
                        lexiconKey: "user-\(module.id)",
                        lexiconName: module.name,
                        pos: nil,
                        sensesJson: dictEntry.sensesJson  // Always pass for reference parsing
                    ))
                }
            }
        } catch {
            print("Failed to look up user dictionary entries: \(error)")
        }

        return entries
    }

    /// Returns entries sorted by user's preferred order
    static func sortedEntries(for num: String, orderString: String) -> [LexiconEntry] {
        let entries = allEntries(for: num)
        let preferredOrder = orderString.split(separator: ",").map { String($0) }

        return entries.sorted { e1, e2 in
            let idx1 = preferredOrder.firstIndex(of: e1.lexiconKey) ?? Int.max
            let idx2 = preferredOrder.firstIndex(of: e2.lexiconKey) ?? Int.max
            if idx1 != idx2 {
                return idx1 < idx2
            }
            return e1.lexiconKey < e2.lexiconKey
        }
    }

    /// Look up a BDB entry directly by its BDB ID (for cross-references like ⦃BDB871⦄)
    static func lookupBDB(_ bdbId: String) -> LexiconEntry? {
        let bundledDb = BundledModuleDatabase.shared
        guard let bdbEntry = try? bundledDb.getDictionaryEntry(moduleId: "bdb", key: bdbId) else {
            return nil
        }

        // Find the Strong's number(s) that map to this BDB entry via reverse lookup
        let strongsIds = (try? bundledDb.getReverseLexiconMappings(targetKey: bdbId)) ?? []
        let strongsId = strongsIds.first ?? ""

        let senses = bdbEntry.senses
        let firstSense = senses.first

        return LexiconEntry(
            id: "\(bdbId)-bdb",
            strongsId: strongsId,
            lemma: bdbEntry.lemma,
            def: firstSense?.definition?.plainText,
            lexiconKey: "bdb",
            lexiconName: "Brown-Driver-Briggs",
            pos: firstSense?.partOfSpeech,
            gloss: firstSense?.gloss,
            sensesJson: bdbEntry.sensesJson,
            bdbId: bdbId
        )
    }

    /// Look up a user dictionary entry by its lexicon ID (e.g., "CWSD_G1234" or entry ID)
    static func lookupUserDictionary(_ lexiconId: String) -> LexiconEntry? {
        let db = ModuleDatabase.shared

        // Try to find entry by ID first
        if let entry = try? db.getDictionaryEntry(id: lexiconId) {
            // Look up module name
            let moduleName = (try? db.getModule(id: entry.moduleId))?.name ?? entry.moduleId
            return LexiconEntry(
                id: entry.id,
                strongsId: entry.key,
                lemma: entry.lemma,
                xlit: entry.transliteration,
                def: entry.definition,
                lexiconKey: entry.moduleId,
                lexiconName: moduleName,
                sensesJson: entry.sensesJson
            )
        }

        // Try parsing as moduleId_key format
        let parts = lexiconId.split(separator: "_", maxSplits: 1)
        if parts.count == 2 {
            let moduleId = String(parts[0])
            let key = String(parts[1])
            if let entry = try? db.getDictionaryEntry(moduleId: moduleId, key: key) {
                let moduleName = (try? db.getModule(id: moduleId))?.name ?? moduleId
                return LexiconEntry(
                    id: entry.id,
                    strongsId: entry.key,
                    lemma: entry.lemma,
                    xlit: entry.transliteration,
                    def: entry.definition,
                    lexiconKey: entry.moduleId,
                    lexiconName: moduleName,
                    sensesJson: entry.sensesJson
                )
            }
        }

        return nil
    }

    /// Converts a homograph number to Roman numeral string
    static func homographLabel(_ num: Int?) -> String? {
        guard let num = num, num > 0 else { return nil }
        let numerals = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        return num <= 10 ? numerals[num] : String(num)
    }
}

/// Pre-parsed entry data to avoid JSON parsing on swipes
struct ParsedLexiconEntryData: Identifiable {
    var id: String { entry.id }
    let entry: LexiconEntry
    let senses: [DictionarySense]  // Senses parsed from sensesJson (used by BDB and user dictionaries)
    let offset: Int

    var hasSenses: Bool { !senses.isEmpty }
}

// MARK: - Single Entry Page View

struct LexiconPageView: View {
    // Pre-parsed data passed from parent (no JSON parsing needed here)
    let parsedEntries: [ParsedLexiconEntryData]
    let totalPopoverCount: Int
    let morphology: String?
    var translationId: String? = nil
    var baseFontSize: CGFloat = 17
    var isCurrentPage: Bool = true  // True when swipe settles on this page (debounced)
    var strongsHitCounts: [String: Int] = [:]  // Hit counts for display
    var searchTerms: [String] = []  // Search terms to highlight
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    // Shared state for cross-segment navigation
    @State private var sheetState: LexiconSheetState? = nil
    @State private var allItems: [LexiconTappableItem] = []

    // Scroll-to-match state (only used when searchTerms is not empty)
    @State private var hasScrolledToMatch: Bool = false
    @State private var preciseMatchOffset: CGFloat? = nil
    @State private var scrollViewRef: UIScrollView? = nil

    // Named coordinate space for scroll-to-match
    private let scrollCoordinateSpaceName = "lexiconScroll"

    // Whether we need scroll-to-match functionality (only from search view)
    private var needsScrollToMatch: Bool { !searchTerms.isEmpty }

    // Scaled fonts
    private var captionFont: Font { .system(size: baseFontSize * 0.798) }  // (+5%)

    /// Find the first entry/sense/field that contains a search term match
    /// Returns (entryId, senseIndex, fieldName) where senseIndex is nil for entry-level match
    private var firstMatchLocation: (entryId: String, senseIndex: Int?, field: String?)? {
        guard !searchTerms.isEmpty else { return nil }
        for data in parsedEntries {
            let hasSenses = !data.senses.isEmpty

            // Check entry-level fields first (only for single-sense entries where these are rendered)
            if !hasSenses {
                // Check gloss (shown if no def)
                if data.entry.def == nil, let gloss = data.entry.gloss, !gloss.isEmpty {
                    if searchTerms.contains(where: { gloss.lowercased().contains($0.lowercased()) }) {
                        return (data.id, nil, "entry-gloss")
                    }
                }
                // Check definition
                if let def = data.entry.def, !def.isEmpty {
                    if searchTerms.contains(where: { def.lowercased().contains($0.lowercased()) }) {
                        return (data.id, nil, "entry-def")
                    }
                }
                // Check KJV usage
                if let kjv = data.entry.kjv, !kjv.isEmpty {
                    if searchTerms.contains(where: { kjv.lowercased().contains($0.lowercased()) }) {
                        return (data.id, nil, "entry-kjv")
                    }
                }
                // Check derivation
                if let deriv = data.entry.deriv, !deriv.isEmpty {
                    if searchTerms.contains(where: { deriv.lowercased().contains($0.lowercased()) }) {
                        return (data.id, nil, "entry-deriv")
                    }
                }
            }

            // Check senses - check each field individually to know where to scroll
            for (index, sense) in data.senses.enumerated() {
                // Check gloss first
                if let gloss = sense.gloss, !gloss.isEmpty {
                    if searchTerms.contains(where: { gloss.lowercased().contains($0.lowercased()) }) {
                        return (data.id, index, "gloss")
                    }
                }
                // Check definition
                if let def = sense.definitionText, !def.isEmpty {
                    if searchTerms.contains(where: { def.lowercased().contains($0.lowercased()) }) {
                        return (data.id, index, "definition")
                    }
                }
                // Check usage
                if let usage = sense.usage, !usage.isEmpty {
                    if searchTerms.contains(where: { usage.lowercased().contains($0.lowercased()) }) {
                        return (data.id, index, "usage")
                    }
                }
                // Check derivation
                if let deriv = sense.derivationText, !deriv.isEmpty {
                    if searchTerms.contains(where: { deriv.lowercased().contains($0.lowercased()) }) {
                        return (data.id, index, "derivation")
                    }
                }
                // Check translation usages
                if let usages = sense.translationUsages {
                    for usage in usages {
                        let usageText = usage.translations.map { $0.word }.joined(separator: " ")
                        if searchTerms.contains(where: { usageText.lowercased().contains($0.lowercased()) }) {
                            return (data.id, index, "translationUsage-\(usage.version)")
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Computed scroll target ID based on first match location
    private var scrollTargetId: String? {
        guard let location = firstMatchLocation else { return nil }
        if let senseIndex = location.senseIndex {
            if let field = location.field {
                return "\(location.entryId)-sense-\(senseIndex)-\(field)"
            }
            return "\(location.entryId)-sense-\(senseIndex)"
        }
        // Entry-level field (e.g., "entry-def", "entry-gloss")
        if let field = location.field {
            return "\(location.entryId)-\(field)"
        }
        return location.entryId
    }

    private func navigateToPrev() {
        guard let current = sheetState, let newState = current.withPrev() else { return }
        sheetState = newState
    }

    private func navigateToNext() {
        guard let current = sheetState, let newState = current.withNext() else { return }
        sheetState = newState
    }

    private func displayTitle(for fullRef: String?, display: String) -> String {
        let ref = fullRef ?? display
        return ref.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    var body: some View {
        // Show loading spinner while swiping, content when settled
        if !isCurrentPage {
            // Loading state during swipe
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if needsScrollToMatch {
            scrollViewWithMatchSupport
        } else {
            simpleScrollView
        }
    }

    // Simple scroll view for reader view (no search terms)
    private var simpleScrollView: some View {
        ScrollView {
            lexiconContent
                .padding()
        }
        .sheet(item: $sheetState) { state in
            sheetContent(state: state)
                .presentationDetents([.fraction(0.4), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
    }

    // Full scroll view with scroll-to-match support (search view case)
    private var scrollViewWithMatchSupport: some View {
        ScrollViewReader { proxy in
            ScrollView {
                lexiconContent
                    .padding()
                    .background(
                        ScrollViewFinder { scrollView in
                            if scrollViewRef == nil {
                                scrollViewRef = scrollView
                            }
                        }
                    )
            }
            .coordinateSpace(name: scrollCoordinateSpaceName)
            .onPreferenceChange(FirstMatchOffsetPreferenceKey.self) { offset in
                if let offset = offset, preciseMatchOffset == nil {
                    preciseMatchOffset = offset
                }
            }
            .onAppear {
                if !hasScrolledToMatch {
                    hasScrolledToMatch = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let offset = preciseMatchOffset, let scrollView = scrollViewRef {
                            let visibleTop = scrollView.contentOffset.y + 120
                            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                            let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                            if !isAlreadyVisible {
                                let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                let targetY = min(max(0, offset - 120), maxScrollY)
                                scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                            }
                        } else if let targetId = scrollTargetId {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(targetId, anchor: .top)
                            }
                        }
                    }
                }
            }
            .onChange(of: preciseMatchOffset) { _, newOffset in
                if hasScrolledToMatch, let offset = newOffset, let scrollView = scrollViewRef {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let visibleTop = scrollView.contentOffset.y + 120
                        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                        let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                        if !isAlreadyVisible {
                            let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                            let targetY = min(max(0, offset - 120), maxScrollY)
                            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                        }
                    }
                }
            }
        }
        .sheet(item: $sheetState) { state in
            sheetContent(state: state)
                .presentationDetents([.fraction(0.4), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
    }

    // Shared content for both scroll view variants (only rendered when page is settled)
    private var lexiconContent: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            // Only compute match location when needed (has search terms)
            let matchLocation = needsScrollToMatch ? firstMatchLocation : nil

            ForEach(parsedEntries) { data in
                let isMatchEntry = matchLocation?.entryId == data.id
                let matchSenseIndex = isMatchEntry ? matchLocation?.senseIndex : nil
                let matchFieldName = isMatchEntry ? matchLocation?.field : nil

                LexiconEntryView(
                    entry: data.entry,
                    senses: data.senses,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse,
                    baseFontSize: baseFontSize,
                    hitCount: strongsHitCounts[data.entry.strongsId],
                    isCurrentPage: true,  // Always true here since we only render when settled
                    searchTerms: searchTerms,
                    baseOffset: data.offset,
                    sharedSheetState: $sheetState,
                    sharedAllItems: $allItems,
                    reportMatchForSense: matchSenseIndex,
                    reportMatchForField: matchFieldName,
                    scrollCoordinateSpace: scrollCoordinateSpaceName
                )
                .id(data.id)

                if data.id != parsedEntries.last?.id {
                    Divider()
                }
            }

            if let morph = morphology, !morph.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Morphology")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                    Text(morph)
                        .font(captionFont.monospaced())
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(state: LexiconSheetState) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                LexiconSheetItemContent(
                    itemType: item.type,
                    translationId: translationId,
                    onSearchStrongs: onSearchStrongs,
                    onNavigateToVerse: onNavigateToVerse
                )
                .padding()
            }
            .navigationTitle(sheetTitle(for: item))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        sheetState = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let navigateAction = sheetNavigateAction(for: item) {
                        Button {
                            navigateAction()
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button {
                            navigateToPrev()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.allItems.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button {
                            navigateToNext()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
    }

    private func sheetTitle(for item: LexiconTappableItem) -> String {
        switch item.type {
        case .strongs(let ref):
            return ref
        case .verseRef(let display, _, _, let fullRef):
            return displayTitle(for: fullRef, display: display)
        case .bdbRef(let bdbId):
            return bdbId
        case .lexiconRef(let lexiconId):
            return lexiconId
        }
    }

    private func sheetNavigateAction(for item: LexiconTappableItem) -> (() -> Void)? {
        switch item.type {
        case .strongs:
            return nil  // Strong's entries don't navigate
        case .verseRef(_, let verseId, _, _):
            guard onNavigateToVerse != nil else { return nil }
            return {
                sheetState = nil
                onNavigateToVerse?(verseId)
            }
        case .bdbRef:
            return nil  // BDB entries don't navigate
        case .lexiconRef:
            return nil  // Lexicon entries don't navigate
        }
    }
}

// MARK: - Lexicon Sheet View (with swipeable lexicons)

/// Wrapper for Strong's search to use with sheet(item:)
struct StrongsSearchItem: Identifiable {
    let id = UUID()
    let strongsNum: String
}

/// Search sheet wrapper for presenting from lexicon
struct LexiconSearchSheet: View {
    let strongsNum: String
    let translationId: String
    let fontSize: Int
    let onNavigateToVerse: (Int) -> Void

    @State private var isPresented: Bool = true
    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SearchView(
            isPresented: $isPresented,
            translationId: translationId,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            initialSearchText: strongsNum,
            initialSearchMode: .strongs,
            initialSearchScope: .bible,  // Always use Bible search for Strong's lookup
            fontSize: fontSize
        )
        .onChange(of: isPresented) {
            if !isPresented {
                dismiss()
            }
        }
        .onChange(of: requestScrollToVerseId) {
            if let verseId = requestScrollToVerseId {
                onNavigateToVerse(verseId)
            }
        }
    }
}

// Holds raw entry data for background parsing (no Realm references)
private struct RawEntryData: Sendable {
    let id: String
    let strongsId: String
    let lemma: String
    let xlit: String?
    let pron: String?
    let def: String?
    let kjv: String?
    let deriv: String?
    let lexiconKey: String
    let lexiconName: String
    let pos: String?
    let gloss: String?
    let sensesJson: String?
    let referencesJson: String?
    let bdbId: String?
    let homograph: Int?

    init(from entry: LexiconEntry) {
        self.id = entry.id
        self.strongsId = entry.strongsId
        self.lemma = entry.lemma
        self.xlit = entry.xlit
        self.pron = entry.pron
        self.def = entry.def
        self.kjv = entry.kjv
        self.deriv = entry.deriv
        self.lexiconKey = entry.lexiconKey
        self.lexiconName = entry.lexiconName
        self.pos = entry.pos
        self.gloss = entry.gloss
        self.sensesJson = entry.sensesJson
        self.referencesJson = entry.referencesJson
        self.bdbId = entry.bdbId
        self.homograph = entry.homograph
    }

    func toLexiconEntry() -> LexiconEntry {
        LexiconEntry(
            id: id,
            strongsId: strongsId,
            lemma: lemma,
            xlit: xlit,
            pron: pron,
            def: def,
            kjv: kjv,
            deriv: deriv,
            lexiconKey: lexiconKey,
            lexiconName: lexiconName,
            pos: pos,
            gloss: gloss,
            sensesJson: sensesJson,
            referencesJson: referencesJson,
            bdbId: bdbId,
            homograph: homograph
        )
    }
}

// Background parsing queue
private let lexiconParsingQueue = DispatchQueue(label: "com.lampbible.lexiconParsing", qos: .userInitiated)

// Observable class to hold lexicon loading state
@MainActor
class LexiconLoader: ObservableObject {
    @Published var cachedLexicons: [String] = []
    @Published var cachedParsedData: [String: [ParsedLexiconEntryData]] = [:]
    @Published var cachedTotalCounts: [String: Int] = [:]
    @Published var isLoading: Bool = true
    @Published var strongsHitCounts: [String: Int] = [:]  // Hit counts per Strong's number

    func load(
        strongs: [String],
        restrictToLexicon: String?,
        hebrewLexiconOrder: String,
        greekLexiconOrder: String,
        hiddenHebrewLexicons: String = "",
        hiddenGreekLexicons: String = "",
        translationId: String? = nil  // For counting hits (GRDB translation ID)
    ) {
        // Step 1: Fetch all Realm data synchronously on main thread and copy to Sendable structs
        let lexicons = computeAvailableLexicons(
            strongs: strongs,
            restrictToLexicon: restrictToLexicon,
            hebrewLexiconOrder: hebrewLexiconOrder,
            greekLexiconOrder: greekLexiconOrder,
            hiddenHebrewLexicons: hiddenHebrewLexicons,
            hiddenGreekLexicons: hiddenGreekLexicons
        )

        var rawEntriesByLexicon: [String: [RawEntryData]] = [:]
        for lexiconKey in lexicons {
            let entries = computeEntries(for: lexiconKey, strongs: strongs)
            rawEntriesByLexicon[lexiconKey] = entries.map { RawEntryData(from: $0) }
        }

        // Step 2: Parse JSON in background using explicit GCD queue
        // NOTE: Uses thread-safe counting function that doesn't access Realm
        lexiconParsingQueue.async { [weak self] in
            var parsedDataByLexicon: [String: [ParsedLexiconEntryData]] = [:]
            var totalCountsByLexicon: [String: Int] = [:]

            for (lexiconKey, rawEntries) in rawEntriesByLexicon {
                var parsedData: [ParsedLexiconEntryData] = []
                var runningOffset = 0
                for rawEntry in rawEntries {
                    let entry = rawEntry.toLexiconEntry()
                    let senses = parseSensesForEntry(entry)
                    let hasSenses = !senses.isEmpty
                    parsedData.append(ParsedLexiconEntryData(
                        entry: entry,
                        senses: senses,
                        offset: runningOffset
                    ))
                    // Use thread-safe counting that doesn't require Realm access
                    runningOffset += countPopoverItemsInEntryThreadSafe(entry, hasSenses: hasSenses, senses: senses)
                }
                parsedDataByLexicon[lexiconKey] = parsedData
                totalCountsByLexicon[lexiconKey] = runningOffset
            }

            // Step 3: Update state on main thread
            DispatchQueue.main.async { [weak self] in
                self?.cachedLexicons = lexicons
                self?.cachedParsedData = parsedDataByLexicon
                self?.cachedTotalCounts = totalCountsByLexicon
                self?.isLoading = false

                // Step 4: Load hit counts asynchronously (after UI update)
                if let translationId = translationId {
                    self?.loadHitCounts(for: strongs, translationId: translationId)
                }
            }
        }
    }

    /// Loads Strong's hit counts using GRDB
    /// Called after initial UI update so loading state shows first
    private func loadHitCounts(for strongs: [String], translationId: String) {
        var counts: [String: Int] = [:]

        for strongsNum in strongs {
            counts[strongsNum] = (try? TranslationDatabase.shared.countStrongsOccurrences(
                translationId: translationId,
                strongsNum: strongsNum
            )) ?? 0
        }

        strongsHitCounts = counts
    }

    private func computeAvailableLexicons(
        strongs: [String],
        restrictToLexicon: String?,
        hebrewLexiconOrder: String,
        greekLexiconOrder: String,
        hiddenHebrewLexicons: String = "",
        hiddenGreekLexicons: String = ""
    ) -> [String] {
        if let restricted = restrictToLexicon {
            return [restricted]
        }

        let isHebrew = strongs.first?.hasPrefix("H") ?? false
        let hiddenString = isHebrew ? hiddenHebrewLexicons : hiddenGreekLexicons
        let hiddenKeys = parseHiddenLexiconKeys(hiddenString)

        var lexicons: Set<String> = []
        for num in strongs {
            let entries = LexiconLookup.allEntries(for: num)
            for entry in entries {
                // Skip hidden lexicons
                if !hiddenKeys.contains(entry.lexiconKey) {
                    lexicons.insert(entry.lexiconKey)
                }
            }
        }

        let orderString = isHebrew ? hebrewLexiconOrder : greekLexiconOrder
        let preferredOrder = orderString.split(separator: ",").map { String($0) }

        return lexicons.sorted { l1, l2 in
            let idx1 = preferredOrder.firstIndex(of: l1) ?? Int.max
            let idx2 = preferredOrder.firstIndex(of: l2) ?? Int.max
            if idx1 != idx2 {
                return idx1 < idx2
            }
            return l1 < l2
        }
    }

    private func computeEntries(for lexiconKey: String, strongs: [String]) -> [LexiconEntry] {
        var result: [LexiconEntry] = []
        var seenIds = Set<String>()
        for num in strongs {
            let allEntries = LexiconLookup.allEntries(for: num)
            if lexiconKey == "bdb" {
                for entry in allEntries where entry.lexiconKey == lexiconKey {
                    if !seenIds.contains(entry.id) {
                        seenIds.insert(entry.id)
                        result.append(entry)
                    }
                }
            } else {
                if let entry = allEntries.first(where: { $0.lexiconKey == lexiconKey }) {
                    if !seenIds.contains(entry.id) {
                        seenIds.insert(entry.id)
                        result.append(entry)
                    }
                }
            }
        }
        return result
    }
}

struct LexiconSheetView: View {
    let word: String
    let strongs: [String]
    let morphology: String?
    let translationId: String  // GRDB translation ID
    var onNavigateToVerse: ((Int) -> Void)? = nil
    var restrictToLexicon: String? = nil  // If set, only show this specific lexicon (no pagination)
    var searchQuery: String? = nil  // If set, highlight search terms and scroll to first match
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var settledPage: Int = 0  // Debounced - only updates when swipe finishes
    @State private var settleTask: Task<Void, Never>? = nil
    @State private var searchItem: StrongsSearchItem? = nil
    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = false
    // Use ObservableObject for async loading
    @StateObject private var loader = LexiconLoader()

    private var userSettings: UserSettings {
        UserDatabase.shared.getSettings()
    }

    private var greekLexiconOrder: String { userSettings.greekLexiconOrder }
    private var hebrewLexiconOrder: String { userSettings.hebrewLexiconOrder }
    private var hiddenGreekLexicons: String { userSettings.hiddenGreekLexicons }
    private var hiddenHebrewLexicons: String { userSettings.hiddenHebrewLexicons }

    /// Base font size at 90% of user's reader font size
    private var scaledBaseFontSize: CGFloat {
        CGFloat(userSettings.readerFontSize) * 0.85
    }

    /// Extract search terms from the query string for highlighting
    private var searchTerms: [String] {
        guard let query = searchQuery, !query.isEmpty else { return [] }
        // Remove quotes and wildcards, split into terms
        let cleanQuery = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleanQuery.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }

    /// Display name for a lexicon key
    private func lexiconDisplayName(_ key: String) -> String {
        switch key {
        case "strongs":
            let isHebrew = strongs.first?.hasPrefix("H") ?? false
            return isHebrew ? "Strong's Hebrew" : "Strong's Greek"
        case "bdb": return "Brown-Driver-Briggs"
        case "dodson": return "Dodson"
        default: return key
        }
    }

    /// Opens search sheet for the given Strong's number
    private func openSearch(_ strongsNum: String) {
        searchItem = StrongsSearchItem(strongsNum: strongsNum)
    }

    /// Handle navigation from search results
    private func handleNavigateToVerse(_ verseId: Int) {
        searchItem = nil
        dismiss()
        onNavigateToVerse?(verseId)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loader.isLoading {
                    // Loading state - show immediately while data loads
                    VStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                } else if loader.cachedLexicons.count > 1 {
                    // Swipeable pages for multiple lexicons
                    TabView(selection: $currentPage) {
                        ForEach(Array(loader.cachedLexicons.enumerated()), id: \.offset) { index, lexiconKey in
                            LexiconPageView(
                                parsedEntries: loader.cachedParsedData[lexiconKey] ?? [],
                                totalPopoverCount: loader.cachedTotalCounts[lexiconKey] ?? 0,
                                morphology: morphology,
                                translationId: translationId,
                                baseFontSize: scaledBaseFontSize,
                                isCurrentPage: settledPage == index,  // Only true when swipe finishes
                                strongsHitCounts: loader.strongsHitCounts,
                                searchTerms: searchTerms,
                                // Disable search when restricted to a specific lexicon (e.g., from module search)
                                onSearchStrongs: (!translationId.isEmpty && restrictToLexicon == nil) ? openSearch : nil,
                                onNavigateToVerse: restrictToLexicon == nil ? handleNavigateToVerse : nil
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: currentPage) { _, newPage in
                        // Debounce: only update settledPage after swipe finishes (no change for 250ms)
                        settleTask?.cancel()
                        settleTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms
                            if !Task.isCancelled {
                                settledPage = newPage
                            }
                        }
                    }

                    // Pill page indicator
                    HStack(spacing: 8) {
                        ForEach(Array(loader.cachedLexicons.enumerated()), id: \.offset) { index, _ in
                            Capsule()
                                .fill(currentPage == index ? Color.primary : Color.secondary)
                                .frame(width: currentPage == index ? 20 : 8, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: currentPage)
                                .onTapGesture {
                                    withAnimation {
                                        currentPage = index
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 12)
                } else {
                    // Single lexicon - no pagination needed
                    if let lexiconKey = loader.cachedLexicons.first {
                        LexiconPageView(
                            parsedEntries: loader.cachedParsedData[lexiconKey] ?? [],
                            totalPopoverCount: loader.cachedTotalCounts[lexiconKey] ?? 0,
                            morphology: morphology,
                            translationId: translationId,
                            baseFontSize: scaledBaseFontSize,
                            strongsHitCounts: loader.strongsHitCounts,
                            searchTerms: searchTerms,
                            // Disable search when restricted to a specific lexicon (e.g., from module search)
                            onSearchStrongs: (!translationId.isEmpty && restrictToLexicon == nil) ? openSearch : nil,
                            onNavigateToVerse: restrictToLexicon == nil ? handleNavigateToVerse : nil
                        )
                    }
                }
            }
            .navigationTitle(word)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .onAppear {
                loader.load(
                    strongs: strongs,
                    restrictToLexicon: restrictToLexicon,
                    hebrewLexiconOrder: hebrewLexiconOrder,
                    greekLexiconOrder: greekLexiconOrder,
                    hiddenHebrewLexicons: hiddenHebrewLexicons,
                    hiddenGreekLexicons: hiddenGreekLexicons,
                    translationId: translationId
                )
            }
            .sheet(item: $searchItem) { item in
                LexiconSearchSheet(
                    strongsNum: item.strongsNum,
                    translationId: translationId,
                    fontSize: Int(userSettings.readerFontSize),
                    onNavigateToVerse: handleNavigateToVerse
                )
            }
        }
    }
}

// MARK: - Lexicon Popover Content (simplified, single lexicon)

struct LexiconPopoverContent: View {
    let word: String
    let strongs: [String]
    let morphology: String?

    private var userSettings: UserSettings {
        UserDatabase.shared.getSettings()
    }

    private var greekLexiconOrder: String { userSettings.greekLexiconOrder }
    private var hebrewLexiconOrder: String { userSettings.hebrewLexiconOrder }
    private var hiddenGreekLexicons: String { userSettings.hiddenGreekLexicons }
    private var hiddenHebrewLexicons: String { userSettings.hiddenHebrewLexicons }

    /// Base font size at 90% of user's reader font size
    private var scaledBaseFontSize: CGFloat {
        CGFloat(userSettings.readerFontSize) * 0.85
    }

    // Scaled fonts
    private var headlineFont: Font { .system(size: scaledBaseFontSize * 1.1) }
    private var captionFont: Font { .system(size: scaledBaseFontSize * 0.76) }

    // Parse senses from JSON based on entry type
    private func parseSenses(for entry: LexiconEntry) -> [DictionarySense] {
        return parseSensesForEntry(entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(word)
                    .font(headlineFont)
                Spacer()
                Text(strongs.joined(separator: ", "))
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Entries (preferred lexicon only for popover)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(strongs, id: \.self) { num in
                        let isHebrew = num.hasPrefix("H")
                        let orderString = isHebrew ? hebrewLexiconOrder : greekLexiconOrder
                        let hiddenString = isHebrew ? hiddenHebrewLexicons : hiddenGreekLexicons
                        let entries = visibleLexiconEntries(for: num, orderString: orderString, hiddenString: hiddenString)
                        if let entry = entries.first {
                            LexiconEntryView(
                                entry: entry,
                                senses: parseSenses(for: entry),
                                baseFontSize: scaledBaseFontSize
                            )

                            if num != strongs.last {
                                Divider()
                            }
                        } else {
                            Text("Entry not found: \(num)")
                                .font(captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Morphology section
                    if let morph = morphology, !morph.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Morphology")
                                .font(captionFont)
                                .foregroundStyle(.secondary)
                            Text(morph)
                                .font(captionFont.monospaced())
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 280, maxWidth: 350)
        .frame(maxHeight: 400)
        .presentationCompactAdaptation(.popover)
    }
}
