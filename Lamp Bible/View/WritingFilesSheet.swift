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

/// A writing's files, as the Mac's workspace keeps them: the writing, and
/// beside it its outline, notes and sources. Opened over the writing in any
/// mode, so a file can be read while the writing is written or presented.
struct WritingFilesSheet: View {
    let writingID: String
    let writingTitle: String
    let canEdit: Bool
    /// The writing's reading size, which a file is read at too.
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [WritingDocument] = []
    @State private var loaded = false
    @State private var editing: WritingDocumentEditing?
    @State private var deleting: WritingDocument?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The writing itself, which is where the sheet goes back to.
                    Button { dismiss() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(LampTheme.caption)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(writingTitle.isEmpty ? "Untitled" : writingTitle)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text("This writing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    ForEach(documents) { document in
                        NavigationLink(value: document.name) {
                            fileRow(document)
                        }
                        .swipeActions {
                            if canEdit {
                                Button(role: .destructive) { deleting = document } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if loaded && documents.isEmpty {
                        Text("No other files yet.")
                            .foregroundStyle(.secondary)
                    }
                    if canEdit {
                        Button {
                            editing = WritingDocumentEditing(writingID: writingID, document: nil)
                        } label: {
                            Label("Add File", systemImage: "doc.badge.plus")
                        }
                    }
                } header: {
                    Text("Other Files")
                } footer: {
                    Text("The outline, notes and sources kept beside this writing, on the Mac and here.")
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: String.self) { name in
                WritingFileView(
                    name: name,
                    document: documents.first { $0.name == name },
                    canEdit: canEdit,
                    fontSize: fontSize,
                    onEdit: { editing = WritingDocumentEditing(writingID: writingID, document: $0) }
                )
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .writingDocumentsDidChange)) { _ in
            Task { await reload() }
        }
        .sheet(item: $editing) { editing in
            WritingDocumentEditor(editing: editing) {
                Task { await reload() }
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "this file")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { document in
            Button("Delete File", role: .destructive) { Task { await delete(document) } }
        } message: { _ in
            Text("It's deleted on your other devices too.")
        }
        .alert(
            "Kept a Copy",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func fileRow(_ document: WritingDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: WritingDocumentText.isMarkdown(document.name) ? "doc.text" : "doc.plaintext")
                .foregroundStyle(LampTheme.caption)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(document.name)
                        .lineLimit(2)
                    if document.isKeptCopy {
                        Text("Kept copy")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if let modified = document.modified {
                    Text("Edited \(modified, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reload() async {
        let loaded = await WritingDocuments.load(writingID: writingID)
        documents = loaded
        self.loaded = true
    }

    private func delete(_ document: WritingDocument) async {
        do {
            // A copy sync brought in since it was shown is kept.
            if let kept = try await WritingDocuments.delete(
                writingID: writingID, name: document.name, seen: document.data
            ) {
                notice = "It changed on another device meanwhile, so that version is kept as \(kept)."
            }
        } catch {
            notice = error.localizedDescription
        }
        await reload()
    }
}

/// One of a writing's files, read: Markdown set as it reads, plain text as
/// it is. Gone back from once the file is deleted, here or elsewhere.
struct WritingFileView: View {
    let name: String
    let document: WritingDocument?
    let canEdit: Bool
    let fontSize: CGFloat
    let onEdit: (WritingDocument) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let document {
                if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing in this file yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if WritingDocumentText.isMarkdown(document.name) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(WritingDocumentText.segments(document.text).enumerated()), id: \.offset) { _, segment in
                            block(segment)
                        }
                    }
                    .padding(.vertical, 16)
                } else {
                    WritingFileText(text: WritingDocumentText.plain(document.text, fontSize: fontSize))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit, let document {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { onEdit(document) }
                }
            }
        }
        .onChange(of: document == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    /// Prose wraps; a code block and a table keep their lines and columns,
    /// scrolled sideways where they're wider than the sheet.
    @ViewBuilder
    private func block(_ segment: WritingDocumentText.Segment) -> some View {
        switch segment {
        case .markdown(let text):
            WritingFileText(text: WritingDocumentText.prose(text, fontSize: fontSize))
                .padding(.horizontal, 20)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: fontSize * 0.8, design: .monospaced))
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
            }
        case .table(let rows):
            let size = fontSize * 0.9
            let widths = WritingDocumentText.columnWidths(rows, size: size, widest: fontSize * 14)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow(alignment: .firstTextBaseline) {
                            ForEach(widths.indices, id: \.self) { column in
                                Text(WritingDocumentText.cell(column < row.count ? row[column] : ""))
                                    .font(Font(LampTheme.serif(size: size, weight: index == 0 ? .semibold : .regular)))
                                    // A width of its own, so a long cell's
                                    // wrapped lines are measured as drawn.
                                    .frame(width: widths[column], alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if index == 0 {
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 20)
            }
        }
    }
}

/// A file's text as it reads. Markdown is drawn as a note's is, line by line
/// in the writing's serif, cut where a fenced code block or a table is,
/// which that doesn't draw: the reader sets those itself.
enum WritingDocumentText {
    static func isMarkdown(_ name: String) -> Bool {
        ["md", "markdown"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Plain text as it was typed, in the writing's serif.
    static func plain(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        var attributes = NoteMarkdown.baseAttributes(fontSize: fontSize, serif: true)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.35
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Markdown prose, its links kept to be opened.
    static func prose(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        NoteMarkdown.render(text, fontSize: fontSize, serif: true, linksTapped: true).text
    }

    /// Each column as wide as its widest cell, up to `widest`, past which
    /// its cells wrap.
    static func columnWidths(_ rows: [[String]], size: CGFloat, widest: CGFloat) -> [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        return (0..<columns).map { column in
            let measured = rows.enumerated().map { index, row -> CGFloat in
                guard column < row.count else { return 0 }
                let font = LampTheme.serif(size: size, weight: index == 0 ? .semibold : .regular)
                let text = String(cell(row[column]).characters) as NSString
                return ceil(text.size(withAttributes: [.font: font]).width) + 2
            }
            return min(widest, max(size, measured.max() ?? 0))
        }
    }

    /// A table cell's inline Markdown, or the cell as written where it won't read.
    static func cell(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }

    enum Segment: Equatable {
        case markdown(String)
        case code(String)
        /// Its rows' cells, the header's first.
        case table([[String]])
    }

    static func isDelimiterRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && trimmed.contains("-") && trimmed.allSatisfy { "|:- ".contains($0) }
    }

    /// A table row's cells, its outer pipes dropped and an escaped pipe kept
    /// as a pipe in its cell.
    static func cells(_ row: String) -> [String] {
        let row = row.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var endsWithPipe = false
        for character in row {
            endsWithPipe = false
            if escaped {
                // Only an escaped pipe is the row's to read: any other escape
                // is left for the cell's own Markdown.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
                endsWithPipe = true
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        if !endsWithPipe { cells.append(cell) }
        if row.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The text cut where a fenced code block or a table starts and ends.
    /// A fence's own lines and a table's alignment row are left out; a fence
    /// never closed runs to the end, as Markdown reads it.
    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        var table: [[String]] = []
        var fence: (mark: Character, length: Int)?
        func endProse() {
            if !prose.isEmpty { segments.append(.markdown(prose.joined(separator: "\n"))) }
            prose = []
        }
        func endTable() {
            if !table.isEmpty { segments.append(.table(table)) }
            table = []
        }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var inTable = false
        var skip = false
        for (index, line) in lines.enumerated() {
            if skip {
                skip = false
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inTable {
                // Its rows, their outer pipes optional, up to a line without one.
                if trimmed.contains("|") {
                    table.append(cells(trimmed))
                    continue
                }
                inTable = false
                endTable()
            }
            if let open = fence {
                let run = trimmed.prefix(while: { $0 == open.mark }).count
                if run >= open.length && run == trimmed.count {
                    fence = nil
                    segments.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(line)
                }
                continue
            }
            if let mark = trimmed.first, mark == "`" || mark == "~" {
                let run = trimmed.prefix(while: { $0 == mark }).count
                // Backticks after a backtick fence's own make a code span.
                if run >= 3, mark == "~" || !trimmed.dropFirst(run).contains("`") {
                    endProse()
                    fence = (mark, run)
                    code = []
                    continue
                }
            }
            // A table is its header over the row that says how its columns
            // align, which is left out; a line merely starting with a pipe
            // is prose.
            if trimmed.contains("|"), index + 1 < lines.count, isDelimiterRow(lines[index + 1]) {
                endProse()
                table = [cells(trimmed)]
                inTable = true
                skip = true
                continue
            }
            prose.append(line)
        }
        endProse()
        endTable()
        if let code { segments.append(.code(code.joined(separator: "\n"))) }
        return segments
    }
}

/// A file's drawn text, selectable to copy from, as tall as it runs.
private struct WritingFileText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        AIFeatures.shared.govern(view)
        view.linkTextAttributes = [.foregroundColor: UIColor.lampLink]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard !(view.attributedText?.isEqual(to: text) ?? false) else { return }
        view.attributedText = text
        context.coordinator.size = nil
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        if let size = context.coordinator.size, abs(size.width - width) < 1 { return size }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: fitted.height)
        context.coordinator.size = size
        return size
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var size: CGSize?
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
