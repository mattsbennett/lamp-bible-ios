//
//  ReadingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-02-12.
//

import SwiftUI
import RealmSwift

struct ReadingsView: View {
    @ObservedRealmObject var user: User
    let planMetaData: PlanMetaData
    let stackHorizontally: Bool

    var body: some View {
        ConditionalStack(isHorizonalStack: stackHorizontally) {
            let readings = planMetaData.readingMetaData
            ForEach(readings.indices, id: \.self) { index in
                let readingMetaData = planMetaData.readingMetaData.first(where: { $0.index == index })!
                VStack(alignment: .leading) {
                    HStack {
                        let readingId = readingMetaData.id

                        Button {
                            if RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(readingId)'").count > 0 {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.removeCompletedReading(id: readingId)
                                }
                            } else {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.addCompletedReading(id: readingId)
                                }
                            }
                        } label: {
                            HStack {
                                if RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(readingId)'").count > 0 {
                                    Image(systemName: "checkmark").frame(width: 17)
                                } else {
                                    Image(systemName: "circle").frame(width: 17)
                                }
                                Text(readingMetaData.description).font(.body).foregroundStyle(Color.primary)
                            }
                        }
                        Spacer()
                        if user.planExternalBible != nil && user.planExternalBible != "None" {
                            Button {
                                let app = externalBibleApps.first(where: { $0.name == user.planExternalBible })
                                if let url = app?.getFullUrl(sv: readingMetaData.sv, ev: readingMetaData.ev) {
                                    if UIApplication.shared.canOpenURL(url) {
                                        UIApplication.shared.open(url)
                                        
                                        if RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(readingId)'").count == 0 {
                                            try! RealmManager.shared.realm.write {
                                                guard let thawedUser = user.thaw() else {
                                                    // Handle the inability to thaw the object
                                                    return
                                                }
                                                thawedUser.addCompletedReading(id: readingId)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: 2)
                                    Image("book.and.external.fill")
                                        .foregroundColor(Color.accentColor)
                                        .font(.title3)
                                }
                            }
                            .frame(width: 57, height: 57)
                            .clipShape(Circle())
                            .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.bottom, 10)
                    Spacer()
                    HStack {
                        Label {
                            Text("Portion")
                        } icon: {
                            HStack {
                                ForEach(0..<index + 1, id: \.self) { _ in
                                    Image("lampflame.fill")
                                        .font(.system(size: 16))
                                        .padding(.trailing, -11)
                                        .padding(.leading, -3)
                                }
                            }
                        }.labelStyle(TrailingIconLabelStyle())
                        Spacer()
                        Label("\(readingMetaData.genre)", systemImage: "bookmark.fill")
                        Spacer()
                        Label("\(readingMetaData.readingTime)", systemImage: "clock").labelStyle(TrailingIconLabelStyle())
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }
                .id(index)
                .padding()
                .if(stackHorizontally) { view in
                    view.frame(width: 325)
                }
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                        )
                )
            }
            Spacer()
        }
    }
}

