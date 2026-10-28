//
//  SyncCoordinator.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation
import Combine
import LampModuleKit

// MARK: - Sync Coordinator

/// Central coordinator for sync operations.
/// Manages sync backend selection (iCloud Drive or WebDAV) and delegates
/// actual sync work to ModuleSyncManager with the appropriate storage provider.
///
/// The abstraction layer is designed to allow CloudKit per-record sync to be
/// added in the future without major refactoring.
@MainActor
class SyncCoordinator: ObservableObject {
    // MARK: - Singleton

    static let shared = SyncCoordinator()

    // MARK: - Published State

    @Published private(set) var syncState: SyncState = .idle
    /// The library at the active endpoint was kept only by this device and
    /// can move to the new sync, once the person agrees. Nothing syncs until
    /// it has moved.
    @Published private(set) var libraryMovable = false
    /// Asking about the move now. Asked once a launch: after Not Now,
    /// Settings keeps the offer rather than every sync asking again.
    @Published var libraryMoveOffered = false
    private var libraryMoveAsked = false
    /// A device on a Lamp Bible older than 1.2.0 is still writing to a library
    /// that has moved to the new sync, and nothing it does is seen.
    @Published var olderDeviceSyncing = false
    /// The library at the active endpoint is still in the earlier shape, kept
    /// by a Mac that has not moved it yet. Nothing syncs until it does.
    @Published var libraryAwaitingMove = false
    /// Attachments the writings name that neither this device nor the server
    /// holds, by library path. Their writings sync all the same; on other
    /// devices these show as missing until the file is back here.
    @Published var unsuppliedAttachments: [String] = []
    @Published private(set) var settings: SyncSettings

    // MARK: - Storage Provider

    /// The active storage provider (iCloud Documents or WebDAV)
    private var storage: ModuleStorage?
    private var backendRecoveryError: Error?
    private var backendTransitionInProgress = false
    private var syncOperationInProgress = false

    struct SyncSession {
        let storage: ModuleStorage
        let backend: SyncBackend
    }

    // MARK: - Dependencies

    private let userDatabase = UserDatabase.shared

    // MARK: - Initialization

    private init() {
        var storedSettings = userDatabase.getSyncSettings()
        var pendingPreviousSettings: SyncSettings?
        var recoveryError: Error?
        do {
            pendingPreviousSettings = try ModuleDatabase.shared.pendingBackendTransition()
            if let pendingPreviousSettings {
                try userDatabase.saveSyncSettings(pendingPreviousSettings)
                try ModuleDatabase.shared.clearPendingBackendTransition()
                storedSettings = pendingPreviousSettings
            }
        } catch {
            recoveryError = error
            // A pending wipe did not commit. Keep the old provider selected in
            // memory and suspend sync until its durable choice is restored.
            storedSettings = pendingPreviousSettings ?? .default
            print("[SyncCoordinator] Backend recovery pending: \(error)")
        }
        let shouldInspectICloud = LegacySyncBackendResolver.requiresICloudInspection(
            storedSettings: storedSettings,
            isExistingInstallation: userDatabase.databaseExistedAtLaunch
        )
        let resolvedSettings = LegacySyncBackendResolver.resolve(
            storedSettings: storedSettings,
            iCloudContentState: shouldInspectICloud
                ? ICloudModuleStorage.shared.probeExistingContent()
                : .empty,
            isExistingInstallation: userDatabase.databaseExistedAtLaunch
        )
        self.settings = resolvedSettings
        self.backendRecoveryError = recoveryError

        // Persist the one-time resolution so future launches never reinterpret it.
        if recoveryError == nil && !(storedSettings?.backendSelectionWasExplicit ?? false) {
            do {
                try userDatabase.saveSyncSettings(resolvedSettings)
                print("[SyncCoordinator] Resolved legacy backend: \(resolvedSettings.backend)")
            } catch {
                print("[SyncCoordinator] Failed to persist resolved backend: \(error)")
            }
        }

        configureStorage()
    }

    // MARK: - Configuration

    /// Configure storage provider based on current settings
    func configureStorage() {
        guard backendRecoveryError == nil && !backendTransitionInProgress else {
            storage = nil
            return
        }
        switch settings.backend {
        case .icloudDrive:
            storage = ICloudModuleStorage.shared

        case .webdav:
            // Configure WebDAV storage with user settings
            if let urlString = settings.webdavURL,
               let baseURL = URL(string: urlString) {
                storage = WebDAVModuleStorage(
                    baseURL: baseURL,
                    username: settings.webdavUsername,
                    password: KeychainHelper.getWebDAVPassword()
                )
            } else {
                storage = nil
            }

        case .none:
            storage = nil
        }
    }

    private func recoverPendingBackendTransition() throws {
        do {
            if let previous = try ModuleDatabase.shared.pendingBackendTransition() {
                try userDatabase.saveSyncSettings(previous)
                try ModuleDatabase.shared.clearPendingBackendTransition()
                settings = previous
                backendRecoveryError = nil
                configureStorage()
            } else if let backendRecoveryError {
                guard let saved = userDatabase.getSyncSettings() else {
                    throw backendRecoveryError
                }
                settings = saved
                self.backendRecoveryError = nil
                configureStorage()
            }
        } catch {
            backendRecoveryError = error
            storage = nil
            throw error
        }
    }

    /// Switch to a new sync backend with option to migrate or wipe data.
    /// - Parameters:
    ///   - backend: The new backend to switch to
    ///   - migrateData: If true, migrate existing data to new backend. If false, wipe local data.
    /// - Note: The UI should confirm with the user before calling with migrateData=false
    func switchBackend(to backend: SyncBackend, migrateData: Bool) async throws {
        guard !backendTransitionInProgress && !syncOperationInProgress else {
            throw SyncError.backendTransitionInProgress
        }
        try recoverPendingBackendTransition()
        let previousBackend = settings.backend

        // No change needed
        if previousBackend == backend {
            return
        }

        backendTransitionInProgress = true
        defer {
            backendTransitionInProgress = false
            configureStorage()
        }

        do {
            // Nothing is copied between providers: this device holds its
            // library, and the first pass at the new endpoint publishes it
            // there, claiming an empty library or merging into the one there.
            // Copying files without their bundle left a library that read as
            // an earlier one waiting to move.
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: !migrateData,
                pullAndMerge: {},
                // Before anything here is wiped: the new endpoint must exist
                // and answer, or the switch stops with this device's data
                // untouched.
                publish: {
                    guard backend.usesRemoteStorage else { return }
                    guard let target = try self.createStorage(for: backend) else {
                        throw SyncError.notConfigured
                    }
                    guard await target.isAvailable() else { throw SyncError.notAvailable }
                },
                persistBackend: {
                    let previousSettings = self.settings
                    var selectedSettings = previousSettings
                    selectedSettings.backend = backend
                    selectedSettings.backendSelectionWasExplicit = true
                    selectedSettings.legacyICloudReconciliationPending = nil
                    if !migrateData {
                        try ModuleDatabase.shared.prepareBackendTransition(
                            previousSettings: previousSettings
                        )
                    }
                    // Keep the recovery record if persistence reports an
                    // error; the next attempt can restore the old choice even
                    // if the database commit outcome was uncertain.
                    try self.userDatabase.saveSyncSettings(selectedSettings)
                    return (previous: previousSettings, selected: selectedSettings)
                },
                wipeLocal: {
                    try ModuleDatabase.shared.wipeAllSyncableData()
                    try ModuleSyncManager.shared.reloadPendingModuleConflicts()
                },
                rollbackBackend: { selection in
                    try self.userDatabase.saveSyncSettings(selection.previous)
                    try ModuleDatabase.shared.clearPendingBackendTransition()
                },
                activateBackend: { selection in
                    self.settings = selection.selected
                    self.configureStorage()
                }
            )
        } catch {
            // A remaining record means the wipe never committed. A failed
            // rollback must not expose the newly persisted provider to sync.
            do {
                if let previous = try ModuleDatabase.shared.pendingBackendTransition() {
                    settings = previous
                    backendRecoveryError = error
                    storage = nil
                }
            } catch {
                backendRecoveryError = error
                storage = nil
            }
            throw error
        }
        // The library goes to the new endpoint by the first pass there.
        guard backend.usesRemoteStorage else { return }
        backendTransitionInProgress = false
        configureStorage()
        try await syncAll()
    }

    /// A storage instance for a backend, before it is the active one.
    private func createStorage(for backend: SyncBackend) throws -> ModuleStorage? {
        switch backend {
        case .icloudDrive:
            return ICloudModuleStorage.shared
        case .webdav:
            guard let urlString = settings.webdavURL,
                  let baseURL = URL(string: urlString) else {
                throw SyncError.notConfigured
            }
            return WebDAVModuleStorage(
                baseURL: baseURL,
                username: settings.webdavUsername,
                password: KeychainHelper.getWebDAVPassword()
            )
        case .none:
            return nil
        }
    }

    /// Update WebDAV settings
    func setWebDAVSettings(url: String?, username: String?) async throws {
        guard !backendTransitionInProgress else {
            throw SyncError.backendTransitionInProgress
        }
        try recoverPendingBackendTransition()
        var updatedSettings = settings
        updatedSettings.webdavURL = url
        updatedSettings.webdavUsername = username

        // Persist settings
        try userDatabase.saveSyncSettings(updatedSettings)
        settings = updatedSettings

        // Reconfigure if WebDAV is active
        if settings.backend == .webdav {
            configureStorage()
        }
    }

    /// Reload settings from database (useful if settings were persisted before SyncCoordinator initialized)
    func reloadSettings() async {
        guard !backendTransitionInProgress else { return }
        do {
            try recoverPendingBackendTransition()
        } catch {
            print("[SyncCoordinator] Cannot reload settings during backend recovery: \(error)")
            return
        }
        if let savedSettings = userDatabase.getSyncSettings() {
            settings = savedSettings
            configureStorage()
            print("[SyncCoordinator] Reloaded settings: backend=\(settings.backend)")
        }
    }

    // MARK: - Sync Operations

    /// Perform a full sync of all content
    /// Delegates to ModuleSyncManager with the configured storage provider
    func syncAll() async throws {
        guard !backendTransitionInProgress && !syncOperationInProgress else {
            throw SyncError.backendTransitionInProgress
        }
        syncOperationInProgress = true
        defer { syncOperationInProgress = false }
        try recoverPendingBackendTransition()
        guard settings.backend != .none else { return }
        guard let session = activeSession else {
            throw SyncError.notConfigured
        }
        let activeStorage = session.storage

        syncState = .syncing(progress: nil)

        // The library syncs only through its settings bundle. One still in
        // the earlier shape waits for the Mac to move it, or, kept only by
        // this device, is offered the move here.
        guard let endpoint = libraryEndpoint(for: activeStorage) else {
            syncState = .idle
            throw SyncError.notConfigured
        }
        do {
            let outcome = try await LibrarySyncPass.runIfMigrated(storage: endpoint)
            libraryMovable = outcome == .phoneLibrary
            if libraryMovable && !libraryMoveAsked {
                libraryMoveAsked = true
                libraryMoveOffered = true
            }
            if case .notMigrated = outcome { libraryAwaitingMove = true } else { libraryAwaitingMove = false }
            if case .synced = outcome {
                var updatedSettings = settings
                updatedSettings.lastSyncDate = Date()
                try userDatabase.saveSyncSettings(updatedSettings)
                settings = updatedSettings
            }
            syncState = .idle
        } catch {
            syncState = .error(error as? SyncError ?? .unknown(error))
            throw error
        }
    }

    /// The person agreed to move a library only this device kept.
    func movePhoneLibraryToNewSync() async throws {
        guard let endpoint = libraryEndpoint(for: activeStorage) else { throw SyncError.notConfigured }
        syncState = .syncing(progress: nil)
        do {
            try await LibrarySyncPass.movePhoneLibrary(storage: endpoint)
            libraryMovable = false
            libraryMoveOffered = false
            syncState = .idle
        } catch {
            syncState = .error(error as? SyncError ?? .unknown(error))
            throw error
        }
    }

    // MARK: - Availability

    /// Check if sync is available
    var isAvailable: Bool {
        get async {
            switch settings.backend {
            case .icloudDrive, .webdav:
                return await storage?.isAvailable() ?? false
            case .none:
                return false
            }
        }
    }

    /// The active storage provider for external use
    var activeStorage: ModuleStorage? {
        backendTransitionInProgress ? nil : storage
    }

    var activeSession: SyncSession? {
        guard let activeStorage else { return nil }
        return SyncSession(storage: activeStorage, backend: settings.backend)
    }

    // MARK: - WebDAV Testing

    /// Test WebDAV connection with given credentials
    /// - Parameters:
    ///   - url: WebDAV server URL
    ///   - username: Username for authentication
    ///   - password: Password for authentication
    /// - Returns: True if connection is successful
    func testWebDAVConnection(url: String, username: String?, password: String?) async throws -> Bool {
        guard let baseURL = URL(string: url) else {
            throw SyncError.notConfigured
        }

        let testStorage = WebDAVModuleStorage(
            baseURL: baseURL,
            username: username,
            password: password
        )

        return await testStorage.isAvailable()
    }

    /// Save WebDAV password to Keychain
    func saveWebDAVPassword(_ password: String) throws {
        try KeychainHelper.saveWebDAVPassword(password)
    }

}

// MARK: - Migration Types

/// Progress of an ongoing migration
struct MigrationProgress {
    let currentFile: String
    let filesCompleted: Int
    let totalFiles: Int
    let currentType: ModuleType?

    var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(filesCompleted) / Double(totalFiles)
    }

    var isComplete: Bool {
        filesCompleted >= totalFiles
    }
}

/// Result of a migration operation
struct MigrationResult {
    var successCount: Int = 0
    var failedFiles: [MigrationFailure] = []

    var totalAttempted: Int {
        successCount + failedFiles.count
    }

    var isFullySuccessful: Bool {
        failedFiles.isEmpty
    }
}

enum MigrationError: LocalizedError {
    case incomplete(MigrationResult)

    var errorDescription: String? {
        switch self {
        case .incomplete(let result):
            "Migration could not copy \(result.failedFiles.count) file(s). The sync backend was not changed."
        }
    }
}

/// A file that failed to migrate
struct MigrationFailure {
    let type: ModuleType
    let fileName: String
    let error: String
}

// Note: getSyncSettings() and saveSyncSettings() are implemented in UserDatabase.swift
