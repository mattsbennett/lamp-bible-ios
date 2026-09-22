//
//  Lamp_BibleTests.swift
//  Lamp BibleTests
//
//  Created by Matthew Bennett on 2023-10-14.
//

import XCTest
@testable import Lamp_Bible

final class Lamp_BibleTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testExplicitBackendAlwaysWinsLegacyResolution() {
        for backend in SyncBackend.allCases {
            let stored = SyncSettings(
                backend: backend,
                webdavURL: "https://example.com/dav",
                webdavUsername: "reader",
                backendSelectionWasExplicit: true
            )

            let resolved = LegacySyncBackendResolver.resolve(
                storedSettings: stored,
                iCloudContentState: .hasContent,
                isExistingInstallation: true
            )

            XCTAssertEqual(resolved.backend, backend)
            XCTAssertEqual(resolved.webdavURL, stored.webdavURL)
            XCTAssertEqual(resolved.webdavUsername, stored.webdavUsername)
            XCTAssertEqual(resolved.backendSelectionWasExplicit, true)
            XCTAssertNil(resolved.legacyICloudReconciliationPending)
        }
    }

    func testLegacyLocalSettingWithICloudContentStaysOnICloud() {
        let resolved = LegacySyncBackendResolver.resolve(
            storedSettings: SyncSettings(backend: .none),
            iCloudContentState: .hasContent,
            isExistingInstallation: true
        )

        XCTAssertEqual(resolved.backend, .icloudDrive)
        XCTAssertEqual(resolved.backendSelectionWasExplicit, true)
        XCTAssertEqual(resolved.legacyICloudReconciliationPending, true)
    }

    func testLegacyLocalSettingWithUnavailableICloudStaysOnICloudConservatively() {
        let resolved = LegacySyncBackendResolver.resolve(
            storedSettings: SyncSettings(backend: .none),
            iCloudContentState: .unavailable,
            isExistingInstallation: true
        )

        XCTAssertEqual(resolved.backend, .icloudDrive)
        XCTAssertEqual(resolved.backendSelectionWasExplicit, true)
        XCTAssertEqual(resolved.legacyICloudReconciliationPending, true)
    }

    func testLegacyLocalSettingWithoutICloudContentStaysLocal() {
        let resolved = LegacySyncBackendResolver.resolve(
            storedSettings: SyncSettings(backend: .none),
            iCloudContentState: .empty,
            isExistingInstallation: true
        )

        XCTAssertEqual(resolved.backend, .none)
        XCTAssertEqual(resolved.backendSelectionWasExplicit, true)
        XCTAssertNil(resolved.legacyICloudReconciliationPending)
    }

    func testOnlyExistingAmbiguousLocalSettingsInspectICloud() {
        XCTAssertTrue(
            LegacySyncBackendResolver.requiresICloudInspection(
                storedSettings: nil,
                isExistingInstallation: true
            )
        )
        XCTAssertTrue(
            LegacySyncBackendResolver.requiresICloudInspection(
                storedSettings: SyncSettings(backend: .none),
                isExistingInstallation: true
            )
        )
        XCTAssertFalse(
            LegacySyncBackendResolver.requiresICloudInspection(
                storedSettings: nil,
                isExistingInstallation: false
            )
        )
        XCTAssertFalse(
            LegacySyncBackendResolver.requiresICloudInspection(
                storedSettings: SyncSettings(backend: .webdav),
                isExistingInstallation: true
            )
        )
        XCTAssertFalse(
            LegacySyncBackendResolver.requiresICloudInspection(
                storedSettings: SyncSettings(
                    backend: .none,
                    backendSelectionWasExplicit: true
                ),
                isExistingInstallation: true
            )
        )
    }

    func testLegacyInstallWithICloudContentStaysOnICloud() {
        let resolved = LegacySyncBackendResolver.resolve(
            storedSettings: nil,
            iCloudContentState: .hasContent,
            isExistingInstallation: true
        )

        XCTAssertEqual(resolved.backend, .icloudDrive)
        XCTAssertEqual(resolved.legacyICloudReconciliationPending, true)
    }

    func testLegacyInstallWithUnavailableICloudStaysOnICloudConservatively() {
        let resolved = LegacySyncBackendResolver.resolve(
            storedSettings: nil,
            iCloudContentState: .unavailable,
            isExistingInstallation: true
        )

        XCTAssertEqual(resolved.backend, .icloudDrive)
        XCTAssertEqual(resolved.legacyICloudReconciliationPending, true)
    }

    func testFreshOrEmptyInstallDefaultsToLocal() {
        let fresh = LegacySyncBackendResolver.resolve(
            storedSettings: nil,
            iCloudContentState: .unavailable,
            isExistingInstallation: false
        )
        let empty = LegacySyncBackendResolver.resolve(
            storedSettings: nil,
            iCloudContentState: .empty,
            isExistingInstallation: true
        )

        XCTAssertEqual(fresh.backend, .none)
        XCTAssertEqual(fresh.backendSelectionWasExplicit, true)
        XCTAssertNil(fresh.legacyICloudReconciliationPending)
        XCTAssertEqual(empty.backend, .none)
        XCTAssertEqual(empty.backendSelectionWasExplicit, true)
        XCTAssertNil(empty.legacyICloudReconciliationPending)
    }

    func testBackendCapabilitiesKeepLocalAndWebDAVOutOfICloudDocuments() {
        XCTAssertFalse(SyncBackend.none.usesRemoteStorage)
        XCTAssertFalse(SyncBackend.none.usesICloudDocuments)
        XCTAssertTrue(SyncBackend.icloudDrive.usesRemoteStorage)
        XCTAssertTrue(SyncBackend.icloudDrive.usesICloudDocuments)
        XCTAssertTrue(SyncBackend.webdav.usesRemoteStorage)
        XCTAssertFalse(SyncBackend.webdav.usesICloudDocuments)
    }

    func testICloudInspectionTreatsMissingOrEmptyDirectoriesAsEmpty() throws {
        let missing = temporaryDirectory.appendingPathComponent("Missing")
        XCTAssertEqual(
            ICloudModuleStorage.inspectExistingContent(documentsURL: missing),
            .empty
        )

        let notes = temporaryDirectory.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("ignore me".utf8).write(
            to: notes.appendingPathComponent("readme.txt")
        )
        try FileManager.default.createDirectory(
            at: notes.appendingPathComponent("directory.lamp"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            ICloudModuleStorage.inspectExistingContent(documentsURL: temporaryDirectory),
            .empty
        )
    }

    func testICloudInspectionDetectsModuleAndPlaceholderFiles() throws {
        let notes = temporaryDirectory.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data([0x01]).write(to: notes.appendingPathComponent("notes.lamp"))

        XCTAssertEqual(
            ICloudModuleStorage.inspectExistingContent(documentsURL: temporaryDirectory),
            .hasContent
        )

        try FileManager.default.removeItem(at: notes.appendingPathComponent("notes.lamp"))
        try Data([0x01]).write(to: notes.appendingPathComponent(".notes.lamp.icloud"))

        XCTAssertEqual(
            ICloudModuleStorage.inspectExistingContent(documentsURL: temporaryDirectory),
            .hasContent
        )
    }

    func testICloudInspectionDetectsUserSettingsDatabase() throws {
        let userData = temporaryDirectory.appendingPathComponent("UserData")
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try Data([0x01]).write(
            to: userData.appendingPathComponent(".user-settings.db.icloud")
        )

        XCTAssertEqual(
            ICloudModuleStorage.inspectExistingContent(documentsURL: temporaryDirectory),
            .hasContent
        )
    }

    func testLegacySyncSettingsJSONDecodesWithoutReconciliationField() throws {
        let data = Data(#"{"backend":"none"}"#.utf8)
        let settings = try JSONDecoder().decode(SyncSettings.self, from: data)

        XCTAssertEqual(settings.backend, .none)
        XCTAssertNil(settings.backendSelectionWasExplicit)
        XCTAssertNil(settings.legacyICloudReconciliationPending)
    }

    func testBundledKJVIsUnavailableInUnitedKingdomStorefronts() {
        for countryCode in ["GBR", "GB", "UK", "gbr"] {
            XCTAssertFalse(
                BundledContentTerritoryRules.allowsBundledTranslation(
                    id: "KJV",
                    countryCode: countryCode
                )
            )
            XCTAssertFalse(
                BundledContentTerritoryRules.allowsBundledTranslation(
                    id: "KJVs",
                    countryCode: countryCode
                )
            )
        }
    }

    func testBundledKJVIsAvailableOutsideUnitedKingdom() {
        for translationId in ["KJV", "KJVs"] {
            for countryCode in ["USA", "CAN", "AUS", "FRA"] {
                XCTAssertTrue(
                    BundledContentTerritoryRules.allowsBundledTranslation(
                        id: translationId,
                        countryCode: countryCode
                    )
                )
            }
        }
    }

    func testBundledKJVFailsClosedWithoutResolvedStorefront() {
        for translationId in ["KJV", "KJVs"] {
            XCTAssertFalse(
                BundledContentTerritoryRules.allowsBundledTranslation(
                    id: translationId,
                    countryCode: nil
                )
            )
        }
    }

    func testUnrestrictedBundledTranslationsRemainAvailableEverywhere() {
        for countryCode in [nil, "GBR", "USA"] as [String?] {
            XCTAssertTrue(
                BundledContentTerritoryRules.allowsBundledTranslation(
                    id: "BSBs",
                    countryCode: countryCode
                )
            )
        }
    }

    func testBookModuleTypeDetectionRequiresBothBookTables() {
        XCTAssertEqual(
            ModuleType.detected(fromTableNames: ["book_modules", "book_sections"]),
            .book
        )
        XCTAssertNil(ModuleType.detected(fromTableNames: ["book_modules"]))
    }

    func testBookJSONDescriptorCountsNestedSectionsAndMedia() throws {
        let data = Data(#"""
        {
          "meta": {"id":"sample-book","type":"book","title":"Sample Book","author":"A. Reader"},
          "sections": [
            {"id":"part-1","type":"part","title":"Part One","sections":[
              {"id":"chapter-1","type":"chapter","title":"Chapter One","content":[]},
              {"id":"chapter-2","type":"chapter","title":"Chapter Two","content":[]}
            ]}
          ],
          "media": [
            {"id":"cover","type":"image","filename":"cover.jpg","mimeType":"image/jpeg"}
          ]
        }
        """#.utf8)

        let descriptor = try BookJSONImportDescriptor.decode(from: data)

        XCTAssertEqual(descriptor.id, "sample-book")
        XCTAssertEqual(descriptor.title, "Sample Book")
        XCTAssertEqual(descriptor.author, "A. Reader")
        XCTAssertEqual(descriptor.sectionCount, 3)
        XCTAssertEqual(descriptor.mediaReferences.map(\.id), ["cover"])
    }

    func testBookJSONDescriptorRejectsMediaPathTraversal() {
        let data = Data(#"""
        {
          "meta": {"id":"unsafe-book","type":"book","title":"Unsafe","language":"en"},
          "sections": [{"id":"one","type":"chapter","title":"One","content":[]}],
          "media": [{"id":"cover","type":"image","filename":"../cover.jpg","mimeType":"image/jpeg"}]
        }
        """#.utf8)

        XCTAssertThrowsError(try BookJSONImportDescriptor.decode(from: data)) { error in
            XCTAssertEqual(error as? BookJSONImportError, .unsafeMediaFilename)
        }
    }

    func testBookAnnotatedTextDecodesScriptureAndFootnoteLinks() throws {
        let data = Data(#"""
        {
          "text": "See note",
          "annotations": [
            {"type":"scripture","start":0,"end":3,"data":{"refs":[{"sv":43003016,"ev":43003017}]}},
            {"type":"footnote","start":4,"end":8,"data":{"footnoteId":"note-1"}}
          ],
          "footnote_refs": [{"id":"note-2","offset":8}]
        }
        """#.utf8)

        let text = try JSONDecoder().decode(BookAnnotatedText.self, from: data)

        XCTAssertEqual(text.annotations?.first?.data?.refs?.first?.sv, 43_003_016)
        XCTAssertEqual(text.annotations?.last?.data?.footnoteId, "note-1")
        XCTAssertEqual(text.footnoteReferences?.first?.id, "note-2")
    }

    func testBookSectionHierarchyPreservesNestedAndOrphanedSections() {
        func section(_ id: String, parent: String? = nil, depth: Int = 0) -> BookSection {
            BookSection(
                id: id,
                moduleId: "sample",
                sectionId: id,
                parentId: parent,
                sectionType: depth == 0 ? "part" : "chapter",
                number: nil,
                title: id.capitalized,
                subtitle: nil,
                depth: depth,
                orderIndex: 0,
                keyScripturesJson: nil,
                contentJson: "[]",
                searchText: id
            )
        }
        let sections = [
            section("sample:part"),
            section("sample:chapter", parent: "sample:part", depth: 1),
            section("sample:orphan", parent: "sample:missing", depth: 1),
        ]

        let roots = BookSectionHierarchy.roots(from: sections)

        XCTAssertEqual(roots.map(\.id), ["sample:part", "sample:orphan"])
        XCTAssertEqual(roots.first?.children?.map(\.id), ["sample:chapter"])
    }

    func testBookReadingProgressRoundTripsPerModule() throws {
        let suiteName = "BookReadingProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = BookReadingProgressStore(defaults: defaults)

        store.save(sectionID: "book-a:chapter-2", for: "book-a")
        store.save(sectionID: "book-b:chapter-7", for: "book-b")

        XCTAssertEqual(store.sectionID(for: "book-a"), "book-a:chapter-2")
        XCTAssertEqual(store.sectionID(for: "book-b"), "book-b:chapter-7")
    }

    func testBookJSONImportsThroughSharedCompilerWithSiblingMedia() async throws {
        let moduleID = "book-import-test-\(UUID().uuidString.lowercased())"
        let sourceDirectory = temporaryDirectory.appendingPathComponent(moduleID, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let jsonURL = sourceDirectory.appendingPathComponent("source.json")
        let coverURL = sourceDirectory.appendingPathComponent("cover.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: coverURL)
        let json = """
        {
          "meta": {
            "schemaVersion": "1.0",
            "id": "\(moduleID)",
            "type": "book",
            "title": "Imported Book",
            "language": "en",
            "coverMediaId": "cover"
          },
          "sections": [
            {
              "id": "chapter-1",
              "type": "chapter",
              "title": "Chapter One",
              "content": [
                {"type": "paragraph", "content": {"text": "A tested paragraph."}}
              ]
            }
          ],
          "media": [
            {"id":"cover","type":"image","filename":"cover.jpg","mimeType":"image/jpeg"}
          ]
        }
        """
        try Data(json.utf8).write(to: jsonURL)
        defer {
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
            try? ModuleMediaStorage.shared.deleteAllMedia(for: moduleID)
        }

        try await ModuleSyncManager.shared.importModuleDocumentFromFile(
            url: jsonURL,
            moduleType: .book
        )

        XCTAssertEqual(try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Imported Book")
        XCTAssertEqual(try ModuleDatabase.shared.getBookSections(moduleId: moduleID).count, 1)
        let mediaRef = try XCTUnwrap(try ModuleDatabase.shared.getBookModule(id: moduleID)?.coverMediaReference)
        XCTAssertNotNil(ModuleMediaStorage.shared.getMediaURL(for: mediaRef, moduleId: moduleID))
    }
}
