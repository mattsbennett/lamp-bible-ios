//
//  SettingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-06.
//

import RealmSwift
import SwiftUI
import GRDB

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var planViewRefreshID: UUID
    @State var planWpm: Double
    @State var notificationTime: Date = Date.now
    @State var showingNotificationAlert = false
    @State var iCloudAvailable: Bool = false
    @State var moduleSyncInProgress: Bool = false
    @State var moduleCount: Int? = nil
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
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

                // MARK: - Tool Settings
                Section {
                    NavigationLink {
                        ModuleSettingsView(user: user)
                    } label: {
                        Label("Module Settings", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        ModuleManagerView()
                    } label: {
                        Label("Module Manager", systemImage: "shippingbox")
                    }

                    // iCloud storage status
                    HStack {
                        Text("Storage")
                        Spacer()
                        if iCloudAvailable {
                            Text("iCloud Drive").foregroundStyle(.secondary)
                            Image(systemName: "checkmark.icloud.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not Available").foregroundStyle(.secondary)
                            Image(systemName: "xmark.icloud")
                                .foregroundStyle(.red)
                        }
                    }

                    // Sync status
                    HStack {
                        Text("Status")
                        Spacer()
                        if moduleSyncInProgress {
                            Text("Syncing...").foregroundStyle(.secondary)
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if let count = moduleCount {
                            Text("\(count) module\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("Not synced").foregroundStyle(.secondary)
                        }
                    }

                    // Manual sync button
                    Button {
                        Task {
                            moduleSyncInProgress = true
                            await ModuleSyncManager.shared.syncAll()
                            moduleCount = (try? ModuleDatabase.shared.getAllModules().count) ?? 0
                            moduleSyncInProgress = false
                        }
                    } label: {
                        HStack {
                            Text("Sync Now")
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(moduleSyncInProgress)
                } header: {
                    VStack(alignment: .leading) {
                        Text("Tool Settings").padding(.bottom, 8).padding(.top, 15)
                        Text("Modules").font(.system(size: 12)).textCase(.uppercase).foregroundStyle(Color.secondary).padding(.bottom, -5)
                    }
                } footer: {
                    if iCloudAvailable {
                        Text("Import and manage notes, dictionaries, commentaries, and devotionals synced via iCloud Drive.")
                    } else {
                        Text("iCloud Drive is not available. Check your network connection or enable iCloud Drive for Lamp Bible in Settings → Apple Account → iCloud → Saved to iCloud.")
                    }
                }
                .headerProminence(.increased)
                .task {
                    iCloudAvailable = await ICloudNoteStorage.shared.isAvailable()
                    moduleCount = (try? ModuleDatabase.shared.getAllModules().count) ?? 0
                }

                // Notes panel (iPad only)
                if horizontalSizeClass != .compact {
                    Section {
                        Picker("Panel Position", selection: $notesPanelOrientation) {
                            Text("Bottom").tag("bottom")
                            Text("Right").tag("right")
                        }
                    } header: {
                        Text("Notes Panel")
                    }
                }

                // MARK: - Reading Plan Settings
                Section {
                    Toggle(isOn: $user.planInAppBible) {
                        Text("In-app Bible")
                    }.tint(.accentColor)
                } header: {
                    VStack(alignment: .leading) {
                        Text("Reading Plan Settings").padding(.bottom, 8).padding(.top, 15)
                        Text("Bible Options").font(.system(size: 12)).textCase(.uppercase).foregroundStyle(Color.secondary).padding(.bottom, -5)
                    }
                } footer: {
                    Text("Show the ") + Text(Image(systemName: "book.fill")) + Text(" button to open readings in the in-app Bible")
                }
                .headerProminence(.increased)

                Section {
                    ForEach(externalApps) { app in
                        HStack {
                            Button {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
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
                            if (user.planExternalBible == app.name || (user.planExternalBible == nil && app.name == "None")) {
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
                                return
                            }
                            thawedUser.planWpm = aloudSetting
                            planViewRefreshID = UUID()
                            generator.notificationOccurred(.success)
                        }
                    }
                    Button("Silent") {
                        let silentSetting = 238.0
                        planWpm = silentSetting
                        try! RealmManager.shared.realm.write {
                            guard let thawedUser = user.thaw() else {
                                return
                            }
                            thawedUser.planWpm = silentSetting
                            planViewRefreshID = UUID()
                            generator.notificationOccurred(.success)
                        }
                    }
                } header: {
                    Text("Reading Rate (WPM)")
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
                .alert("No reading plans", isPresented: $showingNotificationAlert) {
                    NavigationLink(destination: PlanPickerView(plans: plans)) {
                        Button("Go to plans") {
                            showingNotificationAlert = false
                        }
                    }
                    Button("Close") {
                        showingNotificationAlert = false
                    }
                } message: {
                    Text("A reading plan must be selected before notifications can be enabled.")
                }
                .textCase(nil)
                .onChange(of: user.planNotification) { oldValue, newValue in
                    if !oldValue && newValue {
                        if user.plans.count == 0 {
                            showingNotificationAlert = true
                            try! RealmManager.shared.realm.write {
                                guard let thawedUser = user.thaw() else {
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
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                                    if granted {
                                        DispatchQueue.main.async {
                                            scheduleRecurringNotification(at: user.planNotificationDate)
                                        }
                                    } else if let error = error {
                                        print(error.localizedDescription)
                                        try! RealmManager.shared.realm.write {
                                            guard let thawedUser = user.thaw() else {
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
            }
            .navigationBarBackButtonHidden(true)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "arrow.backward")
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
