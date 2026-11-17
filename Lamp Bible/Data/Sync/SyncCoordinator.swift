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
    /// Modules this device holds that the last pass to reach each library
    /// did not find there, by library source and then path, with why (core's
    /// `LampSyncFilePlan.missing`). The Module Manager marks them; nothing
    /// deletes them, since absence is no evidence of a deletion. Kept across
    /// launches, and replaced by each pass that reaches the library.
    @Published private(set) var missingModules: [String: [String: LampSyncFilePlan.Missing]] = SyncCoordinator.storedMissingModules()
    /// The module each missing path is held as here, by source and path,
    /// where the pass knew it.
    private(set) var missingModuleIDs: [String: [String: String]] =
        UserDefaults.standard.dictionary(forKey: SyncCoordinator.missingModuleIDsKey) as? [String: [String: String]] ?? [:]
    /// The libraries, by source, whose last sync never got as far as
    /// checking their files (not connected, signed out, the server down),
    /// with why. A sync that checked them and then failed over one file
    /// leaves its library out: its report of what is missing is fresh. Kept
    /// across launches with the reports, so a stale report never reads as
    /// confirmed.
    @Published private(set) var uncheckedLibraries: [String: String] =
        UserDefaults.standard.dictionary(forKey: SyncCoordinator.uncheckedLibrariesKey) as? [String: String] ?? [:]
    /// Libraries a pass now running has checked the files of.
    private var checkedThisPass: Set<String> = []
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
            libraryUnreachable(storage: nil)
            throw SyncError.notConfigured
        }
        let activeStorage = session.storage

        syncState = .syncing(progress: nil)

        // The library syncs only through its settings bundle. One still in
        // the earlier shape waits for the Mac to move it, or, kept only by
        // this device, is offered the move here.
        guard let endpoint = libraryEndpoint(for: activeStorage) else {
            syncState = .idle
            libraryUnreachable(storage: activeStorage)
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

    private static let missingModulesKey = "LibrarySync.missingModules.v1"
    private static let uncheckedLibrariesKey = "LibrarySync.uncheckedLibraries.v1"
    private static let missingModuleIDsKey = "LibrarySync.missingModuleIDs.v1"

    /// A pass at `source` is starting: whatever it reports replaces the last.
    func libraryCheckStarted(source: String) {
        checkedThisPass.remove(source)
    }

    /// A pass at `source` failed. Unless it had already checked the
    /// library's files (and failed over one of them), the marks from the
    /// last check there are now unconfirmed.
    func libraryCheckFailed(source: String, reason: String) {
        guard !checkedThisPass.contains(source) else { return }
        uncheckedLibraries[source] = reason
        UserDefaults.standard.set(uncheckedLibraries, forKey: Self.uncheckedLibrariesKey)
    }

    /// A sync or a poll couldn't reach the library to try a pass at all.
    /// iCloud's library is named without its container, which is what can't
    /// be reached while signed out.
    func libraryUnreachable(storage: ModuleStorage?) {
        let source: String
        let reason: String
        if settings.backend == .icloudDrive {
            source = ICloudLibraryStorage.librarySource
            reason = "iCloud Drive isn’t available"
        } else if let storage, let endpoint = libraryEndpoint(for: storage) {
            source = endpoint.librarySource
            reason = "your server couldn’t be reached"
        } else {
            return
        }
        libraryCheckStarted(source: source)
        libraryCheckFailed(source: source, reason: reason)
    }

    /// What a pass found missing at `source`, in place of what the last one
    /// there found. Whichever pass it was, a scheduled one too, it checked
    /// that library's files.
    func recordMissingModules(
        _ missing: [String: LampSyncFilePlan.Missing], source: String, moduleIDs: [String: String] = [:]
    ) {
        checkedThisPass.insert(source)
        if uncheckedLibraries.removeValue(forKey: source) != nil {
            UserDefaults.standard.set(uncheckedLibraries, forKey: Self.uncheckedLibrariesKey)
        }
        if missingModuleIDs[source] ?? [:] != moduleIDs {
            missingModuleIDs[source] = moduleIDs.isEmpty ? nil : moduleIDs
            UserDefaults.standard.set(missingModuleIDs, forKey: Self.missingModuleIDsKey)
        }
        guard missingModules[source] ?? [:] != missing else { return }
        missingModules[source] = missing.isEmpty ? nil : missing
        let stored = missingModules.mapValues { paths in
            paths.mapValues { $0 == .notOnServer ? "notOnServer" : "folderNotListed" }
        }
        UserDefaults.standard.set(stored, forKey: Self.missingModulesKey)
    }

    private static func storedMissingModules() -> [String: [String: LampSyncFilePlan.Missing]] {
        let stored = UserDefaults.standard.dictionary(forKey: missingModulesKey) as? [String: [String: String]] ?? [:]
        return stored.mapValues { paths in
            paths.compactMapValues { cause in
                switch cause {
                case "notOnServer": return .notOnServer
                case "folderNotListed": return .folderNotListed
                default: return nil
                }
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
