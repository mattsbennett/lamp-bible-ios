//
//  RealmManager.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-28.
//

import RealmSwift

// Initialize a single instance of realm to share across the application
class RealmManager {
    static let shared = RealmManager()
    let realm: Realm
    var oldRealm: Realm? = nil

    private init() {
        // Initialize the Realm instance
        let bundledRealmPath = Bundle.main.url(forResource: "v7", withExtension: "realm")!
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsURL.appendingPathComponent("v7.realm")
        let v0DestinationURL = documentsURL.appendingPathComponent("default.realm")
        let v1DestinationURL = documentsURL.appendingPathComponent("v1.realm")
        let v2DestinationURL = documentsURL.appendingPathComponent("v2.realm")
        let v3DestinationURL = documentsURL.appendingPathComponent("v3.realm")
        let v4DestinationURL = documentsURL.appendingPathComponent("v4.realm")
        let v5DestinationURL = documentsURL.appendingPathComponent("v5.realm")
        let v6DestinationURL = documentsURL.appendingPathComponent("v6.realm")
        var oldUser: User? = nil
        var hasNotesProperties = false  // v5+ has notes properties

        // Query the user data we need to keep from the old realm
        if fileManager.fileExists(atPath: v0DestinationURL.path) {
            let oldConfig = Realm.Configuration(
                fileURL: v0DestinationURL,
                schemaVersion: 1
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
        } else if fileManager.fileExists(atPath: v1DestinationURL.path) {
            let oldConfig = Realm.Configuration(
                fileURL: v1DestinationURL,
                schemaVersion: 2
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
        } else if fileManager.fileExists(atPath: v2DestinationURL.path) {
            let oldConfig = Realm.Configuration(
                fileURL: v2DestinationURL,
                schemaVersion: 2
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
        } else if fileManager.fileExists(atPath: v3DestinationURL.path) {
            let oldConfig = Realm.Configuration(
                fileURL: v3DestinationURL,
                schemaVersion: 2
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
        } else if fileManager.fileExists(atPath: v4DestinationURL.path) {
            let oldConfig = Realm.Configuration(
                fileURL: v4DestinationURL,
                schemaVersion: 3,
                migrationBlock: { migration, oldSchemaVersion in
                    if oldSchemaVersion < 3 {
                        // Add new notes properties with default values
                        migration.enumerateObjects(ofType: User.className()) { oldObject, newObject in
                            newObject!["notesEnabled"] = true
                            newObject!["notesPanelVisible"] = false
                            newObject!["notesPanelOrientation"] = "bottom"
                        }
                    }
                }
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
        } else if fileManager.fileExists(atPath: v5DestinationURL.path) {
            // v5.realm has notes properties (schemaVersion 3)
            let oldConfig = Realm.Configuration(
                fileURL: v5DestinationURL,
                schemaVersion: 3
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
            hasNotesProperties = true
        } else if fileManager.fileExists(atPath: v6DestinationURL.path) {
            // v6.realm has notes properties + TSKe/Strong's tables (schemaVersion 4)
            // Need migration block because User class now has lexicon properties
            let oldConfig = Realm.Configuration(
                fileURL: v6DestinationURL,
                schemaVersion: 5,
                migrationBlock: { migration, oldSchemaVersion in
                    if oldSchemaVersion < 5 {
                        migration.enumerateObjects(ofType: User.className()) { oldObject, newObject in
                            newObject!["greekLexicon"] = "strongs"
                            newObject!["hebrewLexicon"] = "strongs"
                        }
                    }
                }
            )

            oldRealm = try! Realm(configuration: oldConfig)
            oldUser = oldRealm!.objects(User.self).first!
            hasNotesProperties = true
        }

        // Copy the Realm file to the destination URL
        // If destination exists but we have an old realm to migrate from, we need to replace it
        // (handles case where app was updated mid-development with stale destination file)
        if fileManager.fileExists(atPath: destinationURL.path) && oldUser != nil {
            try! fileManager.removeItem(at: destinationURL)
        }
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try! fileManager.copyItem(at: bundledRealmPath, to: destinationURL)
        }

        // Schema version 5 adds Dodson Greek, BDB lexicons, and lexicon user settings
        let config = Realm.Configuration(
            fileURL: destinationURL,
            schemaVersion: 5,
            migrationBlock: { migration, oldSchemaVersion in
                if oldSchemaVersion < 5 {
                    // Add lexicon properties with default values
                    migration.enumerateObjects(ofType: User.className()) { oldObject, newObject in
                        newObject!["greekLexicon"] = "strongs"
                        newObject!["hebrewLexicon"] = "strongs"
                    }
                }
            }
        )

        realm = try! Realm(configuration: config)

        if (oldUser != nil) {
            try! realm.write {
                // This process is ridiculous, because even if we create a new user like
                // newUser = User(value: oldUser), the new user's child objects will
                // still be "managed" by the old realm, throwing an error, so must
                // manually recreate the user property-by-property
                let newUser = User()
                // Primitive properties can just be assigned
                newUser.planInAppBible = oldUser!.planInAppBible
                newUser.planExternalBible = oldUser!.planExternalBible
                newUser.planWpm = oldUser!.planWpm
                newUser.planNotification = oldUser!.planNotification
                newUser.planNotificationDate = oldUser!.planNotificationDate
                newUser.readerCrossReferenceSort = oldUser!.readerCrossReferenceSort
                newUser.readerFontSize = oldUser!.readerFontSize
                // Notes properties only exist in v5+ schemas
                if hasNotesProperties {
                    newUser.notesEnabled = oldUser!.notesEnabled
                    newUser.notesPanelVisible = oldUser!.notesPanelVisible
                    newUser.notesPanelOrientation = oldUser!.notesPanelOrientation
                }
                // Lexicon settings only exist in v7+ schemas (new User() has defaults)

                // Object properties cannot be assigned, must be recreated so pointers
                // don't point to old realm objects
                newUser.readerTranslation = realm.objects(Translation.self).filter("id == \(oldUser!.readerTranslation!.id)").first!

                for oldPlan in oldUser!.plans {
                    newUser.plans.append(realm.objects(Plan.self).filter("id == \(oldPlan.id)").first!)
                }

                for oldReading in oldUser!.completedReadings {
                    newUser.addCompletedReading(id: oldReading.id)
                }

                realm.add(newUser)
            }
        } else if (realm.objects(User.self).isEmpty) {
            let user = User()
            try! realm.write {
                realm.add(user)
                user.readerTranslation = realm.objects(Translation.self).filter("id == \(user.defaultTranslationId)").first!
            }
        }

        // Now that we've 'copied' over the old user data, we can remove the old realm file
        if fileManager.fileExists(atPath: v0DestinationURL.path) {
            try! fileManager.removeItem(atPath: v0DestinationURL.path)
        } else if fileManager.fileExists(atPath: v1DestinationURL.path) {
            try! fileManager.removeItem(atPath: v1DestinationURL.path)
        } else if fileManager.fileExists(atPath: v2DestinationURL.path) {
            try! fileManager.removeItem(atPath: v2DestinationURL.path)
        } else if fileManager.fileExists(atPath: v3DestinationURL.path) {
            try! fileManager.removeItem(atPath: v3DestinationURL.path)
        } else if fileManager.fileExists(atPath: v4DestinationURL.path) {
            try! fileManager.removeItem(atPath: v4DestinationURL.path)
        } else if fileManager.fileExists(atPath: v5DestinationURL.path) {
            try! fileManager.removeItem(atPath: v5DestinationURL.path)
        } else if fileManager.fileExists(atPath: v6DestinationURL.path) {
            try! fileManager.removeItem(atPath: v6DestinationURL.path)
        }
    }
}
