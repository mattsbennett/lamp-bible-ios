//
//  NewPlanView.swift
//  Lamp Bible
//

import LampCore
import LampIntelligence
import LampModuleKit
import SwiftUI

/// What to read in a plan being made, as the form holds it: passages as
/// typed, so a passage core can't read is shown its message rather than lost.
struct PlanFormTrack: Identifiable, Equatable {
    var id = UUID()
    var passages = ""
    /// Nil: spread over the plan's days.
    var chaptersPerDay: Int?
}

/// A plan being made, as the form holds it, and the request it makes.
struct NewPlanForm: Equatable {
    var name = ""
    var description = ""
    var tracks = [PlanFormTrack()]
    var readingDays = 30
    /// For tracks that are all paced: as long as they take to read once.
    var untilReadThrough = false
    var start = Date()
    var restDays: Set<LampWeekday> = []

    var hasPassages: Bool {
        tracks.contains { !$0.passages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var allPaced: Bool { tracks.allSatisfy { $0.chaptersPerDay != nil } }

    /// A name from what is read and how long, for a plan not yet named.
    var suggestedName: String {
        let first = tracks.first?.passages.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else { return "My Reading Plan" }
        if allPaced && untilReadThrough {
            let pace = tracks.first?.chaptersPerDay ?? 1
            return "\(first), \(pace == 1 ? "a Chapter" : "\(pace) Chapters") a Day"
        }
        return "\(first) in \(readingDays) Days"
    }

    /// The request the form makes, its name the one given or suggested.
    func request() throws -> LampReadingPlanRequest {
        let tracks = try tracks
            .filter { !$0.passages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { track in
                LampReadingPlanRequest.Track(passages: try Self.passages(track.passages), chaptersPerDay: track.chaptersPerDay)
            }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return LampReadingPlanRequest(
            name: trimmedName.isEmpty ? suggestedName : trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription,
            tracks: tracks,
            readingDays: allPaced && untilReadThrough ? nil : readingDays,
            start: start,
            restDays: restDays
        )
    }

    /// Passages as typed, one after another: "Matthew–John; Acts" or one a line.
    static func passages(_ text: String) throws -> [LampPlanPassage] {
        try text.split(whereSeparator: { $0 == ";" || $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(LampPlanPassage.init)
    }

    /// The form filled from what the model or an agent asked for: its
    /// passages as it wrote them, read only when the plan is previewed, so
    /// one core can't read is put right in the form; its dates and rest days
    /// read by core.
    init(agent: LampAgentReadingPlanRequest, today: Date = Date()) throws {
        var timing = agent
        timing.tracks = []
        let request = try timing.request(today: today)
        name = agent.name
        description = agent.description ?? ""
        tracks = agent.tracks.map { PlanFormTrack(passages: $0.passages.joined(separator: "; "), chaptersPerDay: $0.chaptersPerDay) }
        if let days = request.readingDays {
            readingDays = days
            untilReadThrough = false
        } else {
            untilReadThrough = true
        }
        start = request.start
        restDays = request.restDays
    }

    init() {}
}

/// Makes a reading plan to order: from a description, where Apple
/// Intelligence can read one, or from a short form; always shown as its
/// dates and readings before it is added.
struct NewPlanView: View {
    /// Called with the new plan's ID once it is added and followed.
    var onAdded: (String) -> Void

    @State private var form = NewPlanForm()
    @State private var words = ""
    @State private var isAsking = false
    @State private var askError: String?
    @State private var showsPreview = false

    var body: some View {
        Form {
            describeSection

            Section {
                ForEach($form.tracks) { $track in
                    PlanTrackEditor(track: $track)
                }
                .onDelete { offsets in
                    form.tracks.remove(atOffsets: offsets)
                    if form.tracks.isEmpty { form.tracks = [PlanFormTrack()] }
                }
                Button("Read Something Alongside", systemImage: "plus") {
                    form.tracks.append(PlanFormTrack(chaptersPerDay: 1))
                }
            } header: {
                Text("Read")
            } footer: {
                Text("Passages as you'd write them, such as Matthew–John or Psalms 1–41. Each part is read alongside the others, some of each every day.")
            }

            Section("Length") {
                if form.allPaced {
                    Toggle("Until Read Through", isOn: $form.untilReadThrough)
                }
                if !(form.allPaced && form.untilReadThrough) {
                    LabeledContent("Days of Reading") {
                        HStack {
                            TextField("Days", value: $form.readingDays, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 64)
                            Stepper("Days of Reading", value: $form.readingDays, in: 1...366)
                                .labelsHidden()
                        }
                    }
                }
            }

            Section("When") {
                DatePicker("Starts", selection: $form.start, displayedComponents: .date)
                restDaysMenu
            }
        }
        .navigationTitle("New Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Preview") { showsPreview = true }
                    .disabled(!form.hasPassages)
            }
        }
        .navigationDestination(isPresented: $showsPreview) {
            PlanDraftPreview(form: $form, onAdded: onAdded)
        }
    }

    // MARK: Describing

    @ViewBuilder
    private var describeSection: some View {
        if #available(iOS 26, *) {
            if let reason = LampReadingPlanAssistant.unavailableReason {
                Section {
                    Label(reason, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Describe Your Plan")
                }
            } else {
                Section {
                    TextField("The Gospels in a month, weekdays only", text: $words, axis: .vertical)
                        .lineLimit(2...5)
                    Button {
                        Task { await ask() }
                    } label: {
                        HStack {
                            Label("Make from Description", systemImage: "sparkles")
                            if isAsking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAsking)
                } header: {
                    Text("Describe Your Plan")
                } footer: {
                    if let askError {
                        Label(askError, systemImage: "exclamationmark.triangle")
                    } else {
                        Text("Apple Intelligence fills in the plan below, and you see every day of it before it's added.")
                    }
                }
            }
        }
    }

    @available(iOS 26, *)
    private func ask() async {
        isAsking = true
        askError = nil
        defer { isAsking = false }
        do {
            let agent = try await LampReadingPlanAssistant().request(for: words)
            form = try NewPlanForm(agent: agent)
        } catch is CancellationError {
            return
        } catch {
            // Core's errors, the assistant's and the plan's, are written to
            // be shown as they are.
            askError = error.localizedDescription
            return
        }
        do {
            _ = try form.request()
            showsPreview = true
        } catch {
            // The model can still name a chapter a book doesn't have; its
            // plan stays in the form, for that passage to be put right.
            askError = "\(error.localizedDescription) Correct it below, then tap Preview."
        }
    }

    // MARK: Rest days

    private var restDaysMenu: some View {
        Menu {
            Button("No Days Off") { form.restDays = [] }
            Button("Weekends Off") { form.restDays = [.saturday, .sunday] }
            Divider()
            ForEach(LampWeekday.allCases, id: \.self) { day in
                Toggle(day.rawValue.capitalized, isOn: Binding(
                    get: { form.restDays.contains(day) },
                    set: { isOff in
                        if isOff { form.restDays.insert(day) } else { form.restDays.remove(day) }
                    }
                ))
            }
        } label: {
            LabeledContent("Days Off", value: restDaysSummary)
        }
    }

    private var restDaysSummary: String {
        if form.restDays.isEmpty { return "None" }
        if form.restDays == [.saturday, .sunday] { return "Weekends" }
        return LampWeekday.allCases.filter(form.restDays.contains)
            .map { String($0.rawValue.prefix(3)).capitalized }
            .joined(separator: ", ")
    }
}

/// One thing to read: its passages, and whether it is spread over the plan
/// or read at so many chapters a day.
private struct PlanTrackEditor: View {
    @Binding var track: PlanFormTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Matthew–John", text: $track.passages, axis: .vertical)
            Picker("Pace", selection: $track.chaptersPerDay) {
                Text("Spread Over the Plan").tag(Int?.none)
                ForEach(1...10, id: \.self) { pace in
                    Text(pace == 1 ? "A Chapter a Day" : "\(pace) Chapters a Day").tag(Int?.some(pace))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The plan laid out on its dates, named and described as it will be added.
/// Nothing is added until Add is pressed.
struct PlanDraftPreview: View {
    @Binding var form: NewPlanForm
    let onAdded: (String) -> Void

    /// Kept, so the plan drafted again with its edited name is the same plan.
    @State private var planID = UUID().uuidString
    @State private var draft: LampReadingPlanDraft?
    @State private var draftError: String?
    @State private var addError: String?
    @State private var isAdding = false

    var body: some View {
        List {
            if let draftError {
                Section {
                    Label(draftError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else if let draft {
                Section("Plan") {
                    TextField("Name", text: $form.name)
                    TextField("Description", text: $form.description, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Text(summary(of: draft))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let addError {
                        Label(addError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section("Readings") {
                    ForEach(draft.days, id: \.date) { day in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                                .font(.headline)
                            Text(day.readings.map {
                                LampBibleReferenceFormatter.describeRange(from: $0.startReference, to: $0.endReference)
                            }.joined(separator: "; "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add") { Task { await add() } }
                        .disabled(draft == nil || form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task { makeDraft() }
    }

    private func makeDraft() {
        if form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            form.name = form.suggestedName
        }
        do {
            draft = try form.request().draft(id: planID)
            draftError = nil
        } catch {
            draft = nil
            draftError = error.localizedDescription
        }
    }

    private func summary(of draft: LampReadingPlanDraft) -> String {
        guard let first = draft.days.first?.date, let last = draft.days.last?.date else { return "" }
        let range = "\(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))"
        return "\(draft.days.count) days of reading, \(range)."
    }

    /// Compiled to a plan module and taken in as any plan file is, so it
    /// syncs as Plans/<id>.lamp, then followed.
    private func add() async {
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            let draft = try form.request().draft(id: planID)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("lamp-plan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // The compiler holds a module's file to its ID.
            let moduleURL = folder.appendingPathComponent(planID).appendingPathExtension("lamp")
            _ = try LampModuleCompiler().compile(
                data: try draft.moduleJSON(),
                sourceFilename: "\(planID).json",
                destinationURL: moduleURL
            )
            try await ModuleSyncManager.shared.importModuleFromFile(url: moduleURL, moduleType: .plan)
            try UserDatabase.shared.updateSettings { $0.addPlan(planID) }
            WidgetDataService.shared.refreshWidget()
            onAdded(planID)
        } catch {
            addError = error.localizedDescription
        }
    }
}
