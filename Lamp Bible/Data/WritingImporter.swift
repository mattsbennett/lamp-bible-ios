//
//  WritingImporter.swift
//  Lamp Bible
//

import CryptoKit
import Foundation
import GRDB
import LampCore
import LampModuleKit

/// Writing imported from Markdown, as the Mac imports it: core reads the
/// files and plans what importing them would do, the person chooses in
/// `WritingImportSheet`, and core writes what they chose. A file with no id
/// of its own takes one from its path, so importing it again updates the
/// writing rather than adding a copy.
enum WritingImporter {
    /// Reads and plans the files or folders chosen. Nothing is written. The
    /// text is read here, but pictures and recordings are copied in only when
    /// the plan is applied, so `access` keeps chosen files open until then.
    static func plan(
        _ urls: [URL], sourceName: String? = nil, access: SecurityScopedAccess? = nil
    ) async throws -> PendingWritingImport {
        let name = sourceName ?? Self.sourceName(of: urls)
        let (plan, planned) = try await Task.detached(priority: .userInitiated) {
            let files = try urls.flatMap { try LampWritingImport.files(at: $0) }
            let store = try PhoneWritingImportStore(newWritingModuleID: WritingCollection.id)
            let plan = try await LampWritingImport.plan(files, in: store, comparingWithLibrary: true)
            return (plan, store.seen)
        }.value
        return PendingWritingImport(sourceName: name, plan: plan, planned: planned, access: access)
    }

    /// Writes the chosen items, new writings into `moduleID`, and publishes
    /// each collection that changed.
    @discardableResult
    static func apply(
        _ pending: PendingWritingImport, selecting itemIDs: Set<String>, into moduleID: String
    ) async throws -> LampWritingImportResult {
        let plan = pending.plan
        let store = try PhoneWritingImportStore(newWritingModuleID: moduleID, planned: pending.planned)
        let outcome: Result<LampWritingImportResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try await LampWritingImport.apply(plan, selecting: itemIDs, to: store))
            } catch {
                return .failure(error)
            }
        }.value
        // Held to here: the files chosen stay open until their media is in.
        withExtendedLifetime(pending.access) {}
        // Each writing is saved as it goes, so what went in before a later
        // file failed is published too.
        for id in store.touchedModuleIDs.sorted() {
            do {
                try await ModuleSyncManager.shared.exportModule(id: id)
            } catch {
                print("[WritingImport] Export of \(id) failed: \(error)")
            }
        }
        return try outcome.get()
    }

    /// What the sheet calls an import: the folder, the file, or how many.
    static func sourceName(of urls: [URL]) -> String {
        guard urls.count == 1, let url = urls.first else { return "\(urls.count) Files" }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The toast's words for what was written, and for what wasn't.
    static func summary(of result: LampWritingImportResult) -> (title: String, message: String?) {
        let count = result.imported.count
        let title = count == 1 ? "1 writing imported" : "\(count) writings imported"
        var notes: [String] = []
        let refused = result.refused.count
        if refused > 0 {
            notes.append(refused == 1
                ? "1 was changed in Lamp meanwhile and was left as it is"
                : "\(refused) were changed in Lamp meanwhile and were left as they are")
        }
        if let first = result.failed.first {
            notes.append(result.failed.count == 1
                ? "“\(first.item.title)” couldn’t be imported: \(first.reason)"
                : "\(result.failed.count) couldn’t be imported, “\(first.item.title)” first: \(first.reason)")
        }
        notes += result.problems
        return (title, notes.isEmpty ? nil : notes.joined(separator: ". "))
    }

    /// Whether every writing chosen went in.
    static func isComplete(_ result: LampWritingImportResult) -> Bool {
        result.refused.isEmpty && result.failed.isEmpty
    }
}

/// The iCloud Documents/Import/Writing folder, read as an import offered
/// for review. Nothing in it is written or deleted: a file stays where the
/// person put it, and importing the folder again updates what it made.
enum WritingDropFolder {
    /// What the folder held when the person last saw it planned, so a sheet
    /// they cancelled isn't put in front of them again until it changes.
    static let reviewedKey = "writingDropFolder.reviewedFingerprint"

    /// The folder's import, if it holds anything new to choose and the
    /// person hasn't already been shown it as it is.
    static func pendingImport() async -> PendingWritingImport? {
        guard await SyncCoordinator.shared.settings.backend.usesICloudDocuments,
              let folder = DevotionalImportExportManager.shared.importDirectoryURL else { return nil }
        return await pendingImport(
            in: folder, earlierFolder: DevotionalImportExportManager.shared.earlierImportDirectoryURL
        )
    }

    /// `earlierFolder`, the folder's name before writing was renamed, is
    /// moved to `folder` first.
    static func pendingImport(
        in folder: URL, earlierFolder: URL? = nil, defaults: UserDefaults = .standard
    ) async -> PendingWritingImport? {
        let reviewed = defaults.string(forKey: reviewedKey)
        return await Task.detached(priority: .utility) { () -> PendingWritingImport? in
            let fileManager = FileManager.default
            var folder = folder
            // A move that couldn't be made this time leaves the earlier
            // folder the one to read, rather than its files unoffered.
            if let earlierFolder,
               DevotionalImportExportManager.moveEarlierFolder(from: earlierFolder, to: folder) == .failed {
                folder = earlierFolder
            }
            guard fileManager.fileExists(atPath: folder.path) else {
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                return nil
            }
            // A file iCloud is still bringing down would read as missing; wait
            // for it rather than settle on a plan without it.
            let downloading = requestDownloads(in: folder)
            guard let files = try? LampWritingImport.files(at: folder), !files.isEmpty else { return nil }
            let fingerprint = Self.fingerprint(of: files) + (downloading ? "+downloading" : "")
            guard fingerprint != reviewed,
                  let store = try? PhoneWritingImportStore(newWritingModuleID: WritingCollection.id),
                  let plan = try? await LampWritingImport.plan(files, in: store, comparingWithLibrary: true)
            else { return nil }
            let pending = PendingWritingImport(
                sourceName: "Import Folder", plan: plan, planned: store.seen, dropFolderFingerprint: fingerprint
            )
            guard pending.offersAnything else {
                if !downloading { defaults.set(fingerprint, forKey: reviewedKey) }
                return nil
            }
            return pending
        }.value
    }

    /// The person has seen this plan, imported from it or not.
    static func reviewed(_ pending: PendingWritingImport, defaults: UserDefaults = .standard) {
        guard let fingerprint = pending.dropFolderFingerprint else { return }
        defaults.set(fingerprint, forKey: reviewedKey)
    }

    /// The files' paths and texts, and the pictures and decks found beside
    /// them: the same folder gives the same print, and one whose picture has
    /// since arrived gives another.
    static func fingerprint(of files: [LampWritingImportFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.markdown.utf8))
            hasher.update(data: Data([0]))
            // A picture replaced under the same name is a change too: told by
            // its size and when it was saved, rather than reading every byte
            // of every recording on each look.
            for (name, url) in file.attachments.sorted(by: { $0.key < $1.key }) {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                hasher.update(data: Data(name.utf8))
                hasher.update(data: Data("\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)".utf8))
                hasher.update(data: Data([0]))
            }
            if let deck = file.deck {
                hasher.update(data: Data(deck.path.utf8))
                hasher.update(data: deck.data)
            }
            hasher.update(data: Data([1]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A file iCloud hasn't brought down yet — writing, picture or deck —
    /// is a hidden placeholder the reading skips; ask for each, so the next
    /// look finds them. Whether any was still on its way.
    @discardableResult
    private static func requestDownloads(in folder: URL) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        var pending = false
        for case let url as URL in enumerator where url.pathExtension == "icloud" {
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("."), name.count > 1 else { continue }
            let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst()))
            try? fileManager.startDownloadingUbiquitousItem(at: real)
            pending = true
        }
        return pending
    }
}

/// The phone's writing as core's writing import reads and writes it.
///
/// Through the writings file's row, which both apps already agree on: a
/// writing is read as the Mac reads the phone's file, and saved as a Mac
/// import of it reaches the phone by sync, so what an import compares and
/// writes can't drift between them.
final class PhoneWritingImportStore: LampWritingImportStore {
    private let database: ModuleDatabase
    /// Where a writing not already in Lamp goes. One already in Lamp stays in
    /// its own collection.
    let newWritingModuleID: String
    /// The collections written to, to publish once the import is done.
    private(set) var touchedModuleIDs: Set<String> = []
    /// Each writing offered, exactly as stored, by id. A writing read as
    /// core reads it loses what core's model can't hold — a summary's or a
    /// footnote's links and formatting — so two different rows can read
    /// alike; a write is checked against these instead.
    private(set) var seen: [String: Data] = [:]
    /// The rows the plan saw, when applying one: a write goes ahead only
    /// over the row as it was then, or where there was none. Moved on to
    /// what this import itself stores, so core's second save of a writing,
    /// as when it puts back a link to one that failed, goes ahead too.
    private var planned: [String: Data]?
    private let fileManager = FileManager.default

    init(database: ModuleDatabase = .shared, newWritingModuleID: String, planned: [String: Data]? = nil) throws {
        self.database = database
        self.newWritingModuleID = newWritingModuleID
        self.planned = planned
    }

    /// A row exactly as stored, to compare whole.
    private static func snapshot(_ entry: DevotionalEntry?) -> Data? {
        guard let entry else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(entry)
    }

    /// Whether the stored row is still the one the plan saw.
    private func isAsPlanned(_ entry: DevotionalEntry?, id: String) -> Bool {
        guard let planned else { return true }
        return Self.snapshot(entry) == planned[id]
    }

    /// The person's own writing, in every collection they can edit:
    /// subscriptions and bundled writing are someone else's.
    func importableWritings() throws -> [LampDevotional] {
        let names = try editableModuleNames()
        let entries = try database.read { db in
            try DevotionalEntry.filter(names.keys.contains(Column("module_id"))).fetchAll(db)
        }
        let offered = entries.filter { !$0.isFromSubscription }
        seen = Dictionary(offered.compactMap { entry in Self.snapshot(entry).map { (entry.id, $0) } }) { first, _ in first }
        return offered.map { Self.writing(of: $0, names: names) }
    }

    func writingDeletion(id: String) throws -> LampPersonalDeletionLedger.Entry? {
        try database.personalDeletionLedger().entry(.devotional, id)
    }

    /// A subscription's writing, or one in a collection that can't be
    /// edited, shares the table but is never written over.
    func writingRefusal(id: String) throws -> String? {
        guard let existing = try database.getDevotionalEntry(id: id),
              !Self.isImportable(existing, names: try editableModuleNames()) else { return nil }
        return "“\(existing.title)” belongs to a subscription or a collection you can’t edit, so an import can’t change it."
    }

    /// Written only over the copy the import compared with, in the same
    /// transaction as the check: sync and the editor write this database from
    /// other threads, and an edit or a deletion that lands meanwhile wins.
    /// Returns the copy as stored, read back, which undo compares with later.
    func saveImportedWriting(_ writing: LampDevotional, expecting current: LampDevotional?) throws -> LampDevotional? {
        let names = try editableModuleNames()
        let newWritingModuleID = newWritingModuleID
        let saved: (moduleID: String, stored: LampDevotional, row: Data?)? = try database.write { db in
            let existing = try DevotionalEntry.fetchOne(db, key: writing.id)
            if let existing, !Self.isImportable(existing, names: names) { return nil }
            // The collection chosen for new writing, removed by sync while
            // the sheet was open: never a writing in no collection.
            if existing == nil, names[newWritingModuleID] == nil {
                throw LampLibraryError.invalidPersonalContent(
                    "The collection chosen for new writing is no longer here. Import again and choose another."
                )
            }
            guard existing.map({ Self.writing(of: $0, names: names) }) == current,
                  isAsPlanned(existing, id: writing.id) else { return nil }
            let moduleID = existing?.moduleId ?? newWritingModuleID
            var entry = DevotionalEntry(row: try LampPersonalWritingFile.row(for: writing, moduleID: moduleID))
            if let existing {
                // What the file has no word for stays as the phone has it.
                if existing.seriesName == entry.seriesName { entry.seriesId = existing.seriesId }
                entry.relatedIds = existing.relatedIds
                entry.recordChangeTag = existing.recordChangeTag
                entry.created = existing.created
            }
            try entry.save(db)
            try ModuleDatabase.recordPersonalPresence(db, .devotional, entry.id)
            guard let stored = try DevotionalEntry.fetchOne(db, key: entry.id) else { return nil }
            return (moduleID, Self.writing(of: stored, names: names), Self.snapshot(stored))
        }
        guard let saved else { return nil }
        touchedModuleIDs.insert(saved.moduleID)
        if planned != nil { planned?[writing.id] = saved.row }
        return saved.stored
    }

    /// Each save records its writing as present already.
    func recordWritingsPresent(_ ids: [String]) throws {}

    /// For undo: removed only while it is still as the import left it.
    func deleteImportedWriting(id: String, expecting current: LampDevotional) throws -> Bool {
        let names = try editableModuleNames()
        let removed: String? = try database.write { db in
            guard let existing = try DevotionalEntry.fetchOne(db, key: id),
                  Self.isImportable(existing, names: names),
                  Self.writing(of: existing, names: names) == current,
                  try DevotionalEntry.deleteOne(db, key: id) else { return nil }
            try ModuleDatabase.recordPersonalDeletion(db, .devotional, id)
            return existing.moduleId
        }
        guard let removed else { return false }
        touchedModuleIDs.insert(removed)
        return true
    }

    /// Into the writing's media folder, where the editor puts the pictures
    /// it adds, under a name of its own so two files called `photo.png` keep
    /// both, as core names the Mac's.
    func storeImportedMedia(from url: URL, writingID: String) throws -> String {
        guard LampPortableDevotionalMedia.isSafePathComponent(writingID) else {
            throw LampLibraryError.unsafeModuleIdentifier(writingID)
        }
        let moduleID = try moduleID(of: writingID)
        let storage = DevotionalMediaStorage.shared
        try storage.ensureMediaDirectory(devotionalId: writingID, moduleId: moduleID)
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let filename = "\(base.isEmpty ? "attachment" : base)-\(UUID().uuidString.prefix(8))"
            + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())")
        try fileManager.copyItem(
            at: url,
            to: storage.mediaDirectory(devotionalId: writingID, moduleId: moduleID).appendingPathComponent(filename)
        )
        return filename
    }

    func removeImportedMedia(writingID: String, filename: String) throws {
        guard LampPortableDevotionalMedia.isSafePathComponent(writingID),
              LampPortableDevotionalMedia.isSafePathComponent(filename) else { return }
        let file = DevotionalMediaStorage.shared
            .mediaDirectory(devotionalId: writingID, moduleId: try moduleID(of: writingID))
            .appendingPathComponent(filename)
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    /// The collections the person can edit, by id, with their names.
    private func editableModuleNames() throws -> [String: String] {
        Dictionary(
            try database.getAllModules(type: .devotional).filter(\.isEditable).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func isImportable(_ entry: DevotionalEntry, names: [String: String]) -> Bool {
        !entry.isFromSubscription && names[entry.moduleId] != nil
    }

    /// A stored writing as core reads it, the one way both what's offered and
    /// what's checked before a write are read.
    ///
    /// A body kept as blocks — headings, lists — is read as the Markdown the
    /// phone exports it as, not as its plain text, so an unchanged export
    /// comes back unchanged, and its blocks are kept.
    private static func writing(of entry: DevotionalEntry, names: [String: String]) -> LampDevotional {
        let read = LampPersonalWritingFile.writing(
            from: entry.writingFileRow(moduleID: entry.moduleId),
            moduleName: names[entry.moduleId] ?? LampPersonalModule.writing.name
        )
        guard let markdown = LampPortableDevotionalContent.markdown(from: entry.contentJson),
              markdown != read.content else { return read }
        return LampDevotional(
            id: read.id, moduleID: read.moduleID, moduleName: read.moduleName, title: read.title,
            subtitle: read.subtitle, author: read.author, date: read.date, tags: read.tags,
            category: read.category, seriesName: read.seriesName, seriesOrder: read.seriesOrder,
            keyScriptures: read.keyScriptures, summary: read.summary, content: markdown,
            contentJSON: read.contentJSON, footnotes: read.footnotes, mediaJSON: read.mediaJSON,
            created: read.created, lastModified: read.lastModified, isEditable: read.isEditable
        )
    }

    /// The collection a writing is in, or goes to.
    private func moduleID(of writingID: String) throws -> String {
        try database.getDevotionalEntry(id: writingID)?.moduleId ?? newWritingModuleID
    }
}

/// Files chosen in the document picker, kept open while an import of them
/// is planned and applied, and given back when it's done with.
final class SecurityScopedAccess: @unchecked Sendable {
    private let urls: [URL]

    init(_ urls: [URL]) {
        self.urls = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}

extension DevotionalEntry {
    /// The writing as a row of the writings file, losing nothing the phone
    /// keeps.
    func writingFileRow(moduleID: String) -> LampPersonalWritingFile.Row {
        LampPersonalWritingFile.Row(
            id: id, moduleID: moduleID, title: title,
            subtitle: subtitle, author: author, date: date,
            tags: tags, category: category,
            seriesID: seriesId, seriesName: seriesName, seriesOrder: seriesOrder,
            keyScripturesJSON: keyScripturesJson, summaryJSON: summaryJson,
            contentJSON: contentJson, footnotesJSON: footnotesJson,
            relatedIDs: relatedIds, created: created, lastModified: lastModified,
            recordChangeTag: recordChangeTag,
            subscriptionID: subscriptionId, isReadOnly: isReadOnly,
            mediaJSON: mediaJson
        )
    }

    /// A row of the writings file as the phone stores it, as sync stores the
    /// rows of a file it takes in.
    init(row: LampPersonalWritingFile.Row) {
        self.id = row.id
        self.moduleId = row.moduleID
        self.title = row.title
        self.subtitle = row.subtitle
        self.author = row.author
        self.date = row.date
        self.tags = row.tags
        self.category = row.category
        self.seriesId = row.seriesID
        self.seriesName = row.seriesName
        self.seriesOrder = row.seriesOrder
        self.keyScripturesJson = row.keyScripturesJSON
        self.summaryJson = row.summaryJSON
        self.contentJson = row.contentJSON
        self.footnotesJson = row.footnotesJSON
        self.mediaJson = row.mediaJSON
        self.relatedIds = row.relatedIDs
        self.created = row.created
        self.lastModified = row.lastModified
        // As core writes it into the file, which is what sync stores.
        self.searchText = LampPersonalFile.searchText([
            row.title,
            row.subtitle,
            LampPersonalFile.searchableText(in: row.summaryJSON),
            LampPersonalFile.searchableText(in: row.contentJSON),
            LampPersonalFile.searchableText(in: row.footnotesJSON),
        ])
        self.recordChangeTag = row.recordChangeTag
        self.subscriptionId = row.subscriptionID
        self.isReadOnly = row.isReadOnly
    }
}
