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
        if let endpoint = storage as? any LibraryEndpoint {
            return endpoint.librarySource
        }
        if let webDAV = storage as? WebDAVModuleStorage {
            return webDAV.syncSourceIdentifier
        }
        if storage is ICloudModuleStorage { return "icloud-documents" }
        return String(reflecting: type(of: storage))
    }

    private func cachedReadingsBase() -> SettingsSyncBase? {
        guard let data = UserDefaults.standard.data(forKey: Self.readingsBaseKey),
              let base = try? JSONDecoder().decode(SettingsSyncBase.self, from: data) else {
            return nil
        }
        return base
    }

    /// The settings and readings this device last agreed on with the
    /// endpoint: the base a merge with its bundle is taken against.
    private func readingsBase(for source: String) -> SettingsSyncBase? {
        guard let base = cachedReadingsBase(), base.source == source else { return nil }
        return base
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
            // A library still in the earlier shape syncs nothing until it moves.
            if let endpoint = libraryEndpoint(for: storage), LibrarySyncPass.isInUse(at: endpoint) {
                LibrarySyncPass.schedule(on: endpoint, after: 0)
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
        if let endpoint = libraryEndpoint(for: storage),
           let revision = LibrarySyncPass.bundleRevision(for: endpoint.librarySource) {
            var due = LibrarySyncPass.hasLocalWork(at: endpoint)
            if !due {
                due = (try? await LampSyncSettingsStore.hasChanged(since: revision, in: endpoint)) ?? true
            }
            guard due else { return }
            do {
                try await LibrarySyncPass.runIfMigrated(storage: endpoint)
            } catch {
                print("[UserSettingsSync] Poll: library pass failed: \(error)")
            }
            return
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
    private static let baseKey = "SharedPreferenceArchiveSync.bases.v1"

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
    ///
    /// `versions` are copies another device wrote that iCloud kept beside
    /// the current one rather than refusing. One of them may be this
    /// device's own lost write, recorded as its base when it returned; a
    /// three-way merge against that base would read the current copy's
    /// older values as edits and undo it. So with versions present the base
    /// is set aside: each version, then the current copy, is merged without
    /// one (readings as a union, settings field by field by time), and the
    /// result is published, which resolves them.
    func bundleParticipants(
        for bundle: LampSyncSettingsBundle?,
        versions: [LampSyncSettingsBundle] = [],
        storage: ModuleStorage
    ) throws -> [any SettingsBundleParticipant] {
        let source = bundleSource(for: storage)
        let remote = bundle?.userSettings
        var merged: MergeResult?
        if versions.isEmpty {
            if let remote {
                merged = try mergeRemoteData(remote, base: readingsBase(for: source))
            }
        } else {
            for version in versions {
                if let data = version.userSettings { _ = try mergeRemoteData(data, base: nil) }
            }
            if let remote { merged = try mergeRemoteData(remote, base: nil) }
        }
        try UserDatabase.shared.checkpointForSync()
        let portable = try portableSettingsData(from: UserDatabase.shared.databaseURL)
        let publishes = remote == nil || merged?.needsPublish == true || !versions.isEmpty
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
