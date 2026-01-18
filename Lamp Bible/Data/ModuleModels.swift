//
//  ModuleModels.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB

// MARK: - Book OSIS Cache

/// Cache for book OSIS IDs and names to avoid repeated database queries
class BookOsisCache {
    static let shared = BookOsisCache()
    private var osisCache: [Int: String] = [:]
    private var nameCache: [Int: String] = [:]

    func getOsisId(for bookId: Int) -> String {
        if let cached = osisCache[bookId] {
            return cached
        }
        let book = try? BundledModuleDatabase.shared.getBook(id: bookId)
        let osisId = book?.osisId ?? ""
        osisCache[bookId] = osisId
        if let name = book?.name {
            nameCache[bookId] = name
        }
        return osisId
    }

    func getName(for bookId: Int) -> String {
        if let cached = nameCache[bookId] {
            return cached
        }
        let book = try? BundledModuleDatabase.shared.getBook(id: bookId)
        let name = book?.name ?? ""
        nameCache[bookId] = name
        if let osisId = book?.osisId {
            osisCache[bookId] = osisId
        }
        return name
    }
}

// MARK: - Module Type

enum ModuleType: String, Codable, CaseIterable {
    case translation
    case dictionary
    case commentary
    case devotional
    case notes
    case plan
}

// MARK: - Bible Metadata

/// Genre/category of Bible books (Law, History, Wisdom, Prophets, Gospels, etc.)
struct BibleGenre: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "genres"

    var id: Int
    var name: String

    enum CodingKeys: String, CodingKey {
        case id, name
    }
}

/// Bible book metadata (Genesis through Revelation)
struct BibleBook: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "books"

    var id: Int                      // Book number (1-66)
    var genre: Int                   // Foreign key to BibleGenre
    var name: String                 // Full name (e.g., "Genesis")
    var osisId: String               // OSIS identifier (e.g., "Gen")
    var osisParatextAbbreviation: String  // Paratext abbreviation (e.g., "GEN")
    var testament: String            // "OT" or "NT"

    enum CodingKeys: String, CodingKey {
        case id, genre, name
        case osisId = "osis_id"
        case osisParatextAbbreviation = "osis_paratext_abbreviation"
        case testament
    }

    /// Check if this is an Old Testament book
    var isOldTestament: Bool {
        testament == "OT"
    }

    /// Check if this is a New Testament book
    var isNewTestament: Bool {
        testament == "NT"
    }
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
    var seriesFull: String?   // For dictionaries: full series name (e.g., "Theological Dictionary of the NT")
    var seriesAbbrev: String? // For dictionaries: abbreviated series name (e.g., "TDNT")
    var seriesId: String?     // For commentaries: foreign key to commentary_series table
    var createdAt: Int?
    var updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, author, version
        case filePath = "file_path"
        case fileHash = "file_hash"
        case lastSynced = "last_synced"
        case isEditable = "is_editable"
        case keyType = "key_type"
        case seriesFull = "series_full"
        case seriesAbbrev = "series_abbrev"
        case seriesId = "series_id"
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
        seriesFull: String? = nil,
        seriesAbbrev: String? = nil,
        seriesId: String? = nil,
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
        self.seriesFull = seriesFull
        self.seriesAbbrev = seriesAbbrev
        self.seriesId = seriesId
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
        container["series_full"] = seriesFull
        container["series_abbrev"] = seriesAbbrev
        container["series_id"] = seriesId
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
        seriesFull = row["series_full"]
        seriesAbbrev = row["series_abbrev"]
        seriesId = row["series_id"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }
}

// MARK: - Translation Usage (word counts from Bible versions)

/// A single translation word with optional count
struct TranslationWord: Codable {
    var word: String
    var count: Int?
}

/// Translation usage data for a specific Bible version
struct TranslationUsage: Codable {
    var version: String  // Bible version abbreviation (KJV, ESV, etc.)
    var translations: [TranslationWord]
}

// MARK: - Dictionary Sense (definition within an entry)

/// A single sense/definition for a dictionary entry
/// Each key (e.g., Strong's number) can have multiple senses
struct DictionarySense: Codable, Identifiable {
    var id: String?  // Optional sense identifier
    var partOfSpeech: String?
    var definition: FlexibleTextField?      // Can be plain string or AnnotatedText (v2.0)
    var shortDefinition: FlexibleTextField? // Can be plain string or AnnotatedText (v2.0)
    var usage: String?
    var derivation: FlexibleTextField?      // Can be plain string or AnnotatedText (v2.0)
    var references: [VerseRef]?  // Verse references with optional ranges
    var gloss: String?  // Brief gloss/translation
    var translationUsages: [TranslationUsage]?  // Word translation usage counts from Bible versions

    enum CodingKeys: String, CodingKey {
        case id, partOfSpeech, definition, shortDefinition, usage, derivation, references, gloss, translationUsages
    }

    // MARK: - Memberwise Init

    init(
        id: String? = nil,
        partOfSpeech: String? = nil,
        definition: FlexibleTextField? = nil,
        shortDefinition: FlexibleTextField? = nil,
        usage: String? = nil,
        derivation: FlexibleTextField? = nil,
        references: [VerseRef]? = nil,
        gloss: String? = nil,
        translationUsages: [TranslationUsage]? = nil
    ) {
        self.id = id
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.shortDefinition = shortDefinition
        self.usage = usage
        self.derivation = derivation
        self.references = references
        self.gloss = gloss
        self.translationUsages = translationUsages
    }

    // MARK: - Custom Decoder (handles id as String/Int, FlexibleTextField for text fields)

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
        usage = try container.decodeIfPresent(String.self, forKey: .usage)
        gloss = try container.decodeIfPresent(String.self, forKey: .gloss)
        references = try container.decodeIfPresent([VerseRef].self, forKey: .references)

        // Decode flexible text fields (can be String or AnnotatedText)
        definition = try container.decodeIfPresent(FlexibleTextField.self, forKey: .definition)
        shortDefinition = try container.decodeIfPresent(FlexibleTextField.self, forKey: .shortDefinition)
        derivation = try container.decodeIfPresent(FlexibleTextField.self, forKey: .derivation)

        // Decode translation usages
        translationUsages = try container.decodeIfPresent([TranslationUsage].self, forKey: .translationUsages)
    }

    // MARK: - Convenience Accessors

    /// Plain text definition for display fallback and search indexing
    var definitionText: String? {
        definition?.plainText
    }

    /// Plain text short definition
    var shortDefinitionText: String? {
        shortDefinition?.plainText
    }

    /// Plain text derivation
    var derivationText: String? {
        derivation?.plainText
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
            definition: definition.map { FlexibleTextField.plain($0) },
            shortDefinition: shortDefinition.map { FlexibleTextField.plain($0) },
            usage: usage,
            derivation: derivation.map { FlexibleTextField.plain($0) },
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
        senses.first?.definitionText
    }

    /// Primary short definition (from first sense)
    var shortDefinition: String? {
        senses.first?.shortDefinitionText
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
        senses.first?.derivationText
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
// Note: DevotionalEntry is defined in DevotionalModels.swift with the full schema

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
    var footnotesJson: String?    // JSON array of UserNotesFootnote
    var searchText: String?       // Combined text for FTS (content + footnotes)
    var recordChangeTag: String?  // CloudKit record change tag for sync

    enum CodingKeys: String, CodingKey {
        case id, book, chapter, verse, title, content
        case moduleId = "module_id"
        case verseId = "verse_id"
        case verseRefsJson = "verse_refs_json"
        case lastModified = "last_modified"
        case footnotesJson = "footnotes_json"
        case searchText = "search_text"
        case recordChangeTag = "record_change_tag"
    }

    init(
        id: String = UUID().uuidString,
        moduleId: String,
        verseId: Int,
        title: String? = nil,
        content: String,
        verseRefs: [Int]? = nil,
        lastModified: Int? = nil,
        footnotes: [UserNotesFootnote]? = nil
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
        self.footnotesJson = footnotes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        // Build search text from content + footnotes
        var searchParts = [content]
        if let notes = footnotes {
            searchParts.append(contentsOf: notes.map { $0.plainText })
        }
        self.searchText = searchParts.joined(separator: " ")
    }

    var verseRefs: [Int]? {
        guard let json = verseRefsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }

    /// Decoded footnotes array
    var footnotes: [UserNotesFootnote]? {
        guard let json = footnotesJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([UserNotesFootnote].self, from: data)
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
    var seriesFull: String?   // Full series name (e.g., "Theological Dictionary of the NT")
    var seriesAbbrev: String? // Abbreviated series name (e.g., "TDNT")
    var entries: [DictionaryEntryFile]
}

/// A sense/definition in a JSON file (v2.0 supports FlexibleTextField for annotated definitions)
struct DictionarySenseFile: Codable {
    var id: String?
    var partOfSpeech: String?
    var definition: FlexibleTextField?      // Can be plain string or AnnotatedText (v2.0)
    var shortDefinition: FlexibleTextField? // Can be plain string or AnnotatedText (v2.0)
    var usage: String?
    var derivation: FlexibleTextField?      // Can be plain string or AnnotatedText (v2.0)
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
        usage = try container.decodeIfPresent(String.self, forKey: .usage)
        gloss = try container.decodeIfPresent(String.self, forKey: .gloss)
        references = try container.decodeIfPresent([VerseRef].self, forKey: .references)

        // Decode flexible text fields (can be String or AnnotatedText)
        definition = try container.decodeIfPresent(FlexibleTextField.self, forKey: .definition)
        shortDefinition = try container.decodeIfPresent(FlexibleTextField.self, forKey: .shortDefinition)
        derivation = try container.decodeIfPresent(FlexibleTextField.self, forKey: .derivation)
    }

    init(
        id: String? = nil,
        partOfSpeech: String? = nil,
        definition: FlexibleTextField? = nil,
        shortDefinition: FlexibleTextField? = nil,
        usage: String? = nil,
        derivation: FlexibleTextField? = nil,
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
        // Wrap plain strings in FlexibleTextField for type compatibility
        let legacySense = DictionarySense(
            partOfSpeech: partOfSpeech,
            definition: definition.map { FlexibleTextField.plain($0) },
            shortDefinition: shortDefinition.map { FlexibleTextField.plain($0) },
            usage: usage,
            derivation: derivation.map { FlexibleTextField.plain($0) },
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

/// Legacy file format for simple devotional modules (plain text content)
struct LegacyDevotionalModuleFile: Codable {
    var id: String
    var name: String
    var description: String?
    var author: String?
    var version: String?
    var type: String
    var isEditable: Bool?
    var entries: [DevotionalEntryFile]
}

/// Legacy entry format for simple devotional entries
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
    var footnotes: [UserNotesFootnote]?
}

// MARK: - User Notes (Commentary-like Schema)

/// Field that can be either plain text or annotated text (for JSON decoding flexibility)
enum AnnotatedTextField: Codable, Equatable {
    case text(String)
    case annotated(AnnotatedText)

    static func == (lhs: AnnotatedTextField, rhs: AnnotatedTextField) -> Bool {
        // Compare by plain text content for simplicity
        lhs.plainText == rhs.plainText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try decoding as string first
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        // Then try as AnnotatedText
        if let annotated = try? container.decode(AnnotatedText.self) {
            self = .annotated(annotated)
            return
        }
        throw DecodingError.typeMismatch(
            AnnotatedTextField.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected String or AnnotatedText")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .annotated(let annotated):
            try container.encode(annotated)
        }
    }

    /// Get plain text content regardless of type
    var plainText: String {
        switch self {
        case .text(let text): return text
        case .annotated(let at): return at.text
        }
    }

    /// Check if content is empty
    var isEmpty: Bool {
        plainText.isEmpty
    }

    /// Create from plain text
    static func plain(_ text: String) -> AnnotatedTextField {
        .text(text)
    }
}

/// Metadata for user notes module
struct UserNotesMeta: Codable {
    var id: String
    var type: String = "notes"
    var name: String?
    var author: String?
    var schemaVersion: String = "1.0"

    enum CodingKeys: String, CodingKey {
        case id, type, name, author
        case schemaVersion = "schemaVersion"
    }

    init(id: String, name: String? = nil, author: String? = nil) {
        self.id = id
        self.name = name
        self.author = author
    }
}

/// Footnote for user notes (same structure as CommentaryFootnote)
struct UserNotesFootnote: Codable, Identifiable {
    var id: String
    var content: AnnotatedTextField

    /// Get plain text content for searching
    var plainText: String {
        content.plainText
    }
}

/// A single verse note with optional end verse for ranges
struct UserNotesVerse: Codable {
    var sv: Int                         // Start verse in BBCCCVVV format
    var ev: Int?                        // End verse for ranges (optional)
    var commentary: AnnotatedTextField  // Note content
    var footnotes: [UserNotesFootnote]?
    var lastModified: Int?

    /// Computed book number
    var book: Int { sv / 1_000_000 }

    /// Computed chapter number
    var chapter: Int { (sv % 1_000_000) / 1000 }

    /// Computed start verse number
    var verse: Int { sv % 1000 }

    /// Computed end verse number (nil if single verse)
    var endVerse: Int? {
        guard let ev = ev else { return nil }
        return ev % 1000
    }

    /// Get plain text content for searching
    var plainText: String {
        commentary.plainText
    }

    /// Build search text combining all text fields
    var searchText: String {
        var parts = [commentary.plainText]
        if let notes = footnotes {
            parts.append(contentsOf: notes.map { $0.plainText })
        }
        return parts.joined(separator: " ")
    }
}

/// Notes for a single chapter
struct UserNotesChapter: Codable {
    var chapter: Int
    var introduction: AnnotatedTextField?   // Chapter-level intro (verse 0)
    var verses: [UserNotesVerse]?
    var footnotes: [UserNotesFootnote]?     // Chapter-level footnotes

    /// Get all verse notes sorted by verse number
    var sortedVerses: [UserNotesVerse] {
        (verses ?? []).sorted { $0.sv < $1.sv }
    }

    /// Get verse note for specific verse
    func verse(_ verseNum: Int, inBook bookNum: Int) -> UserNotesVerse? {
        let targetSv = bookNum * 1_000_000 + chapter * 1000 + verseNum
        return verses?.first { $0.sv == targetSv }
    }

    /// Build search text for this chapter
    var searchText: String {
        var parts: [String] = []
        if let intro = introduction {
            parts.append(intro.plainText)
        }
        if let verses = verses {
            for verse in verses {
                parts.append(verse.searchText)
            }
        }
        if let notes = footnotes {
            parts.append(contentsOf: notes.map { $0.plainText })
        }
        return parts.joined(separator: " ")
    }
}

/// User notes for an entire book - matches notes_schema.json
struct UserNotesBook: Codable {
    var meta: UserNotesMeta
    var book: String                    // Book abbreviation (e.g., "Matt", "Gen")
    var bookNumber: Int                 // Canonical book number 1-66
    var chapters: [UserNotesChapter]

    /// Get chapter notes by chapter number
    func chapter(_ chapterNum: Int) -> UserNotesChapter? {
        chapters.first { $0.chapter == chapterNum }
    }

    /// Get all chapters sorted by number
    var sortedChapters: [UserNotesChapter] {
        chapters.sorted { $0.chapter < $1.chapter }
    }
}

struct VerseRef: Codable {
    var sv: Int      // Start verse
    var ev: Int?     // End verse (optional, for ranges)
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
    case lexiconRef = "lexicon-ref"  // Cross-reference to another lexicon entry
    case bold           // Bold text
    case italic         // Italic text
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
    var lexiconId: String?          // Lexicon entry ID for lexicon-ref annotations (e.g., "BDB123", "G1234")
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

// MARK: - Flexible Text Field (Dictionary v2.0)

/// A text field that can be either a plain string or annotated text
/// This enables backwards compatibility with v1.0 dictionaries while supporting v2.0 annotations
enum FlexibleTextField: Codable {
    case plain(String)
    case annotated(AnnotatedText)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding as AnnotatedText first (object with "text" key)
        if let annotated = try? container.decode(AnnotatedText.self) {
            self = .annotated(annotated)
            return
        }

        // Fall back to plain string
        let text = try container.decode(String.self)
        self = .plain(text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text):
            try container.encode(text)
        case .annotated(let annotatedText):
            try container.encode(annotatedText)
        }
    }

    /// Extract plain text for display or search indexing
    var plainText: String {
        switch self {
        case .plain(let text):
            return text
        case .annotated(let annotated):
            return annotated.text
        }
    }

    /// Get as AnnotatedText (converts plain to annotated if needed)
    var asAnnotatedText: AnnotatedText {
        switch self {
        case .plain(let text):
            return AnnotatedText(text: text, annotations: nil, footnoteRefs: nil)
        case .annotated(let annotated):
            return annotated
        }
    }

    /// Check if this contains annotations
    var hasAnnotations: Bool {
        switch self {
        case .plain:
            return false
        case .annotated(let at):
            return at.annotations?.isEmpty == false
        }
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

/// Series-level metadata for a commentary series (e.g., NICNT, NIGTC)
/// Matches the commentary_series table in bundled_modules.db
struct CommentarySeries: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "commentary_series"

    var id: String                      // Series identifier (e.g., "nicnt", "nigtc")
    var name: String                    // Full series name
    var abbreviation: String            // Short abbreviation
    var seriesDescription: String?      // Brief description
    var editor: String?                 // Series editor
    var publisher: String?              // Publisher name
    var testament: String?              // "OT", "NT", or "both"
    var language: String?               // Language code
    var website: String?                // Publisher/series website
    var editorPrefaceJson: String?      // Editor's preface as AnnotatedText JSON
    var introductionJson: String?       // Series introduction as AnnotatedText JSON
    var abbreviationsJson: String?      // Series-wide abbreviations JSON array
    var bibliographyJson: String?       // Series bibliography JSON array
    var volumesJson: String?            // List of volumes in series JSON array

    enum CodingKeys: String, CodingKey {
        case id, name, abbreviation, editor, publisher, testament, language, website
        case seriesDescription = "description"
        case editorPrefaceJson = "editor_preface_json"
        case introductionJson = "introduction_json"
        case abbreviationsJson = "abbreviations_json"
        case bibliographyJson = "bibliography_json"
        case volumesJson = "volumes_json"
    }

    init(
        id: String,
        name: String,
        abbreviation: String,
        seriesDescription: String? = nil,
        editor: String? = nil,
        publisher: String? = nil,
        testament: String? = nil,
        language: String? = nil,
        website: String? = nil,
        editorPreface: AnnotatedText? = nil,
        introduction: AnnotatedText? = nil,
        abbreviations: [CommentaryAbbreviation]? = nil,
        bibliography: [BibliographyEntry]? = nil,
        volumes: [CommentarySeriesVolume]? = nil
    ) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.seriesDescription = seriesDescription
        self.editor = editor
        self.publisher = publisher
        self.testament = testament
        self.language = language
        self.website = website
        self.editorPrefaceJson = editorPreface.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.introductionJson = introduction.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.abbreviationsJson = abbreviations.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.bibliographyJson = bibliography.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.volumesJson = volumes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Computed Properties

    var editorPreface: AnnotatedText? {
        guard let json = editorPrefaceJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotatedText.self, from: data)
    }

    var introduction: AnnotatedText? {
        guard let json = introductionJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotatedText.self, from: data)
    }

    var abbreviations: [CommentaryAbbreviation]? {
        guard let json = abbreviationsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CommentaryAbbreviation].self, from: data)
    }

    var bibliography: [BibliographyEntry]? {
        guard let json = bibliographyJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([BibliographyEntry].self, from: data)
    }

    var volumes: [CommentarySeriesVolume]? {
        guard let json = volumesJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([CommentarySeriesVolume].self, from: data)
    }
}

/// Volume info in a commentary series
struct CommentarySeriesVolume: Codable {
    var bookNumber: Int?        // Bible book number if single book
    var title: String?          // Volume title
    var author: String?         // Volume author
    var year: Int?              // Publication year
    var isbn: String?           // ISBN
}

/// Series metadata for standalone commentary module files (.lamp)
/// This is read from the series_meta table in standalone user commentary modules
struct CommentarySeriesMeta: Codable, FetchableRecord {
    static let databaseTableName = "series_meta"

    var id: String                      // Series identifier
    var name: String                    // Full series name
    var abbreviation: String            // Short abbreviation
    var seriesDescription: String?      // Brief description
    var editor: String?                 // Series editor
    var publisher: String?              // Publisher name
    var testament: String?              // "OT", "NT", or "both"
    var language: String?               // Language code
    var website: String?                // Publisher/series website
    var editorPrefaceJson: String?      // Editor's preface as AnnotatedText JSON
    var introductionJson: String?       // Series introduction as AnnotatedText JSON
    var abbreviationsJson: String?      // Series-wide abbreviations JSON array
    var bibliographyJson: String?       // Series bibliography JSON array
    var volumesJson: String?            // List of volumes in series JSON array

    enum CodingKeys: String, CodingKey {
        case id, name, abbreviation, editor, publisher, testament, language, website
        case seriesDescription = "description"
        case editorPrefaceJson = "editor_preface_json"
        case introductionJson = "introduction_json"
        case abbreviationsJson = "abbreviations_json"
        case bibliographyJson = "bibliography_json"
        case volumesJson = "volumes_json"
    }

    /// Convert to CommentarySeries for unified handling
    func toCommentarySeries() -> CommentarySeries {
        var series = CommentarySeries(id: id, name: name, abbreviation: abbreviation)
        series.seriesDescription = seriesDescription
        series.editor = editor
        series.publisher = publisher
        series.testament = testament
        series.language = language
        series.website = website
        series.editorPrefaceJson = editorPrefaceJson
        series.introductionJson = introductionJson
        series.abbreviationsJson = abbreviationsJson
        series.bibliographyJson = bibliographyJson
        series.volumesJson = volumesJson
        return series
    }
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

// MARK: - Translation GRDB Models

/// Type of annotation within verse text
enum VerseAnnotationType: String, Codable {
    case strongs            // Strong's number link (H1234, G5678)
    case footnote           // Translation note marker
    case redLetter = "red-letter"   // Words of Christ
    case added              // Words added for clarity (KJV italics)
    case divineName = "divine-name" // YHWH/LORD
    case selah              // Psalm marker
    case variant            // Manuscript variant
}

/// Data associated with a verse annotation
struct VerseAnnotationData: Codable {
    var strongs: String?        // Strong's number (e.g., "G1080", "H1234")
    var morphology: String?     // Morphology code (e.g., "V-PAI-3S")
    var lemma: String?          // Original language lemma
}

/// Inline annotation within verse text
struct VerseAnnotation: Codable {
    var type: VerseAnnotationType
    var start: Int              // Character offset start position in clean text
    var end: Int                // Character offset end position in clean text
    var text: String?           // The annotated text itself
    var data: VerseAnnotationData?
}

/// Footnote for a verse
struct VerseFootnote: Codable, Identifiable {
    var id: String
    var type: String?           // "translation", "manuscript", "alternate", "explanation"
    var content: FlexibleTextField

    /// Plain text content for searching
    var plainText: String {
        content.plainText
    }
}

/// Reference to a footnote with position in clean text
struct VerseFootnoteRef: Codable {
    var id: String              // Matches footnote.id
    var offset: Int             // Character offset in clean text
}

/// Poetry formatting for a verse
struct VersePoetry: Codable {
    var indent: Int?            // Indent level (1, 2, etc.)
    var stanzaBreak: Bool?      // Stanza break before verse
}

/// Source texts used for translation
struct TranslationSourceTexts: Codable {
    var ot: [String]?           // OT source texts (e.g., ["Masoretic Text", "Dead Sea Scrolls"])
    var nt: [String]?           // NT source texts (e.g., ["Nestle-Aland 28", "Textus Receptus"])
}

/// Features available in a translation
struct TranslationFeatures: Codable {
    var strongs: Bool?
    var morphology: Bool?
    var redLetter: Bool?
    var footnotes: Bool?
    var sectionHeadings: Bool?
    var poetry: Bool?
    var paragraphs: Bool?
}

// MARK: - Translation Module (GRDB Record)

/// Translation metadata record for the translations table
struct TranslationModule: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "translations"

    var id: String                      // Unique identifier (e.g., "KJV", "ESV")
    var name: String                    // Full translation name
    var abbreviation: String            // Short abbreviation
    var translationDescription: String? // Brief description
    var language: String                // ISO 639-1 language code
    var languageName: String?           // Human-readable language name
    var textDirection: String           // "ltr" or "rtl"
    var translationPhilosophy: String?  // "formal", "dynamic", "paraphrase", etc.
    var year: Int?                      // Publication year
    var publisher: String?
    var copyright: String?
    var copyrightYear: Int?
    var license: String?
    var sourceTextsJson: String?        // JSON: TranslationSourceTexts
    var featuresJson: String?           // JSON: TranslationFeatures
    var versification: String           // "standard", "lxx", "vulgate", "orthodox"
    var filePath: String?               // For sync tracking
    var fileHash: String?               // For change detection
    var lastSynced: Int?                // Unix timestamp
    var isBundled: Bool                 // true for bundled, false for user-imported
    var createdAt: Int?
    var updatedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, abbreviation, language, year, publisher, copyright, license, versification
        case translationDescription = "description"
        case languageName = "language_name"
        case textDirection = "text_direction"
        case translationPhilosophy = "translation_philosophy"
        case copyrightYear = "copyright_year"
        case sourceTextsJson = "source_texts_json"
        case featuresJson = "features_json"
        case filePath = "file_path"
        case fileHash = "file_hash"
        case lastSynced = "last_synced"
        case isBundled = "is_bundled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String,
        name: String,
        abbreviation: String,
        translationDescription: String? = nil,
        language: String,
        languageName: String? = nil,
        textDirection: String = "ltr",
        translationPhilosophy: String? = nil,
        year: Int? = nil,
        publisher: String? = nil,
        copyright: String? = nil,
        copyrightYear: Int? = nil,
        license: String? = nil,
        sourceTexts: TranslationSourceTexts? = nil,
        features: TranslationFeatures? = nil,
        versification: String = "standard",
        filePath: String? = nil,
        fileHash: String? = nil,
        lastSynced: Int? = nil,
        isBundled: Bool = false,
        createdAt: Int? = nil,
        updatedAt: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.translationDescription = translationDescription
        self.language = language
        self.languageName = languageName
        self.textDirection = textDirection
        self.translationPhilosophy = translationPhilosophy
        self.year = year
        self.publisher = publisher
        self.copyright = copyright
        self.copyrightYear = copyrightYear
        self.license = license
        self.sourceTextsJson = sourceTexts.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.featuresJson = features.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.versification = versification
        self.filePath = filePath
        self.fileHash = fileHash
        self.lastSynced = lastSynced
        self.isBundled = isBundled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Computed Properties

    var sourceTexts: TranslationSourceTexts? {
        guard let json = sourceTextsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranslationSourceTexts.self, from: data)
    }

    var features: TranslationFeatures? {
        guard let json = featuresJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TranslationFeatures.self, from: data)
    }

    var isRTL: Bool { textDirection == "rtl" }

    // MARK: - Database Encoding

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name"] = name
        container["abbreviation"] = abbreviation
        container["description"] = translationDescription
        container["language"] = language
        container["language_name"] = languageName
        container["text_direction"] = textDirection
        container["translation_philosophy"] = translationPhilosophy
        container["year"] = year
        container["publisher"] = publisher
        container["copyright"] = copyright
        container["copyright_year"] = copyrightYear
        container["license"] = license
        container["source_texts_json"] = sourceTextsJson
        container["features_json"] = featuresJson
        container["versification"] = versification
        container["file_path"] = filePath
        container["file_hash"] = fileHash
        container["last_synced"] = lastSynced
        container["is_bundled"] = isBundled ? 1 : 0
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        abbreviation = row["abbreviation"]
        translationDescription = row["description"]
        language = row["language"]
        languageName = row["language_name"]
        textDirection = row["text_direction"] ?? "ltr"
        translationPhilosophy = row["translation_philosophy"]
        year = row["year"]
        publisher = row["publisher"]
        copyright = row["copyright"]
        copyrightYear = row["copyright_year"]
        license = row["license"]
        sourceTextsJson = row["source_texts_json"]
        featuresJson = row["features_json"]
        versification = row["versification"] ?? "standard"
        filePath = row["file_path"]
        fileHash = row["file_hash"]
        lastSynced = row["last_synced"]
        isBundled = row["is_bundled"] == 1
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }
}

// MARK: - Translation Book (GRDB Record)

/// Book metadata within a translation
struct TranslationBook: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "translation_books"

    var id: String                      // "{translation_id}:{book_number}"
    var translationId: String
    var bookNumber: Int                 // 1-66
    var bookId: String                  // Abbreviation (e.g., "Gen", "Matt")
    var name: String                    // Full name (e.g., "Genesis", "Matthew")
    var testament: String               // "OT" or "NT"
    var chapterCount: Int               // Number of chapters in this book

    enum CodingKeys: String, CodingKey {
        case id, name, testament
        case translationId = "translation_id"
        case bookNumber = "book_number"
        case bookId = "book_id"
        case chapterCount = "chapter_count"
    }

    init(
        translationId: String,
        bookNumber: Int,
        bookId: String,
        name: String,
        testament: String,
        chapterCount: Int
    ) {
        self.id = "\(translationId):\(bookNumber)"
        self.translationId = translationId
        self.bookNumber = bookNumber
        self.bookId = bookId
        self.name = name
        self.testament = testament
        self.chapterCount = chapterCount
    }

    init(row: Row) throws {
        id = row["id"]
        translationId = row["translation_id"]
        bookNumber = row["book_number"]
        bookId = row["book_id"]
        name = row["name"]
        testament = row["testament"]
        chapterCount = row["chapter_count"]
    }
}

// MARK: - Translation Verse (GRDB Record)

/// A single verse in a translation
struct TranslationVerse: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "translation_verses"

    var id: Int64?                      // Auto-increment rowid for FTS
    var translationId: String
    var ref: Int                        // BBCCCVVV format (e.g., 40001001 = Matt 1:1)
    var book: Int                       // Book number 1-66
    var chapter: Int                    // Chapter number
    var verse: Int                      // Verse number
    var text: String                    // Clean searchable text
    var annotationsJson: String?        // JSON array of VerseAnnotation
    var footnotesJson: String?          // JSON array of VerseFootnote
    var footnoteRefsJson: String?       // JSON array of VerseFootnoteRef
    var paragraph: Bool                 // True if starts a new paragraph
    var poetryJson: String?             // JSON: VersePoetry

    enum CodingKeys: String, CodingKey {
        case id, ref, book, chapter, verse, text, paragraph
        case translationId = "translation_id"
        case annotationsJson = "annotations_json"
        case footnotesJson = "footnotes_json"
        case footnoteRefsJson = "footnote_refs_json"
        case poetryJson = "poetry_json"
    }

    init(
        id: Int64? = nil,
        translationId: String,
        ref: Int,
        book: Int,
        chapter: Int,
        verse: Int,
        text: String,
        annotations: [VerseAnnotation]? = nil,
        footnotes: [VerseFootnote]? = nil,
        footnoteRefs: [VerseFootnoteRef]? = nil,
        paragraph: Bool = false,
        poetry: VersePoetry? = nil
    ) {
        self.id = id
        self.translationId = translationId
        self.ref = ref
        self.book = book
        self.chapter = chapter
        self.verse = verse
        self.text = text
        self.annotationsJson = annotations.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.footnotesJson = footnotes.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.footnoteRefsJson = footnoteRefs.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        self.paragraph = paragraph
        self.poetryJson = poetry.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Computed Properties

    var annotations: [VerseAnnotation]? {
        guard let json = annotationsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([VerseAnnotation].self, from: data)
    }

    var footnotes: [VerseFootnote]? {
        guard let json = footnotesJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([VerseFootnote].self, from: data)
    }

    var footnoteRefs: [VerseFootnoteRef]? {
        guard let json = footnoteRefsJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([VerseFootnoteRef].self, from: data)
    }

    var poetry: VersePoetry? {
        guard let json = poetryJson, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VersePoetry.self, from: data)
    }

    /// Check if verse has Strong's annotations
    var hasStrongsAnnotations: Bool {
        annotations?.contains { $0.type == .strongs } ?? false
    }

    /// Get all Strong's numbers in this verse
    var strongsNumbers: [String] {
        annotations?.compactMap { annotation -> String? in
            guard annotation.type == .strongs else { return nil }
            return annotation.data?.strongs
        } ?? []
    }

    // MARK: - Database Encoding

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["translation_id"] = translationId
        container["ref"] = ref
        container["book"] = book
        container["chapter"] = chapter
        container["verse"] = verse
        container["text"] = text
        container["annotations_json"] = annotationsJson
        container["footnotes_json"] = footnotesJson
        container["footnote_refs_json"] = footnoteRefsJson
        container["paragraph"] = paragraph ? 1 : 0
        container["poetry_json"] = poetryJson
    }

    init(row: Row) throws {
        id = row["id"]
        translationId = row["translation_id"]
        ref = row["ref"]
        book = row["book"]
        chapter = row["chapter"]
        verse = row["verse"]
        text = row["text"]
        annotationsJson = row["annotations_json"]
        footnotesJson = row["footnotes_json"]
        footnoteRefsJson = row["footnote_refs_json"]
        paragraph = row["paragraph"] == 1
        poetryJson = row["poetry_json"]
    }
}

// MARK: - Translation Heading (GRDB Record)

/// Section heading within a translation chapter
struct TranslationHeading: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "translation_headings"

    var id: Int64?                      // Auto-increment
    var translationId: String
    var book: Int
    var chapter: Int
    var beforeVerse: Int                // Heading appears before this verse
    var level: Int                      // 1 = major, 2 = minor
    var text: String

    enum CodingKeys: String, CodingKey {
        case id, book, chapter, level, text
        case translationId = "translation_id"
        case beforeVerse = "before_verse"
    }

    init(
        id: Int64? = nil,
        translationId: String,
        book: Int,
        chapter: Int,
        beforeVerse: Int,
        level: Int = 1,
        text: String
    ) {
        self.id = id
        self.translationId = translationId
        self.book = book
        self.chapter = chapter
        self.beforeVerse = beforeVerse
        self.level = level
        self.text = text
    }

    init(row: Row) throws {
        id = row["id"]
        translationId = row["translation_id"]
        book = row["book"]
        chapter = row["chapter"]
        beforeVerse = row["before_verse"]
        level = row["level"]
        text = row["text"]
    }
}

// MARK: - Translation Search Result

/// Search result from translation FTS search or Strong's search
struct TranslationSearchResult: Identifiable {
    let id: String
    let translationId: String
    let translationName: String
    let translationAbbrev: String
    let ref: Int
    let book: Int
    let chapter: Int
    let verse: Int
    let snippet: String
    let rank: Double
    var rawText: String? = nil  // For Strong's search: annotations_json for highlighting

    /// Verse reference string (e.g., "Genesis 1:1")
    func verseReference(bookName: String) -> String {
        "\(bookName) \(chapter):\(verse)"
    }
}

// MARK: - Chapter Content (combined verses + headings)

/// Combined chapter content for rendering
struct ChapterContent {
    var verses: [TranslationVerse]
    var headings: [TranslationHeading]

    /// Get content items with headings interleaved before their verses
    func contentItems() -> [ChapterContentItem] {
        var items: [ChapterContentItem] = []
        var headingIndex = 0

        for verse in verses {
            // Add any headings that come before this verse
            while headingIndex < headings.count &&
                  headings[headingIndex].beforeVerse <= verse.verse {
                items.append(.heading(headings[headingIndex]))
                headingIndex += 1
            }
            items.append(.verse(verse))
        }

        return items
    }
}

/// Item in chapter content (either verse or heading)
enum ChapterContentItem {
    case verse(TranslationVerse)
    case heading(TranslationHeading)
}

// MARK: - Translation Schema JSON File Structures (for import)

/// Metadata for translation JSON file (matches translation_schema.json)
struct TranslationSchemaMeta: Codable {
    var schemaVersion: String
    var id: String
    var type: String
    var name: String
    var abbreviation: String
    var description: String?
    var language: String
    var languageName: String?
    var textDirection: String?
    var translationPhilosophy: String?
    var year: Int?
    var publisher: String?
    var copyright: String?
    var copyrightYear: Int?
    var license: String?
    var sourceTexts: TranslationSourceTexts?
    var features: TranslationFeatures?
    var versification: String?
}

/// Section heading in translation JSON
struct TranslationSchemaHeading: Codable {
    var text: String
    var beforeVerse: Int
    var level: Int?
}

/// Annotated text content in translation JSON
struct TranslationSchemaAnnotatedText: Codable {
    var text: String
    var annotations: [VerseAnnotation]?
    var footnoteRefs: [VerseFootnoteRef]?

    enum CodingKeys: String, CodingKey {
        case text, annotations
        case footnoteRefs = "footnote_refs"
    }
}

/// Footnote in translation JSON
struct TranslationSchemaFootnote: Codable {
    var id: String
    var type: String?
    var content: FlexibleTextField
}

/// Verse in translation JSON
struct TranslationSchemaVerse: Codable {
    var v: Int                          // Verse number within chapter
    var ref: Int                        // Full BBCCCVVV reference
    var content: TranslationSchemaAnnotatedText
    var footnotes: [TranslationSchemaFootnote]?
    var paragraph: Bool?
    var poetry: VersePoetry?
}

/// Chapter in translation JSON
struct TranslationSchemaChapter: Codable {
    var chapter: Int
    var headings: [TranslationSchemaHeading]?
    var verses: [TranslationSchemaVerse]
}

/// Book in translation JSON
struct TranslationSchemaBook: Codable {
    var id: String                      // Book abbreviation
    var name: String                    // Full book name
    var number: Int                     // Canonical book number 1-66
    var testament: String               // "OT" or "NT"
    var chapters: [TranslationSchemaChapter]
}

/// Complete translation JSON file structure
struct TranslationSchemaFile: Codable {
    var meta: TranslationSchemaMeta
    var books: [TranslationSchemaBook]
}

// MARK: - Lexicon Mapping Models

/// Mapping between lexicon entries (e.g., Strong's to BDB)
struct LexiconMapping: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lexicon_mappings"

    var sourceKey: String     // Source lexicon key (e.g., "H1234")
    var targetKeysJson: String  // JSON array of target keys (e.g., ["BDB123", "BDB456"])

    enum CodingKeys: String, CodingKey {
        case sourceKey = "source_key"
        case targetKeysJson = "target_keys_json"
    }

    /// Decoded target keys
    var targetKeys: [String] {
        guard let data = targetKeysJson.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return keys
    }
}

/// Lexicon mapping metadata
struct LexiconMappingMeta: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lexicon_mapping_meta"

    var id: String           // Mapping ID (e.g., "strongs_hebrew_to_bdb")
    var name: String?
    var description: String?
    var sourceKeyType: String   // e.g., "strongs-hebrew"
    var targetKeyType: String   // e.g., "bdb"

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case sourceKeyType = "source_key_type"
        case targetKeyType = "target_key_type"
    }
}

// MARK: - Plan Models (Bundled Reading Plans)

/// Reading plan metadata
struct Plan: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "plans"

    var id: String
    var name: String
    var planDescription: String?
    var author: String?
    var fullDescription: String?
    var duration: Int?           // Number of days (typically 366)
    var readingsPerDay: Int?     // Typical readings per day

    enum CodingKeys: String, CodingKey {
        case id, name
        case planDescription = "description"
        case author
        case fullDescription = "full_description"
        case duration
        case readingsPerDay = "readings_per_day"
    }

    /// Get the plan day number for a given date (handles leap year adjustment)
    func getPlanDay(date: Date) -> Int {
        let year = Calendar.iso8601.component(.year, from: date)
        var day = Calendar.iso8601.ordinality(of: .day, in: .year, for: date)!

        if !year.isALeapYear && day >= 60 {
            // Plans include 366 days (for leap years), but on non-leap-years,
            // we need to skip the extra day (day 60 = Feb 29)
            day = day + 1
        }

        return day
    }
}

/// A single day's readings in a plan
struct PlanDay: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "plan_days"

    var planId: String           // Foreign key to plans.id
    var day: Int                 // Day number (1-366)
    var readingsJson: String?    // JSON array of readings [{sv:..., ev:...}]

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case day
        case readingsJson = "readings_json"
    }

    /// Decoded readings array
    var readings: [PlanReading] {
        guard let json = readingsJson, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PlanReading].self, from: data)) ?? []
    }

    /// Get a description of all readings for this day (e.g., "Genesis 1-2, Psalm 1")
    func getReadingsDescription() -> String {
        readings.map { $0.getDescription() }.joined(separator: ", ")
    }
}

/// A single reading assignment (scripture range)
struct PlanReading: Codable {
    var sv: Int    // Start verse ref (BBCCCVVV format)
    var ev: Int    // End verse ref (BBCCCVVV format)

    /// Get a human-readable description of this reading
    func getDescription() -> String {
        let (startVerse, startChapter, startBook) = splitVerseId(sv)
        let (endVerse, endChapter, endBook) = splitVerseId(ev)

        // Get full book names from cache
        let startBookName = BookOsisCache.shared.getName(for: startBook)
        let endBookName = BookOsisCache.shared.getName(for: endBook)

        // Same book
        if startBook == endBook {
            // Same chapter
            if startChapter == endChapter {
                // Full chapter (verse 1 to 999 or end)
                if startVerse == 1 && (endVerse == 999 || endVerse >= 150) {
                    return "\(startBookName) \(startChapter)"
                }
                // Verse range within chapter
                if startVerse == endVerse {
                    return "\(startBookName) \(startChapter):\(startVerse)"
                }
                return "\(startBookName) \(startChapter):\(startVerse)-\(endVerse)"
            }
            // Multiple chapters
            // Full chapters (start at verse 1, end at 999 or high verse)
            if startVerse == 1 && (endVerse == 999 || endVerse >= 150) {
                return "\(startBookName) \(startChapter)-\(endChapter)"
            }
            return "\(startBookName) \(startChapter):\(startVerse)-\(endChapter):\(endVerse)"
        }

        // Different books
        return "\(startBookName) \(startChapter):\(startVerse) - \(endBookName) \(endChapter):\(endVerse)"
    }
}
