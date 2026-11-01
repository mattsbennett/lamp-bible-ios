//
//  PlanFooterView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

struct PlanFooterView: View {
    let plan: Plan
    /// Deletes the plan, already confirmed; nil for a bundled plan.
    var onDelete: (() -> Void)? = nil
    @State private var showingInfoSheet = false
    @State private var confirmsDelete = false

    /// A made plan has only its short description.
    private var fullDescription: String {
        let full = plan.fullDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return full.isEmpty ? plan.planDescription ?? "" : full
    }

    var body: some View {
        VStack {
            Text(plan.planDescription ?? "").frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            HStack {
                Button {
                    showingInfoSheet.toggle()
                } label: {
                    Text(Image(systemName: "info.circle.fill"))
                    Text("Learn More")
                        .padding(EdgeInsets(top: 0, leading: -4, bottom: 0, trailing: 0))
                }
                .font(.footnote)
                .sheet(isPresented: $showingInfoSheet) {
                    NavigationStack {
                        VStack {
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
                                if onDelete != nil {
                                    Section {
                                        Button("Delete Plan", systemImage: "trash", role: .destructive) {
                                            confirmsDelete = true
                                        }
                                    }
                                }
                            }
                        }
                        .confirmationDialog("Delete “\(plan.name)”?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                            Button("Delete Plan", role: .destructive) {
                                showingInfoSheet = false
                                onDelete?()
                            }
                        } message: {
                            Text("The plan is deleted here and on any device you sync with.")
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { self.showingInfoSheet = false } label: {
                                    Text(Image(systemName: "xmark"))
                                }
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .navigationTitle(plan.name)
                    }
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

#Preview {
    PlanFooterView(plan: (try? BundledModuleDatabase.shared.getAllPlans().first) ?? Plan(id: "preview", name: "Preview Plan", planDescription: "A preview plan", author: "Author", fullDescription: "Full description"))
}
