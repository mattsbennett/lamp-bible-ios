//
//  ModuleModels.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB

// MARK: - Module Type

enum ModuleType: String, Codable, CaseIterable {
    case translation
    case dictionary
    case commentary
    case devotional
    case notes
}

// MARK: - Module Registry

struct Module: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "modules"

    var id: String
    var type: ModuleType
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var filePath: String
    var fileHash: String?
    var lastSynced: Int?
    var isEditable: Bool
    var keyType: String?  // For dictionaries: "strongs-greek", "strongs-hebrew", "custom"
    var createdAt: Int?
    var updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, author, version
        case filePath = "file_path"
        case fileHash = "file_hash"
        case lastSynced = "last_synced"
        case isEditable = "is_editable"
        case keyType = "key_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String = UUID().uuidString,
        type: ModuleType,
        name: String,
        description: String? = nil,
        author: String? = nil,
        version: String? = nil,
        filePath: String,
        fileHash: String? = nil,
        lastSynced: Int? = nil,
        isEditable: Bool = false,
        keyType: String? = nil,
        createdAt: Int? = nil,
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.description = description
        self.author = author
        self.version = version
        self.filePath = filePath
        self.fileHash = fileHash
        self.lastSynced = lastSynced
        self.isEditable = isEditable
        self.keyType = keyType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom encoding for database (convert Bool to Int)
    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["type"] = type.rawValue
        container["name"] = name
        container["description"] = description
        container["author"] = author
        container["version"] = version
        container["file_path"] = filePath
        container["file_hash"] = fileHash
        container["last_synced"] = lastSynced
        container["is_editable"] = isEditable ? 1 : 0
        container["key_type"] = keyType
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    // Custom decoding from database
    init(row: Row) throws {
        id = row["id"]
        type = ModuleType(rawValue: row["type"]) ?? .notes
        name = row["name"]
        description = row["description"]
        author = row["author"]
        version = row["version"]
        filePath = row["file_path"]
        fileHash = row["file_hash"]
        lastSynced = row["last_synced"]
        isEditable = row["is_editable"] == 1
        keyType = row["key_type"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }
}

// MARK: - Dictionary Sense (definition within an entry)

/// A single sense/definition for a dictionary entry
/// Each key (e.g., Strong's number) can have multiple senses
struct DictionarySense: Codable, Identifiable {
    var id: String?  // Optional sense identifier
    var partOfSpeech: String?
    var definition: String?
    var shortDefinition: String?
    var usage: String?
    var derivation: String?
    var references: [VerseRef]?  // Verse references with optional ranges
    var gloss: String?  // Brief gloss/translation

    enum CodingKeys: String, CodingKey {
        case id, partOfSpeech, definition, shortDefinition, usage, derivation, references, gloss
    }

    init(
        id: String? = nil,
        partOfSpeech: String? = nil,
        definition: String? = nil,
        shortDefinition: String? = nil,
        usage: String? = nil,
        derivation: String? = nil,
        references: [VerseRef]? = nil,
        gloss: String? = nil
    ) {
        self.id = id
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.shortDefinition = shortDefinition
        self.usage = usage
        self.derivation = derivation
        self.references = references
        self.gloss = gloss
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle id as either String or Int
        if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = nil
        }

        partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech)
        definition = try container.decodeIfPresent(String.self, forKey: .definition)
        shortDefinition = try container.decodeIfPresent(String.self, forKey: .shortDefinition)
        usage = try container.decodeIfPresent(String.self, forKey: .usage)
        derivation = try container.decodeIfPresent(String.self, forKey: .derivation)
        references = try container.decodeIfPresent([VerseRef].self, forKey: .references)
        gloss = try container.decodeIfPresent(String.self, forKey: .gloss)
    }
}

// MARK: - Dictionary Entry

struct DictionaryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "dictionary_entries"

    var id: String
    var moduleId: String
    var key: String
    var lemma: String
    var transliteration: String?
    var pronunciation: String?
    var sensesJson: String?  // Array of DictionarySense as JSON
    var metadataJson: String?

    enum CodingKeys: String, CodingKey {
        case id, key, lemma, transliteration, pronunciation
        case moduleId = "module_id"
        case sensesJson = "senses_json"
        case metadataJson = "metadata_json"
    }

    init(
        id: String? = nil,
        moduleId: String,
        key: String,
        lemma: String,
        transliteration: String? = nil,
        pronunciation: String? = nil,
        senses: [DictionarySense]? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id ?? "\(moduleId):\(key)"
        self.moduleId = moduleId
        self.key = key
        self.lemma = lemma
        self.transliteration = transliteration
        self.pronunciation = pronunciation
        self.sensesJson = senses.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.metadataJson = metadata.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Convenience initializer for backwards compatibility with single sense
    init(
        id: String? = nil,
        moduleId: String,
        key: String,
        lemma: String,
        transliteration: String? = nil,
        pronunciation: String? = nil,
        partOfSpeech: String?,
        definition: String?,
        shortDefinition: String?,
        usage: String?,
        derivation: String?,
        references: [VerseRef]?,
        metadata: [String: String]? = nil
    ) {
        let sense = DictionarySense(
            partOfSpeech: partOfSpeech,
            definition: definition,
            shortDefinition: shortDefinition,
            usage: usage,
            derivation: derivation,
            references: references
        )
        self.init(
            id: id,
            moduleId: moduleId,
            key: key,
            lemma: lemma,
            transliteration: transliteration,
            pronunciation: pronunciation,
            senses: [sense],
            metadata: metadata
        )
    }

    var senses: [DictionarySense] {
        guard let json = sensesJson, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DictionarySense].self, from: data)) ?? []
    }

    var metadata: [String: String]? {
        guard let json = metadataJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: - Convenience accessors for primary sense (first sense)

    /// Primary definition (from first sense)
    var definition: String? {
        senses.first?.definition
    }

    /// Primary short definition (from first sense)
    var shortDefinition: String? {
        senses.first?.shortDefinition
    }

    /// Primary part of speech (from first sense)
    var partOfSpeech: String? {
        senses.first?.partOfSpeech
    }

    /// Primary usage (from first sense)
    var usage: String? {
        senses.first?.usage
    }

    /// Primary derivation (from first sense)
    var derivation: String? {
        senses.first?.derivation
    }

    /// Primary references (from first sense)
    var references: [VerseRef]? {
        senses.first?.references
    }
}

// MARK: - Commentary Entry

struct CommentaryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "commentary_entries"

    var id: String
    var moduleId: String
    var verseId: Int
    var book: Int
    var chapter: Int
    var verse: Int
    var heading: String?
    var content: String
    var segmentsJson: String?

    enum CodingKeys: String, CodingKey {
        case id, book, chapter, verse, heading, content
        case moduleId = "module_id"
        case verseId = "verse_id"
        case segmentsJson = "segments_json"
    }

    init(
        id: String? = nil,
        moduleId: String,
        verseId: Int,
        heading: String? = nil,
        content: String,
        segments: [[String: Any]]? = nil
    ) {
        self.id = id ?? "\(moduleId):\(verseId)"
        self.moduleId = moduleId
        self.verseId = verseId
        self.book = verseId / 1000000
        self.chapter = (verseId % 1000000) / 1000
        self.verse = verseId % 1000
        self.heading = heading
        self.content = content
        self.segmentsJson = segments.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    var segments: [[String: Any]]? {
        guard let json = segmentsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }
}

// MARK: - Devotional Entry

struct DevotionalEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "devotional_entries"

    var id: String
    var moduleId: String
    var monthDay: String?
    var tags: String?
    var title: String
    var content: String
    var verseRefsJson: String?
    var lastModified: Int?

    enum CodingKeys: String, CodingKey {
        case id, tags, title, content
        case moduleId = "module_id"
        case monthDay = "month_day"
        case verseRefsJson = "verse_refs_json"
        case lastModified = "last_modified"
    }

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
        self.monthDay = monthDay
        self.tags = tags?.joined(separator: ",")
        self.title = title
        self.content = content
        self.verseRefsJson = verseRefs.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.lastModified = lastModified ?? Int(Date().timeIntervalSince1970)
    }

    var tagList: [String] {
        tags?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
    }

    var verseRefs: [Int]? {
        guard let json = verseRefsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }
}

// MARK: - Note Entry

struct NoteEntry: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "note_entries"

    var id: String
    var moduleId: String
    var verseId: Int
    var book: Int
    var chapter: Int
    var verse: Int
    var title: String?
    var content: String
    var verseRefsJson: String?
    var lastModified: Int?

    enum CodingKeys: String, CodingKey {
        case id, book, chapter, verse, title, content
        case moduleId = "module_id"
        case verseId = "verse_id"
        case verseRefsJson = "verse_refs_json"
        case lastModified = "last_modified"
    }

    init(
        id: String = UUID().uuidString,
        moduleId: String,
        verseId: Int,
        title: String? = nil,
        content: String,
        verseRefs: [Int]? = nil,
        lastModified: Int? = nil
    ) {
        self.id = id
        self.moduleId = moduleId
        self.verseId = verseId
        self.book = verseId / 1000000
        self.chapter = (verseId % 1000000) / 1000
        self.verse = verseId % 1000
        self.title = title
        self.content = content
        self.verseRefsJson = verseRefs.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.lastModified = lastModified ?? Int(Date().timeIntervalSince1970)
    }

    var verseRefs: [Int]? {
        guard let json = verseRefsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }
}

// MARK: - JSON Module File Structures

struct ModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: ModuleType
    var isEditable: Bool?
    var keyType: String?  // For dictionaries: "strongs-greek", "strongs-hebrew", "custom"
}

struct DictionaryModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var keyType: String?
    var entries: [DictionaryEntryFile]
}

/// A sense/definition in a JSON file
struct DictionarySenseFile: Codable {
    var id: String?
    var partOfSpeech: String?
    var definition: String?
    var shortDefinition: String?
    var usage: String?
    var derivation: String?
    var references: [VerseRef]?  // Verse refs with optional ranges { sv: 1001001, ev: 1001003 }
    var gloss: String?

    enum CodingKeys: String, CodingKey {
        case id, partOfSpeech, definition, shortDefinition, usage, derivation, references, gloss
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle id as either String or Int
        if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = nil
        }

        partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech)
        definition = try container.decodeIfPresent(String.self, forKey: .definition)
        shortDefinition = try container.decodeIfPresent(String.self, forKey: .shortDefinition)
        usage = try container.decodeIfPresent(String.self, forKey: .usage)
        derivation = try container.decodeIfPresent(String.self, forKey: .derivation)
        references = try container.decodeIfPresent([VerseRef].self, forKey: .references)
        gloss = try container.decodeIfPresent(String.self, forKey: .gloss)
    }

    init(
        id: String? = nil,
        partOfSpeech: String? = nil,
        definition: String? = nil,
        shortDefinition: String? = nil,
        usage: String? = nil,
        derivation: String? = nil,
        references: [VerseRef]? = nil,
        gloss: String? = nil
    ) {
        self.id = id
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.shortDefinition = shortDefinition
        self.usage = usage
        self.derivation = derivation
        self.references = references
        self.gloss = gloss
    }

    func toSense() -> DictionarySense {
        DictionarySense(
            id: id,
            partOfSpeech: partOfSpeech,
            definition: definition,
            shortDefinition: shortDefinition,
            usage: usage,
            derivation: derivation,
            references: references,
            gloss: gloss
        )
    }
}

struct DictionaryEntryFile: Codable {
    var key: String
    var lemma: String
    var transliteration: String?
    var pronunciation: String?
    var senses: [DictionarySenseFile]?

    // Legacy single-sense fields for backwards compatibility
    var partOfSpeech: String?
    var definition: String?
    var shortDefinition: String?
    var usage: String?
    var derivation: String?
    var references: [VerseRef]?  // Verse refs with optional ranges { sv: 1001001, ev: 1001003 }

    /// Returns senses array, converting legacy single-sense format if needed
    func allSenses() -> [DictionarySense] {
        // If senses array is provided, use it
        if let senses = senses, !senses.isEmpty {
            return senses.map { $0.toSense() }
        }

        // Otherwise, create single sense from legacy fields
        let legacySense = DictionarySense(
            partOfSpeech: partOfSpeech,
            definition: definition,
            shortDefinition: shortDefinition,
            usage: usage,
            derivation: derivation,
            references: references
        )

        // Only include if there's actual content
        if legacySense.definition != nil || legacySense.shortDefinition != nil {
            return [legacySense]
        }

        return []
    }
}

struct CommentaryModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var entries: [CommentaryEntryFile]
}

struct CommentaryEntryFile: Codable {
    var verseId: Int
    var heading: String?
    var content: String
    var segments: [[String: Any]]?

    enum CodingKeys: String, CodingKey {
        case verseId, heading, content, segments
    }

    init(verseId: Int, heading: String?, content: String, segments: [[String: Any]]?) {
        self.verseId = verseId
        self.heading = heading
        self.content = content
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verseId = try container.decode(Int.self, forKey: .verseId)
        heading = try container.decodeIfPresent(String.self, forKey: .heading)
        content = try container.decode(String.self, forKey: .content)
        // Segments decoded separately due to Any type
        segments = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verseId, forKey: .verseId)
        try container.encodeIfPresent(heading, forKey: .heading)
        try container.encode(content, forKey: .content)
    }
}

struct DevotionalModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var isEditable: Bool?
    var entries: [DevotionalEntryFile]
}

struct DevotionalEntryFile: Codable {
    var id: String
    var monthDay: String?
    var tags: [String]?
    var title: String
    var content: String
    var verseRefs: [VerseRef]?
    var lastModified: Int?
}

struct NoteModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var isEditable: Bool?
    var entries: [NoteEntryFile]
}

struct NoteEntryFile: Codable {
    var id: String
    var verseId: Int
    var title: String?
    var content: String
    var verseRefs: [VerseRef]?
    var lastModified: Int?
}

struct VerseRef: Codable {
    var sv: Int      // Start verse
    var ev: Int?     // End verse (optional, for ranges)
}

// MARK: - Translation Module File (for iCloud sync)

struct TranslationModuleFile: Codable {
    var id: Int
    var abbreviation: String
    var language: String
    var name: String
    var url: String?
    var license: String?
    var description: String?
    var type: String
    var verses: [TranslationVerseFile]

    enum CodingKeys: String, CodingKey {
        case id, abbreviation, language, name, url, license, description, type, verses
    }
}

struct TranslationVerseFile: Codable {
    var id: Int      // bbcccvvv format
    var b: Int       // book
    var c: Int       // chapter
    var v: Int       // verse
    var t: String    // text (may contain Strong's annotations)
    var cleanText: String?  // clean text without annotations
}

// MARK: - BDB Sense (separate from DictionarySense for BDB-specific format)

/// A single sense/definition for a BDB Hebrew lexicon entry
/// BDB uses a simpler format: id (number), def (with markers), references
struct BDBSense: Codable, Identifiable {
    var id: Int              // Sense number (1, 2, 3...)
    var def: String?         // Sense definition (with ⟦ref⟧, ⟨Strong's⟩, ⦃BDB⦄ markers)
    var references: [VerseRef]?  // Verse references for this sense
}

// MARK: - Commentary Annotation Types

/// Type of inline annotation within commentary text
enum CommentaryAnnotationType: String, Codable {
    case footnote       // Reference to a footnote
    case scripture      // Scripture reference (e.g., Matt 1:1)
    case strongs        // Strong's number reference
    case greek          // Greek text
    case hebrew         // Hebrew text
    case crossref       // Cross-reference
    case abbrev         // Abbreviation
    case page           // Page number marker
}

/// Verse reference within a refs array (for discrete verse lists)
struct VerseRefData: Codable {
    var sv: Int                     // Start verse ref (BBCCCVVV)
    var ev: Int?                    // End verse ref for ranges within the list
}

/// Data associated with a commentary annotation
struct CommentaryAnnotationData: Codable {
    var sv: Int?                    // Start verse ref (BBCCCVVV) for scripture
    var ev: Int?                    // End verse ref for ranges
    var refs: [VerseRefData]?       // Array of discrete verse refs for comma-separated lists like '7:21, 28'
    var strongs: String?            // Strong's number (e.g., G1080, H1234)
    var transliteration: String?    // Transliteration of Greek/Hebrew
    var expansion: String?          // Expanded form of abbreviation
    var pageNum: String?            // Page number
}

/// Inline annotation within commentary text
struct CommentaryAnnotation: Codable {
    var type: CommentaryAnnotationType
    var start: Int                  // Character offset start position
    var end: Int                    // Character offset end position
    var id: String?                 // Reference ID (footnote number, strongs key, etc.)
    var text: String?               // The annotated text itself
    var implicit: Bool?             // True if implicit reference (e.g., 'v. 5') rather than explicit (e.g., 'Rom 10:5')
    var data: CommentaryAnnotationData?
}

/// Reference to a footnote, with position in clean text
struct FootnoteRef: Codable {
    var id: String                  // Footnote ID (matches footnotes[].id)
    var offset: Int                 // Character offset in clean text
}

/// Text content with annotations - the core building block for rich commentary
struct AnnotatedText: Codable {
    var text: String                // Plain text content (footnote numbers stripped for searchability)
    var annotations: [CommentaryAnnotation]?
    var footnoteRefs: [FootnoteRef]?

    enum CodingKeys: String, CodingKey {
        case text, annotations
        case footnoteRefs = "footnote_refs"
    }

    init(text: String = "", annotations: [CommentaryAnnotation]? = nil, footnoteRefs: [FootnoteRef]? = nil) {
        self.text = text
        self.annotations = annotations
        self.footnoteRefs = footnoteRefs
    }
}

/// A footnote with its content
struct CommentaryFootnote: Codable, Identifiable {
    var id: String                  // Footnote identifier (typically a number)
    var content: AnnotatedText
}

/// Abbreviation entry for commentary
struct CommentaryAbbreviation: Codable {
    var abbrev: String
    var expansion: String
    var category: String?           // publication, bible, apocrypha, etc.
}

// MARK: - Commentary Database Records

/// Unit type for commentary content
enum CommentaryUnitType: String, Codable {
    case section
    case pericope
    case verse
}

/// Book-level metadata for a commentary book
struct CommentaryBook: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "commentary_books"

    var id: String                  // module_id:book_number
    var moduleId: String
    var bookNumber: Int             // 1-66
    var seriesFull: String?         // Full series name (e.g., "New International Commentary")
    var seriesAbbrev: String?       // Abbreviated series name (e.g., "NIC")
    var title: String?
    var author: String?
    var editor: String?
    var publisher: String?
    var year: Int?
    var abbreviationsJson: String?  // [{abbrev, expansion, category}]
    var frontMatterJson: String?    // {dedication, editorPreface, authorPreface, introduction, bibliography}
    var indicesJson: String?        // {subjects, authors, scriptures, greekWords, hebrewWords}

    enum CodingKeys: String, CodingKey {
        case id, title, author, editor, publisher, year
        case moduleId = "module_id"
        case bookNumber = "book_number"
        case seriesFull = "series_full"
        case seriesAbbrev = "series_abbrev"
        case abbreviationsJson = "abbreviations_json"
        case frontMatterJson = "front_matter_json"
        case indicesJson = "indices_json"
    }

    init(
        id: String? = nil,
        moduleId: String,
        bookNumber: Int,
        seriesFull: String? = nil,
        seriesAbbrev: String? = nil,
        title: String? = nil,
        author: String? = nil,
        editor: String? = nil,
        publisher: String? = nil,
        year: Int? = nil,
        abbreviations: [CommentaryAbbreviation]? = nil,
        frontMatter: CommentaryFrontMatter? = nil,
        indices: CommentaryIndices? = nil
    ) {
        self.id = id ?? "\(moduleId):\(bookNumber)"
        self.moduleId = moduleId
        self.bookNumber = bookNumber
        self.seriesFull = seriesFull
        self.seriesAbbrev = seriesAbbrev
        self.title = title
        self.author = author
        self.editor = editor
        self.publisher = publisher
        self.year = year
        self.abbreviationsJson = abbreviations.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.frontMatterJson = frontMatter.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.indicesJson = indices.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Computed Properties

    var abbreviations: [CommentaryAbbreviation]? {
        guard let json = abbreviationsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CommentaryAbbreviation].self, from: data)
    }

    var frontMatter: CommentaryFrontMatter? {
        guard let json = frontMatterJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CommentaryFrontMatter.self, from: data)
    }

    var indices: CommentaryIndices? {
        guard let json = indicesJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CommentaryIndices.self, from: data)
    }
}

/// A content unit in commentary (section, pericope, or verse)
struct CommentaryUnit: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "commentary_units"

    var id: String                  // module_id:book:type:identifier
    var moduleId: String
    var book: Int
    var chapter: Int?               // NULL for book-level content
    var sv: Int                     // Start verse (BBCCCVVV)
    var ev: Int?                    // End verse (BBCCCVVV), NULL if single verse
    var unitType: String            // 'section', 'pericope', 'verse'
    var level: Int                  // Nesting level for sections (1=top)
    var parentId: String?           // Parent section/pericope ID
    var title: String?
    var suffix: String?             // For partial verses: 'a', 'b'
    var introductionJson: String?   // AnnotatedText JSON
    var translationJson: String?    // AnnotatedText JSON
    var commentaryJson: String?     // AnnotatedText JSON
    var footnotesJson: String?      // [{id, content: AnnotatedText}]
    var searchText: String          // Plain text for FTS (all fields combined)
    var orderIndex: Int             // Ordering within parent

    enum CodingKeys: String, CodingKey {
        case id, book, chapter, sv, ev, level, title, suffix
        case moduleId = "module_id"
        case unitType = "unit_type"
        case parentId = "parent_id"
        case introductionJson = "introduction_json"
        case translationJson = "translation_json"
        case commentaryJson = "commentary_json"
        case footnotesJson = "footnotes_json"
        case searchText = "search_text"
        case orderIndex = "order_index"
    }

    init(
        id: String? = nil,
        moduleId: String,
        book: Int,
        chapter: Int? = nil,
        sv: Int,
        ev: Int? = nil,
        unitType: CommentaryUnitType,
        level: Int = 1,
        parentId: String? = nil,
        title: String? = nil,
        suffix: String? = nil,
        introduction: AnnotatedText? = nil,
        translation: AnnotatedText? = nil,
        commentary: AnnotatedText? = nil,
        footnotes: [CommentaryFootnote]? = nil,
        orderIndex: Int = 0
    ) {
        let typeStr = unitType.rawValue
        self.id = id ?? "\(moduleId):\(book):\(typeStr):\(sv)"
        self.moduleId = moduleId
        self.book = book
        self.chapter = chapter
        self.sv = sv
        self.ev = ev
        self.unitType = typeStr
        self.level = level
        self.parentId = parentId
        self.title = title
        self.suffix = suffix
        self.introductionJson = introduction.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.translationJson = translation.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.commentaryJson = commentary.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.footnotesJson = footnotes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.orderIndex = orderIndex

        // Build search text from all text fields
        var searchParts: [String] = []
        if let t = title { searchParts.append(t) }
        if let intro = introduction { searchParts.append(intro.text) }
        if let trans = translation { searchParts.append(trans.text) }
        if let comm = commentary { searchParts.append(comm.text) }
        if let notes = footnotes {
            for note in notes {
                searchParts.append(note.content.text)
            }
        }
        self.searchText = searchParts.joined(separator: " ")
    }

    // MARK: - Computed Properties

    var type: CommentaryUnitType {
        CommentaryUnitType(rawValue: unitType) ?? .verse
    }

    var introduction: AnnotatedText? {
        guard let json = introductionJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotatedText.self, from: data)
    }

    var translation: AnnotatedText? {
        guard let json = translationJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotatedText.self, from: data)
    }

    var commentary: AnnotatedText? {
        guard let json = commentaryJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotatedText.self, from: data)
    }

    var footnotes: [CommentaryFootnote]? {
        guard let json = footnotesJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CommentaryFootnote].self, from: data)
    }

    /// Verse for display (computed from sv)
    var verse: Int {
        sv % 1000
    }
}

// MARK: - Commentary Front Matter

struct CommentaryFrontMatter: Codable {
    var dedication: String?
    var editorPreface: AnnotatedText?
    var authorPreface: AnnotatedText?
    var introduction: AnnotatedText?
    var bibliography: [BibliographyEntry]?
}

// MARK: - Commentary Indices

struct CommentaryIndices: Codable {
    var subjects: [String: [String]]?       // Subject -> [references]
    var authors: [String: [String]]?        // Author -> [references]
    var scriptures: [String: [String]]?     // Scripture -> [references]
    var greekWords: [String: [String]]?     // Greek word -> [references]
    var hebrewWords: [String: [String]]?    // Hebrew word -> [references]
}

// MARK: - Commentary JSON File Structures (for import)

/// Metadata for commentary module file
struct CommentaryFileMeta: Codable {
    var schemaVersion: String
    var seriesFull: String      // Full series name (e.g., "New International Commentary")
    var seriesAbbrev: String    // Abbreviated series name (e.g., "NIC")
    var title: String
    var author: String?
    var editor: String?
    var publisher: String?
    var year: Int?
    var isbn: String?
}

/// Commentary for a verse or verse range (in JSON file)
struct VerseCommentaryFile: Codable {
    var sv: Int                     // Start verse in BBCCCVVV format
    var ev: Int?                    // End verse (optional, for verse ranges)
    var suffix: String?             // For partial verses like 'a', 'b'
    var translation: AnnotatedText?
    var commentary: AnnotatedText?
    var footnotes: [CommentaryFootnote]?
}

/// A pericope unit in JSON file
struct PericopeFile: Codable {
    var id: String                  // Pericope identifier like '1:1-17'
    var title: String?
    var sv: Int?                    // Start verse of pericope
    var ev: Int?                    // End verse of pericope
    var introduction: AnnotatedText?
    var translation: AnnotatedText?
    var verses: [VerseCommentaryFile]?
    var footnotes: [CommentaryFootnote]?
}

/// A section in JSON file (can be nested)
struct SectionFile: Codable {
    var id: String
    var title: String
    var level: Int?                 // Nesting level (1=top, 2=sub, etc.)
    var sv: Int?                    // Start verse of section
    var ev: Int?                    // End verse of section
    var introduction: AnnotatedText?
    var subsections: [SectionFile]?
    var pericopae: [PericopeFile]?
}

/// Commentary for a chapter in JSON file
struct ChapterCommentaryFile: Codable {
    var chapter: Int
    var introduction: AnnotatedText?
    var sections: [SectionFile]?
    var pericopae: [PericopeFile]?
    var verses: [VerseCommentaryFile]?
    var footnotes: [CommentaryFootnote]?
}

/// Bibliography entry in front matter
struct BibliographyEntry: Codable {
    var subsection: String?
    var content: AnnotatedText
}

/// Front matter in JSON file
struct FrontMatterFile: Codable {
    var dedication: String?
    var editorPreface: AnnotatedText?
    var authorPreface: AnnotatedText?
    var introduction: AnnotatedText?
    var bibliography: [BibliographyEntry]?
}

/// Indices in JSON file
struct IndicesFile: Codable {
    var subjects: [String: [String]]?
    var authors: [String: [String]]?
    var scriptures: [String: [String]]?
    var greekWords: [String: [String]]?
    var hebrewWords: [String: [String]]?
}

/// Complete commentary book file (per-book JSON format)
struct CommentaryBookFile: Codable {
    var meta: CommentaryFileMeta
    var book: String                // Bible book abbreviation (e.g., Matt, Gen)
    var bookNumber: Int
    var abbreviations: [CommentaryAbbreviation]?
    var frontMatter: FrontMatterFile?
    var chapters: [ChapterCommentaryFile]
    var indices: IndicesFile?

}
