//
//  PlanDateToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI

struct PlanDateToolbarView: ToolbarContent {
    @Binding var date: Date
    @Binding var showingDatePicker: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                date = Calendar.current.date(byAdding: .day, value: -1, to: date)!
            } label: {
                Text(Image(systemName: "chevron.left"))
            }
            .padding(.vertical)
        }
        ToolbarItem(placement: .principal) {
            HStack {
                Text(Image(systemName: "calendar"))
                Text(date, format: (Calendar.current.dateComponents([.year], from: date).year! == Calendar.current.dateComponents([.year], from: Date.now).year!) ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday().day().month().year()
                )
            }
                .foregroundColor(.accentColor)
                .onTapGesture {
                    showingDatePicker.toggle()
                }
                .sheet(
                    isPresented: $showingDatePicker
                ) {
                    NavigationStack {
                        DatePicker(selection: $date, displayedComponents: [.date]){
                        }
                            .datePickerStyle(.graphical)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button {
                                        date = Date.now
                                        showingDatePicker = false
                                    } label: {
                                        Text("Today")
                                    }
                                }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button {
                                        showingDatePicker = false
                                    } label: {
                                        Text("Done")
                                    }
                                }
                            }
                        }
                        .presentationDetents([.height(455)])
                        .presentationDragIndicator(.visible)
                        .padding()
                }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
            } label: {
                Text(Image(systemName: "chevron.right"))
            }
            .padding(.vertical)
        }
    }
}
