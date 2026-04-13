//
//  ReaderPlanToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI

enum BottomToolbarMode: String {
    case navigation = "navigation"
    case history = "history"
    case search = "search"
    case plan = "plan"

    var label: String {
        switch self {
        case .navigation: return "Navigate"
        case .history: return "History"
        case .search: return "Search"
        case .plan: return "Plan"
        }
    }

    var icon: String {
        switch self {
        case .navigation: return "book.pages"
        case .history: return "clock.arrow.circlepath"
        case .search: return "magnifyingglass"
        case .plan: return "book.fill"
        }
    }
}

//// MARK: - Reading Plan Toolbar

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

/// MARK: - Mode Button Toolbar Item

struct ModeButtonToolbarItem: ToolbarContent {
    @Binding var toolbarMode: BottomToolbarMode
    let translationAbbreviation: String
    let hasPlanReadings: Bool
    let date: Date

    private func menuLabel(for mode: BottomToolbarMode) -> String {
        switch mode {
        case .navigation: return "Navigate Chapter/Book"
        case .history: return "History"
        case .search: return "Search \(translationAbbreviation)"
        case .plan:
            if Calendar.current.isDateInToday(date) {
                return "Readings (Today)"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d"
                return "Readings (\(formatter.string(from: date)))"
            }
        }
    }

    private var availableModes: [BottomToolbarMode] {
        // Menu displays bottom-to-top, so reverse order for: Search, History, Navigate, Readings
        var modes: [BottomToolbarMode] = []
        if hasPlanReadings {
            modes.append(.plan)  // Readings at bottom of menu
        }
        modes.append(contentsOf: [.navigation, .history, .search])  // Search at top
        return modes
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Menu {
                ForEach(availableModes, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toolbarMode = mode
                        }
                    } label: {
                        Label(menuLabel(for: mode), systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: toolbarMode.icon)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .frame(width: 36, height: 36)
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
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
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
            .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity)
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
        HStack(spacing: 8) {
            // Chapter navigation (up/down)
            Button(action: loadPrev) {
                Image(systemName: "chevron.up")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == firstBook && currentChapter == firstChapter)

            Text("Ch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()

            Button(action: loadNext) {
                Image(systemName: "chevron.down")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == lastBook && currentChapter == lastChapter)

            Spacer()

            // Book navigation (left/right)
            Button(action: loadPrevBook) {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == firstBook)

            Text("Bk.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()

            Button(action: loadNextBook) {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
            }
            .disabled(currentBook == lastBook)
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
        HStack(spacing: 0) {
            Button {
                if let verseId = history.goBack(savingPosition: currentVerseId) {
                    navigateToVerseId(verseId)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
            }
            .disabled(!history.canGoBack)

            Spacer()

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

            Spacer()

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

// MARK: - Plan Data for Toolbar

struct PlanWithReadings: Equatable {
    let id: String
    let name: String
    let readings: [ReadingMetaData]

    static func == (lhs: PlanWithReadings, rhs: PlanWithReadings) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Plan Mode Toolbar Items

struct PlanModeToolbarItems: ToolbarContent {
    @Binding var date: Date
    @Binding var currentReadingIndex: Int
    @Binding var selectedPlanIndex: Int
    let plansWithReadings: [PlanWithReadings]
    let onReadingChanged: (Int) -> Void
    let onPlanChanged: (Int) -> Void
    var onQuiz: (() -> Void)? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            PlanToolbarContent(
                date: date,
                currentReadingIndex: $currentReadingIndex,
                selectedPlanIndex: $selectedPlanIndex,
                plansWithReadings: plansWithReadings,
                onReadingChanged: onReadingChanged,
                onPlanChanged: onPlanChanged,
                onQuiz: onQuiz
            )
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Plan Toolbar Content

struct PlanToolbarContent: View {
    let date: Date
    @Binding var currentReadingIndex: Int
    @Binding var selectedPlanIndex: Int
    let plansWithReadings: [PlanWithReadings]
    let onReadingChanged: (Int) -> Void
    let onPlanChanged: (Int) -> Void
    var onQuiz: (() -> Void)? = nil
    @State private var showingPlanPicker: Bool = false

    private var hasMultiplePlans: Bool {
        plansWithReadings.count > 1
    }

    private var currentPlan: PlanWithReadings? {
        guard selectedPlanIndex >= 0 && selectedPlanIndex < plansWithReadings.count else { return nil }
        return plansWithReadings[selectedPlanIndex]
    }

    private var currentReadings: [ReadingMetaData] {
        currentPlan?.readings ?? []
    }

    private var centerContentMaxWidth: CGFloat {
        // Scale with screen width: ~35% of screen, clamped between 120-350
        let screenWidth = UIScreen.main.bounds.width
        return min(max(screenWidth * 0.35, 120), 350)
    }

    var body: some View {
        if plansWithReadings.isEmpty {
            Text("No readings for today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 36)
        } else if let plan = currentPlan, !currentReadings.isEmpty {
            HStack(spacing: 24) {
                Button {
                    let newIndex = currentReadingIndex - 1
                    currentReadingIndex = newIndex
                    onReadingChanged(newIndex)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentReadingIndex == 0)

                // Center content - tap to show plan info popover
                Button {
                    showingPlanPicker = true
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(plan.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if currentReadings.count > 1 {
                                Text("·")
                                Text("\(currentReadingIndex + 1)/\(currentReadings.count)")
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        Text(currentReadings[currentReadingIndex].description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: centerContentMaxWidth)
                }
                .popover(isPresented: $showingPlanPicker) {
                    PlanInfoPopover(
                        reading: currentReadings[currentReadingIndex],
                        plansWithReadings: plansWithReadings,
                        selectedPlanIndex: selectedPlanIndex,
                        onSelectPlan: { index in
                            showingPlanPicker = false
                            selectedPlanIndex = index
                            currentReadingIndex = 0
                            onPlanChanged(index)
                        },
                        onQuiz: onQuiz != nil ? {
                            showingPlanPicker = false
                            // Delay to let popover dismiss before presenting sheet
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                onQuiz?()
                            }
                        } : nil
                    )
                }

                Button {
                    let newIndex = currentReadingIndex + 1
                    currentReadingIndex = newIndex
                    onReadingChanged(newIndex)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 36)
                }
                .disabled(currentReadingIndex == currentReadings.count - 1)
            }
            .frame(height: 36)
        } else {
            Text("No readings for today")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 36)
        }
    }
}

// MARK: - Plan Info Popover

struct PlanInfoPopover: View {
    let reading: ReadingMetaData
    let plansWithReadings: [PlanWithReadings]
    let selectedPlanIndex: Int
    let onSelectPlan: (Int) -> Void
    var onQuiz: (() -> Void)? = nil
    @State private var readerCount: Int = UserDatabase.shared.getSettings().planReaderCount

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Reading info section
            VStack(alignment: .leading, spacing: 6) {
                Text(reading.description)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text("\(reading.verseCount) verses")
                    Text("·")
                    Text("~\(reading.readingTime) min")
                    Text("·")
                    Text(reading.genre)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ReaderSplitControl(
                    chapterVerseCounts: reading.chapterVerseCounts,
                    readerCount: $readerCount
                )
            }
            .padding()
            .onChange(of: readerCount) { _, newValue in
                try? UserDatabase.shared.updateSettings { $0.planReaderCount = newValue }
            }

            // Quiz button
            if let onQuiz = onQuiz {
                Divider()

                Button {
                    onQuiz()
                } label: {
                    HStack {
                        Label("Quiz", systemImage: "questionmark.circle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Plan switcher section (when multiple plans)
            if plansWithReadings.count > 1 {
                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Text("Plans")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    ForEach(Array(plansWithReadings.enumerated()), id: \.element.id) { index, plan in
                        Button {
                            onSelectPlan(index)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.name)
                                        .foregroundStyle(index == selectedPlanIndex ? .primary : .secondary)
                                    Text("\(plan.readings.count) reading\(plan.readings.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if index == selectedPlanIndex {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < plansWithReadings.count - 1 {
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
        .frame(maxHeight: 400)
        .presentationCompactAdaptation(.popover)
    }
}

/// MARK: - Main Toolbar View

struct ReaderBottomToolbarView: ToolbarContent {
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var currentReadingIndex: Int
    @Binding var date: Date
    @Binding var translationId: String
    @Binding var translationAbbreviation: String
    @Binding var currentVerseId: Int
    @Binding var showingSearch: Bool
    @Binding var searchText: String
    @Binding var toolbarMode: BottomToolbarMode
    @Binding var selectedPlanIndex: Int
    let plansWithReadings: [PlanWithReadings]
    let loadPrev: () -> Void
    let loadNext: () -> Void
    let loadPrevBook: () -> Void
    let loadNextBook: () -> Void
    let navigateToVerseId: (Int) -> Void
    let onPlanReadingChanged: (Int) -> Void
    let onPlanChanged: (Int) -> Void
    var onQuiz: (() -> Void)? = nil

    private var hasPlanReadings: Bool {
        !plansWithReadings.isEmpty
    }

    private var currentBook: Int { currentVerseId / 1000000 }
    private var currentChapter: Int { (currentVerseId % 1000000) / 1000 }
    // Standard Bible covers Genesis (1) through Revelation (66)
    private var firstBook: Int { 1 }
    private var firstChapter: Int { 1 }
    private var lastBook: Int { 66 }
    private var lastChapter: Int { 22 }  // Revelation has 22 chapters

    var body: some ToolbarContent {
        // Always show mode button and mode-specific content
        freeNavigationContent
    }

    @ToolbarContentBuilder
    private var freeNavigationContent: some ToolbarContent {
        ModeButtonToolbarItem(
            toolbarMode: $toolbarMode,
            translationAbbreviation: translationAbbreviation,
            hasPlanReadings: hasPlanReadings,
            date: date
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
                translationAbbreviation: translationAbbreviation
            )
        case .plan:
            PlanModeToolbarItems(
                date: $date,
                currentReadingIndex: $currentReadingIndex,
                selectedPlanIndex: $selectedPlanIndex,
                plansWithReadings: plansWithReadings,
                onReadingChanged: onPlanReadingChanged,
                onPlanChanged: onPlanChanged,
                onQuiz: onQuiz
            )
        }
    }
}
