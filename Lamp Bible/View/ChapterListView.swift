//
//  ChapterListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import SwiftUI
import RealmSwift

struct ChapterListView: View {
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    let book: Book
    let verses: Results<Verse>
    let loadVersesClosure: () -> Void

    var body: some View {
        List {
            ForEach(verses) { verse in
                HStack {
                    Button(String("\(book.name) \(verse.c)")) {
                        currentVerseId = verse.id
                        loadVersesClosure()
                        showingBookPicker = false
                    }
                        .foregroundColor(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(Color.gray.opacity(0.5))
                        .font(Font.system(size: 14, weight: .bold, design: .default))
                }
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
