//
//  SplitReaderView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import SwiftUI
import GRDB

/// Tracks who initiated the most recent scroll to prevent feedback loops
/// Used by ReaderView for legacy compatibility
enum ScrollOrigin: Equatable {
    case none
    case bible
    case toolPanel
}

/// Preference key to track divider position for overlay alignment
struct DividerPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SplitReaderView: View {
    @Binding var date: Date
    var readingMetaData: [ReadingMetaData]?
    var initialVerseId: Int? = nil
    var initialTranslationId: String? = nil  // GRDB translation ID
    var initialToolbarMode: BottomToolbarMode? = nil
    /// The plan `initialVerseId` was chosen from, in plan mode: plans can
    /// share a passage, and the reading opens in the one it was tapped in.
    var initialPlanId: String? = nil

    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = true
    @SceneStorage("readerCurrentVerseId") private var currentVerseId: Int = 1001001
    @SceneStorage("readerTranslationId") private var currentTranslationId: String = ""
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
    @AppStorage("toolPanelMode") private var toolPanelMode: ToolPanelMode = .commentary
    @AppStorage("toolFontSize") private var toolFontSize: Int = 16
    @AppStorage("selectedNotesModuleId") private var notesModuleId: String = "notes"
    @AppStorage("selectedCommentarySeries") private var selectedCommentarySeries: String = ""
    @AppStorage("selectedDevotionalsModuleId") private var devotionalsModuleId: String = "devotionals"
    @State private var hasUserScrolled: Bool = false
    @State private var toolbarsHidden: Bool = false
    /// Shared by both panes so a scroll in either collapses both headers.
    @State private var toolbarsCollapsed: Bool = false
    @State private var pendingAddNoteVerse: Int? = nil  // Trigger add note sheet in tool panel

    // Available modules for tool selection in horizontal split
    @State private var notesModules: [Module] = []
    @State private var commentarySeries: [String] = []
    @State private var devotionalsModules: [Module] = []

    // Derived from currentVerseId - always in sync
    private var currentBook: Int {
        currentVerseId / 1000000
    }
    private var currentChapter: Int {
        (currentVerseId % 1000000) / 1000
    }
    private var currentVerse: Int {
        currentVerseId % 1000
    }

    /// Chapter range for multi-chapter plan readings (same book only).
    /// Returns (startChapter, endChapter) when the current reading spans multiple chapters.
    private var currentReadingChapterRange: (start: Int, end: Int)? {
        guard let readings = readingMetaData else { return nil }
        for reading in readings {
            if currentVerseId >= reading.sv && currentVerseId <= reading.ev {
                let startChapter = (reading.sv % 1000000) / 1000
                let endChapter = (reading.ev % 1000000) / 1000
                let startBook = reading.sv / 1000000
                let endBook = reading.ev / 1000000
                // Only for same-book, multi-chapter readings
                if startBook == endBook && endChapter > startChapter {
                    return (start: startChapter, end: endChapter)
                }
                return nil
            }
        }
        return nil
    }

    // Resizable panel state - persisted across sessions
    @SceneStorage("toolPanelBottomHeightV2") private var storedBottomPanelHeight: Double = 0
    @SceneStorage("toolPanelRightWidthV2") private var storedRightPanelWidth: Double = 0
    @State private var bottomPanelHeight: CGFloat = 0
    @State private var rightPanelWidth: CGFloat = 350

    // Divider position tracking for overlay alignment
    @State private var dividerY: CGFloat = 0
    /// The divider is dragged far enough that letting go closes the panel.
    @State private var panelDragWouldClose = false
    /// While a note is being typed with the keyboard up, the space above the
    /// keyboard is too little for both panes, and the notes take it.
    @ObservedObject private var noteEditorFocus = NoteEditorFocus.shared
    @State private var keyboardHeight: CGFloat = 0

    /// The bottom panel takes the whole space above the keyboard: the split
    /// then lays itself out around the keyboard, so the panel inside it does
    /// not make room for the keyboard a second time.
    private var notesTakeTheSpace: Bool {
        (noteEditorFocus.isEditing && keyboardHeight > 0 || noteEditorFocus.isAwaitingSheet)
            && effectiveOrientation != "right"
    }

    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var effectiveOrientation: String {
        // On iPhone (compact), always use bottom
        if isCompact {
            return "bottom"
        }
        return notesPanelOrientation
    }

    /// True when tool panel is visible and in horizontal (right-side) split mode
    private var isHorizontalSplit: Bool {
        notesPanelVisible && effectiveOrientation == "right"
    }

    /// Display name for current tool panel mode
    private var currentToolDisplayName: String {
        switch toolPanelMode {
        case .notes:
            return "Notes"
        case .commentary:
            return selectedCommentarySeries.isEmpty ? "Commentary" : selectedCommentarySeries
        case .devotionals:
            return "Devotionals"
        }
    }

    // Minimum and maximum sizes for panels
    private let minPanelSize: CGFloat = 150
    private let maxPanelRatio: CGFloat = 0.7

    var body: some View {
        Group {
            if notesPanelVisible {
                splitView
            } else {
                readerContent
            }
        }
        // Ensure content/background extends behind any bottom toolbar so we don't
        // see the underlying window's black background.
        .background(LampTheme.readerBackground)
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            // Enable scroll linking after initial load completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                hasUserScrolled = true
            }
        }
        .task {
            // Load available modules for tool selection in horizontal split toolbar
            await loadToolModules()
        }
        // Note: Scroll sync is now handled entirely by UIKit via ReaderScrollSpy and ScrollSyncCoordinator
    }

    /// These are all database reads. `.task` runs on the main actor, so without
    /// the hop below they'd block the first frame of the reader.
    private func loadToolModules() async {
        let loaded: (notes: [Module], series: [String], devotionals: [Module]) =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let notes = (try? ModuleDatabase.shared.getAllModules(type: .notes)) ?? []

                    // Commentary series (bundled + user modules)
                    var allSeries = (try? BundledModuleDatabase.shared.getBundledCommentarySeriesNames()) ?? []
                    if let userSeries = try? ModuleDatabase.shared.getCommentarySeriesNames() {
                        for series in userSeries where !allSeries.contains(series) {
                            allSeries.append(series)
                        }
                    }

                    let devotionals = (try? ModuleDatabase.shared.getAllModules(type: .devotional)) ?? []
                    continuation.resume(returning: (notes, allSeries, devotionals))
                }
            }

        notesModules = loaded.notes
        commentarySeries = loaded.series
        devotionalsModules = loaded.devotionals
    }

    @ViewBuilder
    private var splitView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Layer 1: Content
                if effectiveOrientation == "right" {
                    // Use ZStack overlay approach so tool panel can independently extend to top
                    ZStack(alignment: .trailing) {
                        // Tool panel + divider on the right, to the top of the
                        // window, as the passage runs under the header too.
                        HStack(spacing: 0) {
                            // Divider with gradient fade at edges to match toolbar blur effect
                            Rectangle()
                                .fill(Color(UIColor.separator))
                                .frame(width: 1)
                                .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black, location: 0.08),
                                            .init(color: .black, location: 0.92),
                                            .init(color: .clear, location: 1)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(.horizontal, 5.5)
                                .frame(width: 12)
                                .contentShape(Rectangle())

                            // Its content starts below the reader's header
                            // and scrolls up under it, as the passage's does
                            // (`sharedHeaderHeight`). Stopping the panel at
                            // the header left a dead band once it collapsed.
                            toolPanelContent
                                .frame(width: rightPanelWidth)
                        }
                        .frame(maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)

                        // Over the panel: the reader keeps its passage clear
                        // of it, and its header spans both, so the header's
                        // buttons above the panel take the taps there. The
                        // rest of the reader's width is empty and lets them by.
                        readerContent
                    }
                } else {
                    VStack(spacing: 0) {
                        // Kept, at no height, so it is where it was when the
                        // keyboard goes down.
                        readerContent
                            .frame(height: notesTakeTheSpace ? 0 : max(0, geometry.size.height - bottomPanelHeight - 12))
                            .opacity(notesTakeTheSpace ? 0 : 1)
                            .clipped()
                            .allowsHitTesting(!notesTakeTheSpace)

                        // The panel on a ground of its own, under a hairline
                        // and the handle that resizes it.
                        VStack(spacing: 0) {
                            // Divider with integrated drag handle
                            if !notesTakeTheSpace {
                                BottomPanelDivider(
                                    panelHeight: $bottomPanelHeight,
                                    containerHeight: geometry.size.height,
                                    minPanelSize: minPanelSize,
                                    maxPanelRatio: maxPanelRatio,
                                    isClosing: $panelDragWouldClose,
                                    onDragEnd: {
                                        storedBottomPanelHeight = Double(bottomPanelHeight)
                                    },
                                    onClose: closePanelFromDivider
                                )
                            }

                            toolPanelContent
                                // Off the top edge by a point: touching it, the
                                // panel's list would run on up under the status bar
                                // and start behind the panel's own header.
                                .padding(.top, notesTakeTheSpace ? 1 : 0)
                                .frame(height: notesTakeTheSpace
                                       ? max(minPanelSize, geometry.size.height - keyboardHeight)
                                       : bottomPanelHeight)
                                .clipped()
                        }
                        .background(LampTheme.panelBackground)

                        if notesTakeTheSpace {
                            Spacer(minLength: keyboardHeight)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: notesTakeTheSpace)
                }

                // Layer 2: Interactive Drag Overlay (only for right panel - bottom uses inline handle)
                if effectiveOrientation == "right" {
                    SplitDragOverlay(
                        panelSize: $rightPanelWidth,
                        containerSize: geometry.size,
                        // The divider's length: from under the header to the
                        // window's bottom edge.
                        spanTop: readerHeaderHeight,
                        spanBottomOverhang: geometry.safeAreaInsets.bottom,
                        minPanelSize: minPanelSize,
                        maxPanelRatio: maxPanelRatio,
                        isClosing: $panelDragWouldClose,
                        onDragEnd: { newSize in
                            storedRightPanelWidth = Double(newSize)
                        },
                        onClose: closePanelFromDivider
                    )
                }
            }
            .coordinateSpace(name: "splitContainer")
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                // How far up the screen the keyboard reaches.
                let screen = UIScreen.main.bounds
                keyboardHeight = frame.minY >= screen.maxY ? 0 : max(0, screen.maxY - frame.minY)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .onPreferenceChange(DividerPositionKey.self) { value in
                dividerY = value
            }
            // Allow split content (including ToolPanelView) to extend behind the bottom toolbar
            // so there isn't a blank/black strip under it.
            .background(LampTheme.readerBackground)
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                if effectiveOrientation == "right" {
                    if storedRightPanelWidth != 0 {
                        rightPanelWidth = CGFloat(storedRightPanelWidth)
                    } else {
                        rightPanelWidth = min(350, geometry.size.width / 3)
                    }
                } else {
                    if storedBottomPanelHeight != 0 {
                        bottomPanelHeight = CGFloat(storedBottomPanelHeight)
                    } else {
                        bottomPanelHeight = geometry.size.height / 3
                    }
                }
            }
        }
        // Laid out around the keyboard by hand while the notes take the space.
        .ignoresSafeArea(notesTakeTheSpace ? .keyboard : [], edges: .bottom)
    }

    /// The height of the reader's header, which a right-hand panel starts
    /// below.
    /// The divider was let go well past the panel's smallest size.
    private func closePanelFromDivider() {
        withAnimation(.easeInOut(duration: 0.25)) {
            notesPanelVisible = false
        }
    }

    private var readerHeaderHeight: CGFloat {
        toolbarsHidden || toolbarsCollapsed
            ? ReaderNavigationToolbarView.compactHeight
            : ReaderNavigationToolbarView.expandedHeight
    }

    @ViewBuilder
    private func dragHandle(isVertical: Bool) -> some View {
        EmptyView()
    }

    @ViewBuilder
    private var readerContent: some View {
        ReaderView(
            date: $date,
            readingMetaData: readingMetaData,
            translationId: initialTranslationId,
            initialVerseId: initialVerseId,
            initialPlanId: initialPlanId,
            onVerseAction: handleVerseAction,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            visibleVerseId: $currentVerseId,
            toolbarsHidden: $toolbarsHidden,
            toolbarsCollapsed: $toolbarsCollapsed,
            initialToolbarMode: initialToolbarMode,
            // Horizontal split toolbar integration
            isHorizontalSplit: isHorizontalSplit,
            toolPanelMode: $toolPanelMode,
            toolDisplayName: currentToolDisplayName,
            isScrollLinked: $isScrollLinked,
            toolFontSize: $toolFontSize,
            onHideToolPanel: { notesPanelVisible = false },
            onToggleSplitOrientation: {
                notesPanelOrientation = notesPanelOrientation == "right" ? "bottom" : "right"
            },
            notesModules: notesModules,
            commentarySeries: commentarySeries,
            devotionalsModules: devotionalsModules,
            trailingPanelWidth: isHorizontalSplit ? rightPanelWidth + 12 : 0
        )
        .onAppear {
            // Enable scroll linking after initial load completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                hasUserScrolled = true
            }
        }
    }

    @ViewBuilder
    private var toolPanelContent: some View {
        ToolPanelView(
            book: currentBook,
            chapter: currentChapter,
            currentVerse: currentVerse,
            startChapter: currentReadingChapterRange?.start,
            endChapter: currentReadingChapterRange?.end,
            onNavigateToVerse: { verseId in
                // Direct navigation - bypass coordinator, just scroll reader
                requestScrollAnimated = false
                requestScrollToVerseId = verseId
            },
            toolbarsHidden: $toolbarsHidden,
            toolbarsCollapsed: $toolbarsCollapsed,
            hideHeader: isHorizontalSplit,
            sharedHeaderHeight: isHorizontalSplit ? readerHeaderHeight : 0,
            requestAddNoteForVerse: $pendingAddNoteVerse
        )
        // Fades while letting go of the divider would close it.
        .opacity(panelDragWouldClose ? 0.4 : 1)
        .animation(.easeOut(duration: 0.15), value: panelDragWouldClose)
    }

    private func handleVerseAction(verse: Int, action: VerseAction) {
        switch action {
        case .addNote:
            // Show tool panel and trigger add note for the specific verse
            if !notesPanelVisible {
                notesPanelVisible = true
            }
            toolPanelMode = .notes
            pendingAddNoteVerse = verse
        case .highlight:
            // Highlight the verse with the current/default color
            HighlightManager.shared.highlightEntireVerse(verse)
        }
    }
}

/// Inline draggable divider that lives within the layout (not as an overlay)
struct DraggableDivider: View {
    let isVertical: Bool
    @Binding var panelSize: CGFloat
    let containerSize: CGFloat
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    let onDragEnd: (CGFloat) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var initialPanelSize: CGFloat? = nil
    @State private var lastUpdate: Date = Date.distantPast

    private let handleThickness: CGFloat = 12
    private let throttleInterval: TimeInterval = 0.032

    var body: some View {
        ZStack {
            // Divider line
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)

            // Handle pill
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(UIColor.systemGray3))
                .frame(width: isVertical ? 4 : 40, height: isVertical ? 40 : 4)
        }
        .frame(width: isVertical ? handleThickness : nil, height: isVertical ? nil : handleThickness)
        .background(isDragging ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .offset(x: isVertical ? dragOffset : 0, y: isVertical ? 0 : dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        initialPanelSize = panelSize
                    }

                    let translation = isVertical ? value.translation.width : value.translation.height
                    // Clamp the visual offset to valid range
                    let clampedTranslation = clampedDragOffset(translation)
                    dragOffset = clampedTranslation

                    // Throttled update of actual panel size
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > throttleInterval {
                        updatePanelSize(translation: translation)
                        lastUpdate = now
                    }
                }
                .onEnded { value in
                    let translation = isVertical ? value.translation.width : value.translation.height
                    updatePanelSize(translation: translation)

                    if let finalSize = initialPanelSize {
                        let newSize = calculateNewSize(baseSize: finalSize, translation: translation)
                        onDragEnd(newSize)
                    }

                    isDragging = false
                    dragOffset = 0
                    initialPanelSize = nil
                }
        )
    }

    private func calculateNewSize(baseSize: CGFloat, translation: CGFloat) -> CGFloat {
        let newSize = baseSize - translation
        return min(max(newSize, minPanelSize), containerSize * maxPanelRatio)
    }

    private func clampedDragOffset(_ translation: CGFloat) -> CGFloat {
        guard let baseSize = initialPanelSize else { return translation }
        let newSize = baseSize - translation
        let clampedSize = min(max(newSize, minPanelSize), containerSize * maxPanelRatio)
        return baseSize - clampedSize
    }

    private func updatePanelSize(translation: CGFloat) {
        guard let baseSize = initialPanelSize else { return }
        panelSize = calculateNewSize(baseSize: baseSize, translation: translation)
    }
}

/// Inline divider with integrated drag handle for bottom panel
// MARK: - Split Divider

/// What the divider between the passage and a tool panel does in hand, in
/// both orientations, after the iPad's own split between two apps: the
/// panel follows the finger, gives with resistance past its limits, and
/// closes when dragged well past its smallest size.
enum SplitDividerDrag {
    /// How far past the smallest size a release closes the panel.
    static let closeDistance: CGFloat = 72

    /// The size shown for a drag that would make it `raw`: past a limit it
    /// gives less and less, as a scroll view does at its ends.
    static func size(for raw: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        if raw < lo { return lo - band(lo - raw) }
        if raw > hi { return hi + band(raw - hi) }
        return raw
    }

    static func closes(raw: CGFloat, min lo: CGFloat) -> Bool {
        raw < lo - closeDistance
    }

    private static func band(_ over: CGFloat) -> CGFloat {
        let reach: CGFloat = 120
        return (1 - 1 / (over * 0.55 / reach + 1)) * reach
    }
}

/// The grabber across a split's divider, as a sheet's: a short capsule in
/// the system's quiet grey. Held, it grows and darkens, rather than the
/// band around it taking a tint.
struct SplitDividerGrabber: View {
    /// The divider runs top to bottom, beside a right-hand panel.
    let isVertical: Bool
    let isActive: Bool

    var body: some View {
        let long: CGFloat = isActive ? 56 : 36
        let thick: CGFloat = isActive ? 6 : 5
        Capsule()
            .fill(isActive ? Color.primary.opacity(0.55) : Color(UIColor.tertiaryLabel))
            .frame(width: isVertical ? thick : long, height: isVertical ? long : thick)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)
            // A trackpad's pointer takes the grabber's shape.
            .contentShape(.hoverEffect, Capsule().inset(by: -6))
            .hoverEffect(.highlight)
    }
}

private extension View {
    /// A tap when the divider is taken up, a firmer one at a limit, and the
    /// firmest when letting go would close the panel.
    func splitDividerFeedback(isDragging: Bool, atLimit: Bool, isClosing: Bool) -> some View {
        self
            .sensoryFeedback(.impact(weight: .light), trigger: isDragging) { _, new in new }
            .sensoryFeedback(.impact(weight: .medium), trigger: atLimit) { _, new in new }
            .sensoryFeedback(.impact(weight: .heavy), trigger: isClosing) { _, new in new }
    }
}

struct BottomPanelDivider: View {
    @Binding var panelHeight: CGFloat
    let containerHeight: CGFloat
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    /// Letting go now would close the panel; the panel dims to say so.
    @Binding var isClosing: Bool
    let onDragEnd: () -> Void
    let onClose: () -> Void

    @State private var initialHeight: CGFloat?
    @State private var atLimit = false

    private var isDragging: Bool { initialHeight != nil }
    private var maxHeight: CGFloat { containerHeight * maxPanelRatio }

    var body: some View {
        // The hairline where the page meets the panel's ground, and the
        // grabber that says it moves.
        ZStack(alignment: .top) {
            Rectangle()
                .fill(isDragging ? Color.primary.opacity(0.35) : Color(UIColor.separator))
                .frame(height: 1)

            SplitDividerGrabber(isVertical: false, isActive: isDragging)
                .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        // Easier to take than the 12 points it lays out in: it reaches up
        // over the passage's last lines too.
        .contentShape(Rectangle().inset(by: -8))
        .gesture(
            // In the window's space: the divider moves with the drag, so its
            // own space would move under the finger.
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if initialHeight == nil { initialHeight = panelHeight }
                    let raw = (initialHeight ?? panelHeight) - value.translation.height
                    let limit = raw < minPanelSize || raw > maxHeight
                    if limit != atLimit { atLimit = limit }
                    let closing = SplitDividerDrag.closes(raw: raw, min: minPanelSize)
                    if closing != isClosing { isClosing = closing }
                    panelHeight = SplitDividerDrag.size(for: raw, min: minPanelSize, max: maxHeight)
                }
                .onEnded { value in
                    let base = initialHeight ?? panelHeight
                    let raw = base - value.translation.height
                    if SplitDividerDrag.closes(raw: raw, min: minPanelSize) {
                        // Opened again, it comes back at the size it had.
                        panelHeight = base
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            panelHeight = min(max(raw, minPanelSize), maxHeight)
                        }
                        onDragEnd()
                    }
                    initialHeight = nil
                    atLimit = false
                    isClosing = false
                }
        )
        .splitDividerFeedback(isDragging: isDragging, atLimit: atLimit, isClosing: isClosing)
        .accessibilityElement()
        .accessibilityLabel("Panel divider")
        .accessibilityHint("Drag to resize the panel")
    }
}

/// The divider beside a right-hand panel, laid over the split so it can
/// follow the finger ahead of the passage, which reflows at a gentler rate.
struct SplitDragOverlay: View {
    @Binding var panelSize: CGFloat
    let containerSize: CGSize
    /// Where the handle's span starts, and how far it runs past the
    /// container's bottom, into the bottom safe area.
    var spanTop: CGFloat = 0
    var spanBottomOverhang: CGFloat = 0
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    /// Letting go now would close the panel; the panel dims to say so.
    @Binding var isClosing: Bool
    let onDragEnd: (CGFloat) -> Void
    let onClose: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var initialPanelSize: CGFloat?
    @State private var lastUpdate = Date.distantPast
    @State private var atLimit = false

    /// The divider's column in the split's layout.
    private let columnWidth: CGFloat = 12
    /// What a finger can take: wider than the column, centred on its line.
    private let hitWidth: CGFloat = 28
    /// The passage reflows as the panel resizes, which is too much to do on
    /// every frame of a drag; the handle itself follows every frame.
    private let throttleInterval: TimeInterval = 0.032

    private var isDragging: Bool { initialPanelSize != nil }
    private var maxSize: CGFloat { containerSize.width * maxPanelRatio }
    private var rawSize: CGFloat { (initialPanelSize ?? panelSize) - dragOffset }
    private var shownSize: CGFloat {
        SplitDividerDrag.size(for: rawSize, min: minPanelSize, max: maxSize)
    }

    /// The full length of the divider, so the handle and its hit area run
    /// with it rather than stopping short at either end.
    private var span: CGFloat {
        max(0, containerSize.height + spanBottomOverhang - spanTop)
    }

    var body: some View {
        ZStack {
            // The line goes with the finger, so the grabber is never seen
            // apart from it while the panel catches up.
            if isDragging {
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
            }
            SplitDividerGrabber(isVertical: true, isActive: isDragging)
        }
        .frame(width: hitWidth, height: span)
        .contentShape(Rectangle())
        .position(x: containerSize.width - shownSize - columnWidth / 2, y: spanTop + span / 2)
        .gesture(
            // In the window's space: the handle moves with the drag, so its
            // own space would move under the finger.
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    if initialPanelSize == nil { initialPanelSize = panelSize }
                    dragOffset = value.translation.width
                    let limit = rawSize < minPanelSize || rawSize > maxSize
                    if limit != atLimit { atLimit = limit }
                    let closing = SplitDividerDrag.closes(raw: rawSize, min: minPanelSize)
                    if closing != isClosing { isClosing = closing }
                    let now = Date()
                    if now.timeIntervalSince(lastUpdate) > throttleInterval {
                        panelSize = shownSize
                        lastUpdate = now
                    }
                }
                .onEnded { value in
                    let base = initialPanelSize ?? panelSize
                    let raw = base - value.translation.width
                    if SplitDividerDrag.closes(raw: raw, min: minPanelSize) {
                        // Opened again, it comes back at the size it had.
                        panelSize = base
                        onClose()
                    } else {
                        let settled = min(max(raw, minPanelSize), maxSize)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            panelSize = settled
                        }
                        onDragEnd(settled)
                    }
                    initialPanelSize = nil
                    dragOffset = 0
                    atLimit = false
                    isClosing = false
                }
        )
        .splitDividerFeedback(isDragging: isDragging, atLimit: atLimit, isClosing: isClosing)
        .accessibilityElement()
        .accessibilityLabel("Panel divider")
        .accessibilityHint("Drag to resize the panel")
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var date: Date = Date.now

        var body: some View {
            SplitReaderView(
                date: $date
            )
        }
    }

    return PreviewWrapper()
}
