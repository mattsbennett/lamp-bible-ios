//
//  BundledModuleDatabase.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-11.
//

import Foundation
import GRDB

/// Read-only access to bundled modules database (translations, future: commentaries, dictionaries)
/// This database is shipped with the app and cannot be modified by users.
/// Supports both uncompressed (.db) and zlib-compressed (.db.zlib) bundles.
class BundledModuleDatabase {
    static let shared = BundledModuleDatabase()

    private var dbQueue: DatabaseQueue?
    private var isAvailable: Bool = false

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        let dbPath: String

        // Check for compressed database first (.db.zlib), then uncompressed (.db)
        if let compressedPath = Bundle.main.path(forResource: "bundled_modules.db", ofType: "zlib") {
            // Decompress to Application Support if needed
            if let decompressedPath = decompressIfNeeded(compressedPath: compressedPath) {
                dbPath = decompressedPath
            } else {
                print("BundledModuleDatabase: Failed to decompress bundled_modules.db.zlib")
                return
            }
        } else if let uncompressedPath = Bundle.main.path(forResource: "bundled_modules", ofType: "db") {
            // Use uncompressed database directly from bundle
            dbPath = uncompressedPath
        } else {
            print("BundledModuleDatabase: No bundled_modules database found in bundle")
            return
        }

        var config = Configuration()
        config.readonly = true

        do {
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
            isAvailable = true
            print("BundledModuleDatabase: Successfully opened bundled_modules.db")
        } catch {
            print("BundledModuleDatabase: Failed to open database: \(error)")
        }
    }

    /// Decompress the bundled database to Application Support if not already done
    /// Returns the path to the decompressed database, or nil on failure
    private func decompressIfNeeded(compressedPath: String) -> String? {
        let fileManager = FileManager.default

        // Get Application Support directory
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("BundledModuleDatabase: Could not find Application Support directory")
            return nil
        }

        // Create directory if needed
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let decompressedURL = appSupport.appendingPathComponent("bundled_modules.db")
        let decompressedPath = decompressedURL.path
        let versionMarkerURL = appSupport.appendingPathComponent("bundled_modules.version")

        // Use app bundle version as a stable marker instead of modification dates,
        // which are unreliable because iOS changes the bundle path on every install/update
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

        // Check if already decompressed and up-to-date
        if fileManager.fileExists(atPath: decompressedPath),
           let markerVersion = try? String(contentsOf: versionMarkerURL, encoding: .utf8),
           markerVersion == currentVersion {
            print("BundledModuleDatabase: Using existing decompressed database (build \(currentVersion))")
            return decompressedPath
        }

        // Remove outdated decompressed file
        try? fileManager.removeItem(atPath: decompressedPath)

        // Decompress
        print("BundledModuleDatabase: Decompressing bundled database (build \(currentVersion))...")
        do {
            let compressedData = try Data(contentsOf: URL(fileURLWithPath: compressedPath))
            let decompressedData = try (compressedData as NSData).decompressed(using: .zlib) as Data
            try decompressedData.write(to: decompressedURL)
            try currentVersion.write(to: versionMarkerURL, atomically: true, encoding: .utf8)
            print("BundledModuleDatabase: Decompressed \(compressedData.count) -> \(decompressedData.count) bytes")
            return decompressedPath
        } catch {
            print("BundledModuleDatabase: Decompression failed: \(error)")
            return nil
        }
    }

    /// Check if bundled database is available
    var available: Bool { isAvailable }

    // MARK: - Database Access

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        guard let db = dbQueue else {
            throw BundledModuleDatabaseError.notAvailable
        }
        return try db.read(block)
    }

    // MARK: - Translation Queries

    /// Get all bundled translations
    func getAllTranslations() throws -> [TranslationModule] {
        guard isAvailable else { return [] }
        return try read { db in
            try TranslationModule.fetchAll(db)
        }
    }

    /// Get a bundled translation by ID
    func getTranslation(id: String) throws -> TranslationModule? {
        guard isAvailable else { return nil }
        return try read { db in
            try TranslationModule.fetchOne(db, key: id)
        }
    }

    /// Check if a translation is bundled
    func isTranslationBundled(id: String) throws -> Bool {
        guard isAvailable else { return false }
        return try read { db in
            try TranslationModule.fetchOne(db, key: id) != nil
        }
    }

    /// Get bundled translations by language
    func getTranslationsByLanguage(_ language: String) throws -> [TranslationModule] {
        guard isAvailable else { return [] }
        return try read { db in
            try TranslationModule
                .filter(Column("language") == language)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    // MARK: - Translation Book Queries

    /// Get books for a bundled translation
    func getTranslationBooks(translationId: String) throws -> [TranslationBook] {
        guard isAvailable else { return [] }
        return try read { db in
            try TranslationBook
                .filter(Column("translation_id") == translationId)
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    /// Get a specific book
    func getTranslationBook(translationId: String, bookNumber: Int) throws -> TranslationBook? {
        guard isAvailable else { return nil }
        return try read { db in
            try TranslationBook
                .filter(Column("translation_id") == translationId)
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    // MARK: - Verse Queries

    /// Get a single verse from bundled translation
    func getVerse(translationId: String, ref: Int) throws -> TranslationVerse? {
        guard isAvailable else { return nil }
        return try read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("ref") == ref)
                .fetchOne(db)
        }
    }

    /// Get verses from multiple bundled translations
    func getVerses(translationIds: [String], ref: Int) throws -> [String: TranslationVerse] {
        guard isAvailable else { return [:] }
        return try read { db in
            let verses = try TranslationVerse
                .filter(translationIds.contains(Column("translation_id")))
                .filter(Column("ref") == ref)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: verses.map { ($0.translationId, $0) })
        }
    }

    /// Get a full chapter from bundled translation
    func getChapter(translationId: String, book: Int, chapter: Int) throws -> ChapterContent {
        guard isAvailable else { return ChapterContent(verses: [], headings: []) }
        return try read { db in
            let verses = try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("verse"))
                .fetchAll(db)

            let headings = try TranslationHeading
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("before_verse"))
                .fetchAll(db)

            return ChapterContent(verses: verses, headings: headings)
        }
    }

    /// Get a range of verses from bundled translation
    func getVerseRange(translationId: String, startRef: Int, endRef: Int) throws -> [TranslationVerse] {
        guard isAvailable else { return [] }
        return try read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("ref") >= startRef)
                .filter(Column("ref") <= endRef)
                .order(Column("ref"))
                .fetchAll(db)
        }
    }

    /// Get headings for a chapter
    func getHeadingsForChapter(translationId: String, book: Int, chapter: Int) throws -> [TranslationHeading] {
        guard isAvailable else { return [] }
        return try read { db in
            try TranslationHeading
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("before_verse"))
                .fetchAll(db)
        }
    }

    /// Get multiple consecutive chapters for continuous scrolling
    /// - Parameters:
    ///   - translationId: Translation ID
    ///   - chapters: Array of (book, chapter) tuples to fetch
    /// - Returns: Array of ChapterContent in the same order as requested
    func getChapters(translationId: String, chapters: [(book: Int, chapter: Int)]) throws -> [ChapterContent] {
        guard isAvailable else { return [] }
        return try read { db in
            var results: [ChapterContent] = []
            for (book, chapter) in chapters {
                let verses = try TranslationVerse
                    .filter(Column("translation_id") == translationId)
                    .filter(Column("book") == book)
                    .filter(Column("chapter") == chapter)
                    .order(Column("verse"))
                    .fetchAll(db)

                let headings = try TranslationHeading
                    .filter(Column("translation_id") == translationId)
                    .filter(Column("book") == book)
                    .filter(Column("chapter") == chapter)
                    .order(Column("before_verse"))
                    .fetchAll(db)

                results.append(ChapterContent(verses: verses, headings: headings))
            }
            return results
        }
    }

    /// Get headings for a range of chapters (for multi-chapter view)
    func getHeadingsForChapterRange(translationId: String, chapters: [(book: Int, chapter: Int)]) throws -> [TranslationHeading] {
        guard isAvailable else { return [] }
        return try read { db in
            var allHeadings: [TranslationHeading] = []
            for (book, chapter) in chapters {
                let headings = try TranslationHeading
                    .filter(Column("translation_id") == translationId)
                    .filter(Column("book") == book)
                    .filter(Column("chapter") == chapter)
                    .order(Column("before_verse"))
                    .fetchAll(db)
                allHeadings.append(contentsOf: headings)
            }
            return allHeadings
        }
    }

    /// Get chapter count for a book
    func getChapterCount(translationId: String, book: Int) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MAX(chapter) as max_chapter
                FROM translation_verses
                WHERE translation_id = ? AND book = ?
            """, arguments: [translationId, book])
            return row?["max_chapter"] ?? 0
        }
    }

    /// Get verse count for a chapter
    func getVerseCount(translationId: String, book: Int, chapter: Int) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .fetchCount(db)
        }
    }

    /// Get total verse count for a translation
    func getTotalVerseCount(translationId: String) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .fetchCount(db)
        }
    }

    /// Count Strong's number occurrences in a translation
    func countStrongsOccurrences(translationId: String, strongsNum: String) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            // Search for Strong's number in annotations_json
            // Pattern: "strongs":"H1234" or "strongs": "H1234" (handles both compact and spaced JSON)
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM translation_verses
                WHERE translation_id = ? AND annotations_json LIKE ?
            """, arguments: [translationId, "%\"strongs\":%\"\(strongsNum)\"%"])
            return count ?? 0
        }
    }

    /// Search verses by Strong's number in annotations_json
    func searchVersesByStrongs(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        guard isAvailable else { return [] }
        return try read { db in
            var conditions = ["v.translation_id = ?", "v.annotations_json LIKE ?"]
            var arguments: [DatabaseValueConvertible] = [translationId, "%\"strongs\":%\"\(strongsNum)\"%"]

            if let range = bookRange {
                conditions.append("v.book BETWEEN ? AND ?")
                arguments.append(range.lowerBound)
                arguments.append(range.upperBound)
            }

            let whereClause = conditions.joined(separator: " AND ")

            let sql = """
                SELECT
                    v.id,
                    v.translation_id,
                    t.name as translation_name,
                    t.abbreviation as translation_abbrev,
                    v.ref,
                    v.book,
                    v.chapter,
                    v.verse,
                    v.text,
                    v.annotations_json
                FROM translation_verses v
                JOIN translations t ON v.translation_id = t.id
                WHERE \(whereClause)
                ORDER BY v.ref
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let text: String = row["text"] ?? ""
                let annotationsJson: String? = row["annotations_json"]

                // Create snippet with <mark> tags around words matching the Strong's number
                let snippet = Self.addStrongsMarks(to: text, annotationsJson: annotationsJson, strongsNum: strongsNum)

                return TranslationSearchResult(
                    id: "\(row["translation_id"] as String):\(row["ref"] as Int)",
                    translationId: row["translation_id"],
                    translationName: row["translation_name"],
                    translationAbbrev: row["translation_abbrev"],
                    ref: row["ref"],
                    book: row["book"],
                    chapter: row["chapter"],
                    verse: row["verse"],
                    snippet: snippet,
                    rank: 1.0,
                    rawText: annotationsJson
                )
            }
        }
    }

    /// Add <mark> tags around words that match a Strong's number
    private static func addStrongsMarks(to text: String, annotationsJson: String?, strongsNum: String) -> String {
        guard let json = annotationsJson,
              let data = json.data(using: .utf8) else {
            return text
        }

        // Try parsing annotations - some translations use array, others might use wrapped object
        var annotations: [VerseAnnotation]?

        // Try direct array first
        annotations = try? JSONDecoder().decode([VerseAnnotation].self, from: data)

        // If that fails, try wrapped in object
        if annotations == nil {
            struct WrappedAnnotations: Codable {
                var annotations: [VerseAnnotation]?
            }
            annotations = (try? JSONDecoder().decode(WrappedAnnotations.self, from: data))?.annotations
        }

        guard let annotations = annotations else { return text }

        let textCount = text.count

        // Find annotations with matching Strong's number, with validation
        let matchingRanges = annotations
            .filter { $0.data?.strongs?.uppercased() == strongsNum.uppercased() }
            .map { (start: $0.start, end: $0.end) }
            .filter { $0.start >= 0 && $0.end > $0.start && $0.end <= textCount }  // Validate ranges
            .sorted { $0.start < $1.start }

        guard !matchingRanges.isEmpty else { return text }

        // Merge overlapping ranges to avoid nested marks
        var mergedRanges: [(start: Int, end: Int)] = []
        for range in matchingRanges {
            if let last = mergedRanges.last, range.start <= last.end {
                // Overlapping or adjacent - extend the previous range
                mergedRanges[mergedRanges.count - 1] = (last.start, max(last.end, range.end))
            } else {
                mergedRanges.append(range)
            }
        }

        // Insert marks from end to start to preserve offsets
        var result = text
        for range in mergedRanges.reversed() {
            let startIndex = result.index(result.startIndex, offsetBy: range.start)
            let endIndex = result.index(result.startIndex, offsetBy: range.end)
            result.insert(contentsOf: "</mark>", at: endIndex)
            result.insert(contentsOf: "<mark>", at: startIndex)
        }

        return result
    }

    /// Get the last verse ref in a chapter
    func getLastVerseRef(translationId: String, book: Int, chapter: Int) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            let ref = try Int.fetchOne(db, sql: """
                SELECT MAX(ref) FROM translation_verses
                WHERE translation_id = ? AND book = ? AND chapter = ?
            """, arguments: [translationId, book, chapter])
            return ref ?? 0
        }
    }

    // MARK: - FTS Search

    /// Search verses in bundled translations
    func searchVerses(
        query: String,
        translationIds: Set<String>? = nil,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        guard isAvailable else { return [] }

        let ftsQuery = prepareFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try read { db in
            var conditions = ["translation_verses_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            // Translation filter
            if let ids = translationIds, !ids.isEmpty {
                let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
                conditions.append("v.translation_id IN (\(placeholders))")
                for id in ids {
                    arguments.append(id)
                }
            }

            // Book range filter
            if let range = bookRange {
                conditions.append("v.book BETWEEN ? AND ?")
                arguments.append(range.lowerBound)
                arguments.append(range.upperBound)
            }

            let whereClause = conditions.joined(separator: " AND ")

            let sql = """
                SELECT
                    v.id,
                    v.translation_id,
                    t.name as translation_name,
                    t.abbreviation as translation_abbrev,
                    v.ref,
                    v.book,
                    v.chapter,
                    v.verse,
                    bm25(translation_verses_fts) as rank,
                    snippet(translation_verses_fts, 0, '<mark>', '</mark>', '...', 32) as snippet
                FROM translation_verses_fts f
                JOIN translation_verses v ON f.rowid = v.id
                JOIN translations t ON v.translation_id = t.id
                WHERE \(whereClause)
                ORDER BY rank
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                TranslationSearchResult(
                    id: "\(row["translation_id"] as String):\(row["ref"] as Int)",
                    translationId: row["translation_id"],
                    translationName: row["translation_name"],
                    translationAbbrev: row["translation_abbrev"],
                    ref: row["ref"],
                    book: row["book"],
                    chapter: row["chapter"],
                    verse: row["verse"],
                    snippet: row["snippet"] ?? "",
                    rank: -(row["rank"] as Double)
                )
            }
        }
    }

    private func prepareFTSQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let escaped = trimmed
            .replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")

        return "\"\(escaped)\"*"
    }

    // MARK: - Lexicon (Dictionary) Queries

    /// Get a dictionary entry by module and key
    func getDictionaryEntry(moduleId: String, key: String) throws -> DictionaryEntry? {
        guard isAvailable else { return nil }
        return try read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("key") == key)
                .fetchOne(db)
        }
    }

    /// Get a dictionary entry by exact key (any module matching keyType)
    func getDictionaryEntry(key: String, keyType: String) throws -> DictionaryEntry? {
        guard isAvailable else { return nil }
        return try read { db in
            // First find modules matching keyType
            let modules = try Module
                .filter(Column("type") == "dictionary")
                .filter(Column("key_type") == keyType)
                .fetchAll(db)

            for module in modules {
                if let entry = try DictionaryEntry
                    .filter(Column("module_id") == module.id)
                    .filter(Column("key") == key)
                    .fetchOne(db) {
                    return entry
                }
            }
            return nil
        }
    }

    /// Get all dictionary entries for a module
    func getDictionaryEntries(moduleId: String) throws -> [DictionaryEntry] {
        guard isAvailable else { return [] }
        return try read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .order(Column("key"))
                .fetchAll(db)
        }
    }

    /// Get dictionary entry count for a module
    func getDictionaryEntryCount(moduleId: String) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .fetchCount(db)
        }
    }

    /// Search dictionary entries
    func searchDictionaryEntries(
        query: String,
        moduleId: String? = nil,
        keyType: String? = nil,
        limit: Int = 50
    ) throws -> [DictionaryEntry] {
        guard isAvailable else { return [] }
        return try read { db in
            var request = DictionaryEntry.all()

            // Filter by module
            if let moduleId = moduleId {
                request = request.filter(Column("module_id") == moduleId)
            } else if let keyType = keyType {
                // Get modules matching keyType
                let moduleIds = try Module
                    .filter(Column("type") == "dictionary")
                    .filter(Column("key_type") == keyType)
                    .fetchAll(db)
                    .map { $0.id }
                if !moduleIds.isEmpty {
                    request = request.filter(moduleIds.contains(Column("module_id")))
                }
            }

            // Search by key or lemma (case-insensitive)
            let searchPattern = "%\(query)%"
            request = request.filter(
                Column("key").like(searchPattern) ||
                Column("lemma").like(searchPattern)
            )

            return try request.limit(limit).fetchAll(db)
        }
    }

    /// Get all bundled modules
    func getAllModules(type: ModuleType? = nil) throws -> [Module] {
        guard isAvailable else { return [] }
        return try read { db in
            var request = Module.all()
            if let type = type {
                request = request.filter(Column("type") == type.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    /// Get a bundled module by ID
    func getModule(id: String) throws -> Module? {
        guard isAvailable else { return nil }
        return try read { db in
            try Module.fetchOne(db, key: id)
        }
    }

    // MARK: - Bundled Commentary Series Queries

    /// Check if the bundled database has the commentary_series table
    func hasCommentarySeriesTable() -> Bool {
        guard isAvailable else { return false }
        do {
            return try read { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='commentary_series'
                """) ?? 0
                return count > 0
            }
        } catch {
            return false
        }
    }

    /// Check if the bundled database has the modules table
    func hasModulesTable() -> Bool {
        guard isAvailable else { return false }
        do {
            return try read { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='modules'
                """) ?? 0
                return count > 0
            }
        } catch {
            return false
        }
    }

    /// Get all bundled commentary series from the commentary_series table
    func getAllBundledCommentarySeries() throws -> [CommentarySeries] {
        guard isAvailable, hasCommentarySeriesTable() else { return [] }
        return try read { db in
            try CommentarySeries
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get a specific commentary series by ID
    func getBundledCommentarySeries(id: String) throws -> CommentarySeries? {
        guard isAvailable, hasCommentarySeriesTable() else { return nil }
        return try read { db in
            try CommentarySeries.fetchOne(db, key: id)
        }
    }

    /// Get all bundled commentary modules from the modules table
    func getAllBundledCommentaryModules() throws -> [Module] {
        guard isAvailable, hasModulesTable() else { return [] }
        return try read { db in
            try Module
                .filter(Column("type") == "commentary")
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get all bundled commentary books
    func getAllBundledCommentaryBooks() throws -> [CommentaryBook] {
        guard isAvailable else { return [] }
        return try read { db in
            try CommentaryBook
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    /// Get all bundled commentary books for a specific series
    func getBundledCommentaryBooks(forSeriesId seriesId: String) throws -> [CommentaryBook] {
        guard isAvailable, hasModulesTable() else { return [] }
        return try read { db in
            // Get all modules that belong to this series
            let moduleIds = try Row.fetchAll(db, sql: """
                SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
            """, arguments: [seriesId]).compactMap { $0["id"] as String? }

            guard !moduleIds.isEmpty else { return [] }

            // Get all books for these modules
            return try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    /// Get all bundled commentary books for modules without a series_id (ungrouped)
    func getBundledCommentaryBooksWithoutSeries() throws -> [CommentaryBook] {
        guard isAvailable, hasModulesTable() else {
            // Fallback: if no modules table, return all books
            return try getAllBundledCommentaryBooks()
        }
        return try read { db in
            // Get all commentary modules without a series_id
            let moduleIds = try Row.fetchAll(db, sql: """
                SELECT id FROM modules WHERE (series_id IS NULL OR series_id = '') AND type = 'commentary'
            """).compactMap { $0["id"] as String? }

            if moduleIds.isEmpty { return [] }

            // Get all books for these modules
            return try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    /// Check if a commentary series has coverage for a specific book
    func bundledSeriesHasCoverageForBook(seriesId: String, bookNumber: Int) throws -> Bool {
        guard isAvailable, hasModulesTable() else { return false }
        return try read { db in
            // Get module IDs for this series
            let moduleIds = try Row.fetchAll(db, sql: """
                SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
            """, arguments: [seriesId]).compactMap { $0["id"] as String? }

            guard !moduleIds.isEmpty else { return false }

            return try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .filter(Column("book_number") == bookNumber)
                .fetchCount(db) > 0
        }
    }

    /// Get commentary book for a series and book number
    func getBundledCommentaryBook(seriesId: String, bookNumber: Int) throws -> CommentaryBook? {
        guard isAvailable, hasModulesTable() else { return nil }
        return try read { db in
            // Get module IDs for this series
            let moduleIds = try Row.fetchAll(db, sql: """
                SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
            """, arguments: [seriesId]).compactMap { $0["id"] as String? }

            guard !moduleIds.isEmpty else { return nil }

            return try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    /// Get commentary units for a chapter by series ID
    func getBundledCommentaryUnitsForChapter(seriesId: String, book: Int, chapter: Int) throws -> [CommentaryUnit] {
        guard isAvailable, hasModulesTable() else { return [] }
        return try read { db in
            // Get module IDs for this series
            let moduleIds = try Row.fetchAll(db, sql: """
                SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
            """, arguments: [seriesId]).compactMap { $0["id"] as String? }

            guard !moduleIds.isEmpty else { return [] }

            // Find the commentary book for this series + book combination
            guard let commentaryBook = try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .filter(Column("book_number") == book)
                .fetchOne(db) else {
                return []
            }

            // Get all units for this module, book, and chapter
            return try CommentaryUnit
                .filter(Column("module_id") == commentaryBook.moduleId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    /// Get all modules that belong to a specific series
    func getBundledModulesForSeries(seriesId: String) throws -> [Module] {
        guard isAvailable, hasModulesTable() else { return [] }
        return try read { db in
            try Module
                .filter(Column("series_id") == seriesId)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    // MARK: - Legacy Bundled Commentary Queries (for backward compatibility)

    /// Get all bundled commentary series names
    /// First tries commentary_series table, falls back to distinct series_full from commentary_books
    func getBundledCommentarySeriesNames() throws -> [String] {
        guard isAvailable else { return [] }

        return try read { db in
            // Check if commentary_series table exists inline to avoid reentrancy
            let hasSeriesTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='commentary_series'") ?? 0 > 0

            if hasSeriesTable {
                let series = try CommentarySeries
                    .order(Column("name"))
                    .fetchAll(db)
                if !series.isEmpty {
                    return series.map { $0.name }
                }
            }

            // Fallback to series_full from commentary_books
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT series_full FROM commentary_books
                WHERE series_full IS NOT NULL AND series_full != ''
                ORDER BY series_full
            """)
            return rows.compactMap { $0["series_full"] as String? }
        }
    }

    /// Check if a commentary series has coverage for a specific book (legacy - uses series name)
    func bundledSeriesHasCoverageForBook(seriesFull: String, bookNumber: Int) throws -> Bool {
        guard isAvailable else { return false }
        return try read { db in
            // Check if tables exist inline to avoid reentrancy
            let hasSeriesTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='commentary_series'") ?? 0 > 0
            let hasModules = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='modules'") ?? 0 > 0

            // Try new schema first (commentary_series -> modules -> commentary_books)
            if hasSeriesTable && hasModules {
                if let series = try CommentarySeries
                    .filter(Column("name") == seriesFull)
                    .fetchOne(db) {
                    let moduleIds = try Row.fetchAll(db, sql: """
                        SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
                    """, arguments: [series.id]).compactMap { $0["id"] as String? }

                    if !moduleIds.isEmpty {
                        return try CommentaryBook
                            .filter(moduleIds.contains(Column("module_id")))
                            .filter(Column("book_number") == bookNumber)
                            .fetchCount(db) > 0
                    }
                }
            }

            // Fallback: direct series_full lookup on commentary_books
            return try CommentaryBook
                .filter(Column("series_full") == seriesFull)
                .filter(Column("book_number") == bookNumber)
                .fetchCount(db) > 0
        }
    }

    /// Get commentary book for a series name and book number (legacy)
    func getBundledCommentaryBook(seriesFull: String, bookNumber: Int) throws -> CommentaryBook? {
        guard isAvailable else { return nil }
        return try read { db in
            // Check if tables exist inline to avoid reentrancy
            let hasSeriesTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='commentary_series'") ?? 0 > 0
            let hasModules = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='modules'") ?? 0 > 0

            // Try new schema first
            if hasSeriesTable && hasModules {
                if let series = try CommentarySeries
                    .filter(Column("name") == seriesFull)
                    .fetchOne(db) {
                    let moduleIds = try Row.fetchAll(db, sql: """
                        SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
                    """, arguments: [series.id]).compactMap { $0["id"] as String? }

                    if !moduleIds.isEmpty {
                        return try CommentaryBook
                            .filter(moduleIds.contains(Column("module_id")))
                            .filter(Column("book_number") == bookNumber)
                            .fetchOne(db)
                    }
                }
            }

            // Fallback: direct series_full lookup
            return try CommentaryBook
                .filter(Column("series_full") == seriesFull)
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    /// Get commentary units for a chapter by series name (legacy)
    func getBundledCommentaryUnitsForChapter(seriesFull: String, book: Int, chapter: Int) throws -> [CommentaryUnit] {
        guard isAvailable else { return [] }
        return try read { db in
            // Check if tables exist inline to avoid reentrancy
            let hasSeriesTable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='commentary_series'") ?? 0 > 0
            let hasModules = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='modules'") ?? 0 > 0

            // First find the commentary book
            var commentaryBook: CommentaryBook? = nil

            // Try new schema first
            if hasSeriesTable && hasModules {
                if let series = try CommentarySeries
                    .filter(Column("name") == seriesFull)
                    .fetchOne(db) {
                    let moduleIds = try Row.fetchAll(db, sql: """
                        SELECT id FROM modules WHERE series_id = ? AND type = 'commentary'
                    """, arguments: [series.id]).compactMap { $0["id"] as String? }

                    if !moduleIds.isEmpty {
                        commentaryBook = try CommentaryBook
                            .filter(moduleIds.contains(Column("module_id")))
                            .filter(Column("book_number") == book)
                            .fetchOne(db)
                    }
                }
            }

            // Fallback: direct series_full lookup
            if commentaryBook == nil {
                commentaryBook = try CommentaryBook
                    .filter(Column("series_full") == seriesFull)
                    .filter(Column("book_number") == book)
                    .fetchOne(db)
            }

            guard let cb = commentaryBook else { return [] }

            // Get all units for this module, book, and chapter
            return try CommentaryUnit
                .filter(Column("module_id") == cb.moduleId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    // MARK: - Lexicon Mapping Queries

    /// Get target keys for a source key (e.g., Strong's -> BDB)
    func getLexiconMappings(sourceKey: String) throws -> [String] {
        guard isAvailable else { return [] }
        return try read { db in
            if let mapping = try LexiconMapping
                .filter(Column("source_key") == sourceKey)
                .fetchOne(db) {
                return mapping.targetKeys
            }
            return []
        }
    }

    /// Get source keys that map to a target key (reverse lookup)
    func getReverseLexiconMappings(targetKey: String) throws -> [String] {
        guard isAvailable else { return [] }
        return try read { db in
            // Search for target key in JSON array
            let rows = try Row.fetchAll(db, sql: """
                SELECT source_key FROM lexicon_mappings
                WHERE target_keys_json LIKE ?
            """, arguments: ["%\"\(targetKey)\"%"])
            return rows.compactMap { $0["source_key"] as String? }
        }
    }

    /// Get lexicon mapping metadata
    func getLexiconMappingMeta(id: String) throws -> LexiconMappingMeta? {
        guard isAvailable else { return nil }
        return try read { db in
            try LexiconMappingMeta.fetchOne(db, key: id)
        }
    }

    // MARK: - Plan Queries

    /// Get all available plans
    func getAllPlans() throws -> [Plan] {
        guard isAvailable else { return [] }
        return try read { db in
            try Plan.order(Column("name")).fetchAll(db)
        }
    }

    /// Get a specific plan by ID
    func getPlan(id: String) throws -> Plan? {
        guard isAvailable else { return nil }
        return try read { db in
            try Plan.fetchOne(db, key: id)
        }
    }

    /// Get a plan day for a specific plan and day number
    func getPlanDay(planId: String, day: Int) throws -> PlanDay? {
        guard isAvailable else { return nil }
        return try read { db in
            try PlanDay
                .filter(Column("plan_id") == planId)
                .filter(Column("day") == day)
                .fetchOne(db)
        }
    }

    /// Get all days for a plan
    func getPlanDays(planId: String) throws -> [PlanDay] {
        guard isAvailable else { return [] }
        return try read { db in
            try PlanDay
                .filter(Column("plan_id") == planId)
                .order(Column("day"))
                .fetchAll(db)
        }
    }

    /// Get the count of plans
    func getPlanCount() throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            try Plan.fetchCount(db)
        }
    }

    // MARK: - Bible Metadata Queries

    /// Cached books loaded from JSON (fallback when not in database)
    private static var cachedBooks: [BibleBook]?
    private static var cachedGenres: [BibleGenre]?

    /// Get all Bible books (from database or JSON fallback)
    func getAllBooks() throws -> [BibleBook] {
        // Try database first
        if isAvailable {
            do {
                let books = try read { db in
                    try BibleBook.order(Column("id")).fetchAll(db)
                }
                if !books.isEmpty {
                    return books
                }
            } catch {
                // Table might not exist yet, fall through to JSON
            }
        }

        // Fall back to JSON file
        return Self.loadBooksFromJSON()
    }

    /// Get a Bible book by ID (1-66)
    func getBook(id: Int) throws -> BibleBook? {
        // Try database first
        if isAvailable {
            do {
                if let book = try read({ db in try BibleBook.fetchOne(db, key: id) }) {
                    return book
                }
            } catch {
                // Table might not exist, fall through to JSON
            }
        }

        // Fall back to JSON
        return Self.loadBooksFromJSON().first { $0.id == id }
    }

    /// Get books by testament (OT or NT)
    func getBooksByTestament(_ testament: String) throws -> [BibleBook] {
        let allBooks = try getAllBooks()
        return allBooks.filter { $0.testament == testament }
    }

    /// Get books by genre ID
    func getBooksByGenre(_ genreId: Int) throws -> [BibleBook] {
        let allBooks = try getAllBooks()
        return allBooks.filter { $0.genre == genreId }
    }

    /// Get book by OSIS ID (e.g., "Gen", "Matt")
    func getBookByOsisId(_ osisId: String) throws -> BibleBook? {
        let allBooks = try getAllBooks()
        return allBooks.first { $0.osisId.lowercased() == osisId.lowercased() }
    }

    /// Get all Bible genres
    func getAllGenres() throws -> [BibleGenre] {
        // Try database first
        if isAvailable {
            do {
                let genres = try read { db in
                    try BibleGenre.order(Column("id")).fetchAll(db)
                }
                if !genres.isEmpty {
                    return genres
                }
            } catch {
                // Table might not exist yet, fall through to JSON
            }
        }

        // Fall back to JSON file
        return Self.loadGenresFromJSON()
    }

    /// Get a genre by ID
    func getGenre(id: Int) throws -> BibleGenre? {
        // Try database first
        if isAvailable {
            do {
                if let genre = try read({ db in try BibleGenre.fetchOne(db, key: id) }) {
                    return genre
                }
            } catch {
                // Table might not exist, fall through to JSON
            }
        }

        // Fall back to JSON
        return Self.loadGenresFromJSON().first { $0.id == id }
    }

    /// Load books from bundled JSON file (cached)
    private static func loadBooksFromJSON() -> [BibleBook] {
        if let cached = cachedBooks {
            return cached
        }

        guard let url = Bundle.main.url(forResource: "books", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("BundledModuleDatabase: Could not load books.json")
            return []
        }

        // Custom decoding to handle JSON keys
        struct JSONBook: Decodable {
            let id: Int
            let genre: Int
            let name: String
            let osisId: String
            let osisParatextAbbreviation: String
            let testament: String
        }

        do {
            let jsonBooks = try JSONDecoder().decode([JSONBook].self, from: data)
            let books = jsonBooks.map { json in
                BibleBook(
                    id: json.id,
                    genre: json.genre,
                    name: json.name,
                    osisId: json.osisId,
                    osisParatextAbbreviation: json.osisParatextAbbreviation,
                    testament: json.testament
                )
            }
            cachedBooks = books
            return books
        } catch {
            print("BundledModuleDatabase: Failed to decode books.json: \(error)")
            return []
        }
    }

    /// Load genres from bundled JSON file (cached)
    private static func loadGenresFromJSON() -> [BibleGenre] {
        if let cached = cachedGenres {
            return cached
        }

        guard let url = Bundle.main.url(forResource: "genres", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("BundledModuleDatabase: Could not load genres.json")
            return []
        }

        do {
            let genres = try JSONDecoder().decode([BibleGenre].self, from: data)
            cachedGenres = genres
            return genres
        } catch {
            print("BundledModuleDatabase: Failed to decode genres.json: \(error)")
            return []
        }
    }
}

// MARK: - Errors

enum BundledModuleDatabaseError: Error {
    case notAvailable
    case queryFailed(String)
}

// MARK: - Unified Translation Access

/// Provides unified access to both bundled and user translations
class TranslationDatabase {
    static let shared = TranslationDatabase()

    private let bundledDb = BundledModuleDatabase.shared
    private let userDb = ModuleDatabase.shared

    private init() {}

    // MARK: - Unified Translation Queries

    /// Get all available translations (bundled + user-imported)
    func getAllTranslations() throws -> [TranslationModule] {
        var translations: [TranslationModule] = []

        // Get bundled translations
        translations.append(contentsOf: try bundledDb.getAllTranslations())

        // Get user translations
        translations.append(contentsOf: try userDb.getAllTranslations(bundledOnly: false))

        return translations.sorted { $0.name < $1.name }
    }

    /// Get a translation by ID (checks bundled first, then user)
    func getTranslation(id: String) throws -> TranslationModule? {
        // Try bundled first
        if let bundled = try bundledDb.getTranslation(id: id) {
            return bundled
        }
        // Then try user database
        return try userDb.getTranslation(id: id)
    }

    /// Check if a translation is bundled
    func isTranslationBundled(id: String) throws -> Bool {
        try bundledDb.isTranslationBundled(id: id)
    }

    // MARK: - Unified Verse Queries

    /// Get verse from appropriate database
    func getVerse(translationId: String, ref: Int) throws -> TranslationVerse? {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getVerse(translationId: translationId, ref: ref)
        } else {
            return try userDb.getVerse(translationId: translationId, ref: ref)
        }
    }

    /// Get verses from multiple translations (may span both databases)
    func getVerses(translationIds: [String], ref: Int) throws -> [String: TranslationVerse] {
        var results: [String: TranslationVerse] = [:]

        // Separate bundled vs user translation IDs
        var bundledIds: [String] = []
        var userIds: [String] = []

        for id in translationIds {
            if try bundledDb.isTranslationBundled(id: id) {
                bundledIds.append(id)
            } else {
                userIds.append(id)
            }
        }

        // Fetch from bundled
        if !bundledIds.isEmpty {
            let bundledVerses = try bundledDb.getVerses(translationIds: bundledIds, ref: ref)
            results.merge(bundledVerses) { _, new in new }
        }

        // Fetch from user
        if !userIds.isEmpty {
            let userVerses = try userDb.getVerses(translationIds: userIds, ref: ref)
            results.merge(userVerses) { _, new in new }
        }

        return results
    }

    /// Get chapter from appropriate database
    func getChapter(translationId: String, book: Int, chapter: Int) throws -> ChapterContent {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getChapter(translationId: translationId, book: book, chapter: chapter)
        } else {
            return try userDb.getChapter(translationId: translationId, book: book, chapter: chapter)
        }
    }

    /// Get multiple chapters from appropriate database (for continuous scrolling)
    func getChapters(translationId: String, chapters: [(book: Int, chapter: Int)]) throws -> [ChapterContent] {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getChapters(translationId: translationId, chapters: chapters)
        } else {
            return try userDb.getChapters(translationId: translationId, chapters: chapters)
        }
    }

    /// Get verse range from appropriate database
    func getVerseRange(translationId: String, startRef: Int, endRef: Int) throws -> [TranslationVerse] {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getVerseRange(translationId: translationId, startRef: startRef, endRef: endRef)
        } else {
            return try userDb.getVerseRange(translationId: translationId, startRef: startRef, endRef: endRef)
        }
    }

    // MARK: - Unified Search

    /// Search across all translations (bundled + user)
    func searchAllTranslations(
        query: String,
        translationIds: Set<String>? = nil,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        var allResults: [TranslationSearchResult] = []

        // Separate translation IDs by database if specified
        if let ids = translationIds {
            var bundledIds: Set<String> = []
            var userIds: Set<String> = []

            for id in ids {
                if try bundledDb.isTranslationBundled(id: id) {
                    bundledIds.insert(id)
                } else {
                    userIds.insert(id)
                }
            }

            // Search bundled
            if !bundledIds.isEmpty {
                allResults.append(contentsOf: try bundledDb.searchVerses(
                    query: query,
                    translationIds: bundledIds,
                    bookRange: bookRange,
                    limit: limit
                ))
            }

            // Search user
            if !userIds.isEmpty {
                allResults.append(contentsOf: try userDb.searchVerses(
                    query: query,
                    translationIds: userIds,
                    bookRange: bookRange,
                    limit: limit
                ))
            }
        } else {
            // Search both databases without filtering
            allResults.append(contentsOf: try bundledDb.searchVerses(
                query: query,
                translationIds: nil,
                bookRange: bookRange,
                limit: limit
            ))

            allResults.append(contentsOf: try userDb.searchVerses(
                query: query,
                translationIds: nil,
                bookRange: bookRange,
                limit: limit
            ))
        }

        // Sort by rank and limit total results
        return Array(allResults.sorted { $0.rank > $1.rank }.prefix(limit))
    }

    // MARK: - Book Metadata

    /// Get books for a translation
    func getTranslationBooks(translationId: String) throws -> [TranslationBook] {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getTranslationBooks(translationId: translationId)
        } else {
            return try userDb.getTranslationBooks(translationId: translationId)
        }
    }

    /// Get a specific book
    func getTranslationBook(translationId: String, bookNumber: Int) throws -> TranslationBook? {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getTranslationBook(translationId: translationId, bookNumber: bookNumber)
        } else {
            return try userDb.getTranslationBook(translationId: translationId, bookNumber: bookNumber)
        }
    }

    // MARK: - Navigation Helpers

    /// Get chapter count for a book
    func getChapterCount(translationId: String, book: Int) throws -> Int {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getChapterCount(translationId: translationId, book: book)
        } else {
            return try userDb.getChapterCount(translationId: translationId, book: book)
        }
    }

    /// Get verse count for a chapter
    func getVerseCount(translationId: String, book: Int, chapter: Int) throws -> Int {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getVerseCount(translationId: translationId, book: book, chapter: chapter)
        } else {
            return try userDb.getVerseCount(translationId: translationId, book: book, chapter: chapter)
        }
    }

    /// Check if a verse exists
    func verseExists(translationId: String, ref: Int) throws -> Bool {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getVerse(translationId: translationId, ref: ref) != nil
        } else {
            return try userDb.verseExists(translationId: translationId, ref: ref)
        }
    }

    /// Get total verse count for a translation
    func getTotalVerseCount(translationId: String) throws -> Int {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getTotalVerseCount(translationId: translationId)
        } else {
            return try userDb.getTotalVerseCount(translationId: translationId)
        }
    }

    /// Count Strong's number occurrences in a translation
    func countStrongsOccurrences(translationId: String, strongsNum: String) throws -> Int {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.countStrongsOccurrences(translationId: translationId, strongsNum: strongsNum)
        } else {
            return try userDb.countStrongsOccurrences(translationId: translationId, strongsNum: strongsNum)
        }
    }

    /// Search verses by Strong's number in annotations_json
    func searchVersesByStrongs(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.searchVersesByStrongs(
                translationId: translationId,
                strongsNum: strongsNum,
                bookRange: bookRange,
                limit: limit
            )
        } else {
            return try userDb.searchVersesByStrongs(
                translationId: translationId,
                strongsNum: strongsNum,
                bookRange: bookRange,
                limit: limit
            )
        }
    }

    /// Get the last verse ref in a chapter
    func getLastVerseRef(translationId: String, book: Int, chapter: Int) throws -> Int {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getLastVerseRef(translationId: translationId, book: book, chapter: chapter)
        } else {
            return try userDb.getLastVerseRef(translationId: translationId, book: book, chapter: chapter)
        }
    }

    /// Get headings for a chapter
    func getHeadingsForChapter(translationId: String, book: Int, chapter: Int) throws -> [TranslationHeading] {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getHeadingsForChapter(translationId: translationId, book: book, chapter: chapter)
        } else {
            return try userDb.getHeadingsForChapter(translationId: translationId, book: book, chapter: chapter)
        }
    }
}
