//
//  ReaderNavigationToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI
import RealmSwift

struct ReaderNavigationToolbarView: ToolbarContent {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var translation: Translation
    @Binding var currentVerseId: Int
    @Binding var showingDisplayOptions: Bool
    @Binding var showingBookPicker: Bool
    let readerDismiss: DismissAction
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                readerDismiss()
            } label: {
                Text(Image(systemName: "arrow.backward"))
            }
        }
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(RealmManager.shared.realm.objects(Translation.self)) { trans in
                    Button("\(trans.name) (\(trans.abbreviation))") {
                        translation = trans
                    }
                }
            } label: {
                VStack {
                    let currentVerse = RealmManager.shared.realm.objects(Verse.self).filter("id == \(currentVerseId)").first
                    let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(currentVerse!.b)").first
                    Text(translation.abbreviation).bold()
                    Text(book!.name + " \(currentVerse!.c)").font(.caption).foregroundStyle(Color.primary)
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            HStack {
                Button {
                    showingDisplayOptions = true
                } label: {
                    Text(Image(systemName: "textformat.size"))
                }
                .popover(
                    isPresented: $showingDisplayOptions, attachmentAnchor: .point(UnitPoint(x: 0.5, y: 0)), arrowEdge: .bottom
                ) {
                    HStack {
                        Spacer()
                        Button {
                            if user.readerFontSize >= 14 {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.readerFontSize = thawedUser.readerFontSize - 2
                                }
                            }
                        } label: {
                            Label("Smaller Text", systemImage: "textformat.size.smaller").labelStyle(.iconOnly)
                        }
                        .disabled(user.readerFontSize == 12)
                        Spacer()
                        Divider()
                        Spacer()
                        Button {
                            if user.readerFontSize <= 28 {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else {
                                        // Handle the inability to thaw the object
                                        return
                                    }
                                    thawedUser.readerFontSize = thawedUser.readerFontSize + 2
                                }
                            }
                        } label: {
                            Label("Larger Text", systemImage: "textformat.size.larger").labelStyle(.iconOnly)
                        }
                        .disabled(user.readerFontSize == 30)
                        Spacer()
                    }
                    .presentationCompactAdaptation(.popover)
                    .frame(minWidth: 180, minHeight: 35)
                }
                if readingMetaData == nil {
                    Button {
                        showingBookPicker = true
                    } label: {
                        Text(Image(systemName: "line.3.horizontal"))
                    }
                }
            }
        }
    }
}
