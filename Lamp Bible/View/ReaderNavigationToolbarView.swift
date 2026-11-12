//
//  ReaderNavigationToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI
import UIKit
import LampModuleKit

struct ReaderNavigationToolbarView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// The More menu is showing its view settings page.
    @State private var showingViewOptions = false
    /// Room the window's own controls take at the bar's ends, in an iPad
    /// window that has them.
    @State private var windowControls = WindowControlsInsets()
    @Binding var userSettings: UserSettings
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var translationId: String
    @Binding var translationAbbreviation: String
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    @Binding var showingOptionsMenu: Bool
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    /// Serif or sans for scripture, under the key the Mac reader uses.
    @AppStorage("reader.typeface") private var readerTypeface = LampProseTypeface.serif.rawValue
    @AppStorage(LampTextScale.readerLineSpacingKey) private var readerLineSpacing = LampTextScale.readerLineSpacing.defaultValue
    let readerDismiss: DismissAction
    var onHideToolbars: (() -> Void)? = nil

    /// The toolbars are collapsed: the bar keeps only the title, shrunk to one
    /// line, and tapping it brings the rest back.
    var isCompact: Bool = false
    var onExpand: (() -> Void)? = nil
    /// An extra control beside the options button, such as read-aloud in plan
    /// mode. It goes with the other controls when the bar collapses.
    var trailingAccessory: AnyView? = nil

    // Horizontal split integration
    var isHorizontalSplit: Bool = false
    @Binding var toolPanelMode: ToolPanelMode
    var toolDisplayName: String = ""
    @Binding var isScrollLinked: Bool
    @Binding var toolFontSize: Int
    var onHideToolPanel: (() -> Void)? = nil
    var onToggleSplitOrientation: (() -> Void)? = nil

    // Tool module selection (shared with ToolPanelView via AppStorage)
    @AppStorage("selectedNotesModuleId") private var notesModuleId: String = "notes"
    @AppStorage("selectedCommentarySeries") private var selectedCommentarySeries: String = ""
    @AppStorage("selectedDevotionalsModuleId") private var devotionalsModuleId: String = "devotionals"

    // Available modules (passed from parent)
    var notesModules: [Module] = []
    var commentarySeries: [String] = []
    var devotionalsModules: [Module] = []

    // Theme editing callback (to present sheet from parent view)
    var onEditTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)? = nil

    /// Read aloud stop action, offered only while something is being read. Play and
    /// pause live on their own toolbar button; stop is rare enough to sit in here.

    init(
        userSettings: Binding<UserSettings>,
        readingMetaData: Binding<[ReadingMetaData]?>,
        translationId: Binding<String>,
        translationAbbreviation: Binding<String>,
        currentVerseId: Binding<Int>,
        showingBookPicker: Binding<Bool>,
        showingOptionsMenu: Binding<Bool>,
        readerDismiss: DismissAction,
        onHideToolbars: (() -> Void)? = nil,
        isCompact: Bool = false,
        onExpand: (() -> Void)? = nil,
        trailingAccessory: AnyView? = nil,
        isHorizontalSplit: Bool = false,
        toolPanelMode: Binding<ToolPanelMode> = .constant(.commentary),
        toolDisplayName: String = "",
        isScrollLinked: Binding<Bool> = .constant(true),
        toolFontSize: Binding<Int> = .constant(16),
        onHideToolPanel: (() -> Void)? = nil,
        onToggleSplitOrientation: (() -> Void)? = nil,
        notesModules: [Module] = [],
        commentarySeries: [String] = [],
        devotionalsModules: [Module] = [],
        onEditTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)? = nil
    ) {
        _userSettings = userSettings
        _readingMetaData = readingMetaData
        _translationId = translationId
        _translationAbbreviation = translationAbbreviation
        _currentVerseId = currentVerseId
        _showingBookPicker = showingBookPicker
        _showingOptionsMenu = showingOptionsMenu
        self.readerDismiss = readerDismiss
        self.onHideToolbars = onHideToolbars
        self.isCompact = isCompact
        self.onExpand = onExpand
        self.trailingAccessory = trailingAccessory
        self.isHorizontalSplit = isHorizontalSplit
        _toolPanelMode = toolPanelMode
        self.toolDisplayName = toolDisplayName
        _isScrollLinked = isScrollLinked
        _toolFontSize = toolFontSize
        self.onHideToolPanel = onHideToolPanel
        self.onToggleSplitOrientation = onToggleSplitOrientation
        self.notesModules = notesModules
        self.commentarySeries = commentarySeries
        self.devotionalsModules = devotionalsModules
        self.onEditTheme = onEditTheme
    }

    /// A system navigation bar can't get any shorter, so the reader draws its
    /// own. Collapsed it is one slim line, and it changes shape in place between
    /// the two rather than one header leaving and another arriving.
    static let expandedHeight: CGFloat = 54
    static let compactHeight: CGFloat = 38

    var body: some View {
        if #available(iOS 26.0, *) {
            // One container, so the controls' glass morphs as the bar collapses
            // and expands rather than each piece appearing on its own.
            GlassEffectContainer(spacing: 8) { bar }
        } else {
            bar
        }
    }

    private var bar: some View {
        ZStack {
            HStack(spacing: 8) {
                if !isCompact {
                    Button {
                        readerDismiss()
                    } label: {
                        headerIcon("arrow.backward")
                    }
                    .buttonStyle(.plain)
                    .modifier(HeaderGlass(shape: Circle()))
                }
                Spacer(minLength: 0)
                if !isCompact {
                    if let trailingAccessory {
                        trailingAccessory
                            .buttonStyle(.plain)
                            .frame(width: 44, height: 44)
                            .modifier(HeaderGlass(shape: Circle()))
                    }
                    Button {
                        showingOptionsMenu = true
                    } label: {
                        headerIcon("ellipsis")
                    }
                    .buttonStyle(.plain)
                    .modifier(HeaderGlass(shape: Circle()))
                    .popover(isPresented: $showingOptionsMenu) {
                        // Carried in explicitly: a popover left open across a
                        // switch to dark kept drawing itself light.
                        optionsMenuContent
                            .environment(\.colorScheme, colorScheme)
                            .preferredColorScheme(colorScheme)
                    }
                }
            }
            // The back button, first in the bar, sat under the window's
            // close, minimise and resize buttons; they keep their corner.
            .padding(.leading, windowControls.leading)
            .padding(.trailing, windowControls.trailing)
            title
                // Clear of the buttons either side, and of the window's
                // controls, by the same each side so it stays centred.
                .padding(.horizontal, isCompact ? 0 : (trailingAccessory == nil ? 52 : 104))
                .padding(.horizontal, windowControls.widest)
        }
        .padding(.horizontal, 16)
        .frame(height: isCompact ? Self.compactHeight : Self.expandedHeight)
        .background(WindowControlsInsetReader(insets: $windowControls))
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    @ViewBuilder
    private var title: some View {
        let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)
        let book = try? BundledModuleDatabase.shared.getBook(id: currentBook)
        let place = (book?.name ?? "") + " \(currentChapter)"

        if isHorizontalSplit && !isCompact {
            // The passage and the tool, in one capsule. The passage opens the
            // book picker straight away, as it does in one column; the tool
            // is the menu of tools.
            HStack(spacing: 0) {
                Button {
                    showingBookPicker = true
                } label: {
                    VStack(spacing: 0) {
                        Text(translationAbbreviation).bold().font(.system(size: 14))
                        Text(place).font(.caption2)
                    }
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // A reading plan's passage is set by the plan.
                .disabled(readingMetaData != nil)

                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 24)

                Menu {
                    toolMenuContent
                } label: {
                    VStack(spacing: 0) {
                        Text(toolPanelMode.rawValue).bold().font(.system(size: 14))
                        Text(toolDisplayName).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.leading, 8)
                    .padding(.trailing, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
            .modifier(HeaderGlass(shape: Capsule()))
        } else {
            // Translation + Book - opens the book picker. Collapsed, the same
            // button shrinks to one line and brings the toolbars back; staying
            // one button lets its glass resize in place rather than swap for
            // another.
            Button {
                if isCompact {
                    onExpand?()
                } else if readingMetaData == nil {
                    showingBookPicker = true
                }
            } label: {
                Group {
                    if isCompact {
                        HStack(spacing: 4) {
                            Text(translationAbbreviation).bold()
                            Text("· " + place)
                            // Beside a tool panel, what it shows too.
                            if isHorizontalSplit {
                                Text("· " + toolDisplayName)
                            }
                        }
                        .font(.caption)
                    } else {
                        VStack(spacing: 0) {
                            Text(translationAbbreviation).bold().font(.system(size: 14))
                            Text(place).font(.caption2)
                        }
                    }
                }
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, isCompact ? 12 : 16)
                .frame(height: isCompact ? 30 : 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isCompact && readingMetaData != nil)
            .modifier(HeaderGlass(shape: Capsule()))
            .accessibilityHint(isCompact ? "Shows the toolbars" : "")
        }
    }

    /// The tools a panel beside the reader can show, for the title's menu.
    @ViewBuilder
    private var toolMenuContent: some View {
        // Tool section
        Section("Tools") {
            // Notes modules
            if !notesModules.isEmpty {
                ForEach(notesModules, id: \.id) { module in
                    Button {
                        notesModuleId = module.id
                        toolPanelMode = .notes
                    } label: {
                        if toolPanelMode == .notes && notesModuleId == module.id {
                            Label(module.name, systemImage: "checkmark")
                        } else {
                            Text(module.name)
                        }
                    }
                }
            }

            // Commentary series
            if !commentarySeries.isEmpty {
                Divider()
                ForEach(commentarySeries, id: \.self) { series in
                    Button {
                        selectedCommentarySeries = series
                        toolPanelMode = .commentary
                    } label: {
                        if toolPanelMode == .commentary && selectedCommentarySeries == series {
                            Label(series, systemImage: "checkmark")
                        } else {
                            Text(series)
                        }
                    }
                }
            }

            // Devotionals modules
            if !devotionalsModules.isEmpty {
                Divider()
                ForEach(devotionalsModules, id: \.id) { module in
                    Button {
                        devotionalsModuleId = module.id
                        toolPanelMode = .devotionals
                    } label: {
                        if toolPanelMode == .devotionals && devotionalsModuleId == module.id {
                            Label(module.name, systemImage: "checkmark")
                        } else {
                            Text(module.name)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    /// The menu opens on highlighting, the task it is mostly used for; the
    /// reader's view settings are a page of their own behind one row, so the
    /// menu covers less of the passage and doesn't mix the two.
    private var optionsMenuContent: some View {
        Group {
            if showingViewOptions {
                viewOptionsPage
            } else {
                highlightsPage
            }
        }
        .font(.body)
        .fontWeight(.regular)
        .padding(12)
        .frame(width: 320)
        .background(LampTheme.menuBackground)
        .presentationCompactAdaptation(.popover)
        .animation(.easeInOut(duration: 0.2), value: showingViewOptions)
        .onDisappear { showingViewOptions = false }
    }

    private var highlightsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Highlights: style, colour, the set they go in, and showing them.
            menuCaption("Highlights")
            highlightsSectionContent

            // Showing the tools and hiding the toolbars on the first page,
            // one tap away: behind View Options they were hard to find.
            VStack(spacing: 0) {
                if onHideToolbars != nil || !isHorizontalSplit {
                    chromeTiles
                        .padding(8)
                    Divider().padding(.horizontal, 14)
                }
                menuRow("View Options", systemImage: "textformat.size", showsChevron: true) {
                    showingViewOptions = true
                }
            }
            .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
            .padding(.top, 6)
        }
    }

    private var chromeTiles: some View {
        HStack(spacing: 8) {
            if let hideToolbars = onHideToolbars {
                menuTile("Hide Toolbars", systemImage: "eye.slash") {
                    showingOptionsMenu = false
                    hideToolbars()
                }
            }
            if !isHorizontalSplit {
                // Show/Hide Tools only when not in horizontal split (tool panel has its own controls then)
                menuTile(
                    notesPanelVisible ? "Hide Tools" : "Show Tools",
                    systemImage: notesPanelVisible ? "rectangle.portrait" : "inset.filled.bottomhalf.rectangle.portrait"
                ) {
                    notesPanelVisible.toggle()
                }
            }
        }
    }

    private var viewOptionsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Back to the first page, unnamed: that page holds the tools as
            // well as highlighting, so "Highlights" misnamed it.
            Button {
                showingViewOptions = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            // How scripture is set.
            menuCaption("View")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Typeface", selection: $readerTypeface) {
                        Text("Serif").tag(LampProseTypeface.serif.rawValue)
                        Text("Sans").tag(LampProseTypeface.sansSerif.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)

                    textSizeStepper(
                        canDecrease: userSettings.readerFontSize > 12,
                        canIncrease: userSettings.readerFontSize < 30,
                        decrease: {
                            try? UserDatabase.shared.updateSettings { settings in
                                settings.readerFontSize = settings.readerFontSize - 2
                            }
                            userSettings.readerFontSize -= 2
                        },
                        increase: {
                            try? UserDatabase.shared.updateSettings { settings in
                                settings.readerFontSize = settings.readerFontSize + 2
                            }
                            userSettings.readerFontSize += 2
                        }
                    )
                    .frame(width: 112)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 4)

                Divider()
                    .padding(.leading, 12)

                // The space between lines, in points, as the Mac sets it.
                HStack(spacing: 10) {
                    Text("Line Spacing")
                    Spacer(minLength: 4)
                    Text("\(Int(LampTextScale.readerLineSpacing.clamped(readerLineSpacing))) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    lineSpacingStepper
                        .frame(width: 112)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
            }
            .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))

            // Tool options section (only in horizontal split mode)
            if isHorizontalSplit {
                menuCaption("Tool Panel")
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 0) {
                    // Scroll link toggle
                    menuRow(
                        isScrollLinked ? "Unlink Scroll" : "Link Scroll",
                        systemImage: isScrollLinked ? "link.circle.fill" : "link.circle"
                    ) {
                        isScrollLinked.toggle()
                    }

                    // Split orientation toggle
                    if let toggleOrientation = onToggleSplitOrientation {
                        Divider().padding(.leading, 52)
                        menuRow("Split Below", systemImage: "rectangle.split.1x2") {
                            showingOptionsMenu = false
                            toggleOrientation()
                        }
                    }

                    // Hide tool panel
                    if let hidePanel = onHideToolPanel {
                        Divider().padding(.leading, 52)
                        menuRow("Hide Tools", systemImage: "rectangle.portrait") {
                            showingOptionsMenu = false
                            hidePanel()
                        }
                    }
                }
                .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))

                // Tool font size controls
                textSizeStepper(
                    canDecrease: toolFontSize > 12,
                    canIncrease: toolFontSize < 24,
                    decrease: { toolFontSize -= 2 },
                    increase: { toolFontSize += 2 }
                )
                .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
            }
        }
    }


    /// A small heading over a group of the menu's controls.
    private func menuCaption(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LampTheme.caption)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// A half-width action: its icon over its name.
    private func menuTile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(LampTheme.menuBackground, in: RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// One action in the menu: an icon in a fixed column, then its name.
    private func menuRow(_ title: String, systemImage: String, showsChevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .frame(width: 24)
                    .foregroundStyle(Color.primary)
                Text(title)
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityLabel(title)
    }

    /// Smaller and larger text, each a letter drawn at the size it moves toward.
    private func textSizeStepper(
        canDecrease: Bool,
        canIncrease: Bool,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: decrease) {
                Text("A")
                    .font(.system(size: 14, weight: .medium, design: .serif))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDecrease)
            .accessibilityLabel("Smaller Text")

            Divider()
                .frame(height: 22)

            Button(action: increase) {
                Text("A")
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canIncrease)
            .accessibilityLabel("Larger Text")
        }
    }

    /// Tighter and looser lines, a step of a point each.
    private var lineSpacingStepper: some View {
        let scale = LampTextScale.readerLineSpacing
        return HStack(spacing: 0) {
            Button {
                readerLineSpacing = scale.stepped(readerLineSpacing, by: -1)
            } label: {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!scale.canDecrease(readerLineSpacing))
            .accessibilityLabel("Tighter Lines")

            Divider()
                .frame(height: 22)

            Button {
                readerLineSpacing = scale.stepped(readerLineSpacing, by: 1)
            } label: {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!scale.canIncrease(readerLineSpacing))
            .accessibilityLabel("Looser Lines")
        }
    }

    @ViewBuilder
    private var highlightsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Style and color picker
            InlineHighlightPicker(onEditTheme: onEditTheme != nil ? { color, style, existingTheme in
                onEditTheme?(color, style, existingTheme)
                showingOptionsMenu = false
            } : nil)

            Divider()
                .padding(.horizontal, 14)

            // Highlight set chooser
            if !HighlightManager.shared.availableSets.isEmpty {
                Menu {
                    ForEach(HighlightManager.shared.availableSets, id: \.id) { set in
                        Button {
                            HighlightManager.shared.selectSet(set.id)
                        } label: {
                            if HighlightManager.shared.activeSetId == set.id {
                                Label(set.name, systemImage: "checkmark")
                            } else {
                                Text(set.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "folder")
                            .font(.system(size: 17))
                            .frame(width: 24)
                        Text(HighlightManager.shared.availableSets.first { $0.id == HighlightManager.shared.activeSetId }?.name ?? "Select Set")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()
                    .padding(.leading, 52)
            }

            // Show/Hide Highlights
            Button {
                HighlightManager.shared.highlightsHidden.toggle()
            } label: {
                HStack(spacing: 14) {
                    Group {
                        if HighlightManager.shared.highlightsHidden {
                            Image(systemName: "highlighter")
                        } else {
                            Image("highlighter.slash")
                        }
                    }
                    .font(.system(size: 17))
                    .frame(width: 24)
                    Text(HighlightManager.shared.highlightsHidden ? "Show Highlights" : "Hide Highlights")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(LampTheme.menuCard, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
    }
}

/// Glass for header controls — the reader's and the tool panel's — or a
/// material where the OS has no glass.
struct HeaderGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Pins the reader's header to the top, as a bar the text scrolls under.
    @ViewBuilder
    func readerHeaderBar<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, content: header)
        } else {
            safeAreaInset(edge: .top) {
                header().background(.bar)
            }
        }
    }
}


// MARK: - Window Controls

/// How far an iPad window's close, minimise and resize buttons reach into a
/// view, at each end, beyond the safe area it already keeps to.
struct WindowControlsInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var widest: CGFloat { max(leading, trailing) }
}

/// Reads `WindowControlsInsets` for the view it is the background of. SwiftUI
/// has no say in this; UIKit's safe area with corner adaptation does, from
/// iOS 26. Zero before that and wherever a window has no controls.
struct WindowControlsInsetReader: UIViewRepresentable {
    @Binding var insets: WindowControlsInsets

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.onChange = { value in
            // Out of the layout pass that measured it.
            DispatchQueue.main.async {
                if insets != value { insets = value }
            }
        }
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {}

    final class Probe: UIView {
        var onChange: ((WindowControlsInsets) -> Void)?
        private var reported: WindowControlsInsets?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            var value = WindowControlsInsets()
            if #available(iOS 26.0, *) {
                let adapted = edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                let left = max(0, adapted.left - safeAreaInsets.left)
                let right = max(0, adapted.right - safeAreaInsets.right)
                let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
                value.leading = rightToLeft ? right : left
                value.trailing = rightToLeft ? left : right
            }
            guard value != reported else { return }
            reported = value
            onChange?(value)
        }
    }
}
