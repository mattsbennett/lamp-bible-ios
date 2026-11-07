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
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [PresentationDeckEntry] = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var pendingDeckID: String?
    /// The slide to open the deck at, from its outline.
    @State private var pendingSlideIndex = 0

    static let deckContentType: UTType = UTType("com.neus.lamp-bible.presentation-deck")
        ?? UTType(filenameExtension: "lampdeck", conformingTo: .json)
        ?? .json

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else {
                    deckList
                }
            }
            .navigationTitle("Slide Decks")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Labelled: an icon alone didn't say what it brought in.
                    Button("Import") {
                        isImporting = true
                    }
                    .accessibilityLabel("Import Deck")
                }
            }
            .background(LampTheme.groupedBackground.ignoresSafeArea())
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .presentationDecksDidChange)) { _ in
            reload()
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
        List {
            ForEach(entries) { entry in
                Button {
                    pendingSlideIndex = 0
                    pendingDeckID = entry.id
                } label: {
                    DeckLibraryCard(entry: entry)
                }
                .buttonStyle(DeckCardButtonStyle())
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
                if entries.count <= 2, entry.visibleSlides.count > 1 {
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

    // MARK: - Actions

    private func reload() {
        let decks = PresentationDeckStorage.shared
        // Unable to read the writings, list every deck rather than hide one.
        entries = (try? DevotionalStorage.shared.getAllWritingIDs())
            .map(decks.listedEntries(writingIDs:)) ?? decks.entries()
        if let pendingDeckID, !entries.contains(where: { $0.id == pendingDeckID }) {
            self.pendingDeckID = nil
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                try PresentationDeckStorage.shared.importDeck(from: url)
                reload()
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
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// A card's press: it settles a little under the finger.
private struct DeckCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct DeckLibraryCard: View {
    let entry: PresentationDeckEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let slides = entry.visibleSlides
        let store = PresentationDeckStorage.shared.store(for: entry)
        VStack(alignment: .leading, spacing: 0) {
            if let first = slides.first {
                // Framed inside the card rather than bled to its edges, and
                // taken down a little in dark, where a light slide glares.
                LampPresentationSlideCanvas(slide: first, deck: entry.deck, store: store, compact: true)
                    .aspectRatio(entry.deck.aspectRatio.ratio, contentMode: .fit)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.16 : 0))
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
                        HStack(spacing: 6) {
                            Text(slideCountLabel)
                            if entry.origin == .imported {
                                Text("·")
                                Text("On this device")
                            }
                        }
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

    private var slideCountLabel: String {
        let count = entry.visibleSlides.count
        return count == 1 ? "1 slide" : "\(count) slides"
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
