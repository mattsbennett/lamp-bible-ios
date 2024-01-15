//
//  ViewModel.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import RealmSwift

class PlanMetaData {
    let id: Int
    let plan: Plan
    let date: Date
    let description: String
    let readingTime: Int
    var readingMetaData: [ReadingMetaData] = []
    
    init(id: Int, plan: Plan, date: Date) {
        var readingTimeAcc: Int = 0
        var readingMetaDataInit: [ReadingMetaData] = []
        self.id = id
        self.plan = plan
        self.date = date
        let day = plan.getPlanDay(date: date)
        let planDay = plan.plan.filter("day == \(day)").first!
        self.description = planDay.getReadingsDescription()
        
        planDay.readings.indices.forEach { index in
            let user = RealmManager.shared.realm.objects(User.self).first!
            let reading = planDay.readings[index]
            let (sv, ev, description) = reading.getVerseRange()
            let verses = RealmManager.shared.realm.objects(Verse.self).filter("tr == \(user.readerTranslation!.id) && id >= \(sv ?? 0) && id <= \(ev ?? 0)")
            let concatenatedString = verses.map { $0.t }.joined(separator: " ")
            let readingWordCount = countWords(source: concatenatedString)
            let readingTimeReading = Int(ceil(Double(readingWordCount) / user.planWpm))
            let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(verses.first!.b)").first
            let genre = RealmManager.shared.realm.objects(Genre.self).filter("id == \(book!.genre)").first!.name
            readingTimeAcc += readingTimeReading
            readingMetaDataInit.append(
                ReadingMetaData(
                    id: index,
                    readingTime: readingTimeReading,
                    description: description!,
                    genre: genre,
                    sv: sv!,
                    ev: ev!
                )
            )
        }
        
        self.readingMetaData = readingMetaDataInit
        self.readingTime = readingTimeAcc
    }
}

class ReadingMetaData {
    let id: Int
    let readingTime: Int
    let description: String
    let genre: String
    let sv: Int
    let ev: Int
    
    init(id: Int, readingTime: Int, description: String, genre: String, sv: Int, ev: Int) {
        self.id = id
        self.readingTime = readingTime
        self.description = description
        self.genre = genre
        self.sv = sv
        self.ev = ev
    }
}

class PlansMetaData {
    let plans: Results<Plan>
    let date: Date
    var planMetaData: [PlanMetaData] = []
    
    init(plans: Results<Plan> = RealmManager.shared.realm.objects(Plan.self), date: Date) {
        self.plans = plans
        self.date = date
        
        plans.forEach { plan in
            planMetaData.append(PlanMetaData(id: plan.id, plan: plan, date: date))
        }
    }
}
