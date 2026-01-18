//
//  ChapterListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import SwiftUI
import GRDB

struct ChapterListView: View {
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    let book: BibleBook
    let translationId: String
    let loadVersesClosure: () -> Void

    /// Get chapter count for the book from GRDB
    private var chapterCount: Int {
        (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: book.id)) ?? 0
    }

    var body: some View {
        List {
            ForEach(1...max(1, chapterCount), id: \.self) { chapter in
                HStack {
                    Button(String("\(book.name) \(chapter)")) {
                        // Build verseId in BBCCCVVV format
                        currentVerseId = book.id * 1000000 + chapter * 1000 + 1
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
