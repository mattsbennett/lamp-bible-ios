//
//  SyncTypes.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation

// MARK: - Sync Backend

/// Available sync backend options
enum SyncBackend: String, Codable, CaseIterable {
    case icloudDrive = "icloud"
    case webdav = "webdav"
    case none = "none"

    var displayName: String {
        switch self {
        case .icloudDrive: return "iCloud Drive"
        case .webdav: return "WebDAV"
        case .none: return "Local Only"
        }
    }

    var description: String {
        switch self {
        case .icloudDrive:
            return "Sync via iCloud Drive. Files visible in Files app."
        case .webdav:
            return "Sync to your own server (Synology, Nextcloud, ownCloud, etc.)"
        case .none:
            return "No cloud sync. Data stays on this device."
        }
    }
}

// MARK: - Sync Settings

/// User's sync configuration
struct SyncSettings: Codable {
    var backend: SyncBackend
    var webdavURL: String?
    var webdavUsername: String?
    // Password stored in Keychain, not here
    var lastSyncDate: Date?
    var lastEditableSyncDate: Date?
    var lastModuleSyncDate: Date?

    init(
        backend: SyncBackend = .none,
        webdavURL: String? = nil,
        webdavUsername: String? = nil,
        lastSyncDate: Date? = nil,
        lastEditableSyncDate: Date? = nil,
        lastModuleSyncDate: Date? = nil
    ) {
        self.backend = backend
        self.webdavURL = webdavURL
        self.webdavUsername = webdavUsername
        self.lastSyncDate = lastSyncDate
        self.lastEditableSyncDate = lastEditableSyncDate
        self.lastModuleSyncDate = lastModuleSyncDate
    }

    static var `default`: SyncSettings {
        SyncSettings(backend: .none)
    }
}

// MARK: - Sync State

/// Current state of sync operation
enum SyncState: Equatable {
    case idle
    case syncing(progress: Double?)
    case error(SyncError)

    static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.syncing(let p1), .syncing(let p2)):
            return p1 == p2
        case (.error(let e1), .error(let e2)):
            return e1.localizedDescription == e2.localizedDescription
        default:
            return false
        }
    }
}

// MARK: - Sync Error

/// Errors that can occur during sync
enum SyncError: Error, LocalizedError {
    case notAvailable
    case notConfigured
    case authenticationFailed
    case networkError(Error)
    case serverError(Int, String?)
    case conflictDetected
    case encodingFailed
    case decodingFailed
    case recordNotFound(String)
    case quotaExceeded
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Sync service is not available"
        case .notConfigured:
            return "Sync is not configured"
        case .authenticationFailed:
            return "Authentication failed"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code): \(message ?? "Unknown")"
        case .conflictDetected:
            return "Conflict detected during sync"
        case .encodingFailed:
            return "Failed to encode data"
        case .decodingFailed:
            return "Failed to decode data"
        case .recordNotFound(let id):
            return "Record not found: \(id)"
        case .quotaExceeded:
            return "Storage quota exceeded"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Syncable Entry Type

/// Types of entries that can be synced via CloudKit
enum SyncableEntryType: String, CaseIterable, Codable {
    case note
    case devotional

    var recordTypeName: String {
        switch self {
        case .note: return "NoteRecord"
        case .devotional: return "DevotionalRecord"
        }
    }
}

// MARK: - Sync Changeset

/// Changes fetched from remote sync provider
struct SyncChangeset {
    var upsertedNotes: [NoteEntry]
    var deletedNoteIds: [String]
    var upsertedDevotionals: [DevotionalEntry]
    var deletedDevotionalIds: [String]
    var conflicts: [AnySyncConflict]

    init(
        upsertedNotes: [NoteEntry] = [],
        deletedNoteIds: [String] = [],
        upsertedDevotionals: [DevotionalEntry] = [],
        deletedDevotionalIds: [String] = [],
        conflicts: [AnySyncConflict] = []
    ) {
        self.upsertedNotes = upsertedNotes
        self.deletedNoteIds = deletedNoteIds
        self.upsertedDevotionals = upsertedDevotionals
        self.deletedDevotionalIds = deletedDevotionalIds
        self.conflicts = conflicts
    }

    var isEmpty: Bool {
        upsertedNotes.isEmpty &&
        deletedNoteIds.isEmpty &&
        upsertedDevotionals.isEmpty &&
        deletedDevotionalIds.isEmpty &&
        conflicts.isEmpty
    }

    var hasConflicts: Bool {
        !conflicts.isEmpty
    }

    var totalChanges: Int {
        upsertedNotes.count +
        deletedNoteIds.count +
        upsertedDevotionals.count +
        deletedDevotionalIds.count
    }
}

// MARK: - Sync Conflict

/// A conflict between local and remote versions of an entry
struct SyncConflict<T: SyncableEntry>: Identifiable {
    let id: String
    let localEntry: T
    let remoteEntry: T
    let localModified: Date
    let remoteModified: Date

    init(id: String, localEntry: T, remoteEntry: T, localModified: Date, remoteModified: Date) {
        self.id = id
        self.localEntry = localEntry
        self.remoteEntry = remoteEntry
        self.localModified = localModified
        self.remoteModified = remoteModified
    }
}

/// Type-erased sync conflict for storage in arrays
struct AnySyncConflict: Identifiable {
    let id: String
    let entryType: SyncableEntryType
    let localModified: Date
    let remoteModified: Date

    // Store the actual entries as Any
    private let _localEntry: Any
    private let _remoteEntry: Any

    init<T: SyncableEntry>(_ conflict: SyncConflict<T>) {
        self.id = conflict.id
        self.entryType = T.entryType
        self.localModified = conflict.localModified
        self.remoteModified = conflict.remoteModified
        self._localEntry = conflict.localEntry
        self._remoteEntry = conflict.remoteEntry
    }

    func typed<T: SyncableEntry>() -> SyncConflict<T>? {
        guard let local = _localEntry as? T,
              let remote = _remoteEntry as? T else {
            return nil
        }
        return SyncConflict(
            id: id,
            localEntry: local,
            remoteEntry: remote,
            localModified: localModified,
            remoteModified: remoteModified
        )
    }
}

// Note: ConflictResolution is defined in NoteStorage.swift
