//
//  DevotionalView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

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

struct DevotionalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
    @State private var showingMetadataEditor: Bool = false
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

    // Preview sheet navigation (for scripture/strongs references)
    @State private var previewState: PreviewSheetState? = nil
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
        // Load present mode font multiplier from settings
        let settings = UserDatabase.shared.getSettings()
        _presentFontMultiplier = State(initialValue: CGFloat(settings.devotionalPresentFontMultiplier))

        // Debug: Log media when view opens
        print("[DevotionalView] Opening devotional '\(devotional.meta.title)' with \(devotional.media?.count ?? 0) media items")
        if let media = devotional.media {
            for ref in media {
                print("[DevotionalView]   - Media: \(ref.id) -> \(ref.filename)")
            }
        }
    }


    var body: some View {
        VStack(spacing: 0) {
            modeTopChrome
            tiptapWebView
        }
        .navigationTitle(mode == .present ? "" : devotional.meta.title)
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
        .sheet(isPresented: $showingMetadataEditor) {
            MetadataEditorSheet(devotional: $devotional) {
                scheduleAutoSave()
            }
        }
        .sheet(item: $previewState) { state in
            let itemTranslationId = state.currentItem.translationId
            let effectiveTranslationId = itemTranslationId ?? UserDatabase.shared.getSettings().readerTranslationId
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
        .onChange(of: mode) { oldMode, newMode in
            // When leaving edit mode, ensure content is saved
            if oldMode == .edit && newMode != .edit {
                // Stop sync polling
                syncPollingTask?.cancel()
                syncPollingTask = nil

                // If we were in visual mode, sync markdown from visual editor first
                if editMode == .visual {
                    syncMarkdownFromVisualEditor()
                }
                // Then sync blocks from markdown (works for both visual and markdown modes)
                syncBlocksFromMarkdown()
                if hasUnsavedChanges {
                    saveNowSync()
                }
            }

            // When entering edit mode, start sync status polling
            if newMode == .edit && oldMode != .edit {
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

    @ViewBuilder
    private var modeTopChrome: some View {
        switch mode {
        case .edit:
            if editMode == .visual {
                richTextFormattingToolbar
                Divider()
            }
        case .read:
            // Header is rendered inside TipTap WebView so it scrolls with content
            EmptyView()
        case .present:
            // No header in present mode
            EmptyView()
        }
    }

    @ViewBuilder
    private var readModeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(devotional.meta.title)
                .font(.title)
                .fontWeight(.bold)

            if let subtitle = devotional.meta.subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            // Metadata row
            HStack(spacing: 16) {
                if let date = devotional.meta.date {
                    Label(date, systemImage: "calendar")
                        .font(.caption)
                }
                if let author = devotional.meta.author {
                    Label(author, systemImage: "person")
                        .font(.caption)
                }
                if let category = devotional.meta.category {
                    Text(category.rawValue.capitalized)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .foregroundColor(.secondary)

            // Tags
            if let tags = devotional.meta.tags, !tags.isEmpty {
                DevotionalFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(8)
                    }
                }
            }

            // Key scriptures
            if let scriptures = devotional.meta.keyScriptures, !scriptures.isEmpty {
                HStack {
                    Image(systemName: "book")
                        .font(.caption)
                    ForEach(scriptures, id: \.sv) { scripture in
                        if let label = scripture.label {
                            Text(label)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }

            Divider()
        }
        .padding(.top, 12)
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
                onCoordinatorReady: { coordinator in
                    tiptapCoordinator = coordinator

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

                    // Set present padding if starting in present mode
                    if mode == .present {
                        let padding = geometry.size.height - presentFontSize - 96
                        coordinator.setPresentPadding(bottom: max(0, padding))
                    }
                }
            )
            .onChange(of: markdownContent) { _, _ in
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
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }

    // MARK: - Content Sync

    private func syncMarkdownFromBlocks() {
        markdownContent = MarkdownDevotionalConverter.contentToMarkdown(devotional)
    }

    private func syncBlocksFromMarkdown() {
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)
        // Also parse footnotes from markdown
        devotional.footnotes = MarkdownDevotionalConverter.parseFootnotes(from: markdownContent)
    }

    /// Sync markdown from visual editor - TipTap handles this via contentChanged messages,
    /// so this is a no-op (content is already synced via the binding).
    private func syncMarkdownFromVisualEditor() {
        // No-op: TipTap editor syncs markdown content automatically via the binding
    }

    private var richTextFormattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Text style menu
                Menu {
                    Button("Paragraph") { tiptapCoordinator?.applyStyle(.paragraph) }
                    Button("Heading 1") { tiptapCoordinator?.applyStyle(.heading1) }
                    Button("Heading 2") { tiptapCoordinator?.applyStyle(.heading2) }
                    Button("Heading 3") { tiptapCoordinator?.applyStyle(.heading3) }
                } label: {
                    formattingButton(icon: "textformat.size", label: "Aa")
                }

                Divider().frame(height: 24)

                // Bold
                Button(action: { tiptapCoordinator?.applyStyle(.bold) }) {
                    formattingButton(icon: "bold", label: nil)
                }

                // Italic
                Button(action: { tiptapCoordinator?.applyStyle(.italic) }) {
                    formattingButton(icon: "italic", label: nil)
                }

                Divider().frame(height: 24)

                // Bullet list
                Button(action: { tiptapCoordinator?.applyStyle(.bullet) }) {
                    formattingButton(icon: "list.bullet", label: nil)
                }

                // Numbered list
                Button(action: { tiptapCoordinator?.applyStyle(.numberedList) }) {
                    formattingButton(icon: "list.number", label: nil)
                }

                // Decrease indent
                Button(action: { tiptapCoordinator?.applyStyle(.outdent) }) {
                    formattingButton(icon: "decrease.indent", label: nil)
                }

                // Increase indent
                Button(action: { tiptapCoordinator?.applyStyle(.indent) }) {
                    formattingButton(icon: "increase.indent", label: nil)
                }

                Divider().frame(height: 24)

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

                Divider().frame(height: 24)

                // Horizontal rule
                Button(action: { tiptapCoordinator?.insertHorizontalRule() }) {
                    formattingButton(icon: "minus", label: nil)
                }

                // Table
                Button(action: { showingTableInsert = true }) {
                    formattingButton(icon: "tablecells", label: nil)
                }

                Divider().frame(height: 24)

                // Link
                Button(action: { openLinkEditor() }) {
                    formattingButton(icon: "link", label: nil)
                }

                // Remove link
                Button(action: { tiptapCoordinator?.removeLink() }) {
                    formattingButton(icon: "link.badge.minus", label: nil)
                }

                // Footnote
                Button(action: { openFootnoteEditor() }) {
                    formattingButton(icon: "note.text", label: nil)
                }

                Divider().frame(height: 24)

                // Media insertion menu
                Menu {
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
                    formattingButton(icon: "photo.badge.plus", label: nil)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
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
                .font(.system(size: 16))
            if let label = label {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundColor(.primary)
        .frame(width: label != nil ? 44 : 36, height: 36)
        .background(Color(.systemBackground))
        .cornerRadius(6)
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
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
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
                }

                // Sync status (edit mode only)
                if mode == .edit {
                    Button {
                        showingSyncStatusPopover = true
                    } label: {
                        switch syncStatus {
                        case .synced:
                            Image(systemName: "checkmark.icloud.fill")
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
                    .popover(isPresented: $showingSyncStatusPopover) {
                        syncStatusPopoverContent
                    }
                }

                // Share
                Menu {
                    Button(action: shareDevotional) {
                        Label("Share Devotional File", systemImage: "doc")
                    }
                    ShareLink("Share as Markdown", item: markdownContent)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }

        // Bottom toolbar with single mode button (hidden in present mode)
        if mode != .present {
            ToolbarItem(placement: .bottomBar) {
                Spacer()
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
                        Label("Visual Edit", systemImage: "eye")
                    }
                    Divider()
                    Button(action: { showingMetadataEditor = true }) {
                        Label("Edit Metadata", systemImage: "info")
                    }
                } label: {
                    Image(systemName: modeIcon)
                        .font(.body.weight(.semibold))
                }
            }
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

    private var modeIcon: String {
        switch mode {
        case .present: return "rectangle.expand.vertical"
        case .read: return "book"
        case .edit:
            return editMode == .visual ? "eye" : "chevron.left.forwardslash.chevron.right"
        }
    }

    private var modeLabel: String {
        switch mode {
        case .present: return "Present"
        case .read: return "Read"
        case .edit: return editMode == .visual ? "Visual" : "Markdown"
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

        // If in visual edit mode, sync from visual editor first
        if mode == .edit && editMode == .visual {
            syncMarkdownFromVisualEditor()
        }

        // Store markdown directly (preferred over converting to blocks)
        devotional.markdownContent = markdownContent

        // Also update blocks for searchText computation (but markdown is source of truth)
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)
        devotional.footnotes = MarkdownDevotionalConverter.parseFootnotes(from: markdownContent)

        // Update lastModified timestamp
        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        do {
            // Debug: Log media array before save
            print("[DevotionalView] Saving devotional '\(devotional.meta.title)' with \(devotional.media?.count ?? 0) media items")
            if let media = devotional.media {
                for ref in media {
                    print("[DevotionalView]   - Media: \(ref.id) -> \(ref.filename)")
                }
            }

            // Use ModuleSyncManager to save and export to iCloud
            try await ModuleSyncManager.shared.saveDevotional(devotional, moduleId: moduleId)
            hasUnsavedChanges = false
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

            // Check sync status after save
            await checkSyncStatus()
        } catch {
            print("[DevotionalView] Failed to save: \(error)")
            saveState = .error
            // Don't crash - just log the error
            // User can try again or the next auto-save will retry
        }
    }

    private func saveNowSync() {
        guard !isSaving else { return }
        isSaving = true

        // If in visual edit mode, sync from visual editor first
        if mode == .edit && editMode == .visual {
            syncMarkdownFromVisualEditor()
        }

        // Store markdown directly (preferred over converting to blocks)
        devotional.markdownContent = markdownContent

        // Also update blocks for searchText computation (but markdown is source of truth)
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)
        devotional.footnotes = MarkdownDevotionalConverter.parseFootnotes(from: markdownContent)

        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        // Use detached task so cloud sync continues even if view is dismissed
        let devToSave = devotional
        let modId = moduleId
        Task.detached {
            do {
                try await ModuleSyncManager.shared.saveDevotional(devToSave, moduleId: modId)
            } catch {
                print("[DevotionalView] Failed to save on disappear: \(error)")
            }
        }
        isSaving = false
        hasUnsavedChanges = false
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
        case .external(let externalUrl):
            UIApplication.shared.open(externalUrl)
        }
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
            syncStatus = await storage.getSyncStatus(type: .devotional, fileName: fileName)
        } else {
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
                Image(systemName: "xmark.icloud")
                    .foregroundStyle(.red)
                Text("Sync unavailable")
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }
}

// MARK: - Link Editor Sheet

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

    private var books: [(id: Int, name: String)] {
        (try? BundledModuleDatabase.shared.getAllBooks())?.map { ($0.id, $0.name) } ?? []
    }

    private var chapters: [Int] {
        // Use a default translation to get chapter count
        let translationId = UserDatabase.shared.getSettings().readerTranslationId
        let count = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: selectedBook)) ?? 50
        return Array(1...max(1, count))
    }

    private var verses: [Int] {
        let translationId = UserDatabase.shared.getSettings().readerTranslationId
        let count = (try? TranslationDatabase.shared.getVerseCount(translationId: translationId, book: selectedBook, chapter: selectedChapter)) ?? 30
        return Array(1...max(1, count))
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
                                    .foregroundColor(.accentColor)
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
                    Text("A footnote reference will be inserted at the cursor position, and the footnote content will be added to the footnotes section at the bottom of the document.")
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

    private var books: [(id: Int, name: String)] {
        (try? BundledModuleDatabase.shared.getAllBooks())?.map { ($0.id, $0.name) } ?? []
    }

    private func chapters(for book: Int) -> [Int] {
        let count = (try? TranslationDatabase.shared.getChapterCount(translationId: selectedTranslationId, book: book)) ?? 50
        return Array(1...max(1, count))
    }

    private func verses(for book: Int, chapter: Int) -> [Int] {
        let count = (try? TranslationDatabase.shared.getVerseCount(translationId: selectedTranslationId, book: book, chapter: chapter)) ?? 30
        return Array(1...max(1, count))
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
                        ForEach(availableTranslations, id: \.id) { translation in
                            Text("\(translation.abbreviation) - \(translation.name)").tag(translation.id)
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
                    .disabled(previewText.isEmpty || !isValidRange)
                }
            }
            .onAppear {
                loadTranslations()
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

    private func loadTranslations() {
        availableTranslations = (try? TranslationDatabase.shared.getAllTranslations()) ?? []

        // Use default translation from settings
        let settings = UserDatabase.shared.getSettings()
        if availableTranslations.contains(where: { $0.id == settings.readerTranslationId }) {
            selectedTranslationId = settings.readerTranslationId
        } else if let first = availableTranslations.first {
            selectedTranslationId = first.id
        }

        loadPreview()
    }

    private func loadPreview() {
        guard !selectedTranslationId.isEmpty, isValidRange else {
            previewText = ""
            return
        }

        isLoadingPreview = true

        Task {
            do {
                let verses = try TranslationDatabase.shared.getVerseRange(
                    translationId: selectedTranslationId,
                    startRef: startRef,
                    endRef: endRef
                )

                let text: String
                if includeVerseNumbers {
                    // Include verse numbers as bold: **1** text **2** text
                    text = verses.map { "**\($0.verse)** \($0.text)" }.joined(separator: " ")
                } else {
                    // Join verse text without verse numbers
                    text = verses.map { $0.text }.joined(separator: " ")
                }

                await MainActor.run {
                    previewText = text
                    isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    previewText = "Error loading verses"
                    isLoadingPreview = false
                }
            }
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
    @State private var category: DevotionalCategory = .devotional
    @State private var tagsText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Subtitle", text: $subtitle)
                    TextField("Author", text: $author)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Category", selection: $category) {
                        ForEach(DevotionalCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue.capitalized).tag(cat)
                        }
                    }
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
        category = devotional.meta.category ?? .devotional
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
        devotional.meta.category = category
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
                    category: .devotional
                ),
                content: .blocks([
                    DevotionalContentBlock(type: .paragraph, content: DevotionalAnnotatedText(text: "This is a sample devotional with some content."))
                ])
            ),
            moduleId: "devotionals"
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
