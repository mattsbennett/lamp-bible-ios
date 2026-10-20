//
//  ModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import LampModuleKit

// MARK: - Module Storage Errors

enum ModuleStorageError: Error, LocalizedError {
    case notAvailable
    case fileNotFound(String)
    case invalidData
    case encodingFailed
    case decodingFailed
    case directoryCreationFailed
    case fileCoordinationFailed
    case unresolvedVersions
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
        case .unresolvedVersions:
            return "The iCloud file has conflicting versions that need resolution"
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

// MARK: - Stored File Listing

/// One regular file inside a listed directory. Used for content the app reads
/// by path rather than by module type, such as published presentation decks.
struct StoredFileListing {
    let name: String
    let modificationDate: Date?
    /// Bytes, where the provider says.
    var size: Int64? = nil
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

/// What the app asks of a sync provider beside the library pass, which goes
/// through `LampSyncRemoteStore`: whether it is there, its folder names, the
/// files an attachment or a deck is read from, and how an iCloud file stands.
protocol ModuleStorage {
    /// Check if storage is available
    func isAvailable() async -> Bool

    /// Get directory URL for module type
    func directoryURL(for type: ModuleType) -> URL?

    /// Get sync status for a specific file
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus

    /// Read file at arbitrary path (relative to base storage)
    func readFile(path: String) async throws -> Data

    /// Regular files directly inside `path`, relative to base storage.
    /// A directory that does not exist lists as empty rather than throwing, so
    /// optional shared content can be polled without a probe first.
    func listFiles(path: String) async throws -> [StoredFileListing]
}

// MARK: - Default Implementations

extension ModuleStorage {
    /// Backends that only serve module directories list nothing here. The two
    /// shipping backends both override this; the default keeps fixtures and
    /// future partial backends from having to care about shared content.
    func listFiles(path: String) async throws -> [StoredFileListing] { [] }
}

// MARK: - Module Storage Extensions

extension ModuleStorage {
    /// Directory name for each module type
    func directoryName(for type: ModuleType) -> String {
        switch type {
        case .translation:
            return LampSyncContentKind.translations.rawValue
        case .dictionary:
            return LampSyncContentKind.dictionaries.rawValue
        case .commentary:
            return LampSyncContentKind.commentaries.rawValue
        case .book:
            return LampSyncContentKind.books.rawValue
        case .devotional:
            return LampSyncContentKind.devotionals.rawValue
        case .notes:
            return LampSyncContentKind.notes.rawValue
        case .plan:
            return LampSyncContentKind.plans.rawValue
        case .highlights:
            return LampSyncContentKind.highlights.rawValue
        case .quiz:
            return LampSyncContentKind.quizzes.rawValue
        }
    }
}
