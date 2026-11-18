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
    @State private var themes: [String: HighlightTheme] = [:] // key: "colorHex_style"
    @State private var colorForThemeEdit: HighlightColor?
    @State private var showingThemeEditor = false

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
                        loadThemes() // Reload themes when style changes
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
                        onReorder: { saveColors() },
                        themeName: themeNameFor(color: color),
                        onEditTheme: highlightManager.activeSetId != nil ? {
                            colorForThemeEdit = color
                            showingThemeEditor = true
                        } : nil
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
            loadThemes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadColors()
            loadThemes()
        }
        .sheet(isPresented: $showingThemeEditor) {
            if let color = colorForThemeEdit, let setId = highlightManager.activeSetId {
                let existingTheme = themeFor(color: color)
                HighlightThemeEditorSheet(
                    setId: setId,
                    color: color,
                    style: highlightManager.selectedStyle,
                    existingTheme: existingTheme
                ) { theme in
                    try? ModuleDatabase.shared.saveHighlightTheme(theme)
                    loadThemes()
                    scheduleSyncForActiveSet()
                }
            }
        }
    }

    private func loadColors() {
        colors = HighlightColorManager.shared.getColors()
    }

    private func loadThemes() {
        guard let setId = highlightManager.activeSetId else {
            themes = [:]
            return
        }

        if let setThemes = try? ModuleDatabase.shared.getHighlightThemes(setId: setId) {
            var themeMap: [String: HighlightTheme] = [:]
            for theme in setThemes {
                let key = "\(theme.color)_\(theme.style)"
                themeMap[key] = theme
            }
            themes = themeMap
        }
    }

    private func themeFor(color: HighlightColor) -> HighlightTheme? {
        let key = "\(color.hex.uppercased())_\(highlightManager.selectedStyle.rawValue)"
        return themes[key]
    }

    private func themeNameFor(color: HighlightColor) -> String? {
        themeFor(color: color)?.name
    }

    private func scheduleSyncForActiveSet() {
        guard let setId = highlightManager.activeSetId,
              let set = try? ModuleDatabase.shared.getHighlightSet(id: setId) else { return }
        Task {
            try? await ModuleSyncManager.shared.exportModule(id: set.moduleId)
        }
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
    var themeName: String? = nil
    var onEditTheme: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            ColorSwatchButton(
                color: color,
                isSelected: isSelected,
                action: onSelect
            )
            .opacity(draggingColor == color ? 0.5 : 1.0)

            // Show theme name if available
            if let name = themeName {
                Text(name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 40)
            }
        }
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
            if let editTheme = onEditTheme {
                Button {
                    editTheme()
                } label: {
                    Label(themeName != nil ? "Edit Theme" : "Add Theme", systemImage: "tag")
                }
            }

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
    @State private var themes: [String: HighlightTheme] = [:] // key: "colorHex_style"

    /// Callback when user wants to edit a theme (color, style, existing theme if any)
    var onEditTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)? = nil

    /// Maximum colors to show inline before showing +N button
    private let maxInlineColors = 6

    var body: some View {
        VStack(spacing: 0) {
            // Style selector row. Each style is named under its icon: the
            // three underlines differ only in their dash, which an icon alone
            // can't carry at this size.
            HStack(spacing: 4) {
                ForEach(HighlightStyle.allCases, id: \.rawValue) { style in
                    let isSelected = highlightManager.selectedStyle == style
                    Button {
                        highlightManager.selectStyle(style)
                        loadThemes()
                    } label: {
                        VStack(spacing: 3) {
                            style.icon
                                .font(.system(size: 17, weight: .medium))
                                .frame(height: 22)
                            Text(style.displayName)
                                .font(.caption2.weight(isSelected ? .semibold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        // Selected in the text's own colour, a firm fill and
                        // outline: no second accent beside the colour's ring.
                        .background(
                            RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.primary : LampTheme.caption)
                    .accessibilityLabel(style.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Color selector row
            HStack(spacing: 10) {
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
                                .frame(width: 32, height: 32)
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
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
        .popover(isPresented: $showingFullPicker) {
            ColorsOnlyPopover(onSelect: { color in
                highlightManager.selectColor(color)
                showingFullPicker = false
            })
        }
        .onAppear {
            loadColors()
            loadThemes()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadColors()
            loadThemes()
        }
    }

    @ViewBuilder
    private func inlineColorSwatch(color: HighlightColor) -> some View {
        VStack(spacing: 2) {
            Button {
                highlightManager.selectColor(color)
            } label: {
                // The chosen colour wears a ring set a little off it, so the
                // swatch keeps its own colour and size. Each swatch is drawn
                // as the page draws the highlight, a wash with the full colour
                // round its edge, so what is picked is what appears.
                Circle()
                    .fill(Color(uiColor: .lampSwatchFill(color.uiColor)))
                    .background(Circle().fill(LampTheme.readerBackground))
                    .overlay(Circle().strokeBorder(color.color, lineWidth: 2.5))
                    .frame(width: 26, height: 26)
                    .padding(3)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 2)
                            .opacity(highlightManager.selectedColor == color ? 1 : 0)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            // Show theme name if available
            if let name = themeNameFor(color: color) {
                Text(name)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 32)
            }
        }
        .contextMenu {
            if let editTheme = onEditTheme, highlightManager.activeSetId != nil {
                Button {
                    editTheme(color, highlightManager.selectedStyle, themeFor(color: color))
                } label: {
                    Label(themeNameFor(color: color) != nil ? "Edit Theme" : "Add Theme", systemImage: "tag")
                }
            }

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

    private func loadThemes() {
        guard let setId = highlightManager.activeSetId else {
            themes = [:]
            return
        }

        if let setThemes = try? ModuleDatabase.shared.getHighlightThemes(setId: setId) {
            var themeMap: [String: HighlightTheme] = [:]
            for theme in setThemes {
                let key = "\(theme.color)_\(theme.style)"
                themeMap[key] = theme
            }
            themes = themeMap
        }
    }

    private func themeFor(color: HighlightColor) -> HighlightTheme? {
        let key = "\(color.hex.uppercased())_\(highlightManager.selectedStyle.rawValue)"
        return themes[key]
    }

    private func themeNameFor(color: HighlightColor) -> String? {
        themeFor(color: color)?.name
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
            .frame(width: 32, height: 32)
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

// MARK: - Mark Swatch

/// A highlight's mark drawn small, for menus, which take an image in its
/// own colours and nothing else: a filled band for a highlight, a line in
/// its pattern for an underline.
enum HighlightMarkSwatch {
    static func image(color: HighlightColor, style: HighlightStyle) -> UIImage {
        let size = CGSize(width: 22, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let ink = color.uiColor
            switch style {
            case .highlight:
                ink.setFill()
                UIBezierPath(roundedRect: CGRect(x: 1, y: 2, width: 20, height: 12), cornerRadius: 3).fill()
            case .underlineSolid, .underlineDashed, .underlineDotted:
                let line = UIBezierPath()
                line.move(to: CGPoint(x: 2, y: 13))
                line.addLine(to: CGPoint(x: 20, y: 13))
                line.lineWidth = 2.5
                switch style {
                case .underlineDashed:
                    line.setLineDash([4, 2.5], count: 2, phase: 0)
                case .underlineDotted:
                    line.lineCapStyle = .round
                    line.setLineDash([0, 4], count: 2, phase: 0)
                default:
                    break
                }
                ink.setStroke()
                line.stroke()
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Highlight Panel

/// The highlight panel's state, for the words chosen or the highlight
/// tapped: a style, colour or theme chosen applies at once, to the set shown
/// when the words were chosen, and the panel then shows what it made.
@MainActor
final class HighlightPanelModel: ObservableObject {
    let spans: [HighlightSpan]
    /// The words, as the reader shows them.
    let text: String
    let citation: String
    @Published private(set) var target: HighlightManager.Target

    /// The highlights shown: those the words had, then those made here.
    @Published private(set) var current: [HighlightEntry]
    @Published private(set) var color: HighlightColor
    @Published private(set) var style: HighlightStyle
    @Published private(set) var colors: [HighlightColor]
    /// The set's themes, the ones used last first.
    @Published private(set) var themes: [HighlightTheme]
    private var madeHere = false

    var onAddNote: () -> Void = {}
    var onSearch: (() -> Void)?
    var onLookUp: (() -> Void)?
    /// Removes what the words had (`current` before anything was made).
    var onRemove: () -> Void = {}
    var onNameTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)?
    /// Closes the panel, then runs what follows.
    var dismiss: (_ then: (() -> Void)?) -> Void = { then in then?() }

    init(spans: [HighlightSpan], target: HighlightManager.Target, text: String, citation: String, current: [HighlightEntry]) {
        self.spans = spans
        self.target = target
        self.text = text
        self.citation = citation
        self.current = current
        let shown = current.last
        color = shown?.highlightColor ?? HighlightManager.shared.selectedColor
        style = shown?.highlightStyle ?? HighlightManager.shared.selectedStyle
        colors = HighlightColorManager.shared.getColors()
        themes = Self.themes(setId: shown?.setId ?? target.setId)
    }

    /// Whether what's shown has one mark, which the panel then ticks.
    var isMarked: Bool {
        guard let first = current.first else { return false }
        return current.allSatisfy { $0.highlightColor == first.highlightColor && $0.highlightStyle == first.highlightStyle }
    }

    /// The theme that names the mark shown, if one does.
    var theme: HighlightTheme? {
        guard isMarked else { return nil }
        return themes.first { $0.highlightColor == color && $0.highlightStyle == style }
    }

    func apply(color: HighlightColor, style: HighlightStyle) {
        do {
            let manager = HighlightManager.shared
            manager.highlightsHidden = false
            current = try manager.mark(spans, style: style, color: color, to: target)
            madeHere = true
            // A set made for the first highlight takes the rest.
            if target.setId == nil, let setId = current.first?.setId {
                target = HighlightManager.Target(setId: setId, translationId: target.translationId)
                themes = Self.themes(setId: setId)
            }
            self.color = color
            self.style = style
            manager.selectColor(color)
            manager.selectStyle(style)
        } catch {
            print("[Highlight] Error highlighting: \(error)")
        }
    }

    /// A theme sets colour and style together.
    func apply(_ theme: HighlightTheme) {
        apply(color: theme.highlightColor, style: theme.highlightStyle)
        Self.recordRecent(theme)
        themes = Self.themes(setId: theme.setId)
    }

    func addColor(_ color: HighlightColor) {
        HighlightColorManager.shared.addColor(color)
        colors = HighlightColorManager.shared.getColors()
        apply(color: color, style: style)
    }

    func removeFromPalette(_ color: HighlightColor) {
        HighlightColorManager.shared.removeColor(color)
        colors = HighlightColorManager.shared.getColors()
    }

    /// The set new marks go to from here on.
    func useSet(_ setId: String) {
        HighlightManager.shared.selectSet(setId)
        target = HighlightManager.Target(setId: setId, translationId: target.translationId)
        themes = Self.themes(setId: setId)
    }

    func remove() {
        if madeHere {
            for highlight in current {
                try? HighlightManager.shared.removeHighlight(highlight)
            }
        } else {
            onRemove()
        }
        current = []
        dismiss(nil)
    }

    /// Whether a mark can be named: in a set, which a translation without
    /// highlights doesn't have until one is made.
    var canNameTheme: Bool { onNameTheme != nil && target.setId != nil }

    func nameTheme(color: HighlightColor, style: HighlightStyle) {
        guard let onNameTheme, canNameTheme else { return }
        let existing = themes.first { $0.highlightColor == color && $0.highlightStyle == style }
        dismiss { onNameTheme(color, style, existing) }
    }

    // MARK: Recent themes

    /// The themes used last, on this device only, as the Mac keeps its own.
    static let recentKey = "reader.recentHighlightThemes"

    private static func recentKeyOf(_ theme: HighlightTheme) -> String {
        "\(theme.highlightColor.hex)/\(theme.style)"
    }

    static func recordRecent(_ theme: HighlightTheme) {
        var recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        recent.removeAll { $0 == recentKeyOf(theme) }
        recent.insert(recentKeyOf(theme), at: 0)
        UserDefaults.standard.set(Array(recent.prefix(40)), forKey: recentKey)
    }

    static func themes(setId: String?) -> [HighlightTheme] {
        guard let setId, let themes = try? ModuleDatabase.shared.getHighlightThemes(setId: setId) else { return [] }
        let recent = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        func place(_ theme: HighlightTheme) -> Int { recent.firstIndex(of: recentKeyOf(theme)) ?? Int.max }
        return themes.sorted {
            (place($0), $0.name.localizedLowercase) < (place($1), $1.name.localizedLowercase)
        }
    }
}

/// The highlight panel by the words: the four styles drawn in the colour,
/// the palette, the set's themes, and what else the words can be used for.
/// Touch's form of the Mac's bar.
struct HighlightPanel: View {
    @ObservedObject var model: HighlightPanelModel
    @ObservedObject private var manager = HighlightManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            styleRow
            colorRow
            if !model.themes.isEmpty || model.canNameTheme {
                themesPill
            }
            Divider()
            actionRow
        }
        .padding(16)
        .frame(width: 304)
    }

    private var styleRow: some View {
        HStack(spacing: 8) {
            ForEach(HighlightStyle.allCases, id: \.self) { style in
                Button {
                    model.apply(color: model.color, style: style)
                } label: {
                    HighlightStyleSample(color: model.color, style: style)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            if model.isMarked && model.style == style {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.displayName)
                .accessibilityAddTraits(model.isMarked && model.style == style ? .isSelected : [])
            }
        }
    }

    private var colorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.colors) { color in
                    let isTicked = model.isMarked && model.color == color
                    Button {
                        model.apply(color: color, style: model.style)
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 32, height: 32)
                            .overlay {
                                if isTicked {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.name)
                    .accessibilityAddTraits(isTicked ? .isSelected : [])
                    .contextMenu {
                        if model.canNameTheme {
                            Button {
                                model.nameTheme(color: color, style: model.style)
                            } label: {
                                Label("Name This Mark…", systemImage: "tag")
                            }
                        }
                        if model.colors.count > 1 {
                            Button(role: .destructive) {
                                model.removeFromPalette(color)
                            } label: {
                                Label("Remove from Palette", systemImage: "minus.circle")
                            }
                        }
                    }
                }
                AddCustomColorButton { color in
                    model.addColor(color)
                }
                .frame(width: 32, height: 32)
                .scaleEffect(32.0 / 36.0)
            }
            .padding(.vertical, 2)
        }
    }

    private var themesPill: some View {
        Menu {
            ForEach(model.themes) { theme in
                Button {
                    model.apply(theme)
                } label: {
                    Label {
                        Text(theme.name)
                    } icon: {
                        Image(uiImage: HighlightMarkSwatch.image(color: theme.highlightColor, style: theme.highlightStyle))
                    }
                }
            }
            if model.canNameTheme {
                if !model.themes.isEmpty { Divider() }
                Button {
                    model.nameTheme(color: model.color, style: model.style)
                } label: {
                    Label(model.theme == nil ? "Name This Mark…" : "Edit Theme…", systemImage: "tag")
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let theme = model.theme {
                    Image(uiImage: HighlightMarkSwatch.image(color: theme.highlightColor, style: theme.highlightStyle))
                    Text(theme.name)
                        .lineLimit(1)
                } else {
                    Image(systemName: "tag")
                    Text("Themes")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .tint(.primary)
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            panelAction("Add Note", systemImage: "note.text.badge.plus") {
                model.dismiss { model.onAddNote() }
            }
            panelAction("Copy as Citation", systemImage: "quote.opening") {
                UIPasteboard.general.string = model.citation
                model.dismiss(nil)
            }
            Menu {
                if let lookUp = model.onLookUp {
                    Button {
                        model.dismiss { lookUp() }
                    } label: {
                        Label("Look Up", systemImage: "character.book.closed")
                    }
                }
                if let search = model.onSearch {
                    Button {
                        model.dismiss { search() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                Button {
                    UIPasteboard.general.string = model.text
                    model.dismiss(nil)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if manager.availableSets.count > 1 {
                    Divider()
                    Picker(selection: Binding(
                        get: { model.target.setId ?? "" },
                        set: { model.useSet($0) }
                    )) {
                        ForEach(manager.availableSets, id: \.id) { set in
                            Text(set.name).tag(set.id)
                        }
                    } label: {
                        Label("Highlight Set", systemImage: "folder")
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                panelActionLabel("More", systemImage: "ellipsis.circle")
            }
            .tint(.primary)
            // The words' highlight, which the panel shows, can go too.
            if !model.current.isEmpty {
                panelAction("Remove", systemImage: "trash") {
                    model.remove()
                }
                .foregroundStyle(.red)
            }
        }
    }

    private func panelAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            panelActionLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func panelActionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
            // Two lines where four share the row, not cut short
            Text(title)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// "Aa" drawn as a highlight in a style draws it: on a band of the colour,
/// or over a line of it, as thick as the reader's.
struct HighlightStyleSample: View {
    let color: HighlightColor
    let style: HighlightStyle

    var body: some View {
        let sample = Text("Aa").font(.system(size: 17, weight: .medium, design: .serif))
        switch style {
        case .highlight:
            sample
                .padding(.horizontal, 3)
                .background(color.readerFill, in: RoundedRectangle(cornerRadius: 3))
        case .underlineSolid, .underlineDashed, .underlineDotted:
            sample
                .overlay(alignment: .bottom) {
                    style.underlineShape(color: color.color)
                        .frame(width: 24, height: 2.5)
                        .offset(y: 2)
                }
        }
    }
}
