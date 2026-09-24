//
//  UserSettingsSyncManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-02-22.
//

import Foundation
import GRDB
import LampModuleKit

/// Manages user-settings sync with debounced export, periodic polling, and merge-based conflict resolution.
@MainActor
class UserSettingsSyncManager {
    static let shared = UserSettingsSyncManager()

    // MARK: - Configuration

    private let debounceInterval: TimeInterval = 3.0
    private let pollInterval: TimeInterval = 30.0
    private let userSettingsPath = LampSyncLayout.userSettingsPath

    // MARK: - State

    private var debounceTask: Task<Void, Never>?
    private var pollTimer: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var isRunning = false
    private var syncInProgress = false

    /// UserDefaults key for the last-known remote change token
    private static let remoteChangeTokenKey = "UserSettingsSync.remoteChangeToken"
    private static let readingsBaseKey = "UserSettingsSync.readingsBase.v1"

    struct SettingsSyncBase: Codable {
        let source: String
        let token: String?
        let readingIDs: Set<String>
        let settings: UserSettings
        let legacyRevision: String?

        init(
            source: String,
            token: String?,
            readingIDs: Set<String>,
            settings: UserSettings,
            legacyRevision: String? = nil
        ) {
            self.source = source
            self.token = token
            self.readingIDs = readingIDs
            self.settings = settings
            self.legacyRevision = legacyRevision
        }
    }

    private func syncSource(for storage: ModuleStorage) -> String {
        if let webDAV = storage as? WebDAVModuleStorage {
            return webDAV.syncSourceIdentifier
        }
        if storage is ICloudModuleStorage { return "icloud-documents" }
        return String(reflecting: type(of: storage))
    }

    private func archiveSource(for storage: ModuleStorage) -> String {
        "archive:" + syncSource(for: storage)
    }

    private func cachedReadingsBase() -> SettingsSyncBase? {
        guard let data = UserDefaults.standard.data(forKey: Self.readingsBaseKey),
              let base = try? JSONDecoder().decode(SettingsSyncBase.self, from: data) else {
            return nil
        }
        return base
    }

    private func readingsBase(for source: String) -> SettingsSyncBase? {
        guard let base = cachedReadingsBase(),
              base.source == source,
              base.token == storedChangeToken else { return nil }
        return base
    }

    private func expectedStoredToken(for source: String) -> String? {
        if source.hasPrefix("archive:") && cachedReadingsBase()?.source != source {
            return nil
        }
        if let base = cachedReadingsBase(), base.source != source {
            return nil
        }
        return storedChangeToken
    }

    private func expectedStoredToken(for storage: ModuleStorage) -> String? {
        expectedStoredToken(for: syncSource(for: storage))
    }

    private func rememberReadingsBase(
        for source: String,
        token: String?,
        settings: UserSettings,
        readingIDs: Set<String>,
        legacyRevision: String? = nil
    ) throws {
        let base = SettingsSyncBase(
            source: source,
            token: token,
            readingIDs: readingIDs,
            settings: settings,
            legacyRevision: legacyRevision
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(base),
            forKey: Self.readingsBaseKey
        )
    }

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
                try await self?.syncWithRemote(storage: storage, requireRemote: false)
            } catch {
                print("[UserSettingsSync] Debounced export failed: \(error)")
            }
        }
    }

    // MARK: - Polling

    private func pollForRemoteChanges() async {
        guard let storage = await getStorage() else { return }
        await pollForRemoteChanges(storage: storage)
    }

    func pollForRemoteChanges(storage: ModuleStorage) async {
        // The archive and the legacy settings file can change independently.
        // Read both so an older client's edit cannot be hidden by an unchanged
        // archive revision.
        if storage is any LampSyncRemoteStore {
            if await canSkipUnchangedArchivePoll(storage: storage) { return }
            do {
                try await syncWithRemote(storage: storage, requireRemote: false)
            } catch {
                print("[UserSettingsSync] Periodic WebDAV sync failed: \(error)")
            }
            return
        }

        // The file monitor may not detect WAL-mode writes. Reconcile before
        // publishing any local changes found during the periodic poll.
        if UserDatabase.shared.hasUnsyncedChanges {
            print("[UserSettingsSync] Poll: reconciling unsynced local changes")
            do {
                try await syncWithRemote(storage: storage, requireRemote: false)
            } catch {
                print("[UserSettingsSync] Periodic sync failed: \(error)")
            }
            return
        }

        let remoteToken = await storage.getChangeToken(path: userSettingsPath)

        // A missing token can also mean an existing iCloud file whose
        // modification date is unavailable. Read it before assuming absence.
        guard let remoteToken else {
            do {
                if try await readRemoteSettings(from: storage) != nil {
                    try await mergeFromRemote(storage: storage)
                } else {
                    print("[UserSettingsSync] Poll: no remote file yet")
                }
            } catch {
                print("[UserSettingsSync] Poll: could not identify remote settings: \(error)")
            }
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

    func canSkipUnchangedArchivePoll(storage: ModuleStorage) async -> Bool {
        guard !UserDatabase.shared.hasUnsyncedChanges,
              let store = storage as? any LampSyncRemoteStore,
              let base = readingsBase(for: archiveSource(for: storage)) else {
            return false
        }
        return await LampSyncSettingsArchive.canSkipUnchangedPoll(
            expectedArchiveToken: base.token,
            expectedLegacyRevision: base.legacyRevision,
            in: store
        )
    }

    // MARK: - Full Sync (foreground entry point)

    /// Called with the foreground pass's selected provider so settings and
    /// modules cannot resolve different backends during one sync.
    func performFullSync(using storage: ModuleStorage) async -> Bool {
        guard await storage.isAvailable() else {
            print("[UserSettingsSync] Storage not available")
            return false
        }
        do {
            try await syncWithRemote(storage: storage, requireRemote: false)
            return true
        } catch {
            print("[UserSettingsSync] Full sync failed: \(error)")
            return false
        }
    }

    /// Download remote data and reconcile it with the last applied state.
    func mergeFromRemote(storage: ModuleStorage) async throws {
        try await syncWithRemote(storage: storage, requireRemote: true)
    }

    /// Reconcile local pending changes with the current remote snapshot before
    /// publishing. Used by lifecycle and coordinator paths outside the poller.
    func reconcileWithRemote(storage: ModuleStorage) async throws {
        try await syncWithRemote(storage: storage, requireRemote: false)
    }

    private func syncWithRemote(
        storage: ModuleStorage,
        requireRemote: Bool
    ) async throws {
        guard !syncInProgress else { throw SyncError.alreadyRunning }
        syncInProgress = true
        defer { syncInProgress = false }
        let observed = try await readRemoteSettings(from: storage)
        let hasBase = observed.flatMap { applicableBase(for: $0, storage: storage) } != nil
        let hasStoredToken = observed.flatMap { expectedStoredToken(for: $0.source) } != nil
        let action = LampSyncSettingsBootstrap.action(
            remoteExists: observed != nil,
            requireRemote: requireRemote,
            hasApplicableBase: hasBase,
            hasStoredToken: hasStoredToken,
            freshInstall: observed != nil && !hasBase && !hasStoredToken && isFreshInstall(),
            hasUnsyncedChanges: UserDatabase.shared.hasUnsyncedChanges
        )
        guard var remoteSnapshot = observed else {
            if action == .missingRequiredRemote {
                throw ModuleStorageError.fileNotFound(userSettingsPath)
            }
            if storage is any LampSyncRemoteStore {
                try await exportArchiveToRemote(storage: storage, replacing: nil)
            } else {
                try await exportLegacyToRemote(storage: storage)
            }
            return
        }
        if action == .adoptRemote {
            try importWholeFile(from: remoteSnapshot.data)
            if remoteSnapshot.isLegacy {
                try await exportArchiveToRemote(
                    storage: storage, replacing: remoteSnapshot
                )
            } else {
                var legacyRevision = remoteSnapshot.legacyFile?.revision
                if remoteSnapshot.legacyState == .superseded
                    || remoteSnapshot.legacyState == .absent,
                   let store = storage as? any LampSyncRemoteStore {
                    legacyRevision = try await mirrorLegacySettings(
                        remoteSnapshot.data,
                        replacing: remoteSnapshot.legacyFile,
                        in: store
                    )
                }
                storedChangeToken = remoteSnapshot.token
                let imported = try UserDatabase.shared.syncSnapshot()
                try rememberReadingsBase(
                    for: remoteSnapshot.source,
                    token: remoteSnapshot.token,
                    settings: imported.settings,
                    readingIDs: Set(imported.readings.map(\.id)),
                    legacyRevision: legacyRevision
                )
            }
            return
        }

        if action == .guardedFirstUpload {
            // Older installs have no saved membership baseline. Their first
            // pending upload remains guarded by the last observed token.
            guard remoteSnapshot.token == expectedStoredToken(for: remoteSnapshot.source) else {
                throw SyncError.conflictDetected
            }
            if remoteSnapshot.archiveSnapshot != nil && !remoteSnapshot.isLegacy {
                try await exportArchiveToRemote(
                    storage: storage, replacing: remoteSnapshot
                )
            } else {
                try await exportLegacyToRemote(
                    storage: storage, matching: remoteSnapshot.token
                )
            }
            guard let refreshed = try await readRemoteSettings(from: storage) else {
                throw SyncError.conflictDetected
            }
            remoteSnapshot = refreshed
        }
        var result: MergeResult?
        var legacyRevision = remoteSnapshot.legacyFile?.revision
        try await LampSyncEngine.run(
            pullAndMerge: {
                result = try mergeRemoteData(
                    remoteSnapshot.data,
                    base: applicableBase(for: remoteSnapshot, storage: storage)
                )
            },
            publish: {
                guard let result else { throw SyncError.incomplete }
                if result.needsPublish || remoteSnapshot.isLegacy {
                    if remoteSnapshot.archiveSnapshot != nil {
                        try await exportArchiveToRemote(
                            storage: storage, replacing: remoteSnapshot
                        )
                    } else {
                        try await exportLegacyToRemote(
                            storage: storage, matching: remoteSnapshot.token
                        )
                    }
                } else if remoteSnapshot.legacyState == .superseded
                            || remoteSnapshot.legacyState == .absent,
                          let store = storage as? any LampSyncRemoteStore {
                    legacyRevision = try await mirrorLegacySettings(
                        remoteSnapshot.data,
                        replacing: remoteSnapshot.legacyFile,
                        in: store
                    )
                }
            },
            complete: {
                guard let result else { throw SyncError.incomplete }
                guard !result.needsPublish && !remoteSnapshot.isLegacy else { return }
                let synced = try UserDatabase.shared.syncSnapshot()
                try rememberReadingsBase(
                    for: remoteSnapshot.source,
                    token: remoteSnapshot.token,
                    settings: synced.settings,
                    readingIDs: result.readingIDs,
                    legacyRevision: legacyRevision
                )
                storedChangeToken = remoteSnapshot.token
                UserDatabase.shared.clearUnsyncedChanges(through: synced.settings.updatedAt)
            }
        )
    }

    struct RemoteSettingsSnapshot {
        let data: Data
        let token: String?
        let source: String
        let archiveSnapshot: LampSyncSettingsArchive.RemoteSnapshot?
        let legacyFile: LampSyncRemoteFile?
        let legacyState: LampSyncSettingsArchive.LegacyState?

        var isLegacy: Bool { archiveSnapshot != nil && legacyState == nil }
    }

    func applicableBase(
        for snapshot: RemoteSettingsSnapshot,
        storage: ModuleStorage
    ) -> SettingsSyncBase? {
        if let base = readingsBase(for: snapshot.source) { return base }
        guard !snapshot.isLegacy,
              let revision = snapshot.archiveSnapshot?.legacyManifest?.legacyBaseRevision,
              let legacyBase = readingsBase(for: syncSource(for: storage)),
              legacyBase.token == LampSyncConditionalWrite.token(for: revision) else {
            return nil
        }
        return legacyBase
    }

    func readRemoteSettings(from storage: ModuleStorage) async throws -> RemoteSettingsSnapshot? {
        if let remoteStore = storage as? any LampSyncRemoteStore {
            let resolved: LampSyncSettingsArchive.ResolvedRemoteSnapshot?
            do {
                resolved = try await LampSyncSettingsArchive.readWithLegacy(
                    from: remoteStore
                )
            } catch LampSyncSettingsArchive.SettingsArchiveError.changedLegacyFile {
                throw SyncError.conflictDetected
            }
            guard let resolved else { return nil }
            return RemoteSettingsSnapshot(
                data: resolved.data,
                token: resolved.token,
                source: resolved.isLegacy
                    ? syncSource(for: storage) : archiveSource(for: storage),
                archiveSnapshot: resolved.archiveSnapshot,
                legacyFile: resolved.legacyFile,
                legacyState: resolved.legacyState
            )
        }
        do {
            let path = userSettingsPath
            let observed: LampSyncRemoteFile
            do {
                observed = try await LampSyncStableRead.read(
                    revision: { await storage.getChangeToken(path: path) },
                    data: { try await storage.readFile(path: path) },
                    bodyRevision: storage is ICloudModuleStorage
                        ? LampSyncContentRevision.token(for:)
                        : nil
                )
            } catch is LampSyncStableRead.ReadError {
                throw SyncError.conflictDetected
            }
            return RemoteSettingsSnapshot(
                data: observed.data,
                token: observed.revision,
                source: syncSource(for: storage),
                archiveSnapshot: nil,
                legacyFile: nil,
                legacyState: nil
            )
        } catch ModuleStorageError.fileNotFound {
            return nil
        }
    }

    private struct MergeResult {
        let needsPublish: Bool
        let readingIDs: Set<String>
    }

    private func comparableSettings(_ settings: UserSettings) -> UserSettings {
        var value = settings
        value.updatedAt = .distantPast
        return value
    }

    struct SettingsMergePlan {
        let applyRemoteSettings: Bool
        let readings: [CompletedReading]
        let readingIDs: Set<String>
        let needsPublish: Bool
    }

    func planSettingsMerge(
        localSettings: UserSettings,
        localReadings: [CompletedReading],
        remoteSettings: UserSettings,
        remoteReadings: [CompletedReading],
        base: SettingsSyncBase?
    ) throws -> SettingsMergePlan {
        let remoteRows = Dictionary(uniqueKeysWithValues: remoteReadings.map { ($0.id, $0) })
        let corePlan: LampSyncSettingsPlanner.Plan<String, CompletedReading>
        do {
            if let base {
                corePlan = try LampSyncSettingsPlanner.plan(
                    baseSettings: comparableSettings(base.settings),
                    baseReadingIDs: base.readingIDs,
                    localSettings: comparableSettings(localSettings),
                    localReadings: Dictionary(uniqueKeysWithValues:
                        localReadings.map { ($0.id, $0) }
                    ),
                    remoteSettings: comparableSettings(remoteSettings),
                    remoteReadings: remoteRows,
                    revision: \.completedAt
                )
            } else {
                corePlan = try LampSyncSettingsPlanner.planWithoutBase(
                    localSettings: comparableSettings(localSettings),
                    localRevision: localSettings.updatedAt,
                    localReadings: Dictionary(uniqueKeysWithValues:
                        localReadings.map { ($0.id, $0) }
                    ),
                    remoteSettings: comparableSettings(remoteSettings),
                    remoteRevision: remoteSettings.updatedAt,
                    remoteReadings: remoteRows
                )
            }
        } catch LampSyncSettingsPlanner.MergeError.concurrentSettings {
            throw SyncError.conflictDetected
        } catch LampSyncSettingsPlanner.MergeError.concurrentReading {
            throw SyncError.conflictDetected
        }
        return SettingsMergePlan(
            applyRemoteSettings: corePlan.settingsDecision == .remote,
            readings: corePlan.readingIDs.sorted().compactMap { corePlan.readings[$0] },
            readingIDs: corePlan.readingIDs,
            needsPublish: corePlan.needsPublish
        )
    }

    /// The saved base identifies deletions. Without it, reading rows must
    /// already agree after a guarded first upload or fresh installation.
    private func mergeRemoteData(
        _ remoteData: Data,
        base: SettingsSyncBase?
    ) throws -> MergeResult {
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
        let remoteSettings = try remoteDb.read { db in
            try UserSettings.fetchOne(db, key: 1)
        }
        guard let remoteSettings else { throw ModuleStorageError.invalidData }
        let local = try UserDatabase.shared.syncSnapshot()
        let plan = try planSettingsMerge(
            localSettings: local.settings,
            localReadings: local.readings,
            remoteSettings: remoteSettings,
            remoteReadings: remoteReadings,
            base: base
        )

        // Merge settings FIRST — before readings sync, which bumps updated_at
        // and would make the local always look newer than remote.
        let settingsUpdated: Bool
        if plan.applyRemoteSettings {
            settingsUpdated = try UserDatabase.shared.mergeSettings(
                from: remoteSettings, force: base != nil
            )
        } else {
            settingsUpdated = false
        }

        let readingsChanged = try UserDatabase.shared.syncCompletedReadings(
            with: plan.readings
        )

        if readingsChanged || settingsUpdated {
            print("[UserSettingsSync] Merged: readings \(readingsChanged ? "changed" : "unchanged"), settings \(settingsUpdated ? "updated" : "unchanged")")
            UserDatabase.shared.notifySyncChange()
        }

        return MergeResult(
            needsPublish: plan.needsPublish,
            readingIDs: plan.readingIDs
        )
    }

    // MARK: - Export to Remote

    private func mirrorLegacySettings(
        _ data: Data,
        replacing legacy: LampSyncRemoteFile?,
        in store: any LampSyncRemoteStore
    ) async throws -> String {
        do {
            return try await LampSyncSettingsArchive.publishLegacyMirror(
                data, replacing: legacy, in: store
            )
        } catch WebDAVError.preconditionFailed {
            throw SyncError.conflictDetected
        } catch LampSyncConditionalWrite.WriteError.conflict {
            throw SyncError.conflictDetected
        }
    }

    private func exportArchiveToRemote(
        storage: ModuleStorage,
        replacing observed: RemoteSettingsSnapshot?
    ) async throws {
        guard let store = storage as? any LampSyncRemoteStore,
              await storage.isAvailable() else {
            throw ModuleStorageError.notAvailable
        }
        let archiveSnapshot: LampSyncSettingsArchive.RemoteSnapshot
        let legacy: LampSyncRemoteFile?
        if let observed {
            guard let archive = observed.archiveSnapshot else {
                throw SyncError.conflictDetected
            }
            archiveSnapshot = archive
            legacy = observed.legacyFile
        } else {
            archiveSnapshot = try await LampSyncSettingsArchive.read(from: store)
            legacy = try await store.read(path: userSettingsPath)
            guard archiveSnapshot.data == nil, legacy == nil else {
                throw SyncError.conflictDetected
            }
        }

        try UserDatabase.shared.checkpointForSync()
        let portable = try portableSettingsData(from: UserDatabase.shared.databaseURL)
        let revision: String
        do {
            revision = try await LampSyncSettingsArchive.publish(
                portable.data,
                replacing: archiveSnapshot,
                observedLegacy: legacy,
                in: store
            )
        } catch WebDAVError.preconditionFailed {
            throw SyncError.conflictDetected
        } catch LampSyncConditionalWrite.WriteError.conflict {
            throw SyncError.conflictDetected
        }
        let token = LampSyncConditionalWrite.token(for: revision)
        storedChangeToken = token
        try rememberReadingsBase(
            for: archiveSource(for: storage),
            token: token,
            settings: portable.settings,
            readingIDs: portable.readingIDs,
            legacyRevision: legacy?.revision
        )
        UserDatabase.shared.clearUnsyncedChanges(through: portable.settings.updatedAt)

        if legacy?.data != portable.data {
            let legacyRevision = try await mirrorLegacySettings(
                portable.data, replacing: legacy, in: store
            )
            try rememberReadingsBase(
                for: archiveSource(for: storage),
                token: token,
                settings: portable.settings,
                readingIDs: portable.readingIDs,
                legacyRevision: legacyRevision
            )
        }
        print("[UserSettingsSync] Published archive settings")
    }

    /// Compatibility upload for iCloud and an older WebDAV installation's
    /// guarded first sync before it has an archive baseline.
    func exportLegacyToRemote(storage: ModuleStorage) async throws {
        guard !syncInProgress else { throw SyncError.alreadyRunning }
        syncInProgress = true
        defer { syncInProgress = false }
        try await exportLegacyToRemote(
            storage: storage,
            matching: expectedStoredToken(for: storage)
        )
    }

    private func exportLegacyToRemote(
        storage: ModuleStorage,
        matching expectedToken: String?
    ) async throws {
        guard await storage.isAvailable() else { throw ModuleStorageError.notAvailable }

        let conditionalStore = storage as? any LampSyncRemoteStore
        let writeCondition: LampSyncWriteCondition?
        if let conditionalStore {
            do {
                writeCondition = try await LampSyncConditionalWrite.condition(
                    for: userSettingsPath,
                    in: conditionalStore,
                    matching: expectedToken
                )
            } catch LampSyncConditionalWrite.WriteError.conflict {
                throw SyncError.conflictDetected
            }
        } else {
            // iCloud has no server-side compare-and-write operation. Retain
            // the change check for that provider while WebDAV uses HTTP
            // preconditions on the write itself.
            if let remoteToken = await storage.getChangeToken(path: userSettingsPath) {
                guard remoteToken == expectedToken else {
                    throw SyncError.conflictDetected
                }
            } else {
                do {
                    _ = try await storage.readFile(path: userSettingsPath)
                    throw SyncError.conflictDetected
                } catch ModuleStorageError.fileNotFound {
                    guard expectedToken == nil else {
                        throw SyncError.conflictDetected
                    }
                }
            }
            writeCondition = nil
        }

        try UserDatabase.shared.checkpointForSync()

        let portable = try portableSettingsData(from: UserDatabase.shared.databaseURL)

        if let conditionalStore, let writeCondition {
            do {
                let confirmedRevision = try await LampSyncConditionalWrite.writeAndConfirm(
                    portable.data,
                    to: userSettingsPath,
                    in: conditionalStore,
                    condition: writeCondition
                )
                storedChangeToken = LampSyncConditionalWrite.token(for: confirmedRevision)
            } catch WebDAVError.preconditionFailed {
                throw SyncError.conflictDetected
            } catch LampSyncConditionalWrite.WriteError.conflict {
                throw SyncError.conflictDetected
            }
        } else {
            if let iCloud = storage as? ICloudModuleStorage {
                try await iCloud.writeFile(
                    path: userSettingsPath,
                    data: portable.data,
                    matching: expectedToken
                )
            } else {
                try await storage.writeFile(path: userSettingsPath, data: portable.data)
            }
            storedChangeToken = await storage.getChangeToken(path: userSettingsPath)
        }
        try rememberReadingsBase(
            for: syncSource(for: storage),
            token: storedChangeToken,
            settings: portable.settings,
            readingIDs: portable.readingIDs
        )
        UserDatabase.shared.clearUnsyncedChanges(through: portable.settings.updatedAt)

        print("[UserSettingsSync] Exported to remote")
    }

    private struct PortableSettingsSnapshot {
        let data: Data
        let settings: UserSettings
        let readingIDs: Set<String>
    }

    private func portableSettingsData(from localURL: URL) throws -> PortableSettingsSnapshot {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copyURL = directory.appendingPathComponent("user.db")
        try FileManager.default.copyItem(at: localURL, to: copyURL)
        let snapshot: (UserSettings, Set<String>) = try {
            let queue = try DatabaseQueue(path: copyURL.path)
            _ = try queue.writeWithoutTransaction { db in
                try db.execute(sql: "UPDATE user_settings SET sync_settings_json = NULL WHERE id = 1")
                try db.checkpoint(.truncate)
            }
            return try queue.read { db in
                guard let settings = try UserSettings.fetchOne(db, key: 1) else {
                    throw ModuleStorageError.invalidData
                }
                let ids = try String.fetchAll(db, sql: "SELECT id FROM completed_readings")
                return (settings, Set(ids))
            }
        }()
        let data = try Data(contentsOf: copyURL)
        return PortableSettingsSnapshot(
            data: data,
            settings: snapshot.0,
            readingIDs: snapshot.1
        )
    }

    // MARK: - Whole-File Import (fresh install only)

    /// Replace local db file entirely with remote data. Used only for fresh installs.
    private func importWholeFile(from data: Data) throws {
        let localURL = UserDatabase.shared.databaseURL
        let localSyncSettings = UserDatabase.shared.getSyncSettings()
        let validationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: validationURL) }
        try data.write(to: validationURL, options: .atomic)
        var config = Configuration()
        config.readonly = true
        let remoteDb = try DatabaseQueue(path: validationURL.path, configuration: config)
        let isValid = try remoteDb.read { db in
            let check = try String.fetchOne(db, sql: "PRAGMA quick_check")
            let requiredTables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name IN ('user_settings', 'completed_readings')
                """)
            return check == "ok" && Set(requiredTables).count == 2
        }
        guard isValid else { throw ModuleStorageError.invalidData }

        // Backup current
        let backupURL = localURL.deletingLastPathComponent().appendingPathComponent("user.db.backup")
        let hadLocal = FileManager.default.fileExists(atPath: localURL.path)
        if hadLocal {
            try UserDatabase.shared.checkpointForSync()
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: localURL, to: backupURL)
        }

        // Close database before replacing file
        UserDatabase.shared.closeDatabase()

        // Delete WAL/SHM files before replacing the database.
        let walURL = localURL.appendingPathExtension("wal")
        let shmURL = localURL.appendingPathExtension("shm")
        do {
            for sidecar in [walURL, shmURL]
                where FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
            try data.write(to: localURL, options: .atomic)
        } catch {
            if hadLocal {
                try? FileManager.default.removeItem(at: localURL)
                try? FileManager.default.copyItem(at: backupURL, to: localURL)
            }
            UserDatabase.shared.reopenDatabase()
            throw error
        }

        // Reopen
        UserDatabase.shared.reopenDatabase()
        try UserDatabase.shared.restoreLocalSyncSettings(localSyncSettings)
        UserDatabase.shared.notifyExternalChange()
        print("[UserSettingsSync] Imported whole file from remote")
    }

    // MARK: - Fresh Install Detection

    /// Check if the local database only has default values
    private func isFreshInstall() -> Bool {
        guard let snapshot = try? UserDatabase.shared.syncSnapshot() else { return false }
        return snapshot.readings.isEmpty
            && comparableSettings(snapshot.settings) == comparableSettings(UserSettings())
    }

    // MARK: - Helpers

    private func getStorage() async -> ModuleStorage? {
        let storage = await SyncCoordinator.shared.activeStorage
        guard let storage, await storage.isAvailable() else { return nil }
        return storage
    }
}

/// Projects only preferences with the same meaning on iOS and Mac. The local
/// database remains the iOS source of truth; the archive ledger carries the
/// shared fields and their last-applied versions between platforms.
enum SharedPreferenceArchiveSync {
    enum ArchiveExpectation {
        case unchecked
        case revision(String?)
    }

    private static let baseKey = "SharedPreferenceArchiveSync.bases.v1"

    static func sync(
        from store: any LampSyncRemoteStore,
        source: String,
        defaults: UserDefaults = .standard,
        snapshot: LampSyncArchiveRemote.Snapshot? = nil,
        expectation: ArchiveExpectation = .unchecked
    ) async throws {
        let remoteArchive: LampSyncArchiveRemote.Snapshot?
        if let snapshot {
            remoteArchive = snapshot
        } else {
            remoteArchive = try await LampSyncArchiveRemote.read(from: store)
        }
        if case .revision(let expected) = expectation,
           remoteArchive?.revision != expected {
            throw SyncError.conflictDetected
        }
        guard let remoteArchive else {
            return
        }
        let archive = remoteArchive.archive
        let remoteLedger = try LampSyncPreferenceState.ledger(in: archive)

        let previous = LampSyncPreferenceState.cached(
            for: source, in: defaults, key: baseKey
        )
        let local = projectedValues(from: UserDatabase.shared.getSettings(), base: previous)
        let merged = try LampSharedPreferenceLedger.merge(
            local: local,
            base: previous,
            remote: remoteLedger
        )

        if merged != remoteLedger && !merged.fields.isEmpty {
            let updated = try LampSyncPreferenceState.replacing(merged, in: archive)
            try await LampSyncArchiveRemote.publish(
                updated,
                replacing: remoteArchive,
                in: store
            )
        }

        try apply(merged)
        try LampSyncPreferenceState.remember(
            merged, for: source, in: defaults, key: baseKey
        )
    }

    private static func projectedValues(
        from settings: UserSettings,
        base: LampSharedPreferenceLedger?
    ) -> [String: LampSharedPreferenceLedger.Value] {
        let standard = UserSettings()
        var values: [String: LampSharedPreferenceLedger.Value] = [:]
        func shouldInclude(_ key: String, differsFromDefault: Bool) -> Bool {
            differsFromDefault || base?.fields[key]?.value != nil
        }
        if shouldInclude("reader.fontSize", differsFromDefault: settings.readerFontSize != standard.readerFontSize) {
            values["reader.fontSize"] = .number(rounded(settings.readerFontSize))
        }
        if !settings.readerTranslationId.isEmpty,
           shouldInclude(
               "reader.defaultTranslationID",
               differsFromDefault: settings.readerTranslationId != standard.readerTranslationId
           ) {
            values["reader.defaultTranslationID"] = .string(settings.readerTranslationId)
        }
        if shouldInclude(
            "reader.showStrongsHints",
            differsFromDefault: settings.showStrongsHints != standard.showStrongsHints
        ) {
            values["reader.showStrongsHints"] = .boolean(settings.showStrongsHints)
        }
        if shouldInclude("devotional.fontSize", differsFromDefault: settings.devotionalFontSize != standard.devotionalFontSize) {
            values["devotional.fontSize"] = .number(rounded(settings.devotionalFontSize))
        }
        if shouldInclude("plans.reminder.enabled", differsFromDefault: settings.planNotification != standard.planNotification) {
            values["plans.reminder.enabled"] = .boolean(settings.planNotification)
        }
        if shouldInclude("plans.reminder.hour", differsFromDefault: settings.planNotificationHour != standard.planNotificationHour) {
            values["plans.reminder.hour"] = .integer(settings.planNotificationHour)
        }
        if shouldInclude("plans.reminder.minute", differsFromDefault: settings.planNotificationMinute != standard.planNotificationMinute) {
            values["plans.reminder.minute"] = .integer(settings.planNotificationMinute)
        }
        return values
    }

    private static func rounded(_ value: Float) -> Double {
        (Double(value) * 1000).rounded() / 1000
    }

    private static func apply(_ ledger: LampSharedPreferenceLedger) throws {
        let current = UserDatabase.shared.getSettings()
        var updated = current
        overwrite(&updated, with: ledger)
        guard current.readerFontSize != updated.readerFontSize
            || current.readerTranslationId != updated.readerTranslationId
            || current.showStrongsHints != updated.showStrongsHints
            || current.devotionalFontSize != updated.devotionalFontSize
            || current.planNotification != updated.planNotification
            || current.planNotificationHour != updated.planNotificationHour
            || current.planNotificationMinute != updated.planNotificationMinute else { return }
        try UserDatabase.shared.updateSettings { settings in
            overwrite(&settings, with: ledger)
        }
    }

    private static func overwrite(
        _ settings: inout UserSettings,
        with ledger: LampSharedPreferenceLedger
    ) {
        let standard = UserSettings()
        for (key, field) in ledger.fields {
            switch key {
            case "reader.fontSize":
                if case .some(.number(let value)) = field.value {
                    settings.readerFontSize = Float(value)
                } else if field.value == nil {
                    settings.readerFontSize = standard.readerFontSize
                }
            case "reader.defaultTranslationID":
                if case .some(.string(let value)) = field.value {
                    settings.readerTranslationId = value
                } else if field.value == nil {
                    settings.readerTranslationId = standard.readerTranslationId
                }
            case "reader.showStrongsHints":
                if case .some(.boolean(let value)) = field.value {
                    settings.showStrongsHints = value
                } else if field.value == nil {
                    settings.showStrongsHints = standard.showStrongsHints
                }
            case "devotional.fontSize":
                if case .some(.number(let value)) = field.value {
                    settings.devotionalFontSize = Float(value)
                } else if field.value == nil {
                    settings.devotionalFontSize = standard.devotionalFontSize
                }
            case "plans.reminder.enabled":
                if case .some(.boolean(let value)) = field.value {
                    settings.planNotification = value
                } else if field.value == nil {
                    settings.planNotification = standard.planNotification
                }
            case "plans.reminder.hour":
                if case .some(.integer(let value)) = field.value {
                    settings.planNotificationHour = value
                } else if field.value == nil {
                    settings.planNotificationHour = standard.planNotificationHour
                }
            case "plans.reminder.minute":
                if case .some(.integer(let value)) = field.value {
                    settings.planNotificationMinute = value
                } else if field.value == nil {
                    settings.planNotificationMinute = standard.planNotificationMinute
                }
            default:
                break
            }
        }
    }
}
