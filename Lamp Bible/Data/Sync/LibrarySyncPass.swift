//
//  LibrarySyncPass.swift
//  Lamp Bible
//
//  Design B's pass. Each module is its own file on the server, and those files
//  are the truth. A small settings bundle beside them carries the settings,
//  the preference and deletion ledgers, and the manifest saying which files
//  belong to the library. What a pass does with each file is decided in core
//  (`LampSyncFilePlan`), so this side only gathers what it holds and carries
//  the decisions out.
//

import CryptoKit
import Foundation
import GRDB
import LampCore
import LampModuleKit
import UIKit

/// Part of the settings bundle that something on this device keeps.
///
/// `change` runs inside the bundle's read-merge-write, once per attempt and
/// each time against a newer bundle, so it only computes. `committed` runs
/// once, with what was written, and is where local state changes.
@MainActor
protocol SettingsBundleParticipant {
    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws
    func committed(_ written: LampSyncSettingsStore.Snapshot) throws
}

/// A sync endpoint the library pass runs against: storage the importers
/// read modules from, and a remote store with conditional writes.
protocol LibraryEndpoint: ModuleStorage, LampSyncRemoteStore {
    /// Names the endpoint in this device's records: a revision or an upload
    /// recorded at one endpoint means nothing at another.
    var librarySource: String { get }
}

extension WebDAVModuleStorage: LibraryEndpoint {
    var librarySource: String { syncSourceIdentifier }
}

/// The library endpoint for a provider's storage, where it has one.
func libraryEndpoint(for storage: ModuleStorage?) -> (any LibraryEndpoint)? {
    switch storage {
    case let webDAV as WebDAVModuleStorage:
        return webDAV
    case let iCloud as ICloudModuleStorage:
        // Until the Mac migrates the folder, core reads it as not migrated
        // and iCloud Drive syncs as before.
        return iCloud.libraryEndpoint()
    default:
        return nil
    }
}

/// A pass's work that did not all get done. The rest was, and is recorded;
/// the next pass picks up what is left.
enum LibrarySyncError: LocalizedError, Equatable {
    case incomplete([String])
    /// A deletion of a whole collection, which this device never carries out.
    case collectionKept(String)
    /// A picture that arrived with nowhere here core lets it be kept, such
    /// as through a link: never recorded as taken, so it is tried again.
    case mediaNotKept(String)
    /// Another module here is called `writing`, the writing collection's name
    /// on the server since bundle format 4: so the collection cannot take
    /// it, or what arrives as the collection would be taken into that module.
    case writingCollectionNotRenamed

    var errorDescription: String? {
        switch self {
        case .incomplete(let failures):
            let first = failures.first ?? ""
            return failures.count > 1
                ? "Some of the library didn't sync: \(first), and \(failures.count - 1) more."
                : "Some of the library didn't sync: \(first)"
        case .collectionKept(let path):
            return "\(path) holds a whole collection, so it is kept here."
        case .mediaNotKept(let path):
            return "\(path) has nowhere on this device it can be kept."
        case .writingCollectionNotRenamed:
            return "Your writing couldn’t take its new name, “writing”, because another module on this device already has it. Remove the module called “writing”, then sync. Nothing was changed."
        }
    }
}

/// A Design B pass on this device. The pass itself is core's
/// (`LampSyncBundlePass`), the same one the Mac runs: it orders the work and
/// keeps the records. What is this device's own is around it: whether the
/// library has moved yet, the settings and deletion ledger that share its
/// bundle, the decks it mirrors, and `PhonePassLibrary`, which says what the
/// phone holds and takes in what arrives.
@MainActor
struct LibrarySyncPass {
    enum Outcome: Equatable {
        /// The server still holds the archive: the Mac has not migrated, so
        /// the archive pass runs instead. The phone never migrates.
        case notMigrated(archiveRevision: String?)
        /// Nothing migrated, and only this device ever kept the library: the
        /// person may move it, after updating their other devices. Nothing
        /// syncs until they do.
        case phoneLibrary
        case synced(bundleRevision: String, report: Report)
    }

    /// What a pass did, by path. A deletion here comes first: removing
    /// something of the person's is the last thing a pass should do without
    /// saying so, and without it a pass that deleted a highlight set reads
    /// exactly like one that did nothing.
    struct Report: Equatable {
        var deletedHere: [String] = []
        var broughtDown: [String] = []
        var sent: [String] = []
        var deletionsSent: [String] = []
        var changedDuringPass: [String] = []
        /// Brought down although this phone already held those very bytes:
        /// something it holds without saying so, as plans once were. Each
        /// costs a download every pass, and a deletion elsewhere never
        /// reaches it.
        var fetchedAgain: [String] = []
        /// Deleted on another device and installed here, but held here
        /// without saying so, so this pass leaves them: why something
        /// deleted elsewhere is still on this phone pass after pass.
        var deletionsNotCarriedOut: [String] = []

        init(_ outcome: LampSyncBundlePass.Outcome) {
            deletedHere = outcome.deletedLocally.sorted()
            broughtDown = (outcome.installed + outcome.reconciled).sorted()
            sent = outcome.uploaded.sorted()
            deletionsSent = outcome.tombstoned.sorted()
            changedDuringPass = outcome.changedDuringPass.sorted()
            fetchedAgain = outcome.fetchedAgain.sorted()
            deletionsNotCarriedOut = outcome.deletionsNotCarriedOut.sorted()
        }

        var line: String {
            let parts = [
                ("deleted here", deletedHere), ("brought down", broughtDown), ("sent", sent),
                ("deletions sent", deletionsSent), ("changed during the pass", changedDuringPass),
                ("fetched again, though held here", fetchedAgain),
                ("deleted elsewhere, but kept here", deletionsNotCarriedOut),
            ].filter { !$0.1.isEmpty }.map { "\($0.0) \($0.1.count): \($0.1.joined(separator: ", "))" }
            return parts.isEmpty ? "nothing to do" : parts.joined(separator: "; ")
        }
    }

    typealias Store = any ModuleStorage & LampSyncRemoteStore

    let storage: Store
    /// The endpoint, as the settings sync names it. Revisions and records
    /// mean nothing at any other.
    let source: String
    /// Settings and preferences, which live in the same bundle. Made against
    /// the bundle as read, with any versions iCloud kept beside it, and made
    /// again if either moves before the write.
    var makeParticipants: (
        LampSyncSettingsBundle?, [LampSyncSettingsStore.Version]
    ) throws -> [any SettingsBundleParticipant] = { _, _ in [] }
    /// How long a write the server took may take to show back. A Synology
    /// sends no ETag with a PUT and can answer a read with the body from
    /// before for a while after.
    var patience: LampSyncConditionalWrite.Patience = .standard

    /// A participant prepared against one bundle met a newer one at the
    /// write: prepare again against what is there now.
    struct BundleMoved: Error {}

    private var database: ModuleDatabase { .shared }
    private var modules: ModuleSyncManager { .shared }

    func run(knownArchiveRevision: String? = nil) async throws -> Outcome {
        // The server calls the writing collection `writing`. Until it has that
        // name here too, what arrives as `Writing/writing.lamp` would be taken
        // into whatever module is called `writing`, so nothing syncs.
        guard database.nameWritingCollectionIfItCan() else {
            throw LibrarySyncError.writingCollectionNotRenamed
        }
        DevotionalMediaStorage.moveFormatThreeWritingMedia(
            renamingTheCollectionsFolder: database.writingCollectionHasItsNewName()
        )
        // Whether the library has moved, asked first and cheaply: while the
        // archive is still there, at the revision this device imported, one
        // HEAD says so without the library being downloaded to learn it. A
        // truly empty library is claimed here before anything is written.
        do {
            _ = try await LampSyncSettingsStore.readOrClaim(
                from: storage, knownArchiveRevision: knownArchiveRevision, patience: patience
            )
        } catch LampSyncSettingsStore.StoreError.notMigrated(let revision) {
            if try await Self.isThisDevicesOwnLibrary(in: storage, source: source, archiveRevision: revision) {
                return .phoneLibrary
            }
            return .notMigrated(archiveRevision: revision)
        }

        let library = PhonePassLibrary(storage: storage, source: source)
        defer {
            library.announceChanges()
            library.cleanUp()
        }
        var records = try database.libraryRecords(source: source)
        library.seedFolderRevisions(into: &records)
        // A document made again here under a name deleted here, before the
        // deletion went up, replaces the copy the deletion took: planned as
        // changed since that copy, whatever its bytes, so it goes up over it
        // rather than being taken for it or by an edit made elsewhere.
        let heldDocuments = try LibrarySyncPass.documentStore.held()
        for change in try database.pendingManifestChanges(source: source)
        where change.change == .delete && LampSyncFolderLayout.kind(of: change.path) == .writingDocument
            && heldDocuments[change.path] != nil {
            var record = records.record(change.path, in: source)
                ?? LampSyncFileRecords.Record(installedRevision: change.revision)
            record.uploadedDigest = nil
            records.sources[source, default: LampSyncFileRecords.Source()].files[change.path] = record
        }
        // Not the record of a copy deleted here before it was taken in: kept,
        // as a document deleted during the pass keeps its record, it would
        // date the deletion after an edit this device never saw.
        func settleDocumentRecords() {
            for path in library.deletedWhileTakenIn { records.sources[source]?.files[path] = nil }
        }
        let carried = try database.pendingManifestWrites(source: source)
        var ledger = DeletionLedgerParticipant(source: source, contribution: .init(personal: .init()))
        var participants: [any SettingsBundleParticipant] = []
        var prepared: Set<String> = []

        let engine = LampSyncBundlePass(store: storage, library: library, source: source)
        let outcome: LampSyncBundlePass.Outcome
        do {
            outcome = try await engine.run(
                gathering: {
                    var gathered = try library.gather()
                    // A writing's documents change in place, and no folder
                    // listing reaches them: the manifest names each, and
                    // each is asked for in turn, as the Mac asks. Core asks
                    // after the rest (`LampSyncBundlePass.asksForRevision`),
                    // young deletions among them, so a removal that failed is
                    // tried again.
                    let asked = (library.opened?.manifest.paths ?? []).filter { path in
                        guard let entry = library.opened?.manifest.entry(at: path) else { return false }
                        return entry.kind == .writingDocument && entry.isMember
                    }
                    for path in asked.sorted() {
                        if let revision = try await storage.revision(path: path) {
                            gathered.extraListing[path] = revision
                        }
                    }
                    return gathered
                },
                records: &records,
                mergingVersion: { bundle, version in
                    // Only versions the settings were prepared with: one that
                    // landed since would be resolved without this device
                    // having merged its settings.
                    guard prepared.contains(version.revision) else {
                        throw LampSyncBundlePass.PrepareAgain()
                    }
                    try bundle.merge(version: version.bundle)
                },
                plannedKinds: { Self.isPlanned($0) },
                // Notes, writings, highlights and attachments are small, and
                // a write the server took must be seen back before it is
                // recorded; the Synology can answer with the body from before.
                confirmByReading: { Self.confirmsByReading($0) },
                patience: patience,
                receiving: { snapshot in
                    try receive(snapshot.bundle, into: library)
                    // This device's deletions, read here because the update's
                    // change only computes and may run again on a newer bundle.
                    ledger = DeletionLedgerParticipant(
                        source: source,
                        contribution: .init(personal: try database.personalDeletionLedger()),
                        touched: { library.noteChanges(inModules: $0) }
                    )
                    library.opened = snapshot.bundle
                    prepared = Set(snapshot.versions.map(\.revision))
                    participants = try makeParticipants(snapshot.bundle, snapshot.versions)
                },
                contributing: { bundle in
                    let now = ModuleDatabase.nowMilliseconds()
                    // A module file imported here goes up when it is chosen,
                    // outside any pass; the manifest learns of it now.
                    for write in carried {
                        bundle.manifest = try bundle.manifest.recordingWrite(
                            write.path, revision: write.revision, replacing: write.replacing,
                            at: max(write.at, now)
                        )
                    }
                    do {
                        for participant in [ledger] + participants {
                            try participant.change(&bundle, now: now)
                        }
                    } catch is BundleMoved {
                        throw LampSyncBundlePass.PrepareAgain()
                    }
                }
            )
        } catch {
            // What was written before it stopped is real; keep its records.
            settleDocumentRecords()
            try? database.saveLibraryRecords(records, source: source)
            throw error
        }
        settleDocumentRecords()
        try database.saveLibraryRecords(records, source: source)

        guard let written = outcome.written else { throw LampSyncSettingsStore.StoreError.tooManyAttempts }
        for participant in [ledger] + participants { try participant.committed(written) }
        // Not a deletion the pass left out, its file asked about and no
        // answer had: it waits for the next.
        // A document's record, kept through its deletion to date it, goes
        // with the deletion once carried, unless the file is held again: a
        // reap that failed, or found nothing, would otherwise leave it naming
        // a file deleted here as one kept here against a deletion elsewhere.
        let deferred = Set(outcome.deferred)
        let cleared = library.carriedDeletions.filter { !deferred.contains($0.path) }
        let heldNow = try LibrarySyncPass.documentStore.held()
        try database.clearPendingManifestChanges(carried + cleared, forgetting: cleared.filter {
            LampSyncFolderLayout.kind(of: $0.path) == .writingDocument && heldNow[$0.path] == nil
        })

        if await olderDeviceIsWriting() {
            SyncCoordinator.shared.olderDeviceSyncing = true
        }
        if let unsupplied = try? unsuppliedAttachments(manifest: written.bundle.manifest) {
            SyncCoordinator.shared.unsuppliedAttachments = unsupplied
        }
        // By the module each path is held as here: a read-only module's file
        // name need not be its ID.
        SyncCoordinator.shared.recordMissingModules(
            outcome.missing, source: source,
            moduleIDs: outcome.missing.keys.reduce(into: [:]) { ids, path in ids[path] = library.heldModules[path]?.id }
        )

        var failures = outcome.failures
        do {
            try await PresentationDeckSync.pull(from: storage, deletions: written.bundle.deckDeletions)
        } catch {
            failures.append("mirroring decks: \(error.localizedDescription)")
        }
        let report = Report(outcome)
        print("[LibrarySync] \(report.line)")
        for failure in failures { print("[LibrarySync] \(failure)") }
        // A module marked for publishing is settled once what it exports is
        // what the records say was sent. One edited while the pass ran stays
        // marked, so the pass its edit asks for still has it to send.
        for type in [ModuleType.notes, .devotional, .highlights] {
            for id in try database.pendingModulePublications(type: type) {
                guard let module = try database.getModule(id: id) else {
                    try database.clearPendingModulePublication(moduleId: id)
                    continue
                }
                let path = "\(storage.directoryName(for: type))/\(id).lamp"
                if let sent = records.record(path, in: source)?.uploadedDigest,
                   sent == (try? library.exportDigest(module)) {
                    try database.clearPendingModulePublication(moduleId: id)
                }
            }
        }
        guard failures.isEmpty else { throw LibrarySyncError.incomplete(failures) }
        return .synced(bundleRevision: written.revision, report: report)
    }

    /// Deletions made elsewhere, before anything here is gathered: a library
    /// read before them would publish what it had just been told was gone.
    /// One no device can read is skipped, as the Mac skips it.
    private func receive(_ bundle: LampSyncSettingsBundle, into library: PhonePassLibrary) throws {
        if let ledger = LampSyncBundleLedgers.personalDeletions(in: bundle) {
            try database.mergePersonalDeletionLedger(ledger)
            library.noteChanges(inModules: try database.applyPersonalDeletionLedger())
        }
        try Self.settleEmptiedHighlightModules(source: source)
    }

    private static let settingsFileRevisionsKey = "LibrarySync.settingsFileRevisions.v1"

    /// A Lamp Bible before 1.2.0 on iCloud Drive never reads the bundle: it
    /// goes on writing the settings file the new sync left behind, and what
    /// it does there is not seen. That file moving since the last pass means
    /// such a device is still syncing here. Its first sighting only sets the
    /// baseline.
    private func olderDeviceIsWriting() async -> Bool {
        guard let current = try? await storage.revision(path: LampSyncLayout.userSettingsPath) else {
            return false
        }
        let defaults = UserDefaults.standard
        var seen = (defaults.dictionary(forKey: Self.settingsFileRevisionsKey) as? [String: String]) ?? [:]
        let previous = seen[source]
        seen[source] = current
        defaults.set(seen, forKey: Self.settingsFileRevisionsKey)
        guard let previous else { return false }
        return !LampSyncConditionalWrite.namesSameRevision(previous, current)
    }

    /// What this device plans: modules and their media, each writing's
    /// review marks (what the writing assistant changed and the writer
    /// hasn't cleared), and each writing's own documents, its outline and
    /// notes. Decks are the Mac's to publish and mirrored here as before;
    /// the rest of a Mac workspace stays on the Mac. Pruning still sees every
    /// listed file, which core keeps to.
    static func isPlanned(_ kind: LampSyncFileKind?) -> Bool {
        switch kind {
        case .module, .devotionalMedia, .noteMedia, .bookMedia, .writingReview, .writingDocument: true
        case .deck, .deckAsset, .workspaceFile, nil: false
        }
    }

    /// Where the phone keeps its writings' documents, a folder for each
    /// writing as core names it. Every change goes through the store, which
    /// locks each file, so a save in the editor and a pass taking a download
    /// in never write over each other.
    nonisolated static var documentStore: LampWritingDocumentStore {
        LampWritingDocumentStore(
            rootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WritingWorkspaces", isDirectory: true)
        )
    }

    /// Held while a document is deleted here and while a pass takes one in.
    nonisolated static let documentChanges = NSLock()

    /// What a kept copy of this device's edits is named after.
    @MainActor static var deviceName: String { UIDevice.current.name }

    /// A document the writer deleted here, as they last saw it (`seen`):
    /// removed, and its deletion recorded for the server this device syncs
    /// with (`source`, nil for none) and every other it was sent to or taken
    /// from, so every other device removes its copy too, and a server synced
    /// with again later doesn't bring it back. Checked and removed under the file's lock: a copy sync brought
    /// in since, which the writer never saw, is kept under a copy's name,
    /// and that name returned.
    @discardableResult
    nonisolated static func deleteDocument(
        writingID: String, name: String, seen: Data, source: String?, device: String
    ) throws -> String? {
        let path = try LampWritingWorkspaceLayout.documentPath(writingID: writingID, name: name)
        // One at a time with a pass taking a download in, so a download
        // can't land between this deletion and its record.
        documentChanges.lock()
        defer { documentChanges.unlock() }
        let kept = try documentStore.remove(
            path: path, agreedDigest: LampSyncContentRevision.digest(for: seen), localDevice: device
        )
        let database = ModuleDatabase.shared
        for endpoint in Set(try database.syncSources(recording: path)).union(source.map { [$0] } ?? []) {
            try database.recordSyncLocalDeletion(source: endpoint, path: path)
        }
        // Its marks go with it, or with the copy sync brought in since,
        // whose body they were made of.
        try documentMarks(writingID: writingID, document: name, keptAs: kept, source: source)
        return kept
    }

    /// Where the phone keeps its writings' review marks: in its documents,
    /// laid out as the server lays them out, one file per writing. Every
    /// change goes through the store, which locks each file, so a clear in
    /// the editor and a pass taking a download in never write over each
    /// other.
    nonisolated static var reviewStore: LampWritingReviewStore {
        LampWritingReviewStore(rootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    /// The record held here at a review path, read as it stands.
    nonisolated static func heldReview(at path: String) -> LampWritingReview? {
        let url = reviewStore.rootURL.appendingPathComponent(path)
        return (try? Data(contentsOf: url)).flatMap { try? LampWritingReview.decoded(from: $0) }
    }

    /// A document's marks once its body moved or went (`LampWritingDocumentReview`):
    /// moved to the copy its body was kept as (`keptAs`), or gone with it.
    /// Either way the record left behind is deleted on the server this
    /// device syncs with (`source`) and every other the path was sent to or
    /// taken from; a pass deletes those of a document deleted here that never
    /// reached this device. Nothing where it has no marks here.
    nonisolated static func documentMarks(
        writingID: String, document: String, keptAs copy: String?, source: String?
    ) throws {
        let reviews = reviewStore
        // A writing whose id makes no review file's name has no marks to
        // move or sweep.
        guard let url = try? reviews.url(writingID: writingID, document: document),
              FileManager.default.fileExists(atPath: url.path) else { return }
        defer { Task { @MainActor in NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) } }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let deletions = try copy.map {
            try LampWritingDocumentReview.moved(document, to: $0, writingID: writingID, in: reviews, now: now)
        } ?? LampWritingDocumentReview.removed(document, writingID: writingID, in: reviews, now: now)
        let database = ModuleDatabase.shared
        for (path, at) in deletions {
            let time = Date(timeIntervalSince1970: Double(at) / 1_000)
            for endpoint in Set(try database.syncSources(recording: path)).union(source.map { [$0] } ?? []) {
                try database.recordSyncLocalDeletion(source: endpoint, path: path, at: time)
            }
        }
    }

    /// The writing a workspace folder is named for, among those with marks
    /// kept here (`LampWritingWorkspaceLayout.writingID(ofFolder:among:)`).
    nonisolated static func markedWriting(ofFolder folder: String) -> String? {
        LampWritingWorkspaceLayout.writingID(ofFolder: folder, among: (try? reviewStore.writingIDs()) ?? [])
    }

    static func confirmsByReading(_ kind: LampSyncFileKind) -> Bool {
        switch kind {
        case .module(let content): [.notes, .devotionals, .highlights].contains(content)
        case .devotionalMedia, .noteMedia, .bookMedia, .writingReview, .writingDocument: true
        case .deck, .deckAsset, .workspaceFile: false
        }
    }

    /// The files under `directory` of `documents`, by server path: the
    /// directory's own name, then each file's path within it. On a device the
    /// walk names each file under /private/var though Documents is under
    /// /var, so both are standardized before one is taken from the other, as
    /// core takes a book's pictures.
    nonisolated static func mediaFiles(in documents: URL, directory: String) -> [String: URL] {
        let root = documents.appendingPathComponent(directory, isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        let prefix = root.standardizedFileURL.path + "/"
        var media: [String: URL] = [:]
        for case let url as URL in files
        where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            media["\(directory)/\(path.dropFirst(prefix.count))"] = url
        }
        return media
    }

    /// The module a media file belongs to, as a path in the library.
    static func modulePath(forMedia path: String) -> String? {
        guard let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return nil }
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia: return "\(LampSyncContentKind.devotionals.folder)/\(id).lamp"
        case .noteMedia: return "\(LampSyncContentKind.notes.folder)/\(id).lamp"
        case .bookMedia: return "\(LampSyncContentKind.books.folder)/\(id).lamp"
        default: return nil
        }
    }

    static func moduleType(of path: String) -> ModuleType? {
        guard case .module(let kind) = LampSyncFolderLayout.kind(of: path) else { return nil }
        switch kind {
        case .translations: return .translation
        case .dictionaries: return .dictionary
        case .commentaries: return .commentary
        case .books: return .book
        case .devotionals: return .devotional
        case .notes: return .notes
        case .plans: return .plan
        case .highlights: return .highlights
        case .quizzes: return .quiz
        // No default: a kind core adds must be mapped here, or it would be
        // planned, installed as nothing and never claimed.
        }
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Attachments the writings and notes name that neither this device nor
    /// the server holds, by library path. They still go up with them: every
    /// writing shares one file, as every note does, so holding it back would
    /// stop them all, and the reference mends itself, since an attachment
    /// never changes at its path and goes up there the day it is back. One
    /// missing here but a member of the library is on the server, and leaves
    /// nothing to fix. The Mac reports by the same rule, from the same
    /// manifest.
    func unsuppliedAttachments(manifest: LampSyncLibraryManifest) throws -> [String] {
        try database.getAllModules()
            .filter { [.devotional, .notes].contains($0.type) && $0.isEditable }
            .flatMap {
                try $0.type == .notes
                    ? modules.noteMediaItems(moduleId: $0.id)
                    : modules.devotionalMediaItems(moduleId: $0.id, forExport: true)
            }
            .filter {
                !FileManager.default.fileExists(atPath: $0.localURL.path)
                    && manifest.entry(at: $0.remotePath)?.isMember != true
            }
            .map(\.remotePath)
            .sorted()
    }
}

// MARK: - What the phone holds

/// The phone's library as core's pass sees it: what it holds, as files with
/// digests, and how a file from the server becomes part of it. Editable
/// collections live in the database, so each pass exports them to files of
/// its own; installed modules keep no file at all, and are held by what the
/// records say was taken.
@MainActor
final class PhonePassLibrary: LampSyncPassLibrary {
    let storage: LibrarySyncPass.Store
    let source: String
    /// The bundle as the pass read it, which says what the library holds.
    var opened: LampSyncSettingsBundle?
    /// Deletions made here that this pass carries to the manifest.
    private(set) var carriedDeletions: [SyncPendingManifestChange] = []
    /// Documents downloaded but not taken in, deleted here meanwhile: the
    /// pass's record of them names a copy this device never saw.
    private(set) var deletedWhileTakenIn: Set<String> = []
    /// What each module path held here is, as the database knows it: a
    /// module's file may be named other than by its ID.
    private(set) var heldModules: [String: (type: ModuleType, id: String)] = [:]
    /// The IDs held here as modules other than books, gathered with them: a
    /// book's pictures under one of these IDs would share its folder in the
    /// cache, so they're neither sent nor taken in.
    private var otherModuleIDs: Set<String> = []
    /// What each editable module exported as when the pass gathered it,
    /// against which an install finds an edit made while the pass ran.
    private var gatheredDigests: [String: String] = [:]
    /// Paths with a record before this pass: a first install is the only one
    /// that may be answered from the archive the device already installed.
    private var recordedPaths: Set<String> = []
    private let scratch: URL

    private var database: ModuleDatabase { .shared }
    private var modules: ModuleSyncManager { .shared }

    init(storage: LibrarySyncPass.Store, source: String) {
        self.storage = storage
        self.source = source
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-\(UUID().uuidString)", isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The kinds of module this pass took in or removed.
    private var changedModuleTypes: Set<ModuleType> = []

    /// Modules whose entries another device's deletions removed here.
    func noteChanges(inModules ids: Set<String>) {
        for id in ids {
            if let type = try? database.getModule(id: id)?.type { changedModuleTypes.insert(type) }
        }
    }

    /// Tells open lists what the pass changed, once, however it ended: what
    /// was taken in before a failure is in the library all the same.
    func announceChanges() {
        guard !changedModuleTypes.isEmpty else { return }
        NotificationCenter.default.post(
            name: .libraryModulesDidChange, object: nil,
            userInfo: [LibraryModulesChange.typesKey: changedModuleTypes]
        )
        changedModuleTypes = []
    }

    /// On iCloud Drive a file's revision is the digest of its bytes, which is
    /// what the earlier iCloud sync recorded for each module. Taken as the
    /// revision of a module with no record yet, the first pass compares most
    /// files without reading them.
    func seedFolderRevisions(into records: inout LampSyncFileRecords) {
        recordedPaths = Set(records.sources[source]?.files.keys.map { $0 } ?? [])
        guard storage is ICloudLibraryStorage else { return }
        let folderRevision: (String?) -> String? = { hash in
            guard let hash, hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
            return LampSyncDirectoryStore.revision(forDigest: hash.lowercased())
        }
        var seeds: [(String, String)] = []
        for module in (try? database.getAllModules()) ?? [] where module.isEditable {
            if let revision = folderRevision(module.fileHash) {
                seeds.append((remotePath(type: module.type, fileName: "\(module.id).lamp"), revision))
            }
        }
        for (type, _, fileName, fileHash) in (try? installedReadOnlyModules()) ?? [] {
            if let revision = folderRevision(fileHash) {
                seeds.append((remotePath(type: type, fileName: fileName), revision))
            }
        }
        for (path, revision) in seeds where records.record(path, in: source) == nil {
            records.recordInstall(path, in: source, revision: revision, digest: nil)
        }
    }

    /// Everything this device holds, read after the other devices'
    /// deletions were applied.
    func gather() throws -> LampSyncBundlePass.Gathered {
        var gathered = LampSyncBundlePass.Gathered()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let manifest = opened?.manifest ?? LampSyncLibraryManifest()
        heldModules = [:]

        for module in try database.getAllModules() where module.isEditable
            && [.notes, .devotional, .highlights].contains(module.type) {
            // A highlights module whose set has gone has nothing to send.
            if module.type == .highlights, try database.getHighlightSets(forModule: module.id).isEmpty {
                continue
            }
            let path = remotePath(type: module.type, fileName: "\(module.id).lamp")
            guard case .module(let kind)? = LampSyncFolderLayout.kind(of: path) else { continue }
            // A conflict the person has not settled yet: held as it was last
            // agreed, so the other device's changes still arrive but neither
            // side's version goes up until they choose.
            if try database.hasPendingModuleConflicts(moduleId: module.id) {
                gathered.heldWithoutAFile.insert(path)
                heldModules[path] = (module.type, module.id)
                // Still saved here when it was: an edit after another
                // device's deletion survives it, held or not.
                if let saved = try savedAt(module) { gathered.savedAt[path] = saved }
                continue
            }
            let data = try exportedBytes(module)
            let url = scratch.appendingPathComponent("\(UUID().uuidString).lamp")
            try data.write(to: url)
            let digest = LibrarySyncPass.digest(data)
            gatheredDigests[path] = digest
            gathered.local.append(LampSyncLocalFile(
                path: path, kind: .module(kind), url: url, digest: digest
            ))
            if let saved = try savedAt(module) { gathered.savedAt[path] = saved }
            heldModules[path] = (module.type, module.id)
        }

        for (type, id, fileName, _) in try installedReadOnlyModules() {
            let path = remotePath(type: type, fileName: fileName)
            guard heldModules[path] == nil else { continue }
            gathered.heldWithoutAFile.insert(path)
            heldModules[path] = (type, id)
        }

        // Media only for modules in the library.
        let libraryModules = Set(heldModules.keys).union(manifest.members.map(\.path))
        let mediaDigests = PhonePassLibrary.digestCache(
            forLibraryAt: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        )
        for (path, url) in localMedia() {
            guard manifest.entry(at: path) != nil
                    || LibrarySyncPass.modulePath(forMedia: path).map(libraryModules.contains) == true,
                  let kind = LampSyncFolderLayout.kind(of: path)
            else { continue }
            // A file that is here and cannot be read is said so, rather than
            // left out: a path missing from the locals reads as one this
            // device does not hold, so the plan would fetch the server's copy
            // and install it over the file
            // (`lamp-bible-core/Documentation/decisions/0013`).
            guard let digest = PhonePassLibrary.digest(forFileAt: url, kind: kind, cache: mediaDigests)
            else {
                gathered.refused[path] = "its file could not be read"
                continue
            }
            gathered.local.append(LampSyncLocalFile(path: path, kind: kind, url: url, digest: digest))
        }

        // A book's pictures, by core's rules, for the books in the library
        // and any the manifest already names. The cache they're kept in also
        // holds commentaries', dictionaries' and notes' pictures, and those
        // of the books that came with the app: none goes up as a book's, and
        // a book whose ID is another module's here has no folder of its own
        // (`bookOnly`) to send from.
        let held = heldModules.values
        otherModuleIDs = Set(held.filter { $0.type != .book }.map(\.id))
        // One the library holds for a book whose ID is another module's here
        // is kept off this device, as taken when it was last fetched: held,
        // so later passes neither fetch it again nor count it as missing.
        // Not one under a tombstone: no library carries out a deletion of a
        // book's picture, so held there it would be planned to go back up.
        for member in manifest.members where keptOffForAnotherModule(member.path) || keptOffForItsID(member.path) {
            gathered.heldWithoutAFile.insert(member.path)
        }
        let pictures = LampBookMediaFiles.outgoing(
            books: Set(held.filter { $0.type == .book }.map(\.id)),
            otherModules: otherModuleIDs,
            remotePaths: manifest.members.map(\.path),
            folders: ModuleMediaStorage.shared.bookFolders(for:)
        )
        for file in pictures.files {
            guard let digest = PhonePassLibrary.digest(
                forFileAt: file.url, kind: .bookMedia, cache: mediaDigests
            ) else {
                gathered.refused[file.remotePath] = "its file could not be read"
                continue
            }
            gathered.local.append(LampSyncLocalFile(
                path: file.remotePath, kind: .bookMedia, url: file.url, digest: digest
            ))
        }
        for kept in pictures.unplaceable {
            print("[LibrarySync] book picture \(kept.path) kept here: \(kept.reason)")
        }

        carriedDeletions = try database.pendingManifestChanges(source: source).filter { $0.change == .delete }
        gathered.deletedLocally = Dictionary(
            carriedDeletions.map { ($0.path, $0.at) }, uniquingKeysWith: { max($0, $1) }
        )

        // Each writing's review marks. A deleted writing's go with it
        // everywhere, swept first, so a file removed here isn't also offered
        // for upload.
        let reviews = LibrarySyncPass.reviewStore
        let ledger = try database.personalDeletionLedger()
        let reviewDeletions = try reviews.deletions(
            // Only deletions that still stand: a writing saved again under its
            // id after one keeps it beside the newer save.
            deleted: LampWritingReviewStore.deletedWritings(in: ledger),
            held: try DevotionalStorage.shared.getAllWritingIDs(),
            members: Dictionary(manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max),
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        gathered.deletedLocally.merge(reviewDeletions) { max($0, $1) }
        // A document's marks share its fate (`LampWritingDocumentReview.fate`),
        // judged here for each record of one by the document's own path,
        // though the marks never reached this device. A deletion going up is
        // dated after the write the manifest holds for the marks, so a clock
        // running behind can't let that write bring them back. A deleted
        // writing's are core's sweep's, above.
        let written = Dictionary(manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max)
        let documentsHeld = try LibrarySyncPass.documentStore.held()
        // The write a deletion here deleted is the one it names, or, deleted
        // while its own upload ran, the one that upload made, which this
        // device's records keep and no deletion named yet.
        let fileRecords = try database.libraryRecords(source: source)
        let deletedHere = Dictionary(
            carriedDeletions.filter { LampSyncFolderLayout.kind(of: $0.path) == .writingDocument }.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // A name too long to keep is a digest in the record's path, and its
        // record may be gone here already: found among the documents deleted
        // here or held here instead.
        let documentsKnown = Set(deletedHere.keys).union(documentsHeld.keys)
            .compactMap { LampWritingWorkspaceLayout.document(ofPath: $0) }
        for path in Set(written.keys).union(gathered.deletedLocally.keys) where reviewDeletions[path] == nil {
            guard let target = LampSyncFolderLayout.reviewTarget(ofPath: path), let key = target.documentKey else { continue }
            let named = LampWritingDocumentReview.place(of: path, record: LibrarySyncPass.heldReview(at: path))?.document
                ?? documentsKnown.first {
                    LampWritingWorkspaceLayout.directoryName(for: target.writingID) == $0.folder
                        && LampSyncFolderLayout.reviewDocumentKey(writingID: target.writingID, document: $0.name) == key
                }?.name
            guard let name = named,
                  let documentPath = try? LampWritingWorkspaceLayout.documentPath(writingID: target.writingID, name: name)
            else {
                // A digest whose name is gone with its record: a deletion of
                // it already asked for still goes up, dated past the write.
                if let at = gathered.deletedLocally[path] {
                    gathered.deletedLocally[path] = written[path].map { max(at, $0 + 1) } ?? at
                }
                continue
            }
            let document = manifest.entry(at: documentPath)
            let change = deletedHere[documentPath]
            // The revision the deletion here deleted, as core compares it:
            // the one it names, or, deleted while its own upload ran, the one
            // that upload made, which this device's records keep.
            let deletedRevision: String? = change.flatMap { change in
                guard let write = document?.revision else { return change.revision }
                let named = [change.revision, fileRecords.record(documentPath, in: source)?.effectiveRevision]
                    .contains { $0.map { LampSyncConditionalWrite.namesSameRevision($0, write) } ?? false }
                return named ? write : change.revision
            }
            let fate = LampWritingDocumentReview.fate(
                held: documentsHeld[documentPath] != nil,
                deletedHere: change.map { (at: $0.at, revision: deletedRevision) },
                document: document.map { (revision: $0.revision, isMember: $0.isMember) },
                documentWritten: written[documentPath],
                asked: gathered.deletedLocally[path],
                now: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            switch fate {
            case .none:
                continue
            case .cancelled:
                gathered.deletedLocally[path] = nil
            case .deleted(let at):
                try reviews.remove(writingID: target.writingID, document: name)
                gathered.deletedLocally[path] = written[path].map { max(at, $0 + 1) } ?? at
            }
        }
        // The writing's own and each document's beside it, a file each.
        for path in try reviews.paths() {
            guard let place = LampWritingDocumentReview.place(of: path, record: LibrarySyncPass.heldReview(at: path))
            else { continue }
            // Sent from a copy, read under the file's lock: a clear landing
            // while the pass runs can't leave the bytes sent unlike the
            // digest taken of them.
            let review = try reviews.review(writingID: place.writingID, document: place.document)
            let copy = scratch.appendingPathComponent("review-\(UUID().uuidString).json")
            try review.encoded().write(to: copy, options: .atomic)
            guard let digest = try? LampSyncContentRevision.digest(forFileAt: copy) else { continue }
            gathered.local.append(LampSyncLocalFile(path: path, kind: .writingReview, url: copy, digest: digest))
        }

        // Each writing's documents. A deleted writing's go with it, as its
        // marks do; one the writer deleted here is dated never before the
        // write the manifest holds for it, so a clock running behind can't
        // let that write bring it back.
        let documents = LibrarySyncPass.documentStore
        let members = Dictionary(manifest.members.map { ($0.path, $0.presentSince ?? 0) }, uniquingKeysWith: max)
        let documentDeletions = try documents.deletions(
            deleted: LampWritingReviewStore.deletedWritings(in: ledger),
            held: try DevotionalStorage.shared.getAllWritingIDs(),
            members: members,
            now: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        gathered.deletedLocally.merge(documentDeletions) { max($0, $1) }
        for change in carriedDeletions where LampSyncFolderLayout.kind(of: change.path) == .writingDocument {
            // Only over the write it deleted: one another device made since
            // is newer than the deletion, and outlives it.
            guard let deleted = change.revision, let written = manifest.entry(at: change.path)?.revision,
                  LampSyncConditionalWrite.namesSameRevision(deleted, written),
                  let at = gathered.deletedLocally[change.path] else { continue }
            gathered.deletedLocally[change.path] = LampWritingDocumentStore.deletionTime(
                of: change.path, members: members, now: at
            )
        }
        let agreed = try database.libraryRecords(source: source)
        let heldDocuments = try documents.held()
        // One made again here under a name deleted here, before the deletion
        // went up: the deletion took the file, so one held now was written
        // since, and is the writer's new file, not the deletion's to take.
        // It's dated when written whatever its bytes, so it outlives a
        // deletion made elsewhere before it, as a new file does. The
        // deletion is still cleared once the bundle is written.
        var madeAgain: Set<String> = []
        for (path, _) in heldDocuments where documentDeletions[path] == nil
            && carriedDeletions.contains(where: { $0.path == path }) {
            gathered.deletedLocally[path] = nil
            madeAgain.insert(path)
        }
        for (path, url) in heldDocuments where gathered.deletedLocally[path] == nil {
            // Sent from a copy, as the marks are: a save landing while the
            // pass runs can't leave the bytes sent unlike their digest.
            guard let data = try? Data(contentsOf: url) else { continue }
            let copy = scratch.appendingPathComponent("document-\(UUID().uuidString)")
            try data.write(to: copy, options: .atomic)
            gathered.local.append(LampSyncLocalFile(
                path: path, kind: .writingDocument, url: copy, digest: LampSyncContentRevision.digest(for: data)
            ))
            // When it was last written here, so one written after another
            // device deleted it, a file made again under the same name,
            // survives the deletion rather than being taken by it. Only one
            // unlike what this device last agreed with the server on: a copy
            // as taken in is dated when it arrived, which is no edit.
            let digest = LampSyncContentRevision.digest(for: data)
            if madeAgain.contains(path) || agreed.record(path, in: source)?.uploadedDigest != digest,
               let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                gathered.savedAt[path] = Int64(modified.timeIntervalSince1970 * 1_000)
            }
        }
        // A document's marks dated as the document is, so one saved here
        // after another device deleted it comes back with its marks, not
        // without them.
        // Marks changed here and not yet sent, for a document held here, are
        // dated when they were written, so a document that outlived a
        // deletion keeps them though their own upload failed.
        for path in (try? reviews.paths()) ?? [] {
            guard let place = LampWritingDocumentReview.place(of: path, record: LibrarySyncPass.heldReview(at: path)),
                  let name = place.document,
                  let documentPath = try? LampWritingWorkspaceLayout.documentPath(writingID: place.writingID, name: name),
                  heldDocuments[documentPath] != nil else { continue }
            var saved = gathered.savedAt[documentPath]
            let url = reviews.rootURL.appendingPathComponent(path)
            if let digest = try? LampSyncContentRevision.digest(forFileAt: url),
               agreed.record(path, in: source)?.uploadedDigest != digest,
               let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                saved = max(saved ?? 0, Int64(modified.timeIntervalSince1970 * 1_000))
            }
            guard let saved else { continue }
            gathered.savedAt[path] = max(gathered.savedAt[path] ?? 0, saved)
        }
        return gathered
    }

    // MARK: LampSyncPassLibrary

    /// A writing's document is taken in by core's rule, against what this
    /// device last agreed with the server on: edited here since, it's kept
    /// beside the server's copy rather than replaced.
    func install(_ path: String, from url: URL, agreedDigest: String?) async throws -> String? {
        guard LampSyncFolderLayout.kind(of: path) == .writingDocument else {
            return try await install(path, from: url)
        }
        try takeInDocument(path, from: url, agreedDigest: agreedDigest)
        return nil
    }

    /// A writing's document deleted elsewhere is removed, unless it was
    /// edited here since this device last agreed with the server: then it's
    /// kept under a copy's name, and goes up as a document of its own.
    func deleteLocally(_ path: String, agreedDigest: String?) async throws {
        guard LampSyncFolderLayout.kind(of: path) == .writingDocument else {
            return try await deleteLocally(path)
        }
        // Removed, and its marks moved or swept, as one under the lock a
        // save from the Files sheet writes and carries under.
        try LibrarySyncPass.documentChanges.withLock {
            let kept = try LibrarySyncPass.documentStore.remove(
                path: path, agreedDigest: agreedDigest, localDevice: LibrarySyncPass.deviceName
            )
            if let document = LampWritingWorkspaceLayout.document(ofPath: path),
               let writingID = LibrarySyncPass.markedWriting(ofFolder: document.folder) {
                try LibrarySyncPass.documentMarks(writingID: writingID, document: document.name, keptAs: kept, source: source)
            }
        }
        NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
    }

    private func takeInDocument(_ path: String, from url: URL, agreedDigest: String?) throws {
        // Deleted here since the pass gathered it: a download finishing
        // after the writer deleted the file doesn't bring it back. Not one
        // deleted before, which the plan weighed, or which a file made again
        // since undid: a write made elsewhere since outlives it, and is
        // taken. Told apart by when it was made, so a deletion made again
        // since, which replaces the one carried, isn't taken for it. Checked
        // and taken in under the lock a deletion holds.
        LibrarySyncPass.documentChanges.lock()
        defer { LibrarySyncPass.documentChanges.unlock() }
        let pending = try database.pendingManifestDeletions(source: source)[path]
        let deletedSince = pending.map { at in !carriedDeletions.contains { $0.path == path && $0.at == at } } ?? false
        guard !deletedSince else {
            deletedWhileTakenIn.insert(path)
            return
        }
        let decision = try LibrarySyncPass.documentStore.takeIn(
            downloaded: try Data(contentsOf: url), path: path,
            agreedDigest: agreedDigest, localDevice: LibrarySyncPass.deviceName
        )
        // This device's body kept under a copy's name: its marks stay with
        // the document's own name, not moved with it. The pass took the
        // server's marks in before this, and the record now holds those of
        // the body that arrived as well; moved whole, they'd go onto the
        // copy and their deletion with them, and the assistant's latest
        // change would go unmarked everywhere. Marks of the kept body, which
        // the arrived one doesn't hold, are found in neither and drawn on
        // neither.
        _ = decision
        NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
    }

    func install(_ path: String, from url: URL) async throws -> String? {
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia, .noteMedia, .bookMedia:
            // A picture coming in after its note, writing or book: shown
            // once the view holding it draws again.
            switch LampSyncFolderLayout.kind(of: path) {
            case .noteMedia: changedModuleTypes.insert(.notes)
            case .devotionalMedia: changedModuleTypes.insert(.devotional)
            default: changedModuleTypes.insert(.book)
            }
            guard let local = localURL(forMedia: path) else {
                // Another module's folder, not this book's: taken as here,
                // with nothing written, so it isn't fetched on every pass.
                if keptOffForAnotherModule(path) {
                    print("[LibrarySync] \(path) kept off this device: its book's ID is another module's here")
                    return nil
                }
                throw LibrarySyncError.mediaNotKept(path)
            }
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.copyItem(at: url, to: local)
            return nil
        case .module:
            if let type = LibrarySyncPass.moduleType(of: path) { changedModuleTypes.insert(type) }
            return try await installModule(path, from: url, merging: false)
        case .writingReview:
            // Merged into the copy here, never put over it: this device may
            // hold clears the server's copy hasn't seen. What differs from the
            // download goes back up, by the plan on the next pass, or by
            // `reconcile` when both sides changed.
            let arrived = try Data(contentsOf: url)
            guard let place = LampWritingDocumentReview.place(of: path, record: try? LampWritingReview.decoded(from: arrived))
            else { return nil }
            try LibrarySyncPass.reviewStore.takeIn(downloaded: arrived, writingID: place.writingID, document: place.document)
            await MainActor.run { NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) }
            return nil
        default:
            return nil
        }
    }

    /// Both sides changed: each is merged by value into the library, and
    /// what the merge leaves goes back up, as the Mac sends back its own.
    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] {
        var republish: [String: URL] = [:]
        for (path, url) in downloaded.sorted(by: { $0.key < $1.key }) {
            if LampSyncFolderLayout.kind(of: path) == .writingDocument {
                // Both changed: the server's copy keeps the name, and this
                // device's edits, where they differ, are kept beside it and
                // go up on the next pass. Nothing goes back up at the path.
                try takeInDocument(path, from: url, agreedDigest: nil)
                continue
            }
            if LampSyncFolderLayout.kind(of: path) == .writingReview {
                // Merged by `takeIn`; what goes back up is the merge, and only
                // when this device had marks or clears the download lacked.
                let reviews = LibrarySyncPass.reviewStore
                let arrived = try Data(contentsOf: url)
                guard let place = LampWritingDocumentReview.place(of: path, record: try? LampWritingReview.decoded(from: arrived))
                else { continue }
                let differs = try reviews.takeIn(downloaded: arrived, writingID: place.writingID, document: place.document)
                await MainActor.run { NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) }
                guard differs else { continue }
                // From a copy in this pass's scratch, never the file itself.
                let copy = scratch.appendingPathComponent("review-\(UUID().uuidString).json")
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                try reviews.review(writingID: place.writingID, document: place.document)
                    .encoded().write(to: copy, options: .atomic)
                republish[path] = copy
                continue
            }
            if let type = LibrarySyncPass.moduleType(of: path) { changedModuleTypes.insert(type) }
            _ = try await installModule(path, from: url, merging: true)
            guard let id = heldModules[path]?.id ?? LampSyncFolderLayout.remoteModuleID(of: path),
                  let module = try database.getModule(id: id) else { continue }
            let merged = scratch.appendingPathComponent("\(UUID().uuidString).lamp")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try exportedBytes(module).write(to: merged)
            republish[path] = merged
        }
        return republish
    }

    /// Deleted on another device after this copy was saved.
    func deleteLocally(_ path: String) async throws {
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia, .noteMedia, .bookMedia:
            if let url = localURL(forMedia: path) { try? FileManager.default.removeItem(at: url) }
        case .module:
            // Core's plan never asks for a collection; refused here as well.
            guard LampSyncLocalDeletion.target(of: path) != .collection else {
                throw LibrarySyncError.collectionKept(path)
            }
            guard let held = heldModules[path] else { return }
            changedModuleTypes.insert(held.type)
            if held.type == .translation {
                try database.deleteTranslation(id: held.id)
            } else if held.type == .plan {
                // Its days go with it. Whether it is still followed, and its
                // ticks, arrive in the plan ledger from the device that
                // deleted it.
                try database.deletePlan(id: held.id)
            } else {
                try database.deleteAllEntriesForModule(moduleId: held.id)
                try database.deleteModule(id: held.id)
            }
        case .writingReview:
            // The file at that path only: a document's record gone elsewhere
            // isn't the writing's own.
            guard let place = LampWritingDocumentReview.place(of: path, record: LibrarySyncPass.heldReview(at: path))
            else { return }
            try LibrarySyncPass.reviewStore.remove(writingID: place.writingID, document: place.document)
            await MainActor.run { NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) }
        default:
            return
        }
    }

    // MARK: Taking a module in

    /// Returns what this device holds at the path afterwards, as it would
    /// publish it, for an editable collection taken in whole; nil when that
    /// is the bytes that arrived. `merging` when both sides changed it;
    /// otherwise the copy here is as last agreed, and is simply replaced,
    /// unless it was edited while the pass ran.
    private func installModule(_ path: String, from url: URL, merging: Bool) async throws -> String? {
        guard let type = LibrarySyncPass.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return nil }
        if keptOffForItsID(path) {
            print("[LibrarySync] \(path) kept off this device: its ID is a collection's or another module's here")
            return nil
        }
        let fileName = String(path.dropFirst(storage.directoryName(for: type).count + 1))
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let editable = [ModuleType.notes, .devotional, .highlights].contains(type)
        // The first pass after the switch has no records, so every installed
        // module arrives once. Most are the very bytes the archive already
        // installed; reinstalling would rewrite every verse and its search
        // index for nothing.
        if !editable, !recordedPaths.contains(path), heldModules[path] != nil,
           let installed = Self.archivedDigests()[id], installed == LibrarySyncPass.digest(data) {
            return nil
        }
        // Edited here since the pass gathered it, which core can't see in
        // the snapshot it planned from: both sides have changed it, so it is
        // taken as a merge is, and recorded as the bytes that arrived, so
        // the edit goes up next pass rather than counting as sent.
        var editedDuringPass = false
        if !merging, editable, let gathered = gatheredDigests[path], let module = try database.getModule(id: id) {
            editedDuringPass = try exportDigest(module) != gathered
        }
        let fileInfo = ModuleFileInfo(id: id, type: type, filePath: fileName, fileHash: nil, modificationDate: nil)
        try await modules.importRemoteModuleSnapshot(
            fileInfo: fileInfo, type: type,
            snapshot: LampSyncRemoteFile(data: data, revision: nil), storage: storage,
            mergingHighlights: merging || editedDuringPass
        )
        guard editable, !editedDuringPass, let module = try database.getModule(id: id),
              !(try database.pendingModulePublications(type: type).contains(id)) else { return nil }
        // This device spells the same content its own way; recording the
        // other device's bytes as what it holds would have it send its own
        // spelling back, and the other device answer with its own, for ever.
        return LibrarySyncPass.digest(try exportedBytes(module))
    }

    /// What the archive import installed, by module: the digest of each
    /// module's bytes as they were in the archive.
    static func archivedDigests() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: ModuleSyncManager.portableArchiveImportStateKey),
              let state = try? JSONDecoder().decode(
                ModuleSyncManager.PortableArchiveImportState.self, from: data
              ) else { return [:] }
        return Dictionary(state.modules.map { ($0.id, $0.digest) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: The library

    /// This device's own export of an editable module, as a pass would send it.
    func exportDigest(_ module: Module) throws -> String {
        LibrarySyncPass.digest(try exportedBytes(module))
    }

    private func remotePath(type: ModuleType, fileName: String) -> String {
        "\(storage.directoryName(for: type))/\(fileName)"
    }

    /// A collection compiled for publishing, built once per change to it
    /// rather than once per pass.
    ///
    /// Compiling means a database built row by row, `ANALYZE`, `VACUUM` and
    /// zlib. A pass runs whenever anything changed, and an edit to one
    /// collection had all three recompiled — on the phone, where that is
    /// battery. The Mac's side of this is
    /// `lamp-bible-core/Documentation/decisions/0002`.
    ///
    /// Keyed on the count the database keeps of changes to that collection
    /// (`devotionalCollectionChanges`, triggers since v44 for writings and
    /// v45 for notes and highlights), read **before** the rows: a change made
    /// while this compiles counts as after it, so the next pass compiles
    /// again rather than publishing bytes that miss it.
    private func exportedBytes(_ module: Module) throws -> Data {
        let changes = try? database.devotionalCollectionChanges(moduleID: module.id)
        let generation = database.generation
        if let changes {
            Self.collectionExports.lock()
            let kept = Self.collectionExportsByID[module.id]
            Self.collectionExports.unlock()
            if let kept, kept.changes == changes, kept.generation == generation {
                return kept.bytes
            }
        }
        // The module's own row read **after** the count, not before: the row
        // carries the name, description, author and version that go into the
        // file, and a local import can change those between the two reads —
        // which would cache this collection's entries with the metadata they
        // had beforehand, under the new count, and keep it. Found by a Codex
        // review. The caller's copy was fetched earlier still.
        let current = (try? database.getModule(id: module.id)) ?? module
        let bytes: Data = switch current.type {
        case .notes: try modules.exportNoteModuleToSQLite(current)
        case .devotional: try modules.exportDevotionalModuleToSQLite(current)
        case .highlights: try modules.exportHighlightModuleToSQLite(current)
        default: throw ModuleSyncError.moduleNotEditable(current.id)
        }
        if let changes {
            Self.collectionExports.lock()
            Self.collectionExportsByID[module.id] = (generation, changes, bytes)
            Self.collectionExports.unlock()
        }
        return bytes
    }

    /// Each collection's compiled bytes, with the change count they were
    /// built at and which database that count came from.
    ///
    /// The generation matters because the counters start again from zero with
    /// a new database file — a reset from Settings, a recovery — and the same
    /// few writes reproduce the same count, so a count alone would let this
    /// hand back a collection from before the reset.
    nonisolated private static let collectionExports = NSLock()
    nonisolated(unsafe) private static var collectionExportsByID:
        [String: (generation: UUID, changes: Int64, bytes: Data)] = [:]

    /// Digests of the files whose bytes do not change at a path — media and
    /// book pictures — kept for as long as the app runs, and only where the
    /// filesystem maintains an identity worth trusting
    /// (`lamp-bible-core/Documentation/decisions/0007`). The phone's library
    /// is on its own APFS volume, so this is the trusted case; a library
    /// somewhere else reads every file every pass, as it always did.
    nonisolated private static let digestCacheLock = NSLock()
    nonisolated(unsafe) private static var heldDigestCache: (root: String, cache: LampSyncDigestCache?)?

    nonisolated static func digestCache(forLibraryAt root: URL) -> LampSyncDigestCache? {
        let path = root.standardizedFileURL.path
        digestCacheLock.lock()
        defer { digestCacheLock.unlock() }
        if let held = heldDigestCache, held.root == path { return held.cache }
        let trusted = LampSyncIdentityTrust.trustsIdentity(ofVolumeAt: root)
        let cache = trusted ? LampSyncDigestCache() : nil
        heldDigestCache = (path, cache)
        return cache
    }

    /// A file's digest, from the cache where its kind and the filesystem
    /// allow it, and from its bytes otherwise.
    nonisolated private static func digest(
        forFileAt url: URL, kind: LampSyncFileKind, cache: LampSyncDigestCache?
    ) -> String? {
        guard let cache, kind.keepsDigestAgainstIdentity,
              let identity = try? LampFileIdentity(url: url) else {
            return try? LampSyncContentRevision.digest(forFileAt: url)
        }
        if let held = cache.digest(at: url, identity: identity) { return held }
        guard let read = try? LampSyncContentRevision.digest(forFileAt: url) else { return nil }
        cache.remember(read, at: url, identity: identity)
        return read
    }

    private func installedReadOnlyModules() throws -> [(ModuleType, String, String, String?)] {
        let translations = try database.getAllTranslations(bundledOnly: false).compactMap {
            translation -> (ModuleType, String, String, String?)? in
            guard let filePath = translation.filePath, !filePath.isEmpty else { return nil }
            return (.translation, translation.id, filePath, translation.fileHash)
        }
        // Unclaimed, a plan was downloaded again on every pass, and a
        // deletion elsewhere never reached it.
        let plans = try database.installedPlanFiles().map {
            (ModuleType.plan, $0.id, $0.filePath, $0.fileHash)
        }
        // Quizzes neither, and they keep no file of their own: each is held
        // at the path its id spells, as the compiler names the file. Core
        // honours that only where an install was recorded there.
        let quizzes = try database.getAllQuizModules().map {
            (ModuleType.quiz, $0.id, "\($0.id).lamp", String?.none)
        }
        let others = try database.getAllModules().compactMap { module -> (ModuleType, String, String, String?)? in
            guard !module.isEditable, module.type != .translation, !module.filePath.isEmpty else { return nil }
            return (module.type, module.id, module.filePath, module.fileHash)
        }
        return translations + plans + quizzes + others
    }

    /// Writings' and notes' media present on this device, by server path.
    /// A book's pictures are gathered by core's rules instead.
    private func localMedia() -> [String: URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var media: [String: URL] = [:]
        for directory in [LampSyncFolderLayout.devotionalMediaDirectory, LampSyncFolderLayout.noteMediaDirectory] {
            media.merge(LibrarySyncPass.mediaFiles(in: documents, directory: directory)) { kept, _ in kept }
        }
        return media
    }

    private func localURL(forMedia path: String) -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia, .noteMedia:
            return documents.appendingPathComponent(path)
        case .bookMedia:
            return LampBookMediaFiles.installURL(
                forRemotePath: path, folders: ModuleMediaStorage.shared.bookFolders(for:),
                otherModules: otherModuleIDs
            )
        default:
            return nil
        }
    }

    /// A module this device will not take in. It keeps one module per ID,
    /// whatever its kind, so one named for a collection anywhere but that
    /// collection's path, a book called `writing` say, or one whose ID
    /// another kind already holds here, would be taken into that module and
    /// its rows replaced. Kept off instead, and held without a file, so it is
    /// neither fetched on every pass nor deleted here when deleted elsewhere,
    /// since it was never this device's to delete.
    private func keptOffForItsID(_ path: String) -> Bool {
        guard let type = LibrarySyncPass.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return false }
        let collectionIDs = [LampSyncLocalDeletion.notesCollectionID, LampSyncLocalDeletion.writingCollectionID]
        if collectionIDs.contains(id), LampSyncLocalDeletion.target(of: path) != .collection { return true }
        return database.holdsAnotherKindOfModule(id: id, than: type)
    }

    /// A book's picture that core keeps out of the cache only because its
    /// book's ID, as the volume compares names, is another module's here.
    private func keptOffForAnotherModule(_ path: String) -> Bool {
        let folders = ModuleMediaStorage.shared.bookFolders(for:)
        return LampSyncFolderLayout.kind(of: path) == .bookMedia
            && LampBookMediaFiles.installURL(forRemotePath: path, folders: folders, otherModules: otherModuleIDs) == nil
            && LampBookMediaFiles.installURL(forRemotePath: path, folders: folders) != nil
    }

    private func savedAt(_ module: Module) throws -> Int64? {
        let seconds: Int? = try database.read { db in
            switch module.type {
            case .notes:
                return try Int.fetchOne(db, sql: "SELECT max(last_modified) FROM note_entries WHERE module_id = ?", arguments: [module.id])
            case .devotional:
                return try Int.fetchOne(db, sql: "SELECT max(last_modified) FROM devotional_entries WHERE module_id = ?", arguments: [module.id])
            case .highlights:
                return try Int.fetchOne(db, sql: "SELECT max(last_modified) FROM highlight_sets WHERE module_id = ?", arguments: [module.id])
            default:
                return nil
            }
        }
        return seconds.map { Int64($0) * 1_000 }
    }
}

// MARK: - Bundle participants

/// Item deletions: this device's ledger joined with the bundle's, and what
/// the join says is gone removed here too, by the rules both apps share in
/// `LampSyncBundleLedgers`.
@MainActor
struct DeletionLedgerParticipant: SettingsBundleParticipant {
    let source: String
    /// This device's own records, read before the update.
    let contribution: LampSyncBundleLedgers.Contribution
    /// Told the modules whose notes, writings or highlights the ledger
    /// removed here.
    var touched: (Set<String>) -> Void = { _ in }

    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        try contribution.apply(to: &bundle)
    }

    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
        guard let ledger = LampSyncBundleLedgers.personalDeletions(in: written.bundle) else { return }
        try ModuleDatabase.shared.mergePersonalDeletionLedger(ledger)
        touched(try ModuleDatabase.shared.applyPersonalDeletionLedger())
        try LibrarySyncPass.settleEmptiedHighlightModules(source: source)
    }
}

// MARK: - Running it

extension LibrarySyncPass {
    private static let revisionsKey = "LibrarySync.bundleRevisions.v1"
    private static var scheduled: Task<Void, Never>?
    /// A pass was asked for while one ran, which may have read before the
    /// change it's for: another follows it, however either was started.
    private static var passAgain = false

    /// Another pass once the one running ends.
    static func passAgainAfterThisOne() {
        passAgain = true
    }

    /// The bundle revision this device last read or wrote at an endpoint, or
    /// nil while the endpoint still holds the archive.
    static func bundleRevision(for source: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: revisionsKey) as? [String: String])?[source]
    }

    private static func remember(_ revision: String?, for source: String, defaults: UserDefaults = .standard) {
        var revisions = (defaults.dictionary(forKey: revisionsKey) as? [String: String]) ?? [:]
        revisions[source] = revision
        defaults.set(revisions, forKey: revisionsKey)
    }

    static func isInUse(at storage: any LibraryEndpoint) -> Bool {
        bundleRevision(for: storage.librarySource) != nil
    }

    /// The revision of the archive this device last imported, so that until
    /// the Mac migrates, finding out costs one HEAD rather than the library.
    private static func knownArchiveRevision() -> String? {
        guard let data = UserDefaults.standard.data(forKey: ModuleSyncManager.portableArchiveImportStateKey),
              let state = try? JSONDecoder().decode(
                ModuleSyncManager.PortableArchiveImportState.self, from: data
              ) else { return nil }
        return state.revision
    }

    /// The whole pass, once the server holds the settings bundle. While it
    /// still holds the archive this answers `.notMigrated`, touching nothing,
    /// and the archive pass runs as before.
    @discardableResult
    static func runIfMigrated(storage: any LibraryEndpoint) async throws -> Outcome {
        // A one-time search index rebuild may be running on its own
        // connection, and this pass writes the content it indexes.
        await SearchIndexMaintenance.waitUntilFinished()
        let modules = ModuleSyncManager.shared
        guard !modules.isSyncing else {
            passAgain = true
            throw SyncError.alreadyRunning
        }
        modules.isSyncing = true
        defer {
            modules.isSyncing = false
            if passAgain {
                passAgain = false
                schedule(on: storage, after: 0)
            }
        }

        var pass = LibrarySyncPass(storage: storage, source: storage.librarySource)
        pass.makeParticipants = { bundle, versions in
            try UserSettingsSyncManager.shared.bundleParticipants(
                for: bundle, versions: versions.map(\.bundle), storage: storage
            )
        }
        // Only WebDAV ever held the archive; a folder library has none.
        let archiveRevision = storage is WebDAVModuleStorage && !isInUse(at: storage)
            ? knownArchiveRevision() : nil
        // Every pass, scheduled and polled ones too, says whether it got as
        // far as checking the library's files, for the missing-module marks.
        SyncCoordinator.shared.libraryCheckStarted(source: pass.source)
        let outcome: Outcome
        do {
            outcome = try await pass.run(knownArchiveRevision: archiveRevision)
        } catch {
            SyncCoordinator.shared.libraryCheckFailed(source: pass.source, reason: error.localizedDescription)
            throw error
        }
        // What it installed or changed is in the indexes, not yet their lists.
        await SearchIndexMaintenance.refreshWordLists()
        switch outcome {
        case .synced(let revision, _): remember(revision, for: pass.source)
        case .notMigrated, .phoneLibrary: remember(nil, for: pass.source)
        }
        print("[LibrarySync] \(outcome)")
        return outcome
    }

    /// A highlight set deleted on another device goes from here through the
    /// ledger, which leaves its module behind with nothing in it. The module
    /// goes too, and its file is tombstoned if this device synced it, so the
    /// library agrees the set has gone rather than offering it back.
    static func settleEmptiedHighlightModules(source: String) throws {
        for id in try ModuleDatabase.shared.removeHighlightModulesWithoutSets() {
            let path = "\(LampSyncContentKind.highlights.folder)/\(id).lamp"
            if try ModuleDatabase.shared.syncFileRecord(source: source, path: path) != nil {
                try ModuleDatabase.shared.recordSyncLocalDeletion(source: source, path: path)
            }
        }
    }

    private static let archiveJudgementsKey = "LibrarySync.archiveJudgements.v1"

    /// Whether a library not moved yet was kept only by this device, which
    /// may then offer to move it. A folder is judged by its files. An archive
    /// is judged by what is in it, by core, once for each revision: it only
    /// changes when the device keeping it syncs, and a Mac's archive is told
    /// apart from its first entries.
    static func isThisDevicesOwnLibrary(
        in storage: Store, source: String, archiveRevision: String?
    ) async throws -> Bool {
        guard let archiveRevision else {
            return try await LampSyncSettingsStore.earlierLibrary(in: storage) == .phone
        }
        let token = LampSyncConditionalWrite.token(for: archiveRevision)
        let defaults = UserDefaults.standard
        var all = (defaults.dictionary(forKey: archiveJudgementsKey) as? [String: [String: String]]) ?? [:]
        if let judged = all[source]?[token] { return judged == "phone" }
        let phone = try await LampSyncSettingsStore.earlierLibrary(in: storage) == .phone
        all[source] = [token: phone ? "phone" : "mac"]
        defaults.set(all, forKey: archiveJudgementsKey)
        return phone
    }

    /// Moves a library only this device kept onto the settings bundle, once
    /// the person has agreed: claims it, then runs the pass, which adopts
    /// every file and compares it by value. Core refuses a library the Mac
    /// kept, writing nothing.
    @discardableResult
    static func movePhoneLibrary(storage: any LibraryEndpoint) async throws -> Outcome {
        _ = try await LampSyncSettingsStore.migratePhoneLibrary(in: storage)
        return try await runIfMigrated(storage: storage)
    }

    /// Whether this device holds anything the server has not seen: settings,
    /// a module waiting to go up, or a membership change.
    static func hasLocalWork(at storage: any LibraryEndpoint) -> Bool {
        let database = ModuleDatabase.shared
        if UserDatabase.shared.hasUnsyncedChanges { return true }
        if SharedPreferenceArchiveSync.hasLocalChanges(
            source: UserSettingsSyncManager.shared.bundleSource(for: storage)
        ) { return true }
        if ModuleType.allCases.contains(where: {
            !((try? database.pendingModulePublications(type: $0).isEmpty) ?? true)
        }) { return true }
        if !((try? database.pendingManifestChanges(source: storage.librarySource).isEmpty) ?? true) { return true }
        return hasUnsentReviews(source: storage.librarySource) || hasUnsentDocuments(source: storage.librarySource)
    }

    /// A writing's document unlike what this device last sent or took in for
    /// it, written here or kept as a copy beside a download, or sent but not
    /// yet in a bundle the other devices read.
    static func hasUnsentDocuments(source: String) -> Bool {
        guard let held = try? documentStore.held(), !held.isEmpty,
              let records = try? ModuleDatabase.shared.libraryRecords(source: source) else { return false }
        return held.contains { path, url in
            guard let digest = try? LampSyncContentRevision.digest(forFileAt: url) else { return false }
            let record = records.record(path, in: source)
            return record?.uploadedDigest != digest || record?.pendingRevision != nil
        }
    }

    /// A writing's review marks unlike what this device last sent or took in
    /// for them: a clear or a mark made here, or a merge of a download with
    /// marks the server lacked, which goes back up.
    static func hasUnsentReviews(source: String) -> Bool {
        let reviews = reviewStore
        guard let paths = try? reviews.paths(), !paths.isEmpty,
              let records = try? ModuleDatabase.shared.libraryRecords(source: source) else { return false }
        return paths.contains { path in
            guard let digest = try? LampSyncContentRevision.digest(forFileAt: reviews.rootURL.appendingPathComponent(path))
            else { return false }
            return records.record(path, in: source)?.uploadedDigest != digest
        }
    }

    /// Whether a writing isn't at the endpoint `source` names as this device
    /// holds it: its collection, or a file kept with it, differs from what
    /// the records say was sent there or taken from there, or was sent but
    /// isn't yet in a bundle the other devices read. Judged at that endpoint,
    /// so a collection sent only to an earlier server, or a picture whose
    /// upload failed in a pass that sent the rest, still is.
    nonisolated static func hasUnsentWriting(
        _ writingID: String, inModule moduleID: String, source: String
    ) -> Bool {
        let database = ModuleDatabase.shared
        guard let module = try? database.getModule(id: moduleID) else { return false }
        guard let records = try? database.libraryRecords(source: source),
              let queued = try? database.pendingManifestChanges(source: source),
              let exported = exportDigest(ofCollection: module.id)
        else { return true }
        let unlisted = Set(queued.map(\.path))
        func unsent(_ path: String, digest: String) -> Bool {
            records.changedSinceUpload(path, in: source, digest: digest)
                || records.record(path, in: source)?.pendingRevision != nil
                || unlisted.contains(path)
        }
        let collection = "\(ModuleType.devotional.libraryFolder)/\(moduleID).lamp"
        if unsent(collection, digest: exported) { return true }
        // Its own documents, the outline and notes the assistant reads, and
        // any the writer deleted that the server still has.
        let folder = LampWritingWorkspaceLayout.directoryName(for: writingID)
        guard let held = try? documentStore.documents(writingID: writingID) else { return true }
        for document in held {
            guard let path = try? LampWritingWorkspaceLayout.documentPath(folder: folder, name: document.name)
            else { continue }
            if unsent(path, digest: LampSyncContentRevision.digest(for: document.data)) { return true }
        }
        if unlisted.contains(where: { LampWritingWorkspaceLayout.document(ofPath: $0)?.folder == folder }) {
            return true
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = LampSyncFolderLayout.devotionalMediaDirectory
        let own = "\(directory)/\(moduleID)/\(writingID)/"
        return mediaFiles(in: documents, directory: directory).contains { path, url in
            guard path.hasPrefix(own) else { return false }
            guard let digest = try? LampSyncContentRevision.digest(forFileAt: url) else { return true }
            return unsent(path, digest: digest)
        }
    }

    /// Each collection's export digest, with the change count it was taken
    /// at: asked again with nothing changed, the collection isn't exported.
    nonisolated private static let collectionDigests = NSLock()
    nonisolated(unsafe) private static var collectionDigestsByID: [String: (changes: Int64, digest: String)] = [:]

    /// A collection's export digest, as a pass would send it. The count is
    /// read before the collection, so a change made while it's exported
    /// counts as after it.
    nonisolated private static func exportDigest(ofCollection moduleID: String) -> String? {
        let database = ModuleDatabase.shared
        guard let changes = try? database.devotionalCollectionChanges(moduleID: moduleID) else { return nil }
        collectionDigests.lock()
        let kept = collectionDigestsByID[moduleID]
        collectionDigests.unlock()
        if let kept, kept.changes == changes { return kept.digest }
        guard let module = try? database.getModule(id: moduleID),
              let exported = try? ModuleSyncManager.shared.exportDevotionalModuleToSQLite(module)
        else { return nil }
        let taken = digest(exported)
        collectionDigests.lock()
        collectionDigestsByID[moduleID] = (changes, taken)
        collectionDigests.unlock()
        return taken
    }

    /// A pass a few seconds from now, after a burst of edits settles.
    static func schedule(on storage: any LibraryEndpoint, after delay: TimeInterval = 3) {
        scheduled?.cancel()
        scheduled = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                try await runIfMigrated(storage: storage)
            } catch {
                // The poll comes round again; a pass already running has
                // the edit in hand or the next one will.
                print("[LibrarySync] scheduled pass did not run: \(error)")
            }
        }
    }
}

// MARK: - Removing a module

extension ModuleSyncManager {
    /// A module the user removed here, already gone from the database.
    ///
    /// Each file this device synced for it is recorded as deleted, and the
    /// next pass tombstones it and reaps the copy. Deleting the files
    /// directly would leave no record of the deletion: absence never deletes
    /// anything, so another device would put its copy back. A library not
    /// moved yet is not this device's to change.
    func removeFromLibrary(
        type: ModuleType, moduleId: String, storage: ModuleStorage?
    ) async {
        guard let storage else { return }
        if let endpoint = libraryEndpoint(for: storage), await LibrarySyncPass.isInUse(at: endpoint) {
            let source = endpoint.librarySource
            let folder = endpoint.directoryName(for: type)
            let synced = ((try? ModuleDatabase.shared.syncFileRecords(source: source)) ?? []).map(\.path)
                .filter {
                    $0.hasPrefix(folder + "/")
                        && LampSyncFolderLayout.remoteModuleID(of: $0) == moduleId
                        && LampSyncLocalDeletion.target(of: $0).isAllowed
                }
            // Only what this device synced: a path it never had a record of
            // is not its to tombstone.
            for path in synced {
                try? ModuleDatabase.shared.recordSyncLocalDeletion(source: source, path: path)
            }
            await LibrarySyncPass.schedule(on: endpoint)
        }
    }
}

// MARK: - A module imported here

extension ModuleSyncManager {
    /// A module file the user chose to import here goes up while its bytes
    /// are in hand: an installed module keeps no file of its own, so this is
    /// the only time this device could send it. Importing is a choice to use
    /// this copy, so it replaces whatever the server has at the path, written
    /// under the revision there now. The upload is recorded for the manifest.
    func publishImportedFile(
        _ data: Data, type: ModuleType, moduleId: String, fileName: String,
        to storage: any LibraryEndpoint
    ) async throws {
        let path = "\(storage.directoryName(for: type))/\(fileName)"
        let source = storage.librarySource
        let current = try await storage.revision(path: path)
        let revision = try await LampSyncConditionalWrite.write(
            data, to: path, in: storage, condition: current.map { .ifRevision($0) } ?? .ifAbsent
        ).revision(at: path)
        if type == .translation {
            if var translation = try ModuleDatabase.shared.getTranslation(id: moduleId) {
                translation.fileHash = revision
                try ModuleDatabase.shared.saveTranslation(translation)
            }
        } else if var module = try ModuleDatabase.shared.getModule(id: moduleId) {
            module.fileHash = revision
            try ModuleDatabase.shared.saveModule(module)
        }
        try ModuleDatabase.shared.recordSyncUpload(
            source: source, path: path, digest: LibrarySyncPass.digest(data),
            revision: revision, replacing: current
        )
        await LibrarySyncPass.schedule(on: storage)
    }
}


extension LampSyncConditionalWrite.Outcome {
    /// The revision a write produced. Refused, it is the refusal the plan
    /// expects; taken but not yet shown back, nothing is recorded and the
    /// module stays pending, so the next pass finds the file and settles it.
    func revision(at path: String) throws -> String {
        switch self {
        case .written(let revision): return revision
        case .writtenUnconfirmed: throw LampSyncConditionalWrite.Unconfirmed(path: path)
        case .refused: throw LampSyncConditionalWrite.WriteError.conflict
        }
    }
}
