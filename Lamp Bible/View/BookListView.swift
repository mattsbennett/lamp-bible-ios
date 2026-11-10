//
//  BookListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-01.
//

import SwiftUI
import GRDB

struct BookListView: View {
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    @Binding var translationId: String
    @Binding var translationAbbreviation: String
    let loadVersesClosure: () -> Void
    /// Takes the reader to a verse chosen by holding its chapter, as BBCCCVVV.
    let onPickVerse: (Int) -> Void
    var onTranslationChange: ((String) -> Void)? = nil

    private var userSettings: UserSettings {
        UserDatabase.shared.getSettings()
    }

    private var hiddenTranslations: String {
        userSettings.hiddenTranslations
    }

    /// Get all Bible books from GRDB
    private var books: [BibleBook] {
        (try? BundledModuleDatabase.shared.getAllBooks()) ?? []
    }

    /// Get available translations from GRDB
    private var availableTranslations: [TranslationModule] {
        (try? TranslationDatabase.shared.getAllTranslations()) ?? []
    }

    /// Filter to visible translations based on user preferences
    private var orderedVisibleTranslations: [TranslationModule] {
        let hiddenIds = Set(hiddenTranslations.split(separator: ",").map(String.init))
        return availableTranslations.filter { !hiddenIds.contains($0.id) }
    }

    /// Each book's chapter count in this translation, read once per opening.
    @State private var chapterCounts: [Int: Int] = [:]
    /// Books whose rows are on screen, for the testament switch's state.
    @State private var visibleBooks: Set<Int> = []
    /// Genre names, for the section headers.
    @State private var genreNames: [Int: String] = [:]
    /// Whether the list has been brought to the book being read, which it
    /// does once, so coming back from a book leaves it where it was.
    @State private var hasShownCurrentBook = false

    /// The book being read. verseId is BBCCCVVV.
    private var currentBook: Int { currentVerseId / 1000000 }

    /// The books in runs of one genre (Law, History, …), in canonical order,
    /// so the list has landmarks rather than 66 identical rows.
    private var sections: [BookRunSection] {
        var result: [BookRunSection] = []
        for book in books {
            if let last = result.last, last.genre == book.genre, last.testament == book.testament {
                result[result.count - 1].books.append(book)
            } else {
                let opensTestament = result.last?.testament != book.testament
                result.append(BookRunSection(genre: book.genre, testament: book.testament,
                                          opensTestament: opensTestament, books: [book]))
            }
        }
        return result
    }

    var body: some View {
        // A stack, for the verses a held chapter pushes.
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.books) { book in
                            NavigationLink(
                                destination: ChapterListView(
                                    currentVerseId: $currentVerseId,
                                    showingBookPicker: $showingBookPicker,
                                    book: book,
                                    translationId: translationId,
                                    loadVersesClosure: loadVersesClosure,
                                    onPickVerse: onPickVerse
                                )
                            ) {
                                bookRow(book)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 16))
                            .id(book.id)
                            .onAppear { visibleBooks.insert(book.id) }
                            .onDisappear { visibleBooks.remove(book.id) }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .contentMargins(.top, 4, for: .scrollContent)
            // A jump to either testament in a band of its own at the foot, so
            // it covers no rows, showing which testament the list is in.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                testamentJump(proxy)
            }
            // Open on the book being read, in its testament, rather than at
            // Genesis with the reader in Matthew. A turn of the run loop
            // later, once the list has laid out its rows.
            .onAppear {
                guard !hasShownCurrentBook else { return }
                hasShownCurrentBook = true
                let book = currentBook
                DispatchQueue.main.async {
                    proxy.scrollTo(book, anchor: .center)
                }
            }
            }
            .task(id: translationId) {
                loadCounts()
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
                        TranslationLanguageSections(translations: orderedVisibleTranslations) { items in
                            ForEach(items, id: \.id) { trans in
                                Button {
                                    translationId = trans.id
                                    translationAbbreviation = trans.abbreviation
                                    onTranslationChange?(trans.id)
                                } label: {
                                    // A menu item's second text is its subtitle:
                                    // the badge a list row gives a tagged text.
                                    Text(trans.name)
                                    if trans.features?.strongs == true {
                                        Text("Strong’s numbers")
                                    }
                                    if trans.id == translationId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(translationAbbreviation)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .modifier(ConditionalGlassButtonStyle())
                }
            }
        }
    }

    /// The testament at the top of the visible rows.
    private var visibleTestament: String {
        (visibleBooks.min() ?? 1) >= 40 ? "NT" : "OT"
    }

    private func testamentJump(_ proxy: ScrollViewProxy) -> some View {
        Picker("Testament", selection: Binding(
            get: { visibleTestament },
            set: { testament in
                if let first = books.first(where: { $0.testament == testament }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        )) {
            Text("Old Testament").tag("OT")
            Text("New Testament").tag("NT")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            LampTheme.groupedBackground
                .overlay(alignment: .top) { Divider() }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func bookRow(_ book: BibleBook) -> some View {
        let isCurrent = book.id == currentBook
        return HStack(spacing: 8) {
            Text(book.name)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            Spacer(minLength: 8)
            if let count = chapterCounts[book.id], count > 0 {
                Text(count.formatted())
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(LampTheme.caption)
                    .accessibilityLabel(count == 1 ? "1 chapter" : "\(count) chapters")
            }
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func sectionHeader(_ section: BookRunSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if section.opensTestament {
                Text(section.testament == "NT" ? "New Testament" : "Old Testament")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.primary)
                    .textCase(nil)
                    .padding(.top, section.testament == "NT" ? 12 : 0)
            }
            if let name = genreNames[section.genre] {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
            }
        }
    }

    private func loadCounts() {
        var counts: [Int: Int] = [:]
        for book in books {
            counts[book.id] = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: book.id)) ?? 0
        }
        chapterCounts = counts
        if genreNames.isEmpty {
            let genres = (try? BundledModuleDatabase.shared.getAllGenres()) ?? []
            genreNames = Dictionary(genres.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

/// A run of books of one genre within a testament.
private struct BookRunSection: Identifiable {
    let genre: Int
    let testament: String
    let opensTestament: Bool
    var books: [BibleBook]

    var id: String { "\(testament)-\(genre)-\(books.first?.id ?? 0)" }
}
