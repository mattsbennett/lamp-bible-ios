//
//  DataModel.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-28.
//

import RealmSwift
import Realm
import SwiftUI

// Realm Data Model -----------------------------------------------------------

class Genre: RealmSwiftObject, Decodable, Identifiable {
    @Persisted(primaryKey: true) var id: Int
    @Persisted var name: String
}

class Book: RealmSwiftObject, Decodable, Identifiable {
    @Persisted(primaryKey: true) var id: Int
    @Persisted var genre: Int
    @Persisted var name: String
    @Persisted var osisId: String
    @Persisted var osisParatextAbbreviation: String
    @Persisted var testament: String
}

class Translation: RealmSwiftObject, Decodable, Identifiable {
    @Persisted(primaryKey: true) var id: Int
    @Persisted var abbreviation: String
    @Persisted var language: String
    @Persisted var name: String
    @Persisted var url: String
    @Persisted var license: String
    @Persisted var fullDescription: String
    @Persisted var verses: RealmSwift.List<Verse>
}

class CrossReference: RealmSwiftObject, Decodable, Identifiable {
    // Of format bbcccvvv e.g. Gen. 1:1 is 1001001, Rev. 1:1 is 66001001
    @Persisted(indexed: true) var id: Int
    // Rank
    @Persisted var r: Int
    // Start verse
    @Persisted var sv: Int
    // End verse
    @Persisted var ev: Int?
}

extension CrossReference {
    var uniqueId: String { UUID().uuidString }
}

class Verse: RealmSwiftObject, Decodable, Identifiable {
    // Of format bbcccvvv e.g. Gen. 1:1 is 1001001, Rev. 1:1 is 66001001
    @Persisted(indexed: true) var id: Int
    // Book ID (1-66)
    @Persisted var b: Int
    // Chapter number
    @Persisted var c: Int
    // Verse number
    @Persisted var v: Int
    // Verse text
    @Persisted var t: String
    // Translation ID
    @Persisted(indexed: true) var tr: Int
}

class Plan: RealmSwiftObject, Decodable, Identifiable {
    @Persisted(primaryKey: true) var id: Int
    @Persisted var author: String
    @Persisted var name: String
    @Persisted var shortDescription: String
    @Persisted var fullDescription: String
    @Persisted var plan: RealmSwift.List<PlanDay>

    func getPlanDay(date: Date) -> Int {
        let year = Calendar.iso8601.component(.year, from: date)
        var day = Calendar.iso8601.ordinality(of: .day, in: .year, for: date)!

        if !year.isALeapYear && day >= 60 {
            // Plans include 366 days (for leap years), but on non-leap-years,
            // we need to skip the extra day (day 60 (Feb 29))
            day = day + 1
        }

        return day
    }
}

class PlanDay: RealmSwiftObject, Decodable, Identifiable {
    @Persisted(indexed: true) var day: Int
    @Persisted var readings: RealmSwift.List<Reading>

    func getReadingsDescription() -> String {
        var readingsDescription = ""

        self.readings.indices.forEach { index in
            let (_, _, description) = readings[index].getVerseRange()
            let trailingComma = index == self.readings.indices.count - 1 ? "" : ", "

            readingsDescription += description! + trailingComma
        }

        return readingsDescription
    }
}

class Reading: RealmSwiftObject, Decodable, Identifiable {
    @Persisted var book: ReadingRange?
    @Persisted var chapter: ReadingRange?
    @Persisted var verse: ReadingRange?

    func getVerseRange() -> (sv: Int?, ev: Int?, description: String?) {
        var startBook: String? = nil
        var startBookName: String? = nil
        var endBook: String? = nil
        var endBookName: String? = nil
        var startChapter: String? = nil
        var paddedStartChapter: String? = nil
        var endChapter: String? = nil
        var paddedEndChapter: String? = nil
        var startVerse: String? = nil
        var paddedStartVerse: String? = nil
        var endVerse: String? = nil
        var paddedEndVerse: String? = nil
        var sv: String? = nil
        var ev: String? = nil
        var description: String? = nil
        let translationId = RealmManager.shared.realm.objects(User.self).first!.readerTranslation!.id

        if self.book != nil {
            startBook = String(self.book!.start!)
            endBook = String(self.book!.end!)
        }

        if self.chapter != nil && self.chapter!.start != nil {
            startChapter = String(self.chapter!.start!)
            paddedStartChapter = String(format: "%03d", self.chapter!.start!)
            endChapter = String(self.chapter!.end!)
            paddedEndChapter = String(format: "%03d", self.chapter!.end!)
        }

        if self.verse != nil && self.verse!.start != nil {
            startVerse = String(self.verse!.start!)
            paddedStartVerse = String(format: "%03d", self.verse!.start!)
            endVerse = String(self.verse!.end!)
            paddedEndVerse = String(format: "%03d", self.verse!.end!)
        }

        if startBook != nil {
            startBookName = RealmManager.shared.realm.objects(Book.self).filter("id == \(startBook ?? "1")").first!.name
            sv = startBook
            sv! += paddedStartChapter ?? "001"
            sv! += paddedStartVerse ?? "001"
        }

        if endBook != nil {
            let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(endBook ?? "1")").first
            endBookName = book!.name

            // If there's no end verse specified, need to make it the last verse of the endChapter
            if paddedEndVerse == nil {
                let endChapterVerseId = RealmManager.shared.realm.objects(Verse.self).filter("tr == \(translationId) && b == \(book!.id) && c == \(self.chapter!.end ?? 1)").last!.id
                ev = String(endChapterVerseId)
            } else {
                ev = endBook
                ev! += paddedEndChapter ?? "001"
                ev! += paddedEndVerse ?? "001"
            }
        }

        if startBook != nil && endBook != nil {
            description = startBookName!

            if startChapter != nil {
                description! += " " + startChapter!
            }

            if startVerse != nil {
                description! += ":" + startVerse!
            }

            if startBook != endBook {
                description! += " - " + endBookName!
            } else if endChapter != nil && endVerse != nil && startChapter == endChapter {
                description! += "-" + endVerse!
            } else if endChapter != nil && endVerse == nil && startChapter != endChapter {
                description! += "-" + endChapter!
            } else if endChapter != nil && endVerse != nil && startChapter != endChapter {
                description! += "-" + endChapter! + ":" + endVerse!
            }
        }

        return (Int(sv!), Int(ev!), description)
    }
}

class ReadingRange: RealmSwiftObject, Decodable, Identifiable {
    @Persisted var start: Int?
    @Persisted var end: Int?
}

class User: RealmSwiftObject, Identifiable {
    @Persisted var plans = RealmSwift.List<Plan>()
    @Persisted var planInAppBible = true
    @Persisted var planExternalBible: String? = nil
    @Persisted var planWpm: Double = 183
    @Persisted var planNotification = false
    @Persisted var planNotificationDate: Date = {
        var dateComponents = DateComponents()
        dateComponents.hour = 18
        dateComponents.minute = 30
        return Calendar.current.date(from: dateComponents) ?? Date()
    }()
    @Persisted var readerTranslation: Translation? = nil
    @Persisted var readerCrossReferenceSort = "r"
    @Persisted var readerFontSize: Float = 16
    @Persisted var completedReadings = RealmSwift.List<CompletedReading>()

    // Notes settings
    @Persisted var notesEnabled: Bool = true
    @Persisted var notesPanelVisible: Bool = false
    @Persisted var notesPanelOrientation: String = "bottom"  // "bottom" or "right"

    // Lexicon settings
    @Persisted var greekLexicon: String = "strongs"  // "strongs" or "dodson"
    @Persisted var hebrewLexicon: String = "strongs"  // "strongs" or "bdb" (Brown-Driver-Briggs)

    let defaultTranslationId = 3

    func addCompletedReading(id: String) {
        self.completedReadings.append(CompletedReading(id: id))
    }

    func removeCompletedReading(id: String) {
        if let completedReading = RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(id)'").first {
            RealmManager.shared.realm.delete(completedReading)
        }
    }
}

class CompletedReading: RealmSwiftObject, Identifiable {
    @Persisted(primaryKey: true) var id: String

    convenience init(id: String) {
        self.init()
        self.id = id
    }
}

// MARK: - Treasury of Scripture Knowledge (TSKe)

class TSKBook: RealmSwiftObject, Decodable, Identifiable {
    // Book ID (1-66)
    @Persisted(primaryKey: true) var b: Int
    // Book introduction text
    @Persisted var t: String
}

class TSKChapter: RealmSwiftObject, Identifiable {
    // Book ID (1-66)
    @Persisted(indexed: true) var b: Int
    // Chapter number
    @Persisted var c: Int
    // Segments as JSON string (array of text/ref segments)
    // Text segments: {"t": "plain text"}
    // Ref segments: {"sv": verseId} or {"sv": startId, "ev": endId}
    @Persisted var segmentsJson: String

    var id: String { "\(b)_\(c)" }
}

class TSKVerse: RealmSwiftObject, Identifiable {
    // Verse ID (format: bbcccvvv e.g. 1001001)
    @Persisted(primaryKey: true) var id: Int
    // Topics/headings for this verse
    @Persisted var topics: RealmSwift.List<TSKTopic>
}

class TSKTopic: RealmSwiftObject, Identifiable {
    // Topic heading (e.g., "in the hold", "Reciprocal")
    @Persisted var h: String
    // Segments as JSON string (array of text/ref segments)
    // Text segments: {"t": "text"} or {"t": "text", "i": true} for italic
    // Ref segments: {"sv": verseId} or {"sv": startId, "ev": endId}
    @Persisted var segmentsJson: String

    var id: String { UUID().uuidString }
}

class TSKRef: RealmSwiftObject, Decodable, Identifiable {
    // Start verse ID (format: bbcccvvv)
    @Persisted var sv: Int
    // End verse ID (for ranges, nil if single verse)
    @Persisted var ev: Int?
    // Note/comment (optional)
    @Persisted var n: String?

    var id: String { UUID().uuidString }
}

// MARK: - Strong's Lexicons

class StrongsGreek: RealmSwiftObject, Identifiable {
    // Strong's number (e.g., "G18")
    @Persisted(primaryKey: true) var id: String
    // Greek word (lemma)
    @Persisted var lemma: String
    // Transliteration
    @Persisted var xlit: String?
    // Definition
    @Persisted var def: String?
    // KJV usage
    @Persisted var kjv: String?
    // Derivation/etymology
    @Persisted var deriv: String?
}

class StrongsHebrew: RealmSwiftObject, Identifiable {
    // Strong's number (e.g., "H1")
    @Persisted(primaryKey: true) var id: String
    // Hebrew word (lemma)
    @Persisted var lemma: String
    // Transliteration
    @Persisted var xlit: String?
    // Pronunciation
    @Persisted var pron: String?
    // Definition
    @Persisted var def: String?
    // KJV usage
    @Persisted var kjv: String?
    // Derivation/etymology
    @Persisted var deriv: String?
}

class DodsonGreek: RealmSwiftObject, Identifiable {
    // Strong's number (e.g., "G18")
    @Persisted(primaryKey: true) var id: String
    // Greek word with grammatical info (e.g., "ἀγάπη, ης, ἡ")
    @Persisted var lemma: String
    // Definition
    @Persisted var def: String?
    // Brief definition/gloss
    @Persisted var short: String?
}

class BDBEntry: RealmSwiftObject, Identifiable {
    // BDB entry ID (e.g., "a.ac.aa")
    @Persisted(primaryKey: true) var id: String
    // Primary Hebrew word (lemma)
    @Persisted(indexed: true) var lemma: String
    // Part of speech (e.g., "vb", "n.m", "n.pr.m")
    @Persisted var pos: String?
    // Entry type (e.g., "root")
    @Persisted var type: String?
    // Top-level definitions (joined with "; ")
    @Persisted var defs: String?
    // Verb stems for verbs (joined with ", ")
    @Persisted var stems: String?
    // Full senses data as JSON string (for complex nested display)
    @Persisted var sensesJson: String?
    // Sample verse references (joined with ", ")
    @Persisted var refs: String?
}

class BDBMapping: RealmSwiftObject, Identifiable {
    // Strong's number (e.g., "H1")
    @Persisted(primaryKey: true) var id: String
    // BDB entry IDs that match this Strong's number (joined with ",")
    @Persisted var bdbEntryIds: String
}

