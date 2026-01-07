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
    var onTranslationChange: ((Int) -> Void)? = nil

    @AppStorage("hiddenTranslations") private var hiddenTranslations: String = ""

    private var orderedVisibleTranslations: [Translation] {
        visibleTranslations(hiddenString: hiddenTranslations)
    }

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
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(orderedVisibleTranslations) { trans in
                            Button {
                                translation = trans
                                onTranslationChange?(trans.id)
                            } label: {
                                if trans.id == translation.id {
                                    Label(trans.name, systemImage: "checkmark")
                                } else {
                                    Text(trans.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(translation.abbreviation)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .modifier(ConditionalGlassButtonStyle())
                }
            }
        }
    }
}
