//
//  Lamp_BibleTests.swift
//  Lamp BibleTests
//
//  Created by Matthew Bennett on 2023-10-14.
//

import XCTest
import GRDB
import LampModuleKit
@testable import Lamp_Bible

final class Lamp_BibleTests: XCTestCase {
    private var temporaryDirectory: URL!

    func testSharedReferenceLinksOpenInIOS() throws {
        let passage = try XCTUnwrap(URL(
            string: "lampbible://reference/john3:16-18?translation=KJV"
        ))
        guard case .verse(let start, let end, let translation) = LampbibleURL.parse(passage) else {
            return XCTFail("The shared passage format should open in the iOS reader")
        }
        XCTAssertEqual(start, 43_003_016)
        XCTAssertEqual(end, 43_003_018)
        XCTAssertEqual(translation, "KJV")

        let reading = try XCTUnwrap(URL(
            string: "lampbible://reading/43003016/43003018?external=1"
        ))
        guard case .reading(let readingStart, let readingEnd, let external) =
            LampbibleURL.parse(reading) else {
            return XCTFail("The shared reading format should remain available")
        }
        XCTAssertEqual(readingStart, start)
        XCTAssertEqual(readingEnd, end)
        XCTAssertTrue(external)
    }

    func testDevotionalMarkdownRetainsNestedFrontmatter() throws {
        let markdown = """
        ---
        id: "hope"
        title: "Living Hope"
        tags: ["hope", "grace"]
        series:
          id: "series-1"
          name: "Daily Hope"
          order: 2
        keyScriptures:
          - ref: "John 1:1"
            sv: 43001001
            ev: 43001002
        ---

        Hope begins here.
        """
        let parsed = try XCTUnwrap(MarkdownDevotionalConverter.parseMarkdown(markdown))
        XCTAssertEqual(parsed.meta.tags, ["hope", "grace"])
        XCTAssertEqual(parsed.meta.series?.name, "Daily Hope")
        XCTAssertEqual(parsed.meta.series?.order, 2)
        XCTAssertEqual(parsed.meta.keyScriptures?.first?.sv, 43_001_001)
        XCTAssertEqual(parsed.meta.keyScriptures?.first?.ev, 43_001_002)
    }

    func testNotesMarkdownRetainsFootnoteDefinitions() throws {
        let markdown = """
        ---
        book: John
        bookNumber: 43
        ---

        ## Chapter 1

        ### 1:1

        The Word[^one].

        ---

        [^one]: An explanatory footnote.
        """
        let notes = try NotesImportExportManager.shared.parseMarkdownToNotes(
            content: markdown, filename: "John.md"
        )
        XCTAssertEqual(notes.chapter(1)?.verses?.first?.footnotes?.first?.plainText,
            "An explanatory footnote.")
    }

    func testDevotionalMarkdownUsesSharedRichContentProjection() throws {
        let blocks: [DevotionalContentBlock] = [
            .heading("Hope", level: 2),
            .blockquote("First line\nSecond line"),
            .image(mediaId: "photo", caption: "Sunrise"),
            .audio(mediaId: "prayer", caption: "Prayer"),
            .table(headers: ["A", "B"], rows: [["1", "2"]]),
        ]
        let markdown = MarkdownDevotionalConverter.blocksToMarkdown(blocks)
        XCTAssertEqual(markdown, """
        ## Hope

        > First line\u{20}\u{20}
        > Second line

        ![Sunrise](media/photo)

        [Prayer](media/prayer)

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """)

        let structured = DevotionalContent.structured(DevotionalStructuredContent(
            introduction: [.paragraph("Opening")],
            sections: [DevotionalSection(
                id: "section", level: 2, title: "Middle",
                blocks: [.paragraph("Body")],
                subsections: [DevotionalSection(
                    id: "subsection", level: 3, title: "Deeper",
                    blocks: [.paragraph("Inside")], subsections: nil
                )]
            )],
            conclusion: [.paragraph("Closing")]
        ))
        let devotional = Devotional(meta: DevotionalMeta(title: "Test"), content: structured)
        XCTAssertEqual(MarkdownDevotionalConverter.contentToMarkdown(devotional),
            "Opening\n\n## Middle\n\nBody\n\n### Deeper\n\nInside\n\nClosing")
        XCTAssertTrue(MarkdownDevotionalConverter.shouldRetainContentJSON(devotional))
        let revised = try MarkdownDevotionalConverter.revisingContent(
            structured,
            with: "Opening\n\n## Middle\n\nBody\n\n### Deeper\n\nChanged\n\nClosing"
        )
        guard case .structured(let retained) = revised else {
            return XCTFail("A body edit should keep the section tree")
        }
        XCTAssertEqual(retained.sections?.first?.id, "section")
        XCTAssertEqual(retained.sections?.first?.subsections?.first?.id, "subsection")
        XCTAssertEqual(retained.sections?.first?.subsections?.first?.blocks?.first?.content?.text,
            "Changed")
        let plain = Devotional(meta: DevotionalMeta(title: "Plain"),
            content: .blocks([.paragraph("Draft")]))
        XCTAssertFalse(MarkdownDevotionalConverter.shouldRetainContentJSON(plain))
    }

    func testDevotionalMarkdownUsesSharedRichBlockParser() {
        let markdown = """
        ##Heading without a space

        A __bold__ and _italic_ [link](https://example.com)[^note].

        1. First

          1. Child
            continuation
        2. Second

        [^note]: Footnote body

        ![Sunrise](media/photo)

        [Prayer](media/prayer)

        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdown)
        XCTAssertEqual(blocks.map(\.type), [
            .heading, .paragraph, .list, .image, .audio, .table,
        ])
        XCTAssertEqual(blocks[0].content?.text, "Heading without a space")
        XCTAssertEqual(blocks[1].content?.text, "A bold and italic link.")
        XCTAssertEqual(blocks[1].content?.annotations?.count, 3)
        XCTAssertEqual(blocks[1].content?.footnoteRefs?.first?.id, "note")
        XCTAssertEqual(blocks[2].items?.count, 2)
        XCTAssertEqual(blocks[2].items?.first?.children?.first?.content.text,
            "Child continuation")
        XCTAssertEqual(blocks[3].alignment, .center)
        XCTAssertEqual(blocks[4].showWaveform, true)
        XCTAssertEqual(blocks[5].tableData?.rows, [["1", "2"]])
    }

    func testDevotionalOutlineEditKeepsSectionIdentityThroughIOSBridge() throws {
        let original = DevotionalContent.structured(DevotionalStructuredContent(
            introduction: [.paragraph("Opening")],
            sections: [
                DevotionalSection(id: "alpha", level: 2, title: "Alpha",
                    blocks: [.paragraph("First")], subsections: nil),
                DevotionalSection(id: "beta", level: 2, title: "Beta",
                    blocks: [.paragraph("Second")], subsections: nil),
            ],
            conclusion: [.paragraph("Closing")]
        ))
        let edited = "Opening\n\n## Beta\n\nSecond\n\n## New\n\nAdded\n\n## Alpha\n\nFirst\n\nClosing"
        let revised = try MarkdownDevotionalConverter.revisingContent(original, with: edited)
        guard case .structured(let retained) = revised else {
            return XCTFail("An outline edit should keep structured content")
        }
        XCTAssertEqual(retained.sections?.map(\.title), ["Beta", "New", "Alpha"])
        XCTAssertEqual(retained.sections?.map(\.id), ["beta", nil, "alpha"])
        XCTAssertEqual(retained.introduction?.first?.content?.text, "Opening")
        XCTAssertEqual(retained.conclusion?.first?.content?.text, "Closing")
        let devotional = Devotional(meta: DevotionalMeta(title: "Test"), content: revised)
        XCTAssertEqual(MarkdownDevotionalConverter.contentToMarkdown(devotional), edited)
    }

    func testLeadingMarkdownLinkLoadsAsMarkdown() {
        let authored = "[Prayer](media/audio-id)\n\nA reflection."
        let devotional = Devotional(
            meta: DevotionalMeta(title: "Prayer"),
            content: .blocks(MarkdownDevotionalConverter.markdownToBlocks(authored)),
            markdownContent: authored
        )
        let row = DevotionalEntry(from: devotional, moduleId: "personal-devotionals")
        let restored = row.toDevotional()
        XCTAssertEqual(restored?.markdownContent, authored)
        var example = row
        example.contentJson = "{\"example\": true}"
        XCTAssertEqual(example.toDevotional()?.markdownContent, example.contentJson)
    }

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

    @MainActor
    func testFailedSwitchOnlyKeepsLocalNotesAndOldBackend() async throws {
        let coordinator = SyncCoordinator.shared
        let previousSettings = coordinator.settings
        var localSettings = previousSettings
        localSettings.backend = .none
        localSettings.webdavURL = nil
        let module = Module(
            id: "switch-only-\(UUID().uuidString)",
            type: .notes,
            name: "Switch test",
            filePath: "switch-test.lamp"
        )
        let note = NoteEntry(
            moduleId: module.id,
            verseId: 1_001_001,
            content: "Keep this note if target setup fails"
        )

        var workError: Error?
        do {
            try UserDatabase.shared.saveSyncSettings(localSettings)
            await coordinator.reloadSettings()
            try ModuleDatabase.shared.saveModule(module)
            try ModuleDatabase.shared.saveNoteEntry(note)

            do {
                try await coordinator.switchBackend(to: .webdav, migrateData: false)
                XCTFail("An unconfigured WebDAV backend must stop the switch")
            } catch SyncError.notConfigured {
                // Publishing the target could not begin.
            }
            XCTAssertNotNil(try ModuleDatabase.shared.getNoteEntry(id: note.id))
            XCTAssertEqual(coordinator.settings.backend, .none)
        } catch {
            workError = error
        }

        try? ModuleDatabase.shared.deleteModule(id: module.id)
        try UserDatabase.shared.saveSyncSettings(previousSettings)
        await coordinator.reloadSettings()
        if let workError { throw workError }
    }

    @MainActor
    func testPendingBackendSwitchRestoresOldProviderAndKeepsNotes() async throws {
        let coordinator = SyncCoordinator.shared
        let originalSettings = coordinator.settings
        var previous = originalSettings
        previous.backend = .none
        previous.backendSelectionWasExplicit = true
        var attempted = previous
        attempted.backend = .webdav

        let module = Module(
            id: "pending-switch-\(UUID().uuidString)",
            type: .notes,
            name: "Pending switch test",
            filePath: "pending-switch-test.lamp"
        )
        let note = NoteEntry(
            moduleId: module.id,
            verseId: 1_001_001,
            content: "Keep this note while restoring the provider"
        )

        var workError: Error?
        do {
            try UserDatabase.shared.saveSyncSettings(previous)
            await coordinator.reloadSettings()
            try ModuleDatabase.shared.saveModule(module)
            try ModuleDatabase.shared.saveNoteEntry(note)

            // Recreate the durable state after provider persistence but before
            // the module wipe, as if the app stopped at that point.
            try ModuleDatabase.shared.prepareBackendTransition(previousSettings: previous)
            try UserDatabase.shared.saveSyncSettings(attempted)
            await coordinator.reloadSettings()

            XCTAssertEqual(coordinator.settings.backend, .none)
            XCTAssertEqual(UserDatabase.shared.getSyncSettings()?.backend, SyncBackend.none)
            XCTAssertNil(try ModuleDatabase.shared.pendingBackendTransition())
            XCTAssertNotNil(try ModuleDatabase.shared.getNoteEntry(id: note.id))
        } catch {
            workError = error
        }

        try? ModuleDatabase.shared.clearPendingBackendTransition()
        try? ModuleDatabase.shared.deleteModule(id: module.id)
        try UserDatabase.shared.saveSyncSettings(originalSettings)
        await coordinator.reloadSettings()
        if let workError { throw workError }
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

    func testICloudSettingsTokenChangesWithBytesDespiteSameModificationDate() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let userData = documents.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let file = userData.appendingPathComponent("user.db")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let storage = ICloudModuleStorage(documentsURL: documents)

        try Data("first body".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let first = await storage.getChangeToken(path: "UserData/user.db")

        try Data("other body".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let second = await storage.getChangeToken(path: "UserData/user.db")

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, LampSyncContentRevision.token(for: Data("other body".utf8)))
        let readBack = try await storage.readFile(path: "UserData/user.db")
        XCTAssertEqual(readBack, Data("other body".utf8))
    }

    func testICloudGuardedModuleWriteRejectsChangedBody() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let file = notes.appendingPathComponent("guarded.lamp")
        let original = Data("original module".utf8)
        let updated = Data("updated module".utf8)
        try original.write(to: file)
        let storage = ICloudModuleStorage(documentsURL: documents)
        let observed = LampSyncContentRevision.digest(for: original)

        try await storage.writeModuleFile(
            type: .notes, fileName: "guarded.lamp",
            data: updated, matching: observed
        )
        XCTAssertEqual(try Data(contentsOf: file), updated)
        do {
            try await storage.writeModuleFile(
                type: .notes, fileName: "guarded.lamp",
                data: Data("stale write".utf8), matching: observed
            )
            XCTFail("A changed body must be rejected during coordination")
        } catch SyncError.conflictDetected {
            XCTAssertEqual(try Data(contentsOf: file), updated)
        }
    }

    func testICloudGuardedModuleCreateRejectsRemotePlaceholder() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let placeholder = notes.appendingPathComponent(".remote-note.lamp.icloud")
        let module = notes.appendingPathComponent("remote-note.lamp")
        let remote = Data("remote module".utf8)
        try remote.write(to: placeholder)
        let storage = ICloudModuleStorage(documentsURL: documents) { url in
            try FileManager.default.moveItem(at: placeholder, to: url)
        }

        do {
            try await storage.writeModuleFile(
                type: .notes, fileName: "remote-note.lamp",
                data: Data("local module".utf8), matching: nil
            )
            XCTFail("A placeholder must not be treated as an absent module")
        } catch SyncError.conflictDetected {
            XCTAssertEqual(try Data(contentsOf: module), remote)
        }
    }

    func testICloudGuardedSettingsWriteRejectsChangedBody() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let userData = documents.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let file = userData.appendingPathComponent("user-settings.db")
        let original = Data("original settings".utf8)
        let updated = Data("updated settings".utf8)
        try original.write(to: file)
        let storage = ICloudModuleStorage(documentsURL: documents)
        let observed = LampSyncContentRevision.token(for: original)

        try await storage.writeFile(
            path: "UserData/user-settings.db", data: updated, matching: observed
        )
        XCTAssertEqual(try Data(contentsOf: file), updated)
        do {
            try await storage.writeFile(
                path: "UserData/user-settings.db",
                data: Data("stale write".utf8), matching: observed
            )
            XCTFail("A changed settings body must be rejected during coordination")
        } catch SyncError.conflictDetected {
            XCTAssertEqual(try Data(contentsOf: file), updated)
        }
    }

    func testICloudUnbasedMediaWritePreservesDifferentRemoteBody() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let mediaDirectory = documents.appendingPathComponent(
            "DevotionalMedia/entry", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: mediaDirectory, withIntermediateDirectories: true
        )
        let file = mediaDirectory.appendingPathComponent("photo.jpg")
        let local = Data("local photo".utf8)
        let storage = ICloudModuleStorage(documentsURL: documents)

        try await storage.writeFileIfAbsentOrUnchanged(
            path: "DevotionalMedia/entry/photo.jpg", data: local
        )
        try await storage.writeFileIfAbsentOrUnchanged(
            path: "DevotionalMedia/entry/photo.jpg", data: local
        )
        XCTAssertEqual(try Data(contentsOf: file), local)

        let remoteEdit = Data("remote edit".utf8)
        try remoteEdit.write(to: file)
        do {
            try await storage.writeFileIfAbsentOrUnchanged(
                path: "DevotionalMedia/entry/photo.jpg", data: local
            )
            XCTFail("A media upload without a base must preserve a different remote body")
        } catch SyncError.conflictDetected {
            XCTAssertEqual(try Data(contentsOf: file), remoteEdit)
        }
    }

    func testICloudGuardedFileWriteRejectsRemotePlaceholder() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let userData = documents.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        let placeholder = userData.appendingPathComponent(".user-settings.db.icloud")
        try Data("remote settings".utf8).write(to: placeholder)
        let storage = ICloudModuleStorage(documentsURL: documents)

        do {
            try await storage.writeFile(
                path: "UserData/user-settings.db",
                data: Data("local settings".utf8), matching: nil
            )
            XCTFail("A placeholder must not be treated as an absent remote file")
        } catch SyncError.conflictDetected {
            XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: userData.appendingPathComponent("user-settings.db").path
            ))
        }
    }

    @MainActor
    func testICloudDigestUpgradeKeepsLegacySettingsMergeBase() async throws {
        let tokenKey = "UserSettingsSync.remoteChangeToken"
        let baseKey = "UserSettingsSync.readingsBase.v1"
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousBase = UserDefaults.standard.object(forKey: baseKey)
        defer {
            UserDefaults.standard.set(previousToken, forKey: tokenKey)
            UserDefaults.standard.set(previousBase, forKey: baseKey)
        }

        try UserDatabase.shared.checkpointForSync()
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let userData = documents.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: UserDatabase.shared.databaseURL,
            to: userData.appendingPathComponent("user-settings.db")
        )

        let oldToken = "1700000000"
        let snapshot = try UserDatabase.shared.syncSnapshot()
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: "icloud-documents",
            token: oldToken,
            readingIDs: Set(snapshot.readings.map(\.id)),
            settings: snapshot.settings
        )
        UserDefaults.standard.set(oldToken, forKey: tokenKey)
        UserDefaults.standard.set(try JSONEncoder().encode(base), forKey: baseKey)

        let storage = ICloudModuleStorage(documentsURL: documents)
        let observed = try await UserSettingsSyncManager.shared.readRemoteSettings(from: storage)
        let remote = try XCTUnwrap(observed)
        XCTAssertTrue(remote.token?.hasPrefix("sha256:") == true)
        XCTAssertNotNil(UserSettingsSyncManager.shared.applicableBase(
            for: remote,
            storage: storage
        ))
    }

    func testICloudListingDownloadsHiddenModulePlaceholder() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let placeholder = notes.appendingPathComponent(".remote-note.lamp.icloud")
        let body = Data("remote module".utf8)
        try body.write(to: placeholder)
        let storage = ICloudModuleStorage(documentsURL: documents) { fileURL in
            try FileManager.default.moveItem(at: placeholder, to: fileURL)
        }

        let listed = try await storage.listModuleFiles(type: .notes)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, "remote-note")
        XCTAssertEqual(listed.first?.filePath, "remote-note.lamp")
        XCTAssertEqual(
            listed.first?.fileHash,
            String(LampSyncContentRevision.token(for: body).dropFirst("sha256:".count))
        )
        let imported = try await storage.readModuleFile(type: .notes, fileName: "remote-note.lamp")
        XCTAssertEqual(imported, body)
    }

    func testICloudListingRecognizesUppercasePortableExtension() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("portable module".utf8).write(
            to: notes.appendingPathComponent("Upper.LAMP")
        )

        let listed = try await ICloudModuleStorage(documentsURL: documents)
            .listModuleFiles(type: .notes)
        XCTAssertEqual(listed.map(\.id), ["Upper"])
        XCTAssertEqual(listed.map(\.filePath), ["Upper.LAMP"])
    }

    func testICloudListingFailureDoesNotAppearAsEmptyFolder() async throws {
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: documents.appendingPathComponent("Notes"))
        let storage = ICloudModuleStorage(documentsURL: documents)

        do {
            _ = try await storage.listModuleFiles(type: .notes)
            XCTFail("An unreadable module directory must stop the sync")
        } catch {
            // A failed pull must not be treated as an empty provider.
        }
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

    func testBundledKJVsIsAvailableWithoutStorefrontResolution() throws {
        let database = BundledModuleDatabase.shared
        XCTAssertTrue(try database.isTranslationBundled(id: "KJVs"))
        XCTAssertNotNil(try database.getTranslation(id: "KJVs"))
        XCTAssertGreaterThan(try database.getTotalVerseCount(translationId: "KJVs"), 0)
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
            {"id":"cover","type":"image","filename":"chapters/one/cover.jpg","mimeType":"image/jpeg"}
          ]
        }
        """#.utf8)

        let descriptor = try BookJSONImportDescriptor.decode(from: data)

        XCTAssertEqual(descriptor.id, "sample-book")
        XCTAssertEqual(descriptor.title, "Sample Book")
        XCTAssertEqual(descriptor.author, "A. Reader")
        XCTAssertEqual(descriptor.sectionCount, 3)
        XCTAssertEqual(descriptor.mediaReferences.map(\.id), ["cover"])
        XCTAssertEqual(descriptor.mediaReferences.first?.filename, "chapters/one/cover.jpg")
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

    func testBookSectionKeepsValidBlocksAroundMalformedEntry() {
        let section = BookSection(
            id: "book:chapter", moduleId: "book", sectionId: "chapter",
            parentId: nil, sectionType: "chapter", number: nil,
            title: "Chapter", subtitle: nil, depth: 0, orderIndex: 0,
            keyScripturesJson: nil,
            contentJson: #"[{"type":"paragraph","content":{"text":"First"}},{"type":42},{"type":"heading","content":{"text":"Last"}}]"#,
            searchText: "First Last"
        )
        XCTAssertEqual(section.contentBlocks.map(\.type), ["paragraph", "heading"])
    }

    func testBookSectionDecodesRichTableCells() {
        let section = BookSection(
            id: "book:table", moduleId: "book", sectionId: "table",
            parentId: nil, sectionType: "chapter", number: nil,
            title: "Table", subtitle: nil, depth: 0, orderIndex: 0,
            keyScripturesJson: nil,
            contentJson: #"[{"type":"table","columnCount":2,"rows":[{"cells":[{"column":0,"colSpan":2,"header":true,"content":{"text":"John 1:1","annotations":[{"type":"scripture","start":0,"end":8,"data":{"sv":43001001,"source":"KJV"}}]}}]}]}]"#,
            searchText: "John 1:1"
        )
        let cell = section.contentBlocks.first?.rows.first?.cells.first
        XCTAssertEqual(cell?.columnSpan, 2)
        XCTAssertEqual(cell?.content.annotations.first?.data?.source, "KJV")
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

        XCTAssertEqual(text.annotations.first?.data?.references.first?.startReference, 43_003_016)
        XCTAssertEqual(text.annotations.last?.data?.footnoteID, "note-1")
        XCTAssertEqual(text.footnoteReferences.first?.id, "note-2")
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
        let coverURL = sourceDirectory.appendingPathComponent("chapters/one/cover.jpg")
        try FileManager.default.createDirectory(
            at: coverURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
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
            {"id":"cover","type":"image","filename":"chapters/one/cover.jpg","mimeType":"image/jpeg"}
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

    func testPortableArchiveImportsModuleIdentityFromHashedFilenameOnce() async throws {
        let moduleID = "archive-book-test-\(UUID().uuidString.lowercased())"
        let source = temporaryDirectory.appendingPathComponent("Source", isDirectory: true)
        let modules = source.appendingPathComponent(LampPortableBackupLayout.modulesDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(moduleID)", "type":"book", "title":"Archive Book", "language":"en"},
          "sections": [{"id":"chapter-1", "type":"chapter", "title":"Chapter One",
            "content":[{"type":"paragraph", "content":{"text":"Archive content."}}]}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(moduleID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8),
            sourceFilename: "\(moduleID).json",
            destinationURL: compiledURL
        )
        try FileManager.default.copyItem(
            at: compiledURL,
            to: modules.appendingPathComponent("hashed-storage-key.lamp")
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
        let archive = try LampSyncArchive.create(from: source)
        let readState = ArchiveReadState()
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"archive-revision\"",
            state: readState
        )
        let suiteName = "portable-archive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
        }

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote,
            source: suiteName,
            defaults: defaults
        )
        XCTAssertEqual(try ModuleDatabase.shared.getBookModule(id: moduleID)?.title, "Archive Book")
        XCTAssertNil(try ModuleDatabase.shared.getBookModule(id: "hashed-storage-key"))
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote,
            source: suiteName,
            defaults: defaults
        )
        let readCount = await readState.count()
        XCTAssertEqual(readCount, 1)
    }

    func testPortableArchiveImportsCompiledPlanWithoutLocalDatabaseColumns() async throws {
        let planID = "archive-plan-\(UUID().uuidString.lowercased())"
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(planID)",
                   "type":"plan", "name":"Archive Plan", "duration":1},
          "days":[{"day":1,"readings":[{"sv":1001001,"ev":1001002}]}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(planID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: "\(planID).json",
            destinationURL: compiledURL
        )
        let compiled = try Data(contentsOf: compiledURL)
        let digest = LampSyncContentRevision.digest(for: compiled)
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 1, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Modules/opaque-plan.lamp",
                  data: compiled, modifiedAt: .distantPast)
        ])
        let source = "archive-plan-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
        defer {
            defaults.removePersistentDomain(forName: source)
            try? ModuleDatabase.shared.write { db in
                try db.execute(sql: "DELETE FROM plans WHERE id = ?", arguments: [planID])
            }
        }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"plan-revision\"",
            state: ArchiveReadState()
        )

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: source, defaults: defaults
        )
        XCTAssertEqual(try ModuleDatabase.shared.getPlan(id: planID)?.name, "Archive Plan")
        XCTAssertEqual(try ModuleDatabase.shared.getPlanDays(planId: planID).count, 1)
        let installed = try ModuleDatabase.shared.read { db in
            try Row.fetchOne(
                db, sql: "SELECT file_path, file_hash FROM plans WHERE id = ?",
                arguments: [planID]
            )
        }
        XCTAssertEqual(installed?["file_path"] as String?, "\(planID).lamp")
        XCTAssertEqual(installed?["file_hash"] as String?, digest)
    }

    func testPortableArchiveInspectsEveryModuleBeforeInstallingAny() async throws {
        let moduleID = "archive-preflight-\(UUID().uuidString.lowercased())"
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(moduleID)", "type":"book", "title":"Preflight Book", "language":"en"},
          "sections": [{"id":"chapter-1", "type":"chapter", "title":"Chapter One",
            "content":[{"type":"paragraph", "content":{"text":"Archive content."}}]}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(moduleID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8),
            sourceFilename: "\(moduleID).json",
            destinationURL: compiledURL
        )
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 2, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date()
        func entry(_ path: String, _ data: Data) -> LampSyncArchive.Entry {
            .init(
                path: path, data: data, modifiedAt: now,
                sha256: LampSyncContentRevision.digest(for: data)
            )
        }
        let archive = LampSyncArchive(entries: [
            entry(LampPortableBackupLayout.manifestPath, try encoder.encode(manifest)),
            entry("\(LampPortableBackupLayout.modulesDirectory)/a-valid.lamp", try Data(contentsOf: compiledURL)),
            entry("\(LampPortableBackupLayout.modulesDirectory)/z-invalid.lamp", Data("invalid SQLite".utf8))
        ])
        let suiteName = "archive-preflight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
        }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"preflight-revision\"",
            state: ArchiveReadState()
        )

        do {
            _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
                from: remote, source: suiteName, defaults: defaults
            )
            XCTFail("A damaged later module must reject the archive")
        } catch LampPortableModuleInspector.InspectionError.invalidArchive {
            XCTAssertNil(try ModuleDatabase.shared.getBookModule(id: moduleID))
            XCTAssertNil(defaults.data(forKey: ModuleSyncManager.portableArchiveImportStateKey))
        }
    }

    func testPortableArchiveRejectsLaterMissingImportSchemaBeforeInstallingFirst() async throws {
        let moduleID = "archive-schema-\(UUID().uuidString.lowercased())"
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(moduleID)", "type":"book", "title":"First Book", "language":"en"},
          "sections": [{"id":"chapter-1", "type":"chapter", "title":"Chapter One",
            "content":[{"type":"paragraph", "content":{"text":"Valid content."}}]}]
        }
        """
        let validURL = temporaryDirectory.appendingPathComponent("\(moduleID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: "\(moduleID).json",
            destinationURL: validURL
        )
        let invalidURL = temporaryDirectory.appendingPathComponent("invalid-book.sqlite")
        let parentColumns = LampPortableModuleInspector.bookModuleColumns
            .map { "\($0) TEXT" }.joined(separator: ", ")
        do {
            let queue = try DatabaseQueue(path: invalidURL.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE book_modules (\(parentColumns))")
                try db.execute(sql: "INSERT INTO book_modules (id) VALUES ('invalid-book')")
            }
        }
        let invalid = try (Data(contentsOf: invalidURL) as NSData)
            .compressed(using: .zlib) as Data
        let invalidDictionaryURL = temporaryDirectory
            .appendingPathComponent("invalid-dictionary.sqlite")
        do {
            let queue = try DatabaseQueue(path: invalidDictionaryURL.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES ('invalid-dictionary', 'dictionary')"
                )
                try db.execute(sql: """
                    CREATE TABLE dictionary_entries (
                        id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                        transliteration TEXT, pronunciation TEXT, senses_json TEXT
                    )
                    """)
            }
        }
        let invalidDictionary = try (Data(contentsOf: invalidDictionaryURL) as NSData)
            .compressed(using: .zlib) as Data
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 2, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let validData = try Data(contentsOf: validURL)
        defer {
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
        }
        for (broken, table) in [(invalid, "book_sections"),
                                (invalidDictionary, "dictionary_entries")] {
            let archive = LampSyncArchive(formatVersion: 1, entries: [
                .init(path: LampPortableBackupLayout.manifestPath,
                      data: manifestData, modifiedAt: .distantPast),
                .init(path: "Modules/a-valid.lamp",
                      data: validData, modifiedAt: .distantPast),
                .init(path: "Modules/z-invalid.lamp",
                      data: broken, modifiedAt: .distantPast)
            ])
            let source = "archive-schema-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
            defer { defaults.removePersistentDomain(forName: source) }
            let remote = ArchiveRemoteStore(
                data: try archive.compressedData(),
                revision: "\"schema-revision\"",
                state: ArchiveReadState()
            )

            do {
                _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
                    from: remote, source: source, defaults: defaults
                )
                XCTFail("A later module missing \(table) must reject the archive")
            } catch LampPortableModuleInspector.InspectionError.missingImportSchema(let missing) {
                XCTAssertEqual(missing, table)
                XCTAssertNil(try ModuleDatabase.shared.getBookModule(id: moduleID))
                XCTAssertNil(defaults.data(forKey: ModuleSyncManager.portableArchiveImportStateKey))
            }
        }
    }

    func testPortableArchiveLateSQLiteFailureRollsBackEarlierModule() async throws {
        let firstID = "archive-atomic-first-\(UUID().uuidString.lowercased())"
        let secondID = "archive-atomic-second-\(UUID().uuidString.lowercased())"
        let database = ModuleDatabase.shared
        defer {
            try? database.writeWithoutTransaction { db in
                try db.execute(sql: "DROP TRIGGER IF EXISTS temp.reject_late_archive_insert")
            }
            for id in [firstID, secondID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        func dictionary(_ id: String) async throws -> Data {
            let url = temporaryDirectory.appendingPathComponent("\(id).sqlite")
            let source = try DatabaseQueue(path: url.path)
            try await source.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES (?, 'dictionary')",
                    arguments: [id]
                )
                try db.execute(sql: """
                    CREATE TABLE dictionary_entries (
                        id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                        transliteration TEXT, pronunciation TEXT,
                        senses_json TEXT, metadata_json TEXT
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, 'G1', ?)",
                    arguments: ["\(id):G1", id, id]
                )
            }
            return try (Data(contentsOf: url) as NSData).compressed(using: .zlib) as Data
        }
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 2, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Modules/a-first.lamp",
                  data: try await dictionary(firstID), modifiedAt: .distantPast),
            .init(path: "Modules/z-second.lamp",
                  data: try await dictionary(secondID), modifiedAt: .distantPast)
        ])
        let source = "archive-atomic-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
        defer { defaults.removePersistentDomain(forName: source) }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"archive-atomic-revision\"",
            state: ArchiveReadState()
        )
        try database.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_late_archive_insert
                BEFORE INSERT ON dictionary_entries
                WHEN NEW.module_id = '\(secondID)'
                BEGIN SELECT RAISE(ABORT, 'late archive failure'); END
                """)
        }

        do {
            _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
                from: remote, source: source, defaults: defaults
            )
            XCTFail("A later SQL failure must roll back the whole local archive import")
        } catch {
            XCTAssertNil(try database.getModule(id: firstID))
            XCTAssertNil(try database.getModule(id: secondID))
            XCTAssertNil(defaults.data(forKey: ModuleSyncManager.portableArchiveImportStateKey))
        }

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER temp.reject_late_archive_insert")
        }
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: source, defaults: defaults
        )
        XCTAssertNotNil(try database.getModule(id: firstID))
        XCTAssertNotNil(try database.getModule(id: secondID))
    }

    func testPortableArchiveLateSQLiteFailureRollsBackEarlierNotesMerge() async throws {
        let notesID = "archive-atomic-notes-\(UUID().uuidString.lowercased())"
        let dictionaryID = "archive-atomic-dictionary-\(UUID().uuidString.lowercased())"
        let database = ModuleDatabase.shared
        defer {
            try? database.writeWithoutTransaction { db in
                try db.execute(sql: "DROP TRIGGER IF EXISTS temp.reject_archive_dictionary")
            }
            for id in [notesID, dictionaryID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        let notesURL = temporaryDirectory.appendingPathComponent("atomic-notes.sqlite")
        do {
            let source = try DatabaseQueue(path: notesURL.path)
            try await source.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES (?, 'notes')",
                    arguments: [notesID]
                )
                try db.execute(sql: """
                    CREATE TABLE note_entries (
                        id TEXT, module_id TEXT, verse_id INTEGER, book INTEGER,
                        chapter INTEGER, verse INTEGER, title TEXT, content TEXT,
                        last_modified INTEGER
                    )
                    """)
                try db.execute(sql: """
                    INSERT INTO note_entries
                    (id, module_id, verse_id, book, chapter, verse, content, last_modified)
                    VALUES (?, ?, 43003016, 43, 3, 16, 'incoming note', 1700000000)
                    """, arguments: ["\(notesID):43003016", notesID])
            }
        }
        let dictionaryURL = temporaryDirectory.appendingPathComponent("atomic-dictionary.sqlite")
        do {
            let source = try DatabaseQueue(path: dictionaryURL.path)
            try await source.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES (?, 'dictionary')",
                    arguments: [dictionaryID]
                )
                try db.execute(sql: """
                    CREATE TABLE dictionary_entries (
                        id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                        transliteration TEXT, pronunciation TEXT,
                        senses_json TEXT, metadata_json TEXT
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, 'G1', 'entry')",
                    arguments: ["\(dictionaryID):G1", dictionaryID]
                )
            }
        }
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 2, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Modules/a-notes.lamp",
                  data: try (Data(contentsOf: notesURL) as NSData).compressed(using: .zlib) as Data,
                  modifiedAt: .distantPast),
            .init(path: "Modules/z-dictionary.lamp",
                  data: try (Data(contentsOf: dictionaryURL) as NSData).compressed(using: .zlib) as Data,
                  modifiedAt: .distantPast)
        ])
        let source = "archive-atomic-editable-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
        defer { defaults.removePersistentDomain(forName: source) }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"archive-editable-revision\"",
            state: ArchiveReadState()
        )
        try database.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_archive_dictionary
                BEFORE INSERT ON dictionary_entries
                WHEN NEW.module_id = '\(dictionaryID)'
                BEGIN SELECT RAISE(ABORT, 'late archive failure'); END
                """)
        }

        do {
            _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
                from: remote, source: source, defaults: defaults
            )
            XCTFail("A later SQL failure must roll back the earlier notes merge")
        } catch {
            XCTAssertNil(try database.getModule(id: notesID))
            let notes = try database.read { db in
                try NoteEntry.filter(Column("module_id") == notesID).fetchAll(db)
            }
            XCTAssertTrue(notes.isEmpty)
            XCTAssertNil(defaults.data(forKey: ModuleSyncManager.portableArchiveImportStateKey))
        }

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER temp.reject_archive_dictionary")
        }
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: source, defaults: defaults
        )
        XCTAssertNotNil(try database.getModule(id: notesID))
        let notes = try database.read { db in
            try NoteEntry.filter(Column("module_id") == notesID).fetchAll(db)
        }
        XCTAssertEqual(notes.map(\.content), ["incoming note"])
    }

    func testPortableArchiveInstallsMoreModulesThanSQLiteAttachmentLimit() async throws {
        let moduleIDs = (0..<12).map {
            "archive-many-\($0)-\(UUID().uuidString.lowercased())"
        }
        let database = ModuleDatabase.shared
        defer {
            for id in moduleIDs {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: moduleIDs.count, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var entries: [LampSyncArchive.Entry] = [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast)
        ]
        for (index, id) in moduleIDs.enumerated() {
            let sourceURL = temporaryDirectory.appendingPathComponent("many-\(index).sqlite")
            do {
                let source = try DatabaseQueue(path: sourceURL.path)
                try await source.write { db in
                    try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                    try db.execute(
                        sql: "INSERT INTO module_format VALUES (?, 'dictionary')",
                        arguments: [id]
                    )
                    try db.execute(sql: """
                        CREATE TABLE dictionary_entries (
                            id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                            transliteration TEXT, pronunciation TEXT,
                            senses_json TEXT, metadata_json TEXT
                        )
                        """)
                    try db.execute(
                        sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, 'G1', ?)",
                        arguments: ["\(id):G1", id, id]
                    )
                }
            }
            entries.append(.init(
                path: "Modules/module-\(index).lamp",
                data: try (Data(contentsOf: sourceURL) as NSData)
                    .compressed(using: .zlib) as Data,
                modifiedAt: .distantPast
            ))
        }
        let archive = LampSyncArchive(formatVersion: 1, entries: entries)
        let source = "archive-many-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
        defer { defaults.removePersistentDomain(forName: source) }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"archive-many-revision\"",
            state: ArchiveReadState()
        )

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: source, defaults: defaults
        )
        for id in moduleIDs {
            XCTAssertNotNil(try database.getModule(id: id))
        }
    }

    func testPortableArchiveKeepsNewerLocalHighlights() async throws {
        let moduleID = "archive-highlights-\(UUID().uuidString.lowercased())"
        let json = """
        {
          "meta": {"schemaVersion":"1.0", "id":"\(moduleID)",
                   "type":"highlights", "name":"Remote Highlights",
                   "translationId":"ESV", "created":1700000000,
                   "lastModified":1700000100},
          "verses":[{"ref":43003016,
                     "highlights":[{"sc":0,"ec":3,"style":0,"color":"blue"}]}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(moduleID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: "\(moduleID).json",
            destinationURL: compiledURL
        )
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 1, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = LampSyncArchive(formatVersion: 1, entries: [
            .init(path: LampPortableBackupLayout.manifestPath,
                  data: try encoder.encode(manifest), modifiedAt: .distantPast),
            .init(path: "Modules/opaque-highlights.lamp",
                  data: try Data(contentsOf: compiledURL), modifiedAt: .distantPast)
        ])
        let database = ModuleDatabase.shared
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"highlight-revision\"",
            state: ArchiveReadState()
        )
        for pass in 0..<2 {
            let source = "archive-highlights-\(pass)-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: source))
            defer { defaults.removePersistentDomain(forName: source) }
            if pass == 1 {
                try database.write { db in
                    try db.execute(sql: """
                        UPDATE highlight_sets
                        SET name = 'Local Highlights', last_modified = 1700000200
                        WHERE module_id = ?
                        """, arguments: [moduleID])
                }
            }
            _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
                from: remote, source: source, defaults: defaults
            )
            let sets = try database.getHighlightSets(forModule: moduleID)
            XCTAssertEqual(sets.count, 1)
            XCTAssertEqual(sets.first?.name,
                           pass == 0 ? "Remote Highlights" : "Local Highlights")
            let count = try database.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM highlights
                    WHERE set_id IN (SELECT id FROM highlight_sets WHERE module_id = ?)
                    """, arguments: [moduleID])
            }
            XCTAssertEqual(count, 1)
        }
    }

    func testHighlightExportKeepsModuleIDSeparateFromSetID() async throws {
        let moduleID = "roundtrip-highlights-\(UUID().uuidString.lowercased())"
        let setID = UUID().uuidString
        let database = ModuleDatabase.shared
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }
        try database.saveModule(Module(
            id: moduleID, type: .highlights, name: "Highlights",
            filePath: "\(moduleID).lamp", fileHash: nil,
            isEditable: true
        ))
        try database.saveHighlightSet(HighlightSet(
            id: setID, moduleId: moduleID, name: "Highlights",
            translationId: "ESV", created: 1700000000,
            lastModified: 1700000100
        ))
        try database.saveHighlight(HighlightEntry(
            setId: setID, ref: 43003016, sc: 0, ec: 3
        ))

        let state = CapturedModuleBody()
        try await ModuleSyncManager.shared.exportModule(
            id: moduleID, to: CapturingModuleStorage(state: state)
        )
        let exported = await state.body()
        let body = try XCTUnwrap(exported)
        XCTAssertEqual(try LampPortableModuleInspector.inspect(
            compressedData: body, requireImportSchema: true
        ).id, moduleID)
        XCTAssertEqual(try LampWebDAVPersonalArchiveAdapter.highlightSetID(in: body), setID)

        try database.deleteAllEntriesForModule(moduleId: moduleID)
        try database.deleteModule(id: moduleID)
        let revision = LampSyncContentRevision.digest(for: body)
        try await ModuleSyncManager.shared.syncModuleType(
            .highlights,
            using: ModuleJSONStorage(
                moduleID: moduleID, moduleType: .highlights,
                hash: revision, data: body, fileName: "\(moduleID).lamp"
            )
        )
        XCTAssertEqual(try database.getHighlightSet(id: setID)?.moduleId, moduleID)
        XCTAssertEqual(try database.getHighlightCount(setId: setID), 1)

        // Old iOS exports had only the set ID in highlight_meta. The file's
        // canonical path supplies the module ID when that header is absent.
        try database.deleteAllEntriesForModule(moduleId: moduleID)
        try database.deleteModule(id: moduleID)
        let legacyURL = temporaryDirectory.appendingPathComponent("legacy-highlights.sqlite")
        let decompressed = try (body as NSData).decompressed(using: .zlib) as Data
        try decompressed.write(to: legacyURL)
        do {
            let source = try DatabaseQueue(path: legacyURL.path)
            try await source.write { db in
                try db.execute(sql: "DROP TABLE module_format")
            }
        }
        let legacyBody = try (Data(contentsOf: legacyURL) as NSData)
            .compressed(using: .zlib) as Data
        try await ModuleSyncManager.shared.syncModuleType(
            .highlights,
            using: ModuleJSONStorage(
                moduleID: moduleID, moduleType: .highlights,
                hash: "legacy-revision", data: legacyBody,
                fileName: "\(moduleID).lamp"
            )
        )
        XCTAssertEqual(try database.getHighlightSet(id: setID)?.moduleId, moduleID)
        XCTAssertEqual(try database.getHighlightCount(setId: setID), 1)
    }

    func testUnchangedDevotionalRetriesMissingMediaAfterFailedPull() async throws {
        let moduleID = "media-retry-\(UUID().uuidString.lowercased())"
        let entryID = UUID().uuidString
        let media = DevotionalMediaReference(
            type: .image, filename: "image.png", mimeType: "image/png"
        )
        let mediaURL = DevotionalMediaStorage.shared.expectedMediaURL(
            for: media, devotionalId: entryID, moduleId: moduleID
        )
        let database = ModuleDatabase.shared
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
            try? FileManager.default.removeItem(
                at: DevotionalMediaStorage.shared.mediaDirectory(moduleId: moduleID)
            )
        }
        try database.saveModule(Module(
            id: moduleID, type: .devotional, name: "Media retry",
            filePath: "\(moduleID).json", fileHash: "same-revision",
            isEditable: true
        ))
        let mediaJSON = String(decoding: try JSONEncoder().encode([media]), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO devotional_entries
                    (id, module_id, title, content_json, media_json, created)
                VALUES (?, ?, 'Media entry', '{}', ?, 1700000000)
                """, arguments: [entryID, moduleID, mediaJSON])
        }
        let body = Data("media bytes".utf8)
        let storage = ModuleJSONStorage(
            moduleID: moduleID, moduleType: .devotional,
            hash: "same-revision", data: body,
            fileName: "\(moduleID).json", mediaReadFailure: true
        )
        do {
            try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)
            XCTFail("A missing referenced media file must fail the pull")
        } catch ModuleStorageError.fileNotFound {
            XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        }
        do {
            try await ModuleSyncManager.shared.uploadDevotionalMedia(
                moduleId: moduleID, to: storage
            )
            XCTFail("A missing local media file must stop publication")
        } catch ModuleStorageError.fileNotFound {
            XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
        }

        try await ModuleSyncManager.shared.syncModuleType(
            .devotional,
            using: ModuleJSONStorage(
                moduleID: moduleID, moduleType: .devotional,
                hash: "same-revision", data: body,
                fileName: "\(moduleID).json"
            )
        )
        XCTAssertEqual(try Data(contentsOf: mediaURL), body)

        let unsafeMedia = DevotionalMediaReference(
            type: .image, filename: "../outside.png", mimeType: "image/png"
        )
        let unsafeJSON = String(decoding: try JSONEncoder().encode([unsafeMedia]), as: UTF8.self)
        try database.write { db in
            try db.execute(
                sql: "UPDATE devotional_entries SET media_json = ? WHERE id = ?",
                arguments: [unsafeJSON, entryID]
            )
        }
        do {
            try await ModuleSyncManager.shared.downloadDevotionalMedia(
                moduleId: moduleID,
                from: ModuleJSONStorage(
                    moduleID: moduleID, moduleType: .devotional,
                    hash: "same-revision", data: body
                )
            )
            XCTFail("A media reference may not leave its devotional directory")
        } catch ModuleSyncError.importFailed {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: mediaURL.deletingLastPathComponent()
                    .appendingPathComponent("../outside.png").standardizedFileURL.path
            ))
        }
    }

    func testFailedDevotionalMediaUploadKeepsPublicationPending() async throws {
        let moduleID = "media-publish-\(UUID().uuidString.lowercased())"
        let entryID = UUID().uuidString
        let media = DevotionalMediaReference(
            type: .image, filename: "image.png", mimeType: "image/png"
        )
        let remotePath = "DevotionalMedia/\(moduleID)/\(entryID)/image.png"
        let localURL = DevotionalMediaStorage.shared.expectedMediaURL(
            for: media, devotionalId: entryID, moduleId: moduleID
        )
        let database = ModuleDatabase.shared
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
            try? FileManager.default.removeItem(
                at: DevotionalMediaStorage.shared.mediaDirectory(moduleId: moduleID)
            )
        }
        try database.saveModule(Module(
            id: moduleID, type: .devotional, name: "Media publish",
            filePath: "\(moduleID).lamp", fileHash: nil, isEditable: true
        ))
        let mediaJSON = String(decoding: try JSONEncoder().encode([media]), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO devotional_entries
                    (id, module_id, title, content_json, media_json, created)
                VALUES (?, ?, 'Media entry', '{}', ?, 1700000000)
                """, arguments: [entryID, moduleID, mediaJSON])
        }

        let state = CapturedModuleBody()
        let storage = CapturingModuleStorage(
            state: state, moduleID: moduleID, moduleType: .devotional
        )
        do {
            try await ModuleSyncManager.shared.exportModule(id: moduleID, to: storage)
            XCTFail("Missing local media must stop publication")
        } catch ModuleStorageError.fileNotFound {
            XCTAssertTrue(try database.pendingModulePublications(type: .devotional)
                .contains(moduleID))
        }

        let body = Data("media bytes".utf8)
        try DevotionalMediaStorage.shared.ensureMediaDirectory(
            devotionalId: entryID, moduleId: moduleID
        )
        try body.write(to: localURL, options: .atomic)
        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)
        let uploadedMedia = await state.media(at: remotePath)
        XCTAssertEqual(uploadedMedia, body)
        XCTAssertFalse(try database.pendingModulePublications(type: .devotional)
            .contains(moduleID))
    }

    func testPortableArchiveImportsCompatibleNotesModule() async throws {
        let sourceID = "portable-notes-\(UUID().uuidString.lowercased())"
        let targetID = "archive-notes-\(UUID().uuidString.lowercased())"
        let source = temporaryDirectory.appendingPathComponent("Notes Source", isDirectory: true)
        let compatible = source.appendingPathComponent(
            "\(LampPortableBackupLayout.compatibleDirectory)/\(LampSyncContentKind.notes.rawValue)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: compatible, withIntermediateDirectories: true)
        let json = """
        {
          "meta": {"schemaVersion":"1.1", "id":"\(sourceID)", "type":"notes", "name":"Archive Notes"},
          "book":"John", "bookNumber":43,
          "chapters":[{"chapter":3,"verses":[{"sv":43003016,
            "commentary":"An archived observation.","lastModified":1700000000}]}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(sourceID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8),
            sourceFilename: "\(sourceID).json",
            destinationURL: compiledURL
        )
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: compiledURL),
            replacingModuleIDWith: targetID,
            kind: .notes
        )
        try rewritten.write(to: compatible.appendingPathComponent("\(targetID).lamp"))
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 0,
                noteDocumentCount: 1,
                highlightDocumentCount: 0,
                devotionalDocumentCount: 0
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: source.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        )
        let compatibilityManifest = LampCompatibilityManifest(files: [
            .init(
                path: "Notes/\(targetID).lamp",
                data: rewritten,
                baseRevision: "\"old-notes-revision\""
            )
        ])
        try encoder.encode(compatibilityManifest).write(
            to: source.appendingPathComponent(LampPortableBackupLayout.compatibilityManifestPath)
        )
        let archive = try LampSyncArchive.create(from: source)
        let suiteName = "compatible-notes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: targetID)
            try? ModuleDatabase.shared.deleteModule(id: targetID)
        }
        let readState = ArchiveReadState()
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"compatible-notes-revision\"",
            state: readState
        )

        let committed = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote,
            source: suiteName,
            defaults: defaults
        )
        XCTAssertEqual(committed?.baseRevision(for: "Notes/\(targetID).lamp"), "\"old-notes-revision\"")
        let cached = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote,
            source: suiteName,
            defaults: defaults
        )
        XCTAssertEqual(cached, committed)
        let readCount = await readState.count()
        XCTAssertEqual(readCount, 1)
        let notes = try ModuleDatabase.shared.getNotesForVerse(
            moduleId: targetID,
            verseId: 43003016
        )
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].content.contains("An archived observation."))

        // A Switch Only wipe clears this module's rows and hash. The archive
        // revision is unchanged, but its notes must be imported again.
        try ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: targetID)
        try ModuleDatabase.shared.write { db in
            try db.execute(
                sql: "UPDATE modules SET file_hash = NULL, last_synced = NULL WHERE id = ?",
                arguments: [targetID]
            )
        }
        XCTAssertTrue(try ModuleDatabase.shared.getNotesForVerse(
            moduleId: targetID, verseId: 43003016
        ).isEmpty)

        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote,
            source: suiteName,
            defaults: defaults
        )
        let replayReadCount = await readState.count()
        XCTAssertEqual(replayReadCount, 2)
        XCTAssertEqual(try ModuleDatabase.shared.getNotesForVerse(
            moduleId: targetID, verseId: 43003016
        ).count, 1)
    }

    func testPortableArchiveImportsAndRepairsReferencedMacDevotionalMedia() async throws {
        let entryID = "archive-writing-\(UUID().uuidString.lowercased())"
        let moduleID = "archive-devotionals-\(UUID().uuidString.lowercased())"
        let source = temporaryDirectory.appendingPathComponent("Writing Source", isDirectory: true)
        let compatible = source.appendingPathComponent(
            "\(LampPortableBackupLayout.compatibleDirectory)/\(LampSyncContentKind.devotionals.rawValue)",
            isDirectory: true
        )
        let media = source.appendingPathComponent(
            "Media/Devotionals/\(entryID)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: compatible, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let filename = ".morning.png"
        let body = Data("portable image".utf8)
        try body.write(to: media.appendingPathComponent(filename))
        let markdown = "![Morning](lamp-media://\(entryID)/\(filename))"
        let json = """
        {
          "meta": {"schemaVersion":"1.1", "id":"\(entryID)",
                   "type":"devotional", "title":"Morning", "lastModified":1700000100},
          "content": [{"type":"paragraph", "content":{"text":"\(markdown)"}}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(entryID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: "\(entryID).json",
            destinationURL: compiledURL
        )
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: compiledURL), replacingModuleIDWith: moduleID,
            kind: .devotionals, mediaRootURL: source
        )
        try rewritten.write(to: compatible.appendingPathComponent("\(moduleID).lamp"))
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 0, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 1
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: source.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        )
        let archive = try LampSyncArchive.create(from: source)
        let suiteName = "compatible-writing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let localMedia = DevotionalMediaStorage.shared.mediaDirectory(
            devotionalId: entryID, moduleId: moduleID
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
            try? FileManager.default.removeItem(at: localMedia)
        }
        let readState = ArchiveReadState()
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"compatible-writing-revision\"",
            state: readState
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        let imported = try XCTUnwrap(ModuleDatabase.shared.getDevotionalEntry(id: entryID))
        XCTAssertEqual(imported.contentJson, markdown)
        let references = try JSONDecoder().decode(
            [DevotionalMediaReference].self,
            from: Data(try XCTUnwrap(imported.mediaJson).utf8)
        )
        XCTAssertEqual(references.map(\.id), ["lamp-media://\(entryID)/\(filename)"])
        XCTAssertEqual(
            try Data(contentsOf: localMedia.appendingPathComponent(filename)), body
        )

        var legacyEntry = imported
        legacyEntry.contentJson = String(decoding: try JSONSerialization.data(
            withJSONObject: [["type": "paragraph", "content": ["text": markdown]]]
        ), as: UTF8.self)
        legacyEntry.mediaJson = nil
        try ModuleDatabase.shared.saveDevotionalEntry(legacyEntry)
        var legacyState = try JSONDecoder().decode(
            ModuleSyncManager.PortableArchiveImportState.self,
            from: try XCTUnwrap(defaults.data(
                forKey: ModuleSyncManager.portableArchiveImportStateKey
            ))
        )
        legacyState.mediaBridgeVersion = nil
        defaults.set(
            try JSONEncoder().encode(legacyState),
            forKey: ModuleSyncManager.portableArchiveImportStateKey
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        let upgraded = try XCTUnwrap(ModuleDatabase.shared.getDevotionalEntry(id: entryID))
        XCTAssertEqual(upgraded.contentJson, markdown)
        XCTAssertNotNil(upgraded.mediaJson)

        try FileManager.default.removeItem(at: localMedia.appendingPathComponent(filename))
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        XCTAssertEqual(
            try Data(contentsOf: localMedia.appendingPathComponent(filename)), body
        )
        let readCount = await readState.count()
        XCTAssertEqual(readCount, 3)
    }

    func testPortableArchiveRestoresRichDevotionalMediaFromMacArchive() async throws {
        let entryID = "rich-writing-\(UUID().uuidString.lowercased())"
        let moduleID = "rich-devotionals-\(UUID().uuidString.lowercased())"
        let source = temporaryDirectory.appendingPathComponent("Rich Writing Source", isDirectory: true)
        let compatible = source.appendingPathComponent(
            "\(LampPortableBackupLayout.compatibleDirectory)/\(LampSyncContentKind.devotionals.rawValue)",
            isDirectory: true
        )
        let archiveMedia = source.appendingPathComponent(
            "Media/Devotionals/\(entryID)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: compatible, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveMedia, withIntermediateDirectories: true)
        let filename = ".rich.png"
        let body = Data("rich portable image".utf8)
        try body.write(to: archiveMedia.appendingPathComponent(filename))
        let json = """
        {
          "meta": {"schemaVersion":"1.1", "id":"\(entryID)",
                   "type":"devotional", "title":"Rich Morning", "lastModified":1700000200},
          "content": [{"type":"paragraph", "content":{
            "text":"![Morning](media/rich-image)", "marks":["bold"]}}],
          "media": [{"id":"rich-image", "type":"image", "filename":"\(filename)",
                     "mimeType":"image/png", "width":1200, "alt":"Morning light",
                     "futureField":"keep this value"}]
        }
        """
        let compiledURL = temporaryDirectory.appendingPathComponent("\(entryID).lamp")
        _ = try LampModuleCompiler().compile(
            data: Data(json.utf8), sourceFilename: "\(entryID).json",
            destinationURL: compiledURL
        )
        let rewritten = try LampWebDAVPersonalArchiveAdapter.archive(
            Data(contentsOf: compiledURL), replacingModuleIDWith: moduleID,
            kind: .devotionals, mediaRootURL: source
        )
        let sqliteURL = temporaryDirectory.appendingPathComponent("\(entryID)-rich.sqlite")
        try ((rewritten as NSData).decompressed(using: .zlib) as Data).write(to: sqliteURL)
        let rowIdentity = try await DatabaseQueue(path: sqliteURL.path).read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT id, module_id FROM devotional_entries"))
        }
        XCTAssertEqual(rowIdentity["id"] as String, entryID)
        XCTAssertEqual(rowIdentity["module_id"] as String, moduleID)
        try rewritten.write(to: compatible.appendingPathComponent("\(moduleID).lamp"))
        let manifest = LampPortableBackupManifest(
            generatedAt: Date(),
            summary: .init(
                moduleCount: 0, noteDocumentCount: 0,
                highlightDocumentCount: 0, devotionalDocumentCount: 1
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: source.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        )
        let archive = try LampSyncArchive.create(from: source)
        XCTAssertEqual(try archive.syncableContents().modules.count, 1)
        let suiteName = "rich-writing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let localMedia = DevotionalMediaStorage.shared.mediaDirectory(
            devotionalId: entryID, moduleId: moduleID
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
            try? FileManager.default.removeItem(at: localMedia)
        }
        let remote = ArchiveRemoteStore(
            data: try archive.compressedData(),
            revision: "\"rich-writing-revision\"", state: ArchiveReadState()
        )
        _ = try await ModuleSyncManager.shared.importPortableArchiveModules(
            from: remote, source: suiteName, defaults: defaults
        )
        let imported = try XCTUnwrap(ModuleDatabase.shared.getDevotionalEntry(id: entryID))
        XCTAssertTrue(imported.contentJson.contains("marks"))
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(imported.contentJson.utf8)
        ) as? [[String: Any]])
        XCTAssertEqual(
            (blocks.first?["content"] as? [String: Any])?["text"] as? String,
            "![Morning](media/rich-image)"
        )
        let metadata = try XCTUnwrap(imported.mediaJson)
        XCTAssertTrue(metadata.contains("keep this value"))
        let references = try JSONDecoder().decode(
            [DevotionalMediaReference].self, from: Data(metadata.utf8)
        )
        XCTAssertEqual(references.first?.width, 1200)
        XCTAssertEqual(references.first?.alt, "Morning light")
        XCTAssertEqual(try Data(contentsOf: localMedia.appendingPathComponent(filename)), body)
    }

    func testCommittedArchiveSkipsOnlySupersededFolderRevision() async throws {
        let moduleID = "stale-notes-\(UUID().uuidString.lowercased())"
        let remotePath = "Notes/\(moduleID).lamp"
        let manifest = LampCompatibilityManifest(files: [
            .init(
                path: remotePath,
                data: Data("archive module".utf8),
                baseRevision: "\"old-revision\""
            )
        ])
        let oldReads = ArchiveReadState()
        try await ModuleSyncManager.shared.syncModuleType(
            .notes,
            using: CompatibilityFolderStorage(
                moduleID: moduleID,
                revisionValue: "\"old-revision\"",
                state: oldReads
            ),
            compatibilityManifest: manifest
        )
        let oldReadCount = await oldReads.count()
        XCTAssertEqual(oldReadCount, 0)

        let changedReads = ArchiveReadState()
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes,
                using: CompatibilityFolderStorage(
                    moduleID: moduleID,
                    revisionValue: "\"new-revision\"",
                    state: changedReads
                ),
                compatibilityManifest: manifest
            )
            XCTFail("A changed folder file must be read for reconciliation")
        } catch {
            // This mock deliberately returns an invalid module after it is read.
        }
        let changedReadCount = await changedReads.count()
        XCTAssertEqual(changedReadCount, 1)
    }

    func testSharedPreferencesMergeAndPublishPreservesArchiveModules() async throws {
        let original = UserDatabase.shared.getSettings()
        defer {
            try? UserDatabase.shared.updateSettings { $0 = original }
        }
        let source = "shared-preferences-\(UUID().uuidString)"
        let suite = "shared-preferences-cache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = LampSharedPreferenceLedger(fields: [
            "reader.fontSize": .init(value: .number((Double(original.readerFontSize) * 1000).rounded() / 1000)),
            "reader.defaultTranslationID": .init(value: .string(original.readerTranslationId)),
            "reader.showStrongsHints": .init(value: .boolean(original.showStrongsHints)),
            "devotional.fontSize": .init(value: .number((Double(original.devotionalFontSize) * 1000).rounded() / 1000)),
            "plans.reminder.enabled": .init(value: .boolean(original.planNotification)),
            "plans.reminder.hour": .init(value: .integer(original.planNotificationHour)),
            "plans.reminder.minute": .init(value: .integer(original.planNotificationMinute)),
        ])
        defaults.set(
            [source: try JSONEncoder().encode(base)],
            forKey: "SharedPreferenceArchiveSync.bases.v1"
        )
        var fields = base.fields
        let remoteSize = original.readerFontSize + 1
        fields["reader.fontSize"] = .init(value: .number(Double(remoteSize)))
        let remoteLedger = LampSharedPreferenceLedger(fields: fields)

        let directory = temporaryDirectory.appendingPathComponent("Preference Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("keep module".utf8).write(
            to: directory.appendingPathComponent("Modules/book.lamp")
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Settings", isDirectory: true),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(remoteLedger).write(
            to: directory.appendingPathComponent(LampPortableBackupLayout.sharedPreferencesPath)
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
            to: directory.appendingPathComponent(LampPortableBackupLayout.manifestPath)
        )
        let archive = try LampSyncArchive.create(from: directory)
        let store = PreferenceArchiveStore(data: try archive.compressedData())

        try await SharedPreferenceArchiveSync.sync(from: store, source: source, defaults: defaults)
        XCTAssertEqual(UserDatabase.shared.getSettings().readerFontSize, remoteSize)
        let initialWrites = await store.writeCount()
        XCTAssertEqual(initialWrites, 0)

        try UserDatabase.shared.updateSettings { $0.readerFontSize = remoteSize + 1 }
        try await SharedPreferenceArchiveSync.sync(from: store, source: source, defaults: defaults)
        let finalWrites = await store.writeCount()
        XCTAssertEqual(finalWrites, 1)
        let published = try LampSyncArchive.decode(compressedData: await store.archiveData())
        XCTAssertEqual(
            published.entries.first(where: { $0.path == "Modules/book.lamp" })?.data,
            Data("keep module".utf8)
        )
        let ledgerData = try XCTUnwrap(published.entries.first(where: {
            $0.path == LampPortableBackupLayout.sharedPreferencesPath
        })?.data)
        let publishedLedger = try JSONDecoder().decode(LampSharedPreferenceLedger.self, from: ledgerData)
        XCTAssertEqual(
            publishedLedger.fields["reader.fontSize"]?.value,
            .number(Double(remoteSize + 1))
        )
        do {
            try await SharedPreferenceArchiveSync.sync(
                from: store,
                source: source,
                defaults: defaults,
                expectation: .revision("\"preference-archive-v1\"")
            )
            XCTFail("A changed archive revision must restart the sync")
        } catch SyncError.conflictDetected {
            // The module cache described the preceding archive revision.
        }
    }

    func testArchivedCompatibilityAuthorityRequiresSameSourceModuleAndDigest() throws {
        let suite = "archive-compatibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = LampCompatibilityManifest.File(
            path: "Notes/notes.lamp",
            data: Data("archived notes".utf8),
            baseRevision: "\"old-folder\""
        )
        let state = ModuleSyncManager.PortableArchiveImportState(
            source: "https://example.test/library",
            revision: "\"archive\"",
            modules: [ModuleSyncManager.PortableArchiveModuleState(
                path: "Compatibility/Notes/notes.lamp",
                id: "notes",
                type: .notes,
                digest: file.sha256
            )],
            compatibilityManifest: LampCompatibilityManifest(files: [file])
        )
        defaults.set(
            try JSONEncoder().encode(state),
            forKey: ModuleSyncManager.portableArchiveImportStateKey
        )
        let manager = ModuleSyncManager.shared
        XCTAssertEqual(manager.archivedCompatibilityFile(
            moduleID: "notes",
            remotePath: file.path,
            observedHash: file.sha256,
            source: state.source,
            defaults: defaults
        ), file)
        XCTAssertNil(manager.archivedCompatibilityFile(
            moduleID: "notes",
            remotePath: file.path,
            observedHash: "unrelated-local-hash",
            source: state.source,
            defaults: defaults
        ))
        XCTAssertNil(manager.archivedCompatibilityFile(
            moduleID: "notes",
            remotePath: file.path,
            observedHash: file.sha256,
            source: "https://different.example/library",
            defaults: defaults
        ))
    }

    @MainActor
    func testSettingsExportRejectsChangedRemoteSnapshot() async {
        let key = "UserSettingsSync.remoteChangeToken"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("previous-version", forKey: key)

        do {
            try await UserSettingsSyncManager.shared.exportLegacyToRemote(
                storage: ChangedSettingsStorage(token: "changed-version")
            )
            XCTFail("A changed remote snapshot must not be overwritten")
        } catch SyncError.conflictDetected {
            // Expected: the remote token no longer matches the last merge.
        } catch {
            XCTFail("Expected a sync conflict, got \(error)")
        }
    }

    @MainActor
    func testSettingsExportRejectsExistingRemoteWithoutToken() async {
        let key = "UserSettingsSync.remoteChangeToken"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        do {
            try await UserSettingsSyncManager.shared.exportLegacyToRemote(
                storage: ChangedSettingsStorage(token: nil)
            )
            XCTFail("An existing remote file without a token must not be overwritten")
        } catch SyncError.conflictDetected {
            // Expected: absence of a token did not imply absence of a file.
        } catch {
            XCTFail("Expected a sync conflict, got \(error)")
        }
    }

    @MainActor
    func testSettingsExportRejectsConcurrentWebDAVWrite() async {
        let key = "UserSettingsSync.remoteChangeToken"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("same", forKey: key)

        do {
            try await UserSettingsSyncManager.shared.exportLegacyToRemote(
                storage: ChangedSettingsStorage(token: "\"same\"")
            )
            XCTFail("A WebDAV precondition failure must remain a sync conflict")
        } catch SyncError.conflictDetected {
            // The server changed after its revision was read.
        } catch {
            XCTFail("Expected a sync conflict, got \(error)")
        }
    }

    @MainActor
    func testSavingDeviceSyncConfigurationKeepsSharedRevision() throws {
        let previous = UserDatabase.shared.getSyncSettings()
        defer { try? UserDatabase.shared.restoreLocalSyncSettings(previous) }
        let before = try UserDatabase.shared.syncSnapshot().settings.updatedAt

        try UserDatabase.shared.saveSyncSettings(SyncSettings(
            backend: .webdav,
            webdavURL: "https://local.example/library"
        ))

        XCTAssertEqual(try UserDatabase.shared.syncSnapshot().settings.updatedAt, before)
    }

    @MainActor
    func testSettingsExportRejectsRemoteRemovalAfterObservation() async throws {
        let tokenKey = "UserSettingsSync.remoteChangeToken"
        let baseKey = "UserSettingsSync.readingsBase.v1"
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousBase = UserDefaults.standard.object(forKey: baseKey)
        defer {
            UserDefaults.standard.set(previousToken, forKey: tokenKey)
            UserDefaults.standard.set(previousBase, forKey: baseKey)
        }
        UserDefaults.standard.set("observed", forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: baseKey)

        do {
            try await UserSettingsSyncManager.shared.exportLegacyToRemote(
                storage: MissingSettingsStorage()
            )
            XCTFail("An observed file must not be silently recreated")
        } catch SyncError.conflictDetected {
            // The remote file disappeared after the client observed it.
        }
    }

    @MainActor
    func testSettingsExportConfirmsRevisionWhenPUTOmitsETag() async throws {
        let key = "UserSettingsSync.remoteChangeToken"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let baseKey = "UserSettingsSync.readingsBase.v1"
        let previousBase = UserDefaults.standard.object(forKey: baseKey)
        defer { UserDefaults.standard.set(previousBase, forKey: baseKey) }
        UserDefaults.standard.removeObject(forKey: baseKey)
        UserDefaults.standard.set("same", forKey: key)
        let previousSyncSettings = UserDatabase.shared.getSyncSettings()
        defer { try? UserDatabase.shared.restoreLocalSyncSettings(previousSyncSettings) }
        let localSyncSettings = SyncSettings(
            backend: .webdav,
            webdavURL: "https://local.example/library"
        )
        try UserDatabase.shared.restoreLocalSyncSettings(localSyncSettings)
        let state = SettingsWriteState()

        try await UserSettingsSyncManager.shared.exportLegacyToRemote(
            storage: ChangedSettingsStorage(token: "\"same\"", writeState: state)
        )

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "after")
        let uploadedData = await state.uploadedData()
        let uploaded = try XCTUnwrap(uploadedData)
        let uploadedURL = temporaryDirectory.appendingPathComponent("uploaded-user.db")
        try uploaded.write(to: uploadedURL)
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: uploadedURL.path, configuration: config)
        let remoteConfig = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT sync_settings_json FROM user_settings WHERE id = 1")
        }
        XCTAssertNil(remoteConfig)
        XCTAssertEqual(UserDatabase.shared.getSyncSettings()?.webdavURL, localSyncSettings.webdavURL)
    }

    @MainActor
    func testSettingsReadKeepsDatabaseAndRevisionFromOneGET() async throws {
        let snapshot = try await UserSettingsSyncManager.shared.readRemoteSettings(
            from: ChangedSettingsStorage(
                token: "\"old\"",
                reportedChangeToken: "later"
            )
        )
        XCTAssertEqual(snapshot?.data, Data([1]))
        XCTAssertEqual(snapshot?.token, "old")
    }

    @MainActor
    func testSettingsReadRejectsChangingUnconditionalProvider() async throws {
        do {
            _ = try await UserSettingsSyncManager.shared.readRemoteSettings(
                from: ChangingSettingsStorage(tokens: SettingsTokenSequence())
            )
            XCTFail("A changed token during the read must be retried")
        } catch SyncError.conflictDetected {
            // The body cannot be paired with either independently read token.
        }
    }

    @MainActor
    func testSettingsReadRejectsExistingUnversionedProviderFile() async throws {
        do {
            _ = try await UserSettingsSyncManager.shared.readRemoteSettings(
                from: ChangingSettingsStorage(
                    tokens: SettingsTokenSequence(), missingToken: true
                )
            )
            XCTFail("An existing iCloud settings file needs a revision")
        } catch SyncError.conflictDetected {
            // A missing token cannot prove that the body was stable.
        }
    }

    @MainActor
    func testSettingsPollChecksFileWhenProviderTokenIsMissing() async throws {
        let key = "UserDatabase.lastExportedAt"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDatabase.shared.clearUnsyncedChanges(through: .distantFuture)
        let reads = ArchiveReadState()
        await UserSettingsSyncManager.shared.pollForRemoteChanges(
            storage: ChangingSettingsStorage(
                tokens: SettingsTokenSequence(),
                missingToken: true,
                readState: reads
            )
        )
        let readCount = await reads.count()
        XCTAssertEqual(readCount, 1)
    }

    @MainActor
    func testWebDAVSettingsPublishArchiveAndDetectLaterLegacyEdit() async throws {
        let keys = [
            "UserSettingsSync.remoteChangeToken",
            "UserSettingsSync.readingsBase.v1",
            "UserDatabase.lastExportedAt"
        ]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        let state = SettingsArchiveState()
        let storage = SettingsArchiveStorage(state: state)
        try await UserSettingsSyncManager.shared.reconcileWithRemote(storage: storage)

        let archivedFile = await state.file(LampSyncLayout.archivePath)
        let archive = try LampSyncArchive.decode(
            compressedData: XCTUnwrap(archivedFile?.data)
        )
        let settingsData = try XCTUnwrap(LampSyncSettingsArchive.data(in: archive))
        let legacyFile = await state.file(LampSyncLayout.userSettingsPath)
        XCTAssertEqual(legacyFile?.data, settingsData)
        XCTAssertNotNil(try LampSyncSettingsArchive.legacyManifest(in: archive))
        // Other settings tests can leave a newer local edit on this shared
        // database. Exercise the remote-revision shortcut with no local work.
        UserDatabase.shared.clearUnsyncedChanges(through: .distantFuture)
        let canSkipUnchanged = await UserSettingsSyncManager.shared
            .canSkipUnchangedArchivePoll(storage: storage)
        XCTAssertTrue(canSkipUnchanged)

        await state.replaceLegacy(Data("older-client-change".utf8))
        let canSkipChanged = await UserSettingsSyncManager.shared
            .canSkipUnchangedArchivePoll(storage: storage)
        XCTAssertFalse(canSkipChanged)
        do {
            _ = try await UserSettingsSyncManager.shared.readRemoteSettings(from: storage)
            XCTFail("An older client's different settings must not be ignored")
        } catch SyncError.conflictDetected {
            // The legacy copy changed after the archive commit.
        }
    }

    @MainActor
    func testWebDAVSettingsUpdatePreservesOtherArchiveEntries() async throws {
        let tokenKey = "UserSettingsSync.remoteChangeToken"
        let baseKey = "UserSettingsSync.readingsBase.v1"
        let exportedKey = "UserDatabase.lastExportedAt"
        let keys = [tokenKey, baseKey, exportedKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        try UserDatabase.shared.checkpointForSync()
        let remoteURL = temporaryDirectory.appendingPathComponent("older-settings.db")
        try FileManager.default.copyItem(
            at: UserDatabase.shared.databaseURL, to: remoteURL
        )
        let olderSettings: UserSettings = try {
            let queue = try DatabaseQueue(path: remoteURL.path)
            _ = try queue.writeWithoutTransaction { db in
                let current = try XCTUnwrap(UserSettings.fetchOne(db, key: 1))
                try db.execute(
                    sql: "UPDATE user_settings SET plan_wpm = ?, updated_at = ? WHERE id = 1",
                    arguments: [current.planWpm + 1, Date(timeIntervalSince1970: 100)]
                )
                try db.checkpoint(.truncate)
            }
            return try queue.read { db in
                try XCTUnwrap(UserSettings.fetchOne(db, key: 1))
            }
        }()
        let remoteData = try Data(contentsOf: remoteURL)
        let legacy = LampSyncRemoteFile(
            data: remoteData, revision: "\"seed-legacy\""
        )
        let workspaceData = Data("Mac workspace".utf8)
        let archive = try LampSyncSettingsArchive.replacingData(
            remoteData, in: nil, observedLegacy: legacy
        ).replacingEntry(
            at: "Workspaces/mac.md", with: workspaceData
        )
        let state = SettingsArchiveState()
        await state.seed(
            path: LampSyncLayout.archivePath,
            file: LampSyncRemoteFile(
                data: try archive.compressedData(), revision: "\"seed-archive\""
            )
        )
        await state.seed(path: LampSyncLayout.userSettingsPath, file: legacy)
        let source = "archive:" + String(reflecting: SettingsArchiveStorage.self)
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: source,
            token: "seed-archive",
            readingIDs: Set(try UserDatabase.shared.syncSnapshot().readings.map(\.id)),
            settings: olderSettings
        )
        UserDefaults.standard.set(try JSONEncoder().encode(base), forKey: baseKey)
        UserDefaults.standard.set("seed-archive", forKey: tokenKey)
        UserDefaults.standard.set(Date.distantFuture, forKey: exportedKey)

        try await UserSettingsSyncManager.shared.reconcileWithRemote(
            storage: SettingsArchiveStorage(state: state)
        )

        let publishedFile = await state.file(LampSyncLayout.archivePath)
        let published = try LampSyncArchive.decode(
            compressedData: XCTUnwrap(publishedFile?.data)
        )
        XCTAssertEqual(
            published.entries.first { $0.path == "Workspaces/mac.md" }?.data,
            workspaceData
        )
        let settingsData = try XCTUnwrap(LampSyncSettingsArchive.data(in: published))
        XCTAssertNotEqual(settingsData, remoteData)
        let mirrored = await state.file(LampSyncLayout.userSettingsPath)
        XCTAssertEqual(mirrored?.data, settingsData)
    }

    @MainActor
    func testWebDAVSettingsRetryRepairsFailedLegacyMirror() async throws {
        let keys = [
            "UserSettingsSync.remoteChangeToken",
            "UserSettingsSync.readingsBase.v1",
            "UserDatabase.lastExportedAt"
        ]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        let state = SettingsArchiveState()
        await state.failNextLegacyWrite()
        let storage = SettingsArchiveStorage(state: state)
        do {
            try await UserSettingsSyncManager.shared.reconcileWithRemote(storage: storage)
            XCTFail("The failed compatibility mirror must be reported")
        } catch SyncError.conflictDetected {
            // The archive is committed, but the compatibility mirror is pending.
        }
        let committedFile = await state.file(LampSyncLayout.archivePath)
        let committed = try LampSyncArchive.decode(
            compressedData: XCTUnwrap(committedFile?.data)
        )
        let settingsData = try XCTUnwrap(LampSyncSettingsArchive.data(in: committed))
        let missingMirror = await state.file(LampSyncLayout.userSettingsPath)
        XCTAssertNil(missingMirror)

        try await UserSettingsSyncManager.shared.reconcileWithRemote(storage: storage)
        let repairedMirror = await state.file(LampSyncLayout.userSettingsPath)
        XCTAssertEqual(repairedMirror?.data, settingsData)
    }

    @MainActor
    func testArchiveSettingsCanAdoptMatchingLegacyBaseline() async throws {
        let tokenKey = "UserSettingsSync.remoteChangeToken"
        let baseKey = "UserSettingsSync.readingsBase.v1"
        let previousToken = UserDefaults.standard.object(forKey: tokenKey)
        let previousBase = UserDefaults.standard.object(forKey: baseKey)
        defer {
            UserDefaults.standard.set(previousToken, forKey: tokenKey)
            UserDefaults.standard.set(previousBase, forKey: baseKey)
        }
        let source = String(reflecting: SettingsArchiveStorage.self)
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: source, token: "legacy-revision",
            readingIDs: ["observed"], settings: UserSettings()
        )
        UserDefaults.standard.set("legacy-revision", forKey: tokenKey)
        UserDefaults.standard.set(try JSONEncoder().encode(base), forKey: baseKey)

        let legacy = LampSyncRemoteFile(
            data: Data("previous database".utf8),
            revision: "\"legacy-revision\""
        )
        let archive = try LampSyncSettingsArchive.replacingData(
            Data("new archive database".utf8),
            in: nil,
            observedLegacy: legacy
        )
        let state = SettingsArchiveState()
        await state.seed(
            path: LampSyncLayout.archivePath,
            file: LampSyncRemoteFile(
                data: try archive.compressedData(), revision: "\"archive-revision\""
            )
        )
        await state.seed(path: LampSyncLayout.userSettingsPath, file: legacy)
        let storage = SettingsArchiveStorage(state: state)
        let read = try await UserSettingsSyncManager.shared.readRemoteSettings(from: storage)
        let snapshot = try XCTUnwrap(read)
        let adopted = UserSettingsSyncManager.shared.applicableBase(
            for: snapshot, storage: storage
        )
        XCTAssertEqual(adopted?.readingIDs, ["observed"])

        UserDefaults.standard.set("different-revision", forKey: tokenKey)
        XCTAssertNil(UserSettingsSyncManager.shared.applicableBase(
            for: snapshot, storage: storage
        ))
    }

    @MainActor
    func testSettingsPlanMergesIndependentReadingEditsBeforePublish() throws {
        var baseSettings = UserSettings()
        baseSettings.updatedAt = Date(timeIntervalSince1970: 100)
        let localSettings = baseSettings
        var remoteSettings = baseSettings
        remoteSettings.planWpm = 220
        remoteSettings.updatedAt = Date(timeIntervalSince1970: 200)
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: "test", token: "old",
            readingIDs: Set(["kept", "deleted-locally", "deleted-remotely"]),
            settings: baseSettings
        )
        let plan = try UserSettingsSyncManager.shared.planSettingsMerge(
            localSettings: localSettings,
            localReadings: ["kept", "deleted-remotely", "added-locally"].map { CompletedReading(id: $0) },
            remoteSettings: remoteSettings,
            remoteReadings: ["kept", "deleted-locally", "added-remotely"].map { CompletedReading(id: $0) },
            base: base
        )
        XCTAssertTrue(plan.applyRemoteSettings)
        XCTAssertEqual(plan.readingIDs, Set(["kept", "added-locally", "added-remotely"]))
        XCTAssertEqual(Set(plan.readings.map(\.id)), plan.readingIDs)
        XCTAssertTrue(plan.needsPublish)
    }

    @MainActor
    func testSettingsPlanReportsConcurrentDifferentSettingsEdits() throws {
        let baseSettings = UserSettings()
        var localSettings = baseSettings
        localSettings.planWpm = 200
        var remoteSettings = baseSettings
        remoteSettings.planWpm = 220
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: "test", token: "old", readingIDs: [], settings: baseSettings
        )
        do {
            _ = try UserSettingsSyncManager.shared.planSettingsMerge(
                localSettings: localSettings,
                localReadings: [],
                remoteSettings: remoteSettings,
                remoteReadings: [],
                base: base
            )
            XCTFail("Concurrent settings edits must not be overwritten")
        } catch SyncError.conflictDetected {
            // The whole settings row needs explicit resolution.
        }
    }

    @MainActor
    func testSettingsPlanConvergesReadingCompletionDates() throws {
        let settings = UserSettings()
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: "test", token: "old", readingIDs: ["reading"], settings: settings
        )
        let older = CompletedReading(
            id: "reading", completedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = CompletedReading(
            id: "reading", completedAt: Date(timeIntervalSince1970: 200)
        )
        let localWins = try UserSettingsSyncManager.shared.planSettingsMerge(
            localSettings: settings, localReadings: [newer],
            remoteSettings: settings, remoteReadings: [older], base: base
        )
        XCTAssertEqual(localWins.readings, [newer])
        XCTAssertTrue(localWins.needsPublish)

        let remoteWins = try UserSettingsSyncManager.shared.planSettingsMerge(
            localSettings: settings, localReadings: [older],
            remoteSettings: settings, remoteReadings: [newer], base: base
        )
        XCTAssertEqual(remoteWins.readings, [newer])
        XCTAssertFalse(remoteWins.needsPublish)
    }

    @MainActor
    func testSettingsPlanRejectsEqualTimeWithDifferentReadingData() throws {
        let settings = UserSettings()
        let base = UserSettingsSyncManager.SettingsSyncBase(
            source: "test", token: "old", readingIDs: ["reading"], settings: settings
        )
        let local = CompletedReading(
            id: "reading", completedAt: Date(timeIntervalSince1970: 100)
        )
        var remote = local
        remote.planId = "other"

        do {
            _ = try UserSettingsSyncManager.shared.planSettingsMerge(
                localSettings: settings, localReadings: [local],
                remoteSettings: settings, remoteReadings: [remote], base: base
            )
            XCTFail("Equal completion times with different rows must conflict")
        } catch SyncError.conflictDetected {
            // A deterministic winner cannot be inferred from the timestamp.
        }
    }

    @MainActor
    func testSettingsPlanWithoutBaseRejectsUnexplainedReadingChanges() throws {
        var localSettings = UserSettings()
        localSettings.updatedAt = Date(timeIntervalSince1970: 200)
        localSettings.planWpm = 240
        var remoteSettings = UserSettings()
        remoteSettings.updatedAt = Date(timeIntervalSince1970: 100)
        let remoteReading = CompletedReading(id: "remote-reading")

        do {
            _ = try UserSettingsSyncManager.shared.planSettingsMerge(
                localSettings: localSettings,
                localReadings: [CompletedReading(id: "local-reading")],
                remoteSettings: remoteSettings,
                remoteReadings: [remoteReading],
                base: nil
            )
            XCTFail("Without a baseline, neither side can identify the deletion")
        } catch SyncError.conflictDetected {
            // A different reading set needs an explicit resolution.
        }

        let plan = try UserSettingsSyncManager.shared.planSettingsMerge(
            localSettings: localSettings,
            localReadings: [remoteReading],
            remoteSettings: remoteSettings,
            remoteReadings: [remoteReading],
            base: nil
        )
        XCTAssertFalse(plan.applyRemoteSettings)
        XCTAssertEqual(plan.readings, [remoteReading])
        XCTAssertTrue(plan.needsPublish)
    }

    func testPendingNoteConflictsPersistAndBlockExportUntilResolved() async throws {
        let moduleId = "sync-conflict-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        let module = Module(
            id: moduleId,
            type: .notes,
            name: "Conflict test",
            filePath: "\(moduleId).lamp",
            fileHash: "remote-revision",
            isEditable: true
        )
        try database.saveModule(module)
        defer {
            try? database.replacePendingModuleConflicts(
                moduleId: moduleId,
                type: .notes,
                conflicts: [NoteConflict](),
                key: { $0.id }
            )
            try? database.deleteModule(id: moduleId)
        }

        let local = NoteEntry(
            id: "local",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "local",
            lastModified: 42
        )
        let remote = NoteEntry(
            id: "remote",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "remote",
            lastModified: 42
        )
        let conflict = NoteConflict(
            id: String(local.verseId),
            verseId: local.verseId,
            localEntry: local,
            cloudEntry: remote
        )
        try database.replacePendingModuleConflicts(
            moduleId: moduleId,
            type: .notes,
            conflicts: [conflict],
            key: { $0.id }
        )

        let restored = try XCTUnwrap(
            database.firstPendingModuleConflicts(type: .notes, as: NoteConflict.self)
        )
        XCTAssertEqual(restored.moduleId, moduleId)
        XCTAssertEqual(restored.conflicts.map(\.cloudEntry.content), ["remote"])
        XCTAssertTrue(try database.hasPendingModuleConflicts(moduleId: moduleId))

        do {
            try await ModuleSyncManager.shared.exportModule(id: moduleId, to: MissingSettingsStorage())
            XCTFail("Export must wait for conflict resolution")
        } catch SyncError.conflictDetected {
            // The persisted conflict blocks export before any storage write.
        }

        XCTAssertFalse(try database.removePendingModuleConflict(
            moduleId: moduleId,
            type: .notes,
            key: conflict.id
        ))
        XCTAssertFalse(try database.hasPendingModuleConflicts(moduleId: moduleId))
        XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
    }

    func testFailedModulePublicationRetriesFromDurableMarker() async throws {
        let moduleId = "sync-retry-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Publication retry test",
            filePath: "\(moduleId).lamp",
            fileHash: "base",
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-note",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "chosen text",
            lastModified: 43
        ))
        try database.markPendingModulePublication(moduleId: moduleId, type: .notes)
        let state = RetryPublicationState()
        let storage = RetryModuleStorage(moduleID: moduleId, state: state)

        do {
            try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
            XCTFail("The first publication should fail")
        } catch ModuleStorageError.notAvailable {
            XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
            XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "base")
        }

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        XCTAssertFalse(try database.pendingModulePublications(type: .notes).contains(moduleId))
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "published")
        let attemptCount = await state.attemptCount()
        XCTAssertEqual(attemptCount, 2)
    }

    func testFullModulePassPullsAllTypesBeforePublishing() async throws {
        let moduleId = "sync-pull-gate-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "Pull gate test",
            filePath: "\(moduleId).lamp", fileHash: "base", isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-note", moduleId: moduleId,
            verseId: 1_001_001, content: "Keep pending", lastModified: 43
        ))
        try database.markPendingModulePublication(moduleId: moduleId, type: .notes)
        let state = RetryPublicationState()

        do {
            try await ModuleSyncManager.shared.syncAllModuleTypes(
                using: RetryModuleStorage(moduleID: moduleId, state: state),
                precedingPullFailed: true
            )
            XCTFail("A failed archive/settings pull must block all module uploads")
        } catch ModuleSyncError.importFailed {
            let attempts = await state.attemptCount()
            XCTAssertEqual(attempts, 0)
        }

        do {
            try await ModuleSyncManager.shared.syncAllModuleTypes(
                using: RetryModuleStorage(
                    moduleID: moduleId, state: state, failListingType: .quiz
                )
            )
            XCTFail("A later module pull failure must block earlier module uploads")
        } catch ModuleStorageError.notAvailable {
            let attempts = await state.attemptCount()
            XCTAssertEqual(attempts, 0)
        }
        XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
    }

    func testFullSyncDoesNotPublishSettingsBeforeLaterModulePull() async throws {
        let state = SettingsArchiveState()
        let storage = SettingsArchiveStorage(state: state, failListingType: .quiz)
        let succeeded = await ModuleSyncManager.shared.syncAll(
            using: storage, backend: .webdav, archiveSource: UUID().uuidString
        )
        XCTAssertFalse(succeeded)
        let writes = await state.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testForegroundHooksStopAfterFailedModulePull() async throws {
        let state = SettingsArchiveState()
        let hooks = FullSyncHookTrace()
        let storage = SettingsArchiveStorage(state: state, failListingType: .quiz)
        do {
            try await ModuleSyncManager.shared.runFullSync(
                using: storage, backend: .webdav, archiveSource: UUID().uuidString,
                beforePull: { await hooks.record("legacy pull") },
                afterPublish: { await hooks.record("legacy export") },
                complete: { await hooks.record("completion") }
            )
            XCTFail("A failed module pull must stop the foreground pass")
        } catch ModuleStorageError.notAvailable {
            let events = await hooks.snapshot()
            let writes = await state.writeCount()
            XCTAssertEqual(events, ["legacy pull"])
            XCTAssertEqual(writes, 0)
        }
    }

    func testEditableReconciliationPullsAllTypesWithoutPublishing() async throws {
        let moduleId = "editable-pull-only-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "Editable pull only",
            filePath: "\(moduleId).lamp", fileHash: "base", isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-note", moduleId: moduleId,
            verseId: 1_001_001, content: "Keep pending", lastModified: 43
        ))
        try database.markPendingModulePublication(moduleId: moduleId, type: .notes)
        let state = RetryPublicationState()

        try await ModuleSyncManager.shared.reconcileEditableModules(
            with: RetryModuleStorage(moduleID: moduleId, state: state)
        )
        let completedPullAttempts = await state.attemptCount()
        XCTAssertEqual(completedPullAttempts, 0)

        do {
            try await ModuleSyncManager.shared.reconcileEditableModules(
                with: RetryModuleStorage(
                    moduleID: moduleId, state: state, failListingType: .devotional
                )
            )
            XCTFail("A later editable pull failure must stop reconciliation")
        } catch ModuleStorageError.notAvailable {
            let failedPullAttempts = await state.attemptCount()
            XCTAssertEqual(failedPullAttempts, 0)
            XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
        }
    }

    func testFullPassUsesOneSelectedStorageForSettingsAndModules() async {
        let state = SelectedStorageState()
        let completed = await ModuleSyncManager.shared.syncAll(
            using: SelectedStorageFixture(state: state),
            backend: .webdav,
            archiveSource: "test-provider"
        )
        XCTAssertFalse(completed)
        let settingsReads = await state.settingsReads()
        let listedTypes = await state.listedTypes()
        XCTAssertEqual(settingsReads, [LampSyncLayout.userSettingsPath])
        XCTAssertEqual(Set(listedTypes), Set(ModuleType.allCases))
        XCTAssertEqual(listedTypes.count, ModuleType.allCases.count)
    }

    @MainActor
    func testLocalOnlyDefaultModulesDoNotRequireRemoteStorage() async throws {
        let coordinator = SyncCoordinator.shared
        let previous = coordinator.settings
        var localOnly = previous
        localOnly.backend = .none
        localOnly.backendSelectionWasExplicit = true
        let database = ModuleDatabase.shared
        let hadNotes = try database.getModule(id: "notes") != nil
        let hadDevotionals = try database.getModule(id: "devotionals") != nil

        var workError: Error?
        do {
            try UserDatabase.shared.saveSyncSettings(localOnly)
            await coordinator.reloadSettings()
            try await ModuleSyncManager.shared.ensureDefaultNotesModule()
            async let firstDevotionalSetup: Void =
                ModuleSyncManager.shared.ensureDefaultDevotionalsModule()
            async let secondDevotionalSetup: Void =
                ModuleSyncManager.shared.ensureDefaultDevotionalsModule()
            try await firstDevotionalSetup
            try await secondDevotionalSetup
            XCTAssertFalse(try database.getAllModules(type: .notes).isEmpty)
            XCTAssertTrue(try database.getAllModules(type: .devotional)
                .contains(where: { $0.isEditable }))
        } catch {
            workError = error
        }

        try UserDatabase.shared.saveSyncSettings(previous)
        await coordinator.reloadSettings()
        if !hadNotes { try? database.deleteModule(id: "notes") }
        if !hadDevotionals { try? database.deleteModule(id: "devotionals") }
        if let workError { throw workError }
    }

    func testICloudExportKeepsWrittenRevisionWhenRemoteChangesAfterWrite() async throws {
        let moduleId = "export-race-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        let documents = temporaryDirectory.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let remoteURL = notes.appendingPathComponent("\(moduleId).lamp")
        let original = Data("previous module".utf8)
        let later = Data("another device's module".utf8)
        try original.write(to: remoteURL)
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Export revision race",
            filePath: "\(moduleId).lamp",
            fileHash: LampSyncContentRevision.digest(for: original),
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-note",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "local text",
            lastModified: 43
        ))
        let storage = LaterICloudModuleStorage(
            documentsURL: documents,
            remoteURL: remoteURL,
            laterBody: later
        )

        try await ModuleSyncManager.shared.exportModule(id: moduleId, to: storage)

        let written = try XCTUnwrap(storage.writtenData)
        XCTAssertEqual(
            try database.getModule(id: moduleId)?.fileHash,
            LampSyncContentRevision.digest(for: written)
        )
        XCTAssertEqual(try Data(contentsOf: remoteURL), later)
        XCTAssertNotEqual(
            try database.getModule(id: moduleId)?.fileHash,
            LampSyncContentRevision.digest(for: later)
        )
    }

    func testCanonicalLampFileWinsOverInstalledLegacyJSON() async throws {
        let moduleId = "dual-format-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Dual format test",
            filePath: "\(moduleId).json",
            fileHash: "canonical-revision",
            isEditable: true
        ))
        defer { try? database.deleteModule(id: moduleId) }

        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes,
                using: DualFormatModuleStorage(moduleID: moduleId)
            )
            XCTFail("A new canonical path needs an import even when hashes match")
        } catch ModuleStorageError.invalidData {
            // The fixture rejects the selected .lamp before decompression.
        }
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "canonical-revision")
    }

    func testSupersededCanonicalFileDoesNotHideLegacyEdit() async throws {
        let moduleId = "superseded-format-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "Superseded format test",
            filePath: "\(moduleId).json", fileHash: "old-legacy-revision",
            isEditable: true
        ))
        defer { try? database.deleteModule(id: moduleId) }
        let canonicalRevision = "\"canonical-revision\""
        let manifest = LampCompatibilityManifest(files: [
            .init(
                path: "Notes/\(moduleId).lamp",
                data: Data("archived notes".utf8),
                baseRevision: canonicalRevision
            )
        ])
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes,
                using: DualFormatModuleStorage(
                    moduleID: moduleId,
                    expectedReadFilename: "\(moduleId).json",
                    canonicalRevision: canonicalRevision
                ),
                compatibilityManifest: manifest
            )
            XCTFail("The active JSON edit must be read after the .lamp is superseded")
        } catch ModuleStorageError.invalidData {
            // The fixture signals that the active JSON path was selected.
        }
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "old-legacy-revision")
    }

    func testFailedModulePullKeepsPublicationPending() async throws {
        let moduleId = "failed-pull-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Failed pull test",
            filePath: "\(moduleId).json",
            fileHash: "old-revision",
            isEditable: true
        ))
        defer { try? database.deleteModule(id: moduleId) }
        try database.markPendingModulePublication(moduleId: moduleId, type: .notes)

        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes, using: DualFormatModuleStorage(moduleID: moduleId)
            )
            XCTFail("A failed pull must stop publication")
        } catch ModuleStorageError.invalidData {
            XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
        }
    }

    func testLocallyNewerNoteIsPublishedAfterJSONMerge() async throws {
        let moduleId = "local-merge-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Local merge test",
            filePath: "\(moduleId).json",
            fileHash: "old-json",
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-note",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "newer local text",
            lastModified: 20
        ))
        let remote = NoteModuleFile(
            id: moduleId,
            name: "Local merge test",
            description: nil,
            author: nil,
            version: nil,
            type: "notes",
            isEditable: true,
            entries: [NoteEntryFile(
                id: "\(moduleId)-note",
                verseId: 1_001_001,
                title: nil,
                content: "older remote text",
                verseRefs: nil,
                lastModified: 10,
                footnotes: nil
            )],
            media: nil
        )
        let state = MergePublicationState(jsonData: try JSONEncoder().encode(remote))
        let storage = MergePublicationStorage(moduleID: moduleId, state: state)

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        let saved = try XCTUnwrap(database.getModule(id: moduleId))
        XCTAssertEqual(saved.filePath, "\(moduleId).lamp")
        XCTAssertEqual(saved.fileHash, "published-lamp")
        XCTAssertFalse(try database.pendingModulePublications(type: .notes).contains(moduleId))
        let writes = await state.writeCount()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try database.getNoteEntry(id: "\(moduleId)-note")?.content, "newer local text")

        // Both representations now exist; the next pass follows the .lamp.
        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        let finalWrites = await state.writeCount()
        XCTAssertEqual(finalWrites, 1)
    }

    func testNoteJSONImportPersistsConflictAcrossUnchangedRemoteRevision() async throws {
        let moduleId = "sync-import-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Conflict import test",
            filePath: "\(moduleId).json",
            fileHash: "old-revision",
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(moduleId)-local",
            moduleId: moduleId,
            verseId: 1_001_001,
            content: "local text",
            lastModified: 42
        ))

        let remote = NoteModuleFile(
            id: moduleId,
            name: "Conflict import test",
            description: nil,
            author: nil,
            version: nil,
            type: "notes",
            isEditable: true,
            entries: [NoteEntryFile(
                id: "\(moduleId)-remote",
                verseId: 1_001_001,
                title: nil,
                content: "remote text",
                verseRefs: nil,
                lastModified: 42,
                footnotes: nil
            )],
            media: nil
        )
        let storage = ModuleJSONStorage(
            moduleID: moduleId,
            moduleType: .notes,
            hash: "new-revision",
            data: try JSONEncoder().encode(remote)
        )

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "new-revision")
        let retained = try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(retained.map(\.content), ["local text"])
        XCTAssertTrue(try database.hasPendingModuleConflicts(moduleId: moduleId))

        // The same hash is skipped on the next sync, but its conflict remains
        // in the local database for restoration after process restart.
        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        let restored = try XCTUnwrap(
            database.firstPendingModuleConflicts(type: .notes, as: NoteConflict.self)
        )
        XCTAssertEqual(restored.moduleId, moduleId)
        XCTAssertEqual(restored.conflicts.map(\.cloudEntry.content), ["remote text"])
    }

    func testUnversionedRemoteModuleIsReadEvenWhenStoredHashIsMissing() async throws {
        let moduleId = "unversioned-import-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Unversioned import",
            filePath: "\(moduleId).json",
            fileHash: nil,
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        let remote = NoteModuleFile(
            id: moduleId,
            name: "Unversioned import",
            description: nil,
            author: nil,
            version: nil,
            type: "notes",
            isEditable: true,
            entries: [NoteEntryFile(
                id: "\(moduleId)-entry",
                verseId: 1_001_001,
                title: nil,
                content: "remote without ETag",
                verseRefs: nil,
                lastModified: 42,
                footnotes: nil
            )],
            media: nil
        )
        let storage = ModuleJSONStorage(
            moduleID: moduleId,
            moduleType: .notes,
            hash: nil,
            data: try JSONEncoder().encode(remote)
        )

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        let imported = try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(imported.map(\.content), ["remote without ETag"])
    }

    func testModuleImportStoresRevisionFromSameReadAsBody() async throws {
        let moduleId = "paired-read-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .notes,
            name: "Paired import",
            filePath: "\(moduleId).json",
            fileHash: "listed-before",
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        let remote = NoteModuleFile(
            id: moduleId,
            name: "Paired import",
            description: nil,
            author: nil,
            version: nil,
            type: "notes",
            isEditable: true,
            entries: [NoteEntryFile(
                id: "\(moduleId)-entry",
                verseId: 1_001_001,
                title: nil,
                content: "body from GET",
                verseRefs: nil,
                lastModified: 42,
                footnotes: nil
            )],
            media: nil
        )
        let storage = ModuleJSONStorage(
            moduleID: moduleId,
            moduleType: .notes,
            hash: "listed-revision",
            data: try JSONEncoder().encode(remote),
            snapshotHash: "get-revision"
        )

        try await ModuleSyncManager.shared.syncModuleType(.notes, using: storage)
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "get-revision")
        let imported = try database.read { db in
            try NoteEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(imported.map(\.content), ["body from GET"])
    }

    func testInvalidOrMismatchedDictionaryJSONKeepsInstalledRows() async throws {
        let moduleId = "dictionary-preflight-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .dictionary,
            name: "Installed dictionary",
            filePath: "\(moduleId).json",
            fileHash: "installed-revision",
            isEditable: false
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: moduleId, key: "G1", lemma: "installed entry"
            ).insert(db)
        }
        let invalid = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .dictionary,
            hash: "invalid-revision", data: Data("invalid JSON".utf8)
        )
        do {
            try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: invalid)
            XCTFail("Malformed remote JSON must stop the import")
        } catch {
            // Verify the installed rows below.
        }

        let mismatchedData = try JSONSerialization.data(withJSONObject: [
            "id": "another-dictionary", "name": "Wrong identity",
            "type": "dictionary", "entries": []
        ])
        let mismatched = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .dictionary,
            hash: "mismatched-revision", data: mismatchedData
        )
        do {
            try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: mismatched)
            XCTFail("A differently identified remote module must stop the import")
        } catch ModuleSyncError.importFailed {
            // Verify the installed rows below.
        }

        let entries = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(entries.map(\.lemma), ["installed entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "installed-revision")

        let validData = try JSONSerialization.data(withJSONObject: [
            "id": moduleId, "name": "Updated dictionary", "type": "dictionary",
            "entries": [["key": "G2", "lemma": "replacement entry"]]
        ])
        try await ModuleSyncManager.shared.syncModuleType(
            .dictionary,
            using: ModuleJSONStorage(
                moduleID: moduleId, moduleType: .dictionary,
                hash: "updated-revision", data: validData
            )
        )
        let replaced = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(replaced.map(\.lemma), ["replacement entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "updated-revision")
    }

    func testDictionaryJSONKeyCollisionKeepsBothInstalledModules() async throws {
        let selectedID = "json-dictionary-\(UUID().uuidString)"
        let foreignID = "json-foreign-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        for id in [selectedID, foreignID] {
            try database.saveModule(Module(
                id: id, type: .dictionary, name: id,
                filePath: "\(id).json", fileHash: "installed-revision",
                isEditable: false
            ))
        }
        defer {
            for id in [selectedID, foreignID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: selectedID, key: "G1", lemma: "selected installed"
            ).insert(db)
            try DictionaryEntry(
                id: "\(selectedID):G2", moduleId: foreignID,
                key: "G2", lemma: "foreign installed"
            ).insert(db)
        }
        let incoming = try JSONSerialization.data(withJSONObject: [
            "id": selectedID, "name": "Incoming dictionary", "type": "dictionary",
            "entries": [["key": "G2", "lemma": "colliding entry"]]
        ])
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .dictionary,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .dictionary,
                    hash: "incoming-revision", data: incoming
                )
            )
            XCTFail("A foreign primary key must stop the JSON replacement")
        } catch {
            // Check both installed modules below.
        }
        for (id, expectedLemma) in [(selectedID, "selected installed"),
                                    (foreignID, "foreign installed")] {
            let entries = try database.read { db in
                try DictionaryEntry.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.lemma), [expectedLemma])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }
    }

    func testCommentaryJSONKeyCollisionKeepsBothInstalledModules() async throws {
        let selectedID = "json-commentary-\(UUID().uuidString)"
        let foreignID = "json-commentary-foreign-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        for id in [selectedID, foreignID] {
            try database.saveModule(Module(
                id: id, type: .commentary, name: id,
                filePath: "\(id).json", fileHash: "installed-revision",
                isEditable: false
            ))
        }
        defer {
            for id in [selectedID, foreignID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.write { db in
            try CommentaryBook(
                moduleId: selectedID, bookNumber: 41, title: "selected installed"
            ).insert(db)
            try CommentaryBook(
                id: "\(selectedID):40", moduleId: foreignID,
                bookNumber: 40, title: "foreign installed"
            ).insert(db)
        }
        let incoming = try JSONSerialization.data(withJSONObject: [
            "meta": [
                "schemaVersion": "1", "seriesFull": "Incoming series",
                "seriesAbbrev": "IN", "title": "Incoming book"
            ],
            "book": "Matt", "bookNumber": 40, "chapters": []
        ])
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .commentary,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .commentary,
                    hash: "incoming-revision", data: incoming
                )
            )
            XCTFail("A foreign primary key must stop the commentary replacement")
        } catch {
            // Check both installed modules below.
        }
        for (id, expectedTitle) in [(selectedID, "selected installed"),
                                    (foreignID, "foreign installed")] {
            let books = try database.read { db in
                try CommentaryBook.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(books.map(\.title), [expectedTitle])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }
    }

    func testFailedTranslationSchemaReplacementKeepsInstalledRows() async throws {
        let translationID = "translation-rollback-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveTranslation(TranslationModule(
            id: translationID, name: "Installed translation",
            abbreviation: "OLD", language: "en",
            filePath: "\(translationID).json", fileHash: "installed-revision"
        ))
        defer {
            try? database.write { db in
                try db.execute(
                    sql: "DELETE FROM translation_headings WHERE translation_id = ?",
                    arguments: [translationID]
                )
                try db.execute(
                    sql: "DELETE FROM translation_verses WHERE translation_id = ?",
                    arguments: [translationID]
                )
                try db.execute(
                    sql: "DELETE FROM translation_books WHERE translation_id = ?",
                    arguments: [translationID]
                )
                try db.execute(sql: "DELETE FROM translations WHERE id = ?", arguments: [translationID])
            }
        }
        try database.write { db in
            try TranslationBook(
                translationId: translationID, bookNumber: 1,
                bookId: "Gen", name: "Installed Genesis", testament: "OT",
                chapterCount: 0
            ).insert(db)
        }
        let meta: [String: Any] = [
            "schemaVersion": "1", "id": translationID, "type": "translation",
            "name": "Incoming translation", "abbreviation": "NEW", "language": "en"
        ]
        let incomingBook: [String: Any] = [
            "id": "Gen", "name": "Incoming Genesis", "number": 1,
            "testament": "OT", "chapters": []
        ]
        var mismatchedMeta = meta
        mismatchedMeta["type"] = "dictionary"
        let mismatched = try JSONSerialization.data(withJSONObject: [
            "meta": mismatchedMeta, "books": [incomingBook]
        ])
        do {
            try await ModuleSyncManager.shared.importTranslationSchemaModule(
                from: mismatched, fileHash: "wrong-kind-revision"
            )
            XCTFail("A different schema type must stop the translation import")
        } catch ModuleSyncError.importFailed {
            // The installed rows are checked after the duplicate-key attempt.
        }
        let invalid = try JSONSerialization.data(withJSONObject: [
            "meta": meta, "books": [incomingBook, incomingBook]
        ])
        do {
            try await ModuleSyncManager.shared.importTranslationSchemaModule(
                from: invalid, fileHash: "incoming-revision"
            )
            XCTFail("Duplicate incoming book keys must roll back the translation")
        } catch {
            // Check installed metadata and rows below.
        }
        XCTAssertEqual(try database.getTranslation(id: translationID)?.name, "Installed translation")
        XCTAssertEqual(try database.getTranslation(id: translationID)?.fileHash, "installed-revision")
        let oldBooks = try database.read { db in
            try TranslationBook.filter(Column("translation_id") == translationID).fetchAll(db)
        }
        XCTAssertEqual(oldBooks.map(\.name), ["Installed Genesis"])

        let valid = try JSONSerialization.data(withJSONObject: [
            "meta": meta, "books": [incomingBook]
        ])
        let validURL = temporaryDirectory.appendingPathComponent("valid-translation.json")
        try valid.write(to: validURL)
        try await ModuleSyncManager.shared.importTranslationFromFile(url: validURL)
        XCTAssertEqual(try database.getTranslation(id: translationID)?.name, "Incoming translation")
        XCTAssertEqual(
            try database.getTranslation(id: translationID)?.fileHash,
            LampSyncContentRevision.digest(for: valid)
        )
        let replacedBooks = try database.read { db in
            try TranslationBook.filter(Column("translation_id") == translationID).fetchAll(db)
        }
        XCTAssertEqual(replacedBooks.map(\.name), ["Incoming Genesis"])
    }

    func testMismatchedPortableModuleIdentityKeepsInstalledRows() async throws {
        let moduleId = "portable-preflight-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .dictionary, name: "Installed dictionary",
            filePath: "\(moduleId).lamp", fileHash: "installed-revision",
            isEditable: false
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: moduleId, key: "G1", lemma: "installed entry"
            ).insert(db)
        }
        let sourceURL = temporaryDirectory.appendingPathComponent("different.db")
        let source = try DatabaseQueue(path: sourceURL.path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, ?)",
                arguments: ["different-module", "dictionary"]
            )
        }
        let archive = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        let storage = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .dictionary,
            hash: "changed-revision", data: archive,
            fileName: "\(moduleId).lamp"
        )

        do {
            try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: storage)
            XCTFail("A portable body with a different ID must stop before replacing rows")
        } catch ModuleSyncError.importFailed {
            // Verify the installed rows below.
        }

        let entries = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(entries.map(\.lemma), ["installed entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "installed-revision")

    }

    func testFailedSQLiteCopyRollsBackInstalledModule() async throws {
        let moduleId = "sqlite-rollback-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .dictionary, name: "Installed dictionary",
            filePath: "\(moduleId).lamp", fileHash: "installed-revision",
            isEditable: false
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: moduleId, key: "G1", lemma: "installed entry"
            ).insert(db)
        }
        let sourceURL = temporaryDirectory.appendingPathComponent("missing-entries.db")
        let source = try DatabaseQueue(path: sourceURL.path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, ?)",
                arguments: [moduleId, "dictionary"]
            )
        }
        let archive = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        let storage = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .dictionary,
            hash: "broken-revision", data: archive,
            fileName: "\(moduleId).lamp"
        )

        do {
            try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: storage)
            XCTFail("A source without dictionary entries must fail during the copy")
        } catch {
            // Verify the old rows and revision survived the failed copy.
        }

        let entries = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(entries.map(\.lemma), ["installed entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "installed-revision")

        try await source.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary_entries (
                    id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                    transliteration TEXT, pronunciation TEXT,
                    senses_json TEXT, metadata_json TEXT
                )
                """)
            try db.execute(
                sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, ?, ?)",
                arguments: ["\(moduleId):G2", moduleId, "G2", "replacement entry"]
            )
        }
        let repairedArchive = try (Data(contentsOf: sourceURL) as NSData)
            .compressed(using: .zlib) as Data
        try await ModuleSyncManager.shared.syncModuleType(
            .dictionary,
            using: ModuleJSONStorage(
                moduleID: moduleId, moduleType: .dictionary,
                hash: "repaired-revision", data: repairedArchive,
                fileName: "\(moduleId).lamp"
            )
        )
        let replaced = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(replaced.map(\.lemma), ["replacement entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "repaired-revision")
    }

    func testFailedSQLiteMetadataSaveRollsBackCopiedRows() async throws {
        let moduleId = "sqlite-metadata-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .dictionary, name: "Installed dictionary",
            filePath: "\(moduleId).lamp", fileHash: "installed-revision",
            isEditable: false
        ))
        defer {
            try? database.writeWithoutTransaction { db in
                try db.execute(sql: "DROP TRIGGER IF EXISTS temp.reject_archive_metadata")
            }
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: moduleId, key: "G1", lemma: "installed entry"
            ).insert(db)
        }
        let sourceURL = temporaryDirectory.appendingPathComponent("metadata-source.sqlite")
        do {
            let source = try DatabaseQueue(path: sourceURL.path)
            try await source.write { db in
                try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
                try db.execute(
                    sql: "INSERT INTO module_format VALUES (?, 'dictionary')",
                    arguments: [moduleId]
                )
                try db.execute(sql: """
                    CREATE TABLE dictionary_entries (
                        id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                        transliteration TEXT, pronunciation TEXT,
                        senses_json TEXT, metadata_json TEXT
                    )
                    """)
                try db.execute(
                    sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, 'G2', 'replacement entry')",
                    arguments: ["\(moduleId):G2", moduleId]
                )
            }
        }
        let body = try (Data(contentsOf: sourceURL) as NSData)
            .compressed(using: .zlib) as Data
        let storage = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .dictionary,
            hash: "replacement-revision", data: body,
            fileName: "\(moduleId).lamp"
        )
        try database.writeWithoutTransaction { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_archive_metadata
                BEFORE UPDATE ON modules
                WHEN NEW.id = '\(moduleId)'
                BEGIN SELECT RAISE(ABORT, 'metadata rejected'); END
                """)
        }

        do {
            try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: storage)
            XCTFail("A failed metadata save must roll back the copied dictionary rows")
        } catch {
            let entries = try database.read { db in
                try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.lemma), ["installed entry"])
            XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "installed-revision")
        }

        try database.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER temp.reject_archive_metadata")
        }
        try await ModuleSyncManager.shared.syncModuleType(.dictionary, using: storage)
        let replacement = try database.read { db in
            try DictionaryEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(replacement.map(\.lemma), ["replacement entry"])
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "replacement-revision")
    }

    func testFailedCommentarySQLiteCopyRestoresModuleAndBook() async throws {
        let moduleId = "commentary-rollback-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId, type: .commentary, name: "Installed commentary",
            filePath: "\(moduleId).lamp", fileHash: "installed-revision",
            isEditable: false
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        try database.write { db in
            try CommentaryBook(
                moduleId: moduleId, bookNumber: 40, title: "Installed book"
            ).insert(db)
        }
        let sourceURL = temporaryDirectory.appendingPathComponent("broken-commentary.db")
        let source = try DatabaseQueue(path: sourceURL.path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, ?)",
                arguments: [moduleId, "commentary"]
            )
        }
        let archive = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        let storage = ModuleJSONStorage(
            moduleID: moduleId, moduleType: .commentary,
            hash: "broken-revision", data: archive,
            fileName: "\(moduleId).lamp"
        )

        do {
            try await ModuleSyncManager.shared.syncModuleType(.commentary, using: storage)
            XCTFail("Missing commentary tables must stop the import")
        } catch {
            // Verify rollback below.
        }
        XCTAssertEqual(try database.getModule(id: moduleId)?.fileHash, "installed-revision")
        let books = try database.read { db in
            try CommentaryBook.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(books.map(\.title), ["Installed book"])
    }

    func testSQLiteHeaderCannotImportAnotherModulesRows() async throws {
        let selectedID = "sqlite-owner-\(UUID().uuidString)"
        let foreignID = "sqlite-foreign-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        for id in [selectedID, foreignID] {
            try database.saveModule(Module(
                id: id, type: .dictionary, name: id,
                filePath: "\(id).lamp", fileHash: "installed-revision",
                isEditable: false
            ))
        }
        defer {
            for id in [selectedID, foreignID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.write { db in
            try DictionaryEntry(
                moduleId: selectedID, key: "G1", lemma: "selected installed"
            ).insert(db)
            try DictionaryEntry(
                moduleId: foreignID, key: "G2", lemma: "foreign installed"
            ).insert(db)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("mixed-ownership.db")
        let source = try DatabaseQueue(path: sourceURL.path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, 'dictionary')",
                arguments: [selectedID]
            )
            try db.execute(sql: """
                CREATE TABLE dictionary_entries (
                    id TEXT, module_id TEXT, key TEXT, lemma TEXT,
                    transliteration TEXT, pronunciation TEXT,
                    senses_json TEXT, metadata_json TEXT
                )
                """)
            try db.execute(
                sql: "INSERT INTO dictionary_entries (id, module_id, key, lemma) VALUES (?, ?, 'G3', 'foreign incoming')",
                arguments: ["\(foreignID):G3", foreignID]
            )
        }
        let archive = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .dictionary,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .dictionary,
                    hash: "incoming-revision", data: archive,
                    fileName: "\(selectedID).lamp"
                )
            )
            XCTFail("Mixed module ownership must stop the import")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("another module"))
        }

        for (id, expectedLemma) in [(selectedID, "selected installed"),
                                    (foreignID, "foreign installed")] {
            let entries = try database.read { db in
                try DictionaryEntry.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.lemma), [expectedLemma])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }

        // The owner now matches, but the source reuses a primary key owned by
        // the installed foreign module. The bulk copy must fail atomically.
        try await source.write { db in
            try db.execute(
                sql: "UPDATE dictionary_entries SET id = ?, module_id = ?",
                arguments: ["\(foreignID):G2", selectedID]
            )
        }
        let collidingArchive = try (Data(contentsOf: sourceURL) as NSData)
            .compressed(using: .zlib) as Data
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .dictionary,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .dictionary,
                    hash: "colliding-revision", data: collidingArchive,
                    fileName: "\(selectedID).lamp"
                )
            )
            XCTFail("A foreign primary-key collision must stop the import")
        } catch {
            // Verify both installed modules below.
        }
        for (id, expectedLemma) in [(selectedID, "selected installed"),
                                    (foreignID, "foreign installed")] {
            let entries = try database.read { db in
                try DictionaryEntry.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.lemma), [expectedLemma])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }
    }

    func testFailedSQLiteNoteMergePreservesRowsAndRevision() async throws {
        let selectedID = "note-rollback-\(UUID().uuidString)"
        let foreignID = "note-foreign-\(UUID().uuidString)"
        let foreignEntryID = "foreign-note-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        for id in [selectedID, foreignID] {
            try database.saveModule(Module(
                id: id, type: .notes, name: id,
                filePath: "\(id).lamp", fileHash: "installed-revision",
                isEditable: true
            ))
        }
        defer {
            for id in [selectedID, foreignID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(selectedID)-old", moduleId: selectedID,
            verseId: 1_001_001, content: "selected installed", lastModified: 41
        ))
        try database.saveNoteEntry(NoteEntry(
            id: foreignEntryID, moduleId: foreignID,
            verseId: 1_001_002, content: "foreign installed", lastModified: 42
        ))

        let sourceURL = temporaryDirectory.appendingPathComponent("colliding-note.db")
        let source = try DatabaseQueue(path: sourceURL.path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE module_format (module_id TEXT, module_type TEXT)")
            try db.execute(
                sql: "INSERT INTO module_format VALUES (?, 'notes')", arguments: [selectedID]
            )
            try db.execute(sql: """
                CREATE TABLE module_meta (
                    id TEXT PRIMARY KEY, name TEXT, description TEXT,
                    author TEXT, version TEXT, is_editable INTEGER
                )
                """)
            try db.execute(
                sql: "INSERT INTO module_meta (id, name, is_editable) VALUES (?, 'Incoming notes', 1)",
                arguments: [selectedID]
            )
            try db.execute(sql: """
                CREATE TABLE note_entries (
                    id TEXT PRIMARY KEY, module_id TEXT, verse_id INTEGER,
                    book INTEGER, chapter INTEGER, verse INTEGER, title TEXT,
                    content TEXT, verse_refs_json TEXT, last_modified INTEGER,
                    footnotes_json TEXT, search_text TEXT, record_change_tag TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO note_entries
                (id, module_id, verse_id, book, chapter, verse, content, last_modified)
                VALUES (?, ?, 1001003, 1, 1, 3, 'incoming note', 43)
                """, arguments: [foreignEntryID, selectedID])
        }
        let archive = try (Data(contentsOf: sourceURL) as NSData).compressed(using: .zlib) as Data
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .notes,
                    hash: "incoming-revision", data: archive,
                    fileName: "\(selectedID).lamp"
                )
            )
            XCTFail("A foreign note key collision must stop the import")
        } catch {
            // Check that metadata, rows, and publication marker stayed intact.
        }
        for (id, expected) in [(selectedID, "selected installed"),
                               (foreignID, "foreign installed")] {
            let entries = try database.read { db in
                try NoteEntry.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.content), [expected])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }
        XCTAssertFalse(try database.pendingModulePublications(type: .notes).contains(selectedID))
    }

    func testFailedJSONNoteMergePreservesRowsAndRevision() async throws {
        let selectedID = "json-note-rollback-\(UUID().uuidString)"
        let foreignID = "json-note-foreign-\(UUID().uuidString)"
        let foreignEntryID = "foreign-note-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        for id in [selectedID, foreignID] {
            try database.saveModule(Module(
                id: id, type: .notes, name: id,
                filePath: "\(id).json", fileHash: "installed-revision",
                isEditable: true
            ))
        }
        defer {
            for id in [selectedID, foreignID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.saveNoteEntry(NoteEntry(
            id: "\(selectedID)-old", moduleId: selectedID,
            verseId: 1_001_001, content: "selected installed", lastModified: 41
        ))
        try database.saveNoteEntry(NoteEntry(
            id: foreignEntryID, moduleId: foreignID,
            verseId: 1_001_002, content: "foreign installed", lastModified: 42
        ))
        let incoming = NoteModuleFile(
            id: selectedID, name: "Incoming notes", description: nil,
            author: nil, version: nil, type: "notes", isEditable: true,
            entries: [NoteEntryFile(
                id: foreignEntryID, verseId: 1_001_003, title: nil,
                content: "incoming note", verseRefs: nil,
                lastModified: 43, footnotes: nil
            )], media: nil
        )
        do {
            try await ModuleSyncManager.shared.syncModuleType(
                .notes,
                using: ModuleJSONStorage(
                    moduleID: selectedID, moduleType: .notes,
                    hash: "incoming-revision", data: try JSONEncoder().encode(incoming)
                )
            )
            XCTFail("A foreign note key collision must stop the JSON import")
        } catch {
            // Check that both modules survived the failed transaction.
        }
        for (id, expected) in [(selectedID, "selected installed"),
                               (foreignID, "foreign installed")] {
            let entries = try database.read { db in
                try NoteEntry.filter(Column("module_id") == id).fetchAll(db)
            }
            XCTAssertEqual(entries.map(\.content), [expected])
            XCTAssertEqual(try database.getModule(id: id)?.fileHash, "installed-revision")
        }
        XCTAssertFalse(try database.pendingModulePublications(type: .notes).contains(selectedID))
    }

    func testDevotionalJSONImportPersistsEqualTimeConflict() async throws {
        let moduleId = "devotional-import-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        try database.saveModule(Module(
            id: moduleId,
            type: .devotional,
            name: "Devotional conflict test",
            filePath: "\(moduleId).json",
            fileHash: "old-revision",
            isEditable: true
        ))
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleId)
            try? database.deleteModule(id: moduleId)
        }
        var local = Devotional.newEmpty(title: "Local title")
        local.meta.id = "\(moduleId)-entry"
        local.meta.lastModified = 42
        try database.saveDevotionalEntry(DevotionalEntry(from: local, moduleId: moduleId))
        var remote = local
        remote.meta.title = "Remote title"
        let file = DevotionalModuleFile(
            id: moduleId,
            name: "Devotional conflict test",
            isEditable: true,
            entries: [remote]
        )
        let storage = ModuleJSONStorage(
            moduleID: moduleId,
            moduleType: .devotional,
            hash: "new-revision",
            data: try JSONEncoder().encode(file)
        )

        try await ModuleSyncManager.shared.syncModuleType(.devotional, using: storage)
        let retained = try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == moduleId).fetchAll(db)
        }
        XCTAssertEqual(retained.map(\.title), ["Local title"])
        XCTAssertTrue(try database.hasPendingModuleConflicts(moduleId: moduleId))
        let restored = try XCTUnwrap(
            database.firstPendingModuleConflicts(type: .devotional, as: DevotionalConflict.self)
        )
        XCTAssertEqual(restored.moduleId, moduleId)
        XCTAssertEqual(restored.conflicts.map(\.cloudEntry.meta.title), ["Remote title"])
    }
}

private actor SettingsWriteState {
    private var data: Data?

    func save(_ value: Data) { data = value }
    func uploadedData() -> Data? { data }
}

private actor SettingsTokenSequence {
    private var reads = 0

    func next() -> String {
        reads += 1
        return reads == 1 ? "before" : "after"
    }
}

private actor FullSyncHookTrace {
    private var events: [String] = []

    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private actor SettingsArchiveState {
    private var files: [String: LampSyncRemoteFile] = [:]
    private var nextRevision = 0
    private var failLegacyWrite = false

    func file(_ path: String) -> LampSyncRemoteFile? { files[path] }
    func writeCount() -> Int { nextRevision }

    func seed(path: String, file: LampSyncRemoteFile) { files[path] = file }

    func failNextLegacyWrite() { failLegacyWrite = true }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) throws -> String? {
        if path == LampSyncLayout.userSettingsPath && failLegacyWrite {
            failLegacyWrite = false
            throw WebDAVError.preconditionFailed
        }
        let current = files[path]
        switch condition {
        case .ifAbsent where current != nil:
            throw WebDAVError.preconditionFailed
        case .ifRevision(let expected) where current?.revision != expected:
            throw WebDAVError.preconditionFailed
        default:
            break
        }
        nextRevision += 1
        files[path] = LampSyncRemoteFile(
            data: data,
            revision: "\"settings-\(nextRevision)\""
        )
        return nil // Exercise the shared GET confirmation path.
    }

    func replaceLegacy(_ data: Data) {
        nextRevision += 1
        files[LampSyncLayout.userSettingsPath] = LampSyncRemoteFile(
            data: data,
            revision: "\"settings-\(nextRevision)\""
        )
    }
}

private struct SettingsArchiveStorage: ModuleStorage, LampSyncRemoteStore {
    let state: SettingsArchiveState
    var failListingType: ModuleType? = nil

    func isAvailable() async -> Bool { true }
    func getChangeToken(path: String) async -> String? {
        await state.file(path)?.revision
    }
    func readFile(path: String) async throws -> Data {
        guard let file = await state.file(path) else {
            throw ModuleStorageError.fileNotFound(path)
        }
        return file.data
    }
    func writeFile(path: String, data: Data) async throws {
        fatalError("WebDAV settings should use a conditional remote write")
    }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? { await state.file(path) }
    func revision(path: String) async throws -> String? {
        await state.file(path)?.revision
    }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await state.write(data, to: path, condition: condition)
    }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        if type == failListingType { throw ModuleStorageError.notAvailable }
        return []
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        fatalError("Unexpected module read")
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        fatalError("Unexpected module read")
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Unexpected module write")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Unexpected module delete")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }
}

private struct ChangingSettingsStorage: ModuleStorage {
    let tokens: SettingsTokenSequence
    var missingToken = false
    var readState: ArchiveReadState? = nil

    func isAvailable() async -> Bool { true }
    func getChangeToken(path: String) async -> String? {
        if missingToken { return nil }
        return await tokens.next()
    }
    func readFile(path: String) async throws -> Data {
        await readState?.recordRead()
        return Data([1])
    }
    func writeFile(path: String, data: Data) async throws { fatalError("Unexpected write") }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        fatalError("Unexpected module read")
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        fatalError("Unexpected module read")
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Unexpected module write")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Unexpected module delete")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
}

private struct MissingSettingsStorage: ModuleStorage {
    func isAvailable() async -> Bool { true }
    func getChangeToken(path: String) async -> String? { nil }
    func readFile(path: String) async throws -> Data {
        throw ModuleStorageError.fileNotFound(path)
    }
    func writeFile(path: String, data: Data) async throws {
        fatalError("A removed remote file must not be recreated")
    }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        fatalError("Unexpected module read")
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        fatalError("Unexpected module read")
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Unexpected module write")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Unexpected module delete")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }
}

private actor ArchiveReadState {
    private var reads = 0

    func recordRead() { reads += 1 }
    func count() -> Int { reads }
}

private actor PreferenceArchiveStore: LampSyncRemoteStore {
    private var data: Data
    private var revisionValue = "\"preference-archive-v1\""
    private var writes = 0

    init(data: Data) { self.data = data }

    func archiveData() -> Data { data }
    func writeCount() -> Int { writes }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func read(path: String) async throws -> LampSyncRemoteFile? {
        LampSyncRemoteFile(data: data, revision: revisionValue)
    }
    func revision(path: String) async throws -> String? { revisionValue }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        guard condition == .ifRevision(revisionValue) else {
            throw WebDAVError.preconditionFailed
        }
        self.data = data
        writes += 1
        revisionValue = "\"preference-archive-v2\""
        return revisionValue
    }
}

private struct ArchiveRemoteStore: LampSyncRemoteStore {
    let data: Data
    let revisionValue: String
    let state: ArchiveReadState

    init(data: Data, revision: String, state: ArchiveReadState) {
        self.data = data
        self.revisionValue = revision
        self.state = state
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func revision(path: String) async throws -> String? { revisionValue }
    func read(path: String) async throws -> LampSyncRemoteFile? {
        await state.recordRead()
        return LampSyncRemoteFile(data: data, revision: revisionValue)
    }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        fatalError("Archive import must not write to remote storage")
    }
}

private actor MergePublicationState {
    let jsonData: Data
    private var lampData: Data?
    private var writes = 0

    init(jsonData: Data) { self.jsonData = jsonData }

    func listedFiles(moduleID: String) -> [ModuleFileInfo] {
        var files = [ModuleFileInfo(
            id: moduleID, type: .notes, filePath: "\(moduleID).json",
            fileHash: "remote-json", modificationDate: nil
        )]
        if lampData != nil {
            files.append(ModuleFileInfo(
                id: moduleID, type: .notes, filePath: "\(moduleID).lamp",
                fileHash: "published-lamp", modificationDate: nil
            ))
        }
        return files
    }

    func hash(fileName: String) -> String? {
        if fileName.hasSuffix(".json") { return "remote-json" }
        return lampData == nil ? nil : "published-lamp"
    }

    func publish(_ data: Data) {
        lampData = data
        writes += 1
    }
    func writeCount() -> Int { writes }
}

private struct MergePublicationStorage: ModuleStorage {
    let moduleID: String
    let state: MergePublicationState

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == .notes else { return [] }
        return await state.listedFiles(moduleID: moduleID)
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        if fileName.hasSuffix(".json") { return await state.jsonData }
        XCTFail("The published .lamp should not need reimport")
        return Data()
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        if fileName.hasSuffix(".json") {
            return LampSyncRemoteFile(data: await state.jsonData, revision: "remote-json")
        }
        XCTFail("The published .lamp should not need reimport")
        return LampSyncRemoteFile(data: Data(), revision: nil)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        XCTAssertTrue(fileName.hasSuffix(".lamp"))
        await state.publish(data)
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {}
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await state.hash(fileName: fileName)
    }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data { Data() }
    func writeFile(path: String, data: Data) async throws {}
}

private struct DualFormatModuleStorage: ModuleStorage {
    let moduleID: String
    var expectedReadFilename: String? = nil
    var canonicalRevision = "canonical-revision"

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == .notes else { return [] }
        return [
            ModuleFileInfo(
                id: moduleID, type: .notes, filePath: "\(moduleID).json",
                fileHash: "legacy-revision", modificationDate: nil
            ),
            ModuleFileInfo(
                id: moduleID, type: .notes, filePath: "\(moduleID).lamp",
                fileHash: canonicalRevision, modificationDate: nil
            ),
        ]
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        XCTAssertEqual(fileName, expectedReadFilename ?? "\(moduleID).lamp")
        throw ModuleStorageError.invalidData
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        _ = try await readModuleFile(type: type, fileName: fileName)
        throw ModuleStorageError.invalidData
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        XCTFail("An unchanged canonical module should not be published")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {}
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data { Data() }
    func writeFile(path: String, data: Data) async throws {}
}

private actor RetryPublicationState {
    private var hash = "base"
    private var attempts = 0

    func currentHash() -> String { hash }
    func attemptCount() -> Int { attempts }

    func publish(_ data: Data) throws {
        attempts += 1
        if attempts == 1 { throw ModuleStorageError.notAvailable }
        hash = "published"
    }
}

private struct RetryModuleStorage: ModuleStorage {
    let moduleID: String
    let state: RetryPublicationState
    var failListingType: ModuleType? = nil

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        if type == failListingType { throw ModuleStorageError.notAvailable }
        guard type == .notes else { return [] }
        return [ModuleFileInfo(
            id: moduleID,
            type: .notes,
            filePath: "\(moduleID).lamp",
            fileHash: await state.currentHash(),
            modificationDate: nil
        )]
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        XCTFail("An unchanged remote module should not be imported")
        return Data()
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        XCTFail("An unchanged remote module should not be imported")
        return LampSyncRemoteFile(data: Data(), revision: nil)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        try await state.publish(data)
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        XCTFail("Export must not delete a remote module")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await state.currentHash()
    }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data { Data() }
    func writeFile(path: String, data: Data) async throws {
        XCTFail("Module export must not write another path")
    }
}

private actor SelectedStorageState {
    private var reads: [String] = []
    private var types: [ModuleType] = []
    func recordRead(_ path: String) { reads.append(path) }
    func recordList(_ type: ModuleType) { types.append(type) }
    func settingsReads() -> [String] { reads }
    func listedTypes() -> [ModuleType] { types }
}

private struct SelectedStorageFixture: ModuleStorage {
    let state: SelectedStorageState

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        await state.recordList(type)
        return []
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        XCTFail("No module was listed")
        return Data()
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        XCTFail("No module was listed")
        return LampSyncRemoteFile(data: Data(), revision: nil)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        XCTFail("A failed settings pull must block module publication")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        XCTFail("A failed settings pull must not delete remote files")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data {
        await state.recordRead(path)
        throw ModuleStorageError.invalidData
    }
    func writeFile(path: String, data: Data) async throws {
        XCTFail("A failed settings pull must not publish settings")
    }
}

private final class LaterICloudModuleStorage: ICloudModuleStorage {
    let remoteURL: URL
    let laterBody: Data
    private(set) var writtenData: Data?

    init(documentsURL: URL, remoteURL: URL, laterBody: Data) {
        self.remoteURL = remoteURL
        self.laterBody = laterBody
        super.init(documentsURL: documentsURL)
    }

    override func isAvailable() async -> Bool { true }

    override func writeModuleFile(
        type: ModuleType,
        fileName: String,
        data: Data,
        matching expectedDigest: String?
    ) async throws {
        try await super.writeModuleFile(
            type: type,
            fileName: fileName,
            data: data,
            matching: expectedDigest
        )
        writtenData = data
        try laterBody.write(to: remoteURL)
    }
}

private actor CapturedModuleBody {
    private var stored: Data?
    private var mediaFiles: [String: Data] = [:]
    func save(_ data: Data) { stored = data }
    func body() -> Data? { stored }
    func saveMedia(_ data: Data, at path: String) { mediaFiles[path] = data }
    func media(at path: String) -> Data? { mediaFiles[path] }
}

private struct CapturingModuleStorage: ModuleStorage {
    let state: CapturedModuleBody
    var moduleID: String? = nil
    var moduleType: ModuleType? = nil

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard let moduleID, moduleType == type, let body = await state.body() else { return [] }
        return [ModuleFileInfo(
            id: moduleID, type: type, filePath: "\(moduleID).lamp",
            fileHash: LampSyncContentRevision.digest(for: body), modificationDate: nil
        )]
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        throw ModuleStorageError.fileNotFound(fileName)
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        guard let body = await state.body() else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return LampSyncModuleRead.content(body)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        await state.save(data)
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {}
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        let body = await state.body()
        return body.map(LampSyncContentRevision.digest(for:))
    }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data { throw ModuleStorageError.fileNotFound(path) }
    func writeFile(path: String, data: Data) async throws {
        await state.saveMedia(data, at: path)
    }
}

private struct ModuleJSONStorage: ModuleStorage {
    let moduleID: String
    let moduleType: ModuleType
    let hash: String?
    let data: Data
    var snapshotHash: String? = nil
    var fileName: String? = nil
    var mediaReadFailure = false

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == moduleType else { return [] }
        return [ModuleFileInfo(
            id: moduleID,
            type: moduleType,
            filePath: fileName ?? "\(moduleID).json",
            fileHash: hash,
            modificationDate: nil
        )]
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data { data }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        LampSyncRemoteFile(data: data, revision: snapshotHash ?? hash)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        XCTFail("Import must not publish an unresolved conflict")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        XCTFail("Import must not delete a remote module")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { hash }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data {
        if mediaReadFailure { throw ModuleStorageError.fileNotFound(path) }
        return data
    }
    func writeFile(path: String, data: Data) async throws {
        XCTFail("Import must not publish a remote file")
    }
}

private struct CompatibilityFolderStorage: ModuleStorage {
    let moduleID: String
    let revisionValue: String
    let state: ArchiveReadState

    func isAvailable() async -> Bool { true }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == .notes else { return [] }
        return [ModuleFileInfo(
            id: moduleID,
            type: .notes,
            filePath: "\(moduleID).lamp",
            fileHash: revisionValue,
            modificationDate: nil
        )]
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        await state.recordRead()
        return Data("invalid module".utf8)
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        await state.recordRead()
        return LampSyncRemoteFile(data: Data("invalid module".utf8), revision: revisionValue)
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Unexpected module write")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Unexpected module delete")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { revisionValue }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
    func readFile(path: String) async throws -> Data { Data() }
    func writeFile(path: String, data: Data) async throws {
        fatalError("Unexpected file write")
    }
}

private struct ChangedSettingsStorage: ModuleStorage, LampSyncRemoteStore {
    let token: String?
    let reportedChangeToken: String?
    let writeState: SettingsWriteState?

    init(
        token: String?,
        reportedChangeToken: String? = nil,
        writeState: SettingsWriteState? = nil
    ) {
        self.token = token
        self.reportedChangeToken = reportedChangeToken
        self.writeState = writeState
    }

    func isAvailable() async -> Bool { true }
    func getChangeToken(path: String) async -> String? { reportedChangeToken ?? token }
    func revision(path: String) async throws -> String? {
        path == LampSyncLayout.archivePath ? nil : token
    }
    func read(path: String) async throws -> LampSyncRemoteFile? {
        if path == LampSyncLayout.archivePath { return nil }
        if let data = await writeState?.uploadedData() {
            return LampSyncRemoteFile(data: data, revision: "\"after\"")
        }
        return LampSyncRemoteFile(data: Data([1]), revision: token)
    }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { [] }
    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        guard condition == .ifRevision("\"same\"") else {
            fatalError("Expected a conditional update with the exact ETag")
        }
        if let writeState {
            await writeState.save(data)
            return nil
        }
        throw WebDAVError.preconditionFailed
    }
    func readFile(path: String) async throws -> Data { Data([2]) }
    func writeFile(path: String, data: Data) async throws { fatalError("Unexpected write") }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        fatalError("Unexpected module read")
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        fatalError("Unexpected module read")
    }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Unexpected module write")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Unexpected module delete")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? { nil }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
}
