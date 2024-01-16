//
//  SettingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-06.
//

import RealmSwift
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var planViewRefreshID: UUID
    @State var planWpm: Double
    @State var notificationTime: Date = Date.now
    @State var showingNotificationAlert = false
    let plans: Results<Plan>
    let externalApps: [ExternalBibleApp]

    init(
        user: User,
        externalApps: [ExternalBibleApp],
        plans: Results<Plan>,
        planWpm: Double = RealmManager.shared.realm.objects(User.self).first!.planWpm,
        planViewRefreshId: Binding<UUID>
    ) {
        self.user = user
        self.externalApps = externalApps
        self.plans = plans
        _planViewRefreshID = planViewRefreshId
        _planWpm = State(initialValue: planWpm)
    }

    func scheduleRecurringNotification(at date: Date) {
        let calendar = Calendar.current
        let content = UNMutableNotificationContent()
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        content.title = "Bible Reading Reminder"
        content.body = "It's time for your daily Bible reading"

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: "recurringNotification", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request)
    }

    func unscheduleRecurringNotification() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    var body: some View {
        NavigationStack {
            Form {
                let generator = UINotificationFeedbackGenerator()
                Section {
                    Toggle(isOn: $user.planInAppBible) {
                        Text("In-app Bible")
                    }.tint(.accentColor)
                } header: {
                    Text("Reading Plan Settings")
                } footer: {
                    Text("Show the ") + Text(Image(systemName: "book.fill")) + Text(" button to open readings the in-app Bible")
                }
                .headerProminence(.increased)
                Section {
                    ForEach(externalApps) { app in
                        HStack{
                            Button {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }

                                    thawedUser.planExternalBible = app.name
                                    generator.notificationOccurred(.success)
                                }
                            } label: {
                                Text(app.name).tint(.primary)
                            }
                            .disabled(!app.scheme.isEmpty ? !UIApplication.shared.canOpenURL(URL(string: app.scheme)!) : false)
                            Spacer()
                            if ( user.planExternalBible == app.name || (user.planExternalBible == nil && app.name == "None") ) {
                                Text(Image(systemName: "checkmark")).foregroundColor(.accentColor)
                            }
                        }
                    }
                } header: {
                    Text("External Bible")
                } footer: {
                    Text("Show the ") + Text(Image("book.and.external.fill")) + Text(" button to open readings in the selected Bible app.")
                }
                Section {
                    HStack {
                        Spacer()
                        Text("\(Int(planWpm)) wpm")
                        Spacer()
                    }
                    Slider(value: $planWpm, in: 70...400, step: 1) { editing in
                        if !editing {
                            try! RealmManager.shared.realm.write {
                                guard let thawedUser = user.thaw() else {
                                    // Handle the inability to thaw the object
                                    return
                                }
                                thawedUser.planWpm = planWpm
                                planViewRefreshID = UUID()
                            }
                        }
                    }
                    Text("Presets (Adult Avg)").font(.system(size: 12)).textCase(.uppercase).foregroundStyle(Color.secondary).padding(.bottom, -10)
                    Button("Aloud") {
                        let aloudSetting = 183.0
                        planWpm = aloudSetting
                        try! RealmManager.shared.realm.write {
                            guard let thawedUser = user.thaw() else {
                                // Handle the inability to thaw the object
                                return
                            }
                            thawedUser.planWpm = aloudSetting
                            planViewRefreshID = UUID()
                            generator.notificationOccurred(.success)
                        }
                    }
                    Button("Silent") {
                        let slientSetting = 238.0
                        planWpm = slientSetting
                        try! RealmManager.shared.realm.write {
                            guard let thawedUser = user.thaw() else {
                                // Handle the inability to thaw the object
                                return
                            }
                            thawedUser.planWpm = slientSetting
                            planViewRefreshID = UUID()
                            generator.notificationOccurred(.success)
                        }
                    }
                } header: {
                    Text("Reading rate (WPM)")
                } footer: {
                    Text("Adjust reading rate to achieve personalized accuracy in reading plan reading time estimates")
                }
                .listRowSeparator(.hidden)
                Section {
                    Toggle(isOn: $user.planNotification) {
                        Text("Remind me daily")
                    }.tint(.accentColor)
                    DatePicker("Reminder time", selection: $user.planNotificationDate, displayedComponents: .hourAndMinute)
                        .disabled(!user.planNotification)
                } header: {
                    Text("Daily Plan Reminder")
                }
                .alert("No reading plans", isPresented: $showingNotificationAlert) { NavigationLink(destination: PlanPickerView(plans: plans)) {
                        Button("Go to plans") {
                            showingNotificationAlert = false
                        }
                    }
                    Button("Close") {
                        showingNotificationAlert = false
                    }
                } message: {
                    Text("A reading plan must be selected before notifications can be enabled.")
                }.textCase(nil)
                .onChange(of: user.planNotification) { oldValue, newValue in
                    if !oldValue && newValue {
                        if user.plans.count == 0 {
                            showingNotificationAlert = true
                            try! RealmManager.shared.realm.write {
                                guard let thawedUser = user.thaw() else {
                                    // Handle the inability to thaw the object
                                    return
                                }
                                thawedUser.planNotification = false
                            }
                            return
                        }
                        UNUserNotificationCenter.current().getNotificationSettings { settings in
                            if settings.authorizationStatus == .authorized {
                                DispatchQueue.main.async {
                                    scheduleRecurringNotification(at: user.planNotificationDate)
                                }
                            } else {
                                // Notification permission has not been granted
                                // You can handle this case accordingly
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                                    if granted {
                                        DispatchQueue.main.async {
                                            scheduleRecurringNotification(at: user.planNotificationDate)
                                        }
                                    } else if let error = error {
                                        print(error.localizedDescription)
                                        try! RealmManager.shared.realm.write {
                                            guard let thawedUser = user.thaw() else {
                                                // Handle the inability to thaw the object
                                                return
                                            }
                                            thawedUser.planNotification = false
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        unscheduleRecurringNotification()
                    }
                }
                .onChange(of: user.planNotificationDate) { oldValue, newValue in
                    unscheduleRecurringNotification()
                    scheduleRecurringNotification(at: newValue)
                }
                Section {
                    ForEach(RealmManager.shared.realm.objects(Translation.self)) { translation in
                        HStack{
                            Button {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.readerTranslation = translation
                                    generator.notificationOccurred(.success)
                                }
                            } label: {
                                Text(translation.name).tint(.primary)
                            }
                            Spacer()
                            if (user.readerTranslation!.id == translation.id) {
                                Text(Image(systemName: "checkmark")).foregroundColor(.accentColor)
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading) {
                        Text("Bible Settings").padding(.bottom, 8).padding(.top, 15)
                        Text("Default Translation").font(.system(size: 12)).textCase(.uppercase).foregroundStyle(Color.secondary).padding(.bottom, -5)
                    }
                }
                .headerProminence(.increased)
                Section {
                    let sorts = ["r","sv"]
                    let sortNames = ["Relevance","Verse"]
                    ForEach(sorts.indices, id: \.self) { index in
                        HStack{
                            Button {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.readerCrossReferenceSort = sorts[index]
                                    generator.notificationOccurred(.success)
                                }
                            } label: {
                                Text(sortNames[index]).tint(.primary)
                            }
                            Spacer()
                            if (user.readerCrossReferenceSort == sorts[index]) {
                                Text(Image(systemName: "checkmark")).foregroundColor(.accentColor)
                            }
                        }
                    }
                } header: {
                    Text("Cross Reference Sort")
                }
            }
            .navigationBarBackButtonHidden(true)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(Image(systemName: "arrow.backward"))
                    }
                }
            }
        }
    }
}

struct SettingsViewPreview: View {
    @State var previewUUID = UUID()

    var body: some View {
        SettingsView(
            user: RealmManager.shared.realm.objects(User.self).first!,
            externalApps: externalBibleApps,
            plans: RealmManager.shared.realm.objects(Plan.self),
            planViewRefreshId: $previewUUID
        )
    }
}

#Preview {
    SettingsViewPreview()
}
