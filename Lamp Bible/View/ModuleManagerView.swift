//
//  ModuleManagerView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import SwiftUI
import GRDB
import UniformTypeIdentifiers

// MARK: - Module Source

enum ModuleSource: String, CaseIterable {
    case all = "All"
    case bundled = "Bundled"
    case user = "User"
}

// MARK: - Commentary Series Group

struct CommentarySeriesGroup: Identifiable {
    let id: String  // series ID
    let series: CommentarySeries?  // Full series metadata (for bundled with new schema)
    let seriesFull: String         // Series name for legacy/fallback
    let seriesAbbrev: String?
    let books: [CommentaryBook]
    let isBundled: Bool

    var bookCount: Int { books.count }

    var displayName: String { series?.name ?? seriesFull }

    var abbreviation: String? { series?.abbreviation ?? seriesAbbrev }

    var publisher: String? { series?.publisher }

    var editor: String? { series?.editor }

    var bookNames: String {
        books.prefix(3).compactMap { book in
            return (try? BundledModuleDatabase.shared.getBook(id: book.bookNumber))?.name
        }.joined(separator: ", ") + (books.count > 3 ? "..." : "")
    }

    /// Initialize with full series metadata (new schema)
    init(id: String, series: CommentarySeries, books: [CommentaryBook], isBundled: Bool) {
        self.id = id
        self.series = series
        self.seriesFull = series.name
        self.seriesAbbrev = series.abbreviation
        self.books = books
        self.isBundled = isBundled
    }

    /// Initialize with legacy schema (series_full from books)
    init(id: String, seriesFull: String, seriesAbbrev: String?, books: [CommentaryBook], isBundled: Bool) {
        self.id = id
        self.series = nil
        self.seriesFull = seriesFull
        self.seriesAbbrev = seriesAbbrev
        self.books = books
        self.isBundled = isBundled
    }
}

// MARK: - Dictionary Series Group

struct DictionarySeriesGroup: Identifiable {
    let id: String  // series name (e.g., "Greek", "Hebrew")
    let seriesName: String
    let modules: [DisplayModule]

    var moduleCount: Int { modules.count }

    var displayName: String { seriesName }

    var moduleNames: String {
        modules.map { $0.name }.joined(separator: ", ")
    }
}

// MARK: - Highlight Set Display

struct HighlightSetDisplay: Identifiable {
    let id: String
    let set: HighlightSet
    let module: Module
    let translationName: String
    let highlightCount: Int
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
    let series: String?  // For grouping (e.g., "Greek", "Hebrew" for dictionaries)

    // Reference to underlying user module (nil for bundled)
    let userModule: Module?

    /// Create from a user module
    init(from module: Module, entryCount: Int? = nil, series: String? = nil) {
        self.id = module.id
        self.name = module.name
        self.type = module.type
        self.source = .user
        self.description = module.description
        self.version = module.version
        self.isEditable = module.isEditable
        self.entryCount = entryCount
        // Use provided series, or fall back to module's seriesFull field
        self.series = series ?? module.seriesFull
        self.userModule = module
    }

    /// Create a bundled module representation
    init(
        id: String,
        name: String,
        type: ModuleType,
        description: String?,
        version: String? = nil,
        entryCount: Int? = nil,
        series: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.source = .bundled
        self.description = description
        self.version = version
        self.isEditable = false
        self.entryCount = entryCount
        self.series = series
        self.userModule = nil
    }

    var isBundled: Bool {
        source == .bundled
    }

    var isDefaultNotesModule: Bool {
        id == "notes"
    }
}

struct ModuleManagerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var modules: [DisplayModule] = []
    @State private var commentarySeriesGroups: [CommentarySeriesGroup] = []
    @State private var dictionarySeriesGroups: [DictionarySeriesGroup] = []
    @State private var highlightSets: [HighlightSetDisplay] = []
    @State private var bundledPlans: [Plan] = []
    @State private var userPlans: [Plan] = []
    @State private var selectedType: ModuleType? = nil
    @State private var selectedSource: ModuleSource = .all
    @State private var isLoading: Bool = true
    @State private var isSyncing: Bool = false
    @State private var showingImportSheet: Bool = false
    @State private var alertMessage: String = ""
    @State private var showingAlert: Bool = false
    @State private var selectedCommentarySeries: CommentarySeriesGroup? = nil
    @State private var selectedDictionarySeries: DictionarySeriesGroup? = nil

    // Markdown export
    @State private var showingMarkdownExportPicker: Bool = false
    @State private var markdownExportData: String = ""
    @State private var markdownExportFilename: String = ""
    @State private var moduleForMarkdownExport: Module? = nil
    @State private var pendingMarkdownContent: String = ""

    // Create new module
    @State private var showingCreateModule: Bool = false

    // Edit module metadata
    @State private var moduleToEdit: Module? = nil

    private let database = ModuleDatabase.shared
    private let syncManager = ModuleSyncManager.shared
    private let storage = ICloudModuleStorage.shared

    var filteredModules: [DisplayModule] {
        var result = modules

        // Exclude dictionaries that are shown in series groups
        let dictionaryIdsInSeries = Set(dictionarySeriesGroups.flatMap { $0.modules.map { $0.id } })
        result = result.filter { !dictionaryIdsInSeries.contains($0.id) }

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
                } else if filteredModules.isEmpty && filteredCommentarySeries.isEmpty && filteredDictionarySeries.isEmpty && filteredHighlights.isEmpty {
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
                    Button {
                        syncAllModules()
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button {
                            showingCreateModule = true
                        } label: {
                            Label("Create New Module", systemImage: "plus.square")
                        }
                        Button {
                            showingImportSheet = true
                        } label: {
                            Label("Import Module", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task {
                await loadModules()
            }
            .alert("Module Manager", isPresented: $showingAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
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
            // Import module sheet
            .sheet(isPresented: $showingImportSheet) {
                ImportModuleSheet(
                    modules: modules
                        .filter { !$0.isBundled && ($0.type == .notes || $0.type == .devotional) }
                        .compactMap { $0.userModule },
                    onImportMarkdown: { moduleId, moduleType, content in
                        pendingMarkdownContent = content
                        Task {
                            await importMarkdownToModule(moduleId: moduleId, type: moduleType)
                        }
                    },
                    onImportComplete: {
                        Task {
                            await loadModules()
                        }
                    }
                )
            }
            // Create new module
            .sheet(isPresented: $showingCreateModule) {
                CreateModuleView(
                    onCreate: { newModule in
                        Task {
                            await createModule(newModule)
                        }
                    },
                    onCreateHighlightSet: { _ in
                        Task {
                            await loadModules()
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
            Text("Import modules from .lamp files or markdown")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button {
                showingImportSheet = true
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

        // Filter by source
        switch selectedSource {
        case .bundled:
            return commentarySeriesGroups.filter { $0.isBundled }
        case .user:
            return commentarySeriesGroups.filter { !$0.isBundled }
        case .all:
            return commentarySeriesGroups
        }
    }

    /// Filtered dictionary series based on current filters
    private var filteredDictionarySeries: [DictionarySeriesGroup] {
        // Only show when type is nil (all) or dictionary
        guard selectedType == nil || selectedType == .dictionary else {
            return []
        }

        // Filter series groups by source
        switch selectedSource {
        case .bundled:
            // Only include series that have bundled modules
            return dictionarySeriesGroups.compactMap { group in
                let bundledModules = group.modules.filter { $0.isBundled }
                guard !bundledModules.isEmpty else { return nil }
                return DictionarySeriesGroup(id: group.id, seriesName: group.seriesName, modules: bundledModules)
            }
        case .user:
            // Only include series that have user modules
            return dictionarySeriesGroups.compactMap { group in
                let userModules = group.modules.filter { !$0.isBundled }
                guard !userModules.isEmpty else { return nil }
                return DictionarySeriesGroup(id: group.id, seriesName: group.seriesName, modules: userModules)
            }
        case .all:
            return dictionarySeriesGroups
        }
    }

    // Filtered modules by type for organized display
    private var filteredDictionaries: [DisplayModule] {
        filteredModules.filter { $0.type == .dictionary }
    }

    private var filteredTranslations: [DisplayModule] {
        filteredModules.filter { $0.type == .translation }
    }

    private var filteredOtherModules: [DisplayModule] {
        filteredModules.filter { $0.type != .dictionary && $0.type != .translation && $0.type != .highlights }
    }

    private var filteredHighlights: [HighlightSetDisplay] {
        // Only show when type is nil (all) or highlights
        guard selectedType == nil || selectedType == .highlights else {
            return []
        }

        // Filter by source (highlights are always user-created)
        switch selectedSource {
        case .bundled:
            return []
        case .user, .all:
            return highlightSets
        }
    }

    private var filteredPlans: [(plan: Plan, isBundled: Bool)] {
        switch selectedSource {
        case .bundled:
            return bundledPlans.map { ($0, true) }
        case .user:
            return userPlans.map { ($0, false) }
        case .all:
            return bundledPlans.map { ($0, true) } + userPlans.map { ($0, false) }
        }
    }

    @ViewBuilder
    private var modulesList: some View {
        List {
            // Translations section
            if !filteredTranslations.isEmpty {
                Section(header: Text("Translations")) {
                    ForEach(Array(filteredTranslations.enumerated()), id: \.element.id) { index, displayModule in
                        moduleRow(for: displayModule)
                            .listRowSeparator(index == filteredTranslations.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }

            // Dictionaries section: series groups + individual dictionaries
            let hasDictionaries = !filteredDictionarySeries.isEmpty || !filteredDictionaries.isEmpty
            if hasDictionaries {
                let totalDictItems = filteredDictionarySeries.count + filteredDictionaries.count
                Section(header: Text("Dictionaries")) {
                    // Dictionary series groups first
                    ForEach(Array(filteredDictionarySeries.enumerated()), id: \.element.id) { index, series in
                        let isLast = filteredDictionaries.isEmpty && index == filteredDictionarySeries.count - 1
                        DictionarySeriesRow(series: series)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedDictionarySeries = series
                            }
                            .listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
                    }
                    // Individual dictionaries below
                    ForEach(Array(filteredDictionaries.enumerated()), id: \.element.id) { index, displayModule in
                        moduleRow(for: displayModule)
                            .listRowSeparator(index == filteredDictionaries.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }

            // Commentary series section
            if !filteredCommentarySeries.isEmpty {
                Section(header: Text("Commentaries")) {
                    ForEach(Array(filteredCommentarySeries.enumerated()), id: \.element.id) { index, series in
                        CommentarySeriesRow(series: series)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedCommentarySeries = series
                            }
                            .listRowSeparator(index == filteredCommentarySeries.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }

            // Highlights section
            if !filteredHighlights.isEmpty {
                Section(header: Text("Highlights")) {
                    ForEach(Array(filteredHighlights.enumerated()), id: \.element.id) { index, highlightSet in
                        HighlightSetModuleRow(
                            highlightSet: highlightSet,
                            onEdit: {
                                moduleToEdit = highlightSet.module
                            },
                            onDelete: {
                                Task { await deleteHighlightSet(highlightSet) }
                            }
                        )
                        .listRowSeparator(index == filteredHighlights.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }

            // Other modules (notes, devotionals, etc.)
            if !filteredOtherModules.isEmpty {
                Section(header: Text("Other")) {
                    ForEach(Array(filteredOtherModules.enumerated()), id: \.element.id) { index, displayModule in
                        moduleRow(for: displayModule)
                            .listRowSeparator(index == filteredOtherModules.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }

            // Reading Plans section
            if !filteredPlans.isEmpty && selectedType == nil {
                Section(header: Text("Reading Plans")) {
                    ForEach(Array(filteredPlans.enumerated()), id: \.element.plan.id) { index, item in
                        PlanRow(plan: item.plan, isBundled: item.isBundled, onDelete: item.isBundled ? nil : {
                            Task { await deletePlan(item.plan) }
                        })
                        .listRowSeparator(index == filteredPlans.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await loadModules()
        }
        .sheet(item: $selectedCommentarySeries) { series in
            CommentarySeriesDetailView(series: series, onDelete: series.isBundled ? nil : { book in
                Task { await deleteCommentaryBook(book) }
            })
        }
        .sheet(item: $selectedDictionarySeries) { series in
            DictionarySeriesDetailView(series: series, onDelete: { module in
                Task { await deleteDictionaryModule(module) }
            })
        }
        .sheet(item: $moduleToEdit) { module in
            ModuleEditSheet(module: module) { updatedModule in
                Task { await saveModuleMetadata(updatedModule) }
            }
        }
    }

    @ViewBuilder
    private func moduleRow(for displayModule: DisplayModule) -> some View {
        ModuleRow(
            module: displayModule,
            onEdit: (displayModule.isEditable && !displayModule.isBundled) ? {
                if let userModule = displayModule.userModule {
                    moduleToEdit = userModule
                }
            } : nil,
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

    private func loadModules() async {
        isLoading = true

        var allModules: [DisplayModule] = []

        // Load translations from GRDB (bundled + user-imported)
        if let translations = try? TranslationDatabase.shared.getAllTranslations() {
            for translation in translations {
                let verseCount = (try? TranslationDatabase.shared.getTotalVerseCount(translationId: translation.id)) ?? 0
                let isBundled = (try? TranslationDatabase.shared.isTranslationBundled(id: translation.id)) ?? true

                if isBundled {
                    allModules.append(DisplayModule(
                        id: "translation-\(translation.id)",
                        name: translation.name,
                        type: .translation,
                        description: translation.translationDescription?.isEmpty == false ? translation.translationDescription : nil,
                        version: translation.abbreviation,
                        entryCount: verseCount
                    ))
                } else {
                    // User-imported translation - create a Module to use the user DisplayModule initializer
                    let userModule = Module(
                        id: "translation-\(translation.id)",
                        type: .translation,
                        name: translation.name,
                        description: translation.translationDescription,
                        version: translation.abbreviation,
                        filePath: "\(translation.id).lamp",
                        isEditable: false
                    )
                    allModules.append(DisplayModule(from: userModule, entryCount: verseCount))
                }
            }
        }

        // Load bundled lexicon modules from GRDB BundledModuleDatabase
        // Strong's Greek and Hebrew are grouped as "Strong's Concordance" series
        // Dodson and BDB are individual modules (not part of a series)

        let bundledDb = BundledModuleDatabase.shared
        var strongsModules: [DisplayModule] = []

        // Strong's Greek - part of Strong's series
        let greekCount = (try? bundledDb.getDictionaryEntryCount(moduleId: "strongs_greek")) ?? 0
        if greekCount > 0 {
            strongsModules.append(DisplayModule(
                id: "strongs-greek",
                name: "Strong's Greek",
                type: .dictionary,
                description: "Strong's Concordance Greek definitions",
                entryCount: greekCount,
                series: "Strong's Concordance"
            ))
        }

        // Strong's Hebrew - part of Strong's series
        let hebrewCount = (try? bundledDb.getDictionaryEntryCount(moduleId: "strongs_hebrew")) ?? 0
        if hebrewCount > 0 {
            strongsModules.append(DisplayModule(
                id: "strongs-hebrew",
                name: "Strong's Hebrew",
                type: .dictionary,
                description: "Strong's Concordance Hebrew definitions",
                entryCount: hebrewCount,
                series: "Strong's Concordance"
            ))
        }

        // Create Strong's series group if we have modules
        if !strongsModules.isEmpty {
            dictionarySeriesGroups = [
                DictionarySeriesGroup(id: "strongs", seriesName: "Strong's Concordance", modules: strongsModules)
            ]
        } else {
            dictionarySeriesGroups = []
        }

        // Dodson Greek - individual module (not part of a series)
        let dodsonCount = (try? bundledDb.getDictionaryEntryCount(moduleId: "dodson_greek")) ?? 0
        if dodsonCount > 0 {
            allModules.append(DisplayModule(
                id: "dodson_greek",
                name: "Dodson Greek Lexicon",
                type: .dictionary,
                description: "Dodson's Greek New Testament Lexicon",
                entryCount: dodsonCount
            ))
        }

        // BDB Hebrew - individual module (not part of a series)
        let bdbCount = (try? bundledDb.getDictionaryEntryCount(moduleId: "bdb")) ?? 0
        if bdbCount > 0 {
            allModules.append(DisplayModule(
                id: "bdb",
                name: "Brown-Driver-Briggs",
                type: .dictionary,
                description: "Brown-Driver-Briggs Hebrew Lexicon",
                entryCount: bdbCount
            ))
        }

        // Load user modules from GRDB
        // Group user dictionaries with series, show others individually
        var userDictionariesBySeries: [String: [DisplayModule]] = [:]

        do {
            let userModules = try database.getAllModules()
            for module in userModules {
                // Skip commentary modules - they're shown grouped by series
                if module.type == .commentary {
                    continue
                }

                // Skip highlight modules - they're shown in their own section
                if module.type == .highlights {
                    continue
                }

                let displayModule = DisplayModule(from: module)

                // Group user dictionaries by series if they have one
                if module.type == .dictionary, let series = module.seriesFull {
                    userDictionariesBySeries[series, default: []].append(displayModule)
                } else {
                    // Add non-dictionary modules and dictionaries without series to main list
                    allModules.append(displayModule)
                }
            }
        } catch {
            print("Failed to load user modules: \(error)")
        }

        // Add user dictionary series groups
        let userDictGroups = userDictionariesBySeries.map { key, modules in
            DictionarySeriesGroup(id: "user-\(key)", seriesName: key, modules: modules)
        }.sorted { $0.seriesName < $1.seriesName }

        // Combine bundled Strong's group with user dictionary series groups
        dictionarySeriesGroups = dictionarySeriesGroups + userDictGroups

        // Load plans from bundled database
        bundledPlans = (try? bundledDb.getAllPlans()) ?? []

        // Load user plans from user database
        userPlans = (try? database.getAllPlans()) ?? []

        // Load commentary series groups (bundled + user)
        var allCommentaryGroups: [CommentarySeriesGroup] = []

        // Load bundled commentaries
        do {
            var booksInSeries = Set<String>()

            // Try new schema first: commentary_series table
            if bundledDb.hasCommentarySeriesTable() {
                let bundledSeries = try bundledDb.getAllBundledCommentarySeries()
                for series in bundledSeries {
                    let books = try bundledDb.getBundledCommentaryBooks(forSeriesId: series.id)
                    if !books.isEmpty {
                        for book in books {
                            booksInSeries.insert(book.id)
                        }
                        let group = CommentarySeriesGroup(
                            id: "bundled-\(series.id)",
                            series: series,
                            books: books.sorted { $0.bookNumber < $1.bookNumber },
                            isBundled: true
                        )
                        allCommentaryGroups.append(group)
                    }
                }
            }

            // Also check for books not assigned to any series (via series_full grouping)
            let allBundledBooks = try bundledDb.getAllBundledCommentaryBooks()
            var remainingSeriesDict: [String: [CommentaryBook]] = [:]
            for book in allBundledBooks where !booksInSeries.contains(book.id) {
                let seriesKey = book.seriesFull ?? "Unknown Series"
                remainingSeriesDict[seriesKey, default: []].append(book)
            }
            let remainingGroups = remainingSeriesDict.map { key, books in
                CommentarySeriesGroup(
                    id: "bundled-legacy-\(key)",
                    seriesFull: key,
                    seriesAbbrev: books.first?.seriesAbbrev,
                    books: books.sorted { $0.bookNumber < $1.bookNumber },
                    isBundled: true
                )
            }
            allCommentaryGroups.append(contentsOf: remainingGroups)
        } catch {
            print("Failed to load bundled commentary series: \(error)")
        }

        // Load user commentaries
        do {
            // First check for series in commentary_series table
            let userSeries = try database.getAllCommentarySeries()
            for series in userSeries {
                let books = try database.getCommentaryBooksForSeries(seriesId: series.id)
                if !books.isEmpty {
                    let group = CommentarySeriesGroup(
                        id: "user-\(series.id)",
                        series: series,
                        books: books.sorted { $0.bookNumber < $1.bookNumber },
                        isBundled: false
                    )
                    allCommentaryGroups.append(group)
                }
            }

            // Also load any legacy user commentaries that use series_full instead of series_id
            let allUserBooks = try database.getAllCommentaryBooks()
            let booksWithSeries = Set(userSeries.flatMap { series in
                (try? database.getCommentaryBooksForSeries(seriesId: series.id))?.map { $0.id } ?? []
            })

            // Group remaining books by series_full
            var legacySeriesDict: [String: [CommentaryBook]] = [:]
            for book in allUserBooks where !booksWithSeries.contains(book.id) {
                let seriesKey = book.seriesFull ?? "Unknown Series"
                legacySeriesDict[seriesKey, default: []].append(book)
            }

            let legacyGroups = legacySeriesDict.map { key, books in
                CommentarySeriesGroup(
                    id: "user-legacy-\(key)",
                    seriesFull: key,
                    seriesAbbrev: books.first?.seriesAbbrev,
                    books: books.sorted { $0.bookNumber < $1.bookNumber },
                    isBundled: false
                )
            }
            allCommentaryGroups.append(contentsOf: legacyGroups)
        } catch {
            print("Failed to load user commentary series: \(error)")
        }

        commentarySeriesGroups = allCommentaryGroups.sorted { $0.displayName < $1.displayName }

        // Load highlight sets with translation info
        var allHighlightSets: [HighlightSetDisplay] = []
        do {
            let sets = try database.getAllHighlightSets()
            for set in sets {
                // Get the module for this highlight set
                guard let module = try database.getModule(id: set.moduleId) else { continue }

                // Get translation name
                let translationName: String
                if let translation = try? TranslationDatabase.shared.getTranslation(id: set.translationId) {
                    translationName = translation.abbreviation
                } else {
                    translationName = set.translationId
                }

                // Get highlight count
                let count = (try? database.getHighlightCount(setId: set.id)) ?? 0

                allHighlightSets.append(HighlightSetDisplay(
                    id: set.id,
                    set: set,
                    module: module,
                    translationName: translationName,
                    highlightCount: count
                ))
            }
        } catch {
            print("Failed to load highlight sets: \(error)")
        }
        highlightSets = allHighlightSets.sorted { $0.set.name < $1.set.name }

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

    private func deleteDictionaryModule(_ displayModule: DisplayModule) async {
        guard let userModule = displayModule.userModule else { return }

        do {
            // Delete from database
            try database.deleteAllEntriesForModule(moduleId: userModule.id)
            try database.deleteModule(id: userModule.id)

            // Delete from iCloud - try both .json and .lamp extensions
            let jsonFileName = "\(userModule.id).json"
            let dbFileName = "\(userModule.id).lamp"
            try? await storage.deleteModuleFile(type: .dictionary, fileName: jsonFileName)
            try? await storage.deleteModuleFile(type: .dictionary, fileName: dbFileName)

            await loadModules()
            selectedDictionarySeries = nil
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

    private func saveModuleMetadata(_ module: Module) async {
        do {
            print("[ModuleManager] Saving module metadata: id=\(module.id), name=\(module.name), description=\(module.description ?? "nil")")

            // Save module metadata to database
            try database.saveModule(module)

            // If this is a highlights module, also update the highlight set name/description
            if module.type == .highlights {
                if let highlightSets = try? database.getHighlightSets(forModule: module.id) {
                    for var set in highlightSets {
                        set.name = module.name
                        set.description = module.description
                        try database.saveHighlightSet(set)
                    }
                }
            }

            // Verify save
            if let savedModule = try database.getModule(id: module.id) {
                print("[ModuleManager] Verified saved: name=\(savedModule.name), description=\(savedModule.description ?? "nil")")
            }

            // Export to sync the updated metadata to cloud
            try await syncManager.exportModule(id: module.id)

            await loadModules()
            print("[ModuleManager] Module metadata saved successfully")
        } catch {
            print("[ModuleManager] Failed to save module metadata: \(error)")
            alertMessage = "Failed to save: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func createModule(_ module: Module) async {
        do {
            // Save the module to database
            try database.saveModule(module)

            // Export to iCloud
            try await syncManager.exportModule(id: module.id)

            await loadModules()
            alertMessage = "Created module: \(module.name)"
            showingAlert = true
        } catch {
            alertMessage = "Failed to create module: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func deletePlan(_ plan: Plan) async {
        do {
            // Delete plan and its days from database
            try database.deletePlan(id: plan.id)

            // Delete from iCloud - try both extensions
            let dbFileName = "\(plan.id).lamp"
            try? await storage.deleteModuleFile(type: .plan, fileName: dbFileName)

            await loadModules()
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func deleteHighlightSet(_ highlightSet: HighlightSetDisplay) async {
        do {
            // Delete the module (cascade will delete set and highlights)
            try database.deleteModule(id: highlightSet.module.id)

            // Delete from iCloud
            let fileName = "\(highlightSet.module.id).lamp"
            try? await storage.deleteModuleFile(type: .highlights, fileName: fileName)

            await loadModules()
        } catch {
            alertMessage = "Failed to delete: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    // MARK: - Markdown Import/Export

    private func importMarkdownToModule(moduleId: String, type: ModuleType) async {
        do {
            let count: Int
            switch type {
            case .notes:
                count = try await MarkdownConverter.importNotesFromMarkdown(pendingMarkdownContent, moduleId: moduleId)
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
    var onEdit: (() -> Void)? = nil
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
                    if module.isEditable, onEdit != nil {
                        Button {
                            onEdit?()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }

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

// MARK: - Highlight Set Module Row

struct HighlightSetModuleRow: View {
    let highlightSet: HighlightSetDisplay
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var showingDeleteConfirmation: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(highlightSet.set.name)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Type badge
                    Text("Highlights")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    // Translation badge
                    Text(highlightSet.translationName)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
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

                    Text("\(highlightSet.highlightCount) highlights")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let description = highlightSet.set.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if onEdit != nil || onDelete != nil {
                Menu {
                    if let onEdit = onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }

                    if let onDelete = onDelete {
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
            "Delete Highlight Set",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(highlightSet.set.name)\"?\n\nThis will permanently delete all highlights in this set. This cannot be undone.")
        }
    }
}

// MARK: - Plan Row

struct PlanRow: View {
    let plan: Plan
    var isBundled: Bool = true
    var onDelete: (() -> Void)? = nil

    @State private var showingDeleteConfirmation: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Type badge
                    Text("Reading Plan")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    // Source badge
                    Text(isBundled ? "Bundled" : "User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isBundled ? Color.purple : Color.green)
                        .clipShape(Capsule())

                    if let duration = plan.duration {
                        Text("\(duration) days")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let description = plan.planDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Delete action for user plans
            if !isBundled, let onDelete = onDelete {
                Menu {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Delete Plan",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(plan.name)\"?\n\nThis will permanently delete this reading plan. This cannot be undone.")
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
        case .plan: return "Plan"
        case .highlights: return "Highlights"
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
                            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
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
                                .listRowSeparator(index == modules.count - 1 ? .hidden : .visible, edges: .bottom)
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
            // Create new module first with lowercase-hyphenated ID
            let trimmedName = newModuleName.trimmingCharacters(in: .whitespaces)
            let moduleId = trimmedName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)

            let module = Module(
                id: moduleId,
                type: newModuleType,
                name: trimmedName,
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
                HStack(spacing: 4) {
                    Text(series.displayName)
                        .font(.headline)
                    if let abbrev = series.abbreviation {
                        Text("(\(abbrev))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

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
                    Text(series.isBundled ? "Bundled" : "User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(series.isBundled ? Color.purple : Color.green)
                        .clipShape(Capsule())

                    Text("\(series.bookCount) books")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Publisher/editor info if available
                if let publisher = series.publisher {
                    Text(publisher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(series.bookNames)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                // Series metadata header section
                Section {
                    seriesHeaderView
                }

                // Books section
                Section(header: Text("Volumes (\(series.bookCount))")) {
                    ForEach(Array(series.books.enumerated()), id: \.element.id) { index, book in
                        CommentaryBookRow(book: book, onDelete: onDelete != nil ? {
                            bookToDelete = book
                        } : nil)
                        .listRowSeparator(index == series.books.count - 1 ? .hidden : .visible, edges: .bottom)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(series.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
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
                    let bookName = (try? BundledModuleDatabase.shared.getBook(id: book.bookNumber))?.name ?? "Unknown"
                    Text("Delete \"\(bookName)\" from \(series.displayName)?\n\nThis will permanently delete this commentary book. This cannot be undone.")
                }
            }
        }
    }

    @ViewBuilder
    private var seriesHeaderView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title and abbreviation
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let abbrev = series.abbreviation {
                    Text("(\(abbrev))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            // Badges row
            HStack(spacing: 8) {
                // Source badge
                Text(series.isBundled ? "Bundled" : "User")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(series.isBundled ? Color.purple : Color.green)
                    .clipShape(Capsule())

                // Testament badge
                if let testament = series.series?.testament {
                    let testamentLabel = testament == "OT" ? "Old Testament" :
                                         testament == "NT" ? "New Testament" : "Both Testaments"
                    Text(testamentLabel)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            // Description
            if let description = series.series?.seriesDescription, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Metadata grid
            VStack(alignment: .leading, spacing: 6) {
                if let publisher = series.publisher {
                    SeriesMetadataRow(label: "Publisher", value: publisher)
                }
                if let editor = series.editor {
                    SeriesMetadataRow(label: "Editor", value: editor)
                }
                if let language = series.series?.language {
                    SeriesMetadataRow(label: "Language", value: language.uppercased())
                }
                if let website = series.series?.website {
                    SeriesMetadataRow(label: "Website", value: website)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Series Metadata Row

struct SeriesMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Commentary Book Row

struct CommentaryBookRow: View {
    let book: CommentaryBook
    var onDelete: (() -> Void)?

    private var bookName: String {
        (try? BundledModuleDatabase.shared.getBook(id: book.bookNumber))?.name ?? "Unknown"
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

// MARK: - Dictionary Series Row

struct DictionarySeriesRow: View {
    let series: DictionarySeriesGroup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.displayName)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Type badge
                    Text("Dictionary")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    // Source badge - check if all bundled
                    let allBundled = series.modules.allSatisfy { $0.isBundled }
                    Text(allBundled ? "Bundled" : "User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(allBundled ? Color.purple : Color.green)
                        .clipShape(Capsule())

                    Text("\(series.moduleCount) modules")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Text(series.moduleNames)
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

// MARK: - Dictionary Series Detail View

struct DictionarySeriesDetailView: View {
    let series: DictionarySeriesGroup
    var onDelete: ((DisplayModule) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var moduleToDelete: DisplayModule? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(series.modules.enumerated()), id: \.element.id) { index, module in
                    DictionaryModuleRow(module: module) {
                        moduleToDelete = module
                    }
                    .listRowSeparator(index == series.modules.count - 1 ? .hidden : .visible, edges: .bottom)
                }
            }
            .listStyle(.plain)
            .navigationTitle(series.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .confirmationDialog(
                "Delete Dictionary",
                isPresented: Binding(
                    get: { moduleToDelete != nil },
                    set: { if !$0 { moduleToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let module = moduleToDelete {
                        onDelete?(module)
                    }
                    moduleToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    moduleToDelete = nil
                }
            } message: {
                if let module = moduleToDelete {
                    Text("Delete \"\(module.name)\"?\n\nThis will permanently delete this dictionary and all its entries. This cannot be undone.")
                }
            }
        }
    }
}

// MARK: - Dictionary Module Row (for series detail view)

struct DictionaryModuleRow: View {
    let module: DisplayModule
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(module.name)
                    .font(.headline)

                HStack(spacing: 6) {
                    // Source badge
                    Text(module.isBundled ? "Bundled" : "User")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(module.isBundled ? Color.purple : Color.green)
                        .clipShape(Capsule())

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

            // Show delete menu for non-bundled modules
            if !module.isBundled, onDelete != nil {
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

// MARK: - Create Module View

struct CreateModuleView: View {
    var onCreate: ((Module) -> Void)?
    var onCreateHighlightSet: ((HighlightSet) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var moduleName: String = ""
    @State private var moduleDescription: String = ""
    @State private var moduleType: ModuleType = .notes
    @State private var selectedTranslationId: String = ""
    @State private var translations: [TranslationModule] = []

    private var canCreate: Bool {
        let hasName = !moduleName.trimmingCharacters(in: .whitespaces).isEmpty
        if moduleType == .highlights {
            return hasName && !selectedTranslationId.isEmpty
        }
        return hasName
    }

    private var selectedTranslationAbbrev: String {
        translations.first { $0.id == selectedTranslationId }?.abbreviation.uppercased() ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Module Details") {
                    Picker("Type", selection: $moduleType) {
                        Text("Notes").tag(ModuleType.notes)
                        Text("Devotional").tag(ModuleType.devotional)
                        Text("Highlights").tag(ModuleType.highlights)
                    }

                    // Show translation picker for highlights
                    if moduleType == .highlights {
                        if translations.isEmpty {
                            Text("Loading translations...")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Translation", selection: $selectedTranslationId) {
                                Text("Select a translation").tag("")
                                ForEach(translations, id: \.id) { translation in
                                    Text("\(translation.abbreviation) - \(translation.name)")
                                        .tag(translation.id)
                                }
                            }
                        }
                    }

                    TextField("Name", text: $moduleName)

                    TextField("Description (optional)", text: $moduleDescription)
                }

                Section {
                    if moduleType == .highlights {
                        Text("Create a new highlight set for the selected translation. You can have multiple highlight sets per translation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if moduleType == .devotional {
                        Text("Create a new module to store your own devotional content. You can have multiple modules and switch between them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Create a new module to store your own verse-linked bible study notes. You can have multiple modules and switch between them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Create Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createModule()
                    }
                    .disabled(!canCreate)
                }
            }
            .task {
                await loadTranslations()
            }
            .onChange(of: moduleType) { _, newType in
                // Auto-fill name with default format for highlights
                if newType == .highlights && moduleName.isEmpty && !selectedTranslationId.isEmpty {
                    moduleName = "My \(selectedTranslationAbbrev) Highlights"
                }
            }
            .onChange(of: selectedTranslationId) { _, newValue in
                // Auto-fill name with default format when translation changes
                if moduleType == .highlights && moduleName.isEmpty && !newValue.isEmpty {
                    moduleName = "My \(selectedTranslationAbbrev) Highlights"
                }
            }
        }
    }

    private func loadTranslations() async {
        if let allTranslations = try? TranslationDatabase.shared.getAllTranslations() {
            translations = allTranslations.sorted { $0.abbreviation < $1.abbreviation }
        }
    }

    private func createModule() {
        let trimmedName = moduleName.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = moduleDescription.trimmingCharacters(in: .whitespaces)

        if moduleType == .highlights {
            // Use HighlightManager to create the highlight set
            HighlightManager.shared.currentTranslationId = selectedTranslationId

            do {
                let highlightSet = try HighlightManager.shared.createHighlightSet(
                    name: trimmedName,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription
                )
                onCreateHighlightSet?(highlightSet)
                dismiss()
            } catch {
                print("[CreateModuleView] Failed to create highlight set: \(error)")
            }
        } else {
            // Generate lowercase-hyphenated ID from name
            let baseId = trimmedName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)

            // Check if ID exists and increment if needed
            var moduleId = baseId
            var counter = 1
            while (try? ModuleDatabase.shared.getModule(id: moduleId)) != nil {
                counter += 1
                moduleId = "\(baseId)-\(counter)"
            }

            let module = Module(
                id: moduleId,
                type: moduleType,
                name: trimmedName,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                filePath: "\(moduleId).json",
                isEditable: true
            )

            onCreate?(module)
            dismiss()
        }
    }
}

// MARK: - Import Module Sheet

struct ImportModuleSheet: View {
    let modules: [Module]
    var onImportMarkdown: ((String, ModuleType, String) -> Void)?
    var onImportComplete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showingLampImporter: Bool = false
    @State private var showingMarkdownImporter: Bool = false
    @State private var importType: ModuleType = .notes
    @State private var selectedModuleId: String = ""
    @State private var showingModuleSelector: Bool = false
    @State private var pendingMarkdownContent: String = ""

    private var notesModules: [Module] {
        modules.filter { $0.type == .notes }
    }

    private var devotionalModules: [Module] {
        modules.filter { $0.type == .devotional }
    }

    var body: some View {
        NavigationStack {
            List {
                // .lamp module import
                Section {
                    Button {
                        showingLampImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.zipper")
                                .foregroundStyle(.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import .lamp Module")
                                    .foregroundStyle(.primary)
                                Text("Import a Lamp Bible module package")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Module Package")
                }

                // Markdown import
                Section {
                    Button {
                        importType = .notes
                        showingMarkdownImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "note.text")
                                .foregroundStyle(.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import Notes from Markdown")
                                    .foregroundStyle(.primary)
                                Text("Import verse-linked study notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        importType = .devotional
                        showingMarkdownImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Import Devotionals from Markdown")
                                    .foregroundStyle(.primary)
                                Text("Import devotional entries")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Markdown")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Supported formats:")
                            .font(.caption)
                            .fontWeight(.medium)

                        Text("• Single .md file with entries separated by ---")
                            .font(.caption)

                        Text("• Directory of .md files (one entry per file)")
                            .font(.caption)

                        Text("\nNotes should have verse references like [John 3:16]. Devotionals can include YAML frontmatter for metadata (title, date, tags).")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Import Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingLampImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleLampImport(result)
            }
            .fileImporter(
                isPresented: $showingMarkdownImporter,
                allowedContentTypes: [.text, .plainText, .folder],
                allowsMultipleSelection: false
            ) { result in
                handleMarkdownImport(result)
            }
            .sheet(isPresented: $showingModuleSelector) {
                MarkdownImportModuleSelectorView(
                    markdownContent: pendingMarkdownContent,
                    modules: importType == .notes ? notesModules : devotionalModules,
                    onImport: { moduleId, moduleType in
                        onImportMarkdown?(moduleId, moduleType, pendingMarkdownContent)
                        dismiss()
                    }
                )
            }
        }
    }

    private func handleLampImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            Task {
                do {
                    guard url.startAccessingSecurityScopedResource() else {
                        print("[ImportModuleSheet] Could not access security scoped resource")
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }

                    // Detect module type from the .lamp file
                    let moduleType = try detectModuleType(from: url)

                    // Import using ModuleSyncManager (handles both local db and cloud storage)
                    try await ModuleSyncManager.shared.importModuleFromFile(url: url, moduleType: moduleType)

                    onImportComplete?()
                    dismiss()
                } catch {
                    print("[ImportModuleSheet] Failed to import .lamp module: \(error)")
                }
            }

        case .failure(let error):
            print("[ImportModuleSheet] File picker error: \(error)")
        }
    }

    /// Detect module type by examining SQLite tables in the .lamp file
    private func detectModuleType(from url: URL) throws -> ModuleType {
        let data = try Data(contentsOf: url)

        // Decompress the data (zlib compressed)
        guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data else {
            throw NSError(domain: "ImportModuleSheet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress .lamp file"])
        }

        // Write to temp file to open as SQLite
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try decompressed.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Open as SQLite and check tables
        let db = try DatabaseQueue(path: tempURL.path)
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }

        // Determine type based on tables present
        if tables.contains("note_entries") {
            return .notes
        } else if tables.contains("devotional_entries") {
            return .devotional
        } else if tables.contains("highlight_sets") || tables.contains("highlights") {
            return .highlights
        } else if tables.contains("commentary_entries") || tables.contains("commentary_units") {
            return .commentary
        } else if tables.contains("dictionary_entries") {
            return .dictionary
        } else {
            throw NSError(domain: "ImportModuleSheet", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not determine module type"])
        }
    }

    private func handleMarkdownImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                print("[ImportModuleSheet] Could not access security scoped resource")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                let content: String
                if isDirectory.boolValue {
                    // Read all .md files in directory
                    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension.lowercased() == "md" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }

                    var combinedContent = ""
                    for file in files {
                        let fileContent = try String(contentsOf: file, encoding: .utf8)
                        if !combinedContent.isEmpty {
                            combinedContent += "\n\n---\n\n"
                        }
                        combinedContent += fileContent
                    }
                    content = combinedContent
                } else {
                    content = try String(contentsOf: url, encoding: .utf8)
                }

                pendingMarkdownContent = content

                // Show module selector
                let targetModules = importType == .notes ? notesModules : devotionalModules
                if targetModules.isEmpty {
                    // No modules exist, need to create one first
                    print("[ImportModuleSheet] No \(importType.rawValue) modules exist")
                } else {
                    showingModuleSelector = true
                }

            } catch {
                print("[ImportModuleSheet] Failed to read markdown: \(error)")
            }

        case .failure(let error):
            print("[ImportModuleSheet] File picker error: \(error)")
        }
    }
}

// MARK: - Module Edit Sheet

struct ModuleEditSheet: View {
    @Environment(\.dismiss) var dismiss
    let module: Module
    var onSave: ((Module) -> Void)?

    @State private var moduleName: String = ""
    @State private var moduleDescription: String = ""

    init(module: Module, onSave: ((Module) -> Void)? = nil) {
        self.module = module
        self.onSave = onSave
        _moduleName = State(initialValue: module.name)
        _moduleDescription = State(initialValue: module.description ?? "")
    }

    private var canSave: Bool {
        !moduleName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Module Details") {
                    TextField("Name", text: $moduleName)

                    TextField("Description (optional)", text: $moduleDescription)
                }

                Section {
                    HStack {
                        Text("Type")
                        Spacer()
                        Text(module.type.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("ID")
                        Spacer()
                        Text(module.id)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Edit Module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveModule()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func saveModule() {
        var updatedModule = module
        updatedModule.name = moduleName.trimmingCharacters(in: .whitespaces)
        updatedModule.description = moduleDescription.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : moduleDescription.trimmingCharacters(in: .whitespaces)
        updatedModule.updatedAt = Int(Date().timeIntervalSince1970)

        print("[ModuleEditSheet] Saving module: id=\(updatedModule.id), name=\(updatedModule.name), description=\(updatedModule.description ?? "nil")")
        onSave?(updatedModule)
        dismiss()
    }
}

#Preview {
    ModuleManagerView()
}
