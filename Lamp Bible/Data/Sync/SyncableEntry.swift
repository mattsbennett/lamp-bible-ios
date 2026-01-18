//
//  SyncableEntry.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation

// MARK: - Syncable Entry Protocol

/// Protocol for entries that can be synced via CloudKit or WebDAV.
/// Both NoteEntry and DevotionalEntry conform to this protocol.
protocol SyncableEntry: Identifiable, Codable {
    /// The type of entry (note or devotional)
    static var entryType: SyncableEntryType { get }

    /// Unique identifier for this entry
    var id: String { get }

    /// The module this entry belongs to
    var moduleId: String { get }

    /// Unix timestamp of last modification (optional for backward compatibility)
    var lastModified: Int? { get set }

    /// CloudKit record change tag for optimistic locking.
    /// This is updated when the record is saved to CloudKit.
    var recordChangeTag: String? { get set }
}

// MARK: - SyncableEntry Extensions

extension SyncableEntry {
    /// Get last modified as Date
    var lastModifiedDate: Date? {
        guard let timestamp = lastModified else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Set last modified from Date
    mutating func setLastModified(_ date: Date) {
        lastModified = Int(date.timeIntervalSince1970)
    }

    /// Update lastModified to current time
    mutating func touch() {
        lastModified = Int(Date().timeIntervalSince1970)
    }
}

// MARK: - NoteEntry Conformance

extension NoteEntry: SyncableEntry {
    static var entryType: SyncableEntryType { .note }
    // lastModified and recordChangeTag are defined in ModuleModels.swift
}

// MARK: - DevotionalEntry Conformance

extension DevotionalEntry: SyncableEntry {
    static var entryType: SyncableEntryType { .devotional }
    // lastModified and recordChangeTag are defined in DevotionalModels.swift
}
