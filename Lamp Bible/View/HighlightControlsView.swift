//
//  HighlightControlsView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Highlight Color Button

/// Button to select highlight color and style (appears in reader toolbar)
struct HighlightModeButton: View {
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var showingColorPicker = false

    var body: some View {
        Button(action: {
            showingColorPicker = true
        }) {
            Image(systemName: "highlighter")
                .foregroundColor(highlightManager.selectedColor.color)
        }
        .popover(isPresented: $showingColorPicker) {
            HighlightColorPickerView(onSelect: { color in
                highlightManager.selectColor(color)
                showingColorPicker = false
            })
        }
    }
}

// MARK: - Color Picker View

/// Popover view for selecting highlight color and style
struct HighlightColorPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var colors: [HighlightColor] = []
    @State private var draggingColor: HighlightColor?

    let onSelect: (HighlightColor) -> Void

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        VStack(spacing: 16) {
            // Style selector
            HStack(spacing: 8) {
                ForEach(HighlightStyle.allCases, id: \.rawValue) { style in
                    Button(action: {
                        highlightManager.selectStyle(style)
                    }) {
                        VStack(spacing: 4) {
                            style.icon
                                .font(.title2)
                                .frame(height: 26)
                            Text(style.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundColor(highlightManager.selectedStyle == style ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(highlightManager.selectedStyle == style ?
                                      Color.secondary.opacity(0.2) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)

            Divider()

            // Unified colors grid with drag-to-reorder
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(colors) { color in
                    DraggableColorSwatch(
                        color: color,
                        isSelected: highlightManager.selectedColor == color,
                        draggingColor: $draggingColor,
                        colors: $colors,
                        onSelect: { onSelect(color) },
                        onDelete: { deleteColor(color) },
                        onReorder: { saveColors() }
                    )
                }

                // Add custom color button
                AddCustomColorButton { newColor in
                    addColor(newColor)
                    onSelect(newColor)
                }
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 295)
        .presentationCompactAdaptation(.popover)
        .onAppear {
            loadColors()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadColors()
        }
    }

    private func loadColors() {
        colors = HighlightColorManager.shared.getColors()
    }

    private func addColor(_ color: HighlightColor) {
        HighlightColorManager.shared.addColor(color)
        loadColors()
    }

    private func deleteColor(_ color: HighlightColor) {
        HighlightColorManager.shared.removeColor(color)
        loadColors()
    }

    private func saveColors() {
        HighlightColorManager.shared.reorderColors(colors)
    }
}

// MARK: - Colors Only Popover

/// Simple popover showing only colors (no style selector) for +N button
struct ColorsOnlyPopover: View {
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var colors: [HighlightColor] = []
    @State private var draggingColor: HighlightColor?

    let onSelect: (HighlightColor) -> Void

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(colors) { color in
                    DraggableColorSwatch(
                        color: color,
                        isSelected: highlightManager.selectedColor == color,
                        draggingColor: $draggingColor,
                        colors: $colors,
                        onSelect: { onSelect(color) },
                        onDelete: { deleteColor(color) },
                        onReorder: { saveColors() }
                    )
                }

                // Add custom color button
                AddCustomColorButton { newColor in
                    addColor(newColor)
                    onSelect(newColor)
                }
            }
        }
        .padding()
        .frame(minWidth: 250)
        .presentationCompactAdaptation(.popover)
        .onAppear {
            loadColors()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadColors()
        }
    }

    private func loadColors() {
        colors = HighlightColorManager.shared.getColors()
    }

    private func addColor(_ color: HighlightColor) {
        HighlightColorManager.shared.addColor(color)
        loadColors()
    }

    private func deleteColor(_ color: HighlightColor) {
        HighlightColorManager.shared.removeColor(color)
        loadColors()
    }

    private func saveColors() {
        HighlightColorManager.shared.reorderColors(colors)
    }
}

// MARK: - Draggable Color Swatch

/// Color swatch with drag-to-reorder support
struct DraggableColorSwatch: View {
    let color: HighlightColor
    let isSelected: Bool
    @Binding var draggingColor: HighlightColor?
    @Binding var colors: [HighlightColor]
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onReorder: () -> Void

    var body: some View {
        ColorSwatchButton(
            color: color,
            isSelected: isSelected,
            action: onSelect
        )
        .opacity(draggingColor == color ? 0.5 : 1.0)
        .onDrag {
            draggingColor = color
            return NSItemProvider(object: color.hex as NSString)
        }
        .onDrop(of: [.text], delegate: ColorDropDelegate(
            color: color,
            colors: $colors,
            draggingColor: $draggingColor,
            onReorder: onReorder
        ))
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

// MARK: - Color Drop Delegate

/// Handles drop operations for color reordering
struct ColorDropDelegate: DropDelegate {
    let color: HighlightColor
    @Binding var colors: [HighlightColor]
    @Binding var draggingColor: HighlightColor?
    let onReorder: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingColor = nil
        onReorder()
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingColor,
              dragging != color,
              let fromIndex = colors.firstIndex(where: { $0.hex == dragging.hex }),
              let toIndex = colors.firstIndex(where: { $0.hex == color.hex }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            colors.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Add Custom Color Button

/// A "+" button that opens the system color picker directly
struct AddCustomColorButton: View {
    @State private var selectedColor: Color = .orange

    let onAdd: (HighlightColor) -> Void

    var body: some View {
        ColorPicker("", selection: $selectedColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 36, height: 36)
            .background(
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "plus")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            )
            .onChange(of: selectedColor) { _, newColor in
                let color = HighlightColor(color: newColor)
                onAdd(color)
            }
    }
}

// MARK: - Color Swatch Button

/// Individual color swatch button
struct ColorSwatchButton: View {
    let color: HighlightColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.color)
                    .frame(width: 36, height: 36)

                if isSelected {
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

// MARK: - Inline Highlight Picker

/// Compact highlight picker for embedding in menus
struct InlineHighlightPicker: View {
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var colors: [HighlightColor] = []
    @State private var showingFullPicker = false

    /// Maximum colors to show inline before showing +N button
    private let maxInlineColors = 6

    var body: some View {
        VStack(spacing: 0) {
            // Style selector row
            HStack(spacing: 4) {
                ForEach(HighlightStyle.allCases, id: \.rawValue) { style in
                    Button {
                        highlightManager.selectStyle(style)
                    } label: {
                        style.icon
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(highlightManager.selectedStyle == style ?
                                          Color.secondary.opacity(0.2) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(highlightManager.selectedStyle == style ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            // Color selector row
            HStack(spacing: 8) {
                // Show colors up to max
                ForEach(colors.prefix(maxInlineColors)) { color in
                    inlineColorSwatch(color: color)
                }

                // More button if there are additional colors
                if colors.count > maxInlineColors {
                    Button {
                        showingFullPicker = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 28, height: 28)
                            Text("+\(colors.count - maxInlineColors)")
                                .font(.caption2.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Add custom color button
                InlineAddColorButton { newColor in
                    HighlightColorManager.shared.addColor(newColor)
                    loadColors()
                    highlightManager.selectColor(newColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .popover(isPresented: $showingFullPicker) {
            ColorsOnlyPopover(onSelect: { color in
                highlightManager.selectColor(color)
                showingFullPicker = false
            })
        }
        .onAppear {
            loadColors()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadColors()
        }
    }

    @ViewBuilder
    private func inlineColorSwatch(color: HighlightColor) -> some View {
        Button {
            highlightManager.selectColor(color)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2)
                        .opacity(highlightManager.selectedColor == color ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                HighlightColorManager.shared.removeColor(color)
                loadColors()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func loadColors() {
        colors = HighlightColorManager.shared.getColors()
    }
}

// MARK: - Inline Add Color Button

/// Small "+" button for inline picker that opens the system color picker directly
struct InlineAddColorButton: View {
    @State private var selectedColor: Color = .orange

    let onAdd: (HighlightColor) -> Void

    var body: some View {
        ColorPicker("", selection: $selectedColor, supportsOpacity: false)
            .labelsHidden()
            .frame(width: 28, height: 28)
            .background(
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .onChange(of: selectedColor) { _, newColor in
                let color = HighlightColor(color: newColor)
                onAdd(color)
            }
    }
}

// MARK: - Highlight Color Manager

/// Manages the ordered list of highlight colors
class HighlightColorManager {
    static let shared = HighlightColorManager()

    private init() {}

    /// Get the current ordered list of colors
    func getColors() -> [HighlightColor] {
        let settings = UserDatabase.shared.getSettings()

        // If highlightColorOrder is set, use it
        if !settings.highlightColorOrder.isEmpty {
            let hexValues = settings.highlightColorOrder.components(separatedBy: ",")
            return hexValues.map { HighlightColor(hex: $0) }
        }

        // Otherwise, use defaults + any legacy custom colors
        var colors = HighlightColor.defaultColors
        if !settings.customHighlightColors.isEmpty {
            let customHexValues = settings.customHighlightColors.components(separatedBy: ",")
            colors.append(contentsOf: customHexValues.map { HighlightColor(hex: $0) })
        }
        return colors
    }

    /// Add a color to the end of the list
    func addColor(_ color: HighlightColor) {
        var colors = getColors()
        // Don't add duplicates
        guard !colors.contains(where: { $0.hex == color.hex }) else { return }
        colors.append(color)
        saveColors(colors)
    }

    /// Remove a color from the list
    func removeColor(_ color: HighlightColor) {
        var colors = getColors()
        colors.removeAll { $0.hex == color.hex }
        // Ensure at least one color remains
        if colors.isEmpty {
            colors = [.yellow]
        }
        saveColors(colors)
    }

    /// Reorder colors
    func reorderColors(_ colors: [HighlightColor]) {
        saveColors(colors)
    }

    private func saveColors(_ colors: [HighlightColor]) {
        let hexString = colors.map { $0.hex }.joined(separator: ",")
        try? UserDatabase.shared.updateSettings { settings in
            settings.highlightColorOrder = hexString
        }
    }
}

// MARK: - Highlight Toolbar

/// Complete highlight toolbar (for embedding in reader toolbar)
struct HighlightToolbar: View {
    @ObservedObject var highlightManager = HighlightManager.shared
    @State private var showingSetPicker = false

    var body: some View {
        HStack(spacing: 16) {
            // Highlight mode toggle
            HighlightModeButton()

            // Set picker button
            if highlightManager.isHighlightModeActive {
                Button(action: { showingSetPicker = true }) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                }
                .sheet(isPresented: $showingSetPicker) {
                    HighlightSetPickerView()
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        InlineHighlightPicker()
            .padding(.horizontal)

        Divider()

        HighlightColorPickerView(onSelect: { color in
            print("Selected: \(color.hex)")
        })
    }
    .padding()
    .background(Color(UIColor.systemGroupedBackground))
}
