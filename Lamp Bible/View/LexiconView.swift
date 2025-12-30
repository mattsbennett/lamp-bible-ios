//
//  LexiconView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-29.
//

import SwiftUI
import RealmSwift

// MARK: - Strong's Reference Linked Text

extension String: @retroactive Identifiable {
    public var id: String { self }
}

// MARK: - Linked Text Segment Parsing

/// A segment of parsed text - either plain text, a Strong's reference, or a verse reference
private enum LinkedTextSegment: Identifiable {
    case text(String)
    case strongs(String)  // e.g., "H1234", "G5678"
    case verseRef(display: String, verseId: Int)  // parsed verse reference

    var id: String {
        switch self {
        case .text(let s): return "t_\(s.hashValue)"
        case .strongs(let s): return "s_\(s)"
        case .verseRef(let d, let v): return "v_\(d)_\(v)"
        }
    }
}

/// Parses text into segments, identifying Strong's numbers and verse references
private func parseLinkedTextSegments(_ text: String) -> [LinkedTextSegment] {
    var segments: [LinkedTextSegment] = []

    // Combined pattern for Strong's numbers and verse references
    // Strong's: H1234, G5678
    // Verse refs: Book chapter:verse (handles parentheses, various book name formats)
    let strongsPattern = #"[GH]\d+"#
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

        // Check if it's a Strong's number
        if matchedText.first == "H" || matchedText.first == "G",
           matchedText.dropFirst().allSatisfy({ $0.isNumber }) {
            segments.append(.strongs(matchedText))
        }
        // Otherwise it's a verse reference
        else if let verseId = parseVerseReference(matchedText) {
            segments.append(.verseRef(display: matchedText, verseId: verseId))
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

/// Parses a verse reference string into a verse ID
private func parseVerseReference(_ ref: String) -> Int? {
    // Remove parentheses
    let cleaned = ref.trimmingCharacters(in: CharacterSet(charactersIn: "()"))

    // Pattern: BookName chapter:verse
    let pattern = #"^([1-3]?\s*[A-Z][a-z]+\.?)\s+(\d+):(\d+)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else {
        return nil
    }

    guard let bookRange = Range(match.range(at: 1), in: cleaned),
          let chapterRange = Range(match.range(at: 2), in: cleaned),
          let verseRange = Range(match.range(at: 3), in: cleaned) else {
        return nil
    }

    let bookName = String(cleaned[bookRange]).trimmingCharacters(in: .whitespaces)
    guard let chapter = Int(cleaned[chapterRange]),
          let verse = Int(cleaned[verseRange]) else {
        return nil
    }

    // Look up book ID from name
    guard let bookId = lookupBookId(from: bookName) else {
        return nil
    }

    return bookId * 1000000 + chapter * 1000 + verse
}

/// Looks up a book ID from various name formats (full name, OSIS, abbreviation)
private func lookupBookId(from name: String) -> Int? {
    let realm = RealmManager.shared.realm
    let normalizedName = name.lowercased().replacingOccurrences(of: ".", with: "")

    // Try exact match on various fields
    if let book = realm.objects(Book.self).filter("name ==[c] %@ OR osisId ==[c] %@ OR osisParatextAbbreviation ==[c] %@",
                                                   name, name, name).first {
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
       let book = realm.objects(Book.self).filter("osisId == %@", osisId).first {
        return book.id
    }

    return nil
}

/// A view that displays text with tappable Strong's references and verse references
struct LinkedDefinitionText: View {
    let text: String
    let font: Font
    var translation: Translation? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    /// Flattens segments into flow items, splitting text into words for proper wrapping
    private var flowItems: [(id: Int, content: FlowItemContent)] {
        let segments = parseLinkedTextSegments(text)
        var items: [(id: Int, content: FlowItemContent)] = []
        var itemId = 0

        for segment in segments {
            switch segment {
            case .text(let str):
                // Split text into words, preserving spaces
                let words = splitIntoWords(str)
                for word in words {
                    items.append((id: itemId, content: .text(word)))
                    itemId += 1
                }
            case .strongs(let ref):
                items.append((id: itemId, content: .strongs(ref)))
                itemId += 1
            case .verseRef(let display, let verseId):
                items.append((id: itemId, content: .verseRef(display: display, verseId: verseId)))
                itemId += 1
            }
        }
        return items
    }

    /// Splits a string into words, with each word including its trailing space
    private func splitIntoWords(_ str: String) -> [String] {
        var words: [String] = []
        var current = ""

        for char in str {
            if char == " " {
                current.append(char)
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(flowItems, id: \.id) { item in
                switch item.content {
                case .text(let str):
                    Text(str)
                        .font(font)
                case .strongs(let ref):
                    StrongsLinkButton(
                        strongsNum: ref,
                        font: font,
                        translation: translation,
                        onSearchStrongs: onSearchStrongs
                    )
                case .verseRef(let display, let verseId):
                    VerseRefLinkButton(
                        display: display,
                        verseId: verseId,
                        font: font,
                        translation: translation,
                        onNavigateToVerse: onNavigateToVerse
                    )
                }
            }
        }
    }
}

/// Content type for flow layout items
private enum FlowItemContent {
    case text(String)
    case strongs(String)
    case verseRef(display: String, verseId: Int)
}

/// Button for a Strong's reference with its own popover
private struct StrongsLinkButton: View {
    let strongsNum: String
    let font: Font
    var translation: Translation?
    var onSearchStrongs: ((String) -> Void)?

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(strongsNum)
                .font(font)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            LexiconPopoverForRef(strongsNum: strongsNum, translation: translation, onSearchStrongs: onSearchStrongs)
        }
    }
}

/// Button for a verse reference with its own popover
private struct VerseRefLinkButton: View {
    let display: String
    let verseId: Int
    let font: Font
    var translation: Translation?
    var onNavigateToVerse: ((Int) -> Void)?

    @State private var showingPopover = false
    @State private var contentHeight: CGFloat = 100

    private var verse: Verse? {
        guard let translation = translation else { return nil }
        return RealmManager.shared.realm.objects(Verse.self)
            .filter("tr == %@ AND id == %@", translation.id, verseId)
            .first
    }

    private var verseText: AttributedString {
        guard let verse = verse else {
            var notFound = AttributedString("Verse not found")
            notFound.foregroundColor = .secondary
            return notFound
        }

        var verseNum = AttributedString("\(verse.v)")
        verseNum.font = .caption
        verseNum.foregroundColor = .secondary
        verseNum.baselineOffset = 4

        var text = AttributedString(" " + stripStrongsAnnotations(verse.t))
        text.font = .body

        return verseNum + text
    }

    private var displayTitle: String {
        display.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(display)
                .font(font)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: displayTitle,
                verseText: verseText,
                onNavigate: onNavigateToVerse != nil ? {
                    showingPopover = false
                    onNavigateToVerse?(verseId)
                } : nil,
                contentHeight: $contentHeight
            )
        }
    }
}

/// Popover content for a Strong's reference
struct LexiconPopoverForRef: View {
    let strongsNum: String
    var translation: Translation? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    @State private var contentHeight: CGFloat = 150

    var body: some View {
        let entries = LexiconLookup.allEntries(for: strongsNum)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let entry = entries.first {
                    // Header
                    HStack(alignment: .center, spacing: 8) {
                        Text(entry.lemma)
                            .font(.title3)
                            .fontWeight(.semibold)
                        if let onSearch = onSearchStrongs {
                            Button {
                                onSearch(entry.strongsId)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(entry.strongsId)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "magnifyingglass")
                                        .font(.caption2)
                                        .foregroundStyle(.accent)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(entry.strongsId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }

                    if let xlit = entry.xlit, !xlit.isEmpty {
                        Text(xlit)
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(.secondary)
                    }

                    if let def = entry.def, !def.isEmpty {
                        LinkedDefinitionText(text: def, font: .callout, translation: translation, onSearchStrongs: onSearchStrongs)
                    }
                } else {
                    Text("Entry not found: \(strongsNum)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        contentHeight = geo.size.height
                    }
                }
            )
        }
        .frame(width: 300)
        .frame(height: min(max(contentHeight, 100), 300))
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - BDB Senses JSON Parsing

/// A sense can be a stem-level entry (Qal, Niph, etc.) or a numbered sub-sense
struct BDBSense: Codable, Identifiable {
    let n: String?  // Sense number (e.g., "1", "2") - only for sub-senses
    let defs: [String]?  // Definitions
    let refs: [String]?  // Verse references
    let gloss: String?  // Gloss text (for stems, includes stem name like "Qal...")
    let senses: [BDBSense]?  // Nested sub-senses (for stem-level entries)

    var id: String { n ?? gloss ?? UUID().uuidString }

    /// Traditional order for Hebrew verb stems
    static let stemOrder = ["Qal", "Niph.", "Niph", "Niphal", "Pi.", "Pi", "Piel",
                            "Pu.", "Pu", "Pual", "Hithp.", "Hithp", "Hithpael",
                            "Hiph.", "Hiph", "Hiphil", "Hoph.", "Hoph", "Hophal"]

    /// Extract stem name from gloss (e.g., "Qal", "Niph.", "Hiph.")
    var stemName: String? {
        guard let gloss = gloss else { return nil }
        for stem in Self.stemOrder {
            if gloss.hasPrefix(stem) {
                return stem
            }
        }
        return nil
    }

    /// Sort order for this stem (lower = first)
    var stemSortOrder: Int {
        guard let stem = stemName else { return 999 }
        return Self.stemOrder.firstIndex(of: stem) ?? 999
    }

    /// Extract occurrence count from gloss (e.g., "27" from "Qal 27 cease...")
    var occurrenceCount: String? {
        guard let gloss = gloss else { return nil }
        let pattern = #"^(?:Qal|Niph\.?|Pi\.?|Pu\.?|Hithp\.?|Hiph\.?|Hoph\.?|Piel|Pual|Hithpael|Hiphil|Hophal|Niphal)\s+(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(gloss.startIndex..., in: gloss)
            if let match = regex.firstMatch(in: gloss, range: range),
               let numRange = Range(match.range(at: 1), in: gloss) {
                return String(gloss[numRange])
            }
        }
        return nil
    }

    /// Clean gloss by removing stem name and occurrence count
    var cleanedGloss: String? {
        guard let gloss = gloss else { return nil }
        // Remove patterns like "Qal 27 " or "Hiph. 40 " at the start
        let pattern = #"^(Qal|Niph\.?|Pi\.?|Pu\.?|Hithp\.?|Hiph\.?|Hoph\.?|Piel|Pual|Hithpael|Hiphil|Hophal|Niphal)\s*\d*\s*"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(gloss.startIndex..., in: gloss)
            return regex.stringByReplacingMatches(in: gloss, range: range, withTemplate: "")
        }
        return gloss
    }
}

// MARK: - Lexicon Entry Data

struct LexiconEntry: Identifiable {
    let id: String  // e.g., "H1-strongs" or "G18-dodson"
    let strongsId: String
    let lemma: String
    let xlit: String?
    let pron: String?
    let def: String?
    let kjv: String?
    let deriv: String?
    let lexiconKey: String  // "strongs", "bdb", "dodson"
    let lexiconName: String  // Display name

    // BDB-specific fields
    let pos: String?  // Part of speech
    let stems: String?  // Verb stems
    let sensesJson: String?  // Full senses data as JSON
    let refs: String?  // Sample verse references

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
        stems: String? = nil,
        sensesJson: String? = nil,
        refs: String? = nil
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
        self.stems = stems
        self.sensesJson = sensesJson
        self.refs = refs
    }
}

// MARK: - Lexicon Entry Display

struct LexiconEntryView: View {
    let entry: LexiconEntry
    var translation: Translation? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    /// Parse the sensesJson field into BDBSense array
    private var parsedSenses: [BDBSense] {
        guard let json = entry.sensesJson, !json.isEmpty else { return [] }
        guard let data = json.data(using: .utf8) else { return [] }

        // Try parsing as array of senses directly
        if let senses = try? JSONDecoder().decode([BDBSense].self, from: data) {
            return senses
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: Lemma and ID
            HStack(alignment: .center, spacing: 8) {
                Text(entry.lemma)
                    .font(.title2)
                if let onSearch = onSearchStrongs {
                    Button {
                        onSearch(entry.strongsId)
                    } label: {
                        HStack(spacing: 4) {
                            Text(entry.strongsId)
                                .foregroundStyle(.secondary)
                            Image(systemName: "magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.accent)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(entry.strongsId)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            // Lexicon source + part of speech (for BDB)
            HStack(spacing: 4) {
                Text(entry.lexiconName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let pos = entry.pos, !pos.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(pos)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                }
            }

            // Transliteration / Pronunciation
            if let xlit = entry.xlit, !xlit.isEmpty {
                Text(xlit)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
            }

            if let pron = entry.pron, !pron.isEmpty, pron != entry.xlit {
                Text(pron)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Verb stems (BDB) - only show if no detailed senses
            if let stems = entry.stems, !stems.isEmpty, parsedSenses.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stems")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(stems)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.primary)
                }
            }

            // Top-level definition (for entries without senses)
            if let def = entry.def, !def.isEmpty, parsedSenses.isEmpty {
                LinkedDefinitionText(text: def, font: .body, translation: translation, onSearchStrongs: onSearchStrongs, onNavigateToVerse: onNavigateToVerse)
            }

            // BDB Senses/Stems
            if !parsedSenses.isEmpty {
                // Check if top-level entries are stems (Qal, Niph, etc.) or numbered senses
                let hasStems = parsedSenses.contains { $0.stemName != nil }
                let sortedSenses = hasStems
                    ? parsedSenses.sorted { $0.stemSortOrder < $1.stemSortOrder }
                    : parsedSenses

                VStack(alignment: .leading, spacing: 12) {
                    // Show appropriate section title
                    Text(hasStems ? "Stems" : "Senses")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedSenses) { sense in
                            BDBSenseView(sense: sense, isSubSense: false)

                            if sense.id != sortedSenses.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }

            // KJV Usage
            if let kjv = entry.kjv, !kjv.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("KJV Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(kjv)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .padding(.top, 4)
            }

            // Derivation
            if let deriv = entry.deriv, !deriv.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Derivation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LinkedDefinitionText(text: deriv, font: .caption, translation: translation, onSearchStrongs: onSearchStrongs, onNavigateToVerse: onNavigateToVerse)
                }
            }

            // References (BDB) - only show if no senses (senses have their own refs)
            if let refs = entry.refs, !refs.isEmpty, parsedSenses.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("References")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BDBRefsView(refs: refs, onNavigateToVerse: onNavigateToVerse)
                }
            }
        }
    }
}

// MARK: - BDB Sense View

struct BDBSenseView: View {
    let sense: BDBSense
    let isSubSense: Bool

    init(sense: BDBSense, isSubSense: Bool = false) {
        self.sense = sense
        self.isSubSense = isSubSense
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Check if this is a stem-level entry (has stemName or nested senses)
            if let stemName = sense.stemName {
                // Stem header (e.g., "Qal (27)", "Hiph. (40)")
                HStack(spacing: 4) {
                    Text(stemName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    if let count = sense.occurrenceCount {
                        Text("(\(count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Nested sub-senses (preferred if available)
                if let subSenses = sense.senses, !subSenses.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(subSenses) { subSense in
                            BDBSenseView(sense: subSense, isSubSense: true)
                        }
                    }
                    .padding(.leading, 12)
                } else if let cleanedGloss = sense.cleanedGloss, !cleanedGloss.isEmpty {
                    // Only show gloss if no nested senses
                    Text(cleanedGloss)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let n = sense.n {
                // Numbered sense (can have nested sub-senses like a, b, c)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(n).")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            if let defs = sense.defs, !defs.isEmpty {
                                Text(defs.joined(separator: ", "))
                                    .font(.body)
                            }
                            // Only show gloss if no nested senses and no defs
                            if sense.senses == nil || sense.senses!.isEmpty {
                                if let gloss = sense.gloss, !gloss.isEmpty,
                                   gloss != sense.defs?.joined(separator: ", "),
                                   sense.defs == nil || sense.defs!.isEmpty {
                                    Text(gloss)
                                        .font(.body)
                                } else if let gloss = sense.gloss, !gloss.isEmpty,
                                          gloss != sense.defs?.joined(separator: ", ") {
                                    Text(gloss)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let refs = sense.refs, !refs.isEmpty {
                                Text(refs.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // Nested sub-senses (a, b, c, etc.)
                    if let subSenses = sense.senses, !subSenses.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(subSenses) { subSense in
                                BDBSenseView(sense: subSense, isSubSense: true)
                            }
                        }
                        .padding(.leading, 26)
                    }
                }
            } else {
                // Simple entry without number (e.g., "Niph. cease")
                if let defs = sense.defs, !defs.isEmpty {
                    Text(defs.joined(separator: ", "))
                        .font(.body)
                }
                if let gloss = sense.cleanedGloss ?? sense.gloss, !gloss.isEmpty {
                    Text(gloss)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let refs = sense.refs, !refs.isEmpty {
                    Text(refs.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Lexicon Lookup Helper

struct LexiconLookup {
    /// Returns all available lexicon entries for a Strong's number
    static func allEntries(for num: String) -> [LexiconEntry] {
        let realm = RealmManager.shared.realm
        var entries: [LexiconEntry] = []

        if num.hasPrefix("H") {
            // Hebrew - Strong's and BDB
            if let entry = realm.objects(StrongsHebrew.self).filter("id == %@", num).first {
                entries.append(LexiconEntry(
                    id: "\(num)-strongs",
                    strongsId: num,
                    lemma: entry.lemma,
                    xlit: entry.xlit,
                    pron: entry.pron,
                    def: entry.def,
                    kjv: entry.kjv,
                    deriv: entry.deriv,
                    lexiconKey: "strongs",
                    lexiconName: "Strong's Hebrew"
                ))
            }
            // Look up BDB via mapping
            if let mapping = realm.objects(BDBMapping.self).filter("id == %@", num).first {
                let bdbIds = mapping.bdbEntryIds.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                for bdbId in bdbIds {
                    if let bdbEntry = realm.objects(BDBEntry.self).filter("id == %@", bdbId).first {
                        entries.append(LexiconEntry(
                            id: "\(num)-bdb-\(bdbId)",
                            strongsId: num,
                            lemma: bdbEntry.lemma,
                            def: bdbEntry.defs,
                            lexiconKey: "bdb",
                            lexiconName: "Brown-Driver-Briggs",
                            pos: bdbEntry.pos,
                            stems: bdbEntry.stems,
                            sensesJson: bdbEntry.sensesJson,
                            refs: bdbEntry.refs
                        ))
                    }
                }
            }
        } else if num.hasPrefix("G") {
            // Greek - Strong's and Dodson
            if let entry = realm.objects(StrongsGreek.self).filter("id == %@", num).first {
                entries.append(LexiconEntry(
                    id: "\(num)-strongs",
                    strongsId: num,
                    lemma: entry.lemma,
                    xlit: entry.xlit,
                    def: entry.def,
                    kjv: entry.kjv,
                    deriv: entry.deriv,
                    lexiconKey: "strongs",
                    lexiconName: "Strong's Greek"
                ))
            }
            if let entry = realm.objects(DodsonGreek.self).filter("id == %@", num).first {
                // Use full def if available, otherwise fall back to short
                let definition = (entry.def?.isEmpty == false) ? entry.def : entry.short
                entries.append(LexiconEntry(
                    id: "\(num)-dodson",
                    strongsId: num,
                    lemma: entry.lemma,
                    def: definition,
                    lexiconKey: "dodson",
                    lexiconName: "Dodson"
                ))
            }
        }

        return entries
    }

    /// Returns entries sorted with the preferred lexicon first
    static func sortedEntries(for num: String, preferredGreek: String, preferredHebrew: String) -> [LexiconEntry] {
        let entries = allEntries(for: num)
        let preferredKey = num.hasPrefix("H") ? preferredHebrew : preferredGreek

        return entries.sorted { e1, e2 in
            if e1.lexiconKey == preferredKey && e2.lexiconKey != preferredKey {
                return true
            }
            if e2.lexiconKey == preferredKey && e1.lexiconKey != preferredKey {
                return false
            }
            return false
        }
    }
}

// MARK: - Single Entry Page View

struct LexiconPageView: View {
    let entries: [LexiconEntry]  // All entries for multiple Strong's numbers
    let morphology: String?
    var translation: Translation? = nil
    var onSearchStrongs: ((String) -> Void)? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    LexiconEntryView(entry: entry, translation: translation, onSearchStrongs: onSearchStrongs, onNavigateToVerse: onNavigateToVerse)

                    if entry.id != entries.last?.id {
                        Divider()
                    }
                }

                if let morph = morphology, !morph.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Morphology")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(morph)
                            .font(.caption.monospaced())
                    }
                }
            }
            .padding()
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
    let translation: Translation
    let fontSize: Int
    let onNavigateToVerse: (Int) -> Void

    @State private var isPresented: Bool = true
    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SearchView(
            isPresented: $isPresented,
            translation: translation,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            initialSearchText: strongsNum,
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

struct LexiconSheetView: View {
    let word: String
    let strongs: [String]
    let morphology: String?
    let translation: Translation?
    var onNavigateToVerse: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var searchItem: StrongsSearchItem? = nil
    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = false

    private var user: User {
        RealmManager.shared.realm.objects(User.self).first!
    }

    /// Get unique lexicon keys available across all Strong's numbers
    private var availableLexicons: [String] {
        var lexicons: Set<String> = []
        for num in strongs {
            let entries = LexiconLookup.allEntries(for: num)
            for entry in entries {
                lexicons.insert(entry.lexiconKey)
            }
        }

        // Sort with preferred lexicon first
        let isHebrew = strongs.first?.hasPrefix("H") ?? false
        let preferredKey = isHebrew ? user.hebrewLexicon : user.greekLexicon

        return lexicons.sorted { l1, l2 in
            if l1 == preferredKey { return true }
            if l2 == preferredKey { return false }
            return l1 < l2
        }
    }

    /// Get entries for a specific lexicon
    private func entries(for lexiconKey: String) -> [LexiconEntry] {
        var result: [LexiconEntry] = []
        for num in strongs {
            let allEntries = LexiconLookup.allEntries(for: num)
            if let entry = allEntries.first(where: { $0.lexiconKey == lexiconKey }) {
                result.append(entry)
            }
        }
        return result
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
                if availableLexicons.count > 1 {
                    // Swipeable pages for multiple lexicons
                    TabView(selection: $currentPage) {
                        ForEach(Array(availableLexicons.enumerated()), id: \.offset) { index, lexiconKey in
                            LexiconPageView(
                                entries: entries(for: lexiconKey),
                                morphology: morphology,
                                translation: translation,
                                onSearchStrongs: translation != nil ? openSearch : nil,
                                onNavigateToVerse: handleNavigateToVerse
                            )
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    // Pill page indicator
                    HStack(spacing: 8) {
                        ForEach(Array(availableLexicons.enumerated()), id: \.offset) { index, _ in
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
                    if let lexiconKey = availableLexicons.first {
                        LexiconPageView(
                            entries: entries(for: lexiconKey),
                            morphology: morphology,
                            translation: translation,
                            onSearchStrongs: translation != nil ? openSearch : nil,
                            onNavigateToVerse: handleNavigateToVerse
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
            .sheet(item: $searchItem) { item in
                if let tr = translation {
                    LexiconSearchSheet(
                        strongsNum: item.strongsNum,
                        translation: tr,
                        fontSize: Int(user.readerFontSize),
                        onNavigateToVerse: handleNavigateToVerse
                    )
                }
            }
        }
    }
}

// MARK: - Lexicon Popover Content (simplified, single lexicon)

struct LexiconPopoverContent: View {
    let word: String
    let strongs: [String]
    let morphology: String?

    private var user: User {
        RealmManager.shared.realm.objects(User.self).first!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(word)
                    .font(.headline)
                Spacer()
                Text(strongs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Entries (preferred lexicon only for popover)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(strongs, id: \.self) { num in
                        let entries = LexiconLookup.sortedEntries(
                            for: num,
                            preferredGreek: user.greekLexicon,
                            preferredHebrew: user.hebrewLexicon
                        )
                        if let entry = entries.first {
                            LexiconEntryView(entry: entry)

                            if num != strongs.last {
                                Divider()
                            }
                        } else {
                            Text("Entry not found: \(num)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Morphology section
                    if let morph = morphology, !morph.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Morphology")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(morph)
                                .font(.caption.monospaced())
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

// MARK: - BDB References View

struct BDBRefsView: View {
    let refs: String
    var onNavigateToVerse: ((Int) -> Void)?

    private struct ParsedRef: Identifiable {
        let id = UUID()
        let displayText: String
        let verseId: Int?
    }

    private var parsedRefs: [ParsedRef] {
        // Split by ", " and parse each ref
        refs.split(separator: ",").map { ref in
            let trimmed = ref.trimmingCharacters(in: .whitespaces)
            if let parsed = parseOsisRef(trimmed) {
                return ParsedRef(displayText: parsed.display, verseId: parsed.verseId)
            } else {
                return ParsedRef(displayText: trimmed, verseId: nil)
            }
        }
    }

    /// Parse OSIS-style reference like "1Kgs.16.9" to display text and verse ID
    private func parseOsisRef(_ ref: String) -> (display: String, verseId: Int)? {
        let parts = ref.split(separator: ".")
        guard parts.count >= 3 else { return nil }

        let bookAbbrev = String(parts[0])
        guard let chapter = Int(parts[1]),
              let verse = Int(parts[2]) else { return nil }

        // Look up book by osisId or osisParatextAbbreviation
        let realm = RealmManager.shared.realm
        guard let book = realm.objects(Book.self)
            .filter("osisId == %@ OR osisParatextAbbreviation == %@", bookAbbrev, bookAbbrev)
            .first else { return nil }

        let verseId = book.id * 1000000 + chapter * 1000 + verse
        let display = "\(book.osisId) \(chapter):\(verse)"

        return (display: display, verseId: verseId)
    }

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(parsedRefs.enumerated()), id: \.offset) { index, ref in
                HStack(spacing: 0) {
                    if let verseId = ref.verseId {
                        BDBRefButton(displayText: ref.displayText, verseId: verseId, onNavigateToVerse: onNavigateToVerse)
                    } else {
                        Text(ref.displayText)
                            .font(.caption)
                    }
                    if index < parsedRefs.count - 1 {
                        Text(", ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BDBRefButton: View {
    let displayText: String
    let verseId: Int
    var onNavigateToVerse: ((Int) -> Void)?
    @State private var showingPopover: Bool = false
    @State private var contentHeight: CGFloat = 200

    private var translation: Translation? {
        RealmManager.shared.realm.objects(User.self).first?.readerTranslation
    }

    private var verses: [Verse] {
        guard let tr = translation else { return [] }
        return Array(RealmManager.shared.realm.objects(Verse.self)
            .filter("tr == \(tr.id) AND id == \(verseId)"))
    }

    private var inlineVerseText: AttributedString {
        var result = AttributedString()

        for (index, verse) in verses.enumerated() {
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4
            result.append(verseNum)
            result.append(AttributedString(" "))

            var verseText = AttributedString(stripStrongsAnnotations(verse.t))
            verseText.font = .body
            result.append(verseText)

            if index < verses.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(displayText)
                .font(.caption)
                .foregroundColor(.accentColor)
        }
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: displayText,
                verseText: inlineVerseText,
                onNavigate: onNavigateToVerse != nil ? {
                    showingPopover = false
                    onNavigateToVerse?(verseId)
                } : nil,
                contentHeight: $contentHeight
            )
        }
    }
}
