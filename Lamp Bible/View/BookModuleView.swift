import SwiftUI
import UniformTypeIdentifiers
import LampModuleKit

struct BookLibraryView: View {
    @State private var books: [BookLibraryItem] = []
    @State private var selectedBook: BookLibraryItem?
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var showingDuplicateAlert = false
    @State private var duplicateBookName = ""
    @State private var pendingImportURL: URL?
    @State private var pendingImportHasSecurityScope = false

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
                List(filteredBooks) { item in
                    Button {
                        selectedBook = item
                    } label: {
                        BookLibraryRow(item: item)
                    }
                    .buttonStyle(.plain)
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
        .sheet(item: $selectedBook) { item in
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
                    if BookReadingProgressStore().sectionID(for: item.id) != nil {
                        Label("Continue reading", systemImage: "bookmark.fill")
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

/// Reader for bundled and user-installed long-form book modules.
struct BookModuleView: View {
    let moduleId: String
    var initialSectionId: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var book: BookModule?
    @State private var sections: [BookSection] = []
    @State private var selectedSectionId: String?
    @State private var loadError: String?
    @State private var showingContents = false
    @State private var showingDetails = false
    @State private var selectedStrongs: BookStrongsDestination?
    @State private var selectedFootnote: BookFootnote?
    @State private var navigationPath = NavigationPath()
    @State private var readerDate = Date()

    private var selectedSection: BookSection? {
        sections.first { $0.id == selectedSectionId }
    }

    private var selectedIndex: Int? {
        sections.firstIndex { $0.id == selectedSectionId }
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
                } else if let book, let section = selectedSection {
                    ScrollView {
                        BookSectionContentView(
                            book: book,
                            section: section,
                            openReference: openReference
                        )
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 28)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity)

                        sectionNavigationFooter
                            .frame(maxWidth: 760)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 28)
                    }
                    .id(section.id)
                    .environment(\.layoutDirection, book.textDirection == "rtl" ? .rightToLeft : .leftToRight)
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
            BookContentsView(
                bookTitle: book?.title ?? "Contents",
                sections: sections,
                selectedSectionID: selectedSectionId
            ) { sectionID in
                selectedSectionId = sectionID
                showingContents = false
            }
        }
        .sheet(isPresented: $showingDetails) {
            if let book { BookDetailsView(book: book) }
        }
        .sheet(item: $selectedStrongs) { destination in
            LexiconSheetView(
                word: destination.key,
                strongs: [destination.key],
                morphology: nil,
                translationId: UserDatabase.shared.getSettings().readerTranslationId
            )
        }
        .sheet(item: $selectedFootnote) { footnote in
            BookFootnoteView(footnote: footnote)
        }
        .task(id: moduleId) { loadBook() }
        .onChange(of: selectedSectionId) { _, sectionID in
            guard let sectionID else { return }
            BookReadingProgressStore().save(sectionID: sectionID, for: moduleId)
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.host == "book-footnote",
               let footnoteID = url.lastPathComponent.removingPercentEncoding,
               let footnote = book?.footnotes.first(where: { $0.id == footnoteID }) {
                selectedFootnote = footnote
                return .handled
            }
            guard let parsed = LampbibleURL.parse(url) else { return .systemAction }
            switch parsed {
            case .verse(let reference, _, let translationID):
                openReference(reference, translationID: translationID)
            case .reading(let reference, _, _):
                openReference(reference)
            case .strongs(let key):
                selectedStrongs = BookStrongsDestination(key: key)
            case .external:
                return .systemAction
            }
            return .handled
        })
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Book Details", systemImage: "info.circle") { showingDetails = true }
                .labelStyle(.iconOnly)
            Button("Contents", systemImage: "list.bullet.indent") { showingContents = true }
                .labelStyle(.iconOnly)
        }
    }

    private var sectionNavigationFooter: some View {
        HStack(spacing: 12) {
            Button {
                moveSection(by: -1)
            } label: {
                Label(previousSection?.title ?? "Previous", systemImage: "chevron.left")
                    .lineLimit(1)
            }
            .disabled(previousSection == nil)

            Spacer()
            if let selectedIndex {
                Text("\(selectedIndex + 1) of \(sections.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                moveSection(by: 1)
            } label: {
                Label(nextSection?.title ?? "Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .disabled(nextSection == nil)
        }
        .buttonStyle(.bordered)
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

    private func moveSection(by offset: Int) {
        guard let selectedIndex else { return }
        let destination = selectedIndex + offset
        guard sections.indices.contains(destination) else { return }
        selectedSectionId = sections[destination].id
    }

    private func openReference(_ reference: Int, translationID: String? = nil) {
        navigationPath.append(BookScriptureDestination(
            reference: reference,
            translationID: translationID
        ))
    }

    private func loadBook() {
        do {
            if let userBook = try ModuleDatabase.shared.getBookModule(id: moduleId) {
                book = userBook
                sections = try ModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else if let bundledBook = try BundledModuleDatabase.shared.getBookModule(id: moduleId) {
                book = bundledBook
                sections = try BundledModuleDatabase.shared.getBookSections(moduleId: moduleId)
            } else {
                loadError = "The book module is no longer available."
                return
            }

            let rememberedSectionID = BookReadingProgressStore().sectionID(for: moduleId)
            selectedSectionId = [initialSectionId, rememberedSectionID]
                .compactMap { $0 }
                .first { candidate in sections.contains { $0.id == candidate } }
                ?? sections.first?.id
            if sections.isEmpty {
                loadError = "This book does not contain any sections."
            } else {
                loadError = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
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

private struct BookContentsView: View {
    let bookTitle: String
    let sections: [BookSection]
    let selectedSectionID: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var matchingSections: [BookSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return sections.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle?.localizedCaseInsensitiveContains(query) == true
                || $0.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    OutlineGroup(BookSectionHierarchy.roots(from: sections), children: \.children) { node in
                        sectionButton(node.section)
                    }
                } else if matchingSections.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(matchingSections) { section in sectionButton(section) }
                }
            }
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search this book")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sectionButton(_ section: BookSection) -> some View {
        Button {
            onSelect(section.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: section.sectionType))
                    .foregroundStyle(section.id == selectedSectionID ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .foregroundStyle(.primary)
                    if let subtitle = section.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if section.id == selectedSectionID {
                    Image(systemName: "bookmark.fill").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for sectionType: String) -> String {
        switch sectionType {
        case "part": "folder"
        case "chapter": "doc.text"
        case "appendix": "paperclip"
        case "front-matter", "back-matter": "doc.plaintext"
        default: "text.alignleft"
        }
    }
}

private struct BookDetailsView: View {
    let book: BookModule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Book Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}

private struct BookSectionContentView: View {
    let book: BookModule
    let section: BookSection
    let openReference: (Int, String?) -> Void

    private var mediaByID: [String: MediaReference] {
        Dictionary(book.mediaReferences.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                if let number = section.number, !number.isEmpty {
                    Text(number.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(section.title).font(.largeTitle.bold())
                if let subtitle = section.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
            }

            if !section.keyScriptures.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(section.keyScriptures, id: \.self) { reference in
                            Button {
                                openReference(reference.sv, nil)
                            } label: {
                                Label(
                                    reference.label ?? formatReference(reference),
                                    systemImage: "book.pages"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            ForEach(Array(section.contentBlocks.enumerated()), id: \.offset) { _, block in
                BookContentBlockView(
                    block: block,
                    moduleId: book.id,
                    mediaByID: mediaByID
                )
            }
        }
        .textSelection(.enabled)
    }

    private func formatReference(_ range: BookScriptureRange) -> String {
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

private struct BookContentBlockView: View {
    let block: BookContentBlock
    let moduleId: String
    let mediaByID: [String: MediaReference]

    @ViewBuilder
    var body: some View {
        switch block.type {
        case "heading":
            BookAnnotatedTextView(value: block.content)
                .font(headingFont)
                .fontWeight(.semibold)
                .padding(.top, 6)
        case "blockquote":
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(.secondary.opacity(0.45)).frame(width: 3)
                BookAnnotatedTextView(value: block.content)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        case "list":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    BookListItemView(
                        item: item,
                        marker: block.listType == "numbered" ? "\(index + 1)." : "•"
                    )
                }
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.cells.sorted { $0.column < $1.column }.enumerated()), id: \.offset) { _, cell in
                                BookAnnotatedTextView(value: cell.content)
                                    .fontWeight(cell.isHeader ? .semibold : .regular)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.secondary.opacity(cell.isHeader ? 0.12 : 0.05))
                                    .gridCellColumns(cell.columnSpan)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case "thematic-break":
            Divider().padding(.vertical, 8)
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
            BookAnnotatedTextView(value: block.content)
                .font(.body)
                .lineSpacing(5)
        }
    }

    private var headingFont: Font {
        switch block.level ?? 2 {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

private struct BookAnnotatedTextView: View {
    let value: BookAnnotatedText?

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        guard let value else { return AttributedString() }
        var result = AttributedString(value.text)
        for annotation in value.annotations {
            guard annotation.start >= 0,
                  annotation.end > annotation.start,
                  annotation.end <= value.text.count else { continue }
            let stringStart = value.text.index(value.text.startIndex, offsetBy: annotation.start)
            let stringEnd = value.text.index(value.text.startIndex, offsetBy: annotation.end)
            guard let start = AttributedString.Index(stringStart, within: result),
                  let end = AttributedString.Index(stringEnd, within: result) else { continue }
            let range = start..<end

            switch annotation.type {
            case "scripture":
                if let reference = annotation.data?.startReference
                    ?? annotation.data?.references.first?.startReference {
                    let end = annotation.data?.endReference
                        ?? annotation.data?.references.first?.endReference
                    let endReference = end.map { "/\($0)" } ?? ""
                    result[range].link = URL(string: "lampbible://verse/\(reference)\(endReference)")
                    result[range].underlineStyle = .single
                }
            case "strongs", "greek", "hebrew":
                if let key = annotation.data?.strongs,
                   let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    result[range].link = URL(string: "lampbible://strongs/\(encodedKey)")
                    result[range].underlineStyle = .single
                }
            case "link":
                if let url = annotation.data?.url.flatMap(URL.init(string:)) {
                    result[range].link = url
                    result[range].underlineStyle = .single
                }
            case "emphasis":
                switch annotation.data?.style {
                case "bold": result[range].font = .body.bold()
                case "italic": result[range].font = .body.italic()
                case "underline": result[range].underlineStyle = .single
                default: break
                }
            case "quote":
                result[range].font = .body.italic()
            case "footnote":
                if let footnoteID = annotation.data?.footnoteID,
                   let url = bookFootnoteURL(id: footnoteID) {
                    result[range].link = url
                    result[range].underlineStyle = .single
                }
            default:
                break
            }
        }
        let linkedFootnotes = Set(value.annotations.compactMap { annotation in
            annotation.type == "footnote" ? annotation.data?.footnoteID : nil
        })
        for (index, reference) in value.footnoteReferences.enumerated()
            where !linkedFootnotes.contains(reference.id) {
            guard let url = bookFootnoteURL(id: reference.id) else { continue }
            var marker = AttributedString(" [\(index + 1)]")
            marker.link = url
            marker.font = .caption
            result.append(marker)
        }
        return result
    }

    private func bookFootnoteURL(id: String) -> URL? {
        guard let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "lampbible://book-footnote/\(encodedID)")
    }
}

private struct BookFootnoteView: View {
    let footnote: BookFootnote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    switch footnote.content {
                    case .plain(let text): Text(text)
                    case .annotated(let text): BookAnnotatedTextView(value: text)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(24)
            }
            .navigationTitle("Footnote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

private struct BookListItemView: View {
    let item: BookListItem
    let marker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).frame(minWidth: 20, alignment: .trailing)
                BookAnnotatedTextView(value: item.content).lineSpacing(4)
            }
            ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                BookListItemView(item: child, marker: "•")
                    .padding(.leading, 24)
            }
        }
    }
}
