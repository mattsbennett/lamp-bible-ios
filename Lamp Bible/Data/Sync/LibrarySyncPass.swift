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

    var errorDescription: String? {
        switch self {
        case .incomplete(let failures):
            let first = failures.first ?? ""
            return failures.count > 1
                ? "Some of the library didn't sync: \(first), and \(failures.count - 1) more."
                : "Some of the library didn't sync: \(first)"
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
        /// person may move it, after updating their other devices. Until
        /// they do, it syncs as before.
        case phoneLibrary
        case synced(bundleRevision: String)
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
        defer { library.cleanUp() }
        var records = try database.libraryRecords(source: source)
        library.seedFolderRevisions(into: &records)
        let carried = try database.pendingManifestWrites(source: source)
        var ledger = DeletionLedgerParticipant(source: source, contribution: .init(personal: .init()))
        var participants: [any SettingsBundleParticipant] = []
        var prepared: Set<String> = []

        let engine = LampSyncBundlePass(store: storage, library: library, source: source)
        let outcome: LampSyncBundlePass.Outcome
        do {
            outcome = try await engine.run(
                gathering: { try library.gather() },
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
                    try receive(snapshot.bundle)
                    // This device's deletions, read here because the update's
                    // change only computes and may run again on a newer bundle.
                    ledger = DeletionLedgerParticipant(
                        source: source,
                        contribution: .init(personal: try database.personalDeletionLedger())
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
            try? database.saveLibraryRecords(records, source: source)
            throw error
        }
        try database.saveLibraryRecords(records, source: source)

        guard let written = outcome.written else { throw LampSyncSettingsStore.StoreError.tooManyAttempts }
        for participant in [ledger] + participants { try participant.committed(written) }
        try database.clearPendingManifestChanges(carried + library.carriedDeletions)

        if await olderDeviceIsWriting() {
            SyncCoordinator.shared.olderDeviceSyncing = true
        }
        if let unsupplied = try? unsuppliedAttachments(manifest: written.bundle.manifest) {
            SyncCoordinator.shared.unsuppliedAttachments = unsupplied
        }

        var failures = outcome.failures
        do {
            try await PresentationDeckSync.pull(from: storage, deletions: written.bundle.deckDeletions)
        } catch {
            failures.append("mirroring decks: \(error.localizedDescription)")
        }
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
        return .synced(bundleRevision: written.revision)
    }

    /// Deletions made elsewhere, before anything here is gathered: a library
    /// read before them would publish what it had just been told was gone.
    /// One no device can read is skipped, as the Mac skips it.
    private func receive(_ bundle: LampSyncSettingsBundle) throws {
        if let ledger = LampSyncBundleLedgers.personalDeletions(in: bundle) {
            try database.mergePersonalDeletionLedger(ledger)
            try database.applyPersonalDeletionLedger()
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

    /// What this device plans: modules and their media. Decks are the Mac's
    /// to publish and mirrored here as before; workspaces stay on the Mac.
    /// Pruning still sees every listed file, which core keeps to.
    static func isPlanned(_ kind: LampSyncFileKind?) -> Bool {
        switch kind {
        case .module, .devotionalMedia, .bookMedia: true
        case .deck, .deckAsset, .workspaceFile, nil: false
        }
    }

    static func confirmsByReading(_ kind: LampSyncFileKind) -> Bool {
        switch kind {
        case .module(let content): [.notes, .devotionals, .highlights].contains(content)
        case .devotionalMedia, .bookMedia: true
        case .deck, .deckAsset, .workspaceFile: false
        }
    }

    /// The module a media file belongs to, as a path in the library.
    static func modulePath(forMedia path: String) -> String? {
        guard let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return nil }
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia: return "\(LampSyncContentKind.devotionals.rawValue)/\(id).lamp"
        case .bookMedia: return "\(LampSyncContentKind.books.rawValue)/\(id).lamp"
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
        default: return nil
        }
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Attachments the writings name that neither this device nor the server
    /// holds, by library path. Writings still go up with them: every writing
    /// shares one file, so holding it back would stop them all, and the
    /// reference mends itself, since an attachment never changes at its path
    /// and goes up there the day it is back. One missing here but a member of
    /// the library is on the server, and leaves nothing to fix. The Mac
    /// reports by the same rule, from the same manifest.
    func unsuppliedAttachments(manifest: LampSyncLibraryManifest) throws -> [String] {
        try database.getAllModules()
            .filter { $0.type == .devotional && $0.isEditable }
            .flatMap { try modules.devotionalMediaItems(moduleId: $0.id, forExport: true) }
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
    /// What each module path held here is, as the database knows it: a
    /// module's file may be named other than by its ID.
    private var heldModules: [String: (type: ModuleType, id: String)] = [:]
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
            gathered.local.append(LampSyncLocalFile(
                path: path, kind: .module(kind), url: url, digest: LibrarySyncPass.digest(data)
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

        // Media only for modules in the library: the cache also holds media
        // for books that came with the app, which are no one's to upload.
        let libraryModules = Set(heldModules.keys).union(manifest.members.map(\.path))
        for (path, url) in localMedia() {
            guard manifest.entry(at: path) != nil
                    || LibrarySyncPass.modulePath(forMedia: path).map(libraryModules.contains) == true,
                  let kind = LampSyncFolderLayout.kind(of: path),
                  let digest = try? LampSyncContentRevision.digest(forFileAt: url) else { continue }
            gathered.local.append(LampSyncLocalFile(path: path, kind: kind, url: url, digest: digest))
        }

        carriedDeletions = try database.pendingManifestChanges(source: source).filter { $0.change == .delete }
        gathered.deletedLocally = Dictionary(
            carriedDeletions.map { ($0.path, $0.at) }, uniquingKeysWith: { max($0, $1) }
        )
        return gathered
    }

    // MARK: LampSyncPassLibrary

    func install(_ path: String, from url: URL) async throws -> String? {
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia, .bookMedia:
            guard let local = localURL(forMedia: path) else { return nil }
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.copyItem(at: url, to: local)
            return nil
        case .module:
            return try await installModule(path, from: url)
        default:
            return nil
        }
    }

    /// Both sides changed: each is merged by value into the library, and
    /// what the merge leaves goes back up, as the Mac sends back its own.
    func reconcile(_ downloaded: [String: URL]) async throws -> [String: URL] {
        var republish: [String: URL] = [:]
        for (path, url) in downloaded.sorted(by: { $0.key < $1.key }) {
            _ = try await installModule(path, from: url)
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
        case .devotionalMedia, .bookMedia:
            if let url = localURL(forMedia: path) { try? FileManager.default.removeItem(at: url) }
        case .module:
            guard let held = heldModules[path] else { return }
            if held.type == .translation {
                try database.deleteTranslation(id: held.id)
            } else {
                try database.deleteAllEntriesForModule(moduleId: held.id)
                try database.deleteModule(id: held.id)
            }
        default:
            return
        }
    }

    // MARK: Taking a module in

    /// Returns what this device holds at the path afterwards, as it would
    /// publish it, for an editable collection taken in whole; nil when that
    /// is the bytes that arrived.
    private func installModule(_ path: String, from url: URL) async throws -> String? {
        guard let type = LibrarySyncPass.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return nil }
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
        let fileInfo = ModuleFileInfo(id: id, type: type, filePath: fileName, fileHash: nil, modificationDate: nil)
        try await modules.importRemoteModuleSnapshot(
            fileInfo: fileInfo, type: type,
            snapshot: LampSyncRemoteFile(data: data, revision: nil), storage: storage
        )
        guard editable, let module = try database.getModule(id: id),
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

    private func exportedBytes(_ module: Module) throws -> Data {
        switch module.type {
        case .notes: try modules.exportNoteModuleToSQLite(module)
        case .devotional: try modules.exportDevotionalModuleToSQLite(module)
        case .highlights: try modules.exportHighlightModuleToSQLite(module)
        default: throw ModuleSyncError.moduleNotEditable(module.id)
        }
    }

    private func installedReadOnlyModules() throws -> [(ModuleType, String, String, String?)] {
        let translations = try database.getAllTranslations(bundledOnly: false).compactMap {
            translation -> (ModuleType, String, String, String?)? in
            guard let filePath = translation.filePath, !filePath.isEmpty else { return nil }
            return (.translation, translation.id, filePath, translation.fileHash)
        }
        let others = try database.getAllModules().compactMap { module -> (ModuleType, String, String, String?)? in
            guard !module.isEditable, module.type != .translation, !module.filePath.isEmpty else { return nil }
            return (module.type, module.id, module.filePath, module.fileHash)
        }
        return translations + others
    }

    /// Media present on this device, by server path.
    private func localMedia() -> [String: URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var media: [String: URL] = [:]
        for (localRoot, remoteRoot) in [
            (LampSyncFolderLayout.devotionalMediaDirectory, LampSyncFolderLayout.devotionalMediaDirectory),
            ("ModuleMediaCache", LampSyncFolderLayout.bookMediaDirectory),
        ] {
            let root = documents.appendingPathComponent(localRoot, isDirectory: true)
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }
            for case let url as URL in files
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let relative = url.path.dropFirst(root.path.count).drop { $0 == "/" }
                media["\(remoteRoot)/\(relative)"] = url
            }
        }
        return media
    }

    private func localURL(forMedia path: String) -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia:
            return documents.appendingPathComponent(path)
        case .bookMedia:
            let rest = path.dropFirst(LampSyncFolderLayout.bookMediaDirectory.count + 1)
            return documents.appendingPathComponent("ModuleMediaCache").appendingPathComponent(String(rest))
        default:
            return nil
        }
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

    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        try contribution.apply(to: &bundle)
    }

    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
        guard let ledger = LampSyncBundleLedgers.personalDeletions(in: written.bundle) else { return }
        try ModuleDatabase.shared.mergePersonalDeletionLedger(ledger)
        try ModuleDatabase.shared.applyPersonalDeletionLedger()
        try LibrarySyncPass.settleEmptiedHighlightModules(source: source)
    }
}

// MARK: - Running it

extension LibrarySyncPass {
    private static let revisionsKey = "LibrarySync.bundleRevisions.v1"
    private static var scheduled: Task<Void, Never>?

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
        guard !modules.isSyncing else { throw SyncError.alreadyRunning }
        modules.isSyncing = true
        defer { modules.isSyncing = false }

        var pass = LibrarySyncPass(storage: storage, source: storage.librarySource)
        pass.makeParticipants = { bundle, versions in
            try UserSettingsSyncManager.shared.bundleParticipants(
                for: bundle, versions: versions.map(\.bundle), storage: storage
            )
        }
        // Only WebDAV ever held the archive; a folder library has none.
        let archiveRevision = storage is WebDAVModuleStorage && !isInUse(at: storage)
            ? knownArchiveRevision() : nil
        let outcome = try await pass.run(knownArchiveRevision: archiveRevision)
        switch outcome {
        case .synced(let revision): remember(revision, for: pass.source)
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
            let path = "\(LampSyncContentKind.highlights.rawValue)/\(id).lamp"
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
        return !((try? database.pendingManifestChanges(source: storage.librarySource).isEmpty) ?? true)
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
