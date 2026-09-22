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
    @State private var metaDataInputs: PlanMetaDataInputs?
    @State private var showingPresentationRemote = false
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
                        plans = (try? BundledModuleDatabase.shared.getAllPlans()) ?? []
                        refreshMetaData()
                    }
                    .onChange(of: planViewRefreshId) {
                        plans = (try? BundledModuleDatabase.shared.getAllPlans()) ?? []
                        refreshMetaData()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
                        refreshMetaData()
                    }
                    .onChange(of: date) {
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
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingPresentationRemote = true
                            } label: {
                                Image(systemName: "play.rectangle.on.rectangle")
                            }
                            .accessibilityLabel("Presentation Remote")
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            HStack(spacing: 16) {
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
                        }
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
                    .sheet(isPresented: $showingPresentationRemote) {
                        PresentationRemoteView()
                            .presentationDetents([.large])
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

        guard inputs != metaDataInputs else { return }
        metaDataInputs = inputs

        let buildDate = date
        DispatchQueue.global(qos: .userInitiated).async {
            let built = PlansMetaData(plans: selectedPlans, date: buildDate, userSettings: settings)
            DispatchQueue.main.async {
                // Drop the result if a newer refresh has superseded this one
                guard inputs == metaDataInputs else { return }
                plansMetaData = built
            }
        }
    }

    // MARK: - Bottom Bar

    /// One destination in the bottom bar.
    ///
    /// These are sized by their labels, not divided evenly: a `bottomBar`
    /// `ToolbarItem` is laid out at its ideal size, so `maxWidth: .infinity` here
    /// is silently ignored and only removes the spacing that was holding the row
    /// apart. Explicit spacing on the enclosing `HStack` is what keeps it legible.
    private func bottomBarLink<Destination: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundColor(.accentColor)
                    // These glyphs differ in intrinsic height - books.vertical.fill
                    // and gear are noticeably taller than pencil.line - so without a
                    // shared box each label sits at its own baseline and the row
                    // reads as ragged.
                    .frame(height: 22)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(iOS26OrLater ? .primary : .red)
                    // Shrink slightly rather than truncate at large text sizes.
                    // Capping Dynamic Type here would be the easier fix but it
                    // overrides an accessibility setting.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            // The 44pt target is the whole height of the item: the glass capsule
            // behind the bar does not grow to fit its contents, so stacking icon,
            // label and vertical padding on top of that overflowed it.
            .frame(minWidth: 44, minHeight: 44, maxHeight: 44)
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
        VStack {
            Spacer()
            NavigationLink(destination: PlanPickerView()) {
                HStack {
                    Text(Image(systemName: "plus.circle.fill"))
                    Text("Reading plan")
                }.font(.title2)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Plans Scroll View

    @ViewBuilder
    private func plansScrollView(geometry: GeometryProxy) -> some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading) {
                    plansHeader
                    ForEach(plans) { plan in
                        planSection(plan: plan, geometry: geometry, proxy: proxy)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Plans Header

    /// Plan management belongs next to the plans themselves rather than in the
    /// bottom bar, where it held a permanent slot for something you set once.
    /// The empty state already offers the same destination.
    private var plansHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plans")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.secondary)

                Spacer()

                NavigationLink(destination: PlanPickerView()) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 20)

            Divider()
        }
    }

    // MARK: - Plan Section

    @ViewBuilder
    private func planSection(plan: Plan, geometry: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        // Metadata can lag a plan-list change by a frame, so tolerate a miss
        // instead of trapping.
        if userSettings.isPlanSelected(plan.id),
           let planMetaData = plansMetaData.planMetaData.first(where: { $0.id == plan.id }) {
            let readings = planMetaData.readingMetaData

            Spacer().id(plan.name)

            planHeader(plan: plan, planMetaData: planMetaData, readings: readings)
                .onChange(of: date) {
                    proxy.scrollTo(plan.name)
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))

            readingsContent(planMetaData: planMetaData, geometry: geometry)

            if plan.id != userSettings.planIds.last {
                Divider()
            }
        }
    }

    // MARK: - Plan Header

    @ViewBuilder
    private func planHeader(plan: Plan, planMetaData: PlanMetaData, readings: [ReadingMetaData]) -> some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text(plan.name)
                        .font(.title2)
                        .fontWeight(.black)

                    if readings.count > 0 {
                        readingsRow(planMetaData: planMetaData)
                    } else {
                        Text("No readings for today")
                            .padding(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Readings Row

    @ViewBuilder
    private func readingsRow(planMetaData: PlanMetaData) -> some View {
        HStack {
            if userSettings.planInAppBible {
                NavigationLink(
                    destination: SplitReaderView(
                        date: $date,
                        initialToolbarMode: .plan
                    )
                ) {
                    VStack {
                        Image(systemName: "book.circle.fill")
                            .font(.system(size: 52))
                            .frame(width: 57, height: 57)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            VStack(alignment: .leading) {
                Text(planMetaData.description)
                    .font(.system(size: 16))
                Label("\(planMetaData.readingTime)", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .frame(minHeight: 44)
        }
        .padding(.bottom, 10)
    }

    // MARK: - Readings Content

    @ViewBuilder
    private func readingsContent(planMetaData: PlanMetaData, geometry: GeometryProxy) -> some View {
        if geometry.size.width < 600 {
            ReadingsView(
                planMetaData: planMetaData,
                stackHorizontally: false
            )
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 0, leading: 15, bottom: 20, trailing: 15))
        } else {
            ReadingsView(
                planMetaData: planMetaData,
                stackHorizontally: true
            )
            .padding(EdgeInsets(top: 0, leading: 15, bottom: 20, trailing: 15))
        }
    }

}

// MARK: - Trailing Icon Label Style

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.title
            configuration.icon
        }
    }
}

#Preview {
    PlanView()
}
