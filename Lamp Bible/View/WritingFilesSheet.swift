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

    /// A restore the page made, written over the file as it was stored
    /// (`opened`) and recorded with it, under the lock a pass takes a
    /// download in under, the file's other marks carried onto it as a save
    /// carries them. False where the file changed meanwhile, or the record
    /// couldn't be written, in which case the file is put back.
    @MainActor
    static func saveRestored(
        _ restored: String, writingID: String, name: String, opened: Data,
        plan: LampWritingReview.RestorePlan, base: String, known: [String]
    ) async -> Bool {
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            let reviews = LibrarySyncPass.reviewStore
            return (try? LibrarySyncPass.documentChanges.withLock { () -> Bool in
                guard try LibrarySyncPass.documentStore.write(
                    Data(restored.utf8), writingID: writingID, name: name, replacing: opened
                ) else { return false }
                do {
                    _ = try reviews.update(writingID: writingID, document: name) {
                        $0.restoringWording(plan, from: base, to: restored, carryingFrom: known)
                    }
                } catch {
                    // Not recorded: the file put back as it was, so what's
                    // kept and what's recorded agree.
                    _ = try? LibrarySyncPass.documentStore.write(
                        opened, writingID: writingID, name: name, replacing: Data(restored.utf8)
                    )
                    return false
                }
                _ = try? LampWritingDocumentReview.carry(
                    restored, ofDocument: name, writingID: writingID, from: known + [base], in: reviews
                )
                return true
            }) ?? false
        }.value
        if saved {
            WritingReviewTexts.shared.remember(restored, for: writingID, document: name)
            NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil)
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
                if WritingDocumentText.isMarkdown(name) {
                    WritingDocumentPage(
                        writingID: writingID,
                        name: name,
                        document: documents.first { $0.name == name },
                        canEdit: canEdit,
                        showsMarks: showsMarks,
                        fontSize: fontSize
                    )
                } else {
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
    /// among them: one for each range, as the reader lists and clears each
    /// on its own.
    let count: Int

    /// Nil where the document has none to draw. Off the main actor: the
    /// whole document is compared.
    nonisolated static func load(writingID: String, document: String, text: String, known: [String]) -> Self? {
        guard let review = try? LibrarySyncPass.reviewStore.review(writingID: writingID, document: document),
              !review.isEmpty else { return nil }
        let live = review.carryingToText(text, from: known)
        let drawing = live.drawing(in: text)
        guard let marked = drawing.markedMarkdown else { return nil }
        let changes = WritingReviewSession.changes(of: live, drawing)
        return Self(text: text, marked: marked, ranges: drawing.ranges, changes: changes, count: drawing.ranges.count)
    }
}

/// One of a writing's Markdown files in the writing's own editor: read and
/// written there as the writing is, so it reads exactly as the editor reads
/// it, and its review marks are the editor's own, cleared a paragraph at a
/// time with its ✓, put back with its preview, counted and stepped through
/// from the bar. Opened to read, where links open, and edited from Edit.
///
/// Only what the writer changed is saved. The editor writes Markdown back in
/// its own spelling, so what it makes of the file untouched (`baseline`) is
/// taken as the file, and a text that's neither that nor what's stored is an
/// edit. A file opened and left is never rewritten, and what it holds that
/// the editor can't show (an HTML comment) stays until it's edited visually;
/// Edit Markdown Source edits it as written. Each save is over the copy it
/// was built on: one that changed elsewhere meanwhile is the writer's to
/// keep beside it or let go. Plain text keeps its own reader
/// (`WritingFileView`).
struct WritingDocumentPage: View {
    let writingID: String
    let name: String
    /// The file as it's stored now, nil once it's deleted.
    let document: WritingDocument?
    let canEdit: Bool
    /// Whether marks are drawn (`AIFeatures.marksReviews` and the writing
    /// the writer's to change).
    let showsMarks: Bool
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var review = WritingReviewSession()
    @State private var text = ""
    /// The stored copy the page's text is built on, which a save replaces.
    @State private var opened: Data?
    /// The editor's own Markdown for the copy it holds, untouched.
    @State private var baseline: String?
    @State private var editing = false
    @State private var coordinator: TipTapEditorCoordinator?
    @State private var saveTask: Task<Void, Never>?
    @State private var saving = false
    /// A restore under way: the copy it's made from, which its write
    /// replaces, and nothing else taken in until it's written.
    @State private var restoreBase: Data?
    @State private var changedMeanwhile = false
    @State private var deletedWhileEdited = false
    @State private var problem: String?
    @State private var confirmingDelete = false
    /// The file's Markdown opened as written, for what the visual editor
    /// doesn't keep (an HTML comment, say), which a visual edit would drop.
    @State private var editingSource: WritingDocumentEditing?
    @State private var leaving = false
    /// The copy shown when Delete was asked for: the one the writer chose to
    /// delete, a newer one from elsewhere being kept.
    @State private var deleteSeen: Data?
    /// A copy from elsewhere being taken in, and the newest to follow it:
    /// one at a time, so each is checked against the page as the last left it.
    @State private var takingIncoming = false
    @State private var nextIncoming: Data?
    /// A restore written but not recorded (its record couldn't be saved):
    /// recorded with the first save that writes its text.
    @State private var unrecordedRestore: (plan: LampWritingReview.RestorePlan, base: String, restored: String, known: [String])?

    init(writingID: String, name: String, document: WritingDocument?, canEdit: Bool, showsMarks: Bool, fontSize: CGFloat) {
        self.writingID = writingID
        self.name = name
        self.document = document
        self.canEdit = canEdit
        self.showsMarks = showsMarks
        self.fontSize = fontSize
        // Taken from the file as it's opened: set here, not on appearing,
        // since the page isn't there to appear until they are.
        _text = State(initialValue: document?.text ?? "")
        _opened = State(initialValue: document?.data)
    }

    /// The text as it was last stored.
    private var storedText: String? { opened.map { String(decoding: $0, as: UTF8.self) } }

    /// Marks are for editing: reviewing one clears it or puts wording back,
    /// so reading shows the file as it reads.
    private var marksShown: Bool { showsMarks && canEdit && editing }

    /// Whether `candidate` is the writer's edit: neither the file as stored
    /// nor the editor's spelling of it.
    private func isEdit(_ candidate: String) -> Bool {
        candidate != storedText && candidate != baseline
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if opened != nil {
                TipTapEditorView<EmptyView>(
                    markdownContent: $text,
                    fontSize: fontSize,
                    editMode: .visual,
                    viewMode: canEdit && editing ? .edit : .read,
                    header: nil,
                    showsHeader: false,
                    onCoordinatorReady: connect
                )
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        // Left only once what was typed is saved: the page reports typing a
        // moment late, and a save refused once it had gone would have
        // nowhere to ask what to keep.
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { Task { await leave() } } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Files")
                .disabled(leaving)
            }
            if canEdit, document != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Done" : "Edit") {
                        if editing { Task { await finishEditing() } } else { editing = true }
                    }
                    // Not before the page is there to take the mode.
                    .disabled(coordinator == nil || leaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Edit Markdown Source", systemImage: "chevron.left.forwardslash.chevron.right") {
                            Task { await editSource() }
                        }
                        Button("Delete File", systemImage: "trash", role: .destructive) {
                            deleteSeen = opened
                            confirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
            if marksShown, review.count > 0 {
                ToolbarItem(placement: .bottomBar) { reviewMenu }
            }
        }
        .sheet(item: $editingSource) { editing in
            WritingDocumentEditor(editing: editing) {
                NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
            }
        }
        .onChange(of: text) { _, now in
            review.textChanged(now)
            scheduleSave()
        }
        // Changed elsewhere and brought in by sync: taken in where nothing
        // typed here, reported or not, waits to be saved; otherwise the
        // writer chooses.
        .onChange(of: document?.data) { _, stored in
            guard let stored, stored != opened else { return }
            Task { await incoming(stored) }
        }
        .onChange(of: document == nil) { _, gone in
            guard gone else { return }
            Task {
                if canEdit, await hasEdits() { deletedWhileEdited = true } else { dismiss() }
            }
        }
        // Lamp left with typing not yet saved: saved now, with time asked
        // for to finish.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, canEdit else { return }
            let background = UIApplication.shared.beginBackgroundTask(withName: "Save file")
            Task {
                await saveEverything()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
        }
        .task(id: marksShown) {
            await review.follow(writingID: writingID, document: name, text: text, isShown: marksShown)
        }
        .onAppear { SwipeBack.holds += 1 }
        .onDisappear { SwipeBack.holds = max(0, SwipeBack.holds - 1) }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete File", role: .destructive) { Task { await delete() } }
        } message: {
            Text("It's deleted on your other devices too.")
        }
        .alert("Changed on Another Device", isPresented: $changedMeanwhile) {
            Button("Keep Mine as a Copy") { Task { await keepAsCopy() } }
            Button("Use the Other Version", role: .destructive) { Task { await takeStored() } }
        } message: {
            Text("This file changed elsewhere while you were editing it. Your text can be kept beside it as a copy.")
        }
        .alert("Deleted on Another Device", isPresented: $deletedWhileEdited) {
            Button("Keep Mine as a Copy") { Task { await keepAsCopy() } }
            Button("Discard Mine", role: .destructive) { dismiss() }
        } message: {
            Text("This file was deleted elsewhere while you were editing it. Your text can be kept as a copy.")
        }
        .alert(
            "Can’t Save",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .alert(
            "Can’t Restore Original Wording",
            isPresented: Binding(get: { review.restoreRefusal != nil }, set: { if !$0 { review.restoreRefusal = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(review.restoreRefusal ?? "")
        }
        .alert("Restore Not Saved", isPresented: $review.restoreUnsaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The original wording is back on the page, but the file couldn’t be saved with it. Undo it, or edit and it will be saved.")
        }
    }

    /// How many changes are still to read, and stepping through or clearing
    /// them; a paragraph's own ✓ clears that paragraph.
    private var reviewMenu: some View {
        Menu {
            if review.unshownMarks > 0 {
                Section {
                    Text("Some changes can’t be shown here. They’re still counted, and Mark All as Reviewed clears them too.")
                }
            }
            Button { coordinator?.goToReviewMark(forward: true) } label: {
                Label("Next Change", systemImage: "chevron.down")
            }
            Button { coordinator?.goToReviewMark(forward: false) } label: {
                Label("Previous Change", systemImage: "chevron.up")
            }
            if canEdit {
                Button { review.clearAll() } label: {
                    Label("Mark All as Reviewed", systemImage: "checkmark.circle")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: review.unshownMarks > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                Text(review.count, format: .number)
                    .monospacedDigit()
            }
            .font(.body.weight(.semibold))
        }
        .accessibilityLabel(
            (review.count == 1 ? "1 to Review" : "\(review.count) to Review")
                + (review.unshownMarks > 0 ? ", some can’t be shown here" : "")
        )
    }

    /// The page shows the file's marks and sends its clears and restores
    /// back, as the writing's does.
    private func connect(_ coordinator: TipTapEditorCoordinator) {
        self.coordinator = coordinator
        // The copy held now, as opened, so undo can't go back past it to the
        // empty page; one taken in while the page was loading replaces what
        // it was made with.
        coordinator.load(text)
        Task { baseline = await pageText() }
        // No header over it: the page under the bar, not the space kept for
        // the writing's.
        coordinator.setReadPadding(top: 12)
        coordinator.setReviewMarks(review.markedMarkdown, changes: review.markedChanges)
        review.onMarksChanged = { [weak coordinator] marked, changes in
            coordinator?.setReviewMarks(marked, changes: changes)
        }
        coordinator.onReviewClear = { [weak review] marked, pageText in
            review?.clear(markedMarkdown: marked, pageText: pageText, answersPage: true)
        }
        coordinator.onReviewRestore = { [weak review] changeID, pageText in
            review?.restore(changeID: changeID, pageText: pageText)
        }
        coordinator.onLinkTapped = { address in
            guard let url = URL(string: address) else { return }
            UIApplication.shared.open(url)
        }
        coordinator.onFootnoteTapped = { [weak coordinator] id in coordinator?.scrollToFootnote(id) }
        coordinator.onReviewMarksRejected = { [weak review] in review?.marksRejected() }
        coordinator.onReviewMarksPartlyDrawn = { [weak review] unshown in review?.marksPartlyDrawn(unshown: unshown) }
        coordinator.onReviewMarksDrawn = { [weak review] in review?.marksDrawn() }
        coordinator.onReviewMarksStale = { [weak review] in review?.refreshMarks() }
        review.applyRestore = { [weak coordinator] restored, expected in
            guard let coordinator else { return nil }
            // Made from the copy held once a save under way has landed,
            // which its write replaces.
            while saving { try? await Task.sleep(for: .milliseconds(50)) }
            restoreBase = opened
            let made = await withCheckedContinuation { continuation in
                coordinator.restoreWording(restored, expecting: expected) { continuation.resume(returning: $0) }
            }
            guard let made else {
                restoreBase = nil
                return nil
            }
            // Taken now, so what's written is this text.
            text = made
            return made
        }
        review.saveRestoredDocument = { plan, base, restored, known in
            defer { restoreBase = nil }
            guard let from = restoreBase ?? opened else { return false }
            // Its own write, not the typing's: that one waits.
            saveTask?.cancel()
            while saving { try? await Task.sleep(for: .milliseconds(50)) }
            saving = true
            defer { saving = false }
            let saved = await WritingDocuments.saveRestored(
                restored, writingID: writingID, name: name, opened: from,
                plan: plan, base: base, known: known
            )
            if saved {
                opened = Data(restored.utf8)
                baseline = restored
                NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
                // Typed meanwhile: saved after.
                if isEdit(text) { scheduleSave() }
            } else {
                // On the page, not recorded: recorded by the save that writes it.
                unrecordedRestore = (plan, base, restored, known)
            }
            return saved
        }
    }

    /// The page's text as it is this moment, typing not yet reported in it.
    private func pageText() async -> String? {
        guard let coordinator else { return nil }
        return await withCheckedContinuation { continuation in
            coordinator.getContent { continuation.resume(returning: $0) }
        }
    }

    /// Whether the page holds an edit not yet saved, reported or not.
    private func hasEdits() async -> Bool {
        if let live = await pageText(), live != text { text = live }
        return isEdit(text)
    }

    /// Saves a moment after typing stops, over the copy the text is built on.
    private func scheduleSave() {
        guard canEdit, opened != nil, isEdit(text) else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        guard canEdit, let opened, !changedMeanwhile, restoreBase == nil else { return }
        // One at a time: the next waits, and saves what's there then.
        guard !saving else { return scheduleSave() }
        let writing = text
        guard isEdit(writing) else { return }
        saving = true
        defer { saving = false }
        do {
            if try await WritingDocuments.save(writing, writingID: writingID, name: name, opened: opened) {
                self.opened = Data(writing.utf8)
                baseline = writing
                // Saved here while Delete was being asked: still what was seen.
                if deleteSeen != nil { deleteSeen = self.opened }
                await recordRestore(ifSaved: writing)
                // The list's copy too, so the file opened again is this.
                NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
                if isEdit(text) { scheduleSave() }
            } else {
                changedMeanwhile = true
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Everything typed, reported or not, saved now. True where nothing's
    /// left unsaved.
    @discardableResult
    private func saveEverything() async -> Bool {
        saveTask?.cancel()
        guard canEdit else { return true }
        let edited = await hasEdits()
        while saving || restoreBase != nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard edited || isEdit(text) else { return true }
        await save()
        return !isEdit(text)
    }

    /// Saves everything typed, then goes back to the files; a save refused
    /// stays here, to say so and ask what to keep.
    private func leave() async {
        leaving = true
        defer { leaving = false }
        guard await stopEditingAndSave() else { return }
        dismiss()
    }

    private func finishEditing() async {
        _ = await stopEditingAndSave()
    }

    /// Typing stopped (the page read-only), then everything typed saved,
    /// the page read once more for what landed before it stopped. False
    /// where a save was refused, the page left to edit.
    private func stopEditingAndSave() async -> Bool {
        guard await saveEverything() else { return false }
        guard editing else { return true }
        editing = false
        try? await Task.sleep(for: .milliseconds(50))
        guard await saveEverything() else {
            editing = true
            return false
        }
        return true
    }

    /// Records a restore whose record didn't save with it, once a save has
    /// written its text: a text since edited away from it isn't it.
    private func recordRestore(ifSaved written: String) async {
        guard let pending = unrecordedRestore else { return }
        // Still standing in what was written, whatever else was typed; gone
        // (undone or written over), there's nothing to record.
        unrecordedRestore = nil
        guard pending.plan.stands(from: pending.base, in: written) else { return }
        let writingID = writingID
        let name = name
        _ = await Task.detached(priority: .userInitiated) {
            try? LibrarySyncPass.reviewStore.update(writingID: writingID, document: name) {
                $0.restoringWording(pending.plan, from: pending.base, to: pending.restored, carryingFrom: pending.known)
            }
        }.value
        NotificationCenter.default.post(name: .writingReviewsDidChange, object: nil)
    }

    /// The file's Markdown opened as it's written, everything typed saved
    /// first so the source editor opens on it.
    private func editSource() async {
        guard await saveEverything() else { return }
        // As stored now, which is what was just saved, or untouched.
        guard let stored = await WritingDocuments.load(writingID: writingID).first(where: { $0.name == name }) else { return }
        editingSource = WritingDocumentEditing(writingID: writingID, document: stored)
    }

    /// A copy stored elsewhere: taken in, or, with typing here unsaved, the
    /// writer asked.
    private func incoming(_ stored: Data) async {
        // One at a time; the newest waiting goes next.
        guard !takingIncoming else {
            nextIncoming = stored
            return
        }
        takingIncoming = true
        defer { takingIncoming = false }
        var next: Data? = stored
        while let stored = next {
            nextIncoming = nil
            await takeIncoming(stored)
            next = nextIncoming
        }
    }

    private func takeIncoming(_ stored: Data) async {
        while restoreBase != nil || saving { try? await Task.sleep(for: .milliseconds(50)) }
        guard stored != opened else { return }
        let incoming = String(decoding: stored, as: UTF8.self)
        // The page not there yet: it loads this when it is (`connect`).
        guard let coordinator else {
            opened = stored
            text = incoming
            return
        }
        // Taken in only where the page holds nothing typed, checked in the
        // page in the same step as the load, and its Markdown after read in
        // that step too, so a key pressed meanwhile is a change to keep or
        // let go, never taken for the file.
        let untouched = [baseline, storedText].compactMap { $0 }
        let loaded = await withCheckedContinuation { continuation in
            coordinator.load(incoming, ifHolding: untouched) { continuation.resume(returning: $0) }
        }
        if let loaded {
            opened = stored
            text = incoming
            baseline = loaded
        } else if canEdit {
            if let live = await pageText() { text = live }
            changedMeanwhile = true
        }
    }

    /// Takes in a stored copy, in place of the page's.
    private func take(_ stored: Data) async {
        let incoming = String(decoding: stored, as: UTF8.self)
        opened = stored
        text = incoming
        coordinator?.load(incoming)
        baseline = await pageText()
    }

    private func takeStored() async {
        guard let stored = await WritingDocuments.load(writingID: writingID).first(where: { $0.name == name }) else {
            return dismiss()
        }
        changedMeanwhile = false
        await take(stored.data)
    }

    private func keepAsCopy() async {
        do {
            _ = try await WritingDocuments.saveAsCopy(text, writingID: writingID, of: name)
            await ModuleSyncManager.shared.scheduleLibraryPass()
            NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
            if document == nil { return dismiss() }
            await takeStored()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete() async {
        saveTask?.cancel()
        // As last written here: a save under way lands first, so it isn't
        // taken for a copy from elsewhere.
        while saving || restoreBase != nil { try? await Task.sleep(for: .milliseconds(50)) }
        // The copy the writer saw when they asked, or one saved here since:
        // one taken in from elsewhere meanwhile is kept as a copy.
        guard let opened = deleteSeen ?? opened else { return }
        do {
            // A copy sync brought in while this one was open is kept.
            if let kept = try await WritingDocuments.delete(writingID: writingID, name: name, seen: opened) {
                problem = "It changed on another device while open, so that version is kept as \(kept)."
            }
            NotificationCenter.default.post(name: .writingDocumentsDidChange, object: nil)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One of a writing's plain-text files, read as it is, what the assistant
/// changed in it marked, as the writing's own prose is, and the addresses
/// written out in it tappable. A tap on a marked passage shows what it
/// changed, to mark as reviewed or put back. Gone back from once the file is
/// deleted, here or elsewhere. Markdown files open in the writing's editor
/// instead (`WritingDocumentPage`).
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
                } else {
                    let plain = WritingDocumentText.plain(shownText(of: document), fontSize: fontSize)
                    WritingFileText(
                        text: WritingDocumentText.linkingAddresses(WritingDocumentText.drawingMarks(plain, first: 0, open: nil).text),
                        onMark: choose
                    )
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
        // Each marker where it stands, since what's drawn is what's written.
        return LampWritingReviewMarkdown.numbered(marks.marked)
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

/// A plain-text file's text as it reads, and its review marks drawn in it.
/// Markdown files are the editor's (`WritingDocumentPage`).
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

/// Drawn text, selectable to copy from across all of it, as tall as it
/// runs: a plain-text file's, or an agent's reply. A tap on a review mark is
/// `onMark`'s, with the passage's place; any other link opens as links do.
struct WritingFileText: UIViewRepresentable {
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
