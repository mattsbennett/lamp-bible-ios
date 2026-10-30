//
//  ModuleDatabase.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import LampCore
import LampModuleKit

class ModuleDatabase {
    static let shared = ModuleDatabase()

    private var dbQueue: DatabaseQueue!

    private init() {
        do {
            try setupDatabase()
        } catch {
            fatalError("Failed to setup module database: \(error)")
        }
    }

    private var databaseURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("usermodules.db")
    }

    /// Where the database lives, for maintenance that works on its own
    /// connection.
    var fileURL: URL { databaseURL }

    private func setupDatabase() throws {
        // Ensure the Documents directory exists (should always exist, but be safe)
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: documentsDir, withIntermediateDirectories: true)

        var config = Configuration()
        // Don't set PRAGMAs in prepareDatabase - can cause issues on fresh install
        // We'll set them after opening instead

        // `SearchIndexRepair` writes on a second connection, in short
        // transactions. Wait one out rather than failing a write outright.
        config.busyMode = .timeout(5)

        // Try to open the database
        do {
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

            // Set PRAGMAs after database is open (must be outside transaction)
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }

            // Skip integrity_check on startup — it reads every page of the DB.
            // GRDB already validates the header; full checks run via ensureDatabaseHealthy() on error.

            // Run migrations
            try migrator.migrate(dbQueue)

            // Post-migration: Ensure media_json column exists (belt and suspenders)
            try ensureMediaJsonColumn()
        } catch {
            print("[ModuleDatabase] Failed to open database: \(error)")
            print("[ModuleDatabase] Attempting to delete and recreate database...")

            // Delete corrupted database files
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))

            // Create fresh database
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

            // Set PRAGMAs on fresh database too (must be outside transaction)
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }

            try migrator.migrate(dbQueue)
        }
    }

    private func checkDatabaseIntegrity() throws -> Bool {
        try dbQueue.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// Ensure media_json column exists in devotional_entries table
    /// This is a belt-and-suspenders check in case migrations didn't run properly
    private func ensureMediaJsonColumn() throws {
        try dbQueue.write { db in
            let columns = try db.columns(in: "devotional_entries")
            let columnNames = columns.map { $0.name }
            let hasMediaJson = columns.contains { $0.name == "media_json" }
            if !hasMediaJson {
                try db.execute(sql: "ALTER TABLE devotional_entries ADD COLUMN media_json TEXT")
            }
        }
    }

    private func recoverCorruptedDatabase() throws {
        // Close existing connection
        dbQueue = nil

        // Try to recover by copying to a new database
        let backupURL = databaseURL.deletingLastPathComponent().appendingPathComponent("usermodules_backup.db")

        // Delete old backup if exists
        try? FileManager.default.removeItem(at: backupURL)

        // Rename current (corrupted) database as backup
        try? FileManager.default.moveItem(at: databaseURL, to: backupURL)

        // Delete WAL files from corrupted database
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))

        // Create fresh database
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

        print("[ModuleDatabase] Database recovered - data may have been lost")
    }

    // MARK: - Runtime Recovery

    private var isRecovering = false
    private var lastCorruptionError: Date?

    /// Attempts to recover database if corrupted, returns true if recovered or was healthy
    func ensureDatabaseHealthy() -> Bool {
        guard !isRecovering else { return false }

        // Don't attempt recovery more than once per minute to avoid loops
        if let lastError = lastCorruptionError, Date().timeIntervalSince(lastError) < 60 {
            print("[ModuleDatabase] Skipping recovery - too recent")
            return false
        }

        do {
            let isValid = try checkDatabaseIntegrity()
            if !isValid {
                print("[ModuleDatabase] Runtime integrity check failed, recovering...")
                lastCorruptionError = Date()
                isRecovering = true
                defer { isRecovering = false }

                try recoverCorruptedDatabase()
                try migrator.migrate(dbQueue)
                return true
            }
            return true
        } catch {
            print("[ModuleDatabase] Failed to check/recover database: \(error)")
            lastCorruptionError = Date()
            return false
        }
    }

    /// Standard write - no inline recovery to avoid cascading issues
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    /// Read from database
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    /// Write without transaction - for operations like ATTACH/DETACH
    func writeWithoutTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.writeWithoutTransaction(block)
    }

    /// Force reset the database - deletes all data and recreates
    func forceResetDatabase() throws {
        print("[ModuleDatabase] Force resetting database...")

        isRecovering = true
        defer { isRecovering = false }

        // Close existing connection
        dbQueue = nil

        // Delete all database files
        try? FileManager.default.removeItem(at: databaseURL)
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: databaseURL.appendingPathExtension("shm"))

        // Recreate
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try migrator.migrate(dbQueue)

        lastCorruptionError = nil
        print("[ModuleDatabase] Database reset complete")
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Migration v1: Initial schema
        migrator.registerMigration("v1") { db in
            // Module registry
            try db.create(table: "modules") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("author", .text)
                t.column("version", .text)
                t.column("file_path", .text).notNull()
                t.column("file_hash", .text)
                t.column("last_synced", .integer)
                t.column("is_editable", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer)
                t.column("updated_at", .integer)
            }

            // Dictionary entries
            try db.create(table: "dictionary_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("lemma", .text).notNull()
                t.column("transliteration", .text)
                t.column("pronunciation", .text)
                t.column("part_of_speech", .text)
                t.column("definition", .text)
                t.column("short_definition", .text)
                t.column("usage", .text)
                t.column("derivation", .text)
                t.column("references_json", .text)
                t.column("metadata_json", .text)
            }
            try db.create(index: "idx_dict_module", on: "dictionary_entries", columns: ["module_id"])
            try db.create(index: "idx_dict_key", on: "dictionary_entries", columns: ["key"])
            try db.create(index: "idx_dict_lemma", on: "dictionary_entries", columns: ["lemma"])

            // Commentary entries
            try db.create(table: "commentary_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("verse_id", .integer).notNull()
                t.column("book", .integer).notNull()
                t.column("chapter", .integer).notNull()
                t.column("verse", .integer).notNull()
                t.column("heading", .text)
                t.column("content", .text).notNull()
                t.column("segments_json", .text)
            }
            try db.create(index: "idx_comm_module", on: "commentary_entries", columns: ["module_id"])
            try db.create(index: "idx_comm_verse", on: "commentary_entries", columns: ["verse_id"])
            try db.create(index: "idx_comm_chapter", on: "commentary_entries", columns: ["book", "chapter"])

            // Devotional entries
            try db.create(table: "devotional_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("date", .text)
                t.column("tags", .text)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("verse_refs_json", .text)
                t.column("last_modified", .integer)
            }
            try db.create(index: "idx_dev_module", on: "devotional_entries", columns: ["module_id"])
            try db.create(index: "idx_dev_date", on: "devotional_entries", columns: ["date"])

            // Note entries
            try db.create(table: "note_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("verse_id", .integer).notNull()
                t.column("book", .integer).notNull()
                t.column("chapter", .integer).notNull()
                t.column("verse", .integer).notNull()
                t.column("title", .text)
                t.column("content", .text).notNull()
                t.column("verse_refs_json", .text)
                t.column("last_modified", .integer)
            }
            try db.create(index: "idx_note_module", on: "note_entries", columns: ["module_id"])
            try db.create(index: "idx_note_verse", on: "note_entries", columns: ["verse_id"])
            try db.create(index: "idx_note_chapter", on: "note_entries", columns: ["book", "chapter"])

            // FTS5 virtual tables
            try db.execute(sql: """
                CREATE VIRTUAL TABLE dictionary_fts USING fts5(
                    lemma, definition, short_definition, usage,
                    content='dictionary_entries',
                    content_rowid='rowid'
                )
            """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE commentary_fts USING fts5(
                    heading, content,
                    content='commentary_entries',
                    content_rowid='rowid'
                )
            """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE devotional_fts USING fts5(
                    title, content, tags,
                    content='devotional_entries',
                    content_rowid='rowid'
                )
            """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title, content,
                    content='note_entries',
                    content_rowid='rowid'
                )
            """)

            // FTS triggers for dictionary_entries
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_insert AFTER INSERT ON dictionary_entries BEGIN
                    INSERT INTO dictionary_fts(rowid, lemma, definition, short_definition, usage)
                    VALUES (new.rowid, new.lemma, new.definition, new.short_definition, new.usage);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_update AFTER UPDATE ON dictionary_entries BEGIN
                    UPDATE dictionary_fts SET
                        lemma = new.lemma,
                        definition = new.definition,
                        short_definition = new.short_definition,
                        usage = new.usage
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_delete AFTER DELETE ON dictionary_entries BEGIN
                    DELETE FROM dictionary_fts WHERE rowid = old.rowid;
                END
            """)

            // FTS triggers for commentary_entries
            try db.execute(sql: """
                CREATE TRIGGER commentary_fts_insert AFTER INSERT ON commentary_entries BEGIN
                    INSERT INTO commentary_fts(rowid, heading, content)
                    VALUES (new.rowid, new.heading, new.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER commentary_fts_update AFTER UPDATE ON commentary_entries BEGIN
                    UPDATE commentary_fts SET heading = new.heading, content = new.content
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER commentary_fts_delete AFTER DELETE ON commentary_entries BEGIN
                    DELETE FROM commentary_fts WHERE rowid = old.rowid;
                END
            """)

            // FTS triggers for devotional_entries
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_insert AFTER INSERT ON devotional_entries BEGIN
                    INSERT INTO devotional_fts(rowid, title, content, tags)
                    VALUES (new.rowid, new.title, new.content, new.tags);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_update AFTER UPDATE ON devotional_entries BEGIN
                    UPDATE devotional_fts SET title = new.title, content = new.content, tags = new.tags
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_delete AFTER DELETE ON devotional_entries BEGIN
                    DELETE FROM devotional_fts WHERE rowid = old.rowid;
                END
            """)

            // FTS triggers for note_entries
            try db.execute(sql: """
                CREATE TRIGGER note_fts_insert AFTER INSERT ON note_entries BEGIN
                    INSERT INTO note_fts(rowid, title, content)
                    VALUES (new.rowid, new.title, new.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER note_fts_update AFTER UPDATE ON note_entries BEGIN
                    UPDATE note_fts SET title = new.title, content = new.content
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER note_fts_delete AFTER DELETE ON note_entries BEGIN
                    DELETE FROM note_fts WHERE rowid = old.rowid;
                END
            """)
        }

        // Migration v2: Dictionary entries schema change for multiple senses
        migrator.registerMigration("v2") { db in
            // Drop old FTS triggers for dictionary
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictionary_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictionary_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictionary_fts_delete")

            // Create new dictionary_entries table with senses_json
            try db.execute(sql: """
                CREATE TABLE dictionary_entries_new (
                    id TEXT PRIMARY KEY,
                    module_id TEXT NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    lemma TEXT NOT NULL,
                    transliteration TEXT,
                    pronunciation TEXT,
                    senses_json TEXT,
                    metadata_json TEXT
                )
            """)

            // Migrate existing data: convert old columns to senses_json
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, module_id, key, lemma, transliteration, pronunciation,
                       part_of_speech, definition, short_definition, usage, derivation, references_json, metadata_json
                FROM dictionary_entries
            """)

            for row in rows {
                let id: String = row["id"]
                let moduleId: String = row["module_id"]
                let key: String = row["key"]
                let lemma: String = row["lemma"]
                let transliteration: String? = row["transliteration"]
                let pronunciation: String? = row["pronunciation"]
                let partOfSpeech: String? = row["part_of_speech"]
                let definition: String? = row["definition"]
                let shortDefinition: String? = row["short_definition"]
                let usage: String? = row["usage"]
                let derivation: String? = row["derivation"]
                let referencesJson: String? = row["references_json"]
                let metadataJson: String? = row["metadata_json"]

                // Build senses array from legacy fields
                var sensesJson: String? = nil
                if definition != nil || shortDefinition != nil || partOfSpeech != nil {
                    var senseDict: [String: Any] = [:]
                    if let pos = partOfSpeech { senseDict["partOfSpeech"] = pos }
                    if let def = definition { senseDict["definition"] = def }
                    if let shortDef = shortDefinition { senseDict["shortDefinition"] = shortDef }
                    if let usg = usage { senseDict["usage"] = usg }
                    if let deriv = derivation { senseDict["derivation"] = deriv }
                    // Convert integer references to VerseRef format { sv: verseId }
                    if let refsJsonStr = referencesJson,
                       let refsData = refsJsonStr.data(using: .utf8),
                       let refs = try? JSONSerialization.jsonObject(with: refsData) as? [Int] {
                        let verseRefs = refs.map { ["sv": $0] }
                        senseDict["references"] = verseRefs
                    }

                    let sensesArray = [senseDict]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: sensesArray) {
                        sensesJson = String(data: jsonData, encoding: .utf8)
                    }
                }

                try db.execute(sql: """
                    INSERT INTO dictionary_entries_new (id, module_id, key, lemma, transliteration, pronunciation, senses_json, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, moduleId, key, lemma, transliteration, pronunciation, sensesJson, metadataJson])
            }

            // Drop old table and rename new one
            try db.execute(sql: "DROP TABLE dictionary_entries")
            try db.execute(sql: "ALTER TABLE dictionary_entries_new RENAME TO dictionary_entries")

            // Recreate indexes
            try db.create(index: "idx_dict_module", on: "dictionary_entries", columns: ["module_id"])
            try db.create(index: "idx_dict_key", on: "dictionary_entries", columns: ["key"])
            try db.create(index: "idx_dict_lemma", on: "dictionary_entries", columns: ["lemma"])

            // Drop and recreate FTS table
            try db.execute(sql: "DROP TABLE IF EXISTS dictionary_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE dictionary_fts USING fts5(
                    lemma, senses_json,
                    content='dictionary_entries',
                    content_rowid='rowid'
                )
            """)

            // Populate FTS table with existing data
            try db.execute(sql: """
                INSERT INTO dictionary_fts(rowid, lemma, senses_json)
                SELECT rowid, lemma, senses_json FROM dictionary_entries
            """)

            // Create new FTS triggers
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_insert AFTER INSERT ON dictionary_entries BEGIN
                    INSERT INTO dictionary_fts(rowid, lemma, senses_json)
                    VALUES (new.rowid, new.lemma, new.senses_json);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_update AFTER UPDATE ON dictionary_entries BEGIN
                    UPDATE dictionary_fts SET
                        lemma = new.lemma,
                        senses_json = new.senses_json
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictionary_fts_delete AFTER DELETE ON dictionary_entries BEGIN
                    DELETE FROM dictionary_fts WHERE rowid = old.rowid;
                END
            """)
        }

        // Migration v3: Add key_type column to modules and clear file hashes to force re-sync
        migrator.registerMigration("v3") { db in
            try db.alter(table: "modules") { t in
                t.add(column: "key_type", .text)
            }
            // Clear file hashes to force re-import on next sync
            try db.execute(sql: "UPDATE modules SET file_hash = NULL WHERE type = 'dictionary'")
        }

        // Migration v4: New commentary schema with hierarchical structure and annotations
        migrator.registerMigration("v4") { db in
            // Drop old commentary tables and triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS commentary_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS commentary_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS commentary_fts_delete")
            try db.execute(sql: "DROP TABLE IF EXISTS commentary_fts")
            try db.execute(sql: "DROP TABLE IF EXISTS commentary_entries")

            // Create commentary_books table for book-level metadata
            try db.create(table: "commentary_books") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("book_number", .integer).notNull()
                t.column("series_full", .text)      // Full series name (e.g., "New International Commentary")
                t.column("series_abbrev", .text)    // Abbreviated series name (e.g., "NIC")
                t.column("title", .text)
                t.column("author", .text)
                t.column("editor", .text)
                t.column("publisher", .text)
                t.column("year", .integer)
                t.column("abbreviations_json", .text)
                t.column("front_matter_json", .text)
                t.column("indices_json", .text)
            }
            try db.create(index: "idx_comm_books_module", on: "commentary_books", columns: ["module_id"])
            try db.create(index: "idx_comm_books_book", on: "commentary_books", columns: ["book_number"])
            try db.create(index: "idx_comm_books_series", on: "commentary_books", columns: ["series_full"])

            // Create commentary_units table for all content units (sections, pericopae, verses)
            try db.create(table: "commentary_units") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("book", .integer).notNull()
                t.column("chapter", .integer)
                t.column("sv", .integer).notNull()          // Start verse (BBCCCVVV)
                t.column("ev", .integer)                     // End verse (BBCCCVVV)
                t.column("unit_type", .text).notNull()       // 'section', 'pericope', 'verse'
                t.column("level", .integer).notNull().defaults(to: 1)
                t.column("parent_id", .text)
                t.column("title", .text)
                t.column("suffix", .text)                    // For partial verses: 'a', 'b'
                t.column("introduction_json", .text)
                t.column("translation_json", .text)
                t.column("commentary_json", .text)
                t.column("footnotes_json", .text)
                t.column("search_text", .text).notNull()
                t.column("order_index", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_comm_units_module", on: "commentary_units", columns: ["module_id"])
            try db.create(index: "idx_comm_units_verse", on: "commentary_units", columns: ["sv", "ev"])
            try db.create(index: "idx_comm_units_book_chapter", on: "commentary_units", columns: ["book", "chapter"])
            try db.create(index: "idx_comm_units_parent", on: "commentary_units", columns: ["parent_id"])
            try db.create(index: "idx_comm_units_type", on: "commentary_units", columns: ["unit_type"])

            // Create FTS5 virtual table for commentary search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE commentary_units_fts USING fts5(
                    title, search_text,
                    content='commentary_units',
                    content_rowid='rowid'
                )
            """)

            // FTS triggers for commentary_units
            try db.execute(sql: """
                CREATE TRIGGER commentary_units_fts_insert AFTER INSERT ON commentary_units BEGIN
                    INSERT INTO commentary_units_fts(rowid, title, search_text)
                    VALUES (new.rowid, new.title, new.search_text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER commentary_units_fts_update AFTER UPDATE ON commentary_units BEGIN
                    UPDATE commentary_units_fts SET
                        title = new.title,
                        search_text = new.search_text
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER commentary_units_fts_delete AFTER DELETE ON commentary_units BEGIN
                    DELETE FROM commentary_units_fts WHERE rowid = old.rowid;
                END
            """)

            // Clear file hashes for commentary modules to force re-import
            try db.execute(sql: "UPDATE modules SET file_hash = NULL WHERE type = 'commentary'")
        }

        migrator.registerMigration("v5") { db in
            // Add series fields to modules table for dictionary series grouping
            try db.alter(table: "modules") { t in
                t.add(column: "series_full", .text)
                t.add(column: "series_abbrev", .text)
            }
            // Create index for efficient series lookups
            try db.create(index: "idx_modules_series", on: "modules", columns: ["series_full"])
            // Clear file hashes for dictionary modules to force re-import with series info
            try db.execute(sql: "UPDATE modules SET file_hash = NULL WHERE type = 'dictionary'")
        }

        migrator.registerMigration("v6") { db in
            // Force re-import of dictionary modules to pick up series info
            // (in case v5 ran before the file_hash clearing was added)
            try db.execute(sql: "UPDATE modules SET file_hash = NULL WHERE type = 'dictionary'")
        }

        migrator.registerMigration("v7") { db in
            // Force re-import of dictionary modules after SQLite import fix
            // Now reads series_full/series_abbrev from module_metadata table
            try db.execute(sql: "UPDATE modules SET file_hash = NULL WHERE type = 'dictionary'")
        }

        // Migration v8: Enhanced notes schema with footnotes and search_text
        migrator.registerMigration("v8") { db in
            // Add new columns to note_entries for footnotes and combined search text
            try db.alter(table: "note_entries") { t in
                t.add(column: "footnotes_json", .text)  // JSON array of footnotes
                t.add(column: "search_text", .text)     // Combined text for FTS (content + footnotes)
            }

            // Populate search_text from existing content for backward compatibility
            try db.execute(sql: """
                UPDATE note_entries SET search_text = content
            """)

            // Drop old FTS triggers for notes
            try db.execute(sql: "DROP TRIGGER IF EXISTS note_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS note_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS note_fts_delete")

            // Drop and recreate note_fts to use search_text instead of content
            try db.execute(sql: "DROP TABLE IF EXISTS note_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts USING fts5(
                    title, search_text,
                    content='note_entries',
                    content_rowid='rowid'
                )
            """)

            // Repopulate FTS index
            try db.execute(sql: """
                INSERT INTO note_fts(rowid, title, search_text)
                SELECT rowid, title, search_text FROM note_entries
            """)

            // Create new FTS triggers
            try db.execute(sql: """
                CREATE TRIGGER note_fts_insert AFTER INSERT ON note_entries BEGIN
                    INSERT INTO note_fts(rowid, title, search_text)
                    VALUES (new.rowid, new.title, new.search_text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER note_fts_update AFTER UPDATE ON note_entries BEGIN
                    UPDATE note_fts SET title = new.title, search_text = new.search_text
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER note_fts_delete AFTER DELETE ON note_entries BEGIN
                    DELETE FROM note_fts WHERE rowid = old.rowid;
                END
            """)
        }

        // Migration v9: Translation tables with GRDB support
        migrator.registerMigration("v9") { db in
            // Create translations table (metadata)
            try db.create(table: "translations") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("abbreviation", .text).notNull()
                t.column("description", .text)
                t.column("language", .text).notNull()
                t.column("language_name", .text)
                t.column("text_direction", .text).notNull().defaults(to: "ltr")
                t.column("translation_philosophy", .text)
                t.column("year", .integer)
                t.column("publisher", .text)
                t.column("copyright", .text)
                t.column("copyright_year", .integer)
                t.column("license", .text)
                t.column("source_texts_json", .text)
                t.column("features_json", .text)
                t.column("versification", .text).defaults(to: "standard")
                t.column("file_path", .text)
                t.column("file_hash", .text)
                t.column("last_synced", .integer)
                t.column("is_bundled", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer)
                t.column("updated_at", .integer)
            }
            try db.create(index: "idx_translations_language", on: "translations", columns: ["language"])
            try db.create(index: "idx_translations_bundled", on: "translations", columns: ["is_bundled"])

            // Create translation_books table (book metadata per translation)
            try db.create(table: "translation_books") { t in
                t.column("id", .text).primaryKey()
                t.column("translation_id", .text).notNull().references("translations", onDelete: .cascade)
                t.column("book_number", .integer).notNull()
                t.column("book_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("testament", .text).notNull()
                t.column("chapter_count", .integer).notNull()
                t.uniqueKey(["translation_id", "book_number"])
            }
            try db.create(index: "idx_trans_books_translation", on: "translation_books", columns: ["translation_id"])
            try db.create(index: "idx_trans_books_number", on: "translation_books", columns: ["book_number"])

            // Create translation_verses table
            try db.create(table: "translation_verses") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("translation_id", .text).notNull().references("translations", onDelete: .cascade)
                t.column("ref", .integer).notNull()
                t.column("book", .integer).notNull()
                t.column("chapter", .integer).notNull()
                t.column("verse", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("annotations_json", .text)
                t.column("footnotes_json", .text)
                t.column("footnote_refs_json", .text)
                t.column("paragraph", .integer).defaults(to: 0)
                t.column("poetry_json", .text)
                t.uniqueKey(["translation_id", "ref"])
            }
            try db.create(index: "idx_verses_translation", on: "translation_verses", columns: ["translation_id"])
            try db.create(index: "idx_verses_ref", on: "translation_verses", columns: ["ref"])
            try db.create(index: "idx_verses_book_chapter", on: "translation_verses", columns: ["translation_id", "book", "chapter"])

            // Create translation_headings table
            try db.create(table: "translation_headings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("translation_id", .text).notNull().references("translations", onDelete: .cascade)
                t.column("book", .integer).notNull()
                t.column("chapter", .integer).notNull()
                t.column("before_verse", .integer).notNull()
                t.column("level", .integer).notNull().defaults(to: 1)
                t.column("text", .text).notNull()
            }
            try db.create(index: "idx_headings_chapter", on: "translation_headings", columns: ["translation_id", "book", "chapter"])

            // Create FTS5 virtual table for verse search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE translation_verses_fts USING fts5(
                    text,
                    content='translation_verses',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """)

            // FTS triggers for translation_verses
            try db.execute(sql: """
                CREATE TRIGGER translation_verses_fts_insert AFTER INSERT ON translation_verses BEGIN
                    INSERT INTO translation_verses_fts(rowid, text)
                    VALUES (new.id, new.text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER translation_verses_fts_update AFTER UPDATE ON translation_verses BEGIN
                    UPDATE translation_verses_fts SET text = new.text
                    WHERE rowid = new.id;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER translation_verses_fts_delete AFTER DELETE ON translation_verses BEGIN
                    DELETE FROM translation_verses_fts WHERE rowid = old.id;
                END
            """)
        }

        // Migration v10: Reading plans tables
        migrator.registerMigration("v10") { db in
            // Create plans table (metadata)
            try db.create(table: "plans") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("author", .text)
                t.column("full_description", .text)
                t.column("duration", .integer)           // Number of days (typically 366)
                t.column("readings_per_day", .integer)   // Typical readings per day
                t.column("file_path", .text)
                t.column("file_hash", .text)
                t.column("last_synced", .integer)
                t.column("created_at", .integer)
                t.column("updated_at", .integer)
            }

            // Create plan_days table
            try db.create(table: "plan_days") { t in
                t.column("plan_id", .text).notNull().references("plans", onDelete: .cascade)
                t.column("day", .integer).notNull()
                t.column("readings_json", .text)  // JSON array of readings [{sv:..., ev:...}]
                t.primaryKey(["plan_id", "day"])
            }
            try db.create(index: "idx_plan_days_plan", on: "plan_days", columns: ["plan_id"])
        }

        // Migration v11: Rename bible-notes module to notes
        migrator.registerMigration("v11") { db in
            // Check if bible-notes module exists
            let oldModuleExists = try Row.fetchOne(db, sql: "SELECT 1 FROM modules WHERE id = 'bible-notes'") != nil

            if oldModuleExists {
                // Check if new "notes" module already exists
                let newModuleExists = try Row.fetchOne(db, sql: "SELECT 1 FROM modules WHERE id = 'notes'") != nil

                if newModuleExists {
                    // Both exist - migrate entries from bible-notes to notes, then delete old module
                    try db.execute(sql: "UPDATE note_entries SET module_id = 'notes' WHERE module_id = 'bible-notes'")
                    try db.execute(sql: "DELETE FROM modules WHERE id = 'bible-notes'")
                } else {
                    // Only old exists - update note_entries first (disable FK temporarily), then rename module
                    try db.execute(sql: "PRAGMA foreign_keys = OFF")
                    try db.execute(sql: "UPDATE note_entries SET module_id = 'notes' WHERE module_id = 'bible-notes'")
                    try db.execute(sql: "UPDATE modules SET id = 'notes', name = 'Notes', file_path = 'notes.json' WHERE id = 'bible-notes'")
                    try db.execute(sql: "PRAGMA foreign_keys = ON")
                }
            }
        }

        // Migration v12: Commentary series table and series_id in modules
        migrator.registerMigration("v12") { db in
            // Create commentary_series table for series-level metadata
            try db.create(table: "commentary_series") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("abbreviation", .text).notNull()
                t.column("description", .text)
                t.column("editor", .text)
                t.column("publisher", .text)
                t.column("testament", .text)            // "OT", "NT", or "both"
                t.column("language", .text)
                t.column("website", .text)
                t.column("editor_preface_json", .text)  // Editor's preface as AnnotatedText JSON
                t.column("introduction_json", .text)    // Series introduction as AnnotatedText JSON
                t.column("abbreviations_json", .text)   // Series-wide abbreviations JSON array
                t.column("bibliography_json", .text)    // Series bibliography JSON array
                t.column("volumes_json", .text)         // List of volumes in series JSON array
            }

            // Add series_id column to modules table (FK to commentary_series)
            try db.alter(table: "modules") { t in
                t.add(column: "series_id", .text).references("commentary_series", onDelete: .setNull)
            }

            // Create index for efficient series lookups on commentary modules
            try db.create(index: "idx_modules_series_id", on: "modules", columns: ["series_id"])
        }

        // Migration v13: Enhanced devotional schema for user-editable devotionals
        migrator.registerMigration("v13") { db in
            // Drop old FTS triggers for devotionals
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_delete")

            // Drop old FTS table
            try db.execute(sql: "DROP TABLE IF EXISTS devotional_fts")

            // Check if old table has month_day column (legacy) or date column (current)
            let columns = try db.columns(in: "devotional_entries")
            let columnNames = Set(columns.map { $0.name })
            let hasMonthDay = columnNames.contains("month_day")
            let hasContentJson = columnNames.contains("content_json")

            // Create new devotional_entries table with full schema
            try db.execute(sql: """
                CREATE TABLE devotional_entries_new (
                    id TEXT PRIMARY KEY,
                    module_id TEXT NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
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
                    related_ids TEXT,
                    created INTEGER,
                    last_modified INTEGER,
                    search_text TEXT
                )
            """)

            // Migrate existing data from old table based on schema
            if hasMonthDay {
                // Legacy schema: month_day -> date, content -> content_json
                try db.execute(sql: """
                    INSERT INTO devotional_entries_new (id, module_id, title, date, tags, content_json, last_modified, search_text)
                    SELECT id, module_id, title, month_day, tags, content, last_modified, content
                    FROM devotional_entries
                """)
            } else if hasContentJson {
                // Already has new schema, copy as-is
                try db.execute(sql: """
                    INSERT INTO devotional_entries_new (id, module_id, title, date, tags, content_json, last_modified, search_text)
                    SELECT id, module_id, title, date, tags, content_json, last_modified, search_text
                    FROM devotional_entries
                """)
            } else {
                // Current schema: date exists, content -> content_json
                try db.execute(sql: """
                    INSERT INTO devotional_entries_new (id, module_id, title, date, tags, content_json, last_modified, search_text)
                    SELECT id, module_id, title, date, tags, content, last_modified, content
                    FROM devotional_entries
                """)
            }

            // Drop old table and rename new one
            try db.execute(sql: "DROP TABLE devotional_entries")
            try db.execute(sql: "ALTER TABLE devotional_entries_new RENAME TO devotional_entries")

            // Recreate indexes
            try db.create(index: "idx_dev_module", on: "devotional_entries", columns: ["module_id"])
            try db.create(index: "idx_dev_date", on: "devotional_entries", columns: ["date"])
            try db.create(index: "idx_dev_category", on: "devotional_entries", columns: ["category"])
            try db.create(index: "idx_dev_series", on: "devotional_entries", columns: ["series_id"])

            // Create new FTS5 virtual table (title + search_text for manageable index size)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE devotional_entries_fts USING fts5(
                    title, search_text,
                    content='devotional_entries',
                    content_rowid='rowid'
                )
            """)

            // Populate FTS table with existing data
            try db.execute(sql: """
                INSERT INTO devotional_entries_fts(rowid, title, search_text)
                SELECT rowid, title, search_text FROM devotional_entries
            """)

            // Create new FTS triggers
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_insert AFTER INSERT ON devotional_entries BEGIN
                    INSERT INTO devotional_entries_fts(rowid, title, search_text)
                    VALUES (new.rowid, new.title, new.search_text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_update AFTER UPDATE ON devotional_entries BEGIN
                    UPDATE devotional_entries_fts SET
                        title = new.title,
                        search_text = new.search_text
                    WHERE rowid = new.rowid;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_delete AFTER DELETE ON devotional_entries BEGIN
                    DELETE FROM devotional_entries_fts WHERE rowid = old.rowid;
                END
            """)
        }

        // v14: Fix FTS table - remove external content mode to prevent corruption
        // External content FTS tables can get out of sync and cause corruption
        migrator.registerMigration("v14") { db in
            // Check if the problematic FTS table exists
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='devotional_entries_fts'")
            guard !tables.isEmpty else { return }

            print("[ModuleDatabase] v14: Rebuilding FTS table without external content mode")

            // Drop old triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS devotional_fts_delete")

            // Drop old FTS table
            try db.execute(sql: "DROP TABLE IF EXISTS devotional_entries_fts")

            // Create new self-contained FTS table (stores its own content)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS devotional_entries_fts USING fts5(
                    id UNINDEXED,
                    title,
                    search_text
                )
            """)

            // Populate from existing data
            try db.execute(sql: """
                INSERT INTO devotional_entries_fts(id, title, search_text)
                SELECT id, title, search_text FROM devotional_entries
            """)

            // Create triggers that use id instead of rowid
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_insert AFTER INSERT ON devotional_entries BEGIN
                    INSERT INTO devotional_entries_fts(id, title, search_text)
                    VALUES (new.id, new.title, new.search_text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_update AFTER UPDATE ON devotional_entries BEGIN
                    UPDATE devotional_entries_fts SET
                        title = new.title,
                        search_text = new.search_text
                    WHERE id = new.id;
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER devotional_fts_delete AFTER DELETE ON devotional_entries BEGIN
                    DELETE FROM devotional_entries_fts WHERE id = old.id;
                END
            """)
        }

        // v15: Add recordChangeTag for CloudKit sync
        migrator.registerMigration("v15") { db in
            // Add record_change_tag column to note_entries
            let noteColumns = try db.columns(in: "note_entries")
            if !noteColumns.contains(where: { $0.name == "record_change_tag" }) {
                try db.execute(sql: "ALTER TABLE note_entries ADD COLUMN record_change_tag TEXT")
            }

            // Add record_change_tag column to devotional_entries
            let devotionalColumns = try db.columns(in: "devotional_entries")
            if !devotionalColumns.contains(where: { $0.name == "record_change_tag" }) {
                try db.execute(sql: "ALTER TABLE devotional_entries ADD COLUMN record_change_tag TEXT")
            }
        }

        // v16: Add publication and subscription tables for devotional sharing
        migrator.registerMigration("v16") { db in
            // Publications (owner side) - tracks feeds that user publishes
            try db.create(table: "devotional_publications", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("filter_type", .text).notNull()  // 'tag', 'category', 'all'
                t.column("filter_values", .text)          // Comma-separated
                t.column("module_id", .text).notNull()
                t.column("last_published", .integer)
                t.column("subscriber_count", .integer)
            }

            // Subscriptions (subscriber side) - tracks feeds user subscribes to
            try db.create(table: "devotional_subscriptions", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("publication_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("url", .text).notNull()
                t.column("storage_type", .text).notNull()  // 'icloud', 'webdav'
                t.column("last_synced", .integer)
                t.column("last_remote_version", .integer)
                t.column("is_enabled", .integer).notNull().defaults(to: 1)
            }

            // Add subscription_id and is_read_only columns to devotional_entries
            let columns = try db.columns(in: "devotional_entries")
            if !columns.contains(where: { $0.name == "subscription_id" }) {
                try db.execute(sql: "ALTER TABLE devotional_entries ADD COLUMN subscription_id TEXT")
            }
            if !columns.contains(where: { $0.name == "is_read_only" }) {
                try db.execute(sql: "ALTER TABLE devotional_entries ADD COLUMN is_read_only INTEGER DEFAULT 0")
            }

            // Index for subscription lookups
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_devotional_subscription
                ON devotional_entries(subscription_id)
            """)
        }

        // v17: Add devotional_media table for embedded images and audio
        migrator.registerMigration("v17") { db in
            try db.create(table: "devotional_media", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("devotional_id", .text).notNull()
                t.column("module_id", .text).notNull()
                t.column("type", .text).notNull()           // 'image' or 'audio'
                t.column("filename", .text).notNull()
                t.column("mime_type", .text).notNull()
                t.column("size", .integer)
                t.column("width", .integer)                 // Images only
                t.column("height", .integer)                // Images only
                t.column("duration", .double)               // Audio only (seconds)
                t.column("waveform_json", .text)            // Audio only (JSON array of floats)
                t.column("transcription", .text)            // Audio only
                t.column("alt_text", .text)                 // Images only (accessibility)
                t.column("created", .integer)

                t.foreignKey(["devotional_id"], references: "devotional_entries", columns: ["id"], onDelete: .cascade)
                t.foreignKey(["module_id"], references: "modules", columns: ["id"], onDelete: .cascade)
            }

            try db.create(index: "idx_devotional_media_devotional", on: "devotional_media", columns: ["devotional_id"])
            try db.create(index: "idx_devotional_media_module", on: "devotional_media", columns: ["module_id"])

            // Add media_json column to devotional_entries for inline media references
            let columns = try db.columns(in: "devotional_entries")
            if !columns.contains(where: { $0.name == "media_json" }) {
                try db.execute(sql: "ALTER TABLE devotional_entries ADD COLUMN media_json TEXT")
            }
        }

        // v18: Highlight sets and highlights tables
        migrator.registerMigration("v18") { db in
            // Create highlight_sets table for set metadata
            try db.create(table: "highlight_sets", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("translation_id", .text).notNull()  // The translation this set belongs to
                t.column("created", .integer).notNull()
                t.column("last_modified", .integer).notNull()
            }
            try db.create(index: "idx_highlight_sets_module", on: "highlight_sets", columns: ["module_id"])
            try db.create(index: "idx_highlight_sets_translation", on: "highlight_sets", columns: ["translation_id"])

            // Create highlights table for individual highlights
            try db.create(table: "highlights", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("set_id", .text).notNull().references("highlight_sets", onDelete: .cascade)
                t.column("ref", .integer).notNull()          // BBCCCVVV verse reference
                t.column("sc", .integer).notNull()           // Start character offset
                t.column("ec", .integer).notNull()           // End character offset
                t.column("style", .integer).notNull().defaults(to: 0)  // 0=highlight, 1=underline solid, etc.
                t.column("color", .text)                      // Hex color (nil = default yellow)
            }
            try db.create(index: "idx_highlights_set", on: "highlights", columns: ["set_id"])
            try db.create(index: "idx_highlights_ref", on: "highlights", columns: ["ref"])
            try db.create(index: "idx_highlights_set_ref", on: "highlights", columns: ["set_id", "ref"])
        }

        // v19: Rename month_day column to date in devotional_entries
        migrator.registerMigration("v19") { db in
            // Check if month_day column exists (only for existing databases)
            let columns = try db.columns(in: "devotional_entries")
            let hasMonthDay = columns.contains { $0.name == "month_day" }

            guard hasMonthDay else {
                // Column already named 'date' (new database), nothing to do
                return
            }

            try db.rename(table: "devotional_entries", to: "devotional_entries_old")
            try db.create(table: "devotional_entries") { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("modules", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("author", .text)
                t.column("date", .text)
                t.column("tags", .text)
                t.column("category", .text)
                t.column("series_id", .text)
                t.column("series_name", .text)
                t.column("series_order", .integer)
                t.column("key_scriptures_json", .text)
                t.column("summary_json", .text)
                t.column("content_json", .text).notNull()
                t.column("footnotes_json", .text)
                t.column("related_ids", .text)
                t.column("created", .integer).notNull()
                t.column("last_modified", .integer)
                t.column("search_text", .text)
                t.column("record_change_tag", .text)
                t.column("subscription_id", .text)
                t.column("is_read_only", .integer)
                t.column("media_json", .text)
            }
            // Copy data from old table, mapping month_day to date
            // Note: media_json may not exist in old table, so we use NULL
            try db.execute(sql: """
                INSERT INTO devotional_entries (
                    id, module_id, title, subtitle, author, date, tags, category,
                    series_id, series_name, series_order, key_scriptures_json, summary_json,
                    content_json, footnotes_json, related_ids, created, last_modified,
                    search_text, record_change_tag, subscription_id, is_read_only, media_json
                )
                SELECT
                    id, module_id, title, subtitle, author, month_day, tags, category,
                    series_id, series_name, series_order, key_scriptures_json, summary_json,
                    content_json, footnotes_json, related_ids, created, last_modified,
                    search_text, record_change_tag, subscription_id, is_read_only, NULL
                FROM devotional_entries_old
            """)
            try db.drop(table: "devotional_entries_old")
            try db.create(index: "idx_dev_module", on: "devotional_entries", columns: ["module_id"], ifNotExists: true)
            try db.create(index: "idx_dev_date", on: "devotional_entries", columns: ["date"], ifNotExists: true)
        }

        // v20: Add media_json column to devotional_entries (for databases that ran v19 before this column was added)
        migrator.registerMigration("v20") { db in
            let columns = try db.columns(in: "devotional_entries")
            let hasMediaJson = columns.contains { $0.name == "media_json" }

            guard !hasMediaJson else {
                // Column already exists, nothing to do
                return
            }

            try db.alter(table: "devotional_entries") { t in
                t.add(column: "media_json", .text)
            }
        }

        // v21: Quiz modules tables
        migrator.registerMigration("v21") { db in
            try db.create(table: "quiz_modules", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("plan_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("questions_per_reading", .integer).notNull().defaults(to: 0)
                t.column("age_groups_json", .text)
            }

            try db.create(table: "quiz_questions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("quiz_module_id", .text).notNull().references("quiz_modules", onDelete: .cascade)
                t.column("day", .integer).notNull()
                t.column("sv", .integer).notNull()
                t.column("ev", .integer).notNull()
                t.column("age_group", .text).notNull()
                t.column("question_index", .integer).notNull()
                t.column("question_json", .text).notNull()
                t.column("answer_json", .text).notNull()
                t.column("theme", .text).notNull()
                t.column("christ_focused", .boolean).notNull().defaults(to: false)
                t.column("references_json", .text)
                t.column("cross_references_json", .text)
            }

            try db.create(index: "idx_quiz_questions_module_day", on: "quiz_questions", columns: ["quiz_module_id", "day"])
            try db.create(index: "idx_quiz_questions_module_age", on: "quiz_questions", columns: ["quiz_module_id", "age_group"])
        }

        // v22: Highlight themes table for color+style meaning associations
        migrator.registerMigration("v22") { db in
            try db.create(table: "highlight_themes", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()  // Composite: {setId}_{color}_{style}
                t.column("set_id", .text).notNull().references("highlight_sets", onDelete: .cascade)
                t.column("color", .text).notNull()  // Hex color code
                t.column("style", .integer).notNull()  // 0=highlight, 1=underlineSolid, etc.
                t.column("name", .text).notNull()  // Short theme name
                t.column("description", .text)  // Optional longer description
            }
            try db.create(index: "idx_highlight_themes_set", on: "highlight_themes", columns: ["set_id"])
            try db.create(index: "idx_highlight_themes_color_style", on: "highlight_themes", columns: ["color", "style"])
        }

        // v23: Hierarchical long-form book modules
        migrator.registerMigration("v23") { db in
            try db.create(table: "book_modules", ifNotExists: true) { t in
                t.column("id", .text).primaryKey().references("modules", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("description", .text)
                t.column("author", .text)
                t.column("editor", .text)
                t.column("publisher", .text)
                t.column("year", .integer)
                t.column("edition", .text)
                t.column("isbn", .text)
                t.column("language", .text).notNull()
                t.column("text_direction", .text).notNull().defaults(to: "ltr")
                t.column("copyright", .text)
                t.column("license", .text)
                t.column("version", .text)
                t.column("schema_version", .text).notNull()
                t.column("tags_json", .text)
                t.column("cover_media_id", .text)
                t.column("is_editable", .integer).notNull().defaults(to: 0)
                t.column("created", .integer)
                t.column("last_modified", .integer)
                t.column("footnotes_json", .text)
                t.column("media_json", .text)
            }

            try db.create(table: "book_sections", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("module_id", .text).notNull().references("book_modules", onDelete: .cascade)
                t.column("section_id", .text).notNull()
                t.column("parent_id", .text).references("book_sections", onDelete: .cascade)
                t.column("section_type", .text).notNull()
                t.column("number", .text)
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("depth", .integer).notNull()
                t.column("order_index", .integer).notNull()
                t.column("key_scriptures_json", .text)
                t.column("content_json", .text).notNull()
                t.column("search_text", .text).notNull().defaults(to: "")
                t.uniqueKey(["module_id", "section_id"])
            }
            try db.create(index: "idx_book_sections_module", on: "book_sections", columns: ["module_id"])
            try db.create(index: "idx_book_sections_parent", on: "book_sections", columns: ["parent_id", "order_index"])
            try db.create(index: "idx_book_sections_type", on: "book_sections", columns: ["module_id", "section_type"])

            try db.execute(sql: """
                CREATE VIRTUAL TABLE book_sections_fts USING fts5(
                    title,
                    search_text,
                    content='book_sections',
                    content_rowid='rowid'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER book_sections_fts_insert AFTER INSERT ON book_sections BEGIN
                    INSERT INTO book_sections_fts(rowid, title, search_text)
                    VALUES (new.rowid, new.title, new.search_text);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER book_sections_fts_delete AFTER DELETE ON book_sections BEGIN
                    INSERT INTO book_sections_fts(book_sections_fts, rowid, title, search_text)
                    VALUES ('delete', old.rowid, old.title, old.search_text);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER book_sections_fts_update AFTER UPDATE ON book_sections BEGIN
                    INSERT INTO book_sections_fts(book_sections_fts, rowid, title, search_text)
                    VALUES ('delete', old.rowid, old.title, old.search_text);
                    INSERT INTO book_sections_fts(rowid, title, search_text)
                    VALUES (new.rowid, new.title, new.search_text);
                END
                """)
        }

        // This record is local to the module database so the wipe can remove
        // it in the same transaction as the syncable content.
        migrator.registerMigration("v24_backend_transition") { db in
            try db.create(table: "sync_backend_transition") { t in
                t.column("id", .integer).primaryKey()
                t.column("previous_settings_json", .text).notNull()
            }
        }

        migrator.registerMigration("v25_pending_module_conflicts") { db in
            try db.create(table: "sync_pending_module_conflicts") { t in
                t.column("module_id", .text).notNull()
                t.column("type", .text).notNull()
                t.column("entry_key", .text).notNull()
                t.column("payload", .blob).notNull()
                t.primaryKey(["module_id", "type", "entry_key"])
            }
            // Older builds could acknowledge a remote hash while keeping its
            // equal-timestamp conflict only in memory. Re-read editable
            // modules once so those conflicts can enter the durable table.
            try db.execute(sql: """
                UPDATE modules SET file_hash = NULL, last_synced = NULL
                WHERE type IN ('notes', 'devotional')
                """)
        }

        migrator.registerMigration("v26_pending_module_publications") { db in
            try db.create(table: "sync_pending_module_publications") { t in
                t.column("module_id", .text).primaryKey()
                t.column("type", .text).notNull()
            }
        }

        // The search indexes' delete and update triggers removed rows in a way
        // an external-content index cannot act on, so every row ever replaced
        // stayed indexed. Triggers only: the indexes themselves are rebuilt by
        // `SearchIndexRepair`, off the launch path, because one of them had
        // grown to gigabytes.
        migrator.registerMigration("v27_search_index_delete_triggers") { db in
            try ExternalContentSearchIndex.installTriggers(in: db)
        }

        // Design B keeps each module as its own file on the server, and needs
        // to know per file what this device last installed and last uploaded:
        // whether to upload is this device's export compared with its own
        // last upload, never with the server's bytes.
        migrator.registerMigration("v28_sync_file_records") { db in
            // Per sync endpoint: revisions are the provider's, and a switch
            // of provider must start from nothing, not from "already uploaded".
            try db.execute(sql: """
                CREATE TABLE sync_file_records (
                    source TEXT NOT NULL,
                    path TEXT NOT NULL,
                    last_revision TEXT,
                    uploaded_digest TEXT,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY (source, path)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE sync_pending_manifest_changes (
                    source TEXT NOT NULL,
                    path TEXT NOT NULL,
                    change TEXT NOT NULL,
                    revision TEXT,
                    replacing TEXT,
                    at INTEGER NOT NULL,
                    PRIMARY KEY (source, path)
                )
                """)
        }

        // When each note, writing or highlight was last saved here and when
        // it was deleted, in the shape the Mac keeps. Sync merges content as
        // a union, so without this a deletion here is undone by the next
        // copy that still has the item.
        migrator.registerMigration("v29_personal_sync_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE personal_sync_ledger (
                    kind TEXT NOT NULL,
                    item_key TEXT NOT NULL,
                    present_since INTEGER,
                    deleted_at INTEGER,
                    PRIMARY KEY (kind, item_key)
                )
                """)
        }

        // v30: The pass engine is core's, and keeps a write the bundle has not
        // named yet apart from what was installed: only a bundle naming that
        // very revision confirms it.
        migrator.registerMigration("v30_sync_pending_revision") { db in
            try db.execute(sql: "ALTER TABLE sync_file_records ADD COLUMN pending_revision TEXT")
        }

        // v31: A user dictionary is searched by its definitions as plain text,
        // as the bundled ones are, not by the JSON they are stored in, whose
        // field names matched every entry. Rebuilt here on lemmas alone, which
        // is quick; the text is filled in off the launch path
        // (`SearchIndexMaintenance`), each row's index entry following it.
        migrator.registerMigration("v31_dictionary_search_text") { db in
            guard try db.tableExists("dictionary_entries") else { return }
            if try !db.columns(in: "dictionary_entries").contains(where: { $0.name == "search_text" }) {
                try db.execute(sql: "ALTER TABLE dictionary_entries ADD COLUMN search_text TEXT")
            }
            let index = ExternalContentSearchIndex.dictionary
            for suffix in ["insert", "update", "delete"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(index.name)_\(suffix)")
            }
            try db.execute(sql: "DROP TABLE IF EXISTS \(index.name)")
            try db.execute(sql: index.createIndexSQL(named: index.name))
            try db.execute(sql: "INSERT INTO \(index.name)(\(index.name)) VALUES ('rebuild')")
            try index.installTriggers(in: db)
        }

        return migrator
    }

    // MARK: - Module CRUD

    func replacePendingModuleConflicts<T: Encodable>(
        moduleId: String,
        type: ModuleType,
        conflicts: [T],
        key: (T) -> String
    ) throws {
        let encoded = try conflicts.map { (key($0), try JSONEncoder().encode($0)) }
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ? AND type = ?",
                arguments: [moduleId, type.rawValue]
            )
            for (entryKey, payload) in encoded {
                try db.execute(
                    sql: "INSERT INTO sync_pending_module_conflicts (module_id, type, entry_key, payload) VALUES (?, ?, ?, ?)",
                    arguments: [moduleId, type.rawValue, entryKey, payload]
                )
            }
        }
    }

    func firstPendingModuleConflicts<T: Decodable>(
        type: ModuleType,
        as _: T.Type
    ) throws -> (moduleId: String, conflicts: [T])? {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT module_id, payload FROM sync_pending_module_conflicts WHERE type = ? ORDER BY module_id, entry_key",
                arguments: [type.rawValue]
            )
            guard let first = rows.first else { return nil }
            let moduleId: String = first["module_id"]
            let conflicts = try rows
                .filter { (row: Row) in (row["module_id"] as String) == moduleId }
                .map { (row: Row) in
                    try JSONDecoder().decode(T.self, from: row["payload"] as Data)
                }
            return (moduleId, conflicts)
        }
    }

    func hasPendingModuleConflicts(moduleId: String) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sync_pending_module_conflicts WHERE module_id = ? LIMIT 1",
                arguments: [moduleId]
            ) != nil
        }
    }

    func pendingModuleConflictExists(moduleId: String, type: ModuleType, key: String) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sync_pending_module_conflicts WHERE module_id = ? AND type = ? AND entry_key = ? LIMIT 1",
                arguments: [moduleId, type.rawValue, key]
            ) != nil
        }
    }

    func markPendingModulePublication(moduleId: String, type: ModuleType) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_pending_module_publications (module_id, type) VALUES (?, ?)",
                arguments: [moduleId, type.rawValue]
            )
        }
    }

    func pendingModulePublications(type: ModuleType) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT module_id FROM sync_pending_module_publications WHERE type = ? ORDER BY module_id",
                arguments: [type.rawValue]
            )
        }
    }

    func clearPendingModulePublication(moduleId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM sync_pending_module_publications WHERE module_id = ?",
                arguments: [moduleId]
            )
        }
    }

    func removePendingModuleConflict(moduleId: String, type: ModuleType, key: String) throws -> Bool {
        try dbQueue.write { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sync_pending_module_conflicts WHERE module_id = ? AND type = ? AND entry_key = ? LIMIT 1",
                arguments: [moduleId, type.rawValue, key]
            ) != nil
            guard exists else { throw SyncError.conflictDetected }
            try db.execute(
                sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ? AND type = ? AND entry_key = ?",
                arguments: [moduleId, type.rawValue, key]
            )
            let hasMore = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM sync_pending_module_conflicts WHERE module_id = ? LIMIT 1",
                arguments: [moduleId]
            ) != nil
            if !hasMore {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sync_pending_module_publications (module_id, type) VALUES (?, ?)",
                    arguments: [moduleId, type.rawValue]
                )
            }
            return hasMore
        }
    }

    func saveModule(_ module: Module) throws {
        try dbQueue.write { db in
            try module.save(db)
        }
    }

    func deleteModule(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM sync_pending_module_publications WHERE module_id = ?",
                arguments: [id]
            )
            _ = try Module.deleteOne(db, key: id)
        }
    }

    func getModule(id: String) throws -> Module? {
        try dbQueue.read { db in
            try Module.fetchOne(db, key: id)
        }
    }

    func getAllModules(type: ModuleType? = nil) throws -> [Module] {
        try dbQueue.read { db in
            if let type = type {
                return try Module.filter(Column("type") == type.rawValue).fetchAll(db)
            } else {
                return try Module.fetchAll(db)
            }
        }
    }

    // MARK: - Long-form Book CRUD

    func getBookModules() throws -> [BookModule] {
        try dbQueue.read { db in
            try BookModule.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    func getBookModule(id: String) throws -> BookModule? {
        try dbQueue.read { db in
            try BookModule.fetchOne(db, key: id)
        }
    }

    func getBookSections(moduleId: String) throws -> [BookSection] {
        try dbQueue.read { db in
            try BookSection
                .filter(Column("module_id") == moduleId)
                .order(Column.rowID)
                .fetchAll(db)
        }
    }

    /// One section's title, without the text under it: naming where each
    /// book was left would otherwise read every one of those sections whole.
    func getBookSectionTitle(id: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM book_sections WHERE id = ?", arguments: [id])
        }
    }

    func getBookSection(id: String) throws -> BookSection? {
        try dbQueue.read { db in
            try BookSection.fetchOne(db, key: id)
        }
    }


    // MARK: - Note Entry CRUD

    /// A save made on this device. Sync imports write rows directly and do
    /// not come through here, so they never mask a deletion made elsewhere.
    func saveNoteEntry(_ entry: NoteEntry) throws {
        try dbQueue.write { db in
            try entry.save(db)
            try Self.recordPersonalPresence(db, .note, entry.id)
        }
    }

    /// Empties a notes or writing module, each entry deleted as if one at a
    /// time: every deletion goes in the ledger, so it reaches the devices
    /// that still hold the entry rather than being merged back from them.
    func resetPersonalModule(moduleId: String) throws {
        try dbQueue.write { db in
            for id in try String.fetchAll(db, sql: "SELECT id FROM note_entries WHERE module_id = ?", arguments: [moduleId]) {
                try Self.recordPersonalDeletion(db, .note, id)
            }
            for id in try String.fetchAll(db, sql: "SELECT id FROM devotional_entries WHERE module_id = ?", arguments: [moduleId]) {
                try Self.recordPersonalDeletion(db, .devotional, id)
            }
            try db.execute(sql: "DELETE FROM note_entries WHERE module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM devotional_entries WHERE module_id = ?", arguments: [moduleId])
        }
    }

    func deleteNoteEntry(id: String) throws {
        try dbQueue.write { db in
            if try NoteEntry.deleteOne(db, key: id) {
                try Self.recordPersonalDeletion(db, .note, id)
            }
        }
    }

    func getNoteEntry(id: String) throws -> NoteEntry? {
        try dbQueue.read { db in
            try NoteEntry.fetchOne(db, key: id)
        }
    }

    func getNotesForChapter(moduleId: String, book: Int, chapter: Int) throws -> [NoteEntry] {
        try dbQueue.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("verse"))
                .fetchAll(db)
        }
    }

    func getNotesForVerse(moduleId: String, verseId: Int) throws -> [NoteEntry] {
        try dbQueue.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("verse_id") == verseId)
                .fetchAll(db)
        }
    }

    /// Get all notes for a specific book (all chapters)
    func getAllNotesForBook(moduleId: String, book: Int) throws -> [NoteEntry] {
        try dbQueue.read { db in
            try NoteEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("book") == book)
                .order(Column("chapter"), Column("verse"))
                .fetchAll(db)
        }
    }

    /// Get list of book numbers that have notes for a module
    func getBookNumbersWithNotes(moduleId: String) throws -> [Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT book FROM note_entries
                WHERE module_id = ?
                ORDER BY book
                """, arguments: [moduleId])
            return rows.compactMap { $0["book"] as Int? }
        }
    }

    // MARK: - Commentary Book CRUD

    func saveCommentaryBook(_ book: CommentaryBook) throws {
        try dbQueue.write { db in
            try book.save(db)
        }
    }

    func getCommentaryBook(moduleId: String, bookNumber: Int) throws -> CommentaryBook? {
        try dbQueue.read { db in
            try CommentaryBook
                .filter(Column("module_id") == moduleId)
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    func getCommentaryBooks(moduleId: String) throws -> [CommentaryBook] {
        try dbQueue.read { db in
            try CommentaryBook
                .filter(Column("module_id") == moduleId)
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    // MARK: - Commentary Unit CRUD

    func saveCommentaryUnit(_ unit: CommentaryUnit) throws {
        try dbQueue.write { db in
            try unit.save(db)
        }
    }

    func getCommentaryUnitsForChapter(moduleId: String, book: Int, chapter: Int) throws -> [CommentaryUnit] {
        try dbQueue.read { db in
            try CommentaryUnit
                .filter(Column("module_id") == moduleId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    func getCommentaryUnitsForVerse(moduleId: String, verseId: Int) throws -> [CommentaryUnit] {
        // verseId is in BBCCCVVV format
        try dbQueue.read { db in
            // Find units where verseId falls within the sv-ev range
            try CommentaryUnit
                .filter(Column("module_id") == moduleId)
                .filter(Column("sv") <= verseId)
                .filter(Column("ev") >= verseId || Column("ev") == nil && Column("sv") == verseId)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    func getCommentaryUnitsForVerseRange(moduleId: String, startVerse: Int, endVerse: Int) throws -> [CommentaryUnit] {
        try dbQueue.read { db in
            // Find units that overlap with the given range
            try CommentaryUnit
                .filter(Column("module_id") == moduleId)
                .filter(Column("sv") <= endVerse)
                .filter(Column("ev") >= startVerse || Column("ev") == nil && Column("sv") >= startVerse && Column("sv") <= endVerse)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    func getChildCommentaryUnits(parentId: String) throws -> [CommentaryUnit] {
        try dbQueue.read { db in
            try CommentaryUnit
                .filter(Column("parent_id") == parentId)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    func getCommentaryUnitsByType(moduleId: String, unitType: CommentaryUnitType) throws -> [CommentaryUnit] {
        try dbQueue.read { db in
            try CommentaryUnit
                .filter(Column("module_id") == moduleId)
                .filter(Column("unit_type") == unitType.rawValue)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    // MARK: - Commentary Series CRUD

    /// Save a commentary series to the database
    func saveCommentarySeries(_ series: CommentarySeries) throws {
        try dbQueue.write { db in
            try series.save(db)
        }
    }

    /// Get a commentary series by ID
    func getCommentarySeries(id: String) throws -> CommentarySeries? {
        try dbQueue.read { db in
            try CommentarySeries.fetchOne(db, key: id)
        }
    }

    /// Get all commentary series
    func getAllCommentarySeries() throws -> [CommentarySeries] {
        try dbQueue.read { db in
            try CommentarySeries
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Delete a commentary series by ID
    func deleteCommentarySeries(id: String) throws {
        try dbQueue.write { db in
            _ = try CommentarySeries.deleteOne(db, key: id)
        }
    }

    /// Get all modules that belong to a specific series
    func getModulesForSeries(seriesId: String) throws -> [Module] {
        try dbQueue.read { db in
            try Module
                .filter(Column("series_id") == seriesId)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get all commentary books for a specific series
    func getCommentaryBooksForSeries(seriesId: String) throws -> [CommentaryBook] {
        try dbQueue.read { db in
            // Get all modules that belong to this series
            let moduleIds = try Module
                .filter(Column("series_id") == seriesId)
                .fetchAll(db)
                .map { $0.id }

            guard !moduleIds.isEmpty else { return [] }

            // Get all books for these modules
            return try CommentaryBook
                .filter(moduleIds.contains(Column("module_id")))
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    // MARK: - Commentary Series Queries (Legacy - uses series_full field)

    /// Get all unique series names (full names) from commentary books
    func getCommentarySeriesNames() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT series_full FROM commentary_books
                WHERE series_full IS NOT NULL
                ORDER BY series_full
            """)
            return rows.compactMap { $0["series_full"] as String? }
        }
    }

    /// Get commentary book info for a series (by full name) and book number
    func getCommentaryBookForSeries(seriesFull: String, bookNumber: Int) throws -> CommentaryBook? {
        try dbQueue.read { db in
            try CommentaryBook
                .filter(Column("series_full") == seriesFull)
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    /// Get all commentary books (for module manager grouping)
    func getAllCommentaryBooks() throws -> [CommentaryBook] {
        try dbQueue.read { db in
            try CommentaryBook
                .order(Column("series_full"), Column("book_number"))
                .fetchAll(db)
        }
    }

    /// Get commentary units for a chapter by series name (finds the matching module for that book)
    func getCommentaryUnitsForChapterBySeries(seriesFull: String, book: Int, chapter: Int) throws -> [CommentaryUnit] {
        try dbQueue.read { db in
            // First find the module ID for this series + book combination
            let commentaryBook = try CommentaryBook
                .filter(Column("series_full") == seriesFull)
                .filter(Column("book_number") == book)
                .fetchOne(db)

            guard let moduleId = commentaryBook?.moduleId else {
                return []
            }

            // Then get units for that module and chapter
            return try CommentaryUnit
                .filter(Column("module_id") == moduleId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }

    /// Check if a series has coverage for a specific book
    func seriesHasCoverageForBook(seriesFull: String, bookNumber: Int) throws -> Bool {
        try dbQueue.read { db in
            let count = try CommentaryBook
                .filter(Column("series_full") == seriesFull)
                .filter(Column("book_number") == bookNumber)
                .fetchCount(db)
            return count > 0
        }
    }

    // MARK: - Dictionary Entry CRUD

    func saveDictionaryEntry(_ entry: DictionaryEntry) throws {
        try dbQueue.write { db in
            try entry.save(db)
            try Self.writeSearchText(of: entry, in: db)
        }
    }

    /// The record doesn't carry its search text, so a saved entry has it
    /// written beside it, or an edited one would be found by its old senses.
    private static func writeSearchText(of entry: DictionaryEntry, in db: Database) throws {
        try db.execute(
            sql: "UPDATE dictionary_entries SET search_text = ? WHERE id = ?",
            arguments: [DictionarySearchText.text(fromSensesJSON: entry.sensesJson), entry.id]
        )
    }

    func getDictionaryEntry(moduleId: String, key: String) throws -> DictionaryEntry? {
        try dbQueue.read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("key") == key)
                .fetchOne(db)
        }
    }

    func getDictionaryEntry(id: String) throws -> DictionaryEntry? {
        try dbQueue.read { db in
            try DictionaryEntry
                .filter(Column("id") == id)
                .fetchOne(db)
        }
    }

    func getDictionaryEntries(moduleId: String, keys: [String]) throws -> [DictionaryEntry] {
        try dbQueue.read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .filter(keys.contains(Column("key")))
                .fetchAll(db)
        }
    }

    // MARK: - Devotional Entry CRUD

    func saveDevotionalEntry(_ entry: DevotionalEntry) throws {
        do {
            // Debug: Log what we're about to save
            print("[ModuleDatabase] Saving entry '\(entry.title)' with mediaJson: \(entry.mediaJson?.prefix(50) ?? "nil")")

            try write { db in
                try entry.save(db)
                try Self.recordPersonalPresence(db, .devotional, entry.id)

                // Debug: Immediately read back to verify
                if let savedEntry = try DevotionalEntry.fetchOne(db, key: entry.id) {
                    print("[ModuleDatabase] Verified save - mediaJson in DB: \(savedEntry.mediaJson?.prefix(50) ?? "nil")")
                } else {
                    print("[ModuleDatabase] WARNING: Could not read back saved entry!")
                }
            }
        } catch {
            print("[ModuleDatabase] Error saving devotional entry: \(error)")
            print("[ModuleDatabase] Entry ID: \(entry.id), Title: \(entry.title)")
            throw error
        }
    }

    func deleteDevotionalEntry(id: String) throws {
        try dbQueue.write { db in
            if try DevotionalEntry.deleteOne(db, key: id) {
                try Self.recordPersonalDeletion(db, .devotional, id)
            }
        }
    }

    func getDevotionalEntry(id: String) throws -> DevotionalEntry? {
        try dbQueue.read { db in
            try DevotionalEntry.fetchOne(db, key: id)
        }
    }

    func getDevotionalsForDate(moduleId: String, date: String) throws -> [DevotionalEntry] {
        try dbQueue.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("date") == date)
                .fetchAll(db)
        }
    }

    func getDevotionalsWithTag(moduleId: String, tag: String) throws -> [DevotionalEntry] {
        try dbQueue.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("tags").like("%\(tag)%"))
                .fetchAll(db)
        }
    }

    /// Get devotionals by subscription ID
    func getDevotionalsForSubscription(subscriptionId: String) throws -> [DevotionalEntry] {
        try dbQueue.read { db in
            try DevotionalEntry
                .filter(Column("subscription_id") == subscriptionId)
                .fetchAll(db)
        }
    }

    /// Delete all devotionals for a subscription
    func deleteDevotionalsForSubscription(subscriptionId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM devotional_entries WHERE subscription_id = ?", arguments: [subscriptionId])
        }
    }

    // MARK: - Publication CRUD

    func savePublication(_ publication: DevotionalPublication) throws {
        try dbQueue.write { db in
            try publication.save(db)
        }
    }

    func deletePublication(id: String) throws {
        try dbQueue.write { db in
            _ = try DevotionalPublication.deleteOne(db, key: id)
        }
    }

    func getPublication(id: String) throws -> DevotionalPublication? {
        try dbQueue.read { db in
            try DevotionalPublication.fetchOne(db, key: id)
        }
    }

    func getAllPublications() throws -> [DevotionalPublication] {
        try dbQueue.read { db in
            try DevotionalPublication.fetchAll(db)
        }
    }

    func getPublicationsForModule(moduleId: String) throws -> [DevotionalPublication] {
        try dbQueue.read { db in
            try DevotionalPublication
                .filter(Column("module_id") == moduleId)
                .fetchAll(db)
        }
    }

    // MARK: - Subscription CRUD

    func saveSubscription(_ subscription: DevotionalSubscription) throws {
        try dbQueue.write { db in
            try subscription.save(db)
        }
    }

    func deleteSubscription(id: String) throws {
        try dbQueue.write { db in
            _ = try DevotionalSubscription.deleteOne(db, key: id)
        }
    }

    func getSubscription(id: String) throws -> DevotionalSubscription? {
        try dbQueue.read { db in
            try DevotionalSubscription.fetchOne(db, key: id)
        }
    }

    func getAllSubscriptions() throws -> [DevotionalSubscription] {
        try dbQueue.read { db in
            try DevotionalSubscription.fetchAll(db)
        }
    }

    func getEnabledSubscriptions() throws -> [DevotionalSubscription] {
        try dbQueue.read { db in
            try DevotionalSubscription
                .filter(Column("is_enabled") == 1)
                .fetchAll(db)
        }
    }

    func updateSubscriptionLastSynced(id: String, lastSynced: Date, version: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE devotional_subscriptions
                    SET last_synced = ?, last_remote_version = ?
                    WHERE id = ?
                """,
                arguments: [Int(lastSynced.timeIntervalSince1970), version, id]
            )
        }
    }

    func toggleSubscriptionEnabled(id: String, enabled: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE devotional_subscriptions SET is_enabled = ? WHERE id = ?",
                arguments: [enabled ? 1 : 0, id]
            )
        }
    }

    // MARK: - Bulk Operations

    func deleteAllEntriesForModule(moduleId: String) throws {
        try dbQueue.write { db in
            try Self.deleteAllEntriesForModule(moduleId: moduleId, in: db)
        }
    }

    static func deleteAllEntriesForModule(moduleId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM dictionary_entries WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM commentary_units WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM commentary_books WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM devotional_entries WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM note_entries WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM book_sections WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM book_modules WHERE id = ?", arguments: [moduleId])
        // Delete highlights before their sets because of the foreign key.
        try db.execute(sql: "DELETE FROM highlights WHERE set_id IN (SELECT id FROM highlight_sets WHERE module_id = ?)", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM highlight_sets WHERE module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM quiz_questions WHERE quiz_module_id = ?", arguments: [moduleId])
        try db.execute(sql: "DELETE FROM quiz_modules WHERE id = ?", arguments: [moduleId])
    }

    func importDictionaryEntries(_ entries: [DictionaryEntry]) throws {
        try dbQueue.write { db in
            for entry in entries {
                try entry.save(db)
                try Self.writeSearchText(of: entry, in: db)
            }
        }
    }

    func importCommentaryBook(_ book: CommentaryBook) throws {
        try dbQueue.write { db in
            try book.save(db)
        }
    }

    func importCommentaryUnits(_ units: [CommentaryUnit]) throws {
        try dbQueue.write { db in
            for unit in units {
                try unit.save(db)
            }
        }
    }

    func importDevotionalEntries(_ entries: [DevotionalEntry]) throws {
        try dbQueue.write { db in
            for entry in entries {
                try entry.save(db)
            }
        }
    }

    /// Delete a commentary book and all its units
    func deleteCommentaryBook(moduleId: String) throws {
        try dbQueue.write { db in
            // Delete units first (foreign key constraint)
            try db.execute(sql: "DELETE FROM commentary_units WHERE module_id = ?", arguments: [moduleId])
            // Delete the book record
            try db.execute(sql: "DELETE FROM commentary_books WHERE module_id = ?", arguments: [moduleId])
        }
    }

    // MARK: - Translation CRUD

    func saveTranslation(_ translation: TranslationModule) throws {
        try dbQueue.write { db in
            try translation.save(db)
        }
    }

    func deleteTranslation(id: String) throws {
        try dbQueue.write { db in
            _ = try TranslationModule.deleteOne(db, key: id)
        }
        // Plan metadata is keyed by translation id, which can't see content changes
        PlanMetaDataCache.shared.invalidate()
    }

    func getTranslation(id: String) throws -> TranslationModule? {
        try dbQueue.read { db in
            try TranslationModule.fetchOne(db, key: id)
        }
    }

    func getAllTranslations(bundledOnly: Bool? = nil) throws -> [TranslationModule] {
        try dbQueue.read { db in
            if let bundledOnly = bundledOnly {
                return try TranslationModule
                    .filter(Column("is_bundled") == (bundledOnly ? 1 : 0))
                    .order(Column("name"))
                    .fetchAll(db)
            } else {
                return try TranslationModule
                    .order(Column("name"))
                    .fetchAll(db)
            }
        }
    }

    func getTranslationsByLanguage(_ language: String) throws -> [TranslationModule] {
        try dbQueue.read { db in
            try TranslationModule
                .filter(Column("language") == language)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    // MARK: - Translation Book CRUD

    func saveTranslationBook(_ book: TranslationBook) throws {
        try dbQueue.write { db in
            try book.save(db)
        }
    }

    func getTranslationBook(translationId: String, bookNumber: Int) throws -> TranslationBook? {
        try dbQueue.read { db in
            try TranslationBook
                .filter(Column("translation_id") == translationId)
                .filter(Column("book_number") == bookNumber)
                .fetchOne(db)
        }
    }

    func getTranslationBooks(translationId: String) throws -> [TranslationBook] {
        try dbQueue.read { db in
            try TranslationBook
                .filter(Column("translation_id") == translationId)
                .order(Column("book_number"))
                .fetchAll(db)
        }
    }

    // MARK: - Translation Verse CRUD

    func saveTranslationVerse(_ verse: TranslationVerse) throws {
        try dbQueue.write { db in
            try verse.save(db)
        }
    }

    func getVerse(translationId: String, ref: Int) throws -> TranslationVerse? {
        try dbQueue.read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("ref") == ref)
                .fetchOne(db)
        }
    }

    func getVerses(translationIds: [String], ref: Int) throws -> [String: TranslationVerse] {
        try dbQueue.read { db in
            let verses = try TranslationVerse
                .filter(translationIds.contains(Column("translation_id")))
                .filter(Column("ref") == ref)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: verses.map { ($0.translationId, $0) })
        }
    }

    func getChapter(translationId: String, book: Int, chapter: Int) throws -> ChapterContent {
        try dbQueue.read { db in
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

    /// Get multiple consecutive chapters for continuous scrolling
    func getChapters(translationId: String, chapters: [(book: Int, chapter: Int)]) throws -> [ChapterContent] {
        try dbQueue.read { db in
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

    func getVerseRange(translationId: String, startRef: Int, endRef: Int) throws -> [TranslationVerse] {
        try dbQueue.read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("ref") >= startRef)
                .filter(Column("ref") <= endRef)
                .order(Column("ref"))
                .fetchAll(db)
        }
    }

    /// Summary statistics for a verse range, without loading the full rows.
    /// See `BundledModuleDatabase.getVerseRangeStats`.
    func getVerseRangeStats(translationId: String, startRef: Int, endRef: Int) throws -> VerseRangeStats {
        try dbQueue.read { db in
            try VerseRangeStats.fetch(db, translationId: translationId, startRef: startRef, endRef: endRef)
        }
    }

    func getChapterCount(translationId: String, book: Int) throws -> Int {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MAX(chapter) as max_chapter
                FROM translation_verses
                WHERE translation_id = ? AND book = ?
            """, arguments: [translationId, book])
            return row?["max_chapter"] ?? 0
        }
    }

    func getVerseCount(translationId: String, book: Int, chapter: Int) throws -> Int {
        try dbQueue.read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .fetchCount(db)
        }
    }

    func getTotalVerseCount(translationId: String) throws -> Int {
        try dbQueue.read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .fetchCount(db)
        }
    }

    func countStrongsOccurrences(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil
    ) throws -> Int {
        try dbQueue.read { db in
            try StrongsVerseQuery.count(in: db, translationId: translationId, key: strongsNum, bookRange: bookRange)
        }
    }

    func searchVersesByStrongs(
        translationId: String,
        strongsNum: String,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        try dbQueue.read { db in
            try StrongsVerseQuery.verses(
                in: db, translationId: translationId, key: strongsNum, bookRange: bookRange, limit: limit
            )
        }
    }

    func getLastVerseRef(translationId: String, book: Int, chapter: Int) throws -> Int {
        try dbQueue.read { db in
            let ref = try Int.fetchOne(db, sql: """
                SELECT MAX(ref) FROM translation_verses
                WHERE translation_id = ? AND book = ? AND chapter = ?
            """, arguments: [translationId, book, chapter])
            return ref ?? 0
        }
    }

    func verseExists(translationId: String, ref: Int) throws -> Bool {
        try dbQueue.read { db in
            try TranslationVerse
                .filter(Column("translation_id") == translationId)
                .filter(Column("ref") == ref)
                .fetchCount(db) > 0
        }
    }

    // MARK: - Translation Heading CRUD

    func saveTranslationHeading(_ heading: TranslationHeading) throws {
        try dbQueue.write { db in
            try heading.save(db)
        }
    }

    func getHeadingsForChapter(translationId: String, book: Int, chapter: Int) throws -> [TranslationHeading] {
        try dbQueue.read { db in
            try TranslationHeading
                .filter(Column("translation_id") == translationId)
                .filter(Column("book") == book)
                .filter(Column("chapter") == chapter)
                .order(Column("before_verse"))
                .fetchAll(db)
        }
    }

    // MARK: - Translation FTS Search

    func searchVerses(
        query: String,
        translationIds: Set<String>? = nil,
        bookRange: ClosedRange<Int>? = nil,
        limit: Int = 50
    ) throws -> [TranslationSearchResult] {
        let ftsQuery = prepareFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try dbQueue.read { db in
            try TranslationVerseSearch.results(
                in: db,
                ftsQuery: ftsQuery,
                translationIds: translationIds,
                bookRange: bookRange,
                limit: limit
            )
        }
    }

    /// The one search grammar, shared with Mac search and the unified module
    /// search: each word matches as a prefix and all words must appear, while a
    /// quoted run stays a phrase. Escaping it here instead would make a verse
    /// search of two words a phrase search, so "faith works" would miss
    /// "faith without works".
    private func prepareFTSQuery(_ query: String) -> String {
        LampSearchQuery(query).fts5Query
    }

    // MARK: - Translation Bulk Operations

    /// Import a complete translation with batched inserts for performance
    func importTranslation(
        _ translation: TranslationModule,
        books: [TranslationBook],
        verses: [TranslationVerse],
        headings: [TranslationHeading]
    ) throws {
        try dbQueue.write { db in
            // Retire the previous translation in the same transaction as its
            // replacement. A failed child insert restores metadata and rows.
            try db.execute(
                sql: "DELETE FROM translation_headings WHERE translation_id = ?",
                arguments: [translation.id]
            )
            try db.execute(
                sql: "DELETE FROM translation_verses WHERE translation_id = ?",
                arguments: [translation.id]
            )
            try db.execute(
                sql: "DELETE FROM translation_books WHERE translation_id = ?",
                arguments: [translation.id]
            )
            try db.execute(sql: "DELETE FROM translations WHERE id = ?", arguments: [translation.id])
            try translation.insert(db)

            // Batch insert books
            for book in books {
                try book.insert(db)
            }

            // Batch insert verses (in chunks for memory efficiency)
            let verseChunkSize = 1000
            for chunk in verses.chunked(into: verseChunkSize) {
                for verse in chunk {
                    try verse.insert(db)
                }
            }

            // Batch insert headings
            for heading in headings {
                try heading.insert(db)
            }
        }
        // Plan metadata is keyed by translation id, which can't see content changes
        PlanMetaDataCache.shared.invalidate()
    }

    // MARK: - Plan Queries (User Plans)

    /// Get all user plans
    func getAllPlans() throws -> [Plan] {
        try dbQueue.read { db in
            try Plan.order(Column("name")).fetchAll(db)
        }
    }

    /// Get a specific plan by ID
    func getPlan(id: String) throws -> Plan? {
        try dbQueue.read { db in
            try Plan.fetchOne(db, key: id)
        }
    }

    /// Get a plan day for a specific plan and day number
    func getPlanDay(planId: String, day: Int) throws -> PlanDay? {
        try dbQueue.read { db in
            try PlanDay
                .filter(Column("plan_id") == planId)
                .filter(Column("day") == day)
                .fetchOne(db)
        }
    }

    /// Get all days for a plan
    func getPlanDays(planId: String) throws -> [PlanDay] {
        try dbQueue.read { db in
            try PlanDay
                .filter(Column("plan_id") == planId)
                .order(Column("day"))
                .fetchAll(db)
        }
    }

    /// Get the count of user plans
    func getPlanCount() throws -> Int {
        try dbQueue.read { db in
            try Plan.fetchCount(db)
        }
    }

    /// Save a plan
    func savePlan(_ plan: Plan) throws {
        try dbQueue.write { db in
            try plan.save(db)
        }
    }

    /// Save plan days
    func savePlanDays(_ days: [PlanDay]) throws {
        try dbQueue.write { db in
            for day in days {
                try day.save(db)
            }
        }
    }

    /// Delete a plan by ID
    func deletePlan(id: String) throws {
        try dbQueue.write { db in
            _ = try Plan.deleteOne(db, key: id)
        }
    }

    /// Import a complete plan with all days
    func importPlan(_ plan: Plan, days: [PlanDay]) throws {
        try dbQueue.write { db in
            try plan.save(db)
            for day in days {
                try day.save(db)
            }
        }
    }

    // MARK: - Quiz Module CRUD

    /// Get all user quiz modules
    func getAllQuizModules() throws -> [QuizModule] {
        try dbQueue.read { db in
            try QuizModule.order(Column("name")).fetchAll(db)
        }
    }

    /// Get a quiz module by ID
    func getQuizModule(id: String) throws -> QuizModule? {
        try dbQueue.read { db in
            try QuizModule.fetchOne(db, key: id)
        }
    }

    /// Get quiz modules for a specific plan
    func getQuizModulesForPlan(planId: String) throws -> [QuizModule] {
        try dbQueue.read { db in
            try QuizModule
                .filter(Column("plan_id") == planId)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Save a quiz module
    func saveQuizModule(_ module: QuizModule) throws {
        try dbQueue.write { db in
            var module = module
            try module.save(db)
        }
    }

    /// Delete a quiz module by ID
    func deleteQuizModule(id: String) throws {
        try dbQueue.write { db in
            _ = try QuizModule.deleteOne(db, key: id)
        }
    }

    /// Get quiz questions for a specific day and age group
    func getQuizQuestions(moduleId: String, day: Int, ageGroup: String) throws -> [QuizQuestion] {
        try dbQueue.read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .filter(Column("day") == day)
                .filter(Column("age_group") == ageGroup)
                .order(Column("question_index"))
                .fetchAll(db)
        }
    }

    /// Get quiz questions for a specific reading
    func getQuizQuestionsForReading(moduleId: String, day: Int, sv: Int, ev: Int, ageGroup: String) throws -> [QuizQuestion] {
        try dbQueue.read { db in
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

    /// Get all quiz questions for a day
    func getQuizQuestionsForDay(moduleId: String, day: Int) throws -> [QuizQuestion] {
        try dbQueue.read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .filter(Column("day") == day)
                .order(Column("sv"), Column("age_group"), Column("question_index"))
                .fetchAll(db)
        }
    }

    /// Get distinct age groups used in quiz questions for a module
    func getQuizQuestionAgeGroups(moduleId: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT age_group FROM quiz_questions
                WHERE quiz_module_id = ?
                ORDER BY age_group
            """, arguments: [moduleId])
        }
    }

    /// Get distinct days that have quiz questions for a module
    func getQuizDays(moduleId: String) throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT day FROM quiz_questions
                WHERE quiz_module_id = ?
                ORDER BY day
            """, arguments: [moduleId])
        }
    }

    /// Get question count for a module
    func getQuizQuestionCount(moduleId: String) throws -> Int {
        try dbQueue.read { db in
            try QuizQuestion
                .filter(Column("quiz_module_id") == moduleId)
                .fetchCount(db)
        }
    }

    /// Import quiz questions (bulk insert)
    func importQuizQuestions(_ questions: [QuizQuestion]) throws {
        try dbQueue.write { db in
            for var question in questions {
                try question.insert(db)
            }
        }
    }

    /// Delete all quiz questions for a module
    func deleteAllQuizQuestions(moduleId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM quiz_questions WHERE quiz_module_id = ?",
                arguments: [moduleId]
            )
        }
    }

    // MARK: - Highlight Set CRUD

    /// Save a highlight set
    func saveHighlightSet(_ set: HighlightSet) throws {
        try dbQueue.write { db in
            try set.save(db)
            try Self.recordPersonalPresence(db, .highlightSet, set.id)
        }
    }

    /// Delete a highlight set by ID
    func deleteHighlightSet(id: String) throws {
        try dbQueue.write { db in
            if try HighlightSet.deleteOne(db, key: id) {
                try Self.recordPersonalDeletion(db, .highlightSet, id)
            }
        }
    }

    /// Get a highlight set by ID
    func getHighlightSet(id: String) throws -> HighlightSet? {
        try dbQueue.read { db in
            try HighlightSet.fetchOne(db, key: id)
        }
    }

    /// Get all highlight sets for a translation
    func getHighlightSets(forTranslation translationId: String) throws -> [HighlightSet] {
        try dbQueue.read { db in
            try HighlightSet
                .filter(Column("translation_id") == translationId)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get all highlight sets
    func getAllHighlightSets() throws -> [HighlightSet] {
        try dbQueue.read { db in
            try HighlightSet
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Get highlight sets for a module
    func getHighlightSets(forModule moduleId: String) throws -> [HighlightSet] {
        try dbQueue.read { db in
            try HighlightSet
                .filter(Column("module_id") == moduleId)
                .order(Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: - Highlight Entry CRUD

    /// Save a highlight entry and return it with the assigned ID
    @discardableResult
    func saveHighlight(_ highlight: HighlightEntry) throws -> HighlightEntry {
        try dbQueue.write { db in
            var entry = highlight
            try entry.insert(db)
            try Self.recordPersonalPresence(db, .highlight, Self.ledgerKey(entry))
            return entry
        }
    }

    /// Update a highlight entry's character offsets
    ///
    /// A highlight is known by where it is, so moving one deletes the old
    /// one and saves a new one as far as other devices can tell.
    func updateHighlight(id: Int64, sc: Int, ec: Int) throws {
        try dbQueue.write { db in
            guard var entry = try HighlightEntry.fetchOne(db, key: id) else { return }
            try Self.recordPersonalDeletion(db, .highlight, Self.ledgerKey(entry))
            entry.sc = sc
            entry.ec = ec
            try entry.update(db)
            try Self.recordPersonalPresence(db, .highlight, Self.ledgerKey(entry))
        }
    }

    /// Delete a highlight entry by ID
    func deleteHighlight(id: Int64) throws {
        try dbQueue.write { db in
            try Self.deleteRecordingHighlights(db, HighlightEntry.filter(key: id))
        }
    }

    /// Get a highlight entry by ID
    func getHighlight(id: Int64) throws -> HighlightEntry? {
        try dbQueue.read { db in
            try HighlightEntry.fetchOne(db, key: id)
        }
    }

    /// Get all highlights for a set and chapter (all verses in the chapter)
    func getHighlights(setId: String, book: Int, chapter: Int) throws -> [HighlightEntry] {
        // Calculate ref range for the chapter: BBCCC001 to BBCCC999
        let startRef = book * 1_000_000 + chapter * 1000 + 1
        let endRef = book * 1_000_000 + chapter * 1000 + 999

        return try dbQueue.read { db in
            try HighlightEntry
                .filter(Column("set_id") == setId)
                .filter(Column("ref") >= startRef)
                .filter(Column("ref") <= endRef)
                .order(Column("ref"), Column("sc"))
                .fetchAll(db)
        }
    }

    /// Get all highlights for a set and specific verse
    func getHighlights(setId: String, ref: Int) throws -> [HighlightEntry] {
        try dbQueue.read { db in
            try HighlightEntry
                .filter(Column("set_id") == setId)
                .filter(Column("ref") == ref)
                .order(Column("sc"))
                .fetchAll(db)
        }
    }

    /// Get all highlights for a set
    func getAllHighlights(setId: String) throws -> [HighlightEntry] {
        try dbQueue.read { db in
            try HighlightEntry
                .filter(Column("set_id") == setId)
                // A total order: the highlights export is compared byte for byte
                // with the last upload, and ties left to storage would move.
                .order(Column("ref"), Column("sc"), Column("ec"), Column("style"), Column("color"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Delete all highlights for a specific verse in a set
    func deleteHighlights(setId: String, ref: Int) throws {
        try dbQueue.write { db in
            try Self.deleteRecordingHighlights(db, HighlightEntry
                .filter(Column("set_id") == setId)
                .filter(Column("ref") == ref))
        }
    }

    /// Delete a highlight that overlaps with given character range
    func deleteHighlight(setId: String, ref: Int, sc: Int, ec: Int) throws {
        try dbQueue.write { db in
            try Self.deleteRecordingHighlights(db, HighlightEntry
                .filter(Column("set_id") == setId)
                .filter(Column("ref") == ref)
                .filter(Column("sc") == sc)
                .filter(Column("ec") == ec))
        }
    }

    private static func deleteRecordingHighlights(
        _ db: Database, _ request: QueryInterfaceRequest<HighlightEntry>
    ) throws {
        for entry in try request.fetchAll(db) {
            _ = try entry.delete(db)
            try recordPersonalDeletion(db, .highlight, ledgerKey(entry))
        }
    }

    static func ledgerKey(_ entry: HighlightEntry) -> String {
        LampPersonalDeletionLedger.highlightKey(
            setID: entry.setId, reference: entry.ref, start: entry.sc, end: entry.ec,
            style: entry.style, color: entry.color
        )
    }

    static func ledgerKey(_ theme: HighlightTheme) -> String {
        LampPersonalDeletionLedger.highlightThemeKey(
            setID: theme.setId, color: theme.color, style: theme.style
        )
    }

    /// Get highlight count for a set
    func getHighlightCount(setId: String) throws -> Int {
        try dbQueue.read { db in
            try HighlightEntry
                .filter(Column("set_id") == setId)
                .fetchCount(db)
        }
    }

    /// Import highlights for a set (bulk insert)
    func importHighlights(_ highlights: [HighlightEntry]) throws {
        // A file the user chose to import: its highlights are saved here now.
        try dbQueue.write { db in
            for var highlight in highlights {
                try highlight.insert(db)
                try Self.recordPersonalPresence(db, .highlight, Self.ledgerKey(highlight))
            }
        }
    }

    /// Delete all highlights for a set
    func deleteAllHighlights(setId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM highlights WHERE set_id = ?",
                arguments: [setId]
            )
        }
    }

    /// Update highlight set's last_modified timestamp
    func updateHighlightSetModified(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE highlight_sets SET last_modified = ? WHERE id = ?",
                arguments: [Int(Date().timeIntervalSince1970), id]
            )
        }
    }

    /// Get all unique highlight colors used across all highlight sets
    func getUniqueHighlightColors() throws -> [String] {
        try dbQueue.read { db in
            let sql = "SELECT DISTINCT color FROM highlights WHERE color IS NOT NULL"
            let rows = try Row.fetchAll(db, sql: sql)
            var colors: [String] = []
            for row in rows {
                if let colorHex: String = row["color"] {
                    colors.append(colorHex.uppercased())
                }
            }
            // Add default yellow for highlights without explicit color
            if !colors.contains("FFCC00") {
                colors.append("FFCC00")
            }
            return colors
        }
    }

    // MARK: - Highlight Theme CRUD

    /// Save a highlight theme
    func saveHighlightTheme(_ theme: HighlightTheme) throws {
        try dbQueue.write { db in
            try theme.save(db)
            try Self.recordPersonalPresence(db, .highlightTheme, Self.ledgerKey(theme))
        }
    }

    /// Delete a highlight theme by ID
    func deleteHighlightTheme(id: String) throws {
        try dbQueue.write { db in
            guard let theme = try HighlightTheme.fetchOne(db, key: id) else { return }
            _ = try theme.delete(db)
            try Self.recordPersonalDeletion(db, .highlightTheme, Self.ledgerKey(theme))
        }
    }

    /// Get a highlight theme by ID
    func getHighlightTheme(id: String) throws -> HighlightTheme? {
        try dbQueue.read { db in
            try HighlightTheme.fetchOne(db, key: id)
        }
    }

    /// Get all themes for a highlight set
    func getHighlightThemes(setId: String) throws -> [HighlightTheme] {
        try dbQueue.read { db in
            try HighlightTheme
                .filter(Column("set_id") == setId)
                .order(Column("style"), Column("color"))
                .fetchAll(db)
        }
    }

    /// Get theme for a specific color+style combination in a set
    func getHighlightTheme(setId: String, color: String, style: Int) throws -> HighlightTheme? {
        let normalizedColor = color.uppercased().replacingOccurrences(of: "#", with: "")
        let id = "\(setId)_\(normalizedColor)_\(style)"
        return try getHighlightTheme(id: id)
    }

    /// Import themes for a set (bulk insert/update)
    func importHighlightThemes(_ themes: [HighlightTheme]) throws {
        try dbQueue.write { db in
            for theme in themes {
                try theme.save(db)
            }
        }
    }

    /// Delete all themes for a set
    func deleteAllHighlightThemes(setId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM highlight_themes WHERE set_id = ?",
                arguments: [setId]
            )
        }
    }

    // MARK: - Wipe All Syncable Data

    func prepareBackendTransition(previousSettings: SyncSettings) throws {
        let json = try JSONEncoder().encode(previousSettings)
        guard let value = String(data: json, encoding: .utf8) else {
            throw DatabaseError(message: "Failed to encode previous sync settings")
        }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sync_backend_transition (id, previous_settings_json) VALUES (1, ?)",
                arguments: [value]
            )
        }
    }

    func pendingBackendTransition() throws -> SyncSettings? {
        try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT previous_settings_json FROM sync_backend_transition WHERE id = 1"
            ) else { return nil }
            return try JSONDecoder().decode(SyncSettings.self, from: Data(value.utf8))
        }
    }

    func clearPendingBackendTransition() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_backend_transition WHERE id = 1")
        }
    }

    /// Wipe all user-syncable data from the local database.
    /// This includes notes, devotionals, and highlights.
    /// Used when switching sync backends to start fresh.
    func wipeAllSyncableData() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_pending_module_conflicts")
            try db.execute(sql: "DELETE FROM sync_pending_module_publications")
            // Delete all notes
            try db.execute(sql: "DELETE FROM note_entries")

            // Delete all devotionals
            try db.execute(sql: "DELETE FROM devotional_entries")

            // Delete all highlights, themes, and highlight sets
            try db.execute(sql: "DELETE FROM highlights")
            try db.execute(sql: "DELETE FROM highlight_themes")
            try db.execute(sql: "DELETE FROM highlight_sets")

            // The rows no longer match these module snapshots. Force the next
            // provider import even when its file has the old provider's hash.
            try db.execute(sql: """
                UPDATE modules SET file_hash = NULL, last_synced = NULL
                WHERE type IN ('notes', 'devotional', 'highlights')
                """)

            // A committed wipe makes the new provider choice safe to use.
            try db.execute(sql: "DELETE FROM sync_backend_transition WHERE id = 1")

            print("[ModuleDatabase] Wiped all syncable data (notes, devotionals, highlights, themes)")
        }
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Translation verse search

/// The one verse-search query, used against whichever translation database
/// holds the translation being searched.
///
/// Bundled translations and installed ones live in two databases with the same
/// schema, and each used to carry its own copy of this SQL and its own row
/// mapping. They agreed only by having been written at the same time: a change
/// to the ranking, or to the `<mark>` snippet the results list renders, would
/// have made a bundled translation's results look and sort differently from an
/// installed one's.
enum TranslationVerseSearch {
    /// `translationIds` nil or empty searches every translation in `db`.
    static func results(
        in db: Database,
        ftsQuery: String,
        translationIds: Set<String>?,
        bookRange: ClosedRange<Int>?,
        limit: Int
    ) throws -> [TranslationSearchResult] {
        var conditions = ["translation_verses_fts MATCH ?"]
        var arguments: [DatabaseValueConvertible] = [ftsQuery]

        if let ids = translationIds, !ids.isEmpty {
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            conditions.append("v.translation_id IN (\(placeholders))")
            for id in ids { arguments.append(id) }
        }

        // OT, NT, or a chosen span of books.
        if let bookRange {
            conditions.append("v.book BETWEEN ? AND ?")
            arguments.append(bookRange.lowerBound)
            arguments.append(bookRange.upperBound)
        }

        arguments.append(limit)

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
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY rank
            LIMIT ?
        """

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
                // bm25 scores better matches more negatively; the results list
                // sorts on rank descending.
                rank: -(row["rank"] as Double)
            )
        }
    }
}

// MARK: - Sync File Records

/// What this device last did with one file at one sync endpoint.
struct SyncFileRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_file_records"

    /// The endpoint, as the settings sync names it (`webdav:<url>|<user>`).
    var source: String
    /// The file's path there, as `LampSyncFolderLayout` names it.
    var path: String
    /// The provider's revision of the copy this device last installed or
    /// wrote, whichever came last.
    var lastRevision: String?
    /// SHA-256 of this device's own export when it last uploaded the file, or
    /// right after it installed one with nothing of its own pending. Never
    /// the digest of what was downloaded: a copy equal in value but not in
    /// bytes must not read as a local change, or both devices re-upload it
    /// forever.
    var uploadedDigest: String?
    var updatedAt: Int64
    /// A revision this device wrote that no settings bundle has named yet.
    var pendingRevision: String? = nil

    enum CodingKeys: String, CodingKey {
        case source, path
        case lastRevision = "last_revision"
        case uploadedDigest = "uploaded_digest"
        case updatedAt = "updated_at"
        case pendingRevision = "pending_revision"
    }

}

/// A change to the library's membership made here, kept until a settings
/// bundle this device wrote carries it, so a pass cut short still tells the
/// other devices.
struct SyncPendingManifestChange: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_pending_manifest_changes"

    enum Change: String, Codable { case write, delete }

    var source: String
    var path: String
    var change: Change
    /// For a write: the revision it produced, and the one it replaced.
    var revision: String?
    var replacing: String?
    /// Milliseconds since 1970, as the manifest records times.
    var at: Int64
}

extension ModuleDatabase {
    func syncFileRecord(source: String, path: String) throws -> SyncFileRecord? {
        try read { try SyncFileRecord.fetchOne($0, key: ["source": source, "path": path]) }
    }

    func syncFileRecords(source: String) throws -> [SyncFileRecord] {
        try read {
            try SyncFileRecord.filter(Column("source") == source).order(Column("path")).fetchAll($0)
        }
    }

    /// After uploading this device's export: recorded here, and queued for
    /// the pass's settings bundle.
    func recordSyncUpload(
        source: String, path: String, digest: String?, revision: String?, replacing: String?,
        at time: Date = Date()
    ) throws {
        let now = Self.nowMilliseconds(time)
        try write { db in
            try SyncFileRecord(
                source: source, path: path, lastRevision: revision,
                uploadedDigest: digest, updatedAt: now
            ).save(db)
            try SyncPendingManifestChange(
                source: source, path: path, change: .write,
                revision: revision, replacing: replacing, at: now
            ).save(db)
        }
    }

    /// Highlights modules left with no set, as a set deleted on another
    /// device leaves them: removed, with any publication pending for them.
    /// Such a module has nothing to export, and kept would stop every pass.
    func removeHighlightModulesWithoutSets() throws -> [String] {
        try write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM modules WHERE type = ?
                  AND id NOT IN (SELECT module_id FROM highlight_sets)
                """, arguments: [ModuleType.highlights.rawValue])
            for id in ids {
                try db.execute(sql: "DELETE FROM sync_pending_module_publications WHERE module_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM modules WHERE id = ?", arguments: [id])
            }
            return ids
        }
    }

    /// A file this device deleted. The tombstone records which copy it
    /// deleted, so a copy put back later is told apart from it.
    func recordSyncLocalDeletion(source: String, path: String, at time: Date = Date()) throws {
        try write { db in
            let deleted = try SyncFileRecord.fetchOne(db, key: ["source": source, "path": path])
            _ = try SyncFileRecord.deleteOne(db, key: ["source": source, "path": path])
            try SyncPendingManifestChange(
                source: source, path: path, change: .delete,
                revision: deleted?.pendingRevision ?? deleted?.lastRevision, at: Self.nowMilliseconds(time)
            ).save(db)
        }
    }

    func pendingManifestChanges(source: String) throws -> [SyncPendingManifestChange] {
        try read {
            try SyncPendingManifestChange.filter(Column("source") == source)
                .order(Column("path")).fetchAll($0)
        }
    }

    /// Deletions still to reach a bundle, by path: the plan's `deletedLocally`.
    func pendingManifestDeletions(source: String) throws -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: try pendingManifestChanges(source: source)
            .filter { $0.change == .delete }.map { ($0.path, $0.at) })
    }

    /// Once a written bundle carries them. Matched on time as well as path,
    /// so a newer change to the same file, made while the pass ran, stays.
    func clearPendingManifestChanges(_ carried: [SyncPendingManifestChange]) throws {
        guard !carried.isEmpty else { return }
        try write { db in
            for change in carried {
                try db.execute(sql: """
                    DELETE FROM sync_pending_manifest_changes
                    WHERE source = ? AND path = ? AND at = ?
                    """, arguments: [change.source, change.path, change.at])
            }
        }
    }

    /// Writes made outside a pass, as importing a module file makes one,
    /// still to reach a bundle.
    func pendingManifestWrites(source: String) throws -> [SyncPendingManifestChange] {
        try pendingManifestChanges(source: source).filter { $0.change == .write }
    }

    // MARK: Core's records

    /// This endpoint's records as core's pass engine keeps them.
    func libraryRecords(source: String) throws -> LampSyncFileRecords {
        var records = LampSyncFileRecords()
        var files: [String: LampSyncFileRecords.Record] = [:]
        for row in try syncFileRecords(source: source) {
            files[row.path] = LampSyncFileRecords.Record(
                uploadedDigest: row.uploadedDigest,
                installedRevision: row.lastRevision,
                pendingRevision: row.pendingRevision
            )
        }
        records.sources[source, default: LampSyncFileRecords.Source()].files = files
        return records
    }

    /// What a pass left in `records` for this endpoint, replacing what was
    /// kept for it before: a path the pass forgot is forgotten here too.
    func saveLibraryRecords(_ records: LampSyncFileRecords, source: String, at time: Date = Date()) throws {
        var files = records.sources[source]?.files ?? [:]
        let now = Self.nowMilliseconds(time)
        // Deleted here while the pass ran: the deletion already took its
        // record, and the pass's copy of it must not bring it back.
        for path in try pendingManifestDeletions(source: source).keys { files[path] = nil }
        try write { db in
            let kept = try SyncFileRecord.filter(Column("source") == source).fetchAll(db)
            let before = Dictionary(uniqueKeysWithValues: kept.map { ($0.path, $0) })
            for row in kept where files[row.path] == nil {
                _ = try row.delete(db)
            }
            for (path, record) in files {
                var row = before[path] ?? SyncFileRecord(source: source, path: path, updatedAt: now)
                let changed = row.lastRevision != record.installedRevision
                    || row.uploadedDigest != record.uploadedDigest
                    || row.pendingRevision != record.pendingRevision
                guard changed || before[path] == nil else { continue }
                row.lastRevision = record.installedRevision
                row.uploadedDigest = record.uploadedDigest
                row.pendingRevision = record.pendingRevision
                row.updatedAt = now
                try row.save(db)
            }
        }
    }
}

// MARK: - Personal Deletion Ledger

extension ModuleDatabase {
    static func nowMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    static func recordPersonalPresence(
        _ db: Database, _ kind: LampPersonalItemKind, _ key: String,
        at time: Int64 = nowMilliseconds()
    ) throws {
        try db.execute(sql: """
            INSERT INTO personal_sync_ledger (kind, item_key, present_since) VALUES (?, ?, ?)
            ON CONFLICT(kind, item_key) DO UPDATE SET
                present_since = MAX(COALESCE(present_since, 0), excluded.present_since)
            """, arguments: [kind.rawValue, key, time])
    }

    static func recordPersonalDeletion(
        _ db: Database, _ kind: LampPersonalItemKind, _ key: String,
        at time: Int64 = nowMilliseconds()
    ) throws {
        try db.execute(sql: """
            INSERT INTO personal_sync_ledger (kind, item_key, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT(kind, item_key) DO UPDATE SET
                deleted_at = MAX(COALESCE(deleted_at, 0), excluded.deleted_at)
            """, arguments: [kind.rawValue, key, time])
    }

    static func personalDeletionLedger(in db: Database) throws -> LampPersonalDeletionLedger {
        var ledger = LampPersonalDeletionLedger()
        for row in try Row.fetchAll(db, sql: """
            SELECT kind, item_key, present_since, deleted_at FROM personal_sync_ledger
            """) {
            guard let kind = LampPersonalItemKind(rawValue: row["kind"]) else { continue }
            ledger.set(
                .init(presentSince: row["present_since"], deletedAt: row["deleted_at"]),
                kind: kind, key: row["item_key"]
            )
        }
        return ledger
    }

    func personalDeletionLedger() throws -> LampPersonalDeletionLedger {
        try read { try Self.personalDeletionLedger(in: $0) }
    }

    /// Takes in another device's record: per item, the later save and the
    /// later deletion.
    func mergePersonalDeletionLedger(_ incoming: LampPersonalDeletionLedger) throws {
        try write { db in
            for (kind, entries) in incoming.entries {
                for (key, entry) in entries {
                    try db.execute(sql: """
                        INSERT INTO personal_sync_ledger (kind, item_key, present_since, deleted_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(kind, item_key) DO UPDATE SET
                            present_since = CASE
                                WHEN present_since IS NULL THEN excluded.present_since
                                WHEN excluded.present_since IS NULL THEN present_since
                                ELSE MAX(present_since, excluded.present_since) END,
                            deleted_at = CASE
                                WHEN deleted_at IS NULL THEN excluded.deleted_at
                                WHEN excluded.deleted_at IS NULL THEN deleted_at
                                ELSE MAX(deleted_at, excluded.deleted_at) END
                        """, arguments: [kind.rawValue, key, entry.presentSince, entry.deletedAt])
                }
            }
        }
    }

    /// Removes notes, writings, highlight sets, highlights and themes the
    /// ledger records as deleted since this device's copy was saved, and
    /// returns the modules they were in, which now need publishing without
    /// them. Nothing new is recorded.
    @discardableResult
    func applyPersonalDeletionLedger() throws -> Set<String> {
        try write { db in
            let ledger = try Self.personalDeletionLedger(in: db)
            guard ledger.hasDeletions else { return [] }
            var touched = Set<String>()
            for (table, kind) in [("note_entries", LampPersonalItemKind.note),
                                  ("devotional_entries", .devotional)] {
                for row in try Row.fetchAll(db, sql: "SELECT id, module_id, last_modified FROM \(table)") {
                    let id: String = row["id"]
                    guard ledger.isDeleted(kind, id, itemModified: row["last_modified"]) else { continue }
                    try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
                    touched.insert(row["module_id"])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, module_id, last_modified FROM highlight_sets") {
                let id: String = row["id"]
                guard ledger.isDeleted(.highlightSet, id, itemModified: row["last_modified"]) else { continue }
                try db.execute(sql: "DELETE FROM highlights WHERE set_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM highlight_themes WHERE set_id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM highlight_sets WHERE id = ?", arguments: [id])
                touched.insert(row["module_id"])
            }
            let setModules = Dictionary(uniqueKeysWithValues: try Row.fetchAll(
                db, sql: "SELECT id, module_id FROM highlight_sets"
            ).map { ($0["id"] as String, $0["module_id"] as String) })
            for entry in try HighlightEntry.fetchAll(db)
            where ledger.isDeleted(.highlight, Self.ledgerKey(entry), itemModified: nil) {
                _ = try entry.delete(db)
                if let module = setModules[entry.setId] { touched.insert(module) }
            }
            for theme in try HighlightTheme.fetchAll(db)
            where ledger.isDeleted(.highlightTheme, Self.ledgerKey(theme), itemModified: nil) {
                _ = try theme.delete(db)
                if let module = setModules[theme.setId] { touched.insert(module) }
            }
            for moduleId in touched {
                let type = try String.fetchOne(db, sql: "SELECT type FROM modules WHERE id = ?", arguments: [moduleId])
                try db.execute(sql: """
                    INSERT OR REPLACE INTO sync_pending_module_publications (module_id, type)
                    VALUES (?, ?)
                    """, arguments: [moduleId, type ?? ModuleType.notes.rawValue])
            }
            return touched
        }
    }
}

// MARK: - Search Index Maintenance

/// A full-text index that reads its text from another table
/// (`content='…'`) rather than keeping a copy.
///
/// Such an index cannot look up what a row said once the row is gone, so
/// removing one has to be told: the `'delete'` command, given the old values.
/// The original triggers issued a plain `DELETE` and an `UPDATE` instead,
/// which leave the old entries in place. Every translation reinstalled by sync
/// stayed indexed: one phone held 84.5 million index entries for 155,591
/// verses, 7.5 GB of a database whose live content was under 1 GB, and
/// searches matched text that had been deleted or replaced.
struct ExternalContentSearchIndex: Equatable {
    let name: String
    let content: String
    /// The content table's row identifier, as the index refers to it.
    let rowid: String
    let columns: [String]
    let tokenize: String?

    /// A user dictionary's entries by lemma and their definitions as plain
    /// text (`DictionarySearchText`), not the JSON they are stored in.
    static let dictionary = ExternalContentSearchIndex(
        name: "dictionary_fts", content: "dictionary_entries", rowid: "rowid",
        columns: ["lemma", "search_text"], tokenize: nil
    )

    static let all: [ExternalContentSearchIndex] = [
        .init(name: "translation_verses_fts", content: "translation_verses", rowid: "id",
              columns: ["text"], tokenize: "unicode61 remove_diacritics 2"),
        dictionary,
        .init(name: "commentary_units_fts", content: "commentary_units", rowid: "rowid",
              columns: ["title", "search_text"], tokenize: nil),
        .init(name: "note_fts", content: "note_entries", rowid: "rowid",
              columns: ["title", "search_text"], tokenize: nil),
    ]

    /// Replaces each index's triggers with ones that keep it exact. Indexes
    /// whose tables this database does not have are left alone.
    static func installTriggers(in db: Database) throws {
        for index in all where try index.exists(in: db) {
            try index.installTriggers(in: db)
        }
    }

    /// Whether the index and its content are here, with every column it
    /// indexes: a migration before the one adding a column must leave the
    /// index alone, or its triggers would name a column not yet made.
    func exists(in db: Database) throws -> Bool {
        guard try db.tableExists(name), try db.tableExists(content) else { return false }
        let present = Set(try db.columns(in: content).map(\.name))
        return columns.allSatisfy(present.contains)
    }

    func installTriggers(in db: Database) throws {
        let target = name
        let columnList = columns.joined(separator: ", ")
        let newValues = columns.map { "new.\($0)" }.joined(separator: ", ")
        let oldValues = columns.map { "old.\($0)" }.joined(separator: ", ")
        // Named for the index they serve, as the originals were.
        for suffix in ["insert", "update", "delete"] {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)_\(suffix)")
        }
        try db.execute(sql: """
            CREATE TRIGGER \(name)_insert AFTER INSERT ON \(content) BEGIN
                INSERT INTO \(target)(rowid, \(columnList))
                VALUES (new.\(rowid), \(newValues));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER \(name)_update AFTER UPDATE ON \(content) BEGIN
                INSERT INTO \(target)(\(target), rowid, \(columnList))
                VALUES ('delete', old.\(rowid), \(oldValues));
                INSERT INTO \(target)(rowid, \(columnList))
                VALUES (new.\(rowid), \(newValues));
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER \(name)_delete AFTER DELETE ON \(content) BEGIN
                INSERT INTO \(target)(\(target), rowid, \(columnList))
                VALUES ('delete', old.\(rowid), \(oldValues));
            END
            """)
    }

    func createIndexSQL(named indexName: String) -> String {
        var options = columns + ["content='\(content)'", "content_rowid='\(rowid)'"]
        if let tokenize { options.append("tokenize='\(tokenize)'") }
        return "CREATE VIRTUAL TABLE \(indexName) USING fts5(\(options.joined(separator: ", ")))"
    }
}

/// Rebuilds the search indexes once, now that their triggers keep them exact,
/// and gives back the space the stale entries held.
///
/// It works on its own connection, because the app reads this database on the
/// main thread and a long write there would freeze it. An index far larger
/// than its content is rebuilt into a fresh table in batches and swapped in,
/// so search keeps working throughout; only dropping the old one is a single
/// long write. The rest are small enough for SQLite's own `'rebuild'`.
///
/// A run cut short leaves `<index>_rebuild` or `<index>_stale` behind, and the
/// next run clears them before anything else.
enum SearchIndexRepair {
    struct Options {
        var batchRows = 5_000
        /// Compact when at least this much is free, and it is a quarter of the file.
        var vacuumThreshold: Int64 = 256 * 1024 * 1024
    }

    struct Report: Equatable {
        var rebuilt: [String] = []
        var swapped: [String] = []
        var bytesBefore: Int64 = 0
        var bytesAfter: Int64 = 0
        var vacuumed = false
    }

    static func repair(
        _ queue: DatabaseQueue,
        indexes: [ExternalContentSearchIndex] = ExternalContentSearchIndex.all,
        options: Options = Options()
    ) throws -> Report {
        var report = Report()
        report.bytesBefore = try fileBytes(queue)
        for index in indexes {
            guard try queue.read({ try index.exists(in: $0) }) else { continue }
            try clearLeftovers(of: index, in: queue, options: options)

            let (entries, rows) = try queue.read { db in
                (try Int.fetchOne(db, sql: "SELECT count(*) FROM \(index.name)_docsize") ?? 0,
                 try Int.fetchOne(db, sql: "SELECT count(*) FROM \(index.content)") ?? 0)
            }
            if entries > rows + max(1_000, rows / 5) {
                try rebuildBySwapping(index, in: queue, options: options)
                report.swapped.append(index.name)
            } else {
                try queue.write { db in
                    try index.installTriggers(in: db)
                    try db.execute(sql: "INSERT INTO \(index.name)(\(index.name)) VALUES ('rebuild')")
                }
            }
            report.rebuilt.append(index.name)
        }

        let (pages, free, pageSize) = try queue.read { db in
            (try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
             try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
             try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096)
        }
        if free * pageSize >= options.vacuumThreshold, free * 4 >= pages {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            report.vacuumed = true
        }
        report.bytesAfter = try fileBytes(queue)
        return report
    }

    private static func rebuildBySwapping(
        _ index: ExternalContentSearchIndex,
        in queue: DatabaseQueue,
        options: Options
    ) throws {
        let fresh = "\(index.name)_rebuild"
        let columnList = index.columns.joined(separator: ", ")
        try queue.write { db in
            try db.execute(sql: index.createIndexSQL(named: fresh))
        }
        var last = Int64.min
        while true {
            let copied: Int64? = try queue.write { db in
                guard let through = try Int64.fetchOne(db, sql: """
                    SELECT max(\(index.rowid)) FROM (
                        SELECT \(index.rowid) FROM \(index.content)
                        WHERE \(index.rowid) > ? ORDER BY \(index.rowid) LIMIT ?
                    )
                    """, arguments: [last, options.batchRows]) else { return nil }
                try db.execute(sql: """
                    INSERT INTO \(fresh)(rowid, \(columnList))
                    SELECT \(index.rowid), \(columnList) FROM \(index.content)
                    WHERE \(index.rowid) > ? AND \(index.rowid) <= ?
                    """, arguments: [last, through])
                return through
            }
            guard let copied else { break }
            last = copied
        }

        // The content may have moved while the copy ran; if it did, the
        // fresh index is put right before it goes live. Cheap now: what made
        // the old one slow was its stale entries, which this one never had.
        try queue.write { db in
            let entries = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(fresh)_docsize") ?? 0
            let rows = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(index.content)") ?? 0
            if entries != rows {
                try db.execute(sql: "INSERT INTO \(fresh)(\(fresh)) VALUES ('rebuild')")
            }
            for suffix in ["insert", "update", "delete"] {
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(index.name)_\(suffix)")
            }
            try db.execute(sql: "ALTER TABLE \(index.name) RENAME TO \(index.name)_stale")
            try db.execute(sql: "ALTER TABLE \(fresh) RENAME TO \(index.name)")
            try index.installTriggers(in: db)
        }
        try drainStale(index, in: queue, options: options)
    }

    private static func clearLeftovers(
        of index: ExternalContentSearchIndex,
        in queue: DatabaseQueue,
        options: Options
    ) throws {
        // A copy that never went live: it holds no more than the content.
        if try queue.read({ try $0.tableExists("\(index.name)_rebuild") }) {
            try queue.write { db in
                try db.execute(sql: "DROP TABLE \(index.name)_rebuild")
            }
        }
        try drainStale(index, in: queue, options: options)
    }

    /// Drops a replaced index.
    ///
    /// The one long write in the repair, for the index that grew: freeing its
    /// pages cannot be split up, because iOS's SQLite refuses writes to an
    /// index's own tables. The app's reads carry on meanwhile, sync is waiting
    /// on this, and it happens once.
    private static func drainStale(
        _ index: ExternalContentSearchIndex,
        in queue: DatabaseQueue,
        options: Options
    ) throws {
        let stale = "\(index.name)_stale"
        guard try queue.read({ try $0.tableExists(stale) }) else { return }
        try queue.write { db in
            try db.execute(sql: "DROP TABLE \(stale)")
        }
    }

    private static func fileBytes(_ queue: DatabaseQueue) throws -> Int64 {
        try queue.read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            return pages * size
        }
    }
}

/// Runs `SearchIndexRepair` once per install, and fills in any user
/// dictionary entry's search text not yet written, in the background, and
/// lets sync wait for it: sync is what writes the content these indexes read.
@MainActor
enum SearchIndexMaintenance {
    private static let completedKey = "SearchIndexRepair.completed.v1"
    private static var task: Task<Void, Never>?

    static func start(defaults: UserDefaults = .standard) {
        guard task == nil else { return }
        let needsRepair = !defaults.bool(forKey: completedKey)
        task = Task.detached(priority: .utility) {
            let url = ModuleDatabase.shared.fileURL
            do {
                var config = Configuration()
                config.busyMode = .timeout(10)
                let queue = try DatabaseQueue(path: url.path, configuration: config)
                defer { try? queue.close() }
                if needsRepair {
                    let started = Date()
                    let report = try SearchIndexRepair.repair(queue)
                    print("[SearchIndex] repaired \(report.rebuilt) (swapped \(report.swapped)) in \(Int(Date().timeIntervalSince(started)))s: \(report.bytesBefore / 1_000_000) MB -> \(report.bytesAfter / 1_000_000) MB\(report.vacuumed ? ", compacted" : "")")
                    defaults.set(true, forKey: completedKey)
                }
                // Nothing to do, and one quick query, once every entry has it.
                let filled = try DictionarySearchText.fillMissing(in: queue)
                if filled > 0 { print("[SearchIndex] wrote search text for \(filled) dictionary entries") }
            } catch {
                // Not marked done: the next launch picks up where this stopped.
                print("[SearchIndex] maintenance stopped: \(error)")
            }
        }
    }

    static func waitUntilFinished() async {
        await task?.value
    }
}

/// A user dictionary entry's definitions as plain text, for its search index:
/// each sense's definition, short definition and gloss, as core's dictionary
/// compiler writes `search_text` into a module file.
enum DictionarySearchText {
    static func text(fromSensesJSON json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let senses = try? JSONDecoder().decode([DictionarySense].self, from: data) else { return "" }
        return senses
            .flatMap { [$0.definitionText, $0.shortDefinitionText, $0.gloss].compactMap { $0 } }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Writes the text of each entry without it, a module's or every one's.
    /// An entry with no text gets an empty one, so it isn't read again.
    @discardableResult
    static func fill(in db: Database, moduleId: String? = nil) throws -> Int {
        guard try db.columns(in: "dictionary_entries").contains(where: { $0.name == "search_text" }) else {
            return 0
        }
        var sql = "SELECT rowid, senses_json FROM dictionary_entries WHERE search_text IS NULL"
        var arguments: StatementArguments = []
        if let moduleId {
            sql += " AND module_id = ?"
            arguments = [moduleId]
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        for row in rows {
            try db.execute(
                sql: "UPDATE dictionary_entries SET search_text = ? WHERE rowid = ?",
                arguments: [text(fromSensesJSON: row["senses_json"]), row["rowid"] as Int64]
            )
        }
        return rows.count
    }

    /// In batches, so the app's own writes get between them.
    static func fillMissing(in queue: DatabaseQueue, batch: Int = 500) throws -> Int {
        guard try queue.read({ try $0.tableExists("dictionary_entries") }) else { return 0 }
        var total = 0
        while true {
            let written: Int = try queue.write { db in
                guard try db.columns(in: "dictionary_entries").contains(where: { $0.name == "search_text" }) else {
                    return 0
                }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, senses_json FROM dictionary_entries
                    WHERE search_text IS NULL LIMIT ?
                    """, arguments: [batch])
                for row in rows {
                    try db.execute(
                        sql: "UPDATE dictionary_entries SET search_text = ? WHERE rowid = ?",
                        arguments: [text(fromSensesJSON: row["senses_json"]), row["rowid"] as Int64]
                    )
                }
                return rows.count
            }
            total += written
            if written < batch { return total }
        }
    }
}
