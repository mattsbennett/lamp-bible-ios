import SwiftUI
import UniformTypeIdentifiers
import LampCore
import LampModuleKit

struct BookLibraryView: View {
    @State private var books: [BookLibraryItem] = []
    @State private var positions: [String: LampBookReadingPosition] = [:]
    @State private var sectionTitles: [String: String] = [:]
    @State private var selectedBook: BookLibraryItem?
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showingDuplicateAlert = false
    @State private var duplicateBookName = ""
    @State private var pendingImportURL: URL?
    @State private var pendingImportHasSecurityScope = false
    @State private var toast: LampToast?

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
                // A shelf of covers, as a bookshop or Apple Books lays one out.
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        if !isSearching && !recentBooks.isEmpty {
                            shelf("Continue Reading", recentBooks)
                            shelf("All Books", books)
                        } else {
                            shelf(nil, filteredBooks)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .refreshable { loadBooks() }
            }
        }
        .navigationTitle("Books")
        .navigationBarTitleDisplayMode(.large)
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
        .lampToast($toast)
        .task { loadBooks() }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            loadBooks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookReadingDidChange)) { _ in
            loadPositions()
        }
    }

    private func shelf(_ title: String?, _ items: [BookLibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 28
            ) {
                ForEach(items) { row(for: $0) }
                // The shelf's last place is the way to add to it, named, as
                // well as the toolbar's import button.
                if title != "Continue Reading" && !isSearching {
                    importTile
                }
            }
        }
    }

    private var importTile: some View {
        Button {
            showingImporter = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(LampTheme.caption.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(LampTheme.tileFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 28, weight: .medium))
                            Text("Import a Book")
                                .font(.subheadline.weight(.semibold))
                            Text(".lamp or JSON")
                                .font(.caption)
                                .foregroundStyle(LampTheme.caption)
                        }
                        .foregroundStyle(Color.primary.opacity(0.75))
                    }
                Text(" ")
                    .font(.subheadline)
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(BookCoverButtonStyle())
        .disabled(isImporting)
        .accessibilityLabel("Import a Book")
    }

    private func row(for item: BookLibraryItem) -> some View {
        Button {
            selectedBook = item
        } label: {
            BookLibraryRow(item: item, position: positions[item.id], sectionTitle: sectionTitles[item.id])
        }
        .buttonStyle(BookCoverButtonStyle())
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
        let installed = Set(books.map(\.id))
        positions = BookReadingState.store().positions().filter { installed.contains($0.key) }
        // Looked up, not kept with the position: a section renamed by a newer
        // edition shows its current title, and the two apps can't disagree.
        sectionTitles = positions.compactMapValues { position in
            (try? ModuleDatabase.shared.getBookSectionTitle(id: position.sectionID))
                ?? (try? BundledModuleDatabase.shared.getBookSectionTitle(id: position.sectionID))
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
                let name = try? ModuleSyncManager.shared.existingModuleName(forDocumentAt: url)
                if accessing { url.stopAccessingSecurityScopedResource() }
                loadBooks()
                isImporting = false
                announceImport(name: name ?? nil, replaced: false)
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
                let name = try? ModuleSyncManager.shared.existingModuleName(forDocumentAt: url)
                loadBooks()
                isImporting = false
                announceImport(name: name ?? nil, replaced: true)
            } catch {
                isImporting = false
                alertMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    /// Says the import finished, without an alert to dismiss.
    private func announceImport(name: String?, replaced: Bool) {
        let verb = replaced ? "Updated" : "Imported"
        toast = LampToast(
            title: name.map { "\(verb) “\($0)”" } ?? "Book \(verb)",
            message: "Book · now on your shelf"
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

/// A book on the shelf: its cover, then its title, author, and where the
/// reader left it.
private struct BookLibraryRow: View {
    let item: BookLibraryItem
    let position: LampBookReadingPosition?
    let sectionTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCover(book: item.book)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                // Two lines kept for every title, so the lines beneath sit
                // level across the shelf.
                Text(item.book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                if let author = item.book.author, !author.isEmpty {
                    Text(author)
                        .font(.footnote)
                        .foregroundStyle(LampTheme.caption)
                        .lineLimit(1)
                }
                // Where the reader stands in it, which the cover can't say.
                Group {
                    if position != nil {
                        Label(sectionTitle ?? "Continue reading", systemImage: "bookmark.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Label(item.isBundled ? "Included · Not started" : "Not started", systemImage: "sparkle")
                            .foregroundStyle(LampTheme.caption)
                    }
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.top, 2)
            }
            .labelStyle(BookRowLabelStyle())
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct BookCoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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

/// A book's cover: its own image, or one set from its title and author.
private struct BookCover: View {
    let book: BookModule
    /// A thumbnail: a hairline and the faintest shadow, not a shelf's.
    var compact = false
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LampGeneratedCover(id: book.id, title: book.title, author: book.author)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(LampTheme.hairline)
        }
        .shadow(color: .black.opacity(compact ? 0.08 : 0.14), radius: compact ? 1.5 : 6, x: 0, y: compact ? 1 : 4)
        .onAppear {
            guard image == nil, let cover = book.coverMediaReference else { return }
            image = ModuleMediaStorage.shared.loadImage(for: cover, moduleId: book.id)
        }
        .accessibilityHidden(true)
    }
}


// MARK: - Text Style

/// How a book's text is set: under the Mac's keys, in the scales both apps
/// share (`LampTextScale`), so a size means the same on both.
private struct BookTextStyle: Equatable {
    static let fontSizeKey = "books.fontSize"
    static let lineSpacingKey = "books.lineSpacing"
    static let typefaceKey = "books.typeface"

    var fontSize: Double
    var lineSpacing: Double
    var typeface: LampProseTypeface

    init(fontSize: Double, lineSpacing: Double, typeface: LampProseTypeface) {
        self.fontSize = LampTextScale.bookText.clamped(fontSize)
        self.lineSpacing = LampTextScale.bookLineSpacing.clamped(lineSpacing)
        self.typeface = typeface
    }

    func font(_ scale: Double = 1, weight: Font.Weight = .regular) -> Font {
        .system(size: fontSize * scale, weight: weight, design: typeface.design)
    }

    var paragraphSpacing: Double { fontSize * 0.8 }
}

private extension LampProseTypeface {
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
    /// The page and its text: the reader's own (`LampTheme.readerBackground`,
    /// `LampTheme.readerText`), softer than pure black or white, which glare
    /// over a long read.
    static let paper = Color(uiColor: UIColor { traits in
        // White in light, as the reader's page; in dark a near black, which
        // pure black behind off-white text makes halo over a long read.
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1)
            : .systemBackground
    })
    static let ink = LampTheme.readerText
    /// A book's margins, a little wider than the Bible reader's, as a
    /// printed page's are.
    static let margin: CGFloat = 26
    /// The widest the text runs, about 70 characters at the default size.
    static let measure: CGFloat = 680
}

/// Reader for bundled and user-installed long-form book modules.
struct BookModuleView: View {
    let moduleId: String
    var initialSectionId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage(BookTextStyle.fontSizeKey) private var fontSize = LampTextScale.bookText.defaultValue
    @AppStorage(BookTextStyle.lineSpacingKey) private var lineSpacing = LampTextScale.bookLineSpacing.defaultValue
    @AppStorage(BookTextStyle.typefaceKey) private var typeface = LampProseTypeface.serif

    @State private var book: BookModule?
    @State private var sections: [BookSection] = []
    @State private var footnotesByID: [String: BookFootnote] = [:]
    @State private var footnoteNumbers: [String: Int] = [:]
    @State private var mediaByID: [String: MediaReference] = [:]
    @State private var selectedSectionId: String?
    @State private var bookmarkIDs: Set<String> = []
    @State private var document: BookSectionDocument?
    /// Where to put the reader once the selected section is ready.
    @State private var landingBlock = -1
    /// The place the book was left, when it opens there: its block is found
    /// again once the section's blocks are decoded, in case a rebuild of the
    /// book has moved them.
    @State private var resumedPosition: LampBookReadingPosition?
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
                    currentBlock: topBlock,
                    bookmarkIDs: bookmarkIDs
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
                styler: BookTextStyler(footnoteNumbers: footnoteNumbers, fontSize: style.fontSize),
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
        .onReceive(NotificationCenter.default.publisher(for: .bookReadingDidChange)) { _ in
            bookmarkIDs = BookReadingState.store().bookmarkIDs(for: moduleId)
        }
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
                    BookSectionHeader(section: section, bookTitle: book.title, style: style)
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
                .foregroundStyle(BookReaderLayout.ink)
                .padding(.horizontal, BookReaderLayout.margin)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .id(section.id)
            .background(BookReaderLayout.paper.ignoresSafeArea())
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
        // The book's name is the page's running head, so the bar carries
        // only its buttons rather than a title squeezed between them.
        ToolbarItem(placement: .principal) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        ToolbarItem(placement: .cancellationAction) {
            // A glyph, as the verse preview's is: with three buttons beside
            // it, a worded one left the book's title cut short.
            Button("Close", systemImage: "xmark") { dismiss() }
                .labelStyle(.iconOnly)
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
            Button(
                isBookmarked ? "Remove Bookmark" : "Bookmark Section",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            ) {
                guard let selectedSectionId else { return }
                BookReadingState.store().toggleBookmark(sectionID: selectedSectionId, for: moduleId)
                bookmarkIDs = BookReadingState.store().bookmarkIDs(for: moduleId)
            }
            .labelStyle(.iconOnly)
            .disabled(selectedSectionId == nil)
            Button("Contents", systemImage: "list.bullet") { showingContents = true }
                .labelStyle(.iconOnly)
                .disabled(book == nil)
        }
    }

    private var isBookmarked: Bool {
        selectedSectionId.map(bookmarkIDs.contains) ?? false
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
        resumedPosition = nil
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
        guard let selectedSectionId else { return }
        // Anchored to the block's opening words, which find it again after a
        // rebuild; a section not yet decoded has only its top to give.
        let blocks = document?.sectionID == selectedSectionId ? document?.blocks ?? [] : []
        BookReadingState.store().save(
            position: LampBookReadingPosition(sectionID: selectedSectionId, blockIndex: topBlock, in: blocks),
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

            let store = BookReadingState.store()
            let saved = store.position(for: moduleId)
            bookmarkIDs = store.bookmarkIDs(for: moduleId)
            func exists(_ id: String?) -> Bool {
                id.map { id in loadedSections.contains { $0.id == id } } ?? false
            }
            resumedPosition = nil
            if exists(initialSectionId) {
                selectedSectionId = initialSectionId
                landingBlock = -1
            } else if let saved, exists(saved.sectionID) {
                selectedSectionId = saved.sectionID
                landingBlock = saved.blockIndex
                resumedPosition = saved
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
        if !keepsPlace, let resumed = resumedPosition, resumed.sectionID == sectionID {
            landingBlock = resumed.blockIndex(in: prepared.blocks)
            topBlock = landingBlock
            resumedPosition = nil
        }
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

private typealias BookSectionHeading = LampBookSectionIndex.Heading

/// A section made ready to read: its blocks decoded and their text set once,
/// rather than on every redraw.
private final class BookSectionDocument: Sendable {
    let sectionID: String
    let fontSize: Double
    let blocks: [BookContentBlock]
    /// The headings the contents lists, down to level 3.
    let headings: [BookSectionHeading]
    /// The section's key passages, then each passage it cites, once, in the
    /// order first cited: what the verse preview steps through.
    let references: [PreviewItem]
    /// The footnotes it cites, in the order first cited.
    let footnoteIDs: [String]
    let styler: BookTextStyler
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
        let styler = BookTextStyler(footnoteNumbers: footnoteNumbers, fontSize: fontSize)
        self.styler = styler
        let blocks = LampPortableBookJSON.decodeArray(contentJSON, as: BookContentBlock.self).items
        self.blocks = blocks

        let index = LampBookSectionIndex(blocks: blocks)
        headings = index.headings.filter { $0.level <= 3 }
        footnoteIDs = index.footnoteIDs
        var passages = keyScriptures.map { (LampBookPassage(start: $0.sv, end: $0.ev), $0.label ?? "") }
        for passage in index.passages where !passages.contains(where: { $0.0 == passage }) {
            passages.append((passage, ""))
        }
        // An empty label lets the preview name the passage itself.
        references = passages.enumerated().map { index, cited in
            .verse(index: index, verseId: cited.0.start, endVerseId: cited.0.end, displayText: cited.1)
        }

        var texts: [BookAnnotatedText: AttributedString] = [:]
        for content in index.annotatedTexts where texts[content] == nil {
            texts[content] = styler.text(content)
        }
        self.texts = texts
    }

    func text(for content: BookAnnotatedText?) -> AttributedString {
        guard let content else { return AttributedString() }
        return texts[content] ?? styler.text(content)
    }
}

// MARK: - Text

/// Sets a book's text as the phone shows it, from what core says each stretch
/// is (`LampBookTextResolver`): links in the forms this reader opens, footnote
/// markers small and raised, page markers small and grey, original-language
/// words in their colour.
private struct BookTextStyler: Sendable {
    let footnoteNumbers: [String: Int]
    let fontSize: Double

    static func footnoteURL(_ id: String) -> URL? {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "lampbible://book-footnote/\($0)") }
    }

    func text(_ content: BookAnnotatedText) -> AttributedString {
        var value = LampBookTextResolver.resolve(content, footnoteNumbers: footnoteNumbers)

        // Before the book's own links are added: only a link to the web
        // leaves the app, so only it is underlined.
        let webLinks = value.runs[AttributeScopes.FoundationAttributes.LinkAttribute.self]
            .compactMap { run in run.0 == nil ? nil : run.1 }
        for range in webLinks { value[range].underlineStyle = .single }

        let passages = value.runs[LampBookTextAttributes.Scripture.self]
            .compactMap { run in run.0.map { ($0, run.1) } }
        for (passage, range) in passages { value[range].link = passage.verseURL }

        let marks = value.runs[LampBookTextAttributes.Footnote.self]
            .compactMap { run in run.0.map { ($0, run.1) } }
        for (mark, range) in marks {
            value[range].link = Self.footnoteURL(mark.id)
            if mark.isMarker {
                value[range].font = Font.system(size: fontSize * 0.68, weight: .medium)
                value[range].baselineOffset = fontSize * 0.3
            }
        }

        let words = value.runs[LampBookTextAttributes.OriginalLanguage.self]
            .compactMap { run in run.0.map { ($0, run.1) } }
        for (word, range) in words {
            value[range].foregroundColor = Color.lampOriginalLanguage
            value[range].underlineStyle = .single
            if let key = word.strongs,
               let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                value[range].link = URL(string: "lampbible://strongs/\(encodedKey)")
            }
        }

        let underlined = value.runs[LampBookTextAttributes.Underline.self]
            .compactMap { run in run.0 == true ? run.1 : nil }
        for range in underlined { value[range].underlineStyle = .single }

        let pages = value.runs[LampBookTextAttributes.Page.self]
            .compactMap { run in run.0 == nil ? nil : run.1 }
        for range in pages {
            value[range].font = Font.system(size: fontSize * 0.7)
            value[range].foregroundColor = Color.secondary
        }
        return value
    }
}

// MARK: - Section Views

private struct BookSectionHeader: View {
    let section: BookSection
    let bookTitle: String
    let style: BookTextStyle

    /// A chapter opens as a printed one does: the book's name as a running
    /// head, then the number large in the text's face, the title centred
    /// beneath it, and a short rule before the text.
    var body: some View {
        VStack(spacing: style.fontSize * 0.5) {
            Text(bookTitle.uppercased())
                .font(.footnote.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Color.primary.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.bottom, style.fontSize * 0.5)
            if let number = section.number, !number.isEmpty {
                Text(number.uppercased())
                    .font(style.font(1.7, weight: .regular))
                    .foregroundStyle(.tint)
            }
            Text(section.title)
                .font(style.font(1.5, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = section.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(style.font(1.05).italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 32, height: 2)
                .padding(.top, style.fontSize * 0.3)
                .accessibilityHidden(true)
            if !section.keyScriptures.isEmpty {
                WrappingHStack(alignment: .center, horizontalSpacing: 8, verticalSpacing: 8) {
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
        .frame(maxWidth: .infinity)
        .padding(.top, style.fontSize * 0.2)
        .padding(.bottom, style.fontSize * 0.6)
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
                // The accent itself, as the chapter number is, so the page
                // has one red rather than a red and a pink.
                RoundedRectangle(cornerRadius: 1.25)
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
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
            if index == 0 {
                prose(block.content, leadIn: true)
            } else {
                prose(block.content)
            }
        }
    }

    /// A first word printed in capitals ("IN this, a man…"), as old books
    /// open a chapter, set in small capitals so it reads as the lead-in it
    /// is rather than as shouting.
    private func withSmallCapLeadIn(_ text: AttributedString) -> AttributedString {
        var text = text
        let characters = text.characters
        var end = characters.startIndex
        var letters = 0
        while end < characters.endIndex, characters[end].isLetter {
            guard characters[end].isUppercase else { return text }
            letters += 1
            end = characters.index(after: end)
        }
        guard letters >= 2, end < characters.endIndex, characters[end] == " " else { return text }
        // Only a lead-in if the sentence goes on in lower case.
        let rest = characters[end...].dropFirst().prefix(12)
        guard rest.contains(where: { $0.isLowercase }) else { return text }
        let range = text.startIndex..<end
        text[range].font = style.font().uppercaseSmallCaps()
        text[range].kern = 0.6
        return text
    }

    private func prose(
        _ content: BookAnnotatedText?,
        scale: Double = 1,
        weight: Font.Weight = .regular,
        leadIn: Bool = false
    ) -> some View {
        // Each link run that names its own colour keeps it; the tint covers
        // any that doesn't, which would otherwise take the accent.
        let text = document.text(for: content)
        return Text(leadIn ? withSmallCapLeadIn(text) : text)
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
/// Each cell sits at the column it names (`LampBookTableLayout`), so a row
/// missing a cell keeps the rest under their headings.
private struct BookTableView: View {
    let block: BookContentBlock
    let document: BookSectionDocument
    let style: BookTextStyle

    private enum ColumnSizing {
        case shares([Double], minimums: [CGFloat])
        case fixed(CGFloat)
    }

    private var columnCount: Int {
        LampBookTableLayout.resolvedColumnCount(declared: block.columnCount, rows: block.rows)
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
            grid(.shares(
                LampBookTableLayout.columnWeights(rows: block.rows, columnCount: columnCount),
                minimums: minimumWidths
            ))
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
        let columnCount = columnCount
        return Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(LampBookTableLayout.placements(of: row, columnCount: columnCount), id: \.column) { placement in
                        cellView(placement, sizing: sizing)
                            .gridCellColumns(placement.span)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
    }

    private func cellView(_ placement: LampBookTableLayout.Placement, sizing: ColumnSizing) -> some View {
        let isHeader = placement.cell?.isHeader == true
        return sized(
            Text(placement.cell.map { document.text(for: $0.content) } ?? AttributedString())
                .font(style.font(0.88, weight: isHeader ? .semibold : .regular))
                .lineSpacing(style.lineSpacing * 0.6)
                .tint(.lampLink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8),
            placement: placement,
            sizing: sizing
        )
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: isHeader ? .secondarySystemFill : .tertiarySystemFill))
    }

    @ViewBuilder
    private func sized(
        _ content: some View,
        placement: LampBookTableLayout.Placement,
        sizing: ColumnSizing
    ) -> some View {
        let gaps = CGFloat(placement.span - 1)
        switch sizing {
        case .fixed(let width):
            content.frame(width: width * CGFloat(placement.span) + gaps, alignment: .topLeading)
        case .shares(let shares, let minimums):
            content.containerRelativeFrame(.horizontal, alignment: .topLeading) { length, _ in
                let available = min(length - 2 * BookReaderLayout.margin, BookReaderLayout.measure)
                    - CGFloat(shares.count - 1)
                let widths = Self.columnWidths(available: available, shares: shares, minimums: minimums)
                let lower = min(placement.column, widths.count)
                let upper = min(placement.column + placement.span, widths.count)
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
                            Text(document.styler.footnoteNumbers[id].map { "\($0)." } ?? "•")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: style.fontSize * 1.6, alignment: .trailing)
                            Text(document.styler.text(footnote.content.annotatedText))
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
    @Binding var typeface: LampProseTypeface

    private let sizes = LampTextScale.bookText
    private let spacings = LampTextScale.bookLineSpacing

    private var isDefault: Bool {
        fontSize == sizes.defaultValue && lineSpacing == spacings.defaultValue && typeface == .serif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Typeface", selection: $typeface) {
                ForEach(LampProseTypeface.allCases, id: \.self) { typeface in
                    Text(typeface.title).tag(typeface)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $fontSize, in: sizes.range, step: sizes.step) {
                LabeledContent("Text Size", value: "\(Int(fontSize.rounded())) pt")
            }
            Stepper(value: $lineSpacing, in: spacings.range, step: spacings.step) {
                LabeledContent("Line Spacing", value: "\(Int(lineSpacing.rounded()))")
            }

            Button("Reset to Defaults") {
                fontSize = sizes.defaultValue
                lineSpacing = spacings.defaultValue
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
    let bookmarkIDs: Set<String>
    let onSelect: (_ sectionID: String, _ block: Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    /// An unnumbered section's headings (front matter: edition notes,
    /// copyright lines) start folded away, so the chapters lead the list.
    @State private var showsUnnumberedHeadings = false

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The heading the reader is under: the last at or before the first
    /// block on screen.
    private var currentHeading: BookSectionHeading? {
        headings.last { $0.blockIndex <= currentBlock }
    }

    private var bookmarkedSections: [BookSection] {
        sections.filter { bookmarkIDs.contains($0.id) }
    }

    private var minimumDepth: Int { sections.map(\.depth).min() ?? 0 }
    /// Whether any section is numbered, so the number column is kept.
    private var hasNumbers: Bool { sections.contains { !($0.number ?? "").isEmpty } }
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
                        .listRowSeparator(.hidden, edges: .top)
                    }
                    if query.isEmpty {
                        if !bookmarkedSections.isEmpty {
                            Section("Bookmarks") {
                                ForEach(bookmarkedSections) { bookmarkRow($0) }
                            }
                        }
                        // No "Contents" header: the sheet's title already says it.
                        Section {
                            ForEach(sections) { section in
                                sectionRow(section, snippet: nil)
                                if section.id == currentSectionID, !headings.isEmpty {
                                    if Self.isNumbered(section) {
                                        ForEach(headings, id: \.blockIndex) { headingRow($0) }
                                    } else {
                                        DisclosureGroup(isExpanded: $showsUnnumberedHeadings) {
                                            ForEach(headings, id: \.blockIndex) { headingRow($0) }
                                        } label: {
                                            Text(headings.count == 1 ? "Show its heading" : "Show its \(headings.count) headings")
                                                .font(.footnote.weight(.medium))
                                                .foregroundStyle(Color.primary.opacity(0.7))
                                        }
                                        .tint(Color.primary.opacity(0.7))
                                        .listRowSeparator(.hidden, edges: .top)
                                        .padding(.leading, 36)
                                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                                    }
                                }
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .listStyle(.plain)
                .onAppear {
                    let headingsShown = sections.first { $0.id == currentSectionID }.map(Self.isNumbered) ?? false
                    let target = (headingsShown ? currentHeading.map { "heading-\($0.blockIndex)" } : nil) ?? currentSectionID
                    guard let target else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            // An opaque bar in the sheet's own colour, so rows scrolled under
            // the title and search field are hidden rather than ghosting.
            .toolbarBackground(LampTheme.sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // At the top, under the title, so the field never floats over
            // the last chapters of the list.
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this book")
            .environment(\.defaultMinListRowHeight, 30)
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
                ForEach(headingMatches, id: \.blockIndex) { headingRow($0) }
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
            // The number in a column of its own, so titles align and a row
            // is one line tall rather than two.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if hasNumbers || isCurrent {
                    // Where the reader is: a small marker in the number's
                    // place, not a coloured band that reads as a selection.
                    Group {
                        if isCurrent {
                            Image(systemName: "book.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Reading")
                        } else {
                            Text(section.number ?? "")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(LampTheme.caption)
                        }
                    }
                    .frame(minWidth: 24, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.body.weight(isCurrent || section.sectionType == "part" ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
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
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Spacer(minLength: 0)
                if bookmarkIDs.contains(section.id) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Bookmarked")
                }
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(max(section.depth - minimumDepth, 0)) * 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(section.id)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    static func isNumbered(_ section: BookSection) -> Bool {
        !(section.number ?? "").isEmpty
    }

    /// Without the row ID the contents scrolls to: the section's own row has
    /// it.
    private func bookmarkRow(_ section: BookSection) -> some View {
        Button {
            onSelect(section.id, -1)
        } label: {
            Label {
                Text(section.title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headingRow(_ heading: BookSectionHeading) -> some View {
        let isCurrent = heading.blockIndex == currentHeading?.blockIndex
        // A heading within the open section: smaller, set in from a rule,
        // so it reads as part of the section above and not as a chapter.
        return Button {
            if let currentSectionID { onSelect(currentSectionID, heading.blockIndex) }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 2)
                Text(heading.title)
                    .font(.footnote.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : LampTheme.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 30)
            .padding(.leading, (hasNumbers ? 36 : 0) + CGFloat(max(heading.level - minimumLevel, 0)) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Tight and unruled, so a section's headings hang from it as one
        // block rather than standing as chapters of their own.
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
        .listRowSeparator(.hidden)
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
        HStack(spacing: 12) {
            BookCover(book: book, compact: true)
                .frame(width: 36, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.footnote)
                        .foregroundStyle(LampTheme.caption)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            Text("Details")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.7))
        }
        .padding(.vertical, 2)
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
    let styler: BookTextStyler
    let style: BookTextStyle
    let translationID: String
    let openReader: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: PreviewSheetState?
    @State private var strongs: BookStrongsDestination?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(styler.text(footnote.content.annotatedText))
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

// MARK: - Generated Cover

/// A cover for a book without a cover image, set as a printed cloth cover
/// is: its colours, a spine shadow, the title in serif and the author below.
/// At small sizes only the title's initial fits, so that is all it shows.
struct LampGeneratedCover: View {
    let id: String
    let title: String
    let author: String?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pair = LampArtPalette.pair(for: id)
            let isSmall = width < 90
            ZStack {
                LinearGradient(colors: [pair.top, pair.bottom], startPoint: .top, endPoint: .bottom)
                // The spine: a darker edge and a highlight beside it.
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.28), .black.opacity(0.0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(width * 0.07, 3))
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1)
                    Spacer(minLength: 0)
                }
                if isSmall {
                    Text(String(title.prefix(1)))
                        .font(.system(size: width * 0.46, weight: .semibold, design: .serif))
                        .foregroundStyle(Color(red: 0.98, green: 0.95, blue: 0.88))
                } else {
                    VStack(spacing: width * 0.05) {
                        Rectangle()
                            .fill(Color(red: 0.98, green: 0.92, blue: 0.78).opacity(0.7))
                            .frame(width: width * 0.22, height: 1)
                        Text(title)
                            .font(.system(size: width * 0.115, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(Color(red: 0.99, green: 0.96, blue: 0.89))
                        Rectangle()
                            .fill(Color(red: 0.98, green: 0.92, blue: 0.78).opacity(0.7))
                            .frame(width: width * 0.22, height: 1)
                        Spacer(minLength: 0)
                        if let author, !author.isEmpty {
                            Text(author.uppercased())
                                .font(.system(size: width * 0.062, weight: .medium, design: .serif))
                                .tracking(width * 0.008)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .foregroundStyle(Color(red: 0.98, green: 0.92, blue: 0.78).opacity(0.9))
                        }
                    }
                    .padding(.top, width * 0.2)
                    .padding(.bottom, width * 0.12)
                    .padding(.leading, width * 0.13)
                    .padding(.trailing, width * 0.09)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
