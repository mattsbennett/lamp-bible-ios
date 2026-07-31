import Foundation
import UIKit
import WidgetKit

class WidgetDataService {
    static let shared = WidgetDataService()

    private let defaults = UserDefaults(suiteName: WidgetConstants.appGroupId)

    /// All widget payload building happens here. Building 30 days of readings
    /// for every selected plan is far too expensive for the main thread, and a
    /// serial queue also keeps overlapping refreshes from racing each other.
    private let queue = DispatchQueue(label: "com.lampbible.widgetdata", qos: .utility)

    /// Coalesces bursts of refresh requests (e.g. tapping several readings in a
    /// row) into a single rebuild.
    private var pendingRefresh: DispatchWorkItem?
    private let pendingRefreshLock = NSLock()
    private let refreshDebounce: TimeInterval = 0.5

    private init() {}

    // MARK: - Write Widget Data

    func writeWidgetData() {
        let settings = UserDatabase.shared.getSettings()
        let selectedPlans = settings.selectedPlans
        let completedIds = UserDatabase.shared.getCompletedReadingIds()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        var allPlanData: [WidgetPlanData] = []

        // Pre-compute 30 days of readings so the widget can update daily without opening the app
        for dayOffset in 0..<30 {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday)!

            for plan in selectedPlans {
                let meta = PlanMetaDataCache.shared.metaData(
                    for: plan,
                    date: date,
                    userSettings: settings
                )

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

        if let encoded = try? JSONEncoder().encode(allPlanData) {
            defaults?.set(encoded, forKey: WidgetConstants.widgetPlanDataKey)
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

    /// Write everything the widget needs. Safe to call from any thread; the work
    /// is moved off the caller's queue.
    func writeAll() {
        queue.async { [weak self] in
            self?.writeWidgetData()
            self?.writeAvailablePlans()
            self?.writeAvailableApps()
        }
    }

    // MARK: - Refresh

    /// Rebuild the widget payload and reload timelines. Safe to call from any
    /// thread — the work is debounced and runs off the main thread, so callers
    /// in a tap handler don't pay for it.
    func refreshWidget() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRefresh()
        }

        pendingRefreshLock.lock()
        pendingRefresh?.cancel()
        pendingRefresh = workItem
        pendingRefreshLock.unlock()

        queue.asyncAfter(deadline: .now() + refreshDebounce, execute: workItem)
    }

    /// Rebuild immediately, skipping the debounce, and keep the app alive long
    /// enough to finish. Used when the app is heading to the background, where a
    /// pending debounced refresh would otherwise be dropped.
    func refreshWidgetImmediately() {
        pendingRefreshLock.lock()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshLock.unlock()

        let app = UIApplication.shared
        var bgTaskId: UIBackgroundTaskIdentifier = .invalid
        bgTaskId = app.beginBackgroundTask(withName: "WidgetDataRefresh") {
            if bgTaskId != .invalid {
                app.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }

        queue.async { [weak self] in
            self?.performRefresh()
            if bgTaskId != .invalid {
                app.endBackgroundTask(bgTaskId)
                bgTaskId = .invalid
            }
        }
    }

    private func performRefresh() {
        writeWidgetData()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
