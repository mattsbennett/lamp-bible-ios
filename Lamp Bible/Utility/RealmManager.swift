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
        let bundledRealmPath = Bundle.main.url(forResource: "v2", withExtension: "realm")!
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsURL.appendingPathComponent("v2.realm")
        let v0DestinationURL = documentsURL.appendingPathComponent("default.realm")
        let v1DestinationURL = documentsURL.appendingPathComponent("v1.realm")
        var oldUser: User? = nil

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
        }

        // Copy the Realm file to the destination URL
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try! fileManager.copyItem(at: bundledRealmPath, to: destinationURL)
        }

        let config = Realm.Configuration(fileURL: destinationURL, schemaVersion: 2)

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
        }
    }
}
