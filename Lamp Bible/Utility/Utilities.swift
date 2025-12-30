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

func getPrevBookVerses(verseId: Int, verses: RealmSwift.List<Verse>) -> Results<Verse> {
    let (_, _, currentBook) = splitVerseId(verseId)
    // Find the first verse of the previous book
    if let firstVerseOfPrevBook = verses.filter("b < \(currentBook)").last {
        let (_, _, prevBook) = splitVerseId(firstVerseOfPrevBook.id)
        // Return chapter 1 of the previous book
        return verses.filter("b == \(prevBook) && c == 1")
    }
    // If no previous book, stay on current
    return verses.filter("id == \(verseId)")
}

func getNextBookVerses(verseId: Int, verses: RealmSwift.List<Verse>) -> Results<Verse> {
    let (_, _, currentBook) = splitVerseId(verseId)
    // Find the first verse of the next book
    if let firstVerseOfNextBook = verses.filter("b > \(currentBook)").first {
        let (_, _, nextBook) = splitVerseId(firstVerseOfNextBook.id)
        // Return chapter 1 of the next book
        return verses.filter("b == \(nextBook) && c == 1")
    }
    // If no next book, stay on current
    return verses.filter("id == \(verseId)")
}
