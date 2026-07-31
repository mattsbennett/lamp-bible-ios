//
//  ViewModel.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import Foundation

class PlanMetaData {
    let id: String
    let plan: Plan
    let date: Date
    let description: String
    let readingTime: Int
    var readingMetaData: [ReadingMetaData] = []

    convenience init(id: String, plan: Plan, date: Date) {
        self.init(id: id, plan: plan, date: date, userSettings: UserDatabase.shared.getSettings())
    }

    init(id: String, plan: Plan, date: Date, userSettings: UserSettings) {
        var readingTimeAcc: Int = 0
        var readingMetaDataInit: [ReadingMetaData] = []
        self.id = id
        self.plan = plan
        self.date = date
        let dayNum = plan.getPlanDay(date: date)

        // Get plan day from GRDB bundled database
        guard let planDay = try? BundledModuleDatabase.shared.getPlanDay(planId: plan.id, day: dayNum) else {
            self.description = ""
            self.readingTime = 0
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
            let stats = (try? TranslationDatabase.shared.getVerseRangeStats(
                translationId: translationId,
                startRef: sv,
                endRef: ev
            )) ?? .empty

            let readingTimeReading = Int(ceil(Double(stats.wordCount) / userSettings.planWpm))
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
                    chapterVerseCounts: chapterVerseCounts
                )
            )
        }

        self.readingMetaData = readingMetaDataInit
        self.readingTime = readingTimeAcc
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

    var verseCount: Int { chapterVerseCounts.reduce(0, +) }

    init(id: String, index: Int, readingTime: Int, description: String, genre: String, sv: Int, ev: Int, chapterVerseCounts: [Int]) {
        self.id = id
        self.index = index
        self.readingTime = readingTime
        self.description = description
        self.genre = genre
        self.sv = sv
        self.ev = ev
        self.chapterVerseCounts = chapterVerseCounts
    }
}

class PlansMetaData {
    let plans: [Plan]
    let date: Date
    var planMetaData: [PlanMetaData] = []

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
