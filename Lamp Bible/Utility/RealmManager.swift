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

    private init() {
        // Initialize the Realm instance
        let bundledRealmPath = Bundle.main.url(forResource: "default", withExtension: "realm")!
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsURL.appendingPathComponent("default.realm")

        // Copy the Realm file to the destination URL
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try! fileManager.copyItem(at: bundledRealmPath, to: destinationURL)
        }

        let copyConfig = Realm.Configuration(fileURL: destinationURL)
        
        realm = try! Realm(configuration: copyConfig)
        
        if (realm.objects(User.self).isEmpty) {
            let user = User()
            try! realm.write {
                realm.add(user)
                user.readerTranslation = realm.objects(Translation.self).filter("id == \(user.defaultTranslationId)").first!
            }
        }
    }
}
