import LampCore
import LampModuleKit
import SwiftUI

typealias WritingDocument = LampWritingDocumentStore.Document

/// A writing's other files, its outline, notes and sources, as the Mac keeps
/// them beside the prose: read and written through core's store, so a save
/// never writes over a copy sync took in meanwhile.
enum WritingDocuments {
    /// The writing's documents, read off the main thread. Each text read is
    /// one its marks may be anchored in, so it's remembered for their carry.
    @MainActor
    static func load(writingID: String) async -> [WritingDocument] {
        let documents = await Task.detached(priority: .userInitiated) {
            (try? LibrarySyncPass.documentStore.documents(writingID: writingID)) ?? []
        }.value
        for document in documents {
            WritingReviewTexts.shared.remember(document.text, for: writingID, document: document.name)
        }
        return documents
    }

    /// Writes the editor's text over what it opened (`opened`, nil for a new
    /// file). False, writing nothing, where the file changed meanwhile.
    ///
    /// The document's marks are carried onto what's written, from the texts
    /// of it held here (`LampWritingDocumentReview.carry`): without that,
    /// the first word typed after a mark would stray every one.
    @MainActor
    static func save(_ text: String, writingID: String, name: String, opened: Data?) async throws -> Bool {
        if let opened {
            WritingReviewTexts.shared.remember(String(decoding: opened, as: UTF8.self), for: writingID, document: name)
        }
        let known = WritingReviewTexts.shared.known(for: writingID, document: name)
        let (saved, carried) = try await Task.detached(priority: .userInitiated) {
            // Written and carried as one, under the lock a pass takes a
            // download in under: a body sync put in between would have its
            // marks carried onto text that's no longer the document's.
            try LibrarySyncPass.documentChanges.withLock {
                let saved = try LibrarySyncPass.documentStore.write(
                    Data(text.utf8), writingID: writingID, name: name, replacing: opened
                )
                guard saved else { return (false, false) }
                let carried = (try? LampWritingDocumentReview.carry(
                    text, ofDocument: name, writingID: writingID, from: known, in: LibrarySyncPass.reviewStore
                )) ?? false
                return (true, carried)
            }
        }.value
        if saved {
            WritingReviewTexts.shared.remember(text, for: writingID, document: name)
            if carried { NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil) }
            await ModuleSyncManager.shared.scheduleLibraryPass()
        }
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
    /// Whether the assistant's changes are marked (`AIFeatures.marksReviews`
    /// and the writing the writer's to change), as in the writing itself.
    var showsMarks = false
    /// The writing's reading size, which a file is read at too.
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [WritingDocument] = []
    @State private var loaded = false
    @State private var editing: WritingDocumentEditing?
    @State private var deleting: WritingDocument?
    @State private var notice: String?
    /// How many of the assistant's changes each file holds still to read.
    @State private var toReview: [String: Int] = [:]
    @State private var countReads = 0

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
                    writingID: writingID,
                    name: name,
                    document: documents.first { $0.name == name },
                    canEdit: canEdit,
                    showsMarks: showsMarks,
                    fontSize: fontSize,
                    onEdit: { editing = WritingDocumentEditing(writingID: writingID, document: $0) }
                )
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .writingDocumentsDidChange)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .writingReviewsDidChange)) { _ in
            Task { await reload() }
        }
        .onChange(of: showsMarks) { Task { await reload() } }
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
                if let count = toReview[document.name], count > 0 {
                    Label("\(count) to review", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: WritingDocumentText.markEdge))
                        .labelStyle(TightDotLabelStyle())
                }
            }
        }
    }

    private func reload() async {
        let loaded = await WritingDocuments.load(writingID: writingID)
        documents = loaded
        self.loaded = true
        countReads += 1
        guard showsMarks else {
            toReview = [:]
            return
        }
        let read = countReads
        let writingID = writingID
        let known = Dictionary(uniqueKeysWithValues: loaded.map {
            ($0.name, WritingReviewTexts.shared.known(for: writingID, document: $0.name))
        })
        let counts = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: loaded.map { document in
                (document.name, WritingDocumentMarks.load(
                    writingID: writingID, document: document.name, text: document.text, known: known[document.name] ?? []
                )?.count ?? 0)
            })
        }.value
        guard read == countReads else { return }
        if toReview != counts { toReview = counts }
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

/// A small dot before a caption, in the caption's colour.
private struct TightDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

/// A document's review marks as its reader draws them: carried to the text
/// it shows, that text with a marker at each passage's edges, and for each
/// passage in order its range there and what restoring it would put back.
struct WritingDocumentMarks: Equatable, Sendable {
    let text: String
    let marked: String
    let ranges: [NSRange]
    let changes: [LampWritingReview.Change?]
    /// How many passages are still to read, places words were taken out
    /// among them.
    let count: Int

    /// Nil where the document has none to draw. Off the main actor: the
    /// whole document is compared.
    nonisolated static func load(writingID: String, document: String, text: String, known: [String]) -> Self? {
        guard let review = try? LibrarySyncPass.reviewStore.review(writingID: writingID, document: document),
              !review.isEmpty else { return nil }
        let live = review.carryingToText(text, from: known)
        guard let marked = live.markedMarkdown(in: text) else { return nil }
        let ranges = live.highlightedRanges(in: text)
        let changes = live.wordings.isEmpty ? ranges.map { _ in nil } : live.changes(in: text, ranges: ranges)
        return Self(text: text, marked: marked, ranges: ranges, changes: changes, count: live.located(in: text).count)
    }
}

/// One of a writing's files, read: Markdown set as it reads, plain text as
/// it is, and what the assistant changed in it marked, as the writing's own
/// prose is. A tap on a marked passage shows what it changed, to mark as
/// reviewed or put back. Gone back from once the file is deleted, here or
/// elsewhere.
struct WritingFileView: View {
    let writingID: String
    let name: String
    let document: WritingDocument?
    let canEdit: Bool
    /// Whether marks are drawn: the AI features on, the writer keeping
    /// marks, and the writing theirs to change (`AIFeatures.marksReviews`).
    let showsMarks: Bool
    let fontSize: CGFloat
    let onEdit: (WritingDocument) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var marks: WritingDocumentMarks?
    @State private var chosen: ChosenMark?
    @State private var refusal: String?
    @State private var working = false
    /// Counts each read of the marks, so one that finishes after a later one
    /// isn't shown over it.
    @State private var loads = 0

    /// What the marks are read again for: the text, or marks turned on or off.
    struct MarksKey: Equatable {
        let text: String?
        let shown: Bool
    }

    /// The passage a tap chose, as it was drawn then: what it changed, and
    /// its range in the text it was drawn in. Acted on as that, never by its
    /// place among marks read since, which sync may have moved.
    struct ChosenMark: Identifiable {
        let index: Int
        let change: LampWritingReview.Change?
        let range: NSRange
        let text: String
        let verbatim: Bool
        var id: Int { index }
    }

    var body: some View {
        ScrollView {
            if let document {
                // Empty, and nothing taken out of it to put back.
                if document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   marks == nil || marks?.text != document.text {
                    Text("Nothing in this file yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else if WritingDocumentText.isMarkdown(document.name) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(drawnPieces(of: document).enumerated()), id: \.offset) { _, drawn in
                            block(drawn.piece, first: drawn.first, open: drawn.open)
                        }
                    }
                    .padding(.vertical, 16)
                } else {
                    let plain = WritingDocumentText.plain(shownText(of: document), fontSize: fontSize)
                    WritingFileText(text: WritingDocumentText.drawingMarks(plain, first: 0, open: nil).text, onMark: choose)
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
            if let marks, marks.count > 0 {
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        // Each change by its words, so every one can be
                        // opened, however its Markdown is drawn.
                        Section("Changes") {
                            ForEach(marks.ranges.indices, id: \.self) { index in
                                Button(excerpt(of: index, in: marks)) { choose(index) }
                            }
                        }
                        Button {
                            clearAll()
                        } label: {
                            Label("Mark All as Reviewed", systemImage: "checkmark.circle")
                        }
                    } label: {
                        // The count beside the mark, as the writing's own
                        // control has it: a bar's label shows its icon alone.
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text(marks.count, format: .number)
                                .monospacedDigit()
                        }
                        .font(.body.weight(.semibold))
                    }
                    .disabled(working)
                    .accessibilityLabel(marks.count == 1 ? "1 to Review" : "\(marks.count) to Review")
                }
            }
        }
        .onChange(of: document == nil) { _, gone in
            if gone { dismiss() }
        }
        .task(id: MarksKey(text: document?.text, shown: showsMarks)) { await reloadMarks() }
        .onReceive(NotificationCenter.default.publisher(for: .writingReviewsDidChange)) { _ in
            Task { await reloadMarks() }
        }
        .sheet(item: $chosen) { chosen in
            WritingMarkSheet(
                change: chosen.change,
                verbatim: chosen.verbatim,
                canRestore: canEdit,
                onReviewed: {
                    self.chosen = nil
                    clear(chosen)
                },
                onRestore: {
                    self.chosen = nil
                    Task { await restore(chosen) }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .alert(
            "Can’t Restore Original Wording",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    /// The document's text with its marks' markers in, while they're of the
    /// text shown.
    private func shownText(of document: WritingDocument) -> String {
        guard let marks, marks.text == document.text else { return document.text }
        // Placed for Markdown where it's read as Markdown (core leaves code
        // alone); plain text keeps each marker where it stands, since what
        // it draws is what's written.
        guard WritingDocumentText.isMarkdown(document.name) else { return LampWritingReviewMarkdown.numbered(marks.marked) }
        return LampWritingReviewMarkdown.drawable(marks.marked)
    }

    /// Each block to draw, with the place of the first passage it opens and
    /// a passage still open from the block before.
    private func drawnPieces(of document: WritingDocument) -> [(piece: WritingDocumentText.Piece, first: Int, open: Int?)] {
        var first = 0
        var open: Int?
        return WritingDocumentText.pieces(shownText(of: document), fontSize: fontSize).map { piece in
            let drawn = (piece, first, open)
            (first, open) = LampWritingReviewMarkdown.passing(piece.marked, first: first, open: open)
            return drawn
        }
    }

    /// Prose wraps; a code block and a table keep their lines and columns,
    /// scrolled sideways where they're wider than the sheet.
    @ViewBuilder
    private func block(_ piece: WritingDocumentText.Piece, first: Int, open: Int?) -> some View {
        switch piece {
        case .prose(let prose):
            WritingFileText(
                text: WritingDocumentText.linkingAddresses(WritingDocumentText.drawingMarks(prose, first: first, open: open).text),
                onMark: choose
            )
                .padding(.horizontal, 20)
        case .code(let text, let indent):
            ScrollView(.horizontal) {
                Text(WritingDocumentText.drawingMarks(AttributedString(text), first: first, open: open).text)
                    .font(.system(size: fontSize * 0.8, design: .monospaced))
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.leading, indent)
            }
            .environment(\.openURL, markAction)
            // A mark is drawn as its text is, not in the link colour.
            .tint(.primary)
        case .table(let rows, let indent):
            let size = fontSize * 0.9
            let widths = WritingDocumentText.columnWidths(
                rows.map { $0.map { String($0.characters) } }, size: size, widest: fontSize * 14
            )
            let cells = drawnCells(rows, first: first, open: open)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow(alignment: .firstTextBaseline) {
                            ForEach(widths.indices, id: \.self) { column in
                                Text(column < cells[index].count ? cells[index][column] : AttributedString())
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
                .padding(.leading, indent)
            }
            .environment(\.openURL, markAction)
            .tint(.primary)
        }
    }

    /// A table's cells, their marks drawn, in reading order.
    private func drawnCells(_ rows: [[AttributedString]], first: Int, open: Int?) -> [[AttributedString]] {
        var first = first
        var open = open
        return rows.map { row in
            row.map { cell in
                let drawn = WritingDocumentText.drawingMarks(cell, first: first, open: open)
                first = drawn.next
                open = drawn.open
                return WritingDocumentText.linkingAddresses(WritingDocumentText.trimmed(drawn.text))
            }
        }
    }

    /// A change named by its words now, or what's there where it took words
    /// out, short enough for a menu.
    private func excerpt(of index: Int, in marks: WritingDocumentMarks) -> String {
        let range = marks.ranges[index]
        let now = index < marks.changes.count ? marks.changes[index]?.now : nil
        let source = (now ?? (marks.text as NSString).substring(with: range)).replacingOccurrences(of: "\n", with: " ")
        // Its words as they read, not their Markdown.
        let words = String(WritingDocumentText.cell(source).characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return "Words taken out" }
        return words.count > 48 ? String(words.prefix(47)) + "…" : words
    }

    private var markAction: OpenURLAction {
        OpenURLAction { url in
            guard let index = WritingDocumentText.markIndex(url) else { return .systemAction }
            choose(index)
            return .handled
        }
    }

    private func choose(_ index: Int) {
        guard let marks, index >= 0, index < marks.ranges.count else { return }
        chosen = ChosenMark(
            index: index, change: index < marks.changes.count ? marks.changes[index] : nil,
            range: marks.ranges[index], text: marks.text,
            verbatim: !WritingDocumentText.isMarkdown(name) || WritingDocumentText.inCode(marks.ranges[index], of: marks.text)
        )
    }

    private func reloadMarks() async {
        // Counted first, so a read still running when marks are turned off
        // isn't shown after.
        loads += 1
        let load = loads
        guard showsMarks, let document else {
            marks = nil
            return
        }
        let writingID = writingID
        let name = name
        let text = document.text
        WritingReviewTexts.shared.remember(text, for: writingID, document: name)
        let known = WritingReviewTexts.shared.known(for: writingID, document: name)
        let loaded = await Task.detached(priority: .userInitiated) {
            WritingDocumentMarks.load(writingID: writingID, document: name, text: text, known: known)
        }.value
        // Not over a later read, nor a newer text's.
        guard load == loads, !Task.isCancelled, showsMarks, self.document?.text == text else { return }
        if marks != loaded { marks = loaded }
    }

    /// Clears the passage, in the text it was drawn in, the marks carried
    /// there from the texts known.
    private func clear(_ chosen: ChosenMark) {
        change { [range = chosen.range, text = chosen.text] review, known in
            review.clearing(range, in: text, carryingFrom: known)
        }
    }

    private func clearAll() {
        change { review, _ in review.clearingAll() }
    }

    private func change(_ edit: @escaping @Sendable (LampWritingReview, [String]) -> LampWritingReview) {
        let writingID = writingID
        let name = name
        let known = WritingReviewTexts.shared.known(for: writingID, document: name)
        working = true
        Task {
            await Task.detached(priority: .userInitiated) {
                _ = try? LibrarySyncPass.reviewStore.update(writingID: writingID, document: name) { edit($0, known) }
            }.value
            working = false
            WritingReviewWork.marksChanged()
            // The list's counts read again too.
            NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil)
        }
    }

    /// Puts back what the passage's marks replaced: the restored text written
    /// over the document as it was drawn, only if it's still that, and the
    /// restore recorded with it, under the lock a pass takes a download in
    /// under. Nothing is owed: the text written is the text recorded.
    private func restore(_ chosen: ChosenMark) async {
        // The marks it named, in the text it was drawn in, if the document
        // is still that.
        guard let change = chosen.change else { return }
        guard let document, chosen.text == document.text else {
            refusal = WritingRestoreRefusal.moved
            return
        }
        let writingID = writingID
        let name = name
        let text = document.text
        let opened = document.data
        let wanted = LampWritingReview.Change.marks(in: change.id)
        let known = WritingReviewTexts.shared.known(for: writingID, document: name)
        working = true
        defer { working = false }
        let outcome: Result<String, RestoreRefused> = await Task.detached(priority: .userInitiated) {
            let reviews = LibrarySyncPass.reviewStore
            guard let review = try? reviews.review(writingID: writingID, document: name) else {
                return .failure(.with(WritingRestoreRefusal.moved))
            }
            let plan: LampWritingReview.RestorePlan
            switch review.carryingToText(text, from: known).restoring(marks: wanted, in: text) {
            case .plan(let found): plan = found
            case .notKept: return .failure(.with(WritingRestoreRefusal.notKept))
            case .notExact, .nothingTouched: return .failure(.with(WritingRestoreRefusal.edited))
            }
            let restored = plan.applied(to: text)
            do {
                return try LibrarySyncPass.documentChanges.withLock {
                    guard try LibrarySyncPass.documentStore.write(
                        Data(restored.utf8), writingID: writingID, name: name, replacing: opened
                    ) else { return .failure(.with(WritingRestoreRefusal.moved)) }
                    do {
                        _ = try reviews.update(writingID: writingID, document: name) {
                            $0.restoringWording(plan, from: text, to: restored, carryingFrom: known)
                        }
                    } catch {
                        // Not recorded: the file put back as it was, so what's
                        // shown and what's recorded agree.
                        _ = try? LibrarySyncPass.documentStore.write(
                            Data(text.utf8), writingID: writingID, name: name, replacing: Data(restored.utf8)
                        )
                        throw error
                    }
                    // The other marks carried onto the text written, as a save
                    // carries them.
                    _ = try? LampWritingDocumentReview.carry(
                        restored, ofDocument: name, writingID: writingID, from: known + [text], in: reviews
                    )
                    return .success(restored)
                }
            } catch {
                return .failure(.with(error.localizedDescription))
            }
        }.value
        switch outcome {
        case .success(let restored):
            WritingReviewTexts.shared.remember(restored, for: writingID, document: name)
            NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
            WritingReviewWork.marksChanged()
        case .failure(.with(let why)):
            refusal = why
        }
    }

    enum RestoreRefused: Error {
        case with(String)
    }
}

/// What a marked passage in a file changed, shown when it's tapped: the
/// words now and the ones before, or why they can't be put back, with the
/// passage's two answers. As the writing's own page shows them.
struct WritingMarkSheet: View {
    let change: LampWritingReview.Change?
    /// Shown as written, not read as Markdown: a change in plain text or in
    /// a code block.
    var verbatim = false
    let canRestore: Bool
    let onReviewed: () -> Void
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let change {
                        section("Now", change.now, marked: true)
                        if let before = change.before {
                            if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                section("Original", nil, marked: false)
                            } else {
                                section("Original", before, marked: false)
                            }
                        } else if change.reason != nil {
                            Text("Can’t be put back: you’ve edited this since")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Lamp didn’t keep what this change replaced.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        if canRestore, change?.before != nil {
                            Button(action: onRestore) {
                                Text("Restore Original Wording").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(uiColor: WritingDocumentText.markEdge))
                        }
                        Button(action: onReviewed) {
                            Text("Mark as Reviewed").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                    }
                    .controlSize(.large)
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationTitle("Assistant’s Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ label: String, _ text: String?, marked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let text {
                let shown = text.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(verbatim ? AttributedString(shown) : WritingDocumentText.cell(shown))
                    .font(.system(.body, design: .serif))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(marked ? Color(uiColor: WritingDocumentText.markTint) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Nothing: the assistant added these words")
                    .font(.system(.body, design: .serif).italic())
                    .foregroundStyle(.secondary)
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

    // MARK: Blocks

    /// One piece of a Markdown file as the reader lays it out: prose drawn
    /// as one text, and a code block or a table set apart, wider than the
    /// sheet where it must be. Review markers stay in each, for
    /// `drawingMarks`.
    enum Piece {
        case prose(NSAttributedString)
        /// `indent`: how far in the quotations and list items holding it set
        /// it.
        case code(String, indent: CGFloat = 0)
        /// Its rows' cells, the header's first.
        case table([[AttributedString]], indent: CGFloat = 0)

        /// This piece where it reads as `plain` (the same piece read without
        /// its markers) does, and `plain` where it doesn't: for prose, a
        /// paragraph at a time, so one marker that changed its paragraph's
        /// reading costs only that paragraph its marks.
        func merged(onto plain: Piece) -> Piece {
            switch (self, plain) {
            case (.prose(let text), .prose(let bare)):
                let marked = Self.paragraphs(of: text)
                let read = Self.paragraphs(of: bare)
                guard marked.count == read.count else { return plain }
                let out = NSMutableAttributedString()
                for (mine, theirs) in zip(marked, read) { out.append(mine.shape == theirs.shape ? mine.text : theirs.text) }
                return .prose(out)
            case (.code(let code, _), .code(let bare, _)):
                return unmarked(code) == bare ? self : plain
            case (.table(let rows, _), .table(let bare, _)):
                // A space the parser kept beside a marker draws as nothing;
                // where a cell's link goes does.
                let cell: (AttributedString) -> String = { cell in
                    unmarked(String(cell.characters)).trimmingCharacters(in: .whitespaces) + "|"
                        + cell.runs.compactMap { $0.link.map { (cleanedLink($0) ?? $0).absoluteString } }.joined(separator: " ")
                }
                return rows.map { $0.map(cell) } == bare.map { $0.map(cell) } ? self : plain
            default:
                return plain
            }
        }

        /// Each paragraph with its break, and its shape: its words without
        /// their markers, how it's indented and set where its words begin,
        /// and where its links go. What a marker that changed the reading
        /// would change.
        private static func paragraphs(of text: NSAttributedString) -> [(text: NSAttributedString, shape: String)] {
            var out: [(text: NSAttributedString, shape: String)] = []
            let string = text.string as NSString
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { words, range, enclosing, _ in
                var at = range.location
                while at < NSMaxRange(range), (0xE000...0xE01A).contains(string.character(at: at)) { at += 1 }
                var shape = unmarked(words ?? "").trimmingCharacters(in: .whitespaces)
                if at < string.length {
                    let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                    let font = text.attribute(.font, at: at, effectiveRange: nil) as? UIFont
                    shape += "|\(style?.headIndent ?? 0)|\(style?.firstLineHeadIndent ?? 0)|\(font?.fontName ?? "")|\(font?.pointSize ?? 0)"
                }
                text.enumerateAttribute(.link, in: range) { link, _, _ in
                    guard let url = link as? URL else { return }
                    shape += "|" + (cleanedLink(url) ?? url).absoluteString
                }
                out.append((text.attributedSubstring(from: enclosing), shape))
            }
            return out
        }

        /// Its words with their markers, for counting passages across it.
        var marked: String {
            switch self {
            case .prose(let text): return text.string
            case .code(let code, _): return code
            case .table(let rows, _): return rows.flatMap { $0 }.map { String($0.characters) }.joined()
            }
        }
    }

    /// A file's Markdown as the writer's editor reads it, by core
    /// (`LampProse`, a writing's options: a soft wrap joins), laid out in
    /// the writing's serif, its review markers drawn where they're safe to.
    ///
    /// A marker is a character to the parser, and wherever one stands it
    /// can change what a line reads as. So the file is read twice, with its
    /// markers and without, and a piece keeps its markers only where it
    /// reads exactly as it does without them; elsewhere it's drawn as
    /// written, its changes still listed under the count. The common cases
    /// (a fence's or a table's own lines, a blank line, a footnote's label)
    /// are moved first, so they keep theirs.
    static func pieces(_ markdown: String, fontSize: CGFloat) -> [Piece] {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let plain = layout(unmarked(text), fontSize: fontSize)
        guard text.contains(where: isMarker) else { return plain }
        guard !plain.isEmpty else {
            // Nothing left to read: what was taken out still to tap.
            let points = LampWritingReviewMarkdown.asPoints(markers(in: text))
            return [.prose(NSAttributedString(string: points, attributes: NoteMarkdown.baseAttributes(fontSize: fontSize, serif: true)))]
        }
        let marked = layout(settlingSyntaxLines(placingEnds(text)), fontSize: fontSize)
        guard marked.count == plain.count else { return plain }
        return pointingUnpaired(zip(marked, plain).map { $0.merged(onto: $1) })
    }

    private static func layout(_ text: String, fontSize: CGFloat) -> [Piece] {
        let blocks = LampProse.blocks(text, options: .writing)
        var layout = ProseLayout(fontSize: fontSize, footnoteNumbers: footnoteNumbers(blocks))
        layout.add(blocks, depth: 0, quote: 0)
        layout.flush()
        return layout.pieces
    }

    /// What each footnote is shown as, as the editor numbers them
    /// (footnote-numbering.js): those defined, 1, 2, 3 in the order they're
    /// first referred to, then any nothing refers to in the order written.
    /// A reference nothing defines keeps its label.
    static func footnoteNumbers(_ blocks: [LampProseBlock]) -> [String: String] {
        var defined: [String] = []
        var referred: [String] = []
        func texts(_ blocks: [LampProseBlock]) {
            for block in blocks {
                switch block {
                case .heading(_, let text), .paragraph(let text): refer(text)
                case .quote(let inner): texts(inner)
                case .list(_, _, let items): items.forEach { texts($0.blocks) }
                case .table(let headers, let rows): (headers + rows.flatMap { $0 }).forEach(refer)
                case .footnote(let label, _):
                    // Numbered by the text's own references, as the editor
                    // numbers them; one inside a note doesn't count.
                    defined.append(unmarked(label))
                case .code, .html, .audio, .picture, .rule: break
                }
            }
        }
        func refer(_ text: LampProseText) {
            for run in text.text.runs {
                guard let label = run[LampFootnoteReferenceAttribute.self] else { continue }
                // References alike in a row are one run; one is enough here.
                referred.append(unmarked(label))
            }
        }
        texts(blocks)
        var numbers: [String: String] = [:]
        for label in referred + defined where defined.contains(label) && numbers[label] == nil {
            numbers[label] = String(numbers.count + 1)
        }
        return numbers
    }

    /// Each end marker given the place of the start it closes, so a passage
    /// is known by both its edges: should the parse lose one edge of each
    /// of two passages, the two left aren't taken for one.
    static func placingEnds(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        var open: String?
        var at = 0
        while at < characters.count {
            let character = characters[at]
            out.append(character)
            if character == LampWritingReview.markStart || character == LampWritingReview.markPoint {
                var place = ""
                var next = at + 1
                while next < characters.count, LampWritingReviewMarkdown.placeDigit(characters[next]) != nil {
                    place.append(characters[next])
                    next += 1
                }
                if !place.isEmpty, next < characters.count, characters[next] == LampWritingReviewMarkdown.placeEnd {
                    out += place + String(LampWritingReviewMarkdown.placeEnd)
                    if character == LampWritingReview.markStart { open = place }
                    at = next
                }
            } else if character == LampWritingReview.markEnd {
                if let place = open { out += place + String(LampWritingReviewMarkdown.placeEnd) }
                open = nil
            }
            at += 1
        }
        return out
    }

    /// The marked text with markers taken off what's only syntax, where
    /// they'd stop it reading as it does: a fence's lines (the first's into
    /// its code, the last's onto the code's end), a table's alignment row
    /// (onto the row after), a row's outer pipes (moved inside them), a
    /// change of only the pipe between two cells (a point), a footnote's
    /// label, and a blank line (onto the next line with words). Core's
    /// placement leaves code as written (`LampWritingReviewMarkdown.drawable`),
    /// fences included, since a surface that checks its parse refuses them;
    /// this one draws them. Whatever this misses, `pieces` catches.
    static func settlingSyntaxLines(_ marked: String) -> String {
        var lines = marked.components(separatedBy: "\n")
        let bareLines = lines.map(unmarked)
        guard lines.count > 1 || marked.contains(where: isMarker) else { return marked }
        let model = LampMarkdownModel(parsing: bareLines.joined(separator: "\n"))
        var starts: [Int] = []
        var offset = 0
        for line in bareLines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        func line(of location: Int) -> Int {
            var low = 0, high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= location { low = middle } else { high = middle - 1 }
            }
            return low
        }
        func taking(_ index: Int) -> String {
            let found = markers(in: lines[index])
            if !found.isEmpty { lines[index] = unmarked(lines[index]) }
            return found
        }
        /// Markers put on a line where its words begin: after its quote
        /// marks and indent, then past any block syntax there.
        func putting(_ moved: String, onto index: Int, code: Bool) {
            guard !moved.isEmpty else { return }
            let prefix = containerPrefix(lines[index])
            let placed = String(prefix) + moved + lines[index].dropFirst(prefix.count)
            lines[index] = code ? placed : LampWritingReviewMarkdown.clearingBlockSyntax(placed)
        }
        // Lines a code block or a table holds, which a blank line's markers
        // aren't moved onto, and a blank line in code keeps its own.
        var held = Set<Int>()
        var tables = Set<Int>()
        var tableRows: [Int: Int] = [:]
        // For each line of a code block, the last line of its code.
        var codeEnds: [Int: Int] = [:]
        for block in model.blocks.sorted(by: { $0.range.location < $1.range.location }) {
            let first = line(of: block.range.location)
            let last = line(of: max(block.range.location, NSMaxRange(block.range) - 1))
            if block.kind == .codeBlock || block.kind == .table { held.formUnion(first...last) }
            if block.kind == .table {
                tables.formUnion(first...last)
                // A row that isn't the alignment row, to take markers in.
                for index in first...last { tableRows[index] = index == first + 1 ? first : index }
            }
            switch block.kind {
            case .codeBlock:
                // A fence opens within three spaces of its container, or
                // is closed by its own mark; four in, it's indented code.
                let opener = fence(opening: bareLines[first])
                let indent = bareLines[first].prefix { $0 == " " || $0 == ">" }.filter { $0 == " " }.count
                let fenced = opener.map { indent < 4 || (last > first && closes(bareLines[last], $0)) } ?? false
                guard fenced, let fence = opener else {
                    // Indented code: a marker before the indent moved past
                    // it, or the line isn't code.
                    for index in first...last {
                        let head = lines[index].prefix { isMarker($0) || $0 == " " || $0 == "\t" || $0 == ">" }
                        guard head.contains(where: isMarker) else { continue }
                        lines[index] = String(head.filter { !isMarker($0) }) + markers(in: String(head)) + lines[index].dropFirst(head.count)
                    }
                    for index in first...last { codeEnds[index] = last }
                    continue
                }
                let opening = taking(first)
                // A fence never closed runs to the end of its container.
                let closes = last > first && closes(bareLines[last], fence)
                let closing = closes ? taking(last) : ""
                let inner = (first + 1)..<(closes ? last : last + 1)
                for index in first...last { codeEnds[index] = inner.isEmpty ? first : inner.upperBound - 1 }
                if inner.isEmpty {
                    // Nothing in the block: onto the line after it, the line
                    // before, or, alone in the file, left where it was.
                    let moved = LampWritingReviewMarkdown.asPoints(opening + closing)
                    if last + 1 < lines.count {
                        putting(moved, onto: last + 1, code: false)
                    } else if first > 0 {
                        lines[first - 1] += moved
                    } else {
                        lines[first] += moved
                    }
                } else {
                    putting(LampWritingReviewMarkdown.asPoints(opening), onto: inner.lowerBound, code: true)
                    lines[inner.upperBound - 1] += LampWritingReviewMarkdown.asPoints(closing)
                }
            case .table where last > first:
                let alignment = taking(first + 1)
                if !alignment.isEmpty {
                    let moved = LampWritingReviewMarkdown.asPoints(alignment)
                    if first + 2 <= last { lines[first + 2] = insideRow(moved, lines[first + 2]) } else { lines[first] += moved }
                }
                for index in first...last where index != first + 1 {
                    lines[index] = keepingMarkersInsidePipes(lines[index])
                }
            default:
                break
            }
        }
        for index in lines.indices where !held.contains(index) {
            // A footnote's label read as its label.
            let bare = unmarked(lines[index])
            if lines[index] != bare, let label = bare.prefixMatch(of: #/ {0,3}\[\^[^\]\s]+\]:[ \t]?/#) {
                var moved = ""
                var kept = ""
                var rest = Substring(lines[index])
                while kept.count < bare[label.range].count, let character = rest.first {
                    rest = rest.dropFirst()
                    if isMarker(character) { moved.append(character) } else { kept.append(character) }
                }
                lines[index] = kept + moved + rest
            }
        }
        // A blank line kept blank: its markers onto the next line with words
        // that's prose, else the one before, else left where they were.
        let isBlank: (Int) -> Bool = { unmarked(lines[$0]).allSatisfy { $0 == " " || $0 == "\t" } }
        for index in lines.indices where !held.contains(index) && isBlank(index) && lines[index].contains(where: isMarker) {
            let moved = LampWritingReviewMarkdown.asPoints(markers(in: lines[index]))
            if let next = lines.indices[(index + 1)...].first(where: { !isBlank($0) }), !held.contains(next) {
                lines[index] = unmarked(lines[index])
                putting(moved, onto: next, code: false)
            } else if let before = lines.indices[..<index].last(where: { !isBlank($0) }), !held.contains(before) {
                lines[index] = unmarked(lines[index])
                lines[before] += moved
            } else if let before = lines.indices[..<index].last(where: { !isBlank($0) }) {
                // Only a table or code to go to: into its last cell, or onto
                // the end of its code.
                lines[index] = unmarked(lines[index])
                if let row = tableRows[before] {
                    lines[row] = keepingMarkersInsidePipes(lines[row] + moved)
                } else {
                    lines[codeEnds[before] ?? before] += moved
                }
            }
        }
        for index in lines.indices where !held.contains(index) && lines[index].contains(where: isMarker) {
            lines[index] = markersIntoCaption(lines[index])
        }
        return lines.joined(separator: "\n")
    }

    /// A picture or recording on a line of its own with the markers around
    /// it moved into its caption, where they leave it on a line of its own.
    private static func markersIntoCaption(_ line: String) -> String {
        let bare = unmarked(line)
        guard bare.wholeMatch(of: #/\s*!?\[[^\]]*\]\((?:media/|lamp-media://)[^)\s]+\)\s*/#) != nil,
              let open = line.firstIndex(of: "["), let close = line.range(of: "](") else { return line }
        let head = line[..<open]
        guard let end = line[close.upperBound...].firstIndex(of: ")") else { return line }
        let tail = line[line.index(after: end)...]
        let before = markers(in: String(head.filter { $0 != "!" }))
        let after = markers(in: String(tail))
        guard !before.isEmpty || !after.isEmpty else { return line }
        let bang = head.contains("!") ? "!" : ""
        let indent = head.filter { $0 == " " || $0 == "\t" }
        return indent + bang + "[" + before + line[line.index(after: open)..<close.lowerBound] + after
            + line[close.lowerBound...end]
    }

    /// A line's quote marks and indent, which hold it in its container.
    private static func containerPrefix(_ line: String) -> Substring {
        line.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
    }

    /// The fence a line opens, its quote marks and indent aside: its
    /// character and length.
    private static func fence(opening line: String) -> (character: Character, length: Int)? {
        let rest = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix { $0 == character }.count
        return length >= 3 ? (character, length) : nil
    }

    /// Whether a line closes a fence: the same character, at least as long,
    /// and nothing after but spaces.
    private static func closes(_ line: String, _ fence: (character: Character, length: Int)) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        let run = rest.prefix { $0 == fence.character }
        return run.count >= fence.length && rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// `markers` put at the start of a table row's first cell's words.
    private static func insideRow(_ markers: String, _ row: String) -> String {
        let prefix = containerPrefix(row)
        let rest = row.dropFirst(prefix.count)
        guard rest.first == "|" else { return prefix + markers + rest }
        let cell = rest.dropFirst()
        let space = cell.prefix { $0 == " " || $0 == "\t" }
        return prefix + "|" + space + markers + cell.dropFirst(space.count)
    }

    /// A table row with markers standing outside its outer pipes moved in
    /// past them, where they'd be cells of their own, and a change of only
    /// the pipe between two cells made a point, which neither cell draws.
    private static func keepingMarkersInsidePipes(_ row: String) -> String {
        var row = row
        let isMarkerOrSpace: (Character) -> Bool = { isMarker($0) || $0 == " " || $0 == "\t" || $0 == ">" }
        // Before the first pipe, the quote marks holding the row kept.
        let head = row.prefix(while: isMarkerOrSpace)
        if head.contains(where: isMarker), row.dropFirst(head.count).first == "|" {
            let prefix = String(head.filter { !isMarker($0) })
            row = insideRow(markers(in: String(head)), prefix + row.dropFirst(head.count))
        }
        // After the last.
        let tail = String(row.reversed().prefix { isMarker($0) || $0 == " " || $0 == "\t" }.reversed())
        let body = row.dropLast(tail.count)
        if tail.contains(where: isMarker), body.last == "|", !body.dropLast().hasSuffix("\\") {
            // At the end of the last cell's words, before its spaces.
            let cell = body.dropLast()
            let space = String(cell.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            row = cell.dropLast(space.count) + markers(in: tail) + space + "|"
        }
        return row.replacing(#/\x{E000}([\x{E010}-\x{E01A}]*)([ \t]*)\|([ \t]*)\x{E001}[\x{E010}-\x{E01A}]*/#) { match in
            "\u{E002}\(match.output.1)\(match.output.2)|\(match.output.3)"
        }
    }

    /// The pieces with each passage the parse kept only one edge of drawn
    /// safely: a start without its end a point, rather than highlighted on
    /// to the end of the file, and an end without its start left out.
    private static func pointingUnpaired(_ pieces: [Piece]) -> [Piece] {
        var starts = Set<Int>()
        var ends = Set<Int>()
        for piece in pieces {
            for found in placedMarkers(in: piece.marked as NSString) {
                if found.marker == 0xE000 { starts.insert(found.place) }
                if found.marker == 0xE001 { ends.insert(found.place) }
            }
        }
        let lostEnd = starts.subtracting(ends)
        let lostStart = ends.subtracting(starts)
        guard !lostEnd.isEmpty || !lostStart.isEmpty else { return pieces }
        // Each edge to change, as the range it stands in (the marker and its
        // place) and what it becomes; latest first, so earlier ranges hold.
        func edits(_ text: NSString) -> [(range: NSRange, with: String)] {
            placedMarkers(in: text).compactMap { found -> (NSRange, String)? in
                if found.marker == 0xE000, lostEnd.contains(found.place) {
                    return (NSRange(location: found.at, length: 1), String(LampWritingReview.markPoint))
                }
                if found.marker == 0xE001, lostStart.contains(found.place) {
                    return (NSRange(location: found.at, length: found.length), "")
                }
                return nil
            }.reversed()
        }
        return pieces.map { piece in
            switch piece {
            case .prose(let text):
                let out = NSMutableAttributedString(attributedString: text)
                for edit in edits(text.string as NSString) { out.mutableString.replaceCharacters(in: edit.range, with: edit.with) }
                return .prose(out)
            case .code(let code, let indent):
                let out = NSMutableString(string: code)
                for edit in edits(code as NSString) { out.replaceCharacters(in: edit.range, with: edit.with) }
                return .code(out as String, indent: indent)
            case .table(let rows, let indent):
                return .table(rows.map { row in
                    row.map { cell in
                        // Only a cell with an edge to change is rebuilt, so
                        // every other keeps the attributes it was drawn with.
                        let changes = edits(String(cell.characters) as NSString)
                        guard !changes.isEmpty else { return cell }
                        var out = cell
                        for edit in changes {
                            let source = String(out.characters) as NSString
                            let start = out.characters.index(out.startIndex, offsetBy: source.substring(to: edit.range.location).count)
                            let end = out.characters.index(start, offsetBy: source.substring(with: edit.range).count)
                            var replacement = AttributedString(edit.with)
                            replacement.mergeAttributes(out[start..<end].runs.first?.attributes ?? AttributeContainer())
                            out.replaceSubrange(start..<end, with: replacement)
                        }
                        return out
                    }
                }, indent: indent)
            }
        }
    }

    /// Each start, end and point marker in `text` with the place written
    /// after it, where it stands and how long it is with its place (UTF-16;
    /// every marker and digit is one unit). One with no place is left out.
    private static func placedMarkers(in text: NSString) -> [(at: Int, length: Int, marker: unichar, place: Int)] {
        var out: [(at: Int, length: Int, marker: unichar, place: Int)] = []
        var at = 0
        while at < text.length {
            let unit = text.character(at: at)
            guard (0xE000...0xE002).contains(unit) else {
                at += 1
                continue
            }
            var next = at + 1
            var place = 0
            while next < text.length, (0xE010...0xE019).contains(text.character(at: next)) {
                place = place * 10 + Int(text.character(at: next) - 0xE010)
                next += 1
            }
            if next > at + 1, next < text.length, text.character(at: next) == 0xE01A {
                out.append((at, next + 1 - at, unit, place))
                at = next + 1
            } else {
                at += 1
            }
        }
        return out
    }

    /// The blocks walked in reading order, nested blocks indented, each code
    /// block and table cutting the prose around it.
    private struct ProseLayout {
        let fontSize: CGFloat
        var footnoteNumbers: [String: String] = [:]
        var pieces: [Piece] = []
        var flow = NSMutableAttributedString()
        var step: CGFloat { fontSize * 1.4 }

        mutating func flush() {
            guard flow.length > 0 else { return }
            pieces.append(.prose(flow))
            flow = NSMutableAttributedString()
        }

        /// `depth` is how many list items hold these blocks, `quote` how
        /// many quotations. `marker` opens the first of them, for an item.
        /// What's in a list sits close; top-level blocks, a list among them,
        /// sit a paragraph apart (`wide`, for the first).
        mutating func add(_ blocks: [LampProseBlock], depth: Int, quote: Int, marker: String? = nil, wide: Bool = true) {
            // An item or footnote with nothing in it keeps its label.
            if blocks.isEmpty, let marker {
                paragraph(NSAttributedString(), depth: depth, quote: quote, marker: marker, close: !wide)
                return
            }
            var marker = marker
            for (index, block) in blocks.enumerated() {
                let close = index == 0 ? !wide : depth > 0
                switch block {
                case .heading(let level, let text):
                    let size = fontSize * (level == 1 ? 1.3 : level == 2 ? 1.2 : 1.1)
                    paragraph(inline(text.text, size: size, bold: true), depth: depth, quote: quote, marker: marker, close: close)
                case .paragraph(let text):
                    paragraph(inline(text.text, size: fontSize), depth: depth, quote: quote, marker: marker, close: close)
                case .quote(let inner):
                    if let marker { paragraph(NSAttributedString(), depth: depth, quote: quote, marker: marker, close: close) }
                    add(inner, depth: depth, quote: quote + 1, wide: marker == nil && !close)
                case .list(let ordered, let start, let items):
                    if let marker { paragraph(NSAttributedString(), depth: depth, quote: quote, marker: marker, close: close) }
                    for (number, item) in items.enumerated() {
                        let shown: String
                        switch item.checked {
                        case .some(true): shown = "☑\u{FE0E}"
                        case .some(false): shown = "☐"
                        case .none: shown = ordered ? "\(start + number)." : "•"
                        }
                        add(item.blocks, depth: depth + 1, quote: quote, marker: shown, wide: number == 0 && !close && marker == nil)
                    }
                case .code(let language, let code):
                    // An item opening with code keeps its number.
                    if let marker { paragraph(NSAttributedString(), depth: depth, quote: quote, marker: marker, close: close) }
                    flush()
                    // A marker the fence's info took is kept with its code.
                    pieces.append(.code(
                        LampWritingReviewMarkdown.asPoints(markers(in: language ?? "")) + code, indent: indent(depth: depth, quote: quote)
                    ))
                case .table(let headers, let rows):
                    if let marker { paragraph(NSAttributedString(), depth: depth, quote: quote, marker: marker, close: close) }
                    flush()
                    let cells = ([headers] + rows).map { $0.map { WritingDocumentText.numberingFootnotes($0.text, footnoteNumbers, size: fontSize * 0.9) } }
                    pieces.append(.table(cells, indent: indent(depth: depth, quote: quote)))
                case .html(let html):
                    paragraph(plain(html, size: fontSize), depth: depth, quote: quote, marker: marker, close: close)
                case .footnote(let label, let inner):
                    add(inner, depth: depth + 1, quote: quote, marker: markers(in: label) + (footnoteNumbers[unmarked(label)] ?? unmarked(label)))
                case .audio(let caption, let path):
                    let line = NSMutableAttributedString()
                    let symbol = NSTextAttachment()
                    symbol.image = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize * 0.85))?
                        .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                    line.append(NSAttributedString(attachment: symbol))
                    line.append(plain(" " + markers(in: path) + (caption.isEmpty ? "Recording" : caption), size: fontSize))
                    paragraph(line, depth: depth, quote: quote, marker: marker, close: close)
                case .picture(let caption, let path):
                    let picture = NSMutableAttributedString(attributedString: NoteMarkdown.picture(
                        nil, caption: markers(in: path) + caption, fontSize: fontSize, serif: true
                    ))
                    paragraph(picture, depth: depth, quote: quote, marker: marker, close: close)
                case .rule:
                    var attributes = NoteMarkdown.baseAttributes(fontSize: fontSize, serif: true)
                    attributes[.foregroundColor] = UIColor.separator
                    paragraph(NSAttributedString(string: "———", attributes: attributes), depth: depth, quote: quote, marker: marker, close: close)
                }
                marker = nil
            }
        }

        /// How far in the quotations and items holding a block set it.
        private func indent(depth: Int, quote: Int) -> CGFloat {
            CGFloat(quote) * fontSize + CGFloat(depth) * step
        }

        private func plain(_ text: String, size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: NoteMarkdown.baseAttributes(fontSize: size, serif: true))
        }

        /// Inline text in the writing's serif, a link kept on its words to be
        /// opened, a picture in it named after its line.
        private func inline(_ text: AttributedString, size: CGFloat, bold: Bool = false) -> NSAttributedString {
            let read = NoteMarkdown.inline(
                parsed: text, attributes: NoteMarkdown.baseAttributes(fontSize: size, bold: bold, serif: true),
                fontSize: size, bold: bold, serif: true, linksTapped: true, footnoteNumbers: footnoteNumbers
            )
            let out = NSMutableAttributedString(attributedString: read.text)
            // A break the writer made is a line within the paragraph.
            out.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", range: NSRange(location: 0, length: out.length))
            for picture in read.pictures {
                out.append(NSAttributedString(string: "\u{2028}", attributes: NoteMarkdown.baseAttributes(fontSize: size, serif: true)))
                out.append(NoteMarkdown.picture(nil, caption: picture.caption, fontSize: fontSize, serif: true))
            }
            return out
        }

        /// One paragraph of the prose, indented for the items and quotations
        /// holding it, a quotation's in the secondary colour.
        private mutating func paragraph(_ text: NSAttributedString, depth: Int, quote: Int, marker: String?, close: Bool) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = fontSize * 0.35
            let indent = CGFloat(quote) * fontSize + CGFloat(depth) * step
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            if flow.length > 0 { style.paragraphSpacingBefore = close ? fontSize * 0.25 : fontSize * 0.7 }
            let line = NSMutableAttributedString()
            if let marker {
                // The item's marker hangs in the step before its words.
                style.firstLineHeadIndent = indent - step
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.defaultTabInterval = step
                line.append(NSAttributedString(string: marker + "\t", attributes: NoteMarkdown.baseAttributes(fontSize: fontSize, serif: true)))
            }
            line.append(text)
            let whole = NSRange(location: 0, length: line.length)
            line.addAttribute(.paragraphStyle, value: style, range: whole)
            if quote > 0 {
                // Its words in the secondary colour; a link keeps its own.
                line.enumerateAttribute(.foregroundColor, in: whole) { color, range, _ in
                    if (color as? UIColor) == UIColor.label {
                        line.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                    }
                }
            }
            if flow.length > 0 {
                // The break ends the paragraph before, and is styled as it.
                let before = flow.attributes(at: flow.length - 1, effectiveRange: nil)
                flow.append(NSAttributedString(string: "\n", attributes: [
                    .paragraphStyle: before[.paragraphStyle] ?? style,
                    .font: before[.font] ?? UIFont.systemFont(ofSize: fontSize),
                ]))
            }
            flow.append(line)
        }
    }

    // MARK: Review marks

    /// The markers, and each passage's place written after its own, as
    /// core writes them (`LampWritingReviewMarkdown`).
    static func isMarker(_ character: Character) -> Bool { LampWritingReviewMarkdown.isMarker(character) }
    static func unmarked(_ text: String) -> String { LampWritingReviewMarkdown.unmarked(text) }
    static func markers(in text: String) -> String { LampWritingReviewMarkdown.markers(in: text) }

    /// The place written after the marker at `index` in `characters`, and
    /// where it ends; nil where none is written.
    private static func place(after index: Int, in characters: [Character]) -> (place: Int, end: Int)? {
        var at = index + 1
        var value = 0
        var digits = 0
        while at < characters.count, let digit = LampWritingReviewMarkdown.placeDigit(characters[at]) {
            value = value * 10 + digit
            digits += 1
            at += 1
        }
        guard digits > 0, at < characters.count, characters[at] == LampWritingReviewMarkdown.placeEnd else { return nil }
        return (value, at)
    }

    /// A mark's tint, as the editor page draws it, and its edge's colour.
    static let markTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.75, blue: 0.27, alpha: 0.24)
            : UIColor(red: 0.91, green: 0.69, blue: 0.17, alpha: 0.26)
    }
    static let markEdge = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.94, green: 0.75, blue: 0.27, alpha: 0.9)
            : UIColor(red: 0.70, green: 0.47, blue: 0.0, alpha: 0.85)
    }
    /// Drawn where words were taken out and nothing put in their place.
    static let pointGlyph = "\u{2038}"

    /// A link's address without review markers in it, raw or percent-encoded
    /// (the private-use run `U+E000`–`U+E01A`, `%EE%80%80`–`%EE%80%9A`).
    static func cleanedLink(_ url: URL) -> URL? {
        let address = url.absoluteString
        let cleaned = unmarked(address)
            .replacing(#/%EE%80%(?:8[0-9A-Fa-f]|9[0-9Aa])/#, with: "")
        return cleaned == address ? url : URL(string: cleaned)
    }

    /// A drawn passage's link to itself, by its place among the passages.
    static func markLink(_ index: Int) -> URL { URL(string: "lampmark:\(index)")! }

    static func markIndex(_ url: URL) -> Int? {
        guard url.scheme == "lampmark", let index = Int(url.absoluteString.dropFirst("lampmark:".count)),
              index >= 0 else { return nil }
        return index
    }

    /// `text` with its review markers drawn and taken out: each passage
    /// tinted and a link to itself, each point a caret in the mark's colour.
    /// `first` is the place of the first passage it opens; `open` one opened
    /// before it, still running. Returns where the next stretch takes up.
    static func drawingMarks(
        _ text: NSAttributedString, first: Int, open: Int?
    ) -> (text: NSAttributedString, next: Int, open: Int?) {
        let source = text.string as NSString
        var index = first
        var current = open
        var start: Int? = open == nil ? nil : 0
        var spans: [(range: NSRange, index: Int)] = []
        var points: [(at: Int, index: Int)] = []
        var markers: [Int] = []
        var position = 0
        while position < source.length {
            let unit = source.character(at: position)
            // Where the marker stands once the markers before it are out.
            let at = position - markers.count
            switch unit {
            case 0xE000, 0xE002:
                markers.append(position)
                // Its place, where written after it, read and taken out too.
                var found = index
                var next = position + 1
                var value = 0
                while next < source.length, (0xE010...0xE019).contains(source.character(at: next)) {
                    value = value * 10 + Int(source.character(at: next) - 0xE010)
                    next += 1
                }
                if next > position + 1, next < source.length, source.character(at: next) == 0xE01A {
                    markers.append(contentsOf: (position + 1)...next)
                    found = value
                    position = next
                }
                index = found + 1
                if unit == 0xE000 {
                    start = at
                    current = found
                } else {
                    points.append((at, found))
                }
            case 0xE001:
                markers.append(position)
                if let start, let current { spans.append((NSRange(location: start, length: at - start), current)) }
                start = nil
                current = nil
            case 0xE010...0xE01A:
                // A place whose marker Markdown dropped: taken out too.
                markers.append(position)
            default:
                break
            }
            position += 1
        }
        if let start, let current {
            spans.append((NSRange(location: start, length: source.length - markers.count - start), current))
        }
        let out = NSMutableAttributedString(attributedString: text)
        for position in markers.reversed() { out.deleteCharacters(in: NSRange(location: position, length: 1)) }
        // A link Markdown made of marked text (a bare address) goes where
        // its text says, not to an address with the markers in.
        out.enumerateAttribute(.link, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let url = value as? URL, let cleaned = cleanedLink(url), cleaned != url else { return }
            out.addAttribute(.link, value: cleaned, range: range)
        }
        for span in spans {
            // A passage Markdown left nothing of (its asterisks, say): a point.
            guard span.range.length > 0 else {
                points.append((span.range.location, span.index))
                continue
            }
            out.addAttributes([.backgroundColor: markTint, .link: markLink(span.index)], range: span.range)
        }
        points.sort { $0.at < $1.at }
        for point in points.reversed() {
            var attributes: [NSAttributedString.Key: Any] = out.length == 0 ? [:]
                : out.attributes(at: min(point.at, out.length - 1), effectiveRange: nil)
            attributes[.backgroundColor] = nil
            attributes[.foregroundColor] = markEdge
            attributes[.link] = markLink(point.index)
            out.insert(NSAttributedString(string: pointGlyph, attributes: attributes), at: point.at)
        }
        return (out, index, start == nil ? nil : current)
    }

    /// The same for text SwiftUI draws: a table's cell, a code block.
    static func drawingMarks(
        _ text: AttributedString, first: Int, open: Int?
    ) -> (text: AttributedString, next: Int, open: Int?) {
        var out = AttributedString()
        var index = first
        var current = open
        // Whether anything was drawn of the passage open, so one Markdown
        // left nothing of is drawn as a point.
        var drawnOfCurrent = open != nil
        func caret(_ place: Int, _ attributes: AttributeContainer) -> AttributedString {
            var caret = AttributedString(pointGlyph)
            caret.mergeAttributes(attributes)
            caret.backgroundColor = nil
            caret.foregroundColor = Color(uiColor: markEdge)
            caret.link = markLink(place)
            return caret
        }
        for run in text.runs {
            var piece = ""
            func flush() {
                guard !piece.isEmpty else { return }
                var part = AttributedString(piece)
                part.mergeAttributes(run.attributes)
                if let link = part.link, let cleaned = cleanedLink(link) { part.link = cleaned }
                if let current {
                    part.backgroundColor = Color(uiColor: markTint)
                    part.link = markLink(current)
                    drawnOfCurrent = true
                }
                out += part
                piece = ""
            }
            let characters = Array(text[run.range].characters)
            var at = 0
            while at < characters.count {
                let character = characters[at]
                switch character {
                case LampWritingReview.markStart, LampWritingReview.markPoint:
                    flush()
                    let written = place(after: at, in: characters)
                    let found = written?.place ?? index
                    at = written?.end ?? at
                    index = found + 1
                    if character == LampWritingReview.markStart {
                        current = found
                        drawnOfCurrent = false
                    } else {
                        out += caret(found, run.attributes)
                    }
                case LampWritingReview.markEnd:
                    flush()
                    if let current, !drawnOfCurrent { out += caret(current, run.attributes) }
                    current = nil
                default:
                    if !isMarker(character) { piece.append(character) }
                }
                at += 1
            }
            flush()
        }
        return (out, index, current)
    }

    /// A cell's footnote references as the prose shows them: each its
    /// number, raised and small.
    static func numberingFootnotes(_ cell: AttributedString, _ numbers: [String: String], size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for run in cell.runs {
            var piece = AttributedString(cell[run.range])
            if let label = run[LampFootnoteReferenceAttribute.self] {
                let written = String(piece.characters)
                let shown = written.replacing(#/\[\^([^\]]*)\]/#) { match in
                    let label = String(match.output.1)
                    return numbers[unmarked(label)].map { markers(in: label) + $0 } ?? label
                }
                var raised = AttributedString(shown == written ? (numbers[label] ?? label) : shown)
                raised.mergeAttributes(run.attributes)
                raised.baselineOffset = size * 0.35
                raised.font = Font(LampTheme.serif(size: size * 0.7, weight: .regular))
                piece = raised
            }
            out += piece
        }
        return out
    }

    /// Drawn prose with each web or email address written out in it made
    /// a link, as a reader expects (core's `LampBareLinks`). Only for
    /// drawing: the editor reads a bare address as words, and so does
    /// everything that decides what the file says. What the reader drew
    /// that isn't plain words (a link the writer made, a review mark or
    /// caret, a footnote's number, a picture, code) is spoken for, and an
    /// address against any of it is left as words.
    static func linkingAddresses(_ text: NSAttributedString) -> NSAttributedString {
        var taken: [NSRange] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let font = attributes[.font] as? UIFont
            if attributes[.link] != nil || attributes[.attachment] != nil || attributes[.pictureCaption] != nil
                || (attributes[.baselineOffset] as? CGFloat ?? 0) != 0
                || font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true {
                taken.append(range)
            }
        }
        let parts = LampBareLinks.links(in: text.string, excluding: taken)
        guard !parts.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for part in parts {
            out.addAttributes([.link: part.url, .foregroundColor: UIColor.lampLink], range: part.range)
        }
        return out
    }

    /// The same for a table's cell.
    static func linkingAddresses(_ cell: AttributedString) -> AttributedString {
        var taken: [NSRange] = []
        var at = 0
        for run in cell.runs {
            let length = (String(cell[run.range].characters) as NSString).length
            if run.link != nil || run.imageURL != nil || run.inlinePresentationIntent?.contains(.code) == true
                || (run.baselineOffset ?? 0) != 0 {
                taken.append(NSRange(location: at, length: length))
            }
            at += length
        }
        let parts = LampBareLinks.links(in: String(cell.characters), excluding: taken)
        guard !parts.isEmpty else { return cell }
        var out = cell
        for part in parts {
            guard let range = Range(part.range, in: out) else { continue }
            out[range].link = part.url
            out[range].foregroundColor = Color(uiColor: .lampLink)
        }
        return out
    }

    /// A drawn cell without the spaces at its edges, which the parser keeps
    /// beside a review marker and trims where there's none.
    static func trimmed(_ cell: AttributedString) -> AttributedString {
        var cell = cell
        while let first = cell.characters.first, first == " " || first == "\t" {
            cell.removeSubrange(cell.startIndex..<cell.characters.index(after: cell.startIndex))
        }
        while let last = cell.characters.last, last == " " || last == "\t" {
            cell.removeSubrange(cell.characters.index(before: cell.endIndex)..<cell.endIndex)
        }
        return cell
    }

    /// Each column as wide as its widest cell, up to `widest`, past which
    /// its cells wrap: measured from the words as drawn, the review markers
    /// out of them.
    static func columnWidths(_ rows: [[String]], size: CGFloat, widest: CGFloat) -> [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        return (0..<columns).map { column in
            let measured = rows.enumerated().map { index, row -> CGFloat in
                guard column < row.count else { return 0 }
                let font = LampTheme.serif(size: size, weight: index == 0 ? .semibold : .regular)
                let text = unmarked(row[column]).trimmingCharacters(in: .whitespaces) as NSString
                return ceil(text.size(withAttributes: [.font: font]).width) + 2
            }
            return min(widest, max(size, measured.max() ?? 0))
        }
    }

    /// A table cell's inline Markdown, or the cell as written where it won't read.
    static func cell(_ text: String) -> AttributedString {
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
    }

    /// Whether `range` of `text` stands in code, as Markdown reads it: a
    /// fenced or indented block, or an inline code span.
    static func inCode(_ range: NSRange, of text: String) -> Bool {
        LampMarkdownModel(parsing: text).codeRanges.contains {
            // A point (a deletion) is in code only strictly inside it: one
            // at either edge stands just outside, beside the span.
            range.length == 0
                ? $0.location < range.location && range.location < NSMaxRange($0)
                : range.location >= $0.location && NSMaxRange(range) <= NSMaxRange($0)
        }
    }
}

/// A file's drawn text, selectable to copy from, as tall as it runs. A tap
/// on a review mark is `onMark`'s, with the passage's place; any other link
/// opens as links do.
private struct WritingFileText: UIViewRepresentable {
    let text: NSAttributedString
    var onMark: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        AIFeatures.shared.govern(view)
        // Each link drawn as its text is: a mark in its tint, a link in the
        // link colour the Markdown gave it.
        view.linkTextAttributes = [:]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onMark = onMark
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var size: CGSize?
        var onMark: ((Int) -> Void)?

        func textView(
            _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content, let index = WritingDocumentText.markIndex(url) else {
                return defaultAction
            }
            return UIAction { [weak self] _ in self?.onMark?(index) }
        }

        func textView(
            _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            // A mark is a passage to tap, not a link to preview or copy.
            guard case .link(let url) = textItem.content, WritingDocumentText.markIndex(url) != nil else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            return nil
        }
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
