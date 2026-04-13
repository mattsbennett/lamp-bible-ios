//
//  HighlightImportExportManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import Foundation
import GRDB
import Compression

/// Manages import/export of highlight sets as .lamp files (zlib-compressed SQLite)
class HighlightImportExportManager {
    static let shared = HighlightImportExportManager()

    private let fileManager = FileManager.default
    private let moduleStorage = ICloudModuleStorage.shared

    // MARK: - Export

    /// Export a highlight set to a .lamp file
    /// Returns the URL of the exported file
    func exportHighlightSet(setId: String) throws -> URL {
        // Get highlight set metadata
        guard let highlightSet = try ModuleDatabase.shared.getHighlightSet(id: setId) else {
            throw HighlightExportError.setNotFound
        }

        // Get all highlights for the set
        let highlights = try ModuleDatabase.shared.getAllHighlights(setId: setId)

        // Get all themes for the set
        let themes = try ModuleDatabase.shared.getHighlightThemes(setId: setId)

        // Create temporary SQLite database
        let tempDbUrl = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")

        defer {
            try? fileManager.removeItem(at: tempDbUrl)
        }

        // Create and populate SQLite database
        try createExportDatabase(at: tempDbUrl, set: highlightSet, highlights: highlights, themes: themes)

        // Read database file and compress
        let dbData = try Data(contentsOf: tempDbUrl)
        let compressedData = try compress(data: dbData)

        // Write to export directory
        guard let exportDir = moduleStorage.directoryURL(for: ModuleType.highlights) else {
            throw HighlightExportError.compressionFailed
        }
        try fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let exportUrl = exportDir.appendingPathComponent("\(highlightSet.id).lamp")
        try compressedData.write(to: exportUrl)

        // Update module file_path
        if var module = try ModuleDatabase.shared.getModule(id: highlightSet.moduleId) {
            module.filePath = "\(highlightSet.id).lamp"
            module.fileHash = compressedData.sha256Hash
            module.lastSynced = Int(Date().timeIntervalSince1970)
            try ModuleDatabase.shared.saveModule(module)
        }

        return exportUrl
    }

    private func createExportDatabase(at url: URL, set: HighlightSet, highlights: [HighlightEntry], themes: [HighlightTheme]) throws {
        // Remove if exists
        try? fileManager.removeItem(at: url)

        var config = Configuration()
        let dbQueue = try DatabaseQueue(path: url.path, configuration: config)

        try dbQueue.write { db in
            // Create highlight_meta table (matches schema from plan)
            try db.execute(sql: """
                CREATE TABLE highlight_meta (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT,
                    translation_id TEXT NOT NULL,
                    created INTEGER,
                    last_modified INTEGER
                )
            """)

            // Create highlights table
            try db.execute(sql: """
                CREATE TABLE highlights (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ref INTEGER NOT NULL,
                    sc INTEGER NOT NULL,
                    ec INTEGER NOT NULL,
                    style INTEGER DEFAULT 0,
                    color TEXT
                )
            """)

            // Create highlight_themes table
            try db.execute(sql: """
                CREATE TABLE highlight_themes (
                    color TEXT NOT NULL,
                    style INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    PRIMARY KEY (color, style)
                )
            """)

            // Insert metadata
            try db.execute(
                sql: """
                    INSERT INTO highlight_meta (id, name, description, translation_id, created, last_modified)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [set.id, set.name, set.description, set.translationId, set.created, set.lastModified]
            )

            // Insert highlights
            for highlight in highlights {
                try db.execute(
                    sql: "INSERT INTO highlights (ref, sc, ec, style, color) VALUES (?, ?, ?, ?, ?)",
                    arguments: [highlight.ref, highlight.sc, highlight.ec, highlight.style, highlight.color]
                )
            }

            // Insert themes
            for theme in themes {
                try db.execute(
                    sql: "INSERT INTO highlight_themes (color, style, name, description) VALUES (?, ?, ?, ?)",
                    arguments: [theme.color, theme.style, theme.name, theme.themeDescription]
                )
            }
        }
    }

    // MARK: - Import

    /// Import a highlight file and return the imported set
    func importHighlightFile(at url: URL) throws -> HighlightSet {
        // Read and decompress
        let compressedData = try Data(contentsOf: url)
        let dbData = try decompress(data: compressedData)

        // Write to temporary database file
        let tempDbUrl = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")

        defer {
            try? fileManager.removeItem(at: tempDbUrl)
        }

        try dbData.write(to: tempDbUrl)

        // Read metadata and highlights from import database
        var config = Configuration()
        config.readonly = true
        let dbQueue = try DatabaseQueue(path: tempDbUrl.path, configuration: config)

        let (setData, highlightData, themeData) = try dbQueue.read { db -> (HighlightSetData, [HighlightEntryData], [HighlightThemeData]) in
            // Read metadata
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM highlight_meta LIMIT 1") else {
                throw HighlightImportError.invalidFormat
            }

            let setData = HighlightSetData(
                id: row["id"],
                name: row["name"],
                description: row["description"],
                translationId: row["translation_id"],
                created: row["created"],
                lastModified: row["last_modified"]
            )

            // Read highlights
            let highlightRows = try Row.fetchAll(db, sql: "SELECT * FROM highlights")
            let highlights = highlightRows.map { row -> HighlightEntryData in
                HighlightEntryData(
                    ref: row["ref"],
                    sc: row["sc"],
                    ec: row["ec"],
                    style: row["style"],
                    color: row["color"]
                )
            }

            // Read themes (table may not exist in older exports)
            var themes: [HighlightThemeData] = []
            let tableExists = try Row.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='highlight_themes'") != nil
            if tableExists {
                let themeRows = try Row.fetchAll(db, sql: "SELECT * FROM highlight_themes")
                themes = themeRows.map { row -> HighlightThemeData in
                    HighlightThemeData(
                        color: row["color"],
                        style: row["style"],
                        name: row["name"],
                        description: row["description"]
                    )
                }
            }

            return (setData, highlights, themes)
        }

        // Check if set already exists
        if let existingSet = try ModuleDatabase.shared.getHighlightSet(id: setData.id) {
            // Delete existing and re-import
            try ModuleDatabase.shared.deleteHighlightSet(id: existingSet.id)
            try ModuleDatabase.shared.deleteModule(id: existingSet.moduleId)
        }

        // Create module
        let moduleId = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)

        let module = Module(
            id: moduleId,
            type: ModuleType.highlights,
            name: setData.name,
            description: setData.description,
            author: nil,
            version: nil,
            filePath: url.lastPathComponent,
            fileHash: compressedData.sha256Hash,
            lastSynced: now,
            isEditable: true,
            keyType: nil,
            seriesFull: nil,
            seriesAbbrev: nil,
            seriesId: nil,
            createdAt: now,
            updatedAt: now
        )

        try ModuleDatabase.shared.saveModule(module)

        // Create highlight set
        let highlightSet = HighlightSet(
            id: setData.id,
            moduleId: moduleId,
            name: setData.name,
            description: setData.description,
            translationId: setData.translationId,
            created: setData.created ?? now,
            lastModified: setData.lastModified ?? now
        )

        try ModuleDatabase.shared.saveHighlightSet(highlightSet)

        // Import highlights
        let entries = highlightData.map { data -> HighlightEntry in
            HighlightEntry(
                setId: highlightSet.id,
                ref: data.ref,
                sc: data.sc,
                ec: data.ec,
                style: HighlightStyle(rawValue: data.style ?? 0) ?? .highlight,
                color: data.color.map { HighlightColor(hex: $0) }
            )
        }

        try ModuleDatabase.shared.importHighlights(entries)

        // Import themes
        if !themeData.isEmpty {
            let themes = themeData.map { data -> HighlightTheme in
                HighlightTheme(
                    setId: highlightSet.id,
                    color: data.color,
                    style: data.style,
                    name: data.name,
                    description: data.description
                )
            }
            try ModuleDatabase.shared.importHighlightThemes(themes)
        }

        // Copy file to module directory
        if let destDir = moduleStorage.directoryURL(for: ModuleType.highlights) {
            let destUrl = destDir.appendingPathComponent(url.lastPathComponent)
            try? fileManager.removeItem(at: destUrl)
            try fileManager.copyItem(at: url, to: destUrl)
        }

        return highlightSet
    }

    // MARK: - Compression

    private func compress(data: Data) throws -> Data {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourceBytes -> Int in
            guard let sourcePointer = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_encode_buffer(
                destinationBuffer,
                data.count,
                sourcePointer,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else {
            throw HighlightExportError.compressionFailed
        }

        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    private func decompress(data: Data) throws -> Data {
        // Estimate decompressed size (start with 10x)
        var destinationSize = data.count * 10
        var destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)

        defer { destinationBuffer.deallocate() }

        var decompressedSize = data.withUnsafeBytes { sourceBytes -> Int in
            guard let sourcePointer = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                destinationSize,
                sourcePointer,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        // If buffer was too small, retry with larger buffer
        if decompressedSize == 0 || decompressedSize >= destinationSize {
            destinationBuffer.deallocate()
            destinationSize = data.count * 50
            destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationSize)

            decompressedSize = data.withUnsafeBytes { sourceBytes -> Int in
                guard let sourcePointer = sourceBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBuffer,
                    destinationSize,
                    sourcePointer,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decompressedSize > 0 else {
            throw HighlightImportError.decompressionFailed
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}

// MARK: - Internal Data Types

private struct HighlightSetData {
    let id: String
    let name: String
    let description: String?
    let translationId: String
    let created: Int?
    let lastModified: Int?
}

private struct HighlightEntryData {
    let ref: Int
    let sc: Int
    let ec: Int
    let style: Int?
    let color: String?
}

private struct HighlightThemeData {
    let color: String
    let style: Int
    let name: String
    let description: String?
}

// MARK: - Errors

enum HighlightExportError: LocalizedError {
    case setNotFound
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .setNotFound:
            return "Highlight set not found."
        case .compressionFailed:
            return "Failed to compress highlight data."
        }
    }
}

enum HighlightImportError: LocalizedError {
    case invalidFormat
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid highlight file format."
        case .decompressionFailed:
            return "Failed to decompress highlight data."
        }
    }
}

// MARK: - Data Extension

private extension Data {
    var sha256Hash: String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(self.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// CommonCrypto import for SHA256
import CommonCrypto
