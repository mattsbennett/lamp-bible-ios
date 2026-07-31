//
//  ContentView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI
import GRDB

struct ContentView: View {
    @State private var showingPicker = false
    @State private var date = Date.now
    @ObservedObject private var deepLinkManager = DeepLinkManager.shared
    @State private var importAlertMessage: String?
    @State private var showingImportAlert = false
    @State private var showingDuplicateAlert = false
    @State private var duplicateModuleName = ""
    @State private var pendingImportURL: URL?
    @State private var pendingImportType: ModuleType?
    @State private var devotionalImportPreview: LampFilePreview?
    @State private var stagedDevotionalURL: URL?
    @State private var devotionalModules: [Module] = []
    @State private var showingDevotionalImport = false

    var body: some View {
        PlanView()
            .onChange(of: deepLinkManager.pendingFileImportURL) { _, url in
                guard let url else { return }
                deepLinkManager.pendingFileImportURL = nil
                Task {
                    await handleLampFileImport(url: url)
                }
            }
            .alert("Import", isPresented: $showingImportAlert) {
                Button("OK") {}
            } message: {
                Text(importAlertMessage ?? "")
            }
            .alert("Module Already Exists", isPresented: $showingDuplicateAlert) {
                Button("Overwrite") {
                    if let url = pendingImportURL, let type = pendingImportType {
                        Task {
                            let accessing = url.startAccessingSecurityScopedResource()
                            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                            do {
                                try await ModuleSyncManager.shared.importModuleFromFile(url: url, moduleType: type)
                                importAlertMessage = "Successfully imported \(type.rawValue) module."
                            } catch {
                                importAlertMessage = "Import failed: \(error.localizedDescription)"
                            }
                            showingImportAlert = true
                            pendingImportURL = nil
                            pendingImportType = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                    pendingImportType = nil
                }
            } message: {
                Text("\"\(duplicateModuleName)\" is already installed. Overwrite it?")
            }
            .sheet(isPresented: $showingDevotionalImport, onDismiss: cleanupStagedDevotional) {
                if let preview = devotionalImportPreview {
                    ImportPreviewSheet(
                        preview: preview,
                        devotionalModules: devotionalModules,
                        defaultModuleId: defaultDevotionalModuleId,
                        onImport: { moduleId in
                            importStagedDevotional(into: moduleId)
                        },
                        onCancel: {
                            cleanupStagedDevotional()
                        }
                    )
                }
            }
    }

    private func handleLampFileImport(url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)

            // Try decompressing as zlib (module format: notes, highlights, commentary, etc.)
            if let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
                try decompressed.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let moduleType = try detectModuleType(tempURL: tempURL)

                // Check for duplicate
                if let existingName = ModuleSyncManager.shared.existingModuleName(for: url) {
                    pendingImportURL = url
                    pendingImportType = moduleType
                    duplicateModuleName = existingName
                    showingDuplicateAlert = true
                    return
                }

                try await ModuleSyncManager.shared.importModuleFromFile(url: url, moduleType: moduleType)
                importAlertMessage = "Successfully imported \(moduleType.rawValue) module."
                showingImportAlert = true
                return
            }

            // Try as devotional or devotional collection (JSON or ZIP bundle)
            let preview = try DevotionalSharingManager.shared.previewFile(url)
            if preview.devotionalCount > 0 {
                // Stage a copy while the security scope is still held, so the import can
                // run after the user has chosen a destination module.
                let staged = try DevotionalSharingManager.shared.stageForImport(url)
                await presentDevotionalImport(preview: preview, stagedURL: staged)
                return
            }

            importAlertMessage = "Could not read .lamp file."
            showingImportAlert = true
        } catch {
            importAlertMessage = "Import failed: \(error.localizedDescription)"
            showingImportAlert = true
        }
    }

    // MARK: - Devotional Import

    /// Module used when the recipient has only one place to put the devotional
    private var defaultDevotionalModuleId: String {
        devotionalModules.first(where: { $0.isEditable })?.id ?? "devotionals"
    }

    @MainActor
    private func presentDevotionalImport(preview: LampFilePreview, stagedURL: URL) async {
        do {
            // Guarantee there is at least one editable module to import into
            try await ModuleSyncManager.shared.ensureDefaultDevotionalsModule()
            devotionalModules = try ModuleDatabase.shared.getAllModules(type: .devotional)
        } catch {
            devotionalModules = []
        }

        devotionalImportPreview = preview
        stagedDevotionalURL = stagedURL
        showingDevotionalImport = true
    }

    private func importStagedDevotional(into moduleId: String) {
        guard let staged = stagedDevotionalURL else { return }
        let targetModuleId = moduleId.isEmpty ? defaultDevotionalModuleId : moduleId
        let moduleName = devotionalModules.first(where: { $0.id == targetModuleId })?.name

        // Ownership of the staged file moves to this task so dismissal can't delete it
        // out from under the import.
        stagedDevotionalURL = nil

        Task {
            do {
                let imported = try await DevotionalSharingManager.shared.importAndSave(
                    staged,
                    moduleId: targetModuleId
                )
                let subject = imported.count == 1
                    ? "Devotional"
                    : "\(imported.count) devotionals"
                importAlertMessage = moduleName.map { "\(subject) imported into \($0)." }
                    ?? "Successfully imported \(subject.lowercased())."
            } catch {
                importAlertMessage = "Import failed: \(error.localizedDescription)"
            }
            DevotionalSharingManager.shared.discardStagedImport(staged)
            showingImportAlert = true
        }
    }

    private func cleanupStagedDevotional() {
        if let staged = stagedDevotionalURL {
            DevotionalSharingManager.shared.discardStagedImport(staged)
            stagedDevotionalURL = nil
        }
        devotionalImportPreview = nil
    }

    private func detectModuleType(tempURL: URL) throws -> ModuleType {
        let db = try DatabaseQueue(path: tempURL.path)
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }

        if tables.contains("translation_verses") || tables.contains("translations") || tables.contains("translation_meta") {
            return .translation
        } else if tables.contains("note_entries") {
            return .notes
        } else if tables.contains("devotional_entries") {
            return .devotional
        } else if tables.contains("highlight_sets") || tables.contains("highlights") {
            return .highlights
        } else if tables.contains("commentary_entries") || tables.contains("commentary_units") {
            return .commentary
        } else if tables.contains("dictionary_entries") {
            return .dictionary
        } else if tables.contains("quiz_modules") && tables.contains("quiz_questions") {
            return .quiz
        } else if tables.contains("plans") || tables.contains("plan_days") {
            return .plan
        } else {
            throw NSError(domain: "ContentView", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine module type"])
        }
    }
}

#Preview {
    ContentView()
}
