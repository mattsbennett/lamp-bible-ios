//
//  ArchiveReadCountTests.swift
//  Lamp BibleTests
//
//  How many times a sync pass fetches and inflates the whole library.
//
//  Decoding the archive holds every module body in memory at once, so this is
//  the difference between a launch that costs a second and one that costs a
//  minute and a couple of gigabytes. It used to be three times a pass, with
//  two of those spent confirming nothing had changed.
//

import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class ArchiveReadCountTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var moduleID: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-reads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )
        moduleID = "archive-reads-book-\(UUID().uuidString.lowercased())"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
        try? ModuleDatabase.shared.deleteModule(id: moduleID)
    }

    /// An archive holding one real compiled module, so a decode has something
    /// to inflate and the count being measured means something.
    private func makeArchive(body: String = "Archive content.") throws -> Data {
        // A fresh staging directory per call, so an archive can be built more
        // than once in a test without colliding with the last one.
        let staging = temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = staging.appendingPathComponent("Source", isDirectory: true)
        let modules = source.appendingPathComponent(
            LampPortableBackupLayout.modulesDirectory, isDirectory: true
        )
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(moduleID!)", "type":"book",
                   "title":"Archive Book", "language":"en"},
          "sections": [{"id":"chapter-1", "type":"chapter", "title":"Chapter One",
            "content":[{"type":"paragraph", "content":{"text":"\(body)"}}]}]
        }
        """
        let compiledURL = staging.appendingPathComponent("\(moduleID!).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8),
            sourceFilename: "\(moduleID!).json",
            destinationURL: compiledURL
        )
        try FileManager.default.copyItem(
            at: compiledURL, to: modules.appendingPathComponent("\(moduleID!).lamp")
        )
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 1,
                noteDocumentCount: 0,
                highlightDocumentCount: 0,
                devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: source.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        )
        return try LampSyncArchive.create(from: source).compressedData()
    }

    /// The regression this guards: a pass that changes nothing must fetch the
    /// library's bytes once at most, however many things want to look inside
    /// it. Settling first, because the passes that converge a new device do
    /// legitimately write and re-read.
    func testAQuietPassFetchesTheLibraryOnce() async throws {
        let server = ArchiveServer(archive: try makeArchive())
        let storage = CountingArchiveStorage(server: server)
        let source = "archive-reads-\(UUID().uuidString)"

        var settled = false
        for _ in 0..<6 {
            await server.resetCounts()
            _ = await ModuleSyncManager.shared.syncAll(
                using: storage, backend: .webdav, archiveSource: source
            )
            if await server.writeCount() == 0 {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled, "the device never stopped writing, so nothing can be measured")

        await server.resetCounts()
        _ = await ModuleSyncManager.shared.syncAll(
            using: storage, backend: .webdav, archiveSource: source
        )

        let bodyReads = await server.bodyReadCount()
        let writes = await server.writeCount()
        XCTAssertEqual(writes, 0, "a quiet pass must not write")
        XCTAssertEqual(
            bodyReads, 0,
            "a quiet pass inflated the whole library \(bodyReads) times"
        )
    }

    /// The preference half of the skip, which is the part of it written here
    /// rather than inherited from the poll. Getting this wrong the other way
    /// would strand a local preference edit, so it has to be conservative
    /// when it does not know.
    func testAPreferenceEditIsNoticedAndAnUnknownSourceAssumesOne() async throws {
        let server = ArchiveServer(archive: try makeArchive())
        let storage = CountingArchiveStorage(server: server)
        let source = "archive-reads-\(UUID().uuidString)"

        // Never synced: nothing is known about it, so it cannot be skipped.
        XCTAssertTrue(
            SharedPreferenceArchiveSync.hasLocalChanges(source: source),
            "a source with no recorded base must count as changed"
        )

        for _ in 0..<6 {
            await server.resetCounts()
            _ = await ModuleSyncManager.shared.syncAll(
                using: storage, backend: .webdav, archiveSource: source
            )
            if await server.writeCount() == 0 { break }
        }

        // Settled: the ledger this device published is the one it holds.
        XCTAssertFalse(
            SharedPreferenceArchiveSync.hasLocalChanges(source: source),
            "a settled source has nothing waiting to publish"
        )
    }

    /// A whole pass against a server that spells the same ETag differently
    /// between a PROPFIND and a GET still reaches the preference ledger.
    ///
    /// Narrower than it looks, and worth saying so: a first pass reads the
    /// archive, so it takes the contents comparison rather than the revision
    /// one, and this still passed when that revision comparison was broken.
    /// The comparison itself is guarded in core by
    /// LampSyncConditionalWrite.namesSameRevision; this covers the pass
    /// around it.
    func testAPassAgainstADifferentlySpellingServerReachesTheLedger() async throws {
        let server = ArchiveServer(archive: try makeArchive(), baresPropfind: true)
        let storage = CountingArchiveStorage(server: server)
        // A source with no recorded preference ledger, so the publish step
        // has a reason to look at the archive and will reach the comparison.
        let source = "archive-reads-\(UUID().uuidString)"

        _ = await ModuleSyncManager.shared.syncAll(
            using: storage, backend: .webdav, archiveSource: source
        )

        // Reaching the ledger at all is the point: it is the step beyond the
        // comparison that was failing.
        XCTAssertFalse(
            SharedPreferenceArchiveSync.hasLocalChanges(source: source),
            "the pass never got as far as recording a preference ledger"
        )
    }

    /// The other half: an archive that did change must still be read — a sync
    /// that skips its way to being fast and stops noticing other devices is
    /// worse than a slow one — and must be read exactly once. It is a single
    /// object holding every module body, so the module import, the settings
    /// entry and the preference ledger all want the same megabytes, and each
    /// one that fetches them separately pays for the whole library again.
    ///
    /// Note what this does and does not cover. The read it observes comes
    /// from the module import, which compares revisions of its own — so this
    /// guards the module path and nothing else. It passed unchanged when the
    /// settings pass was made to skip unconditionally, which is how that was
    /// found out. Guarding the settings path needs an archive carrying
    /// settings that differ from this device's, and an assertion that they
    /// arrive; until that exists, the settings read stays where it is.
    func testAChangedArchiveIsStillRead() async throws {
        let server = ArchiveServer(archive: try makeArchive())
        let storage = CountingArchiveStorage(server: server)
        let source = "archive-reads-\(UUID().uuidString)"

        for _ in 0..<6 {
            await server.resetCounts()
            _ = await ModuleSyncManager.shared.syncAll(
                using: storage, backend: .webdav, archiveSource: source
            )
            if await server.writeCount() == 0 { break }
        }

        // Another device publishes: same path, new bytes, new revision.
        await server.replaceArchive(try makeArchive(body: "Someone else's edit."))
        await server.resetCounts()
        _ = await ModuleSyncManager.shared.syncAll(
            using: storage, backend: .webdav, archiveSource: source
        )

        // Counted up to the first write: everything that wants to look inside
        // the archive before this device changes anything — the module
        // import, the settings entry, the preference ledger — must share one
        // fetch. A read after our own write is the archive having moved.
        let beforeWriting = await server.readsBeforeWriting()
        XCTAssertEqual(
            beforeWriting, 1,
            "one pass fetched the library \(beforeWriting) times before writing"
        )
    }
}

/// The archive as a server holds it: bytes, a revision that moves on write,
/// and a tally of what was asked for.
private actor ArchiveServer {
    private var files: [String: Data] = [:]
    private var revisions: [String: String] = [:]
    private var issued = 0
    private var bodyReads = 0
    private var writes = 0
    /// Reads taken before this pass wrote anything. A read after our own
    /// write is the archive having genuinely moved; before it, two reads are
    /// two fetches of the same bytes.
    private var readsBeforeFirstWrite: Int?

    /// Some servers spell the same ETag differently depending on how it was
    /// asked for: quoted in a GET's header, bare in a PROPFIND's property.
    /// Both name the same body.
    private let baresPropfind: Bool

    init(archive: Data, baresPropfind: Bool = false) {
        self.baresPropfind = baresPropfind
        files[LampSyncLayout.archivePath] = archive
        issued += 1
        revisions[LampSyncLayout.archivePath] = "\"revision-\(issued)\""
    }

    func resetCounts() {
        bodyReads = 0
        writes = 0
        readsBeforeFirstWrite = nil
    }

    func bodyReadCount() -> Int { bodyReads }
    func writeCount() -> Int { writes }
    func readsBeforeWriting() -> Int { readsBeforeFirstWrite ?? bodyReads }

    func read(_ path: String) -> LampSyncRemoteFile? {
        guard let data = files[path] else { return nil }
        // Only the archive is large enough to care about.
        if path == LampSyncLayout.archivePath { bodyReads += 1 }
        return LampSyncRemoteFile(data: data, revision: revisions[path])
    }

    func revision(_ path: String) -> String? {
        guard let revision = revisions[path] else { return nil }
        guard baresPropfind else { return revision }
        return LampSyncConditionalWrite.token(for: revision)
    }

    func write(_ data: Data, to path: String) -> String? {
        if readsBeforeFirstWrite == nil { readsBeforeFirstWrite = bodyReads }
        writes += 1
        issued += 1
        files[path] = data
        let revision = "\"revision-\(issued)\""
        revisions[path] = revision
        return revision
    }

    func exists(_ path: String) -> Bool { files[path] != nil }

    /// Another device's publish: new bytes under a revision nobody has seen.
    func replaceArchive(_ data: Data) {
        issued += 1
        files[LampSyncLayout.archivePath] = data
        revisions[LampSyncLayout.archivePath] = "\"revision-\(issued)\""
    }
}

private struct CountingArchiveStorage: ModuleStorage, LampSyncRemoteStore {
    let server: ArchiveServer

    // MARK: ModuleStorage

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        guard let file = await server.read(fileName) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return file.data
    }

    func readModuleSnapshot(
        type: ModuleType, fileName: String
    ) async throws -> LampSyncRemoteFile {
        guard let file = await server.read(fileName) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return file
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        _ = await server.write(data, to: fileName)
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {}

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await server.revision(fileName)
    }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }

    func readFile(path: String) async throws -> Data {
        guard let file = await server.read(path) else {
            throw ModuleStorageError.fileNotFound(path)
        }
        return file.data
    }

    func writeFile(path: String, data: Data) async throws {
        _ = await server.write(data, to: path)
    }

    // MARK: LampSyncRemoteStore

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func revision(path: String) async throws -> String? { await server.revision(path) }
    func read(path: String) async throws -> LampSyncRemoteFile? { await server.read(path) }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        await server.write(data, to: path)
    }
}
