//
//  TranslationImportView.swift
//  Lamp Bible
//

import LampModuleKit
import SwiftUI

/// A Bible file that has been read and is waiting for a name before it
/// becomes a translation.
struct PendingTranslationImport: Identifiable {
    let id = UUID()
    let sourceName: String
    let translation: LampImportedTranslation
    let library: ModuleSyncManager.TranslationImportLibrary
}

/// Shows what was found in a Bible file and asks what to call the translation.
struct TranslationImportView: View {
    let pending: PendingTranslationImport
    let onImport: (
        _ destination: LampTranslationImportDestination,
        _ name: String,
        _ abbreviation: String,
        _ language: String
    ) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var abbreviation: String
    @State private var language: String

    init(
        pending: PendingTranslationImport,
        onImport: @escaping (LampTranslationImportDestination, String, String, String) -> Void
    ) {
        self.pending = pending
        self.onImport = onImport
        _name = State(initialValue: pending.translation.suggestedName ?? "")
        _abbreviation = State(initialValue: pending.translation.suggestedAbbreviation ?? "")
        _language = State(initialValue: pending.translation.language ?? "en")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAbbreviation: String { abbreviation.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var destination: LampTranslationImportDestination {
        pending.library.destination(abbreviation: trimmedAbbreviation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Labelled, because a filled-in field otherwise shows only its value.
                    LabeledContent("Name") {
                        TextField("Name", text: $name, prompt: Text("New American Standard Bible"))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Abbreviation") {
                        TextField("Abbreviation", text: $abbreviation, prompt: Text("NASB"))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    Picker("Language", selection: $language) {
                        ForEach(LampTranslationImporter.languageOptions(including: language), id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("\(pending.translation.format.displayName) · \(pending.translation.report.contentsDescription)")
                } footer: {
                    identityNote
                }

                let notices = pending.translation.report.notices
                if !notices.isEmpty {
                    Section("Not imported as written") {
                        ForEach(notices, id: \.self) { notice in
                            Text(notice)
                                .font(.callout)
                        }
                    }
                }

                Section {
                    if let copyright = pending.translation.copyright {
                        Text(copyright)
                            .lineLimit(4)
                    }
                    Text("The translation is kept in your library and syncs like your other modules. Import only Bibles you have the right to use.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle(pending.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(destination.replacedModuleID == nil ? "Import" : "Replace") {
                        onImport(destination, trimmedName, trimmedAbbreviation, language)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || trimmedAbbreviation.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var identityNote: some View {
        if let replacedID = destination.replacedModuleID {
            Label(
                "Replaces “\(pending.library.namesByTranslationID[replacedID] ?? replacedID)”, imported earlier as \(trimmedAbbreviation).",
                systemImage: "arrow.triangle.2.circlepath"
            )
        } else if let sharing = pending.library.nameSharing(abbreviation: trimmedAbbreviation, except: destination) {
            Label("“\(sharing)” is also called \(trimmedAbbreviation) in your library.", systemImage: "exclamationmark.triangle")
        }
    }
}
