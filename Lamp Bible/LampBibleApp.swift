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
        if url.isFileURL && ["lamp", "json"].contains(url.pathExtension.lowercased()) {
            pendingFileImportURL = url
            return
        }

        guard let parsed = LampbibleURL.parse(url) else {
            print("DeepLinkManager: Failed to parse URL: \(url)")
            return
        }

        switch parsed {
        case .verse(let verseId, _, let translationId):
            let availableTranslationId = translationId.flatMap { id in
                ((try? TranslationDatabase.shared.getTranslation(id: id)) ?? nil) == nil ? nil : id
            }
            print("DeepLinkManager: Navigating to verse \(verseId), translation: \(availableTranslationId ?? "default")")
            pendingVerseId = verseId
            pendingTranslationId = availableTranslationId
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

/// Resolves territorial content policy before any content-bearing view is
/// constructed. Restricted bundled translations fail closed while StoreKit is
/// unavailable, instead of briefly appearing during launch.
private struct ContentBootstrapView: View {
    @State private var isReady = false
    @State private var didBootstrap = false
    @State private var contentRevision = 0

    var body: some View {
        Group {
            if isReady {
                ContentView()
                    .id(contentRevision)
            } else {
                ProgressView()
            }
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true

            await BundledContentTerritoryPolicy.shared.refresh()
            RealmMigrator.migrateIfNeeded()
            enforceReaderTranslationAvailability()
            BundledContentTerritoryPolicy.shared.startMonitoring()
            WidgetDataService.shared.writeAll()
            isReady = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .bundledContentTerritoryDidChange)) { _ in
            guard isReady else { return }
            enforceReaderTranslationAvailability()
            contentRevision &+= 1
            WidgetDataService.shared.writeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            guard isReady else { return }
            enforceReaderTranslationAvailability()
        }
    }

    /// If a legacy or synced setting selects Lamp's bundled KJV in a restricted
    /// storefront, move the reader to BSB. A user-imported translation with the
    /// same ID remains available because it resolves through the user database.
    private func enforceReaderTranslationAvailability() {
        let settings = UserDatabase.shared.getSettings()
        let translationId = settings.readerTranslationId
        let policy = BundledContentTerritoryPolicy.shared

        guard policy.restrictsBundledTranslation(id: translationId) else { return }
        if ((try? TranslationDatabase.shared.getTranslation(id: translationId)) ?? nil) != nil {
            return
        }

        let fallbackId = [RealmMigrator.fallbackTranslationId, "ASVs", "WEBs", "YLT"]
            .first { ((try? TranslationDatabase.shared.getTranslation(id: $0)) ?? nil) != nil }
        guard let fallbackId else { return }

        try? UserDatabase.shared.updateSettings { settings in
            settings.readerTranslationId = fallbackId
        }
    }
}

@main
struct LampBibleApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize UserDatabase first (creates schema if needed)
        _ = UserDatabase.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentBootstrapView()
                .onOpenURL { url in
                    DeepLinkManager.shared.handleURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                WidgetDataService.shared.refreshWidget()
                // Start debounce + polling for user settings
                UserSettingsSyncManager.shared.startSync()
                // Full sync from remote on foreground
                Task {
                    await BundledContentTerritoryPolicy.shared.refresh()
                    try? await SyncCoordinator.shared.syncAll()
                }
            } else if newPhase == .background {
                // Refresh widget so any throttled reloads are picked up. Skips
                // the debounce and holds a background assertion so the write
                // survives suspension.
                WidgetDataService.shared.refreshWidgetImmediately()
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
