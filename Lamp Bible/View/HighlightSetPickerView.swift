//
//  HighlightSetPickerView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import SwiftUI

/// Sheet view for selecting and managing highlight sets
struct HighlightSetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var showingNewSetSheet = false
    @State private var setToDelete: HighlightSet?
    @State private var showingDeleteConfirmation = false
    @State private var setForThemes: HighlightSet?

    var body: some View {
        NavigationView {
            List {
                if highlightManager.availableSets.isEmpty {
                    Text("No highlight sets for this translation.")
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(highlightManager.availableSets) { set in
                        HighlightSetRow(
                            set: set,
                            isSelected: highlightManager.activeSetId == set.id,
                            onSelect: {
                                highlightManager.selectSet(set.id)
                                dismiss()
                            },
                            onEditThemes: {
                                setForThemes = set
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                setToDelete = set
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .sheet(item: $setForThemes) { set in
                NavigationStack {
                    HighlightThemesListView(set: set)
                }
            }
            .navigationTitle("Highlight Sets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingNewSetSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewSetSheet) {
                NewHighlightSetSheet()
            }
            .confirmationDialog(
                "Delete Highlight Set",
                isPresented: $showingDeleteConfirmation,
                presenting: setToDelete
            ) { set in
                Button("Delete \"\(set.name)\"", role: .destructive) {
                    deleteSet(set)
                }
            } message: { set in
                Text("This will permanently delete all highlights in \"\(set.name)\". This action cannot be undone.")
            }
        }
    }

    private func deleteSet(_ set: HighlightSet) {
        Task {
            do {
                try await highlightManager.deleteHighlightSet(id: set.id)
            } catch {
                print("[HighlightSetPicker] Error deleting set: \(error)")
            }
        }
    }
}

// MARK: - Highlight Set Row

struct HighlightSetRow: View {
    let set: HighlightSet
    let isSelected: Bool
    let onSelect: () -> Void
    var onEditThemes: (() -> Void)? = nil

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(set.name)
                        .foregroundColor(.primary)

                    if let description = set.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Show highlight and theme counts
                    HStack(spacing: 8) {
                        if let count = highlightCount {
                            Text("\(count) highlight\(count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let themeCount = themeCount, themeCount > 0 {
                            Text("\(themeCount) theme\(themeCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let editThemes = onEditThemes {
                Button {
                    editThemes()
                } label: {
                    Label("Edit Themes", systemImage: "tag")
                }
            }
        }
    }

    private var highlightCount: Int? {
        try? ModuleDatabase.shared.getHighlightCount(setId: set.id)
    }

    private var themeCount: Int? {
        try? ModuleDatabase.shared.getHighlightThemes(setId: set.id).count
    }
}

// MARK: - New Highlight Set Sheet

struct NewHighlightSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var errorMessage: String?

    private var defaultName: String {
        if let translationId = highlightManager.currentTranslationId,
           let translation = try? TranslationDatabase.shared.getTranslation(id: translationId) {
            return "My \(translation.abbreviation.uppercased()) Highlights"
        }
        return "My Highlights"
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(defaultName, text: $name)
                    TextField("Description (optional)", text: $description)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("New Highlight Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createSet()
                    }
                }
            }
        }
    }

    private func createSet() {
        do {
            _ = try highlightManager.createHighlightSet(
                name: name.isEmpty ? nil : name,
                description: description.isEmpty ? nil : description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    HighlightSetPickerView()
}
