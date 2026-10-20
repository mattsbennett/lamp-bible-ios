//
//  UserSettingsSyncManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-02-22.
//

import Foundation
import GRDB
import LampModuleKit

/// Name a conflict in the log without changing what is thrown.
///
/// Nineteen places in this file raise `conflictDetected`, and the console
/// showed only the symbol: enough to know a poll failed, not which check
/// failed it. The difference decides what to do about it. A token or a
/// revision that moved under the poll means something else wrote while this
/// was working, and the next poll carries on; a concurrent settings or
/// reading divergence repeats until it is merged.
private nonisolated func settingsSyncConflict(
    _ reason: String,
    function: StaticString = #function,
    line: UInt = #line
) -> SyncError {
    print("[UserSettingsSync] conflict: \(reason) (\(function):\(line))")
    return .conflictDetected
}

/// The same, for the two places a sync declines to start because one is
/// already under way. Which one it was says who is colliding with whom.
private nonisolated func settingsSyncAlreadyRunning(
    _ reason: String,
    function: StaticString = #function,
    line: UInt = #line
) -> SyncError {
    print("[UserSettingsSync] already running: \(reason) (\(function):\(line))")
    return .alreadyRunning
}

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

    /// When a pass that went to the WebDAV archive last ended.
    ///
    /// While settings live inside the library archive, each such pass
    /// downloads the whole library and, with a change to send, uploads it and
    /// reads it back: well over a gigabyte for one finished reading. A guest
    /// working through a plan set one off every thirty seconds. The poll and
    /// the debounced export leave this much time between them; the
    /// foreground sync and the reconcile on going to the background do not.
    /// Design B, which moves settings out of the archive, retires this.
    private var lastArchivePassEndedAt: Date?
    static let archivePassSpacing: TimeInterval = 300

    nonisolated static func archivePassIsDue(
        lastEnded: Date?,
        now: Date,
        spacing: TimeInterval = archivePassSpacing
    ) -> Bool {
        guard let lastEnded else { return true }
        return now.timeIntervalSince(lastEnded) >= spacing
    }

    private var archivePassIsDue: Bool {
        Self.archivePassIsDue(lastEnded: lastArchivePassEndedAt, now: Date())
    }

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
            if let webDAV = storage as? WebDAVModuleStorage, LibrarySyncPass.isInUse(at: webDAV) {
                LibrarySyncPass.schedule(on: webDAV, after: 0)
                return
            }
            if storage is any LampSyncRemoteStore, self?.archivePassIsDue == false {
                print("[UserSettingsSync] Debounce: archive pass held back; the poll will send it")
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
        // The settings bundle: one HEAD says whether anyone else wrote, and
        // a pass runs only then or with something of this device's to send.
        if let webDAV = storage as? WebDAVModuleStorage,
           let revision = LibrarySyncPass.bundleRevision(for: webDAV.syncSourceIdentifier) {
            var due = LibrarySyncPass.hasLocalWork(at: webDAV)
            if !due {
                due = (try? await LampSyncSettingsStore.hasChanged(since: revision, in: webDAV)) ?? true
            }
            guard due else { return }
            do {
                try await LibrarySyncPass.runIfMigrated(storage: webDAV)
            } catch {
                print("[UserSettingsSync] Poll: library pass failed: \(error)")
            }
            return
        }
        // The archive and the legacy settings file can change independently.
        // Read both so an older client's edit cannot be hidden by an unchanged
        // archive revision.
        if storage is any LampSyncRemoteStore {
            if await canSkipUnchangedArchivePoll(storage: storage) { return }
            guard archivePassIsDue else {
                print("[UserSettingsSync] Poll: archive pass held back until \(Int(Self.archivePassSpacing))s after the last")
                return
            }
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
    /// What a settings pass leaves behind for the caller that runs next.
    ///
    /// The archive is handed over rather than kept: the whole of it is decoded
    /// in memory, so holding one on this singleton between passes would keep
    /// every module body resident for the life of the app. The caller uses it
    /// within the pass and lets it go.
    struct FullSyncOutcome {
        let succeeded: Bool
        /// The archive this pass read. Whether it is still what the server
        /// holds is for the caller to confirm, cheaply, by revision.
        let observedArchive: LampSyncArchiveRemote.Snapshot?
        /// The pass settled it by revision alone and never fetched a body,
        /// so neither need the caller.
        let skippedUnchanged: Bool
    }

    func performFullSync(
        using storage: ModuleStorage,
        reusing candidate: LampSyncArchiveRemote.Snapshot? = nil
    ) async -> FullSyncOutcome {
        guard await storage.isAvailable() else {
            print("[UserSettingsSync] Storage not available")
            return FullSyncOutcome(
                succeeded: false, observedArchive: nil, skippedUnchanged: false
            )
        }
        // The thirty-second poll has always taken this exit. The launch pass
        // never did, and so paid for the whole library to be downloaded and
        // inflated in order to reach a settings entry that two revisions had
        // already shown could not have changed.
        if await canSkipUnchangedArchivePoll(storage: storage) {
            print("[UserSettingsSync] unchanged, settings not read")
            return FullSyncOutcome(
                succeeded: true, observedArchive: nil, skippedUnchanged: true
            )
        }
        lastObservedArchive = nil
        do {
            try await syncWithRemote(
                storage: storage, requireRemote: false, reusing: candidate
            )
            return FullSyncOutcome(
                succeeded: true, observedArchive: takeLastObservedArchive(),
                skippedUnchanged: false
            )
        } catch {
            print("[UserSettingsSync] Full sync failed: \(error)")
            return FullSyncOutcome(
                succeeded: false, observedArchive: takeLastObservedArchive(),
                skippedUnchanged: false
            )
        }
    }

    /// Set while a pass reads the archive, and taken by whoever asks first.
    private var lastObservedArchive: LampSyncArchiveRemote.Snapshot?

    private func takeLastObservedArchive() -> LampSyncArchiveRemote.Snapshot? {
        defer { lastObservedArchive = nil }
        return lastObservedArchive
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

    /// The settings pass already under way, so a second caller can wait for
    /// it rather than be turned away.
    private var inFlightSync: Task<Void, Error>?

    /// Run a settings pass, waiting for one already running rather than
    /// refusing.
    ///
    /// Refusing failed the caller outright, and on launch the caller is the
    /// module publish: one overlapping poll and the phone published nothing
    /// at all — not its settings, not its notes, not its writing. The
    /// collision is also entirely ordinary, since a launch pass and the
    /// thirty-second poll are both meant to be happening.
    ///
    /// The waiting pass then runs its own, rather than adopting the result
    /// of one it did not specify: the two callers do not ask for the same
    /// thing, and `requireRemote` in particular means a caller cannot be
    /// told someone else's pass satisfied it.
    private func syncWithRemote(
        storage: ModuleStorage,
        requireRemote: Bool,
        reusing candidate: LampSyncArchiveRemote.Snapshot? = nil
    ) async throws {
        // Once the server holds the settings bundle, settings travel in it,
        // with the rest of the library pass.
        if let webDAV = storage as? WebDAVModuleStorage, LibrarySyncPass.isInUse(at: webDAV) {
            try await LibrarySyncPass.runIfMigrated(storage: webDAV)
            return
        }
        while let running = inFlightSync {
            _ = try? await running.value
        }
        let task = Task { @MainActor in
            // Cleared here rather than by the caller, so that anyone waiting
            // resumes to find the slot free.
            defer {
                self.inFlightSync = nil
                if storage is any LampSyncRemoteStore {
                    self.lastArchivePassEndedAt = Date()
                }
            }
            try await self.runSyncWithRemote(
                storage: storage, requireRemote: requireRemote, reusing: candidate
            )
        }
        inFlightSync = task
        try await task.value
    }

    private func runSyncWithRemote(
        storage: ModuleStorage,
        requireRemote: Bool,
        reusing candidate: LampSyncArchiveRemote.Snapshot?
    ) async throws {
        guard !syncInProgress else { throw settingsSyncAlreadyRunning("another settings sync is still running") }
        syncInProgress = true
        defer { syncInProgress = false }
        let observed = try await readRemoteSettings(from: storage, reusing: candidate)
        lastObservedArchive = observed?.archiveSnapshot?.archive
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

        // Older installs have no saved membership baseline. Their first
        // pending upload is guarded by the last observed token: send it only
        // while the server still holds what this device last saw.
        //
        // When it does not, the upload is skipped and the merge below runs
        // instead. Refusing the whole sync here settled nothing: the inputs
        // were unchanged by the refusal, so the next poll took the same
        // branch and failed the same way, every thirty seconds, for good. A
        // device in that state could never upload its settings nor earn the
        // base that would get it out. It is also not a rare corner — on an
        // archive source with no base recorded for it, expectedStoredToken is
        // nil, so the comparison can never hold, and any write to the shared
        // archive moves the token besides. The merge is what the guard was
        // protecting anyway: with no base it reconciles through
        // planWithoutBase rather than overwriting what it has not seen. An
        // unknown revision on either side can't show the server is unchanged,
        // so it takes the merge too. Core owns the rule, where the sync model
        // checks it.
        if LampSyncSettingsBootstrap.uploadsBeforeMerge(
            action: action,
            observedToken: expectedStoredToken(for: remoteSnapshot.source),
            remoteToken: remoteSnapshot.token
        ) {
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
                throw settingsSyncConflict("the settings were gone from the server when re-read after writing")
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

    func readRemoteSettings(
        from storage: ModuleStorage,
        reusing candidate: LampSyncArchiveRemote.Snapshot? = nil
    ) async throws -> RemoteSettingsSnapshot? {
        if let remoteStore = storage as? any LampSyncRemoteStore {
            let resolved: LampSyncSettingsArchive.ResolvedRemoteSnapshot?
            do {
                resolved = try await LampSyncSettingsArchive.readWithLegacy(
                    from: remoteStore, reusing: candidate
                )
            } catch LampSyncSettingsArchive.SettingsArchiveError.changedLegacyFile {
                throw settingsSyncConflict("the legacy settings file changed while the archive was being read")
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
                throw settingsSyncConflict("the server kept changing while the settings were being read")
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
                    remoteReadings: remoteRows,
                    revision: \.completedAt
                )
            }
        } catch LampSyncSettingsPlanner.MergeError.concurrentSettings {
            throw settingsSyncConflict("settings were edited on another device at the same time")
        } catch LampSyncSettingsPlanner.MergeError.concurrentReading {
            throw settingsSyncConflict("a reading position moved on another device at the same time")
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
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            throw settingsSyncConflict("the server refused the legacy mirror: it had changed first")
        } catch LampSyncConditionalWrite.WriteError.conflict {
            throw settingsSyncConflict("the legacy mirror's base no longer matched")
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
                throw settingsSyncConflict("the observed snapshot had no archive to replace")
            }
            archiveSnapshot = archive
            legacy = observed.legacyFile
        } else {
            archiveSnapshot = try await LampSyncSettingsArchive.read(from: store)
            legacy = try await store.read(path: userSettingsPath)
            guard archiveSnapshot.data == nil, legacy == nil else {
                throw settingsSyncConflict("a first upload found an archive or legacy file already there")
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
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            throw settingsSyncConflict("the server refused the archive write: it had changed first")
        } catch LampSyncConditionalWrite.WriteError.conflict {
            throw settingsSyncConflict("the archive's base no longer matched")
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
        guard !syncInProgress else { throw settingsSyncAlreadyRunning("another settings sync is still running") }
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
                throw settingsSyncConflict("the legacy upload's base no longer matched")
            }
        } else {
            // iCloud has no server-side compare-and-write operation. Retain
            // the change check for that provider while WebDAV uses HTTP
            // preconditions on the write itself.
            if let remoteToken = await storage.getChangeToken(path: userSettingsPath) {
                guard remoteToken == expectedToken else {
                    throw settingsSyncConflict("the legacy file's change token moved under the upload")
                }
            } else {
                do {
                    _ = try await storage.readFile(path: userSettingsPath)
                    throw settingsSyncConflict("a legacy file exists where the upload expected none")
                } catch ModuleStorageError.fileNotFound {
                    guard expectedToken == nil else {
                        throw settingsSyncConflict("the legacy file is gone but a token was still expected")
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
            } catch LampWebDAVStorage.StorageError.preconditionFailed {
                throw settingsSyncConflict("the server refused the legacy upload: it had changed first")
            } catch LampSyncConditionalWrite.WriteError.conflict {
                throw settingsSyncConflict("the legacy upload's base no longer matched")
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
            throw settingsSyncConflict("the archive revision moved under the shared preference write")
        }
        guard let remoteArchive else {
            // Nothing on the server to merge against, so nothing is recorded
            // either — and the next pass will say it has nothing recorded.
            print("[SharedPreferences] no archive on the server; nothing recorded")
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

        // Each step below can throw, and until now a throw here left no
        // trace: the pass simply never recorded a ledger, and every later
        // pass reported having nothing recorded. Name the step instead.
        do {
            if merged.publishable != remoteLedger && !merged.publishable.fields.isEmpty {
                let updated = try LampSyncPreferenceState.replacing(
                    merged.publishable, in: archive
                )
                try await LampSyncArchiveRemote.publish(
                    updated,
                    replacing: remoteArchive,
                    in: store
                )
                print("[SharedPreferences] published \(merged.publishable.fields.count) field(s)")
            }
        } catch {
            print("[SharedPreferences] publishing failed, so nothing is recorded: \(error)")
            throw error
        }

        do {
            try apply(merged.applicable)
        } catch {
            print("[SharedPreferences] applying failed, so nothing is recorded: \(error)")
            throw error
        }

        do {
            try LampSyncPreferenceState.remember(
                merged.baseline, for: source, in: defaults, key: baseKey
            )
            print("[SharedPreferences] recorded \(merged.baseline.fields.count) field(s)")
        } catch {
            print("[SharedPreferences] recording failed: \(error)")
            throw error
        }
    }

    /// Whether this device holds a preference edit the server has not seen.
    ///
    /// Local state only — no request, no archive. It lets a caller that has
    /// already established the archive has not moved conclude there is
    /// nothing for a preference merge to do. Asked through the real merge
    /// rather than by comparing shapes: with the remote standing still,
    /// anything the merge would change is a local edit waiting to go up. No
    /// cached base means no idea, which counts as changed.
    static func hasLocalChanges(
        source: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let previous = LampSyncPreferenceState.cached(
            for: source, in: defaults, key: baseKey
        ) else {
            // Nothing recorded for this server yet, so there is no telling.
            // Expected on the first pass that gets this far, and the reason
            // it is worth saying out loud rather than inferring from a later
            // archive read.
            print("[SharedPreferences] pending: nothing recorded for this source yet")
            return true
        }
        let local = projectedValues(from: UserDatabase.shared.getSettings(), base: previous)
        guard let merged = try? LampSharedPreferenceLedger.merge(
            local: local, base: previous, remote: previous
        ) else {
            print("[SharedPreferences] pending: the recorded ledger would not merge")
            return true
        }
        guard merged.publishable != previous else { return false }
        // Name the fields rather than just the verdict: a field that never
        // settles would otherwise look exactly like a field someone edited,
        // and only one of those is worth chasing.
        let moved = Set(merged.publishable.fields.keys).union(previous.fields.keys)
            .filter { merged.publishable.fields[$0]?.value != previous.fields[$0]?.value }
            .sorted()
        print("[SharedPreferences] pending: \(moved.joined(separator: ", "))")
        return true
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

// MARK: - Design B: settings in the bundle

extension UserSettingsSyncManager {
    /// The settings and preference bases for the bundle, kept apart from the
    /// archive's: the revisions they were taken at are the bundle's own.
    func bundleSource(for storage: ModuleStorage) -> String {
        "bundle:" + syncSource(for: storage)
    }

    /// The bundle's settings and completed readings merged into this device
    /// now, and what the pass's one bundle write should carry back.
    ///
    /// The merge is a SQLite file merge that applies as it goes, so it runs
    /// here, before the write, rather than in `change`, which must only
    /// compute. `change` then checks the bundle still holds what was merged.
    func bundleParticipants(
        for bundle: LampSyncSettingsBundle?,
        storage: ModuleStorage
    ) throws -> [any SettingsBundleParticipant] {
        let source = bundleSource(for: storage)
        let remote = bundle?.userSettings
        var merged: MergeResult?
        if let remote {
            merged = try mergeRemoteData(remote, base: readingsBase(for: source))
        }
        try UserDatabase.shared.checkpointForSync()
        let portable = try portableSettingsData(from: UserDatabase.shared.databaseURL)
        let publishes = remote == nil || merged?.needsPublish == true
        let settings = BundleSettingsParticipant(
            source: source,
            mergedAgainst: remote,
            publish: publishes ? portable.data : nil,
            settings: portable.settings,
            readingIDs: publishes ? portable.readingIDs : (merged?.readingIDs ?? portable.readingIDs)
        )
        return [settings, SharedPreferenceArchiveSync.BundleParticipant(source: source)]
    }

    fileprivate func rememberBundleSettings(
        source: String, revision: String, settings: UserSettings, readingIDs: Set<String>
    ) throws {
        try rememberReadingsBase(
            for: source, token: LampSyncConditionalWrite.token(for: revision),
            settings: settings, readingIDs: readingIDs
        )
        UserDatabase.shared.clearUnsyncedChanges(through: settings.updatedAt)
    }
}

@MainActor
private struct BundleSettingsParticipant: SettingsBundleParticipant {
    let source: String
    let mergedAgainst: Data?
    let publish: Data?
    let settings: UserSettings
    let readingIDs: Set<String>

    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        guard bundle.userSettings == mergedAgainst else { throw LibrarySyncPass.BundleMoved() }
        if let publish { bundle.userSettings = publish }
    }

    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
        try UserSettingsSyncManager.shared.rememberBundleSettings(
            source: source, revision: written.revision, settings: settings, readingIDs: readingIDs
        )
    }
}

extension SharedPreferenceArchiveSync {
    /// The preference ledger, which the merge settles without touching this
    /// device, so it runs in `change`; what the written bundle settled is
    /// applied after.
    @MainActor
    final class BundleParticipant: SettingsBundleParticipant {
        let source: String
        let defaults: UserDefaults
        private var settled: LampSharedPreferenceLedger.Merge?

        init(source: String, defaults: UserDefaults = .standard) {
            self.source = source
            self.defaults = defaults
        }

        func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
            let previous = LampSyncPreferenceState.cached(for: source, in: defaults, key: baseKey)
            let local = projectedValues(from: UserDatabase.shared.getSettings(), base: previous)
            let merged = try LampSharedPreferenceLedger.merge(
                local: local, base: previous, remote: bundle.preferences
            )
            if merged.publishable != bundle.preferences && !merged.publishable.fields.isEmpty {
                bundle.preferences = merged.publishable
            }
            settled = merged
        }

        func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
            guard let settled else { return }
            try apply(settled.applicable)
            try LampSyncPreferenceState.remember(settled.baseline, for: source, in: defaults, key: baseKey)
        }
    }
}
