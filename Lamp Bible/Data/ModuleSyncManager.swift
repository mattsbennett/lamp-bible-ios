//
//  ModuleSyncManager.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import Compression
import Combine

class ModuleSyncManager: ObservableObject {
    static let shared = ModuleSyncManager()

    /// Get the active storage provider - gets from SyncCoordinator, falls back to iCloud
    @MainActor
    private func getStorage() -> ModuleStorage {
        SyncCoordinator.shared.activeStorage ?? ICloudModuleStorage.shared
    }

    private let database = ModuleDatabase.shared

    private var isSyncing = false

    /// Pending note conflicts that need user resolution
    @Published var pendingConflicts: [NoteConflict] = []

    /// Module ID for pending note conflicts
    @Published var conflictModuleId: String? = nil

    /// Pending devotional conflicts that need user resolution
    @Published var pendingDevotionalConflicts: [DevotionalConflict] = []

    /// Module ID for pending devotional conflicts
    @Published var devotionalConflictModuleId: String? = nil

    private init() {}

    // MARK: - Availability

    /// Check if configured storage is available
    func isAvailable() async -> Bool {
        await getStorage().isAvailable()
    }

    // MARK: - Full Sync

    /// Sync all module types on app launch
    /// Priority order: user settings first (so UI reflects latest state),
    /// then translations (most likely to be needed immediately),
    /// then everything else.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        // 1. User settings first — completed readings, lexicon order, etc.
        await UserSettingsSyncManager.shared.performFullSync()

        // 2. Translations — the user's default translation is needed immediately
        do {
            try await syncModuleType(.translation)
        } catch {
            print("Failed to sync translation modules: \(error)")
        }

        // 3. Process markdown note imports from iCloud/Import/ directory
        do {
            let importResults = try await NotesImportExportManager.shared.processImports()
            if !importResults.isEmpty {
                let successCount = importResults.filter { $0.success }.count
                print("[Sync] Imported \(successCount) note file(s) from Import directory")
            }
        } catch {
            print("[Sync] Note import error: \(error)")
        }

        // 4. Remaining module types
        for type in ModuleType.allCases where type != .translation {
            do {
                try await syncModuleType(type)
            } catch {
                print("Failed to sync \(type.rawValue) modules: \(error)")
            }
        }
    }

    /// Sync all modules of a specific type
    func syncModuleType(_ type: ModuleType) async throws {
        guard await getStorage().isAvailable() else {
            print("iCloud storage not available for \(type.rawValue)")
            return
        }

        // Debug: Print the directory being scanned
        if let dirURL = await getStorage().directoryURL(for: type) {
            print("Scanning directory for \(type.rawValue): \(dirURL.path)")
        }

        // Get files from iCloud
        let cloudFiles = try await getStorage().listModuleFiles(type: type)
        print("Found \(cloudFiles.count) \(type.rawValue) files: \(cloudFiles.map { $0.id })")

        // Get registered modules from database
        let registeredModules = try database.getAllModules(type: type)
        let registeredIds = Set(registeredModules.map { $0.id })

        // Import new or updated modules from cloud
        for fileInfo in cloudFiles {
            // Handle legacy "bible-notes" -> "notes" mapping
            let effectiveId = fileInfo.id == "bible-notes" ? "notes" : fileInfo.id
            let isNew = !registeredIds.contains(effectiveId)
            let needsUpdate = !isNew && registeredModules.first(where: { $0.id == effectiveId })?.fileHash != fileInfo.fileHash

            if isNew || needsUpdate {
                do {
                    try await importModuleFromCloud(fileInfo: fileInfo, type: type)

                    // If we imported a legacy bible-notes file, delete it and export the new notes file
                    if type == .notes && fileInfo.id == "bible-notes" {
                        try? await getStorage().deleteModuleFile(type: .notes, fileName: "bible-notes.json")
                        try? await exportModule(id: "notes")
                        print("[NoteSync] Migrated bible-notes.json to notes.json")
                    }
                } catch {
                    print("Failed to import module \(fileInfo.id): \(error)")
                }
            }
        }

        // Remove modules that were previously synced but no longer exist in cloud
        // (Only delete if the module has a lastSynced timestamp, meaning it was synced before)
        var cloudIds = Set(cloudFiles.map { $0.id })
        // If bible-notes exists in cloud, consider "notes" as present
        if cloudIds.contains("bible-notes") {
            cloudIds.insert("notes")
        }
        for module in registeredModules where !cloudIds.contains(module.id) {
            // Only delete if this module was previously synced to cloud
            // If lastSynced is nil, it was created locally but never synced - don't delete it
            guard module.lastSynced != nil else {
                print("[Sync] Preserving local-only module \(module.id) (never synced to cloud)")
                continue
            }
            do {
                print("[Sync] Deleting module \(module.id) (was synced but no longer in cloud)")
                try database.deleteAllEntriesForModule(moduleId: module.id)
                try database.deleteModule(id: module.id)
            } catch {
                print("Failed to delete module \(module.id): \(error)")
            }
        }
    }

    // MARK: - Single Module Sync

    /// Sync a specific module by ID
    func syncModule(id: String) async throws {
        guard let module = try database.getModule(id: id) else {
            throw ModuleSyncError.moduleNotFound(id)
        }

        guard await getStorage().isAvailable() else {
            throw ModuleStorageError.notAvailable
        }

        // Use the stored file path from module metadata
        let fileName = module.filePath
        let cloudHash = try await getStorage().getFileHash(type: module.type, fileName: fileName)

        if cloudHash != module.fileHash {
            // Cloud has changes - reimport
            let isCompressedDb = fileName.hasSuffix(".lamp") || fileName.hasSuffix(".db.zlib")
            let fileExtension = (fileName as NSString).pathExtension.lowercased()

            if fileExtension == "db" || isCompressedDb {
                // SQLite format (compressed or uncompressed)
                let fileInfo = ModuleFileInfo(
                    id: id,
                    type: module.type,
                    filePath: fileName,
                    fileHash: cloudHash,
                    modificationDate: nil
                )
                try await importModuleFromSQLite(fileInfo: fileInfo, type: module.type)
            } else {
                // JSON format
                let data = try await getStorage().readModuleFile(type: module.type, fileName: fileName)
                try await importModuleData(id: id, type: module.type, data: data, hash: cloudHash)
            }
        }
    }

    // MARK: - Import from Cloud

    private func importModuleFromCloud(fileInfo: ModuleFileInfo, type: ModuleType) async throws {
        // Check file extension to determine import method
        let isCompressedDb = fileInfo.filePath.hasSuffix(".lamp") || fileInfo.filePath.hasSuffix(".db.zlib")
        let fileExtension = (fileInfo.filePath as NSString).pathExtension.lowercased()

        if fileExtension == "db" || isCompressedDb {
            // SQLite format (compressed or uncompressed) - use fast ATTACH DATABASE method
            try await importModuleFromSQLite(fileInfo: fileInfo, type: type)
        } else {
            // JSON format - use traditional JSON decoding
            let data = try await getStorage().readModuleFile(type: type, fileName: fileInfo.filePath)
            try await importModuleData(id: fileInfo.id, type: type, data: data, hash: fileInfo.fileHash)
        }
    }

    private func importModuleFromSQLite(fileInfo: ModuleFileInfo, type: ModuleType) async throws {
        // Download the .db or .lamp file to temporary location
        let data = try await getStorage().readModuleFile(type: type, fileName: fileInfo.filePath)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")

        // Decompress if it's a compressed file (.lamp or .db.zlib)
        if fileInfo.filePath.hasSuffix(".lamp") || fileInfo.filePath.hasSuffix(".db.zlib") {
            let decompressedData = try decompressZlib(data)
            try decompressedData.write(to: tempURL)
        } else {
            try data.write(to: tempURL)
        }

        // Create module metadata FIRST (entries have foreign key to modules table)
        // Note: translations store metadata in translations table, not modules table
        // Note: commentaries handle their own module creation due to series_id FK dependencies
        if type != .commentary {
            try await createModuleMetadata(id: fileInfo.id, type: type, hash: fileInfo.fileHash, tempURL: tempURL)
        }

        // Delete existing entries (after creating module record to avoid orphans)
        if type == .translation {
            // For translations, delete from translations tables
            try database.deleteAllTranslationContent(translationId: fileInfo.id)
            try database.deleteTranslation(id: fileInfo.id)
        } else if type == .commentary {
            // For commentaries, delete series, module, and entries
            // The series might be shared, so only delete if this is the only module using it
            if let existingModule = try database.getModule(id: fileInfo.id), let seriesId = existingModule.seriesId {
                let modulesWithSeries = try database.getModulesForSeries(seriesId: seriesId)
                if modulesWithSeries.count <= 1 {
                    try database.deleteCommentarySeries(id: seriesId)
                }
            }
            try database.deleteAllEntriesForModule(moduleId: fileInfo.id)
            try database.deleteModule(id: fileInfo.id)
        } else {
            try database.deleteAllEntriesForModule(moduleId: fileInfo.id)
        }

        // Use ATTACH DATABASE for fast bulk import
        // Use a unique alias to avoid conflicts with concurrent imports
        let dbAlias = "import_\(UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: ""))"

        do {
            // Use writeWithoutTransaction because ATTACH/DETACH cannot be used inside a transaction
            try database.writeWithoutTransaction { db in
                // Attach the module database with unique alias
                try db.execute(sql: "ATTACH DATABASE '\(tempURL.path)' AS \(dbAlias)")

                do {
                    // Wrap the actual inserts in a transaction for performance
                    try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

                    // Import based on module type
                    switch type {
                    case .dictionary:
                        // Copy dictionary entries
                        try db.execute(sql: """
                            INSERT INTO dictionary_entries (id, module_id, key, lemma, transliteration, pronunciation, senses_json, metadata_json)
                            SELECT id, module_id, key, lemma, transliteration, pronunciation, senses_json, metadata_json
                            FROM \(dbAlias).dictionary_entries
                            """)

                    case .commentary:
                        // Check which schema the source database uses
                        let commTables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type='table'")
                        let commTableNames = commTables.compactMap { $0["name"] as String? }

                        let now = Int(Date().timeIntervalSince1970)
                        let filePath = "\(fileInfo.id).lamp"

                        if commTableNames.contains("series_meta") {
                            // Standalone commentary module with series_meta table
                            // First, import or update the series metadata
                            if let seriesRow = try Row.fetchOne(db, sql: "SELECT * FROM \(dbAlias).series_meta LIMIT 1") {
                                let seriesId: String = seriesRow["id"]
                                let seriesName: String = seriesRow["name"] ?? seriesId
                                let seriesAbbrev: String? = seriesRow["abbreviation"]

                                // Insert or replace series metadata
                                try db.execute(sql: """
                                    INSERT OR REPLACE INTO commentary_series
                                    (id, name, abbreviation, description, editor, publisher, testament, language, website,
                                     editor_preface_json, introduction_json, abbreviations_json, bibliography_json, volumes_json)
                                    SELECT id, name, abbreviation, description, editor, publisher, testament, language, website,
                                           editor_preface_json, introduction_json, abbreviations_json, bibliography_json, volumes_json
                                    FROM \(dbAlias).series_meta
                                    """)

                                // Create module record linked to series
                                // Get book info for module name, use series name for description
                                let bookRow = try Row.fetchOne(db, sql: "SELECT title, author FROM \(dbAlias).commentary_books LIMIT 1")
                                let bookTitle: String = bookRow?["title"] ?? "Unknown"
                                let bookAuthor: String? = bookRow?["author"]

                                try db.execute(sql: """
                                    INSERT OR REPLACE INTO modules
                                    (id, type, name, description, author, file_path, file_hash, last_synced, is_editable, series_id, created_at, updated_at)
                                    VALUES (?, 'commentary', ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                                    """, arguments: [fileInfo.id, bookTitle, seriesName, bookAuthor, filePath, fileInfo.fileHash, now, seriesId, now, now])

                                // Copy commentary books (standalone format - no module_id, series_full, series_abbrev columns)
                                // Use series info from series_meta instead
                                try db.execute(sql: """
                                    INSERT OR REPLACE INTO commentary_books
                                    (id, module_id, book_number, series_full, series_abbrev, title, author, editor,
                                     publisher, year, abbreviations_json, front_matter_json, indices_json)
                                    SELECT ? || ':' || book_number, ?, book_number, ?, ?, title, author, editor,
                                           publisher, year, abbreviations_json, front_matter_json, indices_json
                                    FROM \(dbAlias).commentary_books
                                    """, arguments: [fileInfo.id, fileInfo.id, seriesName, seriesAbbrev])

                                // Copy commentary units (standalone format - no module_id column)
                                try db.execute(sql: """
                                    INSERT INTO commentary_units
                                    (id, module_id, book, chapter, sv, ev, unit_type, level, parent_id,
                                     title, suffix, introduction_json, translation_json, commentary_json, footnotes_json, search_text, order_index)
                                    SELECT ? || ':' || id, ?, book, chapter, sv, ev, unit_type, level, parent_id,
                                           title, suffix, introduction_json, translation_json, commentary_json, footnotes_json, search_text, order_index
                                    FROM \(dbAlias).commentary_units
                                    """, arguments: [fileInfo.id, fileInfo.id])
                            }
                        } else {
                            // Traditional format with module_id in tables
                            // First create the module record
                            let bookRow = try Row.fetchOne(db, sql: "SELECT title, author, series_full, series_abbrev FROM \(dbAlias).commentary_books LIMIT 1")
                            let bookTitle: String = bookRow?["title"] ?? "Unknown"
                            let bookAuthor: String? = bookRow?["author"]
                            let seriesFull: String? = bookRow?["series_full"]
                            let seriesAbbrev: String? = bookRow?["series_abbrev"]

                            try db.execute(sql: """
                                INSERT OR REPLACE INTO modules
                                (id, type, name, description, author, file_path, file_hash, last_synced, is_editable, series_full, series_abbrev, created_at, updated_at)
                                VALUES (?, 'commentary', ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                                """, arguments: [fileInfo.id, bookTitle, seriesFull, bookAuthor, filePath, fileInfo.fileHash, now, seriesFull, seriesAbbrev, now, now])

                            // Copy commentary book metadata
                            try db.execute(sql: """
                                INSERT OR REPLACE INTO commentary_books
                                (id, module_id, book_number, series_full, series_abbrev, title, author, editor,
                                 publisher, year, abbreviations_json, front_matter_json, indices_json)
                                SELECT id, module_id, book_number, series_full, series_abbrev, title, author, editor,
                                       publisher, year, abbreviations_json, front_matter_json, indices_json
                                FROM \(dbAlias).commentary_books
                                """)

                            // Copy commentary units
                            try db.execute(sql: """
                                INSERT INTO commentary_units
                                (id, module_id, book, chapter, sv, ev, unit_type, level, parent_id,
                                 title, suffix, introduction_json, translation_json, commentary_json, footnotes_json, search_text, order_index)
                                SELECT id, module_id, book, chapter, sv, ev, unit_type, level, parent_id,
                                       title, suffix, introduction_json, translation_json, commentary_json, footnotes_json, search_text, order_index
                                FROM \(dbAlias).commentary_units
                                """)
                        }

                    case .devotional:
                        // Check which schema the source database uses
                        let devCols = try Row.fetchAll(db, sql: "PRAGMA \(dbAlias).table_info(devotional_entries)")
                        let devColNames = Set(devCols.compactMap { $0["name"] as String? })

                        if devColNames.contains("content_json") {
                            // New schema with full devotional structure
                            // Check if optional columns exist
                            let hasRecordChangeTag = devColNames.contains("record_change_tag")
                            let hasMediaJson = devColNames.contains("media_json")

                            let recordChangeTagInsert = hasRecordChangeTag ? ", record_change_tag" : ""
                            let recordChangeTagSelect = hasRecordChangeTag ? ", record_change_tag" : ""
                            let mediaJsonInsert = hasMediaJson ? ", media_json" : ""
                            let mediaJsonSelect = hasMediaJson ? ", media_json" : ""

                            try db.execute(sql: """
                                INSERT INTO devotional_entries
                                (id, module_id, title, subtitle, author, date, tags, category,
                                 series_id, series_name, series_order, key_scriptures_json,
                                 summary_json, content_json, footnotes_json, related_ids,
                                 created, last_modified, search_text\(recordChangeTagInsert)\(mediaJsonInsert))
                                SELECT id, module_id, title, subtitle, author, date, tags, category,
                                       series_id, series_name, series_order, key_scriptures_json,
                                       summary_json, content_json, footnotes_json, related_ids,
                                       created, last_modified, search_text\(recordChangeTagSelect)\(mediaJsonSelect)
                                FROM \(dbAlias).devotional_entries
                                """)
                        } else {
                            // Legacy schema - copy with mapping
                            try db.execute(sql: """
                                INSERT INTO devotional_entries
                                (id, module_id, title, date, tags, content_json, last_modified, search_text)
                                SELECT id, module_id, title, month_day, tags, content, last_modified, content
                                FROM \(dbAlias).devotional_entries
                                """)
                        }

                    case .notes:
                        // Check which columns exist in the source database
                        let noteCols = try Row.fetchAll(db, sql: "PRAGMA \(dbAlias).table_info(note_entries)")
                        let noteColNames = Set(noteCols.compactMap { $0["name"] as String? })

                        // Build dynamic column lists based on source schema
                        var insertCols = ["id", "module_id", "verse_id", "title", "content", "last_modified"]
                        var selectCols = ["id", "module_id", "verse_id", "title", "content", "last_modified"]

                        // Handle verse_refs vs verse_refs_json naming
                        if noteColNames.contains("verse_refs_json") {
                            insertCols.append("verse_refs_json")
                            selectCols.append("verse_refs_json")
                        } else if noteColNames.contains("verse_refs") {
                            insertCols.append("verse_refs_json")
                            selectCols.append("verse_refs")
                        }

                        // Add optional columns if they exist in source
                        for col in ["book", "chapter", "verse", "footnotes_json", "search_text", "record_change_tag"] {
                            if noteColNames.contains(col) {
                                insertCols.append(col)
                                selectCols.append(col)
                            }
                        }

                        try db.execute(sql: """
                            INSERT INTO note_entries
                            (\(insertCols.joined(separator: ", ")))
                            SELECT \(selectCols.joined(separator: ", "))
                            FROM \(dbAlias).note_entries
                            """)

                    case .plan:
                        // Check if this is a plan database with plan_meta and days tables
                        let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type='table'")
                        let tableNames = tables.compactMap { $0["name"] as String? }

                        if tableNames.contains("plan_meta") && tableNames.contains("days") {
                            // Compact plan schema with plan_meta, days tables
                            let now = Int(Date().timeIntervalSince1970)
                            let filePath = "\(fileInfo.id).lamp"

                            // Get plan ID from plan_meta
                            guard let metaRow = try Row.fetchOne(db, sql: "SELECT id FROM \(dbAlias).plan_meta LIMIT 1"),
                                  let planId: String = metaRow["id"] else {
                                throw ModuleSyncError.importFailed("Could not read plan ID from plan_meta")
                            }

                            // Copy plan metadata
                            try db.execute(sql: """
                                INSERT INTO plans (id, name, description, author, full_description, duration, readings_per_day,
                                    file_path, file_hash, last_synced, created_at, updated_at)
                                SELECT id, name, description, author, full_description, duration, readings_per_day,
                                    ?, ?, ?, ?, ?
                                FROM \(dbAlias).plan_meta
                                """, arguments: [filePath, fileInfo.fileHash, now, now, now])

                            // Copy plan days
                            try db.execute(sql: """
                                INSERT INTO plan_days (plan_id, day, readings_json)
                                SELECT ?, day, readings_json
                                FROM \(dbAlias).days
                                """, arguments: [planId])
                        } else if tableNames.contains("plans") && tableNames.contains("plan_days") {
                            // Full GRDB schema - copy directly
                            try db.execute(sql: """
                                INSERT INTO plans (id, name, description, author, full_description, duration, readings_per_day,
                                    file_path, file_hash, last_synced, created_at, updated_at)
                                SELECT id, name, description, author, full_description, duration, readings_per_day,
                                    file_path, file_hash, last_synced, created_at, updated_at
                                FROM \(dbAlias).plans
                                """)
                            try db.execute(sql: """
                                INSERT INTO plan_days (plan_id, day, readings_json)
                                SELECT plan_id, day, readings_json
                                FROM \(dbAlias).plan_days
                                """)
                        } else {
                            throw ModuleSyncError.importFailed("Unknown plan database schema")
                        }

                    case .highlights:
                        // Check if this is a highlight database with highlight_meta and highlights tables
                        let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type='table'")
                        let tableNames = tables.compactMap { $0["name"] as String? }

                        if tableNames.contains("highlight_meta") && tableNames.contains("highlights") {
                            let now = Int(Date().timeIntervalSince1970)
                            let filePath = "\(fileInfo.id).lamp"

                            // Gethighlight set metadata
                            guard let metaRow = try Row.fetchOne(db, sql: "SELECT * FROM \(dbAlias).highlight_meta LIMIT 1"),
                                  let setId: String = metaRow["id"],
                                  let setName: String = metaRow["name"],
                                  let translationId: String = metaRow["translation_id"] else {
                                throw ModuleSyncError.importFailed("Could not read highlight metadata")
                            }

                            // Create module if not exists
                            try db.execute(sql: """
                                INSERT OR REPLACE INTO modules (id, type, name, description, file_path, file_hash, last_synced, is_editable, created_at, updated_at)
                                VALUES (?, 'highlights', ?, ?, ?, ?, ?, 1, ?, ?)
                                """, arguments: [fileInfo.id, setName, metaRow["description"] as String?, filePath, fileInfo.fileHash, now, now, now])

                            // Copy highlight set metadata
                            try db.execute(sql: """
                                INSERT OR REPLACE INTO highlight_sets (id, module_id, name, description, translation_id, created, last_modified)
                                VALUES (?, ?, ?, ?, ?, ?, ?)
                                """, arguments: [setId, fileInfo.id, setName, metaRow["description"] as String?, translationId,
                                                 (metaRow["created"] as Int?) ?? now, (metaRow["last_modified"] as Int?) ?? now])

                            // Copy highlights
                            try db.execute(sql: """
                                INSERT INTO highlights (set_id, ref, sc, ec, style, color)
                                SELECT ?, ref, sc, ec, style, color
                                FROM \(dbAlias).highlights
                                """, arguments: [setId])
                        } else if tableNames.contains("highlight_sets") && tableNames.contains("highlights") {
                            // Full GRDB schema - copy directly
                            try db.execute(sql: """
                                INSERT OR REPLACE INTO highlight_sets (id, module_id, name, description, translation_id, created, last_modified)
                                SELECT id, module_id, name, description, translation_id, created, last_modified
                                FROM \(dbAlias).highlight_sets
                                """)
                            try db.execute(sql: """
                                INSERT INTO highlights (set_id, ref, sc, ec, style, color)
                                SELECT set_id, ref, sc, ec, style, color
                                FROM \(dbAlias).highlights
                                """)
                        } else {
                            throw ModuleSyncError.importFailed("Unknown highlights database schema")
                        }

                    case .quiz:
                        // Copy quiz module metadata
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO quiz_modules (id, plan_id, name, description, questions_per_reading, age_groups_json)
                            SELECT id, plan_id, name, description, questions_per_reading, age_groups_json
                            FROM \(dbAlias).quiz_modules
                            """)

                        // Copy quiz questions
                        try db.execute(sql: """
                            INSERT INTO quiz_questions (quiz_module_id, day, sv, ev, age_group, question_index, question_json, answer_json, theme, christ_focused, references_json, cross_references_json)
                            SELECT quiz_module_id, day, sv, ev, age_group, question_index, question_json, answer_json, theme, christ_focused, references_json, cross_references_json
                            FROM \(dbAlias).quiz_questions
                            """)

                    case .translation:
                        // Check which schema the source database uses
                        let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type='table'")
                        let tableNames = tables.compactMap { $0["name"] as String? }

                        // Check which schema the source database uses
                        let hasTranslationsTable = tableNames.contains("translations")
                        let hasVersesTable = tableNames.contains("verses")

                        if hasTranslationsTable {
                            // New GRDB schema - copy directly
                            // Always set is_bundled=0 since synced translations are user-imported, not bundled
                            let now = Int(Date().timeIntervalSince1970)
                            try db.execute(sql: """
                                INSERT INTO translations (id, name, abbreviation, description, language, language_name,
                                    text_direction, translation_philosophy, year, publisher, copyright, copyright_year,
                                    license, source_texts_json, features_json, versification, file_path, file_hash,
                                    last_synced, is_bundled, created_at, updated_at)
                                SELECT id, name, abbreviation, description, language, language_name,
                                    text_direction, translation_philosophy, year, publisher, copyright, copyright_year,
                                    license, source_texts_json, features_json, versification, file_path, file_hash,
                                    ?, 0, ?, ?
                                FROM \(dbAlias).translations
                                """, arguments: [now, now, now])

                            // Copy translation books (if table exists)
                            if tableNames.contains("translation_books") {
                                try db.execute(sql: """
                                    INSERT INTO translation_books (id, translation_id, book_number, book_id, name, testament, chapter_count)
                                    SELECT id, translation_id, book_number, book_id, name, testament, chapter_count
                                    FROM \(dbAlias).translation_books
                                    """)
                            }

                            // Copy translation verses
                            if tableNames.contains("translation_verses") {
                                try db.execute(sql: """
                                    INSERT INTO translation_verses (translation_id, ref, book, chapter, verse, text,
                                        annotations_json, footnotes_json, footnote_refs_json, paragraph, poetry_json)
                                    SELECT translation_id, ref, book, chapter, verse, text,
                                        annotations_json, footnotes_json, footnote_refs_json, paragraph, poetry_json
                                    FROM \(dbAlias).translation_verses
                                    """)
                            }

                            // Copy translation headings (if table exists)
                            if tableNames.contains("translation_headings") {
                                try db.execute(sql: """
                                    INSERT INTO translation_headings (translation_id, book, chapter, before_verse, level, text)
                                    SELECT translation_id, book, chapter, before_verse, level, text
                                    FROM \(dbAlias).translation_headings
                                    """)
                            }
                        } else if tableNames.contains("translation_meta") && hasVersesTable {
                            // Compact schema with translation_meta, books, verses, headings tables
                            // This matches the schema used by the translation export tool
                            // In compact schema, translation_id is not repeated in every table

                            let now = Int(Date().timeIntervalSince1970)
                            let filePath = "\(fileInfo.id).lamp"

                            // Get translation ID from translation_meta
                            guard let metaRow = try Row.fetchOne(db, sql: "SELECT id FROM \(dbAlias).translation_meta LIMIT 1"),
                                  let translationId: String = metaRow["id"] else {
                                throw ModuleSyncError.importFailed("Could not read translation ID from translation_meta")
                            }

                            // Copy translation metadata from translation_meta
                            // Source table has content columns; we add app-specific columns ourselves
                            try db.execute(sql: """
                                INSERT INTO translations (id, name, abbreviation, description, language, language_name,
                                    text_direction, translation_philosophy, year, publisher, copyright, copyright_year,
                                    license, source_texts_json, features_json, versification, file_path, file_hash,
                                    last_synced, is_bundled, created_at, updated_at)
                                SELECT id, name, abbreviation, description, language, language_name,
                                    text_direction, translation_philosophy, year, publisher, copyright, copyright_year,
                                    license, source_texts_json, features_json, versification,
                                    ?, ?, ?, 0, ?, ?
                                FROM \(dbAlias).translation_meta
                                """, arguments: [filePath, fileInfo.fileHash, now, now, now])

                            // Copy books - compact schema: id=book_number, book_id=book_id string
                            if tableNames.contains("books") {
                                try db.execute(sql: """
                                    INSERT INTO translation_books (id, translation_id, book_number, book_id, name, testament, chapter_count)
                                    SELECT ? || ':' || id, ?, id, book_id, name, testament, chapter_count
                                    FROM \(dbAlias).books
                                    """, arguments: [translationId, translationId])
                            }

                            // Copy verses - compact schema may not have all columns
                            // Check which columns exist
                            let versesCols = try Row.fetchAll(db, sql: "PRAGMA \(dbAlias).table_info(verses)")
                            let versesColNames = Set(versesCols.compactMap { $0["name"] as String? })

                            let hasFootnoteRefs = versesColNames.contains("footnote_refs_json")
                            let hasPoetry = versesColNames.contains("poetry_json")

                            try db.execute(sql: """
                                INSERT INTO translation_verses (translation_id, ref, book, chapter, verse, text,
                                    annotations_json, footnotes_json, footnote_refs_json, paragraph, poetry_json)
                                SELECT ?, ref, book, chapter, verse, text,
                                    annotations_json, footnotes_json,
                                    \(hasFootnoteRefs ? "footnote_refs_json" : "NULL"),
                                    paragraph,
                                    \(hasPoetry ? "poetry_json" : "NULL")
                                FROM \(dbAlias).verses
                                """, arguments: [translationId])

                            // Copy headings - compact schema doesn't have translation_id column
                            if tableNames.contains("headings") {
                                try db.execute(sql: """
                                    INSERT INTO translation_headings (translation_id, book, chapter, before_verse, level, text)
                                    SELECT ?, book, chapter, before_verse, level, text
                                    FROM \(dbAlias).headings
                                    """, arguments: [translationId])
                            }

                            print("Imported translation from compact schema")
                        } else {
                            throw ModuleSyncError.importFailed("Unknown translation database schema. Tables found: \(tableNames)")
                        }
                    }

                    try db.execute(sql: "COMMIT")
                } catch {
                    try? db.execute(sql: "ROLLBACK")
                    throw error
                }

                // Detach after transaction is complete
                try db.execute(sql: "DETACH DATABASE \(dbAlias)")
            }
        } catch {
            // Try to detach on error (may fail if attach failed)
            try? database.writeWithoutTransaction { db in
                try? db.execute(sql: "DETACH DATABASE \(dbAlias)")
            }
            // Clean up temp file before rethrowing
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Clean up temp file only after all database operations complete
        try? FileManager.default.removeItem(at: tempURL)

        print("Imported \(type.rawValue) module \(fileInfo.id) from SQLite")

        // Download media files for devotional modules
        if type == .devotional {
            try await downloadDevotionalMedia(moduleId: fileInfo.id)
        }
    }

    private func createModuleMetadata(id: String, type: ModuleType, hash: String?, tempURL: URL) async throws {
        // Create module record by inspecting imported data
        // Use .lamp extension since we're compressing all SQLite files
        let filePath = "\(id).lamp"

        switch type {
        case .dictionary:
            // Try to read module metadata from the temp database
            var moduleName = id
            var moduleDescription: String? = nil
            var moduleAuthor: String? = nil
            var moduleVersion: String? = nil
            var keyType: String? = nil
            var seriesFull: String? = nil
            var seriesAbbrev: String? = nil

            // Open the temp database to read module metadata
            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    // Check both module_meta (new) and module_metadata (old) table names
                    let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                    let tableNames = tables.compactMap { $0["name"] as String? }

                    let metaTable = tableNames.contains("module_meta") ? "module_meta" :
                                    (tableNames.contains("module_metadata") ? "module_metadata" : nil)

                    if let tableName = metaTable,
                       let row = try Row.fetchOne(db, sql: "SELECT * FROM \(tableName) WHERE id = ?", arguments: [id]) {
                        if let name: String = row["name"] { moduleName = name }
                        moduleDescription = row["description"]
                        moduleAuthor = row["author"]
                        moduleVersion = row["version"]
                        keyType = row["key_type"]
                        // Series columns may not exist in older schema
                        seriesFull = row["series_full"]
                        seriesAbbrev = row["series_abbrev"]
                    }
                }
            } catch {
                print("Could not read module metadata from temp database for dictionary: \(error)")
            }

            // Infer key type from first entry if not in metadata
            if keyType == nil {
                let firstEntry = try database.read { db in
                    try DictionaryEntry
                        .filter(Column("module_id") == id)
                        .limit(1)
                        .fetchOne(db)
                }
                if let entry = firstEntry {
                    if entry.key.hasPrefix("H") || entry.key.hasPrefix("G") {
                        keyType = "strongs"
                    } else {
                        keyType = "word"
                    }
                }
            }

            let module = Module(
                id: id,
                type: .dictionary,
                name: moduleName,
                description: moduleDescription,
                author: moduleAuthor,
                version: moduleVersion,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: false,
                keyType: keyType,
                seriesFull: seriesFull,
                seriesAbbrev: seriesAbbrev
            )
            try database.saveModule(module)

        case .commentary:
            // Read book and series metadata from temp database (before import)
            var title: String = "Unknown Title"
            var author: String? = nil
            var seriesFull: String? = nil
            var seriesId: String? = nil

            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    // Check for series_meta table (standalone format)
                    let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                    let tableNames = tables.compactMap { $0["name"] as String? }

                    if tableNames.contains("series_meta") {
                        // Standalone format - read from series_meta
                        if let seriesRow = try Row.fetchOne(db, sql: "SELECT id, name FROM series_meta LIMIT 1") {
                            seriesId = seriesRow["id"]
                            seriesFull = seriesRow["name"]
                        }
                        // Book info from commentary_books (no module_id filter needed)
                        if let row = try Row.fetchOne(db, sql: "SELECT title, author FROM commentary_books LIMIT 1") {
                            if let t: String = row["title"] { title = t }
                            author = row["author"]
                        }
                    } else {
                        // Traditional format with module_id
                        if let row = try Row.fetchOne(db, sql: "SELECT title, author, series_full FROM commentary_books WHERE module_id = ?", arguments: [id]) {
                            if let t: String = row["title"] { title = t }
                            author = row["author"]
                            seriesFull = row["series_full"]
                        }
                    }
                }
            } catch {
                print("Could not read commentary_books from temp database: \(error)")
            }

            let module = Module(
                id: id,
                type: .commentary,
                name: title,
                description: seriesFull,
                author: author,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: false,
                seriesId: seriesId
            )
            try database.saveModule(module)

        case .devotional:
            // Try to read module metadata from the temp database
            var moduleName = id
            var moduleDescription: String? = nil
            var moduleAuthor: String? = nil
            var moduleVersion: String? = nil
            var isEditable = true

            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    // Check both module_meta (new) and module_metadata (old) table names
                    let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                    let tableNames = tables.compactMap { $0["name"] as String? }

                    let metaTable = tableNames.contains("module_meta") ? "module_meta" : "module_metadata"

                    if let row = try Row.fetchOne(db, sql: "SELECT * FROM \(metaTable) WHERE id = ?", arguments: [id]) {
                        if let name: String = row["name"] { moduleName = name }
                        moduleDescription = row["description"]
                        moduleAuthor = row["author"]
                        moduleVersion = row["version"]
                        if let editable: Int = row["is_editable"] { isEditable = editable == 1 }
                    }
                }
            } catch {
                print("Could not read module metadata from temp database for devotional: \(error)")
            }

            let devModule = Module(
                id: id,
                type: .devotional,
                name: moduleName,
                description: moduleDescription,
                author: moduleAuthor,
                version: moduleVersion,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: isEditable
            )
            try database.saveModule(devModule)

        case .notes:
            // Try to read module metadata from the temp database
            var moduleName = id
            var moduleDescription: String? = nil
            var moduleAuthor: String? = nil
            var moduleVersion: String? = nil
            var isEditable = true

            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    // Check both module_meta (new) and module_metadata (old) table names
                    let tables = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
                    let tableNames = tables.compactMap { $0["name"] as String? }

                    let metaTable = tableNames.contains("module_meta") ? "module_meta" : "module_metadata"

                    if let row = try Row.fetchOne(db, sql: "SELECT * FROM \(metaTable) WHERE id = ?", arguments: [id]) {
                        if let name: String = row["name"] { moduleName = name }
                        moduleDescription = row["description"]
                        moduleAuthor = row["author"]
                        moduleVersion = row["version"]
                        if let editable: Int = row["is_editable"] { isEditable = editable == 1 }
                    }
                }
            } catch {
                print("Could not read module metadata from temp database for notes: \(error)")
            }

            let notesModule = Module(
                id: id,
                type: .notes,
                name: moduleName,
                description: moduleDescription,
                author: moduleAuthor,
                version: moduleVersion,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: isEditable
            )
            try database.saveModule(notesModule)

        case .translation:
            // Translations store metadata in the translations table, not modules table
            // The metadata is copied directly via ATTACH DATABASE, so nothing to do here
            break

        case .plan:
            // Plans store metadata in the plans table, not modules table
            // The metadata is copied directly via ATTACH DATABASE, so nothing to do here
            break

        case .highlights:
            // Highlights store metadata in the highlight_sets table
            // The metadata is copied directly via ATTACH DATABASE, so nothing to do here
            break

        case .quiz:
            // Quizzes store metadata in the quiz_modules table
            // The metadata is copied directly via ATTACH DATABASE, so nothing to do here
            break
        }
    }

    private func importModuleData(id: String, type: ModuleType, data: Data, hash: String?) async throws {
        let decoder = JSONDecoder()

        // Delete existing entries (for non-translation modules stored in GRDB)
        if type != .translation {
            try database.deleteAllEntriesForModule(moduleId: id)
        }

        switch type {
        case .translation:
            // Translations should use importTranslationSchemaModule or SQLite import
            // The old JSON format is no longer supported
            throw ModuleSyncError.importFailed("Use importTranslationSchemaModule() for JSON translations or .lamp for SQLite format.")

        case .dictionary:
            let moduleFile = try decoder.decode(DictionaryModuleFile.self, from: data)
            try importDictionaryModule(moduleFile, hash: hash)

        case .commentary:
            let moduleFile = try decoder.decode(CommentaryBookFile.self, from: data)
            try importCommentaryModule(moduleFile, moduleId: id, hash: hash)

        case .devotional:
            let moduleFile = try decoder.decode(DevotionalModuleFile.self, from: data)
            try importDevotionalModule(moduleFile, hash: hash)

        case .notes:
            let moduleFile = try decoder.decode(NoteModuleFile.self, from: data)
            try importNoteModule(moduleFile, hash: hash)

        case .plan:
            // Plans are imported via SQLite format only (.lamp)
            // JSON import could be added in the future if needed
            throw ModuleSyncError.importFailed("JSON import not supported for plans. Use .lamp format.")

        case .highlights:
            // Highlights are imported via SQLite format only (.lamp)
            throw ModuleSyncError.importFailed("JSON import not supported for highlights. Use .lamp format.")

        case .quiz:
            // Quizzes are imported via SQLite format only (.lamp)
            throw ModuleSyncError.importFailed("JSON import not supported for quizzes. Use .lamp format.")
        }
    }

    private func importDictionaryModule(_ file: DictionaryModuleFile, hash: String?) throws {
        let module = Module(
            id: file.id,
            type: .dictionary,
            name: file.name,
            description: file.description,
            author: file.author,
            version: file.version,
            filePath: "\(file.id).json",
            fileHash: hash,
            lastSynced: Int(Date().timeIntervalSince1970),
            isEditable: false,
            keyType: file.keyType,
            seriesFull: file.seriesFull,
            seriesAbbrev: file.seriesAbbrev
        )
        try database.saveModule(module)

        let entries = file.entries.map { entry in
            DictionaryEntry(
                moduleId: file.id,
                key: entry.key,
                lemma: entry.lemma,
                transliteration: entry.transliteration,
                pronunciation: entry.pronunciation,
                senses: entry.allSenses()
            )
        }
        try database.importDictionaryEntries(entries)
    }

    private func importCommentaryModule(_ file: CommentaryBookFile, moduleId: String, hash: String?) throws {
        // Module ID comes from filename (e.g., "NICNT_matt" from "NICNT_matt.json")

        // Create or update module record
        let module = Module(
            id: moduleId,
            type: .commentary,
            name: file.meta.title,
            description: nil,
            author: file.meta.author,
            version: file.meta.schemaVersion,
            filePath: "\(moduleId).json",
            fileHash: hash,
            lastSynced: Int(Date().timeIntervalSince1970),
            isEditable: false
        )
        try database.saveModule(module)

        // Convert front matter for storage
        var frontMatter: CommentaryFrontMatter? = nil
        if let fm = file.frontMatter {
            frontMatter = CommentaryFrontMatter(
                dedication: fm.dedication,
                editorPreface: fm.editorPreface,
                authorPreface: fm.authorPreface,
                introduction: fm.introduction,
                bibliography: fm.bibliography
            )
        }

        // Convert indices for storage
        var indices: CommentaryIndices? = nil
        if let idx = file.indices {
            indices = CommentaryIndices(
                subjects: idx.subjects,
                authors: idx.authors,
                scriptures: idx.scriptures,
                greekWords: idx.greekWords,
                hebrewWords: idx.hebrewWords
            )
        }

        // Create book metadata record
        let commentaryBook = CommentaryBook(
            moduleId: moduleId,
            bookNumber: file.bookNumber,
            seriesFull: file.meta.seriesFull,
            seriesAbbrev: file.meta.seriesAbbrev,
            title: file.meta.title,
            author: file.meta.author,
            editor: file.meta.editor,
            publisher: file.meta.publisher,
            year: file.meta.year,
            abbreviations: file.abbreviations,
            frontMatter: frontMatter,
            indices: indices
        )
        try database.importCommentaryBook(commentaryBook)

        // Parse chapters and create units
        var units: [CommentaryUnit] = []
        var orderIndex = 0

        for chapterFile in file.chapters {
            let chapter = chapterFile.chapter

            // Chapter introduction (if any)
            if let intro = chapterFile.introduction {
                let chapterSv = file.bookNumber * 1000000 + chapter * 1000 + 1
                let unit = CommentaryUnit(
                    id: "\(moduleId):\(file.bookNumber):chapter_intro:\(chapter)",
                    moduleId: moduleId,
                    book: file.bookNumber,
                    chapter: chapter,
                    sv: chapterSv,
                    ev: nil,
                    unitType: .section,
                    level: 0,
                    parentId: nil,
                    title: "Chapter \(chapter) Introduction",
                    introduction: intro,
                    orderIndex: orderIndex
                )
                units.append(unit)
                orderIndex += 1
            }

            // Process sections
            if let sections = chapterFile.sections {
                for section in sections {
                    parseSection(
                        section: section,
                        moduleId: moduleId,
                        bookNumber: file.bookNumber,
                        chapter: chapter,
                        parentId: nil,
                        level: 1,
                        units: &units,
                        orderIndex: &orderIndex,
                        chapterFootnotes: chapterFile.footnotes
                    )
                }
            }

            // Process pericopae (if no sections)
            if let pericopae = chapterFile.pericopae {
                for pericope in pericopae {
                    parsePericope(
                        pericope: pericope,
                        moduleId: moduleId,
                        bookNumber: file.bookNumber,
                        chapter: chapter,
                        parentId: nil,
                        units: &units,
                        orderIndex: &orderIndex,
                        chapterFootnotes: chapterFile.footnotes
                    )
                }
            }

            // Process verses directly (simple commentary format)
            if let verses = chapterFile.verses {
                for verse in verses {
                    parseVerse(
                        verse: verse,
                        moduleId: moduleId,
                        bookNumber: file.bookNumber,
                        chapter: chapter,
                        parentId: nil,
                        units: &units,
                        orderIndex: &orderIndex,
                        footnotes: chapterFile.footnotes
                    )
                }
            }
        }

        // Bulk import all units
        try database.importCommentaryUnits(units)
        print("Imported commentary: \(file.meta.title) - \(file.book) with \(units.count) units")
    }

    // MARK: - Commentary Import Helpers

    private func parseSection(
        section: SectionFile,
        moduleId: String,
        bookNumber: Int,
        chapter: Int,
        parentId: String?,
        level: Int,
        units: inout [CommentaryUnit],
        orderIndex: inout Int,
        chapterFootnotes: [CommentaryFootnote]?
    ) {
        // Use order_index for guaranteed uniqueness
        let sectionId = "\(moduleId):\(bookNumber):section:\(chapter):\(orderIndex)"
        let sv = section.sv ?? (bookNumber * 1000000 + chapter * 1000 + 1)
        let ev = section.ev

        let unit = CommentaryUnit(
            id: sectionId,
            moduleId: moduleId,
            book: bookNumber,
            chapter: chapter,
            sv: sv,
            ev: ev,
            unitType: .section,
            level: level,
            parentId: parentId,
            title: section.title,
            introduction: section.introduction,
            orderIndex: orderIndex
        )
        units.append(unit)
        orderIndex += 1

        // Process subsections recursively
        if let subsections = section.subsections {
            for subsection in subsections {
                parseSection(
                    section: subsection,
                    moduleId: moduleId,
                    bookNumber: bookNumber,
                    chapter: chapter,
                    parentId: sectionId,
                    level: level + 1,
                    units: &units,
                    orderIndex: &orderIndex,
                    chapterFootnotes: chapterFootnotes
                )
            }
        }

        // Process pericopae within section
        if let pericopae = section.pericopae {
            for pericope in pericopae {
                parsePericope(
                    pericope: pericope,
                    moduleId: moduleId,
                    bookNumber: bookNumber,
                    chapter: chapter,
                    parentId: sectionId,
                    units: &units,
                    orderIndex: &orderIndex,
                    chapterFootnotes: chapterFootnotes
                )
            }
        }
    }

    private func parsePericope(
        pericope: PericopeFile,
        moduleId: String,
        bookNumber: Int,
        chapter: Int,
        parentId: String?,
        units: inout [CommentaryUnit],
        orderIndex: inout Int,
        chapterFootnotes: [CommentaryFootnote]?
    ) {
        // Use order_index for guaranteed uniqueness
        let pericopeId = "\(moduleId):\(bookNumber):pericope:\(chapter):\(orderIndex)"
        let sv = pericope.sv ?? (bookNumber * 1000000 + chapter * 1000 + 1)
        let ev = pericope.ev

        // Merge pericope footnotes with chapter footnotes if needed
        var allFootnotes: [CommentaryFootnote]? = nil
        if let pf = pericope.footnotes {
            allFootnotes = pf
        } else if let cf = chapterFootnotes {
            allFootnotes = cf
        }

        let unit = CommentaryUnit(
            id: pericopeId,
            moduleId: moduleId,
            book: bookNumber,
            chapter: chapter,
            sv: sv,
            ev: ev,
            unitType: .pericope,
            level: 1,
            parentId: parentId,
            title: pericope.title,
            introduction: pericope.introduction,
            translation: pericope.translation,
            footnotes: allFootnotes,
            orderIndex: orderIndex
        )
        units.append(unit)
        orderIndex += 1

        // Process verses within pericope
        if let verses = pericope.verses {
            for verse in verses {
                parseVerse(
                    verse: verse,
                    moduleId: moduleId,
                    bookNumber: bookNumber,
                    chapter: chapter,
                    parentId: pericopeId,
                    units: &units,
                    orderIndex: &orderIndex,
                    footnotes: allFootnotes
                )
            }
        }
    }

    private func parseVerse(
        verse: VerseCommentaryFile,
        moduleId: String,
        bookNumber: Int,
        chapter: Int,
        parentId: String?,
        units: inout [CommentaryUnit],
        orderIndex: inout Int,
        footnotes: [CommentaryFootnote]?
    ) {
        let sv = verse.sv
        let ev = verse.ev
        let suffix = verse.suffix ?? ""
        // Include order_index to ensure uniqueness (verses can appear in multiple contexts)
        let verseId = "\(moduleId):\(bookNumber):verse:\(chapter):\(orderIndex):\(sv)\(suffix)"

        // Use verse-specific footnotes if available, otherwise use parent footnotes
        let verseFootnotes = verse.footnotes ?? footnotes

        let unit = CommentaryUnit(
            id: verseId,
            moduleId: moduleId,
            book: bookNumber,
            chapter: chapter,
            sv: sv,
            ev: ev,
            unitType: .verse,
            level: 1,
            parentId: parentId,
            suffix: verse.suffix,
            translation: verse.translation,
            commentary: verse.commentary,
            footnotes: verseFootnotes,
            orderIndex: orderIndex
        )
        units.append(unit)
        orderIndex += 1
    }

    private func importDevotionalModule(_ file: DevotionalModuleFile, hash: String?) throws {
        let module = Module(
            id: file.id,
            type: .devotional,
            name: file.name,
            description: file.description,
            author: file.author,
            version: file.version,
            filePath: "\(file.id).json",
            fileHash: hash,
            lastSynced: Int(Date().timeIntervalSince1970),
            isEditable: file.isEditable ?? true
        )
        try database.saveModule(module)

        // Convert Devotional models to DevotionalEntry for database storage
        let cloudEntries = file.entries.map { devotional in
            DevotionalEntry(from: devotional, moduleId: file.id)
        }

        // Get local entries for this module
        let localEntries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == file.id)
                .fetchAll(db)
        }

        // Merge entries (similar to notes)
        let mergeResult = mergeDevotionalEntries(local: localEntries, cloud: cloudEntries, moduleId: file.id)

        // Save merged entries (delete all first, then insert merged)
        try database.deleteAllEntriesForModule(moduleId: file.id)
        try database.importDevotionalEntries(mergeResult.entriesToSave)

        // Store conflicts for UI resolution
        if !mergeResult.conflicts.isEmpty {
            DispatchQueue.main.async {
                self.pendingDevotionalConflicts = mergeResult.conflicts
                self.devotionalConflictModuleId = file.id
            }
        }

        print("[DevotionalSync] Merged \(mergeResult.cloudMergeCount) from cloud, kept \(mergeResult.localKeptCount) local, \(mergeResult.conflicts.count) conflicts")
    }

    /// Merge local and cloud devotional entries with conflict detection
    private func mergeDevotionalEntries(local: [DevotionalEntry], cloud: [DevotionalEntry], moduleId: String) -> DevotionalMergeResult {
        var result = DevotionalMergeResult(
            entriesToSave: [],
            conflicts: [],
            cloudMergeCount: 0,
            localKeptCount: 0
        )

        // Index entries by ID for efficient lookup
        let localById = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let cloudById = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })

        let allIds = Set(localById.keys).union(Set(cloudById.keys))

        for id in allIds {
            let localEntry = localById[id]
            let cloudEntry = cloudById[id]

            switch (localEntry, cloudEntry) {
            case (nil, let cloud?):
                // Only in cloud - add it
                result.entriesToSave.append(cloud)
                result.cloudMergeCount += 1

            case (let local?, nil):
                // Only in local - keep it
                result.entriesToSave.append(local)
                result.localKeptCount += 1

            case (let local?, let cloud?):
                // Exists in both - check for conflict
                let localModified = local.lastModified ?? 0
                let cloudModified = cloud.lastModified ?? 0

                // Check if content is the same (no conflict)
                if local.contentJson == cloud.contentJson && local.title == cloud.title {
                    // Same content - keep whichever has newer timestamp
                    result.entriesToSave.append(localModified >= cloudModified ? local : cloud)
                } else if cloudModified > localModified {
                    // Cloud is newer - use cloud (THIS OVERWRITES LOCAL CHANGES)
                    print("[DevotionalSync] WARNING: Cloud overwrote local for '\(local.title)' (cloud:\(cloudModified) > local:\(localModified))")
                    result.entriesToSave.append(cloud)
                    result.cloudMergeCount += 1
                } else if localModified > cloudModified {
                    // Local is newer - keep local
                    result.entriesToSave.append(local)
                    result.localKeptCount += 1
                } else {
                    // Same timestamp but different content - true conflict
                    if let localDev = local.toDevotional(), let cloudDev = cloud.toDevotional() {
                        result.conflicts.append(DevotionalConflict(
                            id: id,
                            localEntry: localDev,
                            cloudEntry: cloudDev
                        ))
                    }
                    // Temporarily keep local until user resolves
                    result.entriesToSave.append(local)
                }

            case (nil, nil):
                // Shouldn't happen
                break
            }
        }

        return result
    }

    /// Result of a devotional sync merge operation
    struct DevotionalMergeResult {
        var entriesToSave: [DevotionalEntry]
        var conflicts: [DevotionalConflict]
        var cloudMergeCount: Int
        var localKeptCount: Int
    }

    private func importNoteModule(_ file: NoteModuleFile, hash: String?) throws {
        // Remap legacy "bible-notes" to new "notes" ID
        let moduleId = file.id == "bible-notes" ? "notes" : file.id
        let moduleName = file.id == "bible-notes" ? "My Notes" : file.name
        let filePath = file.id == "bible-notes" ? "notes.json" : "\(file.id).json"

        let module = Module(
            id: moduleId,
            type: .notes,
            name: moduleName,
            description: file.description,
            author: file.author,
            version: file.version,
            filePath: filePath,
            fileHash: hash,
            lastSynced: Int(Date().timeIntervalSince1970),
            isEditable: file.isEditable ?? true
        )
        try database.saveModule(module)

        // Convert cloud entries (using remapped moduleId)
        let cloudEntries = file.entries.map { entry in
            NoteEntry(
                id: entry.id.replacingOccurrences(of: "bible-notes:", with: "notes:"),
                moduleId: moduleId,
                verseId: entry.verseId,
                title: entry.title,
                content: entry.content,
                verseRefs: entry.verseRefs?.map { $0.sv },
                lastModified: entry.lastModified,
                footnotes: entry.footnotes
            )
        }

        // Get local entries for this module
        let localEntries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .fetchAll(db)
        }

        // Merge entries
        let mergeResult = mergeNoteEntries(local: localEntries, cloud: cloudEntries, moduleId: moduleId)

        // Save merged entries (delete all first, then insert merged)
        try database.deleteAllEntriesForModule(moduleId: moduleId)
        try database.importNoteEntries(mergeResult.entriesToSave)

        // Store conflicts for UI resolution
        if !mergeResult.conflicts.isEmpty {
            DispatchQueue.main.async {
                self.pendingConflicts = mergeResult.conflicts
                self.conflictModuleId = moduleId
            }
        }

        print("[NoteSync] Merged \(mergeResult.cloudMergeCount) from cloud, kept \(mergeResult.localKeptCount) local, \(mergeResult.conflicts.count) conflicts")
    }

    /// Merge local and cloud note entries with conflict detection
    private func mergeNoteEntries(local: [NoteEntry], cloud: [NoteEntry], moduleId: String) -> NoteSyncMergeResult {
        var result = NoteSyncMergeResult(
            entriesToSave: [],
            conflicts: [],
            cloudMergeCount: 0,
            localKeptCount: 0
        )

        // Index entries by verseId for efficient lookup
        let localByVerse = Dictionary(grouping: local, by: { $0.verseId }).mapValues { $0.first! }
        let cloudByVerse = Dictionary(grouping: cloud, by: { $0.verseId }).mapValues { $0.first! }

        let allVerseIds = Set(localByVerse.keys).union(Set(cloudByVerse.keys))

        for verseId in allVerseIds {
            let localEntry = localByVerse[verseId]
            let cloudEntry = cloudByVerse[verseId]

            switch (localEntry, cloudEntry) {
            case (nil, let cloud?):
                // Only in cloud - add it
                result.entriesToSave.append(cloud)
                result.cloudMergeCount += 1

            case (let local?, nil):
                // Only in local - keep it
                result.entriesToSave.append(local)
                result.localKeptCount += 1

            case (let local?, let cloud?):
                // Exists in both - check for conflict
                let localModified = local.lastModified ?? 0
                let cloudModified = cloud.lastModified ?? 0

                // Check if content is the same (no conflict)
                if local.content == cloud.content && local.footnotesJson == cloud.footnotesJson {
                    // Same content - keep whichever has newer timestamp
                    result.entriesToSave.append(localModified >= cloudModified ? local : cloud)
                } else if localModified == cloudModified {
                    // Same timestamp but different content - true conflict
                    result.conflicts.append(NoteConflict(
                        id: String(verseId),
                        verseId: verseId,
                        localEntry: local,
                        cloudEntry: cloud
                    ))
                    // Temporarily keep local until user resolves
                    result.entriesToSave.append(local)
                } else if cloudModified > localModified {
                    // Cloud is newer - use cloud
                    result.entriesToSave.append(cloud)
                    result.cloudMergeCount += 1
                } else {
                    // Local is newer - keep local
                    result.entriesToSave.append(local)
                    result.localKeptCount += 1
                }

            case (nil, nil):
                // Shouldn't happen
                break
            }
        }

        return result
    }

    /// Resolve a conflict with user's choice
    func resolveConflict(_ conflict: NoteConflict, resolution: ConflictResolution) {
        guard let moduleId = conflictModuleId else { return }

        do {
            switch resolution {
            case .keepLocal:
                // Already in database, just remove from conflicts
                break

            case .keepCloud:
                // Replace local with cloud version
                try database.saveNoteEntry(conflict.cloudEntry)

            case .keepBoth:
                // Keep local, add cloud as new entry with modified verseId
                // Append to next available verse slot or create compound entry
                var newEntry = conflict.cloudEntry
                newEntry.id = "\(moduleId):\(conflict.verseId):cloud"
                newEntry.content = "[From other device]\n\(conflict.cloudEntry.content)"
                try database.saveNoteEntry(newEntry)
            }

            // Remove from pending conflicts
            DispatchQueue.main.async {
                self.pendingConflicts.removeAll { $0.verseId == conflict.verseId }
                if self.pendingConflicts.isEmpty {
                    self.conflictModuleId = nil
                }
            }

            // Re-export to sync the resolution
            Task {
                try? await exportModule(id: moduleId)
            }
        } catch {
            print("[NoteSync] Failed to resolve conflict: \(error)")
        }
    }

    /// Resolve all conflicts with the same choice
    func resolveAllConflicts(resolution: ConflictResolution) {
        let conflicts = pendingConflicts
        for conflict in conflicts {
            resolveConflict(conflict, resolution: resolution)
        }
    }

    // MARK: - Devotional Conflict Resolution

    /// Resolve a devotional conflict with user's choice
    func resolveDevotionalConflict(_ conflict: DevotionalConflict, resolution: DevotionalConflictResolution) {
        guard let moduleId = devotionalConflictModuleId else { return }

        do {
            switch resolution {
            case .keepLocal:
                // Already in database, just remove from conflicts
                break

            case .keepCloud:
                // Replace local with cloud version
                let entry = DevotionalEntry(from: conflict.cloudEntry, moduleId: moduleId)
                try database.saveDevotionalEntry(entry)

            case .keepBoth:
                // Keep local, add cloud as new entry with modified ID
                var cloudDevotional = conflict.cloudEntry
                cloudDevotional.meta.id = UUID().uuidString
                cloudDevotional.meta.title = "[From other device] \(conflict.cloudEntry.meta.title)"
                let entry = DevotionalEntry(from: cloudDevotional, moduleId: moduleId)
                try database.saveDevotionalEntry(entry)
            }

            // Remove from pending conflicts
            DispatchQueue.main.async {
                self.pendingDevotionalConflicts.removeAll { $0.id == conflict.id }
                if self.pendingDevotionalConflicts.isEmpty {
                    self.devotionalConflictModuleId = nil
                }
            }

            // Re-export to sync the resolution
            Task {
                try? await exportModule(id: moduleId)
            }
        } catch {
            print("[DevotionalSync] Failed to resolve conflict: \(error)")
        }
    }

    /// Resolve all devotional conflicts with the same choice
    func resolveAllDevotionalConflicts(resolution: DevotionalConflictResolution) {
        let conflicts = pendingDevotionalConflicts
        for conflict in conflicts {
            resolveDevotionalConflict(conflict, resolution: resolution)
        }
    }

    // MARK: - Translation Schema Import (GRDB)

    /// Import a translation using the new translation_schema.json format into GRDB
    func importTranslationSchemaModule(from data: Data, fileHash: String? = nil) async throws {
        let decoder = JSONDecoder()
        let file = try decoder.decode(TranslationSchemaFile.self, from: data)

        // Delete existing translation content if it exists
        try database.deleteAllTranslationContent(translationId: file.meta.id)

        // Also delete the translation record itself
        try database.deleteTranslation(id: file.meta.id)

        // Create translation metadata
        let translation = TranslationModule(
            id: file.meta.id,
            name: file.meta.name,
            abbreviation: file.meta.abbreviation,
            translationDescription: file.meta.description,
            language: file.meta.language,
            languageName: file.meta.languageName,
            textDirection: file.meta.textDirection ?? "ltr",
            translationPhilosophy: file.meta.translationPhilosophy,
            year: file.meta.year,
            publisher: file.meta.publisher,
            copyright: file.meta.copyright,
            copyrightYear: file.meta.copyrightYear,
            license: file.meta.license,
            sourceTexts: file.meta.sourceTexts,
            features: file.meta.features,
            versification: file.meta.versification ?? "standard",
            filePath: "\(file.meta.id).json",
            fileHash: fileHash,
            lastSynced: Int(Date().timeIntervalSince1970),
            isBundled: false,
            createdAt: Int(Date().timeIntervalSince1970),
            updatedAt: Int(Date().timeIntervalSince1970)
        )

        // Build arrays for batch import
        var books: [TranslationBook] = []
        var verses: [TranslationVerse] = []
        var headings: [TranslationHeading] = []

        for bookFile in file.books {
            // Create book record
            let book = TranslationBook(
                translationId: file.meta.id,
                bookNumber: bookFile.number,
                bookId: bookFile.id,
                name: bookFile.name,
                testament: bookFile.testament,
                chapterCount: bookFile.chapters.count
            )
            books.append(book)

            // Process chapters
            for chapterFile in bookFile.chapters {
                // Process headings
                if let chapterHeadings = chapterFile.headings {
                    for headingFile in chapterHeadings {
                        let heading = TranslationHeading(
                            translationId: file.meta.id,
                            book: bookFile.number,
                            chapter: chapterFile.chapter,
                            beforeVerse: headingFile.beforeVerse,
                            level: headingFile.level ?? 1,
                            text: headingFile.text
                        )
                        headings.append(heading)
                    }
                }

                // Process verses
                for verseFile in chapterFile.verses {
                    // Convert footnotes
                    var footnotes: [VerseFootnote]? = nil
                    if let vf = verseFile.footnotes {
                        footnotes = vf.map { fn in
                            VerseFootnote(
                                id: fn.id,
                                type: fn.type,
                                content: fn.content
                            )
                        }
                    }

                    // Convert footnote refs
                    let footnoteRefs = verseFile.content.footnoteRefs

                    let verse = TranslationVerse(
                        translationId: file.meta.id,
                        ref: verseFile.ref,
                        book: bookFile.number,
                        chapter: chapterFile.chapter,
                        verse: verseFile.v,
                        text: verseFile.content.text,
                        annotations: verseFile.content.annotations,
                        footnotes: footnotes,
                        footnoteRefs: footnoteRefs,
                        paragraph: verseFile.paragraph ?? false,
                        poetry: verseFile.poetry
                    )
                    verses.append(verse)
                }
            }
        }

        // Batch import all data
        try database.importTranslation(translation, books: books, verses: verses, headings: headings)

        print("Imported translation schema: \(file.meta.name) with \(verses.count) verses, \(headings.count) headings")
    }

    /// Import a translation from a file URL (JSON format using translation_schema.json)
    func importTranslationFromFile(url: URL) async throws {
        let data = try Data(contentsOf: url)

        // Calculate file hash
        let hash = data.withUnsafeBytes { bytes in
            var hasher = Hasher()
            hasher.combine(bytes: bytes)
            return String(hasher.finalize())
        }

        // Import using the translation_schema.json format
        try await importTranslationSchemaModule(from: data, fileHash: hash)
    }

    // MARK: - Export to Cloud (for editable modules)

    /// Check if a module already exists for a given .lamp file URL
    func existingModuleName(for url: URL) -> String? {
        let moduleId = url.lastPathComponent.replacingOccurrences(of: ".lamp", with: "")
        if let existing = try? database.getModule(id: moduleId) {
            return existing.name ?? moduleId
        }
        if let existing = try? database.getTranslation(id: moduleId) {
            return existing.name
        }
        return nil
    }

    /// Import a .lamp module from a local file URL
    /// If cloud storage is available, also writes to cloud for sync
    func importModuleFromFile(url: URL, moduleType: ModuleType) async throws {
        // Read the compressed data
        let compressedData = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let moduleId = fileName.replacingOccurrences(of: ".lamp", with: "")

        // Decompress to temp file for import
        let decompressedData = try decompressZlib(compressedData)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try decompressedData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Calculate hash from compressed data
        let hash = compressedData.sha256Hash

        // Create the file info
        let fileInfo = ModuleFileInfo(
            id: moduleId,
            type: moduleType,
            filePath: fileName,
            fileHash: hash,
            modificationDate: Date()
        )

        // Create module metadata first
        if moduleType != .commentary {
            try await createModuleMetadata(id: moduleId, type: moduleType, hash: hash, tempURL: tempURL)
        }

        // Delete existing entries
        if moduleType == .translation {
            try database.deleteAllTranslationContent(translationId: moduleId)
            try database.deleteTranslation(id: moduleId)
        } else if moduleType == .commentary {
            if let existingModule = try database.getModule(id: moduleId), let seriesId = existingModule.seriesId {
                let modulesWithSeries = try database.getModulesForSeries(seriesId: seriesId)
                if modulesWithSeries.count <= 1 {
                    try database.deleteCommentarySeries(id: seriesId)
                }
            }
            try database.deleteAllEntriesForModule(moduleId: moduleId)
            try database.deleteModule(id: moduleId)
        } else {
            try database.deleteAllEntriesForModule(moduleId: moduleId)
        }

        // Import using ATTACH DATABASE
        try await importFromTempDatabase(tempURL: tempURL, fileInfo: fileInfo, type: moduleType)

        // If cloud storage is available, also write there for sync
        let storage = await MainActor.run { getStorage() }
        if await storage.isAvailable() {
            try await storage.writeModuleFile(type: moduleType, fileName: fileName, data: compressedData)
        }

        print("[ModuleSyncManager] Imported module from file: \(moduleId)")
    }

    /// Helper to import from a temp database file using ATTACH DATABASE
    private func importFromTempDatabase(tempURL: URL, fileInfo: ModuleFileInfo, type: ModuleType) async throws {
        let dbAlias = "import_\(UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: ""))"

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE '\(tempURL.path)' AS \(dbAlias)")

            do {
                try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

                switch type {
                case .dictionary:
                    try db.execute(sql: """
                        INSERT INTO dictionary_entries (id, module_id, key, lemma, transliteration, pronunciation, senses_json, metadata_json)
                        SELECT id, module_id, key, lemma, transliteration, pronunciation, senses_json, metadata_json
                        FROM \(dbAlias).dictionary_entries
                        """)

                case .notes:
                    try db.execute(sql: """
                        INSERT INTO note_entries (id, module_id, verse_id, book, chapter, verse, title, content, verse_refs_json, last_modified)
                        SELECT id, module_id, verse_id, book, chapter, verse, title, content, verse_refs_json, last_modified
                        FROM \(dbAlias).note_entries
                        """)

                case .devotional:
                    // Check source schema
                    let devCols = try Row.fetchAll(db, sql: "PRAGMA \(dbAlias).table_info(devotional_entries)")
                    let devColNames = Set(devCols.compactMap { $0["name"] as String? })

                    if devColNames.contains("content_json") {
                        // Check if media_json column exists in source
                        let hasMediaJson = devColNames.contains("media_json")
                        let mediaJsonInsert = hasMediaJson ? ", media_json" : ""
                        let mediaJsonSelect = hasMediaJson ? ", media_json" : ""

                        try db.execute(sql: """
                            INSERT INTO devotional_entries
                            (id, module_id, title, subtitle, author, date, tags, category,
                             series_id, series_name, series_order, key_scriptures_json,
                             summary_json, content_json, footnotes_json, related_ids,
                             created, last_modified, search_text\(mediaJsonInsert))
                            SELECT id, module_id, title, subtitle, author, date, tags, category,
                                   series_id, series_name, series_order, key_scriptures_json,
                                   summary_json, content_json, footnotes_json, related_ids,
                                   created, last_modified, search_text\(mediaJsonSelect)
                            FROM \(dbAlias).devotional_entries
                            """)
                    } else {
                        // Legacy schema
                        try db.execute(sql: """
                            INSERT INTO devotional_entries
                            (id, module_id, title, date, tags, content_json, last_modified, search_text)
                            SELECT id, module_id, title, month_day, tags, content, last_modified, content
                            FROM \(dbAlias).devotional_entries
                            """)
                    }

                case .highlights:
                    // Import highlight sets first
                    try db.execute(sql: """
                        INSERT INTO highlight_sets (id, module_id, name, description, translation_id, created, last_modified)
                        SELECT id, module_id, name, description, translation_id, created, last_modified
                        FROM \(dbAlias).highlight_sets
                        """)
                    // Import highlights
                    try db.execute(sql: """
                        INSERT INTO highlights (id, set_id, ref, sc, ec, style, color)
                        SELECT id, set_id, ref, sc, ec, style, color
                        FROM \(dbAlias).highlights
                        """)

                default:
                    break
                }

                try db.execute(sql: "COMMIT")
            } catch {
                try? db.execute(sql: "ROLLBACK")
                try db.execute(sql: "DETACH DATABASE \(dbAlias)")
                throw error
            }

            try db.execute(sql: "DETACH DATABASE \(dbAlias)")
        }
    }

    /// Export an editable module to iCloud
    func exportModule(id: String) async throws {
        guard let module = try database.getModule(id: id) else {
            throw ModuleSyncError.moduleNotFound(id)
        }

        guard module.isEditable else {
            throw ModuleSyncError.moduleNotEditable(id)
        }

        guard await getStorage().isAvailable() else {
            throw ModuleStorageError.notAvailable
        }

        let data: Data
        let localEntryCount: Int
        switch module.type {
        case .notes:
            let entries = try database.read { db in
                try NoteEntry.filter(Column("module_id") == module.id).fetchAll(db)
            }
            localEntryCount = entries.count
            data = try exportNoteModuleToSQLite(module)
        case .devotional:
            let entries = try database.read { db in
                try DevotionalEntry.filter(Column("module_id") == module.id).fetchAll(db)
            }
            localEntryCount = entries.count
            data = try exportDevotionalModuleToSQLite(module)
        case .highlights:
            // For highlights, use the dedicated import/export manager
            let sets = try database.getHighlightSets(forModule: module.id)
            localEntryCount = sets.isEmpty ? 0 : try sets.reduce(0) { sum, set in
                sum + (try database.getHighlightCount(setId: set.id))
            }
            data = try exportHighlightModuleToSQLite(module)
        case .translation, .dictionary, .commentary, .plan, .quiz:
            throw ModuleSyncError.moduleNotEditable(id)
        }

        let fileName = "\(id).lamp"

        // SAFEGUARD: Don't overwrite cloud data with empty local data
        if localEntryCount == 0 {
            // Check both SQLite and legacy JSON formats
            let sqliteFileName = "\(id).lamp"
            let jsonFileName = "\(id).json"

            // Check SQLite format first
            if let cloudData = try? await getStorage().readModuleFile(type: module.type, fileName: sqliteFileName) {
                let cloudEntryCount = try? countEntriesInCloudSQLite(cloudData, type: module.type)
                if let count = cloudEntryCount, count > 0 {
                    print("[Export] BLOCKED: Refusing to overwrite \(count) cloud entries with empty local data for \(id)")
                    return
                }
            }
            // Also check legacy JSON format
            else if let cloudData = try? await getStorage().readModuleFile(type: module.type, fileName: jsonFileName) {
                let decoder = JSONDecoder()
                if module.type == .notes,
                   let cloudFile = try? decoder.decode(NoteModuleFile.self, from: cloudData),
                   !cloudFile.entries.isEmpty {
                    print("[Export] BLOCKED: Refusing to overwrite \(cloudFile.entries.count) cloud entries with empty local data for \(id)")
                    return
                }
                if module.type == .devotional,
                   let cloudFile = try? decoder.decode(DevotionalModuleFile.self, from: cloudData),
                   !cloudFile.entries.isEmpty {
                    print("[Export] BLOCKED: Refusing to overwrite \(cloudFile.entries.count) cloud entries with empty local data for \(id)")
                    return
                }
            }
        }

        try await getStorage().writeModuleFile(type: module.type, fileName: fileName, data: data)

        // Update hash after export
        if let newHash = try await getStorage().getFileHash(type: module.type, fileName: fileName) {
            var updatedModule = module
            updatedModule.fileHash = newHash
            updatedModule.lastSynced = Int(Date().timeIntervalSince1970)
            try database.saveModule(updatedModule)
        }

        // Sync media files for devotional modules
        if module.type == .devotional {
            try await uploadDevotionalMedia(moduleId: module.id)
        }
    }

    private func exportNoteModule(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == module.id)
                .fetchAll(db)
        }

        let moduleFile = NoteModuleFile(
            id: module.id,
            name: module.name,
            description: module.description,
            author: module.author,
            version: module.version,
            type: "notes",
            isEditable: module.isEditable,
            entries: entries.map { entry in
                NoteEntryFile(
                    id: entry.id,
                    verseId: entry.verseId,
                    title: entry.title,
                    content: entry.content,
                    verseRefs: entry.verseRefs?.map { VerseRef(sv: $0, ev: nil) },
                    lastModified: entry.lastModified,
                    footnotes: entry.footnotes
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(moduleFile)
    }

    private func exportDevotionalModule(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == module.id)
                .fetchAll(db)
        }

        // Convert DevotionalEntry back to Devotional for export
        let devotionals = entries.compactMap { $0.toDevotional() }

        let moduleFile = DevotionalModuleFile(
            id: module.id,
            name: module.name,
            description: module.description,
            author: module.author,
            version: module.version,
            isEditable: module.isEditable,
            entries: devotionals
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(moduleFile)
    }

    // MARK: - SQLite Export Functions

    /// Export notes module to SQLite+zlib format
    private func exportNoteModuleToSQLite(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == module.id)
                .fetchAll(db)
        }

        // Create temporary database file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Create and populate the SQLite database
        let exportQueue = try DatabaseQueue(path: tempURL.path)
        try exportQueue.write { db in
            // Create note_entries table with full schema
            try db.execute(sql: """
                CREATE TABLE note_entries (
                    id TEXT PRIMARY KEY,
                    module_id TEXT NOT NULL,
                    verse_id INTEGER NOT NULL,
                    book INTEGER NOT NULL,
                    chapter INTEGER NOT NULL,
                    verse INTEGER NOT NULL,
                    title TEXT,
                    content TEXT NOT NULL,
                    verse_refs_json TEXT,
                    last_modified INTEGER,
                    footnotes_json TEXT,
                    search_text TEXT,
                    record_change_tag TEXT
                )
            """)

            // Create module_meta table for module info
            try db.execute(sql: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    author TEXT,
                    version TEXT,
                    is_editable INTEGER DEFAULT 1
                )
            """)

            // Insert module metadata
            try db.execute(
                sql: "INSERT INTO module_meta (id, name, description, author, version, is_editable) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [module.id, module.name, module.description, module.author, module.version, module.isEditable ? 1 : 0]
            )

            // Insert all note entries
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO note_entries
                        (id, module_id, verse_id, book, chapter, verse, title, content, verse_refs_json, last_modified, footnotes_json, search_text, record_change_tag)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        entry.id,
                        entry.moduleId,
                        entry.verseId,
                        entry.book,
                        entry.chapter,
                        entry.verse,
                        entry.title,
                        entry.content,
                        entry.verseRefsJson,
                        entry.lastModified,
                        entry.footnotesJson,
                        entry.searchText,
                        entry.recordChangeTag
                    ]
                )
            }
        }

        // Read the SQLite file and compress with zlib
        let sqliteData = try Data(contentsOf: tempURL)
        guard let compressedData = try? (sqliteData as NSData).compressed(using: .zlib) as Data else {
            throw ModuleSyncError.exportFailed("Failed to compress SQLite data")
        }

        return compressedData
    }

    /// Export devotionals module to SQLite+zlib format
    private func exportDevotionalModuleToSQLite(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == module.id)
                .fetchAll(db)
        }

        // Create temporary database file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Create and populate the SQLite database
        let exportQueue = try DatabaseQueue(path: tempURL.path)
        try exportQueue.write { db in
            // Create devotional_entries table with full schema
            try db.execute(sql: """
                CREATE TABLE devotional_entries (
                    id TEXT PRIMARY KEY,
                    module_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    author TEXT,
                    date TEXT,
                    tags TEXT,
                    category TEXT,
                    series_id TEXT,
                    series_name TEXT,
                    series_order INTEGER,
                    key_scriptures_json TEXT,
                    summary_json TEXT,
                    content_json TEXT NOT NULL,
                    footnotes_json TEXT,
                    media_json TEXT,
                    related_ids TEXT,
                    created INTEGER NOT NULL,
                    last_modified INTEGER,
                    search_text TEXT,
                    record_change_tag TEXT
                )
            """)

            // Create module_meta table for module info
            try db.execute(sql: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    author TEXT,
                    version TEXT,
                    is_editable INTEGER DEFAULT 1
                )
            """)

            // Insert module metadata
            try db.execute(
                sql: "INSERT INTO module_meta (id, name, description, author, version, is_editable) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [module.id, module.name, module.description, module.author, module.version, module.isEditable ? 1 : 0]
            )

            // Insert all devotional entries
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO devotional_entries
                        (id, module_id, title, subtitle, author, date, tags, category, series_id, series_name, series_order,
                         key_scriptures_json, summary_json, content_json, footnotes_json, media_json, related_ids, created, last_modified, search_text, record_change_tag)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        entry.id,
                        entry.moduleId,
                        entry.title,
                        entry.subtitle,
                        entry.author,
                        entry.date,
                        entry.tags,
                        entry.category,
                        entry.seriesId,
                        entry.seriesName,
                        entry.seriesOrder,
                        entry.keyScripturesJson,
                        entry.summaryJson,
                        entry.contentJson,
                        entry.footnotesJson,
                        entry.mediaJson,
                        entry.relatedIds,
                        entry.created,
                        entry.lastModified,
                        entry.searchText,
                        entry.recordChangeTag
                    ]
                )
            }
        }

        // Read the SQLite file and compress with zlib
        let sqliteData = try Data(contentsOf: tempURL)
        guard let compressedData = try? (sqliteData as NSData).compressed(using: .zlib) as Data else {
            throw ModuleSyncError.exportFailed("Failed to compress SQLite data")
        }

        return compressedData
    }

    /// Export highlights module to SQLite+zlib format
    private func exportHighlightModuleToSQLite(_ module: Module) throws -> Data {
        // Get highlight sets for this module
        let sets = try database.getHighlightSets(forModule: module.id)

        guard let set = sets.first else {
            throw ModuleSyncError.exportFailed("No highlight set found for module")
        }

        // Get all highlights for the set
        let highlights = try database.getAllHighlights(setId: set.id)

        // Create temporary database file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Create and populate the SQLite database
        let exportQueue = try DatabaseQueue(path: tempURL.path)
        try exportQueue.write { db in
            // Create highlight_meta table (compact export format)
            try db.execute(sql: """
                CREATE TABLE highlight_meta (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    translation_id TEXT NOT NULL,
                    created INTEGER,
                    last_modified INTEGER
                )
            """)

            // Create highlights table
            try db.execute(sql: """
                CREATE TABLE highlights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ref INTEGER NOT NULL,
                    sc INTEGER NOT NULL,
                    ec INTEGER NOT NULL,
                    style INTEGER DEFAULT 0,
                    color TEXT
                )
            """)

            // Insert highlight set metadata
            try db.execute(
                sql: "INSERT INTO highlight_meta (id, name, description, translation_id, created, last_modified) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [set.id, set.name, set.description, set.translationId, set.created, set.lastModified]
            )

            // Insert all highlights
            for highlight in highlights {
                try db.execute(
                    sql: "INSERT INTO highlights (ref, sc, ec, style, color) VALUES (?, ?, ?, ?, ?)",
                    arguments: [highlight.ref, highlight.sc, highlight.ec, highlight.style, highlight.color]
                )
            }
        }

        // Read the SQLite file and compress with zlib
        let sqliteData = try Data(contentsOf: tempURL)
        guard let compressedData = try? (sqliteData as NSData).compressed(using: .zlib) as Data else {
            throw ModuleSyncError.exportFailed("Failed to compress SQLite data")
        }

        return compressedData
    }

    /// Count entries in a cloud SQLite file (for safeguard check)
    private func countEntriesInCloudSQLite(_ compressedData: Data, type: ModuleType) throws -> Int {
        // Decompress the data
        guard let decompressedData = try? (compressedData as NSData).decompressed(using: .zlib) as Data else {
            return 0
        }

        // Write to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try decompressedData.write(to: tempURL)

        // Open and count entries
        let queue = try DatabaseQueue(path: tempURL.path)
        return try queue.read { db in
            switch type {
            case .notes:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_entries") ?? 0
            case .devotional:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM devotional_entries") ?? 0
            case .highlights:
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM highlights") ?? 0
            default:
                return 0
            }
        }
    }

    // MARK: - Create Default Notes Module

    /// Create the default "My Notes" module if it doesn't exist
    func ensureDefaultNotesModule() async throws {
        print("[Notes] ensureDefaultNotesModule starting...")

        // First sync notes from iCloud to get any existing notes
        try await syncModuleType(.notes)
        print("[Notes] syncModuleType(.notes) completed")

        // Now check if we have any notes modules after sync
        let notesModules = try database.getAllModules(type: .notes)
        print("[Notes] Found \(notesModules.count) notes modules: \(notesModules.map { $0.id })")

        if notesModules.isEmpty {
            let defaultModule = Module(
                id: "notes",
                type: .notes,
                name: "My Notes",
                description: "Personal Bible study notes",
                filePath: "notes.lamp",
                isEditable: true,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            try database.saveModule(defaultModule)

            // Export empty module to iCloud
            if await getStorage().isAvailable() {
                try await exportModule(id: defaultModule.id)
            }
        }
    }

    // MARK: - Save Note Entry (with auto-export)

    /// Save a note entry and export to iCloud
    func saveNote(_ entry: NoteEntry) async throws {
        try database.saveNoteEntry(entry)
        try await exportModule(id: entry.moduleId)
    }

    /// Delete a note entry and export to iCloud
    func deleteNote(id: String, moduleId: String) async throws {
        try database.deleteNoteEntry(id: id)
        try await exportModule(id: moduleId)
    }

    // MARK: - Save Devotional Entry (with auto-export)

    /// Save a devotional and export to iCloud
    func saveDevotional(_ devotional: Devotional, moduleId: String) async throws {
        var mutableDevotional = devotional
        mutableDevotional.meta.lastModified = Int(Date().timeIntervalSince1970)
        let entry = DevotionalEntry(from: mutableDevotional, moduleId: moduleId)

        // Local save first - this must complete
        try database.saveDevotionalEntry(entry)

        // Cloud export in detached task so it continues even if caller is cancelled
        let modId = moduleId
        Task.detached {
            do {
                try await self.exportModule(id: modId)
            } catch {
                print("[ModuleSyncManager] Background export failed: \(error)")
            }
        }
    }

    /// Save a devotional entry directly and export to iCloud
    func saveDevotionalEntry(_ entry: DevotionalEntry) async throws {
        try database.saveDevotionalEntry(entry)
        try await exportModule(id: entry.moduleId)
    }

    /// Delete a devotional entry and export to iCloud
    func deleteDevotional(id: String, moduleId: String) async throws {
        try database.deleteDevotionalEntry(id: id)
        try await exportModule(id: moduleId)
    }

    // MARK: - Create Default Devotionals Module

    /// Track if we've already synced devotionals this session
    private static var hasInitialDevotionalSync = false

    /// Create the default "devotionals" module if it doesn't exist
    func ensureDefaultDevotionalsModule() async throws {
        // Only sync from cloud once per session to avoid overwriting local changes
        // that haven't been uploaded yet
        if !Self.hasInitialDevotionalSync {
            Self.hasInitialDevotionalSync = true
            try await syncModuleType(.devotional)
        }

        // Now check if we have any devotional modules
        let devotionalModules = try database.getAllModules(type: .devotional)

        // Check if user-editable devotionals module exists
        let hasEditableModule = devotionalModules.contains { $0.isEditable }

        if !hasEditableModule {
            let defaultModule = Module(
                id: "devotionals",
                type: .devotional,
                name: "My Devotionals",
                description: "Personal devotional writings",
                filePath: "devotionals.lamp",
                isEditable: true,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            try database.saveModule(defaultModule)

            // Export empty module to iCloud
            if await getStorage().isAvailable() {
                try await exportModule(id: defaultModule.id)
            }
        }
    }

    // MARK: - Zlib Decompression

    private func decompressZlib(_ data: Data) throws -> Data {
        // Use Foundation's built-in zlib decompression (iOS 13+)
        print("Attempting to decompress \(data.count) bytes...")

        do {
            let decompressedData = try (data as NSData).decompressed(using: .zlib) as Data
            print("Successfully decompressed to \(decompressedData.count) bytes")
            return decompressedData
        } catch {
            print("Decompression error: \(error)")
            throw ModuleSyncError.importFailed("Failed to decompress zlib data: \(error.localizedDescription)")
        }
    }

    // MARK: - Devotional Media Sync

    /// Upload all media files for a devotional module to the sync provider
    func uploadDevotionalMedia(moduleId: String) async throws {
        let storage = await getStorage()
        guard await storage.isAvailable() else {
            print("[MediaSync] Sync provider not available")
            return
        }

        // Get all devotional entries for this module that have media
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("media_json") != nil)
                .fetchAll(db)
        }

        print("[MediaSync] Found \(entries.count) entries with media for module \(moduleId)")

        for entry in entries {
            guard let mediaJson = entry.mediaJson,
                  let data = mediaJson.data(using: .utf8),
                  let mediaRefs = try? JSONDecoder().decode([DevotionalMediaReference].self, from: data) else {
                continue
            }

            for mediaRef in mediaRefs {
                // Get local file
                guard let localURL = DevotionalMediaStorage.shared.getMediaURL(
                    for: mediaRef,
                    devotionalId: entry.id,
                    moduleId: moduleId
                ) else {
                    print("[MediaSync] Local file not found: \(mediaRef.filename)")
                    continue
                }

                // Upload to remote
                let remotePath = "DevotionalMedia/\(moduleId)/\(entry.id)/\(mediaRef.filename)"
                do {
                    let fileData = try Data(contentsOf: localURL)
                    try await storage.writeFile(path: remotePath, data: fileData)
                    print("[MediaSync] Uploaded: \(remotePath)")
                } catch {
                    print("[MediaSync] Failed to upload \(remotePath): \(error)")
                }
            }
        }
    }

    /// Download all media files for a devotional module from the sync provider
    func downloadDevotionalMedia(moduleId: String) async throws {
        let storage = await getStorage()
        guard await storage.isAvailable() else {
            print("[MediaSync] Sync provider not available")
            return
        }

        // Get all devotional entries for this module that have media
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("media_json") != nil)
                .fetchAll(db)
        }

        print("[MediaSync] Found \(entries.count) entries with media for module \(moduleId)")

        for entry in entries {
            guard let mediaJson = entry.mediaJson,
                  let data = mediaJson.data(using: .utf8),
                  let mediaRefs = try? JSONDecoder().decode([DevotionalMediaReference].self, from: data) else {
                continue
            }

            for mediaRef in mediaRefs {
                // Ensure local directory exists
                try DevotionalMediaStorage.shared.ensureMediaDirectory(
                    devotionalId: entry.id,
                    moduleId: moduleId
                )

                let localURL = DevotionalMediaStorage.shared.expectedMediaURL(
                    for: mediaRef,
                    devotionalId: entry.id,
                    moduleId: moduleId
                )

                // Skip if already exists locally
                if FileManager.default.fileExists(atPath: localURL.path) {
                    print("[MediaSync] Already exists: \(mediaRef.filename)")
                    continue
                }

                // Download from remote
                let remotePath = "DevotionalMedia/\(moduleId)/\(entry.id)/\(mediaRef.filename)"
                do {
                    let fileData = try await storage.readFile(path: remotePath)
                    try fileData.write(to: localURL)
                    print("[MediaSync] Downloaded: \(remotePath)")
                } catch {
                    print("[MediaSync] Failed to download \(remotePath): \(error)")
                }
            }
        }
    }
}

// MARK: - Sync Errors

enum ModuleSyncError: Error, LocalizedError {
    case moduleNotFound(String)
    case moduleNotEditable(String)
    case importFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .moduleNotFound(let id):
            return "Module not found: \(id)"
        case .moduleNotEditable(let id):
            return "Module is not editable: \(id)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        }
    }
}

// MARK: - Data SHA256 Extension

import CommonCrypto

fileprivate extension Data {
    var sha256Hash: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
