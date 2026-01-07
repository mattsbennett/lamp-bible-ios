    //
//  ModuleSettingsView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-03.
//

import SwiftUI
import RealmSwift
import GRDB

struct ModuleSettingsView: View {
    @ObservedRealmObject var user: User
    @Environment(\.dismiss) var dismiss

    // Translation settings
    @AppStorage("hiddenTranslations") private var hiddenTranslations: String = ""

    // Lexicon settings
    @AppStorage("showStrongsHints") private var showStrongsHints: Bool = false
    @AppStorage("greekLexiconOrder") private var greekLexiconOrder: String = "strongs,dodson"
    @AppStorage("hebrewLexiconOrder") private var hebrewLexiconOrder: String = "strongs,bdb"
    @AppStorage("hiddenGreekLexicons") private var hiddenGreekLexicons: String = ""
    @AppStorage("hiddenHebrewLexicons") private var hiddenHebrewLexicons: String = ""

    private let generator = UINotificationFeedbackGenerator()

    var body: some View {
        Form {
            // MARK: - Translations Section
            Section {
                TranslationList(
                    user: user,
                    hiddenString: $hiddenTranslations,
                    onSetDefault: { translationId in
                        setDefaultTranslation(translationId)
                    }
                )
            } header: {
                Text("Translations")
            } footer: {
                Text("Tap to set default. Swipe to hide.")
            }

            // MARK: - Lexicons Section
            Section {
                Toggle(isOn: $showStrongsHints) {
                    Text("Show Word Hints")
                }.tint(.accentColor)
            } header: {
                Text("Lexicons")
            } footer: {
                Text("Show visual hints for words with Strong's numbers in supported translations (BSBs, KJVs).")
            }

            Section {
                LexiconOrderListWithHiding(
                    orderString: $greekLexiconOrder,
                    hiddenString: $hiddenGreekLexicons,
                    builtInLexicons: [
                        ("strongs", "Strong's Greek"),
                        ("dodson", "Dodson")
                    ],
                    keyType: "strongs-greek"
                )
            } header: {
                Text("Greek Lexicons")
            } footer: {
                Text("Drag to reorder (to set order shown in Lexicon view). Swipe to hide.")
            }

            Section {
                LexiconOrderListWithHiding(
                    orderString: $hebrewLexiconOrder,
                    hiddenString: $hiddenHebrewLexicons,
                    builtInLexicons: [
                        ("strongs", "Strong's Hebrew"),
                        ("bdb", "Brown-Driver-Briggs")
                    ],
                    keyType: "strongs-hebrew"
                )
            } header: {
                Text("Hebrew Lexicons")
            } footer: {
                Text("Drag to reorder. Swipe to hide.")
            }

            // MARK: - Cross References Section
            Section {
                CrossReferenceSortPicker(user: user)
            } header: {
                Text("Cross References")
            } footer: {
                Text("Sort order for cross references in the reader.")
            }
        }
        .navigationTitle("Module Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setDefaultTranslation(_ translationId: Int) {
        let realm = RealmManager.shared.realm
        guard let translation = realm.object(ofType: Translation.self, forPrimaryKey: translationId) else { return }

        try? realm.write {
            guard let thawedUser = user.thaw() else { return }
            thawedUser.readerTranslation = translation
            generator.notificationOccurred(.success)
        }
    }
}

// MARK: - Cross Reference Sort Picker

struct CrossReferenceSortPicker: View {
    @ObservedRealmObject var user: User
    private let generator = UINotificationFeedbackGenerator()

    private let sorts = ["r", "sv"]
    private let sortNames = ["Relevance", "Verse"]

    var body: some View {
        ForEach(sorts.indices, id: \.self) { index in
            HStack {
                Button {
                    try? RealmManager.shared.realm.write {
                        guard let thawedUser = user.thaw() else { return }
                        thawedUser.readerCrossReferenceSort = sorts[index]
                        generator.notificationOccurred(.success)
                    }
                } label: {
                    Text(sortNames[index])
                        .tint(.primary)
                }
                Spacer()
                if user.readerCrossReferenceSort == sorts[index] {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

// MARK: - Translation List

struct TranslationList: View {
    @ObservedRealmObject var user: User
    @Binding var hiddenString: String
    let onSetDefault: (Int) -> Void

    private var defaultTranslationId: Int {
        user.readerTranslation?.id ?? 0
    }

    private var allTranslations: [Translation] {
        Array(RealmManager.shared.realm.objects(Translation.self))
    }

    private var hiddenIds: Set<Int> {
        parseHiddenTranslationIds(hiddenString)
    }

    private var visibleTranslationsList: [Translation] {
        allTranslations.filter { !hiddenIds.contains($0.id) }
    }

    private var hiddenTranslationsList: [Translation] {
        allTranslations.filter { hiddenIds.contains($0.id) }
    }

    var body: some View {
        ForEach(visibleTranslationsList) { translation in
            TranslationRow(
                translation: translation,
                isDefault: translation.id == defaultTranslationId,
                onTap: { onSetDefault(translation.id) }
            )
            .swipeActions(edge: .trailing) {
                if visibleTranslationsList.count > 1 {
                    Button {
                        hideTranslation(translation.id)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                    .tint(.orange)
                }
            }
        }

        if !hiddenTranslationsList.isEmpty {
            Text("Hidden")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden, edges: .bottom)

            ForEach(hiddenTranslationsList) { translation in
                HStack {
                    Text(translation.name)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.tertiary)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        showTranslation(translation.id)
                    } label: {
                        Label("Show", systemImage: "eye")
                    }
                    .tint(.green)
                }
            }
        }
    }

    private func hideTranslation(_ id: Int) {
        var hidden = hiddenIds
        hidden.insert(id)
        hiddenString = hidden.map { String($0) }.joined(separator: ",")
    }

    private func showTranslation(_ id: Int) {
        var hidden = hiddenIds
        hidden.remove(id)
        hiddenString = hidden.map { String($0) }.joined(separator: ",")
    }
}

struct TranslationRow: View {
    let translation: Translation
    let isDefault: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Button(action: onTap) {
                Text(translation.name)
                    .tint(.primary)
            }
            Spacer()
            if isDefault {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - Lexicon Order List with Hiding

struct LexiconOrderListWithHiding: View {
    @Binding var orderString: String
    @Binding var hiddenString: String
    let builtInLexicons: [(key: String, name: String)]
    let keyType: String

    private var hiddenKeys: Set<String> {
        Set(hiddenString.split(separator: ",").map { String($0) })
    }

    private var allLexicons: [(key: String, name: String)] {
        var available = builtInLexicons

        // Discover user dictionary modules with matching keyType
        if let modules = try? ModuleDatabase.shared.getAllModules(type: .dictionary) {
            for module in modules {
                if module.keyType == keyType {
                    available.append((key: "user-\(module.id)", name: module.name))
                }
            }
        }

        return available
    }

    private var orderedLexicons: [(key: String, name: String)] {
        let storedOrder = orderString.split(separator: ",").map { String($0) }
        let available = allLexicons

        var ordered: [(key: String, name: String)] = []

        // First add items from stored order that still exist
        for key in storedOrder {
            if let item = available.first(where: { $0.key == key }) {
                ordered.append(item)
            }
        }

        // Then append any new items not in stored order
        for item in available {
            if !ordered.contains(where: { $0.key == item.key }) {
                ordered.append(item)
            }
        }

        return ordered
    }

    private var visibleLexicons: [(key: String, name: String)] {
        orderedLexicons.filter { !hiddenKeys.contains($0.key) }
    }

    private var hiddenLexiconsList: [(key: String, name: String)] {
        orderedLexicons.filter { hiddenKeys.contains($0.key) }
    }

    var body: some View {
        ForEach(Array(visibleLexicons.enumerated()), id: \.element.key) { _, lexicon in
            HStack {
                Text(lexicon.name)
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
            }
            .swipeActions(edge: .trailing) {
                if visibleLexicons.count > 1 {
                    Button {
                        hideLexicon(lexicon.key)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                    .tint(.orange)
                }
            }
        }
        .onMove { from, to in
            var items = visibleLexicons
            items.move(fromOffsets: from, toOffset: to)

            // Rebuild full order: moved visible items + hidden items
            let visibleKeys = items.map { $0.key }
            let hiddenKeysArray = hiddenLexiconsList.map { $0.key }
            orderString = (visibleKeys + hiddenKeysArray).joined(separator: ",")
        }

        if !hiddenLexiconsList.isEmpty {
            Text("Hidden")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden, edges: .bottom)

            ForEach(Array(hiddenLexiconsList.enumerated()), id: \.element.key) { _, lexicon in
                HStack {
                    Text(lexicon.name)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.tertiary)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        showLexicon(lexicon.key)
                    } label: {
                        Label("Show", systemImage: "eye")
                    }
                    .tint(.green)
                }
            }
        }
    }

    private func hideLexicon(_ key: String) {
        var hidden = hiddenKeys
        hidden.insert(key)
        hiddenString = hidden.map { String($0) }.joined(separator: ",")
    }

    private func showLexicon(_ key: String) {
        var hidden = hiddenKeys
        hidden.remove(key)
        hiddenString = hidden.map { String($0) }.joined(separator: ",")
    }
}

#Preview {
    NavigationStack {
        ModuleSettingsView(user: RealmManager.shared.realm.objects(User.self).first!)
    }
}
