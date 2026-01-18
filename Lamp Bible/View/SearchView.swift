//
//  SearchView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import SwiftUI
import GRDB

enum SearchScope: String, CaseIterable {
    case bible = "Bible"
    case modules = "Modules"

    var icon: String {
        switch self {
        case .bible: return "book.closed"
        case .modules: return "folder"
        }
    }
}

enum SearchContextAmount: Int, CaseIterable {
    case oneVerse = 1
    case threeVerses = 3
    case chapter = 0

    var label: String {
        switch self {
        case .oneVerse: return "1 Verse"
        case .threeVerses: return "3 Verses"
        case .chapter: return "Chapter"
        }
    }
}

enum SearchMode: String, CaseIterable, Codable {
    case text = "Text"
    case strongs = "Strong's"

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .strongs: return "number"
        }
    }

    var placeholder: String {
        switch self {
        case .text: return "Search verses..."
        case .strongs: return "H430, G2316, TH8804..."
        }
    }
}

struct SearchHistoryEntry: Codable, Equatable {
    let query: String
    let mode: SearchMode
    let translationId: String?  // GRDB translation ID

    // For display - get translation abbreviation
    var translationAbbreviation: String? {
        guard let id = translationId,
              let translation = try? TranslationDatabase.shared.getTranslation(id: id) else {
            return nil
        }
        return translation.abbreviation
    }
}

/// Manages search state to persist across navigation
class SearchStateManager: ObservableObject {
    static let shared = SearchStateManager()

    // Bible search state
    @Published var bibleSearchText: String = ""
    @Published var bibleSearchResults: [SearchResult] = []
    @Published var bibleResultLimit: Int = 100
    @Published var bibleTotalResultCount: Int = 0
    @Published var bibleResultsVisible: Bool = false
    var bibleScrollToId: Int? = nil  // Not @Published - only read on appear

    // Module search state
    @Published var moduleSearchText: String = ""
    @Published var moduleSearchResults: [ModuleSearchResult] = []
    @Published var moduleResultLimit: Int = 100
    @Published var moduleTotalResultCount: Int = 0
    @Published var moduleResultsVisible: Bool = false
    var moduleScrollToId: String? = nil  // Not @Published - only read on appear

    // Shared state
    @Published var isSearching: Bool = false

    func clearBibleResults() {
        bibleSearchResults = []
        bibleTotalResultCount = 0
        bibleResultsVisible = false
        bibleScrollToId = nil
    }

    func clearModuleResults() {
        moduleSearchResults = []
        moduleTotalResultCount = 0
        moduleResultsVisible = false
        moduleScrollToId = nil
    }
}

struct ModuleSearchHistoryEntry: Codable, Equatable {
    let query: String
    let types: Set<ModuleType>
    let moduleIds: Set<String>?
    let searchByKey: Bool
    let tags: Set<String>

    var filterSummary: String {
        var parts: [String] = []
        if types.count < ModuleType.allCases.count {
            parts.append(types.map { $0.rawValue }.sorted().joined(separator: ", "))
        }
        if let ids = moduleIds, !ids.isEmpty {
            parts.append("\(ids.count) modules")
        }
        if searchByKey {
            parts.append("by key")
        }
        if !tags.isEmpty {
            parts.append("\(tags.count) tags")
        }
        return parts.isEmpty ? "" : "[\(parts.joined(separator: "; "))]"
    }
}

struct SearchView: View {
    // Optional bindings for sheet presentation mode
    var isPresentedBinding: Binding<Bool>?
    var requestScrollToVerseIdBinding: Binding<Int?>?
    var requestScrollAnimatedBinding: Binding<Bool>?

    // GRDB translation ID - if set, will use GRDB for searches
    var providedTranslationId: String?

    var initialSearchText: String = ""
    var initialSearchMode: SearchMode? = nil  // If set, overrides persisted mode on appear
    var initialSearchScope: SearchScope? = nil  // If set, overrides persisted scope on appear
    var fontSize: Int = 18

    @Environment(\.dismiss) private var dismiss

    // Computed translation ID for GRDB
    private var translationId: String {
        if let provided = providedTranslationId {
            return provided
        }
        // Use selected translation if set (GRDB String ID)
        if let selectedId = selectedTranslationIdString {
            return selectedId
        }
        // Fetch from user's readerTranslationId or use default
        return UserDatabase.shared.getSettings().readerTranslationId
    }

    // GRDB translation module for display purposes
    private var translationModule: TranslationModule? {
        try? TranslationDatabase.shared.getTranslation(id: translationId)
    }

    // Translation abbreviation for display
    private var translationAbbreviation: String {
        translationModule?.abbreviation ?? translationId
    }

    // Convenience initializer for sheet presentation (GRDB version)
    init(
        isPresented: Binding<Bool>,
        translationId: String,
        requestScrollToVerseId: Binding<Int?>,
        requestScrollAnimated: Binding<Bool>,
        initialSearchText: String = "",
        initialSearchMode: SearchMode? = nil,
        initialSearchScope: SearchScope? = nil,
        fontSize: Int = 18
    ) {
        self.isPresentedBinding = isPresented
        self.providedTranslationId = translationId
        self.requestScrollToVerseIdBinding = requestScrollToVerseId
        self.requestScrollAnimatedBinding = requestScrollAnimated
        self.initialSearchText = initialSearchText
        self.initialSearchMode = initialSearchMode
        self.initialSearchScope = initialSearchScope
        self.fontSize = fontSize
    }

    // Convenience initializer for navigation destination (standalone)
    init(initialSearchText: String = "", initialSearchMode: SearchMode? = nil, initialSearchScope: SearchScope? = nil, fontSize: Int = 18) {
        self.isPresentedBinding = nil
        self.providedTranslationId = nil
        self.requestScrollToVerseIdBinding = nil
        self.requestScrollAnimatedBinding = nil
        self.initialSearchText = initialSearchText
        self.initialSearchMode = initialSearchMode
        self.initialSearchScope = initialSearchScope
        self.fontSize = fontSize
    }

    // Shared state manager for persistence across navigation
    @ObservedObject private var stateManager = SearchStateManager.shared

    @State private var searchTask: Task<Void, Never>?
    @State private var selectedTranslationIdString: String? = nil  // For standalone mode translation selection (GRDB String ID)
    @State private var navigateToVerseId: Int? = nil  // For standalone mode navigation to reader
    @State private var readerDate: Date = Date.now  // Date binding for reader
    @AppStorage("searchContextAmount") private var contextAmount: SearchContextAmount = .oneVerse
    @AppStorage("searchHistory") private var searchHistoryData: Data = Data()
    @AppStorage("moduleSearchHistory") private var moduleSearchHistoryData: Data = Data()
    @AppStorage("searchMode") private var searchMode: SearchMode = .text
    @AppStorage("searchScope") private var searchScope: SearchScope = .bible
    @State private var userSettings = UserDatabase.shared.getSettings()

    private var hiddenTranslations: String {
        userSettings.hiddenTranslations
    }

    // Convenience accessors for current scope's state
    private var bibleSearchText: String {
        get { stateManager.bibleSearchText }
        nonmutating set { stateManager.bibleSearchText = newValue }
    }
    private var moduleSearchText: String {
        get { stateManager.moduleSearchText }
        nonmutating set { stateManager.moduleSearchText = newValue }
    }
    private var searchResults: [SearchResult] {
        get { stateManager.bibleSearchResults }
        nonmutating set { stateManager.bibleSearchResults = newValue }
    }
    private var moduleSearchResults: [ModuleSearchResult] {
        get { stateManager.moduleSearchResults }
        nonmutating set { stateManager.moduleSearchResults = newValue }
    }
    private var isSearching: Bool {
        get { stateManager.isSearching }
        nonmutating set { stateManager.isSearching = newValue }
    }
    private var resultLimit: Int {
        get { searchScope == .modules ? stateManager.moduleResultLimit : stateManager.bibleResultLimit }
        nonmutating set {
            if searchScope == .modules {
                stateManager.moduleResultLimit = newValue
            } else {
                stateManager.bibleResultLimit = newValue
            }
        }
    }
    private var totalResultCount: Int {
        get { searchScope == .modules ? stateManager.moduleTotalResultCount : stateManager.bibleTotalResultCount }
        nonmutating set {
            if searchScope == .modules {
                stateManager.moduleTotalResultCount = newValue
            } else {
                stateManager.bibleTotalResultCount = newValue
            }
        }
    }
    private var resultsVisible: Bool {
        get { searchScope == .modules ? stateManager.moduleResultsVisible : stateManager.bibleResultsVisible }
        nonmutating set {
            if searchScope == .modules {
                stateManager.moduleResultsVisible = newValue
            } else {
                stateManager.bibleResultsVisible = newValue
            }
        }
    }

    // Whether we're in standalone mode (can select translation)
    private var isStandaloneMode: Bool {
        providedTranslationId == nil
    }

    // Computed binding for current scope's search text
    private var searchText: Binding<String> {
        Binding(
            get: { searchScope == .modules ? moduleSearchText : bibleSearchText },
            set: { newValue in
                if searchScope == .modules {
                    moduleSearchText = newValue
                } else {
                    bibleSearchText = newValue
                }
            }
        )
    }

    private var currentSearchText: String {
        searchScope == .modules ? moduleSearchText : bibleSearchText
    }

    // All available translations for picker (excluding hidden)
    private var availableTranslations: [TranslationModule] {
        visibleTranslations(hiddenString: hiddenTranslations).sorted { $0.name < $1.name }
    }

    // Module search
    private let moduleSearch = ModuleSearch.shared

    // Bible search filters
    @State private var showBibleFilters: Bool = true  // Show by default for Bible

    // Module search filters
    @State private var showModuleFilters: Bool = false
    @State private var filterTypes: Set<ModuleType> = Set(ModuleType.allCases)
    @State private var filterModuleIds: Set<String>? = nil
    @State private var searchByKey: Bool = false  // Toggle for key vs text search
    @State private var filterTags: Set<String> = []
    @State private var availableModules: [SearchableModule] = []
    @State private var availableTags: [String] = []

    // Module result sheets
    @State private var selectedLexiconEntry: ModuleSearchResult? = nil
    @State private var selectedDevotional: ModuleSearchResult? = nil
    @State private var selectedNote: ModuleSearchResult? = nil
    @State private var selectedCommentary: ModuleSearchResult? = nil

    private let maxHistorySize = 20

    private var moduleSearchPlaceholder: String {
        if searchScope == .modules {
            if searchByKey && filterTypes.contains(.dictionary) {
                return "H430, G2316, BDB871..."
            }
            return "Search modules..."
        }
        return searchMode.placeholder
    }

    /// Check if the current translation has Strong's annotations
    private var translationHasStrongsAnnotations: Bool {
        // Check if translation has Strong's annotations via GRDB
        // For now, assume translations with Strong's annotations are flagged
        // This could be optimized with a metadata field on the translation
        guard let translation = try? TranslationDatabase.shared.getTranslation(id: translationId) else {
            return false
        }
        // Check features JSON for strongs support
        return translation.featuresJson?.contains("strongs") ?? false
    }

    /// Count of active Bible search filters
    private var bibleFilterCount: Int {
        searchMode == .strongs ? 1 : 0
    }

    /// Count of active module search filters
    private var moduleFilterCount: Int {
        var count = 0
        if filterTypes.count < ModuleType.allCases.count { count += 1 }
        if filterModuleIds != nil { count += 1 }
        if searchByKey { count += 1 }
        if !filterTags.isEmpty { count += 1 }
        return count
    }

    /// Current active filter count based on scope
    private var activeFilterCount: Int {
        searchScope == .modules ? moduleFilterCount : bibleFilterCount
    }

    private var searchHistory: [SearchHistoryEntry] {
        get {
            // Try new format first
            if let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: searchHistoryData) {
                return entries
            }
            // Fall back to old format (migrate strings to text mode)
            if let oldStrings = try? JSONDecoder().decode([String].self, from: searchHistoryData) {
                return oldStrings.map { SearchHistoryEntry(query: $0, mode: .text, translationId: nil) }
            }
            return []
        }
    }

    private var moduleSearchHistory: [ModuleSearchHistoryEntry] {
        get {
            if let entries = try? JSONDecoder().decode([ModuleSearchHistoryEntry].self, from: moduleSearchHistoryData) {
                return entries
            }
            return []
        }
    }

    private func saveToBibleHistory(_ query: String) {
        var history = searchHistory
        let entry = SearchHistoryEntry(query: query, mode: searchMode, translationId: translationId)
        // Remove if already exists with same query and translation (to move to top)
        history.removeAll { $0.query.lowercased() == query.lowercased() && $0.translationId == translationId }
        // Add to beginning
        history.insert(entry, at: 0)
        // Trim to max size
        if history.count > maxHistorySize {
            history = Array(history.prefix(maxHistorySize))
        }
        // Save
        if let data = try? JSONEncoder().encode(history) {
            searchHistoryData = data
        }
    }

    private func saveToModuleHistory(_ query: String) {
        var history = moduleSearchHistory
        let entry = ModuleSearchHistoryEntry(
            query: query,
            types: filterTypes,
            moduleIds: filterModuleIds,
            searchByKey: searchByKey,
            tags: filterTags
        )
        // Remove if already exists with same query and filters (to move to top)
        history.removeAll { $0 == entry }
        // Add to beginning
        history.insert(entry, at: 0)
        // Trim to max size
        if history.count > maxHistorySize {
            history = Array(history.prefix(maxHistorySize))
        }
        // Save
        if let data = try? JSONEncoder().encode(history) {
            moduleSearchHistoryData = data
        }
    }

    private func clearHistory() {
        if searchScope == .modules {
            moduleSearchHistoryData = Data()
        } else {
            searchHistoryData = Data()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(moduleSearchPlaceholder, text: searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(searchScope == .bible && searchMode == .strongs ? .asciiCapable : .default)
                        .submitLabel(.search)
                        .onSubmit {
                            submitSearch()
                        }

                    if !currentSearchText.isEmpty {
                        Button {
                            searchText.wrappedValue = ""
                            // Clear results using stateManager
                            if searchScope == .bible {
                                stateManager.clearBibleResults()
                            } else {
                                stateManager.clearModuleResults()
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)

                // Bible filters (only show if translation has Strong's annotations)
                if searchScope == .bible && translationHasStrongsAnnotations && showBibleFilters {
                    bibleFilterSection
                }

                // Module search filters
                if searchScope == .modules && showModuleFilters {
                    moduleFilterSection
                }

                Divider()

                // Content
                Group {
                    if currentSearchText.isEmpty {
                        emptySearchState
                    } else if isSearching {
                        loadingState
                    } else if !resultsVisible {
                        // Prompt to submit search
                        readyToSearchState
                    } else if searchScope == .modules {
                        if moduleSearchResults.isEmpty {
                            moduleNoResultsState
                        } else {
                            moduleResultsList
                        }
                    } else if searchResults.isEmpty {
                        noResultsState
                    } else {
                        resultsList
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isPresentedBinding == nil)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismissView()
                    } label: {
                        // Show X for sheet, back arrow for navigation
                        Image(systemName: isPresentedBinding != nil ? "xmark" : "arrow.backward")
                    }
                }
                ToolbarItem(placement: .principal) {
                    // Scope menu in toolbar
                    Menu {
                        // Scope selection
                        ForEach(SearchScope.allCases, id: \.self) { scope in
                            Button {
                                searchScope = scope
                            } label: {
                                if scope == searchScope {
                                    Label(scope.rawValue, systemImage: "checkmark")
                                } else {
                                    Label(scope.rawValue, systemImage: scope.icon)
                                }
                            }
                        }

                        // Translation selection (only in standalone mode for Bible scope)
                        if isStandaloneMode && searchScope == .bible {
                            Divider()
                            Menu {
                                ForEach(availableTranslations, id: \.id) { trans in
                                    Button {
                                        selectedTranslationIdString = trans.id
                                        // Clear results when changing translation
                                        searchResults = []
                                        resultsVisible = false
                                    } label: {
                                        if trans.id == translationId {
                                            Label(trans.name, systemImage: "checkmark")
                                        } else {
                                            Text(trans.name)
                                        }
                                    }
                                }
                            } label: {
                                Label("Translation: \(translationAbbreviation)", systemImage: "book.closed")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: searchScope.icon)
                            Text(searchScope == .bible ? translationAbbreviation : searchScope.rawValue)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.headline)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        // Filter button with badge
                        if searchScope == .modules || (searchScope == .bible && translationHasStrongsAnnotations) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if searchScope == .modules {
                                        showModuleFilters.toggle()
                                    } else {
                                        showBibleFilters.toggle()
                                    }
                                }
                            } label: {
                                let isShowing = searchScope == .modules ? showModuleFilters : showBibleFilters
                                HStack(spacing: 0) {
                                    Image(systemName: isShowing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                    if activeFilterCount > 0 {
                                        Text("\(activeFilterCount)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(minWidth: 14, minHeight: 14)
                                            .background(Color.accentColor)
                                            .clipShape(Circle())
                                            .offset(x: -6, y: -8)
                                    }
                                }
                            }
                        }

                        Menu {
                            // Context amount setting (only for Bible scope)
                            if searchScope == .bible {
                                Menu {
                                    Picker("Context", selection: $contextAmount) {
                                        ForEach(SearchContextAmount.allCases, id: \.self) { amount in
                                            Text(amount.label).tag(amount)
                                        }
                                    }
                                } label: {
                                    Label("Preview Context", systemImage: "rectangle.expand.vertical")
                                }

                                Divider()
                            }

                            // Search history (scope-aware)
                            if searchScope == .bible {
                                if !searchHistory.isEmpty {
                                    Menu {
                                        ForEach(Array(searchHistory.enumerated()), id: \.offset) { _, entry in
                                            Button {
                                                searchMode = entry.mode
                                                // Restore translation if in standalone mode
                                                if isStandaloneMode, let translationId = entry.translationId {
                                                    selectedTranslationIdString = translationId
                                                }
                                                bibleSearchText = entry.query
                                                DispatchQueue.main.async {
                                                    submitSearch()
                                                }
                                            } label: {
                                                HStack {
                                                    Label(entry.query, systemImage: entry.mode.icon)
                                                    if let abbr = entry.translationAbbreviation {
                                                        Text(abbr)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            clearHistory()
                                        } label: {
                                            Label("Clear History", systemImage: "trash")
                                        }
                                    } label: {
                                        Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                                    }
                                } else {
                                    Label("No Recent Searches", systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                // Module search history with filters
                                if !moduleSearchHistory.isEmpty {
                                    Menu {
                                        ForEach(Array(moduleSearchHistory.enumerated()), id: \.offset) { _, entry in
                                            Button {
                                                // Restore filters
                                                filterTypes = entry.types
                                                filterModuleIds = entry.moduleIds
                                                searchByKey = entry.searchByKey
                                                filterTags = entry.tags
                                                moduleSearchText = entry.query
                                                DispatchQueue.main.async {
                                                    submitSearch()
                                                }
                                            } label: {
                                                VStack(alignment: .leading) {
                                                    Text(entry.query)
                                                    if !entry.filterSummary.isEmpty {
                                                        Text(entry.filterSummary)
                                                            .font(.caption2)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                        }

                                        Divider()

                                        Button(role: .destructive) {
                                            clearHistory()
                                        } label: {
                                            Label("Clear History", systemImage: "trash")
                                        }
                                    } label: {
                                        Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                                    }
                                } else {
                                    Label("No Recent Searches", systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .onChange(of: bibleSearchText) {
                guard searchScope == .bible else { return }
                resultsVisible = false
                autoDetectSearchMode()
            }
            .onChange(of: moduleSearchText) {
                guard searchScope == .modules else { return }
                resultsVisible = false
            }
            .onChange(of: searchMode) {
                // Clear results and auto-submit when switching modes with text
                searchResults = []
                totalResultCount = 0
                if !currentSearchText.isEmpty {
                    submitSearch()
                } else {
                    resultsVisible = false
                }
            }
            .onChange(of: searchScope) {
                // Clear results when switching scope - don't auto-search, let user see their previous text
                searchResults = []
                moduleSearchResults = []
                totalResultCount = 0
                resultsVisible = false
            }
            .onAppear {
                // Reload settings in case they changed
                userSettings = UserDatabase.shared.getSettings()

                // Load available modules and tags for filters
                availableModules = moduleSearch.getSearchableModules()
                availableTags = moduleSearch.getAllDevotionalTags()

                // Override scope if specified (e.g., from lexicon Strong's search)
                if let scope = initialSearchScope {
                    searchScope = scope
                }

                // Use initial search text if provided - submit immediately
                if !initialSearchText.isEmpty {
                    searchText.wrappedValue = initialSearchText
                    // Use provided mode if specified, otherwise auto-detect
                    if let mode = initialSearchMode {
                        searchMode = mode
                    } else {
                        autoDetectSearchMode()
                    }
                    // Auto-detect key search for module scope (Strong's/BDB IDs)
                    if searchScope == .modules {
                        autoDetectInitialKeySearch()
                    }
                    // Use async to ensure submitSearch runs after state updates
                    DispatchQueue.main.async {
                        submitSearch()
                    }
                }
                // Otherwise, previous results are already preserved in stateManager
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .navigationDestination(item: $navigateToVerseId) { verseId in
                // Navigate to reader with the selected verse and translation
                SplitReaderView(
                    date: $readerDate,
                    initialVerseId: verseId,
                    initialTranslationId: translationId
                )
            }
        }
    }

    // MARK: - Bible Filter Section

    private var bibleFilterSection: some View {
        HStack(spacing: 8) {
            Button {
                searchMode = searchMode == .strongs ? .text : .strongs
                // Search is triggered by onChange(of: searchMode)
            } label: {
                HStack {
                    Image(systemName: "number")
                        .font(.caption)
                    Text("By Key")
                        .font(.caption)
                }
                .foregroundColor(searchMode == .strongs ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(searchMode == .strongs ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Module Filter Section

    private var moduleFilterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Module type chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ModuleType.allCases, id: \.self) { type in
                        FilterChip(
                            title: type.displayName,
                            isSelected: filterTypes.contains(type),
                            color: typeColor(for: type)
                        ) {
                            if filterTypes.contains(type) {
                                filterTypes.remove(type)
                            } else {
                                filterTypes.insert(type)
                            }
                            if !currentSearchText.isEmpty {
                                DispatchQueue.main.async { submitSearch() }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            // Module filter and Strong's toggle on same row
            HStack(spacing: 8) {
                if !availableModules.isEmpty {
                    ModuleFilterPicker(
                        availableModules: modulesForSelectedTypes,
                        selectedModuleIds: $filterModuleIds,
                        onChanged: {
                            if !currentSearchText.isEmpty {
                                DispatchQueue.main.async { submitSearch() }
                            }
                        }
                    )
                }

                if filterTypes.contains(.dictionary) {
                    Button {
                        searchByKey.toggle()
                        if !currentSearchText.isEmpty {
                            DispatchQueue.main.async { submitSearch() }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "number")
                                .font(.caption)
                            Text("By Key")
                                .font(.caption)
                        }
                        .foregroundStyle(searchByKey ? .white : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(searchByKey ? Color.accentColor : Color(UIColor.tertiarySystemFill))
                        .clipShape(Capsule())
                    }
                }

                Spacer()
            }
            .padding(.horizontal)

            // Devotional-specific: Tags filter
            if filterTypes.contains(.devotional) && !availableTags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(availableTags, id: \.self) { tag in
                                FilterChip(
                                    title: tag,
                                    isSelected: filterTags.contains(tag),
                                    color: .orange
                                ) {
                                    if filterTags.contains(tag) {
                                        filterTags.remove(tag)
                                    } else {
                                        filterTags.insert(tag)
                                    }
                                    if !currentSearchText.isEmpty {
                                        DispatchQueue.main.async { submitSearch() }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var modulesForSelectedTypes: [SearchableModule] {
        availableModules.filter { filterTypes.contains($0.type) }
    }

    private func typeColor(for type: ModuleType) -> Color {
        switch type {
        case .translation: return .gray
        case .notes: return .blue
        case .commentary: return .green
        case .devotional: return .orange
        case .dictionary: return .purple
        case .plan: return .teal
        }
    }

    // MARK: - View States

    private var emptySearchState: some View {
        ContentUnavailableView(
            searchScope == .modules ? "Search Modules" : (searchMode == .strongs ? "Strong's Search" : "Search the Bible"),
            systemImage: searchScope == .modules ? "folder.badge.questionmark" : (searchMode == .strongs ? "number" : "magnifyingglass"),
            description: Text(searchScope == .modules
                ? "Search notes, commentaries, devotionals, and dictionaries"
                : (searchMode == .strongs
                    ? "Enter a Strong's number (H430, G2316, TH8804)"
                    : "Enter at least 2 characters to search"))
        )
    }

    private var moduleNoResultsState: some View {
        ContentUnavailableView(
            "No Module Results",
            systemImage: "folder.badge.questionmark",
            description: Text("No modules found matching \"\(currentSearchText)\"")
        )
    }

    private var moduleResultsList: some View {
        List {
            Section {
                ForEach(moduleSearchResults) { result in
                    let isLast = result.id == moduleSearchResults.last?.id
                    ModuleSearchResultRow(
                        result: result,
                        searchQuery: currentSearchText,
                        fontSize: fontSize,
                        onNavigate: {
                            handleModuleResultTap(result)
                        }
                    )
                    .id(result.id)
                    .listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
                }
            } header: {
                // Negative count means "X+" (more results available)
                if totalResultCount < 0 {
                    Text("\(-totalResultCount)+ results")
                } else {
                    Text("\(totalResultCount) results")
                }
            }

            // Load more button if there are more results (negative totalResultCount means more available)
            if totalResultCount < 0 {
                Button {
                    loadMoreResults()
                } label: {
                    Text("Load More Results")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .modifier(ConditionalGlassButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listStyle(.plain)
        .sheet(item: $selectedLexiconEntry) { result in
            if let strongsKey = result.strongsKey {
                LexiconSheetView(
                    word: result.title.components(separatedBy: " (").first ?? result.title,
                    strongs: [strongsKey],
                    morphology: nil,
                    translationId: translationId,
                    restrictToLexicon: lexiconKeyForModuleId(result.moduleId),
                    searchQuery: currentSearchText
                )
            }
        }
        .sheet(item: $selectedDevotional) { result in
            DevotionalEntrySheet(moduleId: result.moduleId, entryId: result.id, searchQuery: currentSearchText)
        }
        .sheet(item: $selectedNote) { result in
            NoteEntrySheet(moduleId: result.moduleId, entryId: result.id, verseId: result.verseId, searchQuery: currentSearchText)
        }
        .sheet(item: $selectedCommentary) { result in
            CommentaryEntrySheet(moduleId: result.moduleId, entryId: result.id, verseId: result.verseId, searchQuery: currentSearchText, translationId: translationId)
        }
    }

    private func handleModuleResultTap(_ result: ModuleSearchResult) {
        switch result.moduleType {
        case .translation:
            break  // Translations are not searched via module search
        case .dictionary:
            selectedLexiconEntry = result
        case .devotional:
            selectedDevotional = result
        case .notes:
            selectedNote = result
        case .commentary:
            selectedCommentary = result
        case .plan:
            break  // Plans are not searched via module search
        }
    }

    /// Convert module ID to lexicon key for LexiconSheetView
    private func lexiconKeyForModuleId(_ moduleId: String) -> String {
        switch moduleId {
        case "strongs-greek", "strongs-hebrew":
            return "strongs"
        case "dodson":
            return "dodson"
        case "bdb":
            return "bdb"
        default:
            // User dictionary modules
            return "user-\(moduleId)"
        }
    }

    private var loadingState: some View {
        VStack {
            ProgressView()
                .padding()
            Text("Searching...")
                .foregroundStyle(.secondary)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "doc.text.magnifyingglass",
            description: Text(noResultsDescription)
        )
    }

    private var noResultsDescription: String {
        if searchMode == .strongs {
            if translationHasStrongsAnnotations {
                return "No verses found with Strong's number \"\(currentSearchText.uppercased())\"."
            } else {
                return "\(translationAbbreviation) does not include Strong's annotations. Switch to a Strong's-annotated translation to search by Strong's numbers."
            }
        } else {
            return "No verses found matching \"\(currentSearchText)\"."
        }
    }

    private var readyToSearchState: some View {
        ContentUnavailableView(
            "Search Modules",
            systemImage: "magnifyingglass",
            description: Text("Search for \"\(currentSearchText)\"")
        )
    }

    private var resultsList: some View {
        BibleResultsListView(
            searchResults: searchResults,
            currentSearchText: currentSearchText,
            searchMode: searchMode,
            fontSize: fontSize,
            contextAmount: contextAmount,
            translationId: translationId,
            totalResultCount: totalResultCount,
            resultLimit: resultLimit,
            stateManager: stateManager,
            onNavigate: navigateToVerse,
            onLoadMore: loadMoreResults
        )
    }

    // MARK: - Search Logic

    /// Submit search - shows results and saves to history
    private func submitSearch() {
        searchTask?.cancel()
        resultsVisible = true

        searchTask = Task {
            await performSearchAsync()

            // Save to Bible history if we found results (module history is saved in performModuleSearch)
            if searchScope == .bible {
                let query = bibleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !searchResults.isEmpty && query.count >= 2 {
                    saveToBibleHistory(query)
                }
            }
        }
        // Note: Search state is automatically preserved in stateManager
    }

    /// Async search dispatcher
    private func performSearchAsync(showLoadingState: Bool = true) async {
        // Handle module search separately
        if searchScope == .modules {
            await performModuleSearchAsync(showLoadingState: showLoadingState)
            return
        }

        await performBibleSearchAsync(showLoadingState: showLoadingState)
    }

    /// Performs Bible search on main thread (Realm requires main thread)
    @MainActor
    private func performBibleSearchAsync(showLoadingState: Bool = true) async {
        let query = bibleSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Different validation for different modes
        if searchMode == .strongs {
            guard isValidStrongsQuery(query) else {
                searchResults = []
                totalResultCount = 0
                return
            }
        } else {
            guard query.count >= 2 else {
                searchResults = []
                totalResultCount = 0
                return
            }
        }

        if showLoadingState {
            isSearching = true
            // Clear saved scroll position so re-submitting doesn't restore
            stateManager.bibleScrollToId = nil
        }

        // Yield to allow UI updates before heavy work
        await Task.yield()

        if searchMode == .strongs {
            // Strong's search using annotations_json LIKE query
            let strongsQuery = query.uppercased()
            let results = (try? TranslationDatabase.shared.searchVersesByStrongs(
                translationId: translationId,
                strongsNum: strongsQuery,
                bookRange: nil,
                limit: 10000  // High limit to get total count
            )) ?? []
            totalResultCount = results.count

            let limited = Array(results.prefix(resultLimit))
            searchResults = limited.compactMap { result -> SearchResult? in
                let bookName = (try? BundledModuleDatabase.shared.getBook(id: result.book))?.name ?? "Book \(result.book)"
                return SearchResult(searchResult: result, bookName: bookName)
            }
        } else {
            // Text search using GRDB FTS5
            let cleanQuery = getRealmSearchString(from: query)
            let results = (try? TranslationDatabase.shared.searchAllTranslations(
                query: cleanQuery,
                translationIds: [translationId],
                bookRange: nil,
                limit: 10000  // High limit to get total count
            )) ?? []
            totalResultCount = results.count

            let limited = Array(results.prefix(resultLimit))
            searchResults = limited.compactMap { result -> SearchResult? in
                let bookName = (try? BundledModuleDatabase.shared.getBook(id: result.book))?.name ?? "Book \(result.book)"
                return SearchResult(searchResult: result, bookName: bookName)
            }
        }

        if showLoadingState {
            isSearching = false
        }
    }

    /// Performs search across user modules (includes Realm for bundled dictionaries, must run on main thread)
    @MainActor
    private func performModuleSearchAsync(showLoadingState: Bool = true) async {
        let query = moduleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build filter
        var filter = ModuleSearchFilter()
        filter.types = filterTypes
        filter.moduleIds = filterModuleIds

        // Search by key mode - use query as Strong's key
        if searchByKey && filterTypes.contains(.dictionary) {
            let key = query.uppercased()
            if !key.isEmpty {
                filter.strongsKey = key
            }
        }

        // Tags filter
        if !filterTags.isEmpty {
            filter.tags = filterTags
        }

        // Validation
        let hasQuery = query.count >= 2
        let hasKeyFilter = filter.strongsKey != nil

        guard hasQuery || hasKeyFilter else {
            moduleSearchResults = []
            totalResultCount = 0
            return
        }

        if showLoadingState {
            isSearching = true
        }

        // Yield to allow UI updates before heavy work
        await Task.yield()

        do {
            // Request one extra to detect if there are more results
            let results = try moduleSearch.search(query: searchByKey ? "" : query, filter: filter, limit: resultLimit + 1)
            let hasMoreResults = results.count > resultLimit
            let limitedResults = hasMoreResults ? Array(results.prefix(resultLimit)) : results

            // Use negative count to signal "more available" (e.g., -100 means "100+")
            totalResultCount = hasMoreResults ? -resultLimit : results.count
            moduleSearchResults = limitedResults

            // Save to module history if we have results
            let hasValidQuery = query.count >= 2 || filter.strongsKey != nil
            if !results.isEmpty && hasValidQuery {
                saveToModuleHistory(query)
            }
        } catch {
            print("Module search failed: \(error)")
            moduleSearchResults = []
            totalResultCount = 0
        }

        if showLoadingState {
            isSearching = false
        }
    }

    // MARK: - Strong's Search Helpers

    /// Auto-detect if user is typing a Strong's number and switch mode if appropriate (Bible scope only)
    private func autoDetectSearchMode() {
        let query = bibleSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let looksLikeStrongsNumber = isValidStrongsQuery(query)

        if looksLikeStrongsNumber && translationHasStrongsAnnotations && searchMode != .strongs {
            searchMode = .strongs
        } else if !looksLikeStrongsNumber && searchMode == .strongs && !query.isEmpty {
            // Only switch back to text if it clearly doesn't look like a Strong's number
            // and isn't a partial Strong's entry (like "H" or "H1")
            let looksLikePartialStrongs = query.range(of: "^(H|G|TH)\\d*$", options: .regularExpression) != nil
            if !looksLikePartialStrongs {
                searchMode = .text
            }
        }
    }

    /// Auto-detect key search mode for initial search text (called only on appear)
    private func autoDetectInitialKeySearch() {
        let query = moduleSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let looksLikeStrongsNumber = isValidStrongsQuery(query)
        let looksLikeBDBId = isValidBDBQuery(query)

        if (looksLikeStrongsNumber || looksLikeBDBId) && filterTypes.contains(.dictionary) {
            searchByKey = true
        }
    }

    /// Validates that the query looks like a Strong's number (H, G, or TH prefix followed by digits)
    private func isValidStrongsQuery(_ query: String) -> Bool {
        let pattern = "^(H|G|TH)\\d+$"
        return query.range(of: pattern, options: .regularExpression) != nil
    }

    /// Validates that the query looks like a BDB ID (BDB prefix followed by digits)
    private func isValidBDBQuery(_ query: String) -> Bool {
        let pattern = "^BDB\\d+$"
        return query.range(of: pattern, options: .regularExpression) != nil
    }

    /// Searches for verses containing the exact Strong's number with proper boundary matching
    private func loadMoreResults() {
        resultLimit += 100
        Task {
            // Don't show loading state for load more to preserve scroll position
            await performSearchAsync(showLoadingState: false)
        }
    }

    // MARK: - Navigation

    private func dismissView() {
        if let binding = isPresentedBinding {
            binding.wrappedValue = false
        } else {
            dismiss()
        }
    }

    private func navigateToVerse(_ result: SearchResult) {
        if isStandaloneMode {
            // In standalone mode, navigate to reader view
            navigateToVerseId = result.id
        } else {
            // In sheet mode, use bindings to scroll existing reader
            if let scrollBinding = requestScrollToVerseIdBinding,
               let animatedBinding = requestScrollAnimatedBinding {
                animatedBinding.wrappedValue = false
                scrollBinding.wrappedValue = result.id
            }
            dismissView()
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult
    let searchQuery: String
    let searchMode: SearchMode
    let fontSize: Int
    let contextAmount: SearchContextAmount
    let translationId: String
    let onNavigate: () -> Void

    @State private var showingSheet: Bool = false

    // Get context verses based on setting using GRDB
    private var contextVerses: [TranslationVerse] {
        let verseId = result.id
        let (verse, chapter, book) = splitVerseId(verseId)

        // Get all verses in the chapter
        let content = (try? TranslationDatabase.shared.getChapter(translationId: translationId, book: book, chapter: chapter)) ?? ChapterContent(verses: [], headings: [])
        let chapterVerses = content.verses

        switch contextAmount {
        case .oneVerse:
            // 1 verse before + hit verse + 1 verse after
            guard let index = chapterVerses.firstIndex(where: { $0.ref == verseId }) else {
                if let singleVerse = try? TranslationDatabase.shared.getVerse(translationId: translationId, ref: verseId) {
                    return [singleVerse]
                }
                return []
            }
            let startIndex = max(0, index - 1)
            let endIndex = min(chapterVerses.count - 1, index + 1)
            return Array(chapterVerses[startIndex...endIndex])
        case .threeVerses:
            // 3 verses before + hit verse + 3 verses after
            guard let index = chapterVerses.firstIndex(where: { $0.ref == verseId }) else {
                if let singleVerse = try? TranslationDatabase.shared.getVerse(translationId: translationId, ref: verseId) {
                    return [singleVerse]
                }
                return []
            }
            let startIndex = max(0, index - 3)
            let endIndex = min(chapterVerses.count - 1, index + 3)
            return Array(chapterVerses[startIndex...endIndex])
        case .chapter:
            // All verses in the chapter
            return chapterVerses
        }
    }

    private var sheetTitle: String {
        result.referenceText
    }

    private func highlightedAttributedText(_ text: String, query: String) -> AttributedString {
        var result = AttributedString()
        // Strip quotes from query for highlighting
        let cleanQuery = getRealmSearchString(from: query)
        let lowercaseText = text.lowercased()
        let lowercaseQuery = cleanQuery.lowercased()

        guard !cleanQuery.isEmpty, lowercaseText.contains(lowercaseQuery) else {
            return AttributedString(text)
        }

        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if let range = text.range(of: cleanQuery, options: .caseInsensitive, range: currentIndex..<text.endIndex) {
                // Add text before match
                if currentIndex < range.lowerBound {
                    result.append(AttributedString(String(text[currentIndex..<range.lowerBound])))
                }
                // Add highlighted match
                var highlight = AttributedString(String(text[range]))
                highlight.foregroundColor = .accentColor
                highlight.font = .system(size: CGFloat(fontSize)).bold()
                result.append(highlight)
                currentIndex = range.upperBound
            } else {
                // Add remaining text
                result.append(AttributedString(String(text[currentIndex..<text.endIndex])))
                break
            }
        }

        return result
    }

    /// Scale factor for relative sizing (module results use ~17pt headline, ~15pt subheadline)
    private var scaleFactor: CGFloat {
        CGFloat(fontSize) / 18.0  // Base font size is 18
    }

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Reference as headline
                Text(result.referenceText)
                    .font(.system(size: 17 * scaleFactor, weight: .semibold))
                    .foregroundColor(.primary)

                // Text snippet as subheadline
                listContextText
                    .font(.system(size: 15 * scaleFactor))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                ScrollView {
                    VerseSheetContent(
                        title: sheetTitle,
                        verseId: result.id,
                        endVerseId: nil,
                        translationId: translationId,
                        onNavigate: {
                            showingSheet = false
                            onNavigate()
                        },
                        contextAmount: contextAmount,
                        highlightQuery: searchQuery,
                        highlightMode: searchMode
                    )
                    .padding()
                }
                .navigationTitle(sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            showingSheet = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingSheet = false
                            onNavigate()
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .presentationDetents([.fraction(0.4), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
    }

    // Context for list rows - always includes the match, truncates from ends to fit
    private var listContextText: Text {
        // Get clean text (snippet contains the verse text)
        let cleanedText = result.text
        let hitInfo: (start: Int, end: Int)?

        if searchMode == .strongs {
            // Parse JSON annotations and find matching Strong's number
            hitInfo = findStrongsHitInAnnotations(result.rawText, strongsNum: searchQuery.uppercased())
        } else {
            // Strip quotes from query for hit finding
            let cleanQuery = getRealmSearchString(from: searchQuery)
            if let range = cleanedText.range(of: cleanQuery, options: .caseInsensitive) {
                hitInfo = (
                    cleanedText.distance(from: cleanedText.startIndex, to: range.lowerBound),
                    cleanedText.distance(from: cleanedText.startIndex, to: range.upperBound)
                )
            } else {
                hitInfo = nil
            }
        }

        // Build snippet with hit centered
        return buildSnippetText(cleanedText: cleanedText, hitInfo: hitInfo, targetLength: 120)
    }

    /// Find the position of a Strong's number hit by parsing annotations_json
    private func findStrongsHitInAnnotations(_ annotationsJson: String, strongsNum: String) -> (start: Int, end: Int)? {
        guard let data = annotationsJson.data(using: .utf8),
              let annotations = try? JSONDecoder().decode([VerseAnnotation].self, from: data) else {
            return nil
        }

        for annotation in annotations {
            if let strongs = annotation.data?.strongs, strongsNumbersMatch(strongs, strongsNum) {
                return (annotation.start, annotation.end)
            }
        }
        return nil
    }

    /// Compare Strong's numbers, normalizing leading zeros (H0216 matches H216)
    private func strongsNumbersMatch(_ a: String, _ b: String) -> Bool {
        // Extract prefix (H, G, TH) and numeric part
        let pattern = "^(TH|H|G)(\\d+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return a == b
        }

        let aRange = NSRange(a.startIndex..., in: a)
        let bRange = NSRange(b.startIndex..., in: b)

        guard let aMatch = regex.firstMatch(in: a, range: aRange),
              let bMatch = regex.firstMatch(in: b, range: bRange),
              let aPrefixRange = Range(aMatch.range(at: 1), in: a),
              let aNumRange = Range(aMatch.range(at: 2), in: a),
              let bPrefixRange = Range(bMatch.range(at: 1), in: b),
              let bNumRange = Range(bMatch.range(at: 2), in: b) else {
            return a.uppercased() == b.uppercased()
        }

        // Compare prefix (case insensitive) and numeric value (ignoring leading zeros)
        let aPrefix = a[aPrefixRange].uppercased()
        let bPrefix = b[bPrefixRange].uppercased()
        let aNum = Int(a[aNumRange]) ?? 0
        let bNum = Int(b[bNumRange]) ?? 0

        return aPrefix == bPrefix && aNum == bNum
    }

    /// Build a snippet Text centered on the hit, with highlighting
    private func buildSnippetText(cleanedText: String, hitInfo: (start: Int, end: Int)?, targetLength: Int) -> Text {
        // If no hit found, just truncate from start
        guard let hit = hitInfo else {
            if cleanedText.count <= targetLength {
                return Text(cleanedText)
            } else {
                return Text(String(cleanedText.prefix(targetLength - 3)) + "...")
            }
        }

        // Validate and clamp hit bounds
        let hitStart = max(0, min(hit.start, cleanedText.count))
        let hitEnd = max(hitStart, min(hit.end, cleanedText.count))

        // If hit is empty or invalid after clamping, just show truncated text
        guard hitStart < hitEnd else {
            if cleanedText.count <= targetLength {
                return Text(cleanedText)
            } else {
                return Text(String(cleanedText.prefix(targetLength - 3)) + "...")
            }
        }

        // If whole text fits, show it all with highlighting
        if cleanedText.count <= targetLength {
            let startIdx = cleanedText.index(cleanedText.startIndex, offsetBy: hitStart)
            let endIdx = cleanedText.index(cleanedText.startIndex, offsetBy: hitEnd)
            return Text(cleanedText[cleanedText.startIndex..<startIdx])
                + Text(cleanedText[startIdx..<endIdx]).foregroundColor(.accentColor).bold()
                + Text(cleanedText[endIdx..<cleanedText.endIndex])
        }

        // Calculate context distribution
        let hitLength = hitEnd - hitStart
        let availableContext = max(0, targetLength - hitLength)

        let idealBefore = availableContext / 2
        let idealAfter = availableContext - idealBefore

        var actualBefore = min(idealBefore, hitStart)
        var actualAfter = min(idealAfter, cleanedText.count - hitEnd)

        // Fill shortfall from the other side
        let shortfallBefore = idealBefore - actualBefore
        let shortfallAfter = idealAfter - actualAfter
        actualAfter = min(actualAfter + shortfallBefore, cleanedText.count - hitEnd)
        actualBefore = min(actualBefore + shortfallAfter, hitStart)

        let snippetStart = hitStart - actualBefore
        let snippetEnd = hitEnd + actualAfter

        let startIdx = cleanedText.index(cleanedText.startIndex, offsetBy: snippetStart)
        let endIdx = cleanedText.index(cleanedText.startIndex, offsetBy: snippetEnd)
        let hitStartIdx = cleanedText.index(cleanedText.startIndex, offsetBy: hitStart)
        let hitEndIdx = cleanedText.index(cleanedText.startIndex, offsetBy: hitEnd)

        var result = Text("")

        if snippetStart > 0 {
            result = result + Text("...")
        }

        result = result + Text(cleanedText[startIdx..<hitStartIdx])
        result = result + Text(cleanedText[hitStartIdx..<hitEndIdx]).foregroundColor(.accentColor).bold()
        result = result + Text(cleanedText[hitEndIdx..<endIdx])

        if snippetEnd < cleanedText.count {
            result = result + Text("...")
        }

        return result
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        // Strip quotes from query for highlighting
        let cleanQuery = getRealmSearchString(from: query)
        let lowercaseText = text.lowercased()
        let lowercaseQuery = cleanQuery.lowercased()

        guard !cleanQuery.isEmpty, lowercaseText.contains(lowercaseQuery) else {
            return Text(text)
        }

        var result = Text("")
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if let range = text.range(of: cleanQuery, options: .caseInsensitive, range: currentIndex..<text.endIndex) {
                // Add text before match
                if currentIndex < range.lowerBound {
                    result = result + Text(text[currentIndex..<range.lowerBound])
                }
                // Add highlighted match
                result = result + Text(text[range])
                    .foregroundColor(.accentColor)
                    .bold()
                currentIndex = range.upperBound
            } else {
                // Add remaining text
                result = result + Text(text[currentIndex..<text.endIndex])
                break
            }
        }

        return result
    }

}

// MARK: - Module Search Result Row

struct ModuleSearchResultRow: View {
    let result: ModuleSearchResult
    var searchQuery: String = ""  // For fallback highlighting when no <mark> tags
    var fontSize: Int = 18
    var onNavigate: (() -> Void)? = nil

    /// Scale factor for relative sizing
    private var scaleFactor: CGFloat {
        CGFloat(fontSize) / 18.0  // Base font size is 18
    }

    private var typeColor: Color {
        switch result.moduleType {
        case .translation: return .gray
        case .notes: return .blue
        case .commentary: return .green
        case .devotional: return .orange
        case .dictionary: return .purple
        case .plan: return .teal
        }
    }

    private var verseReference: String? {
        guard let book = result.book, let chapter = result.chapter, let verse = result.verse else {
            return nil
        }
        // Look up book name
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: book))?.name ?? "Book \(book)"
        // Verse 0 means chapter-level (e.g., chapter intro notes), don't show ":0"
        if verse == 0 {
            return "\(bookName) \(chapter)"
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    /// Parse snippet with <mark> tags into highlighted AttributedString, truncated around first match
    private var highlightedSnippet: AttributedString {
        var snippet = result.snippet
            // Strip reference annotations but keep mark tags
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
            .replacingOccurrences(of: "⟨", with: "")
            .replacingOccurrences(of: "⟩", with: "")

        // If no mark tags and we have a search query, add marks around query matches
        if !snippet.contains("<mark>") && !searchQuery.isEmpty {
            snippet = addMarksForQuery(snippet, query: searchQuery)
        }

        // Find first mark position for centering
        let firstMarkRange = snippet.range(of: "<mark>")
        let cleanText = snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")

        // Calculate character offset of first match in clean text
        let matchOffset: Int
        if let markRange = firstMarkRange {
            let textBeforeMark = String(snippet[..<markRange.lowerBound])
            matchOffset = textBeforeMark
                .replacingOccurrences(of: "<mark>", with: "")
                .replacingOccurrences(of: "</mark>", with: "")
                .count
        } else {
            matchOffset = 0
        }

        // Truncate around match (150 chars total, centered on match)
        let maxLength = 150
        let truncatedText: String
        let addLeadingEllipsis: Bool
        let addTrailingEllipsis: Bool

        if cleanText.count <= maxLength {
            truncatedText = cleanText
            addLeadingEllipsis = false
            addTrailingEllipsis = false
        } else {
            let halfWindow = maxLength / 2
            let startOffset = max(0, matchOffset - halfWindow)
            let endOffset = min(cleanText.count, startOffset + maxLength)
            let adjustedStart = max(0, endOffset - maxLength)

            let startIndex = cleanText.index(cleanText.startIndex, offsetBy: adjustedStart)
            let endIndex = cleanText.index(cleanText.startIndex, offsetBy: endOffset)
            truncatedText = String(cleanText[startIndex..<endIndex])
            addLeadingEllipsis = adjustedStart > 0
            addTrailingEllipsis = endOffset < cleanText.count
        }

        // Now build attributed string with highlighting
        // Re-parse the original snippet to find mark positions within our truncated window
        var attributedResult = AttributedString()

        if addLeadingEllipsis {
            var ellipsis = AttributedString("… ")
            ellipsis.foregroundColor = .secondary
            attributedResult.append(ellipsis)
        }

        // Parse marks from original snippet and map to truncated text
        var segments: [(text: String, isHighlighted: Bool)] = []
        var remaining = snippet
        while !remaining.isEmpty {
            if let markStart = remaining.range(of: "<mark>") {
                // Text before mark
                let before = String(remaining[..<markStart.lowerBound])
                if !before.isEmpty {
                    segments.append((before, false))
                }
                remaining = String(remaining[markStart.upperBound...])

                // Find closing mark
                if let markEnd = remaining.range(of: "</mark>") {
                    let marked = String(remaining[..<markEnd.lowerBound])
                    segments.append((marked, true))
                    remaining = String(remaining[markEnd.upperBound...])
                } else {
                    // No closing tag, treat rest as marked
                    segments.append((remaining, true))
                    remaining = ""
                }
            } else {
                // No more marks
                segments.append((remaining, false))
                remaining = ""
            }
        }

        // Build attributed string from segments, tracking position in clean text
        var charCount = 0
        let truncateStart = addLeadingEllipsis ? (cleanText.count > maxLength ? max(0, matchOffset - maxLength / 2) : 0) : 0
        let truncateEnd = truncateStart + truncatedText.count

        for segment in segments {
            let segmentStart = charCount
            let segmentEnd = charCount + segment.text.count

            // Check if this segment overlaps with our truncated window
            if segmentEnd > truncateStart && segmentStart < truncateEnd {
                let overlapStart = max(segmentStart, truncateStart) - segmentStart
                let overlapEnd = min(segmentEnd, truncateEnd) - segmentStart

                let startIdx = segment.text.index(segment.text.startIndex, offsetBy: overlapStart)
                let endIdx = segment.text.index(segment.text.startIndex, offsetBy: overlapEnd)
                let visibleText = String(segment.text[startIdx..<endIdx])

                if !visibleText.isEmpty {
                    var attrText = AttributedString(visibleText)
                    if segment.isHighlighted {
                        attrText.foregroundColor = .accentColor
                        attrText.font = .system(size: 15 * scaleFactor).bold()
                    } else {
                        attrText.foregroundColor = .secondary
                    }
                    attributedResult.append(attrText)
                }
            }

            charCount += segment.text.count
        }

        if addTrailingEllipsis {
            var ellipsis = AttributedString(" …")
            ellipsis.foregroundColor = .secondary
            attributedResult.append(ellipsis)
        }

        return attributedResult
    }

    /// Add <mark> tags around query matches for fallback highlighting
    private func addMarksForQuery(_ text: String, query: String) -> String {
        // Clean query: remove quotes and wildcards
        let cleanQuery = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard !cleanQuery.isEmpty else { return text }

        // Split into individual terms and search for each
        let terms = cleanQuery.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return text }

        var result = text

        // Mark each term separately (process longer terms first to avoid nested marks)
        for term in terms.sorted(by: { $0.count > $1.count }) {
            var searchStart = result.startIndex
            while let range = result.range(of: term, options: .caseInsensitive, range: searchStart..<result.endIndex) {
                // Check if already inside a mark tag
                let beforeRange = result[result.startIndex..<range.lowerBound]
                let lastMarkOpen = beforeRange.range(of: "<mark>", options: .backwards)
                let lastMarkClose = beforeRange.range(of: "</mark>", options: .backwards)

                let isInsideMark: Bool
                if let openPos = lastMarkOpen?.lowerBound {
                    if let closePos = lastMarkClose?.lowerBound {
                        isInsideMark = openPos > closePos
                    } else {
                        isInsideMark = true
                    }
                } else {
                    isInsideMark = false
                }

                if !isInsideMark {
                    let matchedText = String(result[range])
                    result.replaceSubrange(range, with: "<mark>\(matchedText)</mark>")
                    let offset = "<mark>".count + matchedText.count + "</mark>".count
                    if let newStart = result.index(range.lowerBound, offsetBy: offset, limitedBy: result.endIndex) {
                        searchStart = newStart
                    } else {
                        break
                    }
                } else {
                    // Already marked, skip past this occurrence
                    if let newStart = result.index(range.upperBound, offsetBy: 0, limitedBy: result.endIndex) {
                        searchStart = newStart
                    } else {
                        break
                    }
                }
            }
        }
        return result
    }

    var body: some View {
        Button {
            onNavigate?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Module type and name
                HStack(spacing: 6) {
                    Text(result.moduleType.displayName)
                        .font(.system(size: 11 * scaleFactor, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor)
                        .clipShape(Capsule())

                    Text(result.moduleName)
                        .font(.system(size: 12 * scaleFactor))
                        .foregroundStyle(.secondary)
                }

                // Title
                Text(result.title)
                    .font(.system(size: 17 * scaleFactor, weight: .semibold))
                    .foregroundColor(.primary)

                // Verse reference if applicable
                if let ref = verseReference {
                    Text(ref)
                        .font(.system(size: 12 * scaleFactor))
                        .foregroundStyle(.secondary)
                }

                // Snippet with highlighted matches
                Text(highlightedSnippet)
                    .font(.system(size: 15 * scaleFactor))
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigate == nil)
    }
}

// MARK: - Filter UI Components

struct ModuleFilterPicker: View {
    let availableModules: [SearchableModule]
    @Binding var selectedModuleIds: Set<String>?
    var onChanged: () -> Void

    private var isAllSelected: Bool {
        selectedModuleIds == nil
    }

    private func isSelected(_ moduleId: String) -> Bool {
        selectedModuleIds?.contains(moduleId) ?? false
    }

    /// Group modules by series for a given type
    private func modulesBySeries(for type: ModuleType) -> [(series: String, modules: [SearchableModule])] {
        let filtered = availableModules.filter { $0.type == type }
        let grouped = Dictionary(grouping: filtered) { $0.seriesAbbrev ?? $0.seriesFull ?? "Other" }
        return grouped.map { (series: $0.key, modules: $0.value) }
            .sorted { $0.series < $1.series }
    }

    /// Check if a module type should use series grouping
    private func shouldUseSeriesGrouping(for type: ModuleType) -> Bool {
        type == .commentary || type == .dictionary
    }

    /// Check if all modules in a series are selected
    private func isSeriesSelected(_ modules: [SearchableModule]) -> Bool {
        guard let selected = selectedModuleIds else { return false }
        return modules.allSatisfy { selected.contains($0.id) }
    }

    /// Check if some (but not all) modules in a series are selected
    private func isSeriesPartiallySelected(_ modules: [SearchableModule]) -> Bool {
        guard let selected = selectedModuleIds else { return false }
        let selectedCount = modules.filter { selected.contains($0.id) }.count
        return selectedCount > 0 && selectedCount < modules.count
    }

    var body: some View {
        Menu {
            Button {
                selectedModuleIds = nil
                onChanged()
            } label: {
                HStack {
                    Text("All Modules")
                    if isAllSelected {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Group by type
            let grouped = Dictionary(grouping: availableModules) { $0.type }
            ForEach(ModuleType.allCases, id: \.self) { type in
                if let modules = grouped[type], !modules.isEmpty {
                    let seriesGroups = modulesBySeries(for: type)
                    if shouldUseSeriesGrouping(for: type) && !seriesGroups.isEmpty {
                        // Special handling for types with series grouping
                        Menu {
                            // "All [Type]" option
                            Button {
                                toggleAllModulesOfType(modules)
                            } label: {
                                HStack {
                                    Text("All \(type.displayName)")
                                    if modules.allSatisfy({ isSelected($0.id) }) {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }

                            Divider()

                            // Group by series
                            ForEach(seriesGroups, id: \.series) { seriesGroup in
                                if seriesGroup.modules.count > 1 {
                                    // Series with multiple modules - show as submenu
                                    Menu {
                                        // "All in series" option
                                        Button {
                                            toggleSeries(seriesGroup.modules)
                                        } label: {
                                            HStack {
                                                Text("All \(seriesGroup.series)")
                                                if isSeriesSelected(seriesGroup.modules) {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }

                                        Divider()

                                        // Individual modules
                                        ForEach(seriesGroup.modules) { module in
                                            Button {
                                                toggleModule(module.id)
                                            } label: {
                                                HStack {
                                                    Text(module.name)
                                                    if isSelected(module.id) {
                                                        Spacer()
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            Text(seriesGroup.series)
                                            if isSeriesSelected(seriesGroup.modules) {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            } else if isSeriesPartiallySelected(seriesGroup.modules) {
                                                Spacer()
                                                Image(systemName: "minus")
                                            }
                                        }
                                    }
                                } else {
                                    // Single module in series - show directly
                                    ForEach(seriesGroup.modules) { module in
                                        Button {
                                            toggleModule(module.id)
                                        } label: {
                                            HStack {
                                                Text(module.name)
                                                if isSelected(module.id) {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(type.displayName)
                        }
                    } else {
                        // Standard section for other types
                        Section(type.displayName) {
                            ForEach(modules) { module in
                                Button {
                                    toggleModule(module.id)
                                } label: {
                                    HStack {
                                        Image(systemName: module.isBundled ? "shippingbox" : "person.circle")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(module.name)
                                        if isSelected(module.id) {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                Text(selectedModuleIds == nil ? "All Modules" : "\(selectedModuleIds!.count) selected")
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleModule(_ id: String) {
        if selectedModuleIds == nil {
            // Switching from "All" to specific selection
            selectedModuleIds = [id]
        } else if selectedModuleIds!.contains(id) {
            selectedModuleIds!.remove(id)
            if selectedModuleIds!.isEmpty {
                selectedModuleIds = nil
            }
        } else {
            selectedModuleIds!.insert(id)
        }
        onChanged()
    }

    private func toggleSeries(_ modules: [SearchableModule]) {
        let moduleIds = Set(modules.map { $0.id })

        if selectedModuleIds == nil {
            // Switching from "All" to this series
            selectedModuleIds = moduleIds
        } else if moduleIds.isSubset(of: selectedModuleIds!) {
            // All in series selected - deselect all
            selectedModuleIds!.subtract(moduleIds)
            if selectedModuleIds!.isEmpty {
                selectedModuleIds = nil
            }
        } else {
            // Some or none selected - select all in series
            selectedModuleIds!.formUnion(moduleIds)
        }
        onChanged()
    }

    private func toggleAllModulesOfType(_ modules: [SearchableModule]) {
        let moduleIds = Set(modules.map { $0.id })

        if selectedModuleIds == nil {
            // Switching from "All" to just this type
            selectedModuleIds = moduleIds
        } else if moduleIds.isSubset(of: selectedModuleIds!) {
            // All of type selected - deselect all
            selectedModuleIds!.subtract(moduleIds)
            if selectedModuleIds!.isEmpty {
                selectedModuleIds = nil
            }
        } else {
            // Some or none selected - select all of type
            selectedModuleIds!.formUnion(moduleIds)
        }
        onChanged()
    }
}

// MARK: - Highlighted Content Text View

/// A text view that highlights search terms with yellow background
private struct HighlightedContentText: View {
    let content: String
    let searchQuery: String?
    let font: Font
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil
    var scrollCoordinateSpace: String? = nil  // If set, reports offset via preference key

    @State private var localMatchOffset: CGFloat? = nil

    /// Extract search terms from query string
    private var searchTerms: [String] {
        guard let query = searchQuery, !query.isEmpty else { return [] }
        let cleanQuery = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleanQuery.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }

    var body: some View {
        if searchTerms.isEmpty {
            // No search terms - use standard markdown rendering
            Text(LocalizedStringKey(content))
                .font(font)
        } else {
            // Has search terms - use highlighted rendering
            HighlightedTextUIView(
                content: content,
                searchTerms: searchTerms,
                font: font,
                onFirstMatchOffset: { offset in
                    onFirstMatchOffset?(offset)
                    if scrollCoordinateSpace != nil {
                        localMatchOffset = offset
                    }
                }
            )
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: HighlightedContentMatchOffsetPreferenceKey.self,
                            value: scrollCoordinateSpace != nil && localMatchOffset != nil
                                ? geometry.frame(in: .named(scrollCoordinateSpace!)).minY + (localMatchOffset ?? 0)
                                : nil
                        )
                }
            )
        }
    }
}

/// Preference key for highlighted content match offset
private struct HighlightedContentMatchOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if value == nil {
            value = nextValue()
        }
    }
}

/// UIViewRepresentable to capture the UIScrollView for precise scrolling
private struct ContentScrollViewFinder: UIViewRepresentable {
    var onScrollViewFound: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    onScrollViewFound(scrollView)
                    return
                }
                current = view.superview
            }
            onScrollViewFound(nil)
        }
    }
}

/// UIKit wrapper for text with search term highlighting and first match position reporting
private struct HighlightedTextUIView: UIViewRepresentable {
    let content: String
    let searchTerms: [String]
    let font: Font
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil

    private var effectiveFontSize: CGFloat {
        switch font {
        case .body: return 17
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .callout: return 16
        case .caption: return 12
        case .caption2: return 11
        case .footnote: return 13
        default: return 17
        }
    }

    /// Find the character index of the first search term match
    private var firstMatchRange: NSRange? {
        guard !searchTerms.isEmpty else { return nil }
        let contentLower = content.lowercased()

        var earliestRange: NSRange? = nil
        for term in searchTerms {
            let termLower = term.lowercased()
            if let range = contentLower.range(of: termLower) {
                let nsRange = NSRange(range, in: content)
                if earliestRange == nil || nsRange.location < earliestRange!.location {
                    earliestRange = nsRange
                }
            }
        }
        return earliestRange
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let attrString = buildAttributedString()
        textView.attributedText = attrString
        textView.invalidateIntrinsicContentSize()

        // Report first match offset after layout
        if let matchRange = firstMatchRange, let callback = onFirstMatchOffset {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()
                if let start = textView.position(from: textView.beginningOfDocument, offset: matchRange.location),
                   let end = textView.position(from: start, offset: matchRange.length),
                   let textRange = textView.textRange(from: start, to: end) {
                    let rect = textView.firstRect(for: textRange)
                    if !rect.isNull && !rect.isInfinite {
                        callback(rect.origin.y)
                    }
                }
            }
        }
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    private func buildAttributedString() -> NSAttributedString {
        let uiFont = UIFont.systemFont(ofSize: effectiveFontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = effectiveFontSize * 0.3

        let result = NSMutableAttributedString(string: content, attributes: [
            .font: uiFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ])

        // Apply search term highlighting
        let fullString = content
        let fullStringLower = fullString.lowercased()

        for term in searchTerms {
            let termLower = term.lowercased()
            var searchStartIndex = fullStringLower.startIndex

            while let range = fullStringLower.range(of: termLower, range: searchStartIndex..<fullStringLower.endIndex) {
                let nsRange = NSRange(range, in: fullString)
                result.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.4), range: nsRange)
                searchStartIndex = range.upperBound
            }
        }

        return result
    }
}

// MARK: - Module Entry Sheets

struct DevotionalEntrySheet: View {
    let moduleId: String
    let entryId: String
    var searchQuery: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var preciseMatchOffset: CGFloat? = nil
    @State private var hasScrolledToMatch: Bool = false
    @State private var scrollViewRef: UIScrollView? = nil

    private let scrollCoordinateSpaceName = "devotionalScroll"

    private var entry: DevotionalEntry? {
        try? ModuleDatabase.shared.read { db in
            try DevotionalEntry.filter(Column("id") == entryId).fetchOne(db)
        }
    }

    private var module: Module? {
        try? ModuleDatabase.shared.read { db in
            try Module.filter(Column("id") == moduleId).fetchOne(db)
        }
    }

    private var hasSearchTerms: Bool {
        guard let query = searchQuery, !query.isEmpty else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry = entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let monthDay = entry.monthDay {
                                Text(monthDay)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text(entry.title)
                                .font(.title2)
                                .fontWeight(.bold)

                            if !entry.tagList.isEmpty {
                                HStack {
                                    ForEach(entry.tagList, id: \.self) { tag in
                                        Text(tag)
                                            .font(.caption)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.orange.opacity(0.2))
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            HighlightedContentText(
                                content: entry.content,
                                searchQuery: searchQuery,
                                font: .body,
                                scrollCoordinateSpace: scrollCoordinateSpaceName
                            )
                        }
                        .padding()
                        .background(
                            ContentScrollViewFinder { scrollView in
                                if scrollViewRef == nil {
                                    scrollViewRef = scrollView
                                }
                            }
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpaceName)
                    .onPreferenceChange(HighlightedContentMatchOffsetPreferenceKey.self) { offset in
                        if let offset = offset, preciseMatchOffset == nil {
                            preciseMatchOffset = offset
                        }
                    }
                    .onAppear {
                        if !hasScrolledToMatch, hasSearchTerms {
                            hasScrolledToMatch = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if let offset = preciseMatchOffset, let scrollView = scrollViewRef {
                                    let visibleTop = scrollView.contentOffset.y + 120
                                    let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                    let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                    if !isAlreadyVisible {
                                        let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                        let targetY = min(max(0, offset - 120), maxScrollY)
                                        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: preciseMatchOffset) { _, newOffset in
                        if hasScrolledToMatch, let offset = newOffset, let scrollView = scrollViewRef {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let visibleTop = scrollView.contentOffset.y + 120
                                let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                if !isAlreadyVisible {
                                    let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                    let targetY = min(max(0, offset - 120), maxScrollY)
                                    scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Entry Not Found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(module?.name ?? "Devotional")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}

struct NoteEntrySheet: View {
    let moduleId: String
    let entryId: String
    let verseId: Int?
    var searchQuery: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var preciseMatchOffset: CGFloat? = nil
    @State private var hasScrolledToMatch: Bool = false
    @State private var scrollViewRef: UIScrollView? = nil

    private let scrollCoordinateSpaceName = "noteScroll"

    private var entry: NoteEntry? {
        try? ModuleDatabase.shared.read { db in
            try NoteEntry.filter(Column("id") == entryId).fetchOne(db)
        }
    }

    private var module: Module? {
        try? ModuleDatabase.shared.read { db in
            try Module.filter(Column("id") == moduleId).fetchOne(db)
        }
    }

    private var verseReference: String? {
        guard let entry = entry else { return nil }
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: entry.book))?.name ?? "Book \(entry.book)"
        // Verse 0 means chapter-level note, don't show ":0"
        if entry.verse == 0 {
            return "\(bookName) \(entry.chapter)"
        }
        return "\(bookName) \(entry.chapter):\(entry.verse)"
    }

    private var hasSearchTerms: Bool {
        guard let query = searchQuery, !query.isEmpty else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entry = entry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let ref = verseReference {
                                Text(ref)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            if let title = entry.title, !title.isEmpty {
                                Text(title)
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }

                            HighlightedContentText(
                                content: entry.content,
                                searchQuery: searchQuery,
                                font: .body,
                                scrollCoordinateSpace: scrollCoordinateSpaceName
                            )
                        }
                        .padding()
                        .background(
                            ContentScrollViewFinder { scrollView in
                                if scrollViewRef == nil {
                                    scrollViewRef = scrollView
                                }
                            }
                        )
                    }
                    .coordinateSpace(name: scrollCoordinateSpaceName)
                    .onPreferenceChange(HighlightedContentMatchOffsetPreferenceKey.self) { offset in
                        if let offset = offset, preciseMatchOffset == nil {
                            preciseMatchOffset = offset
                        }
                    }
                    .onAppear {
                        if !hasScrolledToMatch, hasSearchTerms {
                            hasScrolledToMatch = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if let offset = preciseMatchOffset, let scrollView = scrollViewRef {
                                    let visibleTop = scrollView.contentOffset.y + 120
                                    let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                    let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                    if !isAlreadyVisible {
                                        let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                        let targetY = min(max(0, offset - 120), maxScrollY)
                                        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: preciseMatchOffset) { _, newOffset in
                        if hasScrolledToMatch, let offset = newOffset, let scrollView = scrollViewRef {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let visibleTop = scrollView.contentOffset.y + 120
                                let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                if !isAlreadyVisible {
                                    let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                    let targetY = min(max(0, offset - 120), maxScrollY)
                                    scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Entry Not Found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(module?.name ?? "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }
}

struct CommentaryEntrySheet: View {
    let moduleId: String
    let entryId: String
    let verseId: Int?
    var searchQuery: String? = nil
    var translationId: String = "BSBs"
    @Environment(\.dismiss) private var dismiss
    @State private var preciseMatchOffset: CGFloat? = nil
    @State private var hasScrolledToMatch: Bool = false
    @State private var scrollViewRef: UIScrollView? = nil

    // Sheet state for interactive references
    @State private var previewState: PreviewSheetState? = nil
    @State private var strongsKey: String? = nil
    @State private var footnoteItem: CommentaryFootnote? = nil

    private let scrollCoordinateSpaceName = "commentaryScroll"

    private var unit: CommentaryUnit? {
        try? ModuleDatabase.shared.read { db in
            try CommentaryUnit.filter(Column("id") == entryId).fetchOne(db)
        }
    }

    private var module: Module? {
        try? ModuleDatabase.shared.read { db in
            try Module.filter(Column("id") == moduleId).fetchOne(db)
        }
    }

    private var verseReference: String? {
        guard let unit = unit else { return nil }
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: unit.book))?.name ?? "Book \(unit.book)"
        let verse = unit.sv % 1000
        let chapter = (unit.sv / 1000) % 1000
        return "\(bookName) \(chapter):\(verse)"
    }

    /// Extract search terms from query string
    private var searchTerms: [String] {
        guard let query = searchQuery, !query.isEmpty else { return [] }
        let cleanQuery = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleanQuery.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count >= 2 }
    }

    /// Format verse reference for display
    private func formatVerseRef(_ sv: Int, ev: Int?) -> String {
        let bookId = sv / 1000000
        let chapter = (sv % 1000000) / 1000
        let verse = sv % 1000
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name ?? "?"
        if let ev = ev {
            let endVerse = ev % 1000
            if endVerse != verse {
                return "\(bookName) \(chapter):\(verse)-\(endVerse)"
            }
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let unit = unit {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let ref = verseReference {
                                    Text(ref)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                // Use CommentaryUnitView for proper rendering
                                CommentaryUnitView(
                                    unit: unit,
                                    style: CommentaryRenderer.Style(
                                        bodyFont: .body,
                                        uiBodyFont: .systemFont(ofSize: 17),
                                        searchTerms: searchTerms
                                    ),
                                    onScriptureTap: { sv, ev in
                                        let displayText = formatVerseRef(sv, ev: ev)
                                        let item = PreviewItem.verse(index: 0, verseId: sv, endVerseId: ev, displayText: displayText)
                                        previewState = PreviewSheetState(currentItem: item, allItems: [item])
                                    },
                                    onStrongsTap: { key in
                                        strongsKey = key
                                    },
                                    onFootnoteTap: { _, footnote in
                                        footnoteItem = footnote
                                    },
                                    hideVerseReference: true,  // Already shown above
                                    shouldReportMatchOffset: !searchTerms.isEmpty,
                                    scrollCoordinateSpace: scrollCoordinateSpaceName
                                )
                                .id("content")
                            }
                            .padding()
                            .background(
                                CommentaryScrollViewFinder { scrollView in
                                    if scrollViewRef == nil {
                                        scrollViewRef = scrollView
                                    }
                                }
                            )
                        }
                        .coordinateSpace(name: scrollCoordinateSpaceName)
                        .onPreferenceChange(CommentaryMatchOffsetPreferenceKey.self) { offset in
                            if let offset = offset, preciseMatchOffset == nil {
                                preciseMatchOffset = offset
                            }
                        }
                        .onAppear {
                            // Scroll to first match when view appears
                            if !hasScrolledToMatch, !searchTerms.isEmpty {
                                hasScrolledToMatch = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    if let offset = preciseMatchOffset, let scrollView = scrollViewRef {
                                        // Check if match is already visible
                                        let visibleTop = scrollView.contentOffset.y + 120
                                        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                        let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                        if !isAlreadyVisible {
                                            // Clamp to max scroll offset to avoid scrolling past content
                                            let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                            let targetY = min(max(0, offset - 120), maxScrollY)
                                            scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                        }
                                    } else {
                                        // Fall back to field-level scrolling
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            proxy.scrollTo("content", anchor: .top)
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: preciseMatchOffset) { _, newOffset in
                            if hasScrolledToMatch, let offset = newOffset, let scrollView = scrollViewRef {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    let visibleTop = scrollView.contentOffset.y + 120
                                    let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
                                    let isAlreadyVisible = offset >= visibleTop && offset <= visibleBottom - 50

                                    if !isAlreadyVisible {
                                        // Clamp to max scroll offset to avoid scrolling past content
                                        let maxScrollY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                                        let targetY = min(max(0, offset - 120), maxScrollY)
                                        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Entry Not Found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle(module?.name ?? "Commentary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        // Scripture reference sheet
        .sheet(item: $previewState) { _ in
            PreviewSheet(
                state: $previewState,
                translationId: translationId
            )
        }
        // Strong's lexicon sheet
        .sheet(item: $strongsKey) { key in
            LexiconSearchSheet(
                strongsNum: key,
                translationId: translationId,
                fontSize: 17,
                onNavigateToVerse: { _ in }  // No navigation from preview sheet
            )
            .presentationDetents([.fraction(0.4), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        // Footnote sheet
        .sheet(item: $footnoteItem) { footnote in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        AnnotatedTextView(
                            footnote.content,
                            style: CommentaryRenderer.Style(
                                bodyFont: .body,
                                uiBodyFont: .systemFont(ofSize: 17)
                            ),
                            onScriptureTap: { sv, ev in
                                footnoteItem = nil
                                let displayText = formatVerseRef(sv, ev: ev)
                                let item = PreviewItem.verse(index: 0, verseId: sv, endVerseId: ev, displayText: displayText)
                                previewState = PreviewSheetState(currentItem: item, allItems: [item])
                            },
                            onStrongsTap: { key in
                                footnoteItem = nil
                                strongsKey = key
                            }
                        )
                    }
                    .padding()
                }
                .navigationTitle("Footnote \(footnote.id)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { footnoteItem = nil } label: { Image(systemName: "xmark") }
                    }
                }
            }
            .presentationDetents([.fraction(0.4), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
    }
}

/// UIViewRepresentable to capture the hosting view for scroll access in commentary sheets
private struct CommentaryScrollViewFinder: UIViewRepresentable {
    var onScrollViewFound: (UIScrollView?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    onScrollViewFound(scrollView)
                    return
                }
                current = view.superview
            }
            onScrollViewFound(nil)
        }
    }
}

// MARK: - Bible Results List with Scroll Position Tracking

private struct BibleResultsListView: View {
    let searchResults: [SearchResult]
    let currentSearchText: String
    let searchMode: SearchMode
    let fontSize: Int
    let contextAmount: SearchContextAmount
    let translationId: String
    let totalResultCount: Int
    let resultLimit: Int
    let stateManager: SearchStateManager
    let onNavigate: (SearchResult) -> Void
    let onLoadMore: () -> Void

    // Track all visible item IDs - local state only, doesn't trigger parent re-renders
    @State private var visibleIds: Set<Int> = []

    /// Compute the first visible item from our set based on searchResults order
    private var firstVisibleId: Int? {
        for result in searchResults {
            if visibleIds.contains(result.id) {
                return result.id
            }
        }
        return nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(searchResults) { result in
                        let isLast = result.id == searchResults.last?.id
                        SearchResultRow(
                            result: result,
                            searchQuery: currentSearchText,
                            searchMode: searchMode,
                            fontSize: fontSize,
                            contextAmount: contextAmount,
                            translationId: translationId,
                            onNavigate: { onNavigate(result) }
                        )
                        .id(result.id)
                        .listRowSeparator(isLast ? .hidden : .visible, edges: .bottom)
                        .onAppear {
                            visibleIds.insert(result.id)
                        }
                        .onDisappear {
                            visibleIds.remove(result.id)
                        }
                    }
                } header: {
                    if totalResultCount > resultLimit {
                        Text("Showing \(searchResults.count) of \(totalResultCount) results")
                    } else {
                        Text("\(searchResults.count) results")
                    }
                }

                if totalResultCount > resultLimit {
                    Button {
                        onLoadMore()
                    } label: {
                        Text("Load More Results")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .modifier(ConditionalGlassButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .onAppear {
                // Restore scroll position on initial appear only (not during active search)
                if !stateManager.isSearching,
                   let savedId = stateManager.bibleScrollToId,
                   let savedIndex = searchResults.firstIndex(where: { $0.id == savedId }) {
                    // Clear immediately so re-submitting same search doesn't restore
                    stateManager.bibleScrollToId = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Scroll to item after the saved one to compensate for tracking offset
                        if savedIndex + 1 < searchResults.count {
                            proxy.scrollTo(searchResults[savedIndex + 1].id, anchor: .top)
                        } else {
                            proxy.scrollTo(savedId, anchor: .top)
                        }
                    }
                }
            }
            .onDisappear {
                // Save scroll position when leaving (not during active search)
                if !stateManager.isSearching, let visibleId = firstVisibleId {
                    stateManager.bibleScrollToId = visibleId
                }
            }
        }
    }
}
