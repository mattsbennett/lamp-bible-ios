//
//  ReaderNavigationToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI

struct ReaderNavigationToolbarView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var userSettings: UserSettings
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var translationId: String
    @Binding var translationAbbreviation: String
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    @Binding var showingOptionsMenu: Bool
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
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
                        optionsMenuContent
                    }
                }
            }
            title
                // Clear of the buttons either side.
                .padding(.horizontal, isCompact ? 0 : (trailingAccessory == nil ? 52 : 104))
        }
        .padding(.horizontal, 16)
        .frame(height: isCompact ? Self.compactHeight : Self.expandedHeight)
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
            // Menu with Bible and Tool selection
            Menu {
                // Bible section
                Section("Bible") {
                    if readingMetaData == nil {
                        Button {
                            showingBookPicker = true
                        } label: {
                            Label("Change Book/Chapter", systemImage: "book")
                        }
                    }
                }

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
            } label: {
                // Combined view: Translation + Book | Tool
                HStack(spacing: 8) {
                    VStack(spacing: 0) {
                        Text(translationAbbreviation).bold().font(.system(size: 14))
                        Text(place).font(.caption2)
                    }
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1, height: 24)
                    VStack(spacing: 0) {
                        Text(toolPanelMode.rawValue).bold().font(.system(size: 14))
                        Text(toolDisplayName).font(.caption2).lineLimit(1)
                    }
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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

    @ViewBuilder
    private var optionsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Highlights section
            highlightsSectionContent

            // Bible options section
            VStack(alignment: .leading, spacing: 0) {
                if let hideToolbars = onHideToolbars {
                    Button {
                        showingOptionsMenu = false
                        hideToolbars()
                    } label: {
                        Label("Hide Toolbars", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()
                }

                if !isHorizontalSplit {
                    // Show/Hide Tools only when not in horizontal split (tool panel has its own controls then)
                    Button {
                        notesPanelVisible.toggle()
                    } label: {
                        Label(
                            notesPanelVisible ? "Hide Tools" : "Show Tools",
                            systemImage: notesPanelVisible ? "rectangle.portrait" : "inset.filled.bottomhalf.rectangle.portrait"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Bible font size controls
            HStack(spacing: 0) {
                Button {
                    if userSettings.readerFontSize > 12 {
                        try? UserDatabase.shared.updateSettings { settings in
                            settings.readerFontSize = settings.readerFontSize - 2
                        }
                        userSettings.readerFontSize -= 2
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(userSettings.readerFontSize <= 12)

                Divider()
                    .frame(height: 20)

                Button {
                    if userSettings.readerFontSize < 30 {
                        try? UserDatabase.shared.updateSettings { settings in
                            settings.readerFontSize = settings.readerFontSize + 2
                        }
                        userSettings.readerFontSize += 2
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(userSettings.readerFontSize >= 30)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Tool options section (only in horizontal split mode)
            if isHorizontalSplit {
                // Section header
                Text("Tool Panel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Scroll link toggle
                    Button {
                        isScrollLinked.toggle()
                    } label: {
                        Label(
                            isScrollLinked ? "Unlink Scroll" : "Link Scroll",
                            systemImage: isScrollLinked ? "link.circle.fill" : "link.circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    // Split orientation toggle
                    if let toggleOrientation = onToggleSplitOrientation {
                        Button {
                            showingOptionsMenu = false
                            toggleOrientation()
                        } label: {
                            Label("Split Below", systemImage: "rectangle.split.1x2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()
                    }

                    // Hide tool panel
                    if let hidePanel = onHideToolPanel {
                        Button {
                            showingOptionsMenu = false
                            hidePanel()
                        } label: {
                            Label("Hide Tools", systemImage: "rectangle.portrait")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)

                // Tool font size controls
                HStack(spacing: 0) {
                    Button {
                        if toolFontSize > 12 {
                            toolFontSize -= 2
                        }
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(toolFontSize <= 12)

                    Divider()
                        .frame(height: 20)

                    Button {
                        if toolFontSize < 24 {
                            toolFontSize += 2
                        }
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(toolFontSize >= 24)
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)
            }
        }
        .font(.body)
        .fontWeight(.regular)
        .padding(12)
        .background(Color(UIColor.systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
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
                .padding(.horizontal, 8)

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
                    HStack {
                        Label {
                            Text(HighlightManager.shared.availableSets.first { $0.id == HighlightManager.shared.activeSetId }?.name ?? "Select Set")
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 8)
            }

            // Show/Hide Highlights
            Button {
                HighlightManager.shared.highlightsHidden.toggle()
            } label: {
                Label {
                    Text(HighlightManager.shared.highlightsHidden ? "Show Highlights" : "Hide Highlights")
                } icon: {
                    if HighlightManager.shared.highlightsHidden {
                        Image(systemName: "highlighter")
                    } else {
                        Image("highlighter.slash")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
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

