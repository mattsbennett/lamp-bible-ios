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
    case image
    case audio
    case table
}

// MARK: - Table Data

struct DevotionalTableData: Codable, Equatable {
    var headers: [String]
    var rows: [[String]]
}

// MARK: - Media Types

enum DevotionalMediaType: String, Codable {
    case image
    case audio
}

enum ImageAlignment: String, Codable {
    case left
    case center
    case right
    case full
}

/// Media reference for image/audio files embedded in devotionals
struct DevotionalMediaReference: Codable, Identifiable, Equatable {
    let id: String
    var type: DevotionalMediaType
    var filename: String
    var mimeType: String
    var size: Int?
    var width: Int?                     // Images only
    var height: Int?                    // Images only
    var duration: Double?               // Audio only (seconds)
    var waveform: [Float]?              // Audio only (0-1 normalized samples)
    var transcription: String?          // Audio only (speech-to-text)
    var alt: String?                    // Images only (accessibility)
    var created: Int?

    init(
        id: String = UUID().uuidString,
        type: DevotionalMediaType,
        filename: String,
        mimeType: String,
        size: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        waveform: [Float]? = nil,
        transcription: String? = nil,
        alt: String? = nil,
        created: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.waveform = waveform
        self.transcription = transcription
        self.alt = alt
        self.created = created ?? Int(Date().timeIntervalSince1970)
    }
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

    // Media block properties
    var mediaId: String?                    // Reference to media in Devotional.media array
    var caption: DevotionalAnnotatedText?   // Caption for image/audio
    var alignment: ImageAlignment?          // Image alignment
    var showWaveform: Bool?                 // Audio: show waveform visualization
    var autoplay: Bool?                     // Audio: autoplay in present mode

    // Table block properties
    var tableData: DevotionalTableData?     // For table blocks

    enum CodingKeys: String, CodingKey {
        case type, content, level, listType, items
        case mediaId, caption, alignment, showWaveform, autoplay
        case tableData
    }

    init(
        type: DevotionalBlockType,
        content: DevotionalAnnotatedText? = nil,
        level: Int? = nil,
        listType: DevotionalListType? = nil,
        items: [DevotionalListItem]? = nil,
        mediaId: String? = nil,
        caption: DevotionalAnnotatedText? = nil,
        alignment: ImageAlignment? = nil,
        showWaveform: Bool? = nil,
        autoplay: Bool? = nil,
        tableData: DevotionalTableData? = nil
    ) {
        self.type = type
        self.content = content
        self.level = level
        self.listType = listType
        self.items = items
        self.mediaId = mediaId
        self.caption = caption
        self.alignment = alignment
        self.showWaveform = showWaveform
        self.autoplay = autoplay
        self.tableData = tableData
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

    static func image(mediaId: String, caption: String? = nil, alignment: ImageAlignment = .center) -> DevotionalContentBlock {
        DevotionalContentBlock(
            type: .image,
            mediaId: mediaId,
            caption: caption.map { DevotionalAnnotatedText(text: $0) },
            alignment: alignment
        )
    }

    static func audio(mediaId: String, caption: String? = nil, showWaveform: Bool = true, autoplay: Bool = false) -> DevotionalContentBlock {
        DevotionalContentBlock(
            type: .audio,
            mediaId: mediaId,
            caption: caption.map { DevotionalAnnotatedText(text: $0) },
            showWaveform: showWaveform,
            autoplay: autoplay
        )
    }

    static func table(headers: [String], rows: [[String]]) -> DevotionalContentBlock {
        DevotionalContentBlock(
            type: .table,
            tableData: DevotionalTableData(headers: headers, rows: rows)
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
    var media: [DevotionalMediaReference]?  // Embedded media files
    var markdownContent: String?  // Direct markdown storage (preferred over content)

    // Identifiable conformance (not stored, derived from meta.id)
    var id: String { meta.id }

    // Hashable conformance (use id for hashing)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // Exclude computed `id` from Codable
    enum CodingKeys: String, CodingKey {
        case meta, summary, content, footnotes, relatedDevotionals, media, markdownContent
    }

    init(
        meta: DevotionalMeta,
        summary: DevotionalTextField? = nil,
        content: DevotionalContent = .blocks([]),
        footnotes: [DevotionalFootnote]? = nil,
        relatedDevotionals: [String]? = nil,
        media: [DevotionalMediaReference]? = nil,
        markdownContent: String? = nil
    ) {
        self.meta = meta
        self.summary = summary
        self.content = content
        self.footnotes = footnotes
        self.relatedDevotionals = relatedDevotionals
        self.media = media
        self.markdownContent = markdownContent
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
    var mediaJson: String?          // JSON array of DevotionalMediaReference
    var relatedIds: String?         // Comma-separated UUIDs
    var created: Int
    var lastModified: Int?
    var searchText: String?
    var recordChangeTag: String?    // CloudKit record change tag for sync
    var subscriptionId: String?     // Subscription ID if from subscription (nil for local)
    var isReadOnly: Int?            // 1 if read-only (from subscription), 0 or nil for editable

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
        case mediaJson = "media_json"
        case relatedIds = "related_ids"
        case created
        case lastModified = "last_modified"
        case searchText = "search_text"
        case recordChangeTag = "record_change_tag"
        case subscriptionId = "subscription_id"
        case isReadOnly = "is_read_only"
    }

    /// Whether this entry is read-only (from a subscription)
    var isFromSubscription: Bool {
        subscriptionId != nil && isReadOnly == 1
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
        // Store markdown directly if available, otherwise fall back to JSON-encoded blocks
        if let markdown = devotional.markdownContent, !markdown.isEmpty {
            self.contentJson = markdown
        } else {
            self.contentJson = (try? JSONEncoder().encode(devotional.content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        self.footnotesJson = devotional.footnotes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.mediaJson = devotional.media.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.relatedIds = devotional.relatedDevotionals?.joined(separator: ",")
        self.created = devotional.meta.created ?? Int(Date().timeIntervalSince1970)
        self.lastModified = devotional.meta.lastModified ?? Int(Date().timeIntervalSince1970)
        self.searchText = devotional.searchText

        // Debug: Log media persistence
        print("[DevotionalEntry] Saving devotional '\(devotional.meta.title)' with \(devotional.media?.count ?? 0) media items")
        if let media = devotional.media {
            for ref in media {
                print("[DevotionalEntry]   - Media: \(ref.id) -> \(ref.filename)")
            }
        }
        print("[DevotionalEntry] mediaJson: \(self.mediaJson?.prefix(100) ?? "nil")")
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
        self.mediaJson = nil
        self.relatedIds = nil
        self.created = lastModified ?? Int(Date().timeIntervalSince1970)
        self.lastModified = lastModified ?? Int(Date().timeIntervalSince1970)
        self.searchText = content
    }

    /// Convert to Devotional model
    func toDevotional() -> Devotional? {
        // Check if contentJson is markdown (doesn't start with '[' or '{') or JSON
        let trimmed = contentJson.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJson = trimmed.hasPrefix("[") || trimmed.hasPrefix("{")

        let content: DevotionalContent
        var markdownContent: String? = nil

        if isJson {
            // Legacy: JSON-encoded blocks
            guard let contentData = contentJson.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(DevotionalContent.self, from: contentData) else {
                return nil
            }
            content = decoded
        } else {
            // New: Direct markdown storage
            markdownContent = contentJson
            content = .blocks([])  // Empty blocks, markdown is the source of truth
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

        let media: [DevotionalMediaReference]? = mediaJson.flatMap { json in
            guard let data = json.data(using: .utf8) else {
                print("[DevotionalEntry] toDevotional: mediaJson present but failed to convert to data")
                return nil
            }
            do {
                let decoded = try JSONDecoder().decode([DevotionalMediaReference].self, from: data)
                print("[DevotionalEntry] toDevotional: Loaded \(decoded.count) media items for '\(title)'")
                for ref in decoded {
                    print("[DevotionalEntry]   - Media: \(ref.id) -> \(ref.filename)")
                }
                return decoded
            } catch {
                print("[DevotionalEntry] toDevotional: Failed to decode mediaJson: \(error)")
                return nil
            }
        }

        // Debug: Log if mediaJson was nil
        if mediaJson == nil {
            print("[DevotionalEntry] toDevotional: mediaJson is nil for '\(title)'")
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
            relatedDevotionals: relatedIds?.split(separator: ",").map { String($0) },
            media: media,
            markdownContent: markdownContent
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

// MARK: - Publication Models

/// Filter type for determining which devotionals to publish
enum PublicationFilterType: String, Codable, CaseIterable {
    case tag
    case category
    case all  // No filter - publish everything

    var displayName: String {
        switch self {
        case .tag: return "By Tag"
        case .category: return "By Category"
        case .all: return "All Devotionals"
        }
    }
}

/// Represents a published feed of devotionals that others can subscribe to
struct DevotionalPublication: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "devotional_publications"

    let id: String                      // UUID
    var name: String                    // Display name for the publication
    var description: String?
    var filterType: PublicationFilterType
    var filterValues: [String]          // Tag names or category values
    var moduleId: String                // Source module to publish from
    var lastPublished: Date?
    var subscriberCount: Int?           // Optional analytics

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case filterType = "filter_type"
        case filterValues = "filter_values"
        case moduleId = "module_id"
        case lastPublished = "last_published"
        case subscriberCount = "subscriber_count"
    }

    // Custom encoding/decoding for filterValues (array to comma-separated string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        filterType = try container.decode(PublicationFilterType.self, forKey: .filterType)
        moduleId = try container.decode(String.self, forKey: .moduleId)
        subscriberCount = try container.decodeIfPresent(Int.self, forKey: .subscriberCount)

        // Handle filter_values as comma-separated string from database
        if let valuesString = try container.decodeIfPresent(String.self, forKey: .filterValues) {
            filterValues = valuesString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            filterValues = []
        }

        // Handle last_published as Unix timestamp from database
        if let timestamp = try container.decodeIfPresent(Int.self, forKey: .lastPublished) {
            lastPublished = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            lastPublished = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(filterType, forKey: .filterType)
        try container.encode(moduleId, forKey: .moduleId)
        try container.encodeIfPresent(subscriberCount, forKey: .subscriberCount)

        // Encode filter_values as comma-separated string
        try container.encode(filterValues.joined(separator: ","), forKey: .filterValues)

        // Encode last_published as Unix timestamp
        if let date = lastPublished {
            try container.encode(Int(date.timeIntervalSince1970), forKey: .lastPublished)
        }
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        filterType: PublicationFilterType = .all,
        filterValues: [String] = [],
        moduleId: String = "devotionals",
        lastPublished: Date? = nil,
        subscriberCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.filterType = filterType
        self.filterValues = filterValues
        self.moduleId = moduleId
        self.lastPublished = lastPublished
        self.subscriberCount = subscriberCount
    }
}

/// Manifest file stored at publication URL - lightweight metadata for subscribers
struct PublicationManifest: Codable {
    let publicationId: String
    let name: String
    let description: String?
    let lastUpdated: Date
    let entryCount: Int
    let version: Int                    // Increments on each publish

    init(
        publicationId: String,
        name: String,
        description: String? = nil,
        lastUpdated: Date = Date(),
        entryCount: Int = 0,
        version: Int = 1
    ) {
        self.publicationId = publicationId
        self.name = name
        self.description = description
        self.lastUpdated = lastUpdated
        self.entryCount = entryCount
        self.version = version
    }
}

/// Storage type for subscriptions
enum SubscriptionStorageType: String, Codable, CaseIterable {
    case icloud
    case webdav

    var displayName: String {
        switch self {
        case .icloud: return "iCloud"
        case .webdav: return "WebDAV"
        }
    }
}

/// Subscription to someone else's publication
struct DevotionalSubscription: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "devotional_subscriptions"

    let id: String                      // UUID
    var publicationId: String           // ID from manifest
    var name: String                    // From manifest, user can override
    var url: String                     // Full URL to manifest
    var storageType: SubscriptionStorageType
    var lastSynced: Date?
    var lastRemoteVersion: Int?         // Track version for change detection
    var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case publicationId = "publication_id"
        case storageType = "storage_type"
        case lastSynced = "last_synced"
        case lastRemoteVersion = "last_remote_version"
        case isEnabled = "is_enabled"
    }

    // Custom decoding for database types
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        publicationId = try container.decode(String.self, forKey: .publicationId)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        storageType = try container.decode(SubscriptionStorageType.self, forKey: .storageType)
        lastRemoteVersion = try container.decodeIfPresent(Int.self, forKey: .lastRemoteVersion)

        // Handle last_synced as Unix timestamp
        if let timestamp = try container.decodeIfPresent(Int.self, forKey: .lastSynced) {
            lastSynced = Date(timeIntervalSince1970: TimeInterval(timestamp))
        } else {
            lastSynced = nil
        }

        // Handle is_enabled as Int (SQLite boolean)
        let enabledInt = try container.decodeIfPresent(Int.self, forKey: .isEnabled) ?? 1
        isEnabled = enabledInt != 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(publicationId, forKey: .publicationId)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(storageType, forKey: .storageType)
        try container.encodeIfPresent(lastRemoteVersion, forKey: .lastRemoteVersion)

        // Encode last_synced as Unix timestamp
        if let date = lastSynced {
            try container.encode(Int(date.timeIntervalSince1970), forKey: .lastSynced)
        }

        // Encode is_enabled as Int
        try container.encode(isEnabled ? 1 : 0, forKey: .isEnabled)
    }

    init(
        id: String = UUID().uuidString,
        publicationId: String,
        name: String,
        url: String,
        storageType: SubscriptionStorageType,
        lastSynced: Date? = nil,
        lastRemoteVersion: Int? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.publicationId = publicationId
        self.name = name
        self.url = url
        self.storageType = storageType
        self.lastSynced = lastSynced
        self.lastRemoteVersion = lastRemoteVersion
        self.isEnabled = isEnabled
    }
}

/// Result of syncing a subscription
struct SubscriptionSyncResult {
    let subscriptionId: String
    let added: Int
    let updated: Int
    let removed: Int
    let error: Error?

    var isSuccess: Bool { error == nil }

    var summary: String {
        if let error = error {
            return "Error: \(error.localizedDescription)"
        }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

