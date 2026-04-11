//
//  UserModels.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2025-01-12.
//

import Foundation
import GRDB

// MARK: - UserSettings

struct UserSettings: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "user_settings"

    var id: Int = 1
    var selectedPlanIds: String = ""
    var planInAppBible: Bool = true
    var planExternalBible: String?
    var planWpm: Double = 183.0
    var planNotification: Bool = false
    var planNotificationHour: Int = 18
    var planNotificationMinute: Int = 30
    var readerTranslationId: String = "BSBs"
    var readerCrossReferenceSort: String = "r"
    var readerFontSize: Float = 18.0
    var devotionalFontSize: Float = 18.0
    var devotionalPresentFontMultiplier: Float = 3.0
    var devotionalLineSpacingBonus: Float = 1.0
    var hiddenTranslations: String = ""
    var greekLexiconOrder: String = "strongs,dodson"
    var hebrewLexiconOrder: String = "strongs,bdb"
    var hiddenGreekLexicons: String = ""
    var hiddenHebrewLexicons: String = ""
    var showStrongsHints: Bool = false
    var customHighlightColors: String = ""  // Deprecated - use highlightColorOrder
    var highlightColorOrder: String = ""    // Comma-separated hex values of ALL visible colors in order
    var defaultQuizAgeGroup: String = "adult"
    var planReaderCount: Int = 1
    var updatedAt: Date = Date()

    // MARK: - CodingKeys for snake_case mapping

    enum CodingKeys: String, CodingKey {
        case id
        case selectedPlanIds = "selected_plan_ids"
        case planInAppBible = "plan_in_app_bible"
        case planExternalBible = "plan_external_bible"
        case planWpm = "plan_wpm"
        case planNotification = "plan_notification"
        case planNotificationHour = "plan_notification_hour"
        case planNotificationMinute = "plan_notification_minute"
        case readerTranslationId = "reader_translation_id"
        case readerCrossReferenceSort = "reader_cross_reference_sort"
        case readerFontSize = "reader_font_size"
        case devotionalFontSize = "devotional_font_size"
        case devotionalPresentFontMultiplier = "devotional_present_font_multiplier"
        case devotionalLineSpacingBonus = "devotional_line_spacing_bonus"
        case hiddenTranslations = "hidden_translations"
        case greekLexiconOrder = "greek_lexicon_order"
        case hebrewLexiconOrder = "hebrew_lexicon_order"
        case hiddenGreekLexicons = "hidden_greek_lexicons"
        case hiddenHebrewLexicons = "hidden_hebrew_lexicons"
        case showStrongsHints = "show_strongs_hints"
        case customHighlightColors = "custom_highlight_colors"
        case highlightColorOrder = "highlight_color_order"
        case defaultQuizAgeGroup = "default_quiz_age_group"
        case planReaderCount = "plan_reader_count"
        case updatedAt = "updated_at"
    }

    // MARK: - Plan Selection Helpers

    /// Get array of selected plan IDs
    var planIds: [String] {
        guard !selectedPlanIds.isEmpty else { return [] }
        return selectedPlanIds.components(separatedBy: ",")
    }

    /// Check if a plan is selected
    func isPlanSelected(_ planId: String) -> Bool {
        planIds.contains(planId)
    }

    /// Add a plan to selections
    mutating func addPlan(_ planId: String) {
        guard !isPlanSelected(planId) else { return }
        if selectedPlanIds.isEmpty {
            selectedPlanIds = planId
        } else {
            selectedPlanIds += ",\(planId)"
        }
    }

    /// Remove a plan from selections
    mutating func removePlan(_ planId: String) {
        var ids = planIds
        ids.removeAll { $0 == planId }
        selectedPlanIds = ids.joined(separator: ",")
    }

    /// Get the notification date from hour/minute components
    var planNotificationDate: Date {
        get {
            var dateComponents = DateComponents()
            dateComponents.hour = planNotificationHour
            dateComponents.minute = planNotificationMinute
            return Calendar.current.date(from: dateComponents) ?? Date()
        }
        set {
            planNotificationHour = Calendar.current.component(.hour, from: newValue)
            planNotificationMinute = Calendar.current.component(.minute, from: newValue)
        }
    }

    /// Get selected plans from GRDB
    var selectedPlans: [Plan] {
        let ids = planIds
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { try? BundledModuleDatabase.shared.getPlan(id: $0) }
    }
}

// MARK: - CompletedReading

struct CompletedReading: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "completed_readings"

    var id: String  // Format: "{planId}_{dayIndex}_r{readingIndex}_{year}"
    var planId: String
    var year: Int
    var completedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case planId = "plan_id"
        case year
        case completedAt = "completed_at"
    }

    init(id: String, completedAt: Date = Date()) {
        self.id = id
        self.completedAt = completedAt

        // Parse planId and year from id
        // Format: "{planId}_{dayIndex}_r{readingIndex}_{year}"
        let components = id.split(separator: "_")
        if components.count >= 1 {
            self.planId = String(components[0])
        } else {
            self.planId = ""
        }

        if let lastComponent = components.last,
           let parsedYear = Int(lastComponent) {
            self.year = parsedYear
        } else {
            self.year = Calendar.current.component(.year, from: Date())
        }
    }
}
