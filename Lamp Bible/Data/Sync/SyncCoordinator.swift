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
        let archiveSource: String
        let needsLegacyReconciliation: Bool
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
            try await LampSyncBackendTransition.run(
                wipeLocalAfterPublish: !migrateData,
                pullAndMerge: {
                    if migrateData {
                        if previousBackend != .none && backend != .none {
                            let result = try await self.migrateStorage(
                                from: previousBackend, to: backend
                            )
                            guard result.isFullySuccessful else {
                                throw MigrationError.incomplete(result)
                            }
                        } else if previousBackend == .none && backend != .none {
                            try await self.uploadLocalDataToBackend(backend)
                        } else if previousBackend != .none && backend == .none {
                            try await self.downloadDataFromBackend(previousBackend)
                        }
                    }
                },
                publish: {
                    guard backend.usesRemoteStorage else { return }
                    guard let targetStorage = try self.createStorage(for: backend) else {
                        throw SyncError.notConfigured
                    }
                    try await targetStorage.initializeDirectoryStructure()
                    try await UserSettingsSyncManager.shared.reconcileWithRemote(
                        storage: targetStorage
                    )
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
    }

    /// Upload local syncable data to the specified backend
    private func uploadLocalDataToBackend(_ backend: SyncBackend) async throws {
        // Create storage for the target backend
        guard let targetStorage = try createStorage(for: backend) else {
            throw SyncError.notConfigured
        }

        guard await targetStorage.isAvailable() else {
            throw SyncError.notAvailable
        }
        try await targetStorage.initializeDirectoryStructure()

        // Merge any existing destination content before writing the combined
        // editable modules back. This avoids choosing either side wholesale.
        try await ModuleSyncManager.shared.reconcileEditableModules(with: targetStorage)
        try await ModuleSyncManager.shared.exportAllEditableModules(to: targetStorage)

        do {
            try await UserSettingsSyncManager.shared.mergeFromRemote(storage: targetStorage)
        } catch ModuleStorageError.fileNotFound {
            // A new destination has no user-settings file yet.
        }
    }

    /// Download data from the specified backend to local storage
    private func downloadDataFromBackend(_ backend: SyncBackend) async throws {
        guard let sourceStorage = try createStorage(for: backend) else {
            throw SyncError.notConfigured
        }
        guard await sourceStorage.isAvailable() else {
            throw SyncError.notAvailable
        }

        for type in ModuleType.allCases {
            try await ModuleSyncManager.shared.syncModuleType(type, using: sourceStorage)
        }
        do {
            try await UserSettingsSyncManager.shared.mergeFromRemote(storage: sourceStorage)
        } catch ModuleStorageError.fileNotFound {
            // The provider may predate user-settings sync.
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

        do {
            try await ModuleSyncManager.shared.runFullSync(
                using: activeStorage,
                backend: session.backend,
                archiveSource: session.archiveSource,
                beforePull: {
                    if session.needsLegacyReconciliation {
                        try await ModuleSyncManager.shared.reconcileEditableModules(with: activeStorage)
                    }
                },
                afterPublish: {
                    if session.needsLegacyReconciliation {
                        try await ModuleSyncManager.shared.exportAllEditableModules(to: activeStorage)
                    }
                    if self.userDatabase.hasUnsyncedChanges {
                        try await UserSettingsSyncManager.shared.reconcileWithRemote(storage: activeStorage)
                    }
                },
                complete: {
                    var updatedSettings = self.settings
                    updatedSettings.lastSyncDate = Date()
                    updatedSettings.legacyICloudReconciliationPending = nil
                    try self.userDatabase.saveSyncSettings(updatedSettings)
                    self.settings = updatedSettings
                }
            )

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
        return SyncSession(
            storage: activeStorage,
            backend: settings.backend,
            archiveSource: settings.webdavURL ?? "",
            needsLegacyReconciliation: settings.legacyICloudReconciliationPending == true
        )
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

    // MARK: - Migration

    /// Migration progress state
    @Published private(set) var migrationProgress: MigrationProgress?

    /// Migrate all modules from one storage backend to another
    /// - Parameters:
    ///   - from: Source backend to migrate from
    ///   - to: Destination backend to migrate to
    ///   - progressHandler: Optional callback for progress updates
    /// - Returns: Migration result with success/failure counts
    func migrateStorage(from sourceBackend: SyncBackend, to destBackend: SyncBackend) async throws -> MigrationResult {
        // Create storage instances for source and destination
        let sourceStorage = try createStorage(for: sourceBackend)
        let destStorage = try createStorage(for: destBackend)

        guard let source = sourceStorage else {
            throw SyncError.notConfigured
        }
        guard let dest = destStorage else {
            throw SyncError.notConfigured
        }

        // Check both are available
        guard await source.isAvailable() else {
            throw SyncError.notAvailable
        }
        guard await dest.isAvailable() else {
            throw SyncError.notAvailable
        }

        var result = MigrationResult()
        let moduleTypes = ModuleType.allCases

        // Initialize directory structure on destination
        try await dest.initializeDirectoryStructure()

        // Merge editable data from both providers into the local database before
        // copying files. Destination-only files remain in place throughout.
        try await ModuleSyncManager.shared.reconcileEditableModules(with: source)
        try await ModuleSyncManager.shared.reconcileEditableModules(with: dest)

        // First pass: count total files
        var totalFiles = 0
        var allFiles: [(ModuleType, ModuleFileInfo)] = []

        for type in moduleTypes {
            let files = try await source.listModuleFiles(type: type)
            allFiles.append(contentsOf: files.map { (type, $0) })
            totalFiles += files.count
        }

        migrationProgress = MigrationProgress(
            currentFile: "",
            filesCompleted: 0,
            totalFiles: totalFiles,
            currentType: nil
        )

        // Second pass: copy files
        for (index, (type, fileInfo)) in allFiles.enumerated() {
            migrationProgress = MigrationProgress(
                currentFile: fileInfo.filePath,
                filesCompleted: index,
                totalFiles: totalFiles,
                currentType: type
            )

            do {
                // Read from source
                let data = try await source.readModuleFile(type: type, fileName: fileInfo.filePath)
                let moduleID = fileInfo.id == "bible-notes" ? "notes" : fileInfo.id
                let localModule = try ModuleDatabase.shared.getModule(id: moduleID)
                let isEditable = [ModuleType.notes, .devotional, .highlights].contains(type)
                    && localModule?.type == type && localModule?.isEditable == true
                _ = try await LampSyncMigrationCopy.run(
                    isEditable: isEditable,
                    source: data,
                    readDestination: {
                        do {
                            return try await dest.readModuleFile(
                                type: type, fileName: fileInfo.filePath
                            )
                        } catch ModuleStorageError.fileNotFound {
                            return nil
                        }
                    },
                    createIfAbsent: { data in
                        if let iCloud = dest as? ICloudModuleStorage {
                            try await iCloud.writeModuleFile(
                                type: type, fileName: fileInfo.filePath,
                                data: data, matching: nil
                            )
                        } else if let webDAV = dest as? WebDAVModuleStorage {
                            _ = try await webDAV.writeModuleFile(
                                type: type, fileName: fileInfo.filePath,
                                data: data, matching: nil
                            )
                        } else {
                            throw SyncError.notConfigured
                        }
                    }
                )

                result.successCount += 1
                print("[Migration] Prepared \(type)/\(fileInfo.filePath)")
            } catch {
                result.failedFiles.append(MigrationFailure(
                    type: type,
                    fileName: fileInfo.filePath,
                    error: error.localizedDescription
                ))
                print("[Migration] Failed to copy \(type)/\(fileInfo.filePath): \(error)")
            }
        }

        // Raw copies preserve bundled/read-only modules. Editable modules are
        // rewritten from the reconciled local database so neither side wins
        // wholesale when both providers contain changes.
        try await ModuleSyncManager.shared.exportAllEditableModules(to: dest)

        // Update progress to complete
        migrationProgress = MigrationProgress(
            currentFile: "",
            filesCompleted: totalFiles,
            totalFiles: totalFiles,
            currentType: nil
        )

        return result
    }

    /// Create a storage instance for a given backend
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

    /// Clear migration progress
    func clearMigrationProgress() {
        migrationProgress = nil
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
