//
//  DevotionalSharingManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-18.
//

import Foundation
import UIKit
import UniformTypeIdentifiers
import Compression

/// Manages sharing individual devotionals with other users
/// Supports export to shareable files and import from shared files
/// Uses bundled format (ZIP) when devotional contains media
class DevotionalSharingManager {
    static let shared = DevotionalSharingManager()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Format Detection

    /// Detect the format of a .lamp file
    func detectFileFormat(_ fileURL: URL) -> LampFileFormat {
        // Check if it's a ZIP file by reading first bytes
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL),
              let header = try? fileHandle.read(upToCount: 4) else {
            return .plainJSON
        }
        try? fileHandle.close()

        // ZIP files start with PK (0x50, 0x4B)
        if header.count >= 2 && header[0] == 0x50 && header[1] == 0x4B {
            return .bundle
        }

        return .plainJSON
    }

    // MARK: - Export

    /// Export a devotional to a temporary file for sharing
    /// Creates a bundle (ZIP) if devotional has media, otherwise plain JSON
    func exportForSharing(_ devotional: Devotional, moduleId: String) throws -> URL {
        // Check if devotional has media
        if let media = devotional.media, !media.isEmpty {
            return try exportAsBundle(devotional, moduleId: moduleId)
        } else {
            return try exportAsJSON(devotional)
        }
    }

    /// Export as plain JSON (v1 format, no media)
    private func exportAsJSON(_ devotional: Devotional) throws -> URL {
        let tempDir = fileManager.temporaryDirectory
        let fileName = sanitizeFilename(devotional.meta.title) + ".lamp"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Create a shareable wrapper
        let shareData = DevotionalShareData(
            version: 1,
            exportDate: Date(),
            devotional: devotional
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(shareData)
        try data.write(to: fileURL)

        return fileURL
    }

    /// Export as bundled format (v2, with media)
    private func exportAsBundle(_ devotional: Devotional, moduleId: String) throws -> URL {
        let tempDir = fileManager.temporaryDirectory
        let bundleDir = tempDir.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // Write manifest
        let manifest = BundleManifest(version: 2, type: "devotional-bundle")
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: bundleDir.appendingPathComponent("manifest.json"))

        // Write devotional JSON
        let shareData = DevotionalShareData(version: 2, exportDate: Date(), devotional: devotional)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let devotionalData = try encoder.encode(shareData)
        try devotionalData.write(to: bundleDir.appendingPathComponent("devotional.json"))

        // Copy media files
        if let media = devotional.media, !media.isEmpty {
            let mediaDir = bundleDir.appendingPathComponent("media")
            try fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)

            for mediaRef in media {
                if let sourceURL = DevotionalMediaStorage.shared.getMediaURL(
                    for: mediaRef,
                    devotionalId: devotional.meta.id,
                    moduleId: moduleId
                ) {
                    let destURL = mediaDir.appendingPathComponent(mediaRef.filename)
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }
            }
        }

        // Create ZIP
        let zipURL = tempDir.appendingPathComponent(sanitizeFilename(devotional.meta.title) + ".lamp")

        // Remove existing file if present
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }

        // Create ZIP archive using native API
        try createZipArchive(from: bundleDir, to: zipURL)

        // Cleanup temp directory
        try? fileManager.removeItem(at: bundleDir)

        return zipURL
    }

    /// Legacy export without moduleId (assumes no media)
    func exportForSharing(_ devotional: Devotional) throws -> URL {
        return try exportAsJSON(devotional)
    }

    /// Export a devotional to markdown for sharing
    func exportToMarkdown(_ devotional: Devotional) throws -> URL {
        let tempDir = fileManager.temporaryDirectory
        let fileName = sanitizeFilename(devotional.meta.title) + ".md"
        let fileURL = tempDir.appendingPathComponent(fileName)

        let markdown = MarkdownDevotionalConverter.devotionalToMarkdown(devotional)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
    }

    /// Share a devotional using the system share sheet (with media support)
    func share(_ devotional: Devotional, moduleId: String, from viewController: UIViewController? = nil, sourceView: UIView? = nil) {
        do {
            let fileURL = try exportForSharing(devotional, moduleId: moduleId)

            var items: [Any] = [fileURL]

            // Also include a text summary for platforms that don't support files
            let summary = createTextSummary(devotional)
            items.append(summary)

            let activityVC = UIActivityViewController(
                activityItems: items,
                applicationActivities: nil
            )

            // Get the presenting view controller
            guard let presenter = viewController ?? getRootViewController() else {
                print("[DevotionalSharingManager] No presenter available")
                return
            }

            // Configure for iPad. A popover without an anchor throws, so fall back to
            // the centre of the presenter's view when no source was supplied.
            if let popover = activityVC.popoverPresentationController {
                if let sourceView = sourceView {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceView.bounds
                } else {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 0,
                        height: 0
                    )
                    popover.permittedArrowDirections = []
                }
            }

            presenter.present(activityVC, animated: true)

        } catch {
            print("[DevotionalSharingManager] Export failed: \(error)")
        }
    }

    // MARK: - Import Preview

    /// Preview a file without importing - returns the devotional for confirmation UI
    func previewFile(_ fileURL: URL) throws -> LampFilePreview {
        let format = detectFileFormat(fileURL)

        switch format {
        case .bundle:
            return try previewBundleFile(fileURL)
        case .plainJSON:
            return try previewJSONFile(fileURL)
        }
    }

    /// Preview a plain JSON .lamp file
    private func previewJSONFile(_ fileURL: URL) throws -> LampFilePreview {
        let data = try Data(contentsOf: fileURL)

        // Try to decode as DevotionalShareData first
        if let shareData = try? JSONDecoder().decode(DevotionalShareData.self, from: data) {
            return LampFilePreview(
                type: .devotional,
                devotional: shareData.devotional,
                exportDate: shareData.exportDate
            )
        }

        // Try as raw Devotional
        if let devotional = try? JSONDecoder().decode(Devotional.self, from: data) {
            return LampFilePreview(type: .devotional, devotional: devotional)
        }

        // Try as DevotionalModuleFile
        if let moduleFile = try? JSONDecoder().decode(DevotionalModuleFile.self, from: data) {
            if moduleFile.entries.count == 1, let first = moduleFile.entries.first {
                return LampFilePreview(type: .devotional, devotional: first)
            } else {
                return LampFilePreview(type: .devotionalModule, moduleFile: moduleFile)
            }
        }

        // Try markdown. parseMarkdown accepts any text without frontmatter, so screen
        // out binary junk first - otherwise an unreadable file previews as an
        // "Untitled" devotional instead of reporting that it can't be read.
        if let content = String(data: data, encoding: .utf8),
           looksLikePlainText(content),
           let devotional = MarkdownDevotionalConverter.parseMarkdown(content) {
            return LampFilePreview(type: .devotional, devotional: devotional)
        }

        throw ImportError.invalidFormat
    }

    /// Whether a decoded string is plausibly a human-authored text document.
    /// Rejects empty content and control characters other than tab/newline.
    private func looksLikePlainText(_ content: String) -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !content.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control
                && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
    }

    /// Preview a bundled .lamp file (ZIP format)
    private func previewBundleFile(_ fileURL: URL) throws -> LampFilePreview {
        // Extract to temp directory for preview
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Unzip using native API
        try extractZipArchive(from: fileURL, to: tempDir)

        // Read devotional.json
        let root = bundleRoot(in: tempDir)
        let devotionalURL = root.appendingPathComponent("devotional.json")
        let data = try Data(contentsOf: devotionalURL)
        let shareData = try JSONDecoder().decode(DevotionalShareData.self, from: data)

        // Count media files
        let mediaDir = root.appendingPathComponent("media")
        var mediaCount = 0
        if fileManager.fileExists(atPath: mediaDir.path),
           let contents = try? fileManager.contentsOfDirectory(atPath: mediaDir.path) {
            mediaCount = contents.count
        }

        return LampFilePreview(
            type: .devotionalBundle,
            devotional: shareData.devotional,
            exportDate: shareData.exportDate,
            mediaCount: mediaCount
        )
    }

    // MARK: - Import

    /// Import the devotionals held in a .lamp file (handles both JSON and bundle
    /// formats). A shared single devotional yields one entry; a collection yields all
    /// of them, so importing a collection never discards its contents.
    func importFromFile(_ fileURL: URL, moduleId: String = "devotionals") throws -> [Devotional] {
        let format = detectFileFormat(fileURL)

        switch format {
        case .bundle:
            // The bundle format wraps exactly one devotional plus its media
            return [try importFromBundle(fileURL, moduleId: moduleId)]
        case .plainJSON:
            return try importFromJSON(fileURL)
        }
    }

    /// Import from plain JSON .lamp file
    private func importFromJSON(_ fileURL: URL) throws -> [Devotional] {
        let data = try Data(contentsOf: fileURL)

        // Try to decode as DevotionalShareData first
        if let shareData = try? JSONDecoder().decode(DevotionalShareData.self, from: data) {
            return [imported(shareData.devotional)]
        }

        // Try as raw Devotional
        if let devotional = try? JSONDecoder().decode(Devotional.self, from: data) {
            return [imported(devotional)]
        }

        // Try as DevotionalModuleFile - keep every entry, not just the first
        if let moduleFile = try? JSONDecoder().decode(DevotionalModuleFile.self, from: data),
           !moduleFile.entries.isEmpty {
            return moduleFile.entries.map { imported($0) }
        }

        throw ImportError.invalidFormat
    }

    /// Prepare a devotional that arrived in a file to be saved.
    ///
    /// A writing with no blocks of its own crosses in the portable format as a
    /// single paragraph holding its authored Markdown, because that format has
    /// nowhere else to put it. Stored as blocks, the body is read back as one
    /// paragraph of literal text: its headings keep their hashes and its images
    /// stay written out as link syntax instead of appearing. Put the authored
    /// text back where authored text lives before anything saves it.
    ///
    /// `importFromMarkdown` is deliberately left out: it was handed Markdown and
    /// parsed it into blocks on purpose, so there is nothing being mistaken for
    /// structure. Previewing skips this too, because a preview reads the blocks
    /// directly and never saves what it decoded.
    private func imported(_ devotional: Devotional) -> Devotional {
        withFreshIdentity(MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(devotional))
    }

    /// Give an incoming devotional a new identity so importing never overwrites an
    /// existing entry. Saving upserts on `meta.id`, so a shared devotional that kept
    /// its original ID would silently replace the recipient's copy — and re-importing
    /// the same file would replace the previous import instead of adding a copy.
    private func withFreshIdentity(_ devotional: Devotional) -> Devotional {
        var copy = devotional
        let now = Int(Date().timeIntervalSince1970)
        copy.meta.id = UUID().uuidString
        copy.meta.created = now
        copy.meta.lastModified = now
        return copy
    }

    /// Import from bundled .lamp file (ZIP with media)
    private func importFromBundle(_ fileURL: URL, moduleId: String) throws -> Devotional {
        // Extract to temp directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Unzip using native API
        try extractZipArchive(from: fileURL, to: tempDir)

        // Read devotional.json
        let root = bundleRoot(in: tempDir)
        let devotionalURL = root.appendingPathComponent("devotional.json")
        let data = try Data(contentsOf: devotionalURL)
        let shareData = try JSONDecoder().decode(DevotionalShareData.self, from: data)
        let devotional = imported(shareData.devotional)
        let newId = devotional.meta.id

        // Import media files
        let sourceMediaDir = root.appendingPathComponent("media")
        if fileManager.fileExists(atPath: sourceMediaDir.path), let media = devotional.media {
            try DevotionalMediaStorage.shared.ensureMediaDirectory(devotionalId: newId, moduleId: moduleId)
            let destMediaDir = DevotionalMediaStorage.shared.mediaDirectory(devotionalId: newId, moduleId: moduleId)

            for mediaRef in media {
                let sourceURL = sourceMediaDir.appendingPathComponent(mediaRef.filename)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    let destURL = destMediaDir.appendingPathComponent(mediaRef.filename)
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }
            }
        }

        // Cleanup temp directory
        try? fileManager.removeItem(at: tempDir)

        return devotional
    }

    /// Import a devotional from markdown
    func importFromMarkdown(_ fileURL: URL) throws -> Devotional {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        guard let devotional = MarkdownDevotionalConverter.parseMarkdown(content) else {
            throw ImportError.invalidFormat
        }
        return withFreshIdentity(devotional)
    }

    /// Import and save every devotional in a file into the given module, exporting to
    /// iCloud like any other devotional edit. Returns all entries that were saved.
    @discardableResult
    func importAndSave(_ fileURL: URL, moduleId: String = "devotionals") async throws -> [Devotional] {
        let imported: [Devotional]

        if fileURL.pathExtension.lowercased() == "md" {
            imported = [try importFromMarkdown(fileURL)]
        } else {
            imported = try importFromFile(fileURL, moduleId: moduleId)
        }

        guard !imported.isEmpty else {
            throw ImportError.invalidFormat
        }

        for devotional in imported {
            try await ModuleSyncManager.shared.saveDevotional(devotional, moduleId: moduleId)
        }

        return imported
    }

    // MARK: - Staging

    /// Copy an incoming file into the temporary directory so it can be imported after
    /// its security-scoped access is released — e.g. once the user has chosen a
    /// destination module. Call `startAccessingSecurityScopedResource()` around this.
    func stageForImport(_ fileURL: URL) throws -> URL {
        let stagedDir = fileManager.temporaryDirectory
            .appendingPathComponent("devotional-import", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagedDir, withIntermediateDirectories: true)

        let stagedURL = stagedDir.appendingPathComponent(fileURL.lastPathComponent)
        try fileManager.copyItem(at: fileURL, to: stagedURL)
        return stagedURL
    }

    /// Remove a file previously produced by `stageForImport(_:)`
    func discardStagedImport(_ stagedURL: URL) {
        try? fileManager.removeItem(at: stagedURL.deletingLastPathComponent())
    }

    // MARK: - Deep Link Sharing

    /// Generate a deep link URL for a devotional
    /// Note: Only practical for short devotionals due to URL length limits
    func generateDeepLink(_ devotional: Devotional) -> URL? {
        // For deep links, we only include essential metadata
        // The recipient can receive the title and a reference to look it up
        var components = URLComponents()
        components.scheme = "lampbible"
        components.host = "devotional"
        components.queryItems = [
            URLQueryItem(name: "title", value: devotional.meta.title),
            URLQueryItem(name: "id", value: devotional.meta.id)
        ]

        if let date = devotional.meta.date {
            components.queryItems?.append(URLQueryItem(name: "date", value: date))
        }

        return components.url
    }

    // MARK: - Helpers

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

    private func createTextSummary(_ devotional: Devotional) -> String {
        var lines: [String] = []

        lines.append(devotional.meta.title)

        if let subtitle = devotional.meta.subtitle {
            lines.append(subtitle)
        }

        if let date = devotional.meta.date {
            lines.append("Date: \(date)")
        }

        if let author = devotional.meta.author {
            lines.append("Author: \(author)")
        }

        lines.append("")
        lines.append("Shared from Lamp Bible")

        return lines.joined(separator: "\n")
    }

    private func getRootViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first,
              var top = window.rootViewController else {
            return nil
        }

        // Present from the topmost controller, otherwise the presentation is a no-op
        // whenever a sheet is already on screen.
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Where a bundle's contents actually are once extracted. This app writes
    /// them at the root; an archive made by zipping a folder nests everything
    /// one level down, and those were shared before this app could read them
    /// back at all.
    private func bundleRoot(in directory: URL) -> URL {
        let manifest = "devotional.json"
        if fileManager.fileExists(
            atPath: directory.appendingPathComponent(manifest).path
        ) {
            return directory
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent(manifest).path)
        } ?? directory
    }

    // MARK: - ZIP Archive Helpers

    /// Write a ZIP holding every file under `sourceDir`, named relative to it.
    ///
    /// Written by hand rather than handed to `NSFileCoordinator(.forUploading)`,
    /// which produces an archive this app cannot read back: it names entries
    /// after the directory it was given, and leaves their sizes at zero in the
    /// header to put them in a descriptor after the data. A writing shared with
    /// an image came back as "the file format is not recognized" because of it.
    ///
    /// Entries are stored rather than deflated. A bundle is a little JSON
    /// beside media that is already compressed, so there is nothing to gain.
    private func createZipArchive(from sourceDir: URL, to destinationURL: URL) throws {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for path in try archivablePaths(in: sourceDir) {
            let data = try Data(contentsOf: sourceDir.appendingPathComponent(path))
            let name = Array(path.utf8)
            let crc = CRC32.checksum(data)
            let size = UInt32(data.count)
            let localHeaderOffset = UInt32(archive.count)

            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))  // version needed
            archive.appendLittleEndian(UInt16(0))   // flags
            archive.appendLittleEndian(UInt16(0))   // stored
            archive.appendLittleEndian(UInt16(0))   // modification time
            archive.appendLittleEndian(UInt16(0))   // modification date
            archive.appendLittleEndian(crc)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(UInt16(name.count))
            archive.appendLittleEndian(UInt16(0))   // extra field
            archive.append(contentsOf: name)
            archive.append(data)

            centralDirectory.appendLittleEndian(UInt32(0x0201_4B50))
            centralDirectory.appendLittleEndian(UInt16(20))  // version made by
            centralDirectory.appendLittleEndian(UInt16(20))  // version needed
            centralDirectory.appendLittleEndian(UInt16(0))   // flags
            centralDirectory.appendLittleEndian(UInt16(0))   // stored
            centralDirectory.appendLittleEndian(UInt16(0))   // modification time
            centralDirectory.appendLittleEndian(UInt16(0))   // modification date
            centralDirectory.appendLittleEndian(crc)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(UInt16(name.count))
            centralDirectory.appendLittleEndian(UInt16(0))   // extra field
            centralDirectory.appendLittleEndian(UInt16(0))   // comment
            centralDirectory.appendLittleEndian(UInt16(0))   // disk number
            centralDirectory.appendLittleEndian(UInt16(0))   // internal attributes
            centralDirectory.appendLittleEndian(UInt32(0))   // external attributes
            centralDirectory.appendLittleEndian(localHeaderOffset)
            centralDirectory.append(contentsOf: name)

            entryCount += 1
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))  // this disk
        archive.appendLittleEndian(UInt16(0))  // disk holding the central directory
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(entryCount)
        archive.appendLittleEndian(UInt32(centralDirectory.count))
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))  // comment

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try archive.write(to: destinationURL)
    }

    /// Every file under `sourceDir`, as paths relative to it, in a fixed order
    /// so the same bundle produces the same bytes twice.
    private func archivablePaths(in sourceDir: URL) throws -> [String] {
        let base = sourceDir.standardizedFileURL.pathComponents
        guard let walker = fileManager.enumerator(
            at: sourceDir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let parts = url.standardizedFileURL.pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else {
                continue
            }
            paths.append(parts.dropFirst(base.count).joined(separator: "/"))
        }
        return paths.sorted()
    }

    /// Extract a ZIP archive to a directory
    private func extractZipArchive(from zipURL: URL, to destinationDir: URL) throws {
        try extractZipData(try Data(contentsOf: zipURL), to: destinationDir)
    }

    /// Extract through the central directory rather than by walking local
    /// headers from the front.
    ///
    /// A writer is allowed to leave the sizes in a local header at zero and
    /// write them in a descriptor after the data, which is what the system
    /// writer does; the central directory always carries the real ones. Reading
    /// it is what makes an archive written elsewhere readable here.
    private func extractZipData(_ data: Data, to destinationDir: URL) throws {
        for entry in try zipEntries(in: data) {
            let payload = try payload(for: entry, in: data)
            let fileURL = destinationDir.appendingPathComponent(entry.name)
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: fileURL)
        }
    }

    private struct ZipEntry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private func zipEntries(in data: Data) throws -> [ZipEntry] {
        guard let directory = endOfCentralDirectory(in: data) else {
            throw ImportError.invalidFormat
        }
        var offset = directory.offset
        var entries: [ZipEntry] = []
        for _ in 0..<directory.entryCount {
            guard offset + 46 <= data.count,
                  readUInt32(data, at: offset) == 0x0201_4B50 else {
                throw ImportError.invalidFormat
            }
            let method = readUInt16(data, at: offset + 10)
            let compressedSize = Int(readUInt32(data, at: offset + 20))
            let uncompressedSize = Int(readUInt32(data, at: offset + 24))
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let headerOffset = Int(readUInt32(data, at: offset + 42))
            guard offset + 46 + nameLength <= data.count else {
                throw ImportError.invalidFormat
            }
            let start = data.startIndex + offset + 46
            let name = String(decoding: data[start..<(start + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength
            // Directory entries carry no payload, and nothing is written
            // outside the directory being extracted into.
            guard !name.hasSuffix("/"), isSafeArchivePath(name) else { continue }
            entries.append(ZipEntry(
                name: name,
                compressionMethod: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: headerOffset
            ))
        }
        return entries
    }

    private func payload(for entry: ZipEntry, in data: Data) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count,
              readUInt32(data, at: header) == 0x0403_4B50 else {
            throw ImportError.invalidFormat
        }
        let nameLength = Int(readUInt16(data, at: header + 26))
        let extraLength = Int(readUInt16(data, at: header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= end, end <= data.count else { throw ImportError.invalidFormat }
        let stored = data[(data.startIndex + start)..<(data.startIndex + end)]

        switch entry.compressionMethod {
        case 0:
            return Data(stored)
        case 8:
            return try decompressDeflate(Data(stored), expectedSize: entry.uncompressedSize)
        default:
            throw ImportError.invalidFormat
        }
    }

    private func endOfCentralDirectory(
        in data: Data
    ) -> (entryCount: Int, offset: Int)? {
        guard data.count >= 22 else { return nil }
        let earliest = max(0, data.count - 22 - 0xFFFF)
        var offset = data.count - 22
        while offset >= earliest {
            if readUInt32(data, at: offset) == 0x0605_4B50 {
                return (
                    Int(readUInt16(data, at: offset + 10)),
                    Int(readUInt32(data, at: offset + 16))
                )
            }
            offset -= 1
        }
        return nil
    }

    /// Nothing absolute, and nothing that climbs out of the directory it is
    /// being written into.
    private func isSafeArchivePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/").contains("..")
    }

    private func readByte(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[data.startIndex + index])
    }

    private func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(readByte(data, at: index) | (readByte(data, at: index + 1) << 8))
    }

    private func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        readByte(data, at: index)
            | (readByte(data, at: index + 1) << 8)
            | (readByte(data, at: index + 2) << 16)
            | (readByte(data, at: index + 3) << 24)
    }

    /// Decompress DEFLATE data using Compression framework
    private func decompressDeflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        // Use Compression framework
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = compressedData.withUnsafeBytes { sourcePtr -> Int in
            guard let sourceBaseAddress = sourcePtr.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                expectedSize,
                sourceBaseAddress.assumingMemoryBound(to: UInt8.self),
                compressedData.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw ImportError.invalidFormat
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }


    // MARK: - Errors

    enum ImportError: LocalizedError {
        case invalidFormat
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                return "The file format is not recognized"
            case .fileNotFound:
                return "File not found"
            }
        }
    }
}

// MARK: - Share Data Wrapper

/// Wrapper for shared devotional data with metadata
struct DevotionalShareData: Codable {
    let version: Int
    let exportDate: Date
    let devotional: Devotional
}

/// Manifest for bundled .lamp files
struct BundleManifest: Codable {
    let version: Int
    let type: String
}

// MARK: - File Format

/// Format of a .lamp file
enum LampFileFormat {
    case plainJSON      // v1: Just JSON
    case bundle         // v2: ZIP with media
}

// MARK: - File Preview

/// Type of content in a .lamp file
enum LampFileType {
    case devotional
    case devotionalBundle   // Devotional with embedded media
    case devotionalModule
    case unknown

    var displayName: String {
        switch self {
        case .devotional: return "Devotional"
        case .devotionalBundle: return "Devotional with Media"
        case .devotionalModule: return "Devotional Collection"
        case .unknown: return "Unknown"
        }
    }

    var iconName: String {
        switch self {
        case .devotional: return "doc.text"
        case .devotionalBundle: return "doc.richtext"
        case .devotionalModule: return "doc.on.doc"
        case .unknown: return "doc.questionmark"
        }
    }
}

/// Preview of a .lamp file contents for confirmation UI
struct LampFilePreview {
    let type: LampFileType
    var devotional: Devotional?
    var moduleFile: DevotionalModuleFile?
    var exportDate: Date?
    var mediaCount: Int?  // For bundles

    var title: String {
        switch type {
        case .devotional, .devotionalBundle:
            return devotional?.meta.title ?? "Untitled"
        case .devotionalModule:
            return moduleFile?.name ?? "Untitled Collection"
        case .unknown:
            return "Unknown Content"
        }
    }

    var subtitle: String? {
        switch type {
        case .devotional:
            return devotional?.meta.subtitle
        case .devotionalBundle:
            var parts: [String] = []
            if let subtitle = devotional?.meta.subtitle {
                parts.append(subtitle)
            }
            if let count = mediaCount, count > 0 {
                parts.append("\(count) media file\(count == 1 ? "" : "s")")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        case .devotionalModule:
            if let count = moduleFile?.entries.count {
                return "\(count) devotional\(count == 1 ? "" : "s")"
            }
            return nil
        case .unknown:
            return nil
        }
    }

    var author: String? {
        switch type {
        case .devotional, .devotionalBundle:
            return devotional?.meta.author
        case .devotionalModule:
            return moduleFile?.author
        case .unknown:
            return nil
        }
    }

    var date: String? {
        devotional?.meta.date
    }

    var category: DevotionalCategory? {
        devotional?.meta.category
    }

    var tags: [String]? {
        devotional?.meta.tags
    }

    var hasMedia: Bool {
        type == .devotionalBundle || (mediaCount ?? 0) > 0
    }

    /// How many devotionals this file will import. A collection imports all of its
    /// entries, so this is what callers should use to decide whether a file holds
    /// anything importable.
    var devotionalCount: Int {
        if let moduleFile = moduleFile {
            return moduleFile.entries.count
        }
        return devotional != nil ? 1 : 0
    }

    var exportDateFormatted: String? {
        guard let date = exportDate else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - UTType for .lamp files

// MARK: - ZIP primitives

/// The checksum every ZIP entry carries. Written so an archive from this app
/// is a real ZIP that other tools accept, not only one this app can read.
private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in
            value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        appendLittleEndian(UInt16(truncatingIfNeeded: value))
        appendLittleEndian(UInt16(truncatingIfNeeded: value >> 16))
    }
}

extension UTType {
    static var lampFile: UTType {
        UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data)
    }
}
