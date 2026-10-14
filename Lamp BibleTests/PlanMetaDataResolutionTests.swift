import XCTest
@testable import Lamp_Bible

/// Uses actual database reads and plan builds to distinguish an empty reading
/// from unavailable data and to verify the cache's retry and reuse behavior.
final class PlanMetaDataResolutionTests: XCTestCase {
    private let translationID = "plan-stats-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try ModuleDatabase.shared.saveTranslation(TranslationModule(
            id: translationID, name: "Empty fixture", abbreviation: "TEST", language: "en"
        ))
    }

    override func tearDownWithError() throws {
        try ModuleDatabase.shared.deleteTranslation(id: translationID)
    }

    func testAnEmptyInstalledTranslationIsResolvedWhileAMissingOneIsNot() throws {
        let database = TranslationDatabase.shared
        let empty = try database.getVerseRangeStats(
            translationId: translationID, startRef: 43_001_001, endRef: 43_001_051
        )
        XCTAssertTrue(empty.isResolved)
        XCTAssertEqual(empty.wordCount, 0)
        XCTAssertEqual(empty.verseCount, 0)
        let missing = try database.getVerseRangeStats(
            translationId: translationID + "-missing", startRef: 43_001_001, endRef: 43_001_051
        )
        XCTAssertFalse(missing.isResolved)
    }

    func testTheMetaDataCacheRetriesUnresolvedBuildsAndReusesResolvedOnes() throws {
        let plan = try XCTUnwrap(BundledModuleDatabase.shared.getAllPlans().first)
        let date = try XCTUnwrap(Calendar.iso8601.date(from:
            DateComponents(year: 2026, month: 1, day: 1)))
        var settings = UserSettings()
        settings.readerTranslationId = translationID + "-missing"

        let first = PlanMetaDataCache.shared.metaData(for: plan, date: date, userSettings: settings)
        XCTAssertFalse(first.readingMetaData.isEmpty, "The bundled plan must contain a reading on day one")
        XCTAssertFalse(first.isFullyResolved)
        XCTAssertTrue(first.readingMetaData.allSatisfy { !$0.isResolved })
        let retry = PlanMetaDataCache.shared.metaData(for: plan, date: date, userSettings: settings)
        XCTAssertFalse(first === retry, "Unavailable data must be retried")

        settings.readerTranslationId = translationID
        let resolved = PlanMetaDataCache.shared.metaData(for: plan, date: date, userSettings: settings)
        XCTAssertTrue(resolved.isFullyResolved)
        XCTAssertTrue(resolved.readingMetaData.allSatisfy(\.isResolved))
        let reused = PlanMetaDataCache.shared.metaData(for: plan, date: date, userSettings: settings)
        XCTAssertTrue(resolved === reused, "Resolved metadata should be cached, including genuinely empty readings")
    }
}
