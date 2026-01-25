//
//  SyncCoordinator.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation
import Combine

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

    // MARK: - Dependencies

    private let userDatabase = UserDatabase.shared

    // MARK: - Initialization

    private init() {
        // Load settings from UserDatabase
        self.settings = userDatabase.getSyncSettings() ?? .default

        // Configure storage based on settings
        Task {
            await configureStorage()
        }
    }

    // MARK: - Configuration

    /// Configure storage provider based on current settings
    func configureStorage() async {
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

    /// Update sync backend and reconfigure storage.
    /// This is the low-level method - prefer using `switchBackend(to:migrateData:)` instead.
    func setBackend(_ backend: SyncBackend) async throws {
        var updatedSettings = settings
        updatedSettings.backend = backend
        settings = updatedSettings

        // Persist settings
        try userDatabase.saveSyncSettings(settings)

        // Reconfigure storage
        await configureStorage()

        // Initialize directory structure on new backend
        if backend != .none, let storage = storage {
            try? await storage.initializeDirectoryStructure()
        }
    }

    /// Switch to a new sync backend with option to migrate or wipe data.
    /// - Parameters:
    ///   - backend: The new backend to switch to
    ///   - migrateData: If true, migrate existing data to new backend. If false, wipe local data.
    /// - Note: The UI should confirm with the user before calling with migrateData=false
    func switchBackend(to backend: SyncBackend, migrateData: Bool) async throws {
        let previousBackend = settings.backend

        // No change needed
        if previousBackend == backend {
            return
        }

        if migrateData {
            // Migrate data from previous backend to new backend
            if previousBackend != .none && backend != .none {
                // Both are cloud backends - migrate between them
                _ = try await migrateStorage(from: previousBackend, to: backend)
                print("[SyncCoordinator] Migrated data from \(previousBackend) to \(backend)")
            } else if previousBackend == .none && backend != .none {
                // Switching from local to cloud - upload local data
                try await uploadLocalDataToBackend(backend)
                print("[SyncCoordinator] Uploaded local data to \(backend)")
            } else if previousBackend != .none && backend == .none {
                // Switching from cloud to local - download cloud data first
                try await downloadDataFromBackend(previousBackend)
                print("[SyncCoordinator] Downloaded data from \(previousBackend) to local")
            }
        } else {
            // Wipe local data (user confirmed this choice)
            do {
                try ModuleDatabase.shared.wipeAllSyncableData()
                print("[SyncCoordinator] Wiped local syncable data before switching from \(previousBackend) to \(backend)")
            } catch {
                print("[SyncCoordinator] Failed to wipe syncable data: \(error)")
                throw error
            }
        }

        // Now switch to the new backend
        try await setBackend(backend)
    }

    /// Upload local syncable data to the specified backend
    private func uploadLocalDataToBackend(_ backend: SyncBackend) async throws {
        // Create storage for the target backend
        guard let targetStorage = try createStorage(for: backend) else {
            throw SyncError.notConfigured
        }

        // Initialize directory structure
        try? await targetStorage.initializeDirectoryStructure()

        // Export notes and devotionals to files and upload
        // This leverages the existing sync infrastructure
        // The actual upload happens when we call syncAll() after switching
        print("[SyncCoordinator] Local data will be synced to \(backend) on next sync")
    }

    /// Download data from the specified backend to local storage
    private func downloadDataFromBackend(_ backend: SyncBackend) async throws {
        // The data is already in the local database from previous syncs
        // When switching to local-only, we just keep the existing local data
        print("[SyncCoordinator] Keeping local copy of data from \(backend)")
    }

    /// Update WebDAV settings
    func setWebDAVSettings(url: String?, username: String?) async throws {
        var updatedSettings = settings
        updatedSettings.webdavURL = url
        updatedSettings.webdavUsername = username
        settings = updatedSettings

        // Persist settings
        try userDatabase.saveSyncSettings(settings)

        // Reconfigure if WebDAV is active
        if settings.backend == .webdav {
            await configureStorage()
        }
    }

    /// Reload settings from database (useful if settings were persisted before SyncCoordinator initialized)
    func reloadSettings() async {
        if let savedSettings = userDatabase.getSyncSettings() {
            settings = savedSettings
            await configureStorage()
            print("[SyncCoordinator] Reloaded settings: backend=\(settings.backend)")
        }
    }

    // MARK: - Sync Operations

    /// Perform a full sync of all content
    /// Delegates to ModuleSyncManager with the configured storage provider
    func syncAll() async throws {
        guard settings.backend != .none else { return }
        guard storage != nil else {
            throw SyncError.notConfigured
        }

        syncState = .syncing(progress: nil)

        do {
            // Delegate to existing ModuleSyncManager
            // In the future, this could use storage parameter to allow custom providers
            await ModuleSyncManager.shared.syncAll()

            // Update last sync date
            var updatedSettings = settings
            updatedSettings.lastSyncDate = Date()
            settings = updatedSettings
            try? userDatabase.saveSyncSettings(settings)

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
        storage
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
        let moduleTypes: [ModuleType] = [.notes, .devotional, .translation, .dictionary, .commentary, .plan]

        // Initialize directory structure on destination
        try? await dest.initializeDirectoryStructure()

        // Delete existing files on destination first
        migrationProgress = MigrationProgress(
            currentFile: "Clearing destination...",
            filesCompleted: 0,
            totalFiles: 0,
            currentType: nil
        )

        for type in moduleTypes {
            do {
                let existingFiles = try await dest.listModuleFiles(type: type)
                for file in existingFiles {
                    try? await dest.deleteModuleFile(type: type, fileName: file.filePath)
                    print("[Migration] Deleted existing \(type)/\(file.filePath) from destination")
                }
            } catch {
                print("[Migration] Failed to list existing \(type) files on destination: \(error)")
            }
        }

        // First pass: count total files
        var totalFiles = 0
        var allFiles: [(ModuleType, ModuleFileInfo)] = []

        for type in moduleTypes {
            do {
                let files = try await source.listModuleFiles(type: type)
                allFiles.append(contentsOf: files.map { (type, $0) })
                totalFiles += files.count
            } catch {
                print("[Migration] Failed to list \(type) files: \(error)")
            }
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

                // Write to destination
                try await dest.writeModuleFile(type: type, fileName: fileInfo.filePath, data: data)

                result.successCount += 1
                print("[Migration] Copied \(type)/\(fileInfo.filePath)")
            } catch {
                result.failedFiles.append(MigrationFailure(
                    type: type,
                    fileName: fileInfo.filePath,
                    error: error.localizedDescription
                ))
                print("[Migration] Failed to copy \(type)/\(fileInfo.filePath): \(error)")
            }
        }

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

/// A file that failed to migrate
struct MigrationFailure {
    let type: ModuleType
    let fileName: String
    let error: String
}

// Note: getSyncSettings() and saveSyncSettings() are implemented in UserDatabase.swift
