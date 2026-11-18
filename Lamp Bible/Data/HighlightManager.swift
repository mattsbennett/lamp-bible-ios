//
//  HighlightManager.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import Foundation
import SwiftUI
import Combine
import LampModuleKit

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

    /// Bumped when a theme is named, renamed or deleted, for what shows
    /// themes' names to read them again.
    @Published private(set) var themesRevision = 0

    func themesChanged() {
        themesRevision += 1
    }

    // MARK: - Private State

    /// The chapter `highlightsByVerse` holds, and the set it was read from.
    private var cachedChapters: [Chapter] = []
    private var cachedSetId: String?
    /// The chapters the reader shows (a plan reading can take several),
    /// read again when the set changes.
    private var shownChapters: [Chapter] = []
    /// Pending syncs, one per highlights module.
    private var syncWorkItems: [String: DispatchWorkItem] = [:]
    private let syncDebounceInterval: TimeInterval = 2.0  // Wait 2 seconds before syncing

    // MARK: - Initialization

    private init() {
        // Load saved preferences
        loadPreferences()
    }

    // MARK: - Sync

    /// Schedule a debounced sync for a highlight set's module
    private func scheduleSync(setId: String?) {
        guard let setId else { return }

        // Get the module ID for the active set
        guard let set = try? ModuleDatabase.shared.getHighlightSet(id: setId) else { return }

        // Cancel any pending sync of the same module
        syncWorkItems[set.moduleId]?.cancel()

        // Schedule new sync
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.syncWorkItems[set.moduleId] = nil
                self?.performSync(moduleId: set.moduleId)
            }
        }
        syncWorkItems[set.moduleId] = workItem
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
        let previousSetId = activeSetId
        defer {
            // Another set's highlights don't belong on this translation's
            // text: the chapter about to load reads the new set's.
            if activeSetId != previousSetId { clearCache() }
        }

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
    func createHighlightSet(name: String? = nil, description: String? = nil, translationId: String? = nil) throws -> HighlightSet {
        guard let translationId = translationId ?? currentTranslationId else {
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
            // The ID the translation had first, as every device records it,
            // so a set made here and one made on the Mac agree (core's rule).
            translationId: LampTranslationID.original(translationId),
            created: now,
            lastModified: now
        )

        try ModuleDatabase.shared.saveHighlightSet(set)

        // Refresh available sets and make it the active one, if the reader
        // is still in the translation it was made for
        if translationId == currentTranslationId {
            loadSetsForTranslation(translationId)
            activeSetId = set.id
            // Nothing in it yet: the shown chapter's highlights are those
            // added from here on.
            highlightsByVerse = [:]
            cachedChapters = shownChapters
            cachedSetId = set.id
            savePreferences()
        }

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
    func deleteHighlightSet(id: String) async throws {
        guard let set = try ModuleDatabase.shared.getHighlightSet(id: id) else {
            return
        }

        let moduleId = set.moduleId

        // Delete the module (cascade will delete set and highlights)
        try ModuleDatabase.shared.deleteModule(id: moduleId)

        // Out of the library: a tombstone the next pass carries to every device.
        await ModuleSyncManager.shared.removeFromLibrary(
            type: .highlights, moduleId: moduleId,
            storage: await ModuleSyncManager.shared.getStorage()
        )

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

    struct Chapter: Equatable {
        let book: Int
        let chapter: Int
    }

    /// Load highlights for a chapter
    func loadHighlightsForChapter(book: Int, chapter: Int) {
        loadHighlights(forChapters: [Chapter(book: book, chapter: chapter)])
    }

    /// Load highlights for the chapters the reader shows together
    func loadHighlights(forChapters chapters: [Chapter]) {
        shownChapters = chapters
        guard let setId = activeSetId else {
            highlightsByVerse = [:]
            cachedSetId = nil
            return
        }

        // Skip if already cached, from this set
        if cachedChapters == chapters && cachedSetId == setId {
            return
        }

        do {
            // Group by verse ref
            var grouped: [Int: [HighlightEntry]] = [:]
            for chapter in chapters {
                for highlight in try ModuleDatabase.shared.getHighlights(setId: setId, book: chapter.book, chapter: chapter.chapter) {
                    grouped[highlight.ref, default: []].append(highlight)
                }
            }

            highlightsByVerse = grouped
            cachedChapters = chapters
            cachedSetId = setId
        } catch {
            print("[HighlightManager] Error loading highlights: \(error)")
            // Nothing cached: the next visit reads the chapter again.
            clearCache()
        }
    }

    /// Highlights written elsewhere (a sync, an import) may be in the shown
    /// chapter, or in a set new to this translation: read both again.
    func reloadAfterExternalChange() {
        themesChanged()
        if let translationId = currentTranslationId {
            loadSetsForTranslation(translationId)
        }
        clearCache()
        if !shownChapters.isEmpty {
            loadHighlights(forChapters: shownChapters)
        }
    }

    /// Clear cached highlights (call when chapter changes)
    func clearCache() {
        highlightsByVerse = [:]
        cachedChapters = []
        cachedSetId = nil
    }

    /// Where a new highlight goes: the set and translation as they were
    /// when its words were chosen. Read later, a translation switched
    /// mid-save would take the offsets to another translation's text.
    struct Target {
        let setId: String?
        let translationId: String?
    }

    var target: Target { Target(setId: activeSetId, translationId: currentTranslationId) }

    /// The target with a set to save to, made for its translation if it
    /// has none: several highlights saved together go to one set.
    func resolved(_ target: Target) throws -> Target {
        if target.setId != nil { return target }
        let set = try createHighlightSet(translationId: target.translationId)
        return Target(setId: set.id, translationId: target.translationId)
    }

    /// Add a highlight to the active set (auto-creates a default set if none exists)
    @discardableResult
    func addHighlight(ref: Int, startChar: Int, endChar: Int, to target: Target? = nil) throws -> HighlightEntry {
        try addHighlight(ref: ref, startChar: startChar, endChar: endChar, style: selectedStyle, color: selectedColor, to: target)
    }

    /// Add a highlight with explicit style and color (used when splitting
    /// highlights), to the target's set, or the active one
    @discardableResult
    func addHighlight(ref: Int, startChar: Int, endChar: Int, style: HighlightStyle, color: HighlightColor, to target: Target? = nil) throws -> HighlightEntry {
        // Auto-create a default highlight set if none exists
        guard let setId = try resolved(target ?? self.target).setId else {
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

        // Update cache with the entry that has the ID, if it shows that set
        // (the active one, before any chapter of it has been read)
        if setId == (cachedSetId ?? activeSetId) {
            highlightsByVerse[ref, default: []].append(highlight)
        }

        // Schedule sync
        scheduleSync(setId: highlight.setId)
        return highlight
    }

    /// Marks each span in one style and colour, in the target's set. A
    /// highlight there lying wholly inside a span is replaced rather than
    /// drawn over; one that only overlaps it stays beneath (the Mac's rule).
    @discardableResult
    func mark(_ spans: [HighlightSpan], style: HighlightStyle, color: HighlightColor, to target: Target) throws -> [HighlightEntry] {
        guard let setId = try resolved(target).setId else { throw HighlightError.noActiveSet }
        let target = Target(setId: setId, translationId: target.translationId)
        var made: [HighlightEntry] = []
        for span in spans {
            for covered in try highlights(setId: setId, ref: span.ref) where covered.sc >= span.sc && covered.ec <= span.ec {
                try removeHighlight(covered)
            }
            made.append(try addHighlight(ref: span.ref, startChar: span.sc, endChar: span.ec, style: style, color: color, to: target))
        }
        return made
    }

    /// A set's highlights at a verse: the shown chapter's from the cache.
    func highlights(setId: String, ref: Int) throws -> [HighlightEntry] {
        if setId == cachedSetId {
            return highlightsByVerse[ref] ?? []
        }
        return try ModuleDatabase.shared.getHighlights(setId: setId, ref: ref)
    }

    /// Highlight an entire verse (used by verse number menu action).
    /// `textLength` is the verse's length in Characters as the reader shows
    /// it; without it, the stored text's.
    func highlightEntireVerse(_ ref: Int, textLength shownLength: Int? = nil, to target: Target? = nil) {
        let target = target ?? self.target
        let textLength: Int
        if let shownLength {
            textLength = shownLength
        } else {
            guard let translationId = target.translationId else {
                print("[HighlightManager] No translation selected for highlighting verse")
                return
            }

            // Get the verse text to determine its length
            guard let verse = try? TranslationDatabase.shared.getVerse(translationId: translationId, ref: ref) else {
                print("[HighlightManager] Could not find verse \(ref)")
                return
            }
            textLength = verse.text.count
        }
        guard textLength > 0 else { return }

        do {
            // Check for existing highlights on this verse, in the target's
            // set: the cache may show another by now
            let resolvedTarget = try resolved(target)
            let existing: [HighlightEntry]
            if resolvedTarget.setId == cachedSetId {
                existing = highlightsByVerse[ref] ?? []
            } else {
                let (_, chapter, book) = splitVerseId(ref)
                existing = try ModuleDatabase.shared
                    .getHighlights(setId: resolvedTarget.setId ?? "", book: book, chapter: chapter)
                    .filter { $0.ref == ref }
            }
            if existing.contains(where: { $0.sc == 0 && $0.ec >= textLength - 1 }) {
                // Already fully highlighted - remove it (toggle behavior)
                for highlight in existing.filter({ $0.sc == 0 && $0.ec >= textLength - 1 }) {
                    try removeHighlight(highlight)
                }
            } else {
                // Add highlight for entire verse
                try addHighlight(ref: ref, startChar: 0, endChar: textLength, to: resolvedTarget)
            }
        } catch {
            print("[HighlightManager] Error highlighting verse: \(error)")
        }
    }

    /// Remove a highlight
    func removeHighlight(_ highlight: HighlightEntry) throws {
        guard let id = highlight.id else { return }

        try ModuleDatabase.shared.deleteHighlight(id: id)
        try ModuleDatabase.shared.updateHighlightSetModified(id: highlight.setId)

        // Update cache
        if var verseHighlights = highlightsByVerse[highlight.ref] {
            verseHighlights.removeAll { $0.id == id }
            highlightsByVerse[highlight.ref] = verseHighlights.isEmpty ? nil : verseHighlights
        }

        // Schedule sync
        scheduleSync(setId: highlight.setId)
    }

    /// Update a highlight's character range
    func updateHighlight(_ highlight: HighlightEntry, newSc: Int, newEc: Int) throws {
        guard let id = highlight.id else { return }

        try ModuleDatabase.shared.updateHighlight(id: id, sc: newSc, ec: newEc)
        try ModuleDatabase.shared.updateHighlightSetModified(id: highlight.setId)

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
        scheduleSync(setId: highlight.setId)
    }

    /// Remove all highlights for a verse
    func removeHighlightsForVerse(ref: Int) throws {
        guard let setId = activeSetId else { return }

        try ModuleDatabase.shared.deleteHighlights(setId: setId, ref: ref)
        try ModuleDatabase.shared.updateHighlightSetModified(id: setId)

        // Update cache
        highlightsByVerse[ref] = nil

        // Schedule sync
        scheduleSync(setId: setId)
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
        // The reader doesn't load its chapter again for a set: read it here.
        if !shownChapters.isEmpty {
            loadHighlights(forChapters: shownChapters)
        }
    }
}

/// Words a highlight covers in one verse, as Characters into its text.
struct HighlightSpan: Equatable {
    let ref: Int
    let sc: Int
    let ec: Int
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
