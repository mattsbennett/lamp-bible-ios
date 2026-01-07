//
//  SearchView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import SwiftUI
import RealmSwift
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
    let translationId: Int?  // nil for legacy entries

    // For display - get translation abbreviation
    var translationAbbreviation: String? {
        guard let id = translationId,
              let translation = RealmManager.shared.realm.object(ofType: Translation.self, forPrimaryKey: id) else {
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

    // Optional translation - if nil, will fetch from Realm
    var providedTranslation: Translation?

    var initialSearchText: String = ""
    var initialSearchMode: SearchMode? = nil  // If set, overrides persisted mode on appear
    var initialSearchScope: SearchScope? = nil  // If set, overrides persisted scope on appear
    var fontSize: Int = 18

    @Environment(\.dismiss) private var dismiss

    // Computed translation - use provided, selected, or fetch default
    private var translation: Translation {
        if let provided = providedTranslation {
            return provided
        }
        let realm = RealmManager.shared.realm
        // Use selected translation if set
        if let selectedId = selectedTranslationId,
           let selected = realm.object(ofType: Translation.self, forPrimaryKey: selectedId) {
            return selected
        }
        // Fetch from user's readerTranslation or get first available
        if let user = realm.objects(User.self).first,
           let userTranslation = user.readerTranslation {
            return userTranslation
        }
        // Fallback to first translation
        return realm.objects(Translation.self).first!
    }

    // Convenience initializer for sheet presentation (backward compatible)
    init(
        isPresented: Binding<Bool>,
        translation: Translation,
        requestScrollToVerseId: Binding<Int?>,
        requestScrollAnimated: Binding<Bool>,
        initialSearchText: String = "",
        initialSearchMode: SearchMode? = nil,
        initialSearchScope: SearchScope? = nil,
        fontSize: Int = 18
    ) {
        self.isPresentedBinding = isPresented
        self.providedTranslation = translation
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
        self.providedTranslation = nil
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
    @State private var selectedTranslationId: Int? = nil  // For standalone mode translation selection
    @State private var navigateToVerseId: Int? = nil  // For standalone mode navigation to reader
    @State private var readerDate: Date = Date.now  // Date binding for reader
    @AppStorage("searchContextAmount") private var contextAmount: SearchContextAmount = .oneVerse
    @AppStorage("searchHistory") private var searchHistoryData: Data = Data()
    @AppStorage("moduleSearchHistory") private var moduleSearchHistoryData: Data = Data()
    @AppStorage("searchMode") private var searchMode: SearchMode = .text
    @AppStorage("searchScope") private var searchScope: SearchScope = .bible
    @AppStorage("hiddenTranslations") private var hiddenTranslations: String = ""

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
        providedTranslation == nil
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
    private var availableTranslations: [Translation] {
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
    private let debounceDelay: UInt64 = 300_000_000 // 300ms

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
        // Quick check: see if any verse contains the Strong's annotation pattern
        translation.verses.filter("t CONTAINS '|H' OR t CONTAINS '|G'").count > 0
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
        let entry = SearchHistoryEntry(query: query, mode: searchMode, translationId: translation.id)
        // Remove if already exists with same query and translation (to move to top)
        history.removeAll { $0.query.lowercased() == query.lowercased() && $0.translationId == translation.id }
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
                        // Show match count while typing, before submit
                        matchCountState
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
                                        selectedTranslationId = trans.id
                                        // Clear results when changing translation
                                        searchResults = []
                                        resultsVisible = false
                                    } label: {
                                        if trans.id == translation.id {
                                            Label(trans.name, systemImage: "checkmark")
                                        } else {
                                            Text(trans.name)
                                        }
                                    }
                                }
                            } label: {
                                Label("Translation: \(translation.abbreviation)", systemImage: "book.closed")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: searchScope.icon)
                            Text(searchScope == .bible ? translation.abbreviation : searchScope.rawValue)
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
                                                    selectedTranslationId = translationId
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
                scheduleSearch()
            }
            .onChange(of: moduleSearchText) {
                guard searchScope == .modules else { return }
                resultsVisible = false
                scheduleSearch()
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
                    user: RealmManager.shared.realm.objects(User.self).first!,
                    date: $readerDate,
                    initialVerseId: verseId,
                    initialTranslation: translation
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
                    ModuleSearchResultRow(
                        result: result,
                        fontSize: fontSize,
                        onNavigate: {
                            handleModuleResultTap(result)
                        }
                    )
                }
            } header: {
                Text("\(moduleSearchResults.count) results")
            }
        }
        .listStyle(.plain)
        .sheet(item: $selectedLexiconEntry) { result in
            if let strongsKey = result.strongsKey {
                LexiconSheetView(
                    word: result.title.components(separatedBy: " (").first ?? result.title,
                    strongs: [strongsKey],
                    morphology: nil,
                    translation: translation,
                    restrictToLexicon: lexiconKeyForModuleId(result.moduleId)
                )
            }
        }
        .sheet(item: $selectedDevotional) { result in
            DevotionalEntrySheet(moduleId: result.moduleId, entryId: result.id)
        }
        .sheet(item: $selectedNote) { result in
            NoteEntrySheet(moduleId: result.moduleId, entryId: result.id, verseId: result.verseId)
        }
        .sheet(item: $selectedCommentary) { result in
            CommentaryEntrySheet(moduleId: result.moduleId, entryId: result.id, verseId: result.verseId)
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
                return "\(translation.abbreviation) does not include Strong's annotations. Switch to a Strong's-annotated translation to search by Strong's numbers."
            }
        } else {
            return "No verses found matching \"\(currentSearchText)\"."
        }
    }

    private var matchCountState: some View {
        ContentUnavailableView(
            totalResultCount > 0 ? "\(totalResultCount) matches" : "No matches",
            systemImage: "magnifyingglass",
            description: Text("Submit to view results")
        )
    }

    private var resultsList: some View {
        BibleResultsListView(
            searchResults: searchResults,
            currentSearchText: currentSearchText,
            searchMode: searchMode,
            fontSize: fontSize,
            contextAmount: contextAmount,
            translation: translation,
            totalResultCount: totalResultCount,
            resultLimit: resultLimit,
            stateManager: stateManager,
            onNavigate: navigateToVerse,
            onLoadMore: loadMoreResults
        )
    }

    // MARK: - Search Logic

    /// Debounced search that just counts matches (for live preview)
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceDelay)
            } catch {
                return // Task was cancelled
            }

            guard !Task.isCancelled else { return }
            await performSearch(showResults: false)
        }
    }

    /// Submit search - shows results and saves to history
    private func submitSearch() {
        searchTask?.cancel()
        resultsVisible = true
        performSearch(showResults: true)

        // Save to Bible history if we found results (module history is saved in performModuleSearch)
        if searchScope == .bible {
            let query = bibleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !searchResults.isEmpty && query.count >= 2 {
                saveToBibleHistory(query)
            }
        }
        // Note: Search state is automatically preserved in stateManager
    }

    @MainActor
    private func performSearch(showResults: Bool) {
        // Handle module search separately
        if searchScope == .modules {
            performModuleSearch(showResults: showResults)
            return
        }

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

        isSearching = true
        // Clear saved scroll position so re-submitting doesn't restore
        stateManager.bibleScrollToId = nil

        if searchMode == .strongs {
            let allResults = versesContainingStrongs(query, translationId: translation.id)
            totalResultCount = allResults.count

            if showResults {
                let limited = Array(allResults.prefix(resultLimit))
                searchResults = limited.compactMap { verse -> SearchResult? in
                    guard let book = RealmManager.shared.realm.objects(Book.self)
                        .filter("id == %@", verse.b).first else { return nil }
                    return SearchResult(verse: verse, bookName: book.name)
                }
            }
        } else {
            // Text search - parse query for quoted (exact word) and unquoted (substring) terms
            let searchTerms = parseSearchQuery(query)
            let realmQuery = getRealmSearchString(from: query)

            // Check if this translation has cleanText populated (first verse non-empty)
            let hasCleanText = translation.verses.first?.cleanText.isEmpty == false

            // Pre-filter with CONTAINS on cleanText or t field
            let candidates = hasCleanText
                ? translation.verses.filter("cleanText CONTAINS[c] %@", realmQuery)
                : translation.verses.filter("t CONTAINS[c] %@", realmQuery)

            // Post-filter for word-boundary matching on quoted terms
            let filteredVerses = candidates.filter { verse in
                let text = hasCleanText ? verse.cleanText : stripStrongsAnnotations(verse.t)
                return textMatchesAllTerms(text, terms: searchTerms)
            }

            totalResultCount = filteredVerses.count

            if showResults {
                let limited = Array(filteredVerses.prefix(resultLimit))
                searchResults = limited.compactMap { verse -> SearchResult? in
                    guard let book = RealmManager.shared.realm.objects(Book.self)
                        .filter("id == %@", verse.b).first else { return nil }
                    return SearchResult(verse: verse, bookName: book.name)
                }
            }
        }

        isSearching = false
    }

    /// Performs search across user modules (notes, commentaries, devotionals, dictionaries)
    @MainActor
    private func performModuleSearch(showResults: Bool) {
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

        isSearching = true

        do {
            let results = try moduleSearch.search(query: searchByKey ? "" : query, filter: filter, limit: resultLimit)
            totalResultCount = results.count

            if showResults {
                moduleSearchResults = results
                // Save to module history if we have results
                let hasValidQuery = query.count >= 2 || filter.strongsKey != nil
                if !results.isEmpty && hasValidQuery {
                    saveToModuleHistory(query)
                }
            }
        } catch {
            print("Module search failed: \(error)")
            moduleSearchResults = []
            totalResultCount = 0
        }

        isSearching = false
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
    private func versesContainingStrongs(_ strongsNum: String, translationId: Int) -> Results<Verse> {
        // All possible boundary patterns for exact match:
        // |H1254}  - single number, end of annotation
        // |H1254,  - first in a comma-separated list
        // ,H1254,  - middle of list
        // ,H1254}  - end of list
        // |H1254|  - single number with morphology following
        // ,H1254|  - end of list with morphology following
        let patterns = [
            "|\(strongsNum)}",   // single, end
            "|\(strongsNum),",   // first in list
            ",\(strongsNum),",   // middle of list
            ",\(strongsNum)}",   // end of list
            "|\(strongsNum)|",   // single with morphology
            ",\(strongsNum)|"    // end of list with morphology
        ]

        let predicates = patterns.map {
            NSPredicate(format: "t CONTAINS %@", $0)
        }
        let compoundPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        return RealmManager.shared.realm.objects(Verse.self)
            .filter("tr == %@", translationId)
            .filter(compoundPredicate)
    }

    private func loadMoreResults() {
        resultLimit += 100
        performSearch(showResults: true)
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
    let translation: Translation
    let onNavigate: () -> Void

    @State private var showingSheet: Bool = false

    // Get context verses based on setting
    private var contextVerses: [Verse] {
        let verseId = result.id
        let (_, chapter, book) = splitVerseId(verseId)

        switch contextAmount {
        case .oneVerse:
            // 1 verse before + hit verse + 1 verse after
            let chapterVerses = translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v")
            guard let index = chapterVerses.firstIndex(where: { $0.id == verseId }) else {
                return Array(translation.verses.filter("id == %@", verseId))
            }
            let startIndex = max(0, index - 1)
            let endIndex = min(chapterVerses.count - 1, index + 1)
            return Array(chapterVerses[startIndex...endIndex])
        case .threeVerses:
            // 3 verses before + hit verse + 3 verses after
            let chapterVerses = translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v")
            guard let index = chapterVerses.firstIndex(where: { $0.id == verseId }) else {
                return Array(translation.verses.filter("id == %@", verseId))
            }
            let startIndex = max(0, index - 3)
            let endIndex = min(chapterVerses.count - 1, index + 3)
            return Array(chapterVerses[startIndex...endIndex])
        case .chapter:
            // All verses in the chapter
            return Array(translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v"))
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

    /// Highlights words that contain the specified Strong's number in their annotation
    private func highlightedStrongsAttributedText(_ text: String, strongsNum: String) -> AttributedString {
        var result = AttributedString()

        // Parse the annotated text: {word|H123} or {word|H123,H456} or {word|H123|TH8799}
        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(stripStrongsAnnotations(text))
        }

        let nsText = text as NSString
        var currentIndex = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // Add text before this annotation
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                result.append(AttributedString(beforeText))
            }

            // Extract word and annotation
            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            // Check if this annotation contains our Strong's number
            let containsStrongs = annotationContainsStrongs(annotation, strongsNum: strongsNum)

            if containsStrongs {
                var highlight = AttributedString(word)
                highlight.foregroundColor = .accentColor
                highlight.font = .system(size: CGFloat(fontSize)).bold()
                result.append(highlight)
            } else {
                result.append(AttributedString(word))
            }

            currentIndex = match.range.location + match.range.length
        }

        // Add remaining text after last annotation
        if currentIndex < nsText.length {
            let remainingText = nsText.substring(from: currentIndex)
            result.append(AttributedString(remainingText))
        }

        return result
    }

    /// Checks if an annotation string contains the specified Strong's number with proper boundaries
    private func annotationContainsStrongs(_ annotation: String, strongsNum: String) -> Bool {
        // Annotation format: H123 or H123,H456 or H123|TH8799
        // Split by comma and pipe to get individual numbers
        let parts = annotation.components(separatedBy: CharacterSet(charactersIn: ",|"))
        return parts.contains { $0.trimmingCharacters(in: .whitespaces) == strongsNum }
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
                        translation: translation,
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
        // Get clean text and find hit position
        let cleanedText = stripStrongsAnnotations(result.text)
        let hitInfo: (start: Int, end: Int)?

        if searchMode == .strongs {
            hitInfo = findStrongsHitPosition(in: result.verse.t, strongsNum: searchQuery.uppercased())
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

    /// Find the position of a Strong's number hit in the cleaned text
    private func findStrongsHitPosition(in annotatedText: String, strongsNum: String) -> (start: Int, end: Int)? {
        let words = parseAnnotatedVerse(annotatedText)
        var position = 0

        for word in words {
            if word.strongs.contains(where: { strongsNumbersMatch($0, strongsNum) }) {
                return (position, position + word.text.count)
            }
            position += word.text.count
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

    /// Highlights words containing the Strong's number, returns Text for full verse display
    private func highlightedStrongsText(_ text: String, strongsNum: String) -> Text {
        var result = Text("")

        // Parse the annotated text: {word|H123} or {word|H123,H456} or {word|H123|TH8799}
        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(stripStrongsAnnotations(text))
        }

        let nsText = text as NSString
        var currentIndex = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // Add text before this annotation
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                result = result + Text(beforeText)
            }

            // Extract word and annotation
            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            // Check if this annotation contains our Strong's number
            let containsStrongs = annotationContainsStrongs(annotation, strongsNum: strongsNum)

            if containsStrongs {
                result = result + Text(word)
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                result = result + Text(word)
            }

            currentIndex = match.range.location + match.range.length
        }

        // Add remaining text after last annotation
        if currentIndex < nsText.length {
            let remainingText = nsText.substring(from: currentIndex)
            result = result + Text(remainingText)
        }

        return result
    }
}

// MARK: - Module Search Result Row

struct ModuleSearchResultRow: View {
    let result: ModuleSearchResult
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
        }
    }

    private var verseReference: String? {
        guard let book = result.book, let chapter = result.chapter, let verse = result.verse else {
            return nil
        }
        // Look up book name
        let bookObj = RealmManager.shared.realm.objects(Book.self).filter("id == %@", book).first
        return "\(bookObj?.name ?? "Book \(book)") \(chapter):\(verse)"
    }

    /// Clean snippet by stripping HTML marks and reference annotations
    private var cleanSnippet: String {
        result.snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
            // Strip Bible reference annotations ⟦...⟧
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
            // Strip Strong's reference annotations ⟨...⟩
            .replacingOccurrences(of: "⟨", with: "")
            .replacingOccurrences(of: "⟩", with: "")
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

                // Snippet (strip HTML marks and reference annotations)
                Text(cleanSnippet)
                    .font(.system(size: 15 * scaleFactor))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
}

// MARK: - Module Entry Sheets

struct DevotionalEntrySheet: View {
    let moduleId: String
    let entryId: String
    @Environment(\.dismiss) private var dismiss

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

                            Text(LocalizedStringKey(entry.content))
                                .font(.body)
                        }
                        .padding()
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
    @Environment(\.dismiss) private var dismiss

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
        let bookObj = RealmManager.shared.realm.objects(Book.self).filter("id == %@", entry.book).first
        return "\(bookObj?.name ?? "Book \(entry.book)") \(entry.chapter):\(entry.verse)"
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

                            Text(LocalizedStringKey(entry.content))
                                .font(.body)
                        }
                        .padding()
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
    @Environment(\.dismiss) private var dismiss

    private var entry: CommentaryEntry? {
        try? ModuleDatabase.shared.read { db in
            try CommentaryEntry.filter(Column("id") == entryId).fetchOne(db)
        }
    }

    private var module: Module? {
        try? ModuleDatabase.shared.read { db in
            try Module.filter(Column("id") == moduleId).fetchOne(db)
        }
    }

    private var verseReference: String? {
        guard let entry = entry else { return nil }
        let bookObj = RealmManager.shared.realm.objects(Book.self).filter("id == %@", entry.book).first
        return "\(bookObj?.name ?? "Book \(entry.book)") \(entry.chapter):\(entry.verse)"
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

                            if let heading = entry.heading, !heading.isEmpty {
                                Text(heading)
                                    .font(.title2)
                                    .fontWeight(.bold)
                            }

                            Text(LocalizedStringKey(entry.content))
                                .font(.body)
                        }
                        .padding()
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
    }
}

// MARK: - Bible Results List with Scroll Position Tracking

private struct BibleResultsListView: View {
    let searchResults: [SearchResult]
    let currentSearchText: String
    let searchMode: SearchMode
    let fontSize: Int
    let contextAmount: SearchContextAmount
    let translation: Translation
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
                        SearchResultRow(
                            result: result,
                            searchQuery: currentSearchText,
                            searchMode: searchMode,
                            fontSize: fontSize,
                            contextAmount: contextAmount,
                            translation: translation,
                            onNavigate: { onNavigate(result) }
                        )
                        .id(result.id)
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
