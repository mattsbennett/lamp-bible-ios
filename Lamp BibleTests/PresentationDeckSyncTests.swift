//
//  PresentationDeckSyncTests.swift
//  Lamp BibleTests
//
//  Decks are read-only on iOS. They arrive as files in the library's deck
//  folder on either provider; these cover that mirror, its images and
//  deletions, and the local import that keeps a device's own decks apart.
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

    // MARK: - Published decks

    func testArchivePullStoresPublishedDecks() async throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
            try deckEntry(deck(id: "b", title: "Advent"), modifiedAt: .init(timeIntervalSince1970: 200)),
        ])

        let pulled1 = try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertTrue(pulled1)

        let entries = decks.entries()
        XCTAssertEqual(entries.map(\.deck.title), ["Advent", "Living Hope"])
        XCTAssertTrue(entries.allSatisfy { $0.origin == .synced })
    }

    func testArchivePullPreservesThePublishedModificationDate() async throws {
        let published = Date(timeIntervalSince1970: 1_234_567)
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: published),
        ])

        try await PresentationDeckSync.pull(from: archive, into: decks)

        // Without this the next pull would compare a local "now" against the
        // publisher's timestamp and keep replacing an unchanged deck.
        XCTAssertEqual(decks.entries().first?.modifiedAt, published)
    }

    func testArchivePullIsIdempotent() async throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])

        let pulled2 = try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertTrue(pulled2)
        let pulled3 = try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertFalse(pulled3)
    }

    func testArchivePullAppliesDeletions() async throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertEqual(decks.entries().count, 1)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("a", at: Date(timeIntervalSince1970: 500))
        let afterDeletion = LampSyncArchive(entries: [
            try ledgerEntry(ledger, modifiedAt: .init(timeIntervalSince1970: 500)),
        ])

        let pulled4 = try await PresentationDeckSync.pull(from: afterDeletion, into: decks)
        XCTAssertTrue(pulled4)
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testArchivePullSkipsAnUnreadableDeck() async throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Living Hope"), modifiedAt: .init(timeIntervalSince1970: 100)),
            LampSyncArchive.Entry(
                path: "\(LampPresentationDeckPortableLayout.directoryPath)/broken.lampdeck",
                data: Data("not a deck".utf8),
                modifiedAt: Date(timeIntervalSince1970: 300)
            ),
        ])

        try await PresentationDeckSync.pull(from: archive, into: decks)
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

    // MARK: - Assets

    private func imageDeck(id: String, assetName: String?) -> LampPresentationDeck {
        var deck = self.deck(id: id, title: "Pictures")
        if let assetName {
            deck.slides.append(
                LampPresentationSlide(
                    layout: .image,
                    blocks: [
                        LampPresentationBlock(
                            kind: .image,
                            assetPath: "\(LampPresentationDeckStore.assetsDirectoryName)/\(assetName)",
                            altText: "A picture"
                        ),
                    ]
                )
            )
        }
        return deck
    }

    private func assetEntry(
        _ name: String,
        _ contents: String,
        modifiedAt: Date
    ) -> LampSyncArchive.Entry {
        LampSyncArchive.Entry(
            path: "\(LampPresentationDeckPortableLayout.assetsDirectoryPath)/\(name)",
            data: Data(contents.utf8),
            modifiedAt: modifiedAt
        )
    }

    private func storedAsset(_ name: String) -> String? {
        let url = decks.syncedStore.assetsDirectoryURL.appendingPathComponent(name)
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testArchivePullStoresImagesBesideTheirDecks() async throws {
        let archive = LampSyncArchive(entries: [
            try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100)),
            assetEntry("photo.jpg", "image bytes", modifiedAt: .init(timeIntervalSince1970: 100)),
        ])

        let pulled5 = try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertTrue(pulled5)
        XCTAssertEqual(storedAsset("photo.jpg"), "image bytes")

        let block = decks.entries().first?.deck.slides.last?.blocks.first
        XCTAssertNotNil(block)
        XCTAssertNotNil(decks.syncedStore.assetURL(for: block!))
    }

    func testTiedImageEditsUseTheSharedMergeRule() async throws {
        let date = Date(timeIntervalSince1970: 100)
        let original = LampSyncArchive(entries: [
            try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: date),
            assetEntry("photo.jpg", "alpha", modifiedAt: date),
        ])
        try await PresentationDeckSync.pull(from: original, into: decks)
        let revised = LampSyncArchive(entries: [
            assetEntry("photo.jpg", "zeta", modifiedAt: date),
        ])
        try await PresentationDeckSync.pull(from: revised, into: decks)
        XCTAssertEqual(storedAsset("photo.jpg"), "zeta")
        try await PresentationDeckSync.pull(from: original, into: decks)
        XCTAssertEqual(storedAsset("photo.jpg"), "zeta")
    }

    func testImagesNoDeckReferencesAreRemoved() async throws {
        let withImage = LampSyncArchive(entries: [
            try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100)),
            assetEntry("photo.jpg", "image bytes", modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try await PresentationDeckSync.pull(from: withImage, into: decks)
        XCTAssertEqual(storedAsset("photo.jpg"), "image bytes")

        // The deck is revised to drop its picture.
        let withoutImage = LampSyncArchive(entries: [
            try deckEntry(imageDeck(id: "a", assetName: nil), modifiedAt: .init(timeIntervalSince1970: 900)),
        ])
        try await PresentationDeckSync.pull(from: withoutImage, into: decks)

        XCTAssertNil(storedAsset("photo.jpg"))
    }

    func testAnImageSharedByTwoDecksSurvivesOneBeingDeleted() async throws {
        var second = imageDeck(id: "b", assetName: "photo.jpg")
        second.title = "Also Pictures"
        let archive = LampSyncArchive(entries: [
            try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100)),
            try deckEntry(second, modifiedAt: .init(timeIntervalSince1970: 100)),
            assetEntry("photo.jpg", "image bytes", modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try await PresentationDeckSync.pull(from: archive, into: decks)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("a", at: Date(timeIntervalSince1970: 500))
        try await PresentationDeckSync.pull(
            from: LampSyncArchive(entries: [try ledgerEntry(ledger, modifiedAt: .init(timeIntervalSince1970: 500))]),
            into: decks
        )

        XCTAssertEqual(decks.entries().count, 1)
        XCTAssertEqual(storedAsset("photo.jpg"), "image bytes")
    }

    func testANewerPublishedImageReplacesTheStoredOne() async throws {
        try await PresentationDeckSync.pull(
            from: LampSyncArchive(entries: [
                try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100)),
                assetEntry("photo.jpg", "first", modifiedAt: .init(timeIntervalSince1970: 100)),
            ]),
            into: decks
        )

        try await PresentationDeckSync.pull(
            from: LampSyncArchive(entries: [
                try deckEntry(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100)),
                assetEntry("photo.jpg", "second", modifiedAt: .init(timeIntervalSince1970: 900)),
            ]),
            into: decks
        )

        XCTAssertEqual(storedAsset("photo.jpg"), "second")
    }

    func testLooseFilePullCarriesImages() async throws {
        try writeDeckFile(imageDeck(id: "a", assetName: "photo.jpg"), modifiedAt: .init(timeIntervalSince1970: 100))
        let assetsDirectory = root
            .appendingPathComponent(LampPresentationDeckPortableLayout.assetsDirectoryPath)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try Data("image bytes".utf8).write(to: assetsDirectory.appendingPathComponent("photo.jpg"))

        let storage = FolderBackedStorage(root: root)
        let changed = try await PresentationDeckSync.pull(from: storage, into: decks)
        XCTAssertTrue(changed)
        XCTAssertEqual(storedAsset("photo.jpg"), "image bytes")
    }

    func testADeckNamingAFileOutsideTheLibraryIsRejected() async throws {
        var deck = self.deck(id: "evil", title: "Nasty")
        deck.slides.append(
            LampPresentationSlide(
                layout: .image,
                blocks: [
                    LampPresentationBlock(
                        kind: .image,
                        assetPath: "../../../../../../etc/passwd",
                        altText: "Nothing good"
                    ),
                ]
            )
        )
        let data = try JSONEncoder().encode(deck)
        let archive = LampSyncArchive(entries: [
            LampSyncArchive.Entry(
                path: "\(LampPresentationDeckPortableLayout.directoryPath)/evil.lampdeck",
                data: data,
                modifiedAt: Date(timeIntervalSince1970: 100)
            ),
        ])

        let pulled6 = try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertFalse(pulled6)
        XCTAssertTrue(decks.entries().isEmpty)
    }

    // MARK: - Local import

    func testImportKeepsADeckOnThisDevice() async throws {
        let source = root.appendingPathComponent("shared.lampdeck")
        try encoded(deck(id: "a", title: "Borrowed")).write(to: source)

        try decks.importDeck(from: source)

        let entries = decks.entries()
        XCTAssertEqual(entries.map(\.deck.title), ["Borrowed"])
        XCTAssertEqual(entries.first?.origin, .imported)
    }

    func testImportRejectsAnInvalidDeck() async throws {
        let source = root.appendingPathComponent("broken.lampdeck")
        try Data("{}".utf8).write(to: source)

        XCTAssertThrowsError(try decks.importDeck(from: source))
        XCTAssertTrue(decks.entries().isEmpty)
    }

    func testAPublishedDeckWinsOverAnImportedCopyOfIt() async throws {
        let source = root.appendingPathComponent("shared.lampdeck")
        try encoded(deck(id: "a", title: "Imported Copy")).write(to: source)
        try decks.importDeck(from: source)

        let archive = LampSyncArchive(entries: [
            try deckEntry(deck(id: "a", title: "Published Copy"), modifiedAt: .init(timeIntervalSince1970: 100)),
        ])
        try await PresentationDeckSync.pull(from: archive, into: decks)

        let entries = decks.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.deck.title, "Published Copy")
        XCTAssertEqual(entries.first?.origin, .synced)
    }

    func testSyncDoesNotRemoveAnImportedDeck() async throws {
        let source = root.appendingPathComponent("local.lampdeck")
        try encoded(deck(id: "local", title: "Mine")).write(to: source)
        try decks.importDeck(from: source)

        var ledger = LampPresentationDeckDeletionLedger()
        ledger.record("local", at: Date(timeIntervalSince1970: 9_000))
        let archive = LampSyncArchive(entries: [
            try ledgerEntry(ledger, modifiedAt: .init(timeIntervalSince1970: 9_000)),
        ])

        try await PresentationDeckSync.pull(from: archive, into: decks)
        XCTAssertEqual(decks.entries().map(\.deck.title), ["Mine"])
    }

    func testRemovingAnImportedDeck() async throws {
        let source = root.appendingPathComponent("local.lampdeck")
        try encoded(deck(id: "local", title: "Mine")).write(to: source)
        try decks.importDeck(from: source)

        try decks.removeImportedDeck(id: "local")
        XCTAssertTrue(decks.entries().isEmpty)
    }

    // MARK: - Decks made from a writing

    private func publish(_ decks: [LampPresentationDeck]) async throws {
        let archive = LampSyncArchive(entries: try decks.map {
            try deckEntry($0, modifiedAt: .init(timeIntervalSince1970: 100))
        })
        try await PresentationDeckSync.pull(from: archive, into: self.decks)
    }

    func testAWritingFindsTheDecksMadeFromIt() async throws {
        var sermon = deck(id: "a", title: "Sermon")
        sermon.source = LampPresentationSource(kind: .devotional, id: "9ADB692A-FE3C-4291-A012-074FFDB3AC53")
        var other = deck(id: "b", title: "Another Writing")
        other.source = LampPresentationSource(kind: .devotional, id: "D71AF007-C2C5-443D-87B1-6C6CABA13525")
        let loose = deck(id: "c", title: "Untitled Presentation")
        try await publish([sermon, other, loose])

        XCTAssertEqual(
            decks.entries(forWriting: "9ADB692A-FE3C-4291-A012-074FFDB3AC53").map(\.title),
            ["Sermon"]
        )
        XCTAssertEqual(
            decks.linkedWritingIDs(),
            ["9ADB692A-FE3C-4291-A012-074FFDB3AC53", "D71AF007-C2C5-443D-87B1-6C6CABA13525"]
        )
    }

    func testAWritingIDMatchesWhicheverCaseItIsSpelledIn() async throws {
        var sermon = deck(id: "a", title: "Sermon")
        sermon.source = LampPresentationSource(kind: .writing, id: "9adb692a-fe3c-4291-a012-074fdb3ac53")
        try await publish([sermon])

        XCTAssertEqual(decks.entries(forWriting: "9ADB692A-FE3C-4291-A012-074FDB3AC53").count, 1)
    }

    func testADeckMadeFromScriptureBelongsToNoWriting() async throws {
        var passage = deck(id: "a", title: "Psalm 23")
        passage.source = LampPresentationSource(kind: .scripture, id: "19023001")
        try await publish([passage])

        XCTAssertTrue(decks.entries(forWriting: "19023001").isEmpty)
        XCTAssertTrue(decks.linkedWritingIDs().isEmpty)
    }
}

// MARK: - Published files

extension PresentationDeckSync {
    /// What the Mac published, as files in a library folder of their own,
    /// pulled the way the library pass mirrors decks.
    @discardableResult
    static func pull(
        from published: LampSyncArchive,
        into decks: PresentationDeckStorage
    ) async throws -> Bool {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }
        for entry in published.entries {
            let url = library.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try entry.data.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: entry.modifiedAt], ofItemAtPath: url.path
            )
        }
        return try await pull(from: FolderBackedStorage(root: library), into: decks)
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
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return StoredFileListing(
                name: url.lastPathComponent,
                modificationDate: values?.contentModificationDate,
                size: values?.fileSize.map(Int64.init)
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
