//
//  WritingImportSheet.swift
//  Lamp Bible
//

import LampCore
import SwiftUI

/// Markdown files that have been read and planned, waiting for the person to
/// choose which become writing. The Mac's sheet of the same name, for the
/// phone.
struct PendingWritingImport: Identifiable {
    let id = UUID()
    /// The folder or file chosen, as the sheet names it.
    let sourceName: String
    let plan: LampWritingImportPlan
    /// The writings the plan compared with, exactly as stored then, which
    /// applying checks each write against.
    var planned: [String: Data] = [:]
    /// For the iCloud drop folder: what it held when planned, so a plan the
    /// person cancelled isn't offered again until the folder changes.
    var dropFolderFingerprint: String?
    /// Files chosen in the picker, open until the import is done with, since
    /// their pictures are copied in only as it's applied.
    var access: SecurityScopedAccess?

    /// Whether there is anything to choose: a folder of unchanged and
    /// unreadable files only is not worth a sheet.
    var offersAnything: Bool {
        plan.items.contains { [.create, .update, .conflict].contains($0.action) }
    }
}

/// What importing a folder or files of writing would do, file by file, with
/// nothing written until Import. New and updated writings come ticked; one
/// changed in Lamp since its file was saved waits to be chosen, and one that
/// cannot be imported says why.
struct WritingImportSheet: View {
    let pending: PendingWritingImport
    /// The collections a new writing can go to; asked only when there are two
    /// or more. A writing already in Lamp stays where it is.
    let modules: [Module]
    let defaultModuleID: String
    let onImport: (Set<String>, String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>
    @State private var moduleID: String

    init(
        pending: PendingWritingImport,
        modules: [Module] = [],
        defaultModuleID: String = WritingCollection.id,
        onImport: @escaping (Set<String>, String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.pending = pending
        self.modules = modules.filter { $0.type == .devotional && $0.isEditable }
        self.defaultModuleID = defaultModuleID
        self.onImport = onImport
        self.onCancel = onCancel
        _selection = State(initialValue: Set(
            pending.plan.items.filter(\.importsByDefault).map(\.id)
        ))
        _moduleID = State(initialValue: defaultModuleID)
    }

    private var items: [LampWritingImportItem] { pending.plan.items }

    private static let sections: [(LampWritingImportItem.Action, String)] = [
        (.create, "New"), (.update, "Updated"), (.conflict, "Changed in Lamp"),
        (.rejected, "Can’t Import"), (.unchanged, "Unchanged"),
    ]

    private var summary: String {
        let parts: [(LampWritingImportItem.Action, String)] = [
            (.create, "new"), (.update, "updated"), (.conflict, "changed in Lamp"),
            (.unchanged, "unchanged"), (.rejected, "can’t be imported"),
        ]
        return parts.compactMap { action, label in
            let count = pending.plan.count(action)
            return count == 0 ? nil : "\(count) \(label)"
        }.joined(separator: " · ")
    }

    private var defaultSelection: Set<String> {
        Set(items.filter(\.importsByDefault).map(\.id))
    }

    /// Asked only when a new writing is ticked and there is a choice.
    private var asksForModule: Bool {
        modules.count > 1 && items.contains { $0.action == .create && selection.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(summary)
                        .foregroundStyle(.secondary)
                    if !defaultSelection.isEmpty {
                        Button(selection.isEmpty ? "Tick New and Updated" : "Untick All") {
                            selection = selection.isEmpty ? defaultSelection : []
                        }
                    }
                    if asksForModule {
                        Picker("New Writing Goes To", selection: $moduleID) {
                            ForEach(modules) { module in
                                Text(module.name).tag(module.id)
                            }
                        }
                        .tint(.primary)
                    }
                } footer: {
                    Text("Nothing is written until you import. A file with no id of its own keeps one made from its path in the folder, so importing the folder again updates these writings rather than adding copies.")
                }

                ForEach(Self.sections, id: \.0) { action, title in
                    let rows = items.filter { $0.action == action }
                    if !rows.isEmpty {
                        Section(title) {
                            ForEach(rows) { item in
                                WritingImportRow(
                                    item: item,
                                    isSelected: selection.contains(item.id)
                                ) {
                                    if selection.contains(item.id) {
                                        selection.remove(item.id)
                                    } else {
                                        selection.insert(item.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(pending.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.count == 1 ? "Import 1" : "Import \(selection.count)") {
                        onImport(selection, moduleID)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .onAppear {
            if !modules.contains(where: { $0.id == moduleID }), let first = modules.first {
                moduleID = first.id
            }
        }
    }
}

private struct WritingImportRow: View {
    let item: LampWritingImportItem
    let isSelected: Bool
    let toggle: () -> Void

    private var canImport: Bool {
        [.create, .update, .conflict].contains(item.action)
    }

    var body: some View {
        // Not disabled: a disabled button greys the reason a file can't be
        // imported, which is the one thing that row is there to say.
        Button { if canImport { toggle() } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if canImport {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    ForEach(Array(noteLines.enumerated()), id: \.offset) { _, note in
                        Text(note.text)
                            .font(.caption)
                            .foregroundStyle(note.isError ? Color.red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(canImport || item.action == .rejected ? 1 : 0.6)
        .accessibilityAddTraits(canImport && isSelected ? .isSelected : [])
    }

    private var noteLines: [(text: String, isError: Bool)] {
        var lines = item.errors.map { ($0, true) }
        if item.action == .conflict {
            let when = item.libraryModified.map {
                " on \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? ""
            lines.append(("Lamp’s copy, last changed\(when), may hold edits made in Lamp. Tick it to replace Lamp’s copy with the file.", false))
        }
        if item.action == .update || item.action == .conflict, !item.changes.isEmpty {
            lines.append(("Differs in: \(item.changes.joined(separator: ", ")).", false))
        }
        lines += item.warnings.map { ($0, false) }
        return lines
    }
}
