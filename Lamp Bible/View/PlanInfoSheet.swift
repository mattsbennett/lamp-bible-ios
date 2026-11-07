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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        LampPlanArtwork(planId: plan.id, size: 72, isFollowed: UserDatabase.shared.getSettings().isPlanSelected(plan.id))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.name)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let author = plan.author, !author.isEmpty {
                                Text(author)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !fullDescription.isEmpty {
                        Text(fullDescription)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text(Image(systemName: "xmark"))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("About This Plan")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    PlanInfoSheet(plan: (try? BundledModuleDatabase.shared.getAllPlans().first) ?? Plan(id: "preview", name: "Preview Plan", planDescription: "A preview plan", author: "Author", fullDescription: "Full description"))
}
