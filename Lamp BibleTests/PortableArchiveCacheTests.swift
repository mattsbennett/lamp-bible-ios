//
//  PortableArchiveCacheTests.swift
//  Lamp BibleTests
//
//  What the launch sync remembers between launches. A device that remembers
//  nothing reinstalls every module in the archive every time it starts, which
//  on a large library is more work than iOS allows an app at startup — it is
//  killed partway, so it remembers nothing next time either.
//

import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class PortableArchiveCacheTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var moduleID: String!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true
        )
        moduleID = "archive-cache-book-\(UUID().uuidString.lowercased())"
        suiteName = "portable-archive-cache-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
        try? ModuleDatabase.shared.deleteModule(id: moduleID)
    }

    // MARK: - Fixture

    /// One compiled book module in a portable archive, the smallest thing a
    /// launch sync can be asked to import.
    private func makeArchive(
        body: String = "Archive content.",
        settings: String? = nil
    ) throws -> Data {
        try makeArchiveValue(body: body, settings: settings).compressedData()
    }

    /// The archive itself, so a test can derive a variant from these exact
    /// bytes. Compiling the module twice does not produce identical bytes, so
    /// "the same library with one entry changed" has to be built by changing
    /// one entry, not by building a second library.
    private func makeArchiveValue(
        body: String = "Archive content.",
        settings: String? = nil
    ) throws -> LampSyncArchive {
        // A fresh staging directory per call, so a test can build more than
        // one archive without the second colliding with the first.
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
        var archive = try LampSyncArchive.create(from: source)
        if let settings {
            // Stands in for the settings entry a real archive carries: not
            // content, and not something a module import installs.
            archive = try archive.replacingEntry(
                at: LampSyncLayout.userSettingsPath,
                with: Data(settings.utf8),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        return archive
    }

    private func storedState() throws -> ModuleSyncManager.PortableArchiveImportState? {
        guard let data = defaults.data(
            forKey: ModuleSyncManager.portableArchiveImportStateKey
        ) else { return nil }
        return try JSONDecoder().decode(
            ModuleSyncManager.PortableArchiveImportState.self, from: data
        )
    }

    // MARK: - Tests

    /// The regression. A server that does not give a strong ETag — a weak one,
    /// or a bare content digest — left nothing recorded at all, so the next
    /// launch had no way to know the module it just installed was installed.
    func testAnImportIsRememberedEvenWithoutAStrongETag() async throws {
        let remote = CountingArchiveStore(
            data: try makeArchive(), revision: "W/\"archive-revision\""
        )

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )

        let state = try XCTUnwrap(try storedState(), "the import must be remembered")
        XCTAssertEqual(state.modules.map(\.id), [moduleID])
        XCTAssertEqual(state.source, suiteName)
        // The revision itself is not kept: it cannot be trusted to mean
        // "unchanged", and keeping it would skip a download that must happen.
        XCTAssertNil(state.revision)
    }

    /// And having remembered it, the second pass treats the module as already
    /// installed instead of unpacking and writing it again.
    func testASecondPassReinstallsNothing() async throws {
        let archive = try makeArchive()
        let remote = CountingArchiveStore(data: archive, revision: "W/\"archive-revision\"")

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        XCTAssertEqual(try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Archive Book")
        let installedAt = try XCTUnwrap(try storedState()).modules.first?.digest

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )

        // Without a trustworthy revision the archive is still fetched — that
        // much cannot be avoided — but what it holds is recognised.
        let reads = await remote.readCount()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Archive Book")
        XCTAssertEqual(try XCTUnwrap(try storedState()).modules.first?.digest, installedAt)
    }

    /// A strong ETag still buys what it always did: the download is skipped
    /// entirely on the second pass.
    func testAStrongETagStillSkipsTheDownloadEntirely() async throws {
        let remote = CountingArchiveStore(
            data: try makeArchive(), revision: "\"archive-revision\""
        )

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )

        let reads = await remote.readCount()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try XCTUnwrap(try storedState()).revision, "\"archive-revision\"")
    }

    /// The structural win: a settings edit on another device moves the
    /// archive's revision without touching a module. The published index says
    /// so, entry by entry, and the import believes it rather than downloading
    /// and inflating the whole library to install nothing.
    func testASettingsOnlyChangeCostsNoLibraryFetch() async throws {
        let original = try makeArchiveValue(settings: "these settings")
        let remote = CountingArchiveStore(
            data: try original.compressedData(), revision: "\"revision-1\""
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        let afterFirstImport = await remote.readCount()

        // Another device edits settings: the very same module bytes, one
        // different entry, a new revision, and an index saying as much.
        let settingsOnly = try original.replacingEntry(
            at: LampSyncLayout.userSettingsPath,
            with: Data("someone else's settings".utf8),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        await remote.replace(
            data: try settingsOnly.compressedData(), revision: "\"revision-2\""
        )
        await remote.permitWrites()
        try await LampSyncArchiveIndex.publish(
            describing: settingsOnly, at: "\"revision-2\"", in: remote
        )

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )

        let reads = await remote.readCount()
        XCTAssertEqual(
            reads, afterFirstImport,
            "a settings-only change fetched the library \(reads - afterFirstImport) times"
        )
        // And it recorded where the server has got to, so the pass after this
        // recognises the archive outright instead of asking the index again.
        XCTAssertEqual(try XCTUnwrap(try storedState()).revision, "\"revision-2\"")
        XCTAssertEqual(
            try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Archive Book"
        )
    }

    /// A different archive is still imported: recognising what is installed
    /// must not mean ignoring what changed.
    func testAChangedArchiveIsStillImported() async throws {
        let remote = CountingArchiveStore(
            data: try makeArchive(), revision: "W/\"archive-revision\""
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        let firstDigest = try XCTUnwrap(try storedState()).modules.first?.digest

        await remote.replace(data: try makeArchive(body: "Revised archive content."))

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )

        XCTAssertNotEqual(try XCTUnwrap(try storedState()).modules.first?.digest, firstDigest)
        XCTAssertEqual(try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Archive Book")
    }
}

/// An archive on a server that counts how often it is actually fetched.
private actor CountingArchiveStore: LampSyncRemoteStore {
    private var data: Data
    private var revisionValue: String
    private var reads = 0
    private var sidecars: [String: Data] = [:]
    private var allowsWrites = false

    init(data: Data, revision: String) {
        self.data = data
        self.revisionValue = revision
    }

    func readCount() -> Int { reads }
    func replace(data: Data) { self.data = data }

    /// Another device publishes: new bytes under a revision nobody has seen.
    func replace(data: Data, revision: String) {
        self.data = data
        self.revisionValue = revision
    }

    func permitWrites() { allowsWrites = true }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }

    func revision(path: String) async throws -> String? {
        path == LampSyncLayout.archivePath ? revisionValue : "\"\(path)\""
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        if path != LampSyncLayout.archivePath {
            guard let sidecar = sidecars[path] else { return nil }
            return LampSyncRemoteFile(data: sidecar, revision: "\"\(path)\"")
        }
        // Only the archive is the whole library; only it is worth counting.
        reads += 1
        return LampSyncRemoteFile(data: data, revision: revisionValue)
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        guard allowsWrites, path != LampSyncLayout.archivePath else {
            XCTFail("Importing an archive must not write to the server")
            return nil
        }
        sidecars[path] = data
        return "\"\(path)\""
    }
}
