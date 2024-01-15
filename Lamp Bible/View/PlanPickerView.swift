//
//  PlanPickerView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import RealmSwift
import SwiftUI

struct PlanPickerView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isPlanOn: [Bool]
    // @todo Can't use an ObservedRealmObject here as though we can thaw and write to it, the toggle
    // implementation doesn't update properly
    let user: User
    let plans: Results<Plan>
    
    init(plans: Results<Plan>, user: User = RealmManager.shared.realm.objects(User.self).first!) {
        self.user = user
        self.plans = plans
        _isPlanOn = State(initialValue: plans.map { user.plans.contains($0) })
    }
    
    var body: some View {
        NavigationStack {
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
                        try! RealmManager.shared.realm.write {
                            if newValue {
                                // Add the plan to the user's plans list
                                if !user.plans.contains(plans[index]) {
                                    user.plans.append(plans[index])
                                }
                            } else {
                                // Remove the plan from the user's plans list
                                if let planIndex = user.plans.index(of: plans[index]) {
                                    user.plans.remove(at: planIndex)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Reading Plans")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Text(Image(systemName: "arrow.backward"))
                }
            }
        }
    }
}

#Preview {
    PlanPickerView(plans: RealmManager.shared.realm.objects(Plan.self))
}

