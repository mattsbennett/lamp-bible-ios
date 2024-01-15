//
//  PlanFooterView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-02.
//

import SwiftUI

struct PlanFooterView: View {
    let plan: Plan
    @State private var showingInfoSheet = false
    
    var body: some View {
        VStack {
            Text(plan.shortDescription).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
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
                                Text(plan.author)
                                    .foregroundColor(.primary)
                                    .italic()
                                Text(plan.fullDescription)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                                    .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
                                    .lineSpacing(8)
                            }
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
    PlanFooterView(plan: RealmManager.shared.realm.objects(Plan.self).first!)
}
