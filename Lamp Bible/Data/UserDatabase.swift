//
//  UserDatabase.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2025-01-12.
//

import Foundation
import GRDB

/// Notification posted when UserDatabase detects remote changes (from any sync provider)
extension Notification.Name {
    static let userDatabaseDidChange = Notification.Name("userDatabaseDidChange")
}

/// Manages user settings and completed readings with sync support
class UserDatabase {
    static let shared = UserDatabase()

    private var dbQueue: DatabaseQueue?
    private let localURL: URL
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?

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
            self?.notifyDatabaseChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func notifyDatabaseChange() {
        print("[UserDB] Database changed, notifying observers")
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
        notifyDatabaseChange()
    }

    /// Mark that local changes have been exported
    func clearUnsyncedChanges() {
        UserDefaults.standard.set(Date(), forKey: Self.lastExportedAtKey)
    }

    /// Close the database connection and stop file monitoring.
    /// Call before replacing the database file on disk.
    func closeDatabase() {
        stopFileMonitoring()
        dbQueue = nil
    }

    /// Close and reopen the database from the file on disk.
    /// Call after replacing the database file to pick up new data.
    func reopenDatabase() {
        stopFileMonitoring()
        dbQueue = nil
        setupDatabase()
        startFileMonitoring()
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

        return migrator
    }

    // MARK: - User Settings Access

    /// Get current user settings (creates default if none exist)
    func getSettings() -> UserSettings {
        guard let dbQueue = dbQueue else {
            return UserSettings()
        }

        do {
            return try dbQueue.read { db in
                try UserSettings.fetchOne(db, key: 1) ?? UserSettings()
            }
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

        try dbQueue.write { db in
            var settings = try UserSettings.fetchOne(db, key: 1) ?? UserSettings()
            update(&settings)
            settings.updatedAt = Date()
            try settings.save(db)
        }

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
            let reading = CompletedReading(id: id)
            try reading.insert(db)
            // Bump updated_at so sync detects the change
            try db.execute(sql: "UPDATE user_settings SET updated_at = datetime('now') WHERE id = 1")
        }

        notifyDatabaseChange()
    }

    /// Remove a completed reading
    func removeCompletedReading(_ id: String) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbQueue.write { db in
            _ = try CompletedReading.deleteOne(db, key: id)
            // Bump updated_at so sync detects the change
            try db.execute(sql: "UPDATE user_settings SET updated_at = datetime('now') WHERE id = 1")
        }

        notifyDatabaseChange()
    }

    /// Remove all completed readings for a plan
    func removeCompletedReadings(forPlan planId: String) throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM completed_readings WHERE plan_id = ?", arguments: [planId])
            // Bump updated_at so sync detects the change
            try db.execute(sql: "UPDATE user_settings SET updated_at = datetime('now') WHERE id = 1")
        }

        notifyDatabaseChange()
    }

    // MARK: - Sync Support

    /// Force a WAL checkpoint to ensure all changes are written to the main database file
    /// Call this before syncing to ensure all data is written
    func checkpointForSync() throws {
        guard let dbQueue = dbQueue else {
            throw DatabaseError(message: "Database not initialized")
        }

        try dbQueue.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
    }

    // MARK: - Merge Support

    /// Sync completed readings with remote: adds remote-only rows, removes local-only rows.
    /// Callers must export local changes first so deletions reach remote before this runs.
    /// Returns true if anything changed.
    @discardableResult
    func syncCompletedReadings(with remoteReadings: [CompletedReading]) -> Bool {
        guard let dbQueue = dbQueue else { return false }

        do {
            return try dbQueue.write { db in
                let localIds = Set(try String.fetchAll(db, sql: "SELECT id FROM completed_readings"))
                let remoteIds = Set(remoteReadings.map(\.id))

                // Nothing to do if sets are identical
                guard localIds != remoteIds else { return false }

                // Add readings present in remote but not local
                let toAdd = remoteReadings.filter { !localIds.contains($0.id) }
                for reading in toAdd {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO completed_readings (id, plan_id, year, completed_at)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [reading.id, reading.planId, reading.year, reading.completedAt])
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

                // Bump updated_at so observers know data changed
                try db.execute(sql: "UPDATE user_settings SET updated_at = datetime('now') WHERE id = 1")
                return true
            }
        } catch {
            print("[UserDB] Failed to sync completed readings: \(error)")
            return false
        }
    }

    /// Merge settings from a remote UserSettings using last-writer-wins by updatedAt.
    /// Preserves local sync_settings_json so device credentials are not overwritten.
    /// Returns true if local settings were updated.
    @discardableResult
    func mergeSettings(from remote: UserSettings) -> Bool {
        guard let dbQueue = dbQueue else { return false }

        do {
            return try dbQueue.write { db in
                guard let local = try UserSettings.fetchOne(db, key: 1) else { return false }
                guard remote.updatedAt > local.updatedAt else {
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
                return true
            }
        } catch {
            print("[UserDB] Failed to merge settings: \(error)")
            return false
        }
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
            try db.execute(sql: """
                UPDATE user_settings SET sync_settings_json = ?, updated_at = datetime('now') WHERE id = 1
                """, arguments: [jsonString])
        }
    }
}

// MARK: - Database Error

struct DatabaseError: Error {
    let message: String
}
