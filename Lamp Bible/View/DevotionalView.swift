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

// MARK: - Main View

struct DevotionalView: View {
    @Environment(\.dismiss) private var dismiss

    // Configuration
    let initialDevotional: Devotional
    let moduleId: String
    var onBack: (() -> Void)?
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

    enum DevotionalSaveState {
        case idle
        case saving
        case saved
        case error
    }

    init(devotional: Devotional, moduleId: String, initialMode: DevotionalViewMode = .read, onBack: (() -> Void)? = nil) {
        self.initialDevotional = devotional
        self.moduleId = moduleId
        self.onBack = onBack
        self.initialMode = initialMode
        _devotional = State(initialValue: devotional)
        _mode = State(initialValue: initialMode)
        _markdownContent = State(initialValue: MarkdownDevotionalConverter.blocksToMarkdown(
            devotional.contentBlocks
        ))
        // Load present mode font multiplier from settings
        let settings = UserDatabase.shared.getSettings()
        _presentFontMultiplier = State(initialValue: CGFloat(settings.devotionalPresentFontMultiplier))
    }

    var body: some View {
        ZStack {
            switch mode {
            case .present:
                presentModeView
            case .read:
                readModeView
            case .edit:
                editModeView
            }
        }
        .navigationTitle(mode == .present ? "" : devotional.meta.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(mode == .present)
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
        }
    }

    // MARK: - Present Mode

    private var presentModeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: presentLineSpacing) {
                // Title - same size as body in present mode
                Text(devotional.meta.title)
                    .font(.system(size: presentFontSize, weight: .bold))
                    .padding(.bottom, 20)

                // Content
                DevotionalContentRenderer(
                    content: devotional.content,
                    style: presentStyle
                )
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
        }
    }

    private var presentFontSize: CGFloat {
        fontSize * presentFontMultiplier
    }

    private var presentLineSpacing: CGFloat {
        fontSize * 1.5  // Comfortable line spacing
    }

    private var presentStyle: DevotionalRendererStyle {
        var style = DevotionalRendererStyle.default
        // Consistent font size for everything
        style.bodyFont = .system(size: presentFontSize)
        style.uiBodyFont = UIFont.systemFont(ofSize: presentFontSize)
        style.blockquoteFont = .system(size: presentFontSize)
        style.listItemFont = .system(size: presentFontSize)
        // Override heading fonts to be same size as body
        style.headingFonts = [
            1: .system(size: presentFontSize, weight: .bold),
            2: .system(size: presentFontSize, weight: .bold),
            3: .system(size: presentFontSize, weight: .bold),
            4: .system(size: presentFontSize, weight: .bold),
            5: .system(size: presentFontSize, weight: .bold),
            6: .system(size: presentFontSize, weight: .bold)
        ]
        style.lineSpacing = presentFontSize * 0.5
        style.paragraphSpacing = presentFontSize * 0.8
        style.headingSpacing = presentFontSize * 0.8  // Same as paragraph
        style.listItemSpacing = presentFontSize * 0.3
        style.isPresentMode = true  // Remove indentation
        return style
    }

    // MARK: - Read Mode

    private var readModeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
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
                }
                .padding(.bottom, 16)

                Divider()

                // Summary
                if let summary = devotional.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        switch summary {
                        case .plain(let text):
                            Text(text)
                                .font(.system(size: fontSize))
                        case .annotated(let annotated):
                            DevotionalAnnotatedTextView(annotated, style: readStyle)
                        }
                    }
                    .padding(.vertical, 8)

                    Divider()
                }

                // Content
                DevotionalContentRenderer(
                    content: devotional.content,
                    style: readStyle,
                    onScriptureTap: { sv, ev in
                        // TODO: Navigate to verse
                        print("Scripture tap: \(sv) - \(ev ?? 0)")
                    },
                    onStrongsTap: { key in
                        // TODO: Show Strong's
                        print("Strong's tap: \(key)")
                    }
                )

                // Footnotes
                if let footnotes = devotional.footnotes, !footnotes.isEmpty {
                    Divider()
                        .padding(.vertical, 8)

                    DevotionalFootnotesView(
                        footnotes: footnotes,
                        style: readStyle,
                        onScriptureTap: nil,
                        onStrongsTap: nil
                    )
                }
            }
            .padding()
        }
    }

    private var readStyle: DevotionalRendererStyle {
        var style = DevotionalRendererStyle.default
        style.bodyFont = .system(size: fontSize)
        style.uiBodyFont = UIFont.systemFont(ofSize: fontSize)
        style.lineSpacing = fontSize * 0.5
        style.paragraphSpacing = fontSize * 0.8
        style.headingSpacing = fontSize * 1.2
        style.listItemSpacing = 4  // Tight spacing between list items
        return style
    }

    // MARK: - Edit Mode

    private var editModeView: some View {
        ZStack(alignment: .bottomTrailing) {
            if editMode == .visual {
                visualEditView
            } else {
                markdownEditView
            }

            // FAB for toggling Visual/Markdown
            Button(action: toggleEditMode) {
                HStack(spacing: 6) {
                    Image(systemName: editMode == .visual ? "chevron.left.forwardslash.chevron.right" : "eye")
                        .font(.body)
                    Text(editMode == .visual ? "MD" : "Visual")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
        // NOTE: Removed syncMarkdownFromBlocks() from onAppear
        // The init() already sets markdownContent from blocks.
        // Calling it again here could overwrite user's fixes with stale data.
    }

    @State private var richTextCoordinator: RichTextEditor.Coordinator?
    @State private var visualEditorRefreshId = UUID()

    private var visualEditView: some View {
        VStack(spacing: 0) {
            richTextFormattingToolbar
            Divider()

            RichTextEditor(
                text: $markdownContent,
                fontSize: fontSize,
                onCoordinatorReady: { coordinator in
                    richTextCoordinator = coordinator
                }
            )
            .id(visualEditorRefreshId)  // Force recreate when switching from markdown mode
            .onChange(of: markdownContent) { _, _ in
                hasUnsavedChanges = true
                scheduleAutoSave()
            }
        }
    }

    private var markdownEditView: some View {
        TextEditor(text: $markdownContent)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal)
            .padding(.top, 8)
            .onChange(of: markdownContent) { _, _ in
                hasUnsavedChanges = true
                scheduleAutoSave()
            }
    }

    // MARK: - Content Sync

    private func syncMarkdownFromBlocks() {
        markdownContent = MarkdownDevotionalConverter.blocksToMarkdown(devotional.contentBlocks)
    }

    private func syncBlocksFromMarkdown() {
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)
    }

    /// Sync markdown from visual editor using the coordinator's stored attributed string
    private func syncMarkdownFromVisualEditor() {
        guard let coordinator = richTextCoordinator,
              let attrString = coordinator.currentAttributedString else {
            return
        }
        markdownContent = coordinator.attributedStringToMarkdown(attrString)
    }

    private var richTextFormattingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Text style menu
                Menu {
                    Button("Paragraph") { richTextCoordinator?.applyStyle(.paragraph) }
                    Button("Heading 1") { richTextCoordinator?.applyStyle(.heading1) }
                    Button("Heading 2") { richTextCoordinator?.applyStyle(.heading2) }
                    Button("Heading 3") { richTextCoordinator?.applyStyle(.heading3) }
                } label: {
                    formattingButton(icon: "textformat.size", label: "Aa")
                }

                Divider().frame(height: 24)

                // Bold
                Button(action: { richTextCoordinator?.applyStyle(.bold) }) {
                    formattingButton(icon: "bold", label: nil)
                }

                // Italic
                Button(action: { richTextCoordinator?.applyStyle(.italic) }) {
                    formattingButton(icon: "italic", label: nil)
                }

                Divider().frame(height: 24)

                // Bullet list
                Button(action: { richTextCoordinator?.applyStyle(.bullet) }) {
                    formattingButton(icon: "list.bullet", label: nil)
                }

                // Numbered list
                Button(action: { richTextCoordinator?.applyStyle(.numberedList) }) {
                    formattingButton(icon: "list.number", label: nil)
                }

                // Decrease indent
                Button(action: { richTextCoordinator?.applyStyle(.outdent) }) {
                    formattingButton(icon: "decrease.indent", label: nil)
                }

                // Increase indent
                Button(action: { richTextCoordinator?.applyStyle(.indent) }) {
                    formattingButton(icon: "increase.indent", label: nil)
                }

                Divider().frame(height: 24)

                // Quote
                Button(action: { richTextCoordinator?.applyStyle(.quote) }) {
                    formattingButton(icon: "text.quote", label: nil)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
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
            // Switching to markdown: sync content from visual editor first
            syncMarkdownFromVisualEditor()
            editMode = .markdown
        } else {
            // Switching to visual: parse markdown back to blocks
            syncBlocksFromMarkdown()
            // Force visual editor to recreate with fresh content
            visualEditorRefreshId = UUID()
            editMode = .visual
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                // Mode toggle
                Menu {
                    Button(action: { withAnimation { mode = .present } }) {
                        Label("Present", systemImage: "rectangle.expand.vertical")
                    }
                    Button(action: { withAnimation { mode = .read } }) {
                        Label("Read", systemImage: "book")
                    }
                    Button(action: { withAnimation { mode = .edit } }) {
                        Label("Edit", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: modeIcon)
                }

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

                // Metadata (edit mode only)
                if mode == .edit {
                    Button(action: { showingMetadataEditor = true }) {
                        Image(systemName: "info.circle")
                    }

                    // Sync status (edit mode only)
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
                ShareLink(item: MarkdownDevotionalConverter.devotionalToMarkdown(devotional)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    private var modeIcon: String {
        switch mode {
        case .present: return "rectangle.expand.vertical"
        case .read: return "book"
        case .edit: return "pencil"
        }
    }

    // MARK: - Auto-save

    @State private var isSaving: Bool = false

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

        // Convert markdown content back to blocks before saving
        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)

        // Update lastModified timestamp
        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        do {
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

        let blocks = MarkdownDevotionalConverter.markdownToBlocks(markdownContent)
        devotional.content = .blocks(blocks)
        devotional.meta.lastModified = Int(Date().timeIntervalSince1970)

        // Use Task to call async save and export to iCloud
        Task {
            defer { isSaving = false }
            do {
                try await ModuleSyncManager.shared.saveDevotional(devotional, moduleId: moduleId)
                await MainActor.run {
                    hasUnsavedChanges = false
                }
            } catch {
                print("[DevotionalView] Failed to save on disappear: \(error)")
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

// MARK: - Rich Text Editor

struct RichTextEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onCoordinatorReady: ((Coordinator) -> Void)?

    enum TextStyle {
        case paragraph, heading1, heading2, heading3, bold, italic, quote, bullet, numberedList, indent, outdent
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 60, right: 12)
        textView.isScrollEnabled = true
        textView.allowsEditingTextAttributes = true
        textView.typingAttributes = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label
        ]
        context.coordinator.textView = textView
        context.coordinator.fontSize = fontSize

        // Load initial content - set flag to prevent textViewDidChange from overwriting
        context.coordinator.isProgrammaticallyChanging = true
        let attributed = markdownToAttributedString(text, fontSize: fontSize)
        textView.attributedText = attributed
        // Store the initial attributed string with custom attributes
        context.coordinator.currentAttributedString = attributed

        // Delay resetting the flag to ensure any async delegate calls are also blocked
        DispatchQueue.main.async {
            context.coordinator.isProgrammaticallyChanging = false
        }

        // Pass coordinator back
        DispatchQueue.main.async {
            self.onCoordinatorReady?(context.coordinator)
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // CRITICAL: Update parent reference since MarkdownTextEditor is a struct (value type)
        // Without this, the coordinator's parent.text would be stale
        context.coordinator.parent = self
        context.coordinator.fontSize = fontSize
        // Only update if text changed externally and we're not currently editing
        if !context.coordinator.isEditing {
            let currentPlain = textView.attributedText.string
            let expectedPlain = markdownToPlainText(text)
            if currentPlain != expectedPlain {
                // Set flag to prevent textViewDidChange from overwriting
                context.coordinator.isProgrammaticallyChanging = true
                let attributed = markdownToAttributedString(text, fontSize: fontSize)
                textView.attributedText = attributed
                // Store the updated attributed string with custom attributes
                context.coordinator.currentAttributedString = attributed
                // Delay resetting the flag to ensure any async delegate calls are also blocked
                DispatchQueue.main.async {
                    context.coordinator.isProgrammaticallyChanging = false
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Convert markdown to plain text (for comparison)
    // IMPORTANT: Must skip empty lines to match markdownToAttributedString behavior
    private func markdownToPlainText(_ markdown: String) -> String {
        var result = ""
        for line in markdown.components(separatedBy: "\n") {
            // Skip empty lines - must match markdownToAttributedString behavior
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            var processedLine = line
            if line.hasPrefix("### ") { processedLine = String(line.dropFirst(4)) }
            else if line.hasPrefix("## ") { processedLine = String(line.dropFirst(3)) }
            else if line.hasPrefix("# ") { processedLine = String(line.dropFirst(2)) }
            else if line.hasPrefix("> ") { processedLine = String(line.dropFirst(2)) }
            // Bullet lists with indentation
            else if let bulletMatch = line.range(of: "^(\\t|  )*- ", options: .regularExpression) {
                let prefix = String(line[bulletMatch])
                let indentLevel = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                processedLine = String(repeating: "\t", count: indentLevel) + "• " + String(line[bulletMatch.upperBound...])
            }
            // Numbered lists with indentation
            else if let numberMatch = line.range(of: "^(\\t|  )*\\d+\\. ", options: .regularExpression) {
                let prefix = String(line[numberMatch])
                let indentLevel = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                if let numRange = prefix.range(of: "\\d+", options: .regularExpression) {
                    let number = String(prefix[numRange])
                    processedLine = String(repeating: "\t", count: indentLevel) + number + ". " + String(line[numberMatch.upperBound...])
                }
            }

            // Remove inline markers
            processedLine = processedLine.replacingOccurrences(of: "**", with: "")
            processedLine = processedLine.replacingOccurrences(of: "*", with: "")

            result += processedLine + "\n"
        }
        return result.trimmingCharacters(in: .newlines)
    }

    // Color between primary and secondary for blockquotes
    private var blockquoteColor: UIColor {
        UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(white: 0.75, alpha: 1.0)
            } else {
                return UIColor(white: 0.35, alpha: 1.0)
            }
        }
    }

    // Convert markdown to NSAttributedString (hiding syntax)
    func markdownToAttributedString(_ markdown: String, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let bodyFont = UIFont.systemFont(ofSize: fontSize)
        let h1Font = UIFont.systemFont(ofSize: fontSize * 1.6, weight: .bold)
        let h2Font = UIFont.systemFont(ofSize: fontSize * 1.4, weight: .bold)
        let h3Font = UIFont.systemFont(ofSize: fontSize * 1.2, weight: .bold)
        let italicFont = UIFont.italicSystemFont(ofSize: fontSize)
        let boldFont = UIFont.boldSystemFont(ofSize: fontSize)

        let lines = markdown.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            // Skip empty lines - we use paragraph spacing instead
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            var processedLine = line
            var lineFont = bodyFont
            var lineColor: UIColor = UIColor.label
            var customAttributes: [NSAttributedString.Key: Any] = [:]
            var listMarkerLength = 0  // Length of bullet/number prefix for secondary color

            // Headings
            if line.hasPrefix("### ") {
                processedLine = String(line.dropFirst(4))
                lineFont = h3Font
                customAttributes[.headingLevel] = 3
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.paragraphSpacing = fontSize * 1.2
                customAttributes[.paragraphStyle] = paragraphStyle
            } else if line.hasPrefix("## ") {
                processedLine = String(line.dropFirst(3))
                lineFont = h2Font
                customAttributes[.headingLevel] = 2
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.paragraphSpacing = fontSize * 1.2
                customAttributes[.paragraphStyle] = paragraphStyle
            } else if line.hasPrefix("# ") {
                processedLine = String(line.dropFirst(2))
                lineFont = h1Font
                customAttributes[.headingLevel] = 1
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.paragraphSpacing = fontSize * 1.2
                customAttributes[.paragraphStyle] = paragraphStyle
            }
            // Blockquotes - use indentation and slightly lower contrast color
            else if line.hasPrefix("> ") {
                processedLine = String(line.dropFirst(2))
                customAttributes[.blockquote] = true
                lineColor = blockquoteColor
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = 20
                paragraphStyle.headIndent = 20
                paragraphStyle.paragraphSpacing = fontSize * 0.8
                paragraphStyle.lineSpacing = fontSize * 0.5
                customAttributes[.paragraphStyle] = paragraphStyle
            }
            // Bullet lists (with optional indentation via tabs or spaces)
            else if let bulletMatch = line.range(of: "^(\\t|  )*- ", options: .regularExpression) {
                let prefix = String(line[bulletMatch])
                let indentLevel = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                processedLine = String(repeating: "\t", count: indentLevel) + "• " + String(line[bulletMatch.upperBound...])
                listMarkerLength = indentLevel + 2  // tabs + "• "
                customAttributes[.bulletList] = true
                customAttributes[.listIndentLevel] = indentLevel
                let paragraphStyle = NSMutableParagraphStyle()
                let baseIndent: CGFloat = 20 + CGFloat(indentLevel) * 20  // 20pt base + nested indent
                paragraphStyle.firstLineHeadIndent = baseIndent
                paragraphStyle.headIndent = baseIndent + 20
                paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
                paragraphStyle.lineSpacing = fontSize * 0.5
                customAttributes[.paragraphStyle] = paragraphStyle
            }
            // Numbered lists (with optional indentation)
            else if let numberMatch = line.range(of: "^(\\t|  )*\\d+\\. ", options: .regularExpression) {
                let prefix = String(line[numberMatch])
                let indentLevel = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                // Extract the number
                if let numRange = prefix.range(of: "\\d+", options: .regularExpression) {
                    let number = String(prefix[numRange])
                    processedLine = String(repeating: "\t", count: indentLevel) + number + ". " + String(line[numberMatch.upperBound...])
                    listMarkerLength = indentLevel + number.count + 2  // tabs + number + ". "
                } else {
                    processedLine = String(line[numberMatch.upperBound...])
                }
                customAttributes[.numberedList] = true
                customAttributes[.listIndentLevel] = indentLevel
                let paragraphStyle = NSMutableParagraphStyle()
                let baseIndent: CGFloat = 20 + CGFloat(indentLevel) * 20  // 20pt base + nested indent
                paragraphStyle.firstLineHeadIndent = baseIndent
                paragraphStyle.headIndent = baseIndent + 24
                paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
                paragraphStyle.lineSpacing = fontSize * 0.5
                customAttributes[.paragraphStyle] = paragraphStyle
            }

            // Add default paragraph style for regular paragraphs if not already set
            // IMPORTANT: Explicitly set all indentation properties to 0 to prevent
            // any inheritance from previous blockquote/list styles
            if customAttributes[.paragraphStyle] == nil {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.firstLineHeadIndent = 0
                paragraphStyle.headIndent = 0
                paragraphStyle.tailIndent = 0
                paragraphStyle.paragraphSpacing = fontSize * 0.8
                paragraphStyle.lineSpacing = fontSize * 0.5
                customAttributes[.paragraphStyle] = paragraphStyle
            }

            // Ensure regular paragraphs don't have any block-level formatting
            // This prevents any accidental inheritance
            if customAttributes[.blockquote] == nil {
                customAttributes[.blockquote] = false
            }
            if customAttributes[.bulletList] == nil {
                customAttributes[.bulletList] = false
            }
            if customAttributes[.numberedList] == nil {
                customAttributes[.numberedList] = false
            }

            // Process inline formatting
            let attributed = processInlineFormatting(processedLine, baseFont: lineFont, fontSize: fontSize)

            // Apply line-level attributes
            let mutableAttr = NSMutableAttributedString(attributedString: attributed)
            let fullRange = NSRange(location: 0, length: mutableAttr.length)
            mutableAttr.addAttribute(.foregroundColor, value: lineColor, range: fullRange)
            for (key, value) in customAttributes {
                mutableAttr.addAttribute(key, value: value, range: fullRange)
            }

            // Apply secondary color to list markers (bullets/numbers)
            if listMarkerLength > 0 && listMarkerLength <= mutableAttr.length {
                let markerRange = NSRange(location: 0, length: listMarkerLength)
                mutableAttr.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: markerRange)
            }

            result.append(mutableAttr)

            if index < lines.count - 1 {
                // Newlines should have clean attributes to prevent bleeding
                // Include explicit paragraph style reset to prevent blockquote/list styles from bleeding
                let cleanParagraphStyle = NSMutableParagraphStyle()
                cleanParagraphStyle.firstLineHeadIndent = 0
                cleanParagraphStyle.headIndent = 0
                cleanParagraphStyle.paragraphSpacing = 0
                cleanParagraphStyle.lineSpacing = 0

                let newlineAttrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: cleanParagraphStyle,
                    .blockquote: false,
                    .bulletList: false,
                    .numberedList: false
                ]
                result.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
            }
        }

        return result
    }

    private func processInlineFormatting(_ text: String, baseFont: UIFont, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: baseFont])

        // Bold: **text**
        if let regex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*", options: []) {
            var offset = 0
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
            for match in matches {
                let adjustedRange = NSRange(location: match.range.location - offset, length: match.range.length)
                let contentRange = NSRange(location: match.range(at: 1).location - offset, length: match.range(at: 1).length)

                if let range = Range(contentRange, in: result.string) {
                    let content = String(result.string[range])
                    let boldFont = UIFont.boldSystemFont(ofSize: baseFont.pointSize)
                    let replacement = NSAttributedString(string: content, attributes: [.font: boldFont, .isBold: true])
                    result.replaceCharacters(in: adjustedRange, with: replacement)
                    offset += match.range.length - content.count
                }
            }
        }

        // Italic: *text* (not **)
        if let regex = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", options: []) {
            var offset = 0
            let currentString = result.string
            let matches = regex.matches(in: currentString, options: [], range: NSRange(location: 0, length: currentString.count))
            for match in matches {
                let adjustedRange = NSRange(location: match.range.location - offset, length: match.range.length)
                let contentRange = NSRange(location: match.range(at: 1).location - offset, length: match.range(at: 1).length)

                if adjustedRange.location >= 0 && adjustedRange.location + adjustedRange.length <= result.length,
                   let range = Range(contentRange, in: result.string) {
                    let content = String(result.string[range])
                    let italicFont = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                    let replacement = NSAttributedString(string: content, attributes: [.font: italicFont, .isItalic: true])
                    result.replaceCharacters(in: adjustedRange, with: replacement)
                    offset += match.range.length - content.count
                }
            }
        }

        return result
    }

    // Extract plain text from attributed string (for comparison)
    private func richTextToPlainText(_ attributed: NSAttributedString) -> String {
        attributed.string
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor
        var isEditing = false
        var isProgrammaticallyChanging = false  // Prevent textViewDidChange from overwriting during style apply
        var hasUserTyped = false  // Only convert to markdown after user actually types
        weak var textView: UITextView?
        var fontSize: CGFloat = 18

        // Store attributed string with custom attrs since UITextView strips them
        var currentAttributedString: NSAttributedString?

        // Helper to compare colors by resolving them to concrete values
        // Uses the blockquoteColor defined in Coordinator (line ~1940)
        private func isBlockquoteColor(_ color: UIColor) -> Bool {
            // Resolve both colors in both light and dark mode to handle dynamic colors
            let lightTraits = UITraitCollection(userInterfaceStyle: .light)
            let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

            let resolvedColorLight = color.resolvedColor(with: lightTraits)
            let expectedLight = blockquoteColor.resolvedColor(with: lightTraits)

            let resolvedColorDark = color.resolvedColor(with: darkTraits)
            let expectedDark = blockquoteColor.resolvedColor(with: darkTraits)

            // Check if it matches our blockquote color in either mode
            return colorsApproximatelyEqual(resolvedColorLight, expectedLight) ||
                   colorsApproximatelyEqual(resolvedColorDark, expectedDark)
        }

        private func colorsApproximatelyEqual(_ c1: UIColor, _ c2: UIColor) -> Bool {
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let tolerance: CGFloat = 0.01
            return abs(r1 - r2) < tolerance && abs(g1 - g2) < tolerance &&
                   abs(b1 - b2) < tolerance && abs(a1 - a2) < tolerance
        }

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            // Only convert if user actually made changes - prevents corruption on initial load
            guard hasUserTyped else { return }
            // Convert back to markdown on end editing
            // Use currentAttributedString if available since textView.attributedText strips custom attributes
            let attrToConvert = currentAttributedString ?? textView.attributedText ?? NSAttributedString()
            parent.text = attributedStringToMarkdown(attrToConvert)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Skip if we're programmatically changing to avoid interference
            guard !isProgrammaticallyChanging else { return }

            let cursorPosition = textView.selectedRange.location
            guard cursorPosition >= 0 else { return }

            let currentText = textView.attributedText?.string ?? ""
            guard !currentText.isEmpty else { return }

            // Find which visual line the cursor is on
            var currentPos = 0
            var visualLineNumber = 0
            let visualLines = currentText.components(separatedBy: "\n")

            for (index, line) in visualLines.enumerated() {
                let lineEnd = currentPos + line.count
                if cursorPosition <= lineEnd || index == visualLines.count - 1 {
                    visualLineNumber = index
                    break
                }
                currentPos = lineEnd + 1
            }

            // Map visual line to markdown line (accounting for skipped empty lines)
            let markdownLines = parent.text.components(separatedBy: "\n")
            var nonEmptyCount = 0
            var markdownLineIndex = 0

            for (index, mdLine) in markdownLines.enumerated() {
                if !mdLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    if nonEmptyCount == visualLineNumber {
                        markdownLineIndex = index
                        break
                    }
                    nonEmptyCount += 1
                }
            }

            // Get the markdown line and determine block type
            let markdownLine = markdownLineIndex < markdownLines.count ? markdownLines[markdownLineIndex] : ""

            // Build typing attributes based on markdown line prefix
            var newTypingAttrs: [NSAttributedString.Key: Any] = [:]
            newTypingAttrs[.font] = UIFont.systemFont(ofSize: fontSize)
            newTypingAttrs[.foregroundColor] = UIColor.label  // Default

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = fontSize * 0.5
            paragraphStyle.paragraphSpacing = fontSize * 0.8

            // Check markdown line prefix to determine block type
            if markdownLine.hasPrefix("### ") {
                newTypingAttrs[.headingLevel] = 3
                newTypingAttrs[.font] = UIFont.systemFont(ofSize: fontSize * 1.2, weight: .bold)
                paragraphStyle.paragraphSpacing = fontSize * 1.2
            } else if markdownLine.hasPrefix("## ") {
                newTypingAttrs[.headingLevel] = 2
                newTypingAttrs[.font] = UIFont.systemFont(ofSize: fontSize * 1.4, weight: .bold)
                paragraphStyle.paragraphSpacing = fontSize * 1.2
            } else if markdownLine.hasPrefix("# ") {
                newTypingAttrs[.headingLevel] = 1
                newTypingAttrs[.font] = UIFont.systemFont(ofSize: fontSize * 1.6, weight: .bold)
                paragraphStyle.paragraphSpacing = fontSize * 1.2
            } else if markdownLine.hasPrefix("> ") {
                newTypingAttrs[.foregroundColor] = blockquoteColor
                newTypingAttrs[.blockquote] = true
                paragraphStyle.firstLineHeadIndent = 20
                paragraphStyle.headIndent = 20
            } else if let bulletMatch = markdownLine.range(of: "^(\\t|  )*- ", options: .regularExpression) {
                let prefix = String(markdownLine[bulletMatch])
                let indent = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                newTypingAttrs[.bulletList] = true
                newTypingAttrs[.listIndentLevel] = indent
                let baseIndent: CGFloat = 20 + CGFloat(indent) * 20
                paragraphStyle.firstLineHeadIndent = baseIndent
                paragraphStyle.headIndent = baseIndent + 20
                paragraphStyle.paragraphSpacing = 0
            } else if let numberMatch = markdownLine.range(of: "^(\\t|  )*\\d+\\. ", options: .regularExpression) {
                let prefix = String(markdownLine[numberMatch])
                let indent = prefix.filter { $0 == "\t" }.count + (prefix.filter { $0 == " " }.count / 2)
                newTypingAttrs[.numberedList] = true
                newTypingAttrs[.listIndentLevel] = indent
                let baseIndent: CGFloat = 20 + CGFloat(indent) * 20
                paragraphStyle.firstLineHeadIndent = baseIndent
                paragraphStyle.headIndent = baseIndent + 24
                paragraphStyle.paragraphSpacing = 0
            }

            newTypingAttrs[.paragraphStyle] = paragraphStyle
            textView.typingAttributes = newTypingAttrs
        }
        func textViewDidChange(_ textView: UITextView) {
            // Skip if we're programmatically changing (e.g., applying styles)
            guard !isProgrammaticallyChanging else { return }

            // Store the attributed string for tracking
            currentAttributedString = textView.attributedText

            // Sync markdown content on every change to ensure edits are saved
            // This is necessary because onDisappear may not be able to access the coordinator
            parent.text = attributedStringToMarkdown(currentAttributedString!)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Mark that user has started typing - this enables markdown conversion
            hasUserTyped = true

            // Handle newline
            if text == "\n" {
                // Check typing attributes first (most reliable for current mode)
                let typingAttrs = textView.typingAttributes

                // Handle headings - insert newline and switch to paragraph mode
                if typingAttrs[.headingLevel] != nil {
                    self.insertNewlineAndSwitchToParagraph(textView: textView, at: range.location)
                    return false
                }

                // Handle blockquotes - insert newline and exit blockquote mode
                if typingAttrs[.blockquote] as? Bool == true {
                    self.insertNewlineAndSwitchToParagraph(textView: textView, at: range.location)
                    return false
                }

                // For lists, check document attributes to get line content
                let currentString = textView.attributedText.string as NSString
                let lineRange = currentString.lineRange(for: range)
                let lineStart = lineRange.location

                if lineStart < textView.attributedText.length {
                    let attrs = textView.attributedText.attributes(at: lineStart, effectiveRange: nil)
                    let line = currentString.substring(with: lineRange).trimmingCharacters(in: .newlines)
                    let indentLevel = attrs[.listIndentLevel] as? Int ?? 0

                    // Handle bullet lists
                    if attrs[.bulletList] as? Bool == true || typingAttrs[.bulletList] as? Bool == true {
                        // Check if line is just the bullet (empty item) - exit list mode
                        if line == "• " || line == String(repeating: "\t", count: indentLevel) + "• " {
                            self.removeEmptyListItemAndExitList(textView: textView, lineRange: lineRange)
                            return false
                        }
                        // Continue bullet list with new bullet
                        self.insertNewListItem(textView: textView, at: range.location, bullet: true, indentLevel: indentLevel)
                        return false
                    }

                    // Handle numbered lists
                    if attrs[.numberedList] as? Bool == true || typingAttrs[.numberedList] as? Bool == true {
                        // Check if line is just the number (empty item) - exit list mode
                        let numberPattern = "^\\t*\\d+\\. $"
                        if let regex = try? NSRegularExpression(pattern: numberPattern),
                           regex.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) != nil {
                            self.removeEmptyListItemAndExitList(textView: textView, lineRange: lineRange)
                            return false
                        }
                        // Continue numbered list with incremented number
                        let nextNumber = getNextListNumber(in: textView.attributedText, at: lineStart)
                        self.insertNewListItem(textView: textView, at: range.location, bullet: false, indentLevel: indentLevel, number: nextNumber)
                        return false
                    }
                }

                // Default: insert newline and reset to paragraph mode
                self.insertNewlineAndSwitchToParagraph(textView: textView, at: range.location)
                return false
            }

            // Handle backspace (delete key)
            if text.isEmpty && range.length > 0 {
                let currentString = textView.attributedText.string as NSString
                let lineRange = currentString.lineRange(for: range)
                let lineStart = lineRange.location

                // Check if we're at the start of a line or about to delete a bullet
                if lineStart < textView.attributedText.length {
                    let attrs = textView.attributedText.attributes(at: lineStart, effectiveRange: nil)

                    // Check if deleting at start of blockquote line - exit blockquote mode
                    if attrs[.blockquote] as? Bool == true && range.location == lineStart {
                        DispatchQueue.main.async {
                            self.removeBlockquoteFromLine(textView: textView, lineRange: lineRange)
                        }
                        return false
                    }

                    // Check if deleting bullet character
                    if attrs[.bulletList] as? Bool == true {
                        let line = currentString.substring(with: lineRange)
                        let indentLevel = attrs[.listIndentLevel] as? Int ?? 0
                        let bulletPrefix = String(repeating: "\t", count: indentLevel) + "• "

                        // If at start or right after bullet, handle indent decrease or exit
                        if range.location == lineStart || range.location <= lineStart + bulletPrefix.count {
                            DispatchQueue.main.async {
                                if indentLevel > 0 {
                                    self.decreaseListIndent(textView: textView, lineRange: lineRange, isBullet: true)
                                } else {
                                    self.removeBulletFromLine(textView: textView, lineRange: lineRange)
                                }
                            }
                            return false
                        }
                    }

                    // Check if deleting numbered list item
                    if attrs[.numberedList] as? Bool == true {
                        let line = currentString.substring(with: lineRange)
                        let indentLevel = attrs[.listIndentLevel] as? Int ?? 0

                        // Find where number prefix ends
                        if let dotRange = line.range(of: ". ") {
                            let prefixEnd = line.distance(from: line.startIndex, to: dotRange.upperBound)
                            if range.location <= lineStart + prefixEnd {
                                DispatchQueue.main.async {
                                    if indentLevel > 0 {
                                        self.decreaseListIndent(textView: textView, lineRange: lineRange, isBullet: false)
                                    } else {
                                        self.removeNumberedListFromLine(textView: textView, lineRange: lineRange)
                                    }
                                }
                                return false
                            }
                        }
                    }
                }
            }

            return true
        }

        private func defaultParagraphAttributes() -> [NSAttributedString.Key: Any] {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = fontSize * 0.8
            paragraphStyle.lineSpacing = fontSize * 0.5  // Slight line spacing for wrapped text
            return [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]
        }

        private func insertNewlineAndSwitchToParagraph(textView: UITextView, at position: Int) {
            var paragraphAttrs = defaultParagraphAttributes()

            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)

            // BEFORE inserting newline: truncate any special formatting attributes
            // at the current position so they don't extend past the newline
            if position > 0 && position < mutableAttr.length {
                let precedingRange = NSRange(location: 0, length: position)
                // Get attributes at the current position to see what we need to truncate
                let currentAttrs = mutableAttr.attributes(at: max(0, position - 1), effectiveRange: nil)

                // If preceding content has special formatting, ensure it doesn't extend beyond
                if currentAttrs[.blockquote] as? Bool == true ||
                   currentAttrs[.headingLevel] != nil ||
                   currentAttrs[.bulletList] as? Bool == true ||
                   currentAttrs[.numberedList] as? Bool == true {
                    // Remove special attributes from everything AFTER the newline position
                    // (we'll do this after insertion)
                }
            }

            // Insert newline with paragraph attributes
            mutableAttr.insert(NSAttributedString(string: "\n", attributes: paragraphAttrs), at: position)

            // The newline at 'position' should have clean paragraph attributes
            // Also ensure it doesn't have any special formatting that could bleed
            let newlineRange = NSRange(location: position, length: 1)
            mutableAttr.removeAttribute(.headingLevel, range: newlineRange)
            mutableAttr.removeAttribute(.blockquote, range: newlineRange)
            mutableAttr.removeAttribute(.bulletList, range: newlineRange)
            mutableAttr.removeAttribute(.numberedList, range: newlineRange)
            mutableAttr.removeAttribute(.listIndentLevel, range: newlineRange)

            // Remove special formatting attributes from content after the newline
            let newPosition = position + 1
            if newPosition < mutableAttr.length {
                let nsString = mutableAttr.string as NSString
                let lineRange = nsString.lineRange(for: NSRange(location: newPosition, length: 0))

                if lineRange.length > 0 {
                    // Clear special attributes from the new line
                    mutableAttr.removeAttribute(.headingLevel, range: lineRange)
                    mutableAttr.removeAttribute(.blockquote, range: lineRange)
                    mutableAttr.removeAttribute(.bulletList, range: lineRange)
                    mutableAttr.removeAttribute(.numberedList, range: lineRange)
                    mutableAttr.removeAttribute(.listIndentLevel, range: lineRange)

                    // Apply proper paragraph styling
                    let paragraphStyle = NSMutableParagraphStyle()
                    paragraphStyle.paragraphSpacing = fontSize * 0.8
                    paragraphStyle.lineSpacing = fontSize * 0.5
                    paragraphStyle.firstLineHeadIndent = 0
                    paragraphStyle.headIndent = 0
                    mutableAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
                    mutableAttr.addAttribute(.foregroundColor, value: UIColor.label, range: lineRange)
                }
            }

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = NSRange(location: newPosition, length: 0)
            isProgrammaticallyChanging = false

            // Set typing attributes SYNCHRONOUSLY to prevent race conditions
            let cursorParagraphStyle = NSMutableParagraphStyle()
            cursorParagraphStyle.paragraphSpacing = fontSize * 0.8
            cursorParagraphStyle.lineSpacing = fontSize * 0.5
            cursorParagraphStyle.firstLineHeadIndent = 0
            cursorParagraphStyle.headIndent = 0

            let cursorAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .paragraphStyle: cursorParagraphStyle
            ]
            textView.typingAttributes = cursorAttrs

            // Async block just for cursor position and layout updates
            DispatchQueue.main.async {
                if let start = textView.position(from: textView.beginningOfDocument, offset: newPosition) {
                    textView.selectedTextRange = textView.textRange(from: start, to: start)
                }
                textView.setNeedsLayout()
                textView.layoutIfNeeded()
                textView.setNeedsDisplay()
            }

            parent.text = self.attributedStringToMarkdown(mutableAttr)
        }

        private func getNextListNumber(in attributed: NSAttributedString, at lineStart: Int) -> Int {
            let string = attributed.string as NSString
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = string.substring(with: lineRange)

            // Extract current number
            if let regex = try? NSRegularExpression(pattern: "^\\t*(\\d+)\\. "),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.count)),
               let numRange = Range(match.range(at: 1), in: line),
               let num = Int(line[numRange]) {
                return num + 1
            }
            return 1
        }

        private func insertNewListItem(textView: UITextView, at position: Int, bullet: Bool, indentLevel: Int, number: Int = 1) {
            let indent = String(repeating: "\t", count: indentLevel)
            let markerPart = bullet ? "• " : "\(number). "
            let prefix = "\n\(indent)\(markerPart)"

            let paragraphStyle = NSMutableParagraphStyle()
            let baseIndent: CGFloat = 20 + CGFloat(indentLevel) * 20  // 20pt base + nested indent
            paragraphStyle.firstLineHeadIndent = baseIndent
            paragraphStyle.headIndent = baseIndent + (bullet ? 20 : 24)  // Numbered lists need more space
            paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
            paragraphStyle.lineSpacing = fontSize * 0.5

            // Marker (bullet/number) gets secondary color
            var markerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle,
                .listIndentLevel: indentLevel
            ]

            if bullet {
                markerAttrs[.bulletList] = true
            } else {
                markerAttrs[.numberedList] = true
            }

            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)

            // Build the attributed string with newline + indent + marker
            let newlineIndent = NSMutableAttributedString(string: "\n\(indent)", attributes: markerAttrs)
            let marker = NSAttributedString(string: markerPart, attributes: markerAttrs)
            newlineIndent.append(marker)

            mutableAttr.insert(newlineIndent, at: position)

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = NSRange(location: position + prefix.count, length: 0)
            isProgrammaticallyChanging = false
            // Set typing attributes with label color for content after marker
            var typingAttrs = markerAttrs
            typingAttrs[.foregroundColor] = UIColor.label
            textView.typingAttributes = typingAttrs
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func removeEmptyListItemAndExitList(textView: UITextView, lineRange: NSRange) {
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)

            // Delete the empty list item line
            mutableAttr.deleteCharacters(in: lineRange)

            // Paragraph style with reset indentation
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = fontSize * 0.8
            paragraphStyle.lineSpacing = fontSize * 0.5
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.headIndent = 0

            let newlineAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            let newPosition = lineRange.location
            textView.selectedRange = NSRange(location: newPosition, length: 0)
            isProgrammaticallyChanging = false

            // Set typing attributes synchronously
            textView.typingAttributes = newlineAttrs

            // Async block for cursor position and layout
            DispatchQueue.main.async {
                if let start = textView.position(from: textView.beginningOfDocument, offset: newPosition) {
                    textView.selectedTextRange = textView.textRange(from: start, to: start)
                }
                textView.setNeedsLayout()
                textView.layoutIfNeeded()
                textView.setNeedsDisplay()
            }

            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func decreaseListIndent(textView: UITextView, lineRange: NSRange, isBullet: Bool) {
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)
            let currentString = mutableAttr.string as NSString
            let line = currentString.substring(with: lineRange)

            // Remove one tab from the beginning
            if line.hasPrefix("\t") {
                mutableAttr.deleteCharacters(in: NSRange(location: lineRange.location, length: 1))

                // Update indent level attribute
                let newLineRange = NSRange(location: lineRange.location, length: lineRange.length - 1)
                if newLineRange.length > 0 {
                    let currentIndent = mutableAttr.attribute(.listIndentLevel, at: lineRange.location, effectiveRange: nil) as? Int ?? 1
                    let newIndent = max(0, currentIndent - 1)
                    mutableAttr.addAttribute(.listIndentLevel, value: newIndent, range: newLineRange)

                    // Update paragraph style
                    let paragraphStyle = NSMutableParagraphStyle()
                    let baseIndent = CGFloat(newIndent) * 20
                    paragraphStyle.firstLineHeadIndent = baseIndent
                    paragraphStyle.headIndent = baseIndent + 20
                    mutableAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: newLineRange)
                }
            }

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            isProgrammaticallyChanging = false
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func removeNumberedListFromLine(textView: UITextView, lineRange: NSRange) {
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)
            let currentString = mutableAttr.string as NSString
            let line = currentString.substring(with: lineRange)

            // Find and remove the number prefix (e.g., "1. ")
            if let regex = try? NSRegularExpression(pattern: "^\\t*\\d+\\. "),
               let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.count)) {
                let prefixRange = NSRange(location: lineRange.location, length: match.range.length)
                mutableAttr.deleteCharacters(in: prefixRange)

                // Remove list attributes from remaining content
                let newLineRange = NSRange(location: lineRange.location, length: lineRange.length - match.range.length)
                if newLineRange.length > 0 && newLineRange.location < mutableAttr.length {
                    mutableAttr.removeAttribute(.numberedList, range: newLineRange)
                    mutableAttr.removeAttribute(.listIndentLevel, range: newLineRange)
                    mutableAttr.removeAttribute(.paragraphStyle, range: newLineRange)
                }
            }

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            isProgrammaticallyChanging = false
            textView.typingAttributes = defaultParagraphAttributes()
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func removeBlockquoteFromLine(textView: UITextView, lineRange: NSRange) {
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)

            // Remove blockquote attribute and reset paragraph style
            mutableAttr.removeAttribute(.blockquote, range: lineRange)
            mutableAttr.removeAttribute(.paragraphStyle, range: lineRange)
            mutableAttr.addAttribute(.foregroundColor, value: UIColor.label, range: lineRange)

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            isProgrammaticallyChanging = false
            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label
            ]
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func removeBulletFromLine(textView: UITextView, lineRange: NSRange) {
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)
            let currentString = mutableAttr.string as NSString
            let line = currentString.substring(with: lineRange)

            // Remove bullet and attributes
            if line.hasPrefix("• ") {
                // Remove the "• " prefix
                let bulletRange = NSRange(location: lineRange.location, length: 2)
                mutableAttr.deleteCharacters(in: bulletRange)

                // Update line range after deletion
                let newLineRange = NSRange(location: lineRange.location, length: lineRange.length - 2)
                if newLineRange.length > 0 && newLineRange.location < mutableAttr.length {
                    mutableAttr.removeAttribute(.bulletList, range: newLineRange)
                    mutableAttr.removeAttribute(.paragraphStyle, range: newLineRange)
                }
            }

            // Store and set with flag to prevent textViewDidChange from overwriting
            currentAttributedString = mutableAttr
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = NSRange(location: lineRange.location, length: 0)
            isProgrammaticallyChanging = false
            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label
            ]
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        /// Determine the block type for a line
        private enum LineBlockType {
            case paragraph
            case heading
            case blockquote
            case bulletList
            case numberedList
            case empty
        }

        // Convert attributed string back to markdown
        func attributedStringToMarkdown(_ attributed: NSAttributedString) -> String {
            var result = ""
            let string = attributed.string
            let lines = string.components(separatedBy: "\n")
            var currentIndex = 0
            var previousBlockType: LineBlockType = .empty

            for (lineIndex, line) in lines.enumerated() {
                if line.isEmpty {
                    result += "\n"
                    currentIndex += 1
                    previousBlockType = .empty
                    continue
                }

                let lineStart = currentIndex
                var lineMarkdown = ""
                var prefix = ""
                var currentBlockType: LineBlockType = .paragraph

                // Check first character's attributes for line-level formatting
                if lineStart < attributed.length {
                    let attrs = attributed.attributes(at: lineStart, effectiveRange: nil)
                    let indentLevel = attrs[.listIndentLevel] as? Int ?? 0
                    let indentPrefix = String(repeating: "\t", count: indentLevel)

                    // First try custom attributes, then infer from styling
                    if let level = attrs[.headingLevel] as? Int {
                        prefix = String(repeating: "#", count: level) + " "
                        currentBlockType = .heading
                    } else if let font = attrs[.font] as? UIFont {
                        // Infer heading level from font size (UITextView strips custom attrs)
                        let fontSizeRatio = font.pointSize / fontSize
                        if fontSizeRatio >= 1.55 && font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                            prefix = "# "  // H1: fontSize * 1.6
                            currentBlockType = .heading
                        } else if fontSizeRatio >= 1.35 && font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                            prefix = "## "  // H2: fontSize * 1.4
                            currentBlockType = .heading
                        } else if fontSizeRatio >= 1.15 && font.fontDescriptor.symbolicTraits.contains(.traitBold) {
                            prefix = "### "  // H3: fontSize * 1.2
                            currentBlockType = .heading
                        }
                    }

                    // Check for lists (custom attrs or text prefix)
                    // Skip if explicitly marked as NOT a list
                    if prefix.isEmpty && attrs[.bulletList] as? Bool != false {
                        if attrs[.bulletList] as? Bool == true || line.contains("• ") {
                            // Remove the bullet point and tabs we added for display, convert back to markdown
                            var content = line
                            // Remove leading tabs
                            while content.hasPrefix("\t") {
                                content = String(content.dropFirst())
                            }
                            // Remove bullet
                            if content.hasPrefix("• ") {
                                content = String(content.dropFirst(2))
                            }
                            lineMarkdown = indentPrefix + "- " + content
                            currentBlockType = .bulletList
                        }
                    }
                    if prefix.isEmpty && lineMarkdown.isEmpty && attrs[.numberedList] as? Bool != false {
                        if attrs[.numberedList] as? Bool == true || line.range(of: "^\\t*\\d+\\. ", options: .regularExpression) != nil {
                            // Remove the number and tabs we added for display, convert back to markdown
                            var content = line
                            // Remove leading tabs
                            while content.hasPrefix("\t") {
                                content = String(content.dropFirst())
                            }
                            // Remove number prefix (e.g., "1. ")
                            if let numMatch = content.range(of: "^\\d+\\. ", options: .regularExpression) {
                                let number = String(content[numMatch]).trimmingCharacters(in: .whitespaces)
                                content = String(content[numMatch.upperBound...])
                                lineMarkdown = indentPrefix + number + " " + content
                                currentBlockType = .numberedList
                            }
                        }
                    }
                    // Check for blockquotes - ONLY use custom attribute, no visual detection
                    // Visual detection (color + indentation) was causing false positives
                    // with paragraphs after blockquotes
                    if prefix.isEmpty && lineMarkdown.isEmpty {
                        if attrs[.blockquote] as? Bool == true {
                            // Custom attribute present and true - it's a blockquote
                            prefix = "> "
                            currentBlockType = .blockquote
                        }
                        // If .blockquote is nil (stripped by UITextView) or false,
                        // we treat it as regular paragraph to avoid corruption
                    }
                }

                if lineMarkdown.isEmpty {
                    // Process inline formatting
                    lineMarkdown = prefix + processLineToMarkdown(line, in: attributed, startingAt: lineStart)
                }

                // CRITICAL: Add empty line when transitioning between different block types
                // This ensures markdownToBlocks correctly separates blocks
                // Without this, a paragraph after a blockquote gets absorbed into the blockquote
                let leavingSpecialBlock = previousBlockType == .blockquote ||
                    previousBlockType == .heading ||
                    (previousBlockType == .bulletList && currentBlockType != .bulletList) ||
                    (previousBlockType == .numberedList && currentBlockType != .numberedList)

                // Also add empty line when entering blockquotes or lists from a paragraph
                // This makes the markdown more readable and follows standard conventions
                let enteringSpecialBlock = previousBlockType == .paragraph &&
                    (currentBlockType == .blockquote ||
                     currentBlockType == .bulletList ||
                     currentBlockType == .numberedList)

                let needsEmptyLineBefore = previousBlockType != .empty &&
                    previousBlockType != currentBlockType &&
                    (leavingSpecialBlock || enteringSpecialBlock)

                if needsEmptyLineBefore {
                    result += "\n"
                }

                result += lineMarkdown
                if lineIndex < lines.count - 1 {
                    result += "\n"
                }

                currentIndex += line.count + 1
                previousBlockType = currentBlockType
            }

            return result
        }

        private func processLineToMarkdown(_ line: String, in attributed: NSAttributedString, startingAt start: Int) -> String {
            var result = ""
            var i = 0

            while i < line.count {
                let location = start + i
                guard location < attributed.length else {
                    result += String(line[line.index(line.startIndex, offsetBy: i)...])
                    break
                }

                var effectiveRange = NSRange()
                let attrs = attributed.attributes(at: location, effectiveRange: &effectiveRange)

                let rangeEnd = min(effectiveRange.location + effectiveRange.length - start, line.count)
                let rangeStart = max(effectiveRange.location - start, i)

                if rangeStart < line.count && rangeEnd > rangeStart {
                    let startIdx = line.index(line.startIndex, offsetBy: rangeStart)
                    let endIdx = line.index(line.startIndex, offsetBy: rangeEnd)
                    var chunk = String(line[startIdx..<endIdx])

                    if attrs[.isBold] as? Bool == true {
                        chunk = "**" + chunk + "**"
                    }
                    if attrs[.isItalic] as? Bool == true {
                        chunk = "*" + chunk + "*"
                    }

                    result += chunk
                    i = rangeEnd
                } else {
                    result += String(line[line.index(line.startIndex, offsetBy: i)])
                    i += 1
                }
            }

            return result
        }

        func applyStyle(_ style: RichTextEditor.TextStyle) {
            guard let textView = textView else { return }

            let selectedRange = textView.selectedRange
            let mutableAttr = NSMutableAttributedString(attributedString: currentAttributedString ?? textView.attributedText)

            switch style {
            case .paragraph:
                applyParagraphStyle(to: mutableAttr, in: selectedRange, textView: textView)
            case .heading1:
                applyHeadingStyle(to: mutableAttr, in: selectedRange, level: 1, textView: textView)
            case .heading2:
                applyHeadingStyle(to: mutableAttr, in: selectedRange, level: 2, textView: textView)
            case .heading3:
                applyHeadingStyle(to: mutableAttr, in: selectedRange, level: 3, textView: textView)
            case .bold:
                toggleBold(in: mutableAttr, range: selectedRange, textView: textView)
            case .italic:
                toggleItalic(in: mutableAttr, range: selectedRange, textView: textView)
            case .quote:
                applyQuoteStyle(to: mutableAttr, in: selectedRange, textView: textView)
            case .bullet:
                applyBulletStyle(to: mutableAttr, in: selectedRange, textView: textView)
            case .numberedList:
                applyNumberedListStyle(to: mutableAttr, in: selectedRange, textView: textView)
            case .indent:
                increaseIndent(in: mutableAttr, at: selectedRange, textView: textView)
            case .outdent:
                decreaseIndent(in: mutableAttr, at: selectedRange, textView: textView)
            }

            // Store the attributed string with custom attributes before UITextView strips them
            currentAttributedString = mutableAttr

            // Prevent textViewDidChange from overwriting with stripped attributes
            isProgrammaticallyChanging = true
            textView.attributedText = mutableAttr
            textView.selectedRange = selectedRange
            isProgrammaticallyChanging = false

            // Convert using our stored version that has custom attributes
            parent.text = attributedStringToMarkdown(mutableAttr)
        }

        private func applyParagraphStyle(to attr: NSMutableAttributedString, in range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)

            // Paragraph spacing
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = fontSize * 0.8  // Moderate spacing after paragraphs

            attr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: lineRange)
            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            attr.removeAttribute(.headingLevel, range: lineRange)
            attr.removeAttribute(.blockquote, range: lineRange)
            attr.removeAttribute(.bulletList, range: lineRange)
            attr.removeAttribute(.numberedList, range: lineRange)
            attr.removeAttribute(.listIndentLevel, range: lineRange)
            attr.addAttribute(.foregroundColor, value: UIColor.label, range: lineRange)

            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ]
        }

        private func applyHeadingStyle(to attr: NSMutableAttributedString, in range: NSRange, level: Int, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)
            let font: UIFont
            switch level {
            case 1: font = UIFont.systemFont(ofSize: fontSize * 1.6, weight: .bold)
            case 2: font = UIFont.systemFont(ofSize: fontSize * 1.4, weight: .bold)
            default: font = UIFont.systemFont(ofSize: fontSize * 1.2, weight: .bold)
            }

            // More spacing after headings
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = fontSize * 1.2  // More spacing after headings

            attr.addAttribute(.font, value: font, range: lineRange)
            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            attr.addAttribute(.headingLevel, value: level, range: lineRange)
            attr.removeAttribute(.blockquote, range: lineRange)
            attr.removeAttribute(.bulletList, range: lineRange)
            attr.removeAttribute(.numberedList, range: lineRange)
            attr.removeAttribute(.listIndentLevel, range: lineRange)
            attr.addAttribute(.foregroundColor, value: UIColor.label, range: lineRange)

            textView.typingAttributes = [
                .font: font,
                .foregroundColor: UIColor.label,
                .headingLevel: level,
                .paragraphStyle: paragraphStyle
            ]
        }

        // Color between primary and secondary for blockquotes
        private var blockquoteColor: UIColor {
            UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    return UIColor(white: 0.75, alpha: 1.0)  // Lighter than secondary in dark mode
                } else {
                    return UIColor(white: 0.35, alpha: 1.0)  // Darker than secondary in light mode
                }
            }
        }

        private func applyQuoteStyle(to attr: NSMutableAttributedString, in range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)

            // Apply indentation and paragraph spacing via paragraph style
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 20
            paragraphStyle.headIndent = 20
            paragraphStyle.paragraphSpacing = fontSize * 0.8  // Paragraph spacing after blockquote
            paragraphStyle.lineSpacing = fontSize * 0.5  // Line spacing for wrapped text

            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: lineRange)
            attr.addAttribute(.blockquote, value: true, range: lineRange)
            attr.removeAttribute(.headingLevel, range: lineRange)
            attr.removeAttribute(.bulletList, range: lineRange)
            attr.removeAttribute(.numberedList, range: lineRange)
            // Use slightly lower contrast color
            attr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: lineRange)
            attr.addAttribute(.foregroundColor, value: blockquoteColor, range: lineRange)

            // Update typing attributes to match
            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: blockquoteColor,
                .blockquote: true,
                .paragraphStyle: paragraphStyle
            ]
        }

        private func applyBulletStyle(to attr: NSMutableAttributedString, in range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)

            // Check if line already starts with bullet
            let lineText = (attr.string as NSString).substring(with: lineRange)
            let indentLevel = 0

            let paragraphStyle = NSMutableParagraphStyle()
            let baseIndent: CGFloat = 20 + CGFloat(indentLevel) * 20  // 20pt base + nested indent
            paragraphStyle.firstLineHeadIndent = baseIndent
            paragraphStyle.headIndent = baseIndent + 20
            paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
            paragraphStyle.lineSpacing = fontSize * 0.5  // Line spacing for wrapped text

            // Bullet character gets secondary color
            let bulletAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.secondaryLabel,
                .bulletList: true,
                .listIndentLevel: indentLevel,
                .paragraphStyle: paragraphStyle
            ]

            if !lineText.hasPrefix("• ") {
                // Insert bullet at start of line with secondary color
                attr.insert(NSAttributedString(string: "• ", attributes: bulletAttributes), at: lineRange.location)
            }

            // Apply indentation and attributes
            let updatedLineRange = NSRange(location: lineRange.location, length: lineRange.length + (lineText.hasPrefix("• ") ? 0 : 2))

            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: updatedLineRange)
            attr.addAttribute(.bulletList, value: true, range: updatedLineRange)
            attr.addAttribute(.listIndentLevel, value: indentLevel, range: updatedLineRange)
            attr.removeAttribute(.headingLevel, range: updatedLineRange)
            attr.removeAttribute(.blockquote, range: updatedLineRange)
            attr.removeAttribute(.numberedList, range: updatedLineRange)

            // Make bullet secondary color, content label color
            let bulletRange = NSRange(location: lineRange.location, length: 2)
            attr.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: bulletRange)
            if updatedLineRange.length > 2 {
                let contentRange = NSRange(location: lineRange.location + 2, length: updatedLineRange.length - 2)
                attr.addAttribute(.foregroundColor, value: UIColor.label, range: contentRange)
            }

            // Update typing attributes to continue bullet list (content is label color)
            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .bulletList: true,
                .listIndentLevel: indentLevel,
                .paragraphStyle: paragraphStyle
            ]
        }

        private func applyNumberedListStyle(to attr: NSMutableAttributedString, in range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)
            let lineText = (attr.string as NSString).substring(with: lineRange)
            let indentLevel = 0

            let paragraphStyle = NSMutableParagraphStyle()
            let baseIndent: CGFloat = 20 + CGFloat(indentLevel) * 20  // 20pt base + nested indent
            paragraphStyle.firstLineHeadIndent = baseIndent
            paragraphStyle.headIndent = baseIndent + 24
            paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
            paragraphStyle.lineSpacing = fontSize * 0.5  // Line spacing for wrapped text

            // Check if line already has a number
            let numberPattern = "^\\d+\\. "
            let hasNumber = (try? NSRegularExpression(pattern: numberPattern))?.firstMatch(in: lineText, range: NSRange(location: 0, length: lineText.count)) != nil

            // Number gets secondary color
            let numberAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.secondaryLabel,
                .numberedList: true,
                .listIndentLevel: indentLevel,
                .paragraphStyle: paragraphStyle
            ]

            var numberLength = 0
            if !hasNumber {
                // Find the appropriate number (count previous numbered items + 1)
                let number = 1
                let numberStr = "\(number). "
                numberLength = numberStr.count
                attr.insert(NSAttributedString(string: numberStr, attributes: numberAttrs), at: lineRange.location)
            } else {
                // Find the existing number length
                if let match = lineText.range(of: "^\\d+\\. ", options: .regularExpression) {
                    numberLength = lineText.distance(from: lineText.startIndex, to: match.upperBound)
                }
            }

            // Apply attributes
            let updatedLineRange = NSRange(location: lineRange.location, length: lineRange.length + (hasNumber ? 0 : numberLength))

            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: updatedLineRange)
            attr.addAttribute(.numberedList, value: true, range: updatedLineRange)
            attr.addAttribute(.listIndentLevel, value: indentLevel, range: updatedLineRange)
            attr.removeAttribute(.headingLevel, range: updatedLineRange)
            attr.removeAttribute(.blockquote, range: updatedLineRange)
            attr.removeAttribute(.bulletList, range: updatedLineRange)

            // Make number secondary color, content label color
            if numberLength > 0 {
                let numRange = NSRange(location: lineRange.location, length: numberLength)
                attr.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: numRange)
                if updatedLineRange.length > numberLength {
                    let contentRange = NSRange(location: lineRange.location + numberLength, length: updatedLineRange.length - numberLength)
                    attr.addAttribute(.foregroundColor, value: UIColor.label, range: contentRange)
                }
            }

            textView.typingAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.label,
                .numberedList: true,
                .listIndentLevel: indentLevel,
                .paragraphStyle: paragraphStyle
            ]
        }

        private func increaseIndent(in attr: NSMutableAttributedString, at range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)
            let lineText = (attr.string as NSString).substring(with: lineRange)

            // Get current indent level
            var currentIndent = 0
            if lineRange.location < attr.length {
                currentIndent = attr.attribute(.listIndentLevel, at: lineRange.location, effectiveRange: nil) as? Int ?? 0
            }

            let isBullet = attr.attribute(.bulletList, at: lineRange.location, effectiveRange: nil) as? Bool ?? false
            let isNumbered = attr.attribute(.numberedList, at: lineRange.location, effectiveRange: nil) as? Bool ?? false

            // Only indent if in a list
            guard isBullet || isNumbered else { return }

            let newIndent = min(currentIndent + 1, 4)  // Max 4 levels

            // Insert a tab at the start of the line
            attr.insert(NSAttributedString(string: "\t"), at: lineRange.location)

            // Update the line range and attributes
            let updatedLineRange = NSRange(location: lineRange.location, length: lineRange.length + 1)

            let paragraphStyle = NSMutableParagraphStyle()
            let baseIndent: CGFloat = 20 + CGFloat(newIndent) * 20  // 20pt base + nested indent
            paragraphStyle.firstLineHeadIndent = baseIndent
            paragraphStyle.headIndent = baseIndent + (isNumbered ? 24 : 20)  // Numbered lists need more space
            paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
            paragraphStyle.lineSpacing = fontSize * 0.5

            attr.addAttribute(.listIndentLevel, value: newIndent, range: updatedLineRange)
            attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: updatedLineRange)

            // Update typing attributes
            var typingAttrs = textView.typingAttributes
            typingAttrs[.listIndentLevel] = newIndent
            typingAttrs[.paragraphStyle] = paragraphStyle
            textView.typingAttributes = typingAttrs
        }

        private func decreaseIndent(in attr: NSMutableAttributedString, at range: NSRange, textView: UITextView) {
            let lineRange = getLineRange(for: range, in: attr.string)
            let lineText = (attr.string as NSString).substring(with: lineRange)

            // Get current indent level
            var currentIndent = 0
            if lineRange.location < attr.length {
                currentIndent = attr.attribute(.listIndentLevel, at: lineRange.location, effectiveRange: nil) as? Int ?? 0
            }

            let isBullet = attr.attribute(.bulletList, at: lineRange.location, effectiveRange: nil) as? Bool ?? false
            let isNumbered = attr.attribute(.numberedList, at: lineRange.location, effectiveRange: nil) as? Bool ?? false

            // Only outdent if in a list and indented
            guard (isBullet || isNumbered) && currentIndent > 0 else { return }

            let newIndent = currentIndent - 1

            // Remove a tab from the start of the line if present
            if lineText.hasPrefix("\t") {
                attr.deleteCharacters(in: NSRange(location: lineRange.location, length: 1))

                let updatedLineRange = NSRange(location: lineRange.location, length: lineRange.length - 1)

                let paragraphStyle = NSMutableParagraphStyle()
                let baseIndent: CGFloat = 20 + CGFloat(newIndent) * 20  // 20pt base + nested indent
                paragraphStyle.firstLineHeadIndent = baseIndent
                paragraphStyle.headIndent = baseIndent + (isNumbered ? 24 : 20)  // Numbered lists need more space
                paragraphStyle.paragraphSpacing = 0  // Minimal spacing - line height provides visual separation
                paragraphStyle.lineSpacing = fontSize * 0.5

                if updatedLineRange.length > 0 {
                    attr.addAttribute(.listIndentLevel, value: newIndent, range: updatedLineRange)
                    attr.addAttribute(.paragraphStyle, value: paragraphStyle, range: updatedLineRange)
                }

                // Update typing attributes
                var typingAttrs = textView.typingAttributes
                typingAttrs[.listIndentLevel] = newIndent
                typingAttrs[.paragraphStyle] = paragraphStyle
                textView.typingAttributes = typingAttrs
            }
        }

        private func toggleBold(in attr: NSMutableAttributedString, range: NSRange, textView: UITextView) {
            guard range.length > 0 else {
                // Toggle for typing
                var typingAttrs = textView.typingAttributes
                if typingAttrs[.isBold] as? Bool == true {
                    typingAttrs.removeValue(forKey: .isBold)
                    typingAttrs[.font] = UIFont.systemFont(ofSize: fontSize)
                } else {
                    typingAttrs[.isBold] = true
                    typingAttrs[.font] = UIFont.boldSystemFont(ofSize: fontSize)
                }
                textView.typingAttributes = typingAttrs
                return
            }

            let currentAttrs = attr.attributes(at: range.location, effectiveRange: nil)
            let isBold = currentAttrs[.isBold] as? Bool == true

            if isBold {
                attr.removeAttribute(.isBold, range: range)
                attr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: range)
            } else {
                attr.addAttribute(.isBold, value: true, range: range)
                attr.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: fontSize), range: range)
            }
        }

        private func toggleItalic(in attr: NSMutableAttributedString, range: NSRange, textView: UITextView) {
            guard range.length > 0 else {
                var typingAttrs = textView.typingAttributes
                if typingAttrs[.isItalic] as? Bool == true {
                    typingAttrs.removeValue(forKey: .isItalic)
                    typingAttrs[.font] = UIFont.systemFont(ofSize: fontSize)
                } else {
                    typingAttrs[.isItalic] = true
                    typingAttrs[.font] = UIFont.italicSystemFont(ofSize: fontSize)
                }
                textView.typingAttributes = typingAttrs
                return
            }

            let currentAttrs = attr.attributes(at: range.location, effectiveRange: nil)
            let isItalic = currentAttrs[.isItalic] as? Bool == true

            if isItalic {
                attr.removeAttribute(.isItalic, range: range)
                attr.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize), range: range)
            } else {
                attr.addAttribute(.isItalic, value: true, range: range)
                attr.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: fontSize), range: range)
            }
        }

        private func getLineRange(for range: NSRange, in string: String) -> NSRange {
            let nsString = string as NSString
            let lineRange = nsString.lineRange(for: range)
            return lineRange
        }
    }
}

// Custom attribute keys
extension NSAttributedString.Key {
    static let headingLevel = NSAttributedString.Key("headingLevel")
    static let blockquote = NSAttributedString.Key("blockquote")
    static let bulletList = NSAttributedString.Key("bulletList")
    static let numberedList = NSAttributedString.Key("numberedList")
    static let listIndentLevel = NSAttributedString.Key("listIndentLevel")
    static let isBold = NSAttributedString.Key("isBold")
    static let isItalic = NSAttributedString.Key("isItalic")
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
