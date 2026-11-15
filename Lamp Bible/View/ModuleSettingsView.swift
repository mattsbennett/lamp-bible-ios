//
//  ModuleSettingsView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-03.
//

import SwiftUI
import LampCore
import GRDB

struct ModuleSettingsView: View {
    @Binding var userSettings: UserSettings
    @Environment(\.dismiss) var dismiss

    private let generator = UINotificationFeedbackGenerator()

    /// The translations and lexicons listed, read once off the main actor
    /// and again when the library changes, rather than on every access by
    /// the lists' rows and swipe actions.
    @State private var translations: [TranslationModule] = []
    @State private var greekLexicons: [(key: String, name: String)] = []
    @State private var hebrewLexicons: [(key: String, name: String)] = []
    @State private var loadGeneration = 0

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
                    translations: translations,
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
                Text("Show visual hints for words in translations with word-level Strong's tagging.")
            }

            Section {
                LexiconOrderListWithHiding(
                    allLexicons: greekLexicons,
                    orderString: greekLexiconOrder,
                    hiddenString: hiddenGreekLexicons
                )
            } header: {
                Text("Greek Lexicons")
            } footer: {
                Text("Drag to reorder (to set order shown in Lexicon view). Swipe to hide.")
            }

            Section {
                LexiconOrderListWithHiding(
                    allLexicons: hebrewLexicons,
                    orderString: hebrewLexiconOrder,
                    hiddenString: hiddenHebrewLexicons
                )
            } header: {
                Text("Hebrew Lexicons")
            } footer: {
                Text("Drag to reorder. Swipe to hide.")
            }
        }
        .navigationTitle("Module Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadModules() }
        .onReceive(NotificationCenter.default.publisher(for: .translationsDidChange)) { _ in
            Task { await loadModules() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            Task { await loadModules() }
        }
    }

    private struct ListedModules {
        let translations: [TranslationModule]
        let greek: [(key: String, name: String)]
        let hebrew: [(key: String, name: String)]
    }

    private func loadModules() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let listed = await Task.detached(priority: .userInitiated) {
            ListedModules(
                translations: (try? TranslationDatabase.shared.getAllTranslations()) ?? [],
                greek: Self.lexicons(in: "greek"),
                hebrew: Self.lexicons(in: "hebrew")
            )
        }.value
        guard generation == loadGeneration else { return }
        translations = listed.translations
        greekLexicons = listed.greek
        hebrewLexicons = listed.hebrew
    }

    /// The bundle's lexicons in a language ("greek" or "hebrew"), and the
    /// user's dictionaries keyed by its Strong's numbers.
    private nonisolated static func lexicons(in language: String) -> [(key: String, name: String)] {
        var available = BundledModuleDatabase.shared.lexicons()
            .filter { $0.language == language }
            .map { (key: $0.lexiconKey, name: $0.shortName) }

        // Discover user dictionary modules with matching keyType
        if let modules = try? ModuleDatabase.shared.getAllModules(type: .dictionary) {
            for module in modules {
                if module.keyType == "strongs-\(language)" {
                    available.append((key: "user-\(module.id)", name: module.name))
                }
            }
        }

        return available
    }

    private func setDefaultTranslation(_ translationId: String) {
        userSettings.readerTranslationId = translationId
        try? UserDatabase.shared.updateSettings { $0.readerTranslationId = translationId }
        generator.notificationOccurred(.success)
    }
}

// MARK: - Translation List

struct TranslationList: View {
    /// Every translation, bundled and installed, as the settings screen read them.
    let translations: [TranslationModule]
    @Binding var userSettings: UserSettings
    @Binding var hiddenString: String
    let onSetDefault: (String) -> Void

    private var defaultTranslationId: String {
        userSettings.readerTranslationId
    }

    private var hiddenIds: Set<String> {
        Set(LampModuleSelection.identifiers(in: hiddenString))
    }

    private var visibleTranslationsList: [TranslationModule] {
        translations.filter { !hiddenIds.contains($0.id) }
    }

    private var hiddenTranslationsList: [TranslationModule] {
        translations.filter { hiddenIds.contains($0.id) }
    }

    var body: some View {
        // Under their languages, as the pickers list them; inside the one
        // Translations section, so as headings in it like Hidden's.
        // Whole Bibles first in each language, then the parts of the Bible
        // under a heading of their own.
        let groups = LampTranslationLanguages.grouped(
            visibleTranslationsList,
            language: { $0.language },
            holdsWholeBible: { TranslationDatabase.shared.holdsWholeBible(translationId: $0.id) }
        )
        ForEach(groups) { group in
            if groups.count > 1 {
                subheader(group.title, isFirst: group.id == groups.first?.id)
            }
            ForEach(group.parts) { part in
            if let title = part.title {
                partHeader(title)
            }
            ForEach(part.items) { translation in
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
            }
        }

        if !hiddenTranslationsList.isEmpty {
            subheader("Hidden")

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

    /// A lesser heading inside a language, over its parts of the Bible.
    private func partHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden, edges: .bottom)
    }

    /// A heading among the rows, the first one close under the section's own.
    private func subheader(_ title: String, isFirst: Bool = false) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: isFirst ? 12 : 24, leading: 20, bottom: 8, trailing: 20))
            .listRowSeparator(.hidden, edges: .bottom)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(translation.name)
                    if translation.features?.strongs == true {
                        StrongsBadge()
                    }
                }
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

/// Translations under the languages they are written in (core
/// `LampTranslationLanguages`): the reader's own first, any other modern
/// language, then Biblical Languages, a section each; one plain run where
/// they share a language. For a menu's or a picker's content.
struct TranslationLanguageSections<Rows: View>: View {
    let translations: [TranslationModule]
    @ViewBuilder let rows: ([TranslationModule]) -> Rows

    var body: some View {
        // Whole Bibles first in each language, then the parts of the Bible
        // below a divider. Not a nested Section: in a menu its rows come
        // out disabled, as the Mac found.
        let groups = LampTranslationLanguages.grouped(
            translations,
            language: { $0.language },
            holdsWholeBible: { TranslationDatabase.shared.holdsWholeBible(translationId: $0.id) }
        )
        if groups.count > 1 {
            ForEach(groups) { group in
                Section(group.title) { parts(group) }
            }
        } else if let group = groups.first {
            parts(group)
        }
    }

    @ViewBuilder
    private func parts(_ group: LampTranslationLanguages.Group<TranslationModule>) -> some View {
        ForEach(group.parts) { part in
            if part.id != group.parts.first?.id {
                Divider()
            }
            rows(part.items)
        }
    }
}

// MARK: - Lexicon Order List with Hiding

struct LexiconOrderListWithHiding: View {
    /// The language's lexicons, as the settings screen read them: the
    /// bundle's, and the user's dictionaries keyed by its Strong's numbers.
    let allLexicons: [(key: String, name: String)]
    @Binding var orderString: String
    @Binding var hiddenString: String

    private var hiddenKeys: Set<String> {
        Set(LampModuleSelection.identifiers(in: hiddenString))
    }

    private var orderedLexicons: [(key: String, name: String)] {
        LampModuleSelection.ordered(
            allLexicons, preferredIDs: LexiconLookup.preferredKeys(in: orderString), id: { $0.key }
        )
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
