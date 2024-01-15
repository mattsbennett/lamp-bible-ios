//
//  ContentView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI

struct ContentView: View {
    @State private var showingPicker = false
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            PlanView(
                user: RealmManager.shared.realm.objects(User.self).first!,
                plans: RealmManager.shared.realm.objects(Plan.self)
            )
        }
    }
}

#Preview {
    ContentView()
}
