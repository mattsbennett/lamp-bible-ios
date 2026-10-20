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
import LampCore
import LampModuleKit

class ModuleSyncManager: ObservableObject {
    static let shared = ModuleSyncManager()

    /// Get the explicitly configured remote storage provider.
    @MainActor
    func getStorage() -> ModuleStorage? {
        SyncCoordinator.shared.activeStorage
    }

    private let database = ModuleDatabase.shared

    /// One pass at a time, archive or library.
    var isSyncing = false
    private let initialDevotionalSync = LampSyncOnce()

    /// Pending note conflicts that need user resolution
    @Published var pendingConflicts: [NoteConflict] = []

    /// Module ID for pending note conflicts
    @Published var conflictModuleId: String? = nil

    /// Pending devotional conflicts that need user resolution
    @Published var pendingDevotionalConflicts: [DevotionalConflict] = []

    /// Module ID for pending devotional conflicts
    @Published var devotionalConflictModuleId: String? = nil

    private init() {
        do {
            // Before anyone is shown them: a stored conflict whose two sides
            // say the same thing has nothing to choose.
            try dropSettledPendingConflicts()
            if let notes = try database.firstPendingModuleConflicts(type: .notes, as: NoteConflict.self) {
                pendingConflicts = notes.conflicts
                conflictModuleId = notes.moduleId
            }
            if let devotionals = try database.firstPendingModuleConflicts(type: .devotional, as: DevotionalConflict.self) {
                pendingDevotionalConflicts = devotionals.conflicts
                devotionalConflictModuleId = devotionals.moduleId
            }
        } catch {
            print("[Sync] Failed to restore pending module conflicts: \(error)")
        }
    }

    func reloadPendingModuleConflicts() throws {
        try dropSettledPendingConflicts()
        let notes = try database.firstPendingModuleConflicts(type: .notes, as: NoteConflict.self)
        let devotionals = try database.firstPendingModuleConflicts(type: .devotional, as: DevotionalConflict.self)
        DispatchQueue.main.async {
            self.pendingConflicts = notes?.conflicts ?? []
            self.conflictModuleId = notes?.moduleId
            self.pendingDevotionalConflicts = devotionals?.conflicts ?? []
            self.devotionalConflictModuleId = devotionals?.moduleId
        }
    }

    // MARK: - Availability

    /// Check if configured storage is available
    func isAvailable() async -> Bool {
        guard let storage = await getStorage() else { return false }
        return await storage.isAvailable()
    }

    struct PortableArchiveModuleState: Codable {
        let path: String
        let id: String
        let type: ModuleType
        let digest: String
    }

    /// What the last archive import installed, as an earlier version of the
    /// app recorded it. The library pass still reads it: the revision says
    /// cheaply whether an unmoved archive is still there, and the digests
    /// spare the first pass reinstalling what the archive installed.
    struct PortableArchiveImportState: Codable {
        let source: String
        var revision: String?
        let modules: [PortableArchiveModuleState]
    }

    static let portableArchiveImportStateKey = "ModuleSyncManager.portableArchiveImportState.v2"

    func moduleType(forDocumentAt url: URL) throws -> ModuleType {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            _ = try BookJSONImportDescriptor.decode(from: data)
            return .book
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try LampZlib.decompress(data, to: tempURL)
        } catch {
            throw ModuleSyncError.importFailed("Failed to decompress the .lamp module.")
        }

        let queue = try DatabaseQueue(path: tempURL.path)
        let tables = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))
        }
        guard let type = ModuleType.detected(fromTableNames: tables) else {
            throw ModuleSyncError.importFailed("Could not determine the module type.")
        }
        return type
    }

    func existingModuleName(forDocumentAt url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "json" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let descriptor = try BookJSONImportDescriptor.decode(from: Data(contentsOf: url))
            return try database.getModule(id: descriptor.id)?.name
                ?? database.getBookModule(id: descriptor.id)?.title
        }
        return existingModuleName(for: url)
    }

    func importModuleDocumentFromFile(url: URL, moduleType: ModuleType) async throws {
        if url.pathExtension.lowercased() == "json" {
            guard moduleType == .book else {
                throw ModuleSyncError.importFailed("Only book modules can currently be imported directly from JSON.")
            }
            try await importBookJSONFromFile(url: url)
        } else {
            try await importModuleFromFile(url: url, moduleType: moduleType)
        }
    }

    private func importBookJSONFromFile(url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let descriptor = try BookJSONImportDescriptor.decode(from: data)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-book-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let lampURL = temporaryDirectory
            .appendingPathComponent(descriptor.id)
            .appendingPathExtension("lamp")
        let result = try LampModuleCompiler().compile(
            data: data,
            sourceFilename: url.lastPathComponent,
            destinationURL: lampURL
        )
        guard result.kind == .book else {
            throw ModuleSyncError.importFailed("The selected JSON document is not a book module.")
        }

        try await importModuleFromFile(url: lampURL, moduleType: .book)
        try ModuleMediaStorage.shared.importMediaFromBundle(
            bundleMediaDir: url.deletingLastPathComponent(),
            mediaRefs: descriptor.mediaReferences,
            moduleId: descriptor.id
        )
    }

    func importRemoteModuleSnapshot(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        snapshot: LampSyncRemoteFile,
        storage: ModuleStorage
    ) async throws {
        let pairedInfo = ModuleFileInfo(
            id: fileInfo.id,
            type: type,
            filePath: fileInfo.filePath,
            fileHash: snapshot.revision,
            modificationDate: fileInfo.modificationDate
        )
        // Check file extension to determine import method
        let lowercasedPath = fileInfo.filePath.lowercased()
        let isCompressedDb = lowercasedPath.hasSuffix(".lamp")
            || lowercasedPath.hasSuffix(".db.zlib")
        let fileExtension = (fileInfo.filePath as NSString).pathExtension.lowercased()

        // Only module files the library holds, one per module: a .lamp, or
        // the uncompressed SQLite an import may hand over.
        guard fileExtension == "db" || isCompressedDb else {
            throw ModuleSyncError.importFailed("Not a module file: \(fileInfo.filePath)")
        }
        try validateRemoteSQLiteIdentity(
            fileInfo: pairedInfo, type: type, data: snapshot.data
        )
        try await importModuleFromSQLite(
            fileInfo: pairedInfo,
            type: type,
            compressedData: snapshot.data,
            mediaStorage: storage
        )
    }

    private func validateRemoteSQLiteIdentity(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        data: Data
    ) throws {
        let kind = type
        let descriptor = try LampPortableModuleInspector.inspectRemote(
            data: data, filename: fileInfo.filePath,
            fallbackID: fileInfo.id, expectedKind: kind
        )
        guard LampSyncModuleFiles.matchesContentIdentity(
                listedID: fileInfo.id,
                contentID: descriptor.id,
                isNotes: type == .notes
              ) else {
            throw ModuleSyncError.importFailed(
                "Remote module \(fileInfo.filePath) contains a different module identity"
            )
        }
    }

    /// Imports module bytes through the same compatibility path regardless of
    /// whether they came from remote storage or a user-selected local file.
    private func importModuleFromSQLite(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        compressedData data: Data,
        mediaStorage: ModuleStorage?
    ) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")

        // Decompress if it's a compressed file (.lamp or .db.zlib)
        let lowercasedPath = fileInfo.filePath.lowercased()
        if lowercasedPath.hasSuffix(".lamp") || lowercasedPath.hasSuffix(".db.zlib") {
            try unpackModule(data, to: tempURL)
        } else {
            try data.write(to: tempURL)
        }

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let portableKind = type
        try LampPortableModuleInspector.validateOwnership(
            databaseURL: tempURL, expectedID: fileInfo.id, kind: portableKind
        )

        // Editable modules need reconciliation before any local rows are removed.
        if type == .notes {
            try await importNoteModuleFromSQLite(
                fileInfo: fileInfo,
                tempURL: tempURL
            )
            return
        }
        if type == .devotional {
            try await importDevotionalModuleFromSQLite(
                fileInfo: fileInfo,
                tempURL: tempURL
            )
            if let mediaStorage {
                try await downloadDevotionalMedia(moduleId: fileInfo.id, from: mediaStorage)
            }
            return
        }
        if type == .highlights,
           try shouldPreserveLocalHighlights(moduleId: fileInfo.id, tempURL: tempURL) {
            print("[HighlightSync] Preserving newer local highlight set \(fileInfo.id)")
            return
        }

        // Use ATTACH DATABASE for fast bulk import
        // Use a unique alias to avoid conflicts with concurrent imports
        let dbAlias = "import_\(UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: ""))"

        do {
            // Attach before the transaction and detach after it. A source
            // queried during the copy remains locked until the commit.
            try database.writeWithoutTransaction { db in
                // Attach the module database with unique alias
                try db.execute(sql: "ATTACH DATABASE '\(tempURL.path)' AS \(dbAlias)")

                do {
                    // Wrap the actual inserts in a transaction for performance
                    try db.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

                    // Retire the previous module inside the same transaction
                    // as the replacement. A failed source copy rolls back both.
                    try prepareModuleReplacement(
                        id: fileInfo.id, type: type,
                        filePath: fileInfo.filePath, in: db
                    )

                    try copySQLiteModuleRows(
                        fileInfo: fileInfo, type: type, dbAlias: dbAlias, in: db
                    )
                    try saveImportedModuleMetadata(
                        fileInfo: fileInfo, type: type, dbAlias: dbAlias, in: db
                    )

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

        if type == .translation {
            PlanMetaDataCache.shared.invalidate()
        }

        // Clean up temp file only after all database operations complete
        try? FileManager.default.removeItem(at: tempURL)

        print("Imported \(type.rawValue) module \(fileInfo.id) from SQLite")

        // Download media files for devotional modules
        if type == .devotional, let mediaStorage {
            try await downloadDevotionalMedia(moduleId: fileInfo.id, from: mediaStorage)
        } else if type == .book, let mediaStorage {
            try await downloadBookMedia(moduleId: fileInfo.id, from: mediaStorage)
        }
    }

    /// Copy one validated source into the caller's active transaction.
    private func copySQLiteModuleRows(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        dbAlias: String,
        in db: Database
    ) throws {
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
            let commTables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type IN ('table', 'view')")
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

                    // Update shared series metadata without deleting
                    // other modules' foreign-key references.
                    try db.execute(sql: """
                        INSERT INTO commentary_series
                        (id, name, abbreviation, description, editor, publisher, testament, language, website,
                         editor_preface_json, introduction_json, abbreviations_json, bibliography_json, volumes_json)
                        SELECT id, name, abbreviation, description, editor, publisher, testament, language, website,
                               editor_preface_json, introduction_json, abbreviations_json, bibliography_json, volumes_json
                        FROM \(dbAlias).series_meta
                        WHERE id = ?
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            abbreviation = excluded.abbreviation,
                            description = excluded.description,
                            editor = excluded.editor,
                            publisher = excluded.publisher,
                            testament = excluded.testament,
                            language = excluded.language,
                            website = excluded.website,
                            editor_preface_json = excluded.editor_preface_json,
                            introduction_json = excluded.introduction_json,
                            abbreviations_json = excluded.abbreviations_json,
                            bibliography_json = excluded.bibliography_json,
                            volumes_json = excluded.volumes_json
                        """, arguments: [seriesId])

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
                        INSERT INTO commentary_books
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
                    INSERT INTO commentary_books
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

        case .book:
            let moduleColumns = LampPortableModuleInspector.bookModuleColumns
                .joined(separator: ", ")
            let sectionColumns = LampPortableModuleInspector.bookSectionColumns
                .joined(separator: ", ")
            try db.execute(sql: """
                INSERT INTO book_modules (\(moduleColumns))
                SELECT \(moduleColumns)
                FROM \(dbAlias).book_modules
                WHERE id = ?
                """, arguments: [fileInfo.id])

            // Compiler/bundler output stores parents before children.
            // Preserve that order so the self-referencing FK is valid.
            try db.execute(sql: """
                INSERT INTO book_sections (\(sectionColumns))
                SELECT \(sectionColumns)
                FROM \(dbAlias).book_sections
                WHERE module_id = ?
                ORDER BY rowid
                """, arguments: [fileInfo.id])

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
                    INSERT OR REPLACE INTO devotional_entries
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
                    INSERT OR REPLACE INTO devotional_entries
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
                INSERT OR REPLACE INTO note_entries
                (\(insertCols.joined(separator: ", ")))
                SELECT \(selectCols.joined(separator: ", "))
                FROM \(dbAlias).note_entries
                """)

        case .plan:
            // Check if this is a plan database with plan_meta and days tables
            let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type IN ('table', 'view')")
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
                // Both compiled plans and full GRDB exports use these content
                // columns. The local installation owns its path and revision.
                let now = Int(Date().timeIntervalSince1970)
                try db.execute(sql: """
                    INSERT INTO plans (id, name, description, author, full_description, duration, readings_per_day,
                        file_path, file_hash, last_synced, created_at, updated_at)
                    SELECT id, name, description, author, full_description, duration, readings_per_day,
                        ?, ?, ?, ?, ?
                    FROM \(dbAlias).plans
                    """, arguments: ["\(fileInfo.id).lamp", fileInfo.fileHash, now, now, now])
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
            let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type IN ('table', 'view')")
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
                    INSERT INTO highlight_sets (id, module_id, name, description, translation_id, created, last_modified)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [setId, fileInfo.id, setName, metaRow["description"] as String?, translationId,
                                     (metaRow["created"] as Int?) ?? now, (metaRow["last_modified"] as Int?) ?? now])

                // Copy highlights
                try db.execute(sql: """
                    INSERT INTO highlights (set_id, ref, sc, ec, style, color)
                    SELECT ?, ref, sc, ec, style, color
                    FROM \(dbAlias).highlights
                    """, arguments: [setId])

                // Copy themes if table exists
                if tableNames.contains("highlight_themes") {
                    let themeRows = try Row.fetchAll(db, sql: "SELECT * FROM \(dbAlias).highlight_themes")
                    for row in themeRows {
                        let color: String = row["color"] ?? ""
                        let style: Int = row["style"] ?? 0
                        let name: String = row["name"] ?? ""
                        let desc: String? = row["description"]
                        let themeId = "\(setId)_\(color.uppercased())_\(style)"
                        try db.execute(sql: """
                            INSERT INTO highlight_themes (id, set_id, color, style, name, description)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """, arguments: [themeId, setId, color.uppercased(), style, name, desc])
                    }
                }
            } else if tableNames.contains("highlight_sets") && tableNames.contains("highlights") {
                // Full GRDB schema - copy directly
                try db.execute(sql: """
                    INSERT INTO highlight_sets (id, module_id, name, description, translation_id, created, last_modified)
                    SELECT id, module_id, name, description, translation_id, created, last_modified
                    FROM \(dbAlias).highlight_sets
                    """)
                try db.execute(sql: """
                    INSERT INTO highlights (id, set_id, ref, sc, ec, style, color)
                    SELECT id, set_id, ref, sc, ec, style, color
                    FROM \(dbAlias).highlights
                    """)
            } else {
                throw ModuleSyncError.importFailed("Unknown highlights database schema")
            }

        case .quiz:
            // Copy quiz module metadata
            try db.execute(sql: """
                INSERT INTO quiz_modules (id, plan_id, name, description, questions_per_reading, age_groups_json)
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
            let tables = try Row.fetchAll(db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type IN ('table', 'view')")
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
    }

    /// Save registry metadata before the row-copy transaction commits, so a
    /// failed metadata write also restores the previous module and its rows.
    private func saveImportedModuleMetadata(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        dbAlias: String,
        in db: Database
    ) throws {
        let id = fileInfo.id
        let filePath = "\(id).lamp"
        let now = Int(Date().timeIntervalSince1970)
        switch type {
        case .dictionary:
            var name = id
            var description: String?
            var author: String?
            var version: String?
            var keyType: String?
            var seriesFull: String?
            var seriesAbbrev: String?
            do {
                let tables = Set(try String.fetchAll(
                    db, sql: "SELECT name FROM \(dbAlias).sqlite_master WHERE type IN ('table', 'view')"
                ))
                let table = tables.contains("module_meta") ? "module_meta"
                    : (tables.contains("module_metadata") ? "module_metadata" : nil)
                if let table, let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM \(dbAlias).\(table) WHERE id = ?",
                    arguments: [id]
                ) {
                    name = row["name"] ?? id
                    description = row["description"]
                    author = row["author"]
                    version = row["version"]
                    keyType = row["key_type"]
                    seriesFull = row["series_full"]
                    seriesAbbrev = row["series_abbrev"]
                }
            } catch {
                print("Could not read module metadata from source database for dictionary: \(error)")
            }
            if keyType == nil,
               let first = try DictionaryEntry
                .filter(Column("module_id") == id)
                .limit(1).fetchOne(db) {
                keyType = first.key.hasPrefix("H") || first.key.hasPrefix("G")
                    ? "strongs" : "word"
            }
            try Module(
                id: id, type: .dictionary, name: name,
                description: description, author: author, version: version,
                filePath: filePath, fileHash: fileInfo.fileHash,
                lastSynced: now, isEditable: false, keyType: keyType,
                seriesFull: seriesFull, seriesAbbrev: seriesAbbrev
            ).save(db)

        case .book:
            var name = id
            var description: String?
            var author: String?
            var version: String?
            var isEditable = false
            do {
                if let row = try Row.fetchOne(
                    db,
                    sql: "SELECT title, description, author, version, is_editable "
                        + "FROM \(dbAlias).book_modules WHERE id = ?",
                    arguments: [id]
                ) {
                    name = row["title"] ?? id
                    description = row["description"]
                    author = row["author"]
                    version = row["version"]
                    let editable: Int = row["is_editable"] ?? 0
                    isEditable = editable != 0
                }
            } catch {
                print("Could not read book metadata from source database: \(error)")
            }
            try Module(
                id: id, type: .book, name: name,
                description: description, author: author, version: version,
                filePath: filePath, fileHash: fileInfo.fileHash,
                lastSynced: now, isEditable: isEditable
            ).save(db)

        default:
            break
        }
    }

    private func prepareModuleReplacement(
        id: String,
        type: ModuleType,
        filePath: String,
        in db: Database
    ) throws {
        switch type {
        case .translation:
            try db.execute(sql: "DELETE FROM translation_headings WHERE translation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM translation_verses WHERE translation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM translation_books WHERE translation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM translations WHERE id = ?", arguments: [id])

        case .commentary:
            let oldSeriesID = try Module.fetchOne(db, key: id)?.seriesId
            let seriesMemberCount = try oldSeriesID.flatMap { seriesID in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM modules WHERE series_id = ?",
                    arguments: [seriesID]
                )
            } ?? 0
            try ModuleDatabase.deleteAllEntriesForModule(moduleId: id, in: db)
            try db.execute(sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM sync_pending_module_publications WHERE module_id = ?", arguments: [id])
            _ = try Module.deleteOne(db, key: id)
            if let oldSeriesID, seriesMemberCount <= 1 {
                try db.execute(sql: "DELETE FROM commentary_series WHERE id = ?", arguments: [oldSeriesID])
            }

        case .dictionary, .book:
            if try Module.fetchOne(db, key: id) == nil {
                try Module(
                    id: id, type: type, name: id, filePath: filePath,
                    fileHash: nil, isEditable: false
                ).save(db)
            }
            try ModuleDatabase.deleteAllEntriesForModule(moduleId: id, in: db)

        case .plan:
            try db.execute(sql: "DELETE FROM plan_days WHERE plan_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM plans WHERE id = ?", arguments: [id])
            try ModuleDatabase.deleteAllEntriesForModule(moduleId: id, in: db)

        case .highlights, .quiz:
            try ModuleDatabase.deleteAllEntriesForModule(moduleId: id, in: db)

        case .notes, .devotional:
            throw ModuleSyncError.importFailed("Editable modules require reconciliation")
        }
    }

    private func importNoteModuleFromSQLite(
        fileInfo: ModuleFileInfo,
        tempURL: URL
    ) async throws {
        let remoteQueue = try DatabaseQueue(path: tempURL.path)
        let remoteEntries = try await remoteQueue.read { db in
            try NoteEntry.fetchAll(db)
        }
        let metadata = try await editableModuleMetadata(
            id: fileInfo.id, type: .notes,
            hash: fileInfo.fileHash, tempURL: tempURL
        )
        let mergeResult = try database.write { db in
            let localEntries = try NoteEntry
                .filter(Column("module_id") == fileInfo.id)
                .fetchAll(db)
            let result = mergeNoteEntries(
                local: localEntries, cloud: remoteEntries, moduleId: fileInfo.id,
                deletions: try ModuleDatabase.personalDeletionLedger(in: db)
            )
            try saveEditableReconciliation(
                in: db, module: metadata, type: .notes,
                entries: result.entriesToSave, conflicts: result.conflicts,
                key: { $0.id }, keptLocal: result.needsPublish
            )
            return result
        }
        try reloadPendingModuleConflicts()

        print(
            "[NoteSync] SQLite merge: \(mergeResult.cloudMergeCount) remote, "
            + "\(mergeResult.localKeptCount) local, \(mergeResult.conflicts.count) conflicts"
        )
    }

    private func importDevotionalModuleFromSQLite(
        fileInfo: ModuleFileInfo,
        tempURL: URL
    ) async throws {
        let remoteQueue = try DatabaseQueue(path: tempURL.path)
        let remoteEntries = try await remoteQueue.read { db in
            try DevotionalEntry.fetchAll(db)
        }
        let metadata = try await editableModuleMetadata(
            id: fileInfo.id, type: .devotional,
            hash: fileInfo.fileHash, tempURL: tempURL
        )
        let mergeResult = try database.write { db in
            let localEntries = try DevotionalEntry
                .filter(Column("module_id") == fileInfo.id)
                .fetchAll(db)
            let result = try mergeDevotionalEntries(
                local: localEntries, cloud: remoteEntries, moduleId: fileInfo.id,
                deletions: try ModuleDatabase.personalDeletionLedger(in: db)
            )
            try saveEditableReconciliation(
                in: db, module: metadata, type: .devotional,
                entries: result.entriesToSave, conflicts: result.conflicts,
                key: { $0.id }, keptLocal: result.needsPublish
            )
            return result
        }
        try reloadPendingModuleConflicts()

        print(
            "[DevotionalSync] SQLite merge: \(mergeResult.cloudMergeCount) remote, "
            + "\(mergeResult.localKeptCount) local, \(mergeResult.conflicts.count) conflicts"
        )
    }

    private func saveEditableReconciliation<Entry: PersistableRecord, Conflict: Encodable>(
        in db: Database,
        module: Module,
        type: ModuleType,
        entries: [Entry],
        conflicts: [Conflict],
        key: (Conflict) -> String,
        keptLocal: Bool
    ) throws {
        let encoded = try conflicts.map { (key($0), try JSONEncoder().encode($0)) }
        try module.save(db)
        try ModuleDatabase.deleteAllEntriesForModule(moduleId: module.id, in: db)
        for entry in entries { try entry.insert(db) }
        if keptLocal {
            try db.execute(sql: """
                INSERT OR REPLACE INTO sync_pending_module_publications (module_id, type)
                VALUES (?, ?)
                """, arguments: [module.id, type.rawValue])
        }
        try db.execute(sql: """
            DELETE FROM sync_pending_module_conflicts WHERE module_id = ? AND type = ?
            """, arguments: [module.id, type.rawValue])
        for (entryKey, payload) in encoded {
            try db.execute(sql: """
                INSERT INTO sync_pending_module_conflicts (module_id, type, entry_key, payload)
                VALUES (?, ?, ?, ?)
                """, arguments: [module.id, type.rawValue, entryKey, payload])
        }
    }

    private func shouldPreserveLocalHighlights(
        moduleId: String,
        tempURL: URL
    ) throws -> Bool {
        guard let localSet = try database.getHighlightSets(forModule: moduleId).first else {
            return false
        }

        let remoteQueue = try DatabaseQueue(path: tempURL.path)
        let remoteModified = try remoteQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT last_modified FROM highlight_meta LIMIT 1"
            ) ?? 0
        }
        return localSet.lastModified >= remoteModified
    }

    private func editableModuleMetadata(
        id: String, type: ModuleType, hash: String?, tempURL: URL
    ) async throws -> Module {
        guard type == .notes || type == .devotional else {
            throw ModuleSyncError.importFailed("Expected editable SQLite module")
        }
        var name = id
        var description: String?
        var author: String?
        var version: String?
        var isEditable = true

        do {
            var config = Configuration()
            config.readonly = true
            let source = try DatabaseQueue(path: tempURL.path, configuration: config)
            try await source.read { db in
                let tables = Set(try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                ))
                let metaTable = tables.contains("module_meta") ? "module_meta" : "module_metadata"
                if tables.contains(metaTable), let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM \(metaTable) WHERE id = ?", arguments: [id]
                ) {
                    if let value: String = row["name"] { name = value }
                    description = row["description"]
                    author = row["author"]
                    version = row["version"]
                    if let value: Int = row["is_editable"] { isEditable = value == 1 }
                }
            }
        } catch {
            print("Could not read \(type.rawValue) metadata from temp database: \(error)")
        }

        return Module(
            id: id, type: type, name: name, description: description,
            author: author, version: version, filePath: "\(id).lamp",
            fileHash: hash, lastSynced: Int(Date().timeIntervalSince1970),
            isEditable: isEditable
        )
    }

    // MARK: - Commentary Import Helpers

    /// Merge local and cloud devotional entries with conflict detection
    private func mergeDevotionalEntries(
        local allLocal: [DevotionalEntry], cloud allCloud: [DevotionalEntry], moduleId: String,
        deletions: LampPersonalDeletionLedger
    ) throws -> DevotionalMergeResult {
        // A copy older than a recorded deletion, on either side, is gone.
        let isLive = { (entry: DevotionalEntry) in
            !deletions.isDeleted(.devotional, entry.id, itemModified: entry.lastModified)
        }
        let local = allLocal.filter(isLive)
        let cloud = allCloud.filter(isLive)
        let incomingByID = cloud.reduce(into: [String: DevotionalEntry]()) { result, entry in
            if result[entry.id] == nil { result[entry.id] = entry }
        }
        let migratedLocal = local.map { current -> DevotionalEntry in
            guard let incoming = incomingByID[current.id],
                  current.mediaJson == nil,
                  incoming.mediaJson != nil,
                  let markdown = LampPortableDevotionalMedia.plainMarkdown(
                    from: current.contentJson
                  ),
                  markdown == incoming.contentJson else { return current }
            var migrated = current
            migrated.contentJson = markdown
            migrated.mediaJson = incoming.mediaJson
            return migrated
        }
        let merged = LampSyncMerge.records(
            local: migratedLocal,
            incoming: cloud,
            key: { $0.id },
            modified: { $0.lastModified },
            sameContent: Self.sameDevotionalContent
        )
        let conflicts = try merged.conflicts.map { conflict -> DevotionalConflict in
            guard let local = conflict.local.toDevotional(),
                  let cloud = conflict.incoming.toDevotional() else {
                throw ModuleSyncError.importFailed("Cannot decode conflicting devotional \(conflict.key)")
            }
            return DevotionalConflict(id: conflict.key, localEntry: local, cloudEntry: cloud)
        }
        return DevotionalMergeResult(
            entriesToSave: merged.recordsToSave,
            conflicts: conflicts,
            cloudMergeCount: merged.incomingCount,
            localKeptCount: merged.localCount,
            deletedCount: (allLocal.count - local.count) + (allCloud.count - cloud.count)
        )
    }

    /// Result of a devotional sync merge operation
    struct DevotionalMergeResult {
        var entriesToSave: [DevotionalEntry]
        var conflicts: [DevotionalConflict]
        var cloudMergeCount: Int
        var localKeptCount: Int
        /// Copies dropped because they predate a recorded deletion.
        var deletedCount = 0
        /// The server copy differs from what this device now holds.
        var needsPublish: Bool { localKeptCount > 0 || deletedCount > 0 }
    }

    /// Merge local and cloud note entries with conflict detection
    private func mergeNoteEntries(
        local: [NoteEntry], cloud: [NoteEntry], moduleId: String,
        deletions: LampPersonalDeletionLedger
    ) -> NoteSyncMergeResult {
        // A copy older than a recorded deletion, on either side, is gone.
        let isLive = { (entry: NoteEntry) in
            !deletions.isDeleted(.note, entry.id, itemModified: entry.lastModified)
        }
        let liveLocal = local.filter(isLive)
        let liveCloud = cloud.filter(isLive)
        let merged = LampSyncMerge.records(
            local: liveLocal,
            incoming: liveCloud,
            key: { $0.verseId },
            modified: { $0.lastModified },
            sameContent: Self.sameNoteContent
        )
        return NoteSyncMergeResult(
            entriesToSave: merged.recordsToSave,
            conflicts: merged.conflicts.map {
                NoteConflict(
                    id: String($0.key),
                    verseId: $0.key,
                    localEntry: $0.local,
                    cloudEntry: $0.incoming
                )
            },
            cloudMergeCount: merged.incomingCount,
            localKeptCount: merged.localCount,
            deletedCount: (local.count - liveLocal.count) + (cloud.count - liveCloud.count)
        )
    }

    // MARK: - Comparing editable entries

    // JSON columns compare by value through core's LampSyncJSONComparison, the
    // rule the Mac's merges use too. The Mac writes object keys sorted and an
    // empty list as `[]`; this device writes keys in declaration order and
    // leaves an absent list nil. Compared as text, every note that crossed
    // between them looked edited on both sides at the same moment.

    /// Whether two copies of a note say the same thing.
    static func sameNoteContent(_ local: NoteEntry, _ cloud: NoteEntry) -> Bool {
        local.title == cloud.title
            && local.content == cloud.content
            && LampSyncJSONComparison.sameValue(local.verseRefsJson, cloud.verseRefsJson)
            && LampSyncJSONComparison.sameValue(local.footnotesJson, cloud.footnotesJson)
    }

    /// Whether two copies of a devotional say the same thing.
    static func sameDevotionalContent(_ local: DevotionalEntry, _ cloud: DevotionalEntry) -> Bool {
        local.title == cloud.title
            && local.subtitle == cloud.subtitle
            && local.author == cloud.author
            && local.date == cloud.date
            && local.tags == cloud.tags
            && local.category == cloud.category
            && local.seriesId == cloud.seriesId
            && local.seriesName == cloud.seriesName
            && local.seriesOrder == cloud.seriesOrder
            && LampSyncJSONComparison.sameValue(local.keyScripturesJson, cloud.keyScripturesJson)
            && LampSyncJSONComparison.sameValue(local.summaryJson, cloud.summaryJson)
            && LampSyncJSONComparison.sameValue(local.contentJson, cloud.contentJson)
            && LampSyncJSONComparison.sameValue(local.footnotesJson, cloud.footnotesJson)
            && LampSyncJSONComparison.sameValue(local.mediaJson, cloud.mediaJson)
            && local.relatedIds == cloud.relatedIds
    }

    /// Conflicts stored before the comparison above knew better: both sides
    /// say the same thing, so there is nothing for anyone to choose. They
    /// would otherwise stay until the remote file changed again, and block
    /// publishing the module meanwhile.
    private func dropSettledPendingConflicts() throws {
        if let notes = try database.firstPendingModuleConflicts(type: .notes, as: NoteConflict.self) {
            for conflict in notes.conflicts
            where Self.sameNoteContent(conflict.localEntry, conflict.cloudEntry) {
                _ = try database.removePendingModuleConflict(
                    moduleId: notes.moduleId, type: .notes, key: conflict.id
                )
            }
        }
        if let devotionals = try database.firstPendingModuleConflicts(
            type: .devotional, as: DevotionalConflict.self
        ) {
            for conflict in devotionals.conflicts where Self.sameDevotionalContent(
                DevotionalEntry(from: conflict.localEntry, moduleId: devotionals.moduleId),
                DevotionalEntry(from: conflict.cloudEntry, moduleId: devotionals.moduleId)
            ) {
                _ = try database.removePendingModuleConflict(
                    moduleId: devotionals.moduleId, type: .devotional, key: conflict.id
                )
            }
        }
    }

    /// Resolve a conflict with user's choice
    func resolveConflict(_ conflict: NoteConflict, resolution: ConflictResolution) {
        guard let moduleId = conflictModuleId else { return }

        do {
            guard try database.pendingModuleConflictExists(
                moduleId: moduleId, type: .notes, key: conflict.id
            ) else { return }
            guard let resolvedTimestamp = LampSyncMerge.resolutionTimestamp(
                localModified: conflict.localEntry.lastModified,
                incomingModified: conflict.cloudEntry.lastModified,
                now: Int(Date().timeIntervalSince1970)
            ) else { throw SyncError.conflictDetected }
            switch resolution {
            case .keepLocal:
                var entry = conflict.localEntry
                entry.lastModified = resolvedTimestamp
                try database.saveNoteEntry(entry)

            case .keepCloud:
                var entry = conflict.cloudEntry
                entry.id = conflict.localEntry.id
                entry.lastModified = resolvedTimestamp
                try database.saveNoteEntry(entry)

            case .keepBoth:
                // Notes merge by verse ID, so retain both texts in one note.
                // A second row for the same verse would be dropped next pull.
                let localFootnotes = conflict.localEntry.footnotes ?? []
                let localFootnoteIDs = Set(localFootnotes.map(\.id))
                let cloudFootnotes = (conflict.cloudEntry.footnotes ?? []).map { footnote in
                    var copy = footnote
                    if localFootnoteIDs.contains(copy.id) {
                        copy.id = "cloud:\(UUID().uuidString)"
                    }
                    return copy
                }
                let references = Array(Set(
                    (conflict.localEntry.verseRefs ?? [])
                        + (conflict.cloudEntry.verseRefs ?? [])
                )).sorted()
                let entry = NoteEntry(
                    id: conflict.localEntry.id,
                    moduleId: moduleId,
                    verseId: conflict.verseId,
                    title: conflict.localEntry.title ?? conflict.cloudEntry.title,
                    content: conflict.localEntry.content
                        + "\n\n[From other device]\n"
                        + conflict.cloudEntry.content,
                    verseRefs: references,
                    lastModified: resolvedTimestamp,
                    footnotes: localFootnotes + cloudFootnotes
                )
                try database.saveNoteEntry(entry)
            }

            let hasMore = try database.removePendingModuleConflict(
                moduleId: moduleId,
                type: .notes,
                key: conflict.id
            )
            try reloadPendingModuleConflicts()

            if !hasMore {
                Task {
                    do { try await exportModule(id: moduleId) }
                    catch { print("[NoteSync] Failed to export resolved conflict: \(error)") }
                }
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
            guard try database.pendingModuleConflictExists(
                moduleId: moduleId, type: .devotional, key: conflict.id
            ) else { return }
            guard let resolvedTimestamp = LampSyncMerge.resolutionTimestamp(
                localModified: conflict.localEntry.meta.lastModified,
                incomingModified: conflict.cloudEntry.meta.lastModified,
                now: Int(Date().timeIntervalSince1970)
            ) else { throw SyncError.conflictDetected }
            switch resolution {
            case .keepLocal:
                guard var entry = try database.read({ db in
                    try DevotionalEntry.fetchOne(db, key: conflict.id)
                }) else { throw ModuleSyncError.moduleNotFound(conflict.id) }
                entry.lastModified = resolvedTimestamp
                try database.saveDevotionalEntry(entry)

            case .keepCloud:
                // Replace local with cloud version
                var entry = DevotionalEntry(from: conflict.cloudEntry, moduleId: moduleId)
                entry.lastModified = resolvedTimestamp
                try database.saveDevotionalEntry(entry)

            case .keepBoth:
                guard var localEntry = try database.read({ db in
                    try DevotionalEntry.fetchOne(db, key: conflict.id)
                }) else { throw ModuleSyncError.moduleNotFound(conflict.id) }
                localEntry.lastModified = resolvedTimestamp
                try database.saveDevotionalEntry(localEntry)
                // Keep local, add cloud as new entry with modified ID.
                var cloudDevotional = conflict.cloudEntry
                cloudDevotional.meta.id = UUID().uuidString
                cloudDevotional.meta.title = "[From other device] \(conflict.cloudEntry.meta.title)"
                cloudDevotional.meta.lastModified = resolvedTimestamp
                let entry = DevotionalEntry(from: cloudDevotional, moduleId: moduleId)
                try database.saveDevotionalEntry(entry)
            }

            let hasMore = try database.removePendingModuleConflict(
                moduleId: moduleId,
                type: .devotional,
                key: conflict.id
            )
            try reloadPendingModuleConflicts()

            if !hasMore {
                Task {
                    do { try await exportModule(id: moduleId) }
                    catch { print("[DevotionalSync] Failed to export resolved conflict: \(error)") }
                }
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
        guard LampModuleKind(schemaValue: file.meta.type) == .translation,
              !file.meta.id.isEmpty,
              !file.meta.id.contains("/"),
              !file.meta.id.contains("\\"),
              !file.meta.id.contains("\0") else {
            throw ModuleSyncError.importFailed("Invalid translation schema identity")
        }

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
        // Import using the translation_schema.json format
        try await importTranslationSchemaModule(
            from: data, fileHash: LampSyncContentRevision.digest(for: data)
        )
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
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let compressedData = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let moduleId = fileName.replacingOccurrences(of: ".lamp", with: "")
        let hash = LampSyncContentRevision.digest(for: compressedData)
        let fileInfo = ModuleFileInfo(
            id: moduleId,
            type: moduleType,
            filePath: fileName,
            fileHash: hash,
            modificationDate: Date()
        )

        try await importModuleFromSQLite(
            fileInfo: fileInfo,
            type: moduleType,
            compressedData: compressedData,
            mediaStorage: nil
        )

        // Into the library, while its bytes are in hand: an installed module
        // keeps no file of its own to send later.
        let storage = await MainActor.run { getStorage() }
        if let storage, let endpoint = libraryEndpoint(for: storage), await LibrarySyncPass.isInUse(at: endpoint) {
            try await publishImportedFile(
                compressedData, type: moduleType, moduleId: moduleId, fileName: fileName, to: endpoint
            )
        }

        print("[ModuleSyncManager] Imported module from file: \(moduleId)")
    }

    /// Marks an edited module for the library pass to publish, and asks for
    /// a pass. A library that has not moved yet keeps the mark until it has.
    func exportModule(id: String) async throws {
        guard let module = try database.getModule(id: id) else {
            throw ModuleSyncError.moduleNotFound(id)
        }
        try database.markPendingModulePublication(moduleId: id, type: module.type)
        guard let storage = await getStorage(),
              let endpoint = libraryEndpoint(for: storage),
              await LibrarySyncPass.isInUse(at: endpoint) else { return }
        await LibrarySyncPass.schedule(on: endpoint)
    }

    // MARK: - SQLite Export Functions

    /// Export notes module to SQLite+zlib format
    ///
    /// The same content must export to the same bytes: whether to upload is
    /// decided against this device's last upload, so bytes that followed
    /// storage order would re-upload the module every pass. Rows are read in
    /// an order that ends on a unique column, as in the other two exports.
    func exportNoteModuleToSQLite(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == module.id)
                .order(Column("id"))
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
    func exportDevotionalModuleToSQLite(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == module.id)
                .order(Column("id"))
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
    func exportHighlightModuleToSQLite(_ module: Module) throws -> Data {
        // Get highlight sets for this module
        let sets = try database.getHighlightSets(forModule: module.id)

        guard let set = sets.first else {
            throw ModuleSyncError.exportFailed("No highlight set found for module")
        }

        // Get all highlights for the set
        let highlights = try database.getAllHighlights(setId: set.id)

        // Get all themes for the set
        let themes = try database.getHighlightThemes(setId: set.id)

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
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, 'highlights')",
                arguments: [module.id]
            )
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

            // Create highlight_themes table
            try db.execute(sql: """
                CREATE TABLE highlight_themes (
                    color TEXT NOT NULL,
                    style INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    PRIMARY KEY (color, style)
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

            // Insert all themes
            for theme in themes {
                try db.execute(
                    sql: "INSERT INTO highlight_themes (color, style, name, description) VALUES (?, ?, ?, ?)",
                    arguments: [theme.color, theme.style, theme.name, theme.themeDescription]
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

    // MARK: - Create Default Notes Module

    /// Create the default "My Notes" module if it doesn't exist
    func ensureDefaultNotesModule() async throws {
        // A fixed ID: a library already holding "notes" merges with this one
        // by value on the next pass rather than gaining a second.
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

            try await exportModule(id: defaultModule.id)
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

    /// Create the default "devotionals" module if it doesn't exist
    func ensureDefaultDevotionalsModule() async throws {
        // Coalesce the first pull and default creation. A failed creation or
        // export must leave the whole operation available for a later retry.
        try await initialDevotionalSync.run {
            let devotionalModules = try self.database.getAllModules(type: .devotional)
            guard !devotionalModules.contains(where: { $0.isEditable }) else { return }

            let defaultModule = Module(
                id: "devotionals",
                type: .devotional,
                name: "My Devotionals",
                description: "Personal devotional writings",
                filePath: "devotionals.lamp",
                isEditable: true,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            try self.database.saveModule(defaultModule)
            try await self.exportModule(id: defaultModule.id)
        }
    }

    // MARK: - Zlib Decompression

    /// Unpacks a module straight to disk. Unpacked in memory, a large module
    /// on top of the sync archive it came in is more than iOS allows an app.
    private func unpackModule(_ data: Data, to url: URL) throws {
        do {
            try LampZlib.decompress(data, to: url)
        } catch {
            throw ModuleSyncError.importFailed("Failed to decompress zlib data: \(error.localizedDescription)")
        }
    }

    // MARK: - Book Media Sync

    func downloadBookMedia(moduleId: String, from storage: ModuleStorage) async throws {
        guard await storage.isAvailable() else { throw ModuleStorageError.notAvailable }
        let items = try bookMediaItems(moduleId: moduleId, forExport: false)
        try await LampSyncReferencedMedia.downloadMissing(items) { path in
            try await storage.readFile(path: path)
        }
    }

    private func bookMediaItems(
        moduleId: String, forExport: Bool
    ) throws -> [LampSyncReferencedMedia.Item] {
        guard BookMediaPath.isSafeFilename(moduleId) else {
            throw forExport
                ? ModuleSyncError.exportFailed("Invalid media module ID: \(moduleId)")
                : ModuleSyncError.importFailed("Invalid media module ID: \(moduleId)")
        }
        guard let book = try database.getBookModule(id: moduleId) else {
            throw ModuleSyncError.moduleNotFound(moduleId)
        }
        return try book.mediaReferences.map { mediaRef in
            guard BookMediaPath.isSafeMediaPath(mediaRef.filename) else {
                throw forExport
                    ? ModuleSyncError.exportFailed("Invalid book media filename: \(mediaRef.filename)")
                    : ModuleSyncError.importFailed("Invalid book media filename: \(mediaRef.filename)")
            }
            return LampSyncReferencedMedia.Item(
                remotePath: "BookMedia/\(moduleId)/\(mediaRef.filename)",
                localURL: ModuleMediaStorage.shared.expectedMediaURL(
                    for: mediaRef, moduleId: moduleId
                )
            )
        }
    }

    // MARK: - Devotional Media Sync

    func downloadDevotionalMedia(moduleId: String, from storage: ModuleStorage) async throws {
        guard await storage.isAvailable() else {
            throw ModuleStorageError.notAvailable
        }
        let items = try devotionalMediaItems(moduleId: moduleId, forExport: false)
        try await LampSyncReferencedMedia.downloadMissing(items) { path in
            try await storage.readFile(path: path)
        }
    }

    func devotionalMediaItems(
        moduleId: String, forExport: Bool
    ) throws -> [LampSyncReferencedMedia.Item] {
        guard BookMediaPath.isSafeFilename(moduleId) else {
            throw forExport
                ? ModuleSyncError.exportFailed("Invalid media module ID: \(moduleId)")
                : ModuleSyncError.importFailed("Invalid media module ID: \(moduleId)")
        }
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("media_json") != nil)
                .fetchAll(db)
        }
        var items: [LampSyncReferencedMedia.Item] = []
        for entry in entries {
            guard BookMediaPath.isSafeFilename(entry.id) else {
                throw forExport
                    ? ModuleSyncError.exportFailed("Invalid media entry ID: \(entry.id)")
                    : ModuleSyncError.importFailed("Invalid media entry ID: \(entry.id)")
            }
            guard let mediaJson = entry.mediaJson else { continue }
            let mediaRefs = try JSONDecoder().decode(
                [DevotionalMediaReference].self, from: Data(mediaJson.utf8)
            )
            for mediaRef in mediaRefs {
                guard BookMediaPath.isSafeFilename(mediaRef.filename) else {
                    throw forExport
                        ? ModuleSyncError.exportFailed(
                            "Invalid devotional media filename: \(mediaRef.filename)"
                        )
                        : ModuleSyncError.importFailed(
                            "Invalid devotional media filename: \(mediaRef.filename)"
                        )
                }
                items.append(LampSyncReferencedMedia.Item(
                    remotePath: try LampPortableDevotionalMedia.iOSRemotePath(
                        moduleID: moduleId,
                        devotionalID: entry.id,
                        filename: mediaRef.filename
                    ),
                    localURL: DevotionalMediaStorage.shared.expectedMediaURL(
                        for: mediaRef, devotionalId: entry.id, moduleId: moduleId
                    )
                ))
            }
        }
        return items
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
