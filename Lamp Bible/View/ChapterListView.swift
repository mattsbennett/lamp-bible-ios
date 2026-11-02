//
//  ChapterListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import SwiftUI
import GRDB

/// A book's chapters as a grid of numbers, as the Mac's passage picker has
/// them, with the chapter being read tinted. A tap opens a chapter at its
/// start; touching and holding one shows its verses to choose from.
struct ChapterListView: View {
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    let book: BibleBook
    let translationId: String
    let loadVersesClosure: () -> Void
    /// Takes the reader to a verse, given as BBCCCVVV.
    let onPickVerse: (Int) -> Void

    /// The chapter held down, whose verses are being chosen from.
    @State private var heldChapter: Int?
    /// The chapter under a finger, dimmed as a pressed button would be.
    @State private var pressedChapter: Int?

    /// Get chapter count for the book from GRDB
    private var chapterCount: Int {
        (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: book.id)) ?? 0
    }

    /// The chapter being read, when it is in this book. verseId is BBCCCVVV.
    private var currentChapter: Int? {
        currentVerseId / 1000000 == book.id ? currentVerseId / 1000 % 1000 : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: PassageNumberLabel.columns, spacing: 8) {
                        ForEach(1...max(1, chapterCount), id: \.self) { chapter in
                            chapterTile(chapter)
                        }
                    }
                    Text("Touch and hold a chapter to choose a verse.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
        .navigationDestination(item: $heldChapter) { chapter in
            VerseGridView(
                book: book,
                chapter: chapter,
                translationId: translationId,
                currentVerse: currentVerseId / 1000 == book.id * 1000 + chapter
                    ? currentVerseId % 1000 : nil
            ) { verse in
                onPickVerse(book.id * 1000000 + chapter * 1000 + verse)
                showingBookPicker = false
            }
        }
        .sensoryFeedback(.selection, trigger: heldChapter) { _, held in held != nil }
    }

    /// A chapter to tap, or to hold for its verses. Gestures rather than a
    /// Button, so that letting go of a hold doesn't open the chapter too.
    private func chapterTile(_ chapter: Int) -> some View {
        let open = {
            // Build verseId in BBCCCVVV format
            currentVerseId = book.id * 1000000 + chapter * 1000 + 1
            loadVersesClosure()
            showingBookPicker = false
        }
        return PassageNumberLabel(number: chapter, isCurrent: chapter == currentChapter)
            .opacity(pressedChapter == chapter ? 0.5 : 1)
            .onTapGesture(perform: open)
            .onLongPressGesture {
                heldChapter = chapter
            } onPressingChanged: { pressing in
                pressedChapter = pressing ? chapter : nil
            }
            .accessibilityLabel("\(book.name) \(chapter)")
            .accessibilityAddTraits(chapter == currentChapter ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
            .accessibilityAction(named: "Choose Verse") { heldChapter = chapter }
            .id(chapter)
    }
}

/// A chapter's verses as a grid of numbers, reached by holding the chapter.
private struct VerseGridView: View {
    let book: BibleBook
    let chapter: Int
    let translationId: String
    /// The verse being read, when it is in this chapter.
    let currentVerse: Int?
    let onPick: (Int) -> Void

    /// The chapter's verse numbers. A translation can leave a verse out, so
    /// these are read rather than counted.
    @State private var verses: [Int] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: PassageNumberLabel.columns, spacing: 8) {
                    ForEach(verses, id: \.self) { verse in
                        Button {
                            onPick(verse)
                        } label: {
                            PassageNumberLabel(number: verse, isCurrent: verse == currentVerse)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.name) \(chapter):\(verse)")
                        .accessibilityAddTraits(verse == currentVerse ? .isSelected : [])
                        .id(verse)
                    }
                }
                .padding()
            }
            .onAppear {
                verses = (try? TranslationDatabase.shared.getVerseNumbers(
                    translationId: translationId, book: book.id, chapter: chapter
                )) ?? []
            }
            .onChange(of: verses) {
                if let currentVerse { proxy.scrollTo(currentVerse, anchor: .center) }
            }
        }
        .navigationTitle("\(book.name) \(chapter)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A chapter or verse number in the picker's grid, tinted when it is the one
/// being read.
private struct PassageNumberLabel: View {
    let number: Int
    let isCurrent: Bool

    // Wider than the Mac's 38 by 30, so each is a comfortable tap.
    static let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        Text(number.formatted())
            .monospacedDigit()
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isCurrent ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
    }
}
