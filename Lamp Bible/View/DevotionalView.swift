//
//  DevotionalView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import SwiftUI
import GRDB

struct DevotionalView: View {
    @State private var devotionalModules: [Module] = []
    @State private var selectedModuleId: String = ""
    @State private var entries: [DevotionalEntry] = []
    @State private var selectedEntry: DevotionalEntry?
    @State private var isLoading: Bool = true
    @State private var filterMode: FilterMode = .date
    @State private var selectedDate: Date = Date()
    @State private var selectedTag: String = ""
    @State private var availableTags: [String] = []
    @State private var isEditing: Bool = false
    @State private var editContent: String = ""
    @State private var editTitle: String = ""
    @State private var showingNewEntrySheet: Bool = false

    private let database = ModuleDatabase.shared
    private let syncManager = ModuleSyncManager.shared

    enum FilterMode: String, CaseIterable {
        case date = "By Date"
        case tag = "By Tag"
        case all = "All"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Module and filter controls
                if devotionalModules.count > 1 {
                    Picker("Module", selection: $selectedModuleId) {
                        ForEach(devotionalModules, id: \.id) { module in
                            Text(module.name).tag(module.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                // Filter mode picker
                Picker("Filter", selection: $filterMode) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Filter controls based on mode
                filterControls

                Divider()

                // Content
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if devotionalModules.isEmpty {
                    emptyModulesView
                } else if entries.isEmpty {
                    emptyEntriesView
                } else {
                    entriesList
                }
            }
            .navigationTitle("Devotionals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !selectedModuleId.isEmpty {
                        Button {
                            showingNewEntrySheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                DevotionalDetailView(
                    entry: entry,
                    isEditable: devotionalModules.first(where: { $0.id == entry.moduleId })?.isEditable ?? false,
                    onSave: { updatedEntry in
                        Task {
                            try? await syncManager.saveDevotional(updatedEntry)
                            await loadEntries()
                        }
                    },
                    onDelete: {
                        Task {
                            try? await syncManager.deleteDevotional(id: entry.id, moduleId: entry.moduleId)
                            await loadEntries()
                        }
                    }
                )
            }
            .sheet(isPresented: $showingNewEntrySheet) {
                NewDevotionalEntryView(moduleId: selectedModuleId) { newEntry in
                    Task {
                        try? await syncManager.saveDevotional(newEntry)
                        await loadEntries()
                    }
                }
            }
            .task {
                await loadModules()
            }
            .onChange(of: selectedModuleId) { _, _ in
                Task { await loadEntries() }
            }
            .onChange(of: filterMode) { _, _ in
                Task { await loadEntries() }
            }
            .onChange(of: selectedDate) { _, _ in
                if filterMode == .date {
                    Task { await loadEntries() }
                }
            }
            .onChange(of: selectedTag) { _, _ in
                if filterMode == .tag {
                    Task { await loadEntries() }
                }
            }
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        switch filterMode {
        case .date:
            DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .padding(.horizontal)
        case .tag:
            if availableTags.isEmpty {
                Text("No tags available")
                    .foregroundStyle(.tertiary)
                    .padding()
            } else {
                Picker("Tag", selection: $selectedTag) {
                    Text("All Tags").tag("")
                    ForEach(availableTags, id: \.self) { tag in
                        Text(tag).tag(tag)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
            }
        case .all:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyModulesView: some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No devotionals installed")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add devotionals via Settings → Modules")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        Spacer()
    }

    @ViewBuilder
    private var emptyEntriesView: some View {
        Spacer()
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No entries found")
                .font(.headline)
                .foregroundStyle(.secondary)
            if filterMode == .date {
                Text("No devotional for \(selectedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        Spacer()
    }

    @ViewBuilder
    private var entriesList: some View {
        List {
            ForEach(entries) { entry in
                Button {
                    selectedEntry = entry
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.headline)
                            .foregroundColor(.primary)

                        if let monthDay = entry.monthDay {
                            Text(monthDay)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !entry.tagList.isEmpty {
                            HStack {
                                ForEach(entry.tagList, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(4)
                                }
                            }
                        }

                        Text(entry.content.prefix(100) + (entry.content.count > 100 ? "..." : ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.plain)
    }

    private func loadModules() async {
        isLoading = true
        do {
            devotionalModules = try database.getAllModules(type: .devotional)
            if !devotionalModules.isEmpty && (selectedModuleId.isEmpty || !devotionalModules.contains(where: { $0.id == selectedModuleId })) {
                selectedModuleId = devotionalModules.first?.id ?? ""
            }
            await loadTags()
            await loadEntries()
        } catch {
            print("Failed to load devotional modules: \(error)")
        }
        isLoading = false
    }

    private func loadTags() async {
        guard !selectedModuleId.isEmpty else {
            availableTags = []
            return
        }

        do {
            let allEntries = try database.read { db in
                try DevotionalEntry
                    .filter(Column("module_id") == selectedModuleId)
                    .fetchAll(db)
            }
            var tagSet = Set<String>()
            for entry in allEntries {
                tagSet.formUnion(entry.tagList)
            }
            availableTags = tagSet.sorted()
        } catch {
            print("Failed to load tags: \(error)")
            availableTags = []
        }
    }

    private func loadEntries() async {
        guard !selectedModuleId.isEmpty else {
            entries = []
            return
        }

        do {
            switch filterMode {
            case .date:
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd"
                let monthDay = formatter.string(from: selectedDate)
                entries = try database.getDevotionalsForDate(moduleId: selectedModuleId, monthDay: monthDay)

            case .tag:
                if selectedTag.isEmpty {
                    entries = try database.read { db in
                        try DevotionalEntry
                            .filter(Column("module_id") == selectedModuleId)
                            .order(Column("title"))
                            .fetchAll(db)
                    }
                } else {
                    entries = try database.getDevotionalsWithTag(moduleId: selectedModuleId, tag: selectedTag)
                }

            case .all:
                entries = try database.read { db in
                    try DevotionalEntry
                        .filter(Column("module_id") == selectedModuleId)
                        .order(Column("title"))
                        .fetchAll(db)
                }
            }
        } catch {
            print("Failed to load devotional entries: \(error)")
            entries = []
        }
    }
}

// MARK: - Devotional Detail View

struct DevotionalDetailView: View {
    let entry: DevotionalEntry
    let isEditable: Bool
    var onSave: ((DevotionalEntry) -> Void)?
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing: Bool = false
    @State private var editTitle: String = ""
    @State private var editContent: String = ""
    @State private var showingDeleteConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEditing {
                        TextField("Title", text: $editTitle)
                            .font(.title2)
                            .fontWeight(.bold)

                        TextEditor(text: $editContent)
                            .frame(minHeight: 300)
                            .scrollContentBackground(.hidden)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                    } else {
                        Text(entry.title)
                            .font(.title2)
                            .fontWeight(.bold)

                        if let monthDay = entry.monthDay {
                            Text(monthDay)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !entry.tagList.isEmpty {
                            HStack {
                                ForEach(entry.tagList, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.1))
                                        .cornerRadius(6)
                                }
                            }
                        }

                        Divider()

                        Text(entry.content)
                            .font(.body)
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Cancel") {
                            isEditing = false
                        }
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if isEditable {
                        if isEditing {
                            Button("Save") {
                                saveChanges()
                            }
                        } else {
                            Menu {
                                Button {
                                    editTitle = entry.title
                                    editContent = entry.content
                                    isEditing = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    showingDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Delete Devotional", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this devotional entry?")
            }
        }
    }

    private func saveChanges() {
        var updated = entry
        updated.title = editTitle
        updated.content = editContent
        updated.lastModified = Int(Date().timeIntervalSince1970)
        onSave?(updated)
        isEditing = false
        dismiss()
    }
}

// MARK: - New Devotional Entry View

struct NewDevotionalEntryView: View {
    let moduleId: String
    var onSave: ((DevotionalEntry) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var monthDay: String = ""
    @State private var tags: String = ""
    @State private var useDate: Bool = false
    @State private var selectedDate: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Enter title", text: $title)
                }

                Section("Date (Optional)") {
                    Toggle("Link to date", isOn: $useDate)
                    if useDate {
                        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    }
                }

                Section("Tags (Optional)") {
                    TextField("Comma-separated tags", text: $tags)
                }

                Section("Content") {
                    TextEditor(text: $content)
                        .frame(minHeight: 200)
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
                    Button("Save") {
                        saveEntry()
                    }
                    .disabled(title.isEmpty || content.isEmpty)
                }
            }
        }
    }

    private func saveEntry() {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"

        let tagList = tags.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let entry = DevotionalEntry(
            moduleId: moduleId,
            monthDay: useDate ? formatter.string(from: selectedDate) : nil,
            tags: tagList.isEmpty ? nil : tagList,
            title: title,
            content: content
        )

        onSave?(entry)
        dismiss()
    }
}

#Preview {
    DevotionalView()
}
