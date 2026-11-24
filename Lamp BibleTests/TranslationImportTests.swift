//
//  TranslationImportTests.swift
//  Lamp BibleTests
//
//  A Bible the user imports is compiled by core and taken in by this
//  device's own module store; these check the two agree.
//

import LampModuleKit
import XCTest
@testable import Lamp_Bible

final class TranslationImportTests: XCTestCase {
    private var abbreviation: String!
    private var installedID: String?

    override func setUpWithError() throws {
        abbreviation = "T\(UUID().uuidString.prefix(6))"
    }

    override func tearDownWithError() throws {
        if let installedID {
            try? ModuleDatabase.shared.deleteTranslation(id: installedID)
        }
    }

    func testAnImportedBibleReadsLikeAnyTranslationAndAReimportReplacesIt() async throws {
        let translation = try LampTranslationImporter().read(data: Data(#"""
            \id PSA Test Psalter
            \c 23
            \d A Psalm of David.
            \q1
            \v 1 The \nd LORD\nd* is my shepherd;\f + \ft Or \fq pastor\f* I shall not want.
            \q2
            \v 2 He maketh me to lie down in green pastures: \qs Selah\qs*
            """#.utf8), filename: "psalter.usfm")

        let destination = try ModuleSyncManager.shared.translationImportLibrary().destination(abbreviation: abbreviation)
        XCTAssertNil(destination.replacedModuleID)
        installedID = destination.moduleID
        try await ModuleSyncManager.shared.importTranslation(
            translation, into: destination, name: "Test Psalter", abbreviation: abbreviation, language: "en"
        )

        XCTAssertEqual(try TranslationDatabase.shared.getTranslation(id: destination.moduleID)?.name, "Test Psalter")
        let first = try XCTUnwrap(TranslationDatabase.shared.getVerse(translationId: destination.moduleID, ref: 19_023_001))
        XCTAssertEqual(first.text, "The LORD is my shepherd; I shall not want.")
        let lord = try XCTUnwrap(first.annotations?.first)
        XCTAssertEqual(lord.type, .divineName)
        // The reader counts Characters, as core does.
        XCTAssertEqual(String(Array(first.text)[lord.start..<lord.end]), "LORD")
        XCTAssertEqual(first.footnoteRefs?.map(\.offset), [Array("The LORD is my shepherd;").count])
        XCTAssertEqual(first.footnotes?.map(\.plainText), ["Or pastor"])
        let second = try XCTUnwrap(TranslationDatabase.shared.getVerse(translationId: destination.moduleID, ref: 19_023_002))
        XCTAssertEqual(second.annotations?.map(\.type), [.selah])

        // And its verses are in the search index. Asked of the index for
        // this translation rather than through a ranked search across the
        // library: with other Bibles installed, "shepherd" fills any limit
        // long before reaching a psalter imported a moment ago, so that
        // assertion passed alone and failed in the suite.
        //
        // Kept from a reverted change to how the index is filled on import:
        // whatever fills it, an imported translation has to be findable, and
        // nothing asserted that before.
        let indexed = try ModuleDatabase.shared.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM translation_verses
                    WHERE translation_id = ? AND id IN (
                        SELECT rowid FROM translation_verses_fts
                        WHERE translation_verses_fts MATCH ?
                    )
                    """,
                arguments: [destination.moduleID, "shepherd"]
            ) ?? 0
        }
        XCTAssertEqual(indexed, 1, "the imported verse is not in the search index")

        let again = try ModuleSyncManager.shared.translationImportLibrary().destination(abbreviation: abbreviation)
        XCTAssertEqual(again.replacedModuleID, destination.moduleID)
        XCTAssertEqual(again.moduleID, destination.moduleID)
    }
}
