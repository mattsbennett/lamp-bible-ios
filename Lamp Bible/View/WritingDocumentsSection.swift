import LampCore
import LampModuleKit
import SwiftUI

typealias WritingDocument = LampWritingDocumentStore.Document

/// A writing's other files, its outline, notes and sources, as the Mac keeps
/// them beside the prose: read and written through core's store, so a save
/// never writes over a copy sync took in meanwhile.
enum WritingDocuments {
    /// The writing's documents, read off the main thread.
    static func load(writingID: String) async -> [WritingDocument] {
        await Task.detached(priority: .userInitiated) {
            (try? LibrarySyncPass.documentStore.documents(writingID: writingID)) ?? []
        }.value
    }

    /// Writes the editor's text over what it opened (`opened`, nil for a new
    /// file). False, writing nothing, where the file changed meanwhile.
    static func save(_ text: String, writingID: String, name: String, opened: Data?) async throws -> Bool {
        let saved = try await Task.detached(priority: .userInitiated) {
            try LibrarySyncPass.documentStore.write(
                Data(text.utf8), writingID: writingID, name: name, replacing: opened
            )
        }.value
        if saved { await ModuleSyncManager.shared.scheduleLibraryPass() }
        return saved
    }

    /// The writer's text kept beside a file that changed while they edited
    /// it, under a copy's name, as sync keeps one. Returns the name.
    @MainActor
    static func saveAsCopy(_ text: String, writingID: String, of name: String) async throws -> String {
        let device = LibrarySyncPass.deviceName
        return try await Task.detached(priority: .userInitiated) {
            let store = LibrarySyncPass.documentStore
            let folder = store.folderURL(writingID: writingID)
            let copy = LampWritingWorkspaceLayout.keptCopyName(
                of: name, device: device, at: Date(),
                taken: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            )
            // A name taken in the moment since it was chosen: nothing written.
            guard try store.write(Data(text.utf8), writingID: writingID, name: copy, replacing: nil) else {
                throw CocoaError(.fileWriteFileExists)
            }
            return copy
        }.value
    }

    /// Removes a file everywhere, as the writer saw it (`seen`): here, and
    /// by a deletion the next pass carries to the server this device syncs
    /// with. A copy sync brought in since is kept under a copy's name, which
    /// is returned.
    @MainActor
    static func delete(writingID: String, name: String, seen: Data) async throws -> String? {
        let source = libraryEndpoint(for: ModuleSyncManager.shared.getStorage())?.librarySource
        let device = LibrarySyncPass.deviceName
        let kept = try await Task.detached(priority: .userInitiated) {
            try LibrarySyncPass.deleteDocument(
                writingID: writingID, name: name, seen: seen, source: source, device: device
            )
        }.value
        await ModuleSyncManager.shared.scheduleLibraryPass()
        return kept
    }

    /// A name typed for a new file, given `.md` when it has no extension a
    /// document takes; nil when no document can be called that.
    static func newName(from typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        let name = LampWritingWorkspaceLayout.documentExtensions.contains(ext) ? trimmed : "\(trimmed).md"
        return LampWritingWorkspaceLayout.isDocumentName(name) ? name.precomposedStringWithCanonicalMapping : nil
    }
}

/// Below a writing's prose while it's read: its other files, folded, each
/// under a heading of its own, as the Mac shows them.
struct WritingDocumentsSection: View {
    let documents: [WritingDocument]
    @Binding var expanded: Bool
    @Binding var openFiles: Set<String>
    let canEdit: Bool
    let onEdit: (WritingDocument) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("OTHER FILES")
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                    Text("\(documents.count)")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(LampTheme.caption)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other Files, \(documents.count)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(documents) { document in
                        fileRow(document)
                    }
                    if canEdit {
                        Button(action: onAdd) {
                            Label("Add File", systemImage: "doc.badge.plus")
                                .font(.subheadline)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fileRow(_ document: WritingDocument) -> some View {
        let open = openFiles.contains(document.name)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { openFiles.remove(document.name) } else { openFiles.insert(document.name) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(document.name)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if document.isKeptCopy {
                        Text("Kept copy")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                Text(Self.shown(document))
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(LampTheme.readerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if canEdit {
                    Button { onEdit(document) } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.subheadline)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Markdown line by line, its lines kept as written: a heading set as
    /// one, the rest with its inline styling. Plain text, and a line that
    /// won't parse, as it is.
    static func shown(_ document: WritingDocument) -> AttributedString {
        let text = document.text.isEmpty ? "Empty." : document.text
        let ext = (document.name as NSString).pathExtension.lowercased()
        guard ext == "md" || ext == "markdown" else { return AttributedString(text) }
        var shown = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { shown.append(AttributedString("\n")) }
            var body = Substring(line)
            let level = body.prefix(while: { $0 == "#" }).count
            let isHeading = (1...6).contains(level) && body.dropFirst(level).first == " "
            if isHeading { body = body.dropFirst(level + 1) }
            var styled = (try? AttributedString(
                markdown: String(body), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(String(body))
            if isHeading { styled.font = .system(level == 1 ? .title3 : .headline, design: .serif).weight(.bold) }
            shown.append(styled)
        }
        return shown
    }
}

/// What the editor sheet is opened on: a file of the writing's, or a new one.
struct WritingDocumentEditing: Identifiable {
    let id = UUID()
    let writingID: String
    /// Nil for a new file, named in the sheet.
    let document: WritingDocument?
}

/// One of a writing's files, written as its text: the Markdown as it's kept,
/// so nothing the Mac or its assistant wrote is rewritten by an editor.
struct WritingDocumentEditor: View {
    let editing: WritingDocumentEditing
    /// Told when a file was saved, kept or deleted, so the list reads again.
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var problem: String?
    @State private var changedMeanwhile = false
    @State private var confirmingDelete = false
    @State private var working = false

    private var isNew: Bool { editing.document == nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isNew {
                    TextField("File name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    Divider()
                }
                TextEditor(text: $text)
                    .font(.system(.body, design: isPlain ? .monospaced : .default))
                    .padding(.horizontal, 12)
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                }
            }
            .navigationTitle(isNew ? "New File" : (editing.document?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(working || (isNew && WritingDocuments.newName(from: name) == nil))
                }
                if !isNew {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete File", systemImage: "trash")
                        }
                        .disabled(working)
                    }
                }
            }
            .confirmationDialog(
                "Delete \(editing.document?.name ?? "this file")?",
                isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete File", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It's deleted on your other devices too.")
            }
            .alert("Changed on Another Device", isPresented: $changedMeanwhile) {
                Button("Keep Mine as a Copy") { Task { await keepAsCopy() } }
                Button("Discard Mine", role: .destructive) { onChange(); dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("This file changed while you were editing it. Your text can be kept beside it as a copy.")
            }
        }
        .interactiveDismissDisabled(isEdited)
        .onAppear {
            text = editing.document?.text ?? ""
        }
    }

    private var isPlain: Bool {
        let shown = isNew ? (WritingDocuments.newName(from: name) ?? name) : (editing.document?.name ?? "")
        return ["txt", "text"].contains((shown as NSString).pathExtension.lowercased())
    }

    private var isEdited: Bool {
        text != (editing.document?.text ?? "") || (isNew && !name.isEmpty)
    }

    private func save() async {
        let fileName: String
        if let document = editing.document {
            fileName = document.name
        } else if let typed = WritingDocuments.newName(from: name) {
            fileName = typed
        } else {
            problem = "That can't be a file's name."
            return
        }
        working = true
        defer { working = false }
        do {
            if try await WritingDocuments.save(
                text, writingID: editing.writingID, name: fileName, opened: editing.document?.data
            ) {
                onChange()
                dismiss()
            } else if isNew {
                problem = "There's already a file called \(fileName)."
            } else {
                changedMeanwhile = true
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func keepAsCopy() async {
        guard let document = editing.document else { return }
        working = true
        defer { working = false }
        do {
            _ = try await WritingDocuments.saveAsCopy(text, writingID: editing.writingID, of: document.name)
            await ModuleSyncManager.shared.scheduleLibraryPass()
            onChange()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete() async {
        guard let document = editing.document else { return }
        working = true
        defer { working = false }
        do {
            // A copy sync brought in while this one was open is kept.
            if let kept = try await WritingDocuments.delete(
                writingID: editing.writingID, name: document.name, seen: document.data
            ) {
                onChange()
                problem = "It changed on another device while open, so that version is kept as \(kept)."
                return
            }
            onChange()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
