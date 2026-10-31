//
//  PlanPickerView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

struct PlanPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isPlanOn: [Bool]
    @State private var userSettings: UserSettings
    @State private var plans: [Plan] = []
    @State private var showsNewPlan = false

    init() {
        let settings = UserDatabase.shared.getSettings()
        _userSettings = State(initialValue: settings)
        let allPlans = ReadingPlanLibrary.allPlans()
        _plans = State(initialValue: allPlans)
        _isPlanOn = State(initialValue: allPlans.map { settings.isPlanSelected($0.id) })
    }

    var body: some View {
        // Pushed onto Plans' or Settings' stack, so New Plan is pushed there too.
        Form {
            ForEach(plans.indices, id: \.self) { index in
                Section {
                    Toggle(isOn: $isPlanOn[index]) {
                        Text(plans[index].name)
                    }.tint(.accentColor)
                } footer: {
                    PlanFooterView(plan: plans[index])
                }
                .onChange(of: isPlanOn[index]) { oldValue, newValue in
                    if newValue {
                        userSettings.addPlan(plans[index].id)
                    } else {
                        userSettings.removePlan(plans[index].id)
                    }
                    try? UserDatabase.shared.updateSettings { $0 = userSettings }
                    WidgetDataService.shared.refreshWidget()
                }
            }
        }
        .navigationDestination(isPresented: $showsNewPlan) {
            NewPlanView { _ in
                reload()
                showsNewPlan = false
            }
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

    /// Every plan and setting read again: a plan just made is followed in
    /// the settings, which this view's copy must not then write over.
    private func reload() {
        let settings = UserDatabase.shared.getSettings()
        userSettings = settings
        plans = ReadingPlanLibrary.allPlans()
        isPlanOn = plans.map { settings.isPlanSelected($0.id) }
    }
}

#Preview {
    PlanPickerView()
}
