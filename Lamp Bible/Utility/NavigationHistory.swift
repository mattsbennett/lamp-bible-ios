//
//  NavigationHistory.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-28.
//

import Foundation
import SwiftUI
import LampCore

/// Manages navigation history for the Bible reader, tracking visited chapters and verse positions
class NavigationHistory: ObservableObject {
    static let shared = NavigationHistory()

    /// Maximum number of history entries to keep
    private let maxHistorySize = 50

    /// UserDefaults keys
    private let historyKey = "navigationHistory"
    private let indexKey = "navigationHistoryIndex"

    /// Flag to prevent saving during loading
    private var isLoading = false

    /// History stack - stores full verseIds (including verse position)
    @Published private(set) var history: [Int] = [] {
        didSet { if !isLoading { saveToUserDefaults() } }
    }

    /// Current position in history (index into history array)
    @Published private(set) var currentIndex: Int = -1 {
        didSet { if !isLoading { saveToUserDefaults() } }
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

    private var timeline: LampNavigationTimeline<Int> {
        get { LampNavigationTimeline(entries: history, currentIndex: currentIndex, capacity: maxHistorySize) }
        set {
            history = newValue.entries
            currentIndex = newValue.currentIndex
        }
    }

    private func chapterIdentity(_ verseId: Int) -> AnyHashable {
        let (_, chapter, book) = splitVerseId(verseId)
        return AnyHashable("\(book):\(chapter)")
    }

    private init() {
        loadFromUserDefaults()
    }

    private func saveToUserDefaults() {
        UserDefaults.standard.set(history, forKey: historyKey)
        UserDefaults.standard.set(currentIndex, forKey: indexKey)
    }

    private func loadFromUserDefaults() {
        isLoading = true
        defer { isLoading = false }

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
        var updated = timeline
        updated.replaceCurrent(with: verseId) { chapterIdentity($0) == chapterIdentity($1) }
        timeline = updated
    }

    /// Record a navigation to a new chapter
    /// - Parameter verseId: The verseId being navigated to
    /// - Parameter isHistoryNavigation: True if this navigation came from going back/forward in history
    func recordNavigation(to verseId: Int, isHistoryNavigation: Bool = false) {
        guard !isHistoryNavigation else { return }
        var updated = timeline
        updated.visit(verseId, identity: chapterIdentity, preserveForwardForExistingIdentity: true)
        timeline = updated
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

        var updated = timeline
        let destination = updated.goBack()
        timeline = updated
        return destination
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

        var updated = timeline
        let destination = updated.goForward()
        timeline = updated
        return destination
    }

    /// Clear all history
    func clear() {
        var updated = timeline
        updated.clear()
        timeline = updated
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

        var updated = timeline
        let destination = updated.goToIndex(index)
        timeline = updated
        return destination
    }

    /// Get all history entries with their descriptions
    /// - Returns: Array of (index, verseId, description) tuples
    func allHistory() -> [(index: Int, verseId: Int, description: String)] {
        return history.enumerated().compactMap { index, verseId in
            let (verse, chapter, book) = splitVerseId(verseId)

            if let bookObj = try? BundledModuleDatabase.shared.getBook(id: book) {
                return (index, verseId, "\(bookObj.name) \(chapter):\(verse)")
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
            let (verse, chapter, book) = splitVerseId(verseId)

            if let bookObj = try? BundledModuleDatabase.shared.getBook(id: book) {
                return (verseId, "\(bookObj.name) \(chapter):\(verse)")
            }
            return nil
        }
    }
}
