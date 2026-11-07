//
//  PlanPickerView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

/// Which plans are followed, and the user's own plans made, kept and
/// deleted: Lamp's plans in one group, the user's in another.
struct PlanPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var userSettings = UserDatabase.shared.getSettings()
    @State private var bundledPlans: [Plan] = []
    @State private var userPlans: [Plan] = []
    @State private var showsNewPlan = false
    @State private var infoPlan: Plan?
    @State private var planToDelete: Plan?
    @State private var deleteError: String?
    @State private var editMode: EditMode = .inactive
    /// Readings ticked this week, by plan, for the strip on a followed plan.
    @State private var completedReadingIds: Set<String> = UserDatabase.shared.getCompletedReadingIds()

    init() {
        let plans = ReadingPlanLibrary.plansBySource()
        _bundledPlans = State(initialValue: plans.bundled)
        _userPlans = State(initialValue: plans.user)
    }

    var body: some View {
        // Pushed onto Plans' or Settings' stack, so New Plan is pushed there too.
        List {
            // Worded and marked as modules and search mark them.
            Section {
                ForEach(bundledPlans, id: \.id) { plan in
                    row(plan)
                }
            } header: {
                Text("Built In")
                    .lampSectionHeader()
            }

            Section {
                ForEach(userPlans, id: \.id) { plan in
                    row(plan)
                }
                .onDelete { offsets in
                    planToDelete = offsets.first.map { userPlans[$0] }
                }
                Button { showsNewPlan = true } label: {
                    HStack(spacing: 14) {
                        LampIconTile(systemName: "plus", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New Plan")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Choose the books, or describe the plan you want")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Plan")
            } header: {
                Text("Your Plans")
                    .lampSectionHeader()
            } footer: {
                if !userPlans.isEmpty {
                    Text("Plans you've made or added. Swipe left on one to delete it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(12)
        .listSectionSpacing(20)
        .environment(\.editMode, $editMode)
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            userSettings = UserDatabase.shared.getSettings()
            completedReadingIds = UserDatabase.shared.getCompletedReadingIds()
        }
        .navigationDestination(isPresented: $showsNewPlan) {
            NewPlanView { _ in
                reload()
                showsNewPlan = false
            }
        }
        .sheet(item: $infoPlan) { plan in
            PlanInfoSheet(plan: plan)
        }
        .confirmationDialog(
            "Delete “\(planToDelete?.name ?? "")”?",
            isPresented: Binding(get: { planToDelete != nil }, set: { if !$0 { planToDelete = nil } }),
            titleVisibility: .visible,
            presenting: planToDelete
        ) { plan in
            Button("Delete Plan", role: .destructive) {
                Task { await delete(plan) }
            }
        } message: { _ in
            Text("The plan is deleted here and on any device you sync with.")
        }
        .alert("Couldn't Delete the Plan", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Reading Plans")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "arrow.backward")
                }
            }
            if !userPlans.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
    }

    /// A plan's card: its art, name, ages and pace, its description, and
    /// Follow and About. A followed plan wears the colours of its card on
    /// the home screen and shows where it stands: its day in the year and
    /// this week's readings.
    private func row(_ plan: Plan) -> some View {
        let following = userSettings.isPlanSelected(plan.id)
        let name = Self.displayName(plan.name)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    LampPlanArtwork(planId: plan.id, size: 56, isFollowed: following)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let meta = meta(of: plan, ages: name.ages) {
                            Text(meta)
                                .font(.subheadline)
                                .foregroundStyle(LampTheme.caption)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let description = plan.planDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if following {
                    progressBlock(plan)
                }
                HStack(spacing: 12) {
                    followButton(plan, following: following)
                    Spacer(minLength: 0)
                    // Quiet, so Follow is the card's one red act.
                    Button { infoPlan = plan } label: {
                        Label("About", systemImage: "info.circle")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("About \(plan.name)")
                }
            }
            .padding(LampTheme.Space.l)
        }
        .listRowInsets(EdgeInsets())
    }

    /// Follow is the card's main act while a plan isn't followed; once it
    /// is, the button steps back to say so, and tapping it again stops.
    @ViewBuilder
    private func followButton(_ plan: Plan, following: Bool) -> some View {
        let binding = isFollowing(plan)
        let button = Button {
            withAnimation(.snappy) { binding.wrappedValue.toggle() }
        } label: {
            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 6)
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel(following ? "Following \(plan.name)" : "Follow \(plan.name)")
        .accessibilityHint(following ? "Stops following this plan" : "Adds its readings to the home screen")
        if following {
            button
                .buttonStyle(.bordered)
                .tint(.secondary)
                .foregroundStyle(.primary)
        } else {
            // White said outright: in a list the icon takes the tint, and
            // drew the plus red on red.
            button
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .foregroundStyle(.white)
        }
    }

    /// The year's progress and this week's days for a followed plan.
    private func progressBlock(_ plan: Plan) -> some View {
        let days = week(of: plan)
        let weekRead = days.reduce(0) { $0 + $1.read }
        let weekTotal = days.reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 12) {
            if let progress = progress(of: plan) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Day \(progress.day) of \(progress.total)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    ProgressView(value: progress.fraction)
                        .tint(.accentColor)
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("This week · \(weekRange(days))")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("\(weekRead) of \(weekTotal) readings read")
                        .font(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                PlanWeekStrip(days: days)
            }
        }
        .padding(LampTheme.Space.m)
        .background(LampTheme.tileFill, in: RoundedRectangle(cornerRadius: LampTheme.Radius.tile, style: .continuous))
    }

    /// A plan's name without a trailing "(10-12 yrs)", which goes in the
    /// line beneath as "Ages 10–12", so titles don't wrap round it.
    static func displayName(_ name: String) -> (title: String, ages: String?) {
        guard let match = name.range(of: #"\s*\((\d+)\s*[-–]\s*(\d+)\s*yrs?\)\s*$"#, options: .regularExpression) else {
            return (name, nil)
        }
        let digits = name[match].split(whereSeparator: { !$0.isNumber })
        guard digits.count == 2 else { return (name, nil) }
        return (String(name[..<match.lowerBound]), "Ages \(digits[0])–\(digits[1])")
    }

    /// "Ages 10–12 · 2 readings a day · 1 year"
    private func meta(of plan: Plan, ages: String?) -> String? {
        var parts: [String] = []
        if let ages { parts.append(ages) }
        if let perDay = plan.readingsPerDay, perDay > 0 {
            parts.append(perDay == 1 ? "1 reading a day" : "\(perDay) readings a day")
        }
        if let duration = plan.duration, duration > 0 {
            parts.append(duration >= 365 ? "1 year" : "\(duration) days")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where today falls in the plan: plans run by the day of the year.
    private func progress(of plan: Plan) -> (day: Int, total: Int, fraction: Double)? {
        let calendar = Calendar.current
        let now = Date.now
        guard let day = calendar.ordinality(of: .day, in: .year, for: now) else { return nil }
        let daysInYear = calendar.range(of: .day, in: .year, for: now)?.count ?? 365
        let total = plan.duration.map { $0 >= 365 ? daysInYear : $0 } ?? daysInYear
        guard total > 0 else { return nil }
        let clamped = min(day, total)
        return (clamped, total, Double(clamped) / Double(total))
    }

    /// This week, Monday first: each day's readings and how many are ticked.
    private func week(of plan: Plan) -> [PlanWeekStrip.Day] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: .now)
        guard let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dayNum = plan.getPlanDay(date: date)
            let year = Calendar.iso8601.component(.year, from: date)
            let total = ((try? ReadingPlanLibrary.planDay(planId: plan.id, day: dayNum)) ?? nil)?.readings.count ?? 0
            let read = (0..<total).filter { completedReadingIds.contains("\(plan.id)_\(dayNum)_\($0)_\(year)") }.count
            return PlanWeekStrip.Day(date: date, read: read, total: total, isToday: date == today, isAhead: date > today)
        }
    }

    /// "Nov 2–8", or "Oct 27 – Nov 2" across a month's end.
    private func weekRange(_ days: [PlanWeekStrip.Day]) -> String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        return (first..<last).formatted(.interval.month(.abbreviated).day())
    }

    /// Following a plan, or not, written straight to the settings.
    private func isFollowing(_ plan: Plan) -> Binding<Bool> {
        Binding(
            get: { userSettings.isPlanSelected(plan.id) },
            set: { isOn in
                try? UserDatabase.shared.updateSettings {
                    if isOn { $0.addPlan(plan.id) } else { $0.removePlan(plan.id) }
                }
                userSettings = UserDatabase.shared.getSettings()
                WidgetDataService.shared.refreshWidget()
            }
        )
    }

    private func delete(_ plan: Plan) async {
        do {
            try await ReadingPlanLibrary.delete(planId: plan.id)
        } catch {
            deleteError = error.localizedDescription
        }
        reload()
    }

    /// Every plan and setting read again: a plan just made is followed in
    /// the settings, and one just deleted no longer is.
    private func reload() {
        userSettings = UserDatabase.shared.getSettings()
        completedReadingIds = UserDatabase.shared.getCompletedReadingIds()
        let plans = ReadingPlanLibrary.plansBySource()
        bundledPlans = plans.bundled
        userPlans = plans.user
        if userPlans.isEmpty { editMode = .inactive }
    }
}

#Preview {
    PlanPickerView()
}

// MARK: - Week Strip

/// This week's days for a followed plan: each a circle under its weekday,
/// ticked when every reading is read, part-ringed when some are, today
/// outlined, the days still to come faint. No date in the circle: beside a
/// row of ticks, a lone "8" read as a count rather than the 8th.
struct PlanWeekStrip: View {
    struct Day: Identifiable {
        let date: Date
        let read: Int
        let total: Int
        let isToday: Bool
        let isAhead: Bool
        var id: Date { date }
        var isComplete: Bool { total > 0 && read >= total }
    }

    let days: [Day]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(day.isToday ? Color.primary : Color.primary.opacity(0.62))
                    ZStack {
                        Circle()
                            // The page colour, so a day stands out from the panel
                            // in dark as well as light.
                            .fill(day.isComplete ? Color.accentColor : Color(uiColor: .systemBackground))
                        if !day.isComplete && day.read > 0 && day.total > 0 {
                            Circle()
                                .trim(from: 0, to: Double(day.read) / Double(day.total))
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .padding(1.5)
                        }
                        if day.isComplete {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .opacity(day.isAhead ? 0.45 : 1)
                    .overlay {
                        if day.isToday && !day.isComplete {
                            Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(day.total == 0 ? "No readings" : "\(day.read) of \(day.total) read")
            }
        }
    }
}

// MARK: - Generated art

/// Muted, bookish colour pairs for art that has no image of its own. Chosen
/// by a stable hash of an ID, so a plan or book keeps its colours.
enum LampArtPalette {
    struct Pair {
        let top: Color
        let bottom: Color
    }

    static let pairs: [Pair] = [
        Pair(top: Color(red: 0.16, green: 0.36, blue: 0.33), bottom: Color(red: 0.08, green: 0.21, blue: 0.20)), // pine
        Pair(top: Color(red: 0.20, green: 0.27, blue: 0.47), bottom: Color(red: 0.11, green: 0.15, blue: 0.30)), // navy
        Pair(top: Color(red: 0.55, green: 0.18, blue: 0.20), bottom: Color(red: 0.33, green: 0.09, blue: 0.13)), // oxblood
        Pair(top: Color(red: 0.72, green: 0.48, blue: 0.20), bottom: Color(red: 0.50, green: 0.30, blue: 0.10)), // ochre
        Pair(top: Color(red: 0.36, green: 0.27, blue: 0.45), bottom: Color(red: 0.21, green: 0.15, blue: 0.29)), // plum
        Pair(top: Color(red: 0.30, green: 0.36, blue: 0.40), bottom: Color(red: 0.17, green: 0.21, blue: 0.25)), // slate
    ]

    static func pair(for id: String) -> Pair {
        // Not `hashValue`, which changes between launches.
        let sum = id.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return pairs[Int(sum % UInt32(pairs.count))]
    }
}

/// A plan's artwork: its colours and a glyph for the kind of plan.
struct LampPlanArtwork: View {
    let planId: String
    var size: CGFloat = 56
    /// A followed plan takes the warm red of its card on the home screen.
    var isFollowed = false

    /// Cool and earthy colours for plans not followed, none of them a red
    /// or purple to clash with the accent.
    private static let quietPairs: [LampArtPalette.Pair] = [
        LampArtPalette.pairs[0], LampArtPalette.pairs[1], LampArtPalette.pairs[3], LampArtPalette.pairs[5],
    ]

    private var colors: [Color] {
        if isFollowed {
            return [Color(red: 0.93, green: 0.45, blue: 0.30), Color(red: 0.80, green: 0.18, blue: 0.27), Color(red: 0.52, green: 0.10, blue: 0.26)]
        }
        // By kind, so plans of different kinds never share a colour.
        let pair: LampArtPalette.Pair
        switch symbol {
        case "books.vertical.fill": pair = Self.quietPairs[0]
        case "figure.and.child.holdinghands": pair = Self.quietPairs[1]
        default: pair = Self.quietPairs[2]
        }
        return [pair.top, pair.bottom]
    }

    private var symbol: String { Self.symbol(for: planId) }

    static func symbol(for planId: String) -> String {
        let id = planId.lowercased()
        if id.contains("intermediate") { return "books.vertical.fill" }
        if id.contains("junior") || id.contains("child") || id.contains("kid") { return "figure.and.child.holdinghands" }
        return "book.pages.fill"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.12))
        }
        .accessibilityHidden(true)
    }
}
