//
//  SplitReaderView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import RealmSwift
import SwiftUI

struct SplitReaderView: View {
    @ObservedRealmObject var user: User
    @Binding var date: Date
    var readingMetaData: [ReadingMetaData]?

    @State private var scrollToVerse: Int? = nil
    @State private var requestScrollToVerseId: Int? = nil
    @State private var requestScrollAnimated: Bool = true
    @SceneStorage("readerCurrentVerseId") private var currentVerseId: Int = 1001001
    @State private var lastVerseId: Int = 0  // Track previous value for change detection
    @State private var suppressScrollLink: Bool = false
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
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
    @State private var isDragging: Bool = false

    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var effectiveOrientation: String {
        // On iPhone (compact), always use bottom
        if isCompact {
            return "bottom"
        }
        return user.notesPanelOrientation
    }

    // Minimum and maximum sizes for panels
    private let minPanelSize: CGFloat = 150
    private let maxPanelRatio: CGFloat = 0.7

    var body: some View {
        Group {
            if user.notesPanelVisible {
                splitView
            } else {
                readerContent
            }
        }
        .onChange(of: currentVerseId) { oldValue, newValue in
            let (_, oldChapter, oldBook) = splitVerseId(oldValue)
            let (newVerse, newChapter, newBook) = splitVerseId(newValue)
            let chapterChanged = oldChapter != newChapter || oldBook != newBook

            // Scroll-link: when verse changes, scroll tool panel to matching section
            // Only auto-scroll after initial load, if chapter didn't change, not suppressed, and scroll linking is enabled
            if hasUserScrolled && !chapterChanged && !suppressScrollLink && isScrollLinked {
                scrollToVerse = newVerse
            }
            // Reset suppress flag
            suppressScrollLink = false
        }
        .onAppear {
            // Enable scroll linking after initial load completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                hasUserScrolled = true
            }
        }
        .task {
            // Check iCloud availability and disable notes if not available
            if user.notesEnabled {
                let isAvailable = await ICloudNoteStorage.shared.isAvailable()
                if !isAvailable {
                    try? RealmManager.shared.realm.write {
                        guard let thawedUser = user.thaw() else { return }
                        thawedUser.notesEnabled = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var splitView: some View {
        if effectiveOrientation == "right" {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    readerContent
                        .frame(maxWidth: .infinity)

                    // Drag handle
                    dragHandle(isVertical: true)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDragging = true
                                    let newWidth = rightPanelWidth - value.translation.width
                                    rightPanelWidth = min(max(newWidth, minPanelSize), geometry.size.width * maxPanelRatio)
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    storedRightPanelWidth = Double(rightPanelWidth)
                                }
                        )

                    toolPanelContent
                        .frame(width: rightPanelWidth)
                }
                .onAppear {
                    if storedRightPanelWidth != 0 {
                        rightPanelWidth = CGFloat(storedRightPanelWidth)
                    } else {
                        // Default to 1/3 of viewport width
                        rightPanelWidth = min(350, geometry.size.width / 3)
                    }
                }
            }
        } else {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    readerContent
                        .frame(height: geometry.size.height - bottomPanelHeight - 12)

                    // Drag handle
                    dragHandle(isVertical: false)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    isDragging = true
                                    let newHeight = bottomPanelHeight - value.translation.height
                                    bottomPanelHeight = min(max(newHeight, minPanelSize), geometry.size.height * maxPanelRatio)
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    storedBottomPanelHeight = Double(bottomPanelHeight)
                                }
                        )

                    toolPanelContent
                        .frame(height: bottomPanelHeight)
                }
                .onAppear {
                    if storedBottomPanelHeight != 0 {
                        bottomPanelHeight = CGFloat(storedBottomPanelHeight)
                    } else {
                        // Default to 1/3 of viewport height
                        bottomPanelHeight = geometry.size.height / 3
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dragHandle(isVertical: Bool) -> some View {
        if isVertical {
            // Vertical divider with horizontal drag handle
            ZStack {
                Rectangle()
                    .fill(Color(UIColor.separator))
                    .frame(width: 1)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(UIColor.systemGray3))
                    .frame(width: 4, height: 40)
            }
            .frame(width: 12)
            .contentShape(Rectangle())
            .background(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
        } else {
            // Horizontal divider with vertical drag handle
            ZStack {
                Rectangle()
                    .fill(Color(UIColor.separator))
                    .frame(height: 1)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(UIColor.systemGray3))
                    .frame(width: 40, height: 4)
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .background(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
        }
    }

    @ViewBuilder
    private var readerContent: some View {
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

    @ViewBuilder
    private var toolPanelContent: some View {
        ToolPanelView(
            book: currentBook,
            chapter: currentChapter,
            currentVerse: currentVerse,
            scrollToVerse: $scrollToVerse,
            user: user,
            onNavigateToVerse: { verseId in
                // Suppress scroll-link to prevent tool pane from scrolling away
                suppressScrollLink = true
                // Request the Bible panel to scroll to this verse (no animation for direct navigation)
                requestScrollAnimated = false
                requestScrollToVerseId = verseId
            },
            onVisibleVerseChanged: { verse in
                // Only scroll-link after user has scrolled (prevents scroll on initial load)
                guard hasUserScrolled else { return }
                // Scroll Bible pane to match tool pane's visible verse (animated for scroll-linking)
                suppressScrollLink = true
                requestScrollAnimated = true
                requestScrollToVerseId = currentBook * 1000000 + currentChapter * 1000 + verse
            }
        )
    }

    private func handleVerseAction(verse: Int, action: VerseAction) {
        switch action {
        case .addNote:
            // Show tool panel and scroll to verse
            if !user.notesPanelVisible {
                try? RealmManager.shared.realm.write {
                    guard let thawedUser = user.thaw() else { return }
                    thawedUser.notesPanelVisible = true
                }
            }
            scrollToVerse = verse
        case .viewCrossReferences:
            // Handled by ReaderView internally
            break
        }
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
