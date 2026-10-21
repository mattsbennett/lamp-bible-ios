//
//  Lamp_BibleTests.swift
//  Lamp BibleTests
//
//  Created by Matthew Bennett on 2023-10-14.
//

import XCTest
import GRDB
import LampCore
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

    func testNotesMarkdownRoundTripKeepsIntroductionsRangesAndRepeatedFootnotes() throws {
        let source = """
        ---
        bookNumber: 43
        ---
        ## Chapter 1
        ### Introduction
        Opening[^intro].
        ### 1:1-2:3
        🌿 First[^7], repeated[^7].
        > [!footnote] 7
        > A verse footnote.
        ---
        [^intro]: A chapter footnote.
        """
        let manager = NotesImportExportManager.shared
        let book = try manager.parseMarkdownToNotes(content: source, filename: "untitled.md")
        let chapter = try XCTUnwrap(book.chapter(1))
        XCTAssertEqual(book.bookNumber, 43)
        XCTAssertEqual(chapter.introduction?.plainText, "Opening[^1].")
        XCTAssertEqual(chapter.footnotes?.first?.plainText, "A chapter footnote.")
        let note = try XCTUnwrap(chapter.verses?.first)
        XCTAssertEqual(note.ev, 43_002_003)
        XCTAssertEqual(note.commentary.plainText, "🌿 First[^1], repeated[^1].")
        XCTAssertEqual(note.footnotes?.count, 1)
        let restored = try manager.parseMarkdownToNotes(
            content: manager.generateMarkdown(from: book), filename: "John.md"
        )
        XCTAssertEqual(restored.chapter(1)?.introduction?.plainText, chapter.introduction?.plainText)
        XCTAssertEqual(restored.chapter(1)?.verses?.first?.commentary.plainText, note.commentary.plainText)
        XCTAssertEqual(restored.chapter(1)?.verses?.first?.footnotes?.first?.plainText, "A verse footnote.")
    }

    func testInvalidNotesMarkdownCannotOverwriteAnEarlierValidNote() async throws {
        let database = ModuleDatabase.shared
        let moduleID = "invalid-markdown-\(UUID().uuidString)"
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }
        try database.saveModule(Module(id: moduleID, type: .notes,
            name: "Notes fixture", filePath: "fixture.lamp", isEditable: true))
        let original = NoteEntry(moduleId: moduleID, verseId: 43_001_001, content: "Keep this note.")
        try database.saveNoteEntry(original)
        do {
            _ = try await NotesImportExportManager.shared.importNotesFromMarkdownString("""
            ## John 1:1
            Replacement.
            ### 1:1000
            Invalid later note.
            """, moduleId: moduleID)
            XCTFail("An invalid reference must reject the whole import")
        } catch let error as LampLibraryError {
            guard case .invalidPersonalContent = error else {
                return XCTFail("Unexpected import error: \(error)")
            }
        } catch {
            return XCTFail("Unexpected import error: \(error)")
        }
        XCTAssertEqual(try database.getNoteEntry(id: original.id)?.content, "Keep this note.")
        XCTAssertEqual(try database.getNotesForVerse(moduleId: moduleID, verseId: 43_001_001).count, 1)
    }

    func testMultiBookNotesMarkdownAcceptsCrossChapterRanges() async throws {
        let moduleID = "markdown-ranges-\(UUID().uuidString)"
        defer {
            try? ModuleDatabase.shared.deleteAllEntriesForModule(moduleId: moduleID)
            try? ModuleDatabase.shared.deleteModule(id: moduleID)
        }
        let markdown = """
        # My Notes

        ## John

        ### Chapter 1

        #### 1:1-2:3

        The Word[^one].

        ---

        [^one]: An explanatory footnote.
        """
        let importedCount = try await NotesImportExportManager.shared
            .importNotesFromMarkdownString(markdown, moduleId: moduleID)
        XCTAssertEqual(importedCount, 1)
        let note = try XCTUnwrap(try ModuleDatabase.shared.getNotesForVerse(
            moduleId: moduleID, verseId: 43_001_001
        ).first)
        XCTAssertEqual(note.verseRefs, [43_002_003])
        XCTAssertEqual(note.footnotes?.first?.plainText, "An explanatory footnote.")
    }

    func testNotesMarkdownImportsReferenceHeadingsAcrossBooksWithoutATitle() async throws {
        let database = ModuleDatabase.shared
        let moduleID = "reference-headings-\(UUID().uuidString)"
        defer {
            try? database.deleteAllEntriesForModule(moduleId: moduleID)
            try? database.deleteModule(id: moduleID)
        }
        let count = try await NotesImportExportManager.shared.importNotesFromMarkdownString("""
        ## John 1:1
        A note on John.
        ## Genesis 1:1
        A note on Genesis.
        """, moduleId: moduleID)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try database.getNotesForVerse(moduleId: moduleID, verseId: 43_001_001).first?.content,
            "A note on John.")
        XCTAssertEqual(try database.getNotesForVerse(moduleId: moduleID, verseId: 1_001_001).first?.content,
            "A note on Genesis.")
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

    func testMultiDevotionalMarkdownPreservesRichFieldsAcrossImport() throws {
        let sourceID = "markdown-source-\(UUID().uuidString)"
        let targetID = "markdown-target-\(UUID().uuidString)"
        let database = ModuleDatabase.shared
        defer {
            for id in [sourceID, targetID] {
                try? database.deleteAllEntriesForModule(moduleId: id)
                try? database.deleteModule(id: id)
            }
        }
        try database.saveModule(Module(
            id: sourceID, type: .devotional, name: "Writing", filePath: "writing.lamp"
        ))
        try database.saveModule(Module(
            id: targetID, type: .devotional, name: "Imported", filePath: "imported.lamp"
        ))
        let rich = Devotional(
            meta: DevotionalMeta(
                title: "Morning Hope", subtitle: "Beginning well", author: "A Reader",
                date: "2026-08-03", tags: ["hope"], category: .reflection,
                series: DevotionalSeriesInfo(id: nil, name: "Daily Hope", order: 1),
                keyScriptures: [DevotionalKeyScripture(
                    sv: 43_001_001, ev: nil, label: "John 1:1"
                )]
            ),
            summary: .plain("God gives hope."),
            content: .blocks([
                .paragraph("Opening."), .heading("A body heading", level: 2),
                .paragraph("More detail.")
            ]),
            footnotes: [DevotionalFootnote(id: "one", content: .plain("A footnote."))]
        )
        try database.saveDevotionalEntry(DevotionalEntry(from: rich, moduleId: sourceID))
        let markdown = try MarkdownConverter.exportDevotionalsToMarkdown(moduleId: sourceID)
        XCTAssertTrue(markdown.contains("## A body heading"))
        let individual = try XCTUnwrap(
            MarkdownConverter.exportDevotionalsToMarkdownByEntry(moduleId: sourceID)["Morning Hope"]
        )
        XCTAssertTrue(individual.contains("series:"))
        XCTAssertTrue(individual.contains("## A body heading"))
        XCTAssertEqual(try LampPersonalMarkdownParser.devotionals(
            from: individual, filename: "Morning Hope"
        ).first?.footnotes, "[^one]: A footnote.")
        XCTAssertEqual(try MarkdownConverter.importDevotionalsFromMarkdown(
            markdown, moduleId: targetID
        ), 1)
        let imported = try database.read { db in
            try DevotionalEntry.filter(Column("module_id") == targetID).fetchOne(db)
        }
        let restored = try XCTUnwrap(imported?.toDevotional())
        XCTAssertEqual(restored.meta.subtitle, "Beginning well")
        XCTAssertEqual(restored.meta.author, "A Reader")
        XCTAssertEqual(restored.meta.tags, ["hope"])
        XCTAssertEqual(restored.meta.category, .reflection)
        XCTAssertEqual(restored.meta.series?.name, "Daily Hope")
        XCTAssertEqual(restored.meta.series?.order, 1)
        XCTAssertEqual(restored.meta.keyScriptures?.first?.sv, 43_001_001)
        XCTAssertEqual(restored.summary?.plainText, "God gives hope.")
        XCTAssertTrue(restored.markdownContent?.contains("## A body heading") == true)
        XCTAssertEqual(restored.footnotes?.first?.plainText, "A footnote.")
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

    // MARK: - Guarded first settings upload

    /// An older install: unsynced local changes and no saved baseline, so its
    /// first pass is a guarded upload. This device has finished one reading
    /// the server may lack; the server has finished one this device lacks.
    private struct GuardedFirstUpload {
        let state: SettingsArchiveState
        let storage: SettingsArchiveStorage
        let localReading: String
        let serverReading: String
        let restore: () -> Void
    }

    @MainActor
    private func guardedFirstUpload(
        storedToken: String?,
        serverRevision: String,
        archived: Bool = false,
        serverHasLocalReading: Bool = false
    ) async throws -> GuardedFirstUpload {
        let keys = [
            "UserSettingsSync.remoteChangeToken",
            "UserSettingsSync.readingsBase.v1",
            "UserDatabase.lastExportedAt"
        ]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let localReading = "guarded-local-\(UUID().uuidString)"
        let serverReading = "guarded-server-\(UUID().uuidString)"
        let restore = {
            try? UserDatabase.shared.removeCompletedReading(localReading)
            try? UserDatabase.shared.removeCompletedReading(serverReading)
            for (key, value) in zip(keys, previous) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        if let storedToken {
            UserDefaults.standard.set(storedToken, forKey: keys[0])
        }

        // Finishing a reading is the unsynced change.
        try UserDatabase.shared.addCompletedReading(localReading)
        XCTAssertTrue(UserDatabase.shared.hasUnsyncedChanges)

        // The server holds the same settings, with the other reading, as the
        // pre-archive legacy file or inside the archive.
        try UserDatabase.shared.checkpointForSync()
        let remoteURL = temporaryDirectory
            .appendingPathComponent("guarded-\(UUID().uuidString).db")
        try FileManager.default.copyItem(
            at: UserDatabase.shared.databaseURL, to: remoteURL
        )
        let queue = try DatabaseQueue(path: remoteURL.path)
        _ = try await queue.writeWithoutTransaction { db in
            if !serverHasLocalReading {
                _ = try CompletedReading.deleteOne(db, key: localReading)
            }
            try CompletedReading(id: serverReading).insert(db)
            try db.checkpoint(.truncate)
        }
        let remoteData = try Data(contentsOf: remoteURL)
        let state = SettingsArchiveState()
        if archived {
            let archive = try LampSyncSettingsArchive.replacingData(
                remoteData, in: nil, observedLegacy: nil
            )
            await state.seed(
                path: LampSyncLayout.archivePath,
                file: LampSyncRemoteFile(
                    data: try archive.compressedData(), revision: serverRevision
                )
            )
        } else {
            await state.seed(
                path: LampSyncLayout.userSettingsPath,
                file: LampSyncRemoteFile(data: remoteData, revision: serverRevision)
            )
        }
        return GuardedFirstUpload(
            state: state,
            storage: SettingsArchiveStorage(state: state),
            localReading: localReading,
            serverReading: serverReading,
            restore: restore
        )
    }

    /// The finished readings in a settings database as stored on the server.
    private func readingIDs(inSettingsDatabase data: Data) throws -> Set<String> {
        let url = temporaryDirectory
            .appendingPathComponent("remote-\(UUID().uuidString).db")
        try data.write(to: url)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return Set(try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM completed_readings")
        })
    }

    private func publishedReadingIDs(in state: SettingsArchiveState) async throws -> Set<String> {
        let file = await state.file(LampSyncLayout.archivePath)
        let archive = try LampSyncArchive.decode(compressedData: XCTUnwrap(file?.data))
        return try readingIDs(
            inSettingsDatabase: XCTUnwrap(LampSyncSettingsArchive.data(in: archive))
        )
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
    func testSettingsPlanWithoutBaseKeepsRowsFromBothSides() throws {
        var localSettings = UserSettings()
        localSettings.updatedAt = Date(timeIntervalSince1970: 200)
        localSettings.planWpm = 240
        var remoteSettings = UserSettings()
        remoteSettings.updatedAt = Date(timeIntervalSince1970: 100)
        let remoteReading = CompletedReading(id: "remote-reading")

        // Without a baseline a row only one side holds is either an addition
        // here or a deletion there. Refusing the merge settled neither, and
        // left the device unable to record the baseline that would tell them
        // apart, so both rows are kept and the deletion is the thing given up.
        let bootstrapped = try UserSettingsSyncManager.shared.planSettingsMerge(
            localSettings: localSettings,
            localReadings: [CompletedReading(id: "local-reading")],
            remoteSettings: remoteSettings,
            remoteReadings: [remoteReading],
            base: nil
        )
        XCTAssertEqual(
            Set(bootstrapped.readings.map(\.id)), ["local-reading", "remote-reading"]
        )
        XCTAssertTrue(bootstrapped.needsPublish)

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


    // MARK: - Taking modules in

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

        let module = try XCTUnwrap(database.getModule(id: moduleID))
        let body = try ModuleSyncManager.shared.exportHighlightModuleToSQLite(module)
        XCTAssertEqual(try LampPortableModuleInspector.inspect(
            compressedData: body, requireImportSchema: true
        ).id, moduleID)
        XCTAssertEqual(try LampWebDAVPersonalArchiveAdapter.highlightSetID(in: body), setID)

        try database.deleteAllEntriesForModule(moduleId: moduleID)
        try database.deleteModule(id: moduleID)
        let revision = LampSyncContentRevision.digest(for: body)
        try await ModuleSyncManager.shared.takeIn(.highlights, from: ModuleJSONStorage(
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
        try await ModuleSyncManager.shared.takeIn(.highlights, from: ModuleJSONStorage(
                moduleID: moduleID, moduleType: .highlights,
                hash: "legacy-revision", data: legacyBody,
                fileName: "\(moduleID).lamp"
            )
        )
        XCTAssertEqual(try database.getHighlightSet(id: setID)?.moduleId, moduleID)
        XCTAssertEqual(try database.getHighlightCount(setId: setID), 1)
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

        XCTAssertFalse(try database.removePendingModuleConflict(
            moduleId: moduleId,
            type: .notes,
            key: conflict.id
        ))
        XCTAssertFalse(try database.hasPendingModuleConflicts(moduleId: moduleId))
        XCTAssertTrue(try database.pendingModulePublications(type: .notes).contains(moduleId))
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
            try await ModuleSyncManager.shared.takeIn(.dictionary, from: storage)
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
            try await ModuleSyncManager.shared.takeIn(.dictionary, from: storage)
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
        try await ModuleSyncManager.shared.takeIn(.dictionary, from: ModuleJSONStorage(
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
            try await ModuleSyncManager.shared.takeIn(.dictionary, from: storage)
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
        try await ModuleSyncManager.shared.takeIn(.dictionary, from: storage)
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
            try await ModuleSyncManager.shared.takeIn(.commentary, from: storage)
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
            try await ModuleSyncManager.shared.takeIn(.dictionary, from: ModuleJSONStorage(
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
            try await ModuleSyncManager.shared.takeIn(.dictionary, from: ModuleJSONStorage(
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
            try await ModuleSyncManager.shared.takeIn(.notes, from: ModuleJSONStorage(
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

private actor SettingsArchiveState {
    private var files: [String: LampSyncRemoteFile] = [:]
    private var nextRevision = 0
    private var failLegacyWrite = false
    private var written: [String] = []

    func file(_ path: String) -> LampSyncRemoteFile? { files[path] }
    func writeCount() -> Int { nextRevision }
    /// The paths written, in order. Seeds and `replaceLegacy` stand for
    /// another client and are left out.
    func writtenPaths() -> [String] { written }

    func seed(path: String, file: LampSyncRemoteFile) { files[path] = file }

    func failNextLegacyWrite() { failLegacyWrite = true }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) throws -> String? {
        if path == LampSyncLayout.userSettingsPath && failLegacyWrite {
            failLegacyWrite = false
            throw LampWebDAVStorage.StorageError.preconditionFailed
        }
        let current = files[path]
        switch condition {
        case .ifAbsent where current != nil:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        case .ifRevision(let expected) where current?.revision != expected:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        nextRevision += 1
        written.append(path)
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

private actor ArchiveReadState {
    private var reads = 0

    func recordRead() { reads += 1 }
    func count() -> Int { reads }
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

private actor SelectedStorageState {
    private var reads: [String] = []
    private var types: [ModuleType] = []
    func recordRead(_ path: String) { reads.append(path) }
    func recordList(_ type: ModuleType) { types.append(type) }
    func settingsReads() -> [String] { reads }
    func listedTypes() -> [ModuleType] { types }
}

private actor CapturedModuleBody {
    private var stored: Data?
    private var mediaFiles: [String: Data] = [:]
    func save(_ data: Data) { stored = data }
    func body() -> Data? { stored }
    func saveMedia(_ data: Data, at path: String) { mediaFiles[path] = data }
    func media(at path: String) -> Data? { mediaFiles[path] }
}

private struct ModuleJSONStorage: ListedModuleStorage {
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

// MARK: - Toolbar collapse

/// A scroll view the reader is moving by hand. A real one only reports
/// dragging during a touch, and the tracker deliberately ignores everything
/// else as programmatic scrolling.
private final class HandScrolledView: UIScrollView {
    var isUnderHand = true
    override var isDragging: Bool { isUnderHand }
    override var isTracking: Bool { isUnderHand }
}

final class ToolbarCollapseTrackerTests: XCTestCase {
    private var scrollView: HandScrolledView!
    private var tracker: ToolbarCollapseTracker!

    override func setUp() {
        super.setUp()
        scrollView = HandScrolledView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        scrollView.contentSize = CGSize(width: 400, height: 5_000)
        tracker = ToolbarCollapseTracker()
        // Arrive part way down a chapter the way a jump does — programmatically
        // — so the tests start with the toolbars showing and no travel counted.
        scrollView.isUnderHand = false
        scroll(to: 500)
        scrollView.isUnderHand = true
    }

    @discardableResult
    private func scroll(to offset: CGFloat) -> Bool? {
        scrollView.contentOffset = CGPoint(x: 0, y: offset)
        return tracker.update(scrollView: scrollView)
    }

    func testScrollingDownCollapses() {
        XCTAssertNil(scroll(to: 600))
        XCTAssertEqual(scroll(to: 700), true)
    }

    func testScrollingBackUpNeverRevealsTheToolbars() {
        scroll(to: 700)
        XCTAssertNil(scroll(to: 650))
        XCTAssertNil(scroll(to: 300))
        XCTAssertNil(scroll(to: 50))
    }

    func testReachingTheTopDoesNotRevealTheToolbars() {
        scroll(to: 700)
        XCTAssertNil(scroll(to: 0))
    }

    func testOnlyARevealFromOutsideBringsThemBack() {
        scroll(to: 700)
        // A tap on the collapsed header reports back through sync.
        tracker.sync(false)
        XCTAssertNil(scroll(to: 600), "scrolling up after a reveal must not report anything")
        XCTAssertNil(scroll(to: 700))
        XCTAssertEqual(scroll(to: 800), true, "scrolling down collapses again")
    }

    func testANudgeBackWhileReadingKeepsTheDistanceScrolled() {
        XCTAssertNil(scroll(to: 600))  // 100 down
        XCTAssertNil(scroll(to: 580))  // 20 back up, net 80
        XCTAssertEqual(scroll(to: 650), true)  // 70 more, net 150
    }

    func testProgrammaticScrollingNeverCollapses() {
        scrollView.isUnderHand = false
        XCTAssertNil(scroll(to: 3_000))
    }

    func testContentThatFitsNeverCollapses() {
        scrollView.contentSize = CGSize(width: 400, height: 900)
        XCTAssertNil(scroll(to: 50))
        XCTAssertNil(scroll(to: 100))
    }
}

/// Linked scrolling reads the current verse from just under the reader's header,
/// and brings a verse there when the panel leads. Verse positions count from
/// the top of the reader's text, which sits below the previous-chapter button,
/// while the header covers the top of the scroll view; missing either made the
/// panel move on to a verse still well down the screen.
final class ReaderReadingLineTests: XCTestCase {
    private let coordinator = ScrollSyncCoordinator.shared
    private var scrollView: UIScrollView!
    private var textView: UIView!

    private let headerHeight: CGFloat = 116
    private let textTop: CGFloat = 71
    // Genesis 1:1–5, a line apart.
    private let positions: [Int: CGFloat] = [
        1001001: 0, 1001002: 40, 1001003: 80, 1001004: 120, 1001005: 160,
    ]

    override func setUp() {
        super.setUp()
        scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset.top = headerHeight
        scrollView.contentSize = CGSize(width: 400, height: 3_000)
        textView = UIView(frame: CGRect(x: 0, y: textTop, width: 400, height: 2_000))
        scrollView.addSubview(textView)
        coordinator.readerScrollView = scrollView
        coordinator.readerTextView = textView
        coordinator.updateReaderVersePositions(positions)
    }

    override func tearDown() {
        coordinator.readerScrollView = nil
        coordinator.readerTextView = nil
        coordinator.updateReaderVersePositions([:])
        super.tearDown()
    }

    /// How far below the top of the scroll view a verse is drawn.
    private func onScreenY(of verseId: Int) -> CGFloat {
        textTop + positions[verseId]! - scrollView.contentOffset.y
    }

    func testAVerseBroughtToTheTopSitsJustUnderTheHeader() {
        XCTAssertTrue(coordinator.scrollReaderToVerseId(1001003))
        XCTAssertEqual(onScreenY(of: 1001003), headerHeight, accuracy: 0.5)
    }

    func testTheVerseBroughtToTheTopIsTheVerseReadBack() {
        for verseId in positions.keys.sorted() {
            coordinator.scrollReaderToVerseId(verseId)
            XCTAssertEqual(coordinator.readerVerseAtReadingLine(in: scrollView), verseId)
        }
    }

    func testTheNextVerseIsReadOnlyOnceItReachesTheTop() {
        let inset = ScrollSyncCoordinator.readingLineInset
        coordinator.scrollReaderToVerseId(1001002)

        // Verse 3 coming up, but still short of the top.
        scrollView.contentOffset.y += 40 - inset - 4
        XCTAssertEqual(onScreenY(of: 1001003), headerHeight + inset + 4, accuracy: 0.5)
        XCTAssertEqual(coordinator.readerVerseAtReadingLine(in: scrollView), 1001002)

        // Now it has arrived.
        scrollView.contentOffset.y += 8
        XCTAssertEqual(coordinator.readerVerseAtReadingLine(in: scrollView), 1001003)
    }

    /// At the top of a chapter the reading line is among the titles above the
    /// first verse. Reading nothing there left a scroll that ended in them to
    /// commit its placeholder, and the reader showed chapter 0.
    func testTheTopOfAChapterReadsAsItsFirstVerse() {
        scrollView.contentOffset.y = -headerHeight
        XCTAssertGreaterThan(onScreenY(of: 1001001), headerHeight + ScrollSyncCoordinator.readingLineInset)
        XCTAssertEqual(coordinator.readerVerseAtReadingLine(in: scrollView), 1001001)
    }
}

// MARK: - Comparing editable entries

/// Notes and devotionals cross between this device and the Mac, which stores
/// the same values in a different spelling. Only a difference in what an entry
/// says may make two copies a conflict.
final class EditableEntryComparisonTests: XCTestCase {
    private func note(footnotesJson: String?, verseRefsJson: String?) -> NoteEntry {
        var entry = NoteEntry(
            id: "personal-notes:1001000", moduleId: "notes", verseId: 1001000,
            title: "General Notes", content: "General note test with asdfkey[^1]",
            lastModified: 1768701506
        )
        entry.footnotesJson = footnotesJson
        entry.verseRefsJson = verseRefsJson
        return entry
    }

    /// As the device's log found them: identical notes, identical timestamps,
    /// keys in a different order and an empty list written out on one side.
    func testTheMacsSpellingOfANoteIsTheSameNote() {
        let phone = note(footnotesJson: #"[{"id":"1","content":"Jer 4:30"}]"#, verseRefsJson: nil)
        let mac = note(footnotesJson: #"[{"content":"Jer 4:30","id":"1"}]"#, verseRefsJson: "[]")
        XCTAssertTrue(ModuleSyncManager.sameNoteContent(phone, mac))
    }

    func testADifferentFootnoteIsStillADifference() {
        let phone = note(footnotesJson: #"[{"id":"1","content":"Jer 4:30"}]"#, verseRefsJson: nil)
        let mac = note(footnotesJson: #"[{"content":"Jer 4:31","id":"1"}]"#, verseRefsJson: "[]")
        XCTAssertFalse(ModuleSyncManager.sameNoteContent(phone, mac))
    }

    /// A copy that only spells the same note differently changes nothing: no
    /// conflict, and nothing left to publish. Counted as a local change, each
    /// device would re-upload its own spelling on every pass, and the other
    /// would fetch it back.
    func testAMatchingCopyLeavesNothingToPublish() {
        let phone = note(footnotesJson: #"[{"id":"1","content":"Jer 4:30"}]"#, verseRefsJson: nil)
        let mac = note(footnotesJson: #"[{"content":"Jer 4:30","id":"1"}]"#, verseRefsJson: "[]")
        let merged = LampSyncMerge.records(
            local: [phone], incoming: [mac],
            key: { $0.verseId }, modified: { $0.lastModified },
            sameContent: ModuleSyncManager.sameNoteContent
        )
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(merged.localCount, 0, "a matching copy must not make the module pending")
        XCTAssertEqual(merged.incomingCount, 0)
    }

    private func writing(mediaJson: String?, footnotesJson: String?, body: String) throws -> DevotionalEntry {
        var row: [String: Any] = [
            "id": "beta-writing", "module_id": "devotionals", "title": "Beta Writing",
            "content_json": body, "created": 1756000000, "last_modified": 1756000000
        ]
        if let mediaJson { row["media_json"] = mediaJson }
        if let footnotesJson { row["footnotes_json"] = footnotesJson }
        return try JSONDecoder().decode(
            DevotionalEntry.self, from: JSONSerialization.data(withJSONObject: row)
        )
    }

    /// Writings merge separately from notes, so the same must hold for them:
    /// the Mac's spelling of an unchanged writing is no conflict and no change.
    func testTheMacsSpellingOfAWritingIsTheSameWriting() throws {
        let phone = try writing(mediaJson: nil, footnotesJson: nil, body: "In the beginning")
        let mac = try writing(mediaJson: "[]", footnotesJson: "[]", body: "In the beginning")
        let merged = LampSyncMerge.records(
            local: [phone], incoming: [mac],
            key: { $0.id }, modified: { $0.lastModified },
            sameContent: ModuleSyncManager.sameDevotionalContent
        )
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(merged.localCount, 0, "a matching copy must not make the module pending")
        XCTAssertEqual(merged.incomingCount, 0)
    }

    /// A plain-text body isn't JSON; a change in what it says is still a change.
    func testADifferentWritingBodyIsStillADifference() throws {
        let phone = try writing(mediaJson: nil, footnotesJson: nil, body: "In the beginning")
        let mac = try writing(mediaJson: "[]", footnotesJson: "[]", body: "In the end")
        XCTAssertFalse(ModuleSyncManager.sameDevotionalContent(phone, mac))
    }
}

final class TemporaryFileSweeperTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweeper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func make(_ name: String, folder: Bool = false, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("staging.sqlite"))
        } else {
            try Data(repeating: 1, count: 4096).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func remaining() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    func testRemovesWhatAKilledRunLeftAndKeepsEverythingElse() throws {
        let launch = Date()
        let earlier = launch.addingTimeInterval(-3600)
        let id = UUID().uuidString
        let leftovers = [
            "\(id).db", "\(id).db-wal", "\(id).db-shm", "\(id).db-journal",
            "lamp-archive-install-\(UUID().uuidString)",
            "lamp-settings-\(UUID().uuidString)",
            UUID().uuidString,
            "NSIRD_Lamp Bible_Mn4EJg",
        ]
        for name in leftovers {
            try make(name, folder: name.hasPrefix("lamp-") || name.hasPrefix("NSIRD") || UUID(uuidString: name) != nil, modified: earlier)
        }
        let kept = [
            "WebKit", "com.apple.WebKit.Networking",
            "\(UUID().uuidString).m4a",  // an audio file a sheet is still holding
            "notes.db", "lamp-archive-install-unfinished",
        ]
        for name in kept {
            try make(name, folder: !name.contains("."), modified: earlier)
        }
        // Made by a pass that started after launch: not this sweep's to take.
        let current = "\(UUID().uuidString).db"
        try make(current, modified: launch.addingTimeInterval(1))

        let result = TemporaryFileSweeper.removeLeftovers(in: directory, olderThan: launch)

        XCTAssertEqual(try remaining(), Set(kept + [current]))
        XCTAssertEqual(result.removed, leftovers.count)
        XCTAssertGreaterThanOrEqual(result.bytes, Int64(leftovers.count * 4096))
    }

    func testAnEmptyOrMissingDirectoryRemovesNothing() throws {
        XCTAssertEqual(TemporaryFileSweeper.removeLeftovers(in: directory, olderThan: Date()), .init())
        let missing = directory.appendingPathComponent("absent", isDirectory: true)
        XCTAssertEqual(TemporaryFileSweeper.removeLeftovers(in: missing, olderThan: Date()), .init())
    }
}

final class SearchIndexRepairTests: XCTestCase {
    private var url: URL!
    private var queue: DatabaseQueue!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString).sqlite")
        queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
    }

    override func tearDownWithError() throws {
        try queue.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// The tables and triggers as migrations v2 and v9 made them.
    private func makeLegacySchema(dictionary: Bool = true) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE translation_verses (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL);
                CREATE VIRTUAL TABLE translation_verses_fts USING fts5(
                    text, content='translation_verses', content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2');
                CREATE TRIGGER translation_verses_fts_insert AFTER INSERT ON translation_verses BEGIN
                    INSERT INTO translation_verses_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER translation_verses_fts_update AFTER UPDATE ON translation_verses BEGIN
                    UPDATE translation_verses_fts SET text = new.text WHERE rowid = new.id;
                END;
                CREATE TRIGGER translation_verses_fts_delete AFTER DELETE ON translation_verses BEGIN
                    DELETE FROM translation_verses_fts WHERE rowid = old.id;
                END;
                """)
            guard dictionary else { return }
            try db.execute(sql: """
                CREATE TABLE dictionary_entries (id TEXT PRIMARY KEY, lemma TEXT NOT NULL, senses_json TEXT);
                CREATE VIRTUAL TABLE dictionary_fts USING fts5(
                    lemma, senses_json, content='dictionary_entries', content_rowid='rowid');
                CREATE TRIGGER dictionary_fts_insert AFTER INSERT ON dictionary_entries BEGIN
                    INSERT INTO dictionary_fts(rowid, lemma, senses_json)
                    VALUES (new.rowid, new.lemma, new.senses_json);
                END;
                CREATE TRIGGER dictionary_fts_update AFTER UPDATE ON dictionary_entries BEGIN
                    UPDATE dictionary_fts SET lemma = new.lemma, senses_json = new.senses_json
                    WHERE rowid = new.rowid;
                END;
                CREATE TRIGGER dictionary_fts_delete AFTER DELETE ON dictionary_entries BEGIN
                    DELETE FROM dictionary_fts WHERE rowid = old.rowid;
                END;
                """)
        }
    }

    /// What sync did to a phone: reinstall the same translation over and over.
    private func reinstallTranslation(times: Int, verses: Int = 120) throws {
        for round in 0..<times {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM translation_verses")
                for verse in 0..<verses {
                    let word = round == times - 1 ? "light" : "darkness"
                    try db.execute(
                        sql: "INSERT INTO translation_verses (text) VALUES (?)",
                        arguments: ["verse \(verse) of round \(round) speaks of \(word)"]
                    )
                }
            }
        }
    }

    private func editDictionary() throws {
        try queue.write { db in
            for entry in 0..<40 {
                try db.execute(
                    sql: "INSERT INTO dictionary_entries (id, lemma, senses_json) VALUES (?, ?, ?)",
                    arguments: ["e\(entry)", "lemma\(entry)", "[\"first sense\"]"]
                )
            }
            try db.execute(sql: "UPDATE dictionary_entries SET senses_json = '[\"second sense\"]'")
            try db.execute(sql: "DELETE FROM dictionary_entries WHERE CAST(substr(id, 2) AS INTEGER) % 2 = 0")
        }
    }

    private func counts(_ index: String, _ content: String) throws -> (entries: Int, rows: Int) {
        try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM \(index)_docsize")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM \(content)")!)
        }
    }

    private func assertExact(_ index: String, _ content: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (entries, rows) = try counts(index, content)
        XCTAssertEqual(entries, rows, "\(index) should index each row once", file: file, line: line)
        // With rank 1 the check compares the index with the content table.
        XCTAssertNoThrow(try queue.write { db in
            try db.execute(sql: "INSERT INTO \(index)(\(index), rank) VALUES ('integrity-check', 1)")
        }, "\(index) should agree with its content", file: file, line: line)
    }

    private func hits(_ index: String, _ query: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(index) WHERE \(index) MATCH ?", arguments: [query])!
        }
    }

    func testTheOldTriggersLeaveEntriesBehindAndTheRepairClearsThem() throws {
        try makeLegacySchema()
        try reinstallTranslation(times: 25)
        try editDictionary()
        XCTAssertGreaterThan(try counts("translation_verses_fts", "translation_verses").entries, 25 * 100)
        XCTAssertGreaterThan(try hits("translation_verses_fts", "darkness"), 0, "deleted verses should still match")
        XCTAssertGreaterThan(try hits("dictionary_fts", "first"), 0, "replaced senses should still match")

        try queue.write { try ExternalContentSearchIndex.installTriggers(in: $0) }
        var options = SearchIndexRepair.Options()
        options.batchRows = 37
        options.vacuumThreshold = 1
        let report = try SearchIndexRepair.repair(queue, options: options)

        XCTAssertEqual(report.swapped, ["translation_verses_fts"])
        XCTAssertEqual(report.rebuilt, ["translation_verses_fts", "dictionary_fts"])
        XCTAssertTrue(report.vacuumed)
        XCTAssertLessThan(report.bytesAfter, report.bytesBefore)
        try assertExact("translation_verses_fts", "translation_verses")
        try assertExact("dictionary_fts", "dictionary_entries")
        XCTAssertEqual(try hits("translation_verses_fts", "darkness"), 0)
        XCTAssertEqual(try hits("translation_verses_fts", "light"), 120)
        XCTAssertEqual(try hits("dictionary_fts", "first"), 0)
        XCTAssertEqual(try hits("dictionary_fts", "second"), 20)
        let leftovers = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name LIKE '%_stale%' OR name LIKE '%_rebuild%'")
        }
        XCTAssertEqual(leftovers, [])

        // And the new triggers keep it that way.
        try reinstallTranslation(times: 3)
        try queue.write { db in
            try db.execute(sql: "UPDATE translation_verses SET text = 'morning' WHERE id % 3 = 0")
            try db.execute(sql: "UPDATE dictionary_entries SET lemma = 'renamed'")
            try db.execute(sql: "DELETE FROM dictionary_entries WHERE id = 'e1'")
        }
        try assertExact("translation_verses_fts", "translation_verses")
        try assertExact("dictionary_fts", "dictionary_entries")
        XCTAssertEqual(try hits("translation_verses_fts", "morning"), 40)
        XCTAssertEqual(try hits("dictionary_fts", "renamed"), 19)
    }

    func testARepairCutShortIsFinishedByTheNextRun() throws {
        try makeLegacySchema(dictionary: false)
        try reinstallTranslation(times: 20)
        try queue.write { db in
            try ExternalContentSearchIndex.installTriggers(in: db)
            // Killed after the swap, part way through emptying the old index...
            try db.execute(sql: """
                CREATE VIRTUAL TABLE translation_verses_fts_stale USING fts5(
                    text, content='translation_verses', content_rowid='id')
                """)
            try db.execute(sql: """
                INSERT INTO translation_verses_fts_stale(rowid, text)
                SELECT id, text FROM translation_verses
                """)
            // ...or before a copy went live.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE translation_verses_fts_rebuild USING fts5(
                    text, content='translation_verses', content_rowid='id')
                """)
        }

        _ = try SearchIndexRepair.repair(queue)

        try assertExact("translation_verses_fts", "translation_verses")
        let leftovers = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name LIKE '%_stale%' OR name LIKE '%_rebuild%'")
        }
        XCTAssertEqual(leftovers, [])
    }

    func testTheMigrationLeavesAbsentIndexesAlone() throws {
        try makeLegacySchema(dictionary: false)
        try queue.write { try ExternalContentSearchIndex.installTriggers(in: $0) }
        let triggers = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        }
        XCTAssertEqual(triggers.count, 3)
        XCTAssertEqual(triggers.filter { $0.contains("'delete'") }.count, 2)
        XCTAssertEqual(try queue.read { try ExternalContentSearchIndex.all[1].exists(in: $0) }, false)
    }
}

final class SyncFileRecordTests: XCTestCase {
    private let database = ModuleDatabase.shared
    private let source = "webdav:https://records-\(UUID().uuidString).test/LampBible|someone"
    private let notes = "Notes/notes.lamp"

    override func tearDownWithError() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM sync_file_records WHERE source = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM sync_pending_manifest_changes WHERE source = ?", arguments: [source])
        }
    }

    func testAnotherEndpointStartsFromNothing() throws {
        try database.recordSyncUpload(source: source, path: notes, digest: "d1", revision: "r1", replacing: nil)
        XCTAssertNil(try database.syncFileRecord(source: "folder:/elsewhere", path: notes))
    }

    func testChangesWaitForABundleAndANewerOneSurvivesTheClear() throws {
        try database.recordSyncUpload(
            source: source, path: notes, digest: "d1", revision: "r1", replacing: "r0",
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try database.recordSyncLocalDeletion(
            source: source, path: "Highlights/old.lamp", at: Date(timeIntervalSince1970: 1_800_000_001)
        )
        let carried = try database.pendingManifestChanges(source: source)
        XCTAssertEqual(carried.map(\.change), [.delete, .write])
        XCTAssertEqual(try database.pendingManifestDeletions(source: source), ["Highlights/old.lamp": 1_800_000_001_000])

        // Uploaded again while the pass that read `carried` was still running.
        try database.recordSyncUpload(
            source: source, path: notes, digest: "d2", revision: "r2", replacing: "r1",
            at: Date(timeIntervalSince1970: 1_800_000_002)
        )
        try database.clearPendingManifestChanges(carried)

        let left = try database.pendingManifestChanges(source: source)
        XCTAssertEqual(left.map(\.revision), ["r2"])
    }
}

// MARK: - Design B pass

/// A WebDAV server holding the library as files, with strong revisions and
/// conditional writes and deletes, as the Synology serves them.
private actor LibraryServer {
    private(set) var files: [String: LampSyncRemoteFile] = [:]
    private var next = 0
    private(set) var writes: [String] = []
    private(set) var deletes: [String] = []

    func file(_ path: String) -> LampSyncRemoteFile? { files[path] }

    /// Downloads, by path, as a device's reads.
    private(set) var fetches: [String] = []
    func fetch(_ path: String) -> LampSyncRemoteFile? {
        fetches.append(path)
        return visible(path)
    }

    /// Another device's write.
    @discardableResult
    func seed(_ path: String, _ data: Data) -> String {
        next += 1
        let revision = "\"lib-\(next)\""
        files[path] = LampSyncRemoteFile(data: data, revision: revision)
        return revision
    }

    /// As a Synology: a PUT answers with no ETag, so a writer confirms by
    /// reading back. With `lagging`, reads keep showing the body from before
    /// each write until `catchUp()`.
    private(set) var withholdsRevisions = false
    private(set) var lagging = false
    private var before: [String: LampSyncRemoteFile?] = [:]
    /// Apache, which the Synology runs, tags a file weak for the second after
    /// it changes: modelled as the next reads of each written path.
    private var weakReadsAfterWrite = 0
    private var weakReadsLeft: [String: Int] = [:]
    func behaveLikeASynology(lagging: Bool, weakReadsAfterWrite: Int = 0) {
        withholdsRevisions = true
        self.lagging = lagging
        self.weakReadsAfterWrite = weakReadsAfterWrite
    }
    func catchUp() { before = [:]; lagging = false }
    /// What a read sees now.
    func visible(_ path: String) -> LampSyncRemoteFile? {
        let file: LampSyncRemoteFile?
        if let stale = before[path] { file = stale } else { file = files[path] }
        return file.map { weakened($0, at: path) }
    }
    private func weakened(_ file: LampSyncRemoteFile, at path: String) -> LampSyncRemoteFile {
        guard let left = weakReadsLeft[path], left > 0, let revision = file.revision else { return file }
        weakReadsLeft[path] = left - 1
        return LampSyncRemoteFile(data: file.data, revision: "W/" + revision)
    }

    /// Every write sent, taken or refused.
    private(set) var attempts: [String] = []

    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) throws -> String? {
        attempts.append(path)
        let current = files[path]
        switch condition {
        case .ifAbsent where current != nil:
            throw LampWebDAVStorage.StorageError.preconditionFailed
        case .ifRevision(let expected)
            where !LampWebDAVStorage.isStrongETag(expected)
                || !LampSyncConditionalWrite.namesSameRevision(current?.revision, expected):
            throw LampWebDAVStorage.StorageError.preconditionFailed
        default:
            break
        }
        writes.append(path)
        if weakReadsAfterWrite > 0 { weakReadsLeft[path] = weakReadsAfterWrite }
        if lagging, before[path] == nil { before[path] = .some(current) }
        let revision = seed(path, data)
        return withholdsRevisions ? nil : revision
    }

    func delete(_ path: String, condition: LampSyncWriteCondition) throws {
        guard let current = files[path] else { return }
        if case .ifRevision(let expected) = condition,
           !LampSyncConditionalWrite.namesSameRevision(current.revision, expected) {
            throw LampWebDAVStorage.StorageError.preconditionFailed
        }
        files[path] = nil
        deletes.append(path)
    }

    /// Another device's bundle, written the moment the pass first lists a
    /// module folder: after the pass read the bundle, before it writes.
    private var interloper: Data?
    func writeBundleDuringThePass(_ data: Data) { interloper = data }

    func list(_ directory: String) -> [LampSyncRemoteEntry] {
        if let interloper, !directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            self.interloper = nil
            seed(LampSyncSettingsStore.path, interloper)
        }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return files.keys.sorted().compactMap { path in
            guard path.hasPrefix(prefix), let file = visible(path) else { return nil }
            let name = String(path.dropFirst(prefix.count))
            guard !name.contains("/") else { return nil }
            return LampSyncRemoteEntry(
                path: path, name: name, isDirectory: false,
                revision: file.revision, modifiedAt: nil, size: Int64(file.data.count)
            )
        }
    }
}

private struct LibraryServerStorage: ModuleStorage, LampSyncRemoteStore {
    let server: LibraryServer

    func isAvailable() async -> Bool { true }
    func list(directory: String) async throws -> [LampSyncRemoteEntry]? { await server.list(directory) }
    func read(path: String) async throws -> LampSyncRemoteFile? { await server.fetch(path) }
    func revision(path: String) async throws -> String? { await server.visible(path)?.revision }
    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        try await server.write(data, to: path, condition: condition)
    }
    func delete(path: String, condition: LampSyncWriteCondition) async throws {
        try await server.delete(path, condition: condition)
    }
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        let path = "\(directoryName(for: type))/\(fileName)"
        guard let file = await server.fetch(path) else { throw ModuleStorageError.fileNotFound(path) }
        return file
    }
    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        try await readModuleSnapshot(type: type, fileName: fileName).data
    }
    func readFile(path: String) async throws -> Data {
        guard let file = await server.fetch(path) else { throw ModuleStorageError.fileNotFound(path) }
        return file.data
    }
    func listFiles(path: String) async throws -> [StoredFileListing] {
        await server.list(path).map { StoredFileListing(name: $0.name, modificationDate: nil) }
    }
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] { [] }
    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        fatalError("Design B writes go through the conditional store")
    }
    func writeFile(path: String, data: Data) async throws {
        fatalError("Design B writes go through the conditional store")
    }
    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        fatalError("Design B deletes are conditional reaps")
    }
    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await server.file("\(directoryName(for: type))/\(fileName)")?.revision
    }
    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
}

@MainActor
final class LibrarySyncPassTests: XCTestCase {
    private let database = ModuleDatabase.shared
    private var server: LibraryServer!
    private var storage: LibraryServerStorage!
    private var moduleId: String!
    private var source: String!

    private var notesPath: String { "Notes/\(moduleId!).lamp" }

    override func setUp() async throws {
        server = LibraryServer()
        storage = LibraryServerStorage(server: server)
        moduleId = "library-pass-\(UUID().uuidString)"
        source = "webdav:https://library-\(UUID().uuidString).test/LampBible|someone"
    }

    override func tearDown() async throws {
        try? database.deleteAllEntriesForModule(moduleId: moduleId)
        try? database.deleteModule(id: moduleId)
        try? database.clearPendingModulePublication(moduleId: moduleId)
        try? database.write { db in
            try db.execute(sql: "DELETE FROM sync_file_records WHERE source = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM sync_pending_manifest_changes WHERE source = ?", arguments: [source])
            try db.execute(sql: "DELETE FROM personal_sync_ledger")
        }
    }

    private func pass() -> LibrarySyncPass {
        var pass = LibrarySyncPass(storage: storage, source: source)
        pass.patience = .immediate
        return pass
    }

    private func saveNotesModule(notes: [String]) throws {
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "My Notes",
            filePath: "\(moduleId!).lamp", isEditable: true
        ))
        for (offset, id) in notes.enumerated() {
            try database.saveNoteEntry(NoteEntry(
                id: id, moduleId: moduleId, verseId: 43_001_001 + offset,
                title: nil, content: "Note \(id)", verseRefs: nil,
                lastModified: 1_788_132_249, footnotes: nil
            ))
        }
    }

    private func storedNoteIDs() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note_entries WHERE module_id = ? ORDER BY id", arguments: [moduleId])
        }
    }

    private func bundle() async throws -> LampSyncSettingsBundle {
        let stored = await server.file(LampSyncSettingsStore.path)
        let file = try XCTUnwrap(stored)
        return try LampSyncSettingsBundle.decode(file.data)
    }

    /// A Mac's archive, as an unmoved library holds it.
    private func macArchive() throws -> Data {
        try LampSyncArchive(entries: [])
            .replacingEntry(at: "Modules/Translations/KJV.lamp", with: Data("module".utf8))
            .compressedData()
    }

    /// The revision the phone last imported, while that archive is still
    /// there: nothing has moved. Who kept it is judged once for that
    /// revision, and later passes neither read it nor judge it again.
    func testTheArchiveLastImportedIsNotReadAgain() async throws {
        let revision = await server.seed(LampSyncSettingsStore.path, try macArchive())

        let outcome = try await pass().run(knownArchiveRevision: revision)
        let judged = await server.fetches.filter { $0 == LampSyncSettingsStore.path }.count
        let again = try await pass().run(knownArchiveRevision: revision)

        XCTAssertEqual(outcome, .notMigrated(archiveRevision: revision))
        XCTAssertEqual(again, .notMigrated(archiveRevision: revision))
        let later = await server.fetches.filter { $0 == LampSyncSettingsStore.path }.count
        XCTAssertEqual(later, judged, "read again once judged")
    }

    /// Once the Mac has moved the library the bundle stands where the archive
    /// was, and the archive revision this phone remembers names nothing there.
    func testABundleWhereTheImportedArchiveWasIsSynced() async throws {
        let archived = await server.seed(
            LampSyncSettingsStore.path, try LampSyncArchive(entries: []).compressedData()
        )
        await server.seed(LampSyncSettingsStore.path, try LampSyncSettingsBundle().encoded())

        let outcome = try await pass().run(knownArchiveRevision: archived)

        guard case .synced = outcome else { return XCTFail("expected a synced pass, got \(outcome)") }
    }

    func testAnArchiveAtThePathMeansTheMacHasNotMigrated() async throws {
        let revision = await server.seed(LampSyncSettingsStore.path, try macArchive())
        let outcome = try await pass().run()
        XCTAssertEqual(outcome, .notMigrated(archiveRevision: revision))
        let writes = await server.writes
        XCTAssertEqual(writes, [], "the phone never migrates")
    }

    func testAFreshServerGetsABundleAndThisDevicesNotesAndThenAQuietPass() async throws {
        try saveNotesModule(notes: ["a", "b"])

        guard case .synced = try await pass().run() else { return XCTFail("expected a synced pass") }

        let written = try await bundle()
        XCTAssertEqual(written.manifest.entry(at: notesPath)?.isMember, true)
        let uploaded = await server.file(notesPath)
        XCTAssertNotNil(uploaded)
        XCTAssertEqual(written.manifest.entry(at: notesPath)?.revision, uploaded?.revision)

        let before = await server.writes.count
        _ = try await pass().run()
        let after = await server.writes.count
        XCTAssertEqual(after, before, "nothing changed, so nothing is written")
    }

    func testANoteAddedElsewhereArrivesAndDoesNotEchoBack() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await pass().run()

        // Another device adds note "b" and publishes: export it from here, then
        // take it back out without a deletion, as if this device never had it.
        try database.saveNoteEntry(NoteEntry(
            id: "b", moduleId: moduleId, verseId: 43_001_002, title: nil, content: "Note b",
            verseRefs: nil, lastModified: 1_788_132_300, footnotes: nil
        ))
        let module = try XCTUnwrap(database.getModule(id: moduleId))
        let theirs = try ModuleSyncManager.shared.exportNoteModuleToSQLite(module)
        try database.write { db in
            try db.execute(sql: "DELETE FROM note_entries WHERE id = 'b' AND module_id = ?", arguments: [moduleId])
            try db.execute(sql: "DELETE FROM personal_sync_ledger WHERE item_key = 'b'")
        }
        let previous = await server.file(notesPath)?.revision
        let revision = await server.seed(notesPath, theirs)
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest.recordingWrite(
                notesPath, revision: revision, replacing: previous, at: ModuleDatabase.nowMilliseconds()
            )
        }
        let before = await server.writes.filter { $0 == notesPath }.count

        _ = try await pass().run()

        XCTAssertEqual(try storedNoteIDs(), ["a", "b"])
        let after = await server.writes.filter { $0 == notesPath }.count
        XCTAssertEqual(after, before, "a download is not uploaded back")
        let record = try XCTUnwrap(database.syncFileRecord(source: source, path: notesPath))
        XCTAssertEqual(record.lastRevision, revision)
    }

    func testAModuleDeletedElsewhereIsRemovedHere() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await pass().run()
        let revision = await server.file(notesPath)?.revision
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest.removing(
                notesPath, at: ModuleDatabase.nowMilliseconds() + 1_000, revision: revision
            )
        }

        let outcome = try await pass().run()

        XCTAssertNil(try database.getModule(id: moduleId))
        let reaped = await server.file(notesPath)
        XCTAssertNil(reaped, "the tombstoned copy is reaped")
        guard case .synced(_, let report) = outcome else { return XCTFail("expected a synced pass") }
        XCTAssertEqual(report.deletedHere, [notesPath])
        XCTAssertEqual(report.line, "deleted here 1: \(notesPath)", "a deletion here is said")
    }

    /// This device's default notes and writings land on the two paths core
    /// keeps whole; a second notes module, or a highlight set with a
    /// colliding ID, deletes like any other module.
    func testThisDevicesDefaultModulesAreTheCollectionsCoreKeeps() {
        func path(_ type: ModuleType, _ id: String) -> String { "\(storage.directoryName(for: type))/\(id).lamp" }
        XCTAssertEqual(LampSyncLocalDeletion.target(of: path(.notes, LampSyncLocalDeletion.notesCollectionID)), .collection)
        XCTAssertEqual(LampSyncLocalDeletion.target(of: path(.devotional, LampSyncLocalDeletion.writingCollectionID)), .collection)
        XCTAssertEqual(LampSyncLocalDeletion.target(of: path(.notes, "grandads-notes")), .module("grandads-notes"))
        XCTAssertEqual(LampSyncLocalDeletion.target(of: path(.highlights, "notes")), .module("notes"))
    }

    /// Another device's deletion of the default notes file never takes every
    /// note here: the file is kept, the pass reads clean, and the next edit
    /// supersedes the deletion.
    func testTheDefaultNotesOutliveADeletionElsewhere() async throws {
        let existed = try database.getModule(id: "notes") != nil
        if !existed {
            try database.saveModule(Module(
                id: "notes", type: .notes, name: "Notes", filePath: "notes.lamp", isEditable: true
            ))
        }
        let noteID = "kept-\(UUID().uuidString)"
        try database.saveNoteEntry(NoteEntry(
            id: noteID, moduleId: "notes", verseId: 43_001_001, title: nil, content: "Kept",
            verseRefs: nil, lastModified: Int(Date().timeIntervalSince1970) - 3_600, footnotes: nil
        ))
        defer {
            try? database.write { db in
                _ = try NoteEntry.deleteOne(db, key: noteID)
                if !existed { try db.execute(sql: "DELETE FROM modules WHERE id = 'notes'") }
            }
        }
        _ = try await pass().run()
        let path = "Notes/notes.lamp"
        let revision = await server.file(path)?.revision
        XCTAssertNotNil(revision)
        // Deleted elsewhere after this device's last save and upload, and
        // before its next pass.
        try await Task.sleep(nanoseconds: 20_000_000)
        let deletedAt = ModuleDatabase.nowMilliseconds()
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest.removing(path, at: deletedAt, revision: revision)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        _ = try await pass().run()

        XCTAssertNotNil(try database.getNoteEntry(id: noteID), "a deletion elsewhere took every note")
        let kept = await server.file(path)
        XCTAssertNotNil(kept, "the notes stay on the server")
        _ = try await pass().run()

        // The next edit here goes up and supersedes the deletion.
        try database.saveNoteEntry(NoteEntry(
            id: noteID, moduleId: "notes", verseId: 43_001_001, title: nil, content: "Kept, edited",
            verseRefs: nil, lastModified: Int(Date().timeIntervalSince1970), footnotes: nil
        ))
        _ = try await pass().run()
        let entry = try await bundle().manifest.entry(at: path)
        XCTAssertEqual(entry?.isMember, true)
    }

    /// Resetting a notes module sends each note's own deletion, so a device
    /// still holding them lets them go rather than merging them back.
    func testResettingAModuleRecordsEachEntrysDeletion() throws {
        try saveNotesModule(notes: ["a", "b"])

        try database.resetPersonalModule(moduleId: moduleId)

        XCTAssertEqual(try storedNoteIDs(), [])
        XCTAssertNotNil(try database.getModule(id: moduleId), "the module itself stays")
        let ledger = try database.personalDeletionLedger()
        XCTAssertNotNil(ledger.entry(.note, "a")?.deletedAt)
        XCTAssertNotNil(ledger.entry(.note, "b")?.deletedAt)
    }

    // MARK: Settings

    private let settingsKeys = [
        "UserSettingsSync.remoteChangeToken",
        "UserSettingsSync.readingsBase.v1",
        "UserDatabase.lastExportedAt",
        "SharedPreferenceArchiveSync.bases.v1",
    ]
    private var savedSettingsKeys: [Any?] = []
    private var addedReadings: [String] = []

    private func keepSettingsState() {
        savedSettingsKeys = settingsKeys.map { UserDefaults.standard.object(forKey: $0) }
    }

    private func restoreSettingsState() {
        for reading in addedReadings { try? UserDatabase.shared.removeCompletedReading(reading) }
        for (key, value) in zip(settingsKeys, savedSettingsKeys) { UserDefaults.standard.set(value, forKey: key) }
    }

    private func settingsPass() -> LibrarySyncPass {
        var pass = LibrarySyncPass(storage: storage, source: source)
        let storage = self.storage!
        pass.makeParticipants = { bundle, versions in
            try UserSettingsSyncManager.shared.bundleParticipants(
                for: bundle, versions: versions.map(\.bundle), storage: storage
            )
        }
        return pass
    }

    private func readings(in settingsDatabase: Data) throws -> Set<String> {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        try settingsDatabase.write(to: url)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return Set(try queue.read { try String.fetchAll($0, sql: "SELECT id FROM completed_readings") })
    }

    /// Another device's settings: these, with one more reading finished.
    private func adding(reading: String, to settingsDatabase: Data) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        try settingsDatabase.write(to: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try CompletedReading(id: reading).insert(db)
            try db.checkpoint(.truncate)
        }
        try queue.close()
        return try Data(contentsOf: url)
    }

    func testSettingsAndReadingsTravelInTheBundle() async throws {
        keepSettingsState()
        defer { restoreSettingsState() }
        let reading = "bundle-here-\(UUID().uuidString)"
        addedReadings.append(reading)
        try UserDatabase.shared.addCompletedReading(reading)

        _ = try await settingsPass().run()

        let written = try await bundle()
        XCTAssertTrue(try readings(in: XCTUnwrap(written.userSettings)).contains(reading))
        XCTAssertFalse(UserDatabase.shared.hasUnsyncedChanges)
    }

    func testAReadingFinishedElsewhereArrivesFromTheBundle() async throws {
        keepSettingsState()
        defer { restoreSettingsState() }
        _ = try await settingsPass().run()
        let theirs = "bundle-there-\(UUID().uuidString)"
        addedReadings.append(theirs)
        let current = try await bundle()
        let changed = try adding(reading: theirs, to: XCTUnwrap(current.userSettings))
        _ = try await LampSyncSettingsStore.update(in: storage) { $0.userSettings = changed }

        _ = try await settingsPass().run()

        XCTAssertTrue(UserDatabase.shared.isReadingCompleted(theirs))
    }

    /// iCloud kept another device's settings beside the current copy: both
    /// devices' finished readings survive, whatever base this one recorded.
    func testSettingsVersionsIcloudKeptAreMergedWithoutTheBase() async throws {
        keepSettingsState()
        defer { restoreSettingsState() }
        _ = try await settingsPass().run()
        let first = try await bundle()
        let base = try XCTUnwrap(first.userSettings)
        let lost = "bundle-lost-\(UUID().uuidString)"
        let current = "bundle-current-\(UUID().uuidString)"
        addedReadings += [lost, current]
        let lostCopy = try adding(reading: lost, to: base)
        let currentCopy = try adding(reading: current, to: base)

        let participants = try UserSettingsSyncManager.shared.bundleParticipants(
            for: LampSyncSettingsBundle(userSettings: currentCopy),
            versions: [LampSyncSettingsBundle(userSettings: lostCopy)],
            storage: storage
        )
        var written = LampSyncSettingsBundle(userSettings: currentCopy)
        for participant in participants { try participant.change(&written, now: 0) }

        XCTAssertTrue(UserDatabase.shared.isReadingCompleted(lost))
        XCTAssertTrue(UserDatabase.shared.isReadingCompleted(current))
        let published = try readings(in: XCTUnwrap(written.userSettings))
        XCTAssertTrue(published.isSuperset(of: [lost, current]))
    }

    /// On iCloud Drive, end to end: another device's settings write was kept
    /// beside the bundle as a conflict version. The pass merges its readings
    /// in, publishes them, and resolves exactly that version.
    func testAnIcloudConflictVersionIsMergedAndResolved() async throws {
        keepSettingsState()
        defer { restoreSettingsState() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Staged: @unchecked Sendable {
            let lock = NSLock()
            var versions: [URL] = []
            var resolved: [URL] = []
        }
        let staged = Staged()
        let store = LampSyncDirectoryStore(
            root: root,
            conflictVersions: .init(
                unresolved: { file in
                    staged.lock.withLock {
                        file.lastPathComponent == LampSyncSettingsStore.path ? staged.versions : []
                    }
                },
                resolve: { _, urls in
                    staged.lock.withLock {
                        staged.resolved += urls
                        staged.versions.removeAll { urls.map(\.standardizedFileURL).contains($0.standardizedFileURL) }
                    }
                }
            )
        )
        let iCloud = ICloudLibraryStorage(store: store)
        var pass = LibrarySyncPass(storage: iCloud, source: "icloud:test-\(UUID().uuidString)")
        pass.makeParticipants = { bundle, versions in
            try UserSettingsSyncManager.shared.bundleParticipants(
                for: bundle, versions: versions.map(\.bundle), storage: iCloud
            )
        }
        _ = try await pass.run()
        let bundleURL = root.appendingPathComponent(LampSyncSettingsStore.path)
        let current = try LampSyncSettingsBundle.decode(Data(contentsOf: bundleURL))

        // Another device's write, lost to this one's and kept as a version.
        let theirs = "version-\(UUID().uuidString)"
        addedReadings.append(theirs)
        var lost = current
        lost.userSettings = try adding(reading: theirs, to: XCTUnwrap(current.userSettings))
        let versionURL = root.appendingPathComponent("conflict-\(UUID().uuidString).lampsync")
        try lost.encoded().write(to: versionURL)
        staged.lock.withLock { staged.versions = [versionURL] }

        _ = try await pass.run()

        XCTAssertTrue(UserDatabase.shared.isReadingCompleted(theirs))
        let published = try LampSyncSettingsBundle.decode(Data(contentsOf: bundleURL))
        XCTAssertTrue(try readings(in: XCTUnwrap(published.userSettings)).contains(theirs))
        XCTAssertEqual(staged.lock.withLock { staged.resolved.map(\.lastPathComponent) }, [versionURL.lastPathComponent])
    }

    /// Prepared against one bundle, met with a newer one at the write: the
    /// pass prepares again against what is there, rather than writing over it.
    func testABundleThatMovesMidPassIsPreparedAgain() async throws {
        await server.writeBundleDuringThePass(
            try LampSyncSettingsBundle(macSettings: Data("the Mac wrote".utf8)).encoded()
        )
        final class Count { var value = 0 }
        let prepared = Count()
        var pass = LibrarySyncPass(storage: storage, source: source)
        pass.makeParticipants = { bundle, _ in
            prepared.value += 1
            return [ExpectingParticipant(expected: bundle?.macSettings)]
        }

        _ = try await pass.run()

        XCTAssertEqual(prepared.value, 2)
        let written = try await bundle()
        XCTAssertEqual(written.macSettings, Data("the Mac wrote".utf8))
        XCTAssertEqual(written.userSettings, Data("the phone wrote".utf8))
    }

    /// After the switch nothing is recorded per file, so every installed
    /// module is fetched once; one whose bytes the archive already installed
    /// is recorded, not reinstalled.
    func testAModuleTheArchiveInstalledIsRecordedNotReinstalled() async throws {
        let key = ModuleSyncManager.portableArchiveImportStateKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        // Not a module at all: importing it would fail, so the pass can only
        // succeed by recognising the bytes.
        let bytes = Data("the archive's copy".utf8)
        try database.saveModule(Module(
            id: moduleId, type: .dictionary, name: "Lexicon",
            filePath: "\(moduleId!).lamp", isEditable: false
        ))
        UserDefaults.standard.set(try JSONEncoder().encode(ModuleSyncManager.PortableArchiveImportState(
            source: "archive", revision: nil,
            modules: [.init(path: "Dictionaries/\(moduleId!).lamp", id: moduleId, type: .dictionary,
                            digest: LibrarySyncPass.digest(bytes))]
        )), forKey: key)
        let path = "Dictionaries/\(moduleId!).lamp"
        let revision = await server.seed(path, bytes)

        _ = try await pass().run()

        XCTAssertEqual(try database.syncFileRecord(source: source, path: path)?.lastRevision, revision)
    }

    /// A WebDAV library only this phone kept: the archive it made holds its
    /// settings and nothing of a Mac's. Judged from a copy the phone decoded,
    /// it is offered, and moving it carries the settings into the bundle.
    func testAnArchiveOnlyThisPhoneMadeIsOfferedAndMovedWithItsSettings() async throws {
        let settings = Data("the phone's settings".utf8)
        let archive = try LampSyncSettingsArchive.replacingData(settings, in: nil, observedLegacy: nil)
        let revision = await server.seed(LampSyncSettingsStore.path, try archive.compressedData())

        let outcome = try await pass().run()
        XCTAssertEqual(outcome, .phoneLibrary)

        _ = try await LampSyncSettingsStore.migratePhoneLibrary(in: storage)
        let moved = try await bundle()
        XCTAssertEqual(moved.userSettings, settings)
    }

    /// The same archive with anything of a Mac's in it waits for the Mac.
    func testAnArchiveTheMacKeptIsNeverOffered() async throws {
        var archive = try LampSyncSettingsArchive.replacingData(Data("settings".utf8), in: nil, observedLegacy: nil)
        archive = try archive.replacingEntry(at: "Modules/Translations/KJV.lamp", with: Data("module".utf8))
        let revision = await server.seed(LampSyncSettingsStore.path, try archive.compressedData())

        let outcome = try await pass().run()
        XCTAssertEqual(outcome, .notMigrated(archiveRevision: revision))
    }

    /// A writing with an attachment.
    private func saveWritingModule(attachment: String) throws -> DevotionalMediaReference {
        try database.saveModule(Module(
            id: moduleId, type: .devotional, name: "My Writings",
            filePath: "\(moduleId!).lamp", isEditable: true
        ))
        let reference = DevotionalMediaReference(id: "A1", type: .image, filename: attachment, mimeType: "image/png")
        try database.saveDevotionalEntry(DevotionalEntry(
            from: Devotional(meta: DevotionalMeta(id: "w1", title: "Sunrise", lastModified: 1_788_132_249), media: [reference]),
            moduleId: moduleId
        ))
        return reference
    }

    /// An attachment on neither this device nor the server is reported, and
    /// the writing goes up regardless: all writings share one file.
    func testAWritingWhoseAttachmentNothingHoldsGoesUpAndIsReported() async throws {
        _ = try saveWritingModule(attachment: "gone.png")
        SyncCoordinator.shared.unsuppliedAttachments = []
        defer { SyncCoordinator.shared.unsuppliedAttachments = [] }

        _ = try await pass().run()

        let published = await server.file("Devotionals/\(moduleId!).lamp")
        XCTAssertNotNil(published)
        XCTAssertEqual(
            SyncCoordinator.shared.unsuppliedAttachments.map { ($0 as NSString).lastPathComponent },
            ["gone.png"]
        )
    }

    /// Missing here but a member of the library: it is on the server, so
    /// there is nothing to report.
    func testAnAttachmentAlreadyInTheLibraryIsNotReported() async throws {
        let reference = try saveWritingModule(attachment: "there.png")
        let mediaPath = try LampPortableDevotionalMedia.iOSRemotePath(
            moduleID: moduleId, devotionalID: "w1", filename: reference.filename
        )
        let revision = await server.seed(mediaPath, Data("image".utf8))
        _ = try await LampSyncSettingsStore.readOrClaim(from: storage)
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest.recordingWrite(
                mediaPath, revision: revision, replacing: nil, at: ModuleDatabase.nowMilliseconds()
            )
        }

        SyncCoordinator.shared.unsuppliedAttachments = ["stale"]
        defer { SyncCoordinator.shared.unsuppliedAttachments = [] }

        _ = try await pass().run()

        let published = await server.file("Devotionals/\(moduleId!).lamp")
        XCTAssertNotNil(published)
        XCTAssertEqual(SyncCoordinator.shared.unsuppliedAttachments, [])
    }

    /// The earlier sync left a copy of the notes under their old name. Its
    /// notes were merged into `notes` long ago, and taken in again they would
    /// make a second notes module and bring back notes deleted before the
    /// ledger existed: it stays out of the library.
    func testTheNotesOldNameStaysOutOfTheLibrary() async throws {
        let entry = "legacy-\(UUID().uuidString)"
        defer {
            try? database.write { db in
                try db.execute(sql: "DELETE FROM note_entries WHERE id = ?", arguments: [entry])
            }
            try? database.deleteAllEntriesForModule(moduleId: "bible-notes")
            try? database.deleteModule(id: "bible-notes")
        }
        let legacy = Module(id: "bible-notes", type: .notes, name: "Bible Notes", filePath: "bible-notes.lamp", isEditable: true)
        try database.saveModule(legacy)
        try database.saveNoteEntry(NoteEntry(
            id: entry, moduleId: "bible-notes", verseId: 43_001_001, title: nil, content: "Old",
            verseRefs: nil, lastModified: 1_788_132_249, footnotes: nil
        ))
        let data = try ModuleSyncManager.shared.exportNoteModuleToSQLite(legacy)
        try database.deleteAllEntriesForModule(moduleId: "bible-notes")
        try database.deleteModule(id: "bible-notes")
        _ = try await LampSyncSettingsStore.readOrClaim(from: storage)
        await server.seed("Notes/bible-notes.lamp", data)

        _ = try await pass().run()

        let fetches = await server.fetches
        XCTAssertFalse(fetches.contains("Notes/bible-notes.lamp"))
        let manifest = try await bundle().manifest
        XCTAssertNil(manifest.entry(at: "Notes/bible-notes.lamp"))
        XCTAssertNil(try database.getModule(id: "bible-notes"))
        let file = await server.file("Notes/bible-notes.lamp")
        XCTAssertNotNil(file, "nothing old is deleted")
    }

    /// A deck is the Mac's to sync, but its deletion is the library's: a
    /// tombstone past its lifetime still waits while the deck's file is on
    /// the server, or the Mac's next pass would adopt the file back.
    func testAnOldDeckDeletionWaitsForItsFileToGo() async throws {
        let deck = "\(LampSyncFolderLayout.decksDirectory)/old.\(LampSyncFolderLayout.deckExtension)"
        let revision = await server.seed(deck, Data("deck".utf8))
        _ = try await LampSyncSettingsStore.readOrClaim(from: storage)
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest
                .recordingWrite(deck, revision: revision, replacing: nil, at: 1_000)
                .removing(deck, at: 2_000, revision: revision)
        }
        // Something of the phone's own, so the pass writes the bundle.
        try saveNotesModule(notes: ["a"])

        _ = try await pass().run()

        let entry = try await bundle().manifest.entry(at: deck)
        XCTAssertNotNil(entry?.deletedAt, "the deletion went while its file is still on the server")
    }

    /// A Synology sends no ETag with a PUT: each upload is confirmed by
    /// reading it back, recorded, and the next pass has nothing to send.
    func testUploadsToAServerThatSendsNoETagAreConfirmedByReadingBack() async throws {
        await server.behaveLikeASynology(lagging: false)
        try saveNotesModule(notes: ["a"])

        _ = try await pass().run()
        let writes = await server.writes.count
        _ = try await pass().run()

        let after = await server.writes.count
        XCTAssertEqual(after, writes, "the second pass sent something again")
        let manifest = try await bundle().manifest
        XCTAssertEqual(manifest.entry(at: notesPath)?.isMember, true)
    }

    /// An attachment sent to a server that names no revision for it is asked
    /// for one, so the next pass knows it is there and sends nothing.
    func testAnAttachmentSentWithoutARevisionIsNotSentAgain() async throws {
        await server.behaveLikeASynology(lagging: false)
        let reference = try saveWritingModule(attachment: "sunrise.png")
        try DevotionalMediaStorage.shared.ensureMediaDirectory(devotionalId: "w1", moduleId: moduleId)
        let local = DevotionalMediaStorage.shared.expectedMediaURL(
            for: reference, devotionalId: "w1", moduleId: moduleId
        )
        try Data("image".utf8).write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local.deletingLastPathComponent().deletingLastPathComponent())
        }
        let mediaPath = try LampPortableDevotionalMedia.iOSRemotePath(
            moduleID: moduleId, devotionalID: "w1", filename: reference.filename
        )

        _ = try await pass().run()
        let sent = await server.attempts.filter { $0 == mediaPath }.count
        _ = try await pass().run()

        let after = await server.attempts.filter { $0 == mediaPath }.count
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(after, sent, "the attachment was sent again")
        XCTAssertNotNil(try database.syncFileRecord(source: source, path: mediaPath)?.lastRevision)
    }

    /// Apache tags a file weak for the second after it changes, so the read
    /// after any write may carry no usable revision. With patience to wait it
    /// out, a pass completes and the next has nothing to send.
    func testWeakRevisionsJustAfterAWriteAreWaitedOut() async throws {
        await server.behaveLikeASynology(lagging: false, weakReadsAfterWrite: 2)
        try saveNotesModule(notes: ["a"])
        var patient = pass()
        patient.patience = LampSyncConditionalWrite.Patience(
            confirm: [.zero, .zero, .zero, .zero], retry: [.zero, .zero]
        )

        _ = try await patient.run()
        let writes = await server.writes.count
        _ = try await patient.run()

        let after = await server.writes.count
        XCTAssertEqual(after, writes, "the second pass sent something again")
        let manifest = try await bundle().manifest
        XCTAssertEqual(manifest.entry(at: notesPath)?.isMember, true)
    }

    /// Taken but not yet shown back: the pass says so rather than calling it
    /// a lost race, and once the server catches up the next pass settles it
    /// without losing anything.
    func testAnUploadTheServerHasNotShownBackIsSettledNextPass() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await LampSyncSettingsStore.readOrClaim(from: storage)
        await server.behaveLikeASynology(lagging: true)

        // The engine says the server took it but has not shown it back: as a
        // failure line for a file, or as the error itself for the bundle.
        // Never as a refusal, which would read as another device writing.
        do {
            _ = try await pass().run()
            XCTFail("the unconfirmed upload should be reported")
        } catch let error as LampSyncConditionalWrite.Unconfirmed {
            XCTAssertFalse(LampSyncConditionalWrite.isRefusal(error))
        } catch let LibrarySyncError.incomplete(failures) {
            XCTAssertTrue(failures.contains { $0.contains("not shown it back") }, "\(failures)")
        }
        await server.catchUp()
        _ = try await pass().run()

        let manifest = try await bundle().manifest
        XCTAssertEqual(manifest.entry(at: notesPath)?.isMember, true)
        XCTAssertEqual(try storedNoteIDs(), ["a"])
        let writes = await server.writes.count
        _ = try await pass().run()
        let after = await server.writes.count
        XCTAssertEqual(after, writes, "settled: nothing left to send")
    }

    /// A highlight set deleted on another device reaches this one through the
    /// ledger, which takes the set and leaves its module with nothing to
    /// export. The pass carries on, the module goes, and its file is
    /// tombstoned so the library agrees the set has gone.
    func testAHighlightSetDeletedElsewhereTakesItsModuleWithIt() async throws {
        let setID = "set-\(UUID().uuidString)"
        defer {
            try? database.deleteModule(id: moduleId)
            try? database.write { db in
                try db.execute(sql: "DELETE FROM highlight_sets WHERE id = ?", arguments: [setID])
            }
        }
        try database.saveModule(Module(
            id: moduleId, type: .highlights, name: "My Highlights",
            filePath: "\(moduleId!).lamp", isEditable: true
        ))
        try database.saveHighlightSet(HighlightSet(
            id: setID, moduleId: moduleId, name: "My Highlights", description: nil,
            translationId: "KJV", created: 1_788_132_249, lastModified: 1_788_132_249
        ))
        let path = "Highlights/\(moduleId!).lamp"
        _ = try await pass().run()
        let published = try await bundle().manifest.entry(at: path)
        XCTAssertEqual(published?.isMember, true)

        var ledger = LampPersonalDeletionLedger()
        ledger.recordDeletion(.highlightSet, setID, at: ModuleDatabase.nowMilliseconds() + 60_000)
        let encoded = try ledger.encoded()
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.personalDeletions = encoded
        }

        _ = try await pass().run()
        _ = try await pass().run()

        XCTAssertNil(try database.getModule(id: moduleId))
        let after = try await bundle().manifest.entry(at: path)
        XCTAssertEqual(after?.isMember, false, "the set's file should be tombstoned")
    }

    /// A conflict the person has not settled is not published: neither side's
    /// version goes up until they choose, and the module is not taken for one
    /// this device lacks and fetched again.
    func testAModuleWithAnUnsettledConflictIsNotPublished() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await pass().run()
        let published = await server.file(notesPath)
        let firstRevision = try XCTUnwrap(published?.revision)

        try database.saveNoteEntry(NoteEntry(
            id: "b", moduleId: moduleId, verseId: 43_001_002, title: nil, content: "Edited here",
            verseRefs: nil, lastModified: 1_788_132_300, footnotes: nil
        ))
        let local = NoteEntry(
            id: "a", moduleId: moduleId, verseId: 43_001_001, title: nil, content: "Mine",
            verseRefs: nil, lastModified: 1_788_132_249, footnotes: nil
        )
        var remote = local
        remote.content = "Theirs"
        try database.replacePendingModuleConflicts(
            moduleId: moduleId, type: .notes,
            conflicts: [NoteConflict(id: "a", verseId: 43_001_001, localEntry: local, cloudEntry: remote)],
            key: { $0.id }
        )
        defer {
            try? database.write { db in
                try db.execute(sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ?", arguments: [moduleId])
            }
        }

        _ = try await pass().run()

        let after = await server.file(notesPath)
        XCTAssertEqual(after?.revision, firstRevision, "published while a conflict was unsettled")
        let fetches = await server.fetches.filter { $0 == notesPath }
        XCTAssertTrue(fetches.isEmpty, "held, not fetched as missing")
    }

    /// Held for an unsettled conflict is still saved here when it was: a
    /// deletion from another device older than an edit here does not take it.
    func testAModuleHeldForAConflictSurvivesAnOlderDeletionElsewhere() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await pass().run()
        let local = NoteEntry(
            id: "a", moduleId: moduleId, verseId: 43_001_001, title: nil, content: "Mine",
            verseRefs: nil, lastModified: 1_788_132_249, footnotes: nil
        )
        var remote = local
        remote.content = "Theirs"
        try database.replacePendingModuleConflicts(
            moduleId: moduleId, type: .notes,
            conflicts: [NoteConflict(id: "a", verseId: 43_001_001, localEntry: local, cloudEntry: remote)],
            key: { $0.id }
        )
        defer {
            try? database.write { db in
                try db.execute(sql: "DELETE FROM sync_pending_module_conflicts WHERE module_id = ?", arguments: [moduleId])
            }
        }
        // Another device deletes the module; this device edits it after that.
        let deletedAt = ModuleDatabase.nowMilliseconds() + 60_000
        try database.saveNoteEntry(NoteEntry(
            id: "a", moduleId: moduleId, verseId: 43_001_001, title: nil, content: "Mine, edited",
            verseRefs: nil, lastModified: Int((deletedAt + 60_000) / 1_000), footnotes: nil
        ))
        let path = notesPath
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.manifest = try bundle.manifest.removing(path, at: deletedAt, revision: nil)
        }

        _ = try await pass().run()

        XCTAssertNotNil(try database.getModule(id: moduleId), "an older deletion took a module saved after it")
        XCTAssertEqual(try storedNoteIDs(), ["a"])
    }

    /// A ledger no device can read must not stop the library syncing.
    func testAnUnreadableDeletionLedgerDoesNotStopThePass() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await LampSyncSettingsStore.readOrClaim(from: storage)
        _ = try await LampSyncSettingsStore.update(in: storage) { bundle in
            bundle.personalDeletions = Data("{ not a ledger".utf8)
        }

        _ = try await pass().run()

        let published = await server.file(notesPath)
        XCTAssertNotNil(published)
    }

    func testADeletionHereIsTombstonedAndReaped() async throws {
        try saveNotesModule(notes: ["a"])
        _ = try await pass().run()
        try database.recordSyncLocalDeletion(source: source, path: notesPath)
        try database.deleteAllEntriesForModule(moduleId: moduleId)
        try database.deleteModule(id: moduleId)

        _ = try await pass().run()

        let written = try await bundle()
        XCTAssertEqual(written.manifest.entry(at: notesPath)?.isMember, false)
        let left = await server.file(notesPath)
        XCTAssertNil(left)
        XCTAssertEqual(try database.pendingManifestChanges(source: source), [])
    }
}

/// Writes only over the bundle it was prepared against.
@MainActor
private struct ExpectingParticipant: SettingsBundleParticipant {
    let expected: Data?
    func change(_ bundle: inout LampSyncSettingsBundle, now: Int64) throws {
        guard bundle.macSettings == expected else { throw LibrarySyncPass.BundleMoved() }
        bundle.userSettings = Data("the phone wrote".utf8)
    }
    func committed(_ written: LampSyncSettingsStore.Snapshot) throws {}
}

/// The library pass over core's folder store, as iCloud Drive runs it, on a
/// plain folder: digests as revisions, writes checked under coordination.
@MainActor
final class ICloudLibraryPassTests: XCTestCase {
    private let database = ModuleDatabase.shared
    private var root: URL!
    private var moduleId: String!
    private var storage: ICloudLibraryStorage!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloud-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storage = ICloudLibraryStorage(store: LampSyncDirectoryStore(root: root))
        moduleId = "icloud-pass-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? database.deleteAllEntriesForModule(moduleId: moduleId)
        try? database.deleteModule(id: moduleId)
        try? database.write { db in
            try db.execute(sql: "DELETE FROM sync_file_records WHERE source = ?", arguments: [storage.librarySource])
            try db.execute(sql: "DELETE FROM sync_pending_manifest_changes WHERE source = ?", arguments: [storage.librarySource])
        }
        // The older-device check keeps a baseline per endpoint, and every test
        // here shares one.
        var seen = UserDefaults.standard.dictionary(forKey: "LibrarySync.settingsFileRevisions.v1") ?? [:]
        seen[storage.librarySource] = nil
        UserDefaults.standard.set(seen, forKey: "LibrarySync.settingsFileRevisions.v1")
        try? FileManager.default.removeItem(at: root)
    }

    /// An earlier library on the folder, as the phone's old iCloud sync left
    /// it: its notes file and settings, and no bundle.
    private func seedPhoneLibrary() throws {
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "My Notes", filePath: "\(moduleId!).lamp", isEditable: true
        ))
        try database.saveNoteEntry(NoteEntry(
            id: "a", moduleId: moduleId, verseId: 43_001_001, title: nil, content: "In the beginning",
            verseRefs: nil, lastModified: 1_788_132_249, footnotes: nil
        ))
        let module = try XCTUnwrap(database.getModule(id: moduleId))
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try ModuleSyncManager.shared.exportNoteModuleToSQLite(module)
            .write(to: notes.appendingPathComponent("\(moduleId!).lamp"))
        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: userData.appendingPathComponent("user-settings.db"))
    }

    func testALibraryOnlyThisDeviceKeptIsOfferedNotMoved() async throws {
        try seedPhoneLibrary()
        let pass = LibrarySyncPass(storage: storage, source: storage.librarySource)

        let outcome = try await pass.run()
        XCTAssertEqual(outcome, .phoneLibrary)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(LampSyncSettingsStore.path).path
        ), "nothing moves until the person agrees")
    }

    func testALibraryTheMacKeptWaitsForTheMac() async throws {
        try seedPhoneLibrary()
        try Data("{}".utf8).write(to: root.appendingPathComponent("lamp-sync-snapshot.json"))
        let pass = LibrarySyncPass(storage: storage, source: storage.librarySource)

        let outcome = try await pass.run()
        XCTAssertEqual(outcome, .notMigrated(archiveRevision: nil))
        do {
            try await LibrarySyncPass.movePhoneLibrary(storage: storage)
            XCTFail("the phone must not move a library the Mac kept")
        } catch LampSyncSettingsStore.StoreError.notMigrated {}
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(LampSyncSettingsStore.path).path
        ))
    }

    func testMovingALibraryOnlyThisDeviceKeptKeepsItsNotes() async throws {
        try seedPhoneLibrary()

        guard case .synced = try await LibrarySyncPass.movePhoneLibrary(storage: storage) else {
            return XCTFail("expected the moved library to sync")
        }

        let bundle = try LampSyncSettingsBundle.decode(
            Data(contentsOf: root.appendingPathComponent(LampSyncSettingsStore.path))
        )
        XCTAssertEqual(bundle.manifest.entry(at: "Notes/\(moduleId!).lamp")?.isMember, true)
        let notes = try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM note_entries WHERE module_id = ?", arguments: [moduleId])
        }
        XCTAssertEqual(notes, ["a"])
    }

    /// An older Lamp Bible on iCloud Drive never reads the bundle and keeps
    /// writing the old settings file; the pass notices the file moving.
    func testAnOlderDeviceStillWritingTheOldSettingsFileIsNoticed() async throws {
        try seedPhoneLibrary()
        SyncCoordinator.shared.olderDeviceSyncing = false
        defer { SyncCoordinator.shared.olderDeviceSyncing = false }
        try await LibrarySyncPass.movePhoneLibrary(storage: storage)
        let pass = LibrarySyncPass(storage: storage, source: storage.librarySource)
        _ = try await pass.run()
        XCTAssertFalse(SyncCoordinator.shared.olderDeviceSyncing)

        try Data("an older phone's settings".utf8)
            .write(to: root.appendingPathComponent("UserData/user-settings.db"))
        _ = try await pass.run()

        XCTAssertTrue(SyncCoordinator.shared.olderDeviceSyncing)
    }

    func testNotesGoUpAsAFileWithABundleAndASecondPassWritesNothing() async throws {
        try database.saveModule(Module(
            id: moduleId, type: .notes, name: "My Notes", filePath: "\(moduleId!).lamp", isEditable: true
        ))
        try database.saveNoteEntry(NoteEntry(
            id: "a", moduleId: moduleId, verseId: 43_001_001, title: nil, content: "In the beginning",
            verseRefs: nil, lastModified: 1_788_132_249, footnotes: nil
        ))
        let pass = LibrarySyncPass(storage: storage, source: storage.librarySource)

        guard case .synced(let first, _) = try await pass.run() else { return XCTFail("expected a synced pass") }

        let notes = root.appendingPathComponent("Notes/\(moduleId!).lamp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
        let bundle = try LampSyncSettingsBundle.decode(
            Data(contentsOf: root.appendingPathComponent(LampSyncSettingsStore.path))
        )
        XCTAssertEqual(bundle.manifest.entry(at: "Notes/\(moduleId!).lamp")?.isMember, true)
        let written = try FileManager.default.attributesOfItem(atPath: notes.path)[.modificationDate] as? Date

        guard case .synced(let second, let quiet) = try await pass.run() else { return XCTFail("expected a synced pass") }
        XCTAssertEqual(quiet.line, "nothing to do")

        XCTAssertEqual(second, first, "nothing changed, so the bundle is not rewritten")
        let after = try FileManager.default.attributesOfItem(atPath: notes.path)[.modificationDate] as? Date
        XCTAssertEqual(after, written, "nor is the module")
    }
}
