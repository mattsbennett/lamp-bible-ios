//
//  SearchView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import SwiftUI
import RealmSwift

enum SearchContextAmount: Int, CaseIterable {
    case oneVerse = 1
    case threeVerses = 3
    case chapter = 0

    var label: String {
        switch self {
        case .oneVerse: return "1 Verse"
        case .threeVerses: return "3 Verses"
        case .chapter: return "Chapter"
        }
    }
}

enum SearchMode: String, CaseIterable, Codable {
    case text = "Text"
    case strongs = "Strong's"

    var icon: String {
        switch self {
        case .text: return "textformat"
        case .strongs: return "number"
        }
    }

    var placeholder: String {
        switch self {
        case .text: return "Search verses..."
        case .strongs: return "H430, G2316, TH8804..."
        }
    }
}

struct SearchHistoryEntry: Codable, Equatable {
    let query: String
    let mode: SearchMode
}

struct SearchView: View {
    @Binding var isPresented: Bool
    var translation: Translation
    @Binding var requestScrollToVerseId: Int?
    @Binding var requestScrollAnimated: Bool
    var initialSearchText: String = ""
    var fontSize: Int = 18

    @State private var searchText: String = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching: Bool = false
    @State private var resultLimit: Int = 100
    @State private var totalResultCount: Int = 0
    @State private var resultsVisible: Bool = false  // Only show results after submit
    @State private var searchTask: Task<Void, Never>?
    @AppStorage("searchContextAmount") private var contextAmount: SearchContextAmount = .oneVerse
    @AppStorage("searchHistory") private var searchHistoryData: Data = Data()
    @AppStorage("searchMode") private var searchMode: SearchMode = .text

    private let maxHistorySize = 20
    private let debounceDelay: UInt64 = 300_000_000 // 300ms

    /// Check if the current translation has Strong's annotations
    private var translationHasStrongsAnnotations: Bool {
        // Quick check: see if any verse contains the Strong's annotation pattern
        translation.verses.filter("t CONTAINS '|H' OR t CONTAINS '|G'").count > 0
    }

    private var searchHistory: [SearchHistoryEntry] {
        get {
            // Try new format first
            if let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: searchHistoryData) {
                return entries
            }
            // Fall back to old format (migrate strings to text mode)
            if let oldStrings = try? JSONDecoder().decode([String].self, from: searchHistoryData) {
                return oldStrings.map { SearchHistoryEntry(query: $0, mode: .text) }
            }
            return []
        }
    }

    private func saveToHistory(_ query: String) {
        var history = searchHistory
        let entry = SearchHistoryEntry(query: query, mode: searchMode)
        // Remove if already exists with same query (to move to top)
        history.removeAll { $0.query.lowercased() == query.lowercased() }
        // Add to beginning
        history.insert(entry, at: 0)
        // Trim to max size
        if history.count > maxHistorySize {
            history = Array(history.prefix(maxHistorySize))
        }
        // Save
        if let data = try? JSONEncoder().encode(history) {
            searchHistoryData = data
        }
    }

    private func clearHistory() {
        searchHistoryData = Data()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search mode toggle (only show if translation has Strong's annotations)
                if translationHasStrongsAnnotations {
                    Picker("Search Mode", selection: $searchMode) {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }

                // Custom search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(searchMode.placeholder, text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(searchMode == .strongs ? .asciiCapable : .default)
                        .submitLabel(.search)
                        .onSubmit {
                            submitSearch()
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                            totalResultCount = 0
                            resultsVisible = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.top, translationHasStrongsAnnotations ? 0 : 8)
                .padding(.bottom, 8)

                Divider()

                // Content
                Group {
                    if searchText.isEmpty {
                        emptySearchState
                    } else if isSearching {
                        loadingState
                    } else if !resultsVisible {
                        // Show match count while typing, before submit
                        matchCountState
                    } else if searchResults.isEmpty {
                        noResultsState
                    } else {
                        resultsList
                    }
                }
            }
            .navigationTitle("Search \(translation.abbreviation)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // Context amount setting
                        Menu {
                            Picker("Context", selection: $contextAmount) {
                                ForEach(SearchContextAmount.allCases, id: \.self) { amount in
                                    Text(amount.label).tag(amount)
                                }
                            }
                        } label: {
                            Label("Tooltip Context", systemImage: "rectangle.expand.vertical")
                        }

                        Divider()

                        // Search history
                        // TODO: iOS Menu enforces system styling - icon color/position cannot be customized.
                        // To get secondary color or trailing position, would need to replace Menu with custom popover.
                        if !searchHistory.isEmpty {
                            Menu {
                                ForEach(Array(searchHistory.enumerated()), id: \.offset) { _, entry in
                                    Button {
                                        searchMode = entry.mode
                                        searchText = entry.query
                                        // Use async to ensure submitSearch runs after onChange
                                        DispatchQueue.main.async {
                                            submitSearch()
                                        }
                                    } label: {
                                        Label(entry.query, systemImage: entry.mode.icon)
                                    }
                                }

                                Divider()

                                Button(role: .destructive) {
                                    clearHistory()
                                } label: {
                                    Label("Clear History", systemImage: "trash")
                                }
                            } label: {
                                Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                            }
                        } else {
                            Label("No Recent Searches", systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .onChange(of: searchText) {
                resultsVisible = false
                // Auto-detect Strong's number and switch mode if appropriate
                autoDetectSearchMode()
                scheduleSearch()
            }
            .onChange(of: searchMode) {
                // Clear results and auto-submit when switching modes with text
                searchResults = []
                totalResultCount = 0
                if !searchText.isEmpty {
                    submitSearch()
                } else {
                    resultsVisible = false
                }
            }
            .onAppear {
                // Use initial search text if provided - submit immediately
                if !initialSearchText.isEmpty && searchText.isEmpty {
                    searchText = initialSearchText
                    // Auto-detect mode for initial search text
                    autoDetectSearchMode()
                    // Use async to ensure submitSearch runs after state updates
                    DispatchQueue.main.async {
                        submitSearch()
                    }
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    // MARK: - View States

    private var emptySearchState: some View {
        ContentUnavailableView(
            searchMode == .strongs ? "Strong's Search" : "Search the Bible",
            systemImage: searchMode == .strongs ? "number" : "magnifyingglass",
            description: Text(searchMode == .strongs
                ? "Enter a Strong's number (H430, G2316, TH8804)"
                : "Enter at least 2 characters to search")
        )
    }

    private var loadingState: some View {
        VStack {
            ProgressView()
                .padding()
            Text("Searching...")
                .foregroundStyle(.secondary)
        }
    }

    private var noResultsState: some View {
        ContentUnavailableView(
            "No Results",
            systemImage: "doc.text.magnifyingglass",
            description: Text(noResultsDescription)
        )
    }

    private var noResultsDescription: String {
        if searchMode == .strongs {
            if translationHasStrongsAnnotations {
                return "No verses found with Strong's number \"\(searchText.uppercased())\"."
            } else {
                return "\(translation.abbreviation) does not include Strong's annotations. Switch to a Strong's-annotated translation to search by Strong's numbers."
            }
        } else {
            return "No verses found matching \"\(searchText)\"."
        }
    }

    private var matchCountState: some View {
        ContentUnavailableView(
            totalResultCount > 0 ? "\(totalResultCount) matches" : "No matches",
            systemImage: "magnifyingglass",
            description: Text("Submit to view results")
        )
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(searchResults) { result in
                    SearchResultRow(
                        result: result,
                        searchQuery: searchText,
                        searchMode: searchMode,
                        fontSize: fontSize,
                        contextAmount: contextAmount,
                        translation: translation,
                        onNavigate: { navigateToVerse(result) }
                    )
                }
            } header: {
                if totalResultCount > resultLimit {
                    Text("Showing \(searchResults.count) of \(totalResultCount) results")
                } else {
                    Text("\(searchResults.count) results")
                }
            }

            if totalResultCount > resultLimit {
                Button {
                    loadMoreResults()
                } label: {
                    Text("Load More Results")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .modifier(ConditionalGlassButtonStyle())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Search Logic

    /// Debounced search that just counts matches (for live preview)
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceDelay)
            } catch {
                return // Task was cancelled
            }

            guard !Task.isCancelled else { return }
            await performSearch(showResults: false)
        }
    }

    /// Submit search - shows results and saves to history
    private func submitSearch() {
        searchTask?.cancel()
        resultsVisible = true
        performSearch(showResults: true)

        // Save to history if we found results
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchResults.isEmpty && query.count >= 2 {
            saveToHistory(query)
        }
    }

    @MainActor
    private func performSearch(showResults: Bool) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // Different validation for different modes
        if searchMode == .strongs {
            guard isValidStrongsQuery(query) else {
                searchResults = []
                totalResultCount = 0
                return
            }
        } else {
            guard query.count >= 2 else {
                searchResults = []
                totalResultCount = 0
                return
            }
        }

        isSearching = true

        if searchMode == .strongs {
            let allResults = versesContainingStrongs(query, translationId: translation.id)
            totalResultCount = allResults.count

            if showResults {
                let limited = Array(allResults.prefix(resultLimit))
                searchResults = limited.compactMap { verse -> SearchResult? in
                    guard let book = RealmManager.shared.realm.objects(Book.self)
                        .filter("id == %@", verse.b).first else { return nil }
                    return SearchResult(verse: verse, bookName: book.name)
                }
            }
        } else {
            // Text search - case insensitive contains
            // First get candidates from Realm, then filter to exclude annotation-only matches
            let candidates = translation.verses.filter("t CONTAINS[c] %@", query)

            // Post-filter to ensure match is in the actual text, not just in Strong's annotations
            let filteredVerses = candidates.filter { verse in
                let cleanedText = stripStrongsAnnotations(verse.t)
                return cleanedText.localizedCaseInsensitiveContains(query)
            }

            totalResultCount = filteredVerses.count

            if showResults {
                let limited = Array(filteredVerses.prefix(resultLimit))
                searchResults = limited.compactMap { verse -> SearchResult? in
                    guard let book = RealmManager.shared.realm.objects(Book.self)
                        .filter("id == %@", verse.b).first else { return nil }
                    return SearchResult(verse: verse, bookName: book.name)
                }
            }
        }

        isSearching = false
    }

    // MARK: - Strong's Search Helpers

    /// Auto-detect if user is typing a Strong's number and switch mode if appropriate
    private func autoDetectSearchMode() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let looksLikeStrongsNumber = isValidStrongsQuery(query)

        if looksLikeStrongsNumber && translationHasStrongsAnnotations && searchMode != .strongs {
            searchMode = .strongs
        } else if !looksLikeStrongsNumber && searchMode == .strongs && !query.isEmpty {
            // Only switch back to text if it clearly doesn't look like a Strong's number
            // and isn't a partial Strong's entry (like "H" or "H1")
            let looksLikePartialStrongs = query.range(of: "^(H|G|TH)\\d*$", options: .regularExpression) != nil
            if !looksLikePartialStrongs {
                searchMode = .text
            }
        }
    }

    /// Validates that the query looks like a Strong's number (H, G, or TH prefix followed by digits)
    private func isValidStrongsQuery(_ query: String) -> Bool {
        let pattern = "^(H|G|TH)\\d+$"
        return query.range(of: pattern, options: .regularExpression) != nil
    }

    /// Searches for verses containing the exact Strong's number with proper boundary matching
    private func versesContainingStrongs(_ strongsNum: String, translationId: Int) -> Results<Verse> {
        // All possible boundary patterns for exact match:
        // |H1254}  - single number, end of annotation
        // |H1254,  - first in a comma-separated list
        // ,H1254,  - middle of list
        // ,H1254}  - end of list
        // |H1254|  - single number with morphology following
        // ,H1254|  - end of list with morphology following
        let patterns = [
            "|\(strongsNum)}",   // single, end
            "|\(strongsNum),",   // first in list
            ",\(strongsNum),",   // middle of list
            ",\(strongsNum)}",   // end of list
            "|\(strongsNum)|",   // single with morphology
            ",\(strongsNum)|"    // end of list with morphology
        ]

        let predicates = patterns.map {
            NSPredicate(format: "t CONTAINS %@", $0)
        }
        let compoundPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        return RealmManager.shared.realm.objects(Verse.self)
            .filter("tr == %@", translationId)
            .filter(compoundPredicate)
    }

    private func loadMoreResults() {
        resultLimit += 100
        performSearch(showResults: true)
    }

    // MARK: - Navigation

    private func navigateToVerse(_ result: SearchResult) {
        requestScrollAnimated = false
        requestScrollToVerseId = result.id
        isPresented = false
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let result: SearchResult
    let searchQuery: String
    let searchMode: SearchMode
    let fontSize: Int
    let contextAmount: SearchContextAmount
    let translation: Translation
    let onNavigate: () -> Void

    @State private var showingPopover: Bool = false
    @State private var contentHeight: CGFloat = 200

    // Get context verses based on setting
    private var contextVerses: [Verse] {
        let verseId = result.id
        let (_, chapter, book) = splitVerseId(verseId)

        switch contextAmount {
        case .oneVerse:
            // 1 verse before + hit verse + 1 verse after
            let chapterVerses = translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v")
            guard let index = chapterVerses.firstIndex(where: { $0.id == verseId }) else {
                return Array(translation.verses.filter("id == %@", verseId))
            }
            let startIndex = max(0, index - 1)
            let endIndex = min(chapterVerses.count - 1, index + 1)
            return Array(chapterVerses[startIndex...endIndex])
        case .threeVerses:
            // 3 verses before + hit verse + 3 verses after
            let chapterVerses = translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v")
            guard let index = chapterVerses.firstIndex(where: { $0.id == verseId }) else {
                return Array(translation.verses.filter("id == %@", verseId))
            }
            let startIndex = max(0, index - 3)
            let endIndex = min(chapterVerses.count - 1, index + 3)
            return Array(chapterVerses[startIndex...endIndex])
        case .chapter:
            // All verses in the chapter
            return Array(translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v"))
        }
    }

    private var popoverTitle: String {
        guard let first = contextVerses.first, let last = contextVerses.last else {
            return result.referenceText
        }
        if first.id == last.id {
            return result.referenceText
        } else {
            return "\(result.bookName) \(first.c):\(first.v)-\(last.v)"
        }
    }

    private var inlineVerseText: AttributedString {
        var attrString = AttributedString()

        for (index, verse) in contextVerses.enumerated() {
            // Add verse number as superscript
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .system(size: CGFloat(fontSize) * 0.75)
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = CGFloat(fontSize) * 0.25
            attrString.append(verseNum)

            // Add space after verse number
            attrString.append(AttributedString(" "))

            // Add verse text - highlight if it's the matched verse
            if verse.id == result.id {
                if searchMode == .strongs {
                    attrString.append(highlightedStrongsAttributedText(verse.t, strongsNum: searchQuery.uppercased()))
                } else {
                    let cleanedText = stripStrongsAnnotations(verse.t)
                    attrString.append(highlightedAttributedText(cleanedText, query: searchQuery))
                }
            } else {
                let cleanedText = stripStrongsAnnotations(verse.t)
                var verseText = AttributedString(cleanedText)
                verseText.foregroundColor = .secondary
                attrString.append(verseText)
            }

            // Add space between verses (but not after last)
            if index < contextVerses.count - 1 {
                attrString.append(AttributedString(" "))
            }
        }

        return attrString
    }

    private func highlightedAttributedText(_ text: String, query: String) -> AttributedString {
        var result = AttributedString()
        let lowercaseText = text.lowercased()
        let lowercaseQuery = query.lowercased()

        guard !query.isEmpty, lowercaseText.contains(lowercaseQuery) else {
            return AttributedString(text)
        }

        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if let range = text.range(of: query, options: .caseInsensitive, range: currentIndex..<text.endIndex) {
                // Add text before match
                if currentIndex < range.lowerBound {
                    result.append(AttributedString(String(text[currentIndex..<range.lowerBound])))
                }
                // Add highlighted match
                var highlight = AttributedString(String(text[range]))
                highlight.foregroundColor = .accentColor
                highlight.font = .system(size: CGFloat(fontSize)).bold()
                result.append(highlight)
                currentIndex = range.upperBound
            } else {
                // Add remaining text
                result.append(AttributedString(String(text[currentIndex..<text.endIndex])))
                break
            }
        }

        return result
    }

    /// Highlights words that contain the specified Strong's number in their annotation
    private func highlightedStrongsAttributedText(_ text: String, strongsNum: String) -> AttributedString {
        var result = AttributedString()

        // Parse the annotated text: {word|H123} or {word|H123,H456} or {word|H123|TH8799}
        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(stripStrongsAnnotations(text))
        }

        let nsText = text as NSString
        var currentIndex = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // Add text before this annotation
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                result.append(AttributedString(beforeText))
            }

            // Extract word and annotation
            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            // Check if this annotation contains our Strong's number
            let containsStrongs = annotationContainsStrongs(annotation, strongsNum: strongsNum)

            if containsStrongs {
                var highlight = AttributedString(word)
                highlight.foregroundColor = .accentColor
                highlight.font = .system(size: CGFloat(fontSize)).bold()
                result.append(highlight)
            } else {
                result.append(AttributedString(word))
            }

            currentIndex = match.range.location + match.range.length
        }

        // Add remaining text after last annotation
        if currentIndex < nsText.length {
            let remainingText = nsText.substring(from: currentIndex)
            result.append(AttributedString(remainingText))
        }

        return result
    }

    /// Checks if an annotation string contains the specified Strong's number with proper boundaries
    private func annotationContainsStrongs(_ annotation: String, strongsNum: String) -> Bool {
        // Annotation format: H123 or H123,H456 or H123|TH8799
        // Split by comma and pipe to get individual numbers
        let parts = annotation.components(separatedBy: CharacterSet(charactersIn: ",|"))
        return parts.contains { $0.trimmingCharacters(in: .whitespaces) == strongsNum }
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.referenceText)
                    .font(.system(size: CGFloat(fontSize) * 0.8))
                    .foregroundStyle(.secondary)

                listContextText
                    .font(.system(size: CGFloat(fontSize)))
                    .lineLimit(3)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: popoverTitle,
                verseText: inlineVerseText,
                onNavigate: {
                    showingPopover = false
                    onNavigate()
                },
                contentHeight: $contentHeight
            )
        }
    }

    // Context for list rows - fixed amount to show the match area
    private var listContextText: Text {
        if searchMode == .strongs {
            return highlightedStrongsTextWithContext(result.verse.t, strongsNum: searchQuery.uppercased())
        }

        let text = result.text
        let query = searchQuery

        // Find the first match
        guard let matchRange = text.range(of: query, options: .caseInsensitive) else {
            return Text(text)
        }

        // Use a generous context for the list (80 chars each side)
        let contextChars = 80

        // Calculate context window around the match
        let matchStart = text.distance(from: text.startIndex, to: matchRange.lowerBound)
        let matchEnd = text.distance(from: text.startIndex, to: matchRange.upperBound)

        var contextStart = max(0, matchStart - contextChars)
        var contextEnd = min(text.count, matchEnd + contextChars)

        // Try to start/end at word boundaries
        if contextStart > 0 {
            let searchStart = text.index(text.startIndex, offsetBy: max(0, contextStart - 10))
            let searchEnd = text.index(text.startIndex, offsetBy: contextStart)
            if let spaceRange = text.range(of: " ", options: [], range: searchStart..<searchEnd) {
                contextStart = text.distance(from: text.startIndex, to: spaceRange.upperBound)
            }
        }

        if contextEnd < text.count {
            let searchStart = text.index(text.startIndex, offsetBy: contextEnd)
            let searchEnd = text.index(text.startIndex, offsetBy: min(text.count, contextEnd + 10))
            if let spaceRange = text.range(of: " ", options: [], range: searchStart..<searchEnd) {
                contextEnd = text.distance(from: text.startIndex, to: spaceRange.lowerBound)
            }
        }

        let startIndex = text.index(text.startIndex, offsetBy: contextStart)
        let endIndex = text.index(text.startIndex, offsetBy: contextEnd)
        var snippet = String(text[startIndex..<endIndex])

        // Add ellipsis
        if contextStart > 0 {
            snippet = "..." + snippet
        }
        if contextEnd < text.count {
            snippet = snippet + "..."
        }

        return highlightedText(snippet, query: query)
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let lowercaseText = text.lowercased()
        let lowercaseQuery = query.lowercased()

        guard !query.isEmpty, lowercaseText.contains(lowercaseQuery) else {
            return Text(text)
        }

        var result = Text("")
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            if let range = text.range(of: query, options: .caseInsensitive, range: currentIndex..<text.endIndex) {
                // Add text before match
                if currentIndex < range.lowerBound {
                    result = result + Text(text[currentIndex..<range.lowerBound])
                }
                // Add highlighted match
                result = result + Text(text[range])
                    .foregroundColor(.accentColor)
                    .bold()
                currentIndex = range.upperBound
            } else {
                // Add remaining text
                result = result + Text(text[currentIndex..<text.endIndex])
                break
            }
        }

        return result
    }

    /// Highlights words containing the Strong's number, returns Text for list display with context around match
    private func highlightedStrongsTextWithContext(_ text: String, strongsNum: String) -> Text {
        // First, find the position of the first matching word in the cleaned text
        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(stripStrongsAnnotations(text))
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Find the first matching annotation and its position in cleaned text
        var cleanedText = ""
        var firstMatchCleanedStart: Int? = nil
        var firstMatchCleanedEnd: Int? = nil
        var currentIndex = 0

        for match in matches {
            // Add text before this annotation to cleaned text
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                cleanedText += beforeText
            }

            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            let wordStartInCleaned = cleanedText.count
            cleanedText += word

            // Check if this is a match and we haven't found one yet
            if firstMatchCleanedStart == nil && annotationContainsStrongs(annotation, strongsNum: strongsNum) {
                firstMatchCleanedStart = wordStartInCleaned
                firstMatchCleanedEnd = cleanedText.count
            }

            currentIndex = match.range.location + match.range.length
        }

        // Add remaining text
        if currentIndex < nsText.length {
            cleanedText += nsText.substring(from: currentIndex)
        }

        // If no match found, just return the cleaned text
        guard let matchStart = firstMatchCleanedStart, let matchEnd = firstMatchCleanedEnd else {
            return Text(cleanedText)
        }

        // Build snippet around the match
        let contextChars = 80
        var contextStart = max(0, matchStart - contextChars)
        var contextEnd = min(cleanedText.count, matchEnd + contextChars)

        // Adjust to word boundaries
        if contextStart > 0 {
            let startIdx = cleanedText.index(cleanedText.startIndex, offsetBy: max(0, contextStart - 10))
            let endIdx = cleanedText.index(cleanedText.startIndex, offsetBy: contextStart)
            if let spaceRange = cleanedText.range(of: " ", options: [], range: startIdx..<endIdx) {
                contextStart = cleanedText.distance(from: cleanedText.startIndex, to: spaceRange.upperBound)
            }
        }

        if contextEnd < cleanedText.count {
            let startIdx = cleanedText.index(cleanedText.startIndex, offsetBy: contextEnd)
            let endIdx = cleanedText.index(cleanedText.startIndex, offsetBy: min(cleanedText.count, contextEnd + 10))
            if let spaceRange = cleanedText.range(of: " ", options: [], range: startIdx..<endIdx) {
                contextEnd = cleanedText.distance(from: cleanedText.startIndex, to: spaceRange.lowerBound)
            }
        }

        // Build the result with highlighting
        let snippetStartIdx = cleanedText.index(cleanedText.startIndex, offsetBy: contextStart)
        let snippetEndIdx = cleanedText.index(cleanedText.startIndex, offsetBy: contextEnd)
        let matchStartIdx = cleanedText.index(cleanedText.startIndex, offsetBy: matchStart)
        let matchEndIdx = cleanedText.index(cleanedText.startIndex, offsetBy: matchEnd)

        var result = Text("")

        if contextStart > 0 {
            result = result + Text("...")
        }

        // Text before match
        if snippetStartIdx < matchStartIdx {
            result = result + Text(cleanedText[snippetStartIdx..<matchStartIdx])
        }

        // The matched word
        result = result + Text(cleanedText[matchStartIdx..<matchEndIdx])
            .foregroundColor(.accentColor)
            .bold()

        // Text after match
        if matchEndIdx < snippetEndIdx {
            result = result + Text(cleanedText[matchEndIdx..<snippetEndIdx])
        }

        if contextEnd < cleanedText.count {
            result = result + Text("...")
        }

        return result
    }

    /// Highlights words containing the Strong's number, returns Text for full verse display
    private func highlightedStrongsText(_ text: String, strongsNum: String) -> Text {
        var result = Text("")

        // Parse the annotated text: {word|H123} or {word|H123,H456} or {word|H123|TH8799}
        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(stripStrongsAnnotations(text))
        }

        let nsText = text as NSString
        var currentIndex = 0

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            // Add text before this annotation
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                result = result + Text(beforeText)
            }

            // Extract word and annotation
            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            // Check if this annotation contains our Strong's number
            let containsStrongs = annotationContainsStrongs(annotation, strongsNum: strongsNum)

            if containsStrongs {
                result = result + Text(word)
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                result = result + Text(word)
            }

            currentIndex = match.range.location + match.range.length
        }

        // Add remaining text after last annotation
        if currentIndex < nsText.length {
            let remainingText = nsText.substring(from: currentIndex)
            result = result + Text(remainingText)
        }

        return result
    }
}

// MARK: - Shared Verse Popover Content

struct VersePopoverContent: View {
    let title: String
    let verseText: AttributedString
    let onNavigate: (() -> Void)?
    @Binding var contentHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header with navigation button
            if let onNavigate = onNavigate {
                Button {
                    onNavigate()
                } label: {
                    HStack {
                        Text(title)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .padding()
            } else {
                Text(title)
                    .font(.headline)
                    .padding()
            }

            Divider()

            // Scrollable verse text
            ScrollView {
                Text(verseText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                contentHeight = geo.size.height + 60
                            }
                        }
                    )
            }
        }
        .frame(minWidth: 280, maxWidth: 400)
        .frame(height: min(max(contentHeight, 100), 300))
        .presentationCompactAdaptation(.popover)
    }
}

