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

    @State private var currentBook: Int = 1
    @State private var currentChapter: Int = 1
    @State private var currentVerse: Int = 1
    @State private var scrollToVerse: Int? = nil
    @SceneStorage("readerCurrentVerseId") private var currentVerseId: Int = 1001001

    // Resizable panel state
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
            if user.notesEnabled && user.notesPanelVisible {
                splitView
            } else {
                readerContent
            }
        }
        .onChange(of: currentVerseId) { _, newValue in
            let (verse, chapter, book) = splitVerseId(newValue)
            let chapterChanged = currentChapter != chapter || currentBook != book
            currentBook = book
            currentChapter = chapter
            currentVerse = verse

            // Scroll-link: when verse changes, scroll notes panel to matching section
            // Only auto-scroll if chapter didn't change (to avoid jumping during chapter navigation)
            if !chapterChanged {
                scrollToVerse = verse
            }
        }
        .onAppear {
            let (verse, chapter, book) = splitVerseId(currentVerseId)
            currentBook = book
            currentChapter = chapter
            currentVerse = verse
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
                                }
                        )

                    notesPanelContent
                        .frame(width: rightPanelWidth)
                }
                .onAppear {
                    if rightPanelWidth == 350 {
                        rightPanelWidth = min(350, geometry.size.width * 0.4)
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
                                }
                        )

                    notesPanelContent
                        .frame(height: bottomPanelHeight)
                }
                .onAppear {
                    if bottomPanelHeight == 0 {
                        bottomPanelHeight = geometry.size.height * 0.4
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
            onVerseAction: handleVerseAction
        )
    }

    @ViewBuilder
    private var notesPanelContent: some View {
        NotesPanelView(
            book: currentBook,
            chapter: currentChapter,
            scrollToVerse: $scrollToVerse,
            user: user
        )
    }

    private func handleVerseAction(verse: Int, action: VerseAction) {
        switch action {
        case .addNote:
            // Show notes panel and scroll to verse
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
