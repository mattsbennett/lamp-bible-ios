//
//  HighlightModels.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-21.
//

import Foundation
import SwiftUI
import GRDB

// MARK: - Highlight Style

/// Style of a highlight (background color or underline type)
enum HighlightStyle: Int, Codable, CaseIterable {
    case highlight = 0           // Background color fill
    case underlineSolid = 1      // Solid underline
    case underlineDashed = 2     // Dashed underline
    case underlineDotted = 3     // Dotted underline

    var displayName: String {
        switch self {
        case .highlight: return "Highlight"
        case .underlineSolid: return "Underline"
        case .underlineDashed: return "Dashed"
        case .underlineDotted: return "Dotted"
        }
    }

    var iconName: String {
        switch self {
        case .highlight: return "highlighter"
        case .underlineSolid: return "underline"
        case .underlineDashed: return "underline.dashed"
        case .underlineDotted: return "underline.dotted"
        }
    }

    /// Whether this style uses a system SF Symbol or custom asset
    var isSystemIcon: Bool {
        switch self {
        case .highlight, .underlineSolid: return true
        case .underlineDashed, .underlineDotted: return false
        }
    }

    /// Returns the appropriate Image for this style
    var icon: Image {
        if isSystemIcon {
            return Image(systemName: iconName)
        } else {
            return Image(iconName)
        }
    }
}

// MARK: - Highlight Color

/// Represents a highlight color with hex serialization
struct HighlightColor: Codable, Equatable, Hashable, Identifiable {
    let hex: String

    var id: String { hex }

    /// Create from hex string (e.g., "#FFFF00" or "FFFF00")
    init(hex: String) {
        // Normalize to uppercase without # prefix
        var normalized = hex.uppercased()
        if normalized.hasPrefix("#") {
            normalized = String(normalized.dropFirst())
        }
        self.hex = normalized
    }

    /// Create from SwiftUI Color
    init(color: Color) {
        self.hex = color.toHex() ?? "FFFF00"
    }

    /// Convert to SwiftUI Color
    var color: Color {
        Color(hex: hex) ?? .yellow
    }

    /// Convert to UIColor
    var uiColor: UIColor {
        UIColor(hex: hex) ?? .systemYellow
    }

    /// Color for highlight background (with alpha)
    var highlightColor: Color {
        color.opacity(0.4)
    }

    /// Color for underline
    var underlineColor: Color {
        color
    }

    // MARK: - Default Colors

    static let yellow = HighlightColor(hex: "FFCC00")
    static let green = HighlightColor(hex: "34C759")
    static let blue = HighlightColor(hex: "007AFF")
    static let pink = HighlightColor(hex: "FF2D55")
    static let orange = HighlightColor(hex: "FF9500")
    static let purple = HighlightColor(hex: "AF52DE")
    static let red = HighlightColor(hex: "FF3B30")
    static let gray = HighlightColor(hex: "8E8E93")

    /// All default colors in display order
    static let defaultColors: [HighlightColor] = [
        .yellow, .green, .blue, .pink
    ]
}

// MARK: - Highlight Set (Metadata)

/// Metadata for a highlight set tied to a specific translation
struct HighlightSet: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "highlight_sets"

    var id: String
    var moduleId: String        // Reference to module table
    var name: String
    var description: String?
    var translationId: String   // The translation this set belongs to
    var created: Int            // Unix timestamp
    var lastModified: Int       // Unix timestamp

    // Map Swift property names to database column names (snake_case)
    enum CodingKeys: String, CodingKey {
        case id
        case moduleId = "module_id"
        case name
        case description
        case translationId = "translation_id"
        case created
        case lastModified = "last_modified"
    }

    init(
        id: String = UUID().uuidString,
        moduleId: String,
        name: String,
        description: String? = nil,
        translationId: String,
        created: Int = Int(Date().timeIntervalSince1970),
        lastModified: Int = Int(Date().timeIntervalSince1970)
    ) {
        self.id = id
        self.moduleId = moduleId
        self.name = name
        self.description = description
        self.translationId = translationId
        self.created = created
        self.lastModified = lastModified
    }

    // MARK: - GRDB Columns

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let moduleId = Column(CodingKeys.moduleId)
        static let name = Column(CodingKeys.name)
        static let description = Column(CodingKeys.description)
        static let translationId = Column(CodingKeys.translationId)
        static let created = Column(CodingKeys.created)
        static let lastModified = Column(CodingKeys.lastModified)
    }
}

// MARK: - Highlight Entry

/// Individual highlight on a verse
struct HighlightEntry: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "highlights"

    // Tell GRDB that id is auto-generated
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var id: Int64?              // Auto-increment
    var setId: String           // Reference to highlight_sets
    var ref: Int                // BBCCCVVV verse reference
    var sc: Int                 // Start character offset within verse text
    var ec: Int                 // End character offset within verse text
    var style: Int              // HighlightStyle raw value
    var color: String?          // Hex color (nil = use default yellow)

    // Map Swift property names to database column names (snake_case)
    enum CodingKeys: String, CodingKey {
        case id
        case setId = "set_id"
        case ref
        case sc
        case ec
        case style
        case color
    }

    init(
        id: Int64? = nil,
        setId: String,
        ref: Int,
        sc: Int,
        ec: Int,
        style: HighlightStyle = .highlight,
        color: HighlightColor? = nil
    ) {
        self.id = id
        self.setId = setId
        self.ref = ref
        self.sc = sc
        self.ec = ec
        self.style = style.rawValue
        self.color = color?.hex
    }

    // MARK: - Computed Properties

    var highlightStyle: HighlightStyle {
        HighlightStyle(rawValue: style) ?? .highlight
    }

    var highlightColor: HighlightColor {
        if let hex = color {
            return HighlightColor(hex: hex)
        }
        return .yellow
    }

    /// Book number (1-66)
    var book: Int {
        ref / 1_000_000
    }

    /// Chapter number
    var chapter: Int {
        (ref / 1000) % 1000
    }

    /// Verse number
    var verse: Int {
        ref % 1000
    }

    // MARK: - GRDB Columns

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let setId = Column(CodingKeys.setId)
        static let ref = Column(CodingKeys.ref)
        static let sc = Column(CodingKeys.sc)
        static let ec = Column(CodingKeys.ec)
        static let style = Column(CodingKeys.style)
        static let color = Column(CodingKeys.color)
    }
}

// MARK: - Color Extensions

extension Color {
    /// Initialize from hex string
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b: Double
        switch hexSanitized.count {
        case 6:
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
        case 8:
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
        default:
            return nil
        }

        self.init(red: r, green: g, blue: b)
    }

    /// Convert to hex string
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components else {
            return nil
        }

        let r = Int(components[0] * 255.0)
        let g = Int(components.count > 1 ? components[1] * 255.0 : components[0] * 255.0)
        let b = Int(components.count > 2 ? components[2] * 255.0 : components[0] * 255.0)

        return String(format: "%02X%02X%02X", r, g, b)
    }
}

extension UIColor {
    /// Initialize from hex string
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r, g, b, a: CGFloat
        switch hexSanitized.count {
        case 6:
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
            a = 1.0
        case 8:
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        default:
            return nil
        }

        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// Convert to hex string
    func toHex() -> String? {
        guard let components = cgColor.components else {
            return nil
        }

        let r = Int(components[0] * 255.0)
        let g = Int(components.count > 1 ? components[1] * 255.0 : components[0] * 255.0)
        let b = Int(components.count > 2 ? components[2] * 255.0 : components[0] * 255.0)

        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Highlight Theme

/// Theme/meaning associated with a color+style combination (stored per highlight set)
struct HighlightTheme: Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Identifiable {
    static let databaseTableName = "highlight_themes"

    var id: String          // Composite key: "{setId}_{color}_{style}"
    var setId: String       // Reference to highlight_sets
    var color: String       // Hex color code
    var style: Int          // HighlightStyle raw value
    var name: String        // Short theme name (e.g., "Promises")
    var themeDescription: String? // Optional longer description

    // Map Swift property names to database column names (snake_case)
    enum CodingKeys: String, CodingKey {
        case id
        case setId = "set_id"
        case color
        case style
        case name
        case themeDescription = "description"
    }

    var highlightColor: HighlightColor {
        HighlightColor(hex: color)
    }

    var highlightStyle: HighlightStyle {
        HighlightStyle(rawValue: style) ?? .highlight
    }

    init(setId: String, color: HighlightColor, style: HighlightStyle, name: String, description: String? = nil) {
        let normalizedColor = color.hex.uppercased()
        self.id = "\(setId)_\(normalizedColor)_\(style.rawValue)"
        self.setId = setId
        self.color = normalizedColor
        self.style = style.rawValue
        self.name = name
        self.themeDescription = description
    }

    init(setId: String, color: String, style: Int, name: String, description: String? = nil) {
        let normalizedColor = color.uppercased().replacingOccurrences(of: "#", with: "")
        self.id = "\(setId)_\(normalizedColor)_\(style)"
        self.setId = setId
        self.color = normalizedColor
        self.style = style
        self.name = name
        self.themeDescription = description
    }

    // MARK: - GRDB Columns

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let setId = Column(CodingKeys.setId)
        static let color = Column(CodingKeys.color)
        static let style = Column(CodingKeys.style)
        static let name = Column(CodingKeys.name)
        static let themeDescription = Column(CodingKeys.themeDescription)
    }
}

/// Export format for themes (simpler, without setId since it's implicit)
struct HighlightThemeExport: Codable {
    let color: String
    let style: Int
    let name: String
    let description: String?

    init(from theme: HighlightTheme) {
        self.color = theme.color
        self.style = theme.style
        self.name = theme.name
        self.description = theme.themeDescription
    }
}

// MARK: - Highlight Module File (for import/export)

/// JSON file structure for highlight modules (SQLite format exported/imported)
struct HighlightModuleFile: Codable {
    let id: String
    let type: String = "highlights"
    let name: String
    let description: String?
    let translationId: String
    let created: Int
    let lastModified: Int
    let highlights: [HighlightExportEntry]
    let themes: [HighlightThemeExport]?  // Optional themes for color+style meanings

    init(from set: HighlightSet, highlights: [HighlightEntry], themes: [HighlightTheme]? = nil) {
        self.id = set.id
        self.name = set.name
        self.description = set.description
        self.translationId = set.translationId
        self.created = set.created
        self.lastModified = set.lastModified
        self.highlights = highlights.map { HighlightExportEntry(from: $0) }
        self.themes = themes?.map { HighlightThemeExport(from: $0) }
    }
}

/// Highlight entry for export (matches SQLite schema)
struct HighlightExportEntry: Codable {
    let ref: Int
    let sc: Int
    let ec: Int
    let style: Int
    let color: String?

    init(from entry: HighlightEntry) {
        self.ref = entry.ref
        self.sc = entry.sc
        self.ec = entry.ec
        self.style = entry.style
        self.color = entry.color
    }
}
