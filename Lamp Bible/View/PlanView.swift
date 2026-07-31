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
    @Environment(\.colorScheme) var colorScheme

    // Deep link navigation
    @ObservedObject private var deepLinkManager = DeepLinkManager.shared
    @State private var showDeepLinkReader: Bool = false
    @State private var deepLinkVerseId: Int? = nil
    @State private var deepLinkTranslationId: String? = nil
    @State private var deepLinkPlanMode: Bool = false

    private var iOS26OrLater: Bool {
        if #available(iOS 26, *) {
            return true
        } else {
            return false
        }
    }

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
                        PlanDateToolbarView(date: $date, showingDatePicker: $showingDatePicker)
                    }
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            HStack(spacing: 25) {
                                NavigationLink(destination: SplitReaderView(
                                    date: $date
                                )) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "book.fill")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Read")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }

                                NavigationLink(destination: SearchView()) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Search")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }

                                NavigationLink(destination: PlanPickerView()) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "calendar")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Plans")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }

                                NavigationLink(destination: DevotionalPickerView(
                                    isFullScreen: false,
                                    showNewProminent: true,
                                    initialModuleId: "devotionals"
                                )) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "pencil.line")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Write")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }

                                NavigationLink(destination: SettingsView(
                                    externalApps: externalBibleApps,
                                    planViewRefreshId: $planViewRefreshId
                                )) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "gear")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Settings")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
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
                    ForEach(plans) { plan in
                        planSection(plan: plan, geometry: geometry, proxy: proxy)
                    }
                    Spacer()
                }
            }
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
