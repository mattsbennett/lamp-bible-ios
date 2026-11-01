//
//  PlanPickerView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

struct PlanPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var userSettings = UserDatabase.shared.getSettings()
    @State private var bundledPlans: [Plan] = []
    @State private var userPlans: [Plan] = []
    @State private var showsNewPlan = false
    @State private var planToDelete: Plan?
    @State private var deleteError: String?

    init() {
        let plans = ReadingPlanLibrary.plansBySource()
        _bundledPlans = State(initialValue: plans.bundled)
        _userPlans = State(initialValue: plans.user)
    }

    var body: some View {
        // Pushed onto Plans' or Settings' stack, so New Plan is pushed there too.
        Form {
            planSections(bundledPlans, titled: "Included", deletable: false)
            planSections(userPlans, titled: "Your Plans", deletable: true)
        }
        .navigationDestination(isPresented: $showsNewPlan) {
            NewPlanView { _ in
                reload()
                showsNewPlan = false
            }
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
            ToolbarItem(placement: .primaryAction) {
                Button("New Plan", systemImage: "plus") { showsNewPlan = true }
            }
        }
    }

    /// A section a plan, the first headed by where the plans come from.
    @ViewBuilder
    private func planSections(_ plans: [Plan], titled title: String, deletable: Bool) -> some View {
        ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
            Section {
                Toggle(isOn: isFollowing(plan)) {
                    Text(plan.name)
                }
                .tint(.accentColor)
                .swipeActions {
                    if deletable {
                        Button("Delete", systemImage: "trash") { planToDelete = plan }
                            .tint(.red)
                    }
                }
            } header: {
                if index == 0 { Text(title) }
            } footer: {
                PlanFooterView(plan: plan, onDelete: deletable ? { Task { await delete(plan) } } : nil)
            }
        }
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
    }
}

#Preview {
    PlanPickerView()
}
