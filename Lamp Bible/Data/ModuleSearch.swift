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
    var snippet: String
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
    /// Whether the result's text holds the query's words together, which
    /// core's merge ranks it by after its title.
    var holdsPhrase = false
    /// A result found without its snippet, which carries a stand-in to rank
    /// by: core's result, for `fillSnippets` to cut one for once the merge
    /// has kept it, and whether it came from the bundled database.
    var unsnipped: (hit: LampModuleSearchResult, bundled: Bool)? = nil

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
    var categories: Set<String>? = nil

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

        // Bundled dictionaries, as the bundle lists them - grouped by language
        for lexicon in BundledModuleDatabase.shared.lexicons() {
            modules.append(SearchableModule(
                id: lexicon.searchId, name: lexicon.shortName, type: .dictionary,
                isBundled: true, seriesAbbrev: lexicon.language.capitalized
            ))
        }

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

        // Words to find, even where an index can't ask for them by itself,
        // as `*faith`, whose FTS query is empty. A query without any allows a
        // dictionary key search or a highlight colour search.
        let parsedQuery = LampSearchQuery(query)
        let hasTextQuery = !parsedQuery.isEmpty && !parsedQuery.plainText.isEmpty
        let hasKeyFilter = filter.strongsKey != nil
        let hasColorFilter = filter.highlightColorOnly && filter.highlightColors != nil

        guard hasTextQuery || hasKeyFilter || hasColorFilter else { return [] }

        if filter.types.contains(.dictionary) {
            // User dictionaries (SQLite)
            if hasTextQuery {
                results.append(contentsOf: try searchDictionaries(query: parsedQuery, filter: filter, limit: limit))
            } else if hasKeyFilter {
                // Key-only search for user dictionaries
                results.append(contentsOf: try searchDictionariesByKey(filter: filter, limit: limit))
            }

            // Bundled dictionaries (Realm)
            if filter.includeBundledDictionaries {
                results.append(contentsOf: searchBundledDictionaries(query: query, filter: filter, limit: limit))
            }
        }

        // Commentaries, books, writings and notes are found without their
        // snippets, which are cut for the results the merge keeps: cutting
        // one for every result each database offered, most of them then
        // dropped, was most of a search's time.
        if filter.types.contains(.commentary) && hasTextQuery {
            results.append(contentsOf: try searchCommentaries(query: LampSearchQuery(query), filter: filter, limit: limit))
        }

        if filter.types.contains(.book) && hasTextQuery {
            results.append(contentsOf: try searchBooks(query: LampSearchQuery(query), filter: filter, limit: limit))
        }

        if filter.types.contains(.devotional) && hasTextQuery {
            results.append(contentsOf: try searchDevotionals(query: LampSearchQuery(query), filter: filter, limit: limit))
        }

        if filter.types.contains(.notes) && hasTextQuery {
            results.append(contentsOf: try searchNotes(query: LampSearchQuery(query), filter: filter, limit: limit))
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

        // A text search is merged as core merges the Mac's, by what names
        // and shows each result and whether it holds the words together, the
        // modules taking turns among equals: the kinds' own ranks are not on
        // one scale. A search by key or colour alone has no words to rank by.
        if hasTextQuery {
            return try fillSnippets(LampModuleSearch.ranked(
                results, by: parsedQuery, limit: limit,
                // A quiz result's title is its question, which shows it
                // rather than names it.
                named: { $0.moduleType == .quiz ? [] : [$0.title] },
                shown: { $0.moduleType == .quiz ? [$0.title, $0.snippet] : [$0.snippet] },
                holdingPhrase: { $0.holdsPhrase },
                from: { ($0.moduleType.rawValue, $0.moduleId) }
            ), query: parsedQuery)
        }
        results.sort { $0.rank > $1.rank }
        return Array(results.prefix(limit))
    }

    /// The results with the snippets they were found without, cut now that
    /// the merge has chosen them, each in the database it came from, as the
    /// Mac cuts its own.
    private func fillSnippets(_ results: [ModuleSearchResult], query: LampSearchQuery) throws -> [ModuleSearchResult] {
        var snippets: [String: String] = [:]
        for bundled in [false, true] {
            let hits = results.compactMap(\.unsnipped).filter { $0.bundled == bundled }.map(\.hit)
            guard !hits.isEmpty else { continue }
            let filled = bundled
                ? try BundledModuleDatabase.shared.read { try Self.snippets(for: hits, in: $0, query: query) }
                : try database.read { try Self.snippets(for: hits, in: $0, query: query) }
            for hit in filled { snippets[hit.id] = hit.snippet }
        }
        return results.map { result in
            guard let unsnipped = result.unsnipped else { return result }
            var result = result
            result.snippet = snippets[unsnipped.hit.id] ?? unsnipped.hit.snippet
            result.unsnipped = nil
            return result
        }
    }

    /// Core's results found without their snippets, with them, cut by each
    /// kind's own reader from one database.
    static func snippets(
        for hits: [LampModuleSearchResult],
        in db: Database,
        query: LampSearchQuery
    ) throws -> [LampModuleSearchResult] {
        try Dictionary(grouping: hits, by: \.kind).flatMap { kind, hits in
            switch kind {
            case .commentary: try LampModuleSearch.commentarySnippets(for: hits, in: db, query: query)
            case .book: try LampModuleSearch.bookSnippets(for: hits, in: db, query: query)
            case .notes: try LampModuleSearch.noteSnippets(for: hits, in: db, query: query)
            case .devotional: try LampModuleSearch.devotionalSnippets(for: hits, in: db, query: query)
            default: hits
            }
        }
    }


    // MARK: - Type-Specific Search

    /// The user's books and the bundled ones.
    private func searchBooks(query: LampSearchQuery, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var results = try database.read { db in
            try Self.bookResults(in: db, query: query, filter: filter, limit: limit, snippets: false)
        }

        if BundledModuleDatabase.shared.hasBookModulesTable() {
            results.append(contentsOf: try BundledModuleDatabase.shared.read { db in
                try Self.bookResults(in: db, query: query, filter: filter, limit: limit, snippets: false, bundled: true)
            })
        }

        return results
    }

    /// One database's books searched by core, as the Mac searches its own.
    static func bookResults(
        in db: Database,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int,
        snippets: Bool = true,
        bundled: Bool = false
    ) throws -> [ModuleSearchResult] {
        guard try db.tableExists("book_modules") else { return [] }
        let modules = try Row.fetchAll(db, sql: "SELECT id, title FROM book_modules ORDER BY title")
            .map { LampSearchedModule(id: $0["id"], name: $0["title"]) }
            .filter { filter.moduleIds?.contains($0.id) ?? true }
        return try LampModuleSearch.books(in: db, modules: modules, query: query, limit: limit, snippets: snippets).map { hit in
            ModuleSearchResult(
                // The section, as the book opens at it.
                id: String(hit.id.dropFirst("book:\(hit.moduleID):".count)),
                moduleId: hit.moduleID,
                moduleName: hit.moduleName,
                moduleType: .book,
                title: hit.subtitle.map { "\(hit.title): \($0)" } ?? hit.title,
                snippet: hit.snippet,
                verseId: hit.startReference,
                rank: 0,
                holdsPhrase: hit.holdsPhrase,
                unsnipped: snippets ? nil : (hit, bundled)
            )
        }
    }

    /// The user's dictionaries, searched as core searches the Mac's and the
    /// bundle's (`LampModuleSearch.dictionaryEntries`): the entry keyed or
    /// headed by what was typed first, each dictionary keeping its own best
    /// for the merge to cut.
    private func searchDictionaries(query: LampSearchQuery, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            try Self.dictionaryResults(in: db, query: query, filter: filter, limit: limit)
        }
    }

    static func dictionaryResults(
        in db: Database,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int
    ) throws -> [ModuleSearchResult] {
        var dictionaries = try Row.fetchAll(db, sql: "SELECT id, name FROM modules WHERE type = 'dictionary' ORDER BY name")
            .map { (id: $0["id"] as String, name: $0["name"] as String) }
        if let moduleIds = filter.moduleIds {
            // Only bundled dictionaries chosen: none of the user's.
            let chosen = Set(Self.userDictionaryIDs(in: moduleIds))
            dictionaries = dictionaries.filter { chosen.contains($0.id) }
        }
        guard !dictionaries.isEmpty else { return [] }
        let names = Dictionary(dictionaries.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let searchTerms = query.terms.map { $0.text.lowercased() }
        // The sense that holds a search term, else the first.
        func definition(_ sensesJSON: String?) -> String? {
            guard let sensesJSON, let data = sensesJSON.data(using: .utf8),
                  let senses = try? JSONDecoder().decode([DictionarySense].self, from: data) else { return nil }
            for sense in senses {
                let text = sense.definitionText ?? sense.shortDefinitionText ?? sense.gloss ?? ""
                if searchTerms.contains(where: { text.lowercased().contains($0) }) { return text }
            }
            return senses.first.flatMap { $0.definitionText ?? $0.shortDefinitionText ?? $0.gloss }
        }
        return try LampModuleSearch.dictionaryEntries(
            in: db, dictionaries: dictionaries.map(\.id), query: query, limit: limit
        ).map { hit in
            ModuleSearchResult(
                id: hit.entryID,
                moduleId: hit.moduleID,
                moduleName: names[hit.moduleID] ?? hit.moduleID,
                moduleType: .dictionary,
                title: "\(hit.lemma) (\(hit.key))",
                snippet: definition(hit.sensesJSON) ?? "",
                verseId: nil,
                rank: 0,
                strongsKey: hit.key,
                holdsPhrase: query.holdsPhrase(definition(hit.sensesJSON) ?? "")
            )
        }
    }

    /// The chosen modules that aren't a bundled dictionary, which the filter
    /// lists under their own IDs.
    private static func userDictionaryIDs(in moduleIds: Set<String>) -> [String] {
        let bundled = Set(BundledModuleDatabase.shared.lexicons().map(\.searchId))
        return moduleIds.filter { !bundled.contains($0) }.sorted()
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

        for lexicon in bundledDb.lexicons() where searchAll || filter.moduleIds?.contains(lexicon.searchId) == true {
            // Use LRM (Left-to-Right Mark) to prevent RTL reordering of a Hebrew key.
            let keyMark = lexicon.language == "hebrew" ? "\u{200E}" : ""
            do {
                if lexicon.isKeyedByStrongs {
                    let hits: [BundledModuleDatabase.DictionaryHit]
                    if let key = filter.strongsKey {
                        // Key-only search
                        hits = try bundledDb.getDictionaryEntry(moduleId: lexicon.moduleId, key: key).map { entry in
                            [BundledModuleDatabase.DictionaryHit(
                                key: entry.key,
                                lemma: entry.lemma,
                                transliteration: entry.transliteration,
                                text: DictionarySearchText.text(fromSensesJSON: entry.sensesJson)
                            )]
                        } ?? []
                    } else {
                        hits = try bundledDb.searchDictionaryEntries(query: query, moduleId: lexicon.moduleId, limit: limit)
                    }

                    for hit in hits.prefix(limit) {
                        results.append(ModuleSearchResult(
                            id: "\(lexicon.searchId)-\(hit.key)",
                            moduleId: lexicon.searchId,
                            moduleName: lexicon.shortName,
                            moduleType: .dictionary,
                            title: "\(hit.lemma) \(keyMark)(\(hit.key))",
                            snippet: snippet(hit.text),
                            verseId: nil,
                            rank: parsedQuery.textRank(in: [hit.key, hit.lemma, hit.text, hit.transliteration ?? ""]),
                            strongsKey: hit.key,
                            holdsPhrase: parsedQuery.holdsPhrase(hit.text)
                        ))
                    }
                } else if let key = filter.strongsKey {
                    // A lexicon keyed by its own numbers, as BDB, is found by
                    // one of them (BDB58), or by a Strong's number through the
                    // bundle's mappings.
                    if let entry = try bundledDb.getDictionaryEntry(moduleId: lexicon.moduleId, key: key.uppercased()) {
                        // Find Strong's number for this entry via reverse lookup
                        let strongsIds = try bundledDb.getReverseLexiconMappings(targetKey: entry.key)
                        let strongsNum = strongsIds.first ?? ""
                        let displayKey = strongsNum.isEmpty ? key.uppercased() : strongsNum
                        let senseDef = entry.senses.first?.definitionText ?? entry.senses.first?.gloss ?? ""
                        results.append(ModuleSearchResult(
                            id: "\(lexicon.searchId)-\(entry.key)",
                            moduleId: lexicon.searchId,
                            moduleName: lexicon.shortName,
                            moduleType: .dictionary,
                            title: "\(entry.lemma) \(keyMark)(\(displayKey))",
                            snippet: String(senseDef.prefix(200)),
                            verseId: nil,
                            rank: 10.0,
                            strongsKey: strongsNum.isEmpty ? entry.key : strongsNum
                        ))
                    } else {
                        var entries: [DictionaryEntry] = []
                        for mappedKey in try bundledDb.getLexiconMappings(sourceKey: key) {
                            if let entry = try bundledDb.getDictionaryEntry(moduleId: lexicon.moduleId, key: mappedKey) {
                                entries.append(entry)
                            }
                        }
                        if let firstEntry = entries.first {
                            let title = entries.count > 1
                                ? "\(firstEntry.lemma) \(keyMark)(\(key)) +\(entries.count - 1) more"
                                : "\(firstEntry.lemma) \(keyMark)(\(key))"
                            let senseDef = firstEntry.senses.first?.definitionText ?? firstEntry.senses.first?.gloss ?? ""
                            results.append(ModuleSearchResult(
                                id: "\(lexicon.searchId)-\(key)",
                                moduleId: lexicon.searchId,
                                moduleName: lexicon.shortName,
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
                    let hits = try bundledDb.searchDictionaryEntries(query: query, moduleId: lexicon.moduleId, limit: limit)
                    var seenKeys = Set<String>()
                    for hit in hits where seenKeys.insert(hit.key).inserted {
                        // Find Strong's number for this entry via reverse lookup
                        let strongsIds = try bundledDb.getReverseLexiconMappings(targetKey: hit.key)
                        let strongsNum = strongsIds.first ?? ""

                        results.append(ModuleSearchResult(
                            id: "\(lexicon.searchId)-\(hit.key)",
                            moduleId: lexicon.searchId,
                            moduleName: lexicon.shortName,
                            moduleType: .dictionary,
                            title: hit.lemma,
                            snippet: snippet(hit.text),
                            verseId: nil,
                            rank: parsedQuery.textRank(in: [hit.lemma, hit.text]),
                            strongsKey: strongsNum.isEmpty ? hit.key : strongsNum,
                            holdsPhrase: parsedQuery.holdsPhrase(hit.text)
                        ))
                    }
                }
            } catch {
                print("Error searching \(lexicon.shortName): \(error)")
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
    private func searchCommentaries(query: LampSearchQuery, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var results = try database.read { db in
            try Self.commentaryResults(in: db, query: query, filter: filter, limit: limit, snippets: false)
        }
        if BundledModuleDatabase.shared.available {
            results += try BundledModuleDatabase.shared.read { db in
                try Self.commentaryResults(in: db, query: query, filter: filter, limit: limit, snippets: false, bundled: true)
            }
        }
        return results
    }

    /// One database's commentaries searched by core, as the Mac searches its
    /// own: which units match, which come first and what their snippets show.
    static func commentaryResults(
        in db: Database,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int,
        snippets: Bool = true,
        bundled: Bool = false
    ) throws -> [ModuleSearchResult] {
        let modules = try Row.fetchAll(db, sql: "SELECT id, name FROM modules WHERE type = 'commentary' ORDER BY name")
            .map { LampSearchedModule(id: $0["id"], name: $0["name"]) }
            .filter { filter.moduleIds?.contains($0.id) ?? true }
        return try LampModuleSearch.commentary(in: db, modules: modules, query: query, limit: limit, snippets: snippets).map { hit in
            ModuleSearchResult(
                // The unit, as the commentary sheet opens it.
                id: String(hit.id.dropFirst("commentary:\(hit.moduleID):".count)),
                moduleId: hit.moduleID,
                moduleName: hit.moduleName,
                moduleType: .commentary,
                title: hit.title,
                snippet: hit.snippet,
                verseId: hit.startReference,
                rank: 0,
                holdsPhrase: hit.holdsPhrase,
                unsnipped: snippets ? nil : (hit, bundled)
            )
        }
    }

    private func searchDevotionals(query: LampSearchQuery, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            try Self.devotionalResults(in: db, query: query, filter: filter, limit: limit, snippets: false)
        }
    }

    /// The phone's writings searched by core, as the Mac searches its own,
    /// by the words and the date, tags and kind the filter asks for.
    static func devotionalResults(
        in db: Database,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int,
        snippets: Bool = true
    ) throws -> [ModuleSearchResult] {
        let modules = try Row.fetchAll(db, sql: "SELECT id, name FROM modules WHERE type = 'devotional' ORDER BY name")
            .map { LampSearchedModule(id: $0["id"], name: $0["name"]) }
            .filter { filter.moduleIds?.contains($0.id) ?? true }
        let criteria = LampDevotionalSearchCriteria(
            date: filter.devotionalDate,
            monthDay: filter.monthDay,
            tags: filter.tags,
            categories: filter.categories
        )
        let hits = try LampModuleSearch.devotionals(
            in: db, modules: modules, query: query, criteria: criteria, limit: limit, snippets: snippets
        )
        guard !hits.isEmpty else { return [] }
        // The subtitle, date and tags the list shows, which core's results
        // don't carry.
        let ids = hits.map { String($0.id.dropFirst("devotional:\($0.moduleID):".count)) }
        let details = Dictionary(
            try Row.fetchAll(db, sql: """
                SELECT id, subtitle, date, tags FROM devotional_entries
                WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments(ids)).map { ($0["id"] as String, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return zip(hits, ids).map { hit, id in
            let subtitle: String? = details[id]?["subtitle"]
            let tags: String? = details[id]?["tags"]
            return ModuleSearchResult(
                id: id,
                moduleId: hit.moduleID,
                moduleName: hit.moduleName,
                moduleType: .devotional,
                title: subtitle.map { "\(hit.title): \($0)" } ?? hit.title,
                snippet: hit.snippet,
                verseId: nil,
                rank: 0,
                monthDay: details[id]?["date"],
                tags: tags?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) },
                holdsPhrase: hit.holdsPhrase,
                unsnipped: snippets ? nil : (hit, false)
            )
        }
    }

    private func searchNotes(query: LampSearchQuery, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        try database.read { db in
            try Self.noteResults(in: db, query: query, filter: filter, limit: limit, snippets: false)
        }
    }

    /// The phone's notes searched by core, as the Mac searches its own.
    static func noteResults(
        in db: Database,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int,
        snippets: Bool = true
    ) throws -> [ModuleSearchResult] {
        let modules = try Row.fetchAll(db, sql: "SELECT id, name FROM modules WHERE type = 'notes' ORDER BY name")
            .map { LampSearchedModule(id: $0["id"], name: $0["name"]) }
            .filter { filter.moduleIds?.contains($0.id) ?? true }
        return try LampModuleSearch.notes(in: db, modules: modules, query: query, limit: limit, snippets: snippets).map { hit in
            ModuleSearchResult(
                // The note, as its sheet opens it.
                id: String(hit.id.dropFirst("notes:\(hit.moduleID):".count)),
                moduleId: hit.moduleID,
                moduleName: hit.moduleName,
                moduleType: .notes,
                title: hit.title,
                snippet: hit.snippet,
                verseId: hit.startReference,
                rank: 0,
                holdsPhrase: hit.holdsPhrase,
                unsnipped: snippets ? nil : (hit, false)
            )
        }
    }

    /// Takes the query as typed, not the prepared FTS one: the translation
    /// searchers build their own from the same core grammar. Unpicking a
    /// prepared query to hand it on was what made a two-word verse search
    /// behave as a phrase search while every other kind of result ANDed.
    private func searchTranslations(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        // Search both bundled and user translations via TranslationDatabase
        let translationDb = TranslationDatabase.shared
        let parsedQuery = LampSearchQuery(query)

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
                rank: result.rank,
                holdsPhrase: parsedQuery.holdsPhrase(
                    result.snippet.replacingOccurrences(of: "<mark>", with: "")
                        .replacingOccurrences(of: "</mark>", with: "")
                )
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
    /// and the user's, searched by core as the Mac searches its own.
    private func searchPlans(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        var plans: [String: Plan] = [:]
        for plan in (try? BundledModuleDatabase.shared.getAllPlans()) ?? [] { plans[plan.id] = plan }
        for plan in try database.getAllPlans() { plans[plan.id] = plan }
        let searched = plans.values
            .filter { filter.moduleIds?.contains($0.id) ?? true }
            .sorted { $0.name < $1.name }
        let authors = Dictionary(searched.map { ($0.id, $0.author) }, uniquingKeysWith: { first, _ in first })
        return LampModuleSearch.plans(
            searched.map { plan in
                LampSearchedPlan(
                    id: plan.id, name: plan.name, description: plan.planDescription,
                    fullDescription: plan.fullDescription, author: plan.author, duration: plan.duration
                )
            },
            query: LampSearchQuery(query), limit: limit
        ).map { hit in
            ModuleSearchResult(
                id: hit.id,
                moduleId: hit.moduleID,
                moduleName: (authors[hit.moduleID] ?? nil) ?? "Reading Plan",
                moduleType: .plan,
                title: hit.title,
                snippet: hit.snippet,
                verseId: nil,
                rank: 0,
                holdsPhrase: hit.holdsPhrase
            )
        }
    }

    /// Quiz questions, the user's and the bundled ones, searched by core as
    /// the Mac searches its own. A result's ID names the database it came
    /// from, since each numbers its questions from 1.
    private func searchQuizzes(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
        let parsed = LampSearchQuery(query)
        var results = try database.read { db in
            try Self.quizResults(in: db, source: "user", query: parsed, filter: filter, limit: limit)
        }
        if BundledModuleDatabase.shared.available {
            results += try BundledModuleDatabase.shared.read { db in
                try Self.quizResults(in: db, source: "bundled", query: parsed, filter: filter, limit: limit)
            }
        }
        return results
    }

    static func quizResults(
        in db: Database,
        source: String,
        query: LampSearchQuery,
        filter: ModuleSearchFilter,
        limit: Int
    ) throws -> [ModuleSearchResult] {
        guard try db.tableExists("quiz_modules") else { return [] }
        let modules = try Row.fetchAll(db, sql: "SELECT id, name FROM quiz_modules ORDER BY name")
            .map { LampSearchedModule(id: $0["id"], name: $0["name"]) }
            .filter { filter.moduleIds?.contains($0.id) ?? true }
        return try LampModuleSearch.quizzes(in: db, modules: modules, query: query, limit: limit).map { hit in
            ModuleSearchResult(
                // The question, in the database its sheet reads it from.
                id: "quiz:\(source):" + hit.id.dropFirst("quiz:\(hit.moduleID):".count),
                moduleId: hit.moduleID,
                moduleName: hit.moduleName,
                moduleType: .quiz,
                title: hit.title,
                snippet: hit.snippet,
                verseId: hit.startReference,
                rank: 0,
                holdsPhrase: hit.holdsPhrase
            )
        }
    }

    // MARK: - Highlight Search

    /// Search highlights - either by verse text or by color only
    private func searchHighlights(query: String, filter: ModuleSearchFilter, limit: Int) throws -> [ModuleSearchResult] {
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

        // Chosen and ordered by core, as the Mac's are: each set's newest
        // first, of the colours, books and words asked for, the sets taking
        // turns. A text search is ranked by the merge after; a search by
        // colour alone keeps this order.
        let searchQuery = LampSearchQuery(query)
        let hasTextQuery = !searchQuery.isEmpty && !searchQuery.plainText.isEmpty
        var entries: [String: [Int64: HighlightEntry]] = [:]
        var sets: [(id: String, highlights: [LampVerseHighlight])] = []
        for set in setsToSearch {
            let highlights = try database.getAllHighlights(setId: set.id)
            entries[set.id] = Dictionary(highlights.compactMap { entry in entry.id.map { ($0, entry) } },
                                         uniquingKeysWith: { first, _ in first })
            sets.append((set.id, highlights.compactMap { entry in
                entry.id.map { id in
                    LampVerseHighlight(
                        id: id, setID: set.id, translationID: set.translationId, reference: entry.ref,
                        startOffset: entry.sc, endOffset: entry.ec,
                        style: LampHighlightStyle(rawValue: entry.style) ?? .highlight, color: entry.color
                    )
                }
            }))
        }
        let names = Dictionary(setsToSearch.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let hits = try LampModuleSearch.highlights(
            in: sets, query: hasTextQuery ? searchQuery : nil, colors: filter.highlightColors,
            bookRange: filter.bookRange, limit: limit
        ) { translationId, references in
            try getVerseTexts(translationId: translationId, refs: Array(references))
        }
        return hits.enumerated().map { place, hit in
            let highlight = hit.highlight
            let bookName = BookOsisCache.shared.displayName(for: highlight.reference / 1_000_000)
            let chapter = (highlight.reference % 1_000_000) / 1000
            let verse = highlight.reference % 1000
            var result = ModuleSearchResult(
                id: "highlight-\(hit.setID)-\(highlight.id)",
                moduleId: hit.setID,
                moduleName: names[hit.setID] ?? hit.setID,
                moduleType: .highlights,
                title: "\(bookName) \(chapter):\(verse)",
                // The highlighted portion, marked for styling.
                snippet: LampHighlightSearch.markedSnippet(
                    text: hit.text, startOffset: highlight.startOffset, endOffset: highlight.endOffset
                ),
                verseId: highlight.reference,
                // Core's order, the best highest, as the results sort.
                rank: -Double(place)
            )
            result.highlightColor = LampHighlightSearch.normalizedColor(highlight.color)
            result.highlightStyle = entries[hit.setID]?[highlight.id]?.highlightStyle ?? .highlight
            result.translationId = highlight.translationID
            result.holdsPhrase = hit.holdsPhrase
            return result
        }
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
