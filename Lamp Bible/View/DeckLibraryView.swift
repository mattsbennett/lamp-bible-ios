import LampCore
import LampPresentationUI
import SwiftUI
import UniformTypeIdentifiers

/// The decks this device can show.
///
/// Decks are authored in Slide Studio on a Mac; this is a reader. Sync mirrors
/// published decks onto the device, and a `.lampdeck` opened from Files, Mail,
/// or AirDrop is kept alongside them.
struct DeckLibraryView: View {
    /// Shown over what opened it, with its own way to close; otherwise pushed
    /// from the home screen's bar, whose stack gives it a back button.
    var inSheet = true

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [PresentationDeckEntry] = []
    /// The same decks as core lists them for the Mac's Presentations section,
    /// so a search, filter and sort leave the same decks on both.
    @State private var shelf = LampPresentationShelf(decks: [])
    @State private var query = ""
    @State private var filter: LampPresentationShelf.Filter = .all
    @AppStorage("deckLibrary.sort") private var sort: LampPresentationShelf.Sort = .recent
    @State private var loadGeneration = 0
    @State private var isImporting = false
    @State private var showingRemote = false
    @State private var importError: String?
    @State private var pendingDeckID: String?
    /// The slide to open the deck at, from its outline.
    @State private var pendingSlideIndex = 0
    /// Each synced deck's videos and clips, by deck, read with the list.
    @State private var largeFiles: [String: DeckLargeFiles] = [:]
    @AppStorage(PresentationDeckStorage.downloadsLargeFilesKey) private var downloadsAllLargeFiles = false

    static let deckContentType: UTType = UTType("com.neus.lamp-bible.presentation-deck")
        ?? UTType(filenameExtension: "lampdeck", conformingTo: .json)
        ?? .json

    var body: some View {
        if inSheet {
            NavigationStack { library }
        } else {
            library
        }
    }

    private var library: some View {
        Group {
            if entries.isEmpty {
                // Pulled, as the list is, to fetch the first deck.
                emptyState
                    .scrollableForPull()
                    .refreshableBySync { await reload() }
            } else {
                deckList
                    .searchable(
                        text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Decks and writings"
                    )
            }
        }
        .navigationTitle("Slide Decks")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            // The remote for a Mac presenting, with the decks it presents,
            // whether or not this device holds the one shown.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingRemote = true
                } label: {
                    // A remote, not a play key: beside the decks' own play
                    // buttons, a play glyph read as "play this deck".
                    Image(systemName: "av.remote")
                }
                .accessibilityLabel("Presentation Remote")
            }
            if entries.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(LampPresentationShelf.Sort.allCases) { sort in
                                Text(sort.rawValue).tag(sort)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityValue(sort.rawValue)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // An icon like its neighbours: a word among icons read as the
                // remote's label. The footer's button still says it in words.
                Button("Import Deck", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .labelStyle(.iconOnly)
            }
        }
        .background(LampTheme.groupedBackground.ignoresSafeArea())
        // Full screen: the remote is the one thing in use while presenting.
        .fullScreenCover(isPresented: $showingRemote) {
            PresentationRemoteView()
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .presentationDecksDidChange)) { _ in
            Task { await reload() }
        }
        // A writing renamed or deleted on another device, which the cards
        // show; a pass already running when the list was pulled ends here.
        .onReceive(NotificationCenter.default.publisher(for: .libraryModulesDidChange)) { notification in
            guard LibraryModulesChange.types(in: notification).contains(.devotional) else { return }
            Task { await reload() }
        }
        // A sync can rename a writing without touching any deck, and the
        // cards show and search their writings' titles.
        .onReceive(SyncCoordinator.shared.$syncState.dropFirst()) { state in
            if case .idle = state { Task { await reload() } }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [Self.deckContentType]
        ) { result in
            handleImport(result)
        }
        .alert(
            "Deck Unavailable",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - List

    /// Each deck as its title slide, large enough to recognise, the way a
    /// presentation app shows its documents; a deck's other slides follow in
    /// a strip, so the card says what is inside before it is opened.
    private var deckList: some View {
        let entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = shelf.shown(filter: filter, sort: sort, query: query)
            .compactMap { deck in entriesByID[deck.id].map { (deck: deck, entry: $0) } }
        return List {
            filterChips
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if shown.isEmpty {
                noMatches
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(shown, id: \.entry.id) { deck, entry in
                Button {
                    pendingSlideIndex = 0
                    pendingDeckID = entry.id
                } label: {
                    DeckLibraryCard(
                        entry: entry,
                        listed: deck,
                        videosLeftOnServer: largeFiles[entry.id]?.isMissing == true
                    )
                }
                .buttonStyle(DeckCardButtonStyle())
                .contextMenu {
                    // With every deck's downloading, there's nothing for one
                    // to ask.
                    if !downloadsAllLargeFiles, let files = largeFiles[entry.id] {
                        largeFilesMenu(entry, files)
                    }
                }
                .swipeActions(edge: .trailing) {
                    // Sync owns a published deck, so removing it here would
                    // only invite the next pull to bring it back.
                    if entry.origin == .imported {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            remove(entry)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                // A short library has room to say what is in a deck, in words
                // that can be read, and to open it at any of them.
                if shown.count <= 2, entry.visibleSlides.count > 1 {
                    DeckOutline(entry: entry) { index in
                        pendingSlideIndex = index
                        pendingDeckID = entry.id
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }

            libraryFooter
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Pulling asks the library for decks other devices changed. A pass
        // this starts reloads the list as it ends; read here only when one
        // was already running, none could run, or there's no sync.
        .refreshable {
            let sync = SyncCoordinator.shared
            guard sync.settings.backend != .none else { return await reload() }
            do { try await sync.syncAll() } catch { await reload() }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { pendingDeckID != nil },
                set: { if !$0 { pendingDeckID = nil } }
            )
        ) {
            if let entry = entries.first(where: { $0.id == pendingDeckID }) {
                DeckViewerView(entry: entry, startingAt: pendingSlideIndex)
            }
        }
    }

    /// All, From Writing and Standalone, each with how many decks it shows for
    /// the search as it stands, wrapping chip by chip at large text sizes.
    private var filterChips: some View {
        WrappingHStack(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(LampPresentationShelf.Filter.allCases) { option in
                DeckFilterChip(
                    title: option.rawValue,
                    count: shelf.count(of: option, query: query),
                    isSelected: filter == option
                ) {
                    filter = option
                }
            }
        }
    }

    /// Nothing the search or filter leaves, said in the list so the chips
    /// above stay to change it.
    @ViewBuilder
    private var noMatches: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        } else {
            ContentUnavailableView(
                filter == .fromWriting ? "No Decks from Writing" : "No Standalone Decks",
                systemImage: "rectangle.on.rectangle",
                description: Text(
                    filter == .fromWriting
                        ? "Decks built from a writing in Slide Studio appear here."
                        : "Decks not built from a writing appear here."
                )
            )
        }
    }

    /// Where decks come from, under the list as well as in the empty state:
    /// this is a reader, and the way to add to it is not otherwise visible.
    private var libraryFooter: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "macbook.and.iphone")
                .font(.body)
                .foregroundStyle(LampTheme.caption)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 10) {
                Text("Decks from Slide Studio on your Mac appear here after sync, or open a .lampdeck file.")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                // A quiet button: the accent is the play key's.
                Button {
                    isImporting = true
                } label: {
                    Label("Import a Deck…", systemImage: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .label))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(LampTheme.tileFill, in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Slide Decks", systemImage: "rectangle.on.rectangle")
        } description: {
            Text(
                """
                Decks built in Slide Studio on a Mac appear here once sync runs. \
                You can also open a .lampdeck file from Files, Mail, or AirDrop.
                """
            )
        } actions: {
            Button("Import Deck", systemImage: "square.and.arrow.down") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// A deck's videos and clips: download them for this deck, or delete
    /// this device's copies.
    @ViewBuilder
    private func largeFilesMenu(_ entry: PresentationDeckEntry, _ files: DeckLargeFiles) -> some View {
        Toggle("Download Videos", systemImage: "arrow.down.circle", isOn: Binding(
            get: { files.isDownloading },
            set: { downloads in
                PresentationDeckStorage.shared.setDownloadsLargeFiles(downloads, forDeck: entry.id)
                largeFiles[entry.id]?.isDownloading = downloads
                // Fetched by the next pull: one now, or after the one running.
                if downloads { SyncCoordinator.shared.syncAfterChange() }
            }
        ))
        if files.heldBytes > 0 {
            Button(role: .destructive) {
                let onICloud = SyncCoordinator.shared.settings.backend == .icloudDrive
                // Off the main actor: the prune reads every deck.
                Task {
                    let failure = await Task.detached(priority: .userInitiated) {
                        do {
                            try PresentationDeckStorage.shared.removeDownloadedLargeFiles(forDeck: entry.id)
                            if onICloud, let icloud = ICloudModuleStorage.shared.libraryEndpoint() {
                                PresentationDeckSync.evictUnwantedICloudCopies(root: icloud.store.root)
                            }
                            return nil as String?
                        } catch {
                            return error.localizedDescription
                        }
                    }.value
                    if let failure { importError = failure }
                }
            } label: {
                Label(
                    "Remove Downloaded Videos (\(files.heldBytes.formatted(.byteCount(style: .file))))",
                    systemImage: "trash"
                )
            }
        }
    }

    // MARK: - Actions

    /// Reads and decodes every deck file, so off the main actor, as the
    /// writing views already read the decks. A read that a later one
    /// overtakes drops its result, so a removed deck can't come back.
    private func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let (loaded, listed, large) = await Task.detached(priority: .userInitiated) {
            let decks = PresentationDeckStorage.shared
            let titles = try? DevotionalStorage.shared.getAllWritingTitles()
            // Unable to read the writings, list every deck rather than hide one.
            let entries = titles.map { decks.listedEntries(writingIDs: Set($0.keys)) } ?? decks.entries()
            // Dated by the file date the listing already read.
            let shelf = LampPresentationShelf(decks: entries.map { entry in
                LampPresentationShelf.Deck(entry.deck, modified: entry.modifiedAt ?? .distantPast) {
                    titles?[$0.uppercased()]
                }
            })
            // Which synced decks have videos or clips, whether they're asked
            // for, and how much of them is here, for the decks' menus.
            // Every stored synced deck, as the prune weighs them, shown or not.
            let synced = entries.filter { $0.origin == .synced }
            let stored = decks.revisions(in: decks.syncedStore).map(\.deck)
            let large = synced.reduce(into: [String: DeckLargeFiles]()) { large, entry in
                let names = LampPresentationLargeAssets.largeNames(in: [entry.deck])
                guard !names.isEmpty else { return }
                let held = decks.heldLargeFiles(of: entry)
                // What removing would free: not a file another deck keeps.
                let keptByOthers = decks.wantedSyncedAssets(of: stored.filter { $0.id != entry.id })
                large[entry.id] = DeckLargeFiles(
                    isDownloading: decks.decksDownloadingLarge.contains(entry.id),
                    heldBytes: held.filter { !keptByOthers.contains($0.name) }.reduce(0) { $0 + $1.bytes },
                    isMissing: held.count < names.count
                )
            }
            return (entries, shelf, large)
        }.value
        guard generation == loadGeneration else { return }
        entries = loaded
        shelf = listed
        largeFiles = large
        if let pendingDeckID, !entries.contains(where: { $0.id == pendingDeckID }) {
            self.pendingDeckID = nil
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try PresentationDeckStorage.shared.importDeck(from: url)
                Task { await reload() }
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func remove(_ entry: PresentationDeckEntry) {
        do {
            try PresentationDeckStorage.shared.removeImportedDeck(id: entry.id)
            Task { await reload() }
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// A synced deck's videos and clips on this device.
private struct DeckLargeFiles {
    /// Asked for for this deck alone.
    var isDownloading: Bool
    /// What this device holds of them that no other deck keeps.
    var heldBytes: Int64
    /// Some aren't here, whether or not they've been asked for.
    var isMissing: Bool
}

/// A card's press: it settles a little under the finger.
private struct DeckCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A filter, and how many decks it shows. Chosen, it is filled and outlined
/// in the accent strongly enough to read in dark, as the Mac's are.
private struct DeckFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color(uiColor: .label) : LampTheme.caption)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(Color(uiColor: .label))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Unchosen, a card on the page's ground, as the deck cards are:
            // the tile fill all but vanished against it.
            .background(
                isSelected ? Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.16) : LampTheme.card,
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.85) : LampTheme.hairline)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(count == 1 ? "1 deck" : "\(count) decks")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DeckLibraryCard: View {
    let entry: PresentationDeckEntry
    let listed: LampPresentationShelf.Deck
    /// Some of its videos and clips aren't on this device, so those slides
    /// show their pictures instead.
    var videosLeftOnServer = false

    var body: some View {
        let slides = entry.visibleSlides
        let store = PresentationDeckStorage.shared.store(for: entry)
        VStack(alignment: .leading, spacing: 0) {
            if let first = slides.first {
                // Framed inside the card rather than bled to its edges, and
                // never dimmed in dark: a dimmed cover reads as washed out.
                LampPresentationSlideCanvas(slide: first, deck: entry.deck, store: store, compact: true)
                    .aspectRatio(entry.deck.aspectRatio.ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous)
                            .strokeBorder(LampTheme.hairline)
                    }
                    .padding([.horizontal, .top], 10)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.deck.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        // The writing it was built from, under its title.
                        if let writingTitle = listed.writingTitle {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "pencil.line")
                                    .font(.footnote)
                                    .accessibilityHidden(true)
                                Text(writingTitle)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .font(.subheadline)
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                        }
                        // One line of words, so it wraps rather than clips.
                        Text(detailLine)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LampTheme.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .accessibilityHidden(true)
                }

            }
            .padding(16)
        }
        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LampTheme.Radius.panel, style: .continuous)
                .strokeBorder(LampTheme.rule.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the deck")
    }

    /// Its slides, when its file last changed, and whether it was opened here.
    private var detailLine: String {
        let count = entry.visibleSlides.count
        var parts = [count == 1 ? "1 slide" : "\(count) slides"]
        if listed.modified != .distantPast {
            parts.append(listed.modified.formatted(.relative(presentation: .named)))
        }
        if entry.origin == .imported {
            parts.append("On this device")
        }
        if videosLeftOnServer {
            parts.append("Videos not downloaded")
        }
        return parts.joined(separator: " · ")
    }
}

/// The slides after the title slide (which the card above already shows), by
/// title, numbered, each opening the deck there, and how many more follow.
private struct DeckOutline: View {
    let entry: PresentationDeckEntry
    let open: (Int) -> Void

    private static let shown = 5

    var body: some View {
        let slides = entry.visibleSlides
        VStack(alignment: .leading, spacing: 0) {
            Text("In This Deck")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            let listed = Array(slides.enumerated().dropFirst().prefix(Self.shown))
            ForEach(listed, id: \.offset) { index, slide in
                Button {
                    open(index)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(LampTheme.caption)
                            .frame(width: 22, alignment: .trailing)
                        Text(slide.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(Color(uiColor: .label))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LampTheme.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Slide \(index + 1), \(slide.displayTitle)")
                .accessibilityHint("Opens the deck at this slide")
                if index != listed.last?.offset {
                    Divider().padding(.leading, 50)
                }
            }
            if slides.count > Self.shown + 1 {
                Text("and \(slides.count - Self.shown - 1) more")
                    .font(.footnote)
                    .foregroundStyle(LampTheme.caption)
                    .padding(.leading, 50)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
    }
}
