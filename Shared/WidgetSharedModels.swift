import Foundation

// MARK: - Widget Shared Constants

enum WidgetConstants {
    static let appGroupId = "group.com.neus.lampbible"
    static let widgetPlanDataKey = "widgetPlanData"
    static let widgetAvailablePlansKey = "widgetAvailablePlans"
    static let widgetAvailableAppsKey = "widgetAvailableApps"
}

// MARK: - Widget Data Models (shared between main app and widget)

struct WidgetPlanData: Codable {
    let planId: String
    let planName: String
    let date: Date
    let readings: [WidgetReading]

    var completedCount: Int {
        readings.filter(\.isCompleted).count
    }

    var totalReadingTime: Int {
        readings.reduce(0) { $0 + $1.readingTime }
    }
}

struct WidgetReading: Codable, Identifiable {
    let id: String
    let description: String
    let sv: Int
    let ev: Int
    let readingTime: Int
    let genre: String
    let isCompleted: Bool

    var deepLinkURL: URL? {
        return URL(string: "lampbible://reading/\(sv)/\(ev)")
    }

    var externalAppDeepLinkURL: URL? {
        return URL(string: "lampbible://reading/\(sv)/\(ev)?external=1")
    }
}

struct WidgetAvailablePlan: Codable, Identifiable {
    let id: String
    let name: String
}

struct WidgetAvailableApp: Codable, Identifiable {
    var id: String { name }
    let name: String
    let scheme: String
}
