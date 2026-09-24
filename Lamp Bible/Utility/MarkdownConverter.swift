//
//  MarkdownConverter.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import GRDB
import LampCore

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
            let endReference = entry.verseRefs?.filter { $0 >= entry.verseId }.max()
            let heading = LampPersonalMarkdownWriter.noteHeading(
                reference: entry.verseId, endReference: endReference
            )
            markdown += "#### \(heading)\n\n"

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
                let endReference = entry.verseRefs?.filter { $0 >= entry.verseId }.max()
                let heading = LampPersonalMarkdownWriter.noteHeading(
                    reference: entry.verseId, endReference: endReference
                )
                markdown += "### \(heading)\n\n"

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
        let rewritten = LampPersonalMarkdownWriter.rewritingFootnoteMarkers(
            in: text, prefix: prefix,
            footnotes: (footnotes ?? []).map { (id: $0.id, content: $0.content.plainText) }
        )
        allFootnotes += rewritten.definitions.map {
            (uniqueId: $0.id, content: $0.content)
        }
        return rewritten.content
    }

    /// Format collected footnotes at end of document
    private static func formatFootnotesAtEnd(_ footnotes: [(uniqueId: String, content: String)]) -> String {
        LampPersonalMarkdownWriter.footnoteDefinitions(
            footnotes.map { (id: $0.uniqueId, content: $0.content) }
        )
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
                .order(Column("date"), Column("title"))
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
            if let devotional = entry.toDevotional() {
                markdown += devotionalEntryMarkdown(devotional) + "\n\n---\n\n"
            } else {
                markdown += LampPersonalMarkdownWriter.devotionalEntry(
                    LampMarkdownDevotionalEntry(title: entry.title, content: entry.content)
                ) + "\n\n---\n\n"
            }
        }

        return markdown
    }

    static func devotionalEntryMarkdown(_ devotional: Devotional) -> String {
        let scriptures = devotional.meta.keyScriptures?.map { scripture in
            scripture.label ?? LampBibleReferenceFormatter.describeRange(
                from: scripture.sv, to: scripture.ev ?? scripture.sv
            )
        } ?? []
        let footnotes = MarkdownDevotionalConverter.footnotesToMarkdown(devotional.footnotes)
        return LampPersonalMarkdownWriter.devotionalEntry(LampMarkdownDevotionalEntry(
            title: devotional.meta.title,
            subtitle: devotional.meta.subtitle,
            author: devotional.meta.author,
            date: devotional.meta.date,
            tags: devotional.meta.tags ?? [],
            category: devotional.meta.category?.rawValue,
            seriesName: devotional.meta.series?.name,
            seriesOrder: devotional.meta.series?.order,
            scriptureDescriptions: scriptures,
            summary: MarkdownDevotionalConverter.summaryToMarkdown(devotional),
            content: MarkdownDevotionalConverter.bodyToMarkdown(devotional),
            footnotes: footnotes
        ))
    }

    /// Export devotionals to individual markdown files (returns dict of title -> markdown)
    static func exportDevotionalsToMarkdownByEntry(moduleId: String) throws -> [String: String] {
        let database = ModuleDatabase.shared
        let entries = try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId)
                .order(Column("date"), Column("title"))
                .fetchAll(db)
        }

        var results: [String: String] = [:]

        for entry in entries {
            let markdown = entry.toDevotional().map(
                MarkdownDevotionalConverter.devotionalToMarkdown
            ) ?? "---\ntitle: \(entry.title)\n---\n\n\(entry.content)"

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
        let drafts = try LampPersonalMarkdownParser.devotionals(
            from: markdown, filename: "Writing"
        )
        for draft in drafts {
            let series: DevotionalSeriesInfo? = draft.seriesName != nil
                || draft.seriesOrder != nil
                ? DevotionalSeriesInfo(id: nil, name: draft.seriesName, order: draft.seriesOrder)
                : nil
            let footnoteDefinitions = draft.footnotes.map {
                LampPersonalMarkdownDocument.extractFootnoteDefinitions(in: "---\n\n" + $0)
                    .definitions
            } ?? [:]
            let body = footnoteDefinitions.isEmpty && draft.footnotes != nil
                ? draft.content + "\n\n### Footnotes\n\n" + (draft.footnotes ?? "")
                : draft.content
            let devotional = Devotional(
                meta: DevotionalMeta(
                    title: draft.title,
                    subtitle: draft.subtitle,
                    author: draft.author,
                    date: draft.date,
                    tags: draft.tags.isEmpty ? nil : draft.tags,
                    category: draft.category.flatMap(DevotionalCategory.init(rawValue:)),
                    series: series,
                    keyScriptures: draft.keyScriptures.map {
                        DevotionalKeyScripture(
                            sv: $0.startReference,
                            ev: $0.endReference,
                            label: $0.text
                        )
                    }
                ),
                summary: draft.summary.map(DevotionalTextField.plain),
                content: .blocks(MarkdownDevotionalConverter.markdownToBlocks(body)),
                footnotes: footnoteDefinitions.sorted { $0.key < $1.key }.map {
                    DevotionalFootnote(id: $0.key, content: .plain($0.value))
                },
                markdownContent: body
            )
            try ModuleDatabase.shared.saveDevotionalEntry(
                DevotionalEntry(from: devotional, moduleId: moduleId)
            )
        }
        return drafts.count
    }

    private static func lookupBookName(_ bookId: Int) -> String? {
        (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name
    }

    private static func lookupBookAbbrev(_ bookId: Int) -> String? {
        (try? BundledModuleDatabase.shared.getBook(id: bookId))?.osisId
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
