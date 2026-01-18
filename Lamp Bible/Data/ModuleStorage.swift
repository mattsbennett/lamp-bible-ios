//
//  ModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation

// MARK: - Module Storage Errors

enum ModuleStorageError: Error, LocalizedError {
    case notAvailable
    case fileNotFound(String)
    case invalidData
    case encodingFailed
    case decodingFailed
    case directoryCreationFailed
    case fileCoordinationFailed
    case hashCalculationFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Module storage is not available"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidData:
            return "Invalid data format"
        case .encodingFailed:
            return "Failed to encode data"
        case .decodingFailed:
            return "Failed to decode data"
        case .directoryCreationFailed:
            return "Failed to create directory"
        case .fileCoordinationFailed:
            return "File coordination failed"
        case .hashCalculationFailed:
            return "Failed to calculate file hash"
        }
    }
}

// MARK: - Module File Info

struct ModuleFileInfo {
    let id: String
    let type: ModuleType
    let filePath: String
    let fileHash: String?
    let modificationDate: Date?
}

// MARK: - Sync Status

/// Status of a file's sync state with the cloud backend
enum ModuleSyncStatus: Equatable {
    case synced
    case syncing
    case notSynced
    case notAvailable
}

// MARK: - Module Storage Protocol

protocol ModuleStorage {
    /// Check if storage is available
    func isAvailable() async -> Bool

    /// List all module files in the given directory
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo]

    /// Read module file data
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data

    /// Write module file data
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws

    /// Delete module file
    func deleteModuleFile(type: ModuleType, fileName: String) async throws

    /// Get file hash for change detection
    func getFileHash(type: ModuleType, fileName: String) async throws -> String?

    /// Get file modification date
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date?

    /// Ensure directory exists for module type
    func ensureDirectoryExists(type: ModuleType) async throws

    /// Get directory URL for module type
    func directoryURL(for type: ModuleType) -> URL?

    /// Get sync status for a specific file
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus
}

// MARK: - Module Storage Extensions

extension ModuleStorage {
    /// Read and decode a module JSON file
    func readModuleJSON<T: Decodable>(type: ModuleType, fileName: String, as: T.Type) async throws -> T {
        let data = try await readModuleFile(type: type, fileName: fileName)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ModuleStorageError.decodingFailed
        }
    }

    /// Encode and write a module JSON file
    func writeModuleJSON<T: Encodable>(type: ModuleType, fileName: String, value: T) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            try await writeModuleFile(type: type, fileName: fileName, data: data)
        } catch is EncodingError {
            throw ModuleStorageError.encodingFailed
        }
    }

    /// Directory name for each module type
    func directoryName(for type: ModuleType) -> String {
        switch type {
        case .translation:
            return "Translations"
        case .dictionary:
            return "Dictionaries"
        case .commentary:
            return "Commentaries"
        case .devotional:
            return "Devotionals"
        case .notes:
            return "Notes"
        case .plan:
            return "Plans"
        }
    }

    /// Initialize the full directory structure for all module types
    /// Creates: /LampBible/Notes/, /LampBible/Translations/, etc.
    func initializeDirectoryStructure() async throws {
        for type in ModuleType.allCases {
            try await ensureDirectoryExists(type: type)
        }
    }
}
