//
//  NoteStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation

// MARK: - Note Section Model

/// A section of notes within a chapter (introduction, verse-specific, or verse range)
struct NoteSection: Identifiable {
    let id: String  // "general" or "v3" or "v16-17"
    let verseStart: Int?
    let verseEnd: Int?
    var content: String
    var footnotes: [UserNotesFootnote]?  // Optional footnotes for this section

    var displayTitle: String {
        if let start = verseStart {
            if let end = verseEnd, end != start {
                return "vv.\(start)-\(end)"
            }
            return "v.\(start)"
        }
        return "General Notes"
    }

    var isGeneral: Bool {
        verseStart == nil
    }

    /// Check if this section has any footnotes
    var hasFootnotes: Bool {
        guard let notes = footnotes else { return false }
        return !notes.isEmpty
    }

    static func general(content: String, footnotes: [UserNotesFootnote]? = nil) -> NoteSection {
        NoteSection(id: "general", verseStart: nil, verseEnd: nil, content: content, footnotes: footnotes)
    }

    static func verse(_ verse: Int, content: String, footnotes: [UserNotesFootnote]? = nil) -> NoteSection {
        NoteSection(id: "v\(verse)", verseStart: verse, verseEnd: verse, content: content, footnotes: footnotes)
    }

    static func verseRange(start: Int, end: Int, content: String, footnotes: [UserNotesFootnote]? = nil) -> NoteSection {
        NoteSection(id: "v\(start)-\(end)", verseStart: start, verseEnd: end, content: content, footnotes: footnotes)
    }
}

// MARK: - Verse Action

/// Actions available when selecting a verse
enum VerseAction {
    case addNote
}

// MARK: - Save State

/// Tracks the current save state for note editing
enum SaveState: Equatable {
    case idle
    case saving
    case saved
    case error(String)
}

// MARK: - Note Sync Conflict

/// Represents a conflict between local and cloud versions of a note entry
struct NoteConflict: Identifiable {
    let id: String  // verseId as string
    let verseId: Int
    let localEntry: NoteEntry
    let cloudEntry: NoteEntry

    /// Human-readable location (e.g., "Genesis 1:5")
    var locationDescription: String {
        let book = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        let bookName = (try? BundledModuleDatabase.shared.getBook(id: book))?.name ?? "Book \(book)"

        if verse == 0 {
            return "\(bookName) \(chapter) - Introduction"
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    /// Local modification date
    var localDate: Date? {
        guard let ts = localEntry.lastModified else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Cloud modification date
    var cloudDate: Date? {
        guard let ts = cloudEntry.lastModified else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
}

/// Result of a sync merge operation
struct NoteSyncMergeResult {
    /// Entries to save to local database (merged result)
    var entriesToSave: [NoteEntry]
    /// Entries that had conflicts requiring user resolution
    var conflicts: [NoteConflict]
    /// Count of entries auto-merged from cloud
    var cloudMergeCount: Int
    /// Count of entries kept from local (newer than cloud)
    var localKeptCount: Int
}

/// User's resolution choice for a conflict
enum ConflictResolution {
    case keepLocal
    case keepCloud
    case keepBoth
}
