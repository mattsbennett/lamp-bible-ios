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
    var title: String { deck.title }

    var visibleSlides: [LampPresentationSlide] {
        deck.slides.filter { !$0.isHidden }
    }

    /// The writing this deck was made from, if it was made from one, under
    /// either of the format's names for the link, as core reads it.
    var linkedWritingID: String? { deck.writingID }

    /// Writing IDs are UUIDs, which one platform may spell in capitals and
    /// another not.
    func isLinked(toWriting writingID: String) -> Bool {
        linkedWritingID?.caseInsensitiveCompare(writingID) == .orderedSame
    }

    /// A deck published from a Mac with nothing behind it: made from a writing
    /// that has gone, or a starter nobody wrote in. A Mac keeps both until
    /// someone deletes them there. A deck kept on this device is the user's
    /// own, whatever it links to.
    func isLeftover(writingIDs: Set<String>) -> Bool {
        guard origin == .synced else { return false }
        if let linkedWritingID {
            return !writingIDs.contains(linkedWritingID.uppercased())
        }
        return deck.isUnwrittenStarter
    }
}

private extension LampPresentationDeck {
    /// Still what a new deck starts as. Slide Studio saves a deck the moment
    /// it makes one, so this is published whether or not anyone wrote in it.
    var isUnwrittenStarter: Bool {
        func words(_ deck: LampPresentationDeck) -> [[String]] {
            deck.slides.map { [$0.speakerNotes] + $0.blocks.map(\.text) }
        }
        let starter = LampPresentationDeck.starter()
        return title == starter.title && words(self) == words(starter)
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
    /// Where the large-file settings are kept, which the Settings screen
    /// and the deck list write as app storage.
    let defaults: UserDefaults

    init(documentsURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let root = documentsURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        syncedStore = LampPresentationDeckStore(rootURL: root)
        importedStore = LampPresentationDeckStore(
            rootURL: root.appendingPathComponent("Imported", isDirectory: true)
        )
    }

    /// The store a deck's images resolve against. A deck imported on this
    /// device arrived as a single file with no images beside it, so its image
    /// blocks resolve in the imported directory and simply find nothing there.
    func store(for entry: PresentationDeckEntry) -> LampPresentationDeckStore {
        entry.origin == .synced ? syncedStore : importedStore
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

    /// The decks to list, given the capitalised ID of every writing held here:
    /// all but the leftovers. Those stay stored, since this device can't remove
    /// a published deck and the next pull would bring it back.
    func listedEntries(writingIDs: Set<String>) -> [PresentationDeckEntry] {
        entries().filter { !$0.isLeftover(writingIDs: writingIDs) }
    }

    /// The decks made from one writing, so the writing can offer them.
    func entries(forWriting writingID: String) -> [PresentationDeckEntry] {
        entries().filter { $0.isLinked(toWriting: writingID) }
    }

    /// Every writing at least one deck was made from.
    func linkedWritingIDs() -> Set<String> {
        Set(entries().compactMap { $0.linkedWritingID?.uppercased() })
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

    /// Mirrors an image or video published alongside the decks, written
    /// newest-wins like the decks themselves.
    func mergeSyncedAsset(_ asset: LampPresentationAssetRevision) throws {
        try LampPresentationAssetFiles.merge([asset], into: syncedStore.assetsDirectoryURL)
    }

    /// Removes the mirrored images and videos no synced deck wants here:
    /// those none references, and videos and clips this device wasn't asked
    /// to download. They carry no deletion ledger, so reachability is what
    /// keeps this directory from growing forever — and because decks and
    /// their images arrive in the same pull, an image is only unreferenced
    /// once no deck wants it.
    func pruneSyncedAssets() throws {
        let fileManager = FileManager.default
        // Nothing to prune, and no reason to read every deck to learn so.
        guard fileManager.fileExists(atPath: syncedStore.assetsDirectoryURL.path) else { return }
        // Every deck read before anything goes: a damaged deck is not
        // evidence that its files are unused, so a failed read keeps them.
        var decks: [LampPresentationDeck] = []
        if fileManager.fileExists(atPath: syncedStore.decksDirectoryURL.path) {
            let files = try fileManager.contentsOfDirectory(
                at: syncedStore.decksDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == LampPresentationDeckPortableLayout.deckExtension }
            for file in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                decks.append(try LampPresentationDeckStore.decode(Data(contentsOf: file)))
            }
        }
        try LampPresentationAssetFiles.prune(
            in: syncedStore.assetsDirectoryURL, referencedNames: wantedSyncedAssets(of: decks)
        )
    }

    /// How many files the synced decks' asset folder holds.
    func syncedAssetCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: syncedStore.assetsDirectoryURL.path).count) ?? 0
    }

    // MARK: - Large files

    /// Whether every synced deck's videos and clips come down to this device.
    /// Off by default: they can run to hundreds of megabytes, and a slide
    /// without its video shows the picture's still.
    static let downloadsLargeFilesKey = "presentations.downloadsLargeFiles"
    /// The decks whose videos and clips come down although the setting above
    /// is off.
    static let decksDownloadingLargeKey = "presentations.decksDownloadingLarge"

    var downloadsLargeFiles: Bool {
        defaults.bool(forKey: Self.downloadsLargeFilesKey)
    }

    var decksDownloadingLarge: Set<String> {
        Set(defaults.stringArray(forKey: Self.decksDownloadingLargeKey) ?? [])
    }

    /// Whether `deckID`'s videos and clips come down, by the setting or the deck.
    func downloadsLargeFiles(forDeck deckID: String) -> Bool {
        downloadsLargeFiles || decksDownloadingLarge.contains(deckID)
    }

    func setDownloadsLargeFiles(_ downloads: Bool, forDeck deckID: String) {
        var ids = decksDownloadingLarge
        if downloads { ids.insert(deckID) } else { ids.remove(deckID) }
        defaults.set(ids.sorted(), forKey: Self.decksDownloadingLargeKey)
    }

    /// The asset files this device holds for `decks`.
    func wantedSyncedAssets(of decks: [LampPresentationDeck]) -> Set<String> {
        LampPresentationLargeAssets.wanted(
            decks: decks,
            downloadsLarge: downloadsLargeFiles,
            decksDownloadingLarge: decksDownloadingLarge
        )
    }

    /// The videos and clips `deck` names that this device holds, with their
    /// sizes; a deck opened from a file keeps its own and lists none.
    func heldLargeFiles(of entry: PresentationDeckEntry) -> [(name: String, bytes: Int64)] {
        guard entry.origin == .synced else { return [] }
        return LampPresentationLargeAssets.held(by: entry.deck, in: syncedStore.assetsDirectoryURL)
    }

    /// Stops downloading `deckID`'s videos and clips and deletes this
    /// device's copies, short of those another deck still wants. Nothing
    /// synced is touched: the next device to want them still finds them.
    func removeDownloadedLargeFiles(forDeck deckID: String) throws {
        setDownloadsLargeFiles(false, forDeck: deckID)
        try PresentationDeckSync.pruneAfterDownloadChange(self)
        Task { @MainActor in
            NotificationCenter.default.post(name: .presentationDecksDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted after a sync pull or an import changes the deck library.
    static let presentationDecksDidChange = Notification.Name("presentationDecksDidChange")
    /// Posted after sync writes writings into the library, whatever ran it.
    static let writingsDidChange = Notification.Name("writingsDidChange")
    /// Posted after sync changes a writing's review marks.
    static let writingReviewsDidChange = Notification.Name("writingReviewsDidChange")
    /// Posted after sync changes a writing's documents, its outline or notes.
    static let writingDocumentsDidChange = Notification.Name("writingDocumentsDidChange")
}
