//
//  UserDatabase.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2025-01-12.
//

import Foundation
import GRDB
import LampCore

/// Notification posted when UserDatabase detects remote changes (from any sync provider)
extension Notification.Name {
    static let userDatabaseDidChange = Notification.Name("userDatabaseDidChange")
}

/// Manages user settings and completed readings with sync support
class UserDatabase {
    static let shared = UserDatabase()

    private var dbQueue: DatabaseQueue?
    private let localURL: URL
    let databaseExistedAtLaunch: Bool
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?

    /// Settings are read from dozens of call sites, several of them inside
    /// SwiftUI view bodies, so the singleton row is memoised and invalidated on
    /// every write path.
    private var cachedSettings: UserSettings?
    private let cacheLock = NSLock()

    /// Timestamp of the most recent write we made ourselves. The file monitor
    /// sees those writes too and would otherwise re-post a notification we have
    /// already sent directly — doubling every downstream refresh.
    private var lastLocalWriteAt: Date = .distantPast
    private let localWriteLock = NSLock()
    private let localWriteSuppressionWindow: TimeInterval = 1.0

    private static let lastExportedAtKey = "UserDatabase.lastExportedAt"

    /// True when local changes have been made that haven't been exported yet
    var hasUnsyncedChanges: Bool {
        guard let lastExported = UserDefaults.standard.object(forKey: Self.lastExportedAtKey) as? Date else {
            // Never exported — check if there's any data worth exporting
            return getSettings().updatedAt > Date.distantPast
        }
        return getSettings().updatedAt > lastExported
    }

    private init() {
        // Always use local storage - sync happens via ModuleSyncManager
        localURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("UserData")
        databaseExistedAtLaunch = FileManager.default.fileExists(
            atPath: localURL.appendingPathComponent("user.db").path
        )

        setupDatabase()
        startFileMonitoring()
    }

    deinit {
        stopFileMonitoring()
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        let dbURL = localURL.appendingPathComponent("user.db")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: localURL,
            withIntermediateDirectories: true
        )

        // Configure GRDB
        let config = Configuration()

        do {
            dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

            // Run migrations
            try migrator.migrate(dbQueue!)
            print("[UserDB] Database initialized at: \(dbURL.path)")
        } catch {
            print("[UserDB] Failed to initialize: \(error)")
        }
    }

    /// Get the database file URL (for sync export/import)
    var databaseURL: URL {
        localURL.appendingPathComponent("user.db")
    }

    // MARK: - File Change Monitoring

    private func startFileMonitoring() {
        let dbURL = databaseURL

        fileDescriptor = open(dbURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[UserDB] Could not open file for monitoring: \(dbURL.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.handleFileChange()
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        source.resume()
        fileMonitorSource = source
        print("[UserDB] File monitoring active")
    }

    private func handleFileChange() {
        // Debounce rapid changes
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Writes we made ourselves already posted a notification directly;
            // don't post a second one for the same change.
            guard !self.isRecentLocalWrite else { return }
            self.invalidateSettingsCache()
            self.notifyDatabaseChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Record that we just wrote to the database ourselves.
    private func markLocalWrite() {
        localWriteLock.lock()
        lastLocalWriteAt = Date()
        localWriteLock.unlock()
    }

    private var isRecentLocalWrite: Bool {
        localWriteLock.lock()
        defer { localWriteLock.unlock() }
        return Date().timeIntervalSince(lastLocalWriteAt) < localWriteSuppressionWindow
    }

    private func invalidateSettingsCache() {
        cacheLock.lock()
        cachedSettings = nil
        cacheLock.unlock()
    }

    private func notifyDatabaseChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .userDatabaseDidChange, object: nil)
        }
    }

    private func stopFileMonitoring() {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
    }

    /// Notify that database was updated from sync (call after importing)
    func notifyExternalChange() {
        // Imported data doesn't need re-exporting — mark as synced
        UserDefaults.standard.set(Date(), forKey: Self.lastExportedAtKey)
        invalidateSettingsCache()
        notifyDatabaseChange()
    }

    /// Refresh readers after a merged pull without claiming that its pending
    /// publish has already succeeded.
    func notifySyncChange() {
        invalidateSettingsCache()
        notifyDatabaseChange()
    }

    /// Mark that local changes have been exported
    func clearUnsyncedChanges(through exportedAt: Date = Date()) {
        UserDefaults.standard.set(exportedAt, forKey: Self.lastExportedAtKey)
    }

    /// Close the database connection and stop file monitoring.
    /// Call before replacing the database file on disk.
    func closeDatabase() {
        stopFileMonitoring()
        invalidateSettingsCache()
        dbQueue = nil
    }

    /// Close and reopen the database from the file on disk.
    /// Call after replacing the database file to pick up new data.
    func reopenDatabase() {
        stopFileMonitoring()
        invalidateSettingsCache()
        dbQueue = nil
        setupDatabase()
        startFileMonitoring()
        // While the database was shut, every `getSettings()` handed out
        // defaults. Readers that built something from those need to know it is
        // readable again — the caller's own notification only covers the path
        // where the replacement succeeded.
        notifyDatabaseChange()
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // Speed up development by nuking the database when schema changes
        // migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            // user_settings table (singleton)
            try db.create(table: "user_settings") { t in
                t.column("id", .integer).primaryKey().defaults(to: 1)
                t.column("selected_plan_ids", .text).notNull().defaults(to: "")
                t.column("plan_in_app_bible", .integer).notNull().defaults(to: 1)
                t.column("plan_external_bible", .text)
                t.column("plan_wpm", .double).notNull().defaults(to: 183.0)
                t.column("plan_notification", .integer).notNull().defaults(to: 0)
                t.column("plan_notification_hour", .integer).notNull().defaults(to: 18)
                t.column("plan_notification_minute", .integer).notNull().defaults(to: 30)
                t.column("reader_translation_id", .text).notNull().defaults(to: "BSBs")
                t.column("reader_cross_reference_sort", .text).notNull().defaults(to: "r")
                t.column("reader_font_size", .double).notNull().defaults(to: 18.0)
                t.column("updated_at", .datetime).notNull()
            }

            // Add check constraint for singleton
            try db.execute(sql: """
                CREATE TRIGGER user_settings_singleton_insert
                BEFORE INSERT ON user_settings
                WHEN (SELECT COUNT(*) FROM user_settings) >= 1
                BEGIN
                    SELECT RAISE(ABORT, 'Only one user_settings row allowed');
                END
            """)

            // completed_readings table
            try db.create(table: "completed_readings") { t in
                t.column("id", .text).primaryKey()
                t.column("plan_id", .text).notNull()
                t.column("year", .integer).notNull()
                t.column("completed_at", .datetime).notNull()
            }

            try db.create(index: "idx_completed_readings_plan", on: "completed_readings", columns: ["plan_id"])
            try db.create(index: "idx_completed_readings_year", on: "completed_readings", columns: ["year"])

            // Insert default user settings
            try db.execute(sql: """
                INSERT INTO user_settings (id, updated_at) VALUES (1, datetime('now'))
            """)
        }

        migrator.registerMigration("v2_devotional_settings") { db in
            // Add devotional-related settings columns
            try db.alter(table: "user_settings") { t in
                t.add(column: "devotional_font_size", .double).notNull().defaults(to: 18.0)
                t.add(column: "devotional_present_font_multiplier", .double).notNull().defaults(to: 3.0)
                t.add(column: "devotional_line_spacing_bonus", .double).notNull().defaults(to: 1.0)
            }
        }

        migrator.registerMigration("v3_sync_settings") { db in
            // Add sync settings column (stored as JSON)
            try db.alter(table: "user_settings") { t in
                t.add(column: "sync_settings_json", .text)
            }
        }

        migrator.registerMigration("v4_module_settings") { db in
            // Add module-related settings columns
            try db.alter(table: "user_settings") { t in
                t.add(column: "hidden_translations", .text).notNull().defaults(to: "")
                t.add(column: "greek_lexicon_order", .text).notNull().defaults(to: "strongs,dodson")
                t.add(column: "hebrew_lexicon_order", .text).notNull().defaults(to: "strongs,bdb")
                t.add(column: "hidden_greek_lexicons", .text).notNull().defaults(to: "")
                t.add(column: "hidden_hebrew_lexicons", .text).notNull().defaults(to: "")
                t.add(column: "show_strongs_hints", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v5_highlight_colors") { db in
            try db.alter(table: "user_settings") { t in
                t.add(column: "custom_highlight_colors", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v6_highlight_color_order") { db in
            try db.alter(table: "user_settings") { t in
                t.add(column: "highlight_color_order", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v7_quiz_age_group") { db in
            try db.alter(table: "user_settings") { t in
                t.add(column: "default_quiz_age_group", .text).notNull().defaults(to: "adult")
            }
        }

        migrator.registerMigration("v8_plan_reader_count") { db in
            try db.alter(table: "user_settings") { t in
                t.add(column: "plan_reader_count", .integer).notNull().defaults(to: 1)
            }
        }

        // This device's record of plans chosen and readings finished, and of
        // each undone, with when: what syncs as the settings bundle's plan
        // progress. One row, the ledger as core encodes it.
        migrator.registerMigration("v9_plan_progress") { db in
            try db.create(table: "plan_progress") { t in
                t.column("id", .integer).primaryKey()
                t.column("ledger", .blob).notNull()
            }
        }

        return migrator
    }

    // MARK: - User Settings Access

    /// Get current user settings (creates default if none exist).
    /// Served from an in-memory cache; every write path invalidates it.
    func getSettings() -> UserSettings {
        cacheLock.lock()
        if let cached = cachedSettings {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let dbQueue = dbQueue else {
            return UserSettings()
        }

        do {
            let settings = try dbQueue.read { db in
                try UserSettings.fetchOne(db, key: 1) ?? UserSettings()
            }
            cacheLock.lock()
            cachedSettings = settings
            cacheLock.unlock()
            return settings
        } catch {
            print("[UserDB] Failed to fetch settings: \(error)")
            return UserSettings()
        }
    }

    /// Update user settings with a closure
    func updateSettings(_ update: (inout UserSettings) -> Void) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        let updated = try dbQueue.write { db -> UserSettings in
            var settings = try UserSettings.fetchOne(db, key: 1) ?? UserSettings()
            let chosen = settings.planIds
            update(&settings)
            settings.updatedAt = Date()
            try settings.save(db)
            try Self.recordPlanChoices(from: chosen, to: settings.planIds, in: db)
            return settings
        }

        cacheLock.lock()
        cachedSettings = updated
        cacheLock.unlock()
        markLocalWrite()

        // Post directly — the file monitor may miss WAL-mode writes
        notifyDatabaseChange()
    }

    // MARK: - Completed Readings Access

    /// Get all completed readings, optionally filtered by plan and/or year
    func getCompletedReadings(forPlan planId: String? = nil, year: Int? = nil) -> [CompletedReading] {
        guard let dbQueue = dbQueue else {
            return []
        }

        do {
            return try dbQueue.read { db in
                var query = CompletedReading.all()
                if let planId = planId {
                    query = query.filter(Column("plan_id") == planId)
                }
                if let year = year {
                    query = query.filter(Column("year") == year)
                }
                return try query.fetchAll(db)
            }
        } catch {
            print("[UserDB] Failed to fetch completed readings: \(error)")
            return []
        }
    }

    /// Get all completed reading IDs (for quick lookup)
    func getCompletedReadingIds() -> Set<String> {
        guard let dbQueue = dbQueue else {
            return []
        }

        do {
            return try dbQueue.read { db in
                let ids = try String.fetchAll(db, sql: "SELECT id FROM completed_readings")
                return Set(ids)
            }
        } catch {
            print("[UserDB] Failed to fetch completed reading IDs: \(error)")
            return []
        }
    }

    /// Check if a specific reading is completed
    func isReadingCompleted(_ id: String) -> Bool {
        guard let dbQueue = dbQueue else {
            return false
        }

        do {
            return try dbQueue.read { db in
                try CompletedReading.fetchOne(db, key: id) != nil
            }
        } catch {
            print("[UserDB] Failed to check completed reading: \(error)")
            return false
        }
    }

    /// Add a completed reading
    func addCompletedReading(_ id: String) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbQueue.write { db in
            var at = Self.milliseconds(Date())
            if var progress = try Self.planProgress(in: db) {
                progress.recordCompletion(id, at: at)
                // The ledger stamps a tick after any untick it undoes; the
                // row keeps the same time, so applying it changes nothing.
                at = progress.readings[id]?.presentSince ?? at
                try Self.save(progress, in: db)
            }
            let reading = CompletedReading(id: id, completedAt: Self.date(milliseconds: at))
            try reading.insert(db)
            // Bump updated_at so sync detects the change
            try db.execute(sql: "UPDATE user_settings SET updated_at = ? WHERE id = 1", arguments: [Date()])
        }

        // updated_at moved, so the memoised settings are stale
        invalidateSettingsCache()
        markLocalWrite()
        notifyDatabaseChange()
    }

    /// Remove a completed reading
    func removeCompletedReading(_ id: String) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbQueue.write { db in
            _ = try CompletedReading.deleteOne(db, key: id)
            if var progress = try Self.planProgress(in: db) {
                progress.recordUncompletion(id, at: Self.milliseconds(Date()))
                try Self.save(progress, in: db)
            }
            // Bump updated_at so sync detects the change
            try db.execute(sql: "UPDATE user_settings SET updated_at = ? WHERE id = 1", arguments: [Date()])
        }

        // updated_at moved, so the memoised settings are stale
        invalidateSettingsCache()
        markLocalWrite()
        notifyDatabaseChange()
    }

    // MARK: - Sync Support

    func syncSnapshot() throws -> (settings: UserSettings, readings: [CompletedReading]) {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }
        return try dbQueue.read { db in
            guard let settings = try UserSettings.fetchOne(db, key: 1) else {
                throw DatabaseError(message: "User settings are missing")
            }
            return (settings, try CompletedReading.fetchAll(db))
        }
    }

    /// Force a WAL checkpoint to ensure all changes are written to the main database file
    /// Call this before syncing to ensure all data is written
    func checkpointForSync() throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        _ = try dbQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    // MARK: - Merge Support

    /// Apply the reading rows selected by the three-way sync planner, including
    /// deletions and changed completion dates.
    /// Returns true if anything changed. A failed database write must abort sync.
    @discardableResult
    func syncCompletedReadings(with remoteReadings: [CompletedReading]) throws -> Bool {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }

        // The write below bumps updated_at when anything changes
        defer { invalidateSettingsCache() }

        return try dbQueue.write { db in
                let localRows = Dictionary(uniqueKeysWithValues:
                    try CompletedReading.fetchAll(db).map { ($0.id, $0) }
                )
                let remoteRows = Dictionary(uniqueKeysWithValues:
                    remoteReadings.map { ($0.id, $0) }
                )
                let localIds = Set(localRows.keys)
                let remoteIds = Set(remoteRows.keys)

                guard localRows != remoteRows else { return false }

                for reading in remoteReadings {
                    if let current = localRows[reading.id] {
                        guard current != reading else { continue }
                        try db.execute(sql: """
                            UPDATE completed_readings
                            SET plan_id = ?, year = ?, completed_at = ?
                            WHERE id = ?
                            """, arguments: [
                                reading.planId, reading.year, reading.completedAt, reading.id
                            ])
                    } else {
                        try db.execute(sql: """
                            INSERT INTO completed_readings (id, plan_id, year, completed_at)
                            VALUES (?, ?, ?, ?)
                            """, arguments: [
                                reading.id, reading.planId, reading.year, reading.completedAt
                            ])
                    }
                }

                // Remove readings present locally but not in remote (propagate deletions)
                let toRemove = localIds.subtracting(remoteIds)
                if !toRemove.isEmpty {
                    let placeholders = Array(repeating: "?", count: toRemove.count).joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM completed_readings WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(Array(toRemove))
                    )
                }

                // A phone without plan progress ticked or unticked these, so
                // the ledger learns of them here: a tick at its own time, an
                // untick when it arrived, the only time known for it.
                if var progress = try Self.planProgress(in: db) {
                    progress.recordHeld(
                        completed: remoteRows.filter { localRows[$0.key] != $0.value }
                            .mapValues { Self.milliseconds($0.completedAt) },
                        selected: [:]
                    )
                    let now = Self.milliseconds(Date())
                    for id in toRemove { progress.recordUncompletion(id, at: now) }
                    try Self.save(progress, in: db)
                }

                // Bump updated_at so observers know data changed
                try db.execute(sql: "UPDATE user_settings SET updated_at = ? WHERE id = 1", arguments: [Date()])
                return true
        }
    }

    /// Apply remote settings, optionally bypassing the legacy timestamp rule
    /// after a three-way comparison has chosen the remote value.
    /// Preserves local sync_settings_json so device credentials are not overwritten.
    /// Returns true if local settings were updated.
    @discardableResult
    func mergeSettings(from remote: UserSettings, force: Bool = false) throws -> Bool {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }

        defer { invalidateSettingsCache() }

        return try dbQueue.write { db in
                guard let local = try UserSettings.fetchOne(db, key: 1) else { return false }
                guard force || remote.updatedAt > local.updatedAt else {
                    print("[UserDB] mergeSettings skipped: remote \(remote.updatedAt) not newer than local \(local.updatedAt)")
                    return false
                }
                print("[UserDB] mergeSettings applying: remote \(remote.updatedAt) > local \(local.updatedAt)")

                // Overwrite all fields except sync_settings_json and id
                try db.execute(sql: """
                    UPDATE user_settings SET
                        selected_plan_ids = ?,
                        plan_in_app_bible = ?,
                        plan_external_bible = ?,
                        plan_wpm = ?,
                        plan_notification = ?,
                        plan_notification_hour = ?,
                        plan_notification_minute = ?,
                        reader_translation_id = ?,
                        reader_cross_reference_sort = ?,
                        reader_font_size = ?,
                        devotional_font_size = ?,
                        devotional_present_font_multiplier = ?,
                        devotional_line_spacing_bonus = ?,
                        hidden_translations = ?,
                        greek_lexicon_order = ?,
                        hebrew_lexicon_order = ?,
                        hidden_greek_lexicons = ?,
                        hidden_hebrew_lexicons = ?,
                        show_strongs_hints = ?,
                        custom_highlight_colors = ?,
                        highlight_color_order = ?,
                        default_quiz_age_group = ?,
                        plan_reader_count = ?,
                        updated_at = ?
                    WHERE id = 1
                    """, arguments: [
                        remote.selectedPlanIds,
                        remote.planInAppBible,
                        remote.planExternalBible,
                        remote.planWpm,
                        remote.planNotification,
                        remote.planNotificationHour,
                        remote.planNotificationMinute,
                        remote.readerTranslationId,
                        remote.readerCrossReferenceSort,
                        remote.readerFontSize,
                        remote.devotionalFontSize,
                        remote.devotionalPresentFontMultiplier,
                        remote.devotionalLineSpacingBonus,
                        remote.hiddenTranslations,
                        remote.greekLexiconOrder,
                        remote.hebrewLexiconOrder,
                        remote.hiddenGreekLexicons,
                        remote.hiddenHebrewLexicons,
                        remote.showStrongsHints,
                        remote.customHighlightColors,
                        remote.highlightColorOrder,
                        remote.defaultQuizAgeGroup,
                        remote.planReaderCount,
                        remote.updatedAt
                    ])
                // Plans chosen on a phone without plan progress reach the
                // ledger this way.
                try Self.recordPlanChoices(from: local.planIds, to: remote.planIds, in: db)
                return true
        }
    }

    // MARK: - Plan Progress

    /// The plan ledger's time: milliseconds since 1970, as GRDB stores a date
    /// to the millisecond, so a time read back from a row is the one written.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// This device's plan ledger: empty before anything is recorded, nil when
    /// it was written by a later version. One that can't be read is left as
    /// it is rather than rewritten without what it holds.
    private static func planProgress(in db: Database) throws -> LampSyncPlanProgress? {
        guard let data = try Data.fetchOne(db, sql: "SELECT ledger FROM plan_progress WHERE id = 1") else {
            return LampSyncPlanProgress()
        }
        guard let progress = try? LampSyncPlanProgress.decode(data) else {
            print("[UserDB] The plan ledger is from a later version; not recording into it")
            return nil
        }
        return progress
    }

    private static func save(_ progress: LampSyncPlanProgress, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO plan_progress (id, ledger) VALUES (1, ?)",
            arguments: [progress.encoded()]
        )
    }

    /// Plans that joined or left the chosen ones, recorded now.
    private static func recordPlanChoices(from before: [String], to after: [String], in db: Database) throws {
        let chosen = Set(after).subtracting(before)
        let dropped = Set(before).subtracting(after)
        guard !chosen.isEmpty || !dropped.isEmpty,
              var progress = try planProgress(in: db) else { return }
        let now = milliseconds(Date())
        for planId in chosen { progress.recordSelection(planId, at: now) }
        for planId in dropped { progress.recordDeselection(planId, at: now) }
        try save(progress, in: db)
    }

    /// This device's plan ledger, for the bundle; nil when it can't be read.
    func planProgress() throws -> LampSyncPlanProgress? {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }
        return try dbQueue.read { try Self.planProgress(in: $0) }
    }

    /// Joins other devices' plan progress into this device's, and changes
    /// the chosen plans and finished readings to what the join says, in one
    /// transaction. True when they changed.
    ///
    /// What this device holds goes into its ledger first, every time: a
    /// finished reading at its own time, a chosen plan at 0, since no time
    /// was kept for it. That seeds the first ledger, and only ever sets, so
    /// a plan or reading cleared since stays cleared.
    @discardableResult
    func applyPlanProgress(joining others: [LampSyncPlanProgress]) throws -> Bool {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }

        defer { invalidateSettingsCache() }

        let changed = try dbQueue.write { db -> Bool in
            guard var progress = try Self.planProgress(in: db),
                  var settings = try UserSettings.fetchOne(db, key: 1) else { return false }
            let completed = try CompletedReading.fetchAll(db).reduce(into: [String: Int64]()) {
                $0[$1.id] = Self.milliseconds($1.completedAt)
            }
            let selected = settings.planIds.reduce(into: [String: Int64]()) { $0[$1] = 0 }
            progress.recordHeld(completed: completed, selected: selected)
            for other in others { progress.merge(other) }
            try Self.save(progress, in: db)

            let changes = progress.changes(toApplyTo: completed, selected: selected)
            guard !changes.isEmpty else { return false }
            // Built as every phone builds a row, so one made here matches
            // a copy an older phone made of the same tick.
            for (id, at) in changes.complete {
                try CompletedReading(id: id, completedAt: Self.date(milliseconds: at)).save(db)
            }
            if !changes.uncomplete.isEmpty {
                _ = try CompletedReading.deleteAll(db, keys: Array(changes.uncomplete))
            }
            if !changes.select.isEmpty || !changes.deselect.isEmpty {
                var ids = settings.planIds.filter { !changes.deselect.contains($0) }
                ids += changes.select.subtracting(ids).sorted()
                settings.selectedPlanIds = ids.joined(separator: ",")
            }
            settings.updatedAt = Date()
            try settings.save(db)
            return true
        }
        if changed { notifyDatabaseChange() }
        return changed
    }

    // MARK: - Sync Settings

    /// Get sync settings from the database
    func getSyncSettings() -> SyncSettings? {
        guard let dbQueue = dbQueue else {
            return nil
        }

        do {
            return try dbQueue.read { db in
                if let row = try Row.fetchOne(db, sql: """
                    SELECT sync_settings_json FROM user_settings WHERE id = 1
                    """) {
                    if let jsonString: String = row["sync_settings_json"],
                       let jsonData = jsonString.data(using: .utf8) {
                        return try JSONDecoder().decode(SyncSettings.self, from: jsonData)
                    }
                }
                return nil
            }
        } catch {
            print("[UserDB] Failed to load sync settings: \(error)")
            return nil
        }
    }

    /// Restore the device's provider configuration after importing a portable
    /// remote database without changing the shared settings timestamp.
    func restoreLocalSyncSettings(_ settings: SyncSettings?) throws {
        guard let dbQueue else { throw DatabaseError(message: "Database not initialized") }
        let jsonString: String?
        if let settings {
            let data = try JSONEncoder().encode(settings)
            jsonString = String(data: data, encoding: .utf8)
            guard jsonString != nil else {
                throw DatabaseError(message: "Failed to encode sync settings")
            }
        } else {
            jsonString = nil
        }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE user_settings SET sync_settings_json = ? WHERE id = 1",
                arguments: [jsonString]
            )
        }
    }

    /// Save sync settings to the database
    func saveSyncSettings(_ settings: SyncSettings) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        let jsonData = try JSONEncoder().encode(settings)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw DatabaseError(message: "Failed to encode sync settings")
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE user_settings SET sync_settings_json = ? WHERE id = 1",
                arguments: [jsonString]
            )
        }

        invalidateSettingsCache()
        markLocalWrite()
    }
}

// MARK: - Database Error

struct DatabaseError: Error {
    let message: String
}
