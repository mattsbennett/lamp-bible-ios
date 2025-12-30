//
//  NavigationHistory.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import Foundation
import SwiftUI

/// Manages navigation history for the Bible reader, tracking visited chapters and verse positions
class NavigationHistory: ObservableObject {
    static let shared = NavigationHistory()

    /// Maximum number of history entries to keep
    private let maxHistorySize = 50

    /// UserDefaults keys
    private let historyKey = "navigationHistory"
    private let indexKey = "navigationHistoryIndex"

    /// History stack - stores full verseIds (including verse position)
    @Published private(set) var history: [Int] = [] {
        didSet { saveToUserDefaults() }
    }

    /// Current position in history (index into history array)
    @Published private(set) var currentIndex: Int = -1 {
        didSet { saveToUserDefaults() }
    }

    /// Whether we can go back in history
    var canGoBack: Bool {
        currentIndex > 0
    }

    /// Whether we can go forward in history
    var canGoForward: Bool {
        currentIndex < history.count - 1
    }

    /// The current history entry
    var current: Int? {
        guard currentIndex >= 0 && currentIndex < history.count else { return nil }
        return history[currentIndex]
    }

    private init() {
        loadFromUserDefaults()
    }

    private func saveToUserDefaults() {
        UserDefaults.standard.set(history, forKey: historyKey)
        UserDefaults.standard.set(currentIndex, forKey: indexKey)
    }

    private func loadFromUserDefaults() {
        if let savedHistory = UserDefaults.standard.array(forKey: historyKey) as? [Int] {
            history = savedHistory
        }
        currentIndex = UserDefaults.standard.integer(forKey: indexKey)
        // Validate currentIndex
        if currentIndex >= history.count {
            currentIndex = history.count - 1
        }
    }

    /// Update the current history entry with the latest verse position
    /// Call this before navigating away to preserve scroll position
    /// - Parameter verseId: The current visible verseId
    func updateCurrentPosition(to verseId: Int) {
        guard currentIndex >= 0 && currentIndex < history.count else { return }

        // Only update if we're in the same chapter (don't change chapters)
        let (_, currentChapter, currentBook) = splitVerseId(history[currentIndex])
        let (_, newChapter, newBook) = splitVerseId(verseId)

        if currentBook == newBook && currentChapter == newChapter {
            history[currentIndex] = verseId
        }
    }

    /// Record a navigation to a new chapter
    /// - Parameter verseId: The verseId being navigated to
    /// - Parameter isHistoryNavigation: True if this navigation came from going back/forward in history
    func recordNavigation(to verseId: Int, isHistoryNavigation: Bool = false) {
        let (_, chapter, book) = splitVerseId(verseId)

        // Don't record if this is a history navigation
        if isHistoryNavigation {
            return
        }

        // Don't record if we're navigating to the same chapter
        if let currentEntry = current {
            let (_, currentChapter, currentBook) = splitVerseId(currentEntry)
            if book == currentBook && chapter == currentChapter {
                return
            }
        }

        // If we're not at the end of history, truncate forward history
        if currentIndex < history.count - 1 {
            history = Array(history.prefix(currentIndex + 1))
        }

        // Add new entry with full verseId (preserving verse position)
        history.append(verseId)
        currentIndex = history.count - 1

        // Trim if exceeds max size
        if history.count > maxHistorySize {
            let excess = history.count - maxHistorySize
            history.removeFirst(excess)
            currentIndex -= excess
        }
    }

    /// Go back in history
    /// - Parameter currentVerseId: The current visible verseId to save before going back
    /// - Returns: The verseId to navigate to, or nil if can't go back
    func goBack(savingPosition currentVerseId: Int? = nil) -> Int? {
        guard canGoBack else { return nil }

        // Save current position before navigating
        if let verseId = currentVerseId {
            updateCurrentPosition(to: verseId)
        }

        currentIndex -= 1
        return history[currentIndex]
    }

    /// Go forward in history
    /// - Parameter currentVerseId: The current visible verseId to save before going forward
    /// - Returns: The verseId to navigate to, or nil if can't go forward
    func goForward(savingPosition currentVerseId: Int? = nil) -> Int? {
        guard canGoForward else { return nil }

        // Save current position before navigating
        if let verseId = currentVerseId {
            updateCurrentPosition(to: verseId)
        }

        currentIndex += 1
        return history[currentIndex]
    }

    /// Clear all history
    func clear() {
        history = []
        currentIndex = -1
    }

    /// Navigate to a specific index in history
    /// - Parameter index: The index to navigate to
    /// - Parameter currentVerseId: The current visible verseId to save before navigating
    /// - Returns: The verseId to navigate to, or nil if index is invalid
    func goToIndex(_ index: Int, savingPosition currentVerseId: Int? = nil) -> Int? {
        guard index >= 0 && index < history.count else { return nil }

        // Save current position before navigating
        if let verseId = currentVerseId {
            updateCurrentPosition(to: verseId)
        }

        currentIndex = index
        return history[currentIndex]
    }

    /// Get all history entries with their descriptions
    /// - Returns: Array of (index, verseId, description) tuples
    func allHistory() -> [(index: Int, verseId: Int, description: String)] {
        return history.enumerated().compactMap { index, verseId in
            let (_, chapter, book) = splitVerseId(verseId)

            if let bookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first {
                return (index, verseId, "\(bookObj.name) \(chapter)")
            }
            return nil
        }
    }

    /// Get recent history entries (for display in a menu)
    /// - Parameter count: Maximum number of entries to return
    /// - Returns: Array of (verseId, description) tuples, most recent first
    func recentHistory(count: Int = 10) -> [(verseId: Int, description: String)] {
        let startIndex = max(0, currentIndex - count)
        let endIndex = currentIndex

        guard startIndex < endIndex else { return [] }

        return (startIndex..<endIndex).reversed().compactMap { index in
            let verseId = history[index]
            let (_, chapter, book) = splitVerseId(verseId)

            if let bookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first {
                return (verseId, "\(bookObj.name) \(chapter)")
            }
            return nil
        }
    }
}
