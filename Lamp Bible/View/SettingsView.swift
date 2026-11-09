//
//  SettingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-06.
//

import SwiftUI
import Combine
import GRDB
import AVFoundation
import LampCore

struct SettingsView: View {
    /// "1.2.0 (1)": the marketing version and the build.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @Environment(\.dismiss) var dismiss
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()
    private let settingsChanged = NotificationCenter.default.publisher(for: .userDatabaseDidChange)
    @Binding var planViewRefreshID: UUID
    @State var planWpm: Double
    @State var notificationTime: Date = Date.now
    @State var showingNotificationAlert = false
    @State var showingDatabaseResetAlert = false
    @State var iCloudAvailable: Bool = false
    @State var moduleSyncInProgress: Bool = false
    @State var moduleCount: Int? = nil
    @State private var manualSyncError: String? = nil
    @State private var showingManualSyncError: Bool = false
    @State private var syncBackend: SyncBackend = .none
    @State private var webdavURL: String = ""
    @State private var webdavUsername: String = ""
    @State private var webdavPassword: String = ""
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: ConnectionTestResult? = nil
    @State private var previousBackend: SyncBackend = .none
    @State private var showingMigrationDialog: Bool = false
    @State private var pendingBackendChange: SyncBackend? = nil
    @State private var isMigrating: Bool = false
    @State private var migrationResult: MigrationResult? = nil
    @State private var showingWebDAVSetup: Bool = false
    @State private var showingWebDAVConfig: Bool = false
    @State private var hasLoadedSettings: Bool = false
    @State private var showingWipeConfirmation: Bool = false
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared
    @ObservedObject private var moduleSyncManager = ModuleSyncManager.shared
    @State private var showingNoteConflicts: Bool = false
    @State private var showingDevotionalConflicts: Bool = false

    enum ConnectionTestResult {
        case success
        case failure(String)
    }
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
    @AppStorage("readerSimplifiedText") private var readerSimplifiedText: Bool = false
    let externalApps: [ExternalBibleApp]

    init(
        externalApps: [ExternalBibleApp],
        planViewRefreshId: Binding<UUID>
    ) {
        let settings = UserDatabase.shared.getSettings()
        _userSettings = State(initialValue: settings)
        self.externalApps = externalApps
        _planViewRefreshID = planViewRefreshId
        _planWpm = State(initialValue: settings.planWpm)
    }

    @ViewBuilder
    private var readAloudSection: some View {
        ReadAloudSettingsSection(translationId: userSettings.readerTranslationId)
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

    private func testWebDAVConnection() async {
        isTestingConnection = true
        connectionTestResult = nil

        do {
            let success = try await SyncCoordinator.shared.testWebDAVConnection(
                url: webdavURL,
                username: webdavUsername.isEmpty ? nil : webdavUsername,
                password: webdavPassword.isEmpty ? nil : webdavPassword
            )

            if success {
                // Save WebDAV settings on successful test
                try await SyncCoordinator.shared.setWebDAVSettings(
                    url: webdavURL,
                    username: webdavUsername.isEmpty ? nil : webdavUsername
                )
                try SyncCoordinator.shared.saveWebDAVPassword(webdavPassword)
                connectionTestResult = .success
            } else {
                connectionTestResult = .failure("Connection failed")
            }
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
        }

        isTestingConnection = false
    }

    private func handleNotificationToggle(oldValue: Bool, newValue: Bool) {
        if !oldValue && newValue {
            if userSettings.planIds.isEmpty {
                showingNotificationAlert = true
                userSettings.planNotification = false
                try? UserDatabase.shared.updateSettings { $0.planNotification = false }
                return
            }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                if settings.authorizationStatus == .authorized {
                    DispatchQueue.main.async {
                        scheduleRecurringNotification(at: userSettings.planNotificationDate)
                    }
                } else {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                        if granted {
                            DispatchQueue.main.async {
                                scheduleRecurringNotification(at: userSettings.planNotificationDate)
                            }
                        } else if let error = error {
                            print(error.localizedDescription)
                            DispatchQueue.main.async {
                                userSettings.planNotification = false
                                try? UserDatabase.shared.updateSettings { $0.planNotification = false }
                            }
                        }
                    }
                }
            }
        } else if !newValue {
            unscheduleRecurringNotification()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                let generator = UINotificationFeedbackGenerator()

                Section {
                    SettingsIdentityCard(
                        moduleCount: moduleCount,
                        syncSummary: syncBackend == .none ? "On this iPhone" : "Syncs with \(syncBackend.displayName)"
                    )
                }

                // MARK: - Tool Settings
                Section {
                    NavigationLink {
                        ModuleManagerView()
                    } label: {
                        SettingsRowLabel(
                            title: "Module Manager",
                            subtitle: "Install, import and remove modules",
                            systemImage: "shippingbox.fill",
                            color: .accentColor
                        )
                    }
                    // The row's former name, kept for automation.
                    .accessibilityIdentifier("Manager")

                    NavigationLink {
                        ModuleSettingsView(userSettings: $userSettings)
                    } label: {
                        SettingsRowLabel(
                            title: "Translations & Lexicons",
                            subtitle: "Default translation, word hints, lexicon order",
                            systemImage: "character.book.closed.fill",
                            color: .indigo
                        )
                    }
                } header: {
                    Text("Modules").lampSectionHeader()
                }

                // MARK: - Sync Settings
                Section {
                    Picker(selection: $syncBackend) {
                        ForEach(SyncBackend.allCases, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    } label: {
                        Label {
                            Text("Sync Method")
                        } icon: {
                            LampIconTile(systemName: "arrow.triangle.2.circlepath", color: .blue)
                        }
                    }
                    .onChange(of: syncBackend) { oldValue, newValue in
                        // Ignore initial load and changes while handling a pending switch
                        guard hasLoadedSettings, pendingBackendChange == nil else { return }

                        // Any backend change should offer migrate/wipe options
                        if oldValue != newValue {
                            pendingBackendChange = newValue
                            syncBackend = oldValue // Revert until user decides

                            if newValue == .webdav {
                                // Switching TO WebDAV - need to configure first
                                showingWebDAVSetup = true
                            } else {
                                // Show migration dialog for all other switches
                                showingMigrationDialog = true
                            }
                        }
                    }

                    // Backend-specific status
                    switch syncBackend {
                    case .icloudDrive:
                        HStack {
                            Text("Status")
                            Spacer()
                            if iCloudAvailable {
                                Text("Connected").foregroundStyle(.secondary)
                                Image(systemName: "checkmark.icloud.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Not Available").foregroundStyle(.secondary)
                                Image(systemName: "xmark.icloud")
                                    .foregroundStyle(.red)
                            }
                        }

                    case .webdav:
                        HStack {
                            Text("Status")
                            Spacer()
                            if webdavURL.isEmpty {
                                Text("Not Configured").foregroundStyle(.secondary)
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else if iCloudAvailable {
                                Text("Connected").foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Not Connected").foregroundStyle(.secondary)
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }

                    case .none:
                        HStack {
                            Label {
                                Text("Status")
                            } icon: {
                                LampIconTile(systemName: "iphone", color: .gray)
                            }
                            Spacer()
                            // The state, not the method again: the row above
                            // already says Local Only.
                            Text("Not Syncing")
                                .foregroundStyle(LampTheme.caption)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    // Sync status (for all backends except none)
                    if syncBackend != .none {
                        HStack {
                            Text("Modules")
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

                        // WebDAV server settings
                        if syncBackend == .webdav {
                            Button {
                                showingWebDAVConfig = true
                            } label: {
                                HStack {
                                    Text("Server Settings")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if !webdavURL.isEmpty {
                                        Text(webdavURL)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // Manual sync button
                        Button {
                            Task {
                                moduleSyncInProgress = true
                                do {
                                    try await syncCoordinator.syncAll()
                                    let modules = (try? ModuleDatabase.shared.getAllModules().count) ?? 0
                                    let translations = (try? TranslationDatabase.shared.getAllTranslations().count) ?? 0
                                    moduleCount = modules + translations
                                } catch {
                                    manualSyncError = error.localizedDescription
                                    showingManualSyncError = true
                                }
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
                        .alert("Sync failed", isPresented: $showingManualSyncError) {
                            Button("OK", role: .cancel) { manualSyncError = nil }
                        } message: {
                            Text(manualSyncError ?? "Sync could not be completed.")
                        }

                        if syncCoordinator.libraryAwaitingMove {
                            Label(
                                "This library is still in the earlier format. On your Mac, open Lamp Bible's Settings, choose Sync and press Move Library. This device syncs once it has moved.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }

                        if syncCoordinator.libraryMovable {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(
                                    "This library is still in the earlier format, and only this device has kept it. Nothing syncs until it moves to the new sync. Update Lamp Bible to 1.2.0 or later on your other devices first: older versions won't see changes made after the move.",
                                    systemImage: "arrow.triangle.2.circlepath"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                Button("Move Library") {
                                    Task {
                                        do {
                                            try await syncCoordinator.movePhoneLibraryToNewSync()
                                        } catch {
                                            manualSyncError = error.localizedDescription
                                            showingManualSyncError = true
                                        }
                                    }
                                }
                                .disabled(moduleSyncInProgress)
                            }
                        }

                        if !moduleSyncManager.pendingConflicts.isEmpty {
                            conflictRow(
                                count: moduleSyncManager.pendingConflicts.count,
                                kind: "note"
                            ) { showingNoteConflicts = true }
                        }

                        if !moduleSyncManager.pendingDevotionalConflicts.isEmpty {
                            conflictRow(
                                count: moduleSyncManager.pendingDevotionalConflicts.count,
                                kind: "devotional"
                            ) { showingDevotionalConflicts = true }
                        }

                        if syncCoordinator.olderDeviceSyncing {
                            Label(
                                "A device with an older Lamp Bible is still syncing here. Update it to 1.2.0 or later: until then it can't see changes made with the new sync, and they can't see its changes.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }

                        if !syncCoordinator.unsuppliedAttachments.isEmpty {
                            let names = syncCoordinator.unsuppliedAttachments
                                .map { ($0 as NSString).lastPathComponent }
                                .joined(separator: ", ")
                            Label(
                                "Your writings refer to attachments that aren't on this device or the server: \(names). Other devices show them as missing until they're added back here.",
                                systemImage: "paperclip"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Sync").lampSectionHeader()
                } footer: {
                    Group {
                    switch syncBackend {
                    case .icloudDrive:
                        if iCloudAvailable {
                            Text("Modules sync via iCloud Drive.")
                        } else {
                            Text("iCloud Drive is not available. Check Settings → Apple Account → iCloud → Saved to iCloud.")
                        }
                    case .webdav:
                        Text("Sync to your own server (Synology, Nextcloud, ownCloud, etc.). Files stored in specified WebDAV path directory.")
                    case .none:
                            Text("Your library stays on this device and isn't synced.")
                    }
                    }
                    .foregroundStyle(LampTheme.caption)
                }
                .task {
                    // Reload settings from database in case they weren't available at app launch
                    await SyncCoordinator.shared.reloadSettings()

                    // Load current settings
                    let settings = SyncCoordinator.shared.settings
                    syncBackend = settings.backend
                    previousBackend = settings.backend
                    webdavURL = settings.webdavURL ?? ""
                    webdavUsername = settings.webdavUsername ?? ""
                    webdavPassword = KeychainHelper.getWebDAVPassword() ?? ""

                    iCloudAvailable = await SyncCoordinator.shared.isAvailable
                    let modules = (try? ModuleDatabase.shared.getAllModules().count) ?? 0
                    let translations = (try? TranslationDatabase.shared.getAllTranslations().count) ?? 0
                    moduleCount = modules + translations

                    // Mark settings as loaded to enable onChange handling
                    hasLoadedSettings = true
                }

                // Notes panel (iPad only)
                if horizontalSizeClass != .compact {
                    Section {
                        Picker("Panel Position", selection: $notesPanelOrientation) {
                            Text("Bottom").tag("bottom")
                            Text("Right").tag("right")
                        }
                    } header: {
                        Text("Notes Panel").lampSectionHeader()
                    }
                }

                // MARK: - Reading Plan Settings
                Section {
                    Toggle(isOn: Binding(
                        get: { userSettings.planInAppBible },
                        set: { newValue in
                            try? UserDatabase.shared.updateSettings { $0.planInAppBible = newValue }
                            userSettings = UserDatabase.shared.getSettings()
                        }
                    )) {
                        Label {
                            Text("In-app Bible")
                        } icon: {
                            LampIconTile(systemName: "book.fill", color: .accentColor)
                        }
                    }.tint(.accentColor)
                } header: {
                    Text("Reading Plans").lampSectionHeader()
                } footer: {
                    Group {
                    Text("Tapping a reading opens it in Lamp Bible’s reader, and Start Reading goes through the day’s readings in order.")
                    }
                    .foregroundStyle(LampTheme.caption)
                }

                Section {
                    // Apps that can be chosen get rows; those not installed are
                    // named once, in a line, rather than as rows that do nothing.
                    let choosable = externalApps.filter { $0.application == nil || $0.isInstalled }
                    let uninstalled = externalApps.filter { $0.application != nil && !$0.isInstalled }
                    ForEach(choosable) { app in
                        let chosen = userSettings.planExternalBible == app.name
                            || (userSettings.planExternalBible == nil && app.name == "None")
                        Button {
                            try? UserDatabase.shared.updateSettings { $0.planExternalBible = app.name }
                            userSettings = UserDatabase.shared.getSettings()
                            generator.notificationOccurred(.success)
                        } label: {
                            HStack {
                                Text(app.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if chosen {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                    if !uninstalled.isEmpty {
                        Label {
                            Text("Also works with \(ListFormatter.localizedString(byJoining: uninstalled.map(\.name))), once installed on this iPhone.")
                                .font(.footnote)
                                .foregroundStyle(LampTheme.caption)
                        } icon: {
                            Image(systemName: "arrow.down.app")
                                .foregroundStyle(LampTheme.caption)
                        }
                    }
                } header: {
                    Text("Open Readings In").lampSectionHeader()
                } footer: {
                    Group {
                    Text("Each reading gets a button that opens it in the chosen app. With the in-app Bible off, tapping a reading opens it there instead.")
                    }
                    .foregroundStyle(LampTheme.caption)
                }

                Section {
                    HStack {
                        Label {
                            Text("Reading Rate")
                        } icon: {
                            LampIconTile(systemName: "gauge.with.dots.needle.67percent", color: .orange)
                        }
                        Spacer()
                        Text("\(Int(planWpm)) words a minute")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    Slider(value: $planWpm, in: 70...400, step: 1) {
                        Text("Reading Rate")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare.fill").foregroundStyle(.secondary)
                    } onEditingChanged: { editing in
                        if !editing {
                            try? UserDatabase.shared.updateSettings { $0.planWpm = planWpm }
                            userSettings = UserDatabase.shared.getSettings()
                            planViewRefreshID = UUID()
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Adult average")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        wpmPreset("Aloud", wpm: 183, generator: generator)
                        wpmPreset("Silent", wpm: 238, generator: generator)
                    }
                } header: {
                    Text("Reading Rate").lampSectionHeader()
                } footer: {
                    Group {
                    Text("Sets both the reading time estimates for plan readings and the pace Read Aloud speaks at.")
                    }
                    .foregroundStyle(LampTheme.caption)
                }

                readAloudSection

                Section {
                    Toggle(isOn: Binding(
                        get: { userSettings.planNotification },
                        set: { newValue in
                            let oldValue = userSettings.planNotification
                            try? UserDatabase.shared.updateSettings { $0.planNotification = newValue }
                            userSettings = UserDatabase.shared.getSettings()
                            handleNotificationToggle(oldValue: oldValue, newValue: newValue)
                        }
                    )) {
                        Label {
                            Text("Remind Me Daily")
                        } icon: {
                            LampIconTile(systemName: "bell.fill", color: .red)
                        }
                    }.tint(.accentColor)
                    DatePicker("Reminder time", selection: Binding(
                        get: { userSettings.planNotificationDate },
                        set: { newValue in
                            try? UserDatabase.shared.updateSettings { $0.planNotificationDate = newValue }
                            userSettings = UserDatabase.shared.getSettings()
                            unscheduleRecurringNotification()
                            scheduleRecurringNotification(at: newValue)
                        }
                    ), displayedComponents: .hourAndMinute)
                        .disabled(!userSettings.planNotification)
                } header: {
                    Text("Daily Plan Reminder").lampSectionHeader()
                }
                .alert("No reading plans", isPresented: $showingNotificationAlert) {
                    NavigationLink(destination: PlanPickerView()) {
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

                Section {
                    aboutLink("Privacy", url: "https://lampbible.com/privacy/apps", systemImage: "hand.raised.fill", color: .blue)
                    aboutLink("Content Licences", url: "https://lampbible.com/content-licences", systemImage: "doc.text.fill", color: .gray)
                    aboutLink("Software Licences", url: "https://lampbible.com/software-licences", systemImage: "chevron.left.forwardslash.chevron.right", color: .gray)
                } header: {
                    Text("About").lampSectionHeader()
                } footer: {
                    Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Privacy disclosures and licence notices for bundled content and software.")
                        // Which build this is decides which sync it speaks, so
                        // the Mac's migration can ask for it by number.
                        Text("Version \(Self.appVersion)")
                    }
                    }
                    .foregroundStyle(LampTheme.caption)
                }

#if DEBUG
                Section {
                    Toggle(isOn: $readerSimplifiedText) {
                        Text("Simplified Reader Text")
                    }
                    .tint(.accentColor)

                    Button(role: .destructive) {
                        showingDatabaseResetAlert = true
                    } label: {
                        Text("Reset Module Database")
                    }
                } header: {
                    Text("Debug").lampSectionHeader()
                } footer: {
                    Group {
                    Text("Temporarily renders the reader text with minimal formatting and no interactions to help diagnose scroll performance. Restart the app after changing.")
                    }
                    .foregroundStyle(LampTheme.caption)
                }
                .alert("Reset Database?", isPresented: $showingDatabaseResetAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Reset", role: .destructive) {
                        do {
                            try ModuleDatabase.shared.forceResetDatabase()
                            generator.notificationOccurred(.success)
                        } catch {
                            print("Failed to reset database: \(error)")
                            generator.notificationOccurred(.error)
                        }
                    }
                } message: {
                    Text("This will delete all devotionals and user-created content. This cannot be undone.")
                }
#endif
            }
            // Even room between groups, so a footer never sits against the
            // next group's header.
            .listSectionSpacing(20)
            .navigationBarBackButtonHidden(true)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "arrow.backward")
                    }
                }
            }
            // Migration confirmation dialog
            .alert("Migrate Data?", isPresented: $showingMigrationDialog) {
                Button("Migrate") {
                    Task {
                        await performMigration()
                    }
                }
                Button("Switch Only", role: .destructive) {
                    // Show secondary confirmation about data wipe
                    // Dismiss migration dialog first to prevent it from re-appearing
                    showingMigrationDialog = false
                    showingWipeConfirmation = true
                }
                Button("Cancel", role: .cancel) {
                    pendingBackendChange = nil
                }
            } message: {
                if let newBackend = pendingBackendChange {
                    Text(newBackend.usesRemoteStorage
                         ? "Switching from \(syncBackend.displayName) to \(newBackend.displayName).\n\n'Migrate' keeps this device's library and syncs it there, merged with any library already there.\n'Switch Only' starts fresh (wipes local data)."
                         : "Switching from \(syncBackend.displayName) to \(newBackend.displayName).\n\n'Migrate' keeps your library on this device.\n'Switch Only' starts fresh (wipes local data).")
                } else {
                    Text("Would you like to migrate your data to the new storage?")
                }
            }
            // Wipe confirmation dialog (secondary confirmation for Switch Only)
            .alert("Wipe Local Data?", isPresented: $showingWipeConfirmation) {
                Button("Wipe & Switch", role: .destructive) {
                    Task {
                        if let newBackend = pendingBackendChange {
                            do {
                                try await SyncCoordinator.shared.switchBackend(to: newBackend, migrateData: false)
                                syncBackend = newBackend
                                previousBackend = newBackend
                                iCloudAvailable = await SyncCoordinator.shared.isAvailable
                            } catch {
                                print("[SettingsView] Failed to switch backend: \(error)")
                            }
                        }
                        pendingBackendChange = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingBackendChange = nil
                }
            } message: {
                Text("This will permanently delete all your notes, devotionals, and highlights from this device.\n\nThis cannot be undone.")
            }
            // Migration progress sheet
            .sheet(isPresented: $isMigrating) {
                MigrationProgressView(
                    progress: nil,
                    result: migrationResult,
                    destination: syncBackend,
                    onDismiss: {
                        isMigrating = false
                        migrationResult = nil
                    }
                )
                .interactiveDismissDisabled(migrationResult == nil)
            }
            // WebDAV setup sheet
            .sheet(isPresented: $showingWebDAVSetup) {
                WebDAVSetupSheet(
                    sourceBackend: syncBackend,
                    webdavURL: $webdavURL,
                    webdavUsername: $webdavUsername,
                    webdavPassword: $webdavPassword,
                    onCancel: {
                        showingWebDAVSetup = false
                        pendingBackendChange = nil
                    },
                    onSwitchOnly: {
                        showingWebDAVSetup = false
                        Task {
                            do {
                                // Wipe data and switch (user already confirmed in WebDAVSetupSheet)
                                try await SyncCoordinator.shared.switchBackend(to: .webdav, migrateData: false)
                                syncBackend = .webdav
                                previousBackend = .webdav
                                iCloudAvailable = await SyncCoordinator.shared.isAvailable
                            } catch {
                                print("[SettingsView] Failed to switch to WebDAV: \(error)")
                            }
                            pendingBackendChange = nil
                        }
                    },
                    onMigrate: {
                        showingWebDAVSetup = false
                        Task {
                            await performMigration()
                        }
                    }
                )
            }
            // Refresh settings when remote sync merges new data
            .onReceive(settingsChanged) { _ in
                userSettings = UserDatabase.shared.getSettings()
            }
            // WebDAV configuration sheet (for editing existing config)
            .sheet(isPresented: $showingWebDAVConfig) {
                WebDAVConfigSheet(
                    webdavURL: $webdavURL,
                    webdavUsername: $webdavUsername,
                    webdavPassword: $webdavPassword,
                    onDone: { success in
                        showingWebDAVConfig = false
                        if success {
                            Task {
                                iCloudAvailable = await SyncCoordinator.shared.isAvailable
                            }
                        }
                    }
                )
            }
            .sheet(isPresented: $showingNoteConflicts) {
                NoteConflictView()
            }
            .sheet(isPresented: $showingDevotionalConflicts) {
                DevotionalConflictView()
            }
        }
    }

    /// A reading-rate preset: filled when it is the rate set now.
    private func wpmPreset(_ title: String, wpm: Double, generator: UINotificationFeedbackGenerator) -> some View {
        let isCurrent = Int(planWpm) == Int(wpm)
        return Button {
            planWpm = wpm
            try? UserDatabase.shared.updateSettings { $0.planWpm = wpm }
            userSettings = UserDatabase.shared.getSettings()
            planViewRefreshID = UUID()
            generator.notificationOccurred(.success)
        } label: {
            Text("\(title) · \(Int(wpm))")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(isCurrent ? .accentColor : .secondary)
        .accessibilityLabel("\(title), \(Int(wpm)) words a minute")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func aboutLink(_ title: String, url: String, systemImage: String, color: Color) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    LampIconTile(systemName: systemImage, color: color)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Changes made here and on another device that the person has to choose
    /// between. Their module can't upload until they do, so the sync
    /// settings say so too.
    private func conflictRow(count: Int, kind: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(count) \(kind)\(count == 1 ? "" : "s") changed on two devices")
                    .foregroundStyle(.primary)
                Spacer()
                Text("Resolve")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityHint("Those \(kind)s sync once you choose which version to keep")
    }

    private func performMigration() async {
        guard let newBackend = pendingBackendChange else { return }

        isMigrating = true
        migrationResult = nil

        do {
            // Use switchBackend with migrateData: true
            // This handles the migration and switches to the new backend
            try await SyncCoordinator.shared.switchBackend(to: newBackend, migrateData: true)

            // The coordinator commits the backend only after all stages succeed.
            migrationResult = MigrationResult(successCount: 1, failedFiles: [])

            syncBackend = newBackend
            previousBackend = newBackend
            iCloudAvailable = await SyncCoordinator.shared.isAvailable

        } catch MigrationError.incomplete(let result) {
            migrationResult = result
        } catch {
            migrationResult = MigrationResult(
                successCount: 0,
                failedFiles: [MigrationFailure(
                    type: .notes,
                    fileName: "Migration",
                    error: error.localizedDescription
                )]
            )
        }

        pendingBackendChange = nil
    }
}

// MARK: - Migration Progress View

struct MigrationProgressView: View {
    let progress: MigrationProgress?
    let result: MigrationResult?
    /// Where the library syncs now, once the switch has been made.
    let destination: SyncBackend
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let result = result {
                    // Show result
                    if result.isFullySuccessful {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                        Text("Switched to \(destination.displayName)")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(destination.usesRemoteStorage
                             ? "This device's library goes up with the next sync, merged with any library already there."
                             : "Your library stays on this device and no longer syncs.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.orange)
                        Text("Switch Didn't Finish")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(result.successCount) succeeded, \(result.failedFiles.count) failed")
                            .foregroundStyle(.secondary)

                        if !result.failedFiles.isEmpty {
                            List {
                                Section("Failed Files") {
                                    ForEach(result.failedFiles, id: \.fileName) { failure in
                                        VStack(alignment: .leading) {
                                            Text("\(failure.type.rawValue)/\(failure.fileName)")
                                                .font(.footnote)
                                            Text(failure.error)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }

                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)

                } else if let progress = progress {
                    // Show progress
                    ProgressView(value: progress.progress) {
                        Text("Migrating...")
                            .font(.headline)
                    } currentValueLabel: {
                        VStack {
                            Text("\(progress.filesCompleted) of \(progress.totalFiles) files")
                            if !progress.currentFile.isEmpty {
                                Text(progress.currentFile)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)

                } else {
                    // Initial state
                    ProgressView()
                    Text("Syncing to the new location...")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 60)
            .navigationTitle("Data Migration")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - WebDAV Config Sheet (for editing existing configuration)

struct WebDAVConfigSheet: View {
    @Binding var webdavURL: String
    @Binding var webdavUsername: String
    @Binding var webdavPassword: String
    let onDone: (Bool) -> Void

    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: ConnectionTestResult? = nil

    enum ConnectionTestResult {
        case success
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $webdavURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Username", text: $webdavUsername)
                        .textContentType(.username)
                        .autocapitalization(.none)

                    SecureField("Password", text: $webdavPassword)
                        .textContentType(.password)
                } header: {
                    Text("Connection Details")
                } footer: {
                    Text(verbatim: "Enter your WebDAV server URL (e.g. https://yourname.synology.me:5006/homes/yourname/LampBible)")
                }

                Section {
                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else if let result = connectionTestResult {
                                switch result {
                                case .success:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                case .failure:
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .disabled(webdavURL.isEmpty || isTestingConnection)

                    if case .failure(let error) = connectionTestResult {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("WebDAV Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDone(false)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveSettings()
                        }
                    }
                    .disabled(webdavURL.isEmpty)
                }
            }
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        defer { isTestingConnection = false }

        guard let url = URL(string: webdavURL) else {
            connectionTestResult = .failure("Invalid URL format")
            return
        }

        let storage = WebDAVModuleStorage(
            baseURL: url,
            username: webdavUsername.isEmpty ? nil : webdavUsername,
            password: webdavPassword.isEmpty ? nil : webdavPassword
        )

        let available = await storage.isAvailable()

        if available {
            connectionTestResult = .success
        } else {
            connectionTestResult = .failure("Could not connect to server")
        }
    }

    private func saveSettings() async {
        do {
            // Save password to keychain (an empty field removes it)
            try KeychainHelper.saveWebDAVPassword(webdavPassword)

            // Update SyncCoordinator settings
            try await SyncCoordinator.shared.setWebDAVSettings(
                url: webdavURL,
                username: webdavUsername.isEmpty ? nil : webdavUsername
            )

            // Reconfigure storage
            SyncCoordinator.shared.configureStorage()

            onDone(true)
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
        }
    }
}

// MARK: - WebDAV Setup Sheet (for initial setup with migration options)

struct WebDAVSetupSheet: View {
    let sourceBackend: SyncBackend
    @Binding var webdavURL: String
    @Binding var webdavUsername: String
    @Binding var webdavPassword: String
    let onCancel: () -> Void
    let onSwitchOnly: () -> Void
    let onMigrate: () -> Void

    enum SetupStep {
        case configure
        case connected
    }

    @State private var step: SetupStep = .configure
    @State private var isTestingConnection: Bool = false
    @State private var connectionError: String? = nil
    @State private var showingWipeConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .configure:
                    configureSection

                case .connected:
                    connectedSection
                }
            }
            .navigationTitle("WebDAV Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }

    // MARK: - Configure Step

    private var configureSection: some View {
        Group {
            Section {
                TextField("Server URL", text: $webdavURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .keyboardType(.URL)

                TextField("Username", text: $webdavUsername)
                    .textContentType(.username)
                    .autocapitalization(.none)

                SecureField("Password", text: $webdavPassword)
                    .textContentType(.password)
            } header: {
                Text("Connection Details")
            } footer: {
                Text(verbatim: "Enter your WebDAV server URL (e.g. https://yourname.synology.me:5006/homes/yourname/LampBible)")
            }

            Section {
                Button {
                    Task {
                        await testConnection()
                    }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(webdavURL.isEmpty || isTestingConnection)

                if let error = connectionError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Connected Step

    private var connectedSection: some View {
        Group {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title)
                    VStack(alignment: .leading) {
                        Text("Connected Successfully")
                            .font(.headline)
                        Text(webdavURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    onMigrate()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Migrate & Switch")
                            Text("Keep this device's library and sync it to the server")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    showingWipeConfirmation = true
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Switch Only")
                            Text("Start fresh on WebDAV (wipes local data)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Choose an Option")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("'Migrate & Switch' merges this device's library with any library already on the server. Nothing on the server is removed.")
                    Text("Your files on \(sourceBackend.displayName) will not be removed.")
                }
            }
            .alert("Wipe Local Data?", isPresented: $showingWipeConfirmation) {
                Button("Wipe & Switch", role: .destructive) {
                    onSwitchOnly()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete all your notes, devotionals, and highlights from this device.\n\nThis cannot be undone.")
            }
        }
    }

    // MARK: - Connection Test

    private func testConnection() async {
        isTestingConnection = true
        connectionError = nil

        defer { isTestingConnection = false }

        // Save credentials first
        do {
            // Save password to keychain (an empty field removes it)
            try KeychainHelper.saveWebDAVPassword(webdavPassword)

            // Update SyncCoordinator settings
            try await SyncCoordinator.shared.setWebDAVSettings(
                url: webdavURL,
                username: webdavUsername.isEmpty ? nil : webdavUsername
            )

            // Test connection
            guard let url = URL(string: webdavURL) else {
                connectionError = "Invalid URL format"
                return
            }

            let storage = WebDAVModuleStorage(
                baseURL: url,
                username: webdavUsername.isEmpty ? nil : webdavUsername,
                password: webdavPassword.isEmpty ? nil : webdavPassword
            )

            let available = await storage.isAvailable()

            if available {
                await MainActor.run {
                    step = .connected
                }
            } else {
                connectionError = "Could not connect to server. Check URL and credentials."
            }

        } catch {
            connectionError = error.localizedDescription
        }
    }
}

// MARK: - Read Aloud

/// Read-aloud preferences. Voice choice is stored per language, because the voice
/// that suits an English translation is no use for a Greek one — and when the
/// language has no installed voice at all, saying so here is the only way the user
/// finds out it's fixable.
private struct ReadAloudSettingsSection: View {
    let translationId: String

    @AppStorage("readAloudFollowsText") private var followsText: Bool = true
    @AppStorage(LampPronunciation.GreekReading.preferenceKey) private var greekReading = ""
    @State private var hasGreekVoice = WordSpeaker.hasGreekVoice
    @State private var languageCode: String?
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var selectedVoiceId: String = ""

    private var languageName: String? {
        SpeechVoiceCatalog.languageName(for: languageCode)
    }

    var body: some View {
        Section {
            Toggle(isOn: $followsText) {
                Label {
                    Text("Follow Along")
                } icon: {
                    LampIconTile(systemName: "waveform", color: .purple)
                }
            }
            .tint(.accentColor)

            if voices.isEmpty {
                Text(noVoiceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // "Automatic" names the voice it stands for, so a reader can
                // tell what they'd be choosing over.
                Picker("Voice", selection: Binding(
                    get: { selectedVoiceId },
                    set: { chosen in
                        selectedVoiceId = chosen
                        SpeechVoiceCatalog.setPreferredVoiceIdentifier(chosen.isEmpty ? nil : chosen, for: languageCode)
                    }
                )) {
                    Text(automaticVoice.map { "Automatic (\($0.name))" } ?? "Automatic")
                        .tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text(SpeechVoiceCatalog.displayName(for: voice))
                            .tag(voice.identifier)
                    }
                }
                if let voiceInUse, SpeechVoiceCatalog.isBasic(voiceInUse) {
                    // Siri's voices are the system's own; apps aren't given them,
                    // so downloading one wouldn't change what Lamp reads with.
                    Text("\(voiceInUse.name) is a basic voice, so words can sound slow and choppy. Enhanced and Premium voices are free in Settings › Accessibility › Spoken Content › Voices. Lamp can't use Siri's voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // How the speaker beside a Greek word says it. Shown as it will
            // be said: without a Greek voice, the classroom way, whatever was
            // chosen before.
            Picker("Greek Words", selection: Binding(
                get: { LampPronunciation.GreekReading.resolved(greekReading, hasGreekVoice: hasGreekVoice) },
                set: { greekReading = $0.rawValue }
            )) {
                ForEach(LampPronunciation.GreekReading.allCases, id: \.self) { reading in
                    Text(reading.title).tag(reading)
                }
            }
            .disabled(!hasGreekVoice)
            if !hasGreekVoice {
                Text("Modern Greek needs a Greek voice. Add one in Settings › Accessibility › Spoken Content › Voices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Read Aloud").lampSectionHeader()
        } footer: {
            Group {
            if let languageName, !voices.isEmpty {
                Text("Follow Along highlights each verse as it's spoken and keeps it on screen. The voice applies to \(languageName) translations. Greek Words is how the speaker beside a Greek word says it.")
            } else {
                Text("Follow Along highlights each verse as it's spoken and keeps it on screen. Greek Words is how the speaker beside a Greek word says it.")
            }
            }
            .foregroundStyle(LampTheme.caption)
        }
        .task(id: translationId) {
            load()
        }
    }

    private var automaticVoice: AVSpeechSynthesisVoice? {
        SpeechVoiceCatalog.automaticVoice(for: languageCode)
    }

    /// The voice reading aloud now: the one chosen, else the automatic one.
    private var voiceInUse: AVSpeechSynthesisVoice? {
        voices.first { $0.identifier == selectedVoiceId } ?? automaticVoice
    }

    private var noVoiceText: String {
        let howToFix = "Add one in Settings › Accessibility › Spoken Content › Voices."
        guard let languageName else {
            return "No speech voice is installed for this translation. \(howToFix)"
        }
        return "No \(languageName) voice is installed, so this translation can't be read aloud. \(howToFix)"
    }

    private func load() {
        hasGreekVoice = WordSpeaker.hasGreekVoice
        let language = (try? TranslationDatabase.shared.getTranslation(id: translationId))?.language
        languageCode = language
        voices = SpeechVoiceCatalog.voices(for: language)
        // The voice chosen, where it is still installed; otherwise Automatic.
        let chosen = SpeechVoiceCatalog.preferredVoiceIdentifier(for: language)
        selectedVoiceId = voices.contains { $0.identifier == chosen } ? chosen ?? "" : ""
    }
}

/// A settings row that leads somewhere: its tile, its name, and a line on
/// what is there, so a row's name never has to explain itself alone.
private struct SettingsRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        // A Label, as every other row's icon is, so all the tiles share
        // one column and one inset.
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(LampTheme.caption)
            }
            .padding(.vertical, 2)
        } icon: {
            LampIconTile(systemName: systemImage, color: color)
        }
    }
}

/// The top of Settings: the app, its version, and the library at a glance.
private struct SettingsIdentityCard: View {
    let moduleCount: Int?
    let syncSummary: String

    /// Compact: the app and the library in two lines, not a banner.
    var body: some View {
        HStack(spacing: 14) {
            AppIconImage()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lamp Bible")
                    .font(.headline)
                Text(moduleCount.map { "\($0) modules · \(syncSummary)" } ?? syncSummary)
                    .font(.footnote)
                    .foregroundStyle(LampTheme.caption)
                Text("Version \(SettingsView.appVersion)")
                    .font(.footnote)
                    .foregroundStyle(LampTheme.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The app's own icon, from the bundle; a tile if it can't be read.
private struct AppIconImage: View {
    private static let icon: UIImage? = {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last
        else { return nil }
        return UIImage(named: name)
    }()

    var body: some View {
        if let icon = Self.icon {
            Image(uiImage: icon)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 10.5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                        .strokeBorder(LampTheme.hairline)
                }
                .accessibilityHidden(true)
        } else {
            LampIconTile(systemName: "book.closed.fill", size: 46)
        }
    }
}

struct SettingsViewPreview: View {
    @State var previewUUID = UUID()

    var body: some View {
        SettingsView(
            externalApps: externalBibleApps,
            planViewRefreshId: $previewUUID
        )
    }
}

#Preview {
    SettingsViewPreview()
}

// MARK: - Section header

/// One header style for every grouped section, so no screen mixes large
/// black headings with small grey ones.
struct LampSectionHeaderStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(0.72))
            .textCase(nil)
    }
}

extension View {
    func lampSectionHeader() -> some View {
        modifier(LampSectionHeaderStyle())
    }
}

// MARK: - Icon tile

/// A white glyph on a filled rounded square, as Settings marks its rows.
struct LampIconTile: View {
    let systemName: String
    var color: Color = .accentColor
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}
