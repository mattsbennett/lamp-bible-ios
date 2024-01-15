//
//  Utilities.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import RealmSwift

func countWords(source: String) -> Int {
    let components = source.components(separatedBy: .whitespacesAndNewlines)
    let wordCount = components.filter { !$0.isEmpty }.count
    
    return wordCount
}

func getPrevChapterVerses(verseId: Int, verses: RealmSwift.List<Verse>) -> Results<Verse> {
    let (_, currentChapter, currentBook) = splitVerseId(verseId)
    let firstChVerse = verses.filter("b == \(currentBook) && c == \(currentChapter)").first!
    let (_, prevChChapter, prevChBook) = splitVerseId(getPrevVerse(verseId: firstChVerse.id, verses: verses))

    return verses.filter("b == \(prevChBook) && c == \(prevChChapter)")
}

func getPrevVerse(verseId: Int, verses: RealmSwift.List<Verse>) -> Int {
    let currentIndex = verses.index(of: verses.filter("id == \(verseId)").first!)!
    let prevIndex = currentIndex - 1 >= verses.indices.first! ? currentIndex - 1 : currentIndex
    
    return verses[prevIndex].id
}

func getNextChapterVerses(verseId: Int, verses: RealmSwift.List<Verse>) -> Results<Verse> {
    let (_, currentChapter, currentBook) = splitVerseId(verseId)
    let lastChVerse = verses.filter("b == \(currentBook) && c == \(currentChapter)").last!
    let (_, nextChChapter, nextChBook) = splitVerseId(getNextVerse(verseId: lastChVerse.id, verses: verses))

    return verses.filter("b == \(nextChBook) && c == \(nextChChapter)")
}

func getNextVerse(verseId: Int, verses: RealmSwift.List<Verse>) -> Int {
    let currentIndex = verses.index(of: verses.filter("id == \(verseId)").first!)!
    let nextIndex = currentIndex + 1 <= verses.indices.last! ? currentIndex + 1 : currentIndex
    
    return verses[nextIndex].id
}

func splitVerseId(_ number: Int) -> (Int, Int, Int) {
    let verse = number % 1000
    let chapter = (number / 1000) % 1000
    let book = number / 1000000
    
    return (verse, chapter, book)
}
