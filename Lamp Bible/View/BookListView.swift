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

    var body: some View {
        NavigationView {
            List {
                ForEach(books) { book in
                    NavigationLink(
                        destination: ChapterListView(
                            currentVerseId: $currentVerseId,
                            showingBookPicker: $showingBookPicker,
                            book: book,
                            translationId: translationId,
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
                        ForEach(orderedVisibleTranslations, id: \.id) { trans in
                            Button {
                                translationId = trans.id
                                translationAbbreviation = trans.abbreviation
                                onTranslationChange?(trans.id)
                            } label: {
                                if trans.id == translationId {
                                    Label(trans.name, systemImage: "checkmark")
                                } else {
                                    Text(trans.name)
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
}
