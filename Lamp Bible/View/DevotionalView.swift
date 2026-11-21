//
//  DevotionalView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import LampCore
import LampModuleKit
import SwiftUI

// MARK: - View Modes

enum DevotionalViewMode: String, CaseIterable {
    case present
    case read
    case edit
}

enum DevotionalEditMode: String, CaseIterable {
    case visual
    case markdown

    var displayName: String {
        switch self {
        case .visual: return "Visual"
        case .markdown: return "Markdown"
        }
    }
}

// MARK: - Full Screen Image Item

struct FullScreenImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let caption: DevotionalAnnotatedText?
}

// MARK: - Main View

/// A writing opened from a link in another.
struct LinkedWriting: Identifiable {
    var id: String { devotional.meta.id }
    let devotional: Devotional
    let moduleId: String

    /// The writing of this id, read off the main thread; nil if it's gone.
    static func load(id: String) async -> LinkedWriting? {
        let entry = await Task.detached { try? ModuleDatabase.shared.getDevotionalEntry(id: id) }.value
        guard let entry, let devotional = entry.toDevotional() else { return nil }
        return LinkedWriting(devotional: devotional, moduleId: entry.moduleId)
    }
}

/// A linked writing in a sheet, with the navigation bar its controls live in.
struct LinkedWritingSheet: View {
    let linked: LinkedWriting
    var onNavigateToVerse: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // No `onBack`: the view calls it whenever it disappears, which a
            // full-screen picture or deck opened from it makes it do, and
            // that would close the sheet under them.
            DevotionalView(
                devotional: linked.devotional,
                moduleId: linked.moduleId,
                onNavigateToVerse: onNavigateToVerse
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct DevotionalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // Configuration
    let initialDevotional: Devotional
    let moduleId: String
    var onBack: (() -> Void)?
    var onNavigateToVerse: ((Int) -> Void)?
    let initialMode: DevotionalViewMode

    // State
    @State private var devotional: Devotional
    @State private var mode: DevotionalViewMode
    @State private var editMode: DevotionalEditMode = .visual
    @State private var markdownContent: String = ""
    @State private var preservesRichContentJSON = false
    @State private var showingMetadataEditor: Bool = false
    /// Asking the writing assistant about this writing, with the words chosen
    /// in it when asked.
    @State private var askingAssistant: AgentRemoteWriting?
    /// The text was just replaced by a newer stored copy, not edited here:
    /// nothing to save.
    @State private var takingInStoredCopy = false
    /// The stored revision this copy was loaded or last saved as. A save
    /// finding the stored writing newer than this keeps both rather than
    /// writing over the other device's (or the assistant's) change.
    @State private var baseLastModified: Int?
    /// The text as last saved, to tell what the editor shows from it.
    @State private var persistedMarkdown: String?
    /// The write an immediate save started, to wait for before what follows
    /// it depends on it.
    @State private var inFlightWrite: Task<WriteOutcome, Never>?

    /// How an immediate save's write ended.
    enum WriteOutcome: Equatable, Sendable {
        /// Stored as this revision.
        case saved(Int)
        /// A newer copy was stored meanwhile: the edits were kept beside it.
        case keptCopy
        case failed
    }
    /// Counts the stored copies put in the editor's place: a read of the page
    /// begun before one is of the text it replaced, and is dropped.
    @State private var documentGeneration = 0
    /// The page's text as editing began. The page writes some Markdown its
    /// own way (a fourth-level heading, a comment), so only text unlike this
    /// is typing; nil until it's read, when none is taken for typing.
    @State private var editBaseline: String?
    /// What was saved as editing began: saved since, the page has been edited.
    @State private var persistedAtEditStart: String?
    /// Counts the times edits were kept as a copy, so what was waiting on a
    /// save knows the writing's own copy didn't take them.
    @State private var keptCopies = 0
    /// Said once edits were kept as a copy beside a newer version.
    @State private var keptEditsNotice: String?
    /// Leaving editing to ask the assistant, which saves on its own terms.
    @State private var handingToAssistant = false
    /// The writing's module takes changes: one that came in a module
    /// doesn't, so the assistant isn't offered for it.
    @State private var writingIsEditable = false
    @ObservedObject private var aiFeatures = AIFeatures.shared
    /// What the assistant changed that the writer hasn't read yet, where
    /// they keep marks (`AIFeatures.marksReviews`).
    @StateObject private var reviewSession = WritingReviewSession()
    @State private var hasUnsavedChanges: Bool = false
    @State private var fontSize: CGFloat = 18

    // Present mode font size
    @State private var presentFontMultiplier: CGFloat = 2.0

    // Auto-save - use longer debounce and simpler mechanism
    @State private var saveTask: Task<Void, Never>?
    @State private var lastSaveTime: Date = Date.distantPast

    // Save/Sync status
    @State private var saveState: DevotionalSaveState = .idle
    @State private var syncStatus: ModuleSyncStatus = .synced
    @State private var syncPollingTask: Task<Void, Never>?
    @State private var showingSyncStatusPopover: Bool = false
    /// No sync service is set up: the writing is simply kept on this device,
    /// which is a choice, not a failure.
    @State private var syncIsOff: Bool = false

    /// The title header has scrolled up under the bar, so the bar shows the
    /// title instead.
    @State private var headerScrolledAway: Bool = false

    // Preview sheet navigation (for scripture/strongs references)
    @State private var previewState: PreviewSheetState? = nil
    /// Another writing a link in this one opened.
    @State private var linkedWriting: LinkedWriting? = nil
    @State private var allDevotionalItems: [PreviewItem] = []

    // Link editor state
    @State private var showingLinkEditor: Bool = false
    @State private var linkEditorSelectedText: String = ""
    // Footnote editor state
    @State private var showingFootnoteEditor: Bool = false

    // Scripture quote state
    @State private var showingScriptureQuoteSheet: Bool = false
    @State private var showingQuotePopover: Bool = false

    // Media insertion state
    @State private var showingImagePicker: Bool = false
    @State private var showingAudioRecorder: Bool = false
    @State private var showingAudioFilePicker: Bool = false
    @State private var fullScreenImageItem: FullScreenImageItem? = nil

    // Slide decks made from this writing on a Mac
    @State private var linkedDecks: [PresentationDeckEntry] = []
    /// The writing's other files, its outline and notes, kept beside it:
    /// whether there are any says whether the files button is shown.
    @State private var documents: [WritingDocument] = []
    @State private var showingFiles = false
    @State private var openDeck: PresentationDeckEntry?

    // Table insertion state
    @State private var showingTableInsert: Bool = false
    @State private var tableRows: Int = 3
    @State private var tableCols: Int = 3
    @State private var tableHeaderRow: Bool = true

    // Audio player for editor audio block taps
    @StateObject private var editorAudioPlayer = AudioPlayer()

    enum DevotionalSaveState {
        case idle
        case saving
        case saved
        case error
    }

    init(devotional: Devotional, moduleId: String, initialMode: DevotionalViewMode = .read, onBack: (() -> Void)? = nil, onNavigateToVerse: ((Int) -> Void)? = nil) {
        self.initialDevotional = devotional
        self.moduleId = moduleId
        self.onBack = onBack
        self.onNavigateToVerse = onNavigateToVerse
        self.initialMode = initialMode
        _devotional = State(initialValue: devotional)
        _mode = State(initialValue: initialMode)
        // Use stored markdown if available, otherwise convert from blocks (legacy data)
        _markdownContent = State(initialValue: devotional.markdownContent ?? MarkdownDevotionalConverter.contentToMarkdown(devotional))
        _baseLastModified = State(initialValue: devotional.meta.lastModified)
        _persistedMarkdown = State(initialValue: devotional.markdownContent ?? MarkdownDevotionalConverter.contentToMarkdown(devotional))
        _preservesRichContentJSON = State(initialValue:
            MarkdownDevotionalConverter.shouldRetainContentJSON(devotional)
        )
        // Load present mode font multiplier from settings
        let settings = UserDatabase.shared.getSettings()
        _presentFontMultiplier = State(initialValue: CGFloat(settings.devotionalPresentFontMultiplier))
    }


    /// The page the writing sits on, matched by the editor's own background
    /// (tiptap-editor/src/editor.css, --bg-color): the reader's white, and in
    /// dark the panel charcoal rather than the reader's black, which is harsh
    /// under a long stretch of one's own prose.
    static let pageColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.lampPanelBackground.resolvedColor(with: traits)
            : UIColor.lampReaderBackground.resolvedColor(with: traits)
    })

    /// The text has the caret. The formatting tools show only then, over the
    /// keyboard, as a writing app's do; the page above stays clear.
    @State private var editorFocused = false
    @State private var focusLossTask: Task<Void, Never>?

    private var showsFormattingBar: Bool {
        mode == .edit && editMode == .visual && editorFocused
    }

    /// The title is drawn at the top of the page in reading and in visual
    /// editing; markdown editing shows the raw text alone.
    private var showsDocumentHeader: Bool {
        mode == .read || (mode == .edit && editMode == .visual)
    }

    private var barTitle: String {
        if mode == .present { return "" }
        if showsDocumentHeader && !headerScrolledAway { return "" }
        return devotional.meta.title
    }

    var body: some View {
        VStack(spacing: 0) {
            tiptapWebView
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsFormattingBar {
                richTextFormattingToolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsFormattingBar)
        .background(Self.pageColor.ignoresSafeArea())
        .navigationTitle(barTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(mode == .present)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if mode == .present {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        withAnimation {
                            mode = .read
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if showsFilesButton {
                            filesButton
                                .foregroundColor(.primary)
                        }
                        Button(action: {
                            let newMultiplier = presentFontMultiplier - 0.25
                            presentFontMultiplier = max(newMultiplier, 1.0)
                            try? UserDatabase.shared.updateSettings {
                                $0.devotionalPresentFontMultiplier = Float(presentFontMultiplier)
                            }
                        }) {
                            Image(systemName: "textformat.size.smaller")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.primary)
                        }
                        .disabled(presentFontMultiplier <= 1.0)

                        Button(action: {
                            let newMultiplier = presentFontMultiplier + 0.25
                            presentFontMultiplier = min(newMultiplier, 4.0)
                            try? UserDatabase.shared.updateSettings {
                                $0.devotionalPresentFontMultiplier = Float(presentFontMultiplier)
                            }
                        }) {
                            Image(systemName: "textformat.size.larger")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.primary)
                        }
                        .disabled(presentFontMultiplier >= 4.0)
                    }
                }
            } else {
                toolbarContent
            }
        }
        .alert(
            "Can’t Restore Original Wording",
            isPresented: Binding(
                get: { reviewSession.restoreRefusal != nil },
                set: { if !$0 { reviewSession.restoreRefusal = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reviewSession.restoreRefusal ?? "")
        }
        .alert("Restore Not Recorded Yet", isPresented: $reviewSession.restoreUnsaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(WritingRestoreRefusal.unsaved)
        }
        .alert(
            "Edits Kept as a Copy",
            isPresented: Binding(get: { keptEditsNotice != nil }, set: { if !$0 { keptEditsNotice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(keptEditsNotice ?? "")
        }
        .sheet(isPresented: $showingMetadataEditor) {
            MetadataEditorSheet(devotional: $devotional) {
                scheduleAutoSave()
            }
        }
        .sheet(item: $askingAssistant, onDismiss: {
            Task { await takeInNewerStoredCopy() }
        }) { writing in
            AskAssistantSheet(writing: writing)
        }
        // A sync, however it ran, can bring a newer copy of this writing: the
        // assistant's change, or another device's.
        .onReceive(NotificationCenter.default.publisher(for: .writingsDidChange)) { _ in
            Task { await takeInNewerStoredCopy() }
        }
        .task(id: devotional.meta.id) {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "OtherFilesDemo") { seedOtherFilesDemo() }
            #endif
            await reloadDocuments()
        }
        .onReceive(NotificationCenter.default.publisher(for: .writingDocumentsDidChange)) { _ in
            Task { await reloadDocuments() }
        }
        // Read again once closed: a file added or deleted there with sync
        // off says so to nothing else.
        .sheet(isPresented: $showingFiles, onDismiss: { Task { await reloadDocuments() } }) {
            WritingFilesSheet(
                writingID: devotional.meta.id,
                writingTitle: devotional.meta.title,
                canEdit: writingIsEditable,
                fontSize: fontSize
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $linkedWriting) { linked in
            LinkedWritingSheet(linked: linked, onNavigateToVerse: onNavigateToVerse)
        }
        .sheet(item: $previewState) { state in
            let itemTranslationId = state.currentItem.translationId
            let effectiveTranslationId = itemTranslationId ?? UserDatabase.shared.getSettings().readerTranslation
            PreviewSheet(
                state: $previewState,
                translationId: effectiveTranslationId,
                onNavigateToVerse: onNavigateToVerse ?? { verseId in
                    // Use deep link URL when callback not provided
                    if let url = buildVerseURL(verseId: verseId, translationId: itemTranslationId) {
                        openURL(url)
                    }
                }
            )
        }
        .sheet(isPresented: $showingLinkEditor) {
            LinkEditorSheet(
                selectedText: linkEditorSelectedText,
                onSave: { linkType in
                    insertLink(linkType)
                },
                onCancel: {
                    showingLinkEditor = false
                }
            )
        }
        .sheet(isPresented: $showingFootnoteEditor) {
            FootnoteEditorSheet(
                onSave: { content in
                    insertFootnote(content)
                },
                onCancel: {
                    showingFootnoteEditor = false
                }
            )
        }
        .sheet(isPresented: $showingScriptureQuoteSheet) {
            ScriptureQuoteSheet(
                onInsert: { citation, quotation in
                    insertScriptureQuote(citation: citation, quotation: quotation)
                },
                onCancel: {
                    showingScriptureQuoteSheet = false
                }
            )
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePickerSheet(isPresented: $showingImagePicker) { image in
                print("[DevotionalView] Image picker callback received image: \(image.size)")
                insertImageBlock(image)
            }
        }
        .sheet(isPresented: $showingAudioRecorder) {
            AudioRecorderSheet(isPresented: $showingAudioRecorder) { audioURL in
                print("[DevotionalView] Audio recorder callback received URL: \(audioURL)")
                insertAudioBlock(from: audioURL)
            }
        }
        .sheet(isPresented: $showingTableInsert) {
            TableInsertSheet(
                rows: $tableRows,
                cols: $tableCols,
                headerRow: $tableHeaderRow,
                onInsert: {
                    tiptapCoordinator?.insertTable(rows: tableRows, cols: tableCols, withHeaderRow: tableHeaderRow)
                    showingTableInsert = false
                },
                onCancel: {
                    showingTableInsert = false
                }
            )
            .presentationDetents([.height(300)])
        }
        .fileImporter(
            isPresented: $showingAudioFilePicker,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav],
            allowsMultipleSelection: false
        ) { result in
            handleAudioFileImport(result)
        }
        .fullScreenCover(item: $openDeck) { entry in
            DeckViewerView(entry: entry)
        }
        .task(id: devotional.meta.id) { await reloadLinkedDecks() }
        // The writing's review marks, followed while it's open and marks are
        // shown; another writing, or marks turned off, starts again.
        .task(id: ReviewFollowing(writingID: devotional.meta.id, isShown: showsReviewMarks)) {
            #if DEBUG
            if showsReviewMarks, UserDefaults.standard.bool(forKey: "ReviewMarksDemo") { seedReviewMarksDemo() }
            #endif
            await reviewSession.follow(writingID: devotional.meta.id, text: markdownContent, isShown: showsReviewMarks)
        }
        .onChange(of: markdownContent) { _, text in reviewSession.textChanged(text) }
        .task(id: moduleId) {
            let id = moduleId
            writingIsEditable = await Task.detached(priority: .utility) {
                (try? ModuleDatabase.shared.getModule(id: id))?.isEditable ?? false
            }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentationDecksDidChange)) { _ in
            Task { await reloadLinkedDecks() }
        }
        .fullScreenCover(item: $fullScreenImageItem) { item in
            FullScreenImageView(
                image: item.image,
                caption: item.caption,
                isPresented: Binding(
                    get: { fullScreenImageItem != nil },
                    set: { if !$0 { fullScreenImageItem = nil } }
                )
            )
        }
        .onDisappear {
            saveTask?.cancel()
            syncPollingTask?.cancel()
            if hasUnsavedChanges {
                saveNowSync()
            }
            onBack?()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive where mode == .edit:
                // What was typed in the last moment, which the editor has
                // not yet reported, is taken while the page can still answer.
                tiptapCoordinator?.getContent { markdown in
                    if let markdown, markdown != markdownContent { markdownContent = markdown }
                }
            case .background where hasUnsavedChanges:
                // Saved as the app leaves the foreground, not after the
                // pause: one closed from the switcher while suspended never
                // comes back to make the save.
                saveTask?.cancel()
                saveTask = nil
                UIApplication.shared.finishing("SaveWriting") { await saveNow() }
            default:
                break
            }
        }
        .onChange(of: mode) { oldMode, newMode in
            // When leaving edit mode, ensure content is saved
            if oldMode == .edit && newMode != .edit {
                // Stop sync polling
                syncPollingTask?.cancel()
                syncPollingTask = nil

                // Asking the assistant reads the page and saves, waiting for
                // the save, itself.
                guard !handingToAssistant else { return }
                // The page is read first, for typing the editor hadn't
                // reported yet; then what it shows is saved, and waited for
                // (a save finding a newer copy keeps the edits beside it);
                // then a newer copy that came while editing is shown.
                // Only the visual editor: leaving Markdown editing has already
                // turned the page back to rich text, whose Markdown isn't
                // what was typed (a fourth-level heading, a comment).
                let visual = editMode == .visual
                Task {
                    if visual, let coordinator = tiptapCoordinator {
                        let generation = documentGeneration
                        let live = await withCheckedContinuation { continuation in
                            coordinator.getContent { continuation.resume(returning: $0) }
                        }
                        if let live, live != markdownContent, isTyped(live), mode != .edit, generation == documentGeneration {
                            takingInStoredCopy = true
                            markdownContent = live
                            hasUnsavedChanges = true
                        }
                    }
                    guard mode != .edit else { return }
                    // Saved now, so an autosave still queued has nothing to do.
                    saveTask?.cancel()
                    saveTask = nil
                    if hasUnsavedChanges { await saveNow() }
                    _ = await inFlightWrite?.value
                    await takeInNewerStoredCopy()
                }
            }

            // When entering edit mode, start sync status polling
            if newMode == .edit && oldMode != .edit {
                editBaseline = nil
                persistedAtEditStart = persistedMarkdown
                if let coordinator = tiptapCoordinator {
                    let generation = documentGeneration
                    coordinator.getContent { text in
                        if generation == documentGeneration, mode == .edit { editBaseline = text }
                    }
                }
                Task {
                    await checkSyncStatus()
                }
                syncPollingTask = startSyncStatusPolling()
            }
            // NOTE: Removed syncMarkdownFromBlocks() when entering edit mode
            // The init() already sets markdownContent, and calling sync here
            // could overwrite user's unsaved changes with stale block data.
        }
        .onAppear {
            // If starting in edit mode, begin sync status polling
            if mode == .edit {
                Task {
                    await checkSyncStatus()
                }
                syncPollingTask = startSyncStatusPolling()
            }

            // Parse all tappable items for preview navigation
            allDevotionalItems = parseDevotionalItems(from: devotional)
        }
        .onChange(of: devotional) { _, newDevotional in
            // Re-parse items when devotional changes
            allDevotionalItems = parseDevotionalItems(from: newDevotional)
        }
    }

    // MARK: - Unified Layout Components

    private var presentFontSize: CGFloat {
        fontSize * presentFontMultiplier
    }

    private var effectiveFontSize: CGFloat {
        mode == .present ? presentFontSize : fontSize
    }

    @State private var tiptapCoordinator: TipTapEditorCoordinator?

    /// "2026-11-06" as a reader would write it.
    private var displayDate: String? {
        guard let raw = devotional.meta.date else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = TimeZone.current
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .long, time: .omitted)
    }

    /// The top of the page: what kind of writing and when, its title, what it
    /// is on. Drawn by the host over the editor's top padding, so it scrolls
    /// with the text. While writing, a tap on it opens the details to edit.
    @ViewBuilder
    private var readModeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            let category = devotional.meta.categoryName
            if category != nil || displayDate != nil {
                HStack(spacing: 6) {
                    if let category {
                        Text(category.uppercased())
                    }
                    if category != nil, displayDate != nil {
                        Text("·")
                    }
                    if let date = displayDate {
                        Text(date.uppercased())
                    }
                }
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(LampTheme.caption)
                .lineLimit(1)
            }

            Text(devotional.meta.title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = devotional.meta.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(LampTheme.readerText.opacity(0.72))
            }

            if let author = devotional.meta.author, !author.isEmpty {
                Label(author, systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Tags
            if let tags = devotional.meta.tags, !tags.isEmpty {
                DevotionalFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            // Key scriptures
            if let scriptures = devotional.meta.keyScriptures, !scriptures.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "book")
                        .font(.caption)
                    ForEach(scriptures, id: \.sv) { scripture in
                        if let label = scripture.label {
                            Text(label)
                                .font(.caption)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.top, 10)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .edit { showingMetadataEditor = true }
        }
        .accessibilityAddTraits(mode == .edit ? .isButton : [])
        .accessibilityHint(mode == .edit ? "Edits the title and details" : "")
    }

    /// The writing's files, the way to its outline and notes: shown in every
    /// mode once it has any, and while it can be written, to add one.
    private var showsFilesButton: Bool {
        !documents.isEmpty || (writingIsEditable && mode != .present)
    }

    private var filesButton: some View {
        Button { showingFiles = true } label: {
            Image(systemName: "doc.on.doc")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("Files")
        .accessibilityValue(documents.isEmpty ? "No other files" : "\(documents.count) other files")
    }

    private func reloadDocuments() async {
        let id = devotional.meta.id
        let loaded = await WritingDocuments.load(writingID: id)
        // Not over another writing's, opened meanwhile.
        guard id == devotional.meta.id else { return }
        documents = loaded
    }

    private var tiptapWebView: some View {
        GeometryReader { geometry in
            TipTapEditorView(
                markdownContent: $markdownContent,
                fontSize: effectiveFontSize,
                editMode: editMode,
                viewMode: mode,
                mediaRefs: devotional.media,
                devotionalId: devotional.meta.id,
                moduleId: moduleId,
                header: readModeHeader,
                showsHeader: showsDocumentHeader,
                onHeaderScrolledAway: { away in
                    if headerScrolledAway != away { headerScrolledAway = away }
                },
                onCoordinatorReady: { coordinator in
                    tiptapCoordinator = coordinator
                    connectReviewMarks(to: coordinator)
                    // A newer copy that came while the editor was loading.
                    Task { await takeInNewerStoredCopy() }

                    coordinator.onImageTapped = { mediaId in
                        handleImageTapByMediaId(mediaId)
                    }

                    coordinator.onAudioBlockTapped = { mediaId in
                        handleAudioBlockTap(mediaId)
                    }

                    coordinator.onLinkTapped = { urlString in
                        guard let url = URL(string: urlString) else { return }
                        handleLinkTap(url: url)
                    }

                    coordinator.onFootnoteTapped = { id in
                        coordinator.scrollToFootnote(id)
                    }

                    // Focus comes and goes for a moment as the page changes
                    // under an edit; only a loss that lasts hides the tools.
                    coordinator.onFocusChanged = { focused in
                        DispatchQueue.main.async {
                            focusLossTask?.cancel()
                            if focused {
                                if !editorFocused { editorFocused = true }
                            } else {
                                focusLossTask = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(350))
                                    guard !Task.isCancelled else { return }
                                    editorFocused = false
                                }
                            }
                        }
                    }

                    // Set present padding if starting in present mode
                    if mode == .present {
                        let padding = geometry.size.height - presentFontSize - 96
                        coordinator.setPresentPadding(bottom: max(0, padding))
                    }
                }
            )
            .onChange(of: markdownContent) { _, _ in
                if takingInStoredCopy {
                    takingInStoredCopy = false
                    return
                }
                if mode == .edit {
                    hasUnsavedChanges = true
                    scheduleAutoSave()
                }
            }
            .onChange(of: mode) { oldMode, newMode in
                if newMode == .present {
                    let padding = geometry.size.height - presentFontSize - 96
                    tiptapCoordinator?.setPresentPadding(bottom: max(0, padding))
                }
            }
            .onChange(of: presentFontMultiplier) { _, _ in
                if mode == .present {
                    let padding = geometry.size.height - presentFontSize - 96
                    tiptapCoordinator?.setPresentPadding(bottom: max(0, padding))
                }
            }
        }
        // Under the bars at both ends while reading; above the formatting
        // tools while they show, so the caret is never kept beneath them.
        .ignoresSafeArea(.container, edges: showsFormattingBar ? [.top] : [.top, .bottom])
    }

    // MARK: - Content Sync

    private func syncMarkdownFromBlocks() {
        markdownContent = MarkdownDevotionalConverter.contentToMarkdown(devotional)
    }

    @discardableResult
    private func syncBlocksFromMarkdown() -> Bool {
        if preservesRichContentJSON {
            guard let decoded = try? MarkdownDevotionalConverter.revisingContent(
                devotional.content, with: markdownContent
            ) else {
                saveState = .error
                return false
            }
            devotional.content = decoded
            devotional.markdownContent = nil
        } else {
            devotional.content = .blocks(
                MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
            )
            devotional.markdownContent = markdownContent
        }
        devotional.footnotes = MarkdownDevotionalConverter.parseFootnotes(from: markdownContent)
        return true
    }

    /// Sync markdown from visual editor - TipTap handles this via contentChanged messages,
    /// so this is a no-op (content is already synced via the binding).
    private func syncMarkdownFromVisualEditor() {
        // No-op: TipTap editor syncs markdown content automatically via the binding
    }

    /// The formatting tools as one calm bar of eight, grouped by kind: text
    /// style, emphasis, lists, quotation, links, and everything inserted.
    /// It fits the phone's width; at the largest text sizes it scrolls.
    private var richTextFormattingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            formattingBar
            ScrollView(.horizontal, showsIndicators: false) {
                formattingBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var formattingBar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Paragraph") { tiptapCoordinator?.applyStyle(.paragraph) }
                Button("Heading 1") { tiptapCoordinator?.applyStyle(.heading1) }
                Button("Heading 2") { tiptapCoordinator?.applyStyle(.heading2) }
                Button("Heading 3") { tiptapCoordinator?.applyStyle(.heading3) }
                Divider()
                Button(action: { tiptapCoordinator?.applyStyle(.indent) }) {
                    Label("Increase Indent", systemImage: "increase.indent")
                }
                Button(action: { tiptapCoordinator?.applyStyle(.outdent) }) {
                    Label("Decrease Indent", systemImage: "decrease.indent")
                }
            } label: {
                formattingButton(icon: "textformat", label: nil)
            }
            .accessibilityLabel("Text Style")

            formattingDivider

            Button(action: { tiptapCoordinator?.applyStyle(.bold) }) {
                formattingButton(icon: "bold", label: nil)
            }
            .accessibilityLabel("Bold")

            Button(action: { tiptapCoordinator?.applyStyle(.italic) }) {
                formattingButton(icon: "italic", label: nil)
            }
            .accessibilityLabel("Italic")

            formattingDivider

            Button(action: { tiptapCoordinator?.applyStyle(.bullet) }) {
                formattingButton(icon: "list.bullet", label: nil)
            }
            .accessibilityLabel("Bulleted List")

            Button(action: { tiptapCoordinator?.applyStyle(.numberedList) }) {
                formattingButton(icon: "list.number", label: nil)
            }
            .accessibilityLabel("Numbered List")

            formattingDivider

            // Quote (menu with Regular/Scripture options)
            Menu {
                Button(action: {
                    tiptapCoordinator?.applyStyle(.quote)
                }) {
                    Label("Regular Quote", systemImage: "text.quote")
                }

                Button(action: {
                    showingScriptureQuoteSheet = true
                }) {
                    Label("Scripture Quote", systemImage: "book.closed")
                }
            } label: {
                formattingButton(icon: "text.quote", label: nil)
            }
            .accessibilityLabel("Quote")

            Menu {
                Button(action: { openLinkEditor() }) {
                    Label("Add Link…", systemImage: "link")
                }
                Button(action: { tiptapCoordinator?.removeLink() }) {
                    Label("Remove Link", systemImage: "link.badge.minus")
                }
            } label: {
                formattingButton(icon: "link", label: nil)
            }
            .accessibilityLabel("Link")

            // Everything placed in the text rather than applied to it
            Menu {
                Button(action: { openFootnoteEditor() }) {
                    Label("Footnote…", systemImage: "note.text")
                }
                Button(action: { tiptapCoordinator?.insertHorizontalRule() }) {
                    Label("Divider", systemImage: "minus")
                }
                Button(action: { showingTableInsert = true }) {
                    Label("Table…", systemImage: "tablecells")
                }
                Divider()
                Button(action: {
                    tiptapCoordinator?.resignFirstResponder()
                    showingImagePicker = true
                }) {
                    Label("Add Image", systemImage: "photo")
                }

                Button(action: {
                    tiptapCoordinator?.resignFirstResponder()
                    showingAudioRecorder = true
                }) {
                    Label("Record Audio", systemImage: "mic")
                }

                Button(action: {
                    tiptapCoordinator?.resignFirstResponder()
                    showingAudioFilePicker = true
                }) {
                    Label("Import Audio", systemImage: "waveform")
                }
            } label: {
                formattingButton(icon: "plus.circle", label: nil)
            }
            .accessibilityLabel("Insert")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // The tools in the text's own colour: a row of accent-coloured
        // glyphs would outshout the writing beneath them.
        .tint(Color.primary)
        .formattingBarSurface()
    }

    private var formattingDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }

    private func replace(with stored: Devotional) {
        let markdown = stored.markdownContent ?? MarkdownDevotionalConverter.contentToMarkdown(stored)
        devotional = stored
        documentGeneration += 1
        baseLastModified = stored.meta.lastModified
        persistedMarkdown = markdown
        preservesRichContentJSON = MarkdownDevotionalConverter.shouldRetainContentJSON(stored)
        guard markdown != markdownContent else { return }
        // The editor resolves images as it draws them: the media the copy
        // brings has to be known to it first.
        var mediaMap: [String: String] = [:]
        for ref in stored.media ?? [] {
            if let url = DevotionalMediaStorage.shared.getMediaURL(for: ref, devotionalId: stored.meta.id, moduleId: moduleId) {
                mediaMap[ref.id] = url.absoluteString
            }
        }
        tiptapCoordinator?.setMediaMap(mediaMap)
        takingInStoredCopy = true
        markdownContent = markdown
        tiptapCoordinator?.setContent(markdown)
    }

    /// Takes in the writing as stored when it's newer than what's shown: the
    /// assistant's change, or another device's, brought by sync. Without this
    /// the next edit here would start from, and save, the older copy.
    /// `regardless` once the edits here were kept as a copy: the stored
    /// version is shown whatever this copy is dated, since an immediate save
    /// dates it before knowing whether it wrote.
    private func takeInNewerStoredCopy(regardless: Bool = false) async {
        // Not while the writing is handed to the assistant, which reads the
        // editor and saves what it shows itself.
        guard !isSaving, regardless || !handingToAssistant else { return }
        let id = devotional.meta.id
        let stored = await Task.detached(priority: .userInitiated) {
            try? DevotionalStorage.shared.getDevotional(id: id)
        }.value
        // Read or presented only, with nothing here waiting to be saved: while
        // editing, typing the editor hasn't reported yet can't be ruled out,
        // and asking the assistant leaves editing first (askAssistant).
        // Not before the editor is there to take it: it would load the copy it
        // began with, and this one would be passed over as already shown.
        guard let stored, regardless || (stored.meta.lastModified ?? 0) > (devotional.meta.lastModified ?? 0),
              mode != .edit, !hasUnsavedChanges, !isSaving, saveTask == nil, regardless || !handingToAssistant,
              tiptapCoordinator != nil else { return }
        replace(with: stored)
    }

    /// Opens the writing's chat with the assistant, taking along whatever is
    /// chosen in the writing.
    private func askAssistant() {
        let writing = AgentRemoteWriting(id: devotional.meta.id, moduleID: moduleId, title: devotional.meta.title)
        Task { @MainActor in
            // The assistant changes the writing on the Mac: editing it here at
            // the same time would be two hands on one page. So everything
            // typed, reported or not, is saved first, no save is left queued
            // to land over the assistant's change, and the writing is read
            // while asking, taking the change in when it comes.
            let editing = mode == .edit
            handingToAssistant = true
            defer { handingToAssistant = false }
            // A save already under way finishes first, so what's read from
            // the editor next isn't marked saved by it.
            for _ in 0..<100 where isSaving {
                try? await Task.sleep(for: .milliseconds(50))
            }
            var live: String?
            var chosen = ""
            let generation = documentGeneration
            if let coordinator = tiptapCoordinator {
                // Taken before leaving editing clears them.
                chosen = await withCheckedContinuation { continuation in
                    coordinator.getChosenWords { continuation.resume(returning: $0) }
                }
                if editing {
                    live = await Self.readPage(coordinator, leaving: { withAnimation { mode = .read } }, visual: editMode == .visual)
                }
            }
            saveTask?.cancel()
            saveTask = nil
            // Every write already started finishes first: an immediate save's
            // detached one, and one in progress.
            if await inFlightWrite?.value == .keptCopy { return }
            for _ in 0..<100 where isSaving {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // A stored copy put in the editor's place meanwhile: what was
            // read is the text it replaced, and nothing is asked.
            guard generation == documentGeneration else { return }
            // Edits are saved for the assistant: those reported, and typing
            // read from the page while editing that wasn't yet. Nothing else
            // is: the page's own Markdown for an unedited writing can differ
            // from what's stored (a fourth-level heading, a comment) and
            // would lose it.
            var saving = hasUnsavedChanges
            if let live, live != markdownContent, isTyped(live) {
                takingInStoredCopy = true
                markdownContent = live
                saving = true
            }
            if saving {
                let shown = markdownContent
                let copiesBefore = keptCopies
                hasUnsavedChanges = true
                await saveNow()
                // Kept beside a newer version: that's the one to ask about,
                // once it's shown.
                guard keptCopies == copiesBefore else { return }
                // Not saved here: nothing goes to the assistant from text the
                // library doesn't have. The save's own error shows.
                guard !hasUnsavedChanges, saveState != .error, persistedMarkdown == shown else { return }
            }
            if editing && mode == .edit { withAnimation { mode = .read } }
            var asked = writing
            let words = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
            asked.selection = words.isEmpty ? nil : words
            // The Mac works on its own copy: a sync pass sends what's saved,
            // and each message carries the writing's revision as stored, so
            // the Mac can check it has caught up (AgentRemoteWritingStamp).
            // Only when there's something to send: a save, now or earlier,
            // that hasn't gone up. One just made hasn't, so the sheet opens
            // without checking, and checks while it waits.
            asked.syncFirst = saving ? true : await asked.isWaitingToGoUp()
            askingAssistant = asked
        }
    }

    private func openLinkEditor() {
        guard let coordinator = tiptapCoordinator else { return }

        coordinator.getSelectedText { selectedText in
            DispatchQueue.main.async {
                self.linkEditorSelectedText = selectedText
                self.showingLinkEditor = true
            }
        }
    }

    private func insertLink(_ linkType: LinkEditorSheet.LinkType) {
        showingLinkEditor = false

        guard let coordinator = tiptapCoordinator else { return }

        let url: String
        switch linkType {
        case .url(let urlString):
            url = urlString
        case .scripture(let verseId, let endVerseId):
            url = formatScriptureURL(verseId: verseId, endVerseId: endVerseId)
        case .strongs(let key):
            url = "lampbible://strongs/\(key)"
        }

        coordinator.insertLink(url: url)
        hasUnsavedChanges = true
        scheduleAutoSave()
    }

    private func openFootnoteEditor() {
        showingFootnoteEditor = true
    }

    private func insertFootnote(_ content: String) {
        showingFootnoteEditor = false

        guard let coordinator = tiptapCoordinator,
              !content.isEmpty else { return }

        let footnoteId = getNextFootnoteId()
        coordinator.insertFootnote(id: footnoteId, content: content)
        hasUnsavedChanges = true
        scheduleAutoSave()
    }

    private func getNextFootnoteId() -> String {
        // Count existing footnotes in the markdown content
        let pattern = "\\[\\^(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "1"
        }

        let matches = regex.matches(in: markdownContent, range: NSRange(markdownContent.startIndex..., in: markdownContent))
        var maxId = 0

        for match in matches {
            if let range = Range(match.range(at: 1), in: markdownContent),
               let id = Int(markdownContent[range]) {
                maxId = max(maxId, id)
            }
        }

        return String(maxId + 1)
    }

    private func insertScriptureQuote(citation: String, quotation: String) {
        showingScriptureQuoteSheet = false

        guard let coordinator = tiptapCoordinator else { return }

        coordinator.insertScriptureQuote(citation: citation, quotation: quotation)
        hasUnsavedChanges = true
        scheduleAutoSave()
    }

    // MARK: - Media Insertion

    private func insertImageBlock(_ image: UIImage) {
        print("[DevotionalView] insertImageBlock called")
        Task {
            do {
                let mediaId = UUID().uuidString
                print("[DevotionalView] Saving image with mediaId: \(mediaId)")
                let mediaRef = try DevotionalMediaStorage.shared.saveImage(
                    image,
                    id: mediaId,
                    devotionalId: devotional.meta.id,
                    moduleId: moduleId
                )
                print("[DevotionalView] Image saved: \(mediaRef.filename)")

                // Add to media array
                if devotional.media == nil {
                    devotional.media = []
                }
                devotional.media?.append(mediaRef)

                // Get local file URL for display
                let localURL = DevotionalMediaStorage.shared.getMediaURL(
                    for: mediaRef, devotionalId: devotional.meta.id, moduleId: moduleId
                )?.absoluteString ?? ""

                await MainActor.run {
                    // Insert via TipTap
                    tiptapCoordinator?.insertImage(mediaId: mediaId, caption: "", localURL: localURL)

                    // Update media map so editor can resolve the new image
                    tiptapCoordinator?.setMediaMap(buildMediaMap())

                    hasUnsavedChanges = true
                    scheduleAutoSave()
                    print("[DevotionalView] Image block inserted successfully")
                }
            } catch {
                print("[DevotionalView] Error saving image: \(error)")
            }
        }
    }

    private func insertAudioBlock(from audioURL: URL) {
        print("[DevotionalView] insertAudioBlock called with URL: \(audioURL)")
        Task {
            do {
                let mediaId = UUID().uuidString
                print("[DevotionalView] Saving audio with mediaId: \(mediaId)")
                let mediaRef = try await DevotionalMediaStorage.shared.saveAudio(
                    from: audioURL,
                    id: mediaId,
                    devotionalId: devotional.meta.id,
                    moduleId: moduleId,
                    generateWaveform: true
                )
                print("[DevotionalView] Audio saved: \(mediaRef.filename)")

                // Add to media array
                if devotional.media == nil {
                    devotional.media = []
                }
                devotional.media?.append(mediaRef)

                await MainActor.run {
                    // Insert via TipTap
                    tiptapCoordinator?.insertAudioBlock(mediaId: mediaId, caption: "Audio")

                    hasUnsavedChanges = true
                    scheduleAutoSave()
                    print("[DevotionalView] Audio block inserted successfully")
                }
            } catch {
                print("[DevotionalView] Error saving audio: \(error)")
            }
        }
    }

    private func handleAudioFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Need to access security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { return }

            // Copy to temp directory so we can process it
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)

            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                url.stopAccessingSecurityScopedResource()
                insertAudioBlock(from: tempURL)
            } catch {
                print("[DevotionalView] Audio import error: \(error)")
                url.stopAccessingSecurityScopedResource()
            }

        case .failure(let error):
            print("[DevotionalView] Audio file picker error: \(error)")
        }
    }

    private func formattingButton(icon: String, label: String?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            if let label = label {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundStyle(.primary)
        .frame(width: label != nil ? 48 : 38, height: 36)
        .contentShape(Rectangle())
    }

    private func toggleEditMode() {
        if editMode == .visual {
            editMode = .markdown
        } else {
            editMode = .visual
        }
        // TipTapEditorView handles mode switching internally via editMode binding
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The writing's own actions at the top; the way between reading,
        // presenting and editing at the bottom, on its own.
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Font size (read mode only)
            if mode == .read {
                Menu {
                    Button(action: { fontSize = max(12, fontSize - 2) }) {
                        Label("Smaller", systemImage: "textformat.size.smaller")
                    }
                    Button(action: { fontSize = min(32, fontSize + 2) }) {
                        Label("Larger", systemImage: "textformat.size.larger")
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .accessibilityLabel("Text Size")
            }

            // Sync status, while writing, when there is a sync to report on.
            // Sync that is off by choice is said in the menu, not flagged here.
            if mode == .edit && !syncIsOff {
                Button {
                    showingSyncStatusPopover = true
                } label: {
                    switch syncStatus {
                    case .synced:
                        Image(systemName: "checkmark.icloud")
                            .foregroundStyle(.green)
                    case .syncing:
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .foregroundStyle(.secondary)
                    case .notSynced:
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(.orange)
                    case .notAvailable:
                        Image(systemName: "xmark.icloud")
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityLabel(syncAccessibilityLabel)
                .popover(isPresented: $showingSyncStatusPopover) {
                    syncStatusPopoverContent
                }
            }

            if !linkedDecks.isEmpty {
                slidesButton
            }

            // Share
            Menu {
                Button(action: shareDevotional) {
                    Label("Share Writing File", systemImage: "doc")
                }
                ShareLink("Share as Markdown", item: markdownContent)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
        }

        // Bottom toolbar with single mode button (hidden in present mode)
        if mode != .present {
            // The writing assistant, on the Mac, while the AI features are on,
            // for a writing it may change.
            if aiFeatures.isEnabled && writingIsEditable {
                ToolbarItem(placement: .bottomBar) {
                    Button(action: askAssistant) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Ask the Assistant")
                }
            }
            if showsReviewMarks && reviewSession.count > 0 {
                ToolbarItem(placement: .bottomBar) {
                    reviewControl
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            if showsFilesButton {
                ToolbarItem(placement: .bottomBar) {
                    filesButton
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button(action: { withAnimation { mode = .present } }) {
                        Label("Present", systemImage: "rectangle.expand.vertical")
                    }
                    Button(action: { withAnimation { mode = .read } }) {
                        Label("Read", systemImage: "book")
                    }
                    Divider()
                    Button(action: { switchToMarkdownEdit() }) {
                        Label("Markdown Edit", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button(action: { switchToVisualEdit() }) {
                        Label("Visual Edit", systemImage: "pencil")
                    }
                    Divider()
                    Button(action: { showingMetadataEditor = true }) {
                        Label("Edit Metadata", systemImage: "info")
                    }
                    if mode == .edit && syncIsOff {
                        Divider()
                        Section("Sync is off. This writing is saved on this device.") {}
                    }
                } label: {
                    Image(systemName: modeIcon)
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Mode: \(modeLabel)")
            }
        }
    }

    /// The current mode's own icon, as its item in the mode menu shows it.
    private var modeIcon: String {
        switch mode {
        case .present: return "rectangle.expand.vertical"
        case .read: return "book"
        case .edit:
            return editMode == .visual ? "pencil" : "chevron.left.forwardslash.chevron.right"
        }
    }

    private var modeLabel: String {
        switch mode {
        case .present: return "Present"
        case .read: return "Read"
        case .edit: return editMode == .visual ? "Visual Edit" : "Markdown Edit"
        }
    }

    private var syncAccessibilityLabel: String {
        switch syncStatus {
        case .synced: "Synced"
        case .syncing: "Syncing"
        case .notSynced: "Waiting to sync"
        case .notAvailable: syncIsOff ? "Sync is off" : "Sync unavailable"
        }
    }

    /// Opens the deck made from this writing, or offers the choice when there
    /// is more than one.
    @ViewBuilder
    private var slidesButton: some View {
        if linkedDecks.count == 1, let entry = linkedDecks.first {
            Button { openDeck = entry } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .accessibilityLabel("Slides")
        } else {
            Menu {
                ForEach(linkedDecks) { entry in
                    Button(entry.title) { openDeck = entry }
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .accessibilityLabel("Slides")
        }
    }

    private func reloadLinkedDecks() async {
        let writingID = devotional.meta.id
        let entries = await Task.detached(priority: .userInitiated) {
            PresentationDeckStorage.shared.entries(forWriting: writingID)
        }.value
        linkedDecks = entries
        if let openDeck, !entries.contains(where: { $0.id == openDeck.id }) {
            self.openDeck = nil
        }
    }

    private func switchToVisualEdit() {
        withAnimation {
            mode = .edit
            editMode = .visual
        }
    }

    private func switchToMarkdownEdit() {
        withAnimation {
            mode = .edit
            editMode = .markdown
        }
    }

    // MARK: - Auto-save

    @State private var isSaving: Bool = false

    /// Share the devotional as a .devotional file
    private func shareDevotional() {
        DevotionalSharingManager.shared.share(devotional, moduleId: moduleId)
    }

    private func scheduleAutoSave() {
        hasUnsavedChanges = true

        // Don't schedule a new save if one is already pending
        if saveTask != nil {
            return
        }

        saveTask = Task { @MainActor in
            // Wait 3 seconds before saving
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            guard !Task.isCancelled else {
                saveTask = nil
                return
            }

            // Ensure minimum time between saves (5 seconds)
            let timeSinceLastSave = Date().timeIntervalSince(lastSaveTime)
            if timeSinceLastSave < 5.0 {
                let additionalWait = UInt64((5.0 - timeSinceLastSave) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: additionalWait)
            }

            guard !Task.isCancelled else {
                saveTask = nil
                return
            }

            await saveNow()
            saveTask = nil
        }
    }

    @MainActor
    private func saveNow() async {
        // Prevent concurrent saves
        guard !isSaving else {
            print("[DevotionalView] Save already in progress, skipping")
            return
        }

        isSaving = true
        saveState = .saving
        defer { isSaving = false }

        // An immediate save's write lands first, so what's stored is judged
        // after it.
        _ = await inFlightWrite?.value
        // A newer copy stored since this one was loaded (another device's,
        // or the assistant's, brought by sync) is never written over: the
        // edits here are kept as a copy of their own beside it. Asked before
        // the text is taken, so nothing reported meanwhile is left out of
        // what's saved.
        let storedIsNewer = await Self.storedIsNewer(id: devotional.meta.id, than: baseLastModified)

        // If in visual edit mode, sync from visual editor first
        if mode == .edit && editMode == .visual {
            syncMarkdownFromVisualEditor()
        }

        guard syncBlocksFromMarkdown() else { return }
        let savedMarkdown = markdownContent

        if storedIsNewer {
            await keepBesideNewer()
            return
        }

        do {
            // Debug: Log media array before save
            print("[DevotionalView] Saving devotional '\(devotional.meta.title)' with \(devotional.media?.count ?? 0) media items")
            if let media = devotional.media {
                for ref in media {
                    print("[DevotionalView]   - Media: \(ref.id) -> \(ref.filename)")
                }
            }

            // The marks' carry takes its place in line before the save waits
            // on the database: a clear asked for meanwhile comes after it.
            let previous = persistedMarkdown
            let carry = showsReviewMarks ? WritingReviewWork.shared.reserveCarry(for: devotional.meta.id) : nil
            let written: Int?
            do {
                written = try await ModuleSyncManager.shared.saveDevotional(
                    devotional, moduleId: moduleId, ifNotNewerThan: baseLastModified
                )
            } catch {
                carry?.reservation.giveUp()
                throw error
            }
            // Newer by the time it was written: kept beside it instead.
            guard let committed = written else {
                carry?.reservation.giveUp()
                await keepBesideNewer()
                return
            }
            if let carry {
                if let previous { WritingReviewWork.shared.carry(carry, from: previous, to: savedMarkdown, savedAs: committed) } else { carry.reservation.giveUp() }
            }
            devotional.meta.lastModified = committed
            baseLastModified = committed
            persistedMarkdown = savedMarkdown
            if markdownContent == savedMarkdown { hasUnsavedChanges = false }
            lastSaveTime = Date()
            saveState = .saved
            print("[DevotionalView] Saved devotional: \(devotional.meta.title)")

            // Clear saved indicator after 3 seconds
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if saveState == .saved {
                    saveState = .idle
                }
            }

            // A restore owed for the writing is recorded if this text holds it.
            await WritingRestoreObligations.shared.settle(writingID: devotional.meta.id, saved: savedMarkdown)

            // Check sync status after save
            await checkSyncStatus()
        } catch {
            print("[DevotionalView] Failed to save: \(error)")
            saveState = .error
            // Don't crash - just log the error
            // User can try again or the next auto-save will retry
        }
    }

    /// The writing as stored is newer than the copy here (another device's,
    /// or the assistant's, brought by sync): the edits here are kept as a
    /// writing of their own beside it, never written over it.
    private func keepBesideNewer() async {
        // Nothing here unsaved (an autosave left queued after the edits
        // were saved): there's nothing to keep, and the newer version is
        // shown once it can be.
        guard hasUnsavedChanges else {
            saveState = .idle
            Task { @MainActor in await takeInNewerStoredCopy() }
            return
        }
        // Editing stops first and the editor is read once more, so
        // nothing typed while the copy is saved is left out of it.
        if mode == .edit {
            let live: String?
            let generation = documentGeneration
            if let coordinator = tiptapCoordinator {
                live = await Self.readPage(coordinator, leaving: { withAnimation { mode = .read } }, visual: editMode == .visual)
            } else {
                live = nil
                withAnimation { mode = .read }
            }
            if let live, live != markdownContent, isTyped(live), generation == documentGeneration {
                takingInStoredCopy = true
                markdownContent = live
                guard syncBlocksFromMarkdown() else { return }
            }
        }
        let kept = (devotional, markdownContent)
        guard let title = await Self.keepAsCopy(devotional, moduleId: moduleId) else {
            // Not kept: the edits stay here, unsaved, for the next try.
            saveState = .error
            return
        }
        keptEdits(as: title, holding: kept)
    }

    private func saveNowSync() {
        guard !isSaving else { return }
        isSaving = true

        // If in visual edit mode, sync from visual editor first
        if mode == .edit && editMode == .visual {
            syncMarkdownFromVisualEditor()
        }

        guard syncBlocksFromMarkdown() else {
            isSaving = false
            return
        }

        let base = baseLastModified
        let stamped = Int(Date().timeIntervalSince1970)
        devotional.meta.lastModified = stamped
        lastSaveTime = Date()
        let previous = persistedMarkdown
        persistedMarkdown = markdownContent
        // In line before the write, as a save's carry always is.
        let carry = showsReviewMarks ? WritingReviewWork.shared.reserveCarry(for: devotional.meta.id) : nil

        // A detached write, so it finishes even if the view goes; kept, so
        // what depends on it (asking the assistant) can wait for it. A newer
        // copy stored meanwhile is kept, and these edits saved beside it.
        let devToSave = devotional
        let keptMarkdown = markdownContent
        let modId = moduleId
        let earlier = inFlightWrite
        inFlightWrite = Task.detached {
            // Judged against what the write before it stored, if it did: this
            // device's own save is no change from elsewhere.
            var base = base
            if case .saved(let revision)? = await earlier?.value { base = max(base ?? revision, revision) }
            // Stored as `stamped` unless what's stored is newer, checked as
            // it's written; only then is it what the next save is judged
            // against.
            if await !Self.storedIsNewer(id: devToSave.meta.id, than: base) {
                do {
                    if let committed = try await ModuleSyncManager.shared.saveDevotional(
                        devToSave, moduleId: modId, ifNotNewerThan: base, at: stamped
                    ) {
                        await MainActor.run {
                            baseLastModified = max(baseLastModified ?? committed, committed)
                            if let carry {
                                if let previous { WritingReviewWork.shared.carry(carry, from: previous, to: keptMarkdown, savedAs: committed) } else { carry.reservation.giveUp() }
                            }
                            Task { await WritingRestoreObligations.shared.settle(writingID: devToSave.meta.id, saved: keptMarkdown) }
                        }
                        return .saved(committed)
                    }
                } catch {
                    carry?.reservation.giveUp()
                    print("[DevotionalView] Failed to save on disappear: \(error)")
                    await MainActor.run {
                        hasUnsavedChanges = true
                        saveState = .error
                    }
                    return .failed
                }
            }
            // Newer: these edits are kept beside it. Not this writing's
            // text, so its marks stay as they are.
            carry?.reservation.giveUp()
            guard let title = await Self.keepAsCopy(devToSave, moduleId: modId) else {
                // Not kept: still unsaved here, for the next try.
                await MainActor.run {
                    hasUnsavedChanges = true
                    saveState = .error
                }
                return .failed
            }
            await MainActor.run { keptEdits(as: title, holding: (devToSave, keptMarkdown)) }
            return .keptCopy
        }
        isSaving = false
        hasUnsavedChanges = false
    }

    /// The edits here went into a copy of their own, beside a newer version
    /// stored meanwhile: said, and the newer version shown in their place,
    /// editing left so no later save writes over it.
    ///
    /// `kept` is the writing and text the copy holds. Changed again since
    /// (editing taken up, or its details changed, while the copy saved),
    /// what's here stays, unsaved: the next save finds the newer version
    /// too, and keeps all of it as well.
    private func keptEdits(as title: String, holding kept: (writing: Devotional, markdown: String)) {
        keptEditsNotice = "This writing changed on another device or by the assistant while you edited it. Your edits were kept as “\(title)”."
        keptCopies += 1
        let unchanged = mode != .edit && markdownContent == kept.markdown && devotional == kept.writing
        if unchanged {
            hasUnsavedChanges = false
            saveTask?.cancel()
            saveTask = nil
            saveState = .idle
        } else {
            // What's shown isn't the writing's stored text, which is the
            // newer version: unsaved until a save keeps it too.
            persistedMarkdown = nil
            hasUnsavedChanges = true
        }
        Task { @MainActor in
            // Handled here either way, so later asks and saves don't take it
            // for a conflict still to come.
            let write = inFlightWrite
            _ = await write?.value
            if inFlightWrite == write { inFlightWrite = nil }
            if unchanged { await takeInNewerStoredCopy(regardless: true) }
        }
    }

    /// Whether text read from the page holds typing, not only the page's own
    /// way of writing the Markdown it was given: it's unlike the page as
    /// editing began, or the page has reported or saved edits since (an undo
    /// back to the start is typing too).
    private func isTyped(_ live: String) -> Bool {
        // The body, not the details: a title changed alone leaves the page as
        // it began, whose Markdown isn't the stored text's to replace.
        if markdownContent != persistedMarkdown || persistedMarkdown != persistedAtEditStart {
            return true
        }
        guard let editBaseline else { return false }
        return live != editBaseline
    }

    // MARK: - Review marks

    /// Whether the assistant's changes are marked here: the writer asked for
    /// it, AI is on, and the writing is one the assistant may change.
    private var showsReviewMarks: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ReviewMarksDemo") { return aiFeatures.isEnabled && writingIsEditable }
        #endif
        return aiFeatures.marksReviews && writingIsEditable
    }

    #if DEBUG
    /// For looking at the marks in the simulator, which has no Mac to make
    /// them: launch with `-ReviewMarksDemo YES`, and the second sentence of
    /// the writing's first long paragraph, or its last paragraph, reads as
    /// the assistant's.
    /// Two files and a kept copy beside the writing, as the Mac's workspace
    /// would hold them, for a look at the section.
    private func seedOtherFilesDemo() {
        let store = LibrarySyncPass.documentStore
        let id = devotional.meta.id
        guard (try? store.documents(writingID: id))?.isEmpty != false else { return }
        let outline = """
            # Outline

            1. The shepherd **knows** his sheep
               - by name (v. 3)
               - and leads them out
            2. The sheep *know* his voice
            3. Other sheep, one flock

            > I am the good shepherd. (John 10:11)

            ## Images

            | Image | Verse | Meaning |
            |:--|:--|:--|
            | Door | 10:7 | The only way in to the fold, and so to *life* |
            | Shepherd | 10:11 | One who lays down his life for the sheep, as a hired hand will not |

            ```
            John 10:11  ego eimi ho poimen ho kalos
            ```
            """
        _ = try? store.write(Data(outline.utf8), writingID: id, name: "outline.md", replacing: nil)
        _ = try? store.write(Data("John 10:1-18\nPsalm 23\nEzekiel 34".utf8), writingID: id, name: "sources.txt", replacing: nil)
        let copy = LampWritingWorkspaceLayout.keptCopyName(of: "outline.md", device: "iPhone", at: Date())
        _ = try? store.write(Data("# Outline\n\n1. The shepherd knows his own".utf8), writingID: id, name: copy, replacing: nil)
    }

    private func seedReviewMarksDemo() {
        let store = LibrarySyncPass.reviewStore
        let id = devotional.meta.id
        guard (try? store.review(writingID: id))?.isEmpty != false else { return }
        let text = markdownContent
        let paragraphs = text.components(separatedBy: "\n\n")
        let old: String
        if let paragraph = paragraphs.first(where: { $0.count > 80 && !$0.hasPrefix("#") }),
           let stop = paragraph.range(of: ". ") {
            old = text.replacingOccurrences(of: paragraph, with: String(paragraph[..<stop.lowerBound]) + ".")
        } else {
            // A short writing: its last paragraph is the assistant's.
            old = paragraphs.dropLast().joined(separator: "\n\n")
        }
        guard old != text else { return }
        try? store.save(LampWritingReview(writingID: id).markingAssistantChange(from: old, to: text))
    }
    #endif

    private struct ReviewFollowing: Equatable {
        let writingID: String
        let isShown: Bool
    }

    /// The page shows the session's marks and sends its clears and restores
    /// back, and takes in the text a restore works out.
    private func connectReviewMarks(to coordinator: TipTapEditorCoordinator) {
        coordinator.setReviewMarks(reviewSession.markedMarkdown, changes: reviewSession.markedChanges)
        reviewSession.onMarksChanged = { [weak coordinator] marked, changes in
            coordinator?.setReviewMarks(marked, changes: changes)
        }
        coordinator.onReviewClear = { [weak reviewSession] marked, pageText in
            reviewSession?.clear(markedMarkdown: marked, pageText: pageText)
        }
        coordinator.onReviewRestore = { [weak reviewSession] changeID, pageText in
            reviewSession?.restore(changeID: changeID, pageText: pageText)
        }
        reviewSession.applyRestore = { [weak coordinator] text, expected in
            guard let coordinator else { return nil }
            // A newer copy stored since this one was loaded would take the
            // save as a copy of its own beside it: the restore would never
            // reach this writing.
            guard await !Self.storedIsNewer(id: devotional.meta.id, than: baseLastModified) else { return nil }
            let generation = documentGeneration
            let restored = await withCheckedContinuation { continuation in
                coordinator.restoreWording(text, expecting: expected) { continuation.resume(returning: $0) }
            }
            // A newer copy put in place meanwhile (a turn's draft) isn't
            // written over by the text the restore was made in.
            guard documentGeneration == generation, let restored else { return nil }
            // Taken now, not when the page next reports its edits, so the
            // save made for it holds it.
            markdownContent = restored
            return restored
        }
        reviewSession.saveRestored = {
            // Its own save, after any in flight, which took the text before
            // the restore. One that fails is tried again a few times; one
            // kept as a copy beside a newer writing isn't.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                while isSaving { try? await Task.sleep(for: .milliseconds(50)) }
                hasUnsavedChanges = true
                await saveNow()
                if saveState != .error { return true }
            }
            return false
        }
        coordinator.onReviewMarksRejected = { [weak reviewSession] in
            reviewSession?.marksRejected()
        }
        coordinator.onReviewMarksStale = { [weak reviewSession] in
            reviewSession?.refreshMarks()
        }
    }

    /// How much is still to read, and the clears that don't need a
    /// paragraph's ✓: the selection, or everything. Markdown editing draws
    /// no marks, and says where they are.
    private var reviewControl: some View {
        Menu {
            if mode == .edit && editMode == .markdown {
                Section("Changes are marked in Visual") {
                    Button(action: { switchToVisualEdit() }) {
                        Label("Visual Edit", systemImage: "pencil")
                    }
                }
            } else {
                // Each selects the change it lands on, for the two below it.
                Section {
                    Button(action: { tiptapCoordinator?.goToReviewMark(forward: true) }) {
                        Label("Next Change", systemImage: "chevron.down")
                    }
                    Button(action: { tiptapCoordinator?.goToReviewMark(forward: false) }) {
                        Label("Previous Change", systemImage: "chevron.up")
                    }
                }
                Button(action: markSelectionAsReviewed) {
                    Label("Mark Selection as Reviewed", systemImage: "text.badge.checkmark")
                }
                // In editing, where the change it makes is saved.
                if mode == .edit && reviewSession.canRestore {
                    Button(action: restoreSelection) {
                        Label("Restore Original Wording", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            Button(action: { reviewSession.clearAll() }) {
                Label("Mark All as Reviewed", systemImage: "checkmark.circle")
            }
        } label: {
            // The count beside the mark: a bar's label shows its icon alone.
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                Text(reviewSession.count, format: .number)
                    .monospacedDigit()
            }
            .font(.body.weight(.semibold))
        }
        .accessibilityLabel(reviewSession.count == 1 ? "1 to Review" : "\(reviewSession.count) to Review")
        .accessibilityHint("Passages the assistant changed that you haven’t read yet")
    }

    private func markSelectionAsReviewed() {
        tiptapCoordinator?.reviewMarkdownForSelection { marked, pageText in
            guard let marked else { return }
            reviewSession.clear(markedMarkdown: marked, pageText: pageText)
        }
    }

    /// Puts back every change the selection touches, or none: by their ids,
    /// as the page has them, so a link round the selection doesn't widen it
    /// to a change beside it, and the record decides each, those the page
    /// stopped offering too. Touching none, it's said so, never asked about
    /// by the selection's range, which a link round it would widen to a
    /// change beside it. Where it touches a passage sent with no id, the
    /// range is asked about, for the record to say which no it is: that
    /// passage, touched either way, refuses the whole.
    private func restoreSelection() {
        tiptapCoordinator?.reviewChangesForSelection { ids, unnamed, caret, marked, pageText in
            if unnamed, let marked {
                reviewSession.restore(markedMarkdown: marked, pageText: pageText)
            } else if !ids.isEmpty {
                reviewSession.restore(changeID: ids, pageText: pageText)
            } else {
                reviewSession.refuseNothingSelected(caret: caret)
            }
        }
    }

    /// The page's text as editing ends, typing its debounced report hasn't
    /// brought yet included. Editing stops first, so nothing more is typed
    /// after; but Markdown editing is read before it stops, since stopping
    /// turns the page back to rich text, whose Markdown isn't what was
    /// typed (a fourth-level heading, a comment).
    @MainActor
    static func readPage(_ coordinator: TipTapEditorCoordinator, leaving: () -> Void, visual: Bool) async -> String? {
        func read() async -> String? {
            await withCheckedContinuation { continuation in
                coordinator.getContent { continuation.resume(returning: $0) }
            }
        }
        if visual {
            leaving()
            return await read()
        }
        let live = await read()
        leaving()
        return live
    }

    /// Whether the writing as stored is newer than `base`, the revision this
    /// copy began from. Read from the row itself: decoding a writing with no
    /// date gives it the time it was read, which would look newer every time.
    nonisolated static func storedIsNewer(id: String, than base: Int?) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard let entry = (try? ModuleDatabase.shared.getDevotionalEntry(id: id)).flatMap({ $0 }),
                  let stored = entry.lastModified else { return false }
            return stored > (base ?? 0)
        }.value
    }

    /// Saves `devotional` as a writing of its own, "(your edits)", with its
    /// media, beside a newer version of it. Returns its title, or nil when
    /// it couldn't be saved.
    nonisolated static func keepAsCopy(_ devotional: Devotional, moduleId: String) async -> String? {
        var copy = devotional
        copy.meta.id = UUID().uuidString
        copy.meta.title = devotional.meta.title + " (your edits)"
        copy.meta.lastModified = Int(Date().timeIntervalSince1970)
        let media = DevotionalMediaStorage.shared
        let from = media.mediaDirectory(devotionalId: devotional.meta.id, moduleId: moduleId)
        let to = media.mediaDirectory(devotionalId: copy.meta.id, moduleId: moduleId)
        do {
            // Its pictures and recordings go with it, or it isn't kept: a copy
            // whose media resolve to nothing isn't the edits.
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: from, to: to)
            }
            try await ModuleSyncManager.shared.saveDevotional(copy, moduleId: moduleId)
        } catch {
            print("[DevotionalView] Failed to keep edits as a copy: \(error)")
            try? FileManager.default.removeItem(at: to)
            return nil
        }
        return copy.meta.title
    }

    // MARK: - Preview Navigation

    /// Handle scripture tap by showing preview sheet with prev/next navigation
    private func handleScriptureTap(sv: Int, ev: Int?, translationId: String? = nil) {
        // Find matching item in allDevotionalItems for prev/next navigation
        if let matchingItem = allDevotionalItems.first(where: {
            if case .verse(let itemSv, let itemEv, _, _) = $0.type {
                return itemSv == sv && itemEv == ev
            }
            return false
        }) {
            // If translationId was passed directly, update the item with it
            let itemToUse: PreviewItem
            if let directTranslation = translationId, matchingItem.translationId == nil {
                // Create new item with the translation from the tap
                itemToUse = PreviewItem.verse(index: matchingItem.index, verseId: sv, endVerseId: ev, displayText: matchingItem.displayText, translationId: directTranslation)
            } else {
                itemToUse = matchingItem
            }
            // Use all verse items for prev/next navigation
            let verseItems = allDevotionalItems.filter {
                if case .verse = $0.type { return true }
                return false
            }
            previewState = PreviewSheetState(currentItem: itemToUse, allItems: verseItems.isEmpty ? [itemToUse] : verseItems)
        } else {
            // Fallback: create single item with translation if provided
            let displayText = formatVerseRangeReference(sv, endVerseId: ev)
            let item = PreviewItem.verse(index: 0, verseId: sv, endVerseId: ev, displayText: displayText, translationId: translationId)
            previewState = PreviewSheetState(currentItem: item, allItems: [item])
        }
    }

    /// Handle strongs tap by showing preview sheet with prev/next navigation
    private func handleStrongsTap(key: String) {
        // Find matching item in allDevotionalItems for prev/next navigation
        if let matchingItem = allDevotionalItems.first(where: {
            if case .strongs(let itemKey, _) = $0.type {
                return itemKey == key
            }
            return false
        }) {
            // Use all strongs items for prev/next navigation
            let strongsItems = allDevotionalItems.filter {
                if case .strongs = $0.type { return true }
                return false
            }
            previewState = PreviewSheetState(currentItem: matchingItem, allItems: strongsItems.isEmpty ? [matchingItem] : strongsItems)
        } else {
            // Fallback: create single item
            let item = PreviewItem.strongs(index: 0, key: key, displayText: key)
            previewState = PreviewSheetState(currentItem: item, allItems: [item])
        }
    }

    /// Handle link tap by parsing lampbible:// URLs and showing preview sheet
    private func handleLinkTap(url: URL) {
        // Parse the URL to determine type
        guard let lampbibleUrl = LampbibleURL.parse(url) else {
            // Unknown format - try to open as external URL
            UIApplication.shared.open(url)
            return
        }

        switch lampbibleUrl {
        case .verse(let verseId, let endVerseId, let translationId):
            handleScriptureTap(sv: verseId, ev: endVerseId, translationId: translationId)
        case .reading(let verseId, let endVerseId, _):
            handleScriptureTap(sv: verseId, ev: endVerseId, translationId: nil)
        case .strongs(let key):
            handleStrongsTap(key: key)
        case .writing(let id):
            openLinkedWriting(id: id)
        case .external(let externalUrl):
            UIApplication.shared.open(externalUrl)
        }
    }

    /// Opens the writing a link names, read off the main thread; a link to
    /// one no longer here does nothing.
    private func openLinkedWriting(id: String) {
        guard id != devotional.meta.id else { return }
        Task { linkedWriting = await LinkedWriting.load(id: id) }
    }

    /// Handle image tap to show full screen viewer
    private func handleImageTap(mediaRef: DevotionalMediaReference, imageURL: URL?) {
        guard let url = imageURL,
              let image = UIImage(contentsOfFile: url.path) else {
            return
        }

        // Find the caption from the block that references this media
        var caption: DevotionalAnnotatedText? = nil
        for block in devotional.contentBlocks {
            if block.type == .image, block.mediaId == mediaRef.id {
                caption = block.caption
                break
            }
        }

        fullScreenImageItem = FullScreenImageItem(image: image, caption: caption)
    }

    /// Handle image tap from TipTap editor (by mediaId)
    private func handleImageTapByMediaId(_ mediaId: String) {
        guard let mediaRef = devotional.media?.first(where: { $0.id == mediaId }) else { return }
        let url = DevotionalMediaStorage.shared.getMediaURL(
            for: mediaRef, devotionalId: devotional.meta.id, moduleId: moduleId
        )
        handleImageTap(mediaRef: mediaRef, imageURL: url)
    }

    /// Handle audio block tap from TipTap editor
    private func handleAudioBlockTap(_ mediaId: String) {
        guard let mediaRef = devotional.media?.first(where: { $0.id == mediaId }) else { return }
        if let url = DevotionalMediaStorage.shared.getMediaURL(
            for: mediaRef, devotionalId: devotional.meta.id, moduleId: moduleId
        ) {
            editorAudioPlayer.load(url: url)
            editorAudioPlayer.togglePlayback()
        }
    }

    /// Build a media map for the TipTap editor { mediaId: fileURL }
    private func buildMediaMap() -> [String: String] {
        guard let refs = devotional.media else { return [:] }
        var map: [String: String] = [:]
        for ref in refs {
            if let url = DevotionalMediaStorage.shared.getMediaURL(
                for: ref, devotionalId: devotional.meta.id, moduleId: moduleId
            ) {
                map[ref.id] = url.absoluteString
            }
        }
        return map
    }

    /// Format verse range for display text
    private func formatVerseRangeReference(_ sv: Int, endVerseId: Int?) -> String {
        let bookId = sv / 1000000
        let chapter = (sv % 1000000) / 1000
        let verse = sv % 1000

        let bookName = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name ?? "?"

        if let ev = endVerseId {
            let endVerse = ev % 1000
            if endVerse != verse {
                return "\(bookName) \(chapter):\(verse)-\(endVerse)"
            }
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    /// Format scripture URL in human-readable format: lampbible://gen1:1 or lampbible://gen1:1-5
    private func formatScriptureURL(verseId: Int, endVerseId: Int?) -> String {
        let bookId = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        // Get OSIS ID for the book (e.g., "Gen", "Exo")
        let osisId = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.osisId.lowercased() ?? "gen"

        if let ev = endVerseId {
            let endVerse = ev % 1000
            if endVerse != verse {
                return "lampbible://\(osisId)\(chapter):\(verse)-\(endVerse)"
            }
        }
        return "lampbible://\(osisId)\(chapter):\(verse)"
    }

    /// Parse all tappable items from devotional content for prev/next navigation
    private func parseDevotionalItems(from devotional: Devotional) -> [PreviewItem] {
        var items: [PreviewItem] = []
        var index = 0

        // Parse summary if present
        if let summary = devotional.summary {
            switch summary {
            case .plain:
                break // No annotations in plain text
            case .annotated(let annotated):
                parseDevotionalAnnotatedText(annotated, into: &items, index: &index)
            }
        }

        // Parse content blocks
        for block in devotional.content.allBlocks {
            if let content = block.content {
                parseDevotionalAnnotatedText(content, into: &items, index: &index)
            }
            // Parse list items
            if let listItems = block.items {
                parseDevotionalListItems(listItems, into: &items, index: &index)
            }
        }

        // Parse footnotes if present
        if let footnotes = devotional.footnotes {
            for footnote in footnotes {
                switch footnote.content {
                case .plain:
                    break
                case .annotated(let annotated):
                    parseDevotionalAnnotatedText(annotated, into: &items, index: &index)
                }
            }
        }

        return items
    }

    /// Parse annotations from a DevotionalAnnotatedText and add to items array
    private func parseDevotionalAnnotatedText(_ annotatedText: DevotionalAnnotatedText, into items: inout [PreviewItem], index: inout Int) {
        let text = annotatedText.text

        // If we have annotations, use them
        if let annotations = annotatedText.annotations, !annotations.isEmpty {
            let scalars = text.unicodeScalars

            for annotation in annotations {
                // Get display text from annotation range
                guard annotation.start >= 0, annotation.end > annotation.start,
                      annotation.start < scalars.count, annotation.end <= scalars.count else { continue }

                let startIdx = scalars.index(scalars.startIndex, offsetBy: annotation.start)
                let endIdx = scalars.index(scalars.startIndex, offsetBy: annotation.end)
                let startStringIdx = startIdx.samePosition(in: text) ?? text.startIndex
                let endStringIdx = endIdx.samePosition(in: text) ?? text.endIndex
                let displayText = String(text[startStringIdx..<endStringIdx])

                switch annotation.type {
                case .scripture:
                    if let sv = annotation.data?.sv {
                        let ev = annotation.data?.ev
                        // Check annotation data first, then text after annotation, then display text itself
                        let translationId = annotation.data?.translationId
                            ?? extractTranslationAfterAnnotation(text: text, annotationEnd: annotation.end)
                            ?? extractTranslationFromText(displayText)
                        items.append(PreviewItem.verse(index: index, verseId: sv, endVerseId: ev, displayText: displayText, translationId: translationId))
                        index += 1
                    }
                case .strongs:
                    if let key = annotation.data?.strongs {
                        items.append(PreviewItem.strongs(index: index, key: key, displayText: displayText))
                        index += 1
                    }
                default:
                    break
                }
            }
        } else {
            // No annotations - parse plain text for verse references
            let parser = VerseReferenceParser.shared
            let refs = parser.parse(text)
            for ref in refs {
                let verseId = ref.bookId * 1000000 + ref.chapter * 1000 + ref.startVerse
                let endVerseId = ref.endVerse.map { ref.bookId * 1000000 + ref.chapter * 1000 + $0 }
                // Check for translation after the reference in the original text
                let translationId = extractTranslationAfterReference(text: text, refRange: ref.range)
                items.append(PreviewItem.verse(index: index, verseId: verseId, endVerseId: endVerseId, displayText: ref.displayText, translationId: translationId))
                index += 1
            }
        }
    }

    /// Extract translation ID from display text like "Genesis 1:1 NIV" or "(John 3:16 ESV)"
    private func extractTranslationFromText(_ text: String) -> String? {
        // Get the last word after trimming
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: " ")
        guard components.count >= 2 else { return nil }

        // Strip punctuation (parentheses, periods, commas, etc.) from the last word
        let lastWord = String(components.last!)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .uppercased()
        return isKnownTranslation(lastWord)
    }

    /// Extract translation ID that appears after an annotation end position
    private func extractTranslationAfterAnnotation(text: String, annotationEnd: Int) -> String? {
        let scalars = text.unicodeScalars
        guard annotationEnd < scalars.count else { return nil }

        let endIdx = scalars.index(scalars.startIndex, offsetBy: annotationEnd)
        guard let endStringIdx = endIdx.samePosition(in: text) else { return nil }

        let afterAnnotation = String(text[endStringIdx...])
        let trimmed = afterAnnotation.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get the first word after the annotation by splitting on whitespace/newlines
        let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map { String($0) }
        guard let word = firstWord else { return nil }

        // Strip punctuation and check
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        return isKnownTranslation(cleaned)
    }

    /// Extract translation ID that appears after a verse reference in text
    private func extractTranslationAfterReference(text: String, refRange: Range<String.Index>) -> String? {
        // Look for text after the reference
        let afterRef = String(text[refRange.upperBound...])
        let trimmed = afterRef.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get the first word after the reference by splitting on whitespace/newlines
        let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map { String($0) }
        guard let word = firstWord else { return nil }

        // Remove any trailing punctuation
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        return isKnownTranslation(cleaned)
    }

    /// Check if a string is a known translation ID, returns the normalized ID if found
    private func isKnownTranslation(_ id: String) -> String? {
        // Common Bible translation abbreviations
        let knownTranslations: Set<String> = [
            "NIV", "ESV", "KJV", "NKJV", "NLT", "NASB", "NASB95", "NASB20",
            "CSB", "HCSB", "RSV", "NRSV", "ASV", "AMP", "MSG", "NET", "NCV",
            "CEV", "GNT", "GNB", "TEV", "TLB", "PHILLIPS", "WEB", "YLT",
            "DARBY", "DRB", "ERV", "EXB", "GW", "ICB", "ISV", "JUB", "LEB",
            "MEV", "MOUNCE", "NABRE", "NIRV", "NIVUK", "OJB", "RGT", "TPT",
            "VOICE", "WE", "WYC", "BSB", "LSB", "NRSVUE"
        ]

        // Check exact match first
        if knownTranslations.contains(id) {
            return id
        }

        // Check if it's a plural form (e.g., "KJVs", "BSBs")
        if id.hasSuffix("S"), id.count > 1 {
            let singular = String(id.dropLast())
            if knownTranslations.contains(singular) {
                return singular
            }
        }

        return nil
    }

    /// Parse list items recursively for annotations
    private func parseDevotionalListItems(_ listItems: [DevotionalListItem], into items: inout [PreviewItem], index: inout Int) {
        for item in listItems {
            parseDevotionalAnnotatedText(item.content, into: &items, index: &index)
            if let children = item.children {
                parseDevotionalListItems(children, into: &items, index: &index)
            }
        }
    }

    // MARK: - Sync Status

    @MainActor
    private func checkSyncStatus() async {
        let fileName = "\(moduleId).lamp"
        if let storage = SyncCoordinator.shared.activeStorage {
            syncIsOff = false
            syncStatus = await storage.getSyncStatus(type: .devotional, fileName: fileName)
        } else {
            syncIsOff = true
            syncStatus = .notAvailable
        }
    }

    private func startSyncStatusPolling() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await checkSyncStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private var syncStatusPopoverContent: some View {
        HStack {
            let backendName = SyncCoordinator.shared.settings.backend.displayName
            switch syncStatus {
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(.green)
                Text("Synced to \(backendName)")
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(.secondary)
                Text("Syncing...")
            case .notSynced:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text("Waiting to sync")
            case .notAvailable:
                if syncIsOff {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.secondary)
                    Text("Sync is off. This writing is saved on this device.")
                } else {
                    Image(systemName: "xmark.icloud")
                        .foregroundStyle(.red)
                    Text("Sync unavailable")
                }
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Link Editor Sheet

/// A passage picker's book list and chapter and verse counts, each read once
/// and kept for as long as the sheet holding it is up. Pickers ask for these
/// with every render, and a render comes with every keystroke in the sheet.
@MainActor
final class PassageShapeMemo {
    private var cachedBooks: [(id: Int, name: String)]?
    private var chapterCounts: [String: Int] = [:]
    private var verseCounts: [String: Int] = [:]

    var books: [(id: Int, name: String)] {
        if let cachedBooks { return cachedBooks }
        let books = (try? BundledModuleDatabase.shared.getAllBooks())?.map { ($0.id, $0.name) } ?? []
        cachedBooks = books
        return books
    }

    func chapters(translationId: String, book: Int) -> [Int] {
        let key = "\(translationId)|\(book)"
        let count = chapterCounts[key] ?? {
            let count = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: book)) ?? 50
            chapterCounts[key] = count
            return count
        }()
        return Array(1...max(1, count))
    }

    func verses(translationId: String, book: Int, chapter: Int) -> [Int] {
        let key = "\(translationId)|\(book)|\(chapter)"
        let count = verseCounts[key] ?? {
            let count = (try? TranslationDatabase.shared.getVerseCount(translationId: translationId, book: book, chapter: chapter)) ?? 30
            verseCounts[key] = count
            return count
        }()
        return Array(1...max(1, count))
    }
}

struct LinkEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedText: String
    let onSave: (LinkType) -> Void
    let onCancel: () -> Void

    enum LinkType {
        case url(String)
        case scripture(verseId: Int, endVerseId: Int?)
        case strongs(key: String)
    }

    enum LinkMode: String, CaseIterable {
        case url = "URL"
        case scripture = "Scripture"
        case strongs = "Strong's"
    }

    @State private var linkMode: LinkMode = .scripture
    @State private var urlText: String = ""
    @State private var strongsKey: String = ""

    // Scripture picker state
    @State private var detectedReference: ParsedVerseReference?
    @State private var selectedBook: Int = 1
    @State private var selectedChapter: Int = 1
    @State private var selectedStartVerse: Int = 1
    @State private var selectedEndVerse: Int? = nil
    @State private var useEndVerse: Bool = false
    /// The pickers' books and counts, each read once while the sheet is up
    /// rather than with every render (a keystroke in the URL field is one).
    @State private var shape = PassageShapeMemo()

    private var books: [(id: Int, name: String)] { shape.books }

    private var chapters: [Int] {
        // Use a default translation to get chapter count
        let translationId = UserDatabase.shared.getSettings().readerTranslation
        return shape.chapters(translationId: translationId, book: selectedBook)
    }

    private var verses: [Int] {
        let translationId = UserDatabase.shared.getSettings().readerTranslation
        return shape.verses(translationId: translationId, book: selectedBook, chapter: selectedChapter)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Selected text: \"\(selectedText)\"")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Section("Link Type") {
                    Picker("Type", selection: $linkMode) {
                        ForEach(LinkMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch linkMode {
                case .url:
                    Section("URL") {
                        TextField("https://example.com", text: $urlText)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }

                case .scripture:
                    if let detected = detectedReference {
                        Section("Detected Reference") {
                            HStack {
                                Text(detected.displayText)
                                Spacer()
                                Button("Use This") {
                                    saveDetectedReference(detected)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    Section("Or Select Manually") {
                        Picker("Book", selection: $selectedBook) {
                            ForEach(books, id: \.id) { book in
                                Text(book.name).tag(book.id)
                            }
                        }

                        Picker("Chapter", selection: $selectedChapter) {
                            ForEach(chapters, id: \.self) { chapter in
                                Text("\(chapter)").tag(chapter)
                            }
                        }

                        Picker("Start Verse", selection: $selectedStartVerse) {
                            ForEach(verses, id: \.self) { verse in
                                Text("\(verse)").tag(verse)
                            }
                        }

                        Toggle("Include End Verse", isOn: $useEndVerse)

                        if useEndVerse {
                            Picker("End Verse", selection: Binding(
                                get: { selectedEndVerse ?? selectedStartVerse },
                                set: { selectedEndVerse = $0 }
                            )) {
                                ForEach(verses.filter { $0 >= selectedStartVerse }, id: \.self) { verse in
                                    Text("\(verse)").tag(verse)
                                }
                            }
                        }
                    }

                case .strongs:
                    Section("Strong's Number") {
                        TextField("G1234 or H5678", text: $strongsKey)
                            .autocapitalization(.allCharacters)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Add Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saveLink()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                detectReference()
            }
            .onChange(of: selectedBook) { _, _ in
                // Reset chapter and verse when book changes
                selectedChapter = 1
                selectedStartVerse = 1
                selectedEndVerse = nil
            }
            .onChange(of: selectedChapter) { _, _ in
                // Reset verse when chapter changes
                selectedStartVerse = 1
                selectedEndVerse = nil
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isValid: Bool {
        switch linkMode {
        case .url:
            return !urlText.isEmpty && URL(string: urlText) != nil
        case .scripture:
            return true // Manual picker always has valid selection
        case .strongs:
            return !strongsKey.isEmpty && (strongsKey.hasPrefix("G") || strongsKey.hasPrefix("H"))
        }
    }

    private func detectReference() {
        let parser = VerseReferenceParser.shared
        let refs = parser.parse(selectedText)
        if let first = refs.first {
            detectedReference = first
            // Also set the picker to match
            selectedBook = first.bookId
            selectedChapter = first.chapter
            selectedStartVerse = first.startVerse
            if let end = first.endVerse {
                useEndVerse = true
                selectedEndVerse = end
            }
        }
    }

    private func saveDetectedReference(_ ref: ParsedVerseReference) {
        let verseId = ref.bookId * 1000000 + ref.chapter * 1000 + ref.startVerse
        let endVerseId = ref.endVerse.map { ref.bookId * 1000000 + ref.chapter * 1000 + $0 }
        onSave(.scripture(verseId: verseId, endVerseId: endVerseId))
    }

    private func saveLink() {
        switch linkMode {
        case .url:
            var url = urlText
            if !url.contains("://") {
                url = "https://" + url
            }
            onSave(.url(url))

        case .scripture:
            let verseId = selectedBook * 1000000 + selectedChapter * 1000 + selectedStartVerse
            let endVerseId: Int?
            if useEndVerse, let ev = selectedEndVerse, ev > selectedStartVerse {
                endVerseId = selectedBook * 1000000 + selectedChapter * 1000 + ev
            } else {
                endVerseId = nil
            }
            onSave(.scripture(verseId: verseId, endVerseId: endVerseId))

        case .strongs:
            onSave(.strongs(key: strongsKey.uppercased()))
        }
    }
}

// MARK: - Footnote Editor Sheet

struct FootnoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var footnoteContent: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Footnote Content") {
                    TextEditor(text: $footnoteContent)
                        .frame(minHeight: 100)
                        .focused($isTextFieldFocused)
                }

                Section {
                    Text("A footnote marker goes in at the cursor, and its note is added after the last of the document's notes. Notes are numbered in the order their markers first appear.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Footnote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(footnoteContent)
                    }
                    .disabled(footnoteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                isTextFieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Scripture Quote Sheet

struct ScriptureQuoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onInsert: (String, String) -> Void  // (citation, quotation)
    let onCancel: () -> Void

    // Translation picker
    @State private var selectedTranslationId: String = ""
    @State private var availableTranslations: [TranslationModule] = []

    // Start verse picker state
    @State private var startBook: Int = 1
    @State private var startChapter: Int = 1
    @State private var startVerse: Int = 1

    // End verse picker state
    @State private var endBook: Int = 1
    @State private var endChapter: Int = 1
    @State private var endVerse: Int = 1

    // Options
    @State private var includeVerseNumbers: Bool = false

    // Preview
    @State private var previewText: String = ""
    @State private var isLoadingPreview: Bool = false
    /// Counts the preview read each picker change; a later one drops an
    /// earlier read that finishes after it.
    @State private var previewGeneration: Int = 0
    /// The pickers' books and counts, each read once while the sheet is up
    /// rather than with every render.
    @State private var shape = PassageShapeMemo()

    private var books: [(id: Int, name: String)] { shape.books }

    private func chapters(for book: Int) -> [Int] {
        shape.chapters(translationId: selectedTranslationId, book: book)
    }

    private func verses(for book: Int, chapter: Int) -> [Int] {
        shape.verses(translationId: selectedTranslationId, book: book, chapter: chapter)
    }

    private func bookName(for bookId: Int) -> String {
        books.first { $0.id == bookId }?.name ?? "Genesis"
    }

    private var selectedTranslationAbbreviation: String {
        availableTranslations.first { $0.id == selectedTranslationId }?.abbreviation ?? selectedTranslationId.uppercased()
    }

    private var startRef: Int {
        startBook * 1000000 + startChapter * 1000 + startVerse
    }

    private var endRef: Int {
        endBook * 1000000 + endChapter * 1000 + endVerse
    }

    private var isValidRange: Bool {
        endRef >= startRef
    }

    /// Convert **n** markdown bold to styled AttributedString for preview
    private var styledPreviewText: AttributedString {
        var result = AttributedString()
        var currentText = previewText

        // Find all **text** patterns and convert to bold
        while let startRange = currentText.range(of: "**") {
            // Add text before **
            let beforeText = String(currentText[currentText.startIndex..<startRange.lowerBound])
            result.append(AttributedString(beforeText))

            // Find closing **
            let afterStart = currentText.index(startRange.upperBound, offsetBy: 0)
            let remaining = String(currentText[afterStart...])
            if let endRange = remaining.range(of: "**") {
                // Extract bold text
                let boldText = String(remaining[remaining.startIndex..<endRange.lowerBound])
                var boldAttr = AttributedString(boldText)
                boldAttr.font = .body.bold()
                result.append(boldAttr)

                // Continue after closing **
                let afterEnd = remaining.index(endRange.upperBound, offsetBy: 0)
                currentText = String(remaining[afterEnd...])
            } else {
                // No closing **, just add the rest as-is
                result.append(AttributedString(String(currentText[startRange.lowerBound...])))
                currentText = ""
            }
        }

        // Add any remaining text
        if !currentText.isEmpty {
            result.append(AttributedString(currentText))
        }

        return result
    }

    private var citation: String {
        let startBookName = bookName(for: startBook)
        let endBookName = bookName(for: endBook)
        let abbrev = selectedTranslationAbbreviation

        if startBook == endBook {
            // Same book
            if startChapter == endChapter {
                // Same chapter
                if startVerse == endVerse {
                    // Single verse
                    return "\(startBookName) \(startChapter):\(startVerse) \(abbrev)"
                } else {
                    // Verse range in same chapter
                    return "\(startBookName) \(startChapter):\(startVerse)-\(endVerse) \(abbrev)"
                }
            } else {
                // Different chapters in same book
                return "\(startBookName) \(startChapter):\(startVerse)-\(endChapter):\(endVerse) \(abbrev)"
            }
        } else {
            // Different books
            return "\(startBookName) \(startChapter):\(startVerse) - \(endBookName) \(endChapter):\(endVerse) \(abbrev)"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Translation") {
                    Picker("Translation", selection: $selectedTranslationId) {
                        TranslationLanguageSections(translations: availableTranslations) { items in
                            ForEach(items, id: \.id) { translation in
                                Text("\(translation.abbreviation) - \(translation.name)").tag(translation.id)
                            }
                        }
                    }
                }

                Section("Start Verse") {
                    Picker("Book", selection: $startBook) {
                        ForEach(books, id: \.id) { book in
                            Text(book.name).tag(book.id)
                        }
                    }

                    Picker("Chapter", selection: $startChapter) {
                        ForEach(chapters(for: startBook), id: \.self) { chapter in
                            Text("\(chapter)").tag(chapter)
                        }
                    }

                    Picker("Verse", selection: $startVerse) {
                        ForEach(verses(for: startBook, chapter: startChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }
                }

                Section("End Verse") {
                    Picker("Book", selection: $endBook) {
                        ForEach(books, id: \.id) { book in
                            Text(book.name).tag(book.id)
                        }
                    }

                    Picker("Chapter", selection: $endChapter) {
                        ForEach(chapters(for: endBook), id: \.self) { chapter in
                            Text("\(chapter)").tag(chapter)
                        }
                    }

                    Picker("Verse", selection: $endVerse) {
                        ForEach(verses(for: endBook, chapter: endChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }

                    if !isValidRange {
                        Text("End verse must be after start verse")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Options") {
                    Toggle("Include verse numbers", isOn: $includeVerseNumbers)
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(citation)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        if isLoadingPreview {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else if !isValidRange {
                            Text("Invalid verse range")
                                .foregroundColor(.secondary)
                                .italic()
                        } else if previewText.isEmpty {
                            Text("Select a passage to preview")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            // Render with bold verse numbers styled, not raw **
                            Text(styledPreviewText)
                                .font(.body)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Insert Scripture Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        onInsert(citation, previewText)
                    }
                    // While a new passage loads, the text shown is the last
                    // one's, which the citation no longer names.
                    .disabled(previewText.isEmpty || !isValidRange || isLoadingPreview)
                }
            }
            .task {
                await loadTranslations()
            }
            .onChange(of: selectedTranslationId) { _, _ in
                loadPreview()
            }
            .onChange(of: startBook) { _, newValue in
                startChapter = 1
                startVerse = 1
                // If end is before start, update end to match start
                if endBook < newValue {
                    endBook = newValue
                    endChapter = 1
                    endVerse = 1
                }
                loadPreview()
            }
            .onChange(of: startChapter) { _, newValue in
                startVerse = 1
                // If same book and end chapter is before start, update
                if startBook == endBook && endChapter < newValue {
                    endChapter = newValue
                    endVerse = 1
                }
                loadPreview()
            }
            .onChange(of: startVerse) { _, newValue in
                // If same book/chapter and end verse is before start, update
                if startBook == endBook && startChapter == endChapter && endVerse < newValue {
                    endVerse = newValue
                }
                loadPreview()
            }
            .onChange(of: endBook) { _, _ in
                endChapter = min(endChapter, chapters(for: endBook).last ?? 1)
                endVerse = min(endVerse, verses(for: endBook, chapter: endChapter).last ?? 1)
                loadPreview()
            }
            .onChange(of: endChapter) { _, _ in
                endVerse = min(endVerse, verses(for: endBook, chapter: endChapter).last ?? 1)
                loadPreview()
            }
            .onChange(of: endVerse) { _, _ in
                loadPreview()
            }
            .onChange(of: includeVerseNumbers) { _, _ in
                loadPreview()
            }
        }
        .presentationDetents([.large])
    }

    /// Every translation in both databases, so read off the main actor.
    private func loadTranslations() async {
        availableTranslations = await Task.detached(priority: .userInitiated) {
            (try? TranslationDatabase.shared.getAllTranslations()) ?? []
        }.value

        // Use default translation from settings
        let settings = UserDatabase.shared.getSettings()
        if availableTranslations.contains(where: { $0.id == settings.readerTranslation }) {
            selectedTranslationId = settings.readerTranslation
        } else if let first = availableTranslations.first {
            selectedTranslationId = first.id
        }

        loadPreview()
    }

    /// Reads the passage off the main actor: a range can run to whole
    /// chapters, and one picker change sets off several reads as the pickers
    /// below it reset. Only the latest read's text is shown.
    private func loadPreview() {
        previewGeneration &+= 1
        let generation = previewGeneration
        guard !selectedTranslationId.isEmpty, isValidRange else {
            previewText = ""
            isLoadingPreview = false
            return
        }

        isLoadingPreview = true
        let translationId = selectedTranslationId
        let startRef = self.startRef
        let endRef = self.endRef
        let includeVerseNumbers = self.includeVerseNumbers

        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String in
                do {
                    let verses = try TranslationDatabase.shared.getVerseRange(
                        translationId: translationId,
                        startRef: startRef,
                        endRef: endRef
                    )
                    if includeVerseNumbers {
                        // Include verse numbers as bold: **1** text **2** text
                        return verses.map { "**\($0.verse)** \($0.text)" }.joined(separator: " ")
                    } else {
                        // Join verse text without verse numbers
                        return verses.map { $0.text }.joined(separator: " ")
                    }
                } catch {
                    return "Error loading verses"
                }
            }.value
            guard generation == previewGeneration else { return }
            previewText = text
            isLoadingPreview = false
        }
    }
}

// MARK: - Metadata Editor Sheet

struct MetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var devotional: Devotional
    let onSave: () -> Void

    @State private var title: String = ""
    @State private var subtitle: String = ""
    @State private var author: String = ""
    @State private var date: Date = Date()
    @State private var category: String = ""
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Subtitle", text: $subtitle)
                    TextField("Author", text: $author)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    DevotionalCategoryField(category: $category)
                }

                Section("Tags") {
                    TextField("Tags (comma-separated)", text: $tagsText)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("Edit Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                }
            }
            .onAppear {
                loadValues()
            }
        }
    }

    private func loadValues() {
        title = devotional.meta.title
        subtitle = devotional.meta.subtitle ?? ""
        author = devotional.meta.author ?? ""
        category = devotional.meta.categoryName ?? ""
        tagsText = devotional.meta.tags?.joined(separator: ", ") ?? ""

        if let dateStr = devotional.meta.date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting
            if let parsedDate = formatter.date(from: dateStr) {
                date = parsedDate
            }
        }
    }

    private func saveChanges() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone.current  // Use local timezone to avoid date shifting

        let tags = tagsText.isEmpty ? nil : tagsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        devotional.meta.title = title
        devotional.meta.subtitle = subtitle.isEmpty ? nil : subtitle
        devotional.meta.author = author.isEmpty ? nil : author
        devotional.meta.date = formatter.string(from: date)
        devotional.meta.setCategory(fromField: category)
        devotional.meta.tags = tags
        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        onSave()
        dismiss()
    }
}

// MARK: - Flow Layout for Tags

struct DevotionalFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.origin.x,
                                               y: bounds.minY + frame.origin.y),
                                   proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

// MARK: - Helper Extensions

extension Devotional {
    var contentBlocks: [DevotionalContentBlock] {
        switch content {
        case .blocks(let blocks):
            return blocks
        case .structured(let structured):
            var blocks: [DevotionalContentBlock] = []
            if let intro = structured.introduction {
                blocks.append(contentsOf: intro)
            }
            // Flatten sections into blocks with headings
            if let sections = structured.sections {
                for section in sections {
                    blocks.append(contentsOf: flattenSection(section))
                }
            }
            if let conclusion = structured.conclusion {
                blocks.append(contentsOf: conclusion)
            }
            return blocks
        }
    }

    private func flattenSection(_ section: DevotionalSection) -> [DevotionalContentBlock] {
        var blocks: [DevotionalContentBlock] = []

        // Add section title as heading
        blocks.append(DevotionalContentBlock(
            type: .heading,
            content: DevotionalAnnotatedText(text: section.title),
            level: section.level ?? 2
        ))

        // Add section blocks
        if let sectionBlocks = section.blocks {
            blocks.append(contentsOf: sectionBlocks)
        }

        // Recursively add subsections
        if let subsections = section.subsections {
            for subsection in subsections {
                blocks.append(contentsOf: flattenSection(subsection))
            }
        }

        return blocks
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DevotionalView(
            devotional: Devotional(
                meta: DevotionalMeta(
                    id: "preview",
                    title: "Sample Devotional",
                    subtitle: "A reflection on faith",
                    author: "John Doe",
                    date: "2025-01-15",
                    tags: ["faith", "hope", "love"],
                    category: "devotional"
                ),
                content: .blocks([
                    DevotionalContentBlock(type: .paragraph, content: DevotionalAnnotatedText(text: "This is a sample devotional with some content."))
                ])
            ),
            moduleId: WritingCollection.id
        )
    }
}

// MARK: - Table Insert Sheet

struct TableInsertSheet: View {
    @Binding var rows: Int
    @Binding var cols: Int
    @Binding var headerRow: Bool
    let onInsert: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Stepper("Rows: \(rows)", value: $rows, in: 2...10)
                Stepper("Columns: \(cols)", value: $cols, in: 2...6)
                Toggle("Header Row", isOn: $headerRow)
            }
            .navigationTitle("Insert Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert", action: onInsert)
                }
            }
        }
    }
}

private extension View {
    /// Liquid Glass where the OS has it; before iOS 26 a quiet filled capsule.
    @ViewBuilder
    func formattingBarSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(Color(.secondarySystemBackground), in: Capsule())
        }
    }
}
