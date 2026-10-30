//
//  BundledModuleDatabase.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-11.
//

import Foundation
import GRDB
import LampCore
import LampModuleKit

/// Read-only access to bundled modules database (translations, future: commentaries, dictionaries)
/// This database is shipped with the app and cannot be modified by users.
/// Supports both uncompressed (.db) and zlib-compressed (.db.zlib) bundles.
class BundledModuleDatabase {
    static let shared = BundledModuleDatabase()

    private var dbQueue: DatabaseQueue?
    private var isAvailable: Bool = false

    /// Whether the bundled database opened. Callers that cache what they read
    /// need this to tell "nothing there" from "could not look".
    var isReady: Bool { isAvailable }

    /// Cached set of bundled translation ids — see `isTranslationBundled`.
    private var bundledTranslationIds: Set<String>?
    private let bundledTranslationIdsLock = NSLock()

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

        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let sourcePath = Bundle.main.path(forResource: "bundled_modules.db", ofType: "zlib") ?? dbPath
        let sourceSize = ((try? FileManager.default.attributesOfItem(atPath: sourcePath))?[.size] as? Int) ?? 0
        contentStamp = "\(appBuild):\(sourceSize)"

        var config = Configuration()
        config.readonly = true

        do {
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
            isAvailable = true
            print("BundledModuleDatabase: Successfully opened bundled_modules.db")
            // List all tables for debugging
            let tables = try dbQueue!.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            }
            print("BundledModuleDatabase: Tables: \(tables.joined(separator: ", "))")
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

        // Marker combines the app build version with the compressed bundle's byte
        // size. Modification dates are unreliable (iOS rewrites the bundle path on
        // every install/update), and the build version alone misses content-only
        // changes — a rebuilt bundle with the same build number (e.g. local dev
        // rebuilds, or a data-only update) would otherwise reuse the stale copy.
        // Including the compressed size means any changed bundle is re-decompressed.
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let compressedSize = ((try? fileManager.attributesOfItem(atPath: compressedPath))?[.size] as? Int) ?? 0
        let currentVersion = "\(appBuild):\(compressedSize)"

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
            // Mapped and unpacked straight to disk: the database is hundreds
            // of megabytes unpacked, and this runs at launch.
            let compressedData = try Data(
                contentsOf: URL(fileURLWithPath: compressedPath), options: .alwaysMapped
            )
            try LampZlib.decompress(compressedData, to: decompressedURL)
            try currentVersion.write(to: versionMarkerURL, atomically: true, encoding: .utf8)
            let decompressedSize = (try? fileManager.attributesOfItem(atPath: decompressedPath)[.size] as? Int) ?? 0
            print("BundledModuleDatabase: Decompressed \(compressedData.count) -> \(decompressedSize) bytes")
            return decompressedPath
        } catch {
            print("BundledModuleDatabase: Decompression failed: \(error)")
            return nil
        }
    }

    /// Check if bundled database is available
    var available: Bool { isAvailable }

    /// The app build and the bundled file's size: changes whenever the
    /// bundled modules may have, as the decompressed copy's marker does.
    private(set) var contentStamp = ""

    private var reverseLexiconMappingsCache: [String: [String]]?
    private let reverseLexiconMappingsLock = NSLock()

    // MARK: - Database Access

    /// Nothing inside `block` may read this database again, `getBook` and
    /// the book-name cache included: the queue isn't reentrant, and GRDB
    /// traps. Look names up once the read has returned.
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

    /// Check if a translation is bundled.
    ///
    /// Every unified verse/chapter lookup calls this first, so the id set is
    /// cached. The bundled database is read-only, so it can never go stale.
    func isTranslationBundled(id: String) throws -> Bool {
        guard isAvailable else { return false }

        bundledTranslationIdsLock.lock()
        if let ids = bundledTranslationIds {
            bundledTranslationIdsLock.unlock()
            return ids.contains(id)
        }
        bundledTranslationIdsLock.unlock()

        let ids = try read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM translations"))
        }

        bundledTranslationIdsLock.lock()
        bundledTranslationIds = ids
        bundledTranslationIdsLock.unlock()

        return ids.contains(id)
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
        guard !translationIds.isEmpty else { return [:] }
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
        guard isAvailable else {
            return ChapterContent(verses: [], headings: [])
        }
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

    /// Summary statistics for a verse range, without loading the full rows.
    ///
    /// `translation_verses` carries large per-verse JSON columns (`annotations_json`
    /// averages ~2 KB against ~120 bytes of actual text), so the full-row fetch is
    /// wildly wasteful when all the caller wants is a word count and verse tallies.
    func getVerseRangeStats(translationId: String, startRef: Int, endRef: Int) throws -> VerseRangeStats {
        guard isAvailable else { return .unresolved }
        return try read { db in
            try VerseRangeStats.fetch(db, translationId: translationId, startRef: startRef, endRef: endRef)
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

    /// Count the verses in a translation tagging a Strong's number
    func countStrongsOccurrences(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil
    ) throws -> Int {
        guard isAvailable else { return 0 }
        return try read { db in
            try StrongsVerseQuery.count(in: db, translationId: translationId, key: strongsNum, bookRange: bookRange)
        }
    }

    /// Search verses by Strong's number
    func searchVersesByStrongs(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        guard isAvailable else { return [] }
        return try read { db in
            try StrongsVerseQuery.verses(
                in: db, translationId: translationId, key: strongsNum, bookRange: bookRange, limit: limit
            )
        }
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

        // Only the translations this database actually holds: the caller may
        // name installed ones too, and an unfiltered search here would answer
        // for translations it was not asked about.
        let availableTranslationIds = Set(try getAllTranslations().map(\.id))
        let searchableTranslationIds = translationIds.map {
            $0.intersection(availableTranslationIds)
        } ?? availableTranslationIds
        guard !searchableTranslationIds.isEmpty else { return [] }

        let ftsQuery = prepareFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try read { db in
            try TranslationVerseSearch.results(
                in: db,
                ftsQuery: ftsQuery,
                translationIds: searchableTranslationIds,
                bookRange: bookRange,
                limit: limit
            )
        }
    }

    /// Bundled translations answer the same grammar as installed ones.
    /// See `ModuleDatabase.prepareFTSQuery`.
    private func prepareFTSQuery(_ query: String) -> String {
        LampSearchQuery(query).fts5Query
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
    /// Entries matching a query as every search reads one (`LampSearchQuery`):
    /// by key, lemma, transliteration and definitions, and by the words in
    /// the senses' JSON but never its field names, as core searches a
    /// dictionary module. The exact key, then the exact lemma, come first.
    /// An entry search found: its headword and its definitions as plain
    /// text, without the senses to decode.
    struct DictionaryHit {
        let key: String
        let lemma: String
        let transliteration: String?
        let text: String
    }

    func searchDictionaryEntries(
        query: String,
        moduleId: String? = nil,
        keyType: String? = nil,
        limit: Int = 50
    ) throws -> [DictionaryHit] {
        guard isAvailable else { return [] }
        let parsed = LampSearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        return try read { db in
            var moduleIds: [String] = []
            if let moduleId {
                moduleIds = [moduleId]
            } else if let keyType {
                moduleIds = try Module
                    .filter(Column("type") == "dictionary")
                    .filter(Column("key_type") == keyType)
                    .fetchAll(db)
                    .map(\.id)
            }
            var moduleCondition = ""
            var moduleArguments = StatementArguments()
            if !moduleIds.isEmpty {
                moduleCondition = "module_id IN (\(moduleIds.map { _ in "?" }.joined(separator: ", "))) AND"
                moduleArguments += StatementArguments(moduleIds)
            }

            let columns = Set(try db.columns(in: "dictionary_entries").map(\.name))
            let hasSearchText = columns.contains("search_text")
            let searchColumns = ["key", "lemma", "transliteration", "search_text"].filter(columns.contains)
            let like = parsed.sqlLikePredicate(columns: searchColumns, jsonColumns: ["senses_json"])
            var condition = "(\(like.condition))"
            var arguments = moduleArguments
            arguments += StatementArguments(like.arguments)

            // SQLite folds neither Greek accents and breathings nor Hebrew
            // points, so "αγαπη" would never find ἀγάπη: a query in either
            // script is matched against every headword here, accents set
            // aside, and those entries are found alongside.
            if query.unicodeScalars.contains(where: Self.isGreekOrHebrew) {
                let ids = try Self.headwordMatches(for: parsed, moduleIds: moduleIds, in: db)
                if !ids.isEmpty {
                    condition = "(\(condition) OR id IN (\(ids.map { _ in "?" }.joined(separator: ", "))))"
                    arguments += StatementArguments(ids)
                }
            }

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            arguments += [trimmed, trimmed, limit]
            let textColumn = hasSearchText ? "search_text" : "NULL AS search_text"
            return try Row.fetchAll(db, sql: """
                SELECT key, lemma, transliteration, \(textColumn),
                       CASE WHEN \(hasSearchText ? "search_text IS NULL OR search_text = ''" : "1") THEN senses_json END AS senses_json
                FROM dictionary_entries
                WHERE \(moduleCondition) \(condition)
                ORDER BY
                    CASE
                        WHEN key = ? COLLATE NOCASE THEN 0
                        WHEN lemma = ? COLLATE NOCASE THEN 1
                        ELSE 2
                    END,
                    key, lemma
                LIMIT ?
                """, arguments: arguments).map { row in
                    let searchText: String? = row["search_text"]
                    return DictionaryHit(
                        key: row["key"] ?? "",
                        lemma: row["lemma"] ?? "",
                        transliteration: row["transliteration"],
                        text: searchText.flatMap { $0.isEmpty ? nil : $0 }
                            ?? DictionarySearchText.text(fromSensesJSON: row["senses_json"])
                    )
                }
        }
    }

    /// Each module's headwords, accents, points, case and apostrophes folded
    /// away, built on the first Greek or Hebrew search. The database is
    /// read-only, so they never go stale.
    private static var foldedHeadwords: [String: [(id: String, text: String, folded: String)]] = [:]
    private static let foldedHeadwordsLock = NSLock()

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !"'’‘ʼ".contains($0) }
    }

    /// The entries whose headword matches, found among those holding every
    /// word of the query once folded, which core's matcher then confirms:
    /// it is too slow to run over every headword.
    private static func headwordMatches(for parsed: LampSearchQuery, moduleIds: [String], in db: Database) throws -> [String] {
        let words = parsed.plainText.split(whereSeparator: \.isWhitespace).map { folded(String($0)) }.filter { !$0.isEmpty }
        let moduleKeys = moduleIds.isEmpty ? [""] : moduleIds
        var ids: [String] = []
        for moduleKey in moduleKeys {
            foldedHeadwordsLock.lock()
            var headwords = foldedHeadwords[moduleKey]
            foldedHeadwordsLock.unlock()
            if headwords == nil {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, key, lemma, transliteration FROM dictionary_entries
                    WHERE \(moduleKey.isEmpty ? "1" : "module_id = ?")
                    """, arguments: moduleKey.isEmpty ? [] : [moduleKey])
                // Each read optional, spelled out: a headword without a
                // transliteration read as a plain String traps in GRDB.
                let built = rows.compactMap { row -> (id: String, text: String, folded: String)? in
                    let key: String? = row["key"]
                    let lemma: String? = row["lemma"]
                    let transliteration: String? = row["transliteration"]
                    let id: DatabaseValue = row["id"]
                    guard let identifier = String.fromDatabaseValue(id) ?? Int64.fromDatabaseValue(id).map(String.init) else {
                        return nil
                    }
                    let text = [key, lemma, transliteration].compactMap { $0 }.joined(separator: " ")
                    return (identifier, text, folded(text))
                }
                foldedHeadwordsLock.lock()
                foldedHeadwords[moduleKey] = built
                foldedHeadwordsLock.unlock()
                headwords = built
            }
            ids += (headwords ?? []).filter { headword in
                words.allSatisfy { headword.folded.contains($0) } && parsed.matches(headword.text)
            }.map(\.id)
        }
        return ids
    }

    private static func isGreekOrHebrew(_ scalar: Unicode.Scalar) -> Bool {
        (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
            || (0x0590...0x05FF).contains(scalar.value)
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

    // MARK: - Long-form Book Queries

    /// Whether this app bundle contains the optional long-form book tables.
    func hasBookModulesTable() -> Bool {
        guard isAvailable else { return false }
        return (try? read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'book_modules'
                """) ?? 0
        }) == 1
    }

    func getBookModules() throws -> [BookModule] {
        guard hasBookModulesTable() else { return [] }
        return try read { db in
            try BookModule
                .order(Column("title").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    func getBookModule(id: String) throws -> BookModule? {
        guard hasBookModulesTable() else { return nil }
        return try read { db in
            try BookModule.fetchOne(db, key: id)
        }
    }

    func getBookSectionTitle(id: String) throws -> String? {
        guard hasBookModulesTable() else { return nil }
        return try read { db in
            try String.fetchOne(db, sql: "SELECT title FROM book_sections WHERE id = ?", arguments: [id])
        }
    }

    func getBookSections(moduleId: String) throws -> [BookSection] {
        guard hasBookModulesTable() else { return [] }
        return try read { db in
            try BookSection.fetchAll(
                db,
                sql: "SELECT * FROM book_sections WHERE module_id = ? ORDER BY rowid",
                arguments: [moduleId]
            )
        }
    }

    func getBookSection(id: String) throws -> BookSection? {
        guard hasBookModulesTable() else { return nil }
        return try read { db in
            try BookSection.fetchOne(db, key: id)
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
        return try reverseLexiconMappings()[targetKey] ?? []
    }

    /// Every target key's sources, in table order, read once: finding one
    /// meant a LIKE over the whole table, and a BDB search asks for each
    /// entry it shows. The database is read-only, so it never goes stale.
    private func reverseLexiconMappings() throws -> [String: [String]] {
        reverseLexiconMappingsLock.lock()
        defer { reverseLexiconMappingsLock.unlock() }
        if let cached = reverseLexiconMappingsCache { return cached }
        var mappings: [String: [String]] = [:]
        try read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT source_key, target_keys_json FROM lexicon_mappings ORDER BY id")
            while let row = try rows.next() {
                guard let source: String = row["source_key"],
                      let json: String = row["target_keys_json"],
                      let targets = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { continue }
                for target in Set(targets) {
                    mappings[target, default: []].append(source)
                }
            }
        }
        reverseLexiconMappingsCache = mappings
        return mappings
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

    // MARK: - Quiz Queries

    /// Check if the bundled database has the quiz_modules table
    func hasQuizModulesTable() -> Bool {
        guard isAvailable else { return false }
        do {
            return try read { db in
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type='table' AND name='quiz_modules'
                """) ?? 0
                print("[BundledModuleDatabase] hasQuizModulesTable: \(count > 0)")
                return count > 0
            }
        } catch {
            print("[BundledModuleDatabase] hasQuizModulesTable error: \(error)")
            return false
        }
    }

    /// Get all bundled quiz modules
    func getAllQuizModules() throws -> [QuizModule] {
        guard isAvailable, hasQuizModulesTable() else {
            print("[BundledModuleDatabase] getAllQuizModules: not available or no table")
            return []
        }
        return try read { db in
            let modules = try QuizModule.order(Column("name")).fetchAll(db)
            print("[BundledModuleDatabase] getAllQuizModules: fetched \(modules.count) modules")
            return modules
        }
    }

    /// Get a quiz module by ID
    func getQuizModule(id: String) throws -> QuizModule? {
        guard isAvailable, hasQuizModulesTable() else { return nil }
        return try read { db in
            try QuizModule.fetchOne(db, key: id)
        }
    }

    /// Get quiz modules for a specific plan
    func getQuizModulesForPlan(planId: String) throws -> [QuizModule] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try QuizModule
                .filter(Column("plan_id") == planId)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get quiz questions for a specific day and age group
    func getQuizQuestions(moduleId: String, day: Int, ageGroup: String) throws -> [QuizQuestion] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .filter(Column("day") == day)
                .filter(Column("age_group") == ageGroup)
                .order(Column("question_index"))
                .fetchAll(db)
        }
    }

    /// Get quiz questions for a specific reading (sv/ev) and age group
    func getQuizQuestionsForReading(moduleId: String, day: Int, sv: Int, ev: Int, ageGroup: String) throws -> [QuizQuestion] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .filter(Column("day") == day)
                .filter(Column("sv") == sv)
                .filter(Column("ev") == ev)
                .filter(Column("age_group") == ageGroup)
                .order(Column("question_index"))
                .fetchAll(db)
        }
    }

    /// Get all quiz questions for a day (all readings, all age groups)
    func getQuizQuestionsForDay(moduleId: String, day: Int) throws -> [QuizQuestion] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .filter(Column("day") == day)
                .order(Column("sv"), Column("age_group"), Column("question_index"))
                .fetchAll(db)
        }
    }

    /// Get all available age groups for a quiz module
    func getQuizAgeGroups(moduleId: String) throws -> [QuizAgeGroup] {
        guard let module = try getQuizModule(id: moduleId) else { return [] }
        return module.ageGroups
    }

    /// Get distinct age groups used in quiz questions for a module
    func getQuizQuestionAgeGroups(moduleId: String) throws -> [String] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT age_group FROM quiz_questions
                WHERE quiz_module_id = ?
                ORDER BY age_group
            """, arguments: [moduleId])
        }
    }

    /// Get question count for a module
    func getQuizQuestionCount(moduleId: String) throws -> Int {
        guard isAvailable, hasQuizModulesTable() else { return 0 }
        return try read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .fetchCount(db)
        }
    }

    /// Get distinct days that have quiz questions for a module
    func getQuizDays(moduleId: String) throws -> [Int] {
        guard isAvailable, hasQuizModulesTable() else { return [] }
        return try read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT day FROM quiz_questions
                WHERE quiz_module_id = ?
                ORDER BY day
            """, arguments: [moduleId])
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

    /// Summary statistics for a verse range, without loading the full rows.
    ///
    /// A tally of zero only means "this reading has no verses" when the
    /// translation it was counted from actually exists. Otherwise the zero is
    /// an unknown — the module may not be installed yet, or the bundled
    /// database may not have opened, in which case `isTranslationBundled`
    /// reports false and the lookup lands here. Returning `.unresolved` keeps
    /// callers from caching or displaying that as an answer.
    func getVerseRangeStats(translationId: String, startRef: Int, endRef: Int) throws -> VerseRangeStats {
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.getVerseRangeStats(translationId: translationId, startRef: startRef, endRef: endRef)
        }
        let stats = try userDb.getVerseRangeStats(
            translationId: translationId,
            startRef: startRef,
            endRef: endRef
        )
        // The existence check costs a query, so it is only paid when there was
        // nothing to count.
        guard stats.verseCount == 0 else { return stats }
        return try userDb.getTranslation(id: translationId) == nil ? .unresolved : stats
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

    /// What the translation's Strong's tags say about one key
    /// (`LampStrongsAnalyzer`), measured against every tagged verse of it, not
    /// only the ones holding the key, and keeping those verses' text to show.
    /// A pass over the whole translation: call it off the main thread.
    func analyzeStrongs(key: String, translationId: String) throws -> LampStrongsAnalysis? {
        guard let translation = try getTranslation(id: translationId) else { return nil }
        var analyzer = LampStrongsAnalyzer(
            key: key,
            translationID: translation.id,
            translationName: translation.name,
            translationAbbreviation: translation.abbreviation,
            language: translation.language,
            includingVerseText: true
        )
        func feed(_ db: Database) throws {
            let rows = try Row.fetchCursor(db, sql: """
                SELECT ref, text, annotations_json FROM translation_verses
                WHERE translation_id = ? AND annotations_json IS NOT NULL
                """, arguments: [translationId])
            while let row = try rows.next() {
                // The text is read only for a verse holding the key.
                analyzer.add(reference: row["ref"], text: row["text"] ?? "", annotationsJSON: row["annotations_json"])
            }
        }
        if try bundledDb.isTranslationBundled(id: translationId) {
            try bundledDb.read(feed)
        } else {
            try userDb.read(feed)
        }
        return analyzer.analysis()
    }

    /// Count Strong's number occurrences in a translation
    /// The database the translation's verses are in.
    func verseSource(for translationId: String) throws -> TranslationVerseSource {
        try bundledDb.isTranslationBundled(id: translationId) ? bundledDb : userDb
    }

    /// From the Strong's index, or, while the translation has none, by
    /// reading the verses that may tag the key.
    func countStrongsOccurrences(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil
    ) throws -> Int {
        if let refs = StrongsIndex.shared.refs(
            translationId: translationId, key: strongsNum, bookRange: bookRange,
            source: try verseSource(for: translationId)
        ) {
            return refs.count
        }
        if try bundledDb.isTranslationBundled(id: translationId) {
            return try bundledDb.countStrongsOccurrences(
                translationId: translationId, strongsNum: strongsNum, bookRange: bookRange
            )
        } else {
            return try userDb.countStrongsOccurrences(
                translationId: translationId, strongsNum: strongsNum, bookRange: bookRange
            )
        }
    }

    /// The verses tagging a Strong's number, from the index, or, while the
    /// translation has none, by reading the verses that may tag it.
    func searchVersesByStrongs(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        let source = try verseSource(for: translationId)
        if let refs = StrongsIndex.shared.refs(
            translationId: translationId, key: strongsNum, bookRange: bookRange, source: source
        ) {
            let shown = Array(refs.prefix(limit))
            return try source.read { db in
                try StrongsVerseQuery.verses(in: db, translationId: translationId, key: strongsNum, refs: shown)
            }
        }
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

/// The verses a Strong's key tags, in either database: core's prefilter by
/// the key's letters and number, then each candidate's tags read with the
/// scanner the analysis uses. A key inside a comma-joined tag ("H996,H914")
/// is found, so a key's count, its verse list and its analysis agree.
enum StrongsVerseQuery {
    static func count(
        in db: Database,
        translationId: String,
        key: String,
        bookRange: ClosedRange<Int>? = nil
    ) throws -> Int {
        let prefilter = LampStrongsSearch.sqlPrefilter(for: key, column: "annotations_json")
        var arguments = StatementArguments([translationId] + prefilter.arguments)
        var books = ""
        if let bookRange {
            books = " AND book BETWEEN ? AND ?"
            arguments += [bookRange.lowerBound, bookRange.upperBound]
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT annotations_json FROM translation_verses
            WHERE translation_id = ? AND \(prefilter.condition)\(books)
            """, arguments: arguments)
        var count = 0
        while let row = try rows.next() {
            if LampStrongsSearch.holdsKey(row["annotations_json"], key: key) { count += 1 }
        }
        return count
    }

    static func verses(
        in db: Database,
        translationId: String,
        key: String,
        bookRange: ClosedRange<Int>?,
        limit: Int
    ) throws -> [TranslationSearchResult] {
        let prefilter = LampStrongsSearch.sqlPrefilter(for: key, column: "v.annotations_json")
        var conditions = ["v.translation_id = ?", prefilter.condition]
        var arguments: [DatabaseValueConvertible] = [translationId] + prefilter.arguments
        if let range = bookRange {
            conditions.append("v.book BETWEEN ? AND ?")
            arguments.append(range.lowerBound)
            arguments.append(range.upperBound)
        }
        let rows = try Row.fetchCursor(db, sql: """
            SELECT v.translation_id, t.name AS translation_name, t.abbreviation AS translation_abbrev,
                   v.ref, v.book, v.chapter, v.verse, v.text, v.annotations_json
            FROM translation_verses v
            JOIN translations t ON v.translation_id = t.id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY v.ref
            """, arguments: StatementArguments(arguments))
        var results: [TranslationSearchResult] = []
        while results.count < limit, let row = try rows.next() {
            let annotationsJson: String? = row["annotations_json"]
            guard LampStrongsSearch.holdsKey(annotationsJson, key: key) else { continue }
            results.append(result(from: row, key: key))
        }
        return results
    }

    /// The verses at `refs`, which the Strong's index found tagging `key`,
    /// in order.
    static func verses(in db: Database, translationId: String, key: String, refs: [Int]) throws -> [TranslationSearchResult] {
        var results: [TranslationSearchResult] = []
        var start = 0
        while start < refs.count {
            let chunk = refs[start..<min(start + 500, refs.count)]
            start += chunk.count
            results += try Row.fetchAll(db, sql: """
                SELECT v.translation_id, t.name AS translation_name, t.abbreviation AS translation_abbrev,
                       v.ref, v.book, v.chapter, v.verse, v.text, v.annotations_json
                FROM translation_verses v
                JOIN translations t ON v.translation_id = t.id
                WHERE v.translation_id = ? AND v.ref IN (\(chunk.map { _ in "?" }.joined(separator: ", ")))
                ORDER BY v.ref
                """, arguments: StatementArguments([translationId] + Array(chunk))
            ).map { result(from: $0, key: key) }
        }
        return results
    }

    private static func result(from row: Row, key: String) -> TranslationSearchResult {
        let annotationsJson: String? = row["annotations_json"]
        let text: String = row["text"] ?? ""
        return TranslationSearchResult(
            id: "\(row["translation_id"] as String):\(row["ref"] as Int)",
            translationId: row["translation_id"],
            translationName: row["translation_name"] ?? "",
            translationAbbrev: row["translation_abbrev"] ?? "",
            ref: row["ref"],
            book: row["book"],
            chapter: row["chapter"],
            verse: row["verse"],
            snippet: LampStrongsSearch.markedText(text, annotationsJSON: annotationsJson, key: key),
            rank: 1.0,
            rawText: annotationsJson
        )
    }
}
