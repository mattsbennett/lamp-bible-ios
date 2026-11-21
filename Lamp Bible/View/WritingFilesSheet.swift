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
                        ForEach(Array(drawnSegments(of: document).enumerated()), id: \.offset) { _, drawn in
                            block(drawn.segment, first: drawn.first, open: drawn.open)
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
        return WritingDocumentText.numbered(marks.marked)
    }

    /// Each block to draw, with the place of the first passage it opens and
    /// a passage still open from the block before.
    private func drawnSegments(of document: WritingDocument) -> [(segment: WritingDocumentText.Segment, first: Int, open: Int?)] {
        var first = 0
        var open: Int?
        return WritingDocumentText.segments(shownText(of: document)).map { segment in
            let text: String
            switch segment {
            case .markdown(let prose): text = prose
            case .code(let code): text = code
            case .table(let rows): text = rows.flatMap { $0 }.joined()
            }
            let drawn = (segment, first, open)
            (first, open) = WritingDocumentText.passing(text, first: first, open: open)
            return drawn
        }
    }

    /// Prose wraps; a code block and a table keep their lines and columns,
    /// scrolled sideways where they're wider than the sheet.
    @ViewBuilder
    private func block(_ segment: WritingDocumentText.Segment, first: Int, open: Int?) -> some View {
        switch segment {
        case .markdown(let text):
            let prose = WritingDocumentText.prose(text, fontSize: fontSize)
            WritingFileText(text: WritingDocumentText.drawingMarks(prose, first: first, open: open).text, onMark: choose)
                .padding(.horizontal, 20)
        case .code(let text):
            ScrollView(.horizontal) {
                Text(WritingDocumentText.drawingMarks(AttributedString(text), first: first, open: open).text)
                    .font(.system(size: fontSize * 0.8, design: .monospaced))
                    .fixedSize()
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
            }
            .environment(\.openURL, markAction)
            // A mark is drawn as its text is, not in the link colour.
            .tint(.primary)
        case .table(let rows):
            let size = fontSize * 0.9
            let widths = WritingDocumentText.columnWidths(rows, size: size, widest: fontSize * 14)
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
            }
            .environment(\.openURL, markAction)
            .tint(.primary)
        }
    }

    /// A table's cells read as Markdown, their marks drawn, in reading order.
    private func drawnCells(_ rows: [[String]], first: Int, open: Int?) -> [[AttributedString]] {
        var first = first
        var open = open
        return rows.map { row in
            row.map { cell in
                let drawn = WritingDocumentText.drawingMarks(WritingDocumentText.cell(cell), first: first, open: open)
                first = drawn.next
                open = drawn.open
                return drawn.text
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

    /// Markdown prose, its links kept to be opened. Review markers in it
    /// stay in what's drawn, for `drawingMarks` to draw; one before a
    /// line's block syntax is moved after it first, so the line still reads
    /// as its heading, list item or quote.
    static func prose(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n").map { clearingBlockSyntax(movingMarksOutOfLinks($0)) }
        return NoteMarkdown.render(lines.joined(separator: "\n"), fontSize: fontSize, serif: true, linksTapped: true).text
    }

    // MARK: Review marks

    /// The markers core puts at a mark's edges (`markedMarkdown(in:)`), as
    /// the editor page reads them: a passage's start and end, and a point
    /// where words were taken out.
    static func isMarker(_ character: Character) -> Bool {
        character == LampWritingReview.markStart || character == LampWritingReview.markEnd
            || character == LampWritingReview.markPoint || placeDigit(character) != nil || character == placeEnd
    }

    /// Each passage's place is written after its start or point marker, in
    /// private-use digits, so it survives Markdown dropping a marker it
    /// reads as part of something else — a link's address — and every
    /// passage after still names its own change.
    static let placeEnd: Character = "\u{E01A}"

    static func placeDigit(_ character: Character) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0xE010...0xE019).contains(scalar.value) else { return nil }
        return Int(scalar.value - 0xE010)
    }

    /// `marked` with each passage's place after its marker, in order.
    static func numbered(_ marked: String) -> String {
        var out = ""
        var next = 0
        for character in marked {
            out.append(character)
            guard character == LampWritingReview.markStart || character == LampWritingReview.markPoint else { continue }
            for digit in String(next) {
                out.unicodeScalars.append(Unicode.Scalar(0xE010 + UInt32(digit.wholeNumberValue ?? 0))!)
            }
            out.append(placeEnd)
            next += 1
        }
        return out
    }

    /// The place written after the marker at `index` in `characters`, and
    /// where it ends; nil where none is written.
    private static func place(after index: Int, in characters: [Character]) -> (place: Int, end: Int)? {
        var at = index + 1
        var value = 0
        var digits = 0
        while at < characters.count, let digit = placeDigit(characters[at]) {
            value = value * 10 + digit
            digits += 1
            at += 1
        }
        guard digits > 0, at < characters.count, characters[at] == placeEnd else { return nil }
        return (value, at)
    }

    static func unmarked(_ text: String) -> String { text.filter { !isMarker($0) } }
    static func markers(in text: String) -> String { text.filter(isMarker) }

    /// Where a stretch of marked text leaves the count of passages, and a
    /// passage still open at its end, from where it took them up.
    static func passing(_ text: String, first: Int, open: Int?) -> (next: Int, open: Int?) {
        var next = first
        var open = open
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch character {
            case LampWritingReview.markStart, LampWritingReview.markPoint:
                let place = Self.place(after: index, in: characters)?.place ?? next
                if character == LampWritingReview.markStart { open = place }
                next = place + 1
            case LampWritingReview.markEnd: open = nil
            default: break
            }
        }
        return (next, open)
    }

    /// Review markers inside a link's address moved out before its words,
    /// each passage as a point: in the address they'd be taken into where
    /// the link goes, and the change they mark would have nothing to tap.
    /// A point, not a passage around the words, which may be marked
    /// themselves.
    static func movingMarksOutOfLinks(_ line: String) -> String {
        guard line.contains(where: isMarker) else { return line }
        let escapesKept = keepingInlineSyntax(line)
        // An address may hold parentheses, balanced two deep; a bracket a
        // backslash escapes opens no link.
        return escapesKept.replacing(#/(\\?)(!?)\[([^\]]*)\]\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)/#) { match in
            let address = String(match.output.4)
            guard match.output.1.isEmpty, address.contains(where: isMarker) else { return String(match.output.0) }
            let moved = sortingOut(markers(in: address))
            // Before an image's `!` too, so it's still an image.
            return "\(match.output.1)\(moved.before)\(match.output.2)[\(match.output.3)\(moved.ending)](\(unmarked(address)))\(moved.after)"
        }
        // An autolink, in angle brackets or bare: its markers before it, so
        // it's still read as a link and goes where it says.
        .replacing(#/<([\x{E000}-\x{E01A}]*[A-Za-z][A-Za-z0-9+.\-\x{E000}-\x{E01A}]*:[^\s<>]*)>/#) { match in
            let link = String(match.output.1)
            guard link.contains(where: isMarker) else { return String(match.output.0) }
            let moved = sortingOut(markers(in: link))
            return moved.before + moved.ending + "<\(unmarked(link))>" + moved.after
        }
        .replacing(#/(^|[^\w(<\x{E000}-\x{E01A}])([A-Za-z][A-Za-z0-9+.\-\x{E000}-\x{E01A}]*:\/\/[^\s<>()]+)/#) { match in
            let link = String(match.output.2)
            guard link.contains(where: isMarker) else { return String(match.output.0) }
            let moved = sortingOut(markers(in: link))
            return match.output.1 + moved.before + moved.ending + unmarked(link) + moved.after
        }
    }

    /// Markers taken out of text that isn't drawn as written (a link's
    /// address), sorted by where they go: passages begun and ended there as
    /// points before it; an end of one begun before it, at its end; a start
    /// of one running on past it, after it.
    static func sortingOut(_ markers: String) -> (before: String, ending: String, after: String) {
        var before = ""
        var ending = ""
        var after = ""
        var group: String?
        for character in asPoints(markers) {
            if character == LampWritingReview.markEnd {
                ending.append(character)
            } else if character == LampWritingReview.markStart {
                group = String(character)
            } else if character == LampWritingReview.markPoint {
                group = nil
                before.append(character)
            } else if group != nil {
                group?.append(character)
                if character == placeEnd, let started = group {
                    after += started
                    group = nil
                }
            } else {
                before.append(character)
            }
        }
        if let group { after += group }
        return (before, ending, after)
    }

    /// Review markers standing between a backslash and the character it
    /// escapes moved after that character, so the escape still reads.
    static func keepingEscapes(_ line: String) -> String {
        line.replacing(#/\\([\x{E000}-\x{E01A}]+)([!-\/:-@\[-`{-~])/#) { match in
            "\\\(match.output.2)\(match.output.1)"
        }
    }

    /// The line's inline syntax kept as it reads without review markers:
    /// escapes whole, and markers stepped inside an emphasis's `*` or `_`,
    /// whose meaning hangs on what stands beside them, which a marker (read
    /// as a letter) would change. Repeated until nothing moves, so a run of
    /// delimiters a marker split comes back together.
    static func keepingInlineSyntax(_ line: String) -> String {
        guard line.contains(where: isMarker) else { return line }
        var kept = keepingEscapes(line)
        for _ in 0..<8 {
            let before = kept
            // Syntax a marker split put back together: a run of `*`, `_` or
            // backticks, a link's `](`, an image's `![`. The markers go on
            // after the run, or before the bracket.
            kept = kept.replacing(#/([*_`])([\x{E000}-\x{E01A}]+)(\1)/#) { "\($0.output.1)\($0.output.3)\($0.output.2)" }
            kept = kept.replacing(#/\]([\x{E000}-\x{E01A}]+)\(/#) { "\($0.output.1)](" }
            kept = kept.replacing(#/!([\x{E000}-\x{E01A}]+)\[/#) { "\($0.output.1)![" }
            // A whole run of delimiters only, never part of one.
            kept = kept.replacing(#/([^\\_*\x{E000}-\x{E01A}]|^)([\x{E000}-\x{E01A}]+)([_*]+)(?=\S)/#) {
                "\($0.output.1)\($0.output.3)\($0.output.2)"
            }
            // Not an escaped one, which is no delimiter.
            kept = kept.replacing(#/([^\s\\_*\x{E000}-\x{E01A}])([_*]+)([\x{E000}-\x{E01A}]+)/#) {
                "\($0.output.1)\($0.output.3)\($0.output.2)"
            }
            if kept == before { break }
        }
        return kept
    }

    /// Markers from text that isn't drawn (a link's address, a fence's line,
    /// a table's alignment row), each passage begun and ended among them
    /// made a point, so it has a caret to tap; a start or end belonging to
    /// a passage outside them kept as it is.
    static func asPoints(_ markers: String) -> String {
        let characters = Array(markers)
        // Which starts are ended among these.
        var open: [Int] = []
        var ended: Set<Int> = []
        var closing: Set<Int> = []
        for (index, character) in characters.enumerated() {
            if character == LampWritingReview.markStart {
                open.append(index)
            } else if character == LampWritingReview.markEnd, let start = open.popLast() {
                ended.insert(start)
                closing.insert(index)
            }
        }
        var out = ""
        for (index, character) in characters.enumerated() {
            if closing.contains(index) { continue }
            out.append(ended.contains(index) ? LampWritingReview.markPoint : character)
        }
        return out
    }

    /// A line with any review marker standing before its block's own syntax
    /// (a heading's `#`, a list's marker, a quote's `>`) moved after it.
    static func clearingBlockSyntax(_ line: String) -> String {
        let bare = unmarked(line)
        guard let match = bare.prefixMatch(of: #/\s*(?:#{1,6}\s+|[-*+]\s+|\d{1,9}[.)]\s+|>\s?)/#) else { return line }
        let syntax = bare[match.range].count
        var head = ""
        var moved = ""
        var rest = Substring(line)
        while head.count < syntax, let character = rest.first {
            rest = rest.dropFirst()
            if isMarker(character) { moved.append(character) } else { head.append(character) }
        }
        // A change to the syntax alone, begun and ended in it, a point.
        return head + asPoints(moved) + rest
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

    /// Each column as wide as its widest cell, up to `widest`, past which
    /// its cells wrap.
    static func columnWidths(_ rows: [[String]], size: CGFloat, widest: CGFloat) -> [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        return (0..<columns).map { column in
            let measured = rows.enumerated().map { index, row -> CGFloat in
                guard column < row.count else { return 0 }
                let font = LampTheme.serif(size: size, weight: index == 0 ? .semibold : .regular)
                // As drawn: without the review markers in it.
                let text = String(cell(unmarked(row[column])).characters) as NSString
                return ceil(text.size(withAttributes: [.font: font]).width) + 2
            }
            return min(widest, max(size, measured.max() ?? 0))
        }
    }

    /// A table cell's inline Markdown, or the cell as written where it won't read.
    static func cell(_ text: String) -> AttributedString {
        let text = movingMarksOutOfLinks(text)
        return (try? AttributedString(
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
        let trimmed = unmarked(line).trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && trimmed.contains("-") && trimmed.allSatisfy { "|:- ".contains($0) }
    }

    /// A table row's cells, its outer pipes dropped and an escaped pipe kept
    /// as a pipe in its cell.
    static func cells(_ row: String) -> [String] {
        let row = keepingEscapes(row.trimmingCharacters(in: .whitespaces))
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
        // The edges outside the outer pipes hold no cell: a review marker
        // there goes into the cell beside it.
        if !row.hasSuffix("|"), unmarked(row).hasSuffix("|"), cells.count > 1,
           unmarked(cells[cells.count - 1]).trimmingCharacters(in: .whitespaces).isEmpty {
            let trailing = markers(in: cells.removeLast())
            cells[cells.count - 1] += trailing
        }
        if unmarked(row).hasPrefix("|"), !cells.isEmpty {
            let leading = markers(in: cells.removeFirst())
            if !cells.isEmpty { cells[0] = leading + cells[0] }
        }
        // A passage that was only a pipe between two cells (a column split)
        // is a point in the first.
        if cells.count > 1 {
            for index in cells.indices.dropLast() {
                guard let start = cells[index].firstMatch(of: #/\x{E000}([\x{E010}-\x{E019}]*\x{E01A}?)\s*$/#),
                      cells[index + 1].firstMatch(of: #/^\s*\x{E001}/#) != nil else { continue }
                cells[index].replaceSubrange(start.range, with: "\u{E002}\(start.output.1)")
                cells[index + 1] = cells[index + 1].replacing(#/^\s*\x{E001}/#, with: "", maxReplacements: 1)
            }
        }
        return cells.map(trimmingAroundMarkers)
    }

    /// A cell's spaces trimmed from its words, though review markers stand
    /// outside them: the markers kept, at the ends they stood at.
    static func trimmingAroundMarkers(_ cell: String) -> String {
        let edge: (Character) -> Bool = { $0 == " " || $0 == "\t" || isMarker($0) }
        let head = cell.prefix(while: edge)
        let rest = cell.dropFirst(head.count)
        let tail = rest.reversed().prefix(while: edge)
        let words = rest.dropLast(tail.count)
        return markers(in: String(head)) + words + markers(in: String(tail.reversed()))
    }

    /// Whether `range` of `text` stands in a fenced code block.
    static func inCode(_ range: NSRange, of text: String) -> Bool {
        var offset = 0
        var fence: (mark: Character, length: Int, start: Int)?
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                let run = trimmed.prefix(while: { $0 == open.mark }).count
                if run >= open.length && run == trimmed.count {
                    if range.location >= open.start, NSMaxRange(range) <= offset + length { return true }
                    fence = nil
                }
            } else if let mark = trimmed.first, mark == "`" || mark == "~" {
                let run = trimmed.prefix(while: { $0 == mark }).count
                if run >= 3, mark == "~" || !trimmed.dropFirst(run).contains("`") { fence = (mark, run, offset) }
            }
            offset += length + 1
        }
        if let open = fence, range.location >= open.start { return true }
        return false
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
        // Review markers on a line that isn't drawn (a fence's, a table's
        // alignment row), carried to the next that is, so none is lost.
        var pending = ""
        func taking(_ line: String) -> String {
            defer { pending = "" }
            return pending + line
        }
        for (index, line) in lines.enumerated() {
            if skip {
                skip = false
                continue
            }
            // Read without its review markers, which are drawn, not read.
            let trimmed = unmarked(line).trimmingCharacters(in: .whitespaces)
            let row = line.trimmingCharacters(in: .whitespaces)
            if inTable {
                // Its rows, their outer pipes optional, up to a line without one.
                if trimmed.contains("|") {
                    table.append(cells(taking(row)))
                    continue
                }
                inTable = false
                endTable()
            }
            if let open = fence {
                let run = trimmed.prefix(while: { $0 == open.mark }).count
                if run >= open.length && run == trimmed.count {
                    fence = nil
                    pending += asPoints(markers(in: line))
                    segments.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(taking(line))
                }
                continue
            }
            if let mark = trimmed.first, mark == "`" || mark == "~" {
                let run = trimmed.prefix(while: { $0 == mark }).count
                // Backticks after a backtick fence's own make a code span.
                if run >= 3, mark == "~" || !trimmed.dropFirst(run).contains("`") {
                    endProse()
                    pending += asPoints(markers(in: line))
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
                table = [cells(taking(row))]
                pending += asPoints(markers(in: lines[index + 1]))
                inTable = true
                skip = true
                continue
            }
            prose.append(taking(line))
        }
        endProse()
        endTable()
        if let code { segments.append(.code(code.joined(separator: "\n"))) }
        // Markers left over at the very end go on the last that's drawn.
        if !pending.isEmpty {
            switch segments.popLast() {
            case .markdown(let text): segments.append(.markdown(text + pending))
            case .code(let text): segments.append(.code(text + pending))
            case .table(var rows):
                if rows.isEmpty || rows[rows.count - 1].isEmpty { rows.append([pending]) } else {
                    rows[rows.count - 1][rows[rows.count - 1].count - 1] += pending
                }
                segments.append(.table(rows))
            case nil: segments.append(.markdown(pending))
            }
        }
        return segments
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
