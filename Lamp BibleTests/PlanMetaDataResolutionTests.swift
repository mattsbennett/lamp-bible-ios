//
//  PlanMetaDataResolutionTests.swift
//  Lamp BibleTests
//
//  A plan reading's verse tallies come from the translation database. When that
//  database isn't readable yet — the app is still opening it, or sync has it
//  shut — the tallies come back as zeroes. These cover keeping that apart from
//  a reading that genuinely has no verses, so a zero is never cached or shown
//  as though it were the answer. Before this, one unlucky launch left every
//  reading card reading "0v" until the app was relaunched.
//

import XCTest
@testable import Lamp_Bible

final class PlanMetaDataResolutionTests: XCTestCase {
    func testResolvedStatsReportAnAnswerEvenWhenTheRangeIsEmpty() {
        // A translation that doesn't cover the range: read it, found nothing.
        let stats = VerseRangeStats(
            wordCount: 0,
            chapterVerseCounts: [],
            firstBook: nil,
            isResolved: true
        )
        XCTAssertTrue(stats.isResolved)
        XCTAssertEqual(stats.verseCount, 0)
    }

    func testUnresolvedStatsAreNotAnAnswer() {
        XCTAssertFalse(VerseRangeStats.unresolved.isResolved)
        XCTAssertEqual(VerseRangeStats.unresolved.verseCount, 0)
        XCTAssertTrue(VerseRangeStats.unresolved.chapterVerseCounts.isEmpty)
    }

    func testReadingMetaDataCarriesResolutionToTheCard() {
        let unresolved = ReadingMetaData(
            id: "p_1_0_2026",
            index: 0,
            readingTime: 0,
            description: "John 1",
            genre: "Gospel",
            sv: 43_001_001,
            ev: 43_001_051,
            chapterVerseCounts: [],
            isResolved: false
        )
        XCTAssertFalse(unresolved.isResolved)

        let resolved = ReadingMetaData(
            id: "p_1_0_2026",
            index: 0,
            readingTime: 4,
            description: "John 1",
            genre: "Gospel",
            sv: 43_001_001,
            ev: 43_001_051,
            chapterVerseCounts: [51]
        )
        XCTAssertTrue(resolved.isResolved, "Resolution defaults to true for ordinary builds")
        XCTAssertEqual(resolved.verseCount, 51)
    }

    /// The key cannot change once a database comes back, so memoising a failed
    /// build would outlive the failure and survive every later rebuild.
    func testTheMetaDataCacheKeepsResolvedBuildsAndDropsUnresolvedOnes() throws {
        let plans = (try? BundledModuleDatabase.shared.getAllPlans()) ?? []
        try XCTSkipIf(plans.isEmpty, "No bundled plans available in this build")
        guard let plan = plans.first else { return }

        var settings = UserSettings()
        // An id no database holds, so every reading's stats come back unresolved.
        settings.readerTranslationId = "__lamp_missing_translation__"
        let date = Date()

        let first = PlanMetaDataCache.shared.metaData(
            for: plan,
            date: date,
            userSettings: settings
        )
        guard !first.readingMetaData.isEmpty else {
            throw XCTSkip("Plan has no reading for this date")
        }
        XCTAssertFalse(
            first.isFullyResolved,
            "A missing translation cannot produce resolved tallies"
        )

        let second = PlanMetaDataCache.shared.metaData(
            for: plan,
            date: date,
            userSettings: settings
        )
        XCTAssertFalse(
            first === second,
            "An unresolved build must not be memoised, or it outlives the failure"
        )
    }
}
