import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct TodayReadingsEntry: TimelineEntry {
    let date: Date
    let planData: WidgetPlanData?
    let isPlaceholder: Bool
    let openExternal: Bool

    static var placeholder: TodayReadingsEntry {
        TodayReadingsEntry(
            date: Date(),
            planData: WidgetPlanData(
                planId: "sample",
                planName: "M'Cheyne",
                date: Date(),
                readings: [
                    WidgetReading(id: "1", description: "Genesis 1-2", sv: 1001001, ev: 1002999, readingTime: 7, genre: "Law", isCompleted: true),
                    WidgetReading(id: "2", description: "Psalm 1", sv: 19001001, ev: 19001999, readingTime: 2, genre: "Wisdom", isCompleted: false),
                    WidgetReading(id: "3", description: "Matthew 1", sv: 40001001, ev: 40001999, readingTime: 5, genre: "Gospel", isCompleted: false),
                    WidgetReading(id: "4", description: "Acts 1", sv: 44001001, ev: 44001999, readingTime: 6, genre: "History", isCompleted: false),
                ]
            ),
            isPlaceholder: true,
            openExternal: false
        )
    }
}

// MARK: - Timeline Provider

struct TodayReadingsProvider: AppIntentTimelineProvider {
    typealias Entry = TodayReadingsEntry
    typealias Intent = SelectPlanIntent

    func placeholder(in context: Context) -> TodayReadingsEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectPlanIntent, in context: Context) async -> TodayReadingsEntry {
        let planData = loadPlanData(for: configuration)
        let openExternal = configuration.openWith == .externalApp
        return TodayReadingsEntry(date: Date(), planData: planData, isPlaceholder: false, openExternal: openExternal)
    }

    func timeline(for configuration: SelectPlanIntent, in context: Context) async -> Timeline<TodayReadingsEntry> {
        let allPlanData = loadAllPlanData()
        let openExternal = configuration.openWith == .externalApp
        let calendar = Calendar.current

        // Filter to selected plan (or first available)
        let selectedPlanId = configuration.plan?.id
        let planEntries = allPlanData.filter { entry in
            if let selectedPlanId {
                return entry.planId == selectedPlanId
            }
            // If no plan selected, use the first plan's ID to group
            return entry.planId == allPlanData.first?.planId
        }.sorted { $0.date < $1.date }

        // Create a timeline entry for each day
        var entries: [TodayReadingsEntry] = []
        for planData in planEntries {
            let entryDate = calendar.startOfDay(for: planData.date)
            entries.append(TodayReadingsEntry(
                date: entryDate,
                planData: planData,
                isPlaceholder: false,
                openExternal: openExternal
            ))
        }

        // If no entries, create a single empty entry
        if entries.isEmpty {
            entries.append(TodayReadingsEntry(
                date: Date(),
                planData: nil,
                isPlaceholder: false,
                openExternal: openExternal
            ))
        }

        // Refresh after the last entry's date (next day at midnight)
        let lastDate = entries.last?.date ?? Date()
        let refreshDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDate))!
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    /// Load all plan data from shared UserDefaults (all days, all plans)
    private func loadAllPlanData() -> [WidgetPlanData] {
        let defaults = UserDefaults(suiteName: WidgetConstants.appGroupId)

        guard let defaults = defaults,
              let data = defaults.data(forKey: WidgetConstants.widgetPlanDataKey),
              let allPlans = try? JSONDecoder().decode([WidgetPlanData].self, from: data) else {
            return []
        }

        print("[Widget:Read] decoded \(allPlans.count) plan entries")
        return allPlans
    }

    /// Load plan data for a specific date (used by snapshot)
    private func loadPlanData(for configuration: SelectPlanIntent) -> WidgetPlanData? {
        let allPlans = loadAllPlanData()
        let today = Calendar.current.startOfDay(for: Date())

        // Filter to today's entries
        let todayPlans = allPlans.filter { Calendar.current.isDate($0.date, inSameDayAs: today) }

        // If a specific plan is selected, use that; otherwise use the first available
        if let selectedPlan = configuration.plan {
            return todayPlans.first { $0.planId == selectedPlan.id }
                ?? allPlans.first { $0.planId == selectedPlan.id }
        }
        return todayPlans.first ?? allPlans.first
    }
}

// MARK: - Widget Definition

struct TodayReadingsWidget: Widget {
    let kind = "TodayReadingsWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectPlanIntent.self,
            provider: TodayReadingsProvider()
        ) { entry in
            TodayReadingsEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
        }
        .configurationDisplayName("Today's Readings")
        .description("View your daily Bible reading plan assignments.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Entry View (routes to size-specific views)

struct TodayReadingsEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: TodayReadingsEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .accessoryRectangular:
            RectangularLockScreenView(entry: entry)
        case .accessoryCircular:
            CircularLockScreenView(entry: entry)
        case .accessoryInline:
            InlineLockScreenView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Helpers

func readingURL(_ reading: WidgetReading, external: Bool) -> URL {
    (external ? reading.externalAppDeepLinkURL : reading.deepLinkURL) ?? URL(string: "lampbible://")!
}

// MARK: - Small Widget View

struct SmallWidgetView: View {
    let entry: TodayReadingsEntry

    var body: some View {
        if let plan = entry.planData {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    Image("lampflame.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.accent)
                        .padding(.top, 1)
                    Text(plan.planName)
                        .font(.headline)
                }

                Spacer()

                Label("\(plan.readings.count) readings", systemImage: "book.closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                Label("~\(plan.totalReadingTime) min", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                HStack(spacing: 4) {
                    Text("\(plan.completedCount)/\(plan.readings.count)")
                        .font(.caption.bold())
                    Text("completed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Text("Today's Readings")
                    .font(.caption.bold())
                Text("Open Lamp Bible to set up a reading plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Medium Widget View

struct MediumWidgetView: View {
    let entry: TodayReadingsEntry

    var body: some View {
        if let plan = entry.planData {
            HStack(spacing: 0) {
                // Left: readings list
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image("lampflame.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.accent)
                        Text(plan.planName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    .padding(.bottom, 4)

                    ForEach(plan.readings) { reading in
                        Link(destination: readingURL(reading, external: entry.openExternal)) {
                            HStack(spacing: 6) {
                                Image(systemName: reading.isCompleted ? "checkmark" : "circle")
                                    .font(.system(size: 12))
                                    .frame(width: 15)
                                    .foregroundStyle(reading.isCompleted ? .primary : .secondary)
                                Text(reading.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                    }
                }

                // Right: stats
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Label("~\(plan.totalReadingTime) min", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 80)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today's Readings")
                    .font(.headline)
                Text("Open Lamp Bible to set up a reading plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Rectangular Lock Screen View

struct RectangularLockScreenView: View {
    let entry: TodayReadingsEntry

    var body: some View {
        if let plan = entry.planData {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.planName)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()

                ForEach(plan.readings.prefix(3)) { reading in
                    HStack(spacing: 4) {
                        Image(systemName: reading.isCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                        Text(reading.description)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No plan selected")
                .font(.caption)
        }
    }
}

// MARK: - Circular Lock Screen View

struct CircularLockScreenView: View {
    let entry: TodayReadingsEntry

    private var progress: Double {
        guard let plan = entry.planData, plan.readings.count > 0 else { return 0 }
        return Double(plan.completedCount) / Double(plan.readings.count)
    }

    var body: some View {
        ZStack {
            Color.clear
            // Background ring
            Circle()
                .stroke(lineWidth: 6)
                .opacity(0.3)

            // Filled progress arc
            Circle()
                .trim(from: 0, to: progress)
                .stroke(style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Center icon
            Image("lampflame.fill")
                .font(.system(size: 20))
        }
        .padding(1.5)
        .widgetAccentable()
    }
}

// MARK: - Inline Lock Screen View

struct InlineLockScreenView: View {
    let entry: TodayReadingsEntry

    var body: some View {
        if let plan = entry.planData {
            Text("\(plan.planName): \(plan.completedCount)/\(plan.readings.count) done")
        } else {
            Text("Lamp Bible")
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    TodayReadingsWidget()
} timeline: {
    TodayReadingsEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    TodayReadingsWidget()
} timeline: {
    TodayReadingsEntry.placeholder
}
