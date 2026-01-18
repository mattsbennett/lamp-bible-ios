//
//  ModuleSearch.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB

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

        // User modules from SQLite
        do {
            let userModules = try database.getAllModules()

            // Get series info for commentary modules
            let commentarySeriesInfo = getCommentarySeriesInfo()

            for module in userModules {
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

    // MARK: - Unified Search

    /// Search across all module types with filters
    func search(query: String, filter: ModuleSearchFilter = .default, limit: Int = 50) throws -> [ModuleSearchResult] {
        var results: [ModuleSearchResult] = []

        // Escape FTS5 special characters and prepare query
        let ftsQuery = prepareFTSQuery(query)

        // Allow empty query for dictionary key search
        let hasTextQuery = !ftsQuery.isEmpty
        let hasKeyFilter = filter.strongsKey != nil

        guard hasTextQuery || hasKeyFilter else { return [] }

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

        if filter.types.contains(.devotional) && hasTextQuery {
            results.append(contentsOf: try searchDevotionals(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.notes) && hasTextQuery {
            results.append(contentsOf: try searchNotes(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        if filter.types.contains(.translation) && hasTextQuery {
            results.append(contentsOf: try searchTranslations(ftsQuery: ftsQuery, filter: filter, limit: limit))
        }

        // Sort by rank (higher is better match)
        results.sort { $0.rank > $1.rank }

        // Apply overall limit
        return Array(results.prefix(limit))
    }

    /// Legacy method for compatibility
    func search(query: String, types: Set<ModuleType>? = nil, limit: Int = 50) throws -> [ModuleSearchResult] {
        var filter = ModuleSearchFilter.default
        if let types = types {
            filter.types = types
        }
        return try search(query: query, filter: filter, limit: limit)
    }

    // MARK: - Type-Specific Search

    private func searchDictionaries(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            // Build module filter clause
            var moduleCondition = ""
            var moduleArgs: [DatabaseValueConvertible] = []
            if let moduleIds = filter.moduleIds {
                let userModuleIds = Array(moduleIds.filter { !$0.hasPrefix("strongs-") && $0 != "dodson" && $0 != "bdb" })
                if !userModuleIds.isEmpty {
                    let placeholders = userModuleIds.map { _ in "?" }.joined(separator: ", ")
                    moduleCondition = "AND d.module_id IN (\(placeholders))"
                    moduleArgs = userModuleIds.map { $0 as DatabaseValueConvertible }
                }
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

    /// Search user dictionaries by key only (no FTS)
    private func searchDictionariesByKey(filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        guard let key = filter.strongsKey else { return [] }

        return try database.read { db in
            var conditions = ["d.key = ?"]
            var arguments: [DatabaseValueConvertible] = [key]

            // Module filter
            if let moduleIds = filter.moduleIds {
                let userModuleIds = Array(moduleIds.filter { !$0.hasPrefix("strongs-") && $0 != "dodson" && $0 != "bdb" })
                if !userModuleIds.isEmpty {
                    let placeholders = userModuleIds.map { _ in "?" }.joined(separator: ", ")
                    conditions.append("d.module_id IN (\(placeholders))")
                    for id in userModuleIds {
                        arguments.append(id)
                    }
                }
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

        // Parse query for quoted (exact word match) and unquoted (substring match) terms
        let searchTerms = parseSearchQuery(query)
        let searchQuery = getRealmSearchString(from: query).lowercased()

        // Check which bundled dictionaries to search
        let searchAll = filter.moduleIds == nil
        let searchStrongsGreek = searchAll || filter.moduleIds?.contains("strongs-greek") == true
        let searchStrongsHebrew = searchAll || filter.moduleIds?.contains("strongs-hebrew") == true
        let searchDodson = searchAll || filter.moduleIds?.contains("dodson") == true
        let searchBDB = searchAll || filter.moduleIds?.contains("bdb") == true

        // Helper to check if entry matches all terms (for word-boundary matching of quoted terms)
        func entryMatchesTerms(_ texts: [String]) -> Bool {
            let combinedText = texts.joined(separator: " ")
            return textMatchesAllTerms(combinedText, terms: searchTerms)
        }

        // Strong's Greek (module ID: strongs_greek)
        if searchStrongsGreek {
            do {
                let entries: [DictionaryEntry]
                if let key = filter.strongsKey {
                    // Key-only search
                    if let entry = try bundledDb.getDictionaryEntry(moduleId: "strongs_greek", key: key) {
                        entries = [entry]
                    } else {
                        entries = []
                    }
                } else {
                    // Text search
                    entries = try bundledDb.searchDictionaryEntries(query: searchQuery, moduleId: "strongs_greek", keyType: nil, limit: limit)
                }

                for entry in entries.prefix(limit) {
                    // Get definition from first sense
                    let senseDef = entry.senses.first?.definitionText ?? entry.senses.first?.shortDefinitionText ?? entry.senses.first?.gloss ?? ""
                    let entryTexts = [entry.key, entry.lemma, senseDef, entry.transliteration ?? ""]
                    guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                    let snippet = extractSnippetAroundMatch(senseDef, searchTerms: searchTerms, maxLength: 200)
                    results.append(ModuleSearchResult(
                        id: "strongs-greek-\(entry.key)",
                        moduleId: "strongs-greek",
                        moduleName: "Strong's Greek",
                        moduleType: .dictionary,
                        title: "\(entry.lemma) (\(entry.key))",
                        snippet: snippet,
                        verseId: nil,
                        rank: calculateTextRank(query: searchQuery, in: entryTexts),
                        strongsKey: entry.key
                    ))
                }
            } catch {
                print("Error searching Strong's Greek: \(error)")
            }
        }

        // Strong's Hebrew (module ID: strongs_hebrew)
        if searchStrongsHebrew {
            do {
                let entries: [DictionaryEntry]
                if let key = filter.strongsKey {
                    if let entry = try bundledDb.getDictionaryEntry(moduleId: "strongs_hebrew", key: key) {
                        entries = [entry]
                    } else {
                        entries = []
                    }
                } else {
                    entries = try bundledDb.searchDictionaryEntries(query: searchQuery, moduleId: "strongs_hebrew", keyType: nil, limit: limit)
                }

                for entry in entries.prefix(limit) {
                    let senseDef = entry.senses.first?.definitionText ?? entry.senses.first?.shortDefinitionText ?? entry.senses.first?.gloss ?? ""
                    let entryTexts = [entry.key, entry.lemma, senseDef, entry.transliteration ?? ""]
                    guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                    let snippet = extractSnippetAroundMatch(senseDef, searchTerms: searchTerms, maxLength: 200)
                    // Use LRM (Left-to-Right Mark) to prevent RTL reordering of key
                    let lrm = "\u{200E}"
                    results.append(ModuleSearchResult(
                        id: "strongs-hebrew-\(entry.key)",
                        moduleId: "strongs-hebrew",
                        moduleName: "Strong's Hebrew",
                        moduleType: .dictionary,
                        title: "\(entry.lemma) \(lrm)(\(entry.key))",
                        snippet: snippet,
                        verseId: nil,
                        rank: calculateTextRank(query: searchQuery, in: entryTexts),
                        strongsKey: entry.key
                    ))
                }
            } catch {
                print("Error searching Strong's Hebrew: \(error)")
            }
        }

        // Dodson Greek (module ID: dodson)
        if searchDodson {
            do {
                let entries: [DictionaryEntry]
                if let key = filter.strongsKey {
                    if let entry = try bundledDb.getDictionaryEntry(moduleId: "dodson", key: key) {
                        entries = [entry]
                    } else {
                        entries = []
                    }
                } else {
                    entries = try bundledDb.searchDictionaryEntries(query: searchQuery, moduleId: "dodson", keyType: nil, limit: limit)
                }

                for entry in entries.prefix(limit) {
                    let senseDef = entry.senses.first?.definitionText ?? entry.senses.first?.shortDefinitionText ?? entry.senses.first?.gloss ?? ""
                    let entryTexts = [entry.key, entry.lemma, senseDef]
                    guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                    let snippet = extractSnippetAroundMatch(senseDef, searchTerms: searchTerms, maxLength: 200)
                    results.append(ModuleSearchResult(
                        id: "dodson-\(entry.key)",
                        moduleId: "dodson",
                        moduleName: "Dodson Greek",
                        moduleType: .dictionary,
                        title: "\(entry.lemma) (\(entry.key))",
                        snippet: snippet,
                        verseId: nil,
                        rank: calculateTextRank(query: searchQuery, in: entryTexts),
                        strongsKey: entry.key
                    ))
                }
            } catch {
                print("Error searching Dodson: \(error)")
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
                    let bdbEntries = try bundledDb.searchDictionaryEntries(query: searchQuery, moduleId: "bdb", keyType: nil, limit: limit)
                    var seenBdbIds = Set<String>()
                    for entry in bdbEntries {
                        guard !seenBdbIds.contains(entry.key) else { continue }
                        seenBdbIds.insert(entry.key)

                        let senseDef = entry.senses.first?.definitionText ?? entry.senses.first?.gloss ?? ""
                        let entryTexts = [entry.lemma, senseDef]
                        guard entryMatchesTerms(entryTexts) else { continue }

                        let snippet = extractSnippetAroundMatch(senseDef, searchTerms: searchTerms, maxLength: 200)

                        // Find Strong's number for this BDB entry via reverse lookup
                        let strongsIds = try bundledDb.getReverseLexiconMappings(targetKey: entry.key)
                        let strongsNum = strongsIds.first ?? ""

                        results.append(ModuleSearchResult(
                            id: "bdb-\(entry.key)",
                            moduleId: "bdb",
                            moduleName: "Brown-Driver-Briggs",
                            moduleType: .dictionary,
                            title: entry.lemma,
                            snippet: snippet,
                            verseId: nil,
                            rank: calculateTextRank(query: searchQuery, in: entryTexts),
                            strongsKey: strongsNum.isEmpty ? entry.key : strongsNum
                        ))
                    }
                }
            } catch {
                print("Error searching BDB: \(error)")
            }
        }

        return results
    }

    /// Simple text rank calculation for Realm results
    private func calculateTextRank(query: String, in texts: [String]) -> Double {
        var score = 0.0
        for text in texts {
            let lower = text.lowercased()
            if lower == query {
                score += 10.0  // Exact match
            } else if lower.hasPrefix(query) {
                score += 5.0  // Prefix match
            } else if lower.contains(query) {
                score += 1.0  // Contains match
            }
        }
        return score
    }

    /// Extract a snippet centered around the first search term match
    private func extractSnippetAroundMatch(_ text: String, searchTerms: [SearchTerm], maxLength: Int) -> String {
        guard !text.isEmpty else { return "" }

        let lowerText = text.lowercased()

        // Find the first matching term's position
        var matchPosition: String.Index? = nil
        for term in searchTerms {
            if let range = lowerText.range(of: term.text.lowercased()) {
                matchPosition = range.lowerBound
                break
            }
        }

        guard let matchPos = matchPosition else {
            // No match found, return start of text
            return String(text.prefix(maxLength))
        }

        let matchOffset = text.distance(from: text.startIndex, to: matchPos)

        // If match is within first maxLength chars, just return prefix
        if matchOffset < maxLength / 2 {
            return String(text.prefix(maxLength))
        }

        // Center the snippet around the match
        let halfWindow = maxLength / 2
        let startOffset = max(0, matchOffset - halfWindow)
        let endOffset = min(text.count, startOffset + maxLength)

        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)

        var snippet = String(text[startIndex..<endIndex])

        // Add ellipsis if truncated
        if startOffset > 0 {
            snippet = "…" + snippet
        }
        if endOffset < text.count {
            snippet = snippet + "…"
        }

        return snippet
    }

    private func searchCommentaries(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
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
                let title: String? = row["title"]
                let unitType: String = row["unit_type"]
                let sv: Int = row["sv"]
                let book: Int = row["book"]
                let chapter: Int = row["chapter"]
                let verse = sv % 1000

                // Format display title based on unit type
                let displayTitle: String
                if let t = title, !t.isEmpty {
                    displayTitle = t
                } else {
                    let bookName = (try? BundledModuleDatabase.shared.getBook(id: book))?.name ?? "Book \(book)"
                    switch unitType {
                    case "section":
                        displayTitle = "Section in \(bookName) \(chapter)"
                    case "pericope":
                        displayTitle = "Pericope \(bookName) \(chapter):\(verse)"
                    default:
                        displayTitle = "Commentary on \(bookName) \(chapter):\(verse)"
                    }
                }

                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .commentary,
                    title: displayTitle,
                    snippet: row["snippet"] ?? "",
                    verseId: sv,
                    rank: -(row["rank"] as Double)
                )
            }
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

            // Date filter (new ISO format)
            if let date = filter.devotionalDate {
                conditions.append("d.date = ?")
                arguments.append(date)
            }

            // Legacy date filter (month_day format, check against date column)
            if let monthDay = filter.monthDay {
                // Match MM-DD portion of YYYY-MM-DD
                conditions.append("d.date LIKE ?")
                arguments.append("%-\(monthDay)")
            }

            // Tags filter
            if let tags = filter.tags, !tags.isEmpty {
                // Match any of the tags
                let tagConditions = tags.map { _ in "d.tags LIKE ?" }
                conditions.append("(\(tagConditions.joined(separator: " OR ")))")
                for tag in tags {
                    arguments.append("%\(tag)%")
                }
            }

            // Category filter
            if let categories = filter.categories, !categories.isEmpty {
                let categoryStrings = categories.map { $0.rawValue }
                let placeholders = categoryStrings.map { _ in "?" }.joined(separator: ", ")
                conditions.append("d.category IN (\(placeholders))")
                for cat in categoryStrings {
                    arguments.append(cat)
                }
            }

            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
                SELECT
                    d.id, d.module_id, d.title, d.subtitle, d.date, d.tags, d.category,
                    m.name as module_name,
                    bm25(devotional_entries_fts) as rank,
                    snippet(devotional_entries_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
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
                    let bookName = (try? BundledModuleDatabase.shared.getBook(id: book))?.name ?? "Book \(book)"
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

    private func searchTranslations(ftsQuery: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
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
            query: ftsQuery.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: ""),
            translationIds: translationIds,
            bookRange: filter.bookRange,
            limit: limit
        )

        // Convert to ModuleSearchResult
        return searchResults.map { result in
            // Get book name from GRDB (or use number if not found)
            let bookName = (try? BundledModuleDatabase.shared.getBook(id: result.book))?.name ?? "Book \(result.book)"

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

    // MARK: - Dictionary-Specific Search

    /// Search dictionaries by key (Strong's number)
    func searchDictionaryByKey(_ key: String, moduleId: String? = nil) throws -> [DictionaryEntry] {
        try database.read { db in
            var query = DictionaryEntry.filter(Column("key") == key)
            if let moduleId = moduleId {
                query = query.filter(Column("module_id") == moduleId)
            }
            return try query.fetchAll(db)
        }
    }

    /// Search dictionaries by lemma
    func searchDictionaryByLemma(_ lemma: String, moduleId: String? = nil) throws -> [DictionaryEntry] {
        try database.read { db in
            var query = DictionaryEntry.filter(Column("lemma").like("%\(lemma)%"))
            if let moduleId = moduleId {
                query = query.filter(Column("module_id") == moduleId)
            }
            return try query.fetchAll(db)
        }
    }

    // MARK: - FTS Query Preparation

    private func prepareFTSQuery(_ query: String) -> String {
        // Trim and check for empty
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Parse the query to identify quoted phrases and unquoted terms
        let searchTerms = parseSearchQuery(trimmed)

        // Build FTS5 query
        var ftsTerms: [String] = []
        for term in searchTerms {
            // Escape FTS5 special characters: * - ^ : ( )
            var escaped = term.text
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "^", with: "")
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !escaped.isEmpty else { continue }

            // Escape any quote characters that might be in the term
            escaped = escaped
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\u{201C}", with: "")  // " left double
                .replacingOccurrences(of: "\u{201D}", with: "")  // " right double
                .replacingOccurrences(of: "\u{2018}", with: "")  // ' left single
                .replacingOccurrences(of: "\u{2019}", with: "")  // ' right single

            if term.isExact {
                // Quoted phrase - use FTS5 phrase matching (no prefix wildcard)
                // This ensures exact word matching in FTS5
                ftsTerms.append("\"\(escaped)\"")
            } else {
                // Unquoted term - add prefix wildcard for partial matching
                ftsTerms.append("\"\(escaped)\"*")
            }
        }

        return ftsTerms.joined(separator: " ")
    }
}
