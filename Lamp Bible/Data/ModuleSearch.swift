//
//  ModuleSearch.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import RealmSwift

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
    var monthDay: String? = nil  // Format: "01-15" for January 15
    var tags: Set<String>? = nil

    // Dictionary filters
    var strongsKey: String? = nil  // Filter by Strong's number

    static var `default`: ModuleSearchFilter { ModuleSearchFilter() }
}

// MARK: - Available Module Info

struct SearchableModule: Identifiable {
    let id: String
    let name: String
    let type: ModuleType
    let isBundled: Bool
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

        // Bundled dictionaries
        modules.append(SearchableModule(id: "strongs-greek", name: "Strong's Greek", type: .dictionary, isBundled: true))
        modules.append(SearchableModule(id: "strongs-hebrew", name: "Strong's Hebrew", type: .dictionary, isBundled: true))
        modules.append(SearchableModule(id: "dodson", name: "Dodson Greek", type: .dictionary, isBundled: true))
        modules.append(SearchableModule(id: "bdb", name: "Brown-Driver-Briggs", type: .dictionary, isBundled: true))

        // User modules from SQLite
        do {
            let userModules = try database.getAllModules()
            for module in userModules {
                modules.append(SearchableModule(id: module.id, name: module.name, type: module.type, isBundled: false))
            }
        } catch {
            print("Failed to get user modules: \(error)")
        }

        return modules
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

            var results = try Row.fetchAll(db, sql: ftsSql, arguments: StatementArguments(ftsArgs)).map { row -> ModuleSearchResult in
                var shortDef: String? = nil
                if let sensesJson: String = row["senses_json"],
                   let data = sensesJson.data(using: .utf8),
                   let senses = try? JSONDecoder().decode([DictionarySense].self, from: data),
                   let first = senses.first {
                    shortDef = first.shortDefinition ?? first.gloss
                }

                let key: String = row["key"]
                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .dictionary,
                    title: "\(row["lemma"] as String) (\(key))",
                    snippet: (row["snippet"] as String?) ?? shortDef ?? "",
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
                        shortDef = first.shortDefinition ?? first.gloss
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
                    shortDef = first.shortDefinition ?? first.gloss
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

    /// Search bundled dictionaries in Realm
    private func searchBundledDictionaries(query: String, filter: ModuleSearchFilter, limit: Int) -> [ModuleSearchResult] {
        let realm = RealmManager.shared.realm
        var results: [ModuleSearchResult] = []

        // Parse query for quoted (exact word match) and unquoted (substring match) terms
        let searchTerms = parseSearchQuery(query)
        let realmQuery = getRealmSearchString(from: query).lowercased()

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

        // Strong's Greek
        if searchStrongsGreek {
            var greekResults = realm.objects(StrongsGreek.self)
            if let key = filter.strongsKey {
                // Key-only search: exact match on id
                greekResults = greekResults.filter("id == %@", key)
            } else {
                // Text search: also include id field
                greekResults = greekResults.filter("id CONTAINS[c] %@ OR lemma CONTAINS[c] %@ OR def CONTAINS[c] %@ OR xlit CONTAINS[c] %@", realmQuery, realmQuery, realmQuery, realmQuery)
            }
            for entry in greekResults.prefix(limit) {
                // Post-filter for word-boundary matching of quoted terms
                let entryTexts = [entry.id, entry.lemma, entry.def ?? "", entry.xlit ?? ""]
                guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                let snippet = entry.def ?? ""
                results.append(ModuleSearchResult(
                    id: "strongs-greek-\(entry.id)",
                    moduleId: "strongs-greek",
                    moduleName: "Strong's Greek",
                    moduleType: .dictionary,
                    title: "\(entry.lemma) (\(entry.id))",
                    snippet: String(snippet.prefix(200)),
                    verseId: nil,
                    rank: calculateTextRank(query: realmQuery, in: entryTexts),
                    strongsKey: entry.id
                ))
            }
        }

        // Strong's Hebrew
        if searchStrongsHebrew {
            var hebrewResults = realm.objects(StrongsHebrew.self)
            if let key = filter.strongsKey {
                // Key-only search: exact match on id
                hebrewResults = hebrewResults.filter("id == %@", key)
            } else {
                // Text search: also include id field
                hebrewResults = hebrewResults.filter("id CONTAINS[c] %@ OR lemma CONTAINS[c] %@ OR def CONTAINS[c] %@ OR xlit CONTAINS[c] %@", realmQuery, realmQuery, realmQuery, realmQuery)
            }
            for entry in hebrewResults.prefix(limit) {
                // Post-filter for word-boundary matching of quoted terms
                let entryTexts = [entry.id, entry.lemma, entry.def ?? "", entry.xlit ?? ""]
                guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                let snippet = entry.def ?? ""
                // Use LRM (Left-to-Right Mark) to prevent RTL reordering of key
                let lrm = "\u{200E}"
                results.append(ModuleSearchResult(
                    id: "strongs-hebrew-\(entry.id)",
                    moduleId: "strongs-hebrew",
                    moduleName: "Strong's Hebrew",
                    moduleType: .dictionary,
                    title: "\(entry.lemma) \(lrm)(\(entry.id))",
                    snippet: String(snippet.prefix(200)),
                    verseId: nil,
                    rank: calculateTextRank(query: realmQuery, in: entryTexts),
                    strongsKey: entry.id
                ))
            }
        }

        // Dodson Greek
        if searchDodson {
            var dodsonResults = realm.objects(DodsonGreek.self)
            if let key = filter.strongsKey {
                // Key-only search: exact match on id
                dodsonResults = dodsonResults.filter("id == %@", key)
            } else {
                // Text search: also include id field
                dodsonResults = dodsonResults.filter("id CONTAINS[c] %@ OR lemma CONTAINS[c] %@ OR def CONTAINS[c] %@ OR short CONTAINS[c] %@", realmQuery, realmQuery, realmQuery, realmQuery)
            }
            for entry in dodsonResults.prefix(limit) {
                // Post-filter for word-boundary matching of quoted terms
                let entryTexts = [entry.id, entry.lemma, entry.def ?? "", entry.short ?? ""]
                guard filter.strongsKey != nil || entryMatchesTerms(entryTexts) else { continue }

                let snippet = entry.def ?? entry.short ?? ""
                results.append(ModuleSearchResult(
                    id: "dodson-\(entry.id)",
                    moduleId: "dodson",
                    moduleName: "Dodson Greek",
                    moduleType: .dictionary,
                    title: "\(entry.lemma) (\(entry.id))",
                    snippet: String(snippet.prefix(200)),
                    verseId: nil,
                    rank: calculateTextRank(query: realmQuery, in: entryTexts),
                    strongsKey: entry.id
                ))
            }
        }

        // BDB (Brown-Driver-Briggs) - supports both Strong's key lookup and direct BDB ID lookup
        if searchBDB {
            let searchedKey = filter.strongsKey  // Remember the key we searched for
            if let key = searchedKey {
                // Check if this is a direct BDB ID (e.g., "BDB58", "BDB871")
                if key.uppercased().hasPrefix("BDB") {
                    // Direct BDB ID lookup
                    if let bdbEntry = realm.object(ofType: BDBHebrew.self, forPrimaryKey: key.uppercased()) {
                        let lrm = "\u{200E}"
                        // Find Strong's number for this BDB entry via reverse lookup
                        var strongsNum = ""
                        let mappings = realm.objects(StrongsToBDB.self)
                        for mapping in mappings {
                            if mapping.bdbIds.contains(bdbEntry.id) {
                                strongsNum = mapping.id
                                break
                            }
                        }
                        let displayKey = strongsNum.isEmpty ? key.uppercased() : strongsNum
                        results.append(ModuleSearchResult(
                            id: "bdb-\(bdbEntry.id)",
                            moduleId: "bdb",
                            moduleName: "Brown-Driver-Briggs",
                            moduleType: .dictionary,
                            title: "\(bdbEntry.lemma) \(lrm)(\(displayKey))",
                            snippet: String((bdbEntry.def ?? bdbEntry.gloss ?? "").prefix(200)),
                            verseId: nil,
                            rank: 10.0,  // High rank for key match
                            strongsKey: strongsNum.isEmpty ? bdbEntry.id : strongsNum
                        ))
                    }
                } else {
                    // Strong's key search: look up via StrongsToBDB mapping table
                    if let mapping = realm.object(ofType: StrongsToBDB.self, forPrimaryKey: key) {
                        let bdbIds = Array(mapping.bdbIds)
                        let bdbEntries = bdbIds.compactMap { realm.object(ofType: BDBHebrew.self, forPrimaryKey: $0) }
                        if let firstEntry = bdbEntries.first {
                            let lrm = "\u{200E}"
                            let entryCount = bdbEntries.count
                            let title = entryCount > 1
                                ? "\(firstEntry.lemma) \(lrm)(\(key)) +\(entryCount - 1) more"
                                : "\(firstEntry.lemma) \(lrm)(\(key))"
                            results.append(ModuleSearchResult(
                                id: "bdb-\(key)",
                                moduleId: "bdb",
                                moduleName: "Brown-Driver-Briggs",
                                moduleType: .dictionary,
                                title: title,
                                snippet: String((firstEntry.def ?? firstEntry.gloss ?? "").prefix(200)),
                                verseId: nil,
                                rank: 10.0,  // High rank for key match
                                strongsKey: key
                            ))
                        }
                    }
                }
            } else {
                // Text search: search lemma, def, and gloss fields
                let bdbResults = realm.objects(BDBHebrew.self)
                    .filter("lemma CONTAINS[c] %@ OR def CONTAINS[c] %@ OR gloss CONTAINS[c] %@", realmQuery, realmQuery, realmQuery)
                var seenBdbIds = Set<String>()
                for entry in bdbResults.prefix(limit) {
                    guard !seenBdbIds.contains(entry.id) else { continue }
                    seenBdbIds.insert(entry.id)

                    // Post-filter for word-boundary matching of quoted terms
                    let entryTexts = [entry.lemma, entry.def ?? "", entry.gloss ?? ""]
                    guard entryMatchesTerms(entryTexts) else { continue }

                    let snippet = entry.def ?? entry.gloss ?? ""
                    // Find Strong's number for this BDB entry via reverse lookup
                    var strongsNum = ""
                    let mappings = realm.objects(StrongsToBDB.self)
                    for mapping in mappings {
                        if mapping.bdbIds.contains(entry.id) {
                            strongsNum = mapping.id
                            break
                        }
                    }
                    results.append(ModuleSearchResult(
                        id: "bdb-\(entry.id)",
                        moduleId: "bdb",
                        moduleName: "Brown-Driver-Briggs",
                        moduleType: .dictionary,
                        title: entry.lemma,
                        snippet: String(snippet.prefix(200)),
                        verseId: nil,
                        rank: calculateTextRank(query: realmQuery, in: entryTexts),
                        strongsKey: strongsNum.isEmpty ? entry.id : strongsNum  // Use Strong's if found, otherwise BDB ID
                    ))
                }
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
                    switch unitType {
                    case "section":
                        displayTitle = "Section in \(book):\(chapter)"
                    case "pericope":
                        displayTitle = "Pericope \(book):\(chapter):\(verse)"
                    default:
                        displayTitle = "Commentary on \(book):\(chapter):\(verse)"
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
            var conditions = ["devotional_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let moduleIds = filter.moduleIds {
                let moduleIdArray = Array(moduleIds)
                let placeholders = moduleIdArray.map { _ in "?" }.joined(separator: ", ")
                conditions.append("d.module_id IN (\(placeholders))")
                for id in moduleIdArray {
                    arguments.append(id)
                }
            }

            // Date filter
            if let monthDay = filter.monthDay {
                conditions.append("d.month_day = ?")
                arguments.append(monthDay)
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

            let whereClause = conditions.joined(separator: " AND ")
            let sql = """
                SELECT
                    d.id, d.module_id, d.title, d.month_day, d.tags, d.content,
                    m.name as module_name,
                    bm25(devotional_fts) as rank,
                    snippet(devotional_fts, 1, '<mark>', '</mark>', '...', 32) as snippet
                FROM devotional_fts f
                JOIN devotional_entries d ON f.rowid = d.rowid
                JOIN modules m ON d.module_id = m.id
                WHERE \(whereClause)
                ORDER BY rank
                LIMIT ?
            """
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
                let tagsStr: String? = row["tags"]
                let tagList = tagsStr?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .devotional,
                    title: row["title"],
                    snippet: row["snippet"] ?? "",
                    verseId: nil,
                    rank: -(row["rank"] as Double),
                    monthDay: row["month_day"],
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

                return ModuleSearchResult(
                    id: row["id"],
                    moduleId: row["module_id"],
                    moduleName: row["module_name"],
                    moduleType: .notes,
                    title: title ?? "Note on \(book):\(chapter):\(verse)",
                    snippet: row["snippet"] ?? "",
                    verseId: row["verse_id"],
                    rank: -(row["rank"] as Double)
                )
            }
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
