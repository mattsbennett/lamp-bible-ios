//
//  Lamp_BibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI

// MARK: - Deep Link Types

/// Destination for deep link navigation
struct DeepLinkDestination: Hashable, Identifiable {
    let verseId: Int
    let translationId: String?

    var id: Int { verseId }
}

// MARK: - Deep Link Manager

/// Manages deep link state for navigation
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingVerseId: Int? = nil
    @Published var pendingTranslationId: String? = nil

    private init() {}

    func handleURL(_ url: URL) {
        guard let parsed = LampbibleURL.parse(url) else {
            print("DeepLinkManager: Failed to parse URL: \(url)")
            return
        }

        switch parsed {
        case .verse(let verseId, _, let translationId):
            print("DeepLinkManager: Navigating to verse \(verseId), translation: \(translationId ?? "default")")
            pendingVerseId = verseId
            pendingTranslationId = translationId
        case .strongs(let key):
            print("DeepLinkManager: Strongs link \(key) not yet supported for deep linking")
        case .external(let externalUrl):
            print("DeepLinkManager: External URL not handled: \(externalUrl)")
        }
    }

    func clearPending() {
        pendingVerseId = nil
        pendingTranslationId = nil
    }
}

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
                .onOpenURL { url in
                    DeepLinkManager.shared.handleURL(url)
                }
        }
    }
}
