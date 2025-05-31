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
    
    init(user: User, plans: Results<Plan>, date: Date = Date.now) {
        self.plans = plans
        self.user = user
        _plansMetaData = State(initialValue: PlansMetaData(plans: plans, date: date))
    }

    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                VStack {
                    if user.plans.count > 0 {
                        ScrollView {
                            ScrollViewReader { proxy in
                                VStack(alignment: .leading) {
                                    ForEach(plans) { plan in
                                        let planMetaData = plansMetaData.planMetaData.first(where: { $0.id == plan.id })!
                                        let readings = planMetaData.readingMetaData
                                        if (user.plans.filter("id == \(plan.id)").count > 0) {
                                            Spacer().id(plan.name)
                                            VStack(alignment: .leading) {
                                                HStack {
                                                    VStack(alignment: .leading) {
                                                        Text(plan.name)
                                                            .font(.title2)
                                                            .fontWeight(.black)
                                                        if readings.count > 0 {
                                                            HStack {
                                                                if user.planInAppBible {
                                                                    NavigationLink(
                                                                        destination: ReaderView(
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
                                                                    Label("\(planMetaData.readingTime)", systemImage: "clock").font(.caption).foregroundStyle(Color.secondary)
                                                                }
                                                                .frame(minHeight: 44)
                                                            }
                                                            .padding(.bottom, 10)
                                                        } else {
                                                            Text("No readings for today")
                                                                .padding(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
                                                                .foregroundStyle(Color.secondary)
                                                        }
                                                    }
                                                }
                                            }
                                            .onChange(of: date) {
                                                proxy.scrollTo(plan.name)
                                            }
                                            .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))
                                            
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
                                            
                                            if plan.id != user.plans.last!.id {
                                                Divider()
                                            }
                                        }
                                    }
                                    Spacer()
                                }
//                                iOS 18 broke gestures on scrollviews
//                                .gesture(
//                                    DragGesture()
//                                        .onEnded { gesture in
//                                            if gesture.translation.width < -200 {
//                                                // Perform action for left swipe
//                                                date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
//                                            } else if gesture.translation.width > 200 {
//                                                // Perform action for right swipe
//                                                date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
//                                            }
//                                        }
//                                )
                            }
                        }
                    } else {
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
                }
                .onChange(of: planViewRefreshId) {
                    // This seems like a hack, but on returning from SettingsView, we need to refresh
                    // plansMetaData for reading time estimates to take effect
                    plansMetaData = PlansMetaData(plans: plans, date: date)
                }
                .onChange(of: date) {
                    plansMetaData = PlansMetaData(plans: plans, date: date)
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSCalendarDayChanged)) { _ in
                    // Update the date to the current date if day has changed
                    date = Date()
                }
                .frame(maxWidth: .infinity)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PlanDateToolbarView(date: $date, showingDatePicker: $showingDatePicker)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        
                        NavigationLink(destination: PlanPickerView(plans: plans)) {
                            VStack {
                                Image(systemName: "calendar")
                                    .font(.callout)
                                    .padding(EdgeInsets(top: 1, leading: 0, bottom: 0.5, trailing: 0))
                                Text("Plans")
                                    .font(.caption2)
                            }
                        }
                        
                        Spacer()
                        
                        NavigationLink(destination: ReaderView(
                            user: RealmManager.shared.realm.objects(User.self).first!,
                            date: $date
                        )) {
                            VStack {
                                Image(systemName: "book.fill")
                                    .font(.callout)
                                    .padding(EdgeInsets(top: 1.5, leading: 0, bottom: 2, trailing: 0))
                                Text("Read")
                                    .font(.caption2)
                            }
                        }
                        
                        Spacer()
                        
                        NavigationLink(destination: SettingsView(
                            user: user,
                            externalApps: externalBibleApps,
                            plans: plans,
                            planViewRefreshId: $planViewRefreshId
                        )) {
                            VStack {
                                Image(systemName: "gear")
                                    .font(.callout)
                                    .padding(EdgeInsets(top: 1, leading: 0, bottom: 0.1, trailing: 0))
                                Text("Settings")
                                    .font(.caption2)
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
        }
    }
}

// Make a struct that conforms to the LabelStyle protocol,
//and return a view that has the title and icon switched in a HStack
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
