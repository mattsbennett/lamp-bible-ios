//
//  ModuleSettingsView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-03.
//

import SwiftUI
import GRDB

struct ModuleSettingsView: View {
    @Binding var userSettings: UserSettings
    @Environment(\.dismiss) var dismiss

    private let generator = UINotificationFeedbackGenerator()

    // Binding helpers that persist to database
    private var hiddenTranslations: Binding<String> {
        Binding(
            get: { userSettings.hiddenTranslations },
            set: { newValue in
                userSettings.hiddenTranslations = newValue
                try? UserDatabase.shared.updateSettings { $0.hiddenTranslations = newValue }
            }
        )
    }

    private var showStrongsHints: Binding<Bool> {
        Binding(
            get: { userSettings.showStrongsHints },
            set: { newValue in
                userSettings.showStrongsHints = newValue
                try? UserDatabase.shared.updateSettings { $0.showStrongsHints = newValue }
            }
        )
    }

    private var greekLexiconOrder: Binding<String> {
        Binding(
            get: { userSettings.greekLexiconOrder },
            set: { newValue in
                userSettings.greekLexiconOrder = newValue
                try? UserDatabase.shared.updateSettings { $0.greekLexiconOrder = newValue }
            }
        )
    }

    private var hebrewLexiconOrder: Binding<String> {
        Binding(
            get: { userSettings.hebrewLexiconOrder },
            set: { newValue in
                userSettings.hebrewLexiconOrder = newValue
                try? UserDatabase.shared.updateSettings { $0.hebrewLexiconOrder = newValue }
            }
        )
    }

    private var hiddenGreekLexicons: Binding<String> {
        Binding(
            get: { userSettings.hiddenGreekLexicons },
            set: { newValue in
                userSettings.hiddenGreekLexicons = newValue
                try? UserDatabase.shared.updateSettings { $0.hiddenGreekLexicons = newValue }
            }
        )
    }

    private var hiddenHebrewLexicons: Binding<String> {
        Binding(
            get: { userSettings.hiddenHebrewLexicons },
            set: { newValue in
                userSettings.hiddenHebrewLexicons = newValue
                try? UserDatabase.shared.updateSettings { $0.hiddenHebrewLexicons = newValue }
            }
        )
    }

    var body: some View {
        Form {
            // MARK: - Translations Section
            Section {
                TranslationList(
                    userSettings: $userSettings,
                    hiddenString: hiddenTranslations,
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
                Toggle(isOn: showStrongsHints) {
                    Text("Show Word Hints")
                }.tint(.accentColor)
            } header: {
                Text("Lexicons")
            } footer: {
                Text("Show visual hints for words with Strong's numbers in supported translations (BSBs, KJVs).")
            }

            Section {
                LexiconOrderListWithHiding(
                    orderString: greekLexiconOrder,
                    hiddenString: hiddenGreekLexicons,
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
                    orderString: hebrewLexiconOrder,
                    hiddenString: hiddenHebrewLexicons,
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
                CrossReferenceSortPicker(userSettings: $userSettings)
            } header: {
                Text("Cross References")
            } footer: {
                Text("Sort order for cross references in the reader.")
            }
        }
        .navigationTitle("Module Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setDefaultTranslation(_ translationId: String) {
        userSettings.readerTranslationId = translationId
        try? UserDatabase.shared.updateSettings { $0.readerTranslationId = translationId }
        generator.notificationOccurred(.success)
    }
}

// MARK: - Cross Reference Sort Picker

struct CrossReferenceSortPicker: View {
    @Binding var userSettings: UserSettings
    private let generator = UINotificationFeedbackGenerator()

    private let sorts = ["r", "sv"]
    private let sortNames = ["Relevance", "Verse"]

    var body: some View {
        ForEach(sorts.indices, id: \.self) { index in
            HStack {
                Button {
                    userSettings.readerCrossReferenceSort = sorts[index]
                    try? UserDatabase.shared.updateSettings { $0.readerCrossReferenceSort = sorts[index] }
                    generator.notificationOccurred(.success)
                } label: {
                    Text(sortNames[index])
                        .tint(.primary)
                }
                Spacer()
                if userSettings.readerCrossReferenceSort == sorts[index] {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

// MARK: - Translation List

struct TranslationList: View {
    @Binding var userSettings: UserSettings
    @Binding var hiddenString: String
    let onSetDefault: (String) -> Void

    private var defaultTranslationId: String {
        userSettings.readerTranslationId
    }

    private var allTranslations: [TranslationModule] {
        (try? TranslationDatabase.shared.getAllTranslations()) ?? []
    }

    private var hiddenIds: Set<String> {
        Set(hiddenString.split(separator: ",").map { String($0) })
    }

    private var visibleTranslationsList: [TranslationModule] {
        allTranslations.filter { !hiddenIds.contains($0.id) }
    }

    private var hiddenTranslationsList: [TranslationModule] {
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

    private func hideTranslation(_ id: String) {
        var hidden = hiddenIds
        hidden.insert(id)
        hiddenString = hidden.joined(separator: ",")
    }

    private func showTranslation(_ id: String) {
        var hidden = hiddenIds
        hidden.remove(id)
        hiddenString = hidden.joined(separator: ",")
    }
}

struct TranslationRow: View {
    let translation: TranslationModule
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
    struct PreviewWrapper: View {
        @State var settings = UserDatabase.shared.getSettings()
        var body: some View {
            NavigationStack {
                ModuleSettingsView(userSettings: $settings)
            }
        }
    }
    return PreviewWrapper()
}
