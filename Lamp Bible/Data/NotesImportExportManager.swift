//
//  NotesImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-09.
//

import Foundation
import UIKit
import LampCore

/// Manages markdown import/export for user notes
/// Import: iCloud/Documents/Import/Notes/*.md → parsed and saved to database, file deleted
/// Export: Database → iCloud/Documents/Export/Notes/{book}.md
///
/// Media files are stored in a shared `media/` folder:
/// - Export: `Export/Notes/media/{filename}`
/// - Import: `Import/Notes/media/{filename}`
class NotesImportExportManager {
    static let shared = NotesImportExportManager()

    private let fileManager = FileManager.default
    private let containerIdentifier = "iCloud.com.neus.lamp-bible"

    // MARK: - Directory Access

    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private var documentsURL: URL? {
        guard let container = containerURL else { return nil }
        return container.appendingPathComponent("Documents")
    }

    var importDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent("Import").appendingPathComponent("Notes")
    }

    var exportDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent("Export").appendingPathComponent("Notes")
    }

    // MARK: - Book Name Mappings

    private let bookNames = Dictionary(uniqueKeysWithValues: (1...66).map {
        ($0, LampBibleReferenceFormatter.bookName($0))
    })
    private let bookAbbrevs = Dictionary(uniqueKeysWithValues: (1...66).map {
        ($0, LampBibleReferenceFormatter.bookAbbreviation($0))
    })

    // MARK: - Import

    /// Import result for a single file
    struct ImportResult {
        let fileName: String
        let bookName: String
        let bookNumber: Int
        let chapterCount: Int
        let verseCount: Int
        let success: Bool
        let error: String?
    }

    /// Process all markdown files in the Import directory
    /// Returns list of imported book names, deletes files after successful import
    func processImports() async throws -> [ImportResult] {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            return []
        }
        print("[NotesImport] processImports() called")
        guard let importDir = importDirectoryURL else {
            print("[NotesImport] Import directory not available")
            return []
        }
        print("[NotesImport] Import directory: \(importDir.path)")

        // Create import directory if needed
        if !fileManager.fileExists(atPath: importDir.path) {
            try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
            print("[NotesImport] Created import directory")
            return []
        }

        // Find all .md files
        let contents = try fileManager.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil)
        let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }

        if mdFiles.isEmpty {
            return []
        }

        print("[NotesImport] Found \(mdFiles.count) markdown file(s) to import")

        var results: [ImportResult] = []

        for fileURL in mdFiles {
            do {
                let result = try await importMarkdownFile(at: fileURL)
                results.append(result)

                if result.success {
                    // Delete file after successful import
                    try fileManager.removeItem(at: fileURL)
                    print("[NotesImport] Deleted imported file: \(fileURL.lastPathComponent)")
                }
            } catch {
                results.append(ImportResult(
                    fileName: fileURL.lastPathComponent,
                    bookName: "",
                    bookNumber: 0,
                    chapterCount: 0,
                    verseCount: 0,
                    success: false,
                    error: error.localizedDescription
                ))
                print("[NotesImport] Error importing \(fileURL.lastPathComponent): \(error)")
            }
        }

        return results
    }

    /// Import a single markdown file (can contain one book or multiple books)
    private func importMarkdownFile(at url: URL) async throws -> ImportResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        let books = try parsedMarkdownBooks(
            content: content, filename: url.deletingPathExtension().lastPathComponent
        )
        for book in books { try await saveNotesToDatabase(book) }
        return importResult(for: books, filename: url.lastPathComponent)
    }

    private func importResult(for books: [UserNotesBook], filename: String) -> ImportResult {
        ImportResult(
            fileName: filename,
            bookName: books.count == 1 ? books[0].book : "\(books.count) books",
            bookNumber: books.count == 1 ? books[0].bookNumber : 0,
            chapterCount: books.reduce(0) { $0 + $1.chapters.count },
            verseCount: books.flatMap(\.chapters).reduce(0) { $0 + ($1.verses?.count ?? 0) },
            success: true, error: nil
        )
    }

    func parseMarkdownToNotes(content: String, filename: String) throws -> UserNotesBook {
        let books = try parsedMarkdownBooks(
            content: content,
            filename: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        )
        guard books.count == 1, let book = books.first else {
            throw ImportError.parseError("Expected notes for one book")
        }
        return book
    }

    /// Core owns headings, ranges and footnotes; this adapter builds the iOS
    /// book/chapter records used by its database and media importer.
    private func parsedMarkdownBooks(content: String, filename: String) throws -> [UserNotesBook] {
        let metadata = LampPersonalMarkdownDocument.frontmatter(in: content).metadata
        let drafts = try LampPersonalMarkdownParser.notes(from: content, filename: filename)
            .map { $0.withNumberedFootnotes() }
        let groups = Dictionary(grouping: drafts) { $0.reference / 1_000_000 }
        var seen = Set<Int>()
        let bookNumbers = drafts.map { $0.reference / 1_000_000 }.filter { seen.insert($0).inserted }
        let modified = Int(Date().timeIntervalSince1970)
        return bookNumbers.map { bookNumber in
            let chapters = Dictionary(grouping: groups[bookNumber] ?? []) {
                ($0.reference / 1_000) % 1_000
            }.sorted { $0.key < $1.key }.map { chapter, drafts in
                let introduction = drafts.first { $0.reference % 1_000 == 0 }
                let verses = drafts.filter { $0.reference % 1_000 != 0 }.map { draft in
                    // iOS's portable note model carries titles in the body.
                    let body = draft.title.map { "**Title:** \($0)\n\n" } ?? ""
                    let end = draft.verseReferences.last.flatMap { $0 == draft.reference ? nil : $0 }
                    return UserNotesVerse(
                        sv: draft.reference, ev: end,
                        commentary: .text(body + draft.content),
                        footnotes: draft.footnotes.isEmpty ? nil : draft.footnotes.map {
                            UserNotesFootnote(id: $0.id, content: .text($0.content))
                        }, lastModified: modified
                    )
                }
                return UserNotesChapter(
                    chapter: chapter,
                    introduction: introduction.map { .text($0.content) },
                    verses: verses.isEmpty ? nil : verses,
                    footnotes: introduction.flatMap { draft in
                        draft.footnotes.isEmpty ? nil : draft.footnotes.map {
                            UserNotesFootnote(id: $0.id, content: .text($0.content))
                        }
                    }
                )
            }
            return UserNotesBook(
                meta: UserNotesMeta(id: metadata["id"] ?? "notes", name: metadata["name"], author: metadata["author"]),
                book: bookName(bookNumber, metadata: metadata, isSingleBook: groups.count == 1),
                bookNumber: bookNumber, chapters: chapters
            )
        }
    }

    private func bookName(_ number: Int, metadata: [String: String], isSingleBook: Bool) -> String {
        isSingleBook ? metadata["book"] ?? LampBibleReferenceFormatter.bookName(number)
            : LampBibleReferenceFormatter.bookName(number)
    }

    // MARK: - Export

    /// Export a single book's notes to markdown
    func exportToMarkdown(notesBook: UserNotesBook) async throws -> URL {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let markdown = generateMarkdown(from: notesBook)
        let fileName = "\(notesBook.book).md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[NotesExport] Exported \(fileName)")

        return fileURL
    }

    /// Generate markdown from UserNotesBook
    func generateMarkdown(from notesBook: UserNotesBook) -> String {
        var lines: [String] = []

        // YAML frontmatter
        lines.append("---")
        lines.append("id: \(notesBook.meta.id)")
        lines.append("type: notes")
        if let name = notesBook.meta.name {
            lines.append("name: \"\(name)\"")
        }
        if let author = notesBook.meta.author {
            lines.append("author: \"\(author)\"")
        }
        lines.append("book: \(notesBook.book)")
        lines.append("bookNumber: \(notesBook.bookNumber)")
        lines.append("---")
        lines.append("")

        // Book title
        let bookName = bookNames[notesBook.bookNumber] ?? notesBook.book
        lines.append("# \(bookName)")
        lines.append("")

        // Collect all footnotes with unique IDs for end of document
        var allFootnotes: [(uniqueId: String, content: String)] = []

        // Process chapters
        for chapter in notesBook.sortedChapters {
            lines.append("## Chapter \(chapter.chapter)")
            lines.append("")

            // Chapter introduction
            if let intro = chapter.introduction, !intro.isEmpty {
                lines.append("### Introduction")
                lines.append("")
                // Replace local footnote markers with unique IDs
                let introContent = replaceFootnoteMarkers(
                    content: intro,
                    prefix: "\(chapter.chapter):0",
                    footnotes: chapter.footnotes,
                    allFootnotes: &allFootnotes
                )
                lines.append(introContent)
                lines.append("")
            }

            // Verse notes
            for verse in chapter.sortedVerses {
                let verseRef = verseRefToString(sv: verse.sv, ev: verse.ev)
                lines.append("### \(verseRef)")
                lines.append("")
                // Replace local footnote markers with unique IDs
                let verseContent = replaceFootnoteMarkers(
                    content: verse.commentary,
                    prefix: verseRef,
                    footnotes: verse.footnotes,
                    allFootnotes: &allFootnotes
                )
                lines.append(verseContent)
                lines.append("")
            }
        }

        // Add all footnotes at the end of the document
        if !allFootnotes.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            for (uniqueId, content) in allFootnotes {
                let contentLines = content.components(separatedBy: "\n")
                if contentLines.count == 1 {
                    lines.append("[^\(uniqueId)]: \(content)")
                } else {
                    lines.append("[^\(uniqueId)]: \(contentLines[0])")
                    for line in contentLines.dropFirst() {
                        lines.append("    \(line)")
                    }
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Replace local footnote markers [^1] with unique IDs [^1:5-1] and collect footnote definitions
    private func replaceFootnoteMarkers(
        content: AnnotatedTextField,
        prefix: String,
        footnotes: [UserNotesFootnote]?,
        allFootnotes: inout [(uniqueId: String, content: String)]
    ) -> String {
        let rewritten = LampPersonalMarkdownWriter.rewritingFootnoteMarkers(
            in: content.plainText, prefix: prefix,
            footnotes: (footnotes ?? []).map { (id: $0.id, content: $0.content.plainText) }
        )
        allFootnotes += rewritten.definitions.map { (uniqueId: $0.id, content: $0.content) }
        return rewritten.content
    }

    /// Convert BBCCCVVV verse reference to string like "1:1" or "1:2-5"
    private func verseRefToString(sv: Int, ev: Int?) -> String {
        LampPersonalMarkdownWriter.noteHeading(reference: sv, endReference: ev)
    }

    // MARK: - Public Import from String

    /// Import notes from markdown string (used by MarkdownConverter and other importers)
    /// Returns count of imported entries
    func importNotesFromMarkdownString(_ content: String, moduleId: String) async throws -> Int {
        let books = try parsedMarkdownBooks(content: content, filename: "import")
        for book in books { try await saveNotesToDatabase(book, moduleId: moduleId) }
        return books.flatMap(\.chapters).reduce(0) {
            $0 + ($1.verses?.count ?? 0) + ($1.introduction == nil ? 0 : 1)
        }
    }

    // MARK: - Database Integration

    /// Save notes to database
    private func saveNotesToDatabase(_ notesBook: UserNotesBook, moduleId: String? = nil) async throws {
        let targetModuleId = moduleId ?? "notes"

        // Ensure module exists
        try await ensureNotesModuleExists(id: targetModuleId, name: notesBook.meta.name ?? "My Notes")

        // Convert to NoteEntry records and save
        for chapter in notesBook.chapters {
            // Save introduction as verse 0
            if let intro = chapter.introduction, !intro.isEmpty {
                let verseId = notesBook.bookNumber * 1_000_000 + chapter.chapter * 1000 + 0
                // Parse footnotes for intro
                var introFootnotes: [UserNotesFootnote]? = nil
                if let chapterFootnotes = chapter.footnotes, !chapterFootnotes.isEmpty {
                    introFootnotes = chapterFootnotes
                }
                let entry = NoteEntry(
                    id: "\(targetModuleId):\(verseId)",
                    moduleId: targetModuleId,
                    verseId: verseId,
                    title: "Introduction",
                    content: intro.plainText,
                    verseRefs: nil,
                    lastModified: Int(Date().timeIntervalSince1970),
                    footnotes: introFootnotes
                )
                try ModuleDatabase.shared.saveNoteEntry(entry)
            }

            // Save verse notes
            if let verses = chapter.verses {
                for verse in verses {
                    // Convert end verse to array if present
                    let verseRefs: [Int]? = verse.ev.map { [$0] }

                    print("[NotesImport] Saving verse \(verse.sv): footnotes=\(verse.footnotes?.count ?? 0)")
                    if let fns = verse.footnotes {
                        for fn in fns {
                            print("[NotesImport]   Footnote \(fn.id): \(fn.content.plainText.prefix(50))")
                        }
                    }

                    let entry = NoteEntry(
                        id: "\(targetModuleId):\(verse.sv)",
                        moduleId: targetModuleId,
                        verseId: verse.sv,
                        title: nil,
                        content: verse.plainText,
                        verseRefs: verseRefs,
                        lastModified: verse.lastModified ?? Int(Date().timeIntervalSince1970),
                        footnotes: verse.footnotes
                    )
                    try ModuleDatabase.shared.saveNoteEntry(entry)
                }
            }
        }

        print("[NotesImport] Saved notes for \(notesBook.book) to database")
    }

    /// Ensure the user notes module exists
    private func ensureNotesModuleExists(id: String, name: String) async throws {
        let existingModules = try ModuleDatabase.shared.getAllModules()
        if !existingModules.contains(where: { $0.id == id }) {
            let module = Module(
                id: id,
                type: .notes,
                name: name,
                filePath: "",  // User notes don't have a file path
                lastSynced: Int(Date().timeIntervalSince1970),
                isEditable: true
            )
            try ModuleDatabase.shared.saveModule(module)
        }
    }

    // MARK: - Export All

    /// Export all user notes to markdown files
    /// Returns list of exported file URLs
    func exportAllToMarkdown() async throws -> [URL] {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let moduleId = "notes"

        // Get all book numbers that have notes
        let bookNumbers = try ModuleDatabase.shared.getBookNumbersWithNotes(moduleId: moduleId)

        if bookNumbers.isEmpty {
            throw ExportError.noNotesFound
        }

        var exportedURLs: [URL] = []

        for bookNumber in bookNumbers {
            do {
                let notesBook = try loadNotesForBook(moduleId: moduleId, bookNumber: bookNumber)
                let url = try await exportToMarkdown(notesBook: notesBook)
                exportedURLs.append(url)
            } catch {
                print("[NotesExport] Failed to export book \(bookNumber): \(error)")
            }
        }

        return exportedURLs
    }

    /// Export all user notes to a single combined markdown file
    /// Returns the URL of the exported file
    func exportAllToSingleFile() async throws -> URL {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let moduleId = "notes"

        // Get all book numbers that have notes
        let bookNumbers = try ModuleDatabase.shared.getBookNumbersWithNotes(moduleId: moduleId)

        if bookNumbers.isEmpty {
            throw ExportError.noNotesFound
        }

        var lines: [String] = []

        // Header
        lines.append("# My Notes")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Collect all footnotes with unique IDs
        var allFootnotes: [(uniqueId: String, content: String)] = []

        // Process each book
        for bookNumber in bookNumbers.sorted() {
            let notesBook = try loadNotesForBook(moduleId: moduleId, bookNumber: bookNumber)
            let bookName = bookNames[bookNumber] ?? notesBook.book

            lines.append("## \(bookName)")
            lines.append("")

            for chapter in notesBook.sortedChapters {
                lines.append("### Chapter \(chapter.chapter)")
                lines.append("")

                // Introduction
                if let intro = chapter.introduction, !intro.isEmpty {
                    lines.append("#### Introduction")
                    lines.append("")
                    let introContent = replaceFootnoteMarkersForSingleFile(
                        content: intro,
                        bookAbbrev: bookAbbrevs[bookNumber] ?? "B\(bookNumber)",
                        chapter: chapter.chapter,
                        verse: 0,
                        footnotes: chapter.footnotes,
                        allFootnotes: &allFootnotes
                    )
                    lines.append(introContent)
                    lines.append("")
                }

                // Verses
                for verse in chapter.sortedVerses {
                    let verseRef = verseRefToString(sv: verse.sv, ev: verse.ev)
                    lines.append("#### \(verseRef)")
                    lines.append("")
                    let verseContent = replaceFootnoteMarkersForSingleFile(
                        content: verse.commentary,
                        bookAbbrev: bookAbbrevs[bookNumber] ?? "B\(bookNumber)",
                        chapter: (verse.sv / 1000) % 1000,
                        verse: verse.sv % 1000,
                        footnotes: verse.footnotes,
                        allFootnotes: &allFootnotes
                    )
                    lines.append(verseContent)
                    lines.append("")
                }
            }
        }

        // Add all footnotes at end
        if !allFootnotes.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            for (uniqueId, content) in allFootnotes {
                let contentLines = content.components(separatedBy: "\n")
                if contentLines.count == 1 {
                    lines.append("[^\(uniqueId)]: \(content)")
                } else {
                    lines.append("[^\(uniqueId)]: \(contentLines[0])")
                    for line in contentLines.dropFirst() {
                        lines.append("    \(line)")
                    }
                }
                lines.append("")
            }
        }

        let markdown = lines.joined(separator: "\n")
        let fileName = "All_Notes.md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[NotesExport] Exported all notes to \(fileName)")

        return fileURL
    }

    /// Replace footnote markers with unique IDs for single-file export (includes book abbreviation)
    private func replaceFootnoteMarkersForSingleFile(
        content: AnnotatedTextField,
        bookAbbrev: String,
        chapter: Int,
        verse: Int,
        footnotes: [UserNotesFootnote]?,
        allFootnotes: inout [(uniqueId: String, content: String)]
    ) -> String {
        replaceFootnoteMarkers(
            content: content, prefix: "\(bookAbbrev)-\(chapter):\(verse)",
            footnotes: footnotes, allFootnotes: &allFootnotes
        )
    }

    /// Load notes from database and convert to UserNotesBook format
    func loadNotesForBook(moduleId: String, bookNumber: Int) throws -> UserNotesBook {
        let entries = try ModuleDatabase.shared.getAllNotesForBook(moduleId: moduleId, book: bookNumber)

        guard !entries.isEmpty else {
            throw ExportError.noNotesFound
        }

        // Group entries by chapter
        var chapterEntries: [Int: [NoteEntry]] = [:]
        for entry in entries {
            chapterEntries[entry.chapter, default: []].append(entry)
        }

        // Build chapters
        var chapters: [UserNotesChapter] = []
        for chapterNum in chapterEntries.keys.sorted() {
            let entries = chapterEntries[chapterNum]!
            var introduction: AnnotatedTextField?
            var verses: [UserNotesVerse] = []
            var chapterFootnotes: [UserNotesFootnote] = []

            for entry in entries {
                // Get footnotes using computed property
                let entryFootnotes = entry.footnotes

                if entry.verse == 0 {
                    // Introduction
                    introduction = .text(entry.content)
                    if let fns = entryFootnotes {
                        chapterFootnotes.append(contentsOf: fns)
                    }
                } else {
                    // Verse note
                    let verse = UserNotesVerse(
                        sv: entry.verseId,
                        ev: nil,  // TODO: Parse from verseRefsJson if needed
                        commentary: .text(entry.content),
                        footnotes: entryFootnotes,
                        lastModified: entry.lastModified
                    )
                    verses.append(verse)
                }
            }

            let chapter = UserNotesChapter(
                chapter: chapterNum,
                introduction: introduction,
                verses: verses.isEmpty ? nil : verses,
                footnotes: chapterFootnotes.isEmpty ? nil : chapterFootnotes
            )
            chapters.append(chapter)
        }

        let meta = UserNotesMeta(
            id: moduleId,
            name: "My Notes"
        )

        let bookName = bookNames[bookNumber] ?? "Book \(bookNumber)"

        return UserNotesBook(
            meta: meta,
            book: bookName,
            bookNumber: bookNumber,
            chapters: chapters
        )
    }

    // MARK: - Media Export Helpers

    /// Export media files to the shared media folder
    private func exportMediaFiles(
        _ mediaRefs: [MediaReference],
        moduleId: String,
        to exportDir: URL
    ) throws {
        guard !mediaRefs.isEmpty else { return }

        let mediaDir = exportDir.appendingPathComponent("media")

        // Create media directory if needed
        if !fileManager.fileExists(atPath: mediaDir.path) {
            try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        }

        for mediaRef in mediaRefs {
            guard let sourceURL = ModuleMediaStorage.shared.getMediaURL(
                for: mediaRef,
                moduleId: moduleId
            ) else {
                print("[NotesExport] Media file not found: \(mediaRef.filename)")
                continue
            }

            let destURL = mediaDir.appendingPathComponent(mediaRef.filename)

            // Skip if already exists (shared across notes)
            if fileManager.fileExists(atPath: destURL.path) {
                continue
            }

            try fileManager.copyItem(at: sourceURL, to: destURL)
            print("[NotesExport] Copied media: \(mediaRef.filename)")
        }
    }

    /// Generate markdown with proper media file references
    private func generateMarkdownWithMedia(_ notesBook: UserNotesBook, moduleId: String) -> String {
        // Build a map of mediaId -> filename for replacement
        var mediaFilenames: [String: String] = [:]
        if let media = notesBook.media {
            for mediaRef in media {
                mediaFilenames[mediaRef.id] = mediaRef.filename
            }
        }

        // Generate base markdown
        var markdown = generateMarkdown(from: notesBook)

        // Replace media ID references with actual filenames
        for (mediaId, filename) in mediaFilenames {
            markdown = markdown.replacingOccurrences(
                of: "media/\(mediaId)",
                with: "media/\(filename)"
            )
        }

        return markdown
    }

    /// Export notes for a single book with media support
    func exportNotesWithMedia(moduleId: String, bookNumber: Int) async throws -> URL {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let notesBook = try loadNotesForBook(moduleId: moduleId, bookNumber: bookNumber)

        // Export media files if present
        if let media = notesBook.media, !media.isEmpty {
            try exportMediaFiles(media, moduleId: moduleId, to: exportDir)
        }

        // Generate markdown with media references
        let markdown = generateMarkdownWithMedia(notesBook, moduleId: moduleId)
        let bookName = bookNames[bookNumber] ?? notesBook.book
        let fileName = "\(bookName).md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[NotesExport] Exported \(fileName)")

        return fileURL
    }

    /// Export all notes with media to the export directory
    func exportAllNotesWithMedia(moduleId: String = "notes") async throws -> [URL] {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        // Get all book numbers that have notes
        let bookNumbers = try ModuleDatabase.shared.getBookNumbersWithNotes(moduleId: moduleId)

        if bookNumbers.isEmpty {
            throw ExportError.noNotesFound
        }

        var exportedURLs: [URL] = []

        for bookNumber in bookNumbers.sorted() {
            do {
                let url = try await exportNotesWithMedia(moduleId: moduleId, bookNumber: bookNumber)
                exportedURLs.append(url)
            } catch {
                print("[NotesExport] Failed to export book \(bookNumber): \(error)")
            }
        }

        return exportedURLs
    }

    // MARK: - Media Import Helpers

    /// Import media files referenced in the note content
    private func importMediaReferences(
        for notesBook: UserNotesBook,
        from mediaDir: URL,
        moduleId: String
    ) async throws -> UserNotesBook {
        var updatedBook = notesBook

        // Check if media directory exists
        guard fileManager.fileExists(atPath: mediaDir.path) else {
            return notesBook
        }

        // Find media files in the media directory
        let mediaFiles = try? fileManager.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)
        guard let files = mediaFiles, !files.isEmpty else {
            return notesBook
        }

        var mediaRefs: [MediaReference] = []

        // Scan all chapter content for media references
        for chapter in notesBook.chapters {
            // Check introduction
            if let intro = chapter.introduction {
                let foundMedia = try await importMediaFromContent(
                    intro.plainText,
                    mediaFiles: files,
                    moduleId: moduleId
                )
                mediaRefs.append(contentsOf: foundMedia)
            }

            // Check verses
            if let verses = chapter.verses {
                for verse in verses {
                    let foundMedia = try await importMediaFromContent(
                        verse.commentary.plainText,
                        mediaFiles: files,
                        moduleId: moduleId
                    )
                    mediaRefs.append(contentsOf: foundMedia)
                }
            }
        }

        if !mediaRefs.isEmpty {
            updatedBook.media = mediaRefs
        }

        return updatedBook
    }

    /// Import media files found in content text
    private func importMediaFromContent(
        _ content: String,
        mediaFiles: [URL],
        moduleId: String
    ) async throws -> [MediaReference] {
        var mediaRefs: [MediaReference] = []

        // Pattern to find image references: ![caption](media/filename)
        let imagePattern = #"!\[([^\]]*)\]\(media/([^)]+)\)"#
        // Pattern to find audio references: [caption](media/filename.m4a|mp3|wav|etc)
        let audioPattern = #"\[([^\]]*)\]\(media/([^)]+\.(?:m4a|mp3|wav|aac|ogg))\)"#

        if let imageRegex = try? NSRegularExpression(pattern: imagePattern),
           let audioRegex = try? NSRegularExpression(pattern: audioPattern) {

            let range = NSRange(content.startIndex..., in: content)

            // Find images
            for match in imageRegex.matches(in: content, range: range) {
                if let filenameRange = Range(match.range(at: 2), in: content) {
                    let filename = String(content[filenameRange])
                    if let sourceURL = mediaFiles.first(where: { $0.lastPathComponent == filename }) {
                        let mediaRef = try await importMediaFile(from: sourceURL, moduleId: moduleId)
                        mediaRefs.append(mediaRef)
                    }
                }
            }

            // Find audio
            for match in audioRegex.matches(in: content, range: range) {
                if let filenameRange = Range(match.range(at: 2), in: content) {
                    let filename = String(content[filenameRange])
                    if let sourceURL = mediaFiles.first(where: { $0.lastPathComponent == filename }) {
                        let mediaRef = try await importMediaFile(from: sourceURL, moduleId: moduleId)
                        mediaRefs.append(mediaRef)
                    }
                }
            }
        }

        return mediaRefs
    }

    /// Import a media file and create a reference
    private func importMediaFile(
        from sourceURL: URL,
        moduleId: String
    ) async throws -> MediaReference {
        let ext = sourceURL.pathExtension.lowercased()

        // Determine type from extension
        let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext)
        let isAudio = ["m4a", "mp3", "wav", "aac", "ogg"].contains(ext)

        if isImage {
            // Load and save image
            guard let image = UIImage(contentsOfFile: sourceURL.path) else {
                throw ImportError.parseError("Failed to load image: \(sourceURL.lastPathComponent)")
            }
            return try ModuleMediaStorage.shared.saveImage(
                image,
                moduleId: moduleId
            )
        } else if isAudio {
            // Copy and process audio
            return try await ModuleMediaStorage.shared.saveAudio(
                from: sourceURL,
                moduleId: moduleId
            )
        } else {
            throw ImportError.parseError("Unsupported media type: \(ext)")
        }
    }

    /// Process imports with media support
    func processImportsWithMedia() async throws -> [ImportResult] {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            return []
        }
        print("[NotesImport] processImportsWithMedia() called")
        guard let importDir = importDirectoryURL else {
            print("[NotesImport] Import directory not available")
            return []
        }
        print("[NotesImport] Import directory: \(importDir.path)")

        // Create import directory if needed
        if !fileManager.fileExists(atPath: importDir.path) {
            try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
            print("[NotesImport] Created import directory")
            return []
        }

        // Find all .md files
        let contents = try fileManager.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil)
        let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }

        if mdFiles.isEmpty {
            return []
        }

        print("[NotesImport] Found \(mdFiles.count) markdown file(s) to import")

        // Check for media directory
        let mediaDir = importDir.appendingPathComponent("media")

        var results: [ImportResult] = []

        for fileURL in mdFiles {
            do {
                let result = try await importMarkdownFileWithMedia(at: fileURL, mediaDir: mediaDir)
                results.append(result)

                if result.success {
                    // Delete file after successful import
                    try fileManager.removeItem(at: fileURL)
                    print("[NotesImport] Deleted imported file: \(fileURL.lastPathComponent)")
                }
            } catch {
                results.append(ImportResult(
                    fileName: fileURL.lastPathComponent,
                    bookName: "",
                    bookNumber: 0,
                    chapterCount: 0,
                    verseCount: 0,
                    success: false,
                    error: error.localizedDescription
                ))
                print("[NotesImport] Error importing \(fileURL.lastPathComponent): \(error)")
            }
        }

        return results
    }

    /// Import a single markdown file with media support
    private func importMarkdownFileWithMedia(at url: URL, mediaDir: URL) async throws -> ImportResult {
        let content = try String(contentsOf: url, encoding: .utf8)
        var books = try parsedMarkdownBooks(
            content: content, filename: url.deletingPathExtension().lastPathComponent
        )
        for index in books.indices {
            books[index] = try await importMediaReferences(for: books[index], from: mediaDir, moduleId: "notes")
            try await saveNotesToDatabase(books[index])
        }
        return importResult(for: books, filename: url.lastPathComponent)
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unknownBook(String)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .unknownBook(let book):
                return "Unknown book: \(book)"
            case .parseError(let message):
                return "Parse error: \(message)"
            }
        }
    }

    enum ExportError: LocalizedError {
        case directoryNotAvailable
        case noNotesFound

        var errorDescription: String? {
            switch self {
            case .directoryNotAvailable:
                return "Export directory not available"
            case .noNotesFound:
                return "No notes found to export"
            }
        }
    }
}
