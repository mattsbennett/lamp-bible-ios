//
//  SettingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-11-06.
//

import SwiftUI
import GRDB

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()
    @Binding var planViewRefreshID: UUID
    @State var planWpm: Double
    @State var notificationTime: Date = Date.now
    @State var showingNotificationAlert = false
    @State var showingDatabaseResetAlert = false
    @State var iCloudAvailable: Bool = false
    @State var moduleSyncInProgress: Bool = false
    @State var moduleCount: Int? = nil
    @State private var syncBackend: SyncBackend = .icloudDrive
    @State private var webdavURL: String = ""
    @State private var webdavUsername: String = ""
    @State private var webdavPassword: String = ""
    @State private var isTestingConnection: Bool = false
    @State private var connectionTestResult: ConnectionTestResult? = nil
    @State private var previousBackend: SyncBackend = .icloudDrive
    @State private var showingMigrationDialog: Bool = false
    @State private var pendingBackendChange: SyncBackend? = nil
    @State private var isMigrating: Bool = false
    @State private var migrationResult: MigrationResult? = nil
    @State private var showingWebDAVSetup: Bool = false
    @State private var showingWebDAVConfig: Bool = false
    @State private var hasLoadedSettings: Bool = false
    @ObservedObject private var syncCoordinator = SyncCoordinator.shared

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
                if !webdavPassword.isEmpty {
                    try SyncCoordinator.shared.saveWebDAVPassword(webdavPassword)
                }
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

                // MARK: - Tool Settings
                Section {
                    NavigationLink {
                        ModuleSettingsView(userSettings: $userSettings)
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    NavigationLink {
                        ModuleManagerView()
                    } label: {
                        Label("Manager", systemImage: "shippingbox")
                    }
                } header: {
                    VStack(alignment: .leading) {
                        Text("Modules").padding(.bottom, 8).padding(.top, 15)
                    }
                }
                .headerProminence(.increased)

                // MARK: - Sync Settings
                Section {
                    Picker("Sync Method", selection: $syncBackend) {
                        ForEach(SyncBackend.allCases, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .onChange(of: syncBackend) { oldValue, newValue in
                        // Ignore initial load and changes while handling a pending switch
                        guard hasLoadedSettings, pendingBackendChange == nil else { return }

                        // Check if we're switching between actual storage backends
                        if oldValue != .none && newValue != .none && oldValue != newValue {
                            pendingBackendChange = newValue
                            syncBackend = oldValue // Revert until user decides

                            if newValue == .webdav {
                                // Switching TO WebDAV - need to configure first
                                showingWebDAVSetup = true
                            } else {
                                // Switching FROM WebDAV to something else - show migration dialog
                                showingMigrationDialog = true
                            }
                        } else if pendingBackendChange == nil {
                            // Just switch (e.g., to/from "none")
                            Task {
                                try? await SyncCoordinator.shared.setBackend(newValue)
                                iCloudAvailable = await SyncCoordinator.shared.isAvailable
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
                            Text("Status")
                            Spacer()
                            Text("Local Only").foregroundStyle(.secondary)
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                        }
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
                                await ModuleSyncManager.shared.syncAll()
                                let modules = (try? ModuleDatabase.shared.getAllModules().count) ?? 0
                                let translations = (try? TranslationDatabase.shared.getAllTranslations().count) ?? 0
                                moduleCount = modules + translations
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
                    }
                } header: {
                    Text("Sync")
                } footer: {
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
                        Text("Data stays on this device only. Not synced to cloud.")
                    }
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
                        Text("Notes Panel")
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
                        Text("In-app Bible")
                    }.tint(.accentColor)
                } header: {
                    VStack(alignment: .leading) {
                        Text("Reading Plan Settings").padding(.bottom, 8).padding(.top, 15)
                    }
                } footer: {
                    Text("Show the ") + Text(Image(systemName: "book.fill")) + Text(" button to open readings in the in-app Bible")
                }
                .headerProminence(.increased)

                Section {
                    ForEach(externalApps) { app in
                        HStack {
                            Button {
                                try? UserDatabase.shared.updateSettings { $0.planExternalBible = app.name }
                                userSettings = UserDatabase.shared.getSettings()
                                generator.notificationOccurred(.success)
                            } label: {
                                Text(app.name).tint(.primary)
                            }
                            .disabled(!app.scheme.isEmpty ? !UIApplication.shared.canOpenURL(URL(string: app.scheme)!) : false)
                            Spacer()
                            if (userSettings.planExternalBible == app.name || (userSettings.planExternalBible == nil && app.name == "None")) {
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
                            try? UserDatabase.shared.updateSettings { $0.planWpm = planWpm }
                            userSettings = UserDatabase.shared.getSettings()
                            planViewRefreshID = UUID()
                        }
                    }
                    Text("Presets (Adult Avg)").font(.system(size: 12)).textCase(.uppercase).foregroundStyle(Color.secondary).padding(.bottom, -10)
                    Button("Aloud") {
                        let aloudSetting = 183.0
                        planWpm = aloudSetting
                        try? UserDatabase.shared.updateSettings { $0.planWpm = aloudSetting }
                        userSettings = UserDatabase.shared.getSettings()
                        planViewRefreshID = UUID()
                        generator.notificationOccurred(.success)
                    }
                    Button("Silent") {
                        let silentSetting = 238.0
                        planWpm = silentSetting
                        try? UserDatabase.shared.updateSettings { $0.planWpm = silentSetting }
                        userSettings = UserDatabase.shared.getSettings()
                        planViewRefreshID = UUID()
                        generator.notificationOccurred(.success)
                    }
                } header: {
                    Text("Reading Rate (WPM)")
                } footer: {
                    Text("Adjust reading rate to achieve personalized accuracy in reading plan reading time estimates")
                }
                .listRowSeparator(.hidden)

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
                        Text("Remind me daily")
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
                    Text("Daily Plan Reminder")
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
                    Text("Debug")
                } footer: {
                    Text("Temporarily renders the reader text with minimal formatting and no interactions to help diagnose scroll performance. Restart the app after changing.")
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
                Button("Switch Only") {
                    Task {
                        if let newBackend = pendingBackendChange {
                            try? await SyncCoordinator.shared.setBackend(newBackend)
                            syncBackend = newBackend
                            previousBackend = newBackend
                            iCloudAvailable = await SyncCoordinator.shared.isAvailable
                        }
                        pendingBackendChange = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingBackendChange = nil
                }
            } message: {
                if let newBackend = pendingBackendChange {
                    Text("Copy your modules from \(syncBackend.displayName) to \(newBackend.displayName)?\n\n")
                    + Text("Warning: Any existing files on \(newBackend.displayName) will be removed before migration.")
                        .foregroundColor(.orange)
                } else {
                    Text("Would you like to migrate your data to the new storage?\n\n")
                    + Text("Warning: Existing files on the destination will be removed.")
                        .foregroundColor(.orange)
                }
            }
            // Migration progress sheet
            .sheet(isPresented: $isMigrating) {
                MigrationProgressView(
                    progress: syncCoordinator.migrationProgress,
                    result: migrationResult,
                    onDismiss: {
                        isMigrating = false
                        migrationResult = nil
                        SyncCoordinator.shared.clearMigrationProgress()
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
                            try? await SyncCoordinator.shared.setBackend(.webdav)
                            syncBackend = .webdav
                            iCloudAvailable = await SyncCoordinator.shared.isAvailable
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
        }
    }

    private func performMigration() async {
        guard let newBackend = pendingBackendChange else { return }

        isMigrating = true
        migrationResult = nil

        do {
            // Perform migration (syncBackend holds the old value since it was reverted)
            let result = try await SyncCoordinator.shared.migrateStorage(
                from: syncBackend,
                to: newBackend
            )
            migrationResult = result

            // Switch to new backend after migration
            try await SyncCoordinator.shared.setBackend(newBackend)
            syncBackend = newBackend
            iCloudAvailable = await SyncCoordinator.shared.isAvailable

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
                        Text("Migration Complete")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("\(result.successCount) file(s) copied successfully")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.orange)
                        Text("Migration Completed with Errors")
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
                    Text("Preparing migration...")
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
            // Save password to keychain
            if !webdavPassword.isEmpty {
                try KeychainHelper.saveWebDAVPassword(webdavPassword)
            }

            // Update SyncCoordinator settings
            try await SyncCoordinator.shared.setWebDAVSettings(
                url: webdavURL,
                username: webdavUsername.isEmpty ? nil : webdavUsername
            )

            // Reconfigure storage
            await SyncCoordinator.shared.configureStorage()

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
                            Text("Copy all modules from \(sourceBackend.displayName)")
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
                    onSwitchOnly()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Switch Only")
                            Text("Start fresh on WebDAV")
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
                    Text("Warning: 'Migrate & Switch' will remove any existing files on WebDAV before copying.")
                        .foregroundStyle(.orange)
                    Text("Your files on \(sourceBackend.displayName) will not be removed.")
                }
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
            // Save password to keychain
            if !webdavPassword.isEmpty {
                try KeychainHelper.saveWebDAVPassword(webdavPassword)
            }

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
