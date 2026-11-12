//
//  TodayView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-04.
//
import SwiftUI

/// The inputs that actually change plan metadata. Anything else (marking a
/// reading complete, changing the reader count, a sync touching an unrelated
/// column) shouldn't trigger a rebuild.
private struct PlanMetaDataInputs: Equatable {
    let planIds: [String]
    let translationId: String
    let wpm: Double
    let date: Date
}

struct PlanView: View {
    @State private var userSettings: UserSettings = UserSettings()
    @State private var planViewRefreshId = UUID()
    @State private var showingDatePicker = false
    @State private var showingInfoModal = false
    @State private var date = Date.now
    @State private var plansMetaData: PlansMetaData = PlansMetaData(plans: [], date: Date.now, userSettings: UserSettings())
    @State private var plans: [Plan] = []
    @State private var isLoaded = false
    /// Inputs whose metadata was built from readable databases. Recorded only
    /// on success, so a build that raced a database opening is retried.
    @State private var metaDataInputs: PlanMetaDataInputs?
    /// Inputs currently being built, so concurrent refreshes don't duplicate work.
    @State private var buildingMetaDataInputs: PlanMetaDataInputs?
    @State private var metaDataRetryCount = 0
    @State private var showingPresentationRemote = false
    @State private var showingDeckLibrary = false
    @State private var deckImportError: String?
    @Environment(\.colorScheme) var colorScheme

    /// The app target deploys to iOS 18, so this is a live branch: only the glass
    /// bar on 26 makes a primary-coloured label readable.
    private var iOS26OrLater: Bool {
        if #available(iOS 26, *) {
            return true
        } else {
            return false
        }
    }

    // Deep link navigation
    @ObservedObject private var deepLinkManager = DeepLinkManager.shared
    @State private var showDeepLinkReader: Bool = false
    @State private var deepLinkVerseId: Int? = nil
    @State private var deepLinkTranslationId: String? = nil
    @State private var deepLinkPlanMode: Bool = false

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                mainContent(geometry: geometry)
                    .task {
                        guard !isLoaded else { return }
                        isLoaded = true
                        plans = ReadingPlanLibrary.allPlans()
                        refreshMetaData()
                    }
                    .onChange(of: planViewRefreshId) {
                        plans = ReadingPlanLibrary.allPlans()
                        refreshMetaData()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
                        refreshMetaData()
                    }
                    .onChange(of: date) {
                        refreshMetaData()
                    }
                    // The counts come from the reader's translation, which can
                    // arrive after the plan was built, or change under the
                    // same id; the inputs alone can't see either.
                    .onReceive(NotificationCenter.default.publisher(for: .translationsDidChange)) { _ in
                        metaDataInputs = nil
                        buildingMetaDataInputs = nil
                        metaDataRetryCount = 0
                        refreshMetaData()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSCalendarDayChanged)) { _ in
                        date = Date()
                    }
                    .frame(maxWidth: .infinity)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        PlanDateToolbarView(
                            date: $date,
                            showingDatePicker: $showingDatePicker,
                            availableWidth: geometry.size.width
                        )
                    }
                    .toolbar {
                        // Slide decks open from the writings they were made
                        // from; this is only the remote for a Mac presenting.
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingPresentationRemote = true
                            } label: {
                                Image(systemName: "play.rectangle.on.rectangle")
                            }
                            .accessibilityLabel("Presentation Remote")
                        }
                    }
                    .planBottomBar {
                        bottomBar
                    }
                    .onChange(of: deepLinkManager.pendingVerseId) { _, newVerseId in
                        if let verseId = newVerseId {
                            // Dismiss any existing reader first
                            showDeepLinkReader = false

                            // Capture values and clear pending
                            deepLinkVerseId = verseId
                            deepLinkTranslationId = deepLinkManager.pendingTranslationId
                            deepLinkPlanMode = deepLinkManager.pendingPlanMode
                            deepLinkManager.clearPending()

                            print("[DeepLink] verseId=\(verseId), planMode=\(deepLinkPlanMode)")

                            // Trigger navigation on next run loop to allow dismiss
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                showDeepLinkReader = true
                            }
                        }
                    }
                    .navigationDestination(isPresented: $showDeepLinkReader) {
                        SplitReaderView(
                            date: $date,
                            initialVerseId: deepLinkVerseId,
                            initialTranslationId: deepLinkTranslationId,
                            initialToolbarMode: deepLinkPlanMode ? .plan : nil
                        )
                    }
                    // Full screen: the remote is the one thing in use while presenting.
                    .fullScreenCover(isPresented: $showingPresentationRemote) {
                        PresentationRemoteView()
                    }
                    .sheet(isPresented: $showingDeckLibrary) {
                        DeckLibraryView()
                            .presentationDetents([.large])
                    }
                    // A .lampdeck opened from Files, Mail, or AirDrop lands in
                    // the deck library rather than the module importer.
                    .onChange(of: deepLinkManager.pendingDeckImportURL) { _, url in
                        guard let url else { return }
                        deepLinkManager.clearPendingDeckImport()
                        do {
                            try PresentationDeckStorage.shared.importDeck(from: url)
                            NotificationCenter.default.post(
                                name: .presentationDecksDidChange,
                                object: nil
                            )
                            showingDeckLibrary = true
                        } catch {
                            deckImportError = error.localizedDescription
                        }
                    }
                    .alert(
                        "Deck Unavailable",
                        isPresented: Binding(
                            get: { deckImportError != nil },
                            set: { if !$0 { deckImportError = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) { deckImportError = nil }
                    } message: {
                        Text(deckImportError ?? "")
                    }
            }
        }
    }

    // MARK: - Meta Data Loading

    /// Refresh settings, then rebuild plan metadata only if something it depends
    /// on actually moved. The build itself queries the bundled database once per
    /// reading, so it runs off the main thread.
    private func refreshMetaData() {
        let settings = UserDatabase.shared.getSettings()
        userSettings = settings

        // Metadata is only ever displayed for selected plans, so don't build the
        // rest.
        let selectedPlans = plans.filter { settings.isPlanSelected($0.id) }
        let inputs = PlanMetaDataInputs(
            planIds: selectedPlans.map(\.id),
            translationId: settings.readerTranslationId,
            wpm: settings.planWpm,
            date: date
        )

        guard inputs != metaDataInputs, inputs != buildingMetaDataInputs else { return }
        buildingMetaDataInputs = inputs

        let buildDate = date
        DispatchQueue.global(qos: .userInitiated).async {
            let built = PlansMetaData(plans: selectedPlans, date: buildDate, userSettings: settings)
            DispatchQueue.main.async {
                // Drop the result if a newer refresh has superseded this one
                guard inputs == buildingMetaDataInputs else { return }
                buildingMetaDataInputs = nil
                plansMetaData = built
                guard built.isFullyResolved else {
                    // The verse and word tallies came back from a database that
                    // wasn't readable yet, so they are zeroes rather than
                    // answers. Recording these inputs would make every later
                    // refresh short-circuit on them for the rest of the
                    // session, which is why this used to need a relaunch.
                    metaDataInputs = nil
                    scheduleMetaDataRetry()
                    return
                }
                metaDataInputs = inputs
                metaDataRetryCount = 0
            }
        }
    }

    /// Tries again shortly after an unresolved build. Nothing is guaranteed to
    /// announce a database finishing its open — `reopenDatabase()` is silent on
    /// its failure path — so the view asks again rather than waiting to be told.
    private func scheduleMetaDataRetry() {
        guard metaDataRetryCount < 10 else { return }
        metaDataRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshMetaData()
        }
    }

    // MARK: - Bottom Bar

    /// Taller than the system's bottom bar, whose glass keeps its own height
    /// whatever its items ask for and left the labels pressed to its edges.
    private static let bottomBarHeight: CGFloat = 58

    /// The app's destinations, on a capsule of the system's glass the plans
    /// scroll under: drawn here, as the reader draws its header, so it can
    /// be as tall as it needs.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            bottomBarLink("Read", systemImage: "book.fill") {
                SplitReaderView(date: $date)
            }

            bottomBarLink("Search", systemImage: "magnifyingglass") {
                SearchView()
            }

            bottomBarLink("Books", systemImage: "books.vertical.fill") {
                BookLibraryView()
            }

            bottomBarLink("Write", systemImage: "pencil.line") {
                DevotionalPickerView(
                    isFullScreen: false,
                    showNewProminent: true,
                    initialModuleId: "devotionals"
                )
            }

            bottomBarLink("Settings", systemImage: "gear") {
                SettingsView(
                    externalApps: externalBibleApps,
                    planViewRefreshId: $planViewRefreshId
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.bottomBarHeight)
        .modifier(BottomBarGlass())
        .padding(.horizontal, 20)
    }

    /// One destination in the bottom bar, an equal share of its width.
    private func bottomBarLink<Destination: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            VStack(spacing: 4) {
                // Monochrome, as the bar's glass draws its items: these are
                // destinations, none of them selected, so none takes the accent.
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    // The size a toolbar gave them, before the bar was its own.
                    .imageScale(.large)
                    .foregroundColor(iOS26OrLater ? .primary : .accentColor)
                    // These glyphs differ in intrinsic height - books.vertical.fill
                    // and gear are noticeably taller than pencil.line - so without a
                    // shared box each label sits at its own baseline and the row
                    // reads as ragged.
                    .frame(height: 26)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(iOS26OrLater ? .primary : .accentColor)
                    // Shrink slightly rather than truncate at large text sizes.
                    // Capping Dynamic Type here would be the easier fix but it
                    // overrides an accessibility setting.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(geometry: GeometryProxy) -> some View {
        VStack {
            if !userSettings.planIds.isEmpty {
                plansScrollView(geometry: geometry)
            } else {
                emptyStateView
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Spacer()
            LampPlanArtwork(planId: "empty", size: 84, isFollowed: true)
            VStack(spacing: 8) {
                Text("Read Through the Bible")
                    .font(.title2.weight(.bold))
                Text("Follow a daily plan, and each day's readings wait for you here.")
                    .font(.body)
                    .foregroundStyle(LampTheme.caption)
                    .multilineTextAlignment(.center)
            }
            NavigationLink(destination: PlanPickerView()) {
                Label("Reading Plan", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(LampTheme.groupedBackground.ignoresSafeArea())
    }

    // MARK: - Plans Scroll View

    @ViewBuilder
    private func plansScrollView(geometry: GeometryProxy) -> some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    plansHeader
                    ForEach(plans) { plan in
                        planSection(plan: plan, geometry: geometry, proxy: proxy)
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(LampTheme.groupedBackground.ignoresSafeArea())
    }

    // MARK: - Plans Header

    /// Plan management belongs next to the plans themselves rather than in the
    /// bottom bar, where it held a permanent slot for something you set once.
    /// The empty state already offers the same destination.
    private var plansHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Daily Reading")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            Spacer()

            // Following, making and deleting plans: more than adding one.
            NavigationLink(destination: PlanPickerView()) {
                Label("Manage", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - Plan Section

    @ViewBuilder
    private func planSection(plan: Plan, geometry: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        // Metadata can lag a plan-list change by a frame, so tolerate a miss
        // instead of trapping.
        if userSettings.isPlanSelected(plan.id),
           let planMetaData = plansMetaData.planMetaData.first(where: { $0.id == plan.id }) {
            let readings = planMetaData.readingMetaData

            Color.clear.frame(height: 0).id(plan.name)

            Group {
                if !readings.isEmpty {
                    readingsContent(planMetaData: planMetaData, geometry: geometry)
                } else {
                    planHeader(plan: plan, planMetaData: planMetaData, readings: readings)
                }
            }
            .onChange(of: date) {
                proxy.scrollTo(plan.name)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: - Plan Header

    /// A plan with nothing to read on this date: its name, and saying so.
    @ViewBuilder
    private func planHeader(plan: Plan, planMetaData: PlanMetaData, readings: [ReadingMetaData]) -> some View {
        HStack(spacing: 14) {
            LampPlanArtwork(planId: plan.id, size: 48, isFollowed: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.name)
                    .font(.headline)
                if readings.isEmpty {
                    Text("No readings for today")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LampTheme.Space.l)
        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
    }

    // MARK: - Readings Content

    @ViewBuilder
    private func readingsContent(planMetaData: PlanMetaData, geometry: GeometryProxy) -> some View {
        if geometry.size.width < 600 {
            ReadingsView(
                date: $date,
                planMetaData: planMetaData,
                stackHorizontally: false
            )
            .frame(maxWidth: .infinity)
        } else {
            ReadingsView(
                date: $date,
                planMetaData: planMetaData,
                stackHorizontally: true
            )
        }
    }

}

/// The system's glass behind the plan screen's bar, or a material where the
/// OS has no glass.
private struct BottomBarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private extension View {
    /// Pins the plan screen's bottom bar, as a bar the plans scroll under.
    @ViewBuilder
    func planBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: bar)
        } else {
            safeAreaInset(edge: .bottom, content: bar)
        }
    }
}

#Preview {
    PlanView()
}
