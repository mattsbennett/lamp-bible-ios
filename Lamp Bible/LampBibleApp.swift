//
//  Lamp_BibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI
import WidgetKit

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
    @Published var pendingPlanMode: Bool = false
    @Published var pendingFileImportURL: URL? = nil

    private init() {}

    func handleURL(_ url: URL) {
        // Handle .lamp file imports from external sources
        if url.isFileURL && url.pathExtension.lowercased() == "lamp" {
            pendingFileImportURL = url
            return
        }

        guard let parsed = LampbibleURL.parse(url) else {
            print("DeepLinkManager: Failed to parse URL: \(url)")
            return
        }

        switch parsed {
        case .verse(let verseId, _, let translationId):
            print("DeepLinkManager: Navigating to verse \(verseId), translation: \(translationId ?? "default")")
            pendingVerseId = verseId
            pendingTranslationId = translationId
            pendingPlanMode = false
        case .reading(let verseId, let endVerseId, let openExternal):
            if openExternal {
                print("DeepLinkManager: Opening reading in external app sv=\(verseId)")
                openInExternalApp(sv: verseId, ev: endVerseId ?? verseId)
            } else {
                print("DeepLinkManager: Opening reading at verse \(verseId) in plan mode")
                pendingVerseId = verseId
                pendingTranslationId = nil
                pendingPlanMode = true
            }
        case .strongs(let key):
            print("DeepLinkManager: Strongs link \(key) not yet supported for deep linking")
        case .external(let externalUrl):
            print("DeepLinkManager: External URL not handled: \(externalUrl)")
        }
    }

    func clearPending() {
        pendingVerseId = nil
        pendingTranslationId = nil
        pendingPlanMode = false
    }

    private func openInExternalApp(sv: Int, ev: Int) {
        let settings = UserDatabase.shared.getSettings()
        guard let appName = settings.planExternalBible,
              appName != "None",
              let app = externalBibleApps.first(where: { $0.name == appName }),
              let url = app.getFullUrl(sv: sv, ev: ev) else {
            // Fall back to opening in Lamp Bible plan mode
            pendingVerseId = sv
            pendingPlanMode = true
            return
        }
        UIApplication.shared.open(url)
    }
}

@main
struct LampBibleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize UserDatabase first (creates schema if needed)
        _ = UserDatabase.shared

        // Migrate from Realm if needed (one-time migration)
        RealmMigrator.migrateIfNeeded()

        // Write widget data in background to avoid blocking launch
        DispatchQueue.global(qos: .utility).async {
            WidgetDataService.shared.writeAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    DeepLinkManager.shared.handleURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                DispatchQueue.global(qos: .utility).async {
                    WidgetDataService.shared.refreshWidget()
                }
                // Start debounce + polling for user settings
                UserSettingsSyncManager.shared.startSync()
                // Full sync from remote on foreground
                Task {
                    try? await SyncCoordinator.shared.syncAll()
                }
            } else if newPhase == .background {
                // Refresh widget so any throttled reloads are picked up
                WidgetDataService.shared.refreshWidget()
                // Stop debounce + polling
                UserSettingsSyncManager.shared.stopSync()
                // Final conditional export if there are unsynced local changes
                guard UserDatabase.shared.hasUnsyncedChanges else { return }
                let app = UIApplication.shared
                var bgTaskId: UIBackgroundTaskIdentifier = .invalid
                bgTaskId = app.beginBackgroundTask {
                    app.endBackgroundTask(bgTaskId)
                    bgTaskId = .invalid
                }
                Task {
                    defer {
                        if bgTaskId != .invalid {
                            app.endBackgroundTask(bgTaskId)
                        }
                    }
                    if let storage = await SyncCoordinator.shared.activeStorage {
                        try? await UserSettingsSyncManager.shared.exportToRemote(storage: storage)
                    }
                }
            }
        }
    }
}
