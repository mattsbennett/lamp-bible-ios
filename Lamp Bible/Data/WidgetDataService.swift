import Foundation
import WidgetKit

class WidgetDataService {
    static let shared = WidgetDataService()

    private let defaults = UserDefaults(suiteName: WidgetConstants.appGroupId)

    private init() {}

    // MARK: - Write Widget Data

    func writeWidgetData() {
        let settings = UserDatabase.shared.getSettings()
        let selectedPlans = settings.selectedPlans
        let completedIds = UserDatabase.shared.getCompletedReadingIds()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        print("[Widget] writeWidgetData: defaults=\(defaults != nil), selectedPlanIds='\(settings.selectedPlanIds)', planCount=\(selectedPlans.count)")

        var allPlanData: [WidgetPlanData] = []

        // Pre-compute 30 days of readings so the widget can update daily without opening the app
        for dayOffset in 0..<30 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday)!

            for plan in selectedPlans {
                let meta = PlanMetaData(id: plan.id, plan: plan, date: date)

                let readings = meta.readingMetaData.map { reading in
                    WidgetReading(
                        id: reading.id,
                        description: reading.description,
                        sv: reading.sv,
                        ev: reading.ev,
                        readingTime: reading.readingTime,
                        genre: reading.genre,
                        isCompleted: dayOffset == 0 ? completedIds.contains(reading.id) : false
                    )
                }

                allPlanData.append(WidgetPlanData(
                    planId: plan.id,
                    planName: plan.name,
                    date: date,
                    readings: readings
                ))
            }
        }

        print("[Widget] writing \(allPlanData.count) plans with \(allPlanData.flatMap(\.readings).count) total readings")

        if let encoded = try? JSONEncoder().encode(allPlanData) {
            defaults?.set(encoded, forKey: WidgetConstants.widgetPlanDataKey)
            defaults?.synchronize()
            print("[Widget] wrote \(encoded.count) bytes to UserDefaults")
        }
    }

    func writeAvailablePlans() {
        let plans = (try? BundledModuleDatabase.shared.getAllPlans()) ?? []
        let widgetPlans = plans.map { WidgetAvailablePlan(id: $0.id, name: $0.name) }

        if let encoded = try? JSONEncoder().encode(widgetPlans) {
            defaults?.set(encoded, forKey: WidgetConstants.widgetAvailablePlansKey)
        }
    }

    func writeAvailableApps() {
        let apps = externalBibleApps
            .filter { $0.name != "None" }
            .map { WidgetAvailableApp(name: $0.name, scheme: $0.scheme) }

        if let encoded = try? JSONEncoder().encode(apps) {
            defaults?.set(encoded, forKey: WidgetConstants.widgetAvailableAppsKey)
        }
    }

    func writeAll() {
        writeWidgetData()
        writeAvailablePlans()
        writeAvailableApps()
    }

    func refreshWidget() {
        writeWidgetData()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
