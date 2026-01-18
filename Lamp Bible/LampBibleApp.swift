//
//  Lamp_BibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI

@main
struct LampBibleApp: App {
    init() {
        // Initialize UserDatabase first (creates schema if needed)
        _ = UserDatabase.shared

        // Migrate from Realm if needed (one-time migration)
        RealmMigrator.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
