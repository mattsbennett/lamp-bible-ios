//
//  ModuleSearch.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import LampCore

// MARK: - Search Result

struct ModuleSearchResult: Identifiable {
    let id: String
    let moduleId: String
    let moduleName: String
    let moduleType: ModuleType
    let title: String
    let snippet: String
    let verseId: Int?
    let rank: Double

    // Extra metadata for display
    var monthDay: String? = nil
    var tags: [String]? = nil
    var strongsKey: String? = nil
    var highlightColor: String? = nil  // Hex color for highlight results
    var highlightStyle: HighlightStyle? = nil  // Style for highlight results
    /// A highlight's own translation, which its offsets count into.
    var translationId: String? = nil

    // For navigation
    var book: Int? { verseId.map { $0 / 1000000 } }
    var chapter: Int? { verseId.map { ($0 % 1000000) / 1000 } }
    var verse: Int? { verseId.map { $0 % 1000 } }
}

// MARK: - Search Filter

struct ModuleSearchFilter {
    // Module type filter
    var types: Set<ModuleType> = Set(ModuleType.allCases)

    // Specific module filter (nil = all modules of the type)
    var moduleIds: Set<String>? = nil

    // Include bundled dictionaries (Strong's, BDB, Dodson)
    var includeBundledDictionaries: Bool = true

    // Devotional filters
    var monthDay: String? = nil  // Format: "01-15" for January 15 (legacy)
    var devotionalDate: String? = nil  // ISO 8601: YYYY-MM-DD
    var tags: Set<String>? = nil
    var categories: Set<DevotionalCategory>? = nil

    // Dictionary filters
    var strongsKey: String? = nil  // Filter by Strong's number

    // Translation filters
    var translationIds: Set<String>? = nil  // Specific translations to search
    var bookRange: ClosedRange<Int>? = nil  // Book range (1-39 OT, 40-66 NT)

    // Highlight filters
    var highlightColors: Set<String>? = nil  // Filter by highlight color hex values
    var highlightColorOnly: Bool = false     // Search by color only (no text query required)

    static var `default`: ModuleSearchFilter { ModuleSearchFilter() }
}

// MARK: - Available Module Info

struct SearchableModule: Identifiable {
    let id: String
    let name: String
    let type: ModuleType
    let isBundled: Bool
    let seriesAbbrev: String?  // For commentaries - series abbreviation (e.g., "MHCC")
    let seriesFull: String?    // For commentaries - full series name

    init(id: String, name: String, type: ModuleType, isBundled: Bool, seriesAbbrev: String? = nil, seriesFull: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isBundled = isBundled
        self.seriesAbbrev = seriesAbbrev
        self.seriesFull = seriesFull
    }
}

// MARK: - Module Search

class ModuleSearch {
    static let shared = ModuleSearch()

    private let database = ModuleDatabase.shared

    private init() {}

    // MARK: - Available Modules

    /// Get all searchable modules for filter UI
    func getSearchableModules() -> [SearchableModule] {
        var modules: [SearchableModule] = []

        // Bundled dictionaries - grouped by language
        modules.append(SearchableModule(id: "strongs-greek", name: "Strong's Greek", type: .dictionary, isBundled: true, seriesAbbrev: "Greek"))
        modules.append(SearchableModule(id: "strongs-hebrew", name: "Strong's Hebrew", type: .dictionary, isBundled: true, seriesAbbrev: "Hebrew"))
        modules.append(SearchableModule(id: "dodson", name: "Dodson Greek", type: .dictionary, isBundled: true, seriesAbbrev: "Greek"))
        modules.append(SearchableModule(id: "bdb", name: "Brown-Driver-Briggs", type: .dictionary, isBundled: true, seriesAbbrev: "Hebrew"))

        // GRDB translations (bundled + user)
        do {
            let translations = try TranslationDatabase.shared.getAllTranslations()
            for translation in translations {
                modules.append(SearchableModule(
                    id: translation.id,
                    name: translation.name,
                    type: .translation,
                    isBundled: translation.isBundled,
                    seriesAbbrev: translation.abbreviation
                ))
            }
        } catch {
            print("Failed to get translations: \(error)")
        }

        // User modules from SQLite (excluding highlights - those are added via highlight sets below)
        do {
            let bundledBooks = try BundledModuleDatabase.shared.getBookModules()
            modules.append(contentsOf: bundledBooks.map {
                SearchableModule(id: $0.id, name: $0.title, type: .book, isBundled: true)
            })
        } catch {
            print("Failed to get bundled books: \(error)")
        }

        // The bundled commentaries, the Treasury and the cross-references,
        // which live in the bundled database rather than the user's.
        if BundledModuleDatabase.shared.available {
            do {
                let bundledCommentaries = try BundledModuleDatabase.shared.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, name FROM modules WHERE type = 'commentary' ORDER BY name")
                }
                modules.append(contentsOf: bundledCommentaries.map {
                    SearchableModule(id: $0["id"], name: $0["name"], type: .commentary, isBundled: true)
                })
            } catch {
                print("Failed to get bundled commentaries: \(error)")
            }
        }

        do {
            let userModules = try database.getAllModules()

            // Get series info for commentary modules
            let commentarySeriesInfo = getCommentarySeriesInfo()

            for module in userModules {
                // Skip highlight modules - they're added via highlight sets below
                if module.type == .highlights {
                    continue
                }

                if module.type == .commentary, let seriesInfo = commentarySeriesInfo[module.id] {
                    modules.append(SearchableModule(
                        id: module.id,
                        name: module.name,
                        type: module.type,
                        isBundled: false,
                        seriesAbbrev: seriesInfo.abbrev,
                        seriesFull: seriesInfo.full
                    ))
                } else if module.type == .dictionary {
                    // Group user dictionaries by keyType if available
                    let series = dictionarySeriesFromKeyType(module.keyType)
                    modules.append(SearchableModule(
                        id: module.id,
                        name: module.name,
                        type: module.type,
                        isBundled: false,
                        seriesAbbrev: series
                    ))
                } else {
                    modules.append(SearchableModule(id: module.id, name: module.name, type: module.type, isBundled: false))
                }
            }
        } catch {
            print("Failed to get user modules: \(error)")
        }

        // Reading plans and quizzes, the bundled ones and the user's; a user's
        // copy stands in for a bundled one of the same ID.
        var plans: [String: SearchableModule] = [:]
        for plan in (try? BundledModuleDatabase.shared.getAllPlans()) ?? [] {
            plans[plan.id] = SearchableModule(id: plan.id, name: plan.name, type: .plan, isBundled: true)
        }
        for plan in (try? database.getAllPlans()) ?? [] {
            plans[plan.id] = SearchableModule(id: plan.id, name: plan.name, type: .plan, isBundled: false)
        }
        modules.append(contentsOf: plans.values.sorted { $0.name < $1.name })
        var quizzes: [String: SearchableModule] = [:]
        for quiz in (try? BundledModuleDatabase.shared.getAllQuizModules()) ?? [] {
            quizzes[quiz.id] = SearchableModule(id: quiz.id, name: quiz.name, type: .quiz, isBundled: true)
        }
        for quiz in (try? database.getAllQuizModules()) ?? [] {
            quizzes[quiz.id] = SearchableModule(id: quiz.id, name: quiz.name, type: .quiz, isBundled: false)
        }
        modules.append(contentsOf: quizzes.values.sorted { $0.name < $1.name })

        // Highlight sets
        do {
            let highlightSets = try database.getAllHighlightSets()
            for set in highlightSets {
                modules.append(SearchableModule(
                    id: set.id,
                    name: set.name,
                    type: .highlights,
                    isBundled: false,
                    seriesAbbrev: set.translationId.uppercased()
                ))
            }
        } catch {
            print("Failed to get highlight sets: \(error)")
        }

        return modules
    }

    /// Convert dictionary keyType to a display series name
    private func dictionarySeriesFromKeyType(_ keyType: String?) -> String? {
        guard let keyType = keyType else { return nil }
        switch keyType.lowercased() {
        case "strongs-greek", "greek":
            return "Greek"
        case "strongs-hebrew", "hebrew":
            return "Hebrew"
        default:
            return nil
        }
    }

    /// Get series info for all commentary modules
    private func getCommentarySeriesInfo() -> [String: (abbrev: String?, full: String?)] {
        do {
            return try database.read { db in
                let sql = """
                    SELECT DISTINCT module_id, series_abbrev, series_full
                    FROM commentary_books
                    WHERE series_abbrev IS NOT NULL OR series_full IS NOT NULL
                """
                let rows = try Row.fetchAll(db, sql: sql)
                var result: [String: (abbrev: String?, full: String?)] = [:]
                for row in rows {
                    let moduleId: String = row["module_id"]
                    let abbrev: String? = row["series_abbrev"]
                    let full: String? = row["series_full"]
                    result[moduleId] = (abbrev: abbrev, full: full)
                }
                return result
            }
        } catch {
            print("Failed to get commentary series info: \(error)")
            return [:]
        }
    }

    /// Get unique tags from all devotionals
    func getAllDevotionalTags() -> [String] {
        do {
            return try database.read { db in
                let sql = "SELECT DISTINCT tags FROM devotional_entries WHERE tags IS NOT NULL AND tags != ''"
                let rows = try Row.fetchAll(db, sql: sql)
                var allTags = Set<String>()
                for row in rows {
                    if let tagsStr: String = row["tags"] {
                        for tag in tagsStr.split(separator: ",") {
                            allTags.insert(String(tag).trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
                return Array(allTags).sorted()
            }
        } catch {
            return []
        }
    }

    /// Get all unique highlight colors used across all highlight sets
    /// Returns default colors plus any custom colors found in highlights
    func getAllHighlightColors() -> [HighlightColor] {
        var colors = Set(HighlightColor.defaultColors.map { $0.hex })

        // Add any custom colors from existing highlights
        if let customHexes = try? database.getUniqueHighlightColors() {
            for hex in customHexes {
                colors.insert(hex.uppercased())
            }
        }

        // Return sorted by default order first, then custom colors
        let defaultHexes = Set(HighlightColor.defaultColors.map { $0.hex })
        let sortedColors = HighlightColor.defaultColors + colors
            .filter { !defaultHexes.contains($0) }
            .sorted()
            .map { HighlightColor(hex: $0) }

        return sortedColors
    }

    // MARK: - Unified Search

    /// Search across all module types with filters
    func search(query: String, filter: ModuleSearchFilter = .default, limit: Int = 50) throws -> [ModuleSearchResult] {
        var results: [ModuleSearchResult] = []

        // Escape FTS5 special characters and prepare query
        let ftsQuery = prepareFTSQuery(query)

        // Allow empty query for dictionary key search or highlight color-only search
        let hasTextQuery = !ftsQuery.isEmpty
        let hasKeyFilter = filter.strongsKey != nil
        let hasColorFilter = filter.highlightColorOnly && filter.highlightColors != nil

        guard hasTextQuery || hasKeyFilter || hasColorFilter else { return [] }

        if filter.types.contains(.dictionary) {
            // User dictionaries (SQLite)
            if hasTextQuery {
                results.append(contentsOf: try searchDictionaries(ftsQuery: ftsQuery, filter: filter, limit: limit))
            } else if hasKeyFilter {
                // Key-only search for user dictionaries
                results.append(contentsOf: try searchDictionariesByKey(filter: filter, limit: limit))
            }

            // Bundled dictionaries (Realm)
            if filter.includeBundledDictionaries {
                results.append(contentsOf: searchBundledDictionaries(query: query, filter: filter, limit: limit))
            }
        }

        if filter.types.contains(.commentary) && hasTextQuery {
            results.append(contentsOf: try searchCommentaries(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.book) && hasTextQuery {
            results.append(contentsOf: try searchBooks(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.devotional) && hasTextQuery {
            results.append(contentsOf: try searchDevotionals(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.notes) && hasTextQuery {
            results.append(contentsOf: try searchNotes(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.translation) {
            if hasTextQuery {
                results.append(contentsOf: try searchTranslations(query: query, filter: filter, limit: limit))
            } else if hasKeyFilter {
                // Strong's key search for translations with Strong's support
                results.append(contentsOf: try searchTranslationsByStrongs(filter: filter, limit: limit))
            }
        }

        if filter.types.contains(.plan) && hasTextQuery {
            results.append(contentsOf: try searchPlans(query: query, filter: filter, limit: limit))
        }

        if filter.types.contains(.quiz) && hasTextQuery {
            results.append(contentsOf: try searchQuizzes(query: query, filter: filter, limit: limit))
        }

        if filter.types.contains(.highlights) && (hasTextQuery || hasColorFilter) {
            results.append(contentsOf: try searchHighlights(query: query, filter: filter, limit: limit))
        }

        // Sort by rank (higher is better match)
        results.sort { $0.rank > $1.rank }

        // Apply overall limit
        return Array(results.prefix(limit))
    }


    // MARK: - Type-Specific Search

    private func searchBooks(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var results = try database.read { db in
            try searchBooks(in: db, ftsQuery: ftsQuery, filter: filter, limit: limit)
        }

        if BundledModuleDatabase.shared.hasBookModulesTable() {
            results.append(contentsOf: try BundledModuleDatabase.shared.read { db in
                try searchBooks(in: db, ftsQuery: ftsQuery, filter: filter, limit: limit)
            })
        }

        return results
    }

    private func searchBooks(
        in db: Database,
        ftsQuery: String,
        filter: ModuleSearchFilter,
        limit: Int
    ) throws -> [ModuleSearchResult] {
        var conditions = ["book_sections_fts MATCH ?"]
        var arguments: [DatabaseValueConvertible] = [ftsQuery]

        if let moduleIds = filter.moduleIds {
            guard !moduleIds.isEmpty else { return [] }
            let sortedIds = moduleIds.sorted()
            let placeholders = sortedIds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("s.module_id IN (\(placeholders))")
            arguments.append(contentsOf: sortedIds)
        }

        arguments.append(limit)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT s.id, s.module_id, s.title, s.subtitle, s.key_scriptures_json,
                       b.title AS module_name,
                       bm25(book_sections_fts) AS rank,
                       snippet(book_sections_fts, 1, '<mark>', '</mark>', '...', 32) AS snippet
                FROM book_sections_fts f
                JOIN book_sections s ON f.rowid = s.rowid
                JOIN book_modules b ON s.module_id = b.id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY rank
                LIMIT ?
                """,
            arguments: StatementArguments(arguments)
        )

        return rows.map { row in
            let title: String = row["title"]
            let subtitle: String? = row["subtitle"]
            return ModuleSearchResult(
                id: row["id"],
                moduleId: row["module_id"],
                moduleName: row["module_name"],
                moduleType: .book,
                title: subtitle.map { "\(title): \($0)" } ?? title,
                snippet: row["snippet"] ?? "",
                verseId: firstScriptureReference(in: row["key_scriptures_json"]),
                rank: -(row["rank"] as Double)
            )
        }
    }

    private func firstScriptureReference(in json: String?) -> Int? {
        guard let json,
              let data = json.data(using: .utf8),
              let ranges = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = ranges.first else { return nil }
        return first["sv"] as? Int
    }

    private func searchDictionaries(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            // Build module filter clause
            var moduleCondition = ""
            var moduleArgs: [DatabaseValueConvertible] = []
            if let moduleIds = filter.moduleIds {
                let userModuleIds = Self.userDictionaryIDs(in: moduleIds)
                // Only bundled dictionaries chosen: none of the user's.
                guard !userModuleIds.isEmpty else { return [] }
                let placeholders = userModuleIds.map { _ in "?" }.joined(separator: ", ")
                moduleCondition = "AND d.module_id IN (\(placeholders))"
                moduleArgs = userModuleIds.map { $0 as DatabaseValueConvertible }
            }

            // FTS search
            let ftsSql = """
                SELECT
                    d.id, d.module_id, d.key, d.lemma, d.senses_json,
                    m.name as module_name,
                    bm25(dictionary_fts) as rank,
                    snippet(dictionary_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
                FROM dictionary_fts f
                JOIN dictionary_entries d ON f.rowid = d.rowid
                JOIN modules m ON d.module_id = m.id
                WHERE dictionary_fts MATCH ? \(moduleCondition)
                ORDER BY rank
                LIMIT ?
            """
            var ftsArgs: [DatabaseValueConvertible] = [ftsQuery]
            ftsArgs.append(contentsOf: moduleArgs)
            ftsArgs.append(limit)

            // Extract search terms for finding matching sense
            let searchTerms = ftsQuery
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { $0.lowercased() }

            var results = try Row.fetchAll(db, sql: ftsSql, arguments: StatementArguments(ftsArgs)).map { row -> ModuleSearchResult in
                var shortDef: String? = nil
                if let sensesJson: String = row["senses_json"],
                   let data = sensesJson.data(using: .utf8),
                   let senses = try? JSONDecoder().decode([DictionarySense].self, from: data) {
                    // Find the sense that contains a search term (not just first sense)
                    for sense in senses {
                        let defText = sense.definitionText ?? sense.shortDefinitionText ?? sense.gloss ?? ""
                        let defLower = defText.lowercased()
                        if searchTerms.contains(where: { defLower.contains($0) }) {
                            shortDef = defText
                            break
                        }
                    }
                    // Fall back to first sense if no match found
                    if shortDef == nil, let first = senses.first {
                        shortDef = first.definitionText ?? first.shortDefinitionText ?? first.gloss
                    }
                }

                let key: String = row["key"]
                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .dictionary,
                    title: "\(row["lemma"] as String) (\(key))",
                    // Use parsed definition text instead of raw FTS snippet (which contains JSON)
                    snippet: shortDef ?? "",
                    verseId: nil,
                    rank: -(row["rank"] as Double),
                    strongsKey: key
                )
            }

            // Also search by key (since key is not in FTS index)
            // Extract potential key from query (e.g., "G2316" or "H430")
            let keyPattern = ftsQuery.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "").uppercased()
            if keyPattern.count >= 2 {
                let keySql = """
                    SELECT
                        d.id, d.module_id, d.key, d.lemma, d.senses_json,
                        m.name as module_name
                    FROM dictionary_entries d
                    JOIN modules m ON d.module_id = m.id
                    WHERE d.key LIKE ? \(moduleCondition)
                    LIMIT ?
                """
                var keyArgs: [DatabaseValueConvertible] = ["%\(keyPattern)%"]
                keyArgs.append(contentsOf: moduleArgs)
                keyArgs.append(limit)

                let keyResults = try Row.fetchAll(db, sql: keySql, arguments: StatementArguments(keyArgs)).compactMap { row -> ModuleSearchResult? in
                    let id: String = row["id"]
                    // Skip if already in FTS results
                    if results.contains(where: { $0.id == id }) {
                        return nil
                    }

                    var shortDef: String? = nil
                    if let sensesJson: String = row["senses_json"],
                       let data = sensesJson.data(using: .utf8),
                       let senses = try? JSONDecoder().decode([DictionarySense].self, from: data),
                       let first = senses.first {
                        shortDef = first.shortDefinitionText ?? first.gloss
                    }

                    let key: String = row["key"]
                    return ModuleSearchResult(
                        id: id,
                        moduleId: row["module_id"],
                        moduleName: row["module_name"],
                        moduleType: .dictionary,
                        title: "\(row["lemma"] as String) (\(key))",
                        snippet: shortDef ?? "",
                        verseId: nil,
                        rank: 5.0,  // Good rank for key match
                        strongsKey: key
                    )
                }
                results.append(contentsOf: keyResults)
            }

            return results
        }
    }

    /// The chosen modules that aren't a bundled dictionary, which the filter
    /// lists under their own IDs.
    private static func userDictionaryIDs(in moduleIds: Set<String>) -> [String] {
        moduleIds.filter { !$0.hasPrefix("strongs-") && $0 != "dodson" && $0 != "bdb" }.sorted()
    }

    /// Search user dictionaries by key only (no FTS)
    private func searchDictionariesByKey(filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        guard let key = filter.strongsKey else { return [] }

        return try database.read { db in
            var conditions = ["d.key = ?"]
            var arguments: [DatabaseValueConvertible] = [key]

            // Module filter
            if let moduleIds = filter.moduleIds {
                let userModuleIds = Self.userDictionaryIDs(in: moduleIds)
                // Only bundled dictionaries chosen: none of the user's.
                guard !userModuleIds.isEmpty else { return [] }
                let placeholders = userModuleIds.map { _ in "?" }.joined(separator: ", ")
                conditions.append("d.module_id IN (\(placeholders))")
                arguments.append(contentsOf: userModuleIds)
            }

            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
                SELECT
                    d.id, d.module_id, d.key, d.lemma, d.senses_json,
                    m.name as module_name
                FROM dictionary_entries d
                JOIN modules m ON d.module_id = m.id
                WHERE \(whereClause)
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                var shortDef: String? = nil
                if let sensesJson: String = row["senses_json"],
                   let data = sensesJson.data(using: .utf8),
                   let senses = try? JSONDecoder().decode([DictionarySense].self, from: data),
                   let first = senses.first {
                    shortDef = first.shortDefinitionText ?? first.gloss
                }

                let entryKey: String = row["key"]
                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .dictionary,
                    title: "\(row["lemma"] as String) (\(entryKey))",
                    snippet: shortDef ?? "",
                    verseId: nil,
                    rank: 10.0,  // High rank for exact key match
                    strongsKey: entryKey
                )
            }
        }
    }

    /// Search bundled dictionaries via GRDB BundledModuleDatabase
    private func searchBundledDictionaries(query: String, filter: ModuleSearchFilter, limit: Int) -> [ModuleSearchResult] {
        let bundledDb = BundledModuleDatabase.shared
        var results: [ModuleSearchResult] = []

        // The database matches every term, in any sense, and hands back each
        // entry's definitions as plain text; what is left here is to rank
        // each entry and show where it matched.
        let parsedQuery = LampSearchQuery(query)
        func snippet(_ text: String) -> String {
            parsedQuery.markedSnippet(Self.snippetSource(text, for: parsedQuery), limit: 200)
        }
        let searchAll = filter.moduleIds == nil
        let searchBDB = searchAll || filter.moduleIds?.contains("bdb") == true

        // Use LRM (Left-to-Right Mark) to prevent RTL reordering of a Hebrew key.
        let lexicons: [(id: String, bundledId: String, name: String, keyMark: String)] = [
            ("strongs-greek", "strongs_greek", "Strong's Greek", ""),
            ("strongs-hebrew", "strongs_hebrew", "Strong's Hebrew", "\u{200E}"),
            ("dodson", "dodson_greek", "Dodson Greek", ""),
        ]
        for lexicon in lexicons where searchAll || filter.moduleIds?.contains(lexicon.id) == true {
            do {
                let hits: [BundledModuleDatabase.DictionaryHit]
                if let key = filter.strongsKey {
                    // Key-only search
                    hits = try bundledDb.getDictionaryEntry(moduleId: lexicon.bundledId, key: key).map { entry in
                        [BundledModuleDatabase.DictionaryHit(
                            key: entry.key,
                            lemma: entry.lemma,
                            transliteration: entry.transliteration,
                            text: DictionarySearchText.text(fromSensesJSON: entry.sensesJson)
                        )]
                    } ?? []
                } else {
                    hits = try bundledDb.searchDictionaryEntries(query: query, moduleId: lexicon.bundledId, limit: limit)
                }

                for hit in hits.prefix(limit) {
                    results.append(ModuleSearchResult(
                        id: "\(lexicon.id)-\(hit.key)",
                        moduleId: lexicon.id,
                        moduleName: lexicon.name,
                        moduleType: .dictionary,
                        title: "\(hit.lemma) \(lexicon.keyMark)(\(hit.key))",
                        snippet: snippet(hit.text),
                        verseId: nil,
                        rank: parsedQuery.textRank(in: [hit.key, hit.lemma, hit.text, hit.transliteration ?? ""]),
                        strongsKey: hit.key
                    ))
                }
            } catch {
                print("Error searching \(lexicon.name): \(error)")
            }
        }

        // BDB (Brown-Driver-Briggs) - supports both Strong's key lookup and direct BDB ID lookup
        if searchBDB {
            do {
                if let key = filter.strongsKey {
                    // Check if this is a direct BDB ID (e.g., "BDB58", "BDB871")
                    if key.uppercased().hasPrefix("BDB") {
                        // Direct BDB ID lookup
                        if let bdbEntry = try bundledDb.getDictionaryEntry(moduleId: "bdb", key: key.uppercased()) {
                            let lrm = "\u{200E}"
                            // Find Strong's number for this BDB entry via reverse lookup
                            let strongsIds = try bundledDb.getReverseLexiconMappings(targetKey: bdbEntry.key)
                            let strongsNum = strongsIds.first ?? ""
                            let displayKey = strongsNum.isEmpty ? key.uppercased() : strongsNum
                            let senseDef = bdbEntry.senses.first?.definitionText ?? bdbEntry.senses.first?.gloss ?? ""
                            results.append(ModuleSearchResult(
                                id: "bdb-\(bdbEntry.key)",
                                moduleId: "bdb",
                                moduleName: "Brown-Driver-Briggs",
                                moduleType: .dictionary,
                                title: "\(bdbEntry.lemma) \(lrm)(\(displayKey))",
                                snippet: String(senseDef.prefix(200)),
                                verseId: nil,
                                rank: 10.0,
                                strongsKey: strongsNum.isEmpty ? bdbEntry.key : strongsNum
                            ))
                        }
                    } else {
                        // Strong's key search: look up via lexicon mapping
                        let bdbIds = try bundledDb.getLexiconMappings(sourceKey: key)
                        var bdbEntries: [DictionaryEntry] = []
                        for bdbId in bdbIds {
                            if let entry = try bundledDb.getDictionaryEntry(moduleId: "bdb", key: bdbId) {
                                bdbEntries.append(entry)
                            }
                        }
                        if let firstEntry = bdbEntries.first {
                            let lrm = "\u{200E}"
                            let entryCount = bdbEntries.count
                            let title = entryCount > 1
                                ? "\(firstEntry.lemma) \(lrm)(\(key)) +\(entryCount - 1) more"
                                : "\(firstEntry.lemma) \(lrm)(\(key))"
                            let senseDef = firstEntry.senses.first?.definitionText ?? firstEntry.senses.first?.gloss ?? ""
                            results.append(ModuleSearchResult(
                                id: "bdb-\(key)",
                                moduleId: "bdb",
                                moduleName: "Brown-Driver-Briggs",
                                moduleType: .dictionary,
                                title: title,
                                snippet: String(senseDef.prefix(200)),
                                verseId: nil,
                                rank: 10.0,
                                strongsKey: key
                            ))
                        }
                    }
                } else {
                    // Text search
                    let bdbHits = try bundledDb.searchDictionaryEntries(query: query, moduleId: "bdb", limit: limit)
                    var seenBdbIds = Set<String>()
                    for hit in bdbHits where seenBdbIds.insert(hit.key).inserted {
                        // Find Strong's number for this BDB entry via reverse lookup
                        let strongsIds = try bundledDb.getReverseLexiconMappings(targetKey: hit.key)
                        let strongsNum = strongsIds.first ?? ""

                        results.append(ModuleSearchResult(
                            id: "bdb-\(hit.key)",
                            moduleId: "bdb",
                            moduleName: "Brown-Driver-Briggs",
                            moduleType: .dictionary,
                            title: hit.lemma,
                            snippet: snippet(hit.text),
                            verseId: nil,
                            rank: parsedQuery.textRank(in: [hit.lemma, hit.text]),
                            strongsKey: strongsNum.isEmpty ? hit.key : strongsNum
                        ))
                    }
                }
            } catch {
                print("Error searching BDB: \(error)")
            }
        }

        return results
    }

    /// `text` cut to a stretch around the first place a query word falls,
    /// for `markedSnippet` to cut again and mark. Its cost grows with the
    /// text, and a BDB entry runs to pages: marking whole ones took a fifth of
    /// a second a search. The stretch is wider than the snippet, so core
    /// still makes its own cut and ellipses.
    static func snippetSource(_ text: String, for query: LampSearchQuery, radius: Int = 400) -> String {
        guard text.utf16.count > radius * 2 else { return text }
        let first = query.plainText.split(whereSeparator: \.isWhitespace)
            .compactMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound }
            .min() ?? text.startIndex
        let start = text.index(first, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    /// The user's commentaries and the bundled ones, the Treasury and the
    /// cross-references, whose units and index are in the bundled database.
    private func searchCommentaries(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var hits = try database.read { db in
            try commentaryHits(in: db, ftsQuery: ftsQuery, filter: filter, limit: limit)
        }
        if BundledModuleDatabase.shared.available {
            hits += try BundledModuleDatabase.shared.read { db in
                try commentaryHits(in: db, ftsQuery: ftsQuery, filter: filter, limit: limit)
            }
        }
        // Titled once the reads are done: a book's name comes from the
        // bundled database, which can't be read again inside its own read.
        return hits.map { hit in
            let displayTitle: String
            if let title = hit.title, !title.isEmpty {
                displayTitle = title
            } else {
                let bookName = BookOsisCache.shared.displayName(for: hit.book)
                let verse = hit.sv % 1000
                switch hit.unitType {
                case "section":
                    displayTitle = "Section in \(bookName) \(hit.chapter)"
                case "pericope":
                    displayTitle = "Pericope \(bookName) \(hit.chapter):\(verse)"
                default:
                    displayTitle = "Commentary on \(bookName) \(hit.chapter):\(verse)"
                }
            }
            return ModuleSearchResult(
                id: hit.id,
                moduleId: hit.moduleId,
                moduleName: hit.moduleName,
                moduleType: .commentary,
                title: displayTitle,
                snippet: hit.snippet,
                verseId: hit.sv,
                rank: hit.rank
            )
        }
    }

    private struct CommentaryHit {
        let id: String
        let moduleId: String
        let moduleName: String
        let title: String?
        let unitType: String
        let sv: Int
        let book: Int
        let chapter: Int
        let snippet: String
        let rank: Double
    }

    private func commentaryHits(
        in db: Database,
        ftsQuery: String,
        filter: ModuleSearchFilter,
        limit: Int
    ) throws -> [CommentaryHit] {
        var conditions = ["commentary_units_fts MATCH ?"]
        var arguments: [DatabaseValueConvertible] = [ftsQuery]

        if let moduleIds = filter.moduleIds {
            let moduleIdArray = Array(moduleIds)
            let placeholders = moduleIdArray.map { _ in "?" }.joined(separator: ", ")
            conditions.append("c.module_id IN (\(placeholders))")
            for id in moduleIdArray {
                arguments.append(id)
            }
        }

        let whereClause = conditions.joined(separator: " AND ")
        let sql = """
            SELECT
                c.id, c.module_id, c.sv, c.ev, c.title, c.unit_type,
                c.book, c.chapter,
                m.name as module_name,
                bm25(commentary_units_fts) as rank,
                snippet(commentary_units_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
            FROM commentary_units_fts f
            JOIN commentary_units c ON f.rowid = c.rowid
            JOIN modules m ON c.module_id = m.id
            WHERE \(whereClause)
            ORDER BY rank
            LIMIT ?
        """
        arguments.append(limit)

        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            let sv: Int = row["sv"]
            return CommentaryHit(
                id: row["id"],
                moduleId: row["module_id"],
                moduleName: row["module_name"],
                title: row["title"],
                unitType: row["unit_type"],
                sv: sv,
                book: row["book"],
                chapter: row["chapter"] ?? (sv / 1000) % 1000,
                snippet: row["snippet"] ?? "",
                rank: -(row["rank"] as Double)
            )
        }
    }

    private func searchDevotionals(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            var conditions = ["devotional_entries_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let moduleIds = filter.moduleIds {
                let moduleIdArray = Array(moduleIds)
                let placeholders = moduleIdArray.map { _ in "?" }.joined(separator: ", ")
                conditions.append("d.module_id IN (\(placeholders))")
                for id in moduleIdArray {
                    arguments.append(id)
                }
            }

            let criteria = LampDevotionalSearchCriteria(
                date: filter.devotionalDate,
                monthDay: filter.monthDay,
                tags: filter.tags,
                categories: filter.categories.map { Set($0.map(\.rawValue)) }
            )
            let facets = criteria.sqlConditions(tableAlias: "d")
            conditions += facets.clauses
            arguments += facets.arguments

            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
                SELECT
                    d.id, d.module_id, d.title, d.subtitle, d.date, d.tags, d.category,
                    m.name as module_name,
                    bm25(devotional_entries_fts) as rank,
                    snippet(devotional_entries_fts, 2, '<mark>', '</mark>', '...', 32) as snippet
                FROM devotional_entries_fts f
                JOIN devotional_entries d ON f.id = d.id
                JOIN modules m ON d.module_id = m.id
                WHERE \(whereClause)
                ORDER BY rank
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let tagsStr: String? = row["tags"]
                let tagList = tagsStr?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let dateStr: String? = row["date"]

                // Format display title with subtitle if available
                let title: String = row["title"]
                let subtitle: String? = row["subtitle"]
                let displayTitle = subtitle != nil ? "\(title): \(subtitle!)" : title

                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .devotional,
                    title: displayTitle,
                    snippet: row["snippet"] ?? "",
                    verseId: nil,
                    rank: -(row["rank"] as Double),
                    monthDay: dateStr,  // Use date field for monthDay (backward compatible)
                    tags: tagList
                )
            }
        }
    }

    private func searchNotes(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            var conditions = ["note_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let moduleIds = filter.moduleIds {
                let moduleIdArray = Array(moduleIds)
                let placeholders = moduleIdArray.map { _ in "?" }.joined(separator: ", ")
                conditions.append("n.module_id IN (\(placeholders))")
                for id in moduleIdArray {
                    arguments.append(id)
                }
            }

            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
                SELECT
                    n.id, n.module_id, n.verse_id, n.title, n.content,
                    n.book, n.chapter, n.verse,
                    m.name as module_name,
                    bm25(note_fts) as rank,
                    snippet(note_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
                FROM note_fts f
                JOIN note_entries n ON f.rowid = n.rowid
                JOIN modules m ON n.module_id = m.id
                WHERE \(whereClause)
                ORDER BY rank
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let title: String? = row["title"]
                let book: Int = row["book"]
                let chapter: Int = row["chapter"]
                let verse: Int = row["verse"]

                let displayTitle: String
                if let t = title, !t.isEmpty {
                    displayTitle = t
                } else {
                    let bookName = BookOsisCache.shared.displayName(for: book)
                    // Verse 0 means chapter-level note, don't show ":0"
                    if verse == 0 {
                        displayTitle = "Note on \(bookName) \(chapter)"
                    } else {
                        displayTitle = "Note on \(bookName) \(chapter):\(verse)"
                    }
                }

                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .notes,
                    title: displayTitle,
                    snippet: row["snippet"] ?? "",
                    verseId: row["verse_id"],
                    rank: -(row["rank"] as Double)
                )
            }
        }
    }

    /// Takes the query as typed, not the prepared FTS one: the translation
    /// searchers build their own from the same core grammar. Unpicking a
    /// prepared query to hand it on was what made a two-word verse search
    /// behave as a phrase search while every other kind of result ANDed.
    private func searchTranslations(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        // Search both bundled and user translations via TranslationDatabase
        let translationDb = TranslationDatabase.shared

        // Determine which translations to search
        var translationIds: Set<String>? = filter.translationIds

        // If specific module IDs are set but not translation IDs, use those
        if translationIds == nil, let moduleIds = filter.moduleIds {
            translationIds = moduleIds
        }

        // Perform search
        let searchResults = try translationDb.searchAllTranslations(
            query: query,
            translationIds: translationIds,
            bookRange: filter.bookRange,
            limit: limit
        )

        // Convert to ModuleSearchResult
        return searchResults.map { result in
            // Get book name from GRDB (or use number if not found)
            let bookName = BookOsisCache.shared.displayName(for: result.book)

            let displayTitle = "\(bookName) \(result.chapter):\(result.verse)"

            return ModuleSearchResult(
                id: result.id,
                moduleId: result.translationId,
                moduleName: result.translationAbbrev,
                moduleType: .translation,
                title: displayTitle,
                snippet: result.snippet,
                verseId: result.ref,
                rank: result.rank
            )
        }
    }

    /// Search translations by Strong's number
    private func searchTranslationsByStrongs(filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        guard let strongsKey = filter.strongsKey else { return [] }

        let translationDb = TranslationDatabase.shared

        // Get all translations and filter to those with Strong's support
        let allTranslations = try translationDb.getAllTranslations()
        let strongsTranslations = allTranslations.filter { $0.features?.strongs == true }

        // If specific module IDs are set, filter to those
        let translationsToSearch: [TranslationModule]
        if let moduleIds = filter.moduleIds {
            translationsToSearch = strongsTranslations.filter { moduleIds.contains($0.id) }
        } else {
            translationsToSearch = strongsTranslations
        }

        guard !translationsToSearch.isEmpty else { return [] }

        var results: [ModuleSearchResult] = []
        let limitPerTranslation = max(5, limit / translationsToSearch.count)

        for translation in translationsToSearch {
            let searchResults = try translationDb.searchVersesByStrongs(
                translationId: translation.id,
                strongsNum: strongsKey,
                bookRange: filter.bookRange,
                limit: limitPerTranslation
            )

            for result in searchResults {
                let bookName = BookOsisCache.shared.displayName(for: result.book)
                let displayTitle = "\(bookName) \(result.chapter):\(result.verse)"

                results.append(ModuleSearchResult(
                    id: "\(result.translationId)-\(result.ref)",
                    moduleId: result.translationId,
                    moduleName: result.translationAbbrev,
                    moduleType: .translation,
                    title: displayTitle,
                    snippet: result.snippet,
                    verseId: result.ref,
                    rank: result.rank,
                    strongsKey: strongsKey
                ))
            }

            if results.count >= limit { break }
        }

        return Array(results.prefix(limit))
    }


    // MARK: - Plans and Quizzes

    /// Reading plans by their name, author and descriptions, the bundled ones
    /// and the user's, as the Mac searches them.
    private func searchPlans(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        let parsed = LampSearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        var plans: [String: Plan] = [:]
        for plan in (try? BundledModuleDatabase.shared.getAllPlans()) ?? [] { plans[plan.id] = plan }
        for plan in try database.getAllPlans() { plans[plan.id] = plan }
        return plans.values
            .filter { plan in
                (filter.moduleIds?.contains(plan.id) ?? true)
                    && parsed.matches(
                        [plan.name, plan.planDescription, plan.fullDescription, plan.author]
                            .compactMap { $0 }.joined(separator: " ")
                    )
            }
            .sorted { $0.name < $1.name }
            .prefix(limit)
            .map { plan in
                ModuleSearchResult(
                    id: "plan:\(plan.id)",
                    moduleId: plan.id,
                    moduleName: plan.author ?? "Reading Plan",
                    moduleType: .plan,
                    title: plan.name,
                    snippet: parsed.markedSnippet(
                        plan.fullDescription ?? plan.planDescription ?? plan.duration.map { "\($0) days" } ?? "",
                        limit: 200
                    ),
                    verseId: nil,
                    rank: parsed.textRank(in: [plan.name, plan.author ?? "", plan.planDescription ?? ""])
                )
            }
    }

    /// Quiz questions by their theme and the words of their question and
    /// answer, never the JSON's field names, as the Mac searches them; the
    /// user's and the bundled ones. A result's ID names the database it came
    /// from, since each numbers its questions from 1.
    private func searchQuizzes(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        let parsed = LampSearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        var results = try database.read { db in
            try quizHits(in: db, source: "user", parsed: parsed, filter: filter, limit: limit)
        }
        if BundledModuleDatabase.shared.available {
            results += try BundledModuleDatabase.shared.read { db in
                try quizHits(in: db, source: "bundled", parsed: parsed, filter: filter, limit: limit)
            }
        }
        return results
    }

    private func quizHits(
        in db: Database,
        source: String,
        parsed: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int
    ) throws -> [ModuleSearchResult] {
        guard try db.tableExists("quiz_questions"), try db.tableExists("quiz_modules") else { return [] }
        let like = parsed.sqlLikePredicate(columns: ["q.theme"], jsonColumns: ["q.question_json", "q.answer_json"])
        var conditions = [like.condition]
        var arguments = StatementArguments(like.arguments)
        if let moduleIds = filter.moduleIds {
            guard !moduleIds.isEmpty else { return [] }
            conditions.append("q.quiz_module_id IN (\(moduleIds.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(moduleIds.sorted())
        }
        arguments += [limit]
        // Unordered in SQL, so the scan stops at the limit: sorting first
        // would test every question's JSON. They are stored in reading order,
        // and the ones found are put in it.
        let rows = try Row.fetchAll(db, sql: """
            SELECT q.id, q.quiz_module_id, q.day, q.sv, q.age_group, q.question_index,
                   q.question_json, q.answer_json, m.name AS module_name
            FROM quiz_questions q
            JOIN quiz_modules m ON m.id = q.quiz_module_id
            WHERE \(conditions.joined(separator: " AND "))
            LIMIT ?
            """, arguments: arguments).sorted { lhs, rhs in
                let left: (Int, Int, String, Int) = (lhs["day"], lhs["sv"], lhs["age_group"], lhs["question_index"])
                let right: (Int, Int, String, Int) = (rhs["day"], rhs["sv"], rhs["age_group"], rhs["question_index"])
                return left < right
            }
        return rows.map { row in
            let questionJSON: String = row["question_json"]
            let answerJSON: String = row["answer_json"]
            let question = QuizTextParser.parse(questionJSON).text
            let answer = QuizTextParser.parse(answerJSON).text
            return ModuleSearchResult(
                id: "quiz:\(source):\(row["id"] as Int64)",
                moduleId: row["quiz_module_id"],
                moduleName: row["module_name"],
                moduleType: .quiz,
                title: question.isEmpty ? "Quiz Question" : question,
                snippet: parsed.markedSnippet(answer, limit: 200),
                verseId: row["sv"],
                rank: parsed.textRank(in: [question, answer])
            )
        }
    }

    // MARK: - FTS Query Preparation

    /// The one search grammar. Every searcher below is handed the result of
    /// this, except the translation searchers, which take the raw query and
    /// apply the same grammar themselves.
    private func prepareFTSQuery(_ query: String) -> String {
        LampSearchQuery(query).fts5Query
    }

    // MARK: - Highlight Search

    /// Search highlights - either by verse text or by color only
    private func searchHighlights(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var results: [ModuleSearchResult] = []

        // Get highlight sets to search
        let allSets = try database.getAllHighlightSets()
        var setsToSearch: [HighlightSet] = allSets

        // Filter by module IDs (highlight set IDs)
        if let moduleIds = filter.moduleIds {
            setsToSearch = setsToSearch.filter { moduleIds.contains($0.id) }
        }

        // Filter by translation IDs (for color search filtering by translation)
        if let translationIds = filter.translationIds {
            setsToSearch = setsToSearch.filter { translationIds.contains($0.translationId) }
        }

        guard !setsToSearch.isEmpty else { return [] }

        // The grammar every other search follows: words in any order, quoted
        // phrases, a word's start.
        let searchQuery = LampSearchQuery(query)
        let hasTextQuery = !searchQuery.isEmpty

        for set in setsToSearch {
            // Get all highlights for this set
            var highlights = try database.getAllHighlights(setId: set.id)

            // Filter by color if specified
            if let colorFilter = filter.highlightColors, !colorFilter.isEmpty {
                highlights = highlights.filter { entry in
                    LampHighlightSearch.matchesColor(entry.color, in: colorFilter)
                }
            }
            if let bookRange = filter.bookRange {
                highlights = highlights.filter { bookRange.contains($0.ref / 1_000_000) }
            }

            guard !highlights.isEmpty else { continue }

            // Get verse texts for highlighted verses from the translation
            let translationId = set.translationId
            let verseRefs = Array(Set(highlights.map { $0.ref }))

            // Fetch verses from translation
            let versesById = try getVerseTexts(translationId: translationId, refs: verseRefs)

            // Create results for each highlight
            for highlight in highlights {
                guard let verseText = versesById[highlight.ref] else { continue }

                if hasTextQuery {
                    guard searchQuery.matches(verseText) else { continue }
                }

                // Build result
                let bookId = highlight.ref / 1_000_000
                let chapter = (highlight.ref % 1_000_000) / 1000
                let verse = highlight.ref % 1000
                let bookName = BookOsisCache.shared.displayName(for: bookId)
                let title = "\(bookName) \(chapter):\(verse)"

                // Create snippet - show highlighted portion marked for styling
                let snippet = LampHighlightSearch.markedSnippet(
                    text: verseText, startOffset: highlight.sc, endOffset: highlight.ec
                )

                // By the highlighted words first, then the verse: the
                // snippet starts with its mark, so compared as a whole it
                // could never equal the query or start with it. A search by
                // colour alone puts the newest first, by the row's ID, which
                // grows as highlights are made.
                let rank: Double
                if hasTextQuery {
                    let characters = Array(verseText)
                    let lower = min(max(highlight.sc, 0), characters.count)
                    let upper = min(max(highlight.ec, lower), characters.count)
                    rank = searchQuery.textRank(in: [String(characters[lower..<upper]), verseText])
                } else {
                    rank = Double(highlight.id ?? 0)
                }

                var result = ModuleSearchResult(
                    id: "highlight-\(set.id)-\(highlight.id ?? 0)",
                    moduleId: set.id,
                    moduleName: set.name,
                    moduleType: .highlights,
                    title: title,
                    snippet: snippet,
                    verseId: highlight.ref,
                    rank: rank
                )
                result.highlightColor = LampHighlightSearch.normalizedColor(highlight.color)
                result.highlightStyle = highlight.highlightStyle
                result.translationId = translationId
                results.append(result)

                if results.count >= limit { break }
            }

            if results.count >= limit { break }
        }

        return results
    }

    /// Helper to get verse texts from a translation
    private func getVerseTexts(translationId: String, refs: [Int]) throws -> [Int: String] {
        guard !refs.isEmpty else { return [:] }

        var result: [Int: String] = [:]

        // Get verses using the translation database
        for ref in refs {
            if let verse = try? TranslationDatabase.shared.getVerse(translationId: translationId, ref: ref) {
                result[ref] = verse.text
            }
        }

        return result
    }
}
