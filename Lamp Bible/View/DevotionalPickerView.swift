//
//  DevotionalPickerView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

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
    @State private var availableCategories: [DevotionalCategory] = []
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

    /// The currently selected module
    private var selectedModule: Module? {
        devotionalModules.first { $0.id == selectedModuleId }
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
            result = result.filter { devotional in
                guard let category = devotional.meta.category else { return false }
                return filterOptions.categories.contains(category)
            }
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack = onBack {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                }
            }

            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(devotionalModules, id: \.id) { module in
                        Button {
                            if selectedModuleId != module.id {
                                selectedModuleId = module.id
                                loadDevotionals()
                            }
                        } label: {
                            HStack {
                                Text(module.name)
                                if module.id == selectedModuleId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedModule?.name ?? "Devotionals")
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
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
                        Label("Import Devotional", systemImage: "doc.badge.plus")
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
                    Button(action: { showingNewDevotional = true }) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewDevotional) {
            DevotionalEditorSheet(moduleId: selectedModuleId) { newDevotional in
                loadDevotionals()
            }
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
            loadDevotionals()
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

        do {
            _ = try DevotionalSharingManager.shared.importAndSave(url, moduleId: targetModuleId)
            loadDevotionals()
        } catch {
            importError = error.localizedDescription
            showingImportError = true
        }

        cleanupPendingImport()
    }

    private func cleanupPendingImport() {
        pendingImportURL?.stopAccessingSecurityScopedResource()
        pendingImportURL = nil
        importPreview = nil
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search devotionals...", text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
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
                    DevotionalFilterChip(label: category.rawValue, icon: "folder") {
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
                Text("No devotionals found")
                    .font(.headline)
                Text("Try adjusting your search or filters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("No Devotionals Yet")
                    .font(.headline)
                Text("Create your first devotional to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button(action: { showingNewDevotional = true }) {
                    Label("New Devotional", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var devotionalList: some View {
        List {
            ForEach(filteredDevotionals, id: \.meta.id) { devotional in
                if let onSelect = onSelect {
                    // When used with onSelect callback (e.g., in ToolPanel)
                    Button {
                        onSelect(devotional)
                    } label: {
                        DevotionalListRow(devotional: devotional)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden, edges: devotional.meta.id == filteredDevotionals.first?.meta.id ? .top : [])
                    .listRowSeparator(devotional.meta.id == filteredDevotionals.last?.meta.id ? .hidden : .visible, edges: .bottom)
                } else {
                    // When used standalone - navigate to DevotionalView
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
                        DevotionalListRow(devotional: devotional)
                    }
                    .listRowSeparator(.hidden, edges: devotional.meta.id == filteredDevotionals.first?.meta.id ? .top : [])
                    .listRowSeparator(devotional.meta.id == filteredDevotionals.last?.meta.id ? .hidden : .visible, edges: .bottom)
                }
            }
            .onDelete(perform: deleteDevotionals)
        }
        .listStyle(.plain)
        .refreshable {
            loadDevotionals()
        }
    }

    // MARK: - Actions

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
            } catch {
                print("Failed to load devotionals: \(error)")
            }
            isLoading = false
        }
    }

    private func deleteDevotionals(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredDevotionals[$0] }
        for devotional in toDelete {
            do {
                try DevotionalStorage.shared.deleteDevotional(id: devotional.meta.id)
            } catch {
                print("Failed to delete devotional: \(error)")
            }
        }
        loadDevotionals()
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

    init(devotional: Devotional) {
        self.devotional = devotional
    }

    private var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title and category
            HStack {
                Text(devotional.meta.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if let category = devotional.meta.category {
                    Text(category.rawValue.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(categoryColor(category).opacity(0.2))
                        .foregroundColor(categoryColor(category))
                        .cornerRadius(4)
                }
            }

            // Subtitle
            if let subtitle = devotional.meta.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Metadata row
            HStack(spacing: 12) {
                // Date
                if let dateStr = devotional.meta.date {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(dateStr)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                // Author
                if let author = devotional.meta.author {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.caption2)
                        Text(author)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }

            // Tags
            if let tags = devotional.meta.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                        if tags.count > 3 {
                            Text("+\(tags.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func categoryColor(_ category: DevotionalCategory) -> Color {
        switch category {
        case .devotional: return .purple
        case .exhortation: return .blue
        case .reflection: return .green
        case .study: return .orange
        case .prayer: return .pink
        case .other: return .gray
        }
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
    let availableCategories: [DevotionalCategory]

    @State private var selectedTags: Set<String> = []
    @State private var selectedCategories: Set<DevotionalCategory> = []
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
                            Toggle(category.rawValue.capitalized, isOn: Binding(
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
    @State private var category: DevotionalCategory = .devotional
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Subtitle (optional)", text: $subtitle)
                    TextField("Author (optional)", text: $author)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Category", selection: $category) {
                        ForEach(DevotionalCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue.capitalized).tag(cat)
                        }
                    }
                }

                Section("Tags") {
                    TextField("Tags (comma-separated)", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("New Devotional")
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

// MARK: - Preview

#Preview {
    DevotionalPickerView(isFullScreen: true)
}
