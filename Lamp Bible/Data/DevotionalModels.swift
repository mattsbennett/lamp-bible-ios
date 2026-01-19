//
//  DevotionalModels.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import GRDB

// MARK: - Devotional Category

enum DevotionalCategory: String, Codable, CaseIterable {
    case devotional
    case exhortation
    case reflection
    case study
    case prayer
    case other

    var displayName: String {
        switch self {
        case .devotional: return "Devotional"
        case .exhortation: return "Exhortation"
        case .reflection: return "Reflection"
        case .study: return "Study"
        case .prayer: return "Prayer"
        case .other: return "Other"
        }
    }
}

// MARK: - Devotional Annotation Types

enum DevotionalAnnotationType: String, Codable {
    case scripture
    case strongs
    case greek
    case hebrew
    case link
    case emphasis
    case quote
}

enum DevotionalEmphasisStyle: String, Codable {
    case bold
    case italic
    case underline
}

// MARK: - Devotional Annotation Data

struct DevotionalAnnotationData: Codable, Equatable {
    var sv: Int?                    // Start verse ref (BBCCCVVV) for scripture annotations
    var ev: Int?                    // End verse ref for ranges
    var refs: [DevotionalVerseRef]? // Array of discrete verse references
    var strongs: String?            // Strong's number (e.g., G1080, H1234)
    var url: String?                // External URL for link annotations
    var style: DevotionalEmphasisStyle? // Emphasis style
    var source: String?             // Attribution for quote annotations
    var translationId: String?      // Translation ID for scripture annotations (e.g., "NIV", "ESV")
}

struct DevotionalVerseRef: Codable, Equatable {
    var sv: Int                     // Start verse ref (BBCCCVVV)
    var ev: Int?                    // End verse ref for ranges
}

// MARK: - Devotional Annotation

struct DevotionalAnnotation: Codable, Equatable {
    var type: DevotionalAnnotationType
    var start: Int                  // Character offset start position
    var end: Int                    // Character offset end position
    var text: String?               // The annotated text itself
    var data: DevotionalAnnotationData?
}

// MARK: - Footnote Reference

struct DevotionalFootnoteRef: Codable, Equatable {
    var id: String                  // Footnote ID (matches footnotes[].id)
    var offset: Int                 // Character offset where footnote marker belongs
}

// MARK: - Annotated Text

struct DevotionalAnnotatedText: Codable, Equatable {
    var text: String                // Plain text content
    var annotations: [DevotionalAnnotation]?
    var footnoteRefs: [DevotionalFootnoteRef]?

    /// Alias for text property (for consistency with DevotionalTextField.plainText)
    var plainText: String { text }

    enum CodingKeys: String, CodingKey {
        case text, annotations
        case footnoteRefs = "footnote_refs"
    }

    init(text: String = "", annotations: [DevotionalAnnotation]? = nil, footnoteRefs: [DevotionalFootnoteRef]? = nil) {
        self.text = text
        self.annotations = annotations
        self.footnoteRefs = footnoteRefs
    }
}

// MARK: - Flexible Text Field (supports both plain string and annotated)

enum DevotionalTextField: Codable, Equatable {
    case plain(String)
    case annotated(DevotionalAnnotatedText)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
            return
        }
        if let annotated = try? container.decode(DevotionalAnnotatedText.self) {
            self = .annotated(annotated)
            return
        }
        throw DecodingError.typeMismatch(
            DevotionalTextField.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or DevotionalAnnotatedText")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text):
            try container.encode(text)
        case .annotated(let annotated):
            try container.encode(annotated)
        }
    }

    var plainText: String {
        switch self {
        case .plain(let text): return text
        case .annotated(let at): return at.text
        }
    }

    var isEmpty: Bool {
        plainText.isEmpty
    }

    static func text(_ string: String) -> DevotionalTextField {
        .plain(string)
    }
}

// MARK: - Footnote

struct DevotionalFootnote: Codable, Identifiable, Equatable {
    var id: String
    var content: DevotionalTextField

    var plainText: String {
        content.plainText
    }
}

// MARK: - List Item

struct DevotionalListItem: Codable, Equatable {
    var content: DevotionalAnnotatedText
    var children: [DevotionalListItem]?
}

// MARK: - Content Block Types

enum DevotionalBlockType: String, Codable {
    case paragraph
    case list
    case blockquote
    case heading
}

enum DevotionalListType: String, Codable {
    case bullet
    case numbered
}

// MARK: - Content Block

struct DevotionalContentBlock: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString  // For SwiftUI identification
    var type: DevotionalBlockType
    var content: DevotionalAnnotatedText?   // For paragraph, blockquote, heading
    var level: Int?                         // Heading level (1-6)
    var listType: DevotionalListType?       // For list blocks
    var items: [DevotionalListItem]?        // For list blocks

    enum CodingKeys: String, CodingKey {
        case type, content, level, listType, items
    }

    init(type: DevotionalBlockType, content: DevotionalAnnotatedText? = nil, level: Int? = nil, listType: DevotionalListType? = nil, items: [DevotionalListItem]? = nil) {
        self.type = type
        self.content = content
        self.level = level
        self.listType = listType
        self.items = items
    }

    // Convenience initializers
    static func paragraph(_ text: String) -> DevotionalContentBlock {
        DevotionalContentBlock(type: .paragraph, content: DevotionalAnnotatedText(text: text))
    }

    static func heading(_ text: String, level: Int) -> DevotionalContentBlock {
        DevotionalContentBlock(type: .heading, content: DevotionalAnnotatedText(text: text), level: level)
    }

    static func blockquote(_ text: String) -> DevotionalContentBlock {
        DevotionalContentBlock(type: .blockquote, content: DevotionalAnnotatedText(text: text))
    }

    static func bulletList(_ items: [String]) -> DevotionalContentBlock {
        DevotionalContentBlock(
            type: .list,
            listType: .bullet,
            items: items.map { DevotionalListItem(content: DevotionalAnnotatedText(text: $0)) }
        )
    }

    static func numberedList(_ items: [String]) -> DevotionalContentBlock {
        DevotionalContentBlock(
            type: .list,
            listType: .numbered,
            items: items.map { DevotionalListItem(content: DevotionalAnnotatedText(text: $0)) }
        )
    }
}

// MARK: - Section

struct DevotionalSection: Codable, Equatable, Identifiable {
    var id: String?
    var level: Int?
    var title: String
    var blocks: [DevotionalContentBlock]?
    var subsections: [DevotionalSection]?
}

// MARK: - Structured Content

struct DevotionalStructuredContent: Codable, Equatable {
    var introduction: [DevotionalContentBlock]?
    var sections: [DevotionalSection]?
    var conclusion: [DevotionalContentBlock]?
}

// MARK: - Content (either flat blocks or structured)

enum DevotionalContent: Codable, Equatable {
    case blocks([DevotionalContentBlock])
    case structured(DevotionalStructuredContent)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let blocks = try? container.decode([DevotionalContentBlock].self) {
            self = .blocks(blocks)
            return
        }
        if let structured = try? container.decode(DevotionalStructuredContent.self) {
            self = .structured(structured)
            return
        }
        throw DecodingError.typeMismatch(
            DevotionalContent.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected [DevotionalContentBlock] or DevotionalStructuredContent")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .blocks(let blocks):
            try container.encode(blocks)
        case .structured(let structured):
            try container.encode(structured)
        }
    }

    /// Get all blocks flattened (for search text extraction)
    var allBlocks: [DevotionalContentBlock] {
        switch self {
        case .blocks(let blocks):
            return blocks
        case .structured(let s):
            var result: [DevotionalContentBlock] = []
            if let intro = s.introduction {
                result.append(contentsOf: intro)
            }
            if let sections = s.sections {
                for section in sections {
                    result.append(contentsOf: collectBlocks(from: section))
                }
            }
            if let conclusion = s.conclusion {
                result.append(contentsOf: conclusion)
            }
            return result
        }
    }

    private func collectBlocks(from section: DevotionalSection) -> [DevotionalContentBlock] {
        var result: [DevotionalContentBlock] = []
        if let blocks = section.blocks {
            result.append(contentsOf: blocks)
        }
        if let subsections = section.subsections {
            for sub in subsections {
                result.append(contentsOf: collectBlocks(from: sub))
            }
        }
        return result
    }
}

// MARK: - Key Scripture Reference

struct DevotionalKeyScripture: Codable, Equatable {
    var sv: Int                     // Start verse ref (BBCCCVVV)
    var ev: Int?                    // End verse ref
    var label: String?              // Human-readable reference (e.g., 'John 3:16-17')
}

// MARK: - Series Info

struct DevotionalSeriesInfo: Codable, Equatable {
    var id: String?
    var name: String?
    var order: Int?
}

// MARK: - Devotional Metadata

struct DevotionalMeta: Codable, Equatable {
    var schemaVersion: String = "1.0"
    var id: String
    var type: String = "devotional"
    var title: String
    var subtitle: String?
    var author: String?
    var date: String?               // ISO 8601 format: YYYY-MM-DD
    var tags: [String]?
    var category: DevotionalCategory?
    var series: DevotionalSeriesInfo?
    var keyScriptures: [DevotionalKeyScripture]?
    var created: Int?               // Unix timestamp
    var lastModified: Int?          // Unix timestamp

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        author: String? = nil,
        date: String? = nil,
        tags: [String]? = nil,
        category: DevotionalCategory? = nil,
        series: DevotionalSeriesInfo? = nil,
        keyScriptures: [DevotionalKeyScripture]? = nil,
        created: Int? = nil,
        lastModified: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.date = date
        self.tags = tags
        self.category = category
        self.series = series
        self.keyScriptures = keyScriptures
        self.created = created ?? Int(Date().timeIntervalSince1970)
        self.lastModified = lastModified ?? Int(Date().timeIntervalSince1970)
    }
}

// MARK: - Devotional (Main Model)

struct Devotional: Codable, Identifiable, Equatable, Hashable {
    var meta: DevotionalMeta
    var summary: DevotionalTextField?
    var content: DevotionalContent
    var footnotes: [DevotionalFootnote]?
    var relatedDevotionals: [String]?

    // Identifiable conformance (not stored, derived from meta.id)
    var id: String { meta.id }

    // Hashable conformance (use id for hashing)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Exclude computed `id` from Codable
    enum CodingKeys: String, CodingKey {
        case meta, summary, content, footnotes, relatedDevotionals
    }

    init(
        meta: DevotionalMeta,
        summary: DevotionalTextField? = nil,
        content: DevotionalContent,
        footnotes: [DevotionalFootnote]? = nil,
        relatedDevotionals: [String]? = nil
    ) {
        self.meta = meta
        self.summary = summary
        self.content = content
        self.footnotes = footnotes
        self.relatedDevotionals = relatedDevotionals
    }

    /// Create a new empty devotional
    static func newEmpty(title: String = "Untitled") -> Devotional {
        Devotional(
            meta: DevotionalMeta(title: title),
            content: .blocks([.paragraph("")])
        )
    }

    /// Extract plain text for search indexing
    var searchText: String {
        var parts: [String] = [meta.title]

        if let subtitle = meta.subtitle {
            parts.append(subtitle)
        }

        if let summary = summary {
            parts.append(summary.plainText)
        }

        for block in content.allBlocks {
            if let text = block.content?.text {
                parts.append(text)
            }
            if let items = block.items {
                parts.append(contentsOf: extractListText(items))
            }
        }

        if let footnotes = footnotes {
            for fn in footnotes {
                parts.append(fn.plainText)
            }
        }

        return parts.joined(separator: " ")
    }

    private func extractListText(_ items: [DevotionalListItem]) -> [String] {
        var result: [String] = []
        for item in items {
            result.append(item.content.text)
            if let children = item.children {
                result.append(contentsOf: extractListText(children))
            }
        }
        return result
    }
}

// MARK: - Devotional Module File (for sync)

struct DevotionalModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var isEditable: Bool?
    var entries: [Devotional]

    init(
        id: String,
        name: String,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        type: String = "devotional",
        isEditable: Bool? = nil,
        entries: [Devotional]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.type = type
        self.isEditable = isEditable
        self.entries = entries
    }
}

// MARK: - Database Entry (flattened for GRDB)

struct DevotionalEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "devotional_entries"

    var id: String                  // UUID
    var moduleId: String
    var title: String
    var subtitle: String?
    var author: String?
    var date: String?               // ISO 8601 (YYYY-MM-DD)
    var tags: String?               // Comma-separated
    var category: String?
    var seriesId: String?
    var seriesName: String?
    var seriesOrder: Int?
    var keyScripturesJson: String?
    var summaryJson: String?
    var contentJson: String
    var footnotesJson: String?
    var relatedIds: String?         // Comma-separated UUIDs
    var created: Int
    var lastModified: Int?
    var searchText: String?
    var recordChangeTag: String?  // CloudKit record change tag for sync

    enum CodingKeys: String, CodingKey {
        case id
        case moduleId = "module_id"
        case title, subtitle, author, date, tags, category
        case seriesId = "series_id"
        case seriesName = "series_name"
        case seriesOrder = "series_order"
        case keyScripturesJson = "key_scriptures_json"
        case summaryJson = "summary_json"
        case contentJson = "content_json"
        case footnotesJson = "footnotes_json"
        case relatedIds = "related_ids"
        case created
        case lastModified = "last_modified"
        case searchText = "search_text"
        case recordChangeTag = "record_change_tag"
    }

    /// Convert from Devotional model
    init(from devotional: Devotional, moduleId: String) {
        self.id = devotional.meta.id
        self.moduleId = moduleId
        self.title = devotional.meta.title
        self.subtitle = devotional.meta.subtitle
        self.author = devotional.meta.author
        self.date = devotional.meta.date
        self.tags = devotional.meta.tags?.joined(separator: ",")
        self.category = devotional.meta.category?.rawValue
        self.seriesId = devotional.meta.series?.id
        self.seriesName = devotional.meta.series?.name
        self.seriesOrder = devotional.meta.series?.order
        self.keyScripturesJson = devotional.meta.keyScriptures.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.summaryJson = devotional.summary.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.contentJson = (try? JSONEncoder().encode(devotional.content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.footnotesJson = devotional.footnotes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.relatedIds = devotional.relatedDevotionals?.joined(separator: ",")
        self.created = devotional.meta.created ?? Int(Date().timeIntervalSince1970)
        self.lastModified = devotional.meta.lastModified ?? Int(Date().timeIntervalSince1970)
        self.searchText = devotional.searchText
    }

    /// Simple init for backward compatibility (plain text content)
    init(
        id: String = UUID().uuidString,
        moduleId: String,
        monthDay: String? = nil,
        tags: [String]? = nil,
        title: String,
        content: String,
        verseRefs: [Int]? = nil,
        lastModified: Int? = nil
    ) {
        self.id = id
        self.moduleId = moduleId
        self.title = title
        self.subtitle = nil
        self.author = nil
        self.date = monthDay
        self.tags = tags?.joined(separator: ",")
        self.category = nil
        self.seriesId = nil
        self.seriesName = nil
        self.seriesOrder = nil
        self.keyScripturesJson = verseRefs.flatMap { refs in
            let scriptures = refs.map { DevotionalKeyScripture(sv: $0, ev: nil, label: nil) }
            return try? JSONEncoder().encode(scriptures)
        }.flatMap { String(data: $0, encoding: .utf8) }
        self.summaryJson = nil
        // Store plain text as a single paragraph block
        let block = DevotionalContentBlock(type: .paragraph, content: DevotionalAnnotatedText(text: content))
        self.contentJson = (try? JSONEncoder().encode(DevotionalContent.blocks([block]))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.footnotesJson = nil
        self.relatedIds = nil
        self.created = lastModified ?? Int(Date().timeIntervalSince1970)
        self.lastModified = lastModified ?? Int(Date().timeIntervalSince1970)
        self.searchText = content
    }

    /// Convert to Devotional model
    func toDevotional() -> Devotional? {
        guard let contentData = contentJson.data(using: .utf8),
              let content = try? JSONDecoder().decode(DevotionalContent.self, from: contentData) else {
            return nil
        }

        let keyScriptures: [DevotionalKeyScripture]? = keyScripturesJson.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([DevotionalKeyScripture].self, from: data)
        }

        let summary: DevotionalTextField? = summaryJson.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DevotionalTextField.self, from: data)
        }

        let footnotes: [DevotionalFootnote]? = footnotesJson.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([DevotionalFootnote].self, from: data)
        }

        let series: DevotionalSeriesInfo? = {
            guard seriesId != nil || seriesName != nil || seriesOrder != nil else { return nil }
            return DevotionalSeriesInfo(id: seriesId, name: seriesName, order: seriesOrder)
        }()

        let meta = DevotionalMeta(
            id: id,
            title: title,
            subtitle: subtitle,
            author: author,
            date: date,
            tags: tags?.split(separator: ",").map { String($0) },
            category: category.flatMap { DevotionalCategory(rawValue: $0) },
            series: series,
            keyScriptures: keyScriptures,
            created: created,
            lastModified: lastModified
        )

        return Devotional(
            meta: meta,
            summary: summary,
            content: content,
            footnotes: footnotes,
            relatedDevotionals: relatedIds?.split(separator: ",").map { String($0) }
        )
    }

    /// Get tags as array
    var tagsArray: [String] {
        tags?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
    }

    /// Backward-compatible alias for tagsArray
    var tagList: [String] { tagsArray }

    /// Backward-compatible alias for date (legacy monthDay format)
    var monthDay: String? { date }

    /// Get plain text content for display (backward compatibility)
    var content: String {
        searchText ?? extractPlainText()
    }

    /// Extract plain text from contentJson for display
    private func extractPlainText() -> String {
        guard let data = contentJson.data(using: .utf8),
              let content = try? JSONDecoder().decode(DevotionalContent.self, from: data) else {
            return ""
        }

        var texts: [String] = []
        switch content {
        case .blocks(let blocks):
            for block in blocks {
                if let text = block.content?.plainText {
                    texts.append(text)
                }
            }
        case .structured(let structured):
            if let intro = structured.introduction {
                for block in intro {
                    if let text = block.content?.plainText {
                        texts.append(text)
                    }
                }
            }
            if let sections = structured.sections {
                for section in sections {
                    texts.append(contentsOf: extractTextFromSection(section))
                }
            }
            if let conclusion = structured.conclusion {
                for block in conclusion {
                    if let text = block.content?.plainText {
                        texts.append(text)
                    }
                }
            }
        }
        return texts.joined(separator: "\n\n")
    }

    private func extractTextFromSection(_ section: DevotionalSection) -> [String] {
        var texts: [String] = []
        texts.append(section.title)
        if let blocks = section.blocks {
            for block in blocks {
                if let text = block.content?.plainText {
                    texts.append(text)
                }
            }
        }
        if let subsections = section.subsections {
            for subsection in subsections {
                texts.append(contentsOf: extractTextFromSection(subsection))
            }
        }
        return texts
    }

    /// Get parsed date
    var parsedDate: Date? {
        guard let dateStr = date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting
        return formatter.date(from: dateStr)
    }
}

// MARK: - Conflict Model

struct DevotionalConflict: Identifiable {
    let id: String
    let localEntry: Devotional
    let cloudEntry: Devotional

    var localDate: Date? {
        guard let ts = localEntry.meta.lastModified else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    var cloudDate: Date? {
        guard let ts = cloudEntry.meta.lastModified else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    var title: String {
        localEntry.meta.title
    }
}

// MARK: - Sync Merge Result

struct DevotionalSyncMergeResult {
    var entriesToSave: [Devotional]
    var conflicts: [DevotionalConflict]
    var cloudMergeCount: Int
    var localKeptCount: Int
}

// MARK: - Conflict Resolution

enum DevotionalConflictResolution {
    case keepLocal
    case keepCloud
    case keepBoth
}

// MARK: - Sort Options

enum DevotionalSortOption: String, CaseIterable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case titleAZ = "Title (A-Z)"
    case titleZA = "Title (Z-A)"
    case lastModified = "Last Modified"
}

// MARK: - Filter Options

struct DevotionalFilterOptions {
    var tags: Set<String> = []
    var categories: Set<DevotionalCategory> = []
    var dateRange: ClosedRange<Date>?
    var searchQuery: String = ""

    var isEmpty: Bool {
        tags.isEmpty && categories.isEmpty && dateRange == nil && searchQuery.isEmpty
    }
}
