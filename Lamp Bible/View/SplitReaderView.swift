//
//  SplitReaderView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import RealmSwift
import SwiftUI

/// Tracks who initiated the most recent scroll to prevent feedback loops
/// Used by ReaderView for legacy compatibility
enum ScrollOrigin: Equatable {
    case none
    case bible
    case toolPanel
}

struct SplitReaderView: View {
    @ObservedRealmObject var user: User
    @Binding var date: Date
    var readingMetaData: [ReadingMetaData]?
    var initialVerseId: Int? = nil
    var initialTranslation: Translation? = nil

    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = true
    @SceneStorage("readerCurrentVerseId") private var currentVerseId: Int = 1001001
    @State private var hasAppliedInitialVerse: Bool = false
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
    @State private var hasUserScrolled: Bool = false

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

                        // Static Divider Space
                        Rectangle()
                            .fill(Color(UIColor.separator))
                            .frame(width: 1)
                            .padding(.horizontal, 5.5) // Total 12 width
                            .frame(width: 12)
                            .contentShape(Rectangle())

                        toolPanelContent
                            .frame(width: rightPanelWidth)
                    }
                } else {
                    VStack(spacing: 0) {
                        readerContent
                            .frame(height: geometry.size.height - bottomPanelHeight - 12)

                        // Static Divider Space
                        Rectangle()
                            .fill(Color(UIColor.separator))
                            .frame(height: 1)
                            .padding(.vertical, 5.5) // Total 12 height
                            .frame(height: 12)
                            .contentShape(Rectangle())

                        toolPanelContent
                            .frame(height: bottomPanelHeight)
                    }
                }

                // Layer 2: Interactive Drag Overlay
                SplitDragOverlay(
                    isVertical: effectiveOrientation == "right",
                    panelSize: effectiveOrientation == "right" ? $rightPanelWidth : $bottomPanelHeight,
                    containerSize: geometry.size,
                    minPanelSize: minPanelSize,
                    maxPanelRatio: maxPanelRatio,
                    onDragEnd: { newSize in
                        if effectiveOrientation == "right" {
                            storedRightPanelWidth = Double(newSize)
                        } else {
                            storedBottomPanelHeight = Double(newSize)
                        }
                    }
                )
            }
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
        Group {
            if let translation = initialTranslation {
                ReaderView(
                    user: user,
                    date: $date,
                    readingMetaData: readingMetaData,
                    translation: translation,
                    onVerseAction: handleVerseAction,
                    requestScrollToVerseId: $requestScrollToVerseId,
                    requestScrollAnimated: $requestScrollAnimated,
                    visibleVerseId: $currentVerseId
                )
            } else {
                ReaderView(
                    user: user,
                    date: $date,
                    readingMetaData: readingMetaData,
                    onVerseAction: handleVerseAction,
                    requestScrollToVerseId: $requestScrollToVerseId,
                    requestScrollAnimated: $requestScrollAnimated,
                    visibleVerseId: $currentVerseId
                )
            }
        }
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
            user: user,
            onNavigateToVerse: { verseId in
                // Direct navigation - bypass coordinator, just scroll reader
                requestScrollAnimated = false
                requestScrollToVerseId = verseId
            }
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
        case .viewCrossReferences:
            // Handled by ReaderView internally
            break
        }
    }
}

struct SplitDragOverlay: View {
    let isVertical: Bool
    @Binding var panelSize: CGFloat
    let containerSize: CGSize
    let minPanelSize: CGFloat
    let maxPanelRatio: CGFloat
    let onDragEnd: (CGFloat) -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    @State private var initialPanelSize: CGFloat? = nil
    @State private var lastUpdate: Date = Date.distantPast

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
        let currentBaseSize = initialPanelSize ?? panelSize
        // Calculate where the handle *should* be based on the drag, not the lagging panelSize
        let visualPanelSize = calculateNewSize(baseSize: currentBaseSize, translation: dragOffset)

        if isVertical {
            let x = containerSize.width - visualPanelSize - (handleThickness / 2)
            return CGPoint(x: x, y: containerSize.height / 2)
        } else {
            let y = containerSize.height - visualPanelSize - (handleThickness / 2)
            return CGPoint(x: containerSize.width / 2, y: y)
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
                user: RealmManager.shared.realm.objects(User.self).first!,
                date: $date
            )
        }
    }

    return PreviewWrapper()
}
