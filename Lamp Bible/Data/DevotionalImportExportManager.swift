//
//  DevotionalImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import UIKit

/// Manages markdown import/export for devotionals
/// Import: iCloud/Documents/Import/Devotionals/*.md → offered for review by `WritingDropFolder`
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

    // The Import folder is read by `WritingDropFolder`, through core's
    // writing import and the review sheet; nothing in it is deleted.

    // MARK: - Export

    /// Export a single devotional to markdown (with media if present)
    func exportDevotional(_ devotional: Devotional, moduleId: String = WritingCollection.id) async throws -> URL {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }
        return try exportDevotional(devotional, moduleId: moduleId, to: exportDir)
    }

    func exportDevotional(
        _ devotional: Devotional, moduleId: String, to exportDir: URL
    ) throws -> URL {
        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        // Export media files if present
        if let media = devotional.media, !media.isEmpty {
            try exportMediaFiles(media, devotionalId: devotional.meta.id, moduleId: moduleId, to: exportDir)
        }

        // Generate markdown with media references
        let markdown = generateMarkdownWithMedia(devotional)
        let fileName = sanitizeFilename(devotional.meta.title) + ".md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[DevotionalExport] Exported \(fileName)")

        return fileURL
    }

    /// Export all devotionals from a module (with shared media folder)
    func exportAllDevotionals(moduleId: String) async throws -> [URL] {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }
        return try exportAllDevotionals(
            try DevotionalStorage.shared.getAllDevotionals(moduleId: moduleId),
            moduleId: moduleId,
            to: exportDir
        )
    }

    func exportAllDevotionals(
        _ devotionals: [Devotional], moduleId: String, to exportDir: URL
    ) throws -> [URL] {
        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        if devotionals.isEmpty {
            throw ExportError.noDevotionalsFound
        }

        var exportedURLs: [URL] = []

        for devotional in devotionals {
            do {
                // Export media files to shared media folder
                if let media = devotional.media, !media.isEmpty {
                    try exportMediaFiles(media, devotionalId: devotional.meta.id, moduleId: moduleId, to: exportDir)
                }

                // Generate markdown with media references
                let markdown = generateMarkdownWithMedia(devotional)
                let fileName = sanitizeFilename(devotional.meta.title) + ".md"
                let fileURL = exportDir.appendingPathComponent(fileName)

                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                exportedURLs.append(fileURL)
                print("[DevotionalExport] Exported \(fileName)")
            } catch {
                print("[DevotionalExport] Failed to export '\(devotional.meta.title)': \(error)")
            }
        }

        return exportedURLs
    }

    // MARK: - Media Export Helpers

    /// Export media files to the shared media folder
    private func exportMediaFiles(
        _ mediaRefs: [DevotionalMediaReference],
        devotionalId: String,
        moduleId: String,
        to exportDir: URL
    ) throws {
        let mediaDir = exportDir.appendingPathComponent("media")

        // Create media directory if needed
        if !fileManager.fileExists(atPath: mediaDir.path) {
            try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        }

        for mediaRef in mediaRefs {
            guard let sourceURL = DevotionalMediaStorage.shared.getMediaURL(
                for: mediaRef,
                devotionalId: devotionalId,
                moduleId: moduleId
            ) else {
                print("[DevotionalExport] Media file not found: \(mediaRef.filename)")
                continue
            }

            let destURL = mediaDir.appendingPathComponent(mediaRef.filename)

            // Skip if already exists (shared across devotionals)
            if fileManager.fileExists(atPath: destURL.path) {
                continue
            }

            try fileManager.copyItem(at: sourceURL, to: destURL)
            print("[DevotionalExport] Copied media: \(mediaRef.filename)")
        }
    }

    /// Generate markdown with proper media file references
    private func generateMarkdownWithMedia(_ devotional: Devotional) -> String {
        // Build a map of mediaId -> filename for replacement
        var mediaFilenames: [String: String] = [:]
        if let media = devotional.media {
            for mediaRef in media {
                mediaFilenames[mediaRef.id] = mediaRef.filename
            }
        }

        // Generate base markdown
        var markdown = MarkdownDevotionalConverter.devotionalToMarkdown(devotional)

        // Replace media ID references with actual filenames
        for (mediaId, filename) in mediaFilenames {
            markdown = markdown.replacingOccurrences(
                of: "media/\(mediaId)",
                with: "media/\(filename)"
            )
        }

        return markdown
    }

    /// Export all devotionals to a single combined markdown file
    func exportAllToSingleFile(moduleId: String) async throws -> URL {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments else {
            throw ExportError.directoryNotAvailable
        }
        guard let exportDir = exportDirectoryURL else {
            throw ExportError.directoryNotAvailable
        }
        return try exportAllToSingleFile(
            try DevotionalStorage.shared.getAllDevotionals(moduleId: moduleId),
            to: exportDir
        )
    }

    func exportAllToSingleFile(_ devotionals: [Devotional], to exportDir: URL) throws -> URL {
        // Create export directory if needed
        if !fileManager.fileExists(atPath: exportDir.path) {
            try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        }

        if devotionals.isEmpty {
            throw ExportError.noDevotionalsFound
        }

        let markdown = Self.combinedMarkdown(for: devotionals)
        let fileName = "All_Writing.md"
        let fileURL = exportDir.appendingPathComponent(fileName)

        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[DevotionalExport] Exported all devotionals to \(fileName)")

        return fileURL
    }

    /// One document holding every writing, separated by rules — the shape
    /// someone reads outside the app.
    static func combinedMarkdown(for devotionals: [Devotional]) -> String {
        let entries = devotionals.map(MarkdownConverter.devotionalEntryMarkdown)
        return "# My Writing\n\n---\n\n"
            + entries.joined(separator: "\n\n---\n\n") + "\n\n---\n"
    }

    // MARK: - Helper Methods

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
                return "No writing found to export"
            }
        }
    }
}
