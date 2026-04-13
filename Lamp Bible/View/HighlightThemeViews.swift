//
//  HighlightThemeViews.swift
//  Lamp Bible
//
//  Created by Claude on 2025-04-12.
//

import SwiftUI

// MARK: - Theme Editor Sheet

/// Sheet for editing a single highlight theme (color+style combo)
struct HighlightThemeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let setId: String
    let color: HighlightColor
    let style: HighlightStyle
    let existingTheme: HighlightTheme?
    let onSave: (HighlightTheme) -> Void

    @State private var name: String = ""
    @State private var themeDescription: String = ""

    init(setId: String, color: HighlightColor, style: HighlightStyle, existingTheme: HighlightTheme? = nil, onSave: @escaping (HighlightTheme) -> Void) {
        self.setId = setId
        self.color = color
        self.style = style
        self.existingTheme = existingTheme
        self.onSave = onSave
        _name = State(initialValue: existingTheme?.name ?? "")
        _themeDescription = State(initialValue: existingTheme?.themeDescription ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Preview of the color+style
                    HStack {
                        ThemePreviewSwatch(color: color, style: style)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.displayName)
                                .font(.headline)
                            Text(color.hex)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Theme")) {
                    TextField("Name (e.g., Promises, Commands)", text: $name)

                    TextField("Description (optional)", text: $themeDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                if existingTheme != nil {
                    Section {
                        Button(role: .destructive) {
                            deleteTheme()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Remove Theme")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(existingTheme != nil ? "Edit Theme" : "Add Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveTheme()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func saveTheme() {
        let theme = HighlightTheme(
            setId: setId,
            color: color,
            style: style,
            name: name.trimmingCharacters(in: .whitespaces),
            description: themeDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : themeDescription.trimmingCharacters(in: .whitespaces)
        )
        onSave(theme)
        dismiss()
    }

    private func deleteTheme() {
        if let existing = existingTheme {
            try? ModuleDatabase.shared.deleteHighlightTheme(id: existing.id)
        }
        dismiss()
    }
}

// MARK: - Themes List View

/// List of all themes for a highlight set
struct HighlightThemesListView: View {
    let set: HighlightSet

    @State private var themes: [HighlightTheme] = []
    @State private var showingAddTheme = false
    @State private var selectedColorForNew: HighlightColor = .yellow
    @State private var selectedStyleForNew: HighlightStyle = .highlight
    @State private var themeToEdit: HighlightTheme?

    var body: some View {
        List {
            if themes.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "tag")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Themes")
                            .font(.headline)
                        Text("Add themes to give meaning to your color and style combinations.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section(header: Text("Themes")) {
                    ForEach(themes) { theme in
                        ThemeRow(theme: theme)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                themeToEdit = theme
                            }
                    }
                    .onDelete(perform: deleteThemes)
                }
            }
        }
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showingAddTheme = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddTheme) {
            AddThemeSheet(setId: set.id) { theme in
                saveTheme(theme)
            }
        }
        .sheet(item: $themeToEdit) { theme in
            HighlightThemeEditorSheet(
                setId: set.id,
                color: theme.highlightColor,
                style: theme.highlightStyle,
                existingTheme: theme
            ) { updatedTheme in
                saveTheme(updatedTheme)
            }
        }
        .onAppear {
            loadThemes()
        }
    }

    private func loadThemes() {
        themes = (try? ModuleDatabase.shared.getHighlightThemes(setId: set.id)) ?? []
    }

    private func saveTheme(_ theme: HighlightTheme) {
        try? ModuleDatabase.shared.saveHighlightTheme(theme)
        loadThemes()
        scheduleSyncForSet()
    }

    private func deleteThemes(at offsets: IndexSet) {
        for index in offsets {
            let theme = themes[index]
            try? ModuleDatabase.shared.deleteHighlightTheme(id: theme.id)
        }
        loadThemes()
        scheduleSyncForSet()
    }

    private func scheduleSyncForSet() {
        // Trigger sync for the highlight module
        if let module = try? ModuleDatabase.shared.getModule(id: set.moduleId) {
            Task {
                try? await ModuleSyncManager.shared.exportModule(id: module.id)
            }
        }
    }
}

// MARK: - Add Theme Sheet

/// Sheet for adding a new theme (select color+style first)
struct AddThemeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let setId: String
    let onSave: (HighlightTheme) -> Void

    @State private var selectedColor: HighlightColor = .yellow
    @State private var selectedStyle: HighlightStyle = .highlight
    @State private var name: String = ""
    @State private var themeDescription: String = ""
    @State private var colors: [HighlightColor] = []

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Style")) {
                    HStack(spacing: 8) {
                        ForEach(HighlightStyle.allCases, id: \.rawValue) { style in
                            Button {
                                selectedStyle = style
                            } label: {
                                VStack(spacing: 4) {
                                    style.icon
                                        .font(.title2)
                                    Text(style.displayName)
                                        .font(.caption2)
                                }
                                .foregroundColor(selectedStyle == style ? .primary : .secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedStyle == style ? Color.secondary.opacity(0.2) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(header: Text("Color")) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(colors) { color in
                            Button {
                                selectedColor = color
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 36, height: 36)

                                    if selectedColor.hex == color.hex {
                                        Circle()
                                            .strokeBorder(Color.primary, lineWidth: 3)
                                            .frame(width: 36, height: 36)

                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section(header: Text("Preview")) {
                    HStack {
                        ThemePreviewSwatch(color: selectedColor, style: selectedStyle)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedStyle.displayName)
                                .font(.headline)
                            Text(selectedColor.hex)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Theme")) {
                    TextField("Name (e.g., Promises, Commands)", text: $name)

                    TextField("Description (optional)", text: $themeDescription, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("Add Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let theme = HighlightTheme(
                            setId: setId,
                            color: selectedColor,
                            style: selectedStyle,
                            name: name.trimmingCharacters(in: .whitespaces),
                            description: themeDescription.trimmingCharacters(in: .whitespaces).isEmpty ? nil : themeDescription.trimmingCharacters(in: .whitespaces)
                        )
                        onSave(theme)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                colors = HighlightColorManager.shared.getColors()
                if let first = colors.first {
                    selectedColor = first
                }
            }
        }
    }
}

// MARK: - Theme Row

/// Row displaying a single theme
struct ThemeRow: View {
    let theme: HighlightTheme

    var body: some View {
        HStack(spacing: 12) {
            ThemePreviewSwatch(color: theme.highlightColor, style: theme.highlightStyle)

            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name)
                    .font(.body)

                if let description = theme.themeDescription, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Theme Preview Swatch

/// Preview of a color+style combination
struct ThemePreviewSwatch: View {
    let color: HighlightColor
    let style: HighlightStyle

    var body: some View {
        ZStack {
            // Background showing the style
            RoundedRectangle(cornerRadius: 6)
                .fill(style == .highlight ? color.color.opacity(0.4) : Color.clear)
                .frame(width: 44, height: 28)

            // Text sample
            Text("Aa")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)

            // Underline for underline styles
            if style != .highlight {
                style.underlineShape(color: color.color)
                    .frame(width: 28, height: 4)
                    .offset(y: 10)
            }
        }
        .frame(width: 44, height: 32)
    }
}

// MARK: - Highlight Style Extension

extension HighlightStyle {
    @ViewBuilder
    func underlineShape(color: Color) -> some View {
        switch self {
        case .highlight:
            EmptyView()
        case .underlineSolid:
            Rectangle()
                .fill(color)
        case .underlineDashed:
            Rectangle()
                .fill(color)
                .mask(
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { _ in
                            Rectangle()
                                .frame(width: 4)
                        }
                    }
                )
        case .underlineDotted:
            Rectangle()
                .fill(color)
                .mask(
                    HStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { _ in
                            Circle()
                                .frame(width: 3, height: 3)
                        }
                    }
                )
        }
    }
}

// MARK: - Theme Badge (for color picker)

/// Small badge showing theme name under a color swatch
struct ThemeBadge: View {
    let themeName: String

    var body: some View {
        Text(themeName)
            .font(.system(size: 8, weight: .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 40)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HighlightThemesListView(set: HighlightSet(
            id: "preview",
            moduleId: "preview-module",
            name: "Preview Set",
            description: nil,
            translationId: "kjv",
            created: Int(Date().timeIntervalSince1970),
            lastModified: Int(Date().timeIntervalSince1970)
        ))
    }
}
