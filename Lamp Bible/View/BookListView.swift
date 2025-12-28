//
//  BookListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-01.
//

import SwiftUI
import RealmSwift

struct BookListView: View {
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    @Binding var translation: Translation
    let loadVersesClosure: () -> Void

    @State private var showingTranslationPicker: Bool = false

    var body: some View {
        NavigationView {
            List {
                ForEach(RealmManager.shared.realm.objects(Book.self)) { book in
                    NavigationLink(
                        destination: ChapterListView(
                            currentVerseId: $currentVerseId,
                            showingBookPicker: $showingBookPicker,
                            book: book,
                            verses: RealmManager.shared.realm.objects(Verse.self).distinct(by: ["c"]).filter("b == \(book.id) AND v == 1"),
                            loadVersesClosure: loadVersesClosure
                        )
                    ) {
                        Text(book.name)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showingBookPicker = false
                    } label: {
                        Text(Image(systemName: "xmark"))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        showingTranslationPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(translation.abbreviation)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .modifier(ConditionalGlassButtonStyle())
                    .popover(isPresented: $showingTranslationPicker) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(RealmManager.shared.realm.objects(Translation.self)) { trans in
                                Button {
                                    translation = trans
                                    showingTranslationPicker = false
                                } label: {
                                    HStack {
                                        Text("\(trans.name) (\(trans.abbreviation))")
                                        Spacer()
                                        if trans.id == translation.id {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)

                                if trans.id != RealmManager.shared.realm.objects(Translation.self).last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
        }
    }
}
