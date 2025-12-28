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
    @Binding var showingBookPicker: Bool
    @Binding var showingOptionsMenu: Bool
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
            Button {
                if readingMetaData == nil {
                    showingBookPicker = true
                }
            } label: {
                VStack {
                    let currentVerse = RealmManager.shared.realm.objects(Verse.self).filter("id == \(currentVerseId)").first
                    let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(currentVerse!.b)").first
                    Text(translation.abbreviation).bold().font(.system(size: 14))
                    Text(book!.name + " \(currentVerse!.c)").font(.caption2).foregroundStyle(Color.primary)
                }
                .padding(.horizontal, 4)
            }
            .disabled(readingMetaData != nil)
            .modifier(ConditionalGlassButtonStyle())
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                showingOptionsMenu = true
            } label: {
                Image(systemName: "ellipsis")
            }
            .popover(isPresented: $showingOptionsMenu) {
                VStack(alignment: .leading, spacing: 8) {
                    // Tools toggle (only shown when notes are enabled)
                    if user.notesEnabled {
                        Button {
                            try! RealmManager.shared.realm.write {
                                guard let thawedUser = user.thaw() else { return }
                                thawedUser.notesPanelVisible.toggle()
                            }
                        } label: {
                            Label(
                                user.notesPanelVisible ? "Hide Tools" : "Show Tools",
                                systemImage: user.notesPanelVisible ? "rectangle.portrait" : "inset.filled.bottomhalf.rectangle.portrait"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(14)
                    }

                    // Font size controls - compact row
                    HStack(spacing: 0) {
                        Button {
                            if user.readerFontSize > 12 {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else { return }
                                    thawedUser.readerFontSize = thawedUser.readerFontSize - 2
                                }
                            }
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(user.readerFontSize <= 12)

                        Divider()
                            .frame(height: 20)

                        Button {
                            if user.readerFontSize < 30 {
                                try! RealmManager.shared.realm.write {
                                    guard let thawedUser = user.thaw() else { return }
                                    thawedUser.readerFontSize = thawedUser.readerFontSize + 2
                                }
                            }
                        } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(user.readerFontSize >= 30)
                    }
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(14)
                }
                .font(.body)
                .fontWeight(.regular)
                .padding(12)
                .background(Color(UIColor.systemGroupedBackground))
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}
