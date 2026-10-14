//
//  ViewModel.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import Foundation
import LampCore

class PlanMetaData {
    let id: String
    let plan: Plan
    let date: Date
    let description: String
    let readingTime: Int
    var readingMetaData: [ReadingMetaData] = []
    /// Whether every reading's numbers came from a readable database. A build
    /// made while one was still opening is all zeroes, and must not be cached
    /// or shown as though it were the answer.
    let isFullyResolved: Bool

    convenience init(id: String, plan: Plan, date: Date) {
        self.init(id: id, plan: plan, date: date, userSettings: UserDatabase.shared.getSettings())
    }

    init(id: String, plan: Plan, date: Date, userSettings: UserSettings) {
        var readingTimeAcc: Int = 0
        var readingMetaDataInit: [ReadingMetaData] = []
        var allResolved = true
        self.id = id
        self.plan = plan
        self.date = date
        let dayNum = plan.getPlanDay(date: date)

        // Get plan day from GRDB bundled database
        guard let planDay = try? BundledModuleDatabase.shared.getPlanDay(planId: plan.id, day: dayNum) else {
            self.description = ""
            self.readingTime = 0
            // A plan can legitimately lack this day; a database that has not
            // opened yet cannot say either way.
            self.isFullyResolved = BundledModuleDatabase.shared.isReady
            return
        }

        self.description = planDay.getReadingsDescription()
        let readings = planDay.readings

        let translationId = userSettings.readerTranslationId

        for (index, reading) in readings.enumerated() {
            let sv = reading.sv
            let ev = reading.ev
            let readingDescription = reading.getDescription()

            // Only the word count and verse tallies are needed here, so avoid
            // pulling the full verse rows (annotations/footnotes/poetry JSON).
            // A throw here means the translation database could not be read,
            // not that the reading is empty: `.unresolved` keeps the two apart
            // so neither the cards nor `PlanView`'s cache mistake it for zero.
            let stats = (try? TranslationDatabase.shared.getVerseRangeStats(
                translationId: translationId,
                startRef: sv,
                endRef: ev
            )) ?? .unresolved

            allResolved = allResolved && stats.isResolved
            let readingTimeReading = LampReadingTimeEstimator.minutes(
                wordCount: stats.wordCount, wordsPerMinute: userSettings.planWpm
            )
            let book = try? BundledModuleDatabase.shared.getBook(id: stats.firstBook ?? 1)
            let genre = (try? BundledModuleDatabase.shared.getGenre(id: book?.genre ?? 1))?.name ?? "General"
            let chapterVerseCounts = stats.chapterVerseCounts

            let year = Calendar.iso8601.component(.year, from: date)
            let readingId = "\(id)_\(dayNum)_\(index)_\(year)"
            readingTimeAcc += readingTimeReading
            readingMetaDataInit.append(
                ReadingMetaData(
                    id: readingId,
                    index: index,
                    readingTime: readingTimeReading,
                    description: readingDescription,
                    genre: genre,
                    sv: sv,
                    ev: ev,
                    chapterVerseCounts: chapterVerseCounts,
                    isResolved: stats.isResolved
                )
            )
        }

        self.readingMetaData = readingMetaDataInit
        self.readingTime = readingTimeAcc
        self.isFullyResolved = allResolved
    }
}

class ReadingMetaData {
    // Unique reading id across all plans and years of the format
    // "{planId}_{planDay}_r{eadingIndex}_{year)" also used as primary key
    // for CompletedReading
    let id: String
    let index: Int
    let readingTime: Int
    let description: String
    let genre: String
    let sv: Int
    let ev: Int
    let chapterVerseCounts: [Int]
    /// False when the translation database could not be read, so the zeroes
    /// below mean "unknown" rather than "none".
    let isResolved: Bool

    var verseCount: Int { chapterVerseCounts.reduce(0, +) }

    init(id: String, index: Int, readingTime: Int, description: String, genre: String, sv: Int, ev: Int, chapterVerseCounts: [Int], isResolved: Bool = true) {
        self.id = id
        self.index = index
        self.readingTime = readingTime
        self.description = description
        self.genre = genre
        self.sv = sv
        self.ev = ev
        self.chapterVerseCounts = chapterVerseCounts
        self.isResolved = isResolved
    }
}

class PlansMetaData {
    let plans: [Plan]
    let date: Date
    var planMetaData: [PlanMetaData] = []

    /// Whether every plan built from readable databases. `PlanView` keys its
    /// rebuild decision on this, so a launch that raced a database opening
    /// recovers instead of showing zeroes until the app is relaunched.
    var isFullyResolved: Bool { planMetaData.allSatisfy(\.isFullyResolved) }

    convenience init(plans: [Plan]? = nil, date: Date) {
        self.init(plans: plans, date: date, userSettings: UserDatabase.shared.getSettings())
    }

    init(plans: [Plan]?, date: Date, userSettings: UserSettings) {
        // Get all plans from GRDB bundled database if not provided
        self.plans = plans ?? ((try? BundledModuleDatabase.shared.getAllPlans()) ?? [])
        self.date = date

        for plan in self.plans {
            planMetaData.append(
                PlanMetaDataCache.shared.metaData(for: plan, date: date, userSettings: userSettings)
            )
        }
    }
}

// MARK: - Plan Meta Data Cache

/// Memoises built plan metadata.
///
/// Building one entry queries the bundled database once per reading, and the
/// same day gets rebuilt constantly — stepping back and forth through dates, and
/// the widget payload covering a 30-day window. Everything that can change the
/// result is part of the key, so entries never need explicit invalidation.
final class PlanMetaDataCache {
    static let shared = PlanMetaDataCache()

    private struct Key: Hashable {
        let planId: String
        let dayNum: Int
        let year: Int
        let translationId: String
        let wpm: Double
    }

    private var entries: [Key: PlanMetaData] = [:]
    /// Insertion order, for cheap FIFO eviction.
    private var insertionOrder: [Key] = []
    private let lock = NSLock()
    private let limit = 400

    private init() {}

    func metaData(for plan: Plan, date: Date, userSettings: UserSettings) -> PlanMetaData {
        let key = Key(
            planId: plan.id,
            dayNum: plan.getPlanDay(date: date),
            year: Calendar.iso8601.component(.year, from: date),
            translationId: userSettings.readerTranslationId,
            wpm: userSettings.planWpm
        )

        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Built outside the lock: this is the expensive part, and building the
        // same entry twice is harmless.
        let built = PlanMetaData(id: plan.id, plan: plan, date: date, userSettings: userSettings)

        // Never memoise a build whose databases could not be read: the key
        // cannot change afterwards, so a cached failure would survive every
        // rebuild for the rest of the session.
        guard built.isFullyResolved else { return built }

        lock.lock()
        if entries[key] == nil {
            entries[key] = built
            insertionOrder.append(key)
            while insertionOrder.count > limit {
                entries.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        lock.unlock()

        return built
    }

    /// Drop everything. Needed when the underlying module data changes (a
    /// translation is imported or removed), which the key can't see.
    func invalidate() {
        lock.lock()
        entries.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }
}
