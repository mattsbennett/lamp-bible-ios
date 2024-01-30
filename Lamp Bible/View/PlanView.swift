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
                                                }
                                            }
                                        }
                                        .onChange(of: date) {
                                            proxy.scrollTo(plan.name)
                                        }
                                        .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 20))
                                        ScrollView(.horizontal) {
                                            ScrollViewReader { proxy in
                                                HStack {
                                                    ForEach(readings.indices, id: \.self) { index in
                                                        let readingMetaData = planMetaData.readingMetaData.first(where: { $0.id == index })!
                                                        VStack(alignment: .leading) {
                                                            HStack {
                                                                Label {
                                                                    Text("Portion")
                                                                } icon: {
                                                                    HStack {
                                                                        ForEach(0..<index + 1, id: \.self) { _ in
                                                                            Image("lampflame.fill")
                                                                                .font(.system(size: 16))
                                                                                .padding(.trailing, -11)
                                                                                .padding(.leading, -3)
                                                                        }
                                                                    }
                                                                }.labelStyle(TrailingIconLabelStyle())
                                                            }
                                                            .font(.caption)
                                                            .foregroundStyle(Color.secondary)
                                                            HStack {
                                                                Text(readingMetaData.description).font(.body)
                                                                Spacer()
                                                                if user.planExternalBible != nil && user.planExternalBible != "None" {
                                                                    Button {
                                                                        let app = externalBibleApps.first(where: { $0.name == user.planExternalBible })
                                                                        if let url = app?.getFullUrl(sv: readingMetaData.sv, ev: readingMetaData.ev) {
                                                                            if UIApplication.shared.canOpenURL(url) {
                                                                                UIApplication.shared.open(url)
                                                                            }
                                                                        }
                                                                    } label: {
                                                                        ZStack {
                                                                            Circle()
                                                                                .stroke(Color.accentColor, lineWidth: 2)
                                                                            Image("book.and.external.fill")
                                                                                .foregroundColor(Color.accentColor)
                                                                                .font(.title3)
                                                                        }
                                                                    }
                                                                    .frame(width: 57, height: 57)
                                                                    .clipShape(Circle())
                                                                    .foregroundColor(.accentColor)
                                                                }
                                                            }
                                                            .padding(.vertical)
                                                            Spacer()
                                                            HStack {
                                                                Label("\(readingMetaData.genre)", systemImage: "bookmark.fill")
                                                                Spacer()
                                                                Label("\(readingMetaData.readingTime)", systemImage: "clock").labelStyle(TrailingIconLabelStyle())
                                                            }
                                                            .font(.caption)
                                                            .foregroundStyle(Color.secondary)
                                                        }
                                                        .id(index)
                                                        .frame(minWidth: 200, maxWidth: 350)
                                                        .padding()
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 15)
                                                                .fill(Color.clear)
                                                                .overlay(
                                                                    RoundedRectangle(cornerRadius: 15)
                                                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                                                                )
                                                        )
                                                        .onChange(of: date) {
                                                            proxy.scrollTo(0)
                                                        }
                                                    }
                                                    Spacer().frame(width: 15)
                                                }
                                                .frame(maxWidth: .infinity)
                                            }
                                        }
                                        .padding(.leading, 15)
                                        .padding(.bottom, 25)
                                        .scrollIndicators(.never)
                                        
                                        if plan.id != user.plans.last!.id {
                                            Divider()
                                        }
                                    }
                                }
                                Spacer()
                            }
                            .gesture(
                                DragGesture()
                                    .onEnded { gesture in
                                        if gesture.translation.width < -200 {
                                            // Perform action for left swipe
                                            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
                                        } else if gesture.translation.width > 200 {
                                            // Perform action for right swipe
                                            date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
                                        }
                                    }
                            )
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
