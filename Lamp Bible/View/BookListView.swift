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
    let loadVersesClosure: () -> Void
    
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
            .navigationTitle("Books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showingBookPicker = false
                    } label: {
                        Text(Image(systemName: "xmark"))
                    }
                }
            }
        }
    }
}
