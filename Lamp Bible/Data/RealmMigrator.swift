//
//  RealmMigrator.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2025-01-12.
//
//  Handles one-time migration of user data from Realm to GRDB.
//  This file can be removed after all users have migrated.
//

import Foundation
import RealmSwift

/// Values read out of a legacy Realm file, detached from Realm so they can be
/// inspected and asserted on without a live Realm or the shared UserDatabase.
struct LegacyRealmData: Equatable {
    var planIds: String
    var planInAppBible: Bool
    var planExternalBible: String?
    var planWpm: Double
    var planNotification: Bool
    var planNotificationHour: Int
    var planNotificationMinute: Int
    var readerTranslationId: String
    var readerCrossReferenceSort: String
    var readerFontSize: Float
    var completedReadingIds: [String]
}

/// Handles one-time migration from Realm to GRDB UserDatabase
class RealmMigrator {

    /// Default translation when the legacy user has no translation set
    static let fallbackTranslationId = "BSBs"

    /// Realm database files with their schema versions (from old RealmManager)
    /// Schema versions: default.realm=1, v1-v4.realm=2
    private static let realmFiles: [(name: String, schemaVersion: UInt64)] = [
        ("v4.realm", 2),
        ("v3.realm", 2),
        ("v2.realm", 2),
        ("v1.realm", 2),
        ("default.realm", 1)
    ]

    /// Performs migration if any Realm database exists.
    /// Should be called early in app lifecycle, after UserDatabase is initialized.
    static func migrateIfNeeded() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // Find the first existing Realm database (check newest versions first)
        var foundRealmURL: URL?
        var foundSchemaVersion: UInt64 = 0

        for (fileName, schemaVersion) in realmFiles {
            let url = documentsURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                foundRealmURL = url
                foundSchemaVersion = schemaVersion
                print("RealmMigrator: Found \(fileName) (schema version \(schemaVersion))")
                break
            }
        }

        // Check if any Realm database exists
        guard let realmURL = foundRealmURL else {
            print("RealmMigrator: No Realm database found, skipping migration")
            cleanupAllRealmFiles()
            return
        }

        print("RealmMigrator: Starting migration from \(realmURL.lastPathComponent)...")

        guard let legacy = readLegacyData(at: realmURL, schemaVersion: foundSchemaVersion) else {
            cleanupAllRealmFiles()
            return
        }

        // Migrate user settings to GRDB
        do {
            try UserDatabase.shared.updateSettings { settings in
                settings.selectedPlanIds = legacy.planIds
                settings.planInAppBible = legacy.planInAppBible
                settings.planExternalBible = legacy.planExternalBible
                settings.planWpm = legacy.planWpm
                settings.planNotification = legacy.planNotification
                settings.planNotificationHour = legacy.planNotificationHour
                settings.planNotificationMinute = legacy.planNotificationMinute
                settings.readerTranslationId = legacy.readerTranslationId
                settings.readerCrossReferenceSort = legacy.readerCrossReferenceSort
                settings.readerFontSize = legacy.readerFontSize
            }
            print("RealmMigrator: Migrated user settings (translation: \(legacy.readerTranslationId), plans: \(legacy.planIds))")
        } catch {
            print("RealmMigrator: Failed to migrate user settings: \(error)")
        }

        // Migrate completed readings
        var migratedCount = 0
        for readingId in legacy.completedReadingIds {
            do {
                try UserDatabase.shared.addCompletedReading(readingId)
                migratedCount += 1
            } catch {
                // Ignore duplicate key errors (reading already exists)
            }
        }
        print("RealmMigrator: Migrated \(migratedCount) completed readings")

        // Clean up all old Realm files
        cleanupAllRealmFiles()

        print("RealmMigrator: Migration complete!")
    }

    /// Read a legacy Realm file into plain values.
    ///
    /// Split out from `migrateIfNeeded()` so the legacy schema can be exercised
    /// without touching the shared UserDatabase or the app's Documents directory.
    /// Realm objects are thread-confined, so everything is copied out eagerly.
    static func readLegacyData(at realmURL: URL, schemaVersion: UInt64) -> LegacyRealmData? {
        let config = Realm.Configuration(
            fileURL: realmURL,
            schemaVersion: schemaVersion,
            objectTypes: [LegacyUser.self, LegacyTranslation.self, LegacyPlan.self, LegacyCompletedReading.self]
        )

        guard let oldRealm = try? Realm(configuration: config) else {
            print("RealmMigrator: Failed to open Realm database")
            return nil
        }

        guard let oldUser = oldRealm.objects(LegacyUser.self).first else {
            print("RealmMigrator: No user found in Realm database")
            return nil
        }

        return LegacyRealmData(
            // Plans become a comma-separated string of IDs
            planIds: oldUser.plans.map { String($0.id) }.joined(separator: ","),
            planInAppBible: oldUser.planInAppBible,
            planExternalBible: oldUser.planExternalBible,
            planWpm: oldUser.planWpm,
            planNotification: oldUser.planNotification,
            planNotificationHour: Calendar.current.component(.hour, from: oldUser.planNotificationDate),
            planNotificationMinute: Calendar.current.component(.minute, from: oldUser.planNotificationDate),
            // Use the translation abbreviation if set, otherwise the default
            readerTranslationId: oldUser.readerTranslation?.abbreviation ?? fallbackTranslationId,
            readerCrossReferenceSort: oldUser.readerCrossReferenceSort,
            readerFontSize: oldUser.readerFontSize,
            completedReadingIds: oldUser.completedReadings.map { $0.id }
        )
    }

    /// Remove all Realm database files (all versions)
    private static func cleanupAllRealmFiles() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!

        // All possible Realm file base names
        let realmBases = ["default", "v1", "v2", "v3", "v4"]

        // Extensions/suffixes for each Realm database
        let realmSuffixes = [".realm", ".realm.lock", ".realm.note", ".realm.management"]

        for base in realmBases {
            for suffix in realmSuffixes {
                let fileName = base + suffix
                let url = documentsURL.appendingPathComponent(fileName)

                if fileManager.fileExists(atPath: url.path) {
                    do {
                        try fileManager.removeItem(at: url)
                        print("RealmMigrator: Deleted \(fileName)")
                    } catch {
                        print("RealmMigrator: Failed to delete \(fileName): \(error)")
                    }
                }
            }
        }
    }
}

// MARK: - Legacy Realm Models (for migration only)

/// Legacy User model from old Realm schema
/// Properties match the old User class that was in DataModel.swift
class LegacyUser: RealmSwift.Object {
    @Persisted var planInAppBible = true
    @Persisted var planExternalBible: String? = nil
    @Persisted var planWpm: Double = 183.0
    @Persisted var planNotification = false
    @Persisted var planNotificationDate: Date = {
        var dateComponents = DateComponents()
        dateComponents.hour = 18
        dateComponents.minute = 30
        return Calendar.current.date(from: dateComponents) ?? Date()
    }()
    @Persisted var readerTranslation: LegacyTranslation?
    @Persisted var readerCrossReferenceSort = "r"
    @Persisted var readerFontSize: Float = 18
    @Persisted var plans = RealmSwift.List<LegacyPlan>()
    @Persisted var completedReadings = RealmSwift.List<LegacyCompletedReading>()
}

/// Legacy Translation model (only need id for migration)
class LegacyTranslation: RealmSwift.Object {
    @Persisted(primaryKey: true) var id: Int = 0
    @Persisted var abbreviation: String = ""
}

/// Legacy Plan model (only need id for migration)
class LegacyPlan: RealmSwift.Object {
    @Persisted(primaryKey: true) var id: Int = 0
}

/// Legacy CompletedReading model from Realm schema
class LegacyCompletedReading: RealmSwift.Object {
    @Persisted(primaryKey: true) var id: String
}
