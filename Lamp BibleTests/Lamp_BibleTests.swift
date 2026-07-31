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
}
