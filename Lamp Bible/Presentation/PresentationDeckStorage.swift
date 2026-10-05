import Foundation
import LampCore

/// Where a deck on this device came from.
///
/// Synced decks are a mirror of what a Mac published: sync owns them, so the
/// viewer never offers to delete one — the next pull would simply bring it
/// back. Imported decks were opened on this device and are the user's to
/// remove.
enum PresentationDeckOrigin: String, Sendable {
    case synced
    case imported
}

struct PresentationDeckEntry: Identifiable, Sendable {
    let deck: LampPresentationDeck
    let origin: PresentationDeckOrigin
    let modifiedAt: Date?

    var id: String { deck.id }

    var visibleSlides: [LampPresentationSlide] {
        deck.slides.filter { !$0.isHidden }
    }
}

/// The device's deck files, kept in two directories so sync and the user never
/// fight over the same copy.
///
/// Nothing here publishes. iOS shows decks authored on a Mac and decks the user
/// opened locally; authoring a deck on a phone would make iOS a writer, which
/// would oblige it to carry deck merge and deletion records of its own.
struct PresentationDeckStorage: Sendable {
    static let shared = PresentationDeckStorage()

    /// `Documents/Presentations` — replaced by sync.
    let syncedStore: LampPresentationDeckStore
    /// `Documents/Imported/Presentations` — opened on this device.
    let importedStore: LampPresentationDeckStore

    init(documentsURL: URL? = nil) {
        let root = documentsURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        syncedStore = LampPresentationDeckStore(rootURL: root)
        importedStore = LampPresentationDeckStore(
            rootURL: root.appendingPathComponent("Imported", isDirectory: true)
        )
    }

    // MARK: - Reading

    /// Every deck this device can show, newest-looking name order, with a
    /// synced copy winning over an imported one of the same deck.
    func entries() -> [PresentationDeckEntry] {
        var byID: [String: PresentationDeckEntry] = [:]
        for revision in revisions(in: importedStore) {
            byID[revision.id] = PresentationDeckEntry(
                deck: revision.deck,
                origin: .imported,
                modifiedAt: revision.modifiedAt
            )
        }
        for revision in revisions(in: syncedStore) {
            byID[revision.id] = PresentationDeckEntry(
                deck: revision.deck,
                origin: .synced,
                modifiedAt: revision.modifiedAt
            )
        }
        return byID.values.sorted {
            $0.deck.title.localizedStandardCompare($1.deck.title) == .orderedAscending
        }
    }

    /// Stored copies with the bytes and dates a merge decision needs. A deck
    /// this build cannot validate is skipped rather than failing the listing.
    func revisions(in store: LampPresentationDeckStore) -> [LampPresentationDeckRevision] {
        let fileManager = FileManager.default
        let directory = store.decksDirectoryURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { url in
            guard url.pathExtension.lowercased()
                    == LampPresentationDeckPortableLayout.deckExtension,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url),
                  let deck = try? LampPresentationDeckStore.decode(data)
            else { return nil }
            let modified = try? url
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return LampPresentationDeckRevision(
                deck: deck,
                data: data,
                modifiedAt: modified ?? .distantPast
            )
        }
    }

    // MARK: - Import

    /// Validates a `.lampdeck` document and keeps it on this device.
    ///
    /// The file may be outside the app's container — a Files pick, an AirDrop,
    /// a share sheet — so the read is security scoped.
    @discardableResult
    func importDeck(from url: URL) throws -> LampPresentationDeck {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let deck = try LampPresentationDeckStore.decode(data)
        try importedStore.save(deck)
        return deck
    }

    func removeImportedDeck(id: String) throws {
        try importedStore.delete(id: id)
    }

    // MARK: - Sync

    /// Writes what a pull decided, stamping each deck with the modification
    /// date it was published with so the next pull compares like with like.
    ///
    /// The published bytes are stored verbatim rather than re-encoded: when two
    /// copies share a modification time the merge decision falls back to
    /// comparing bytes, and re-encoding could make an identical deck look
    /// different.
    func applySyncPlan(_ plan: LampPresentationDeckPortablePull.Plan) throws {
        let fileManager = FileManager.default
        if !plan.decksToSave.isEmpty {
            try fileManager.createDirectory(
                at: syncedStore.decksDirectoryURL,
                withIntermediateDirectories: true
            )
        }
        for revision in plan.decksToSave {
            let url = syncedStore.deckFileURL(for: revision.id)
            try revision.data.write(to: url, options: [.atomic])
            try? fileManager.setAttributes(
                [.modificationDate: revision.modifiedAt],
                ofItemAtPath: url.path
            )
        }
        for id in plan.deckIDsToDelete {
            try syncedStore.delete(id: id)
        }
    }
}

extension Notification.Name {
    /// Posted after a sync pull or an import changes the deck library.
    static let presentationDecksDidChange = Notification.Name("presentationDecksDidChange")
}
