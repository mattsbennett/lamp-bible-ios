//
//  ModuleSyncManager.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import RealmSwift
import Compression

class ModuleSyncManager {
    static let shared = ModuleSyncManager()

    private let storage = ICloudModuleStorage.shared
    private let database = ModuleDatabase.shared

    private var isSyncing = false

    private init() {}

    // MARK: - Full Sync

    /// Sync all module types on app launch
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        for type in ModuleType.allCases {
            do {
                try await syncModuleType(type)
            } catch {
                print("Failed to sync \(type.rawValue) modules: \(error)")
            }
        }
    }

    /// Sync all modules of a specific type
    func syncModuleType(_ type: ModuleType) async throws {
        guard await storage.isAvailable() else {
            print("iCloud storage not available for \(type.rawValue)")
            return
        }

        // Debug: Print the directory being scanned
        if let dirURL = storage.directoryURL(for: type) {
            print("Scanning directory for \(type.rawValue): \(dirURL.path)")
        }

        // Get files from iCloud
        let cloudFiles = try await storage.listModuleFiles(type: type)
        print("Found \(cloudFiles.count) \(type.rawValue) files: \(cloudFiles.map { $0.id })")

        // Get registered modules from database
        let registeredModules = try database.getAllModules(type: type)
        let registeredIds = Set(registeredModules.map { $0.id })

        // Import new or updated modules from cloud
        for fileInfo in cloudFiles {
            let isNew = !registeredIds.contains(fileInfo.id)
            let needsUpdate = !isNew && registeredModules.first(where: { $0.id == fileInfo.id })?.fileHash != fileInfo.fileHash

            if isNew || needsUpdate {
                do {
                    try await importModuleFromCloud(fileInfo: fileInfo, type: type)
                } catch {
                    print("Failed to import module \(fileInfo.id): \(error)")
                }
            }
        }

        // Remove modules deleted from cloud
        let cloudIds = Set(cloudFiles.map { $0.id })
        for module in registeredModules where !cloudIds.contains(module.id) {
            do {
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

        guard await storage.isAvailable() else {
            throw ModuleStorageError.notAvailable
        }

        // Use the stored file path from module metadata
        let fileName = module.filePath
        let cloudHash = try await storage.getFileHash(type: module.type, fileName: fileName)

        if cloudHash != module.fileHash {
            // Cloud has changes - reimport
            let isDbZlib = fileName.hasSuffix(".db.zlib")
            let fileExtension = (fileName as NSString).pathExtension.lowercased()

            if fileExtension == "db" || isDbZlib {
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
                let data = try await storage.readModuleFile(type: module.type, fileName: fileName)
                try await importModuleData(id: id, type: module.type, data: data, hash: cloudHash)
            }
        }
    }

    // MARK: - Import from Cloud

    private func importModuleFromCloud(fileInfo: ModuleFileInfo, type: ModuleType) async throws {
        // Check file extension to determine import method
        let isDbZlib = fileInfo.filePath.hasSuffix(".db.zlib")
        let fileExtension = (fileInfo.filePath as NSString).pathExtension.lowercased()

        if fileExtension == "db" || isDbZlib {
            // SQLite format (compressed or uncompressed) - use fast ATTACH DATABASE method
            try await importModuleFromSQLite(fileInfo: fileInfo, type: type)
        } else {
            // JSON format - use traditional JSON decoding
            let data = try await storage.readModuleFile(type: type, fileName: fileInfo.filePath)
            try await importModuleData(id: fileInfo.id, type: type, data: data, hash: fileInfo.fileHash)
        }
    }

    private func importModuleFromSQLite(fileInfo: ModuleFileInfo, type: ModuleType) async throws {
        // Download the .db or .db.zlib file to temporary location
        let data = try await storage.readModuleFile(type: type, fileName: fileInfo.filePath)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")

        // Decompress if it's a .zlib file
        if fileInfo.filePath.hasSuffix(".db.zlib") {
            let decompressedData = try decompressZlib(data)
            try decompressedData.write(to: tempURL)
        } else {
            try data.write(to: tempURL)
        }

        // Create module metadata FIRST (entries have foreign key to modules table)
        try await createModuleMetadata(id: fileInfo.id, type: type, hash: fileInfo.fileHash, tempURL: tempURL)

        // Delete existing module entries (after creating module record to avoid orphans)
        try database.deleteAllEntriesForModule(moduleId: fileInfo.id)

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

                    case .devotional:
                        // Copy devotional entries
                        try db.execute(sql: """
                            INSERT INTO devotional_entries
                            (id, module_id, month_day, tags, title, content, verse_refs, last_modified)
                            SELECT id, module_id, month_day, tags, title, content, verse_refs, last_modified
                            FROM \(dbAlias).devotional_entries
                            """)

                    case .notes:
                        // Copy note entries
                        try db.execute(sql: """
                            INSERT INTO note_entries
                            (id, module_id, verse_id, title, content, verse_refs, last_modified)
                            SELECT id, module_id, verse_id, title, content, verse_refs, last_modified
                            FROM \(dbAlias).note_entries
                            """)

                    case .translation:
                        throw ModuleSyncError.importFailed("SQLite format not supported for translation modules")
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
    }

    private func createModuleMetadata(id: String, type: ModuleType, hash: String?, tempURL: URL) async throws {
        // Create module record by inspecting imported data
        // Use .db.zlib extension since we're compressing all SQLite files
        let filePath = "\(id).db.zlib"

        switch type {
        case .dictionary:
            // Try to read module metadata from the temp database
            var moduleName = id.uppercased()
            var moduleDescription: String? = nil
            var moduleAuthor: String? = nil
            var moduleVersion: String? = nil
            var keyType: String? = nil

            // Open the temp database to read module_metadata table
            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    if let row = try Row.fetchOne(db, sql: "SELECT name, description, author, version, key_type FROM module_metadata WHERE id = ?", arguments: [id]) {
                        if let name: String = row["name"] { moduleName = name }
                        moduleDescription = row["description"]
                        moduleAuthor = row["author"]
                        moduleVersion = row["version"]
                        keyType = row["key_type"]
                    }
                }
            } catch {
                print("Could not read module_metadata from temp database: \(error)")
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
                keyType: keyType
            )
            try database.saveModule(module)

        case .commentary:
            // Read book metadata from temp database (before import)
            var title: String = "Unknown Title"
            var author: String? = nil
            var seriesFull: String? = nil

            do {
                var config = Configuration()
                config.readonly = true
                let tempDb = try DatabaseQueue(path: tempURL.path, configuration: config)
                try await tempDb.read { db in
                    if let row = try Row.fetchOne(db, sql: "SELECT title, author, series_full FROM commentary_books WHERE module_id = ?", arguments: [id]) {
                        if let t: String = row["title"] { title = t }
                        author = row["author"]
                        seriesFull = row["series_full"]
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
                isEditable: false
            )
            try database.saveModule(module)

        case .devotional:
            let module = Module(
                id: id,
                type: .devotional,
                name: id.uppercased(),
                description: nil,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: false
            )
            try database.saveModule(module)

        case .notes:
            let module = Module(
                id: id,
                type: .notes,
                name: id.uppercased(),
                description: nil,
                filePath: filePath,
                fileHash: hash,
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: true
            )
            try database.saveModule(module)

        case .translation:
            throw ModuleSyncError.importFailed("SQLite format not supported for translation modules")
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
            let moduleFile = try decoder.decode(TranslationModuleFile.self, from: data)
            try await importTranslationModule(moduleFile)

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
            keyType: file.keyType
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

        let entries = file.entries.map { entry in
            DevotionalEntry(
                id: entry.id,
                moduleId: file.id,
                monthDay: entry.monthDay,
                tags: entry.tags,
                title: entry.title,
                content: entry.content,
                verseRefs: entry.verseRefs?.map { $0.sv },
                lastModified: entry.lastModified
            )
        }
        try database.importDevotionalEntries(entries)
    }

    private func importNoteModule(_ file: NoteModuleFile, hash: String?) throws {
        let module = Module(
            id: file.id,
            type: .notes,
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

        let entries = file.entries.map { entry in
            NoteEntry(
                id: entry.id,
                moduleId: file.id,
                verseId: entry.verseId,
                title: entry.title,
                content: entry.content,
                verseRefs: entry.verseRefs?.map { $0.sv },
                lastModified: entry.lastModified
            )
        }
        try database.importNoteEntries(entries)
    }

    private func importTranslationModule(_ file: TranslationModuleFile) async throws {
        let realm = try await Realm()

        // Check if translation already exists
        if let existing = realm.object(ofType: Translation.self, forPrimaryKey: file.id) {
            // Delete existing translation's verses and the translation itself
            try realm.write {
                realm.delete(existing.verses)
                realm.delete(existing)
            }
        }

        // Create new translation
        let translation = Translation()
        translation.id = file.id
        translation.abbreviation = file.abbreviation
        translation.language = file.language
        translation.name = file.name
        translation.url = file.url ?? ""
        translation.license = file.license ?? ""
        translation.fullDescription = file.description ?? ""

        // Create verses
        for verseFile in file.verses {
            let verse = Verse()
            verse.id = verseFile.id
            verse.b = verseFile.b
            verse.c = verseFile.c
            verse.v = verseFile.v
            verse.t = verseFile.t
            verse.cleanText = verseFile.cleanText ?? ""
            verse.tr = file.id
            translation.verses.append(verse)
        }

        try realm.write {
            realm.add(translation)
        }

        print("Imported translation: \(file.name) with \(file.verses.count) verses")
    }

    // MARK: - Export to Cloud (for editable modules)

    /// Export an editable module to iCloud
    func exportModule(id: String) async throws {
        guard let module = try database.getModule(id: id) else {
            throw ModuleSyncError.moduleNotFound(id)
        }

        guard module.isEditable else {
            throw ModuleSyncError.moduleNotEditable(id)
        }

        guard await storage.isAvailable() else {
            throw ModuleStorageError.notAvailable
        }

        let data: Data
        switch module.type {
        case .notes:
            data = try exportNoteModule(module)
        case .devotional:
            data = try exportDevotionalModule(module)
        case .translation, .dictionary, .commentary:
            throw ModuleSyncError.moduleNotEditable(id)
        }

        let fileName = "\(id).json"
        try await storage.writeModuleFile(type: module.type, fileName: fileName, data: data)

        // Update hash after export
        if let newHash = try await storage.getFileHash(type: module.type, fileName: fileName) {
            var updatedModule = module
            updatedModule.fileHash = newHash
            updatedModule.lastSynced = Int(Date().timeIntervalSince1970)
            try database.saveModule(updatedModule)
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
                    lastModified: entry.lastModified
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

        let moduleFile = DevotionalModuleFile(
            id: module.id,
            name: module.name,
            description: module.description,
            author: module.author,
            version: module.version,
            type: "devotional",
            isEditable: module.isEditable,
            entries: entries.map { entry in
                DevotionalEntryFile(
                    id: entry.id,
                    monthDay: entry.monthDay,
                    tags: entry.tagList.isEmpty ? nil : entry.tagList,
                    title: entry.title,
                    content: entry.content,
                    verseRefs: entry.verseRefs?.map { VerseRef(sv: $0, ev: nil) },
                    lastModified: entry.lastModified
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(moduleFile)
    }

    // MARK: - Create Default Notes Module

    /// Create the default "Bible Notes" module if it doesn't exist
    func ensureDefaultNotesModule() async throws {
        let notesModules = try database.getAllModules(type: .notes)

        if notesModules.isEmpty {
            let defaultModule = Module(
                id: "bible-notes",
                type: .notes,
                name: "Bible Notes",
                description: "Personal Bible study notes",
                filePath: "bible-notes.json",
                isEditable: true,
                createdAt: Int(Date().timeIntervalSince1970)
            )
            try database.saveModule(defaultModule)

            // Export empty module to iCloud
            if await storage.isAvailable() {
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

    /// Save a devotional entry and export to iCloud
    func saveDevotional(_ entry: DevotionalEntry) async throws {
        try database.saveDevotionalEntry(entry)
        try await exportModule(id: entry.moduleId)
    }

    /// Delete a devotional entry and export to iCloud
    func deleteDevotional(id: String, moduleId: String) async throws {
        try database.deleteDevotionalEntry(id: id)
        try await exportModule(id: moduleId)
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
