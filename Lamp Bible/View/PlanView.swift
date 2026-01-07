//
//  TodayView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-04.
//
import RealmSwift
import SwiftUI

struct PlanView: View {
    @ObservedRealmObject var user: User
    @State private var planViewRefreshId = UUID()
    @State private var showingDatePicker = false
    @State private var showingInfoModal = false
    @State private var date = Date.now
    @State private var plansMetaData: PlansMetaData
    @Environment(\.colorScheme) var colorScheme
    let plans: Results<Plan>

    private var iOS26OrLater: Bool {
        if #available(iOS 26, *) {
            return true
        } else {
            return false
        }
    }

    init(user: User, plans: Results<Plan>, date: Date = Date.now) {
        self.plans = plans
        self.user = user
        _plansMetaData = State(initialValue: PlansMetaData(plans: plans, date: date))
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                mainContent(geometry: geometry)
                    .onChange(of: planViewRefreshId) {
                        plansMetaData = PlansMetaData(plans: plans, date: date)
                    }
                    .onChange(of: date) {
                        plansMetaData = PlansMetaData(plans: plans, date: date)
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
                                NavigationLink(destination: PlanPickerView(plans: plans)) {
                                    VStack(spacing: 4) {
                                        Image(systemName: "calendar")
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                        Text("Plans")
                                            .font(.caption2)
                                            .foregroundColor(iOS26OrLater ? .primary : .red)
                                    }
                                }

                                NavigationLink(destination: SplitReaderView(
                                    user: RealmManager.shared.realm.objects(User.self).first!,
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

                                NavigationLink(destination: SettingsView(
                                    user: user,
                                    externalApps: externalBibleApps,
                                    plans: plans,
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
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(geometry: GeometryProxy) -> some View {
        VStack {
            if user.plans.count > 0 {
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
            NavigationLink(destination: PlanPickerView(plans: plans)) {
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
        let planMetaData = plansMetaData.planMetaData.first(where: { $0.id == plan.id })!
        let readings = planMetaData.readingMetaData

        if user.plans.filter("id == \(plan.id)").count > 0 {
            Spacer().id(plan.name)

            planHeader(plan: plan, planMetaData: planMetaData, readings: readings)
                .onChange(of: date) {
                    proxy.scrollTo(plan.name)
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))

            readingsContent(planMetaData: planMetaData, geometry: geometry)

            if plan.id != user.plans.last!.id {
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
                        readingsRow(planMetaData: planMetaData, readings: readings)
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
    private func readingsRow(planMetaData: PlanMetaData, readings: [ReadingMetaData]) -> some View {
        HStack {
            if user.planInAppBible {
                NavigationLink(
                    destination: SplitReaderView(
                        user: RealmManager.shared.realm.objects(User.self).first!,
                        date: $date,
                        readingMetaData: readings
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
                user: RealmManager.shared.realm.objects(User.self).first!,
                planMetaData: planMetaData,
                stackHorizontally: false
            )
            .frame(maxWidth: .infinity)
            .padding(EdgeInsets(top: 0, leading: 15, bottom: 20, trailing: 15))
        } else {
            ReadingsView(
                user: RealmManager.shared.realm.objects(User.self).first!,
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
    PlanView(
        user: RealmManager.shared.realm.objects(User.self).first!,
        plans: RealmManager.shared.realm.objects(Plan.self)
    )
}
