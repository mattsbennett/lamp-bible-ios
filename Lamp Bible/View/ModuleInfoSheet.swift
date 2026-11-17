//
//  ModuleInfoSheet.swift
//  Lamp Bible
//

import LampModuleKit
import SwiftUI

/// Everything the library holds about one module: what a reader wants to
/// know first, and its ID, file and sync record behind a disclosure. Two
/// modules can share a name ("ESV" and "ESVs" across the translation-ID
/// rename); the ID below is what tells them apart. The Mac's info window
/// shows the same, split the same way.
struct ModuleInfoSheet: View {
    let module: DisplayModule

    @Environment(\.dismiss) private var dismiss
    @State private var info: ModuleInfo?
    @AppStorage("moduleInfoShowsDetails") private var showsDetails = false

    var body: some View {
        NavigationStack {
            List {
                if let info {
                    Section {
                        ForEach(info.about) { row in
                            ModuleInfoRow(row: row)
                        }
                    }
                    Section {
                        DisclosureGroup("Developer Details", isExpanded: $showsDetails) {
                            ForEach(info.details + info.sync) { row in
                                ModuleInfoRow(row: row, isTechnical: true)
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(module.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            // The sync endpoint is the coordinator's, read here; the
            // records are read off the main thread.
            let storage = SyncCoordinator.shared.activeStorage
            let module = module
            info = await Task.detached { ModuleInfo.read(module, storage: storage) }.value
        }
    }
}

private struct ModuleInfoRow: View {
    let row: ModuleInfo.Row
    var isTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: row.value ?? "None")
                .font(isTechnical ? .callout.monospaced() : .body)
                .foregroundStyle(row.value == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

/// A module's record as the sheet shows it. Reader-facing rows are left out
/// where the module has nothing to say; a technical row that applies to
/// the module's kind is always shown, "None" where it is empty, so a blank
/// hash or path reads as missing, not as not applying.
struct ModuleInfo {
    struct Row: Identifiable {
        let label: String
        let value: String?
        let id = UUID()
    }

    var about: [Row] = []
    var details: [Row] = []
    var sync: [Row] = []

    /// The module's own ID: a translation's row is listed under
    /// "translation-<id>".
    static func moduleID(of module: DisplayModule) -> String {
        if module.type == .translation, module.id.hasPrefix("translation-") {
            return String(module.id.dropFirst("translation-".count))
        }
        return module.id
    }

    nonisolated static func read(_ module: DisplayModule, storage: ModuleStorage?) -> ModuleInfo {
        var info = ModuleInfo()
        let id = moduleID(of: module)
        var about: [(String, String?)] = [("Name", module.name)]

        if module.type == .translation, let translation = try? TranslationDatabase.shared.getTranslation(id: id) {
            about += [
                ("Abbreviation", translation.abbreviation),
                ("Kind", module.type.displayName),
                ("Language", translation.languageName ?? translation.language),
                ("Translation Philosophy", translation.translationPhilosophy?.capitalized),
                ("Year", translation.year.map(String.init)),
                ("Publisher", translation.publisher),
                ("Copyright", copyright(translation.copyright, year: translation.copyrightYear)),
                ("License", translation.license),
                ("Contents", module.entryCount.map { ModuleListStyle.countText($0, for: .translation) }),
                ("Strong’s Numbers", module.isStrongsTagged ? "Tagged" : nil),
                ("Source", translation.isBundled ? "Built in" : "Yours"),
                ("Description", translation.translationDescription),
            ]
            info.details = [
                Row(label: "ID", value: translation.id),
                Row(label: "Language Code", value: translation.language),
                Row(label: "Text Direction", value: translation.textDirection),
                Row(label: "Versification", value: translation.versification),
                Row(label: "Features", value: translation.featuresJson),
                Row(label: "Source Texts", value: translation.sourceTextsJson),
            ]
            // A built-in translation has no file or sync of its own.
            if !translation.isBundled {
                info.details += [
                    Row(label: "File", value: translation.filePath),
                    Row(label: "File Hash", value: translation.fileHash),
                    Row(label: "Last Synced", value: date(translation.lastSynced.map(Int64.init))),
                    Row(label: "Created", value: date(translation.createdAt.map(Int64.init))),
                    Row(label: "Updated", value: date(translation.updatedAt.map(Int64.init))),
                ]
            }
        } else {
            let user = module.userModule
            about += [
                ("Abbreviation", user?.seriesAbbrev),
                ("Kind", module.type.displayName),
                ("Series", user?.seriesFull),
                ("Author", user?.author),
                ("Version", module.version),
                ("Contents", module.entryCount.map { ModuleListStyle.countText($0, for: module.type) }),
                ("Editable", module.isEditable ? "Yes" : nil),
                ("Source", module.isBundled ? "Built in" : "Yours"),
                ("Description", module.description),
            ]
            info.details = [Row(label: "ID", value: id)]
            if let user {
                if module.type == .dictionary {
                    info.details.append(Row(label: "Key Type", value: user.keyType))
                }
                if module.type == .commentary {
                    info.details.append(Row(label: "Series ID", value: user.seriesId))
                }
                info.details += [
                    Row(label: "File", value: user.filePath),
                    Row(label: "File Hash", value: user.fileHash),
                    Row(label: "Last Synced", value: date(user.lastSynced.map(Int64.init))),
                    Row(label: "Created", value: date(user.createdAt.map(Int64.init))),
                    Row(label: "Updated", value: date(user.updatedAt.map(Int64.init))),
                ]
            }
        }
        info.about = about.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }

        // The file this device syncs it as, found as deleting it finds it.
        if !module.isBundled, let storage, let endpoint = libraryEndpoint(for: storage) {
            let folder = storage.directoryName(for: module.type)
            let records = ((try? ModuleDatabase.shared.syncFileRecords(source: endpoint.librarySource)) ?? [])
                .filter { $0.path.hasPrefix(folder + "/") && LampSyncFolderLayout.remoteModuleID(of: $0.path) == id }
            for record in records {
                info.sync += [
                    Row(label: "Library Path", value: record.path),
                    Row(label: "Server Revision", value: record.lastRevision),
                    Row(label: "Uploaded SHA-256", value: record.uploadedDigest),
                    Row(label: "Revision Not Yet in Manifest", value: record.pendingRevision),
                    Row(label: "Record Updated", value: date(record.updatedAt)),
                ]
            }
            if records.isEmpty {
                info.sync = [Row(label: "Library Path", value: nil)]
            }
        }
        return info
    }

    private static func copyright(_ holder: String?, year: Int?) -> String? {
        switch (holder, year) {
        case let (holder?, year?) where !holder.contains(String(year)): return "© \(year) \(holder)"
        case let (holder?, _): return holder
        case let (nil, year?): return "© \(year)"
        default: return nil
        }
    }

    /// Stored times are seconds in the module tables and milliseconds in
    /// the sync records.
    private static func date(_ stamp: Int64?) -> String? {
        guard let stamp, stamp > 0 else { return nil }
        let seconds = stamp > 100_000_000_000 ? Double(stamp) / 1000 : Double(stamp)
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }
}
