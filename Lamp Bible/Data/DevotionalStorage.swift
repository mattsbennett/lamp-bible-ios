//
//  DevotionalStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import GRDB

// MARK: - Devotional Storage

/// High-level storage operations for devotionals
class DevotionalStorage {
    static let shared = DevotionalStorage()

    private let db = ModuleDatabase.shared

    private init() {}

    // MARK: - CRUD Operations

    /// Get a single devotional by ID
    func getDevotional(id: String) throws -> Devotional? {
        guard let entry = try db.getDevotionalEntry(id: id) else {
            return nil
        }
        return entry.toDevotional()
    }

    /// Get all devotionals for a module
    func getAllDevotionals(moduleId: String) throws -> [Devotional] {
        try db.read { db in
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .order(Column("date").desc, Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get all devotional entries for a module (raw database records)
    func getAllDevotionalEntries(moduleId: String) throws -> [DevotionalEntry] {
        try db.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .fetchAll(db)
        }
    }

    /// Save a devotional (insert or update)
    func saveDevotional(_ devotional: Devotional, moduleId: String) throws {
        var mutableDevotional = devotional
        mutableDevotional.meta.lastModified = Int(Date().timeIntervalSince1970)
        let entry = DevotionalEntry(from: mutableDevotional, moduleId: moduleId)
        try db.saveDevotionalEntry(entry)
    }

    /// Delete a devotional by ID
    func deleteDevotional(id: String) throws {
        try db.deleteDevotionalEntry(id: id)
    }

    /// Delete all devotionals for a module
    func deleteAllDevotionals(moduleId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM devotional_entries WHERE module_id = ?", arguments: [moduleId])
        }
    }

    // MARK: - Filtered Queries

    /// Get devotionals filtered and sorted
    func getDevotionals(
        moduleId: String,
        filter: DevotionalFilterOptions = DevotionalFilterOptions(),
        sort: DevotionalSortOption = .dateNewest
    ) throws -> [Devotional] {
        try db.read { db in
            var query = DevotionalEntry.filter(Column("module_id") == moduleId)

            // Apply date range filter
            if let dateRange = filter.dateRange {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withFullDate]
                formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting
                let startStr = formatter.string(from: dateRange.lowerBound)
                let endStr = formatter.string(from: dateRange.upperBound)
                query = query.filter(Column("date") >= startStr && Column("date") <= endStr)
            }

            // Apply category filter
            if !filter.categories.isEmpty {
                let categoryStrings = filter.categories.map { $0.rawValue }
                query = query.filter(categoryStrings.contains(Column("category")))
            }

            // Apply sorting
            // Note: GRDB doesn't have nullsLast/nullsFirst, so we use COALESCE or CASE in SQL
            switch sort {
            case .dateNewest:
                // Sort by date descending, nulls last (empty string sorts after dates)
                query = query.order(SQL("COALESCE(date, '') DESC"), Column("title"))
            case .dateOldest:
                // Sort by date ascending, nulls first (empty string sorts before dates when using special handling)
                query = query.order(SQL("CASE WHEN date IS NULL OR date = '' THEN 0 ELSE 1 END"), Column("date"), Column("title"))
            case .titleAZ:
                query = query.order(Column("title").collating(.localizedCaseInsensitiveCompare))
            case .titleZA:
                query = query.order(Column("title").collating(.localizedCaseInsensitiveCompare).desc)
            case .lastModified:
                query = query.order(Column("last_modified").desc)
            }

            var entries = try query.fetchAll(db)

            // Apply tag filter (done in-memory since tags are comma-separated)
            if !filter.tags.isEmpty {
                entries = entries.filter { entry in
                    let entryTags = Set(entry.tagsArray)
                    return !filter.tags.isDisjoint(with: entryTags)
                }
            }

            // Apply search filter (done in-memory for simple local filtering)
            if !filter.searchQuery.isEmpty {
                let searchLower = filter.searchQuery.lowercased()
                entries = entries.filter { entry in
                    entry.title.lowercased().contains(searchLower) ||
                    entry.subtitle?.lowercased().contains(searchLower) == true ||
                    entry.searchText?.lowercased().contains(searchLower) == true
                }
            }

            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get devotionals by date (exact match)
    func getDevotionalsByDate(moduleId: String, date: String) throws -> [Devotional] {
        try db.read { db in
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("date") == date)
                .order(Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get devotionals by date range
    func getDevotionalsByDateRange(moduleId: String, startDate: String, endDate: String) throws -> [Devotional] {
        try db.read { db in
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("date") >= startDate && Column("date") <= endDate)
                .order(Column("date").desc, Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get devotionals by tag
    func getDevotionalsByTag(moduleId: String, tag: String) throws -> [Devotional] {
        try db.read { db in
            // Use LIKE for comma-separated tag matching
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(
                    Column("tags") == tag ||                           // Exact single tag
                    Column("tags").like("\(tag),%") ||                 // Tag at start
                    Column("tags").like("%,\(tag)") ||                 // Tag at end
                    Column("tags").like("%,\(tag),%")                  // Tag in middle
                )
                .order(Column("date").desc, Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get devotionals by category
    func getDevotionalsByCategory(moduleId: String, category: DevotionalCategory) throws -> [Devotional] {
        try db.read { db in
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("category") == category.rawValue)
                .order(Column("date").desc, Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    /// Get devotionals in a series
    func getDevotionalsInSeries(moduleId: String, seriesId: String) throws -> [Devotional] {
        try db.read { db in
            let entries = try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("series_id") == seriesId)
                .order(SQL("COALESCE(series_order, 999999)"), Column("title"))
                .fetchAll(db)
            return entries.compactMap { $0.toDevotional() }
        }
    }

    // MARK: - Tag Operations

    /// Get all unique tags across all devotionals in a module
    func getAllTags(moduleId: String) throws -> [String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tags FROM devotional_entries
                WHERE module_id = ? AND tags IS NOT NULL AND tags != ''
            """, arguments: [moduleId])

            var tagSet = Set<String>()
            for row in rows {
                if let tagsString: String = row["tags"] {
                    let tags = tagsString.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                    tagSet.formUnion(tags)
                }
            }
            return tagSet.sorted()
        }
    }

    /// Get tag counts for a module
    func getTagCounts(moduleId: String) throws -> [String: Int] {
        let tags = try getAllTags(moduleId: moduleId)
        var counts: [String: Int] = [:]

        try db.read { db in
            for tag in tags {
                let count = try DevotionalEntry
                    .filter(Column("module_id") == moduleId)
                    .filter(
                        Column("tags") == tag ||
                        Column("tags").like("\(tag),%") ||
                        Column("tags").like("%,\(tag)") ||
                        Column("tags").like("%,\(tag),%")
                    )
                    .fetchCount(db)
                counts[tag] = count
            }
        }

        return counts
    }

    // MARK: - Category Operations

    /// Get all categories used in a module
    func getUsedCategories(moduleId: String) throws -> [DevotionalCategory] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT category FROM devotional_entries
                WHERE module_id = ? AND category IS NOT NULL
                ORDER BY category
            """, arguments: [moduleId])

            return rows.compactMap { row in
                guard let categoryStr: String = row["category"] else { return nil }
                return DevotionalCategory(rawValue: categoryStr)
            }
        }
    }

    /// Get category counts for a module
    func getCategoryCounts(moduleId: String) throws -> [DevotionalCategory: Int] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT category, COUNT(*) as count FROM devotional_entries
                WHERE module_id = ? AND category IS NOT NULL
                GROUP BY category
            """, arguments: [moduleId])

            var counts: [DevotionalCategory: Int] = [:]
            for row in rows {
                if let categoryStr: String = row["category"],
                   let category = DevotionalCategory(rawValue: categoryStr),
                   let count: Int = row["count"] {
                    counts[category] = count
                }
            }
            return counts
        }
    }

    // MARK: - Series Operations

    /// Get all series in a module
    func getAllSeries(moduleId: String) throws -> [(id: String, name: String)] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT series_id, series_name FROM devotional_entries
                WHERE module_id = ? AND series_id IS NOT NULL
                ORDER BY series_name
            """, arguments: [moduleId])

            return rows.compactMap { row in
                guard let id: String = row["series_id"],
                      let name: String = row["series_name"] else { return nil }
                return (id: id, name: name)
            }
        }
    }

    // MARK: - Date Operations

    /// Get the date range of devotionals in a module
    func getDateRange(moduleId: String) throws -> (earliest: String?, latest: String?) {
        try db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(date) as earliest, MAX(date) as latest FROM devotional_entries
                WHERE module_id = ? AND date IS NOT NULL
            """, arguments: [moduleId])

            return (earliest: row?["earliest"], latest: row?["latest"])
        }
    }

    /// Get distinct dates that have devotionals
    func getDatesWithDevotionals(moduleId: String) throws -> [String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT date FROM devotional_entries
                WHERE module_id = ? AND date IS NOT NULL
                ORDER BY date DESC
            """, arguments: [moduleId])

            return rows.compactMap { $0["date"] as String? }
        }
    }

    // MARK: - Count Operations

    /// Get total count of devotionals in a module
    func getDevotionalCount(moduleId: String) throws -> Int {
        try db.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .fetchCount(db)
        }
    }

    // MARK: - Bulk Operations

    /// Import multiple devotionals
    func importDevotionals(_ devotionals: [Devotional], moduleId: String) throws {
        let entries = devotionals.map { DevotionalEntry(from: $0, moduleId: moduleId) }
        try db.importDevotionalEntries(entries)
    }

    /// Export all devotionals from a module
    func exportDevotionals(moduleId: String) throws -> [Devotional] {
        try getAllDevotionals(moduleId: moduleId)
    }
}

// MARK: - ModuleDatabase Extension for Enhanced Devotional Queries

extension ModuleDatabase {

    /// Get devotionals matching a FTS query
    func searchDevotionalsFTS(
        moduleId: String? = nil,
        query: String,
        limit: Int = 50
    ) throws -> [DevotionalEntry] {
        let ftsQuery = prepareFTSQueryForDevotionals(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try read { db in
            var conditions = ["devotional_entries_fts MATCH ?"]
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let moduleId = moduleId {
                conditions.append("d.module_id = ?")
                arguments.append(moduleId)
            }

            let whereClause = conditions.joined(separator: " AND ")

            let sql = """
                SELECT d.*
                FROM devotional_entries_fts f
                JOIN devotional_entries d ON f.id = d.id
                WHERE \(whereClause)
                ORDER BY bm25(devotional_entries_fts)
                LIMIT ?
            """
            arguments.append(limit)

            return try DevotionalEntry.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    private func prepareFTSQueryForDevotionals(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Escape FTS5 special characters
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

    /// Get all devotional entries for a module
    func getAllDevotionalEntries(moduleId: String) throws -> [DevotionalEntry] {
        try read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .fetchAll(db)
        }
    }
}
