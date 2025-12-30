//
//  ReaderPlanToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI
import RealmSwift

enum BottomToolbarMode: String {
    case navigation = "navigation"
    case history = "history"
    case search = "search"

    var label: String {
        switch self {
        case .navigation: return "Navigate"
        case .history: return "History"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .navigation: return "book.pages"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        }
    }
}

// MARK: - Reading Plan Toolbar

struct ReadingPlanToolbarView: ToolbarContent {
    @Binding var readingMetaData: [ReadingMetaData]
    @Binding var currentReadingIndex: Int
    @Binding var date: Date

    var body: some ToolbarContent {
        if readingMetaData.count > 1 {
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    currentReadingIndex -= 1
                }) {
                    Image(systemName: "chevron.left")
                }
                .frame(width: 36, height: 36)
                .disabled(currentReadingIndex == 0)
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            VStack {
                HStack {
                    Text(date, format: .dateTime.weekday().day().month())
                    Divider()
                    Text("Portion")
                        .padding(.trailing, -3)
                    ForEach(0..<currentReadingIndex + 1, id: \.self) { _ in
                        Image("lampflame.fill")
                            .font(.system(size: 11))
                            .padding(.trailing, -11)
                            .padding(.leading, -3)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity)
                Text(readingMetaData[currentReadingIndex].description)
                    .font(.system(size: 16))
            }
            .padding(.top, 2.5)
            .padding(.bottom, 2.5)
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        if readingMetaData.count > 1 {
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    currentReadingIndex += 1
                }) {
                    Image(systemName: "chevron.right")
                }
                .frame(width: 36, height: 36)
                .disabled(currentReadingIndex == readingMetaData.count - 1)
            }
        }
    }
}

// MARK: - Mode Button Toolbar Item

struct ModeButtonToolbarItem: ToolbarContent {
    @Binding var toolbarMode: BottomToolbarMode
    let translationAbbreviation: String

    private func label(for mode: BottomToolbarMode) -> String {
        switch mode {
        case .navigation: return "Navigate Books/Chapters"
        case .history: return "History"
        case .search: return "Search \(translationAbbreviation)"
        }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Menu {
                ForEach([BottomToolbarMode.navigation, .history, .search], id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toolbarMode = mode
                        }
                    } label: {
                        Label(label(for: mode), systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: toolbarMode.icon)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .frame(height: 36)
        }
    }
}

// MARK: - Search Mode Toolbar

struct SearchModeToolbarItems: ToolbarContent {
    @Binding var searchText: String
    @Binding var showingSearch: Bool
    let translationAbbreviation: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            InlineSearchBar(
                text: $searchText,
                placeholder: "Search \(translationAbbreviation)",
                onSubmit: { showingSearch = true }
            )
        }
    }
}

// MARK: - Inline Search Bar

struct InlineSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    @State private var isKeyboardVisible: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    if !text.isEmpty {
                        onSubmit()
                    }
                }

            // Show clear button when keyboard is open, search button when not
            if isKeyboardVisible {
                Button {
                    text = ""
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onSubmit()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}

// MARK: - Navigation Mode Toolbar

struct NavigationModeToolbarItems: ToolbarContent {
    let currentBook: Int
    let currentChapter: Int
    let firstBook: Int
    let firstChapter: Int
    let lastBook: Int
    let lastChapter: Int
    let loadPrev: () -> Void
    let loadNext: () -> Void
    let loadPrevBook: () -> Void
    let loadNextBook: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            NavigationToolbarContent(
                currentBook: currentBook,
                currentChapter: currentChapter,
                firstBook: firstBook,
                firstChapter: firstChapter,
                lastBook: lastBook,
                lastChapter: lastChapter,
                loadPrev: loadPrev,
                loadNext: loadNext,
                loadPrevBook: loadPrevBook,
                loadNextBook: loadNextBook
            )
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
    }
}

// MARK: - History Mode Toolbar

struct HistoryModeToolbarItems: ToolbarContent {
    let currentVerseId: Int
    let navigateToVerseId: (Int) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            HistoryToolbarContent(
                currentVerseId: currentVerseId,
                navigateToVerseId: navigateToVerseId
            )
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
    }
}

// MARK: - Navigation Toolbar Content

struct NavigationToolbarContent: View {
    let currentBook: Int
    let currentChapter: Int
    let firstBook: Int
    let firstChapter: Int
    let lastBook: Int
    let lastChapter: Int
    let loadPrev: () -> Void
    let loadNext: () -> Void
    let loadPrevBook: () -> Void
    let loadNextBook: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Previous chapter
            Button(action: loadPrev) {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == firstBook && currentChapter == firstChapter)

            // Book navigation (side-by-side)
            HStack(spacing: 4) {
                Button(action: loadPrevBook) {
                    Image(systemName: "chevron.up")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentBook == firstBook)

                Button(action: loadNextBook) {
                    Image(systemName: "chevron.down")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentBook == lastBook)
            }

            // Next chapter
            Button(action: loadNext) {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == lastBook && currentChapter == lastChapter)
        }
        .frame(height: 36)
    }
}

// MARK: - History Toolbar Content

struct HistoryToolbarContent: View {
    let currentVerseId: Int
    let navigateToVerseId: (Int) -> Void
    @ObservedObject private var history = NavigationHistory.shared
    @State private var showingHistoryList: Bool = false

    var body: some View {
        HStack(spacing: 24) {
            Button {
                if let verseId = history.goBack(savingPosition: currentVerseId) {
                    navigateToVerseId(verseId)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .disabled(!history.canGoBack)

            // History indicator - tap to show full list
            if history.history.count > 0 {
                Button {
                    showingHistoryList = true
                } label: {
                    Text("\(history.currentIndex + 1) of \(history.history.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .popover(isPresented: $showingHistoryList) {
                    HistoryListPopover(
                        currentVerseId: currentVerseId,
                        navigateToVerseId: { verseId in
                            showingHistoryList = false
                            navigateToVerseId(verseId)
                        }
                    )
                }
            }

            Button {
                if let verseId = history.goForward(savingPosition: currentVerseId) {
                    navigateToVerseId(verseId)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
            }
            .disabled(!history.canGoForward)
        }
        .frame(height: 36)
    }
}

// MARK: - History List Popover

struct HistoryListPopover: View {
    let currentVerseId: Int
    let navigateToVerseId: (Int) -> Void
    @ObservedObject private var history = NavigationHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.headline)
                .padding()

            Divider()

            if history.history.isEmpty {
                Text("No history yet")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(history.allHistory(), id: \.index) { item in
                                Button {
                                    if let verseId = history.goToIndex(item.index, savingPosition: currentVerseId) {
                                        navigateToVerseId(verseId)
                                    }
                                } label: {
                                    HStack {
                                        Text(item.description)
                                            .foregroundStyle(item.index == history.currentIndex ? .primary : .secondary)
                                        Spacer()
                                        if item.index == history.currentIndex {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(item.index)

                                if item.index < history.history.count - 1 {
                                    Divider()
                                        .padding(.leading)
                                }
                            }
                        }
                    }
                    .onAppear {
                        // Scroll to current position
                        proxy.scrollTo(history.currentIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 200, maxWidth: 280)
        .frame(maxHeight: 300)
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Main Toolbar View

struct ReaderBottomToolbarView: ToolbarContent {
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var currentReadingIndex: Int
    @Binding var date: Date
    @Binding var translation: Translation
    @Binding var currentVerseId: Int
    @Binding var showingSearch: Bool
    @Binding var searchText: String
    let loadPrev: () -> Void
    let loadNext: () -> Void
    let loadPrevBook: () -> Void
    let loadNextBook: () -> Void
    let navigateToVerseId: (Int) -> Void

    @AppStorage("bottomToolbarMode") private var toolbarMode: BottomToolbarMode = .navigation

    private var currentBook: Int { currentVerseId / 1000000 }
    private var currentChapter: Int { (currentVerseId % 1000000) / 1000 }
    private var firstBook: Int { translation.verses.first!.id / 1000000 }
    private var firstChapter: Int { (translation.verses.first!.id % 1000000) / 1000 }
    private var lastBook: Int { translation.verses.last!.id / 1000000 }
    private var lastChapter: Int { (translation.verses.last!.id % 1000000) / 1000 }

    var body: some ToolbarContent {
        if readingMetaData != nil {
            readingPlanContent
        } else {
            freeNavigationContent
        }
    }

    @ToolbarContentBuilder
    private var readingPlanContent: some ToolbarContent {
        ReadingPlanToolbarView(
            readingMetaData: Binding(
                get: { readingMetaData! },
                set: { _ in }
            ),
            currentReadingIndex: $currentReadingIndex,
            date: $date
        )
    }

    @ToolbarContentBuilder
    private var freeNavigationContent: some ToolbarContent {
        ModeButtonToolbarItem(
            toolbarMode: $toolbarMode,
            translationAbbreviation: translation.abbreviation
        )

        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }

        modeSpecificContent
    }

    @ToolbarContentBuilder
    private var modeSpecificContent: some ToolbarContent {
        switch toolbarMode {
        case .navigation:
            NavigationModeToolbarItems(
                currentBook: currentBook,
                currentChapter: currentChapter,
                firstBook: firstBook,
                firstChapter: firstChapter,
                lastBook: lastBook,
                lastChapter: lastChapter,
                loadPrev: loadPrev,
                loadNext: loadNext,
                loadPrevBook: loadPrevBook,
                loadNextBook: loadNextBook
            )
        case .history:
            HistoryModeToolbarItems(
                currentVerseId: currentVerseId,
                navigateToVerseId: navigateToVerseId
            )
        case .search:
            SearchModeToolbarItems(
                searchText: $searchText,
                showingSearch: $showingSearch,
                translationAbbreviation: translation.abbreviation
            )
        }
    }
}
