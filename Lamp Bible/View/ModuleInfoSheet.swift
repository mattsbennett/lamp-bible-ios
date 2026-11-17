//
//  ModuleInfoSheet.swift
//  Lamp Bible
//

import LampCore
import LampModuleKit
import SwiftUI

/// Everything the library holds about one module, read by core
/// (`LampModuleRecord`) as the Mac's info window reads it: what a reader
/// wants to know first, and behind a disclosure its ID, where it is kept,
/// every column of its kind's tables and its sync record. Two modules can
/// share a name ("ESV" and "ESVs" across the translation-ID rename); the ID
/// is what tells them apart.
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
                            ForEach(info.details) { row in
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
        if row.isHeading {
            Text(verbatim: row.label)
                .font(.footnote.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.label)
                    .font(isTechnical ? .subheadline.monospaced() : .subheadline)
                    .foregroundStyle(.secondary)
                // A column the table has, empty for this module: missing,
                // as opposed to one its kind doesn't have, which isn't shown.
                Text(verbatim: row.value ?? "None")
                    .font(isTechnical ? .callout.monospaced() : .body)
                    .foregroundStyle(row.value == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 1)
        }
    }
}

/// A module's record as the sheet shows it: the reader's facts, where the
/// module has them, then everything else as core read it, table by table.
struct ModuleInfo {
    struct Row: Identifiable {
        let label: String
        let value: String?
        var isHeading = false
        let id = UUID()
    }

    var about: [Row] = []
    var details: [Row] = []

    /// The module's own ID: a translation's row is listed under
    /// "translation-<id>".
    static func moduleID(of module: DisplayModule) -> String {
        if module.type == .translation, module.id.hasPrefix("translation-") {
            return String(module.id.dropFirst("translation-".count))
        }
        return module.id
    }

    nonisolated static func read(_ module: DisplayModule, storage: ModuleStorage?) -> ModuleInfo {
        let id = moduleID(of: module)
        let record = (try? self.record(of: module, id: id)) ?? nil
        var info = ModuleInfo()

        func text(_ column: String) -> String? {
            record?.value(of: column).flatMap(display)
        }
        let copyright: String? = switch (text("copyright"), text("copyright_year")) {
        case let (holder?, year?) where !holder.contains(year): "© \(year) \(holder)"
        case let (holder?, _): holder
        case let (nil, year?): "© \(year)"
        default: nil
        }
        let about: [(String, String?)] = [
            ("Name", module.name),
            ("Abbreviation", text("abbreviation") ?? text("series_abbrev")),
            ("Kind", module.type.displayName),
            ("Language", text("language_name") ?? text("language")),
            ("Translation Philosophy", text("translation_philosophy")?.capitalized),
            ("Series", text("series_full")),
            ("Author", text("author")),
            ("Year", text("year")),
            ("Publisher", text("publisher")),
            ("Copyright", copyright),
            ("License", text("license")),
            ("Version", text("version")),
            ("Contents", module.entryCount.map { ModuleListStyle.countText($0, for: module.type) }),
            ("Strong’s Numbers", module.isStrongsTagged ? "Tagged" : nil),
            ("Editable", module.isEditable ? "Yes" : nil),
            ("Source", module.isBundled ? "Built in" : "Yours"),
            ("Description", text("translation_description") ?? text("description") ?? module.description),
        ]
        info.about = about.compactMap { label, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(label: label, value: value)
        }

        info.details = [Row(label: "ID", value: id)]
        if let record {
            switch record.storage {
            case .installed(let moduleFile, let database):
                if let moduleFile { info.details += rows(describing: moduleFile, as: "Module File") }
                info.details += rows(describing: database, as: "Database")
            case .bundled(let database):
                info.details += rows(describing: database, as: "Built-in Database")
            case .shared(let database):
                info.details += rows(describing: database, as: "Library Database")
            }
            for table in record.tables {
                for (index, row) in table.rows.enumerated() {
                    let heading = table.rows.count > 1 ? "\(table.name) (\(index + 1) of \(table.rows.count))" : table.name
                    info.details.append(Row(label: heading, value: nil, isHeading: true))
                    info.details += row.map { Row(label: $0.name, value: display($0.value)) }
                }
            }
        }

        // The file this device syncs it as, found as deleting it finds it.
        // The phone's own record of the sync, beside core's of the module.
        if !module.isBundled, let storage, let endpoint = libraryEndpoint(for: storage) {
            let folder = storage.directoryName(for: module.type)
            let records = ((try? ModuleDatabase.shared.syncFileRecords(source: endpoint.librarySource)) ?? [])
                .filter { $0.path.hasPrefix(folder + "/") && LampSyncFolderLayout.remoteModuleID(of: $0.path) == id }
            info.details.append(Row(label: "sync", value: nil, isHeading: true))
            if records.isEmpty {
                info.details.append(Row(label: "Library Path", value: nil))
            }
            for record in records {
                info.details += [
                    Row(label: "Library Path", value: record.path),
                    Row(label: "Server Revision", value: record.lastRevision),
                    Row(label: "Uploaded SHA-256", value: record.uploadedDigest),
                    Row(label: "Revision Not Yet in Manifest", value: record.pendingRevision),
                    Row(label: "Record Updated", value: date(record.updatedAt)),
                ]
            }
        }
        return info
    }

    /// Core's record of the module: a built-in one from the bundle's
    /// database, one of the person's from the phone's own, both in the
    /// shared layout core reads.
    private nonisolated static func record(of module: DisplayModule, id: String) throws -> LampModuleRecord? {
        let installed = LampInstalledModule(
            id: id, kind: module.type, name: module.name,
            abbreviation: module.type == .translation ? module.version : nil,
            isBundled: module.isBundled, tagsStrongs: module.isStrongsTagged
        )
        if module.isBundled {
            let bundled = BundledModuleDatabase.shared
            guard let path = bundled.databasePath else { return nil }
            // Strong's lexicons are listed by their search IDs
            // ("strongs-greek"); the bundle keeps them by their own.
            let stored = module.type == .dictionary
                ? bundled.lexicons().first { $0.searchId == id }?.moduleId ?? id
                : id
            let tables = try bundled.read { try LampModuleRecord.tables(sharedLayoutIn: $0, kind: module.type, id: stored) }
            return LampModuleRecord(module: installed, storage: .bundled(database: file(at: URL(fileURLWithPath: path))), tables: tables)
        }
        let database = ModuleDatabase.shared
        let tables = try database.read { try LampModuleRecord.tables(sharedLayoutIn: $0, kind: module.type, id: id) }
        return LampModuleRecord(module: installed, storage: .shared(database: file(at: database.fileURL)), tables: tables)
    }

    private nonisolated static func file(at url: URL) -> LampModuleRecord.File {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return LampModuleRecord.File(url: url, byteCount: values?.fileSize, modifiedAt: values?.contentModificationDate, sha256: nil)
    }

    private static func rows(describing file: LampModuleRecord.File, as label: String) -> [Row] {
        var rows = [Row(label: label, value: file.url.lastPathComponent)]
        if let size = file.byteCount {
            rows.append(Row(label: "\(label) Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let modified = file.modifiedAt {
            rows.append(Row(label: "\(label) Modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
        }
        if let sha256 = file.sha256 {
            rows.append(Row(label: "\(label) SHA-256", value: sha256))
        }
        return rows
    }

    private static func display(_ value: LampModuleRecord.Value) -> String? {
        switch value {
        case .null: nil
        case .integer(let integer): String(integer)
        case .real(let real): String(real)
        case .text(let text): text
        case .blob(let byteCount): "\(byteCount) bytes"
        }
    }

    /// Sync records keep milliseconds.
    private static func date(_ stamp: Int64?) -> String? {
        guard let stamp, stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(stamp) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}
