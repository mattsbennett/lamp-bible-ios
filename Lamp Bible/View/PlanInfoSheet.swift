//
//  PlanInfoSheet.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

/// A plan at more length than its row in the plan list has room for.
struct PlanInfoSheet: View {
    let plan: Plan
    @Environment(\.dismiss) private var dismiss

    /// A made plan has only its short description.
    private var fullDescription: String {
        let full = plan.fullDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return full.isEmpty ? plan.planDescription ?? "" : full
    }

    var body: some View {
        NavigationStack {
            List {
                Text(plan.name)
                    .font(.title)
                    .foregroundColor(.primary)
                    .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                    .bold()
                if let author = plan.author, !author.isEmpty {
                    Text(author)
                        .foregroundColor(.primary)
                        .italic()
                }
                if !fullDescription.isEmpty {
                    Text(fullDescription)
                        .font(.callout)
                        .foregroundColor(.primary)
                        .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                        .lineSpacing(8)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(Image(systemName: "xmark"))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(plan.name)
        }
    }
}

#Preview {
    PlanInfoSheet(plan: (try? BundledModuleDatabase.shared.getAllPlans().first) ?? Plan(id: "preview", name: "Preview Plan", planDescription: "A preview plan", author: "Author", fullDescription: "Full description"))
}
