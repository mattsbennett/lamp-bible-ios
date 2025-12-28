//
//  ICloudNoteStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import RealmSwift

class ICloudNoteStorage: NoteStorage {
    static let shared = ICloudNoteStorage()

    private let fileManager = FileManager.default
    private let notesDirectoryName = "BibleNotes"

    // Cache for book name lookups
    private var bookNameCache: [Int: String] = [:]
    private var bookIdCache: [String: Int] = [:]

    private init() {
        // Pre-populate book name caches
        let realm = RealmManager.shared.realm
        for book in realm.objects(Book.self) {
            let lowercaseName = book.name.lowercased().replacingOccurrences(of: " ", with: "-")
            bookNameCache[book.id] = lowercaseName
            bookIdCache[lowercaseName] = book.id
        }
    }

    // MARK: - Container URL

    private let containerIdentifier = "iCloud.com.neus.lamp-bible"

    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private var notesDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        // Write directly to Documents folder (no subfolder) to simplify iCloud sync
        return container.appendingPathComponent("Documents")
    }

    // MARK: - NoteStorage Protocol

    func isAvailable() async -> Bool {
        let hasToken = fileManager.ubiquityIdentityToken != nil
        let hasContainer = containerURL != nil
        print("[iCloud] isAvailable check - token: \(hasToken), container: \(hasContainer)")
        if let url = containerURL {
            print("[iCloud] Container URL: \(url.path)")
        }
        if let notesDir = notesDirectoryURL {
            print("[iCloud] Notes directory URL: \(notesDir.path)")
        }
        return hasToken && hasContainer
    }

    func readNote(book: Int, chapter: Int) async throws -> Note? {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        let fileURL = notesDir.appendingPathComponent(fileName(book: book, chapter: chapter))

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var didResume = false

            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinatorError) { url in
                guard !didResume else { return }
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let note = try NoteParser.parse(content: content, book: book, chapter: chapter)
                    didResume = true
                    continuation.resume(returning: note)
                } catch {
                    didResume = true
                    continuation.resume(throwing: NoteStorageError.readFailed(underlying: error))
                }
            }

            if let error = coordinatorError, !didResume {
                didResume = true
                continuation.resume(throwing: NoteStorageError.readFailed(underlying: error))
            }
        }
    }

    func writeNote(_ note: Note) async throws -> WriteResult {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        // Check for conflicts before writing
        let conflicts = try await checkForConflicts(book: note.book, chapter: note.chapter)
        if let conflict = conflicts.first {
            return .conflict(conflict)
        }

        // Ensure notes directory exists
        try await ensureNotesDirectoryExists()

        let destURL = notesDir.appendingPathComponent(fileName(book: note.book, chapter: note.chapter))
        let bookNameStr = bookName(for: note.book)
        let content = NoteParser.serialize(note: note, bookName: bookNameStr)

        print("[iCloud] Writing note to: \(destURL.path)")

        // Check if file already exists in iCloud
        let fileExists = fileManager.fileExists(atPath: destURL.path)

        if fileExists {
            // Update existing file using coordinator
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var didResume = false

                coordinator.coordinate(writingItemAt: destURL, options: .forReplacing, error: &coordinatorError) { url in
                    guard !didResume else { return }
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        print("[iCloud] Successfully updated file at: \(url.path)")

                        // Check upload status
                        do {
                            let resourceValues = try destURL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey])
                            print("[iCloud] Upload status - uploaded: \(resourceValues.ubiquitousItemIsUploaded ?? false), uploading: \(resourceValues.ubiquitousItemIsUploading ?? false)")
                            if let error = resourceValues.ubiquitousItemUploadingError {
                                print("[iCloud] Upload error: \(error)")
                            }
                        } catch {
                            print("[iCloud] Could not get resource values: \(error)")
                        }

                        didResume = true
                        continuation.resume()
                    } catch {
                        print("[iCloud] Write error: \(error)")
                        didResume = true
                        continuation.resume(throwing: NoteStorageError.writeFailed(underlying: error))
                    }
                }

                if let error = coordinatorError, !didResume {
                    print("[iCloud] Coordinator error: \(error)")
                    didResume = true
                    continuation.resume(throwing: NoteStorageError.writeFailed(underlying: error))
                }
            }
        } else {
            // Create new file: write to temp location, then use setUbiquitous
            let tempDir = fileManager.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(fileName(book: note.book, chapter: note.chapter))

            do {
                // Clean up any existing temp file first
                if fileManager.fileExists(atPath: tempURL.path) {
                    try? fileManager.removeItem(at: tempURL)
                }

                // Write to temp file first
                try content.write(to: tempURL, atomically: true, encoding: .utf8)
                print("[iCloud] Wrote temp file at: \(tempURL.path)")
                print("[iCloud] Temp file size: \(try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] ?? 0)")

                // Move to iCloud using setUbiquitous
                print("[iCloud] Calling setUbiquitous to move to: \(destURL.path)")
                try fileManager.setUbiquitous(true, itemAt: tempURL, destinationURL: destURL)
                print("[iCloud] setUbiquitous completed successfully")

                // Verify file exists at destination and check upload status
                if fileManager.fileExists(atPath: destURL.path) {
                    print("[iCloud] Verified: file exists at destination")
                    // Check upload status
                    do {
                        let resourceValues = try destURL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey])
                        print("[iCloud] Upload status - uploaded: \(resourceValues.ubiquitousItemIsUploaded ?? false), uploading: \(resourceValues.ubiquitousItemIsUploading ?? false)")
                        if let error = resourceValues.ubiquitousItemUploadingError {
                            print("[iCloud] Upload error: \(error)")
                        }
                    } catch {
                        print("[iCloud] Could not get resource values: \(error)")
                    }
                } else {
                    print("[iCloud] Warning: file not found at destination after setUbiquitous")
                }
            } catch {
                // Clean up temp file if it exists
                try? fileManager.removeItem(at: tempURL)
                print("[iCloud] setUbiquitous error: \(error)")
                throw NoteStorageError.writeFailed(underlying: error)
            }
        }

        return .success
    }

    func deleteNote(book: Int, chapter: Int) async throws {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        let fileURL = notesDir.appendingPathComponent(fileName(book: book, chapter: chapter))

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return // Nothing to delete
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            var didResume = false

            coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinatorError) { url in
                guard !didResume else { return }
                do {
                    try self.fileManager.removeItem(at: url)
                    didResume = true
                    continuation.resume()
                } catch {
                    didResume = true
                    continuation.resume(throwing: NoteStorageError.deleteFailed(underlying: error))
                }
            }

            if let error = coordinatorError, !didResume {
                didResume = true
                continuation.resume(throwing: NoteStorageError.deleteFailed(underlying: error))
            }
        }
    }

    func listNotes() async throws -> [NoteReference] {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        guard fileManager.fileExists(atPath: notesDir.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.contentModificationDateKey])

        var references: [NoteReference] = []

        for file in files {
            guard file.pathExtension == "md" else { continue }

            let filename = file.lastPathComponent
            guard let (book, chapter) = parseFileName(filename) else {
                continue
            }

            let attributes = try? fileManager.attributesOfItem(atPath: file.path)
            let modified = attributes?[.modificationDate] as? Date ?? Date()

            references.append(NoteReference(book: book, chapter: chapter, modified: modified))
        }

        return references.sorted { ($0.book, $0.chapter) < ($1.book, $1.chapter) }
    }

    // MARK: - Book Name Helper

    func bookName(for bookId: Int) -> String {
        if let cached = bookNameCache[bookId] {
            return cached
        }
        // Fallback to realm lookup
        if let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(bookId)").first {
            let name = book.name.lowercased().replacingOccurrences(of: " ", with: "-")
            bookNameCache[bookId] = name
            return name
        }
        return "\(bookId)"
    }

    private func bookId(for name: String) -> Int? {
        let normalized = name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let cached = bookIdCache[normalized] {
            return cached
        }
        return nil
    }

    // MARK: - Helpers

    private func fileName(book: Int, chapter: Int) -> String {
        let name = bookName(for: book)
        return "\(name)-\(chapter).md"
    }

    /// Parse book and chapter from filename (e.g., "john-3.md" -> (43, 3))
    private func parseFileName(_ filename: String) -> (book: Int, chapter: Int)? {
        let name = filename.replacingOccurrences(of: ".md", with: "")

        // Find the last hyphen (chapter separator)
        guard let lastHyphenIndex = name.lastIndex(of: "-") else { return nil }

        let bookPart = String(name[..<lastHyphenIndex])
        let chapterPart = String(name[name.index(after: lastHyphenIndex)...])

        guard let chapter = Int(chapterPart) else { return nil }

        // Try to get book ID from name
        if let bookId = bookId(for: bookPart) {
            return (bookId, chapter)
        }

        // Fallback: try parsing as numeric book ID (for backwards compatibility)
        if let bookId = Int(bookPart) {
            return (bookId, chapter)
        }

        return nil
    }

    private func ensureNotesDirectoryExists() async throws {
        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        if !fileManager.fileExists(atPath: notesDir.path) {
            print("[iCloud] Creating Documents directory at: \(notesDir.path)")
            try fileManager.createDirectory(at: notesDir, withIntermediateDirectories: true)
            print("[iCloud] Documents directory created successfully")
        } else {
            print("[iCloud] Documents directory already exists at: \(notesDir.path)")
        }
    }

    /// Force iCloud to check for updates in the container
    func forceSync() async {
        guard let notesDir = notesDirectoryURL else { return }

        do {
            let files = try fileManager.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            for file in files {
                let resourceValues = try file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
                print("[iCloud] File: \(file.lastPathComponent) - uploaded: \(resourceValues.ubiquitousItemIsUploaded ?? false), uploading: \(resourceValues.ubiquitousItemIsUploading ?? false)")
            }
        } catch {
            print("[iCloud] forceSync error: \(error)")
        }
    }

    // MARK: - Locking

    func acquireLock(book: Int, chapter: Int) async throws -> LockResult {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        // Read current note to check lock status
        if let note = try await readNote(book: book, chapter: chapter) {
            if note.isLockedByOther {
                return .lockedByOther(lockedBy: note.lockedBy!, lockedAt: note.lockedAt!)
            }
            if note.isLockedByMe {
                // Refresh the lock
                try await refreshLock(book: book, chapter: chapter)
                return .alreadyLockedByMe
            }
        }

        // Acquire lock by writing note with lock fields
        var note = try await readNote(book: book, chapter: chapter) ?? Note(book: book, chapter: chapter)
        note.lockedBy = Note.deviceId
        note.lockedAt = Date()
        note.modified = Date()

        let _ = try await writeNoteInternal(note)

        // Verify we got the lock (race condition check)
        if let verifyNote = try await readNote(book: book, chapter: chapter) {
            if verifyNote.lockedBy == Note.deviceId {
                return .acquired
            } else if let lockedBy = verifyNote.lockedBy, let lockedAt = verifyNote.lockedAt {
                return .lockedByOther(lockedBy: lockedBy, lockedAt: lockedAt)
            }
        }

        return .acquired
    }

    func releaseLock(book: Int, chapter: Int) async throws {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard var note = try await readNote(book: book, chapter: chapter) else {
            return // No note to unlock
        }

        // Only release if we hold the lock
        if note.lockedBy == Note.deviceId {
            note.lockedBy = nil
            note.lockedAt = nil
            note.modified = Date()
            let _ = try await writeNoteInternal(note)
        }
    }

    func refreshLock(book: Int, chapter: Int) async throws {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard var note = try await readNote(book: book, chapter: chapter) else {
            return
        }

        // Only refresh if we hold the lock
        if note.lockedBy == Note.deviceId {
            note.lockedAt = Date()
            note.modified = Date()
            let _ = try await writeNoteInternal(note)
        }
    }

    /// Internal write that bypasses conflict check (used for lock operations)
    private func writeNoteInternal(_ note: Note) async throws {
        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        try await ensureNotesDirectoryExists()

        let destURL = notesDir.appendingPathComponent(fileName(book: note.book, chapter: note.chapter))
        let bookNameStr = bookName(for: note.book)
        let content = NoteParser.serialize(note: note, bookName: bookNameStr)

        let fileExists = fileManager.fileExists(atPath: destURL.path)

        if fileExists {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let coordinator = NSFileCoordinator()
                var coordinatorError: NSError?
                var didResume = false

                coordinator.coordinate(writingItemAt: destURL, options: .forReplacing, error: &coordinatorError) { url in
                    guard !didResume else { return }
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        didResume = true
                        continuation.resume()
                    } catch {
                        didResume = true
                        continuation.resume(throwing: NoteStorageError.writeFailed(underlying: error))
                    }
                }

                if let error = coordinatorError, !didResume {
                    didResume = true
                    continuation.resume(throwing: NoteStorageError.writeFailed(underlying: error))
                }
            }
        } else {
            let tempDir = fileManager.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(fileName(book: note.book, chapter: note.chapter))

            if fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }

            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            try fileManager.setUbiquitous(true, itemAt: tempURL, destinationURL: destURL)
        }
    }

    // MARK: - Conflict Detection and Resolution

    func checkForConflicts() async throws -> [NoteConflict] {
        guard await isAvailable() else {
            throw NoteStorageError.notAvailable
        }

        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        guard fileManager.fileExists(atPath: notesDir.path) else {
            return []
        }

        var conflicts: [NoteConflict] = []

        let files = try fileManager.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)

        for file in files {
            guard file.pathExtension == "md" else { continue }

            guard let (book, chapter) = parseFileName(file.lastPathComponent) else {
                continue
            }

            if let conflict = try await checkForConflicts(book: book, chapter: chapter).first {
                conflicts.append(conflict)
            }
        }

        return conflicts
    }

    /// Check for conflicts for a specific note
    private func checkForConflicts(book: Int, chapter: Int) async throws -> [NoteConflict] {
        guard let notesDir = notesDirectoryURL else {
            return []
        }

        let fileURL = notesDir.appendingPathComponent(fileName(book: book, chapter: chapter))

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        // Get conflict versions using NSFileVersion
        guard let currentVersion = NSFileVersion.currentVersionOfItem(at: fileURL) else {
            return []
        }

        let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []

        if conflictVersions.isEmpty {
            return []
        }

        // Build conflict object
        let currentNoteVersion = NoteVersion(
            id: currentVersion.persistentIdentifier as? String ?? "current",
            modified: currentVersion.modificationDate ?? Date(),
            contentLength: (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0,
            isCurrentVersion: true,
            content: { [fileURL] in
                try String(contentsOf: fileURL, encoding: .utf8)
            }
        )

        let conflictNoteVersions = conflictVersions.map { version in
            NoteVersion(
                id: version.persistentIdentifier as? String ?? UUID().uuidString,
                modified: version.modificationDate ?? Date(),
                contentLength: 0, // Can't easily get size of conflict version
                isCurrentVersion: false,
                content: {
                    return try String(contentsOf: version.url, encoding: .utf8)
                }
            )
        }

        let conflict = NoteConflict(
            id: "\(book)-\(chapter)",
            book: book,
            chapter: chapter,
            currentVersion: currentNoteVersion,
            conflictVersions: conflictNoteVersions
        )

        return [conflict]
    }

    func resolveConflict(_ conflict: NoteConflict, keepVersionId: String) async throws {
        guard let notesDir = notesDirectoryURL else {
            throw NoteStorageError.notConfigured
        }

        let fileURL = notesDir.appendingPathComponent(fileName(book: conflict.book, chapter: conflict.chapter))

        let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []

        // Find the version to keep
        let keepingCurrent = conflict.currentVersion.id == keepVersionId

        if !keepingCurrent {
            // User wants to keep a conflict version - replace current with it
            if let versionToKeep = conflictVersions.first(where: { ($0.persistentIdentifier as? String ?? UUID().uuidString) == keepVersionId }) {
                let versionURL = versionToKeep.url
                let content = try String(contentsOf: versionURL, encoding: .utf8)

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        let coordinator = NSFileCoordinator()
                        var coordinatorError: NSError?
                        var didResume = false

                        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinatorError) { url in
                            guard !didResume else { return }
                            do {
                                try content.write(to: url, atomically: true, encoding: .utf8)
                                didResume = true
                                continuation.resume()
                            } catch {
                                didResume = true
                                continuation.resume(throwing: error)
                            }
                        }

                        if let error = coordinatorError, !didResume {
                            didResume = true
                            continuation.resume(throwing: error)
                        }
                    }
            }
        }

        // Mark all conflict versions as resolved
        for version in conflictVersions {
            version.isResolved = true
        }

        // Remove old conflict versions
        try NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
    }
}
