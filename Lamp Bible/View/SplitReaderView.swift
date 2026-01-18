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

    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = true
    @SceneStorage("readerCurrentVerseId") private var currentVerseId: Int = 1001001
    @State private var hasAppliedInitialVerse: Bool = false
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
    @State private var hasUserScrolled: Bool = false
    @State private var toolbarsHidden: Bool = false

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

    // Resizable panel state - persisted across sessions
    @SceneStorage("toolPanelBottomHeightV2") private var storedBottomPanelHeight: Double = 0
    @SceneStorage("toolPanelRightWidthV2") private var storedRightPanelWidth: Double = 0
    @State private var bottomPanelHeight: CGFloat = 0
    @State private var rightPanelWidth: CGFloat = 350

    // Divider position tracking for overlay alignment
    @State private var dividerY: CGFloat = 0

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
        .background(Color(UIColor.systemBackground))
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear {
            // Enable scroll linking after initial load completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                hasUserScrolled = true
            }
        }
        // Note: Scroll sync is now handled entirely by UIKit via ReaderScrollSpy and ScrollSyncCoordinator
    }

    @ViewBuilder
    private var splitView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Layer 1: Content
                if effectiveOrientation == "right" {
                    HStack(spacing: 0) {
                        readerContent
                            .frame(maxWidth: .infinity)

                        // Static Divider
                        Rectangle()
                            .fill(Color(UIColor.separator))
                            .frame(width: 1)
                            .padding(.horizontal, 5.5)
                            .frame(width: 12)
                            .contentShape(Rectangle())

                        toolPanelContent
                            .frame(width: rightPanelWidth)
                    }
                } else {
                    VStack(spacing: 0) {
                        readerContent
                            .frame(height: geometry.size.height - bottomPanelHeight - 12)

                        // Divider with integrated drag handle
                        BottomPanelDivider(
                            panelHeight: $bottomPanelHeight,
                            containerHeight: geometry.size.height,
                            minPanelSize: minPanelSize,
                            maxPanelRatio: maxPanelRatio,
                            onDragEnd: {
                                storedBottomPanelHeight = Double(bottomPanelHeight)
                            }
                        )

                        toolPanelContent
                            .frame(height: bottomPanelHeight)
                    }
                }

                // Layer 2: Interactive Drag Overlay (only for right panel - bottom uses inline handle)
                if effectiveOrientation == "right" {
                    SplitDragOverlay(
                        isVertical: true,
                        panelSize: $rightPanelWidth,
                        containerSize: geometry.size,
                        minPanelSize: minPanelSize,
                        maxPanelRatio: maxPanelRatio,
                        dividerY: dividerY,
                        onDragEnd: { newSize in
                            storedRightPanelWidth = Double(newSize)
                        }
                    )
                }
            }
            .coordinateSpace(name: "splitContainer")
            .onPreferenceChange(DividerPositionKey.self) { value in
                dividerY = value
            }
            // Allow split content (including ToolPanelView) to extend behind the bottom toolbar
            // so there isn't a blank/black strip under it.
            .background(Color(UIColor.systemBackground))
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
            onVerseAction: handleVerseAction,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            visibleVerseId: $currentVerseId,
            toolbarsHidden: $toolbarsHidden,
            initialToolbarMode: initialToolbarMode
        )
        .onAppear {
            // Scroll to initial verse if provided
            if let verseId = initialVerseId, !hasAppliedInitialVerse {
                hasAppliedInitialVerse = true
                requestScrollAnimated = false
                requestScrollToVerseId = verseId
            }
        }
    }

    @ViewBuilder
    private var toolPanelContent: some View {
        ToolPanelView(
            book: currentBook,
            chapter: currentChapter,
            currentVerse: currentVerse,
            onNavigateToVerse: { verseId in
                // Direct navigation - bypass coordinator, just scroll reader
                requestScrollAnimated = false
                requestScrollToVerseId = verseId
            },
            toolbarsHidden: $toolbarsHidden
        )
    }

    private func handleVerseAction(verse: Int, action: VerseAction) {
        switch action {
        case .addNote:
            // Show tool panel and scroll to verse
            if !notesPanelVisible {
                notesPanelVisible = true
            }
            // Tool panel will pick up the verse from currentVerse
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
struct BottomPanelDivider: View {
    @Binding var panelHeight: CGFloat
    let containerHeight: CGFloat
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    let onDragEnd: () -> Void

    @State private var isDragging: Bool = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 1)

            // Drag handle pill
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(UIColor.systemGray3))
                .frame(width: 40, height: 4)
        }
        .padding(.vertical, 5.5)
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .background(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                    }
                    let translation = value.translation.height
                    let newHeight = max(minPanelSize, min(panelHeight - translation, containerHeight * maxPanelRatio))
                    panelHeight = newHeight
                }
                .onEnded { _ in
                    isDragging = false
                    onDragEnd()
                }
        )
    }
}

struct SplitDragOverlay: View {
    let isVertical: Bool
    @Binding var panelSize: CGFloat
    let containerSize: CGSize
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    let dividerY: CGFloat  // Y position of actual divider in splitContainer coordinate space
    let onDragEnd: (CGFloat) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var initialPanelSize: CGFloat? = nil
    @State private var lastUpdate: Date = Date.distantPast
    @State private var keyboardHeight: CGFloat = 0

    // Constants matching the main view
    private let handleThickness: CGFloat = 12
    private let throttleInterval: TimeInterval = 0.032 // ~30fps

    var body: some View {
        ZStack {
            // The Hit Area & Visual Handle
            handleVisual
                .position(handlePosition)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                initialPanelSize = panelSize
                            }

                            let translation = isVertical ? value.translation.width : value.translation.height
                            dragOffset = translation

                            // Throttled update of the actual panel size
                            let now = Date()
                            if now.timeIntervalSince(lastUpdate) > throttleInterval {
                                updatePanelSize(translation: translation)
                                lastUpdate = now
                            }
                        }
                        .onEnded { value in
                            let translation = isVertical ? value.translation.width : value.translation.height
                            updatePanelSize(translation: translation)

                            // Persist final size
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    private func calculateNewSize(baseSize: CGFloat, translation: CGFloat) -> CGFloat {
        // Dragging left/up increases panel size (for right/bottom panels)
        let newSize = baseSize - translation
        return min(max(newSize, minPanelSize), (isVertical ? containerSize.width : containerSize.height) * maxPanelRatio)
    }

    private func updatePanelSize(translation: CGFloat) {
        guard let baseSize = initialPanelSize else { return }
        panelSize = calculateNewSize(baseSize: baseSize, translation: translation)
    }

    private var handlePosition: CGPoint {
        if isVertical {
            let currentBaseSize = initialPanelSize ?? panelSize
            let visualPanelSize = calculateNewSize(baseSize: currentBaseSize, translation: dragOffset)
            let x = containerSize.width - visualPanelSize - (handleThickness / 2)
            return CGPoint(x: x, y: containerSize.height / 2)
        } else {
            // For horizontal split (bottom panel):
            // - During drag: calculate from drag offset for smooth feedback
            // - Otherwise: use actual divider Y position (handles keyboard push-up)
            // Minimum Y to keep handle below top header area
            let minY: CGFloat = handleThickness

            if isDragging {
                let currentBaseSize = initialPanelSize ?? panelSize
                let visualPanelSize = calculateNewSize(baseSize: currentBaseSize, translation: dragOffset)
                let y = containerSize.height - visualPanelSize - (handleThickness / 2)
                return CGPoint(x: containerSize.width / 2, y: max(y, minY))
            } else {
                // Use dividerY directly - it tracks the actual divider position
                let y = dividerY > 0 ? dividerY : containerSize.height - panelSize - (handleThickness / 2)
                return CGPoint(x: containerSize.width / 2, y: max(y, minY))
            }
        }
    }

    private var handleVisual: some View {
        Group {
            if isVertical {
                ZStack {
                    Rectangle()
                        .fill(Color.clear) // Transparent hit area
                        .frame(width: handleThickness)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(UIColor.systemGray3))
                        .frame(width: 4, height: 40)
                }
                .frame(width: handleThickness)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.clear) // Transparent hit area
                        .frame(height: handleThickness)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(UIColor.systemGray3))
                        .frame(width: 40, height: 4)
                }
                .frame(height: handleThickness)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .background(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
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
