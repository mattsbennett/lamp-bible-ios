//
//  UserSettingsSyncManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-02-22.
//

import Foundation
import GRDB

/// Manages user-settings sync with debounced export, periodic polling, and merge-based conflict resolution.
@MainActor
class UserSettingsSyncManager {
    static let shared = UserSettingsSyncManager()

    // MARK: - Configuration

    private let debounceInterval: TimeInterval = 3.0
    private let pollInterval: TimeInterval = 30.0
    private let userSettingsPath = "UserData/user-settings.db"

    // MARK: - State

    private var debounceTask: Task<Void, Never>?
    private var pollTimer: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var isRunning = false

    /// UserDefaults key for the last-known remote change token
    private static let remoteChangeTokenKey = "UserSettingsSync.remoteChangeToken"

    private var storedChangeToken: String? {
        get { UserDefaults.standard.string(forKey: Self.remoteChangeTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.remoteChangeTokenKey) }
    }

    private init() {}

    // MARK: - Lifecycle

    /// Start the debounce observer and poll timer. Call when the app becomes active.
    func startSync() {
        guard !isRunning else { return }
        isRunning = true

        // Observe local database changes for debounced export
        changeObserver = NotificationCenter.default.addObserver(
            forName: .userDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleDebouncedExport()
            }
        }

        // Start polling for remote changes
        pollTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.pollForRemoteChanges()
            }
        }

        print("[UserSettingsSync] Started (debounce=\(debounceInterval)s, poll=\(pollInterval)s)")
    }

    /// Stop the debounce observer and poll timer. Call when the app goes to background.
    func stopSync() {
        guard isRunning else { return }
        isRunning = false

        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
            changeObserver = nil
        }

        debounceTask?.cancel()
        debounceTask = nil

        pollTimer?.cancel()
        pollTimer = nil

        print("[UserSettingsSync] Stopped")
    }

    // MARK: - Debounced Export

    private func scheduleDebouncedExport() {
        print("[UserSettingsSync] Debounce scheduled")
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(3 * 1_000_000_000))
            guard !Task.isCancelled else {
                print("[UserSettingsSync] Debounce cancelled (superseded)")
                return
            }

            guard UserDatabase.shared.hasUnsyncedChanges else {
                print("[UserSettingsSync] Debounce fired but no unsynced changes")
                return
            }

            guard let storage = await self?.getStorage() else {
                print("[UserSettingsSync] Debounce fired but no storage available")
                return
            }
            do {
                try await self?.exportToRemote(storage: storage)
            } catch {
                print("[UserSettingsSync] Debounced export failed: \(error)")
            }
        }
    }

    // MARK: - Polling

    private func pollForRemoteChanges() async {
        guard let storage = await getStorage() else { return }

        // If there are unsynced local changes, export them now.
        // The file monitor may not detect WAL-mode writes, so the debounced
        // export might never fire — this ensures changes reach remote within 30s.
        if UserDatabase.shared.hasUnsyncedChanges {
            print("[UserSettingsSync] Poll: exporting unsynced local changes")
            do {
                try await exportToRemote(storage: storage)
            } catch {
                print("[UserSettingsSync] Periodic export failed: \(error)")
            }
            return // Don't merge in the same cycle — let the next poll pick up remote changes
        }

        let remoteToken = await storage.getChangeToken(path: userSettingsPath)

        // No remote file yet — nothing to merge
        guard let remoteToken else {
            print("[UserSettingsSync] Poll: no remote file yet")
            return
        }

        // Compare with stored token
        if remoteToken != storedChangeToken {
            print("[UserSettingsSync] Remote change detected (token: \(remoteToken) vs stored: \(storedChangeToken ?? "nil")), merging...")
            do {
                try await mergeFromRemote(storage: storage)
            } catch {
                print("[UserSettingsSync] Merge from remote failed: \(error)")
            }
        } else {
            print("[UserSettingsSync] Poll: no remote changes")
        }
    }

    // MARK: - Full Sync (foreground entry point)

    /// Called from ModuleSyncManager.syncAll() on foreground.
    /// Exports first if there are local changes (so deletions reach remote before merge),
    /// then downloads remote, merges, and re-exports if the merge added anything.
    func performFullSync() async {
        guard let storage = await getStorage() else { return }
        guard await storage.isAvailable() else {
            print("[UserSettingsSync] Storage not available")
            return
        }

        // Export first if there are unsynced local changes.
        // This ensures local deletions reach remote BEFORE we merge,
        // preventing INSERT OR IGNORE from re-adding rows the user deleted.
        if UserDatabase.shared.hasUnsyncedChanges {
            print("[UserSettingsSync] Local changes pending, exporting before merge...")
            do {
                try await exportToRemote(storage: storage)
            } catch {
                print("[UserSettingsSync] Pre-merge export failed: \(error)")
            }
        }

        // Download remote
        let remoteData: Data?
        do {
            remoteData = try await storage.readFile(path: userSettingsPath)
        } catch {
            remoteData = nil
        }

        if let remoteData {
            let localIsFreshInstall = isFreshInstall(at: UserDatabase.shared.databaseURL)

            if localIsFreshInstall {
                print("[UserSettingsSync] Fresh install detected, importing remote settings...")
                await importWholeFile(from: remoteData)
                storedChangeToken = await storage.getChangeToken(path: userSettingsPath)
                return
            }

            // If local changes arrived while we were downloading, export again first
            if UserDatabase.shared.hasUnsyncedChanges {
                do {
                    try await exportToRemote(storage: storage)
                    // Re-download so we merge against the up-to-date remote
                    if let freshData = try await storage.readFile(path: userSettingsPath) as Data? {
                        let merged = try mergeRemoteData(freshData)
                        storedChangeToken = await storage.getChangeToken(path: userSettingsPath)
                        if merged { try await exportToRemote(storage: storage) }
                    }
                } catch {
                    print("[UserSettingsSync] Sync failed: \(error)")
                }
                return
            }

            do {
                let merged = try mergeRemoteData(remoteData)
                storedChangeToken = await storage.getChangeToken(path: userSettingsPath)
                if merged {
                    try await exportToRemote(storage: storage)
                }
            } catch {
                print("[UserSettingsSync] Full sync merge failed: \(error)")
            }
        } else {
            // No remote file — export local
            print("[UserSettingsSync] No remote file, exporting...")
            do {
                try await exportToRemote(storage: storage)
            } catch {
                print("[UserSettingsSync] Initial export failed: \(error)")
            }
        }
    }

    // MARK: - Merge from Remote

    /// Download remote db, merge into local, and update stored change token.
    func mergeFromRemote(storage: ModuleStorage) async throws {
        // If local changes are pending, export first so deletions reach remote
        if UserDatabase.shared.hasUnsyncedChanges {
            try await exportToRemote(storage: storage)
        }

        let remoteData = try await storage.readFile(path: userSettingsPath)
        let merged = try mergeRemoteData(remoteData)
        storedChangeToken = await storage.getChangeToken(path: userSettingsPath)

        if merged {
            // Re-export the merged result so remote also has the union
            try await exportToRemote(storage: storage)
        }
    }

    /// Core merge logic — opens remote db read-only, merges readings and settings into local.
    /// Returns true if anything was changed locally.
    private func mergeRemoteData(_ remoteData: Data) throws -> Bool {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try remoteData.write(to: tempURL)

        var config = Configuration()
        config.readonly = true
        let remoteDb = try DatabaseQueue(path: tempURL.path, configuration: config)

        // Read remote completed readings
        let remoteReadings: [CompletedReading] = try remoteDb.read { db in
            try CompletedReading.fetchAll(db)
        }

        // Read remote settings
        let remoteSettings: UserSettings? = try remoteDb.read { db in
            try UserSettings.fetchOne(db, key: 1)
        }

        // Merge settings FIRST — before readings sync, which bumps updated_at
        // and would make the local always look newer than remote.
        var settingsUpdated = false
        if let remoteSettings {
            settingsUpdated = UserDatabase.shared.mergeSettings(from: remoteSettings)
        }

        // Sync completed readings: add remote-only, remove local-only (propagate deletions)
        let readingsChanged = UserDatabase.shared.syncCompletedReadings(with: remoteReadings)

        let didMerge = readingsChanged || settingsUpdated

        if didMerge {
            print("[UserSettingsSync] Merged: readings \(readingsChanged ? "changed" : "unchanged"), settings \(settingsUpdated ? "updated" : "unchanged")")
            // Notify UI — mark as external change so it doesn't trigger re-export via hasUnsyncedChanges
            UserDatabase.shared.notifyExternalChange()
        }

        return didMerge
    }

    // MARK: - Export to Remote

    /// Checkpoint WAL, read the local db file, and upload to remote storage.
    func exportToRemote(storage: ModuleStorage) async throws {
        guard await storage.isAvailable() else { return }

        try UserDatabase.shared.checkpointForSync()

        let localURL = UserDatabase.shared.databaseURL
        let data = try Data(contentsOf: localURL)

        try await storage.writeFile(path: userSettingsPath, data: data)
        UserDatabase.shared.clearUnsyncedChanges()

        // Fetch and store the new remote change token
        storedChangeToken = await storage.getChangeToken(path: userSettingsPath)

        print("[UserSettingsSync] Exported to remote")
    }

    // MARK: - Whole-File Import (fresh install only)

    /// Replace local db file entirely with remote data. Used only for fresh installs.
    private func importWholeFile(from data: Data) {
        let localURL = UserDatabase.shared.databaseURL

        // Backup current
        let backupURL = localURL.deletingLastPathComponent().appendingPathComponent("user.db.backup")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: localURL, to: backupURL)

        // Close database before replacing file
        UserDatabase.shared.closeDatabase()

        // Delete WAL/SHM files
        let walURL = localURL.appendingPathExtension("wal")
        let shmURL = localURL.appendingPathExtension("shm")
        try? FileManager.default.removeItem(at: walURL)
        try? FileManager.default.removeItem(at: shmURL)

        // Write new data
        try? data.write(to: localURL)

        // Reopen
        UserDatabase.shared.reopenDatabase()
        UserDatabase.shared.notifyExternalChange()
        print("[UserSettingsSync] Imported whole file from remote")
    }

    // MARK: - Fresh Install Detection

    /// Check if the local database only has default values
    private func isFreshInstall(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            return try queue.read { db in
                let readingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM completed_readings") ?? 0
                if readingCount > 0 { return false }

                let row = try Row.fetchOne(db, sql: """
                    SELECT sync_settings_json, selected_plan_ids,
                           reader_translation_id, hidden_translations,
                           greek_lexicon_order, hebrew_lexicon_order
                    FROM user_settings WHERE id = 1
                """)

                guard let row else { return true }

                let hasSyncSettings: Bool = row["sync_settings_json"] != nil
                let hasPlans = (row["selected_plan_ids"] as? String ?? "").isEmpty == false
                let changedTranslation = (row["reader_translation_id"] as? String) != "BSBs"
                let hasHidden = (row["hidden_translations"] as? String ?? "").isEmpty == false
                let changedGreek = (row["greek_lexicon_order"] as? String) != "strongs,dodson"
                let changedHebrew = (row["hebrew_lexicon_order"] as? String) != "strongs,bdb"

                return !hasSyncSettings && !hasPlans && !changedTranslation
                    && !hasHidden && !changedGreek && !changedHebrew
            }
        } catch {
            print("[UserSettingsSync] Error checking fresh install: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private func getStorage() async -> ModuleStorage? {
        let storage = await SyncCoordinator.shared.activeStorage
        guard let storage, await storage.isAvailable() else { return nil }
        return storage
    }
}
