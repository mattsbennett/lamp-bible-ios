import AppIntents
import WidgetKit

// MARK: - Open Target

enum OpenTarget: String, AppEnum {
    case lampBible = "lampBible"
    case externalApp = "externalApp"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Open With")

    static var caseDisplayRepresentations: [OpenTarget: DisplayRepresentation] = [
        .lampBible: "Lamp Bible",
        .externalApp: "External Bible App"
    ]
}

// MARK: - Plan Selection Intent

struct SelectPlanIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Reading Plan"
    static var description = IntentDescription("Choose which reading plan to display")

    @Parameter(title: "Reading Plan", default: nil)
    var plan: PlanEntity?

    @Parameter(title: "Open With", default: .lampBible)
    var openWith: OpenTarget
}

struct PlanEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reading Plan")

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PlanEntityQuery()
}

struct PlanEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PlanEntity] {
        let plans = loadAvailablePlans()
        return plans.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PlanEntity] {
        loadAvailablePlans()
    }

    func defaultResult() async -> PlanEntity? {
        let plans = loadAvailablePlans()
        let planData = loadAllPlanData()
        if let firstWithData = planData.first {
            return plans.first { $0.id == firstWithData.planId }
        }
        return plans.first
    }

    private func loadAvailablePlans() -> [PlanEntity] {
        guard let defaults = UserDefaults(suiteName: WidgetConstants.appGroupId),
              let data = defaults.data(forKey: WidgetConstants.widgetAvailablePlansKey),
              let plans = try? JSONDecoder().decode([WidgetAvailablePlan].self, from: data) else {
            return []
        }
        return plans.map { PlanEntity(id: $0.id, name: $0.name) }
    }

    private func loadAllPlanData() -> [WidgetPlanData] {
        guard let defaults = UserDefaults(suiteName: WidgetConstants.appGroupId),
              let data = defaults.data(forKey: WidgetConstants.widgetPlanDataKey),
              let plans = try? JSONDecoder().decode([WidgetPlanData].self, from: data) else {
            return []
        }
        return plans
    }
}
