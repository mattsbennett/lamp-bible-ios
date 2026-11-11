//
//  NoteStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import LampCore
import LampModuleKit

// MARK: - Note Media

/// A note's pictures. Kept as the Mac keeps them, in a folder named for the
/// note's verse rather than its id: a module holds one note a verse, and
/// the id's colon has no place in a path. The folder is the path the
/// pictures sync under, NoteMedia/<module>/<verse>/<file>.
enum NoteMedia {
    static func owner(_ verseId: Int) -> String {
        LampLibrary.noteMediaOwnerID(verseId)
    }

    static func url(for ref: DevotionalMediaReference, moduleId: String, verseId: Int) -> URL? {
        DevotionalMediaStorage.notes.getMediaURL(for: ref, devotionalId: owner(verseId), moduleId: moduleId)
    }

    static func expectedURL(for ref: DevotionalMediaReference, moduleId: String, verseId: Int) -> URL {
        DevotionalMediaStorage.notes.expectedMediaURL(for: ref, devotionalId: owner(verseId), moduleId: moduleId)
    }

    /// Where each of a note's pictures is, by id, for the editor and the
    /// note as drawn. A picture not on this device yet is left out.
    static func map(_ mediaJson: String?, moduleId: String, verseId: Int) -> [String: URL] {
        var map: [String: URL] = [:]
        for ref in LampPortableBookJSON.decodeArray(mediaJson, as: DevotionalMediaReference.self).items {
            if let url = url(for: ref, moduleId: moduleId, verseId: verseId) { map[ref.id] = url }
        }
        return map
    }

    /// The note's list with one more picture. Every entry already there is
    /// kept whole, including fields this version doesn't know.
    static func appending(_ ref: DevotionalMediaReference, to mediaJson: String?) throws -> String {
        var list = mediaJson
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
        list.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ref)))
        return String(decoding: try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]), as: UTF8.self)
    }

    /// A note moved to another verse takes its pictures with it, since the
    /// folder is named for the verse.
    static func move(moduleId: String, from oldVerseId: Int, to newVerseId: Int) throws {
        guard oldVerseId != newVerseId else { return }
        let storage = DevotionalMediaStorage.notes
        let source = storage.mediaDirectory(devotionalId: owner(oldVerseId), moduleId: moduleId)
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        try storage.ensureMediaDirectory(devotionalId: owner(newVerseId), moduleId: moduleId)
        let destination = storage.mediaDirectory(devotionalId: owner(newVerseId), moduleId: moduleId)
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: file, to: target)
        }
        try? manager.removeItem(at: source)
    }
}

// MARK: - Note Section Model

/// A section of notes within a chapter (introduction, verse-specific, or verse range)
struct NoteSection: Identifiable {
    let id: String  // "general" or "v3" or "v16-17"
    let verseStart: Int?
    let verseEnd: Int?
    var content: String
    var footnotes: [UserNotesFootnote]?  // Optional footnotes for this section
    /// The note's pictures as stored, carried from load to save: the chapter
    /// is saved by writing its notes again, so a note that dropped this
    /// would lose its pictures at the next keystroke.
    var mediaJson: String? = nil

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

    static func general(content: String, footnotes: [UserNotesFootnote]? = nil, mediaJson: String? = nil) -> NoteSection {
        NoteSection(id: "general", verseStart: nil, verseEnd: nil, content: content, footnotes: footnotes, mediaJson: mediaJson)
    }

    static func verse(_ verse: Int, content: String, footnotes: [UserNotesFootnote]? = nil, mediaJson: String? = nil) -> NoteSection {
        NoteSection(id: "v\(verse)", verseStart: verse, verseEnd: verse, content: content, footnotes: footnotes, mediaJson: mediaJson)
    }

    static func verseRange(start: Int, end: Int, content: String, footnotes: [UserNotesFootnote]? = nil, mediaJson: String? = nil) -> NoteSection {
        NoteSection(id: "v\(start)-\(end)", verseStart: start, verseEnd: end, content: content, footnotes: footnotes, mediaJson: mediaJson)
    }
}

extension NoteSection {
    /// The section an ID names: "general", "v3" or "v16-17".
    init?(id: String, content: String, footnotes: [UserNotesFootnote]? = nil) {
        if id == "general" {
            self = .general(content: content, footnotes: footnotes)
            return
        }
        guard id.hasPrefix("v") else { return nil }
        let verses = id.dropFirst().split(separator: "-").compactMap { Int($0) }
        switch verses.count {
        case 1: self = .verse(verses[0], content: content, footnotes: footnotes)
        case 2: self = .verseRange(start: verses[0], end: verses[1], content: content, footnotes: footnotes)
        default: return nil
        }
    }
}

// MARK: - Verse Action

/// Actions available when selecting a verse
enum VerseAction {
    case addNote
    case highlight
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
struct NoteConflict: Codable, Identifiable {
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
    /// Copies dropped because they predate a recorded deletion.
    var deletedCount = 0
    /// The server copy differs from what this device now holds.
    var needsPublish: Bool { localKeptCount > 0 || deletedCount > 0 }
}

/// User's resolution choice for a conflict
enum ConflictResolution {
    case keepLocal
    case keepCloud
    case keepBoth
}
