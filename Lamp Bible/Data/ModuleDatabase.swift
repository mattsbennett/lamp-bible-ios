//
//  ModuleDatabase.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB

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

    private func setupDatabase() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for concurrent access
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

        // Run migrations
        try migrator.migrate(dbQueue)
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
                t.column("month_day", .text)
                t.column("tags", .text)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("verse_refs_json", .text)
                t.column("last_modified", .integer)
            }
            try db.create(index: "idx_dev_module", on: "devotional_entries", columns: ["module_id"])
            try db.create(index: "idx_dev_date", on: "devotional_entries", columns: ["month_day"])

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

        return migrator
    }

    // MARK: - Database Access

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    func writeWithoutTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.writeWithoutTransaction(block)
    }

    // MARK: - Module CRUD

    func saveModule(_ module: Module) throws {
        try dbQueue.write { db in
            try module.save(db)
        }
    }

    func deleteModule(id: String) throws {
        try dbQueue.write { db in
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

    // MARK: - Note Entry CRUD

    func saveNoteEntry(_ entry: NoteEntry) throws {
        try dbQueue.write { db in
            try entry.save(db)
        }
    }

    func deleteNoteEntry(id: String) throws {
        try dbQueue.write { db in
            _ = try NoteEntry.deleteOne(db, key: id)
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

    // MARK: - Commentary Series Queries

    /// Get all unique series names (full names) from commentary books
    func getCommentarySeries() throws -> [String] {
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
        }
    }

    func getDictionaryEntry(moduleId: String, key: String) throws -> DictionaryEntry? {
        try dbQueue.read { db in
            try DictionaryEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("key") == key)
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
        try dbQueue.write { db in
            try entry.save(db)
        }
    }

    func deleteDevotionalEntry(id: String) throws {
        try dbQueue.write { db in
            _ = try DevotionalEntry.deleteOne(db, key: id)
        }
    }

    func getDevotionalEntry(id: String) throws -> DevotionalEntry? {
        try dbQueue.read { db in
            try DevotionalEntry.fetchOne(db, key: id)
        }
    }

    func getDevotionalsForDate(moduleId: String, monthDay: String) throws -> [DevotionalEntry] {
        try dbQueue.read { db in
            try DevotionalEntry
                .filter(Column("module_id") == moduleId)
                .filter(Column("month_day") == monthDay)
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

    // MARK: - Bulk Operations

    func deleteAllEntriesForModule(moduleId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dictionary_entries WHERE module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM commentary_units WHERE module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM commentary_books WHERE module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM devotional_entries WHERE module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM note_entries WHERE module_id = ?", arguments: [moduleId])
        }
    }

    func importDictionaryEntries(_ entries: [DictionaryEntry]) throws {
        try dbQueue.write { db in
            for entry in entries {
                try entry.save(db)
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

    func importNoteEntries(_ entries: [NoteEntry]) throws {
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
}
