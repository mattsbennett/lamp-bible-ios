//
//  SyncProvider.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation

// MARK: - Module Sync Provider

/// Protocol for file-based sync providers (iCloud Documents, WebDAV).
/// This is a typealias for the existing ModuleStorage protocol.
///
/// Both ICloudModuleStorage and WebDAVModuleStorage implement this protocol,
/// allowing the SyncCoordinator to switch between backends transparently.
typealias ModuleSyncProvider = ModuleStorage

// MARK: - Editable Sync Provider (Future CloudKit Support)

/// Protocol for per-record sync providers (future CloudKit implementation).
/// This is not currently used but is defined here to allow CloudKit to be
/// added in the future without major refactoring.
///
/// When CloudKit is implemented, it would conform to this protocol for
/// syncing notes and devotionals as individual records rather than files.
protocol EditableSyncProvider: AnyObject {
    /// Unique identifier for this provider
    var id: String { get }

    /// Human-readable name for display
    var displayName: String { get }

    /// Check if the provider is available and configured
    var isAvailable: Bool { get async }

    /// Current sync state
    var syncState: SyncState { get }

    /// Date of last successful sync
    var lastSyncDate: Date? { get }

    // MARK: - Lifecycle

    /// Configure the provider with settings
    func configure(with settings: SyncSettings) async throws

    /// Perform a full sync operation
    func performSync() async throws

    // MARK: - Entry Operations

    /// Save an entry to the remote store
    func saveEntry(_ entry: any SyncableEntry) async throws

    /// Delete an entry from the remote store
    func deleteEntry(id: String, type: SyncableEntryType) async throws

    /// Fetch changes since the given date (or all if nil)
    func fetchChanges(since: Date?) async throws -> SyncChangeset

    // MARK: - Conflict Handling

    /// Resolve a conflict with the given resolution
    func resolveConflict<T: SyncableEntry>(_ conflict: SyncConflict<T>, resolution: ConflictResolution) async throws
}

// MARK: - Module Type Extensions

extension ModuleType {
    /// Module types that contain user-editable content
    static var editableCases: [ModuleType] {
        [.notes, .devotional]
    }

    /// Module types that are read-only
    static var readOnlyCases: [ModuleType] {
        [.translation, .dictionary, .commentary, .plan]
    }

    /// Whether this module type contains user-editable content
    var isEditable: Bool {
        self == .notes || self == .devotional
    }
}
