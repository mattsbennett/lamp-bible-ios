//
//  ModuleManagerView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import SwiftUI
import GRDB
import RealmSwift
import UniformTypeIdentifiers

// MARK: - Module Source

enum ModuleSource: String, CaseIterable {
    case all = "All"
    case bundled = "Bundled"
    case user = "User"
}

// MARK: - Commentary Series Group

struct CommentarySeriesGroup: Identifiable {
    let id: String  // seriesFull name
    let seriesFull: String
    let seriesAbbrev: String?
    let books: [CommentaryBook]

    var bookCount: Int { books.count }

    var displayName: String { seriesFull }

    var bookNames: String {
        books.prefix(3).compactMap { book in
            let realm = RealmManager.shared.realm
            return realm.objects(Book.self).filter("id == %@", book.bookNumber).first?.name
        }.joined(separator: ", ") + (books.count > 3 ? "..." : "")
    }
}

// MARK: - Display Module (unified wrapper for bundled and user modules)

struct DisplayModule: Identifiable {
    let id: String
    let name: String
    let type: ModuleType
    let source: ModuleSource
    let description: String?
    let version: String?
    let isEditable: Bool
    let entryCount: Int?

    // Reference to underlying user module (nil for bundled)
    let userModule: Module?

    /// Create from a user module
    init(from module: Module, entryCount: Int? = nil) {
        self.id = module.id
        self.name = module.name
        self.type = module.type
        self.source = .user
        self.description = module.description
        self.version = module.version
        self.isEditable = module.isEditable
        self.entryCount = entryCount
        self.userModule = module
    }

    /// Create a bundled module representation
    init(
        id: String,
        name: String,
        type: ModuleType,
        description: String?,
        version: String? = nil,
        entryCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.source = .bundled
        self.description = description
        self.version = version
        self.isEditable = false
        self.entryCount = entryCount
        self.userModule = nil
    }

    var isBundled: Bool {
        source == .bundled
    }

    var isDefaultNotesModule: Bool {
        id == "bible-notes"
    }
}

struct ModuleManagerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var modules: [DisplayModule] = []
    @State private var commentarySeriesGroups: [CommentarySeriesGroup] = []
    @State private var selectedType: ModuleType? = nil
    @State private var selectedSource: ModuleSource = .all
    @State private var isLoading: Bool = true
    @State private var isSyncing: Bool = false
    @State private var showingImportPicker: Bool = false
    @State private var alertMessage: String = ""
    @State private var showingAlert: Bool = false
    @State private var selectedCommentarySeries: CommentarySeriesGroup? = nil

    // Markdown import/export
    @State private var showingMarkdownImportPicker: Bool = false
    @State private var showingMarkdownExportPicker: Bool = false
    @State private var markdownExportData: String = ""
    @State private var markdownExportFilename: String = ""
    @State private var moduleForMarkdownExport: Module? = nil
    @State private var showingMarkdownImportModuleSelector: Bool = false
    @State private var pendingMarkdownContent: String = ""

    private let database = ModuleDatabase.shared
    private let syncManager = ModuleSyncManager.shared
    private let storage = ICloudModuleStorage.shared

    var filteredModules: [DisplayModule] {
        var result = modules

        // Filter by type
        if let type = selectedType {
            result = result.filter { $0.type == type }
        }

        // Filter by source
        switch selectedSource {
        case .bundled:
            result = result.filter { $0.isBundled }
        case .user:
            result = result.filter { !$0.isBundled }
        case .all:
            break
        }

        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Filter controls
                VStack(spacing: 8) {
                    // Type filter row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            FilterChip(title: "All", isSelected: selectedType == nil) {
                                selectedType = nil
                            }
                            ForEach(ModuleType.allCases, id: \.self) { type in
                                FilterChip(title: type.displayName, isSelected: selectedType == type) {
                                    selectedType = type
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Source filter row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ModuleSource.allCases, id: \.self) { source in
                                FilterChip(
                                    title: source.rawValue,
                                    isSelected: selectedSource == source,
                                    color: source == .bundled ? .purple : (source == .user ? .green : .accentColor)
                                ) {
                                    selectedSource = source
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)

                Divider()

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if filteredModules.isEmpty && filteredCommentarySeries.isEmpty {
                    emptyStateView
                } else {
                    modulesList
                }
            }
            .navigationTitle("Modules")
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "arrow.backward")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingImportPicker = true
                        } label: {
                            Label("Import Module (JSON)", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            showingMarkdownImportPicker = true
                        } label: {
                            Label("Import Markdown", systemImage: "doc.text")
                        }

                        Divider()

                        Button {
                            syncAllModules()
                        } label: {
                            Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .task {
                await loadModules()
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Module Manager", isPresented: $showingAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
            }
            // Markdown import picker
            .fileImporter(
                isPresented: $showingMarkdownImportPicker,
                allowedContentTypes: [.text, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleMarkdownImport(result)
            }
            // Markdown export picker
            .fileExporter(
                isPresented: $showingMarkdownExportPicker,
                document: MarkdownExportDocument(content: markdownExportData),
                contentType: .text,
                defaultFilename: markdownExportFilename
            ) { result in
                handleMarkdownExportResult(result)
            }
            // Module selector for markdown import (user modules only)
            .sheet(isPresented: $showingMarkdownImportModuleSelector) {
                MarkdownImportModuleSelectorView(
                    markdownContent: pendingMarkdownContent,
                    modules: modules
                        .filter { !$0.isBundled && ($0.type == .notes || $0.type == .devotional) }
                        .compactMap { $0.userModule },
                    onImport: { moduleId, moduleType in
                        Task {
                            await importMarkdownToModule(moduleId: moduleId, type: moduleType)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No modules installed")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Import modules from JSON files")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
                showingImportPicker = true
            } label: {
                Label("Import Module", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
        }
        Spacer()
    }

    /// Filtered commentary series based on current filters
    private var filteredCommentarySeries: [CommentarySeriesGroup] {
        // Only show when type is nil (all) or commentary
        guard selectedType == nil || selectedType == .commentary else {
            return []
        }
        // Only show when source is all or user (commentaries are user modules)
        guard selectedSource == .all || selectedSource == .user else {
            return []
        }
        return commentarySeriesGroups
    }

    @ViewBuilder
    private var modulesList: some View {
        List {
            // Commentary series groups (shown at top when applicable)
            if !filteredCommentarySeries.isEmpty {
                Section(header: Text("Commentary Series")) {
                    ForEach(filteredCommentarySeries) { series in
                        CommentarySeriesRow(series: series)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedCommentarySeries = series
                            }
                    }
                }
            }

            // Regular modules
            if !filteredModules.isEmpty {
                Section(header: filteredCommentarySeries.isEmpty ? nil : Text("Other Modules")) {
                    ForEach(filteredModules) { displayModule in
                        ModuleRow(
                            module: displayModule,
                            onMarkdownExport: displayModule.isBundled ? nil : {
                                if let userModule = displayModule.userModule {
                                    exportModuleToMarkdown(userModule)
                                }
                            },
                            onDelete: (displayModule.isBundled || displayModule.isDefaultNotesModule) ? nil : {
                                if let userModule = displayModule.userModule {
                                    Task { await deleteModule(userModule) }
                                }
                            },
                            onReset: displayModule.isDefaultNotesModule ? {
                                if let userModule = displayModule.userModule {
                                    Task { await resetModule(userModule) }
                                }
                            } : nil,
                            onSync: displayModule.isBundled ? nil : {
                                if let userModule = displayModule.userModule {
                                    Task { await syncModule(userModule) }
                                }
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await loadModules()
        }
        .sheet(item: $selectedCommentarySeries) { series in
            CommentarySeriesDetailView(series: series, onDelete: { book in
                Task { await deleteCommentaryBook(book) }
            })
        }
    }

    private func loadModules() async {
        isLoading = true

        var allModules: [DisplayModule] = []

        let realm = RealmManager.shared.realm

        // Load bundled translations
        let translations = realm.objects(Translation.self)
        for translation in translations {
            let verseCount = translation.verses.count
            allModules.append(DisplayModule(
                id: "translation-\(translation.id)",
                name: translation.name,
                type: .translation,
                description: translation.fullDescription.isEmpty ? nil : translation.fullDescription,
                version: translation.abbreviation,
                entryCount: verseCount
            ))
        }

        // Load bundled lexicon modules
        // Strong's Greek
        let greekCount = realm.objects(StrongsGreek.self).count
        if greekCount > 0 {
            allModules.append(DisplayModule(
                id: "strongs-greek",
                name: "Strong's Greek",
                type: .dictionary,
                description: "Strong's Concordance Greek definitions",
                entryCount: greekCount
            ))
        }

        // Strong's Hebrew
        let hebrewCount = realm.objects(StrongsHebrew.self).count
        if hebrewCount > 0 {
            allModules.append(DisplayModule(
                id: "strongs-hebrew",
                name: "Strong's Hebrew",
                type: .dictionary,
                description: "Strong's Concordance Hebrew definitions",
                entryCount: hebrewCount
            ))
        }

        // Dodson Greek
        let dodsonCount = realm.objects(DodsonGreek.self).count
        if dodsonCount > 0 {
            allModules.append(DisplayModule(
                id: "dodson",
                name: "Dodson Greek Lexicon",
                type: .dictionary,
                description: "Dodson's Greek New Testament Lexicon",
                entryCount: dodsonCount
            ))
        }

        // BDB Hebrew
        let bdbCount = realm.objects(BDBHebrew.self).count
        if bdbCount > 0 {
            allModules.append(DisplayModule(
                id: "bdb",
                name: "Brown-Driver-Briggs",
                type: .dictionary,
                description: "Brown-Driver-Briggs Hebrew Lexicon",
                entryCount: bdbCount
            ))
        }

        // Load user modules from GRDB (excluding commentary - those are grouped by series)
        do {
            let userModules = try database.getAllModules()
            for module in userModules {
                // Skip commentary modules - they're shown grouped by series
                if module.type != .commentary {
                    allModules.append(DisplayModule(from: module))
                }
            }
        } catch {
            print("Failed to load user modules: \(error)")
        }

        // Load commentary series groups
        do {
            let allBooks = try database.getAllCommentaryBooks()
            var seriesDict: [String: [CommentaryBook]] = [:]
            for book in allBooks {
                let seriesKey = book.seriesFull ?? "Unknown Series"
                seriesDict[seriesKey, default: []].append(book)
            }
            commentarySeriesGroups = seriesDict.map { key, books in
                CommentarySeriesGroup(
                    id: key,
                    seriesFull: key,
                    seriesAbbrev: books.first?.seriesAbbrev,
                    books: books.sorted { $0.bookNumber < $1.bookNumber }
                )
            }.sorted { $0.seriesFull < $1.seriesFull }
        } catch {
            print("Failed to load commentary series: \(error)")
            commentarySeriesGroups = []
        }

        modules = allModules
        isLoading = false
    }

    private func syncAllModules() {
        isSyncing = true
        Task {
            await syncManager.syncAll()
            await loadModules()
            isSyncing = false
        }
    }

    private func syncModule(_ module: Module) async {
        do {
            try await syncManager.syncModule(id: module.id)
            await loadModules()
        } catch {
            alertMessage = "Failed to sync: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func deleteCommentaryBook(_ book: CommentaryBook) async {
        do {
            // Delete the commentary book and its units from database
            try database.deleteCommentaryBook(moduleId: book.moduleId)
            // Also delete the module record
            try database.deleteModule(id: book.moduleId)
            // Delete from iCloud
            let fileName = "\(book.moduleId).json"
            try await storage.deleteModuleFile(type: .commentary, fileName: fileName)
            await loadModules()
            selectedCommentarySeries = nil
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func deleteModule(_ module: Module) async {
        do {
            // Delete from database
            try database.deleteAllEntriesForModule(moduleId: module.id)
            try database.deleteModule(id: module.id)

            // Delete from iCloud
            let fileName = "\(module.id).json"
            try await storage.deleteModuleFile(type: module.type, fileName: fileName)

            await loadModules()
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func resetModule(_ module: Module) async {
        do {
            // Delete all entries but keep the module
            try database.deleteAllEntriesForModule(moduleId: module.id)

            // Export the now-empty module to iCloud
            try await syncManager.exportModule(id: module.id)

            await loadModules()
            alertMessage = "Module reset successfully"
            showingAlert = true
        } catch {
            alertMessage = "Failed to reset: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                alertMessage = "Cannot access file"
                showingAlert = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)

                // Try to parse as a module file to detect type
                let decoder = JSONDecoder()

                // Try each module type
                if let dictModule = try? decoder.decode(DictionaryModuleFile.self, from: data) {
                    Task {
                        try await importDictionaryModule(dictModule, data: data)
                        await loadModules()
                        alertMessage = "Imported dictionary: \(dictModule.name)"
                        showingAlert = true
                    }
                } else if let commModule = try? decoder.decode(CommentaryModuleFile.self, from: data) {
                    Task {
                        try await importCommentaryModule(commModule, data: data)
                        await loadModules()
                        alertMessage = "Imported commentary: \(commModule.name)"
                        showingAlert = true
                    }
                } else if let devModule = try? decoder.decode(DevotionalModuleFile.self, from: data) {
                    Task {
                        try await importDevotionalModule(devModule, data: data)
                        await loadModules()
                        alertMessage = "Imported devotional: \(devModule.name)"
                        showingAlert = true
                    }
                } else if let noteModule = try? decoder.decode(NoteModuleFile.self, from: data) {
                    Task {
                        try await importNoteModule(noteModule, data: data)
                        await loadModules()
                        alertMessage = "Imported notes: \(noteModule.name)"
                        showingAlert = true
                    }
                } else {
                    alertMessage = "Unrecognized module format"
                    showingAlert = true
                }
            } catch {
                alertMessage = "Failed to read file: \(error.localizedDescription)"
                showingAlert = true
            }

        case .failure(let error):
            alertMessage = "Import failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func importDictionaryModule(_ file: DictionaryModuleFile, data: Data) async throws {
        let fileName = "\(file.id).json"
        try await storage.writeModuleFile(type: .dictionary, fileName: fileName, data: data)
        try await syncManager.syncModule(id: file.id)
    }

    private func importCommentaryModule(_ file: CommentaryModuleFile, data: Data) async throws {
        let fileName = "\(file.id).json"
        try await storage.writeModuleFile(type: .commentary, fileName: fileName, data: data)
        try await syncManager.syncModule(id: file.id)
    }

    private func importDevotionalModule(_ file: DevotionalModuleFile, data: Data) async throws {
        let fileName = "\(file.id).json"
        try await storage.writeModuleFile(type: .devotional, fileName: fileName, data: data)
        try await syncManager.syncModule(id: file.id)
    }

    private func importNoteModule(_ file: NoteModuleFile, data: Data) async throws {
        let fileName = "\(file.id).json"
        try await storage.writeModuleFile(type: .notes, fileName: fileName, data: data)
        try await syncManager.syncModule(id: file.id)
    }

    // MARK: - Markdown Import/Export

    private func handleMarkdownImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                alertMessage = "Cannot access file"
                showingAlert = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                pendingMarkdownContent = content
                showingMarkdownImportModuleSelector = true
            } catch {
                alertMessage = "Failed to read markdown file: \(error.localizedDescription)"
                showingAlert = true
            }

        case .failure(let error):
            alertMessage = "Import failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func importMarkdownToModule(moduleId: String, type: ModuleType) async {
        do {
            let count: Int
            switch type {
            case .notes:
                count = try MarkdownConverter.importNotesFromMarkdown(pendingMarkdownContent, moduleId: moduleId)
            case .devotional:
                count = try MarkdownConverter.importDevotionalsFromMarkdown(pendingMarkdownContent, moduleId: moduleId)
            default:
                alertMessage = "Markdown import not supported for this module type"
                showingAlert = true
                return
            }

            // Sync the module to iCloud
            try await syncManager.exportModule(id: moduleId)

            await loadModules()
            alertMessage = "Imported \(count) entries"
            showingAlert = true
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
            showingAlert = true
        }
        pendingMarkdownContent = ""
    }

    private func exportModuleToMarkdown(_ module: Module) {
        do {
            let markdown: String
            switch module.type {
            case .notes:
                markdown = try MarkdownConverter.exportNotesToMarkdown(moduleId: module.id)
            case .devotional:
                markdown = try MarkdownConverter.exportDevotionalsToMarkdown(moduleId: module.id)
            default:
                alertMessage = "Markdown export not supported for this module type"
                showingAlert = true
                return
            }

            markdownExportData = markdown
            markdownExportFilename = "\(module.name).md"
            moduleForMarkdownExport = module
            showingMarkdownExportPicker = true
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func handleMarkdownExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            alertMessage = "Markdown exported successfully"
            showingAlert = true
        case .failure(let error):
            alertMessage = "Export failed: \(error.localizedDescription)"
            showingAlert = true
        }
        moduleForMarkdownExport = nil
        markdownExportData = ""
    }
}

// MARK: - Supporting Views

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var color: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : Color.secondary.opacity(0.15))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ModuleRow: View {
    let module: DisplayModule
    var onMarkdownExport: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onReset: (() -> Void)? = nil
    var onSync: (() -> Void)? = nil

    @State private var showingDeleteConfirmation: Bool = false
    @State private var showingResetConfirmation: Bool = false

    private var supportsMarkdownExport: Bool {
        !module.isBundled && (module.type == .notes || module.type == .devotional)
    }

    private var hasActions: Bool {
        !module.isBundled
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(module.name)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Type badge
                    Text(module.type.displayName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    // Source badge
                    Text(module.isBundled ? "Bundled" : "User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(module.isBundled ? Color.purple : Color.green)
                        .clipShape(Capsule())

                    if module.isEditable {
                        Text("Editable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let version = module.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let count = module.entryCount {
                        Text("\(count) entries")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let description = module.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Only show menu for user modules
            if hasActions {
                Menu {
                    if onSync != nil {
                        Button {
                            onSync?()
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    if supportsMarkdownExport, onMarkdownExport != nil {
                        Divider()

                        Button {
                            onMarkdownExport?()
                        } label: {
                            Label("Export (Markdown)", systemImage: "square.and.arrow.up")
                        }
                    }

                    // Show Reset for default notes module, Delete for others
                    if module.isDefaultNotesModule {
                        if onReset != nil {
                            Divider()

                            Button(role: .destructive) {
                                showingResetConfirmation = true
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                        }
                    } else if onDelete != nil {
                        Divider()

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundColor(Color(uiColor: .label))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Delete Module",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(module.name)\"?\n\nThis will permanently delete the module and all its entries. This cannot be undone.")
        }
        .confirmationDialog(
            "Reset Module",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                onReset?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset \"\(module.name)\"?\n\nThis will delete all entries in this module. The module itself will be kept. This cannot be undone.")
        }
    }
}

// MARK: - Module Type Extension

extension ModuleType {
    var displayName: String {
        switch self {
        case .translation: return "Translation"
        case .dictionary: return "Dictionary"
        case .commentary: return "Commentary"
        case .devotional: return "Devotional"
        case .notes: return "Notes"
        }
    }
}

// MARK: - Markdown Export Document

struct MarkdownExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.text, .plainText] }

    let content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(data: data, encoding: .utf8) ?? ""
        } else {
            content = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Markdown Import Module Selector

struct MarkdownImportModuleSelectorView: View {
    let markdownContent: String
    let modules: [Module]
    var onImport: ((String, ModuleType) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedModuleId: String = ""
    @State private var createNewModule: Bool = false
    @State private var newModuleName: String = ""
    @State private var newModuleType: ModuleType = .notes

    private let database = ModuleDatabase.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Create new module", isOn: $createNewModule)
                }

                if createNewModule {
                    Section("New Module") {
                        TextField("Module Name", text: $newModuleName)

                        Picker("Type", selection: $newModuleType) {
                            Text("Notes").tag(ModuleType.notes)
                            Text("Devotional").tag(ModuleType.devotional)
                        }
                    }
                } else {
                    Section("Select Module") {
                        if modules.isEmpty {
                            Text("No compatible modules found")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(modules, id: \.id) { module in
                                Button {
                                    selectedModuleId = module.id
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(module.name)
                                                .foregroundColor(.primary)
                                            Text(module.type.displayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedModuleId == module.id {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Preview: \(markdownContent.prefix(200))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import Markdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .disabled(!canImport)
                }
            }
        }
    }

    private var canImport: Bool {
        if createNewModule {
            return !newModuleName.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            return !selectedModuleId.isEmpty
        }
    }

    private func performImport() {
        if createNewModule {
            // Create new module first
            let moduleId = UUID().uuidString
            let module = Module(
                id: moduleId,
                type: newModuleType,
                name: newModuleName.trimmingCharacters(in: .whitespaces),
                description: nil,
                filePath: "\(moduleId).json",
                isEditable: true
            )
            do {
                try database.saveModule(module)
                onImport?(module.id, newModuleType)
            } catch {
                print("Failed to create module: \(error)")
            }
        } else if let module = modules.first(where: { $0.id == selectedModuleId }) {
            onImport?(selectedModuleId, module.type)
        }
        dismiss()
    }
}

// MARK: - Commentary Series Row

struct CommentarySeriesRow: View {
    let series: CommentarySeriesGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.displayName)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Type badge
                    Text("Commentary")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    // Source badge
                    Text("User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .clipShape(Capsule())

                    Text("\(series.bookCount) books")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(series.bookNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Commentary Series Detail View

struct CommentarySeriesDetailView: View {
    let series: CommentarySeriesGroup
    var onDelete: ((CommentaryBook) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var bookToDelete: CommentaryBook? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(series.books, id: \.id) { book in
                    CommentaryBookRow(book: book) {
                        bookToDelete = book
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(series.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Delete Commentary Book",
                isPresented: Binding(
                    get: { bookToDelete != nil },
                    set: { if !$0 { bookToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let book = bookToDelete {
                        onDelete?(book)
                    }
                    bookToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    bookToDelete = nil
                }
            } message: {
                if let book = bookToDelete {
                    let bookName = RealmManager.shared.realm.objects(Book.self)
                        .filter("id == %@", book.bookNumber).first?.name ?? "Unknown"
                    Text("Delete \"\(bookName)\" from \(series.displayName)?\n\nThis will permanently delete this commentary book. This cannot be undone.")
                }
            }
        }
    }
}

// MARK: - Commentary Book Row

struct CommentaryBookRow: View {
    let book: CommentaryBook
    var onDelete: (() -> Void)?

    private var bookName: String {
        RealmManager.shared.realm.objects(Book.self)
            .filter("id == %@", book.bookNumber).first?.name ?? "Unknown"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(bookName)
                    .font(.headline)

                if let title = book.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let author = book.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let year = book.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if onDelete != nil {
                Menu {
                    Button(role: .destructive) {
                        onDelete?()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundColor(Color(uiColor: .label))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ModuleManagerView()
}
