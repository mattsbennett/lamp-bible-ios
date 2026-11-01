//
//  ChapterListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import SwiftUI
import GRDB

/// A book's chapters as a grid of numbers, as the Mac's passage picker has
/// them, with the chapter being read tinted.
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

    /// The chapter being read, when it is in this book. verseId is BBCCCVVV.
    private var currentChapter: Int? {
        currentVerseId / 1000000 == book.id ? currentVerseId / 1000 % 1000 : nil
    }

    // Wider than the Mac's 38 by 30, so each is a comfortable tap.
    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(1...max(1, chapterCount), id: \.self) { chapter in
                        Button {
                            // Build verseId in BBCCCVVV format
                            currentVerseId = book.id * 1000000 + chapter * 1000 + 1
                            loadVersesClosure()
                            showingBookPicker = false
                        } label: {
                            Text(chapter.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    chapter == currentChapter
                                        ? AnyShapeStyle(.tint.opacity(0.25))
                                        : AnyShapeStyle(.quaternary),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.name) \(chapter)")
                        .accessibilityAddTraits(chapter == currentChapter ? .isSelected : [])
                        .id(chapter)
                    }
                }
                .padding()
            }
            // Open on the chapter being read, rather than at Psalm 1 with
            // the reader somewhere past 100.
            .onAppear {
                if let currentChapter { proxy.scrollTo(currentChapter, anchor: .center) }
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
