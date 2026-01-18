//
//  DevotionalImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation

/// Manages markdown import/export for devotionals
/// Import: iCloud/Documents/Import/Devotionals/*.md → parsed and saved to database, file deleted
/// Export: Database → iCloud/Documents/Export/Devotionals/{title-slug}.md
class DevotionalImportExportManager {
    static let shared = DevotionalImportExportManager()

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
        return docs.appendingPathComponent("Import").appendingPathComponent("Devotionals")
    }

    var exportDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent("Export").appendingPathComponent("Devotionals")
    }

    // MARK: - Import

    /// Import result for a single file
    struct ImportResult {
        let fileName: String
        let devotionalTitle: String
        let success: Bool
        let error: String?
    }

    /// Process all markdown files in the Import/Devotionals directory
    /// Returns list of imported devotionals, deletes files after successful import
    func processImports(moduleId: String = "devotionals") async throws -> [ImportResult] {
        print("[DevotionalImport] processImports() called")
        guard let importDir = importDirectoryURL else {
            print("[DevotionalImport] Import directory not available")
            return []
        }
        print("[DevotionalImport] Import directory: \(importDir.path)")

        // Create import directory if needed
        if !fileManager.fileExists(atPath: importDir.path) {
            try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
            print("[DevotionalImport] Created import directory")
            return []
        }

        // Find all .md files
        let contents = try fileManager.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil)
        let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }

        if mdFiles.isEmpty {
            return []
        }

        print("[DevotionalImport] Found \(mdFiles.count) markdown file(s) to import")

        var results: [ImportResult] = []

        for fileURL in mdFiles {
            do {
                let result = try await importMarkdownFile(at: fileURL, moduleId: moduleId)
                results.append(result)

                if result.success {
                    // Delete file after successful import
                    try fileManager.removeItem(at: fileURL)
                    print("[DevotionalImport] Deleted imported file: \(fileURL.lastPathComponent)")
                }
            } catch {
                results.append(ImportResult(
                    fileName: fileURL.lastPathComponent,
                    devotionalTitle: "",
                    success: false,
                    error: error.localizedDescription
                ))
                print("[DevotionalImport] Error importing \(fileURL.lastPathComponent): \(error)")
            }
        }

        return results
    }

    /// Import a single markdown file
    private func importMarkdownFile(at url: URL, moduleId: String) async throws -> ImportResult {
        let content = try String(contentsOf: url, encoding: .utf8)

        // Parse markdown to Devotional
        guard let devotional = MarkdownDevotionalConverter.parseMarkdown(content) else {
            throw ImportError.parseError("Failed to parse markdown")
        }

        // Save to database
        let entry = DevotionalEntry(from: devotional, moduleId: moduleId)
        try ModuleDatabase.shared.saveDevotionalEntry(entry)

        return ImportResult(
            fileName: url.lastPathComponent,
            devotionalTitle: devotional.meta.title,
            success: true,
            error: nil
        )
    }

    // MARK: - Export

    /// Export a single devotional to markdown
    func exportDevotional(_ devotional: Devotional) async throws -> URL {
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let markdown = MarkdownDevotionalConverter.devotionalToMarkdown(devotional)
        let fileName = sanitizeFilename(devotional.meta.title) + ".md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[DevotionalExport] Exported \(fileName)")

        return fileURL
    }

    /// Export all devotionals from a module
    func exportAllDevotionals(moduleId: String) async throws -> [URL] {
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let devotionals = try DevotionalStorage.shared.getAllDevotionals(moduleId: moduleId)

        if devotionals.isEmpty {
            throw ExportError.noDevotionalsFound
        }

        var exportedURLs: [URL] = []

        for devotional in devotionals {
            do {
                let url = try await exportDevotional(devotional)
                exportedURLs.append(url)
            } catch {
                print("[DevotionalExport] Failed to export '\(devotional.meta.title)': \(error)")
            }
        }

        return exportedURLs
    }

    /// Export all devotionals to a single combined markdown file
    func exportAllToSingleFile(moduleId: String) async throws -> URL {
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }

        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        let devotionals = try DevotionalStorage.shared.getAllDevotionals(moduleId: moduleId)

        if devotionals.isEmpty {
            throw ExportError.noDevotionalsFound
        }

        var lines: [String] = []

        // Header
        lines.append("# My Devotionals")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Process each devotional
        for devotional in devotionals {
            lines.append("## \(devotional.meta.title)")
            lines.append("")

            // Metadata
            var metadataLines: [String] = []
            if let date = devotional.meta.date {
                metadataLines.append("**Date:** \(date)")
            }
            if let category = devotional.meta.category {
                metadataLines.append("**Category:** \(category.rawValue)")
            }
            if let tags = devotional.meta.tags, !tags.isEmpty {
                metadataLines.append("**Tags:** \(tags.joined(separator: ", "))")
            }
            if let author = devotional.meta.author {
                metadataLines.append("**Author:** \(author)")
            }

            if !metadataLines.isEmpty {
                lines.append(metadataLines.joined(separator: " | "))
                lines.append("")
            }

            // Summary
            if let summary = devotional.summary {
                lines.append("### Summary")
                lines.append("")
                switch summary {
                case .plain(let text):
                    lines.append(text)
                case .annotated(let annotated):
                    lines.append(annotated.text)
                }
                lines.append("")
            }

            // Content
            switch devotional.content {
            case .blocks(let blocks):
                lines.append(MarkdownDevotionalConverter.blocksToMarkdown(blocks))
            case .structured(let structured):
                if let intro = structured.introduction {
                    lines.append(MarkdownDevotionalConverter.blocksToMarkdown(intro))
                }
                if let sections = structured.sections {
                    for section in sections {
                        lines.append(sectionToMarkdown(section))
                    }
                }
                if let conclusion = structured.conclusion {
                    lines.append(MarkdownDevotionalConverter.blocksToMarkdown(conclusion))
                }
            }

            lines.append("---")
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")
        let fileName = "All_Devotionals.md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[DevotionalExport] Exported all devotionals to \(fileName)")

        return fileURL
    }

    // MARK: - Helper Methods

    private func sectionToMarkdown(_ section: DevotionalSection) -> String {
        var lines: [String] = []

        let level = section.level ?? 2
        let prefix = String(repeating: "#", count: level + 1) // +1 because we're inside a devotional
        lines.append("\(prefix) \(section.title)")
        lines.append("")

        if let blocks = section.blocks {
            lines.append(MarkdownDevotionalConverter.blocksToMarkdown(blocks))
        }

        if let subsections = section.subsections {
            for subsection in subsections {
                lines.append(sectionToMarkdown(subsection))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func sanitizeFilename(_ title: String) -> String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "|", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .parseError(let message):
                return "Parse error: \(message)"
            }
        }
    }

    enum ExportError: LocalizedError {
        case directoryNotAvailable
        case noDevotionalsFound

        var errorDescription: String? {
            switch self {
            case .directoryNotAvailable:
                return "Export directory not available"
            case .noDevotionalsFound:
                return "No devotionals found to export"
            }
        }
    }
}
