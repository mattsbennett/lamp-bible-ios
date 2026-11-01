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

    init() {
        let plans = ReadingPlanLibrary.plansBySource()
        _bundledPlans = State(initialValue: plans.bundled)
        _userPlans = State(initialValue: plans.user)
    }

    var body: some View {
        // Pushed onto Plans' or Settings' stack, so New Plan is pushed there too.
        Form {
            // Worded and marked as modules and search mark them.
            Section {
                ForEach(bundledPlans, id: \.id) { plan in
                    row(plan)
                }
            } header: {
                Label("Built In", systemImage: "shippingbox")
            }

            Section {
                ForEach(userPlans, id: \.id) { plan in
                    row(plan)
                }
                .onDelete { offsets in
                    planToDelete = offsets.first.map { userPlans[$0] }
                }
                Button("New Plan", systemImage: "plus") { showsNewPlan = true }
            } header: {
                Label("Your Plans", systemImage: "person.circle")
            } footer: {
                if !userPlans.isEmpty {
                    Text("Plans you've made or added. Swipe left on one to delete it.")
                }
            }
        }
        .environment(\.editMode, $editMode)
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

    /// A plan's name and description, its details behind the info button,
    /// and whether it is followed.
    private func row(_ plan: Plan) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name)
                if let description = plan.planDescription, !description.isEmpty {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { infoPlan = plan } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(plan.name)")
            Toggle(plan.name, isOn: isFollowing(plan))
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.vertical, 2)
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
        let plans = ReadingPlanLibrary.plansBySource()
        bundledPlans = plans.bundled
        userPlans = plans.user
        if userPlans.isEmpty { editMode = .inactive }
    }
}

#Preview {
    PlanPickerView()
}
