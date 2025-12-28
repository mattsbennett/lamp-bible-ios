//
//  NoteStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import UIKit

// MARK: - Models

struct Note: Equatable {
    let book: Int
    let chapter: Int
    var content: String
    let created: Date
    var modified: Date
    var lockedBy: String?
    var lockedAt: Date?
    var contentLength: Int

    init(book: Int, chapter: Int, content: String = "", created: Date = Date(), modified: Date = Date(), lockedBy: String? = nil, lockedAt: Date? = nil) {
        self.book = book
        self.chapter = chapter
        self.content = content
        self.created = created
        self.modified = modified
        self.lockedBy = lockedBy
        self.lockedAt = lockedAt
        self.contentLength = content.utf8.count
    }

    /// Check if the note is currently locked by another device
    var isLockedByOther: Bool {
        guard let lockedBy = lockedBy, let lockedAt = lockedAt else { return false }
        let lockTimeout: TimeInterval = 5 * 60 // 5 minutes
        let isStale = Date().timeIntervalSince(lockedAt) > lockTimeout
        return !isStale && lockedBy != Note.deviceId
    }

    /// Check if the note is locked by this device
    var isLockedByMe: Bool {
        return lockedBy == Note.deviceId
    }

    /// Get a unique device identifier
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "noteDeviceId") {
            return id
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "noteDeviceId")
        return id
    }
}

struct NoteReference: Identifiable {
    let book: Int
    let chapter: Int
    let modified: Date

    var id: String { "\(book)-\(chapter)" }
}

struct NoteSection: Identifiable {
    let id: String  // "general" or "v3" or "v16-17"
    let verseStart: Int?
    let verseEnd: Int?
    var content: String

    var displayTitle: String {
        if let start = verseStart {
            if let end = verseEnd, end != start {
                return "Verses \(start)-\(end)"
            }
            return "Verse \(start)"
        }
        return ""
    }

    var isGeneral: Bool {
        verseStart == nil
    }

    static func general(content: String) -> NoteSection {
        NoteSection(id: "general", verseStart: nil, verseEnd: nil, content: content)
    }

    static func verse(_ verse: Int, content: String) -> NoteSection {
        NoteSection(id: "v\(verse)", verseStart: verse, verseEnd: verse, content: content)
    }

    static func verseRange(start: Int, end: Int, content: String) -> NoteSection {
        NoteSection(id: "v\(start)-\(end)", verseStart: start, verseEnd: end, content: content)
    }
}

enum VerseAction {
    case addNote
    case viewCrossReferences
}

enum NoteStorageError: LocalizedError {
    case notAvailable
    case notConfigured
    case readFailed(underlying: Error?)
    case writeFailed(underlying: Error?)
    case deleteFailed(underlying: Error?)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Note storage is not available. Please sign in to iCloud."
        case .notConfigured:
            return "Note storage has not been configured."
        case .readFailed(let error):
            return "Failed to read note: \(error?.localizedDescription ?? "Unknown error")"
        case .writeFailed(let error):
            return "Failed to save note: \(error?.localizedDescription ?? "Unknown error")"
        case .deleteFailed(let error):
            return "Failed to delete note: \(error?.localizedDescription ?? "Unknown error")"
        case .parseError(let message):
            return "Failed to parse note: \(message)"
        }
    }
}

enum SaveState: Equatable {
    case idle
    case saving
    case saved
    case error(String)
}

// MARK: - Locking Types

enum LockResult {
    case acquired
    case alreadyLockedByMe
    case lockedByOther(lockedBy: String, lockedAt: Date)
}

enum LockAction {
    case viewReadOnly
    case editAnyway
    case cancel
}

// MARK: - Conflict Types

struct NoteVersion: Identifiable {
    let id: String  // Version identifier (e.g., file URL or version ID)
    let modified: Date
    let contentLength: Int
    let isCurrentVersion: Bool
    let content: () async throws -> String  // Lazy load

    static func == (lhs: NoteVersion, rhs: NoteVersion) -> Bool {
        lhs.id == rhs.id
    }
}

struct NoteConflict: Identifiable {
    let id: String
    let book: Int
    let chapter: Int
    let currentVersion: NoteVersion
    let conflictVersions: [NoteVersion]
}

enum WriteResult {
    case success
    case conflict(NoteConflict)
    case lockedByOther(lockedBy: String, lockedAt: Date)
}

// MARK: - Protocol

protocol NoteStorage {
    /// Check if the storage backend is available
    func isAvailable() async -> Bool

    /// Read a note for a specific chapter
    func readNote(book: Int, chapter: Int) async throws -> Note?

    /// Write a note (creates or updates)
    func writeNote(_ note: Note) async throws -> WriteResult

    /// Delete a note for a specific chapter
    func deleteNote(book: Int, chapter: Int) async throws

    /// List all notes
    func listNotes() async throws -> [NoteReference]

    /// Check if a note exists for a specific chapter
    func noteExists(book: Int, chapter: Int) async -> Bool

    // MARK: - Locking

    /// Attempt to acquire a lock on a note for editing
    func acquireLock(book: Int, chapter: Int) async throws -> LockResult

    /// Release a lock on a note
    func releaseLock(book: Int, chapter: Int) async throws

    /// Refresh the lock timestamp (call periodically while editing)
    func refreshLock(book: Int, chapter: Int) async throws

    // MARK: - Conflict Resolution

    /// Check for any conflicts in the storage
    func checkForConflicts() async throws -> [NoteConflict]

    /// Resolve a conflict by keeping the specified version
    func resolveConflict(_ conflict: NoteConflict, keepVersionId: String) async throws

    /// Get the book name for a given book ID (for filename generation)
    func bookName(for bookId: Int) -> String
}

extension NoteStorage {
    func noteExists(book: Int, chapter: Int) async -> Bool {
        do {
            return try await readNote(book: book, chapter: chapter) != nil
        } catch {
            return false
        }
    }
}
