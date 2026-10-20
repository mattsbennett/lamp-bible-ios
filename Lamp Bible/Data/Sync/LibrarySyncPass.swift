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

@MainActor
struct LibrarySyncPass {
    enum Outcome: Equatable {
        /// The server still holds the archive: the Mac has not migrated, so
        /// the archive pass runs instead. The phone never migrates.
        case notMigrated(archiveRevision: String?)
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

    /// A participant prepared against one bundle met a newer one at the
    /// write: prepare again against what is there now.
    struct BundleMoved: Error {}

    private var database: ModuleDatabase { .shared }
    private var modules: ModuleSyncManager { .shared }

    func run(knownArchiveRevision: String? = nil) async throws -> Outcome {
        let snapshot: LampSyncSettingsStore.Snapshot
        do {
            // A truly empty library is claimed with an empty bundle before
            // anything else: once a module file is there without one, core
            // reads the library as an earlier one waiting for the Mac.
            snapshot = try await LampSyncSettingsStore.readOrClaim(
                from: storage, knownArchiveRevision: knownArchiveRevision
            )
        } catch LampSyncSettingsStore.StoreError.notMigrated(let revision) {
            return .notMigrated(archiveRevision: revision)
        }
        let bundle = snapshot.bundle

        // Deletions made elsewhere, before anything here is compared or sent.
        if let data = bundle.personalDeletions {
            try database.mergePersonalDeletionLedger(LampPersonalDeletionLedger.decode(data))
            try database.applyPersonalDeletionLedger()
        }

        // Decks are the Mac's to publish, and mirrored here as before; the
        // plan covers modules and their media.
        let listing = try await LampSyncFilePlan.listing(in: storage, manifest: bundle.manifest)
            .filter { Self.isPlanned(LampSyncFolderLayout.kind(of: $0.key)) }
        let held = try heldFiles(manifest: bundle.manifest, listing: listing)
        let plan = LampSyncFilePlan.plan(
            manifest: bundle.manifest,
            local: held.values.map(\.local),
            deletedLocally: try database.pendingManifestDeletions(source: source),
            listing: listing
        )

        var firstError: Error?
        func attempt(_ what: String, _ body: () async throws -> Void) async {
            do { try await body() } catch {
                print("[LibrarySync] \(what) failed: \(error)")
                if firstError == nil { firstError = error }
            }
        }
        for path in plan.deleteLocally {
            await attempt("removing \(path)") { try removeLocally(path, held: held[path]) }
        }
        for path in plan.downloads where plan.merge[path] == nil {
            await attempt("downloading \(path)") { try await install(path, revision: listing[path]) }
        }
        for (path, revision) in plan.merge.sorted(by: { $0.key < $1.key }) {
            await attempt("merging \(path)") { try await merge(path, revision: revision) }
        }
        for (path, condition) in plan.uploads.sorted(by: { $0.key < $1.key }) {
            await attempt("uploading \(path)") {
                try await upload(path, condition: condition, held: held[path])
            }
        }
        await attempt("mirroring decks") {
            try await PresentationDeckSync.pull(from: storage, deletions: bundle.deckDeletions)
        }

        // One bundle write for the whole pass: membership, the deletion
        // ledger, settings and preferences together.
        let carried = try database.pendingManifestChanges(source: source)
        let membership = ManifestParticipant(
            source: source, carried: carried, adopt: plan.adopt, present: Set(listing.keys)
        )
        let written = try await writeBundle(
            fixed: [membership, DeletionLedgerParticipant()], from: snapshot
        )

        for (path, revision) in plan.reap.sorted(by: { $0.key < $1.key }) {
            await attempt("reaping \(path)") {
                try await storage.delete(path: path, condition: .ifRevision(revision))
            }
        }
        if let firstError { throw firstError }
        return .synced(bundleRevision: written.revision)
    }

    /// The pass's one bundle write, with every participant in it.
    ///
    /// Versions iCloud kept beside the bundle are folded in by core's merge
    /// and resolved by the write, but only those the participants were
    /// prepared with: one that landed since would be resolved without this
    /// device having merged its settings, so the pass prepares again.
    func writeBundle(
        fixed: [any SettingsBundleParticipant],
        from read: LampSyncSettingsStore.Snapshot?
    ) async throws -> LampSyncSettingsStore.Snapshot {
        var latest = read
        for _ in 0..<3 {
            let versions = latest?.versions ?? []
            let prepared = Set(versions.map(\.revision))
            let all = fixed + (try makeParticipants(latest?.bundle, versions))
            do {
                let written = try await LampSyncSettingsStore.update(
                    in: storage,
                    mergingVersion: { bundle, version in
                        guard prepared.contains(version.revision) else { throw BundleMoved() }
                        try bundle.merge(version: version.bundle)
                    }
                ) { bundle in
                    let now = ModuleDatabase.nowMilliseconds()
                    for participant in all { try participant.change(&bundle, now: now) }
                }
                for participant in all { try participant.committed(written) }
                return written
            } catch is BundleMoved {
                latest = try await LampSyncSettingsStore.read(from: storage)
            }
        }
        throw LampSyncSettingsStore.StoreError.tooManyAttempts
    }

    static func isPlanned(_ kind: LampSyncFileKind?) -> Bool {
        switch kind {
        case .module, .devotionalMedia, .bookMedia: true
        case .deck, .deckAsset, .workspaceFile, nil: false
        }
    }

    // MARK: - What this device holds

    /// A file this device can produce, and where it comes from.
    struct Held {
        enum Origin {
            /// Notes, writings and highlights: exported from the database.
            case editable(Module)
            /// Installed from the server and never changed here.
            case installed(type: ModuleType, id: String)
            case media(URL)
        }
        let local: LampSyncFilePlan.Local
        let origin: Origin
    }

    /// Everything this device can offer the plan. A module it cannot produce
    /// bytes for is left out unless the server already has it: offered, it
    /// would be planned as an upload this device has nothing to send for.
    func heldFiles(
        manifest: LampSyncLibraryManifest,
        listing: [String: String]
    ) throws -> [String: Held] {
        let records = Dictionary(
            uniqueKeysWithValues: try database.syncFileRecords(source: source).map { ($0.path, $0) }
        )
        var held: [String: Held] = [:]

        for module in try database.getAllModules() where module.isEditable
            && [.notes, .devotional, .highlights].contains(module.type) {
            let path = remotePath(type: module.type, fileName: "\(module.id).lamp")
            let digest = Self.digest(try exportedBytes(module))
            let record = records[path]
            held[path] = Held(
                local: .init(
                    path: path,
                    changedSinceUpload: record?.hasChangedSinceUpload(exportDigest: digest) ?? true,
                    lastRevision: record?.lastRevision,
                    savedAt: try savedAt(module)
                ),
                origin: .editable(module)
            )
        }

        for (type, id, fileName) in try installedReadOnlyModules() {
            let path = remotePath(type: type, fileName: fileName)
            guard held[path] == nil,
                  listing[path] != nil || manifest.entry(at: path) != nil else { continue }
            held[path] = Held(
                local: .init(
                    path: path, changedSinceUpload: false,
                    lastRevision: records[path]?.lastRevision, savedAt: nil
                ),
                origin: .installed(type: type, id: id)
            )
        }

        // Media only for modules in the library: the cache also holds media
        // for books that came with the app, which are no one's to upload.
        let libraryModules = Set(held.keys).union(listing.keys).union(manifest.members.map(\.path))
        for (path, url) in localMedia() where held[path] == nil {
            guard manifest.entry(at: path) != nil
                    || Self.modulePath(forMedia: path).map(libraryModules.contains) == true else { continue }
            held[path] = Held(
                local: .init(
                    path: path, changedSinceUpload: false,
                    lastRevision: records[path]?.lastRevision, savedAt: nil
                ),
                origin: .media(url)
            )
        }
        return held
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

    private func installedReadOnlyModules() throws -> [(ModuleType, String, String)] {
        let translations = try database.getAllTranslations(bundledOnly: false).compactMap {
            translation -> (ModuleType, String, String)? in
            guard let filePath = translation.filePath, !filePath.isEmpty else { return nil }
            return (.translation, translation.id, filePath)
        }
        let others = try database.getAllModules().compactMap { module -> (ModuleType, String, String)? in
            guard !module.isEditable, module.type != .translation, !module.filePath.isEmpty else { return nil }
            return (module.type, module.id, module.filePath)
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

    // MARK: - Carrying out the plan

    private func remotePath(type: ModuleType, fileName: String) -> String {
        "\(storage.directoryName(for: type))/\(fileName)"
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

    private func exportedBytes(_ module: Module) throws -> Data {
        switch module.type {
        case .notes: try modules.exportNoteModuleToSQLite(module)
        case .devotional: try modules.exportDevotionalModuleToSQLite(module)
        case .highlights: try modules.exportHighlightModuleToSQLite(module)
        default: throw ModuleSyncError.moduleNotEditable(module.id)
        }
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func install(_ path: String, revision: String?) async throws {
        switch LampSyncFolderLayout.kind(of: path) {
        case .devotionalMedia, .bookMedia:
            try await installMedia(path)
        case .module:
            try await installModule(path, revision: revision)
            try recordInstall(path)
        default:
            return
        }
    }

    private func installModule(_ path: String, revision: String?) async throws {
        guard let type = Self.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return }
        let fileName = String(path.dropFirst(storage.directoryName(for: type).count + 1))
        let fileInfo = ModuleFileInfo(
            id: id, type: type, filePath: fileName, fileHash: revision, modificationDate: nil
        )
        // The first pass after the switch has no folder revisions recorded,
        // so every installed module is fetched once. Most are the very bytes
        // the archive already installed; for those, recording the revision
        // is enough, and reinstalling would rewrite every verse and its
        // search index for nothing.
        if ![.notes, .devotional, .highlights].contains(type),
           try database.syncFileRecord(source: source, path: path) == nil,
           let installed = Self.archivedDigests()[id] {
            let snapshot = try await storage.readModuleSnapshot(type: type, fileName: fileName)
            if Self.digest(snapshot.data) == installed {
                try recordFileHash(type: type, id: id, revision: snapshot.revision)
                return
            }
            try await modules.importRemoteModuleSnapshot(
                fileInfo: fileInfo, type: type, snapshot: snapshot, storage: storage
            )
            return
        }
        try await modules.importModuleFromCloud(fileInfo: fileInfo, type: type, storage: storage)
    }

    /// What the archive import installed, by module: the digest of each
    /// module's bytes as they were in the archive.
    private static func archivedDigests() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: ModuleSyncManager.portableArchiveImportStateKey),
              let state = try? JSONDecoder().decode(
                ModuleSyncManager.PortableArchiveImportState.self, from: data
              ) else { return [:] }
        return Dictionary(state.modules.map { ($0.id, $0.digest) }, uniquingKeysWith: { first, _ in first })
    }

    private func recordFileHash(type: ModuleType, id: String, revision: String?) throws {
        if type == .translation {
            if var translation = try database.getTranslation(id: id) {
                translation.fileHash = revision
                try database.saveTranslation(translation)
            }
        } else if var module = try database.getModule(id: id) {
            module.fileHash = revision
            try database.saveModule(module)
        }
    }

    /// After an install with nothing of this device's own pending, its export
    /// is what it now agrees with the server on; with something pending, the
    /// upload record stays, so the change still goes up.
    private func recordInstall(_ path: String) throws {
        let revision = try currentRevision(of: path)
        var exportDigest: String?
        if let type = Self.moduleType(of: path), [.notes, .devotional, .highlights].contains(type),
           let id = LampSyncFolderLayout.remoteModuleID(of: path),
           let module = try database.getModule(id: id),
           !(try database.pendingModulePublications(type: type).contains(id)) {
            exportDigest = Self.digest(try exportedBytes(module))
        }
        try database.recordSyncInstall(
            source: source, path: path, revision: revision, exportDigest: exportDigest
        )
    }

    private func currentRevision(of path: String) throws -> String? {
        guard let type = Self.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path) else { return nil }
        if type == .translation {
            return try database.getAllTranslations(bundledOnly: false).first { $0.id == id }?.fileHash
        }
        return try database.getModule(id: id)?.fileHash
    }

    /// Both sides changed: the import merges by value, with the ledger
    /// applied, and what that leaves this device holding goes back up under
    /// the revision it merged.
    private func merge(_ path: String, revision: String) async throws {
        try await installModule(path, revision: revision)
        guard let type = Self.moduleType(of: path),
              let id = LampSyncFolderLayout.remoteModuleID(of: path),
              let module = try database.getModule(id: id) else { return }
        if try database.pendingModulePublications(type: type).contains(id) {
            try await uploadModule(path, module: module, condition: .ifRevision(revision), replacing: revision)
        } else {
            try recordInstall(path)
        }
    }

    private func upload(
        _ path: String, condition: LampSyncWriteCondition, held: Held?
    ) async throws {
        guard let held else { return }
        switch held.origin {
        case .editable(let module):
            try await uploadModule(path, module: module, condition: condition, replacing: held.local.lastRevision)
        case .media(let url):
            try await uploadMedia(path, from: url)
        case .installed:
            // Never planned: an installed module offered is unchanged, and
            // one the server lacks is not offered.
            return
        }
    }

    private func uploadModule(
        _ path: String, module: Module, condition: LampSyncWriteCondition, replacing: String?
    ) async throws {
        let data = try exportedBytes(module)
        let revision = try await LampSyncConditionalWrite.writeAndConfirm(
            data, to: path, in: storage, condition: condition
        )
        var updated = module
        updated.fileHash = revision
        updated.filePath = "\(module.id).lamp"
        updated.lastSynced = Int(Date().timeIntervalSince1970)
        try database.saveModule(updated)
        try database.recordSyncUpload(
            source: source, path: path, digest: Self.digest(data),
            revision: revision, replacing: replacing
        )
        // Its media goes up as files of its own, planned like any other, so
        // each is recorded in the manifest.
        try database.clearPendingModulePublication(moduleId: module.id)
    }

    // MARK: Media

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

    /// Media never changes at a path, so a copy is fetched only where this
    /// device has none, and a 404 means it is not uploaded yet.
    private func installMedia(_ path: String) async throws {
        guard let url = localURL(forMedia: path) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let file = try await storage.read(path: path, into: url) else { return }
        try database.recordSyncInstall(source: source, path: path, revision: file.revision, exportDigest: nil)
    }

    private func uploadMedia(_ path: String, from url: URL) async throws {
        let revision: String?
        do {
            revision = try await storage.write(fileAt: url, to: path, condition: .ifAbsent)
        } catch where LampSyncConditionalWrite.isRefusal(error) {
            // Already there: media is the same bytes at a path, so it's done.
            revision = try await storage.revision(path: path)
        }
        try database.recordSyncUpload(
            source: source, path: path, digest: nil, revision: revision, replacing: nil
        )
    }

    // MARK: Deletions from elsewhere

    /// Deleted on another device after this copy was saved. Nothing is
    /// recorded here: the deletion is already in the manifest.
    private func removeLocally(_ path: String, held: Held?) throws {
        switch held?.origin {
        case .editable(let module):
            try database.deleteAllEntriesForModule(moduleId: module.id)
            try database.deleteModule(id: module.id)
        case .installed(let type, let id):
            if type == .translation {
                try database.deleteTranslation(id: id)
            } else {
                try database.deleteAllEntriesForModule(moduleId: id)
                try database.deleteModule(id: id)
            }
        case .media(let url):
            try? FileManager.default.removeItem(at: url)
        case nil:
            break
        }
        try database.removeSyncFileRecord(source: source, path: path)
    }
}

// MARK: - Bundle participants

/// Membership: this pass's uploads and this device's deletions, files found
/// on the server that nobody had recorded, and tombstones whose time is up.
@MainActor
struct ManifestParticipant: SettingsBundleParticipant {
    let source: String
    /// Read before the write, and cleared only once a written bundle has them.
    let carried: [SyncPendingManifestChange]
    let adopt: [String: String]
    /// What the pass found listed; a pass that did not list prunes nothing.
    let present: Set<String>?

    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        var manifest = bundle.manifest
        for (path, revision) in adopt.sorted(by: { $0.key < $1.key }) {
            manifest = try manifest.adopting(path, revision: revision, at: now)
        }
        for change in carried {
            switch change.change {
            case .write:
                manifest = try manifest.recordingWrite(
                    change.path, revision: change.revision, replacing: change.replacing,
                    at: max(change.at, now)
                )
            case .delete:
                manifest = try manifest.removing(change.path, at: change.at, revision: change.revision)
            }
        }
        bundle.manifest = present.map { manifest.pruned(now: now, present: $0) } ?? manifest
    }

    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
        try ModuleDatabase.shared.clearPendingManifestChanges(carried)
    }
}

/// Item deletions: this device's ledger joined with the bundle's, and what
/// the join says is gone removed here too.
@MainActor
struct DeletionLedgerParticipant: SettingsBundleParticipant {
    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        var ledger = try bundle.personalDeletions.map(LampPersonalDeletionLedger.decode)
            ?? LampPersonalDeletionLedger()
        ledger.merge(try ModuleDatabase.shared.personalDeletionLedger())
        guard !ledger.isEmpty else { return }
        bundle.personalDeletions = try ledger.encoded()
    }

    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {
        guard let data = written.bundle.personalDeletions else { return }
        try ModuleDatabase.shared.mergePersonalDeletionLedger(LampPersonalDeletionLedger.decode(data))
        try ModuleDatabase.shared.applyPersonalDeletionLedger()
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
        case .notMigrated: remember(nil, for: pass.source)
        }
        print("[LibrarySync] \(outcome)")
        return outcome
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
    /// With the settings bundle in use, each file this device synced for it
    /// is recorded as deleted, and the next pass tombstones it and reaps the
    /// copy. Deleting the files directly, as before, would leave no record
    /// of the deletion: absence never deletes anything, so another device
    /// would put its copy back. Without the bundle, the folder copies go as
    /// they always have.
    func removeFromLibrary(
        type: ModuleType, moduleId: String, fileNames: [String], storage: ModuleStorage?
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
            return
        }
        for fileName in fileNames {
            try? await storage.deleteModuleFile(type: type, fileName: fileName)
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
        let revision = try await LampSyncConditionalWrite.writeAndConfirm(
            data, to: path, in: storage, condition: current.map { .ifRevision($0) } ?? .ifAbsent
        )
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
