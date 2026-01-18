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

    init(id: String, plan: Plan, date: Date) {
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

        // Get user settings from GRDB
        let userSettings = UserDatabase.shared.getSettings()

        for (index, reading) in readings.enumerated() {
            let sv = reading.sv
            let ev = reading.ev
            let readingDescription = reading.getDescription()

            // Fetch verses from GRDB using translationId
            let translationId = userSettings.readerTranslationId
            let verses = (try? TranslationDatabase.shared.getVerseRange(
                translationId: translationId,
                startRef: sv,
                endRef: ev
            )) ?? []

            let concatenatedString = verses.map { $0.text }.joined(separator: " ")
            let readingWordCount = countWords(source: concatenatedString)
            let readingTimeReading = Int(ceil(Double(readingWordCount) / userSettings.planWpm))
            let book = try? BundledModuleDatabase.shared.getBook(id: verses.first?.book ?? 1)
            let genre = (try? BundledModuleDatabase.shared.getGenre(id: book?.genre ?? 1))?.name ?? "General"
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
                    ev: ev
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
    
    init(id: String, index: Int, readingTime: Int, description: String, genre: String, sv: Int, ev: Int) {
        self.id = id
        self.index = index
        self.readingTime = readingTime
        self.description = description
        self.genre = genre
        self.sv = sv
        self.ev = ev
    }
}

class PlansMetaData {
    let plans: [Plan]
    let date: Date
    var planMetaData: [PlanMetaData] = []

    init(plans: [Plan]? = nil, date: Date) {
        // Get all plans from GRDB bundled database if not provided
        self.plans = plans ?? ((try? BundledModuleDatabase.shared.getAllPlans()) ?? [])
        self.date = date

        for plan in self.plans {
            planMetaData.append(PlanMetaData(id: plan.id, plan: plan, date: date))
        }
    }
}
