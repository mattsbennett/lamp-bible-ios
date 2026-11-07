//
//  ContentView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-10-14.
//

import SwiftUI

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
    @State private var pendingImportHasSecurityScope = false
    @State private var devotionalImportPreview: LampFilePreview?
    @State private var stagedDevotionalURL: URL?
    @State private var devotionalModules: [Module] = []
    @State private var showingDevotionalImport = false
    /// A finished import, said without an alert to dismiss.
    @State private var importToast: LampToast?

    var body: some View {
        PlanView()
            .lampToast($importToast)
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
                            let hasSecurityScope = pendingImportHasSecurityScope
                            pendingImportHasSecurityScope = false
                            let accessing = hasSecurityScope ? false : url.startAccessingSecurityScopedResource()
                            defer {
                                if hasSecurityScope || accessing {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                            do {
                                try await ModuleSyncManager.shared.importModuleDocumentFromFile(url: url, moduleType: type)
                                announceImport(name: duplicateModuleName, type: type, replaced: true)
                            } catch {
                                importAlertMessage = "Import failed: \(error.localizedDescription)"
                                showingImportAlert = true
                            }
                            pendingImportURL = nil
                            pendingImportType = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    if pendingImportHasSecurityScope {
                        pendingImportURL?.stopAccessingSecurityScopedResource()
                    }
                    pendingImportURL = nil
                    pendingImportType = nil
                    pendingImportHasSecurityScope = false
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
        var shouldReleaseAccess = accessing
        defer { if shouldReleaseAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)

            if url.pathExtension.lowercased() == "json" {
                let moduleType = try ModuleSyncManager.shared.moduleType(forDocumentAt: url)
                if let existingName = try ModuleSyncManager.shared.existingModuleName(forDocumentAt: url) {
                    pendingImportURL = url
                    pendingImportType = moduleType
                    pendingImportHasSecurityScope = accessing
                    duplicateModuleName = existingName
                    showingDuplicateAlert = true
                    shouldReleaseAccess = false
                    return
                }
                try await ModuleSyncManager.shared.importModuleDocumentFromFile(
                    url: url,
                    moduleType: moduleType
                )
                announceImport(
                    name: try? ModuleSyncManager.shared.existingModuleName(forDocumentAt: url),
                    type: moduleType
                )
                return
            }

            // Try decompressing as zlib (module format: notes, highlights, commentary, etc.)
            if (try? (data as NSData).decompressed(using: .zlib)) != nil {
                let moduleType = try ModuleSyncManager.shared.moduleType(forDocumentAt: url)

                // Check for duplicate
                if let existingName = ModuleSyncManager.shared.existingModuleName(for: url) {
                    pendingImportURL = url
                    pendingImportType = moduleType
                    pendingImportHasSecurityScope = accessing
                    duplicateModuleName = existingName
                    showingDuplicateAlert = true
                    shouldReleaseAccess = false
                    return
                }

                try await ModuleSyncManager.shared.importModuleDocumentFromFile(url: url, moduleType: moduleType)
                announceImport(name: ModuleSyncManager.shared.existingModuleName(for: url), type: moduleType)
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
                    ? "Writing"
                    : "\(imported.count) writings"
                importToast = LampToast(
                    title: "\(subject) imported",
                    message: moduleName.map { "Now in \($0)" }
                )
            } catch {
                importAlertMessage = "Import failed: \(error.localizedDescription)"
                showingImportAlert = true
            }
            DevotionalSharingManager.shared.discardStagedImport(staged)
        }
    }

    private func announceImport(name: String?, type: ModuleType, replaced: Bool = false) {
        let verb = replaced ? "Updated" : "Imported"
        let title = name.flatMap { $0.isEmpty ? nil : "\(verb) “\($0)”" } ?? "\(type.displayName) \(verb)"
        importToast = LampToast(title: title, message: "\(type.displayName) · ready to use")
    }

    private func cleanupStagedDevotional() {
        if let staged = stagedDevotionalURL {
            DevotionalSharingManager.shared.discardStagedImport(staged)
            stagedDevotionalURL = nil
        }
        devotionalImportPreview = nil
    }

}

#Preview {
    ContentView()
}

// MARK: - Toast

/// A short confirmation that something finished, shown without stopping the
/// person with an alert they have to dismiss.
struct LampToast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    var message: String? = nil
    var systemImage: String = "checkmark.circle.fill"
    var isError = false
}

private struct LampToastModifier: ViewModifier {
    @Binding var toast: LampToast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast {
                toastView(toast)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast.id) {
                        let spoken = [toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")
                        UIAccessibility.post(notification: .announcement, argument: spoken)
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation(.easeInOut(duration: 0.3)) {
                            if self.toast?.id == toast.id { self.toast = nil }
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: toast)
    }

    @ViewBuilder
    private func toastView(_ toast: LampToast) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: toast.systemImage)
                .font(.title2)
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let message = toast.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture { self.toast = nil }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ImportConfirmation")
        .accessibilityAddTraits(.isStaticText)

        if #available(iOS 26, *) {
            label.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            label
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

extension View {
    /// Shows `toast` over the top of the view for a few seconds.
    func lampToast(_ toast: Binding<LampToast?>) -> some View {
        modifier(LampToastModifier(toast: toast))
    }
}
