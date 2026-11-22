//
//  DevotionalImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import UIKit

/// Manages markdown import/export for writing
/// Import: iCloud/Documents/Import/Writing/*.md → offered for review by `WritingDropFolder`
/// Export: Database → iCloud/Documents/Export/Writing/{title-slug}.md
///
/// Both folders were named `Devotionals` before writing was renamed; an
/// earlier folder is moved to the new name the next time either is used
/// (`moveEarlierFolder`).
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

    /// The folder a person drops writing into, as Files shows it.
    static let folderName = "Writing"
    /// The folders' name before writing was renamed.
    static let earlierFolderName = "Devotionals"

    var importDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent("Import").appendingPathComponent(Self.folderName)
    }

    var earlierImportDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent("Import").appendingPathComponent(Self.earlierFolderName)
    }

    /// The Export folder, once an earlier `Export/Devotionals` has been
    /// moved to it. Reached off the main thread: it touches iCloud Drive.
    ///
    /// While a move that should have happened hasn't, exports go on into the
    /// earlier folder, so a move that failed once isn't turned, by an export
    /// into the new folder, into two folders that both hold something,
    /// which are never merged.
    var exportDirectoryURL: URL? {
        guard let docs = documentsURL else { return nil }
        let export = docs.appendingPathComponent("Export")
        let folder = export.appendingPathComponent(Self.folderName)
        let earlier = export.appendingPathComponent(Self.earlierFolderName)
        switch Self.moveEarlierFolder(from: earlier, to: folder, fileManager: fileManager) {
        case .failed: return earlier
        case .done, .leftBoth: return folder
        }
    }

    enum EarlierFolderMove: Equatable {
        /// There was no earlier folder, or it has been moved or removed.
        case done
        /// Both folders hold something, and are left as they are.
        case leftBoth
        /// The move should have happened and didn't, or the new name is taken
        /// by something not a folder: the earlier folder is still the one to
        /// use, and the next ask tries again.
        case failed
    }

    /// One move at a time in this process, held for the whole of it, so
    /// nothing is handed the new folder while the old is still being moved.
    private static let moving = NSLock()

    /// Moves an earlier `Devotionals` folder to its new name by renaming it
    /// whole, through a file coordinator, which keeps every file, the
    /// pictures beside them and any `lamp-import.json` together as they were.
    /// A new folder that holds nothing yet, as one made at a look before
    /// anything was dropped in, is given way to.
    ///
    /// Where both hold something, nothing is moved or merged: a merge could
    /// part a writing from its pictures or bring one folder's manifest over
    /// the other's files. The earlier folder is left as it is, for the person
    /// to move by hand, except that an empty one, as an older Lamp on another
    /// device makes, is removed.
    ///
    /// Asked on every use, at the cost of one look for the old folder, so a
    /// move that failed is tried again, and a folder that appears later is
    /// moved too. A symbolic link is never followed. Never throws.
    @discardableResult
    static func moveEarlierFolder(
        from old: URL, to new: URL, fileManager: FileManager = .default
    ) -> EarlierFolderMove {
        func isFolder(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        /// Removes `folder` if it holds nothing but Finder's `.DS_Store`
        /// file, by removals that refuse anything else, under a coordinator,
        /// so a save another app has begun into it finishes first and the
        /// folder is then kept.
        func holdsNothing(_ folder: URL) -> Bool {
            guard let left = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return false }
            return left.allSatisfy { $0 == ".DS_Store" }
        }
        func removeIfEmpty(_ folder: URL) -> Bool {
            // Looked at first too, so no editor holding a file in a folder
            // that stays is asked to give way to a deletion that won't come.
            guard holdsNothing(folder) else { return false }
            var removed = false
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: folder, options: .forDeleting, error: &coordinationError
            ) { folder in
                guard holdsNothing(folder) else { return }
                // `unlink` removes only a file, and `rmdir` only an empty folder.
                _ = folder.appendingPathComponent(".DS_Store").withUnsafeFileSystemRepresentation {
                    $0.map { unlink($0) }
                }
                removed = folder.withUnsafeFileSystemRepresentation { $0.map { rmdir($0) } } == 0
            }
            return removed
        }
        guard isFolder(old) else { return .done }
        moving.lock()
        defer { moving.unlock() }
        guard isFolder(old) else { return .done }
        if (try? fileManager.attributesOfItem(atPath: new.path)) != nil {
            // Something not a folder has the new name: the earlier folder
            // stays the one to use until the person sorts it out.
            guard isFolder(new) else { return .failed }
            if removeIfEmpty(old) { return .done }
            if !holdsNothing(new), fileManager.fileExists(atPath: new.path) { return .leftBoth }
            guard removeIfEmpty(new) else { return .failed }
        }
        try? fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        var moved = false
        var coordinationError: NSError?
        // The move is announced by the coordinator doing it: another raises.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: old, options: .forMoving, writingItemAt: new, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            guard !fileManager.fileExists(atPath: to.path) else { return }
            if (try? fileManager.moveItem(at: from, to: to)) != nil {
                coordinator.item(at: from, didMoveTo: to)
                moved = true
            }
        }
        return moved ? .done : .failed
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
