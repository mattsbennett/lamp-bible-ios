//
//  DevotionalPickerView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import LampCore
import SwiftUI
import UniformTypeIdentifiers

struct DevotionalPickerView: View {
    // Configuration
    var isFullScreen: Bool = false
    var showNewProminent: Bool = false
    var initialModuleId: String = "devotionals"
    var onSelect: ((Devotional) -> Void)?
    var onBack: (() -> Void)?

    // State
    @State private var selectedModuleId: String = ""
    @State private var devotionals: [Devotional] = []
    @State private var searchText: String = ""
    @State private var sortOption: DevotionalSortOption = .dateNewest
    @State private var filterOptions: DevotionalFilterOptions = DevotionalFilterOptions()
    @State private var availableTags: [String] = []
    @State private var availableCategories: [String] = []
    @State private var isLoading: Bool = true
    @State private var showingNewDevotional: Bool = false
    @State private var showingSortMenu: Bool = false
    @State private var showingFilterSheet: Bool = false
    @State private var showingExportOptions: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var importError: String? = nil
    @State private var showingImportError: Bool = false
    @State private var showingImportPreview: Bool = false
    @State private var importPreview: LampFilePreview? = nil
    @State private var pendingImportURL: URL? = nil
    @State private var devotionalModules: [Module] = []
    @State private var selectedImportModuleId: String = ""
    @State private var lastLoadedModuleId: String = ""
    /// Writings a slide deck was made from, so their rows can say so.
    @State private var writingIDsWithSlides: Set<String> = []
    @State private var showingDeckLibrary: Bool = false
    /// Writings changed here and on another device since they last agreed.
    /// Until each is settled their module can't upload, so they're offered
    /// here, where the writing is.
    @ObservedObject private var moduleSyncManager = ModuleSyncManager.shared
    @State private var showingConflicts: Bool = false

    /// The currently selected module
    private var selectedModule: Module? {
        devotionalModules.first { $0.id == selectedModuleId }
    }

    /// A module's name as the library shows it. The default module was
    /// created as "My Devotionals"; what it holds is all the person's
    /// writing, of which a devotional is one kind.
    static func displayName(of module: Module?) -> String {
        guard let module else { return "Writing" }
        return module.name == "My Devotionals" ? "My Writing" : module.name
    }

    // Filtered results
    private var filteredDevotionals: [Devotional] {
        var result = devotionals

        // Apply search filter
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { devotional in
                devotional.meta.title.lowercased().contains(query) ||
                devotional.meta.subtitle?.lowercased().contains(query) == true ||
                devotional.meta.tags?.contains { $0.lowercased().contains(query) } == true
            }
        }

        // Apply tag filter
        if !filterOptions.tags.isEmpty {
            result = result.filter { devotional in
                guard let tags = devotional.meta.tags else { return false }
                return !filterOptions.tags.isDisjoint(with: Set(tags))
            }
        }

        // Apply category filter
        if !filterOptions.categories.isEmpty {
            result = result.filter { filterOptions.matchesCategory(of: $0.meta) }
        }

        // Apply date range filter
        if let range = filterOptions.dateRange {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting
            result = result.filter { devotional in
                guard let dateStr = devotional.meta.date,
                      let date = formatter.date(from: dateStr) else { return true }
                return range.contains(date)
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar

            // Filter indicators
            if hasActiveFilters {
                filterIndicators
            }

            if !moduleSyncManager.pendingDevotionalConflicts.isEmpty {
                conflictBanner
            }

            // Main content
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDevotionals.isEmpty {
                emptyState
            } else {
                devotionalList
            }
        }
        .background(LampTheme.groupedBackground.ignoresSafeArea())
        // Standalone, the list is the writing's home: its module as a large
        // title, switched from the title's own menu.
        .navigationTitle(Self.displayName(of: selectedModule))
        .navigationBarTitleDisplayMode(onSelect == nil ? .large : .inline)
        .toolbarTitleMenu {
            moduleButtons
        }
        .toolbar {
            if let onBack = onBack {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                }
            }

            if onSelect != nil {
            ToolbarItem(placement: .principal) {
                Menu {
                    moduleButtons
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.displayName(of: selectedModule))
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                }
            }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    // Also on the large title's own menu; here too, where it
                    // is in plain sight.
                    if onSelect == nil {
                        Menu {
                            moduleButtons
                        } label: {
                            Label("Module", systemImage: "books.vertical")
                        }
                    }

                    Menu {
                        ForEach(DevotionalSortOption.allCases, id: \.self) { option in
                            Button(action: { sortOption = option }) {
                                HStack {
                                    Text(option.rawValue)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }

                    Button(action: { showingFilterSheet = true }) {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }

                    Divider()

                    Menu {
                        Button(action: { exportAll() }) {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                        Button(action: { exportToSingleFile() }) {
                            Label("Export to Single File", systemImage: "doc.text")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }

                    Button(action: { showingFileImporter = true }) {
                        Label("Import Writing", systemImage: "doc.badge.plus")
                    }

                    Divider()

                    // Every deck, including those not made from a writing and
                    // those opened from Files.
                    Button(action: { showingDeckLibrary = true }) {
                        Label("Slide Decks", systemImage: "rectangle.on.rectangle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }

            // Bottom toolbar with new devotional button
            if !isLoading && !filteredDevotionals.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                ToolbarItem(placement: .bottomBar) {
                    newWritingButton
                }
            }
        }
        .sheet(isPresented: $showingNewDevotional) {
            DevotionalEditorSheet(moduleId: selectedModuleId) { newDevotional in
                loadDevotionals()
            }
        }
        .sheet(isPresented: $showingDeckLibrary) {
            DeckLibraryView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingConflicts, onDismiss: loadDevotionals) {
            DevotionalConflictView()
        }
        .onChange(of: moduleSyncManager.pendingDevotionalConflicts.count) { oldCount, newCount in
            if oldCount == 0 && newCount > 0 {
                showingConflicts = true
            }
        }
        .task { await reloadWritingIDsWithSlides() }
        .onReceive(NotificationCenter.default.publisher(for: .presentationDecksDidChange)) { _ in
            Task { await reloadWritingIDsWithSlides() }
        }
        .sheet(isPresented: $showingFilterSheet) {
            DevotionalFilterSheet(
                filterOptions: $filterOptions,
                availableTags: availableTags,
                availableCategories: availableCategories
            )
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.lampFile, .json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK") { }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .sheet(isPresented: $showingImportPreview) {
            if let preview = importPreview {
                ImportPreviewSheet(
                    preview: preview,
                    devotionalModules: devotionalModules,
                    defaultModuleId: selectedModuleId,
                    onImport: { importModuleId in
                        selectedImportModuleId = importModuleId
                        performImport()
                    },
                    onCancel: {
                        cleanupPendingImport()
                    }
                )
            }
        }
        .task {
            // Only load if we haven't loaded yet or module changed
            let targetModuleId = selectedModuleId.isEmpty ? initialModuleId : selectedModuleId
            if lastLoadedModuleId != targetModuleId || devotionals.isEmpty {
                loadDevotionals()
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing the security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Could not access the selected file"
                showingImportError = true
                return
            }

            // Store the URL for later import (keep security scope active)
            pendingImportURL = url

            do {
                // Preview the file
                let preview = try DevotionalSharingManager.shared.previewFile(url)
                importPreview = preview
                showingImportPreview = true
            } catch {
                url.stopAccessingSecurityScopedResource()
                pendingImportURL = nil
                importError = error.localizedDescription
                showingImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func performImport() {
        guard let url = pendingImportURL else { return }

        // Use the selected module ID, or fall back to current module
        let targetModuleId = selectedImportModuleId.isEmpty ? selectedModuleId : selectedImportModuleId

        // Stage a copy while the security scope is still held; the import itself is
        // async and would otherwise outlive the scope released below.
        let staged: URL
        do {
            staged = try DevotionalSharingManager.shared.stageForImport(url)
        } catch {
            importError = error.localizedDescription
            showingImportError = true
            cleanupPendingImport()
            return
        }

        cleanupPendingImport()

        Task {
            do {
                try await DevotionalSharingManager.shared.importAndSave(staged, moduleId: targetModuleId)
                // Show the module the devotional landed in, otherwise the import looks
                // like it did nothing when the destination isn't the current module.
                if selectedModuleId != targetModuleId {
                    selectedModuleId = targetModuleId
                }
                loadDevotionals()
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }
            DevotionalSharingManager.shared.discardStagedImport(staged)
        }
    }

    private func cleanupPendingImport() {
        pendingImportURL?.stopAccessingSecurityScopedResource()
        pendingImportURL = nil
        importPreview = nil
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            // A placeholder of our own: the field's own is too faint to read.
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search writing")
                .overlay(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search writing")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The one action this list exists for, in the accent so it is found at
    /// once.
    @ViewBuilder
    private var newWritingButton: some View {
        let button = Button(action: { showingNewDevotional = true }) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("New Writing")
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button
        }
    }

    private var conflictBanner: some View {
        let count = moduleSyncManager.pendingDevotionalConflicts.count
        return Button {
            showingConflicts = true
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("\(count) sync conflict\(count == 1 ? "" : "s")")
                    .fontWeight(.medium)
                Spacer()
                Text("Resolve")
                    .foregroundColor(.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.orange.opacity(0.15))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var hasActiveFilters: Bool {
        !filterOptions.tags.isEmpty ||
        !filterOptions.categories.isEmpty ||
        filterOptions.dateRange != nil
    }

    private var filterIndicators: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(filterOptions.tags), id: \.self) { tag in
                    DevotionalFilterChip(label: tag, icon: "tag") {
                        filterOptions.tags.remove(tag)
                    }
                }

                ForEach(Array(filterOptions.categories), id: \.self) { category in
                    DevotionalFilterChip(label: LampWritingCategory.displayName(category) ?? category, icon: "folder") {
                        filterOptions.categories.remove(category)
                    }
                }

                if filterOptions.dateRange != nil {
                    DevotionalFilterChip(label: "Date Range", icon: "calendar") {
                        filterOptions.dateRange = nil
                    }
                }

                Button(action: { filterOptions = DevotionalFilterOptions() }) {
                    Text("Clear All")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if !searchText.isEmpty || hasActiveFilters {
                Text("No writing found")
                    .font(.headline)
                Text("Try adjusting your search or filters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("No Writing Yet")
                    .font(.headline)
                Text("Start your first piece: a study, a reflection, a prayer.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button(action: { showingNewDevotional = true }) {
                    Label("New Writing", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .padding(.top, 8)
            }
        }
        .centeredInVisibleSpace()
    }

    /// The modules writing can live in, to switch between.
    @ViewBuilder
    private var moduleButtons: some View {
        ForEach(devotionalModules, id: \.id) { module in
            Button {
                if selectedModuleId != module.id {
                    selectedModuleId = module.id
                    loadDevotionals()
                }
            } label: {
                HStack {
                    Text(Self.displayName(of: module))
                    if module.id == selectedModuleId {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    /// Each piece its own card.
    private var devotionalList: some View {
        List {
            Section {
                ForEach(filteredDevotionals, id: \.meta.id) { devotional in
                    Group {
                        if let onSelect = onSelect {
                            // When used with onSelect callback (e.g., in ToolPanel)
                            Button {
                                onSelect(devotional)
                            } label: {
                                DevotionalListRow(devotional: devotional, hasSlides: hasSlides(devotional))
                            }
                            .buttonStyle(.plain)
                        } else {
                            // When used standalone - navigate to DevotionalView.
                            // The link sits behind the card, so the card draws
                            // its own disclosure mark in its own colour.
                            ZStack {
                                NavigationLink {
                                    DevotionalView(
                                        devotional: devotional,
                                        moduleId: selectedModuleId,
                                        initialMode: .read,
                                        onBack: {
                                            loadDevotionals()
                                        }
                                    )
                                } label: {
                                    EmptyView()
                                }
                                .opacity(0)
                                DevotionalListRow(devotional: devotional, hasSlides: hasSlides(devotional), showsDisclosure: true)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 32, bottom: 6, trailing: 28))
                    .listRowSeparator(.hidden)
                    .listRowBackground(cardBackground)
                }
                .onDelete(perform: deleteDevotionals)

            } header: {
                Text(listHeader)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
                    .textCase(nil)
                    .padding(.leading, 4)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable {
            loadDevotionals()
        }
    }

    /// A list row's card, inset from the screen's edges and from its
    /// neighbours.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous)
            .fill(LampTheme.card)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    /// How many pieces, and in what order, above the list.
    private var listHeader: String {
        let count = filteredDevotionals.count
        let pieces = count == 1 ? "1 piece" : "\(count) pieces"
        let order = switch sortOption {
        case .dateNewest: "Newest first"
        case .dateOldest: "Oldest first"
        case .titleAZ: "A to Z"
        case .titleZA: "Z to A"
        case .lastModified: "Recently edited"
        }
        return "\(pieces) · \(order)"
    }

    // MARK: - Actions

    private func hasSlides(_ devotional: Devotional) -> Bool {
        writingIDsWithSlides.contains(devotional.meta.id.uppercased())
    }

    private func reloadWritingIDsWithSlides() async {
        writingIDsWithSlides = await Task.detached(priority: .utility) {
            PresentationDeckStorage.shared.linkedWritingIDs()
        }.value
    }

    private func loadDevotionals() {
        Task {
            isLoading = true
            do {
                // Ensure the default devotionals module exists
                try await ModuleSyncManager.shared.ensureDefaultDevotionalsModule()

                // Load available devotional modules first
                devotionalModules = try ModuleDatabase.shared.getAllModules(type: .devotional)

                // Ensure we have a valid selected module
                if selectedModuleId.isEmpty {
                    selectedModuleId = initialModuleId
                }
                // If the selected module doesn't exist, fall back to first available
                if !devotionalModules.contains(where: { $0.id == selectedModuleId }) {
                    selectedModuleId = devotionalModules.first?.id ?? "devotionals"
                }

                // Load devotionals with current sort
                devotionals = try DevotionalStorage.shared.getDevotionals(
                    moduleId: selectedModuleId,
                    filter: DevotionalFilterOptions(),
                    sort: sortOption
                )

                // Load available tags and categories for filtering
                availableTags = try DevotionalStorage.shared.getAllTags(moduleId: selectedModuleId)
                availableCategories = try DevotionalStorage.shared.getUsedCategories(moduleId: selectedModuleId)

                // Track which module we loaded
                lastLoadedModuleId = selectedModuleId
            } catch {
                print("Failed to load devotionals: \(error)")
            }
            isLoading = false
        }
    }

    private func deleteDevotionals(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredDevotionals[$0] }
        let moduleId = selectedModuleId
        Task {
            for devotional in toDelete {
                do {
                    try await ModuleSyncManager.shared.deleteDevotional(id: devotional.meta.id, moduleId: moduleId)
                } catch {
                    print("Failed to delete devotional: \(error)")
                }
            }
            await MainActor.run {
                loadDevotionals()
            }
        }
    }

    private func exportAll() {
        Task {
            do {
                let urls = try await DevotionalImportExportManager.shared.exportAllDevotionals(moduleId: selectedModuleId)
                print("Exported \(urls.count) devotionals")
            } catch {
                print("Export failed: \(error)")
            }
        }
    }

    private func exportToSingleFile() {
        Task {
            do {
                let url = try await DevotionalImportExportManager.shared.exportAllToSingleFile(moduleId: selectedModuleId)
                print("Exported to \(url.path)")
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}

// MARK: - Supporting Views

struct DevotionalListRow: View {
    let devotional: Devotional
    /// A slide deck was made from this writing; the writing opens it.
    var hasSlides: Bool = false
    /// Draws its own chevron: the list's link sits behind the card.
    var showsDisclosure: Bool = false

    init(devotional: Devotional, hasSlides: Bool = false, showsDisclosure: Bool = false) {
        self.devotional = devotional
        self.hasSlides = hasSlides
        self.showsDisclosure = showsDisclosure
    }

    /// "2026-11-06" as a reader would write it.
    private var displayDate: String? {
        guard let raw = devotional.meta.date else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = TimeZone.current
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The opening of the text, so a row can be told from its neighbours
    /// by what it says and not only by its title.
    private var excerpt: String? {
        let markdown = devotional.markdownContent ?? MarkdownDevotionalConverter.contentToMarkdown(devotional)
        return Self.excerpt(fromMarkdown: markdown)
    }

    /// Plain prose from the first paragraphs of some Markdown: headings,
    /// quotation and list markers, emphasis, links and note markers removed.
    static func excerpt(fromMarkdown markdown: String, limit: Int = 180) -> String? {
        var pieces: [String] = []
        var length = 0
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Headings, rules, tables, images and note definitions say
            // little about the writing.
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || line.hasPrefix("![")
                || line.hasPrefix("[^") || line.allSatisfy({ "-*_ ".contains($0) }) {
                continue
            }
            for prefix in ["> ", ">", "- ", "* ", "+ "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            line = line.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[\^[^\]]*\]"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            pieces.append(line)
            length += line.count
            if length >= limit { break }
        }
        let text = pieces.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            details
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(LampTheme.caption)
                    .accessibilityHidden(true)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(devotional.meta.title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Subtitle
            if let subtitle = devotional.meta.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
                    .lineLimit(1)
            }

            // The opening, in the writing's own serif.
            if let excerpt {
                Text(excerpt)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(LampTheme.readerText.opacity(0.85))
                    .lineSpacing(2)
                    .lineLimit(2)
                    .padding(.top, 2)
            }

            // Metadata row
            HStack(spacing: 6) {
                if let date = displayDate {
                    Text(date)
                }
                if let category = devotional.meta.categoryName {
                    if displayDate != nil { Text("·") }
                    Text(category)
                }
                if let author = devotional.meta.author, !author.isEmpty {
                    Text("·")
                    Text(author)
                }
                if hasSlides {
                    Text("·")
                    Label("Slides", systemImage: "rectangle.on.rectangle")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(LampTheme.caption)
            .lineLimit(1)
            .padding(.top, 4)

            // Tags
            if let tags = devotional.meta.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(LampTheme.tileFill, in: Capsule())
                                .foregroundStyle(LampTheme.caption)
                        }
                        if tags.count > 3 {
                            Text("+\(tags.count - 3)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}

struct DevotionalFilterChip: View {
    let label: String
    let icon: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1))
        .foregroundColor(.accentColor)
        .cornerRadius(12)
    }
}

// MARK: - Filter Sheet

struct DevotionalFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filterOptions: DevotionalFilterOptions
    let availableTags: [String]
    let availableCategories: [String]

    @State private var selectedTags: Set<String> = []
    @State private var selectedCategories: Set<String> = []
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var useDateFilter: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // Tags
                if !availableTags.isEmpty {
                    Section("Tags") {
                        ForEach(availableTags, id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { selectedTags.contains(tag) },
                                set: { if $0 { selectedTags.insert(tag) } else { selectedTags.remove(tag) } }
                            ))
                        }
                    }
                }

                // Categories
                if !availableCategories.isEmpty {
                    Section("Categories") {
                        ForEach(availableCategories, id: \.self) { category in
                            Toggle(LampWritingCategory.displayName(category) ?? category, isOn: Binding(
                                get: { selectedCategories.contains(category) },
                                set: { if $0 { selectedCategories.insert(category) } else { selectedCategories.remove(category) } }
                            ))
                        }
                    }
                }

                // Date Range
                Section("Date Range") {
                    Toggle("Filter by Date", isOn: $useDateFilter)

                    if useDateFilter {
                        DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                        DatePicker("End Date", selection: $endDate, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyFilters()
                        dismiss()
                    }
                }
            }
            .onAppear {
                selectedTags = filterOptions.tags
                selectedCategories = filterOptions.categories
                if let range = filterOptions.dateRange {
                    useDateFilter = true
                    startDate = range.lowerBound
                    endDate = range.upperBound
                }
            }
        }
    }

    private func applyFilters() {
        filterOptions.tags = selectedTags
        filterOptions.categories = selectedCategories
        filterOptions.dateRange = useDateFilter ? startDate...endDate : nil
    }
}

// MARK: - New Devotional Editor Sheet

struct DevotionalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let moduleId: String
    let onSave: (Devotional) -> Void

    @State private var title: String = ""
    @State private var subtitle: String = ""
    @State private var author: String = ""
    @State private var date: Date = Date()
    @State private var category: String = "Devotional"
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Subtitle (optional)", text: $subtitle)
                    TextField("Author (optional)", text: $author)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    DevotionalCategoryField(category: $category)
                }

                Section("Tags") {
                    TextField("Tags (comma-separated)", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("New Writing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createDevotional()
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }

    private func createDevotional() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting

        let tags = tagsText.isEmpty ? nil : tagsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let meta = DevotionalMeta(
            id: UUID().uuidString,
            title: title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            author: author.isEmpty ? nil : author,
            date: formatter.string(from: date),
            tags: tags,
            category: category,
            created: Int(Date().timeIntervalSince1970),
            lastModified: Int(Date().timeIntervalSince1970)
        )

        let devotional = Devotional(
            meta: meta,
            content: .blocks([
                DevotionalContentBlock(
                    type: .paragraph,
                    content: DevotionalAnnotatedText(text: "")
                )
            ])
        )

        // Use Task to call async save and export to iCloud
        Task {
            do {
                try await ModuleSyncManager.shared.saveDevotional(devotional, moduleId: moduleId)
                await MainActor.run {
                    onSave(devotional)
                    dismiss()
                }
            } catch {
                print("Failed to save devotional: \(error)")
            }
        }
    }
}

// MARK: - Category Field

/// A writing's kind, chosen from the suggestions and the kinds the library
/// already holds, or named by the writer under Custom. The list comes first:
/// picking is the usual case, and a text field here hid it behind the keyboard.
struct DevotionalCategoryField: View {
    @Binding var category: String

    @State private var offered = LampWritingCategory.suggestions
    @State private var isNamingCustom = false
    @State private var customName = ""

    private var shownName: String {
        category.isEmpty ? "None" : category
    }

    var body: some View {
        Menu {
            ForEach(offered, id: \.self) { kind in
                let name = LampWritingCategory.displayName(kind) ?? kind
                Button {
                    category = name
                } label: {
                    if LampWritingCategory.foldedKey(kind) == LampWritingCategory.foldedKey(category) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("Custom\u{2026}") {
                customName = category
                isNamingCustom = true
            }
            Button("None") { category = "" }
        } label: {
            HStack {
                // A menu tints its label, relative styles included.
                Text("Category")
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(shownName)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Category")
        .accessibilityValue(shownName)
        .alert("Custom Category", isPresented: $isNamingCustom) {
            TextField("Category", text: $customName)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                category = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onAppear {
            offered = LampWritingCategory.offered(
                forLibraryHolding: (try? DevotionalStorage.shared.getUsedCategories()) ?? []
            )
        }
    }
}

// MARK: - Preview

#Preview {
    DevotionalPickerView(isFullScreen: true)
}
