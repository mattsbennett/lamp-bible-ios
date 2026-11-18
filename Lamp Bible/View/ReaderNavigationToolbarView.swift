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
    @AppStorage("selectedDevotionalsModuleId") private var devotionalsModuleId: String = WritingCollection.id

    // Available modules (passed from parent)
    var notesModules: [Module] = []
    var commentarySeries: [String] = []
    var devotionalsModules: [Module] = []

    /// Read aloud stop action, offered only while something is being read. Play and
    /// pause live on their own toolbar button; stop is rare enough to sit in here.

    /// In plan reading mode, the plan and the day's readings. The title then
    /// says the mode, as the Mac's plan bar does, since it is the one control
    /// still there once the toolbars hide, and opens the day's readings and
    /// the way out of the mode.
    var planContext: PlanHeaderContext? = nil
    @State private var showingPlanMenu = false
    /// What the plan sheet asked for that needs another sheet, done once it
    /// has gone.
    @State private var planSheetFollowUp: PlanSheetFollowUp?

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
        planContext: PlanHeaderContext? = nil
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
        self.planContext = planContext
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
                .sheet(isPresented: $showingPlanMenu, onDismiss: runPlanSheetFollowUp) {
                    if let planContext {
                        PlanReadingSheet(plan: planContext) { followUp in
                            planSheetFollowUp = followUp
                            showingPlanMenu = false
                        }
                    }
                }
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
        let place = (TranslationDatabase.shared.bookName(currentBook, translationId: translationId) ?? "") + " \(currentChapter)"

        if isHorizontalSplit && !isCompact {
            // The passage and the tool, in one capsule. The passage opens the
            // book picker straight away, as it does in one column; the tool
            // is the menu of tools.
            HStack(spacing: 0) {
                Button {
                    if planContext != nil {
                        showingPlanMenu = true
                    } else {
                        showingBookPicker = true
                    }
                } label: {
                    VStack(spacing: 0) {
                        planAbbreviation
                        Text(placeLine(place)).font(.caption2)
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
                .accessibilityLabel(planAccessibilityLabel(place) ?? "\(translationAbbreviation), \(place)")

                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1, height: 24)

                Menu {
                    toolMenuContent
                } label: {
                    VStack(spacing: 0) {
                        Text(toolPanelMode.displayName).bold().font(.system(size: 14))
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
                } else if planContext != nil {
                    showingPlanMenu = true
                } else if readingMetaData == nil {
                    showingBookPicker = true
                }
            } label: {
                Group {
                    if isCompact {
                        HStack(spacing: 4) {
                            if planContext != nil {
                                Image(systemName: "checklist")
                                    .foregroundStyle(.tint)
                            }
                            Text(translationAbbreviation).bold()
                            Text("· " + placeLine(place))
                            // Beside a tool panel, what it shows too.
                            if isHorizontalSplit {
                                Text("· " + toolDisplayName)
                            }
                        }
                        .font(.caption)
                    } else {
                        VStack(spacing: 0) {
                            planAbbreviation
                            Text(placeLine(place)).font(.caption2)
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
            .disabled(!isCompact && readingMetaData != nil && planContext == nil)
            .modifier(HeaderGlass(shape: Capsule()))
            .accessibilityLabel(planAccessibilityLabel(place) ?? "\(translationAbbreviation), \(place)")
            .accessibilityHint(isCompact ? "Shows the toolbars" : (planContext != nil ? "Shows the day's readings" : ""))
        }
    }

    /// The translation, after the plan's mark in plan mode.
    private var planAbbreviation: some View {
        HStack(spacing: 4) {
            if planContext != nil {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text(translationAbbreviation).bold().font(.system(size: 14))
        }
    }

    /// The place, with which of the day's readings it is in plan mode.
    private func placeLine(_ place: String) -> String {
        guard let planContext, planContext.readings.count > 1 else { return place }
        return "\(place) · \(planContext.currentIndex + 1) of \(planContext.readings.count)"
    }

    private func planAccessibilityLabel(_ place: String) -> String? {
        guard let planContext else { return nil }
        return "Plan reading, \(place), reading \(planContext.currentIndex + 1) of \(planContext.readings.count), \(translationAbbreviation)"
    }

    private func runPlanSheetFollowUp() {
        defer { planSheetFollowUp = nil }
        switch planSheetFollowUp {
        case .choosePassage: showingBookPicker = true
        case .quiz: planContext?.onQuiz?()
        case nil: break
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
            // Highlights: the set they go in, and showing them.
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
                // In the label colour, as the app's other back buttons are.
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            // How scripture is set.
            menuCaption("View")
            TextSettingsCard(
                typeface: $readerTypeface,
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
                },
                lineSpacing: $readerLineSpacing,
                scale: .readerLineSpacing
            )
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

                // How the panel's text is set, as the reader's is above:
                // its typeface and size on one row, its line spacing below.
                ToolTextSettingsCard(toolFontSize: $toolFontSize)
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

    @ViewBuilder
    private var highlightsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Style and colour are chosen by the words, in the highlight
            // panel; here, the set they go in and whether they show.

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


/// How a body of text is set, on one card: its typeface and size on one row,
/// the space between its lines on the next. The reader's and the tool
/// panel's, so the two read alike wherever they are set.
struct TextSettingsCard: View {
    @Binding var typeface: String
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void
    @Binding var lineSpacing: Double
    let scale: LampTextScale

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Typeface", selection: $typeface) {
                    Text("Serif").tag(LampProseTypeface.serif.rawValue)
                    Text("Sans").tag(LampProseTypeface.sansSerif.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                textSizeStepper
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
                Text("\(Int(scale.clamped(lineSpacing))) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                lineSpacingStepper
                    .frame(width: 112)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
        }
    }

    /// Smaller and larger text, each a letter drawn at the size it moves toward.
    private var textSizeStepper: some View {
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
        HStack(spacing: 0) {
            Button {
                lineSpacing = scale.stepped(lineSpacing, by: -1)
            } label: {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!scale.canDecrease(lineSpacing))
            .accessibilityLabel("Tighter Lines")

            Divider()
                .frame(height: 22)

            Button {
                lineSpacing = scale.stepped(lineSpacing, by: 1)
            } label: {
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!scale.canIncrease(lineSpacing))
            .accessibilityLabel("Looser Lines")
        }
    }
}

/// The tool panel's text settings: the panel's typeface, size and line
/// spacing, which its sheets take too.
struct ToolTextSettingsCard: View {
    @Binding var toolFontSize: Int
    @AppStorage(LampTextScale.toolTypefaceKey) private var typeface = LampProseTypeface.serif.rawValue
    @AppStorage(LampTextScale.toolLineSpacingKey) private var lineSpacing = LampTextScale.toolLineSpacing.defaultValue

    var body: some View {
        TextSettingsCard(
            typeface: $typeface,
            canDecrease: toolFontSize > LampToolText.sizeRange.lowerBound,
            canIncrease: toolFontSize < LampToolText.sizeRange.upperBound,
            decrease: { toolFontSize -= 2 },
            increase: { toolFontSize += 2 },
            lineSpacing: $lineSpacing,
            scale: .toolLineSpacing
        )
    }
}

/// What the reader's title shows and offers in plan reading mode.
struct PlanHeaderContext {
    struct Reading: Identifiable {
        /// The reading's index in the day's readings.
        let id: Int
        let title: String
        let isRead: Bool
        /// Its length, kind and verses, said when its row is opened.
        let meta: ReadingMetaData
    }

    struct Plan: Identifiable {
        /// The plan's index among those with readings on the day.
        let id: Int
        let name: String
        let readingCount: Int
    }

    let planName: String
    let date: Date
    let readings: [Reading]
    let currentIndex: Int
    /// The reading on screen, for its length, kind and the readers' split.
    let current: ReadingMetaData
    /// Every followed plan with readings on the day; more than one offers a
    /// choice between them.
    let plans: [Plan]
    let selectedPlanIndex: Int
    let onSelectReading: (Int) -> Void
    let onSelectPlan: (Int) -> Void
    /// Nil when the reading has no quiz.
    let onQuiz: (() -> Void)?
    let onExit: () -> Void
}

/// What the plan sheet hands back to be done once it has closed, since it
/// opens another sheet.
enum PlanSheetFollowUp {
    case choosePassage
    case quiz
}

/// Plan reading mode's controls, from the reader's title: what was on the
/// plan's bottom bar (the reading, the readers' split, the quiz, the plans)
/// with the day's readings and the way out of the mode. Everything about the
/// mode in one place, as the Mac's plan bar has it, so the bar can go.
///
/// Laid out so each thing is said once and the way out is always in reach:
/// the plan is the title, with the other plans in the title's menu; the day
/// is a card like the home screen's, with its readings' progress across it;
/// each reading opens in place to say what it is, without leaving the one
/// being read; and Choose Passage and Exit Plan Mode sit at the foot.
struct PlanReadingSheet: View {
    let plan: PlanHeaderContext
    /// Closes the sheet, then does what it names.
    let finish: (PlanSheetFollowUp?) -> Void
    @State private var readerCount = 1
    /// The readings opened in place, the one being read to begin with.
    @State private var opened: Set<Int>
    /// Full height from the start, as the owner asked; it can still be
    /// pulled down to half.
    @State private var detent: PresentationDetent = .large

    init(plan: PlanHeaderContext, finish: @escaping (PlanSheetFollowUp?) -> Void) {
        self.plan = plan
        self.finish = finish
        _opened = State(initialValue: [plan.currentIndex])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    dayCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(HeroBackground())
                }
                Section {
                    ForEach(plan.readings) { reading in
                        row(reading)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle(plan.planName)
            .navigationBarTitleDisplayMode(.inline)
            // The other plans with readings on the day, from the title that
            // names the one being read; no menu where there is only the one.
            .if(plan.plans.count > 1) { view in
                view.toolbarTitleMenu {
                    ForEach(plan.plans) { other in
                        Button {
                            if other.id != plan.selectedPlanIndex { plan.onSelectPlan(other.id) }
                            finish(nil)
                        } label: {
                            Label {
                                Text(other.name)
                                Text("\(other.readingCount) reading\(other.readingCount == 1 ? "" : "s")")
                            } icon: {
                                if other.id == plan.selectedPlanIndex { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .task {
            let count = await Task.detached { UserDatabase.shared.getSettings().planReaderCount }.value
            readerCount = count
        }
        .onChange(of: readerCount) { old, new in
            guard old != new else { return }
            // In order, as each change is made: a small write.
            try? UserDatabase.shared.updateSettings { $0.planReaderCount = new }
        }
    }

    // MARK: The day

    private var readCount: Int { plan.readings.filter(\.isRead).count }

    /// The day as the home screen's card has it: the date, how many readings
    /// and how long, how many are read, and a segment for each across the
    /// card's width.
    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plan.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 4)
            HStack(spacing: 6) {
                Text("^[\(plan.readings.count) reading](inflect: true)")
                if plan.readings.allSatisfy(\.meta.isResolved) {
                    Text("·")
                    Text("\(plan.readings.reduce(0) { $0 + $1.meta.readingTime }) min")
                }
                Spacer(minLength: 8)
                if readCount == plan.readings.count {
                    Label("All read", systemImage: "checkmark.circle.fill")
                        .fontWeight(.semibold)
                } else {
                    Text("\(readCount) of \(plan.readings.count) read")
                        .fontWeight(.semibold)
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.92))
            HStack(spacing: 5) {
                ForEach(plan.readings) { reading in
                    Capsule()
                        .fill(reading.isRead ? Color.white : Color.white.opacity(0.28))
                        .frame(height: 6)
                }
            }
            .padding(.top, 14)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(readCount) of \(plan.readings.count) read")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The readings

    private func statusIcon(_ reading: PlanHeaderContext.Reading) -> some View {
        Image(systemName: reading.isRead ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(reading.isRead ? Color.accentColor : Color.secondary.opacity(0.6))
            .frame(width: Self.iconWidth)
    }

    private static let iconWidth: CGFloat = 26

    /// A reading of the day: its title, which opens it in place to say its
    /// length and kind, the readers' split and, for the one being read, the
    /// quiz; another reading is read from its own Read button there.
    private func row(_ reading: PlanHeaderContext.Reading) -> some View {
        let isOpen = opened.contains(reading.id)
        let isCurrent = reading.id == plan.currentIndex
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    if isOpen { opened.remove(reading.id) } else { opened.insert(reading.id) }
                }
            } label: {
                HStack(alignment: .readingTitle, spacing: 12) {
                    statusIcon(reading)
                        .alignmentGuide(.readingTitle) { $0[VerticalAlignment.center] }
                    VStack(alignment: .leading, spacing: 3) {
                        if isCurrent, plan.readings.count > 1 {
                            Text("Reading \(plan.currentIndex + 1) of \(plan.readings.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        Text(reading.title)
                            .font(isCurrent ? .headline : .body)
                            .foregroundStyle(reading.isRead && !isCurrent ? Color.secondary : Color.primary)
                            .alignmentGuide(.readingTitle) { $0[VerticalAlignment.center] }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        // Grey, not the borderless button's tint.
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .alignmentGuide(.readingTitle) { $0[VerticalAlignment.center] }
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(reading.title), \(reading.isRead ? "read" : "not read")\(isCurrent ? ", reading now" : "")")
            .accessibilityHint(isOpen ? "Hides its details" : "Shows its details")

            if isOpen {
                details(reading, isCurrent: isCurrent)
                    .padding(.leading, Self.iconWidth + 12)
                    .transition(.opacity)
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        // Each divider starts under the titles, whatever the row has open.
        .alignmentGuide(.listRowSeparatorLeading) { _ in Self.iconWidth + 12 }
    }

    private func details(_ reading: PlanHeaderContext.Reading, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details(of: reading.meta))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            // Chips wrap whole: the second goes under the first where the
            // two don't fit side by side. Stacked, a chip still too wide for
            // the row (many chapters at a large text size) may wrap within
            // itself rather than be cut off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips(reading, isCurrent: isCurrent, whole: true) }
                VStack(alignment: .leading, spacing: 8) { chips(reading, isCurrent: isCurrent, whole: false) }
            }
        }
    }

    @ViewBuilder
    private func chips(_ reading: PlanHeaderContext.Reading, isCurrent: Bool, whole: Bool) -> some View {
                // Only when reading aloud in turns, as Settings sets.
                if readerCount > 1 {
                    ReaderSplitControl(
                        chapterVerseCounts: reading.meta.chapterVerseCounts,
                        isResolved: reading.meta.isResolved,
                        readerCount: $readerCount,
                        style: .chip
                    )
                    .fixedSize(horizontal: whole, vertical: !whole)
                }
                if isCurrent {
                    if plan.onQuiz != nil {
                        chip("Quiz", systemImage: "questionmark.circle.fill") { finish(.quiz) }
                    }
                } else {
                    Button {
                        plan.onSelectReading(reading.id)
                        finish(nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "book.fill")
                                .font(.caption.weight(.semibold))
                            Text("Read")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor, in: Capsule())
                        .contentShape(Capsule())
                        .fixedSize()
                    }
                    .accessibilityLabel("Read \(reading.title)")
                }
    }

    /// Drawn as the readers' chip beside it is.
    private func chip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(LampTheme.tileFill, in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .accessibilityLabel(title)
    }

    /// The ways out of what the plan sets, at the sheet's foot.
    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                // Words alone: with icons, "Choose Passage" no longer fit
                // half a phone's width.
                Button {
                    finish(.choosePassage)
                } label: {
                    Text("Choose Passage")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    plan.onExit()
                    finish(nil)
                } label: {
                    Text("Exit Plan Mode")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Text("Choosing another passage leaves plan mode.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(LampTheme.groupedBackground)
    }

    private func details(of reading: ReadingMetaData) -> String {
        guard reading.isResolved else { return "— verses · ~— min · \(reading.genre)" }
        return "\(reading.verseCount) verses · ~\(reading.readingTime) min · \(reading.genre)"
    }
}

private extension VerticalAlignment {
    /// A plan reading's title, which its read mark lines up with whatever
    /// is said above the title.
    enum ReadingTitle: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let readingTitle = VerticalAlignment(ReadingTitle.self)
}
