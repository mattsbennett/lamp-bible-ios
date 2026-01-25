//
//  HighlightManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import Foundation
import SwiftUI
import Combine

/// Observable manager for Bible text highlighting
@MainActor
class HighlightManager: ObservableObject {
    static let shared = HighlightManager()

    // MARK: - Published State

    /// Whether highlights are hidden in the reader
    @Published var highlightsHidden: Bool = UserDefaults.standard.bool(forKey: "highlightsHidden") {
        didSet {
            UserDefaults.standard.set(highlightsHidden, forKey: "highlightsHidden")
        }
    }

    /// Whether highlight mode is active (user is selecting text to highlight)
    @Published var isHighlightModeActive: Bool = false

    /// The currently active highlight set ID
    @Published var activeSetId: String?

    /// The currently selected color for new highlights
    @Published var selectedColor: HighlightColor = .yellow

    /// The currently selected style for new highlights
    @Published var selectedStyle: HighlightStyle = .highlight

    /// Cached highlights by verse ref (for current chapter)
    @Published private(set) var highlightsByVerse: [Int: [HighlightEntry]] = [:]

    /// Current translation ID (to filter highlight sets)
    @Published var currentTranslationId: String?

    /// All highlight sets for current translation
    @Published private(set) var availableSets: [HighlightSet] = []

    // MARK: - Private State

    private var cachedBook: Int = 0
    private var cachedChapter: Int = 0
    private var syncWorkItem: DispatchWorkItem?
    private let syncDebounceInterval: TimeInterval = 2.0  // Wait 2 seconds before syncing

    // MARK: - Initialization

    private init() {
        // Load saved preferences
        loadPreferences()
    }

    // MARK: - Sync

    /// Schedule a debounced sync for the active highlight set's module
    private func scheduleSyncForActiveSet() {
        guard let setId = activeSetId else { return }

        // Get the module ID for the active set
        guard let set = try? ModuleDatabase.shared.getHighlightSet(id: setId) else { return }

        // Cancel any pending sync
        syncWorkItem?.cancel()

        // Schedule new sync
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performSync(moduleId: set.moduleId)
            }
        }
        syncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + syncDebounceInterval, execute: workItem)
    }

    /// Perform the actual sync
    private func performSync(moduleId: String) {
        Task {
            do {
                try await ModuleSyncManager.shared.exportModule(id: moduleId)
                print("[HighlightManager] Synced highlights module: \(moduleId)")
            } catch {
                print("[HighlightManager] Failed to sync highlights: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Load highlight sets for a translation
    func loadSetsForTranslation(_ translationId: String) {
        currentTranslationId = translationId

        do {
            availableSets = try ModuleDatabase.shared.getHighlightSets(forTranslation: translationId)

            // If no active set or active set doesn't belong to this translation, select first
            if let activeId = activeSetId {
                if !availableSets.contains(where: { $0.id == activeId }) {
                    activeSetId = availableSets.first?.id
                }
            } else {
                activeSetId = availableSets.first?.id
            }
        } catch {
            print("[HighlightManager] Error loading highlight sets: \(error)")
            availableSets = []
            activeSetId = nil
        }
    }

    /// Create a new highlight set for the current translation
    /// - Parameters:
    ///   - name: Optional name for the set. If nil, defaults to "My [ABBREV] Highlights"
    ///   - description: Optional description
    func createHighlightSet(name: String? = nil, description: String? = nil) throws -> HighlightSet {
        guard let translationId = currentTranslationId else {
            throw HighlightError.noTranslationSelected
        }

        // Get translation abbreviation for readable module ID and default name
        let translationAbbrev: String
        let translationAbbrevUpper: String
        if let translation = try? TranslationDatabase.shared.getTranslation(id: translationId) {
            translationAbbrev = translation.abbreviation.lowercased()
            translationAbbrevUpper = translation.abbreviation.uppercased()
        } else {
            translationAbbrev = translationId.lowercased()
            translationAbbrevUpper = translationId.uppercased()
        }

        // Use provided name or generate default with translation abbreviation
        let setName = name ?? "My \(translationAbbrevUpper) Highlights"

        // Create module ID like "kjv-highlights" or "kjv-highlights-2" if one exists
        var moduleId = "\(translationAbbrev)-highlights"
        var counter = 1
        while (try? ModuleDatabase.shared.getModule(id: moduleId)) != nil {
            counter += 1
            moduleId = "\(translationAbbrev)-highlights-\(counter)"
        }

        let now = Int(Date().timeIntervalSince1970)

        let module = Module(
            id: moduleId,
            type: .highlights,
            name: setName,
            description: description,
            author: nil,
            version: nil,
            filePath: "\(moduleId).lamp",
            fileHash: nil,
            lastSynced: nil,
            isEditable: true,
            keyType: nil,
            seriesFull: nil,
            seriesAbbrev: nil,
            seriesId: nil,
            createdAt: now,
            updatedAt: now
        )

        try ModuleDatabase.shared.saveModule(module)

        // Create highlight set
        let set = HighlightSet(
            id: UUID().uuidString,
            moduleId: moduleId,
            name: setName,
            description: description,
            translationId: translationId,
            created: now,
            lastModified: now
        )

        try ModuleDatabase.shared.saveHighlightSet(set)

        // Refresh available sets
        loadSetsForTranslation(translationId)

        // Set as active
        activeSetId = set.id
        savePreferences()

        // Sync the new module to cloud
        Task {
            do {
                try await ModuleSyncManager.shared.exportModule(id: moduleId)
                print("[HighlightManager] Synced new highlights module: \(moduleId)")
            } catch {
                print("[HighlightManager] Failed to sync new highlights module: \(error)")
            }
        }

        return set
    }

    /// Delete a highlight set
    func deleteHighlightSet(id: String) throws {
        guard let set = try ModuleDatabase.shared.getHighlightSet(id: id) else {
            return
        }

        // Delete the module (cascade will delete set and highlights)
        try ModuleDatabase.shared.deleteModule(id: set.moduleId)

        // Refresh available sets
        if let translationId = currentTranslationId {
            loadSetsForTranslation(translationId)
        }

        // If deleted set was active, select another
        if activeSetId == id {
            activeSetId = availableSets.first?.id
            savePreferences()
        }
    }

    /// Load highlights for a chapter
    func loadHighlightsForChapter(book: Int, chapter: Int) {
        guard let setId = activeSetId else {
            highlightsByVerse = [:]
            return
        }

        // Skip if already cached
        if cachedBook == book && cachedChapter == chapter && !highlightsByVerse.isEmpty {
            return
        }

        do {
            let highlights = try ModuleDatabase.shared.getHighlights(setId: setId, book: book, chapter: chapter)

            // Group by verse ref
            var grouped: [Int: [HighlightEntry]] = [:]
            for highlight in highlights {
                grouped[highlight.ref, default: []].append(highlight)
            }

            highlightsByVerse = grouped
            cachedBook = book
            cachedChapter = chapter
        } catch {
            print("[HighlightManager] Error loading highlights: \(error)")
            highlightsByVerse = [:]
        }
    }

    /// Clear cached highlights (call when chapter changes)
    func clearCache() {
        highlightsByVerse = [:]
        cachedBook = 0
        cachedChapter = 0
    }

    /// Add a highlight to the active set (auto-creates a default set if none exists)
    func addHighlight(ref: Int, startChar: Int, endChar: Int) throws {
        try addHighlight(ref: ref, startChar: startChar, endChar: endChar, style: selectedStyle, color: selectedColor)
    }

    /// Add a highlight with explicit style and color (used when splitting highlights)
    func addHighlight(ref: Int, startChar: Int, endChar: Int, style: HighlightStyle, color: HighlightColor) throws {
        // Auto-create a default highlight set if none exists
        if activeSetId == nil {
            guard let translationId = currentTranslationId else {
                throw HighlightError.noTranslationSelected
            }
            let newSet = try createHighlightSet()
            activeSetId = newSet.id
        }

        guard let setId = activeSetId else {
            throw HighlightError.noActiveSet
        }

        var highlight = HighlightEntry(
            setId: setId,
            ref: ref,
            sc: startChar,
            ec: endChar,
            style: style,
            color: color
        )

        // Save and get back the entry with assigned ID
        highlight = try ModuleDatabase.shared.saveHighlight(highlight)
        try ModuleDatabase.shared.updateHighlightSetModified(id: setId)

        // Update cache with the entry that has the ID
        highlightsByVerse[ref, default: []].append(highlight)

        // Schedule sync
        scheduleSyncForActiveSet()
    }

    /// Remove a highlight
    func removeHighlight(_ highlight: HighlightEntry) throws {
        guard let id = highlight.id else { return }

        try ModuleDatabase.shared.deleteHighlight(id: id)

        if let setId = activeSetId {
            try ModuleDatabase.shared.updateHighlightSetModified(id: setId)
        }

        // Update cache
        if var verseHighlights = highlightsByVerse[highlight.ref] {
            verseHighlights.removeAll { $0.id == id }
            highlightsByVerse[highlight.ref] = verseHighlights.isEmpty ? nil : verseHighlights
        }

        // Schedule sync
        scheduleSyncForActiveSet()
    }

    /// Update a highlight's character range
    func updateHighlight(_ highlight: HighlightEntry, newSc: Int, newEc: Int) throws {
        guard let id = highlight.id else { return }

        try ModuleDatabase.shared.updateHighlight(id: id, sc: newSc, ec: newEc)

        if let setId = activeSetId {
            try ModuleDatabase.shared.updateHighlightSetModified(id: setId)
        }

        // Update cache
        if var verseHighlights = highlightsByVerse[highlight.ref] {
            if let idx = verseHighlights.firstIndex(where: { $0.id == id }) {
                var updated = verseHighlights[idx]
                updated.sc = newSc
                updated.ec = newEc
                verseHighlights[idx] = updated
                highlightsByVerse[highlight.ref] = verseHighlights
            }
        }

        // Schedule sync
        scheduleSyncForActiveSet()
    }

    /// Remove all highlights for a verse
    func removeHighlightsForVerse(ref: Int) throws {
        guard let setId = activeSetId else { return }

        try ModuleDatabase.shared.deleteHighlights(setId: setId, ref: ref)
        try ModuleDatabase.shared.updateHighlightSetModified(id: setId)

        // Update cache
        highlightsByVerse[ref] = nil

        // Schedule sync
        scheduleSyncForActiveSet()
    }

    /// Toggle highlight mode
    func toggleHighlightMode() {
        isHighlightModeActive.toggle()
    }

    /// Get highlights for a specific verse from cache
    func getHighlights(for ref: Int) -> [HighlightEntry] {
        return highlightsByVerse[ref] ?? []
    }

    /// Check if verse has any highlights
    func hasHighlights(for ref: Int) -> Bool {
        return highlightsByVerse[ref]?.isEmpty == false
    }

    /// Check if a new highlight would overlap any existing highlights in a verse
    /// Returns the overlapping highlights if any exist
    func getOverlappingHighlights(ref: Int, startChar: Int, endChar: Int) -> [HighlightEntry] {
        guard let existing = highlightsByVerse[ref] else { return [] }
        return existing.filter { highlight in
            // Check for overlap: ranges overlap if one starts before the other ends
            highlight.sc < endChar && highlight.ec > startChar
        }
    }

    /// Check if a new highlight would overlap any existing highlights
    func hasOverlappingHighlights(ref: Int, startChar: Int, endChar: Int) -> Bool {
        return !getOverlappingHighlights(ref: ref, startChar: startChar, endChar: endChar).isEmpty
    }

    // MARK: - Preferences

    private func savePreferences() {
        UserDefaults.standard.set(activeSetId, forKey: "highlight_active_set_id")
        UserDefaults.standard.set(selectedColor.hex, forKey: "highlight_selected_color")
        UserDefaults.standard.set(selectedStyle.rawValue, forKey: "highlight_selected_style")
    }

    private func loadPreferences() {
        if let savedSetId = UserDefaults.standard.string(forKey: "highlight_active_set_id") {
            activeSetId = savedSetId
        }

        if let savedColorHex = UserDefaults.standard.string(forKey: "highlight_selected_color") {
            selectedColor = HighlightColor(hex: savedColorHex)
        }

        if let savedStyleRaw = UserDefaults.standard.object(forKey: "highlight_selected_style") as? Int,
           let savedStyle = HighlightStyle(rawValue: savedStyleRaw) {
            selectedStyle = savedStyle
        }
    }

    /// Select a color and save preference
    func selectColor(_ color: HighlightColor) {
        selectedColor = color
        savePreferences()
    }

    /// Select a style and save preference
    func selectStyle(_ style: HighlightStyle) {
        selectedStyle = style
        savePreferences()
    }

    /// Select active set and save preference
    func selectSet(_ setId: String?) {
        activeSetId = setId
        clearCache()
        savePreferences()
    }
}

// MARK: - Errors

enum HighlightError: LocalizedError {
    case noActiveSet
    case noTranslationSelected
    case highlightNotFound

    var errorDescription: String? {
        switch self {
        case .noActiveSet:
            return "No highlight set is active. Please create or select a highlight set."
        case .noTranslationSelected:
            return "No translation is selected."
        case .highlightNotFound:
            return "Highlight not found."
        }
    }
}
