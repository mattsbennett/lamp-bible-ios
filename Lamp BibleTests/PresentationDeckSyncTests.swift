//
//  PresentationDeckSyncTests.swift
//  Lamp BibleTests
//
//  Decks are read-only on iOS. These cover the two ways they arrive — inside a
//  WebDAV sync archive and as loose files on iCloud Documents — plus the local
//  import that keeps a device's own decks apart from the synced mirror.
//

import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class PresentationDeckSyncTests: XCTestCase {
    private var root: URL!
    private var decks: PresentationDeckStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        decks = PresentationDeckStorage(documentsURL: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func deck(id: String, title: String) -> LampPresentationDeck {
        var deck = LampPresentationDeck.starter(title: title)
        deck.id = id
        return deck
    }

    private func encoded(_ deck: LampPresentationDeck) throws -> Data {
        try LampPresentationDeckStore(rootURL: root).encoded(deck)
    }

    private func deckEntry(
        _ deck: LampPresentationDeck,
        modifiedAt: Date
    ) throws -> LampSyncArchive.Entry {
        LampSyncArchive.Entry(
            path: "\(LampPresentationDeckPortableLayout.directoryPath)/\(deck.id).lampdeck",
            data: try encoded(deck),
            modifiedAt: modifiedAt
        )
    }

    private func ledgerEntry(
        _ ledger: LampPresentationDeckDeletionLedger,
        modifiedAt: Date
    ) throws -> LampSyncArchive.Entry {
        LampSyncArchive.Entry(
            path: LampPresentationDeckPortableLayout.deletionsPath,
            data: try ledger.encoded(),
            modifiedAt: modifiedAt
        )
    }

    private func writeDeckFile(
        _ deck: LampPresentationDeck,
        modifiedAt: Date
    ) throws {
        let directory = root
            .appendingPathComponent(LampPresentationDeckPortableLayout.directoryPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(deck.id).lampdeck")
        try encoded(deck).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Archive pull (WebDAV)

    func testArchivePullStoresPublishedDecks() throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
            try deckEntry(deck(id: "b", title: "Advent"), modifiedAt: .init(timeIntervalSince1970: 200)),
        ])

        XCTAssertTrue(try PresentationDeckSync.pull(from: archive, into: decks))

        let entries = decks.entries()
        XCTAssertEqual(entries.map(\.deck.title), ["Advent", "Living Hope"])
        XCTAssertTrue(entries.allSatisfy { $0.origin == .synced })
    }

    func testArchivePullPreservesThePublishedModificationDate() throws {
        let published = Date(timeIntervalSince1970: 1_234_567)
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: published),
        ])

        try PresentationDeckSync.pull(from: archive, into: decks)

        // Without this the next pull would compare a local "now" against the
        // publisher's timestamp and keep replacing an unchanged deck.
        XCTAssertEqual(decks.entries().first?.modifiedAt, published)
    }

    func testArchivePullIsIdempotent() throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])

        XCTAssertTrue(try PresentationDeckSync.pull(from: archive, into: decks))
        XCTAssertFalse(try PresentationDeckSync.pull(from: archive, into: decks))
    }

    func testArchivePullAppliesDeletions() throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertEqual(decks.entries().count, 1)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("a", at: Date(timeIntervalSince1970: 500))
        let afterDeletion = LampSyncArchive(entries: [
            try ledgerEntry(ledger, modifiedAt: .init(timeIntervalSince1970: 500)),
        ])

        XCTAssertTrue(try PresentationDeckSync.pull(from: afterDeletion, into: decks))
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testArchivePullSkipsAnUnreadableDeck() throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
            LampSyncArchive.Entry(
                path: "\(LampPresentationDeckPortableLayout.directoryPath)/broken.lampdeck",
                data: Data("not a deck".utf8),
                modifiedAt: Date(timeIntervalSince1970: 300)
            ),
        ])

        try PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertEqual(decks.entries().map(\.deck.title), ["Living Hope"])
    }

    // MARK: - Loose file pull (iCloud Documents)

    func testLooseFilePullReadsTheSamePathsAsTheArchive() async throws {
        try writeDeckFile(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100))
        try writeDeckFile(deck(id: "b", title: "Advent"), modifiedAt: .init(timeIntervalSince1970: 200))

        let storage = FolderBackedStorage(root: root)
        let changed = try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertTrue(changed)
        XCTAssertEqual(decks.entries().map(\.deck.title), ["Advent", "Living Hope"])
    }

    func testLooseFilePullAppliesDeletions() async throws {
        try writeDeckFile(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100))
        let storage = FolderBackedStorage(root: root)
        try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertEqual(decks.entries().count, 1)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("a", at: Date(timeIntervalSince1970: 500))
        let directory = root
            .appendingPathComponent(LampPresentationDeckPortableLayout.directoryPath)
        try ledger.encoded().write(
            to: directory.appendingPathComponent(
                LampPresentationDeckPortableLayout.deletionsFilename
            )
        )
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.lampdeck"))

        let changed = try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertTrue(changed)
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testLooseFilePullIgnoresNonDeckFiles() async throws {
        let directory = root
            .appendingPathComponent(LampPresentationDeckPortableLayout.directoryPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: directory.appendingPathComponent("readme.txt"))

        let storage = FolderBackedStorage(root: root)
        let changed = try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertFalse(changed)
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testLooseFilePullWithNoDirectoryIsNotAnError() async throws {
        let storage = FolderBackedStorage(root: root)
        let changed = try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertFalse(changed)
    }

    // MARK: - Local import

    func testImportKeepsADeckOnThisDevice() throws {
        let source = root.appendingPathComponent("shared.lampdeck")
        try encoded(deck(id: "a", title: "Borrowed")).write(to: source)

        try decks.importDeck(from: source)

        let entries = decks.entries()
        XCTAssertEqual(entries.map(\.deck.title), ["Borrowed"])
        XCTAssertEqual(entries.first?.origin, .imported)
    }

    func testImportRejectsAnInvalidDeck() throws {
        let source = root.appendingPathComponent("broken.lampdeck")
        try Data("{}".utf8).write(to: source)

        XCTAssertThrowsError(try decks.importDeck(from: source))
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testAPublishedDeckWinsOverAnImportedCopyOfIt() throws {
        let source = root.appendingPathComponent("shared.lampdeck")
        try encoded(deck(id: "a", title: "Imported Copy")).write(to: source)
        try decks.importDeck(from: source)

        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Published Copy"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try PresentationDeckSync.pull(from: archive, into: decks)

        let entries = decks.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.deck.title, "Published Copy")
        XCTAssertEqual(entries.first?.origin, .synced)
    }

    func testSyncDoesNotRemoveAnImportedDeck() throws {
        let source = root.appendingPathComponent("local.lampdeck")
        try encoded(deck(id: "local", title: "Mine")).write(to: source)
        try decks.importDeck(from: source)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("local", at: Date(timeIntervalSince1970: 9_000))
        let archive = LampSyncArchive(entries: [
            try ledgerEntry(ledger, modifiedAt: .init(timeIntervalSince1970: 9_000)),
        ])

        try PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertEqual(decks.entries().map(\.deck.title), ["Mine"])
    }

    func testRemovingAnImportedDeck() throws {
        let source = root.appendingPathComponent("local.lampdeck")
        try encoded(deck(id: "local", title: "Mine")).write(to: source)
        try decks.importDeck(from: source)

        try decks.removeImportedDeck(id: "local")
        XCTAssertTrue(decks.entries().isEmpty)
    }
}

// MARK: - Test storage

/// A `ModuleStorage` backed by a plain directory, standing in for iCloud
/// Documents. Only the path-based reads the deck pull uses are implemented.
private final class FolderBackedStorage: ModuleStorage {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func listFiles(path: String) async throws -> [StoredFileListing] {
        let directory = root.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return [] }

        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).map { url in
            StoredFileListing(
                name: url.lastPathComponent,
                modificationDate: try? url
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            )
        }
    }

    func readFile(path: String) async throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    // MARK: Unused by the deck pull

    func isAvailable() async -> Bool { true }

    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        throw ModuleStorageError.notAvailable
    }

    func readModuleSnapshot(
        type: ModuleType,
        fileName: String
    ) async throws -> LampSyncRemoteFile {
        throw ModuleStorageError.notAvailable
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        throw ModuleStorageError.notAvailable
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        throw ModuleStorageError.notAvailable
    }

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }

    func ensureDirectoryExists(type: ModuleType) async throws {}

    func directoryURL(for type: ModuleType) -> URL? { nil }

    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }

    func writeFile(path: String, data: Data) async throws {
        throw ModuleStorageError.notAvailable
    }
}
