//
//  NotesImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-09.
//

import Foundation
import UIKit

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

    /// Book name/abbreviation to number mapping (lowercase keys)
    private let bookNumbers: [String: Int] = [
        "genesis": 1, "gen": 1, "exodus": 2, "exod": 2, "exo": 2,
        "leviticus": 3, "lev": 3, "numbers": 4, "num": 4,
        "deuteronomy": 5, "deut": 5, "deu": 5, "joshua": 6, "josh": 6, "jos": 6,
        "judges": 7, "judg": 7, "jdg": 7, "ruth": 8, "rut": 8,
        "1 samuel": 9, "1samuel": 9, "1sam": 9, "1sa": 9,
        "2 samuel": 10, "2samuel": 10, "2sam": 10, "2sa": 10,
        "1 kings": 11, "1kings": 11, "1kgs": 11, "1ki": 11,
        "2 kings": 12, "2kings": 12, "2kgs": 12, "2ki": 12,
        "1 chronicles": 13, "1chronicles": 13, "1chr": 13, "1ch": 13,
        "2 chronicles": 14, "2chronicles": 14, "2chr": 14, "2ch": 14,
        "ezra": 15, "ezr": 15, "nehemiah": 16, "neh": 16,
        "esther": 17, "esth": 17, "est": 17, "job": 18,
        "psalms": 19, "psalm": 19, "ps": 19, "psa": 19,
        "proverbs": 20, "prov": 20, "pro": 20,
        "ecclesiastes": 21, "eccl": 21, "ecc": 21,
        "song of solomon": 22, "song": 22, "sos": 22, "sng": 22,
        "isaiah": 23, "isa": 23, "jeremiah": 24, "jer": 24,
        "lamentations": 25, "lam": 25, "ezekiel": 26, "ezek": 26, "eze": 26,
        "daniel": 27, "dan": 27, "hosea": 28, "hos": 28, "joel": 29, "joe": 29,
        "amos": 30, "amo": 30, "obadiah": 31, "obad": 31, "oba": 31,
        "jonah": 32, "jon": 32, "micah": 33, "mic": 33, "nahum": 34, "nah": 34,
        "habakkuk": 35, "hab": 35, "zephaniah": 36, "zeph": 36, "zep": 36,
        "haggai": 37, "hag": 37, "zechariah": 38, "zech": 38, "zec": 38,
        "malachi": 39, "mal": 39,
        "matthew": 40, "matt": 40, "mat": 40, "mt": 40,
        "mark": 41, "mrk": 41, "mk": 41, "mar": 41,
        "luke": 42, "luk": 42, "lk": 42, "john": 43, "joh": 43, "jhn": 43, "jn": 43,
        "acts": 44, "act": 44, "romans": 45, "rom": 45,
        "1 corinthians": 46, "1corinthians": 46, "1cor": 46, "1co": 46,
        "2 corinthians": 47, "2corinthians": 47, "2cor": 47, "2co": 47,
        "galatians": 48, "gal": 48, "ephesians": 49, "eph": 49,
        "philippians": 50, "phil": 50, "php": 50, "colossians": 51, "col": 51,
        "1 thessalonians": 52, "1thessalonians": 52, "1thess": 52, "1th": 52,
        "2 thessalonians": 53, "2thessalonians": 53, "2thess": 53, "2th": 53,
        "1 timothy": 54, "1timothy": 54, "1tim": 54, "1ti": 54,
        "2 timothy": 55, "2timothy": 55, "2tim": 55, "2ti": 55,
        "titus": 56, "tit": 56, "philemon": 57, "phlm": 57, "phm": 57,
        "hebrews": 58, "heb": 58, "james": 59, "jas": 59, "jam": 59,
        "1 peter": 60, "1peter": 60, "1pet": 60, "1pe": 60,
        "2 peter": 61, "2peter": 61, "2pet": 61, "2pe": 61,
        "1 john": 62, "1john": 62, "1jn": 62, "1jo": 62,
        "2 john": 63, "2john": 63, "2jn": 63, "2jo": 63,
        "3 john": 64, "3john": 64, "3jn": 64, "3jo": 64,
        "jude": 65, "jud": 65, "revelation": 66, "rev": 66, "revelations": 66
    ]

    /// Book number to full name
    private let bookNames: [Int: String] = [
        1: "Genesis", 2: "Exodus", 3: "Leviticus", 4: "Numbers", 5: "Deuteronomy",
        6: "Joshua", 7: "Judges", 8: "Ruth", 9: "1 Samuel", 10: "2 Samuel",
        11: "1 Kings", 12: "2 Kings", 13: "1 Chronicles", 14: "2 Chronicles",
        15: "Ezra", 16: "Nehemiah", 17: "Esther", 18: "Job", 19: "Psalms",
        20: "Proverbs", 21: "Ecclesiastes", 22: "Song of Solomon", 23: "Isaiah",
        24: "Jeremiah", 25: "Lamentations", 26: "Ezekiel", 27: "Daniel",
        28: "Hosea", 29: "Joel", 30: "Amos", 31: "Obadiah", 32: "Jonah",
        33: "Micah", 34: "Nahum", 35: "Habakkuk", 36: "Zephaniah", 37: "Haggai",
        38: "Zechariah", 39: "Malachi",
        40: "Matthew", 41: "Mark", 42: "Luke", 43: "John", 44: "Acts",
        45: "Romans", 46: "1 Corinthians", 47: "2 Corinthians", 48: "Galatians",
        49: "Ephesians", 50: "Philippians", 51: "Colossians",
        52: "1 Thessalonians", 53: "2 Thessalonians", 54: "1 Timothy",
        55: "2 Timothy", 56: "Titus", 57: "Philemon", 58: "Hebrews",
        59: "James", 60: "1 Peter", 61: "2 Peter", 62: "1 John", 63: "2 John",
        64: "3 John", 65: "Jude", 66: "Revelation"
    ]

    /// Book number to abbreviation (for export filenames)
    private let bookAbbrevs: [Int: String] = [
        1: "Gen", 2: "Exod", 3: "Lev", 4: "Num", 5: "Deut", 6: "Josh", 7: "Judg",
        8: "Ruth", 9: "1Sam", 10: "2Sam", 11: "1Kgs", 12: "2Kgs", 13: "1Chr",
        14: "2Chr", 15: "Ezra", 16: "Neh", 17: "Esth", 18: "Job", 19: "Ps",
        20: "Prov", 21: "Eccl", 22: "Song", 23: "Isa", 24: "Jer", 25: "Lam",
        26: "Ezek", 27: "Dan", 28: "Hos", 29: "Joel", 30: "Amos", 31: "Obad",
        32: "Jonah", 33: "Mic", 34: "Nah", 35: "Hab", 36: "Zeph", 37: "Hag",
        38: "Zech", 39: "Mal", 40: "Matt", 41: "Mark", 42: "Luke", 43: "John",
        44: "Acts", 45: "Rom", 46: "1Cor", 47: "2Cor", 48: "Gal", 49: "Eph",
        50: "Phil", 51: "Col", 52: "1Thess", 53: "2Thess", 54: "1Tim", 55: "2Tim",
        56: "Titus", 57: "Phlm", 58: "Heb", 59: "Jas", 60: "1Pet", 61: "2Pet",
        62: "1John", 63: "2John", 64: "3John", 65: "Jude", 66: "Rev"
    ]

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

        // Check if this is a multi-book file (has ## Book Name headers)
        if isMultiBookFile(content) {
            // Parse as multi-book file
            let books = try parseMultiBookMarkdown(content: content)

            var totalChapters = 0
            var totalVerses = 0
            var bookNames: [String] = []

            for notesBook in books {
                try await saveNotesToDatabase(notesBook)
                totalChapters += notesBook.chapters.count
                totalVerses += notesBook.chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }
                bookNames.append(notesBook.book)
            }

            return ImportResult(
                fileName: url.lastPathComponent,
                bookName: "\(books.count) books",
                bookNumber: 0,
                chapterCount: totalChapters,
                verseCount: totalVerses,
                success: true,
                error: nil
            )
        } else {
            // Parse as single-book file
            let notesBook = try parseMarkdownToNotes(content: content, filename: url.lastPathComponent)

            // Save to database
            try await saveNotesToDatabase(notesBook)

            // Count for result
            let verseCount = notesBook.chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }

            return ImportResult(
                fileName: url.lastPathComponent,
                bookName: notesBook.book,
                bookNumber: notesBook.bookNumber,
                chapterCount: notesBook.chapters.count,
                verseCount: verseCount,
                success: true,
                error: nil
            )
        }
    }

    /// Check if content contains multiple books (## Book Name headers after # Title)
    private func isMultiBookFile(_ content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        var foundTitle = false
        var bookHeaderCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip frontmatter
            if trimmed == "---" { continue }

            // Found main title
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                foundTitle = true
                continue
            }

            // Count ## headers that look like book names (not "## Chapter N")
            if foundTitle && trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") {
                let headerText = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !headerText.lowercased().hasPrefix("chapter") {
                    // Check if it's a known book name
                    if bookNumbers[headerText.lowercased()] != nil ||
                       bookNumbers[headerText.lowercased().replacingOccurrences(of: " ", with: "")] != nil {
                        bookHeaderCount += 1
                    }
                }
            }
        }

        return bookHeaderCount >= 1
    }

    /// Parse a multi-book markdown file into multiple UserNotesBook objects
    private func parseMultiBookMarkdown(content: String) throws -> [UserNotesBook] {
        // First extract footnote definitions from end of document
        let (bodyWithoutFootnotes, allFootnoteDefinitions) = extractAllFootnoteDefinitions(from: content)

        // Parse frontmatter for shared metadata
        let (metadata, body) = parseFrontmatter(content: bodyWithoutFootnotes)

        var books: [UserNotesBook] = []
        var currentBookName: String? = nil
        var currentBookNumber: Int? = nil
        var currentBookContent: [String] = []

        let lines = body.components(separatedBy: "\n")

        func flushBook() throws {
            guard let bookName = currentBookName,
                  let bookNumber = currentBookNumber,
                  !currentBookContent.isEmpty else {
                return
            }

            let bookBody = currentBookContent.joined(separator: "\n")
            let chapters = parseChaptersWithFootnotes(body: bookBody, bookNumber: bookNumber, footnoteDefinitions: allFootnoteDefinitions)

            guard !chapters.isEmpty else {
                return
            }

            let meta = UserNotesMeta(
                id: metadata["id"] ?? "notes",
                name: metadata["name"],
                author: metadata["author"]
            )

            let notesBook = UserNotesBook(
                meta: meta,
                book: bookName,
                bookNumber: bookNumber,
                chapters: chapters
            )
            books.append(notesBook)
            currentBookContent = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip main title (# My Notes)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                continue
            }

            // Check for book header (## Genesis, ## Matthew, etc.)
            if trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") {
                let headerText = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)

                // Check if it's a book name (not "Chapter N")
                if !headerText.lowercased().hasPrefix("chapter") {
                    let lookupName = headerText.lowercased().replacingOccurrences(of: " ", with: "")
                    if let bookNum = bookNumbers[headerText.lowercased()] ?? bookNumbers[lookupName] {
                        // Flush previous book
                        try flushBook()

                        // Start new book
                        currentBookName = headerText
                        currentBookNumber = bookNum
                        continue
                    }
                }
            }

            // Accumulate content for current book
            if currentBookNumber != nil {
                currentBookContent.append(line)
            }
        }

        // Flush last book
        try flushBook()

        return books
    }

    /// Parse chapters with pre-extracted footnote definitions (for multi-book parsing)
    private func parseChaptersWithFootnotes(body: String, bookNumber: Int, footnoteDefinitions: [String: String]) -> [UserNotesChapter] {
        var chapters: [UserNotesChapter] = []
        var currentChapter: Int? = nil
        var currentChapterData: (intro: String?, verses: [UserNotesVerse], footnotes: [UserNotesFootnote])? = nil
        var currentSection: String? = nil
        var currentVerseData: (sv: Int, ev: Int?, content: [String])? = nil
        var sectionContent: [String] = []

        let lines = body.components(separatedBy: "\n")

        // Match exporter format: ### Chapter N
        let chapterRegex = try! NSRegularExpression(pattern: #"^###\s+Chapter\s+(\d+)\s*$"#, options: .caseInsensitive)
        // Match exporter format: #### Introduction
        let introRegex = try! NSRegularExpression(pattern: #"^####\s+Introduction\s*$"#, options: .caseInsensitive)
        // Match exporter format: #### 1:1 or #### 1:1-5 (chapter:verse format)
        let verseRegex = try! NSRegularExpression(pattern: #"^####\s+(\d+:\d+(?:-\d+)?)\s*$"#)

        func flushSection() {
            guard !sectionContent.isEmpty else { return }
            let rawContent = sectionContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawContent.isEmpty else {
                sectionContent = []
                return
            }

            let (remainingContent, inlineFootnotes) = parseFootnoteCallouts(content: rawContent)

            let markerPattern = #"\[\^([^\]]+)\]"#
            guard let markerRegex = try? NSRegularExpression(pattern: markerPattern) else {
                sectionContent = []
                return
            }

            let text = remainingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = markerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))

            var footnotes: [UserNotesFootnote] = []
            var cleanText = ""
            var lastEnd = text.startIndex
            var footnoteCounter = 1

            for match in matches {
                guard let matchRange = Range(match.range, in: text),
                      let idRange = Range(match.range(at: 1), in: text) else {
                    continue
                }

                cleanText += text[lastEnd..<matchRange.lowerBound]

                let originalId = String(text[idRange])
                print("[Import] Looking up footnote '\(originalId)' in definitions (count=\(footnoteDefinitions.count))")

                var footnoteContent: String? = nil
                if let content = footnoteDefinitions[originalId] {
                    print("[Import]   Found in definitions: \(content.prefix(30))")
                    footnoteContent = content
                } else if let inlineFn = inlineFootnotes.first(where: { $0.id == originalId }) {
                    print("[Import]   Found in inline footnotes")
                    footnoteContent = inlineFn.content.plainText
                } else {
                    print("[Import]   NOT FOUND. Available keys: \(Array(footnoteDefinitions.keys).prefix(5))")
                }

                if let content = footnoteContent {
                    cleanText += "[^\(footnoteCounter)]"
                    footnotes.append(UserNotesFootnote(id: String(footnoteCounter), content: .text(content)))
                    footnoteCounter += 1
                } else {
                    // Footnote not found - preserve original marker
                    cleanText += "[^\(originalId)]"
                }

                lastEnd = matchRange.upperBound
            }

            cleanText += text[lastEnd...]

            if footnotes.isEmpty && !inlineFootnotes.isEmpty {
                footnotes = inlineFootnotes
            }

            let contentWithMarkers = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

            print("[Import] flushSection: section=\(currentSection ?? "nil"), footnotes=\(footnotes.count), content=\(contentWithMarkers.prefix(30))")

            if currentSection == "introduction", currentChapterData != nil {
                currentChapterData?.intro = contentWithMarkers
                if !footnotes.isEmpty {
                    currentChapterData?.footnotes.append(contentsOf: footnotes)
                }
            } else if currentSection == "verse", let verseData = currentVerseData, currentChapterData != nil {
                print("[Import] Creating verse \(verseData.sv) with \(footnotes.count) footnotes")
                let verse = UserNotesVerse(
                    sv: verseData.sv,
                    ev: verseData.ev,
                    commentary: .text(contentWithMarkers),
                    footnotes: footnotes.isEmpty ? nil : footnotes,
                    lastModified: Int(Date().timeIntervalSince1970)
                )
                currentChapterData?.verses.append(verse)
                currentVerseData = nil
            }

            sectionContent = []
        }

        func flushChapter() {
            flushSection()
            if let chapter = currentChapter, let data = currentChapterData {
                let chapterNotes = UserNotesChapter(
                    chapter: chapter,
                    introduction: data.intro.map { .text($0) },
                    verses: data.verses.isEmpty ? nil : data.verses,
                    footnotes: data.footnotes.isEmpty ? nil : data.footnotes
                )
                chapters.append(chapterNotes)
            }
            currentChapterData = nil
        }

        for line in lines {
            // Trim carriage returns that might come from Windows line endings
            let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let cleanLineRange = NSRange(cleanLine.startIndex..., in: cleanLine)

            if let match = chapterRegex.firstMatch(in: cleanLine, range: cleanLineRange),
               let chapterRange = Range(match.range(at: 1), in: cleanLine),
               let chapterNum = Int(cleanLine[chapterRange]) {
                flushChapter()
                currentChapter = chapterNum
                currentChapterData = (nil, [], [])
                currentSection = nil
                continue
            }

            if introRegex.firstMatch(in: cleanLine, range: cleanLineRange) != nil {
                flushSection()
                currentSection = "introduction"
                continue
            }

            if let match = verseRegex.firstMatch(in: cleanLine, range: cleanLineRange),
               let verseRefRange = Range(match.range(at: 1), in: cleanLine),
               let chapter = currentChapter {
                flushSection()
                let verseRef = String(cleanLine[verseRefRange])
                let (sv, ev) = parseVerseRef(ref: verseRef, bookNumber: bookNumber, defaultChapter: chapter)
                currentVerseData = (sv, ev, [])
                currentSection = "verse"
                continue
            }

            if cleanLine.hasPrefix("# ") { continue }

            sectionContent.append(line)
        }

        flushChapter()
        return chapters
    }

    // MARK: - Markdown Parsing

    /// Parse markdown content into UserNotesBook structure
    func parseMarkdownToNotes(content: String, filename: String) throws -> UserNotesBook {
        // Parse frontmatter
        let (metadata, body) = parseFrontmatter(content: content)

        // Get book info
        let book = metadata["book"] ?? String(filename.dropLast(3))  // Remove .md
        var bookNumber = 0
        if let numStr = metadata["bookNumber"], let num = Int(numStr) {
            bookNumber = num
        } else {
            // Try to determine from book name
            let bookLower = book.lowercased().replacingOccurrences(of: " ", with: "")
            bookNumber = bookNumbers[bookLower] ?? 0
        }

        guard bookNumber > 0 else {
            throw ImportError.unknownBook(book)
        }

        // Build metadata
        let meta = UserNotesMeta(
            id: metadata["id"] ?? "notes",
            name: metadata["name"],
            author: metadata["author"]
        )

        // Parse chapters
        let chapters = parseChapters(body: body, bookNumber: bookNumber)

        return UserNotesBook(
            meta: meta,
            book: book,
            bookNumber: bookNumber,
            chapters: chapters
        )
    }

    /// Parse YAML frontmatter from markdown
    private func parseFrontmatter(content: String) -> (metadata: [String: String], body: String) {
        guard content.hasPrefix("---") else {
            return ([:], content)
        }

        // Find closing ---
        let lines = content.components(separatedBy: "\n")
        var endIndex = -1
        for (i, line) in lines.enumerated() where i > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = i
                break
            }
        }

        guard endIndex > 0 else {
            return ([:], content)
        }

        // Parse YAML (simple key: value format)
        var metadata: [String: String] = [:]
        for i in 1..<endIndex {
            let line = lines[i]
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                // Remove quotes if present
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                metadata[key] = value
            }
        }

        // Body is everything after the closing ---
        let bodyLines = Array(lines[(endIndex + 1)...])
        let body = bodyLines.joined(separator: "\n")

        return (metadata, body)
    }

    /// Extract all footnote definitions from the end of the document (after ---)
    /// Returns the body without the footnotes section and a dictionary of complex ID to content
    private func extractAllFootnoteDefinitions(from body: String) -> (bodyWithoutFootnotes: String, definitions: [String: String]) {
        var definitions: [String: String] = [:]

        // Find the last --- separator
        let lines = body.components(separatedBy: "\n")
        var separatorIndex: Int? = nil

        for (i, line) in lines.enumerated().reversed() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                separatorIndex = i
                break
            }
        }

        guard let sepIdx = separatorIndex else {
            // No separator found, return body as-is
            return (body, [:])
        }

        // Everything before separator is the body
        let bodyLines = Array(lines[0..<sepIdx])
        let footnoteLines = Array(lines[(sepIdx + 1)...])

        // Check if the lines after the separator look like footnotes
        let looksLikeFootnotes = footnoteLines.contains { $0.contains("[^") && $0.contains("]:") }

        // If the separator doesn't seem to be for footnotes, return body as-is
        if !looksLikeFootnotes && footnoteLines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || !$0.contains("[^") }) {
            return (body, [:])
        }

        // Parse footnote definitions from the end section
        let footnotePattern = #"^\[\^([^\]]+)\]:\s*(.*)$"#
        guard let footnoteRegex = try? NSRegularExpression(pattern: footnotePattern) else {
            return (bodyLines.joined(separator: "\n"), [:])
        }

        var i = 0
        while i < footnoteLines.count {
            let line = footnoteLines[i]
            let lineRange = NSRange(line.startIndex..., in: line)

            if let match = footnoteRegex.firstMatch(in: line, range: lineRange),
               let idRange = Range(match.range(at: 1), in: line),
               let contentRange = Range(match.range(at: 2), in: line) {
                let fnId = String(line[idRange])
                var fnLines = [String(line[contentRange])]

                // Collect continuation lines (4 spaces or tab indented)
                i += 1
                while i < footnoteLines.count {
                    let nextLine = footnoteLines[i]
                    if nextLine.hasPrefix("    ") {
                        fnLines.append(String(nextLine.dropFirst(4)))
                        i += 1
                    } else if nextLine.hasPrefix("\t") {
                        fnLines.append(String(nextLine.dropFirst(1)))
                        i += 1
                    } else if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                    } else {
                        break
                    }
                }

                let fnContent = fnLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                definitions[fnId] = fnContent
            } else {
                i += 1
            }
        }

        return (bodyLines.joined(separator: "\n"), definitions)
    }

    /// Parse chapter content from markdown body
    private func parseChapters(body: String, bookNumber: Int) -> [UserNotesChapter] {
        // First pass: extract all footnote definitions from the end of the document
        let (bodyWithoutFootnotes, allFootnoteDefinitions) = extractAllFootnoteDefinitions(from: body)

        var chapters: [UserNotesChapter] = []
        var currentChapter: Int? = nil
        var currentChapterData: (intro: String?, verses: [UserNotesVerse], footnotes: [UserNotesFootnote])? = nil
        var currentSection: String? = nil  // "introduction" or "verse"
        var currentVerseData: (sv: Int, ev: Int?, content: [String])? = nil
        var sectionContent: [String] = []

        let lines = bodyWithoutFootnotes.components(separatedBy: "\n")

        // Chapter regex: ## Chapter N
        let chapterRegex = try! NSRegularExpression(pattern: #"^##\s+Chapter\s+(\d+)\s*$"#, options: .caseInsensitive)
        // Introduction regex: ### Introduction
        let introRegex = try! NSRegularExpression(pattern: #"^###\s+Introduction\s*$"#, options: .caseInsensitive)
        // Verse regex: ### 1:1 or ### 1:2-5
        let verseRegex = try! NSRegularExpression(pattern: #"^###\s+(\d+:\d+(?:-\d+(?::\d+)?)?)\s*$"#)

        func flushSection() {
            guard !sectionContent.isEmpty else { return }
            let rawContent = sectionContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawContent.isEmpty else {
                sectionContent = []
                return
            }

            // Extract any inline footnotes (legacy format with definitions inline)
            let (remainingContent, inlineFootnotes) = parseFootnoteCallouts(content: rawContent)

            // Find all footnote markers in the text (e.g., [^1] or [^Gen-1:5-1])
            let markerPattern = #"\[\^([^\]]+)\]"#
            guard let markerRegex = try? NSRegularExpression(pattern: markerPattern) else {
                sectionContent = []
                return
            }

            let text = remainingContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = markerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))

            // Build list of footnotes by looking up definitions
            var footnotes: [UserNotesFootnote] = []
            var cleanText = ""
            var lastEnd = text.startIndex
            var footnoteCounter = 1

            for match in matches {
                guard let matchRange = Range(match.range, in: text),
                      let idRange = Range(match.range(at: 1), in: text) else {
                    continue
                }

                // Add text before marker
                cleanText += text[lastEnd..<matchRange.lowerBound]

                let originalId = String(text[idRange])

                // Look up footnote content - first in allFootnoteDefinitions, then inline
                var footnoteContent: String? = nil
                if let content = allFootnoteDefinitions[originalId] {
                    footnoteContent = content
                } else if let inlineFn = inlineFootnotes.first(where: { $0.id == originalId }) {
                    footnoteContent = inlineFn.content.plainText
                }

                if let content = footnoteContent {
                    // Add marker with sequential ID
                    cleanText += "[^\(footnoteCounter)]"
                    footnotes.append(UserNotesFootnote(id: String(footnoteCounter), content: .text(content)))
                    footnoteCounter += 1
                } else {
                    // Footnote not found - preserve original marker
                    cleanText += "[^\(originalId)]"
                }

                lastEnd = matchRange.upperBound
            }

            // Add remaining text
            cleanText += text[lastEnd...]

            // If no markers but inline footnotes exist, add them
            if footnotes.isEmpty && !inlineFootnotes.isEmpty {
                footnotes = inlineFootnotes
            }

            let contentWithMarkers = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

            if currentSection == "introduction", currentChapterData != nil {
                currentChapterData?.intro = contentWithMarkers
                if !footnotes.isEmpty {
                    currentChapterData?.footnotes.append(contentsOf: footnotes)
                }
            } else if currentSection == "verse", let verseData = currentVerseData, currentChapterData != nil {
                let verse = UserNotesVerse(
                    sv: verseData.sv,
                    ev: verseData.ev,
                    commentary: .text(contentWithMarkers),
                    footnotes: footnotes.isEmpty ? nil : footnotes,
                    lastModified: Int(Date().timeIntervalSince1970)
                )
                currentChapterData?.verses.append(verse)
                currentVerseData = nil
            }

            sectionContent = []
        }

        func flushVerse() {
            flushSection()
        }

        func flushChapter() {
            flushVerse()

            if let chapter = currentChapter, let data = currentChapterData {
                let chapterNotes = UserNotesChapter(
                    chapter: chapter,
                    introduction: data.intro.map { .text($0) },
                    verses: data.verses.isEmpty ? nil : data.verses,
                    footnotes: data.footnotes.isEmpty ? nil : data.footnotes
                )
                chapters.append(chapterNotes)
            }
            currentChapterData = nil
        }

        for line in lines {
            let lineRange = NSRange(line.startIndex..., in: line)

            // Check for ## Chapter N
            if let match = chapterRegex.firstMatch(in: line, range: lineRange),
               let chapterRange = Range(match.range(at: 1), in: line),
               let chapterNum = Int(line[chapterRange]) {
                flushChapter()
                currentChapter = chapterNum
                currentChapterData = (nil, [], [])
                currentSection = nil
                continue
            }

            // Check for ### Introduction
            if introRegex.firstMatch(in: line, range: lineRange) != nil {
                flushVerse()
                currentSection = "introduction"
                continue
            }

            // Check for ### 1:1 or ### 1:2-5
            if let match = verseRegex.firstMatch(in: line, range: lineRange),
               let verseRefRange = Range(match.range(at: 1), in: line),
               let chapter = currentChapter {
                flushVerse()
                let verseRef = String(line[verseRefRange])
                let (sv, ev) = parseVerseRef(ref: verseRef, bookNumber: bookNumber, defaultChapter: chapter)
                currentVerseData = (sv, ev, [])
                currentSection = "verse"
                continue
            }

            // Skip book title heading (# Book Name)
            if line.hasPrefix("# ") {
                continue
            }

            // Accumulate content
            sectionContent.append(line)
        }

        // Flush final content
        flushChapter()

        return chapters
    }

    /// Parse verse reference like "1:1" or "1:2-5" or "1:1-2:3"
    private func parseVerseRef(ref: String, bookNumber: Int, defaultChapter: Int) -> (sv: Int, ev: Int?) {
        // Pattern: chapter:verse or chapter:verse-verse or chapter:verse-chapter:verse
        let pattern = #"(\d+):(\d+)(?:-(\d+)(?::(\d+))?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: ref, range: NSRange(ref.startIndex..., in: ref)) else {
            return (0, nil)
        }

        func intAt(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: ref) else { return nil }
            return Int(ref[range])
        }

        guard let chapter = intAt(1), let startVerse = intAt(2) else {
            return (0, nil)
        }

        let sv = bookNumber * 1_000_000 + chapter * 1000 + startVerse

        if let endNum = intAt(3) {
            if let endVerse = intAt(4) {
                // Cross-chapter: 1:1-2:3
                let ev = bookNumber * 1_000_000 + endNum * 1000 + endVerse
                return (sv, ev)
            } else {
                // Same chapter: 1:2-5
                let ev = bookNumber * 1_000_000 + chapter * 1000 + endNum
                return (sv, ev)
            }
        }

        return (sv, nil)
    }

    /// Extract footnote markers from text - handles both simple [^1] and complex [^Gen-1:5-1] formats
    /// Returns clean text with markers removed and renumbered refs starting from 1
    private func extractFootnoteMarkers(text: String) -> (cleanText: String, refs: [FootnoteRef]) {
        var refs: [FootnoteRef] = []
        var cleanText = ""
        var pos = text.startIndex

        // Match both simple [^1] and complex [^Gen-1:5-1] or [^1:5-1] formats
        let pattern = #"\[\^([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var footnoteCounter = 1
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let idRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            // Add text before this marker
            cleanText += text[pos..<matchRange.lowerBound]

            // Use sequential numbering for internal storage (1, 2, 3...)
            // The original complex ID is preserved in footnote definitions
            refs.append(FootnoteRef(id: String(footnoteCounter), offset: cleanText.count))
            footnoteCounter += 1

            pos = matchRange.upperBound
        }

        // Add remaining text
        cleanText += text[pos...]

        return (cleanText, refs)
    }

    /// Extract the simple footnote number from a complex ID like "Gen-1:5-1" or "1:5-1"
    /// Returns the last component after the final hyphen (the actual footnote number)
    private func extractSimpleFootnoteId(from complexId: String) -> String {
        // Complex IDs are like "Gen-1:5-1" or "1:5-1", we want the last "-N" part
        if let lastHyphenIndex = complexId.lastIndex(of: "-") {
            let afterHyphen = complexId[complexId.index(after: lastHyphenIndex)...]
            if Int(afterHyphen) != nil {
                return String(afterHyphen)
            }
        }
        // If no hyphen or not a number after hyphen, return as-is
        return complexId
    }

    /// Extract footnotes from content - supports both formats:
    /// - Standard markdown: [^1]: content or [^Gen-1:5-1]: content
    /// - Callout format: > [!footnote] 1
    /// Renumbers footnotes sequentially (1, 2, 3...) for internal storage
    private func parseFootnoteCallouts(content: String) -> (remaining: String, footnotes: [UserNotesFootnote]) {
        var footnotes: [UserNotesFootnote] = []
        var remainingLines: [String] = []
        let lines = content.components(separatedBy: "\n")

        // Pattern for callout format: > [!footnote] N
        let calloutPattern = #"^>\s*\[!footnote\]\s*(\S+)\s*"#
        // Pattern for standard markdown footnote: [^ID]: content (ID can be complex like Gen-1:5-1)
        let standardPattern = #"^\[\^([^\]]+)\]:\s*(.*)$"#

        guard let calloutRegex = try? NSRegularExpression(pattern: calloutPattern),
              let standardRegex = try? NSRegularExpression(pattern: standardPattern) else {
            return (content, [])
        }

        var footnoteCounter = 1
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let lineRange = NSRange(line.startIndex..., in: line)

            // Try callout format first: > [!footnote] N
            if let match = calloutRegex.firstMatch(in: line, range: lineRange),
               let idRange = Range(match.range(at: 1), in: line) {
                var fnLines: [String] = []

                // Collect continuation lines (lines starting with >)
                i += 1
                while i < lines.count && lines[i].hasPrefix(">") {
                    var fnLine = lines[i]
                    // Remove > prefix
                    if fnLine.hasPrefix("> ") {
                        fnLine = String(fnLine.dropFirst(2))
                    } else if fnLine.hasPrefix(">") {
                        fnLine = String(fnLine.dropFirst(1))
                    }
                    fnLines.append(fnLine)
                    i += 1
                }

                let fnContent = fnLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                // Use sequential numbering for internal storage
                footnotes.append(UserNotesFootnote(id: String(footnoteCounter), content: .text(fnContent)))
                footnoteCounter += 1
            }
            // Try standard markdown format: [^ID]: content
            else if let match = standardRegex.firstMatch(in: line, range: lineRange),
                    let idRange = Range(match.range(at: 1), in: line),
                    let contentRange = Range(match.range(at: 2), in: line) {
                var fnLines = [String(line[contentRange])]

                // Collect continuation lines (lines starting with 4 spaces or tab)
                i += 1
                while i < lines.count {
                    let nextLine = lines[i]
                    if nextLine.hasPrefix("    ") {
                        fnLines.append(String(nextLine.dropFirst(4)))
                        i += 1
                    } else if nextLine.hasPrefix("\t") {
                        fnLines.append(String(nextLine.dropFirst(1)))
                        i += 1
                    } else if nextLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        // Empty line might be part of multi-line footnote, check next
                        i += 1
                    } else {
                        break
                    }
                }

                let fnContent = fnLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                // Use sequential numbering for internal storage
                footnotes.append(UserNotesFootnote(id: String(footnoteCounter), content: .text(fnContent)))
                footnoteCounter += 1
            } else {
                remainingLines.append(line)
                i += 1
            }
        }

        return (remainingLines.joined(separator: "\n"), footnotes)
    }

    /// Build AnnotatedTextField from text and footnote refs
    private func buildAnnotatedField(text: String, footnoteRefs: [FootnoteRef]) -> AnnotatedTextField {
        if footnoteRefs.isEmpty {
            return .text(text)
        }
        return .annotated(AnnotatedText(text: text, annotations: nil, footnoteRefs: footnoteRefs))
    }

    // MARK: - Export

    /// Export a single book's notes to markdown
    func exportToMarkdown(notesBook: UserNotesBook) async throws -> URL {
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
        var text = content.plainText

        guard let footnotes = footnotes, !footnotes.isEmpty else {
            return text
        }

        // Replace each [^N] with [^prefix-N] and collect definitions
        for fn in footnotes {
            let localMarker = "[^\(fn.id)]"
            let uniqueId = "\(prefix)-\(fn.id)"
            let uniqueMarker = "[^\(uniqueId)]"

            text = text.replacingOccurrences(of: localMarker, with: uniqueMarker)
            allFootnotes.append((uniqueId: uniqueId, content: fn.content.plainText))
        }

        return text
    }

    /// Convert BBCCCVVV verse reference to string like "1:1" or "1:2-5"
    private func verseRefToString(sv: Int, ev: Int?) -> String {
        let chapter = (sv / 1000) % 1000
        let startVerse = sv % 1000

        guard let ev = ev, ev != sv else {
            return "\(chapter):\(startVerse)"
        }

        let endVerse = ev % 1000
        let endChapter = (ev / 1000) % 1000

        if endChapter != chapter {
            // Cross-chapter range
            return "\(chapter):\(startVerse)-\(endChapter):\(endVerse)"
        } else {
            return "\(chapter):\(startVerse)-\(endVerse)"
        }
    }

    // MARK: - Public Import from String

    /// Import notes from markdown string (used by MarkdownConverter and other importers)
    /// Returns count of imported entries
    func importNotesFromMarkdownString(_ content: String, moduleId: String) async throws -> Int {
        var totalVerses = 0

        if isMultiBookFile(content) {
            let books = try parseMultiBookMarkdown(content: content)
            for notesBook in books {
                try await saveNotesToDatabase(notesBook, moduleId: moduleId)
                totalVerses += notesBook.chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }
                // Count intros too
                totalVerses += notesBook.chapters.filter { $0.introduction != nil }.count
            }
        } else {
            let notesBook = try parseMarkdownToNotes(content: content, filename: "import.md")
            try await saveNotesToDatabase(notesBook, moduleId: moduleId)
            totalVerses = notesBook.chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }
            totalVerses += notesBook.chapters.filter { $0.introduction != nil }.count
        }

        return totalVerses
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
        var text = content.plainText

        guard let footnotes = footnotes, !footnotes.isEmpty else {
            return text
        }

        for fn in footnotes {
            let localMarker = "[^\(fn.id)]"
            let uniqueId = "\(bookAbbrev)-\(chapter):\(verse)-\(fn.id)"
            let uniqueMarker = "[^\(uniqueId)]"

            text = text.replacingOccurrences(of: localMarker, with: uniqueMarker)
            allFootnotes.append((uniqueId: uniqueId, content: fn.content.plainText))
        }

        return text
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
        let moduleId = "notes"

        // Check if this is a multi-book file
        if isMultiBookFile(content) {
            var books = try parseMultiBookMarkdown(content: content)

            var totalChapters = 0
            var totalVerses = 0

            for i in 0..<books.count {
                // Import media references for each book
                books[i] = try await importMediaReferences(
                    for: books[i],
                    from: mediaDir,
                    moduleId: moduleId
                )
                try await saveNotesToDatabase(books[i])
                totalChapters += books[i].chapters.count
                totalVerses += books[i].chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }
            }

            return ImportResult(
                fileName: url.lastPathComponent,
                bookName: "\(books.count) books",
                bookNumber: 0,
                chapterCount: totalChapters,
                verseCount: totalVerses,
                success: true,
                error: nil
            )
        } else {
            var notesBook = try parseMarkdownToNotes(content: content, filename: url.lastPathComponent)

            // Import media references
            notesBook = try await importMediaReferences(
                for: notesBook,
                from: mediaDir,
                moduleId: moduleId
            )

            // Save to database
            try await saveNotesToDatabase(notesBook)

            let verseCount = notesBook.chapters.reduce(0) { $0 + ($1.verses?.count ?? 0) }

            return ImportResult(
                fileName: url.lastPathComponent,
                bookName: notesBook.book,
                bookNumber: notesBook.bookNumber,
                chapterCount: notesBook.chapters.count,
                verseCount: verseCount,
                success: true,
                error: nil
            )
        }
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
