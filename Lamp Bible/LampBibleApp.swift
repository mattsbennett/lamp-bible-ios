//
//  Lamp_BibleApp.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI
import UIKit
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
@MainActor
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingVerseId: Int? = nil
    @Published var pendingTranslationId: String? = nil
    @Published var pendingPlanMode: Bool = false
    @Published var pendingFileImportURL: URL? = nil
    @Published var pendingDeckImportURL: URL? = nil

    private init() {}

    func handleURL(_ url: URL) {
        // A deck is read, not installed, so it takes its own route rather than
        // the module importer's.
        if url.isFileURL && url.pathExtension.lowercased() == "lampdeck" {
            pendingDeckImportURL = url
            return
        }

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

    func clearPendingDeckImport() {
        pendingDeckImportURL = nil
    }

    private func openInExternalApp(sv: Int, ev: Int) {
        let settings = UserDatabase.shared.getSettings()
        guard let appName = settings.planExternalBible,
              appName != "None",
              let app = externalBibleApps.first(where: { $0.name == appName }),
              app.isInstalled,
              let url = app.getFullUrl(sv: sv, ev: ev) else {
            // Fall back to opening in Lamp Bible plan mode, as for an app
            // chosen once and removed since
            pendingVerseId = sv
            pendingPlanMode = true
            return
        }
        UIApplication.shared.open(url)
    }
}

/// Runs the one-time data migration before constructing the content views.
private struct ContentBootstrapView: View {
    @State private var isReady = false
    @State private var didBootstrap = false
    @ObservedObject private var sync = SyncCoordinator.shared

    var body: some View {
        Group {
            if isReady {
                ContentView()
            } else {
                ProgressView()
            }
        }
        .alert("Move to the new sync?", isPresented: $sync.libraryMoveOffered) {
            Button("Move") {
                Task { try? await SyncCoordinator.shared.movePhoneLibraryToNewSync() }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Only this device has kept this library. The new sync keeps each module as its own file, so a change no longer uploads the whole library.\n\nUpdate Lamp Bible to 1.2.0 or later on your other devices first: older versions won't see changes made after the move.")
        }
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true

            RealmMigrator.migrateIfNeeded()
            WidgetDataService.shared.writeAll()
            isReady = true

            // The note editor's page, loaded once the app is up rather than
            // when someone first opens a note.
            try? await Task.sleep(for: .seconds(2))
            TipTapPagePool.shared.warmUp(.note)
        }
    }
}

/// Exists only so a screen can hold the interface orientation for as long as it
/// needs it. UIKit re-evaluates orientation against the app's supported set, so
/// a geometry request alone is undone the moment it is made; the deck viewer
/// narrows this mask while it is open and widens it again on the way out.
final class LampBibleAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

@main
struct LampBibleApp: App {
    @UIApplicationDelegateAdaptor(LampBibleAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Initialize UserDatabase first (creates schema if needed)
        _ = UserDatabase.shared

        // Off the main thread, and only what predates this launch, so the
        // first sync can start making its own files while this runs.
        let launch = Date()
        DispatchQueue.global(qos: .utility).async {
            let swept = TemporaryFileSweeper.removeLeftovers(olderThan: launch)
            if swept.removed > 0 {
                print("[TemporaryFiles] removed \(swept.removed) left by earlier runs (\(swept.bytes / 1_000_000) MB)")
            }
        }
        SearchIndexMaintenance.start()
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
                    try? await SyncCoordinator.shared.syncAll()
                }
            } else if newPhase == .background {
                // Refresh widget so any throttled reloads are picked up. Skips
                // the debounce and holds a background assertion so the write
                // survives suspension.
                WidgetDataService.shared.refreshWidgetImmediately()
                // Stop debounce + polling
                UserSettingsSyncManager.shared.stopSync()
                // Send what this device still has to send before suspension.
                guard let endpoint = libraryEndpoint(for: SyncCoordinator.shared.activeStorage),
                      LibrarySyncPass.isInUse(at: endpoint),
                      LibrarySyncPass.hasLocalWork(at: endpoint) else { return }
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
                    _ = try? await LibrarySyncPass.runIfMigrated(storage: endpoint)
                }
            }
        }
    }
}
