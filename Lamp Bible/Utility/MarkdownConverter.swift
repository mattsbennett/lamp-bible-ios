//
//  MarkdownConverter.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB

/// Converts between module entries and markdown format for import/export
struct MarkdownConverter {

    // MARK: - Notes Export

    /// Export all notes from a module to a single markdown string
    static func exportNotesToMarkdown(moduleId: String) throws -> String {
        let database = ModuleDatabase.shared
        let entries = try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId)
                .order(Column("book"), Column("chapter"), Column("verse"))
                .fetchAll(db)
        }

        guard let module = try database.getModule(id: moduleId) else {
            throw MarkdownError.moduleNotFound
        }

        var markdown = "# \(module.name)\n\n"

        if let description = module.description, !description.isEmpty {
            markdown += "> \(description)\n\n"
        }

        markdown += "---\n\n"

        // Collect all footnotes with unique IDs
        var allFootnotes: [(uniqueId: String, content: String)] = []

        // Group entries by book and chapter
        var currentBook: Int = 0
        var currentChapter: Int = 0

        for entry in entries {
            // Book header
            if entry.book != currentBook {
                currentBook = entry.book
                currentChapter = 0
                if let bookName = lookupBookName(entry.book) {
                    markdown += "## \(bookName)\n\n"
                }
            }

            // Chapter header
            if entry.chapter != currentChapter {
                currentChapter = entry.chapter
                markdown += "### Chapter \(currentChapter)\n\n"
            }

            // Entry
            if entry.verse == 0 {
                markdown += "#### General Notes\n\n"
            } else if let verseRefs = entry.verseRefs, let endVerse = verseRefs.first, endVerse != entry.verse {
                markdown += "#### Verses \(entry.verse)-\(endVerse)\n\n"
            } else {
                markdown += "#### Verse \(entry.verse)\n\n"
            }

            // Replace local footnote markers with unique IDs (include book for cross-book uniqueness)
            let bookAbbrev = lookupBookAbbrev(entry.book) ?? "b\(entry.book)"
            let content = replaceFootnoteMarkers(
                text: entry.content,
                prefix: "\(bookAbbrev)-\(currentChapter):\(entry.verse)",
                footnotes: entry.footnotes,
                allFootnotes: &allFootnotes
            )
            markdown += content + "\n\n"
        }

        // Add all footnotes at end of document
        if !allFootnotes.isEmpty {
            markdown += "\n---\n\n"
            markdown += formatFootnotesAtEnd(allFootnotes)
        }

        return markdown
    }

    /// Export notes to individual markdown files per book (returns dict of bookName -> markdown)
    static func exportNotesToMarkdownByBook(moduleId: String) throws -> [String: String] {
        let database = ModuleDatabase.shared
        let entries = try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId)
                .order(Column("book"), Column("chapter"), Column("verse"))
                .fetchAll(db)
        }

        var results: [String: String] = [:]

        // Group by book
        let entriesByBook = Dictionary(grouping: entries) { $0.book }

        for (bookId, bookEntries) in entriesByBook {
            guard let bookName = lookupBookName(bookId) else { continue }

            var markdown = "# \(bookName) Notes\n\n---\n\n"
            var allFootnotes: [(uniqueId: String, content: String)] = []
            var currentChapter: Int = 0

            for entry in bookEntries.sorted(by: { ($0.chapter, $0.verse) < ($1.chapter, $1.verse) }) {
                // Chapter header
                if entry.chapter != currentChapter {
                    currentChapter = entry.chapter
                    markdown += "## Chapter \(currentChapter)\n\n"
                }

                // Entry
                if entry.verse == 0 {
                    markdown += "### General Notes\n\n"
                } else if let verseRefs = entry.verseRefs, let endVerse = verseRefs.first, endVerse != entry.verse {
                    markdown += "### Verses \(entry.verse)-\(endVerse)\n\n"
                } else {
                    markdown += "### Verse \(entry.verse)\n\n"
                }

                // Replace local footnote markers with unique IDs
                let content = replaceFootnoteMarkers(
                    text: entry.content,
                    prefix: "\(currentChapter):\(entry.verse)",
                    footnotes: entry.footnotes,
                    allFootnotes: &allFootnotes
                )
                markdown += content + "\n\n"
            }

            // Add footnotes at end of book
            if !allFootnotes.isEmpty {
                markdown += "\n---\n\n"
                markdown += formatFootnotesAtEnd(allFootnotes)
            }

            results[bookName] = markdown
        }

        return results
    }

    /// Replace local footnote markers [^1] with unique IDs [^chapter:verse-1]
    private static func replaceFootnoteMarkers(
        text: String,
        prefix: String,
        footnotes: [UserNotesFootnote]?,
        allFootnotes: inout [(uniqueId: String, content: String)]
    ) -> String {
        var result = text

        guard let footnotes = footnotes, !footnotes.isEmpty else {
            return result
        }

        for fn in footnotes {
            let localMarker = "[^\(fn.id)]"
            let uniqueId = "\(prefix)-\(fn.id)"
            let uniqueMarker = "[^\(uniqueId)]"

            result = result.replacingOccurrences(of: localMarker, with: uniqueMarker)
            allFootnotes.append((uniqueId: uniqueId, content: fn.content.plainText))
        }

        return result
    }

    /// Format collected footnotes at end of document
    private static func formatFootnotesAtEnd(_ footnotes: [(uniqueId: String, content: String)]) -> String {
        var lines: [String] = []

        for (uniqueId, content) in footnotes {
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

        return lines.joined(separator: "\n")
    }

    // MARK: - Notes Import

    /// Import notes from markdown into a module
    /// Delegates to NotesImportExportManager for full footnote support
    static func importNotesFromMarkdown(_ markdown: String, moduleId: String) async throws -> Int {
        return try await NotesImportExportManager.shared.importNotesFromMarkdownString(markdown, moduleId: moduleId)
    }

    // MARK: - Devotionals Export

    /// Export all devotionals from a module to markdown
    static func exportDevotionalsToMarkdown(moduleId: String) throws -> String {
        let database = ModuleDatabase.shared
        let entries = try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId)
                .order(Column("month_day"), Column("title"))
                .fetchAll(db)
        }

        guard let module = try database.getModule(id: moduleId) else {
            throw MarkdownError.moduleNotFound
        }

        var markdown = "# \(module.name)\n\n"

        if let description = module.description, !description.isEmpty {
            markdown += "> \(description)\n\n"
        }

        markdown += "---\n\n"

        for entry in entries {
            markdown += "## \(entry.title)\n\n"

            // YAML-style frontmatter for metadata
            var metadata: [String] = []
            if let monthDay = entry.monthDay {
                metadata.append("**Date:** \(monthDay)")
            }
            if !entry.tagList.isEmpty {
                metadata.append("**Tags:** \(entry.tagList.joined(separator: ", "))")
            }

            if !metadata.isEmpty {
                markdown += metadata.joined(separator: " | ") + "\n\n"
            }

            markdown += entry.content + "\n\n---\n\n"
        }

        return markdown
    }

    /// Export devotionals to individual markdown files (returns dict of title -> markdown)
    static func exportDevotionalsToMarkdownByEntry(moduleId: String) throws -> [String: String] {
        let database = ModuleDatabase.shared
        let entries = try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId)
                .order(Column("month_day"), Column("title"))
                .fetchAll(db)
        }

        var results: [String: String] = [:]

        for entry in entries {
            var markdown = "---\n"
            markdown += "title: \(entry.title)\n"
            if let monthDay = entry.monthDay {
                markdown += "date: \(monthDay)\n"
            }
            if !entry.tagList.isEmpty {
                markdown += "tags: \(entry.tagList.joined(separator: ", "))\n"
            }
            markdown += "---\n\n"
            markdown += entry.content

            // Use title as filename, sanitized
            let filename = entry.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            results[filename] = markdown
        }

        return results
    }

    // MARK: - Devotionals Import

    /// Import devotionals from markdown into a module
    static func importDevotionalsFromMarkdown(_ markdown: String, moduleId: String) throws -> Int {
        let database = ModuleDatabase.shared
        var importedCount = 0

        // Split by entry separators (## Title or ---)
        let entries = parseDevotionalEntries(markdown)

        for entryData in entries {
            let entry = DevotionalEntry(
                moduleId: moduleId,
                monthDay: entryData.monthDay,
                tags: entryData.tags.isEmpty ? nil : entryData.tags,
                title: entryData.title,
                content: entryData.content
            )

            try database.saveDevotionalEntry(entry)
            importedCount += 1
        }

        return importedCount
    }

    // MARK: - Helper Types

    private struct ParsedDevotional {
        let title: String
        let monthDay: String?
        let tags: [String]
        let content: String
    }

    // MARK: - Parsing Helpers

    private static func parseBookHeader(_ line: String) -> String? {
        // Match: ## Genesis or # Genesis Notes or ## Genesis Notes
        let patterns = [
            "^#{1,2}\\s+(.+?)(?:\\s+Notes)?\\s*$"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                let name = String(line[range]).trimmingCharacters(in: .whitespaces)
                // Verify it's actually a book name
                if lookupBookId(name) != nil {
                    return name
                }
            }
        }
        return nil
    }

    private static func parseChapterHeader(_ line: String) -> Int? {
        // Match: ### Chapter 1 or ## Chapter 1
        let pattern = "^#{2,3}\\s+Chapter\\s+(\\d+)\\s*$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 1), in: line) {
            return Int(line[range])
        }
        return nil
    }

    private static func parseVerseHeader(_ line: String) -> (Int, Int?)? {
        // Match: #### Verse 1 or ### Verse 1 or #### Verses 1-5
        let singlePattern = "^#{3,4}\\s+Verse\\s+(\\d+)\\s*$"
        let rangePattern = "^#{3,4}\\s+Verses?\\s+(\\d+)-(\\d+)\\s*$"

        // Try range first
        if let regex = try? NSRegularExpression(pattern: rangePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let startRange = Range(match.range(at: 1), in: line),
           let endRange = Range(match.range(at: 2), in: line),
           let start = Int(line[startRange]),
           let end = Int(line[endRange]) {
            return (start, end)
        }

        // Try single
        if let regex = try? NSRegularExpression(pattern: singlePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let range = Range(match.range(at: 1), in: line),
           let verse = Int(line[range]) {
            return (verse, nil)
        }

        return nil
    }

    private static func parseDevotionalEntries(_ markdown: String) -> [ParsedDevotional] {
        var entries: [ParsedDevotional] = []

        // Check if it's YAML frontmatter format (single entry)
        if markdown.hasPrefix("---") {
            if let entry = parseSingleDevotionalWithFrontmatter(markdown) {
                return [entry]
            }
        }

        // Otherwise, split by ## headers
        let lines = markdown.components(separatedBy: .newlines)
        var currentTitle: String? = nil
        var currentContent: [String] = []
        var currentMonthDay: String? = nil
        var currentTags: [String] = []

        func saveCurrentEntry() {
            guard let title = currentTitle else { return }
            let content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return }

            entries.append(ParsedDevotional(
                title: title,
                monthDay: currentMonthDay,
                tags: currentTags,
                content: content
            ))
            currentContent = []
            currentMonthDay = nil
            currentTags = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Entry header: ## Title
            if trimmed.hasPrefix("## ") && !trimmed.hasPrefix("### ") {
                saveCurrentEntry()
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Skip module header and separators
            if trimmed.hasPrefix("# ") || trimmed == "---" || trimmed.hasPrefix(">") {
                continue
            }

            // Parse metadata line: **Date:** 01-15 | **Tags:** faith, hope
            if trimmed.hasPrefix("**Date:**") || trimmed.hasPrefix("**Tags:**") {
                let parts = trimmed.components(separatedBy: "|")
                for part in parts {
                    let cleaned = part.trimmingCharacters(in: .whitespaces)
                    if cleaned.hasPrefix("**Date:**") {
                        currentMonthDay = cleaned.replacingOccurrences(of: "**Date:**", with: "").trimmingCharacters(in: .whitespaces)
                    } else if cleaned.hasPrefix("**Tags:**") {
                        let tagsStr = cleaned.replacingOccurrences(of: "**Tags:**", with: "").trimmingCharacters(in: .whitespaces)
                        currentTags = tagsStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                }
                continue
            }

            // Content
            if currentTitle != nil {
                currentContent.append(line)
            }
        }

        saveCurrentEntry()
        return entries
    }

    private static func parseSingleDevotionalWithFrontmatter(_ markdown: String) -> ParsedDevotional? {
        let lines = markdown.components(separatedBy: .newlines)

        guard lines.first == "---" else { return nil }

        var title: String? = nil
        var monthDay: String? = nil
        var tags: [String] = []
        var contentStart: Int? = nil

        for (index, line) in lines.enumerated() {
            if index == 0 { continue } // Skip opening ---

            if line == "---" {
                contentStart = index + 1
                break
            }

            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            switch key {
            case "title":
                title = value
            case "date":
                monthDay = value
            case "tags":
                tags = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            default:
                break
            }
        }

        guard let entryTitle = title, let start = contentStart else { return nil }

        let content = lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedDevotional(
            title: entryTitle,
            monthDay: monthDay,
            tags: tags,
            content: content
        )
    }

    private static func lookupBookName(_ bookId: Int) -> String? {
        (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name
    }

    private static func lookupBookAbbrev(_ bookId: Int) -> String? {
        (try? BundledModuleDatabase.shared.getBook(id: bookId))?.osisId
    }

    private static func lookupBookId(_ name: String) -> Int? {
        let allBooks = (try? BundledModuleDatabase.shared.getAllBooks()) ?? []

        // Try exact match (case insensitive)
        if let book = allBooks.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return book.id
        }

        // Try OSIS ID (case insensitive)
        if let book = allBooks.first(where: { $0.osisId.lowercased() == name.lowercased() }) {
            return book.id
        }

        return nil
    }
}

// MARK: - Errors

enum MarkdownError: Error, LocalizedError {
    case moduleNotFound
    case parseError(String)
    case exportError(String)

    var errorDescription: String? {
        switch self {
        case .moduleNotFound:
            return "Module not found"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .exportError(let message):
            return "Export error: \(message)"
        }
    }
}
