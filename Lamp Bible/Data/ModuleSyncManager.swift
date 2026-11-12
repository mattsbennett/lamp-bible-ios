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
            // Lamp is offered for any JSON file; only a book module opens.
            do {
                _ = try BookJSONImportDescriptor.decode(from: data)
            } catch {
                throw ModuleSyncError.importFailed(
                    "\(url.lastPathComponent) isn't a book module, the only JSON file Lamp Bible opens."
                )
            }
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

    // MARK: - Bible import

    /// What reviewing a Bible import needs to know of the translations and
    /// modules installed here, read once rather than on every keystroke.
    struct TranslationImportLibrary {
        /// Translations the user imported; a new import can replace one.
        let replaceableTranslationIDs: Set<String>
        /// Everything else, bundled modules included, which an import avoids.
        let otherModuleIDs: Set<String>
        let abbreviationsByTranslationID: [String: String]
        let namesByTranslationID: [String: String]

        func destination(abbreviation: String) -> LampTranslationImportDestination {
            LampTranslationImporter.destination(
                abbreviation: abbreviation,
                replaceableTranslationIDs: replaceableTranslationIDs,
                otherModuleIDs: otherModuleIDs
            )
        }

        /// The translation already shown under `abbreviation`, other than
        /// the one an import would replace.
        func nameSharing(abbreviation: String, except destination: LampTranslationImportDestination) -> String? {
            LampTranslationImporter.translationID(
                sharingAbbreviation: abbreviation,
                abbreviationsByTranslationID: abbreviationsByTranslationID,
                except: destination
            ).flatMap { namesByTranslationID[$0] }
        }
    }

    func translationImportLibrary() throws -> TranslationImportLibrary {
        let imported = try database.getAllTranslations(bundledOnly: false)
        let bundled = try BundledModuleDatabase.shared.getAllTranslations()
        let modules = try database.getAllModules()
        let translations = bundled + imported
        return TranslationImportLibrary(
            replaceableTranslationIDs: Set(imported.map(\.id)),
            otherModuleIDs: Set(bundled.map(\.id) + modules.map(\.id)),
            abbreviationsByTranslationID: Dictionary(
                translations.map { ($0.id, $0.abbreviation) }, uniquingKeysWith: { first, _ in first }
            ),
            namesByTranslationID: Dictionary(
                translations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Installs a Bible read from another format: compiled into a `.lamp`
    /// and taken in like any module file, which also publishes it to the
    /// library for the user's other devices.
    func importTranslation(
        _ translation: LampImportedTranslation,
        into destination: LampTranslationImportDestination,
        name: String,
        abbreviation: String,
        language: String
    ) async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-translation-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let compiled = try translation.compile(
            into: temporaryDirectory,
            id: destination.moduleID,
            name: name,
            abbreviation: abbreviation,
            language: language
        )
        try await importModuleFromFile(url: compiled.outputURL, moduleType: .translation)
    }

    func importRemoteModuleSnapshot(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        snapshot: LampSyncRemoteFile,
        storage: ModuleStorage,
        mergingHighlights: Bool = true
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
            mediaStorage: storage,
            mergingHighlights: mergingHighlights,
            forSync: true
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
    /// A highlight set already here takes the module's highlights in with its
    /// own (`mergeHighlightSet`), unless `mergingHighlights` is off: a sync
    /// pass turns it off when the set here is as it last agreed, so has no
    /// edits to keep, and is replaced. `forSync` is off for a file taken in
    /// by hand.
    private func importModuleFromSQLite(
        fileInfo: ModuleFileInfo,
        type: ModuleType,
        compressedData data: Data,
        mediaStorage: ModuleStorage?,
        mergingHighlights: Bool = true,
        forSync: Bool = false
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
            if let mediaStorage {
                try await downloadNoteMedia(moduleId: fileInfo.id, from: mediaStorage)
            }
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
        if type == .highlights, mergingHighlights,
           let local = try database.getHighlightSets(forModule: fileInfo.id).first {
            try mergeHighlightSet(local, from: tempURL, forSync: forSync)
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

    /// Copies a commentary module's units, with the footnote text a module
    /// carries for search; one from before it gets its text written here. A
    /// standalone module's units are named for it (`standaloneModuleId`),
    /// having no module of their own.
    static func copyCommentaryUnits(
        from dbAlias: String,
        standaloneModuleId: String?,
        in db: Database
    ) throws {
        let carriesFootnotesText = try Row.fetchAll(db, sql: "PRAGMA \(dbAlias).table_info(commentary_units)")
            .contains { ($0["name"] as String?) == "footnotes_text" }
        let lastRowid = try Int64.fetchOne(db, sql: "SELECT max(rowid) FROM commentary_units") ?? 0
        try copyCompiled(
            "commentary_units", of: .commentary, from: dbAlias,
            filling: standaloneModuleId == nil ? [:] : [
                "id": ":module || ':' || id", "module_id": ":module",
                // The parent named as its unit now is; none stays none.
                "parent_id": ":module || ':' || parent_id",
            ],
            arguments: ["module": standaloneModuleId], in: db
        )
        if !carriesFootnotesText {
            try CommentaryFootnoteSearchText.fill(in: db, after: lastRowid)
        }
    }

    /// A dictionary's own account of its publication, kept beside its
    /// entry in `modules`.
    static let dictionaryBibliography = ["editor", "publisher", "year", "isbn", "language"]

    /// Copies one table of an attached module: every column it shares with
    /// this database's `destination`, so a column both have arrives without
    /// a list to edit, less those this database numbers itself
    /// (`excluding`), and with `filling` giving, as SQL over the source row,
    /// the columns this database sets for itself. Named arguments in
    /// `filling` and `filter` bind from `arguments`.
    static func copyRows(
        from alias: String,
        table: String,
        into destination: String,
        excluding: Set<String> = [],
        filling: [String: String] = [:],
        filter: String? = nil,
        order: String? = nil,
        arguments: [String: (any DatabaseValueConvertible)?] = [:],
        in db: Database
    ) throws {
        func columns(_ schema: String, _ table: String) throws -> [String] {
            try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\(table))").compactMap { $0["name"] as String? }
        }
        let held = Set(try columns("main", destination))
        let shared = try columns(alias, table).filter {
            held.contains($0) && !excluding.contains($0) && filling[$0] == nil
        }
        let filled = filling.sorted { $0.key < $1.key }
        let sql = """
            INSERT INTO \(destination) (\((shared + filled.map(\.key)).joined(separator: ", ")))
            SELECT \((shared + filled.map(\.value)).joined(separator: ", "))
            FROM \(alias).\(table)
            \(filter.map { "WHERE \($0)" } ?? "")
            \(order.map { "ORDER BY \($0)" } ?? "")
            """
        // Only the arguments the statement names: SQLite refuses others.
        let named = arguments.filter { sql.contains(":\($0.key)") }
        try db.execute(sql: sql, arguments: StatementArguments(named))
    }

    /// `copyRows` for a table core says a compiled module holds, into where
    /// `CompiledModuleLanding` says this database keeps it.
    static func copyCompiled(
        _ table: String,
        of kind: ModuleType,
        from alias: String,
        filling: [String: String] = [:],
        filter: String? = nil,
        order: String? = nil,
        arguments: [String: (any DatabaseValueConvertible)?] = [:],
        in db: Database
    ) throws {
        guard let landing = CompiledModuleLanding.table(table, of: kind) else {
            throw ModuleSyncError.importFailed("No place here for a \(kind.rawValue) module's \(table)")
        }
        try copyRows(
            from: alias, table: table, into: landing.destination,
            excluding: Set(landing.notKept.keys), filling: filling, filter: filter, order: order,
            arguments: arguments, in: db
        )
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
            // Copy dictionary entries, with the search text a compiled module
            // carries; one from before it gets its text written here.
            try Self.copyCompiled("dictionary_entries", of: .dictionary, from: dbAlias, in: db)
            try DictionarySearchText.fill(in: db, moduleId: fileInfo.id)

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
                    try Self.copyCompiled(
                        "commentary_books", of: .commentary, from: dbAlias,
                        filling: [
                            "id": ":module || ':' || book_number", "module_id": ":module",
                            "series_full": ":seriesFull", "series_abbrev": ":seriesAbbrev",
                        ],
                        arguments: ["module": fileInfo.id, "seriesFull": seriesName, "seriesAbbrev": seriesAbbrev],
                        in: db
                    )

                    // Copy commentary units (standalone format - no module_id column)
                    try Self.copyCommentaryUnits(from: dbAlias, standaloneModuleId: fileInfo.id, in: db)
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
                try Self.copyCompiled("commentary_books", of: .commentary, from: dbAlias, in: db)

                // Copy commentary units
                try Self.copyCommentaryUnits(from: dbAlias, standaloneModuleId: nil, in: db)
            }

        case .book:
            try Self.copyCompiled(
                "book_modules", of: .book, from: dbAlias,
                filter: "id = :module", arguments: ["module": fileInfo.id], in: db
            )
            // Compiler/bundler output stores parents before children.
            // Preserve that order so the self-referencing FK is valid.
            try Self.copyCompiled(
                "book_sections", of: .book, from: dbAlias,
                filter: "module_id = :module", order: "rowid", arguments: ["module": fileInfo.id], in: db
            )

        case .notes, .devotional:
            // Taken in as records and reconciled with what is here
            // (`importNoteModuleFromSQLite`, `importDevotionalModuleFromSQLite`),
            // never copied: a copy naming its own columns is how a column
            // nobody listed goes missing.
            throw ModuleSyncError.importFailed("Editable modules require reconciliation")

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
                try Self.copyCompiled(
                    "plans", of: .plan, from: dbAlias,
                    filling: [
                        "file_path": ":filePath", "file_hash": ":hash", "last_synced": ":now",
                        "created_at": ":now", "updated_at": ":now",
                    ],
                    arguments: [
                        "filePath": "\(fileInfo.id).lamp", "hash": fileInfo.fileHash,
                        "now": Int(Date().timeIntervalSince1970),
                    ],
                    in: db
                )
                try Self.copyCompiled("plan_days", of: .plan, from: dbAlias, in: db)
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
                      let fileSetId: String = metaRow["id"],
                      let setName: String = metaRow["name"],
                      let translationId: String = metaRow["translation_id"] else {
                    throw ModuleSyncError.importFailed("Could not read highlight metadata")
                }
                // The set the file says it is. One written before sets said
                // so carries the module's id instead, and only then is the
                // Mac's default set read back as the Mac reads it, colon and
                // all: a set named otherwise than its module was named so.
                let setId = fileSetId == fileInfo.id
                    ? LampLibrary.canonicalHighlightSetID(fileSetId, translationID: translationId)
                    : fileSetId

                // Create module if not exists
                try db.execute(sql: """
                    INSERT OR REPLACE INTO modules (id, type, name, description, file_path, file_hash, last_synced, is_editable, created_at, updated_at)
                    VALUES (?, 'highlights', ?, ?, ?, ?, ?, 1, ?, ?)
                    """, arguments: [fileInfo.id, setName, metaRow["description"] as String?, filePath, fileInfo.fileHash, now, now, now])

                // Copy highlight set metadata. A set that gives no times is
                // stamped with its arrival here, which the deletion ledger
                // reads as when it was saved here.
                try Self.copyCompiled(
                    "highlight_meta", of: .highlights, from: dbAlias,
                    filling: [
                        "id": ":set",
                        "module_id": ":module",
                        "created": "COALESCE(created, :now)",
                        "last_modified": "COALESCE(last_modified, :now)",
                    ],
                    arguments: ["set": setId, "module": fileInfo.id, "now": now], in: db
                )

                // Copy highlights
                try Self.copyCompiled(
                    "highlights", of: .highlights, from: dbAlias,
                    filling: ["set_id": ":set"], arguments: ["set": setId], in: db
                )

                // Copy themes if table exists, each keyed by its set, colour
                // and style
                if tableNames.contains("highlight_themes") {
                    try Self.copyCompiled(
                        "highlight_themes", of: .highlights, from: dbAlias,
                        filling: [
                            "id": ":set || '_' || upper(COALESCE(color, '')) || '_' || COALESCE(style, 0)",
                            "set_id": ":set",
                            "color": "upper(COALESCE(color, ''))",
                            "style": "COALESCE(style, 0)",
                            "name": "COALESCE(name, '')",
                        ],
                        arguments: ["set": setId], in: db
                    )
                }
            } else if tableNames.contains("highlight_sets") && tableNames.contains("highlights") {
                // Full GRDB schema - copy directly. Only an import by hand
                // reaches here: core's compiler and this app's export both
                // write highlight_meta. Unlike that branch, this makes no
                // `modules` row, so a pass could not claim what it brought.
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
            try Self.copyCompiled("quiz_modules", of: .quiz, from: dbAlias, in: db)

            // Copy quiz questions
            try Self.copyCompiled("quiz_questions", of: .quiz, from: dbAlias, in: db)

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
                try Self.copyRows(
                    from: dbAlias, table: "translations", into: "translations",
                    filling: [
                        "last_synced": ":now", "is_bundled": "0", "created_at": ":now", "updated_at": ":now",
                    ],
                    arguments: ["now": Int(Date().timeIntervalSince1970)], in: db
                )

                // Copy translation books (if table exists)
                if tableNames.contains("translation_books") {
                    try Self.copyRows(from: dbAlias, table: "translation_books", into: "translation_books", in: db)
                }

                // Copy translation verses and headings, numbered here
                for table in ["translation_verses", "translation_headings"] where tableNames.contains(table) {
                    try Self.copyRows(from: dbAlias, table: table, into: table, excluding: ["id"], in: db)
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
                try Self.copyCompiled(
                    "translation_meta", of: .translation, from: dbAlias,
                    filling: [
                        "file_path": ":filePath", "file_hash": ":hash", "last_synced": ":now",
                        "is_bundled": "0", "created_at": ":now", "updated_at": ":now",
                    ],
                    arguments: ["filePath": filePath, "hash": fileInfo.fileHash, "now": now], in: db
                )

                // Copy books - compact schema: id=book_number, book_id=book_id string
                if tableNames.contains("books") {
                    try Self.copyCompiled(
                        "books", of: .translation, from: dbAlias,
                        filling: [
                            "id": ":translation || ':' || id", "translation_id": ":translation", "book_number": "id",
                        ],
                        arguments: ["translation": translationId], in: db
                    )
                }

                // Copy verses and headings - compact schema doesn't have a
                // translation_id column
                for table in ["verses", "headings"] where tableNames.contains(table) {
                    try Self.copyCompiled(
                        table, of: .translation, from: dbAlias,
                        filling: ["translation_id": ":translation"],
                        arguments: ["translation": translationId], in: db
                    )
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
            var bibliography: [(any DatabaseValueConvertible)?] = Self.dictionaryBibliography.map { _ in nil }
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
                    bibliography = Self.dictionaryBibliography.map { row[$0] as DatabaseValue? }
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
            // What else the dictionary says of itself, where it says it.
            try db.execute(
                sql: "UPDATE modules SET "
                    + Self.dictionaryBibliography.map { "\($0) = ?" }.joined(separator: ", ")
                    + " WHERE id = ?",
                arguments: StatementArguments(bibliography + [id])
            )

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
        let (fetched, carriesMedia) = try await remoteQueue.read { db in
            (try NoteEntry.fetchAll(db),
             try db.columns(in: "note_entries").contains { $0.name == "media_json" })
        }
        // Searched as a note here is searched, footnotes and all: a file's
        // search text is its writer's, and core's leaves footnotes out.
        let isCollection = fileInfo.id == LampSyncLocalDeletion.notesCollectionID
        let remoteEntries = fetched.map { entry in
            var entry = entry
            entry.searchText = NoteEntry.searchText(content: entry.content, footnotes: entry.footnotes)
            // Named as a note here is named, as the Mac names it: a note that
            // won the merge would otherwise keep the name an older device
            // gave it, and match nothing in the ledger.
            if isCollection { entry.id = NoteEntry.panelID(moduleId: fileInfo.id, verseId: entry.verseId) }
            return entry
        }
        let metadata = try await editableModuleMetadata(
            id: fileInfo.id, type: .notes,
            hash: fileInfo.fileHash, tempURL: tempURL
        )
        let mergeResult = try database.write { db in
            // One note a verse: one twice under two names keeps its newest,
            // where the merge, keying by verse, would keep whichever came first.
            let localEntries = Dictionary(
                grouping: try NoteEntry.filter(Column("module_id") == fileInfo.id).fetchAll(db), by: \.verseId
            ).values.compactMap { copies in copies.max { ($0.lastModified ?? 0) < ($1.lastModified ?? 0) } }
            let result = mergeNoteEntries(
                local: localEntries,
                cloud: carriesMedia ? remoteEntries : Self.keepingLocalMedia(remoteEntries, from: localEntries),
                moduleId: fileInfo.id,
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
        let fetched = try await remoteQueue.read { db in
            try DevotionalEntry.fetchAll(db)
        }
        // Searched as a writing here is searched: a file's search text is
        // its writer's, and core's is built differently.
        let remoteEntries = fetched.map { entry in
            var entry = entry
            if let devotional = entry.toDevotional() { entry.searchText = devotional.searchText }
            return entry
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

    /// Another copy of a highlight set taken into the one here, highlight by
    /// highlight, as the Mac takes it: each highlight not here is added,
    /// unless the deletion ledger says it was deleted, and none here is taken
    /// away for being missing there. A highlight is a small thing on its own,
    /// and a set kept or replaced whole lost whichever side's new highlights
    /// the other copy lacked. The ledger is what keeps the union from
    /// bringing back a deletion, so a sync checks it first; a file taken in
    /// by hand doesn't, and what it brings counts as saved here.
    ///
    /// The set's name and description, and each theme's, go to whichever
    /// copy was changed last.
    private func mergeHighlightSet(_ local: HighlightSet, from tempURL: URL, forSync: Bool) throws {
        let (meta, highlights, themes) = try DatabaseQueue(path: tempURL.path).read { db in
            let tables = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            return (
                try Row.fetchOne(db, sql: "SELECT * FROM highlight_meta LIMIT 1"),
                try Row.fetchAll(db, sql: "SELECT ref, sc, ec, style, color FROM highlights"),
                tables.contains("highlight_themes")
                    ? try Row.fetchAll(db, sql: "SELECT color, style, name, description FROM highlight_themes")
                    : []
            )
        }
        try database.write { db in
            let ledger = try ModuleDatabase.personalDeletionLedger(in: db)
            let incomingModified: Int? = meta?["last_modified"]
            // This copy predates the set's deletion; the set here was made again since.
            if forSync, ledger.isDeleted(.highlightSet, local.id, itemModified: incomingModified) { return }
            let incomingIsNewer = (incomingModified ?? 0) > local.lastModified

            if incomingIsNewer, let meta, let name: String = meta["name"] {
                try db.execute(sql: """
                    UPDATE highlight_sets SET name = ?, description = ?, last_modified = ? WHERE id = ?
                    """, arguments: [name, meta["description"] as String?, incomingModified, local.id])
                try db.execute(sql: "UPDATE modules SET name = ?, description = ? WHERE id = ?",
                               arguments: [name, meta["description"] as String?, local.moduleId])
            }

            for row in highlights {
                var entry = HighlightEntry(setId: local.id, ref: row["ref"], sc: row["sc"], ec: row["ec"])
                entry.style = row["style"] ?? 0
                entry.color = Self.normalizedHighlightColor(row["color"])
                guard entry.sc >= 0, entry.ec > entry.sc else { continue }
                let key = ModuleDatabase.ledgerKey(entry)
                if forSync, ledger.isDeleted(.highlight, key, itemModified: nil) { continue }
                let here = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM highlights
                        WHERE set_id = ? AND ref = ? AND sc = ? AND ec = ? AND style = ?
                          AND COALESCE(color, '') = COALESCE(?, '')
                    )
                    """, arguments: [entry.setId, entry.ref, entry.sc, entry.ec, entry.style, entry.color]) ?? false
                if here { continue }
                try entry.insert(db)
                if !forSync { try ModuleDatabase.recordPersonalPresence(db, .highlight, key) }
            }

            for row in themes {
                let theme = HighlightTheme(
                    setId: local.id, color: row["color"] ?? "", style: row["style"] ?? 0,
                    name: row["name"] ?? "", description: row["description"]
                )
                let key = ModuleDatabase.ledgerKey(theme)
                if forSync, ledger.isDeleted(.highlightTheme, key, itemModified: nil) { continue }
                if try HighlightTheme.exists(db, key: theme.id) {
                    if incomingIsNewer { try theme.update(db) }
                } else {
                    try theme.insert(db)
                }
                if !forSync { try ModuleDatabase.recordPersonalPresence(db, .highlightTheme, key) }
            }
        }
    }

    /// A highlight's colour as the Mac keys it: hex without its `#`, in
    /// capitals, and anything else as it came.
    static func normalizedHighlightColor(_ color: String?) -> String? {
        guard var color else { return nil }
        if color.hasPrefix("#") { color.removeFirst() }
        let isHex = [6, 8].contains(color.count) && color.allSatisfy(\.isHexDigit)
        return isHex ? color.uppercased() : color
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
            && LampSyncJSONComparison.sameValue(local.mediaJson, cloud.mediaJson)
    }

    /// Notes from a file written before notes carried pictures. Its missing
    /// column says nothing about a note's pictures, so each note keeps the
    /// ones it has here; taken as an empty list, a note edited on a device
    /// that can't hold pictures would arrive without them.
    static func keepingLocalMedia(_ incoming: [NoteEntry], from local: [NoteEntry]) -> [NoteEntry] {
        let media = Dictionary(
            local.compactMap { entry in entry.mediaJson.map { (entry.verseId, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return incoming.map { entry in
            var entry = entry
            entry.mediaJson = media[entry.verseId]
            return entry
        }
    }

    /// Both copies' pictures, for a note that keeps both texts: the local
    /// list first, then each of the other's it lacks. Entries are kept as
    /// written, so a field a newer Lamp wrote survives.
    static func combinedMedia(_ local: String?, _ cloud: String?) -> String? {
        func entries(_ json: String?) -> [[String: Any]] {
            guard let data = json?.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
            return list.compactMap { $0 as? [String: Any] }
        }
        let ours = entries(local)
        let seen = Set(ours.compactMap { $0["id"] as? String })
        let theirs = entries(cloud).filter { ($0["id"] as? String).map { !seen.contains($0) } ?? false }
        guard !theirs.isEmpty else { return local ?? cloud }
        guard let data = try? JSONSerialization.data(withJSONObject: ours + theirs, options: [.sortedKeys]) else {
            return local
        }
        return String(decoding: data, as: UTF8.self)
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
            // The note's id as it is now, which may have changed since the
            // conflict was set aside (`nameCollectionNotesAsTheMacDoes`):
            // saved under the old one, the choice would add a second note.
            let currentID = try database.read { db in
                try String.fetchOne(db, sql: """
                    SELECT id FROM note_entries WHERE module_id = ? AND verse_id = ? ORDER BY id LIMIT 1
                    """, arguments: [moduleId, conflict.verseId])
            } ?? conflict.localEntry.id
            switch resolution {
            case .keepLocal:
                var entry = conflict.localEntry
                entry.id = currentID
                entry.lastModified = resolvedTimestamp
                try database.saveNoteEntry(entry)

            case .keepCloud:
                var entry = conflict.cloudEntry
                entry.id = currentID
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
                    id: currentID,
                    moduleId: moduleId,
                    verseId: conflict.verseId,
                    title: conflict.localEntry.title ?? conflict.cloudEntry.title,
                    content: conflict.localEntry.content
                        + "\n\n[From other device]\n"
                        + conflict.cloudEntry.content,
                    verseRefs: references,
                    lastModified: resolvedTimestamp,
                    footnotes: localFootnotes + cloudFootnotes,
                    mediaJson: Self.combinedMedia(
                        conflict.localEntry.mediaJson, conflict.cloudEntry.mediaJson
                    )
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
        await SearchIndexMaintenance.refreshWordLists()
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
        // Written by core, as the Mac writes it, so the same notes are the
        // same file on either device: the reader's collection under its name
        // on the server and the collection's own, as the Mac names it, a
        // module of their own making under its own.
        let isCollection = module.id == LampSyncLocalDeletion.notesCollectionID
        return try Self.notesArchive(
            entries, moduleID: module.id,
            name: isCollection ? LampPersonalModule.notes.name : module.name,
            description: isCollection ? nil : module.description,
            author: isCollection ? nil : module.author,
            version: isCollection ? nil : module.version
        )
    }

    /// The notes file as core writes it, each note as the row it's stored
    /// as, so nothing this device keeps is flattened on the way out (a
    /// footnote's annotations, its kind), and in the order the Mac hands
    /// notes over, so the same notes are the Mac's bytes.
    static func notesArchive(
        _ entries: [NoteEntry], moduleID: String, name: String = LampPersonalModule.notes.name,
        description: String? = nil, author: String? = nil, version: String? = nil
    ) throws -> Data {
        let ordered = entries.sorted {
            ($0.book, $0.chapter, $0.verse, $0.lastModified ?? 0, $0.id)
                < ($1.book, $1.chapter, $1.verse, $1.lastModified ?? 0, $1.id)
        }
        return try LampPersonalNotesFile.archive(
            rows: ordered.map { entry in
                LampPersonalNotesFile.Row(
                    id: entry.id, moduleID: moduleID, reference: entry.verseId,
                    title: entry.title, content: entry.content,
                    // No list is written as the Mac writes an empty one.
                    verseReferencesJSON: entry.verseRefsJson ?? "[]",
                    footnotesJSON: entry.footnotesJson ?? "[]",
                    mediaJSON: entry.mediaJson, lastModified: entry.lastModified,
                    recordChangeTag: entry.recordChangeTag
                )
            },
            moduleID: moduleID, name: name, description: description, author: author, version: version
        )
    }

    /// Export devotionals module to SQLite+zlib format
    func exportDevotionalModuleToSQLite(_ module: Module) throws -> Data {
        let entries = try database.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == module.id)
                .fetchAll(db)
        }
        // Written by core, as the Mac writes it: the reader's collection
        // under its name on the server and the collection's own, a module of
        // their own making under its own name and description.
        let isCollection = module.id == LampSyncLocalDeletion.writingCollectionID
        return try Self.writingsArchive(
            entries, moduleID: module.id,
            name: isCollection ? LampPersonalModule.writing.name : module.name,
            description: isCollection ? nil : module.description,
            author: isCollection ? nil : module.author,
            version: isCollection ? nil : module.version
        )
    }

    /// The writings file as core writes it, each writing as the row it is
    /// stored as, so nothing this device keeps is flattened on the way out,
    /// and in the order the Mac hands writings over.
    static func writingsArchive(
        _ entries: [DevotionalEntry], moduleID: String, name: String,
        description: String? = nil, author: String? = nil, version: String? = nil
    ) throws -> Data {
        // As SQLite orders them, which is how the Mac reads them: series by
        // its bytes, its order as a number, then the date, the title and the
        // id by their bytes.
        let ordered = entries.sorted { lhs, rhs in
            let (left, right) = (lhs.seriesName ?? "", rhs.seriesName ?? "")
            if left != right { return left.utf8.lexicographicallyPrecedes(right.utf8) }
            if (lhs.seriesOrder ?? 0) != (rhs.seriesOrder ?? 0) { return (lhs.seriesOrder ?? 0) < (rhs.seriesOrder ?? 0) }
            for (left, right) in [(lhs.date ?? "", rhs.date ?? ""), (lhs.title, rhs.title), (lhs.id, rhs.id)]
            where left != right {
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
            return false
        }
        return try LampPersonalWritingFile.archive(
            rows: ordered.map { entry in
                LampPersonalWritingFile.Row(
                    id: entry.id, moduleID: moduleID, title: entry.title,
                    subtitle: entry.subtitle, author: entry.author, date: entry.date,
                    tags: entry.tags, category: entry.category,
                    seriesID: entry.seriesId, seriesName: entry.seriesName, seriesOrder: entry.seriesOrder,
                    keyScripturesJSON: entry.keyScripturesJson, summaryJSON: entry.summaryJson,
                    contentJSON: entry.contentJson, footnotesJSON: entry.footnotesJson,
                    relatedIDs: entry.relatedIds, created: entry.created, lastModified: entry.lastModified,
                    recordChangeTag: entry.recordChangeTag,
                    subscriptionID: entry.subscriptionId, isReadOnly: entry.isReadOnly,
                    mediaJSON: entry.mediaJson
                )
            },
            moduleID: moduleID, name: name, description: description, author: author, version: version
        )
    }

    /// Export highlights module to SQLite+zlib format
    func exportHighlightModuleToSQLite(_ module: Module) throws -> Data {
        guard let set = try database.getHighlightSets(forModule: module.id).first else {
            throw ModuleSyncError.exportFailed("No highlight set found for module")
        }
        return try Self.highlightsArchive(
            set, moduleID: module.id,
            highlights: database.getAllHighlights(setId: set.id),
            themes: database.getHighlightThemes(setId: set.id)
        )
    }

    /// A highlight set's file as the Mac makes it: core's document for the
    /// set, saying which set it is apart from the module it travels as,
    /// compiled by core's compiler. The same set is the same file on either
    /// device. Core orders a verse's spans; the themes go in the Mac's order.
    static func highlightsArchive(
        _ set: HighlightSet, moduleID: String, highlights: [HighlightEntry], themes: [HighlightTheme]
    ) throws -> Data {
        let spans = highlights.map { highlight in
            LampVerseHighlight(
                id: highlight.id ?? 0, setID: set.id, translationID: set.translationId,
                reference: highlight.ref, startOffset: highlight.sc, endOffset: highlight.ec,
                style: LampHighlightStyle(rawValue: highlight.style) ?? .highlight, color: highlight.color
            )
        }
        let named = themes
            .sorted { ($0.name, $0.color, $0.style) < ($1.name, $1.color, $1.style) }
            .map { theme in
                LampHighlightTheme(
                    setID: set.id, color: theme.color,
                    style: LampHighlightStyle(rawValue: theme.style) ?? .highlight,
                    name: theme.name, description: theme.themeDescription
                )
            }
        let document = try LampPersonalHighlightsFile.document(for: .init(
            id: set.id, moduleID: moduleID, name: set.name, translationID: set.translationId,
            description: set.description, created: set.created, lastModified: set.lastModified,
            highlights: spans, themes: named
        ))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-highlights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let compiled = try LampModuleCompiler().compile(
            data: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]),
            sourceFilename: "\(moduleID).json",
            destinationURL: folder.appendingPathComponent("\(moduleID).lamp")
        )
        return try Data(contentsOf: compiled.outputURL)
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
            // By filename, not by reading each entry: one of a media type
            // this version has no name for still has its file carried.
            let filenames: [String]
            do {
                filenames = try LampPortableDevotionalMedia.filenames(in: entry.mediaJson)
            } catch {
                throw forExport
                    ? ModuleSyncError.exportFailed("Invalid devotional media in \(entry.id): \(error)")
                    : ModuleSyncError.importFailed("Invalid devotional media in \(entry.id): \(error)")
            }
            for filename in filenames {
                items.append(LampSyncReferencedMedia.Item(
                    remotePath: try LampPortableDevotionalMedia.iOSRemotePath(
                        moduleID: moduleId,
                        devotionalID: entry.id,
                        filename: filename
                    ),
                    localURL: DevotionalMediaStorage.shared
                        .mediaDirectory(devotionalId: entry.id, moduleId: moduleId)
                        .appendingPathComponent(filename)
                ))
            }
        }
        return items
    }

    /// Fetches the pictures a notes module's notes name that this device
    /// lacks. They come because the notes named them, so a note attached
    /// on another device brings its pictures with it.
    func downloadNoteMedia(moduleId: String, from storage: ModuleStorage) async throws {
        let items = try noteMediaItems(moduleId: moduleId)
        try await LampSyncReferencedMedia.downloadMissing(items) { path in
            try await storage.readFile(path: path)
        }
    }

    /// Each picture a notes module's notes name, where it syncs and where it
    /// is kept here. Asked by filename rather than by reading each entry, so
    /// one of a media type this version has no name for still has its file
    /// carried. A note whose list can't be read, or names a file that can't
    /// be a path, costs its own pictures and no other note's.
    func noteMediaItems(moduleId: String) throws -> [LampSyncReferencedMedia.Item] {
        guard BookMediaPath.isSafeFilename(moduleId) else { return [] }
        let entries = try database.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("media_json") != nil)
                .fetchAll(db)
        }
        return entries.flatMap { entry in
            ((try? LampPortableDevotionalMedia.filenames(in: entry.mediaJson)) ?? []).compactMap { filename in
                guard let remotePath = try? NoteMedia.remotePath(
                    filename: filename, moduleId: moduleId, verseId: entry.verseId
                ) else { return nil }
                return LampSyncReferencedMedia.Item(
                    remotePath: remotePath,
                    localURL: NoteMedia.expectedURL(filename: filename, moduleId: moduleId, verseId: entry.verseId)
                )
            }
        }
    }
}

// MARK: - Compiled Modules

/// What this database keeps of each table a compiled module holds: core's
/// `LampModuleCompiledSchema` declares what arrives, and this where it goes.
/// The import copies through it (`ModuleSyncManager.copyCompiled`), and
/// `CompiledModuleLandingTests` holds it to core's declaration and to this
/// database's tables, so a column a compiler adds fails a test here until it
/// has somewhere to go or is left behind on purpose.
enum CompiledModuleLanding {
    struct Table {
        /// The table that keeps the rows here.
        let destination: String
        /// Columns left behind, each with why.
        var notKept: [String: String] = [:]
        /// Columns whose NULL the import replaces with a value of its own,
        /// so the column here may refuse NULL.
        var filledWhenNull: Set<String> = []
    }

    private static let numberedHere = "This database numbers its own rows."

    static func table(_ compiled: String, of kind: ModuleType) -> Table? {
        switch (kind, compiled) {
        case (.book, "book_modules"), (.book, "book_sections"),
             (.commentary, "commentary_books"), (.commentary, "commentary_units"),
             (.dictionary, "dictionary_entries"),
             (.plan, "plans"), (.plan, "plan_days"),
             (.quiz, "quiz_modules"):
            return Table(destination: compiled)
        case (.quiz, "quiz_questions"):
            return Table(destination: compiled, notKept: ["id": numberedHere])
        case (.dictionary, "module_metadata"):
            // Written by `saveImportedModuleMetadata`, not copied.
            return Table(destination: "modules", notKept: [
                "schema_version": "The format's version, which inspecting the module has already read.",
            ])
        case (.translation, "translation_meta"):
            return Table(destination: "translations")
        case (.translation, "books"):
            return Table(destination: "translation_books")
        case (.translation, "verses"):
            return Table(destination: "translation_verses", notKept: ["id": numberedHere])
        case (.translation, "headings"):
            return Table(destination: "translation_headings", notKept: ["id": numberedHere])
        case (.highlights, "highlight_meta"):
            return Table(destination: "highlight_sets", filledWhenNull: ["created", "last_modified"])
        case (.highlights, "highlights"):
            return Table(destination: "highlights", notKept: ["id": numberedHere])
        case (.highlights, "highlight_themes"):
            return Table(destination: "highlight_themes")
        default:
            return nil
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
