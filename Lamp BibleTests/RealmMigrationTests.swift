//
//  RealmMigrationTests.swift
//  Lamp BibleTests
//
//  Guards the one-time Realm -> GRDB migration against Realm SDK upgrades.
//
//  Scope: these tests write a legacy Realm with the Legacy* models and read it
//  back through RealmMigrator, so they catch the SDK breaking on the legacy
//  schema - object types, @Persisted properties, List handling, optional
//  relationships and field mapping.
//
//  They deliberately cannot cover opening an older on-disk *file format*
//  (e.g. format 22 written by realm-core 14). The installed SDK only writes the
//  current format, so no test here can produce one. That compatibility rests on
//  realm-core's accepted file format list, {24, 23, 22, 21, 20, 11, 10}, which is
//  unchanged between the version CocoaPods shipped and the current one.
//

import XCTest
import RealmSwift
@testable import Lamp_Bible

final class RealmMigrationTests: XCTestCase {
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

    // MARK: - Helpers

    private var legacyObjectTypes: [Object.Type] {
        [LegacyUser.self, LegacyTranslation.self, LegacyPlan.self, LegacyCompletedReading.self]
    }

    private func realmURL(_ name: String = "v4.realm") -> URL {
        temporaryDirectory.appendingPathComponent(name)
    }

    /// Build a legacy Realm file at `url`, populated by `populate`.
    @discardableResult
    private func makeLegacyRealm(
        at url: URL,
        schemaVersion: UInt64 = 2,
        populate: (Realm) -> Void
    ) throws -> URL {
        let config = Realm.Configuration(
            fileURL: url,
            schemaVersion: schemaVersion,
            objectTypes: legacyObjectTypes
        )
        let realm = try Realm(configuration: config)
        try realm.write {
            populate(realm)
        }
        // Close the file before it is read back
        realm.invalidate()
        return url
    }

    /// A fully populated legacy user, matching what the old app wrote
    private func makeFullUser() -> LegacyUser {
        let user = LegacyUser()
        user.planInAppBible = false
        user.planExternalBible = "com.example.bible"
        user.planWpm = 220.5
        user.planNotification = true

        var components = DateComponents()
        components.hour = 7
        components.minute = 45
        user.planNotificationDate = Calendar.current.date(from: components) ?? Date()

        let translation = LegacyTranslation()
        translation.id = 7
        translation.abbreviation = "ESV"
        user.readerTranslation = translation

        user.readerCrossReferenceSort = "v"
        user.readerFontSize = 22

        for id in [11, 22, 33] {
            let plan = LegacyPlan()
            plan.id = id
            user.plans.append(plan)
        }

        for id in ["1-1-1", "1-1-2", "2-5-9"] {
            let reading = LegacyCompletedReading()
            reading.id = id
            user.completedReadings.append(reading)
        }

        return user
    }

    // MARK: - Reading the legacy schema

    func testReadsFullyPopulatedLegacyUser() throws {
        let url = try makeLegacyRealm(at: realmURL()) { realm in
            realm.add(self.makeFullUser())
        }

        let data = try XCTUnwrap(
            RealmMigrator.readLegacyData(at: url, schemaVersion: 2),
            "Realm SDK could not read the legacy schema"
        )

        XCTAssertEqual(data.planInAppBible, false)
        XCTAssertEqual(data.planExternalBible, "com.example.bible")
        XCTAssertEqual(data.planWpm, 220.5)
        XCTAssertEqual(data.planNotification, true)
        XCTAssertEqual(data.planNotificationHour, 7)
        XCTAssertEqual(data.planNotificationMinute, 45)
        XCTAssertEqual(data.readerTranslationId, "ESV")
        XCTAssertEqual(data.readerCrossReferenceSort, "v")
        XCTAssertEqual(data.readerFontSize, 22)
    }

    /// Ordered `List` contents must survive as a comma-separated ID string
    func testPlanListBecomesCommaSeparatedIds() throws {
        let url = try makeLegacyRealm(at: realmURL()) { realm in
            realm.add(self.makeFullUser())
        }

        let data = try XCTUnwrap(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))

        XCTAssertEqual(data.planIds, "11,22,33")
    }

    func testCompletedReadingsAreAllPreserved() throws {
        let url = try makeLegacyRealm(at: realmURL()) { realm in
            realm.add(self.makeFullUser())
        }

        let data = try XCTUnwrap(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))

        XCTAssertEqual(data.completedReadingIds, ["1-1-1", "1-1-2", "2-5-9"])
    }

    // MARK: - Edge cases

    /// `readerTranslation` is an optional relationship; a nil one must fall back
    /// rather than crash or produce an empty translation ID.
    func testMissingTranslationFallsBackToDefault() throws {
        let url = try makeLegacyRealm(at: realmURL()) { realm in
            let user = LegacyUser()
            user.readerTranslation = nil
            realm.add(user)
        }

        let data = try XCTUnwrap(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))

        XCTAssertEqual(data.readerTranslationId, RealmMigrator.fallbackTranslationId)
    }

    func testUserWithNoPlansOrReadingsReadsCleanly() throws {
        let url = try makeLegacyRealm(at: realmURL()) { realm in
            realm.add(LegacyUser())
        }

        let data = try XCTUnwrap(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))

        XCTAssertEqual(data.planIds, "")
        XCTAssertTrue(data.completedReadingIds.isEmpty)
    }

    /// default.realm was written at schema version 1, the others at 2
    func testReadsSchemaVersionOneFile() throws {
        let url = try makeLegacyRealm(at: realmURL("default.realm"), schemaVersion: 1) { realm in
            realm.add(self.makeFullUser())
        }

        let data = try XCTUnwrap(
            RealmMigrator.readLegacyData(at: url, schemaVersion: 1),
            "Could not read a schema version 1 file"
        )

        XCTAssertEqual(data.readerTranslationId, "ESV")
        XCTAssertEqual(data.planIds, "11,22,33")
    }

    // MARK: - Failure handling

    func testEmptyRealmYieldsNoData() throws {
        let url = try makeLegacyRealm(at: realmURL()) { _ in }

        XCTAssertNil(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))
    }

    func testMissingFileYieldsNoDataRatherThanCrashing() {
        let missing = temporaryDirectory.appendingPathComponent("does-not-exist.realm")

        // Opening a non-existent Realm creates an empty one, so the result is "no
        // user" either way - the contract is that it never traps.
        XCTAssertNil(RealmMigrator.readLegacyData(at: missing, schemaVersion: 2))
    }

    func testUnreadableFileYieldsNoDataRatherThanCrashing() throws {
        let url = realmURL("corrupt.realm")
        try Data("this is not a realm file".utf8).write(to: url)

        XCTAssertNil(RealmMigrator.readLegacyData(at: url, schemaVersion: 2))
    }
}
