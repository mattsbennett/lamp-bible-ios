import SwiftUI
import UniformTypeIdentifiers
import LampModuleKit

struct BookLibraryView: View {
    @State private var books: [BookLibraryItem] = []
    @State private var positions: [String: BookReadingPosition] = [:]
    @State private var selectedBook: BookLibraryItem?
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showingDuplicateAlert = false
    @State private var duplicateBookName = ""
    @State private var pendingImportURL: URL?
    @State private var pendingImportHasSecurityScope = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredBooks: [BookLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }
        return books.filter { item in
            [item.book.title, item.book.subtitle, item.book.author, item.book.description]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
                || item.book.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// The books read most recently: a way back into them once the library is
    /// long enough that finding one means scrolling for it.
    private var recentBooks: [BookLibraryItem] {
        guard books.count > 3 else { return [] }
        return books
            .compactMap { item in positions[item.id].map { (item: item, readAt: $0.updatedAt) } }
            .sorted { $0.readAt > $1.readAt }
            .prefix(3)
            .map(\.item)
    }

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView {
                    Label("No Books Installed", systemImage: "books.vertical")
                } description: {
                    Text("Install a compiled .lamp book or its source JSON to begin reading.")
                } actions: {
                    Button("Import Book…") { showingImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredBooks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    if !isSearching && !recentBooks.isEmpty {
                        Section("Continue Reading") {
                            ForEach(recentBooks) { row(for: $0) }
                        }
                        Section("All Books") {
                            ForEach(books) { row(for: $0) }
                        }
                    } else {
                        ForEach(filteredBooks) { row(for: $0) }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { loadBooks() }
            }
        }
        .navigationTitle("Books")
        .searchable(text: $searchText, prompt: "Title, author, or tag")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Book", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                .disabled(isImporting)
            }
        }
        .overlay {
            if isImporting {
                ProgressView("Importing Book…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        // Full screen rather than a sheet: at the top of a section, a sheet
        // takes pulling the text down as a request to close the book.
        .fullScreenCover(item: $selectedBook, onDismiss: loadPositions) { item in
            BookModuleView(moduleId: item.id)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.lampFile, .json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure(let error) = result { alertMessage = error.localizedDescription }
                return
            }
            prepareBookImport(from: url)
        }
        .alert("Book Already Exists", isPresented: $showingDuplicateAlert) {
            Button("Overwrite") {
                guard let url = pendingImportURL else { return }
                performBookImport(
                    from: url,
                    hasSecurityScope: pendingImportHasSecurityScope
                )
            }
            Button("Cancel", role: .cancel) {
                releasePendingImport()
            }
        } message: {
            Text("\"\(duplicateBookName)\" is already installed. Overwrite it?")
        }
        .alert("Books", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .task { loadBooks() }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadBooks()
        }
    }

    private func row(for item: BookLibraryItem) -> some View {
        Button {
            selectedBook = item
        } label: {
            BookLibraryRow(item: item, position: positions[item.id])
        }
        .buttonStyle(.plain)
    }

    private func loadBooks() {
        var byID: [String: BookLibraryItem] = [:]
        if let bundled = try? BundledModuleDatabase.shared.getBookModules() {
            for book in bundled {
                byID[book.id] = BookLibraryItem(book: book, isBundled: true)
            }
        }
        if let installed = try? ModuleDatabase.shared.getBookModules() {
            for book in installed {
                byID[book.id] = BookLibraryItem(book: book, isBundled: false)
            }
        }
        books = byID.values.sorted {
            $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending
        }
        loadPositions()
    }

    private func loadPositions() {
        let store = BookReadingProgressStore()
        positions = books.reduce(into: [:]) { result, item in
            result[item.id] = store.position(for: item.id)
        }
    }

    private func prepareBookImport(from url: URL) {
        isImporting = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                let type = try ModuleSyncManager.shared.moduleType(forDocumentAt: url)
                guard type == .book else {
                    throw BookJSONImportError.notABook
                }
                if let existingName = try ModuleSyncManager.shared.existingModuleName(
                    forDocumentAt: url
                ) {
                    pendingImportURL = url
                    pendingImportHasSecurityScope = accessing
                    duplicateBookName = existingName
                    showingDuplicateAlert = true
                    isImporting = false
                    return
                }
                try await ModuleSyncManager.shared.importModuleDocumentFromFile(
                    url: url,
                    moduleType: .book
                )
                if accessing { url.stopAccessingSecurityScopedResource() }
                loadBooks()
                isImporting = false
                alertMessage = "Book imported successfully."
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                isImporting = false
                alertMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func performBookImport(from url: URL, hasSecurityScope: Bool) {
        pendingImportURL = nil
        pendingImportHasSecurityScope = false
        isImporting = true
        Task {
            let accessing = hasSecurityScope ? false : url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope || accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try await ModuleSyncManager.shared.importModuleDocumentFromFile(
                    url: url,
                    moduleType: .book
                )
                loadBooks()
                isImporting = false
                alertMessage = "Book imported successfully."
            } catch {
                isImporting = false
                alertMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func releasePendingImport() {
        if pendingImportHasSecurityScope {
            pendingImportURL?.stopAccessingSecurityScopedResource()
        }
        pendingImportURL = nil
        pendingImportHasSecurityScope = false
    }
}

private struct BookLibraryItem: Identifiable {
    let book: BookModule
    let isBundled: Bool
    var id: String { book.id }
}

private struct BookLibraryRow: View {
    let item: BookLibraryItem
    let position: BookReadingPosition?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCoverThumbnail(book: item.book)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.book.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let subtitle = item.book.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let author = item.book.author, !author.isEmpty {
                    Label(author, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let position {
                        Label(position.sectionTitle ?? "Continue reading", systemImage: "bookmark.fill")
                            .lineLimit(1)
                    }
                    if item.isBundled {
                        Label("Included", systemImage: "checkmark.seal")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tint)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // In a list row a label's icon otherwise takes a row icon's width,
        // leaving a gap wider than the icon before each detail.
        .labelStyle(BookRowLabelStyle())
    }
}

private struct BookRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

private struct BookCoverThumbnail: View {
    let book: BookModule
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.11))
            }
        }
        .frame(width: 58, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator.opacity(0.5)) }
        .onAppear {
            guard let cover = book.coverMediaReference else { return }
            image = ModuleMediaStorage.shared.loadImage(for: cover, moduleId: book.id)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Text Style

/// How a book's text is set. The keys and ranges are the Mac's (its
/// `LampTextScale.bookText` and `.bookLineSpacing`), so a size means the same
/// on both.
private struct BookTextStyle: Equatable {
    static let fontSizeKey = "books.fontSize"
    static let lineSpacingKey = "books.lineSpacing"
    static let typefaceKey = "books.typeface"
    static let fontSizes: ClosedRange<Double> = 13...34
    static let lineSpacings: ClosedRange<Double> = 0...16
    static let defaultFontSize: Double = 18
    static let defaultLineSpacing: Double = 6

    var fontSize: Double
    var lineSpacing: Double
    var typeface: BookTypeface

    init(fontSize: Double, lineSpacing: Double, typeface: BookTypeface) {
        self.fontSize = min(max(fontSize, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        self.lineSpacing = min(max(lineSpacing, Self.lineSpacings.lowerBound), Self.lineSpacings.upperBound)
        self.typeface = typeface
    }

    func font(_ scale: Double = 1, weight: Font.Weight = .regular) -> Font {
        .system(size: fontSize * scale, weight: weight, design: typeface.design)
    }

    var paragraphSpacing: Double { fontSize * 0.8 }
}

/// Raw values are the Mac's, for the same reason.
private enum BookTypeface: String, CaseIterable, Identifiable {
    case serif
    case sansSerif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: "Serif"
        case .sansSerif: "Sans Serif"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sansSerif: .default
        }
    }
}

// MARK: - Reader

private enum BookReaderLayout {
    static let margin: CGFloat = 20
    /// The widest the text runs, about 70 characters at the default size.
    static let measure: CGFloat = 680
}

/// Reader for bundled and user-installed long-form book modules.
struct BookModuleView: View {
    let moduleId: String
    var initialSectionId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage(BookTextStyle.fontSizeKey) private var fontSize = BookTextStyle.defaultFontSize
    @AppStorage(BookTextStyle.lineSpacingKey) private var lineSpacing = BookTextStyle.defaultLineSpacing
    @AppStorage(BookTextStyle.typefaceKey) private var typeface = BookTypeface.serif

    @State private var book: BookModule?
    @State private var sections: [BookSection] = []
    @State private var footnotesByID: [String: BookFootnote] = [:]
    @State private var footnoteNumbers: [String: Int] = [:]
    @State private var mediaByID: [String: MediaReference] = [:]
    @State private var selectedSectionId: String?
    @State private var document: BookSectionDocument?
    /// Where to put the reader once the selected section is ready.
    @State private var landingBlock = -1
    /// The first block on screen, or -1 for the section's heading.
    @State private var topBlock = -1
    @State private var scrollRequest: BookScrollRequest?
    @State private var landedSerial = 0
    /// While a jump is under way, what scrolls past isn't where the reader is.
    @State private var isLanding = false
    @State private var loadError: String?
    @State private var showingContents = false
    @State private var showingTextSettings = false
    @State private var selectedStrongs: BookStrongsDestination?
    @State private var selectedFootnote: BookFootnote?
    @State private var preview: PreviewSheetState?
    @State private var navigationPath = NavigationPath()
    @State private var readerDate = Date()

    private var style: BookTextStyle {
        BookTextStyle(fontSize: fontSize, lineSpacing: lineSpacing, typeface: typeface)
    }

    private var selectedSection: BookSection? {
        sections.first { $0.id == selectedSectionId }
    }

    private var selectedIndex: Int? {
        sections.firstIndex { $0.id == selectedSectionId }
    }

    private var previousSection: BookSection? {
        guard let selectedIndex, selectedIndex > sections.startIndex else { return nil }
        return sections[sections.index(before: selectedIndex)]
    }

    private var nextSection: BookSection? {
        guard let selectedIndex else { return nil }
        let nextIndex = sections.index(after: selectedIndex)
        return sections.indices.contains(nextIndex) ? sections[nextIndex] : nil
    }

    private var translationID: String {
        UserDatabase.shared.getSettings().readerTranslationId
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Unable to Open Book",
                        systemImage: "book.closed",
                        description: Text(loadError)
                    )
                } else if let book, let section = selectedSection,
                          let document, document.sectionID == section.id {
                    reader(book: book, section: section, document: document)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(book?.title ?? "Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { readerToolbar }
            .navigationDestination(for: BookScriptureDestination.self) { destination in
                SplitReaderView(
                    date: $readerDate,
                    initialVerseId: destination.reference,
                    initialTranslationId: destination.translationID
                )
            }
        }
        .sheet(isPresented: $showingContents) {
            if let book {
                BookContentsView(
                    book: book,
                    sections: sections,
                    currentSectionID: selectedSectionId,
                    headings: document?.headings ?? [],
                    currentBlock: topBlock
                ) { sectionID, block in
                    showingContents = false
                    select(sectionID: sectionID, block: block)
                }
            }
        }
        .sheet(item: $selectedStrongs) { destination in
            LexiconSheetView(
                word: destination.key,
                strongs: [destination.key],
                morphology: nil,
                translationId: translationID
            )
        }
        .sheet(item: $selectedFootnote) { footnote in
            BookFootnoteSheet(
                footnote: footnote,
                number: footnoteNumbers[footnote.id],
                renderer: BookTextRenderer(footnoteNumbers: footnoteNumbers, fontSize: style.fontSize),
                style: style,
                translationID: translationID
            ) { verseID in
                selectedFootnote = nil
                openReader(at: verseID)
            }
        }
        .sheet(item: $preview) { _ in
            PreviewSheet(
                state: $preview,
                translationId: translationID,
                onNavigateToVerse: { openReader(at: $0) }
            )
        }
        .task(id: moduleId) { loadBook() }
        .task(id: BookDocumentKey(sectionID: selectedSectionId, fontSize: style.fontSize)) {
            await prepareDocument()
        }
        .onChange(of: style) { _, _ in
            // Text set larger or looser moves everything below it, so the
            // reader would otherwise lose their place by changing it.
            requestScroll(to: topBlock)
        }
        .environment(\.openURL, OpenURLAction { open($0) })
    }

    private func reader(
        book: BookModule,
        section: BookSection,
        document: BookSectionDocument
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: some books are a single section thousands of blocks long.
                LazyVStack(alignment: .leading, spacing: style.paragraphSpacing) {
                    BookSectionHeader(section: section, style: style)
                        .id(-1)

                    if document.blocks.isEmpty {
                        emptySection(section)
                    }

                    ForEach(document.blocks.indices, id: \.self) { index in
                        BookContentBlockView(
                            index: index,
                            document: document,
                            moduleId: book.id,
                            mediaByID: mediaByID,
                            style: style
                        )
                        .equatable()
                        .id(index)
                    }

                    if !document.footnoteIDs.isEmpty {
                        BookSectionFootnotesView(
                            document: document,
                            footnotesByID: footnotesByID,
                            style: style
                        )
                    }

                    if sections.count > 1 {
                        sectionNavigationFooter
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: BookReaderLayout.measure, alignment: .leading)
                .padding(.horizontal, BookReaderLayout.margin)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .id(section.id)
            .environment(\.layoutDirection, book.textDirection == "rtl" ? .rightToLeft : .leftToRight)
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visible in
                guard !isLanding, let first = visible.min(), first != topBlock else { return }
                topBlock = first
                savePosition()
            }
            .task(id: scrollRequest) {
                defer { isLanding = false }
                guard let scrollRequest, scrollRequest.sectionID == section.id,
                      scrollRequest.serial != landedSerial else { return }
                await Task.yield()
                proxy.scrollTo(scrollRequest.block, anchor: .top)
                landedSerial = scrollRequest.serial
                // Let the jump's own visibility changes go by.
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    @ViewBuilder
    private func emptySection(_ section: BookSection) -> some View {
        let children = sections.filter { $0.parentId == section.id }
        if children.isEmpty {
            Text("This section has no text of its own.")
                .font(style.font())
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children) { child in
                    Button {
                        select(sectionID: child.id)
                    } label: {
                        HStack {
                            Text(child.title)
                                .font(style.font())
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Text Settings", systemImage: "textformat.size") {
                showingTextSettings = true
            }
            .labelStyle(.iconOnly)
            .popover(isPresented: $showingTextSettings) {
                BookTextSettingsView(
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing,
                    typeface: $typeface
                )
                .presentationCompactAdaptation(.popover)
            }
            Button("Contents", systemImage: "list.bullet") { showingContents = true }
                .labelStyle(.iconOnly)
                .disabled(book == nil)
        }
    }

    private var sectionNavigationFooter: some View {
        VStack(spacing: 12) {
            Divider()
            if let selectedIndex {
                Text("Section \(selectedIndex + 1) of \(sections.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                navigationCard(to: previousSection, isNext: false)
                navigationCard(to: nextSection, isNext: true)
            }
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func navigationCard(to section: BookSection?, isNext: Bool) -> some View {
        if let section {
            Button {
                select(sectionID: section.id)
            } label: {
                VStack(alignment: isNext ? .trailing : .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        if !isNext { Image(systemName: "chevron.left") }
                        Text(isNext ? "Next" : "Previous")
                        if isNext { Image(systemName: "chevron.right") }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(isNext ? .trailing : .leading)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: isNext ? .trailing : .leading)
                .padding(14)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isNext ? "Next" : "Previous") section, \(section.title)")
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        }
    }

    // MARK: Moving

    private func select(sectionID: String, block: Int = -1) {
        if sectionID == selectedSectionId {
            requestScroll(to: block)
        } else {
            landingBlock = block
            selectedSectionId = sectionID
        }
        topBlock = block
        savePosition()
    }

    private func requestScroll(to block: Int) {
        guard let sectionID = selectedSectionId else { return }
        isLanding = true
        scrollRequest = BookScrollRequest(
            sectionID: sectionID,
            block: block,
            serial: (scrollRequest?.serial ?? 0) + 1
        )
    }

    private func savePosition() {
        guard let section = selectedSection else { return }
        BookReadingProgressStore().save(
            BookReadingPosition(sectionID: section.id, sectionTitle: section.title, blockIndex: topBlock),
            for: moduleId
        )
    }

    private func openReader(at verseID: Int) {
        navigationPath.append(BookScriptureDestination(reference: verseID, translationID: nil))
    }

    // MARK: Links

    private func open(_ url: URL) -> OpenURLAction.Result {
        if url.host == "book-footnote",
           let footnoteID = url.lastPathComponent.removingPercentEncoding,
           let footnote = footnotesByID[footnoteID] {
            selectedFootnote = footnote
            return .handled
        }
        guard let parsed = LampbibleURL.parse(url) else { return .systemAction }
        switch parsed {
        case .verse(let reference, let endReference, let translationID):
            showPassage(reference, through: endReference, translationID: translationID)
        case .reading(let reference, let endReference, _):
            showPassage(reference, through: endReference, translationID: nil)
        case .strongs(let key):
            selectedStrongs = BookStrongsDestination(key: key)
        case .external:
            return .systemAction
        }
        return .handled
    }

    /// Opens a cited passage in the verse preview, stepping from it through
    /// the section's other citations.
    private func showPassage(_ reference: Int, through endReference: Int?, translationID: String?) {
        let references = document?.references ?? []
        let cited = references.first { item in
            guard case .verse(let start, let end, _, _) = item.type else { return false }
            return start == reference && end == endReference
        }
        if let cited, translationID == nil {
            preview = PreviewSheetState(currentItem: cited, allItems: references)
        } else {
            let item = PreviewItem.verse(
                index: 0,
                verseId: reference,
                endVerseId: endReference,
                displayText: "",
                translationId: translationID
            )
            preview = PreviewSheetState(currentItem: item, allItems: [item])
        }
    }

    // MARK: Loading

    private func loadBook() {
        do {
            let loaded: BookModule
            let loadedSections: [BookSection]
            if let userBook = try ModuleDatabase.shared.getBookModule(id: moduleId) {
                loaded = userBook
                loadedSections = try ModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else if let bundledBook = try BundledModuleDatabase.shared.getBookModule(id: moduleId) {
                loaded = bundledBook
                loadedSections = try BundledModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else {
                loadError = "The book module is no longer available."
                return
            }

            book = loaded
            sections = loadedSections
            let footnotes = loaded.footnotes
            footnotesByID = Dictionary(footnotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            footnoteNumbers = Dictionary(
                footnotes.enumerated().map { ($0.element.id, $0.offset + 1) },
                uniquingKeysWith: { first, _ in first }
            )
            mediaByID = Dictionary(
                loaded.mediaReferences.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard !loadedSections.isEmpty else {
                loadError = "This book does not contain any sections."
                return
            }
            loadError = nil

            let saved = BookReadingProgressStore().position(for: moduleId)
            func exists(_ id: String?) -> Bool {
                id.map { id in loadedSections.contains { $0.id == id } } ?? false
            }
            if exists(initialSectionId) {
                selectedSectionId = initialSectionId
                landingBlock = -1
            } else if let saved, exists(saved.sectionID) {
                selectedSectionId = saved.sectionID
                landingBlock = saved.blockIndex
            } else {
                selectedSectionId = loadedSections.first?.id
                landingBlock = -1
            }
            topBlock = landingBlock
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func prepareDocument() async {
        guard let section = selectedSection else { return }
        let fontSize = style.fontSize
        if let document, document.sectionID == section.id, document.fontSize == fontSize { return }
        let keepsPlace = document?.sectionID == section.id
        let sectionID = section.id
        let contentJSON = section.contentJson
        let keyScriptures = section.keyScriptures
        let numbers = footnoteNumbers
        let prepared = await Task.detached(priority: .userInitiated) {
            BookSectionDocument(
                sectionID: sectionID,
                contentJSON: contentJSON,
                keyScriptures: keyScriptures,
                footnoteNumbers: numbers,
                fontSize: fontSize
            )
        }.value
        guard !Task.isCancelled, selectedSectionId == sectionID else { return }
        document = prepared
        requestScroll(to: keepsPlace ? topBlock : landingBlock)
    }
}

private struct BookScriptureDestination: Hashable {
    let reference: Int
    let translationID: String?
}

private struct BookStrongsDestination: Identifiable {
    let key: String
    var id: String { key }
}

private struct BookDocumentKey: Equatable {
    let sectionID: String?
    let fontSize: Double
}

/// A jump within the open section. The serial tells a fresh request from one
/// already carried out, which a view coming back on screen would otherwise
/// carry out again, taking the reader away from where they had scrolled since.
private struct BookScrollRequest: Equatable {
    let sectionID: String
    let block: Int
    let serial: Int
}

// MARK: - Section Document

private struct BookSectionHeading: Identifiable, Sendable {
    let blockIndex: Int
    let level: Int
    let title: String
    var id: Int { blockIndex }
}

private struct BookPassage: Hashable, Sendable {
    let start: Int
    let end: Int?
}

/// A section made ready to read: its blocks decoded and their text set once,
/// rather than on every redraw.
private final class BookSectionDocument: Sendable {
    let sectionID: String
    let fontSize: Double
    let blocks: [BookContentBlock]
    /// For the contents to jump to.
    let headings: [BookSectionHeading]
    /// Each passage the section cites, once, in the order first cited: what
    /// the verse preview steps through.
    let references: [PreviewItem]
    /// The footnotes it cites, in the order first cited.
    let footnoteIDs: [String]
    let renderer: BookTextRenderer
    private let texts: [BookAnnotatedText: AttributedString]

    init(
        sectionID: String,
        contentJSON: String,
        keyScriptures: [BookScriptureRange],
        footnoteNumbers: [String: Int],
        fontSize: Double
    ) {
        self.sectionID = sectionID
        self.fontSize = fontSize
        let renderer = BookTextRenderer(footnoteNumbers: footnoteNumbers, fontSize: fontSize)
        self.renderer = renderer
        let blocks = LampPortableBookJSON.decodeArray(contentJSON, as: BookContentBlock.self).items
        self.blocks = blocks

        var collector = BookSectionCollector()
        for range in keyScriptures {
            collector.cite(BookPassage(start: range.sv, end: range.ev), label: range.label ?? "")
        }
        for (index, block) in blocks.enumerated() {
            if block.type == "heading", let content = block.content, (block.level ?? 2) <= 3 {
                let title = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    collector.headings.append(
                        BookSectionHeading(blockIndex: index, level: block.level ?? 2, title: title)
                    )
                }
            }
            collector.collect(block)
        }
        headings = collector.headings
        references = collector.references
        footnoteIDs = collector.footnoteIDs

        var texts: [BookAnnotatedText: AttributedString] = [:]
        for content in collector.contents where texts[content] == nil {
            texts[content] = renderer.render(content)
        }
        self.texts = texts
    }

    func text(for content: BookAnnotatedText?) -> AttributedString {
        guard let content else { return AttributedString() }
        return texts[content] ?? renderer.render(content)
    }
}

private struct BookSectionCollector {
    var headings: [BookSectionHeading] = []
    var references: [PreviewItem] = []
    var footnoteIDs: [String] = []
    var contents: [BookAnnotatedText] = []
    private var passages: Set<BookPassage> = []
    private var footnotes: Set<String> = []

    mutating func cite(_ passage: BookPassage, label: String) {
        guard passages.insert(passage).inserted else { return }
        references.append(.verse(
            index: references.count,
            verseId: passage.start,
            endVerseId: passage.end,
            displayText: label
        ))
    }

    mutating func collect(_ block: BookContentBlock) {
        if let content = block.content { collect(content) }
        if let caption = block.caption?.annotatedText { collect(caption) }
        for item in block.items { collect(item) }
        for row in block.rows {
            for cell in row.cells { collect(cell.content) }
        }
    }

    mutating func collect(_ item: BookListItem) {
        collect(item.content)
        for child in item.children { collect(child) }
    }

    mutating func collect(_ content: BookAnnotatedText) {
        contents.append(content)
        for annotation in content.annotations {
            switch annotation.type {
            case "scripture":
                if let passage = BookTextRenderer.passage(of: annotation) {
                    cite(passage, label: annotation.text ?? BookTextRenderer.text(of: annotation, in: content))
                }
            case "footnote":
                if let id = annotation.data?.footnoteID { citeFootnote(id) }
            default:
                break
            }
        }
        for reference in content.footnoteReferences { citeFootnote(reference.id) }
    }

    private mutating func citeFootnote(_ id: String) {
        if footnotes.insert(id).inserted { footnoteIDs.append(id) }
    }
}

// MARK: - Text

/// Sets a book's annotated text: its links, emphasis and footnote markers.
/// Emphasis is an intent rather than a font, so a bold word in a heading takes
/// the heading's size, not the body's.
///
/// Page annotations are left out: they carry the source PDF's page index,
/// not the printed page number, so a reader citing one would cite it wrong.
private struct BookTextRenderer: Sendable {
    let footnoteNumbers: [String: Int]
    let fontSize: Double

    static func passage(of annotation: BookTextAnnotation) -> BookPassage? {
        guard let start = annotation.data?.startReference
            ?? annotation.data?.references.first?.startReference else { return nil }
        let end = annotation.data?.endReference ?? annotation.data?.references.first?.endReference
        return BookPassage(start: start, end: end)
    }

    static func text(of annotation: BookTextAnnotation, in content: BookAnnotatedText) -> String {
        let characters = Array(content.text)
        guard annotation.start >= 0, annotation.start < annotation.end,
              annotation.end <= characters.count else { return "" }
        return String(characters[annotation.start..<annotation.end])
    }

    static func footnoteURL(_ id: String) -> URL? {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "lampbible://book-footnote/\($0)") }
    }

    func render(_ content: BookAnnotatedText) -> AttributedString {
        var value = AttributedString(content.text)
        var linkedFootnotes: Set<String> = []
        for annotation in content.annotations {
            guard let range = Self.range(annotation.start, annotation.end, in: value) else { continue }
            switch annotation.type {
            case "scripture":
                if let passage = Self.passage(of: annotation) {
                    let end = passage.end.map { "/\($0)" } ?? ""
                    value[range].link = URL(string: "lampbible://verse/\(passage.start)\(end)")
                }
            case "strongs", "greek", "hebrew":
                if let key = annotation.data?.strongs,
                   let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    value[range].link = URL(string: "lampbible://strongs/\(encodedKey)")
                    value[range].foregroundColor = Color.lampOriginalLanguage
                    value[range].underlineStyle = .single
                }
            case "link":
                if let url = annotation.data?.url.flatMap(URL.init(string:)) {
                    value[range].link = url
                    // Underlined, unlike the book's references: this one
                    // leaves the app.
                    value[range].underlineStyle = .single
                }
            case "footnote":
                if let id = annotation.data?.footnoteID, let url = Self.footnoteURL(id) {
                    value[range].link = url
                    linkedFootnotes.insert(id)
                }
            case "emphasis":
                switch annotation.data?.style {
                case "bold": value[range].inlinePresentationIntent = .stronglyEmphasized
                case "underline": value[range].underlineStyle = .single
                default: value[range].inlinePresentationIntent = .emphasized
                }
            case "quote":
                value[range].inlinePresentationIntent = .emphasized
            default:
                break
            }
        }

        // Markers go where the book places them, numbered as the book numbers
        // its footnotes, so a marker's number is the one in its sheet.
        var insertions: [(offset: Int, marker: AttributedString)] = []
        for reference in content.footnoteReferences where !linkedFootnotes.contains(reference.id) {
            guard let url = Self.footnoteURL(reference.id) else { continue }
            var marker = AttributedString("[\(footnoteNumbers[reference.id].map(String.init) ?? "•")]")
            marker.link = url
            marker.font = Font.system(size: fontSize * 0.68, weight: .medium)
            marker.baselineOffset = fontSize * 0.3
            insertions.append((reference.offset, marker))
        }
        // From the end, so each offset still counts the original text; markers
        // at one offset keep the order they were listed in.
        let ordered = insertions.enumerated().sorted {
            ($0.element.offset, $0.offset) > ($1.element.offset, $1.offset)
        }
        for (_, insertion) in ordered {
            let index = Self.index(insertion.offset, in: value) ?? value.endIndex
            value.insert(insertion.marker, at: index)
        }
        return value
    }

    private static func index(_ offset: Int, in value: AttributedString) -> AttributedString.Index? {
        guard offset >= 0 else { return nil }
        return value.characters.index(
            value.characters.startIndex,
            offsetBy: offset,
            limitedBy: value.characters.endIndex
        )
    }

    private static func range(
        _ start: Int,
        _ end: Int,
        in value: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let lower = index(start, in: value),
              let upper = index(end, in: value),
              lower < upper else { return nil }
        return lower..<upper
    }
}

// MARK: - Section Views

private struct BookSectionHeader: View {
    let section: BookSection
    let style: BookTextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let number = section.number, !number.isEmpty {
                Text(number.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
            Text(section.title)
                .font(style.font(1.6, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = section.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(style.font(1.1))
                    .foregroundStyle(.secondary)
            }
            if !section.keyScriptures.isEmpty {
                WrappingHStack(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(section.keyScriptures, id: \.self) { reference in
                        if let url = Self.url(for: reference) {
                            Link(destination: url) {
                                Label(
                                    reference.label ?? Self.formatReference(reference),
                                    systemImage: "book.pages"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, style.fontSize * 0.4)
    }

    private static func url(for range: BookScriptureRange) -> URL? {
        let end = range.ev.map { "/\($0)" } ?? ""
        return URL(string: "lampbible://verse/\(range.sv)\(end)")
    }

    private static func formatReference(_ range: BookScriptureRange) -> String {
        func components(_ value: Int) -> (String, Int, Int) {
            let bookNumber = value / 1_000_000
            let chapter = (value % 1_000_000) / 1_000
            let verse = value % 1_000
            let name = (try? BundledModuleDatabase.shared.getBook(id: bookNumber))?.name ?? "Book \(bookNumber)"
            return (name, chapter, verse)
        }

        let start = components(range.sv)
        guard let endValue = range.ev, endValue != range.sv else {
            return "\(start.0) \(start.1):\(start.2)"
        }
        let end = components(endValue)
        if start.0 == end.0 && start.1 == end.1 {
            return "\(start.0) \(start.1):\(start.2)–\(end.2)"
        }
        return "\(start.0) \(start.1):\(start.2)–\(end.0) \(end.1):\(end.2)"
    }
}

/// One block of a section. Equatable on what it draws, so that scrolling,
/// which changes the reader's state as each block passes, redraws none of them.
private struct BookContentBlockView: View, Equatable {
    let index: Int
    let document: BookSectionDocument
    let moduleId: String
    let mediaByID: [String: MediaReference]
    let style: BookTextStyle

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.document === rhs.document
            && lhs.moduleId == rhs.moduleId && lhs.style == rhs.style
    }

    private var block: BookContentBlock { document.blocks[index] }

    @ViewBuilder
    var body: some View {
        switch block.type {
        case "heading":
            prose(block.content, scale: headingScale, weight: (block.level ?? 2) <= 2 ? .bold : .semibold)
                .padding(.top, style.fontSize * 0.5)
                .accessibilityAddTraits(.isHeader)
        case "blockquote":
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 3)
                // Primary, not the secondary of a caption: in some of these
                // books quotations, mostly of scripture, outnumber the
                // author's own paragraphs.
                prose(block.content, scale: 0.94)
            }
            .padding(.leading, 4)
        case "list":
            VStack(alignment: .leading, spacing: style.fontSize * 0.45) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { itemIndex, item in
                    BookListItemView(
                        item: item,
                        marker: block.listType == "numbered" ? "\(itemIndex + 1)." : "•",
                        document: document,
                        style: style
                    )
                }
            }
        case "table":
            BookTableView(block: block, document: document, style: style)
        case "thematic-break":
            Capsule()
                .fill(.separator)
                .frame(width: 64, height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, style.fontSize * 0.6)
                .accessibilityHidden(true)
        case "image", "audio":
            if let mediaId = block.mediaID, let mediaRef = mediaByID[mediaId] {
                ModuleMediaView(
                    mediaRef: mediaRef,
                    moduleId: moduleId,
                    caption: block.caption?.text ?? mediaRef.caption,
                    alignment: block.alignment.flatMap(MediaAlignment.init(rawValue:)) ?? .center
                )
            } else {
                MissingBookMediaView(
                    icon: block.type == "image" ? "photo" : "waveform",
                    label: block.caption?.text ?? (block.type == "image" ? "Image unavailable" : "Audio unavailable")
                )
            }
        default:
            prose(block.content)
        }
    }

    private func prose(
        _ content: BookAnnotatedText?,
        scale: Double = 1,
        weight: Font.Weight = .regular
    ) -> some View {
        // Each link run that names its own colour keeps it; the tint covers
        // any that doesn't, which would otherwise take the accent.
        Text(document.text(for: content))
            .font(style.font(scale, weight: weight))
            .lineSpacing(style.lineSpacing * (scale > 1 ? 0.5 : 1))
            .tint(.lampLink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headingScale: Double {
        switch block.level ?? 2 {
        case 1: 1.45
        case 2: 1.25
        case 3: 1.1
        default: 1.02
        }
    }
}

private struct BookListItemView: View {
    let item: BookListItem
    let marker: String
    let document: BookSectionDocument
    let style: BookTextStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.fontSize * 0.4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(style.font())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: style.fontSize * 1.2, alignment: .trailing)
                Text(document.text(for: item.content))
                    .font(style.font())
                    .lineSpacing(style.lineSpacing)
                    .tint(.lampLink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                BookListItemView(item: child, marker: "◦", document: document, style: style)
                    .padding(.leading, style.fontSize * 1.4)
            }
        }
    }
}

/// A table at the reading width when its columns fit there, with its text
/// wrapping in them. Wider tables scroll sideways, a fixed width to a column:
/// in a sideways scroll a cell would otherwise run its text out on one line.
private struct BookTableView: View {
    let block: BookContentBlock
    let document: BookSectionDocument
    let style: BookTextStyle

    private enum ColumnSizing {
        case shares([Double], minimums: [CGFloat])
        case fixed(CGFloat)
    }

    private var columnCount: Int {
        let widest = block.rows.map { $0.cells.reduce(0) { $0 + $1.columnSpan } }.max() ?? 0
        return max(block.columnCount ?? 0, widest, 1)
    }

    /// Each column's share of the reading width, by the longest text it
    /// holds: a column of single terms beside one of definitions shouldn't
    /// take half the table.
    private var columnShares: [Double] {
        var lengths = Array(repeating: 0.0, count: columnCount)
        for row in block.rows {
            for cell in row.cells
            where cell.columnSpan == 1 && !cell.isHeader && lengths.indices.contains(cell.column) {
                lengths[cell.column] = max(lengths[cell.column], Double(min(cell.content.text.count, 240)))
            }
        }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / Double(columnCount), count: columnCount) }
        let floor = 0.6 / Double(columnCount)
        let raised = lengths.map { max($0 / total, floor) }
        let sum = raised.reduce(0, +)
        return raised.map { $0 / sum }
    }

    /// The narrowest each column can be without breaking a word: its longest
    /// word, measured in the cell's face and a little bolder for headers, and
    /// the cell's padding.
    private var minimumWidths: [CGFloat] {
        let base = UIFont.systemFont(ofSize: style.fontSize * 0.88, weight: .semibold)
        let font = style.typeface == .serif
            ? base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 0) } ?? base
            : base
        var widths = Array(repeating: CGFloat(0), count: columnCount)
        for row in block.rows {
            for cell in row.cells where cell.columnSpan == 1 && widths.indices.contains(cell.column) {
                for word in cell.content.text.split(whereSeparator: \.isWhitespace) {
                    let width = (String(word) as NSString).size(withAttributes: [.font: font]).width
                    widths[cell.column] = max(widths[cell.column], width.rounded(.up))
                }
            }
        }
        return widths.map { $0 + 20 }
    }

    /// Widths by share, with any column too narrow for its longest word
    /// widened, up to most of the table, at the others' expense.
    private static func columnWidths(
        available: CGFloat,
        shares: [Double],
        minimums: [CGFloat]
    ) -> [CGFloat] {
        var widths: [CGFloat] = shares.map { available * CGFloat($0) }
        let narrow = Set(widths.indices.filter { widths[$0] < minimums[$0] })
        guard !narrow.isEmpty else { return widths }
        for index in narrow { widths[index] = min(minimums[index], available * 0.6) }
        let taken = narrow.reduce(CGFloat(0)) { $0 + widths[$1] }
        let others = widths.indices.filter { !narrow.contains($0) }
        let otherShare = others.reduce(0.0) { $0 + shares[$1] }
        guard otherShare > 0 else { return widths }
        for index in others {
            widths[index] = max(available - taken, 0) * CGFloat(shares[index] / otherShare)
        }
        return widths
    }

    var body: some View {
        if columnCount <= 3 {
            grid(.shares(columnShares, minimums: minimumWidths))
        } else {
            ScrollView(.horizontal) {
                grid(.fixed(200))
            }
            // Drawn on into the margin, so that a table cut off at the edge
            // reads as one that scrolls.
            .scrollClipDisabled()
        }
    }

    private func grid(_ sizing: ColumnSizing) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.sorted { $0.column < $1.column }.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, sizing: sizing)
                            .gridCellColumns(cell.columnSpan)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
    }

    private func cellView(_ cell: LampBookTableCell, sizing: ColumnSizing) -> some View {
        sized(
            Text(document.text(for: cell.content))
                .font(style.font(0.88, weight: cell.isHeader ? .semibold : .regular))
                .lineSpacing(style.lineSpacing * 0.6)
                .tint(.lampLink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8),
            cell: cell,
            sizing: sizing
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: cell.isHeader ? .secondarySystemFill : .tertiarySystemFill))
    }

    @ViewBuilder
    private func sized(_ content: some View, cell: LampBookTableCell, sizing: ColumnSizing) -> some View {
        let gaps = CGFloat(cell.columnSpan - 1)
        switch sizing {
        case .fixed(let width):
            content.frame(width: width * CGFloat(cell.columnSpan) + gaps, alignment: .topLeading)
        case .shares(let shares, let minimums):
            content.containerRelativeFrame(.horizontal, alignment: .topLeading) { length, _ in
                let available = min(length - 2 * BookReaderLayout.margin, BookReaderLayout.measure)
                    - CGFloat(shares.count - 1)
                let widths = Self.columnWidths(available: available, shares: shares, minimums: minimums)
                let lower = min(cell.column, widths.count)
                let upper = min(cell.column + cell.columnSpan, widths.count)
                return max(widths[lower..<upper].reduce(0, +) + gaps, 44)
            }
        }
    }
}

/// The section's footnotes at its end, folded away until wanted, for reading
/// them through rather than one marker at a time.
private struct BookSectionFootnotesView: View {
    let document: BookSectionDocument
    let footnotesByID: [String: BookFootnote]
    let style: BookTextStyle
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(document.footnoteIDs, id: \.self) { id in
                    if let footnote = footnotesByID[id] {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(document.renderer.footnoteNumbers[id].map { "\($0)." } ?? "•")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: style.fontSize * 1.6, alignment: .trailing)
                            Text(document.renderer.render(footnote.content.annotatedText))
                                .lineSpacing(style.lineSpacing * 0.8)
                                .tint(.lampLink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(style.font(0.85))
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Text("Footnotes (\(document.footnoteIDs.count))")
                .font(style.font(0.94, weight: .semibold))
        }
        // Not the accent: this is the book's apparatus, not a control the
        // reader is being pointed to.
        .tint(Color.primary)
        .padding(.top, 12)
    }
}

private struct MissingBookMediaView: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Text Settings

private struct BookTextSettingsView: View {
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var typeface: BookTypeface

    private var isDefault: Bool {
        fontSize == BookTextStyle.defaultFontSize
            && lineSpacing == BookTextStyle.defaultLineSpacing
            && typeface == .serif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Typeface", selection: $typeface) {
                ForEach(BookTypeface.allCases) { typeface in
                    Text(typeface.title).tag(typeface)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $fontSize, in: BookTextStyle.fontSizes, step: 1) {
                LabeledContent("Text Size", value: "\(Int(fontSize.rounded())) pt")
            }
            Stepper(value: $lineSpacing, in: BookTextStyle.lineSpacings, step: 1) {
                LabeledContent("Line Spacing", value: "\(Int(lineSpacing.rounded()))")
            }

            Button("Reset to Defaults") {
                fontSize = BookTextStyle.defaultFontSize
                lineSpacing = BookTextStyle.defaultLineSpacing
                typeface = .serif
            }
            .disabled(isDefault)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Contents

private struct BookContentsView: View {
    let book: BookModule
    let sections: [BookSection]
    let currentSectionID: String?
    /// The open section's headings.
    let headings: [BookSectionHeading]
    let currentBlock: Int
    let onSelect: (_ sectionID: String, _ block: Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The heading the reader is under: the last at or before the first
    /// block on screen.
    private var currentHeading: BookSectionHeading? {
        headings.last { $0.blockIndex <= currentBlock }
    }

    private var minimumDepth: Int { sections.map(\.depth).min() ?? 0 }
    private var minimumLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        NavigationLink {
                            BookDetailsList(book: book)
                        } label: {
                            BookContentsHeader(book: book)
                        }
                    }
                    if query.isEmpty {
                        Section("Contents") {
                            ForEach(sections) { section in
                                sectionRow(section, snippet: nil)
                                if section.id == currentSectionID {
                                    ForEach(headings) { headingRow($0) }
                                }
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .onAppear {
                    let target = currentHeading.map { "heading-\($0.blockIndex)" } ?? currentSectionID
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search this book")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let headingMatches = headings.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let sectionMatches = sections.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle?.localizedCaseInsensitiveContains(query) == true
                || $0.searchText.localizedCaseInsensitiveContains(query)
        }
        if headingMatches.isEmpty && sectionMatches.isEmpty {
            ContentUnavailableView.search(text: query)
        }
        if !headingMatches.isEmpty {
            Section("Headings") {
                ForEach(headingMatches) { headingRow($0) }
            }
        }
        if !sectionMatches.isEmpty {
            Section("Sections") {
                ForEach(sectionMatches) { section in
                    let titleMatches = section.title.localizedCaseInsensitiveContains(query)
                    sectionRow(section, snippet: titleMatches ? nil : Self.snippet(in: section.searchText, matching: query))
                }
            }
        }
    }

    private func sectionRow(_ section: BookSection, snippet: AttributedString?) -> some View {
        let isCurrent = section.id == currentSectionID
        return Button {
            onSelect(section.id, -1)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let number = section.number, !number.isEmpty {
                    Text(number)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(section.title)
                    .font(.body.weight(isCurrent || section.sectionType == "part" ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let snippet {
                    Text(snippet)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(max(section.depth - minimumDepth, 0)) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(section.id)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func headingRow(_ heading: BookSectionHeading) -> some View {
        let isCurrent = heading.blockIndex == currentHeading?.blockIndex
        return Button {
            if let currentSectionID { onSelect(currentSectionID, heading.blockIndex) }
        } label: {
            Text(heading.title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16 + CGFloat(max(heading.level - minimumLevel, 0)) * 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id("heading-\(heading.blockIndex)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// A line of a section's text around the first match, the match in bold.
    private static func snippet(in text: String, matching query: String) -> AttributedString? {
        guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = text.index(match.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        func plain(_ part: Substring) -> AttributedString {
            AttributedString(part.replacingOccurrences(of: "\n", with: " "))
        }
        var result = AttributedString(start > text.startIndex ? "…" : "")
        result += plain(text[start..<match.lowerBound])
        var found = plain(text[match])
        found.inlinePresentationIntent = .stronglyEmphasized
        found.foregroundColor = Color.primary
        result += found
        result += plain(text[match.upperBound..<end])
        if end < text.endIndex { result += AttributedString("…") }
        return result
    }
}

private struct BookContentsHeader: View {
    let book: BookModule

    var body: some View {
        HStack(spacing: 14) {
            BookCoverThumbnail(book: book)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BookDetailsList: View {
    let book: BookModule

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    Text(book.title).font(.title2.bold())
                    if let subtitle = book.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                    if let description = book.description { Text(description).padding(.top, 4) }
                }
                .padding(.vertical, 5)
            }
            Section("Publication") {
                detail("Author", book.author)
                detail("Editor", book.editor)
                detail("Publisher", book.publisher)
                detail("Year", book.year.map(String.init))
                detail("Edition", book.edition)
                detail("ISBN", book.isbn)
                detail("Language", book.language)
            }
            if !book.tags.isEmpty {
                Section("Tags") { Text(book.tags.joined(separator: " • ")) }
            }
            if book.copyright != nil || book.license != nil {
                Section("Rights") {
                    if let copyright = book.copyright { Text(copyright) }
                    if let license = book.license { Text(license).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("About This Book")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}

// MARK: - Footnote

private struct BookFootnoteSheet: View {
    let footnote: BookFootnote
    let number: Int?
    let renderer: BookTextRenderer
    let style: BookTextStyle
    let translationID: String
    let openReader: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: PreviewSheetState?
    @State private var strongs: BookStrongsDestination?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(renderer.render(footnote.content.annotatedText))
                    .font(style.font(0.94))
                    .lineSpacing(style.lineSpacing)
                    .tint(.lampLink)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(number.map { "Footnote \($0)" } ?? "Footnote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            switch LampbibleURL.parse(url) {
            case .verse(let reference, let endReference, let translationID)?:
                showPassage(reference, through: endReference, translationID: translationID)
            case .reading(let reference, let endReference, _)?:
                showPassage(reference, through: endReference, translationID: nil)
            case .strongs(let key)?:
                strongs = BookStrongsDestination(key: key)
            case .external?, nil:
                // A marker for another footnote, inside this one, goes nowhere.
                return url.host == "book-footnote" ? .handled : .systemAction
            }
            return .handled
        })
        .sheet(item: $preview) { _ in
            PreviewSheet(state: $preview, translationId: translationID, onNavigateToVerse: openReader)
        }
        .sheet(item: $strongs) { destination in
            LexiconSheetView(
                word: destination.key,
                strongs: [destination.key],
                morphology: nil,
                translationId: translationID
            )
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func showPassage(_ reference: Int, through endReference: Int?, translationID: String?) {
        let item = PreviewItem.verse(
            index: 0,
            verseId: reference,
            endVerseId: endReference,
            displayText: "",
            translationId: translationID
        )
        preview = PreviewSheetState(currentItem: item, allItems: [item])
    }
}
