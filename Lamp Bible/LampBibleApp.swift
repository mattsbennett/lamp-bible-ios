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
    /// A writing a lampbible://writing link asked for.
    @Published var pendingWritingID: String? = nil

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
        case .writing(let id):
            pendingWritingID = id
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

/// Opens the library before constructing the content views: the bundled
/// modules unpacked (off the main thread, as it takes tens of seconds after
/// an update and would otherwise freeze the launch screen), then the
/// one-time data migration. The lamplight splash is shown meanwhile.
private struct ContentBootstrapView: View {
    @State private var isReady = false
    @State private var didBootstrap = false
    /// Links and files opened while the library is still opening. Handled
    /// then, they would read the bundled database on the main thread and
    /// freeze the splash for the rest of the unpacking; and the screens that
    /// act on them only hear of a change, so set before those screens exist
    /// they would be lost. Handed on once the content has appeared.
    @State private var heldURLs: [URL] = []
    @ObservedObject private var sync = SyncCoordinator.shared

    var body: some View {
        ZStack {
            if isReady {
                ContentView()
                    .onAppear {
                        let urls = heldURLs
                        heldURLs = []
                        // A turn later, so the content's own observers are in
                        // place to hear what the links set; and a moment
                        // apart, as they would have arrived, since each
                        // screen holds one pending link or file at a time and
                        // two handed over at once would leave only the last.
                        for (index, url) in urls.enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 + 0.6 * Double(index)) {
                                DeepLinkManager.shared.handleURL(url)
                            }
                        }
                    }
            } else {
                LampSplashView()
                    .transition(.opacity.animation(.easeInOut(duration: 0.28)))
                    // Above the interface while it fades, not behind it.
                    .zIndex(1)
            }
        }
        .onOpenURL { url in
            if isReady {
                DeepLinkManager.shared.handleURL(url)
            } else {
                heldURLs.append(url)
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

            // First touch of the bundled database unpacks it when the bundle
            // has changed. Here, off the main thread, while the splash
            // animates; the steps below read it, and on the main thread they
            // would have done the unpacking with the screen frozen.
            await Task.detached(priority: .userInitiated) { _ = BundledModuleDatabase.shared }.value

            RealmMigrator.migrateIfNeeded()
            WidgetDataService.shared.writeAll()
            withAnimation { isReady = true }

            // The note editor's page, loaded once the app is up rather than
            // when someone first opens a note.
            try? await Task.sleep(for: .seconds(2))
            TipTapPagePool.shared.warmUp(.note)
        }
    }
}

/// Shown while the library opens, as the Mac's is: the launch screen's flame,
/// at the same size and place, in the app's accent, with the name, a hairline
/// with a gleam of the accent passing along it, and the verse the app is named
/// for. The gleam is Core Animation's, run by the render server, so it keeps
/// moving while the main thread is busy opening the library. With Reduce
/// Motion it rests, brightening and dimming.
private struct LampSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingSlowStartMessage = false
    /// The words' height, which sets how far the group's centre is from the
    /// flame's.
    @State private var wordsHeight: CGFloat = 0
    /// Whether the flame has moved from the launch image's place to its own.
    @State private var hasSettled = false

    /// The launch image's height, at which it is drawn.
    private static let flameHeight: CGFloat = 100

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            GeometryReader { proxy in
                // The flame and the words centred on the screen as one group
                // (owner, Nov 2026); they were the flame centred and the words
                // hung under it, which sat the whole low. On a short screen —
                // a small phone on its side — the verse stays out and the
                // words may shrink, so nothing is pushed off at any text size.
                let isShort = proxy.size.height < 560
                let gap: CGFloat = isShort ? 20 : 44
                VStack(spacing: gap) {
                    flame
                        // From where the launch image left it, the screen's
                        // centre, up to its place in the group.
                        .offset(y: hasSettled ? 0 : (gap + wordsHeight) / 2)
                    words(includingVerse: !isShort, isCompact: isShort)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wordsHeight = $0 }
                        .opacity(hasSettled ? 1 : 0)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            // The launch image is centred on the whole screen.
            .ignoresSafeArea()
        }
        .task {
            // Once the words are measured, so the flame starts where the
            // launch image was.
            for _ in 0..<30 where wordsHeight == 0 {
                try? await Task.sleep(for: .milliseconds(16))
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { hasSettled = true }
        }
        // The bundled modules are unpacked and verified on a first run or after
        // an update, which takes long enough to be worth explaining.
        .task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { isShowingSlowStartMessage = true }
        }
    }

    private func words(includingVerse: Bool, isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            Text("Lamp Bible")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            LampSplashShimmer(isAnimated: !reduceMotion)
                .frame(width: 160, height: 2)
                .padding(.top, 12)
                .accessibilityHidden(true)

            if includingVerse { verse }

            Text(isShowingSlowStartMessage
                ? "Preparing your library. This happens once after an update."
                : "Opening your library…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .lineLimit(isCompact ? 2 : nil)
                .minimumScaleFactor(isCompact ? 0.5 : 1)
                .fixedSize(horizontal: false, vertical: !isCompact)
                // Room for two lines from the start, so nothing shifts when
                // the longer message replaces the short one; more where a
                // larger text size needs it.
                .frame(minHeight: 36, alignment: .top)
                .padding(.top, 24)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 24)
    }

    private var verse: some View {
        VStack(spacing: 6) {
            Text("“Thy word is a lamp unto my feet,\nand a light unto my path.”")
                .font(.system(size: 15, design: .serif).italic())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Text("Psalm 119:105")
                .font(.system(size: 11, weight: .medium, design: .serif))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
    }

    /// The launch image used as the mask of the accent, so the flame is the
    /// launch screen's shape in the launch screen's place.
    private var flame: some View {
        Color.accentColor
            .mask(Image("lampsplash").resizable().scaledToFit())
            .aspectRatio(0.5, contentMode: .fit)
            .frame(height: Self.flameHeight)
            .accessibilityHidden(true)
    }
}

/// A hairline with a gleam of the accent passing along it, for "working on
/// it" without a spinner. Unanimated, the gleam rests in the middle and only
/// brightens and dims.
private struct LampSplashShimmer: UIViewRepresentable {
    let isAnimated: Bool

    func makeUIView(context: Context) -> ShimmerView { ShimmerView() }

    func updateUIView(_ view: ShimmerView, context: Context) {
        view.isAnimated = isAnimated
    }

    final class ShimmerView: UIView {
        private let track = CALayer()
        private let gleam = CAGradientLayer()
        /// The width the gleam's sweep was set up for: a layout pass at the
        /// same width leaves it running rather than starting it again.
        private var animatedWidth: CGFloat = 0
        var isAnimated = true {
            didSet { if isAnimated != oldValue { animate() } }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            layer.addSublayer(track)
            track.masksToBounds = true
            track.addSublayer(gleam)
            gleam.startPoint = CGPoint(x: 0, y: 0.5)
            gleam.endPoint = CGPoint(x: 1, y: 0.5)
            paint()
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerView, _: UITraitCollection) in
                view.paint()
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            gleam.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.4, height: bounds.height)
            gleam.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
            if bounds.width != animatedWidth { animate() }
        }

        /// A layer's animations are dropped when its view leaves the window,
        /// as it does going to the background mid-launch; they are added
        /// again on its return.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { animate() }
        }

        private func paint() {
            let accent = (UIColor(named: "AccentColor") ?? .systemRed).resolvedColor(with: traitCollection)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            track.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.18).resolvedColor(with: traitCollection).cgColor
            gleam.colors = [accent.withAlphaComponent(0).cgColor, accent.cgColor, accent.withAlphaComponent(0).cgColor]
            CATransaction.commit()
        }

        private func animate() {
            gleam.removeAllAnimations()
            animatedWidth = bounds.width
            guard bounds.width > 0 else { return }
            if isAnimated {
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = -bounds.width * 0.2
                sweep.toValue = bounds.width * 1.2
                sweep.duration = 1.6
                sweep.repeatCount = .infinity
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gleam.add(sweep, forKey: "sweep")
            } else {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.35
                pulse.toValue = 1
                pulse.duration = 1.2
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                gleam.add(pulse, forKey: "pulse")
            }
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
        // The installed voices, listed once off the main thread: asking the
        // speech service for them is slow, and the speaker button needs them.
        DispatchQueue.global(qos: .utility).async { _ = SpeechVoiceCatalog.installedVoices }
        SearchIndexMaintenance.start()
        // Indexed once and kept, so a Strong's search is a lookup.
        StrongsIndex.shared.prepare(readerTranslationId: UserDatabase.shared.getSettings().readerTranslationId)
    }

    var body: some Scene {
        WindowGroup {
            // Opened links are handled by the bootstrap, which holds them
            // until the library is open.
            ContentBootstrapView()
                // Apple's Writing Tools in the app's SwiftUI text, sheets
                // included, only with the AI features on.
                .writingToolsFollowAIFeatures()
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
