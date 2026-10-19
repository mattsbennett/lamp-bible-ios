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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import Deck")
                }
            }
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

    private var deckList: some View {
        List {
            ForEach(entries) { entry in
                Button {
                    pendingDeckID = entry.id
                } label: {
                    DeckLibraryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    // Sync owns a published deck, so removing it here would
                    // only invite the next pull to bring it back.
                    if entry.origin == .imported {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            remove(entry)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .fullScreenCover(
            isPresented: Binding(
                get: { pendingDeckID != nil },
                set: { if !$0 { pendingDeckID = nil } }
            )
        ) {
            if let entry = entries.first(where: { $0.id == pendingDeckID }) {
                DeckViewerView(entry: entry)
            }
        }
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
        entries = PresentationDeckStorage.shared.entries()
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

private struct DeckLibraryRow: View {
    let entry: PresentationDeckEntry

    var body: some View {
        HStack(spacing: 14) {
            if let slide = entry.visibleSlides.first {
                LampPresentationSlideCanvas(
                    slide: slide,
                    deck: entry.deck,
                    store: PresentationDeckStorage.shared.store(for: entry),
                    compact: true
                )
                    .aspectRatio(entry.deck.aspectRatio.ratio, contentMode: .fit)
                    .frame(width: 86)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.deck.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(slideCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.origin == .imported {
                    Text("On this device")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var slideCountLabel: String {
        let count = entry.visibleSlides.count
        return count == 1 ? "1 slide" : "\(count) slides"
    }
}
