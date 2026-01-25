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

            // Configure for iPad
            if let sourceView = sourceView {
                activityVC.popoverPresentationController?.sourceView = sourceView
                activityVC.popoverPresentationController?.sourceRect = sourceView.bounds
            }

            // Get the presenting view controller
            let presenter = viewController ?? getRootViewController()
            presenter?.present(activityVC, animated: true)

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

        // Try markdown
        if let content = String(data: data, encoding: .utf8),
           let devotional = MarkdownDevotionalConverter.parseMarkdown(content) {
            return LampFilePreview(type: .devotional, devotional: devotional)
        }

        throw ImportError.invalidFormat
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
        let devotionalURL = tempDir.appendingPathComponent("devotional.json")
        let data = try Data(contentsOf: devotionalURL)
        let shareData = try JSONDecoder().decode(DevotionalShareData.self, from: data)

        // Count media files
        let mediaDir = tempDir.appendingPathComponent("media")
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

    /// Import a devotional from a .lamp file (handles both JSON and bundle formats)
    func importFromFile(_ fileURL: URL, moduleId: String = "devotionals") throws -> Devotional {
        let format = detectFileFormat(fileURL)

        switch format {
        case .bundle:
            return try importFromBundle(fileURL, moduleId: moduleId)
        case .plainJSON:
            return try importFromJSON(fileURL)
        }
    }

    /// Import from plain JSON .lamp file
    private func importFromJSON(_ fileURL: URL) throws -> Devotional {
        let data = try Data(contentsOf: fileURL)

        // Try to decode as DevotionalShareData first
        if let shareData = try? JSONDecoder().decode(DevotionalShareData.self, from: data) {
            return shareData.devotional
        }

        // Try as raw Devotional
        if let devotional = try? JSONDecoder().decode(Devotional.self, from: data) {
            return devotional
        }

        // Try as DevotionalModuleFile (for backwards compatibility)
        if let moduleFile = try? JSONDecoder().decode(DevotionalModuleFile.self, from: data),
           let first = moduleFile.entries.first {
            return first
        }

        throw ImportError.invalidFormat
    }

    /// Import from bundled .lamp file (ZIP with media)
    private func importFromBundle(_ fileURL: URL, moduleId: String) throws -> Devotional {
        // Extract to temp directory
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Unzip using native API
        try extractZipArchive(from: fileURL, to: tempDir)

        // Read devotional.json
        let devotionalURL = tempDir.appendingPathComponent("devotional.json")
        let data = try Data(contentsOf: devotionalURL)
        let shareData = try JSONDecoder().decode(DevotionalShareData.self, from: data)
        var devotional = shareData.devotional

        // Generate new ID
        let newId = UUID().uuidString
        devotional.meta.id = newId
        devotional.meta.created = Int(Date().timeIntervalSince1970)
        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        // Import media files
        let sourceMediaDir = tempDir.appendingPathComponent("media")
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
        return devotional
    }

    /// Import and save a devotional to the database
    func importAndSave(_ fileURL: URL, moduleId: String = "devotionals") throws -> Devotional {
        let devotional: Devotional

        if fileURL.pathExtension.lowercased() == "md" {
            devotional = try importFromMarkdown(fileURL)
        } else {
            devotional = try importFromFile(fileURL, moduleId: moduleId)
        }

        // Generate a new ID to avoid conflicts (if not already done by bundle import)
        var imported = devotional
        if imported.meta.created == nil || imported.meta.created == 0 {
            imported.meta.id = UUID().uuidString
            imported.meta.created = Int(Date().timeIntervalSince1970)
            imported.meta.lastModified = Int(Date().timeIntervalSince1970)
        }

        // Save to database
        try DevotionalStorage.shared.saveDevotional(imported, moduleId: moduleId)

        return imported
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
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            return nil
        }
        return window.rootViewController
    }

    // MARK: - ZIP Archive Helpers

    /// Create a ZIP archive from a directory using Process and the zip command
    private func createZipArchive(from sourceDir: URL, to destinationURL: URL) throws {
        // Use NSFileCoordinator-based approach for creating ZIP
        let coordinator = NSFileCoordinator()
        var error: NSError?

        coordinator.coordinate(readingItemAt: sourceDir, options: [.forUploading], error: &error) { zipURL in
            do {
                // The system creates a temporary ZIP at zipURL, copy it to destination
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: zipURL, to: destinationURL)
            } catch {
                print("[DevotionalSharingManager] Failed to create ZIP: \(error)")
            }
        }

        if let error = error {
            throw error
        }
    }

    /// Extract a ZIP archive to a directory
    private func extractZipArchive(from zipURL: URL, to destinationDir: URL) throws {
        // Use NSFileCoordinator for unzipping
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        // First, copy to a .zip extension file (required for NSFileCoordinator to recognize it)
        let tempZipURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try fileManager.copyItem(at: zipURL, to: tempZipURL)

        defer {
            try? fileManager.removeItem(at: tempZipURL)
        }

        coordinator.coordinate(readingItemAt: tempZipURL, options: [.forUploading], error: &coordinatorError) { _ in
            // This doesn't actually help us extract - we need a different approach
        }

        // Use a manual approach: read the ZIP file and extract using Foundation
        // For iOS 16+, we can use the built-in Archive handling
        if #available(iOS 16.0, *) {
            try extractUsingFileManager(from: tempZipURL, to: destinationDir)
        } else {
            // Fallback for older iOS - use a simpler approach
            try extractUsingFileManager(from: tempZipURL, to: destinationDir)
        }
    }

    /// Extract ZIP using FileManager's built-in capabilities (requires copying from iCloud or similar)
    private func extractUsingFileManager(from zipURL: URL, to destinationDir: URL) throws {
        // Unfortunately, iOS doesn't have a built-in ZIP extraction API in Foundation
        // We'll use a minimal ZIP extraction implementation

        let data = try Data(contentsOf: zipURL)
        try extractZipData(data, to: destinationDir)
    }

    /// Minimal ZIP extraction - extracts files from ZIP data
    /// Supports basic ZIP format (no compression or DEFLATE)
    private func extractZipData(_ data: Data, to destinationDir: URL) throws {
        var offset = 0

        while offset < data.count - 4 {
            // Look for local file header signature (PK\x03\x04)
            guard data[offset] == 0x50, data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
                // Not a local file header, might be central directory
                break
            }

            // Parse local file header
            let compressionMethod = UInt16(data[offset + 8]) | (UInt16(data[offset + 9]) << 8)
            let compressedSize = UInt32(data[offset + 18]) | (UInt32(data[offset + 19]) << 8) |
                                (UInt32(data[offset + 20]) << 16) | (UInt32(data[offset + 21]) << 24)
            let uncompressedSize = UInt32(data[offset + 22]) | (UInt32(data[offset + 23]) << 8) |
                                  (UInt32(data[offset + 24]) << 16) | (UInt32(data[offset + 25]) << 24)
            let fileNameLength = Int(UInt16(data[offset + 26]) | (UInt16(data[offset + 27]) << 8))
            let extraFieldLength = Int(UInt16(data[offset + 28]) | (UInt16(data[offset + 29]) << 8))

            // Get filename
            let fileNameStart = offset + 30
            let fileNameData = data[fileNameStart..<(fileNameStart + fileNameLength)]
            guard let fileName = String(data: fileNameData, encoding: .utf8) else {
                offset += 30 + fileNameLength + extraFieldLength + Int(compressedSize)
                continue
            }

            // Skip directories (end with /)
            if fileName.hasSuffix("/") {
                let dirURL = destinationDir.appendingPathComponent(fileName)
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
                offset += 30 + fileNameLength + extraFieldLength + Int(compressedSize)
                continue
            }

            // Get file data
            let fileDataStart = fileNameStart + fileNameLength + extraFieldLength
            let fileDataEnd = fileDataStart + Int(compressedSize)

            guard fileDataEnd <= data.count else {
                throw ImportError.invalidFormat
            }

            var fileData = data[fileDataStart..<fileDataEnd]

            // Handle compression
            if compressionMethod == 8 {
                // DEFLATE compression - decompress using zlib
                fileData = try decompressDeflate(Data(fileData), expectedSize: Int(uncompressedSize))
            } else if compressionMethod != 0 {
                // Unsupported compression method
                print("[DevotionalSharingManager] Unsupported compression method: \(compressionMethod) for \(fileName)")
                offset = fileDataEnd
                continue
            }

            // Write file
            let fileURL = destinationDir.appendingPathComponent(fileName)
            let parentDir = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fileData.write(to: fileURL)

            offset = fileDataEnd
        }
    }

    /// Decompress DEFLATE data using Compression framework
    private func decompressDeflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
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

    var exportDateFormatted: String? {
        guard let date = exportDate else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - UTType for .lamp files

extension UTType {
    static var lampFile: UTType {
        UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .json)
    }
}
