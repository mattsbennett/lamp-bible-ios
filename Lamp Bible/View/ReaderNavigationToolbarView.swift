//
//  ReaderNavigationToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI

struct ReaderNavigationToolbarView: ToolbarContent {
    @Environment(\.dismiss) var dismiss
    @Binding var userSettings: UserSettings
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var translationId: String
    @Binding var translationAbbreviation: String
    @Binding var currentVerseId: Int
    @Binding var showingBookPicker: Bool
    @Binding var showingOptionsMenu: Bool
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    let readerDismiss: DismissAction
    var onHideToolbars: (() -> Void)? = nil

    // Horizontal split integration
    var isHorizontalSplit: Bool = false
    @Binding var toolPanelMode: ToolPanelMode
    var toolDisplayName: String = ""
    @Binding var isScrollLinked: Bool
    @Binding var toolFontSize: Int
    var onHideToolPanel: (() -> Void)? = nil
    var onToggleSplitOrientation: (() -> Void)? = nil

    // Tool module selection (shared with ToolPanelView via AppStorage)
    @AppStorage("selectedNotesModuleId") private var notesModuleId: String = "notes"
    @AppStorage("selectedCommentarySeries") private var selectedCommentarySeries: String = ""
    @AppStorage("selectedDevotionalsModuleId") private var devotionalsModuleId: String = "devotionals"

    // Available modules (passed from parent)
    var notesModules: [Module] = []
    var commentarySeries: [String] = []
    var devotionalsModules: [Module] = []

    // Theme editing callback (to present sheet from parent view)
    var onEditTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)? = nil

    init(
        userSettings: Binding<UserSettings>,
        readingMetaData: Binding<[ReadingMetaData]?>,
        translationId: Binding<String>,
        translationAbbreviation: Binding<String>,
        currentVerseId: Binding<Int>,
        showingBookPicker: Binding<Bool>,
        showingOptionsMenu: Binding<Bool>,
        readerDismiss: DismissAction,
        onHideToolbars: (() -> Void)? = nil,
        isHorizontalSplit: Bool = false,
        toolPanelMode: Binding<ToolPanelMode> = .constant(.commentary),
        toolDisplayName: String = "",
        isScrollLinked: Binding<Bool> = .constant(true),
        toolFontSize: Binding<Int> = .constant(16),
        onHideToolPanel: (() -> Void)? = nil,
        onToggleSplitOrientation: (() -> Void)? = nil,
        notesModules: [Module] = [],
        commentarySeries: [String] = [],
        devotionalsModules: [Module] = [],
        onEditTheme: ((HighlightColor, HighlightStyle, HighlightTheme?) -> Void)? = nil
    ) {
        _userSettings = userSettings
        _readingMetaData = readingMetaData
        _translationId = translationId
        _translationAbbreviation = translationAbbreviation
        _currentVerseId = currentVerseId
        _showingBookPicker = showingBookPicker
        _showingOptionsMenu = showingOptionsMenu
        self.readerDismiss = readerDismiss
        self.onHideToolbars = onHideToolbars
        self.isHorizontalSplit = isHorizontalSplit
        _toolPanelMode = toolPanelMode
        self.toolDisplayName = toolDisplayName
        _isScrollLinked = isScrollLinked
        _toolFontSize = toolFontSize
        self.onHideToolPanel = onHideToolPanel
        self.onToggleSplitOrientation = onToggleSplitOrientation
        self.notesModules = notesModules
        self.commentarySeries = commentarySeries
        self.devotionalsModules = devotionalsModules
        self.onEditTheme = onEditTheme
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                readerDismiss()
            } label: {
                Image(systemName: "arrow.backward")
            }
        }
        ToolbarItem(placement: .principal) {
            if isHorizontalSplit {
                // Menu with Bible and Tool selection
                Menu {
                    // Bible section
                    Section("Bible") {
                        if readingMetaData == nil {
                            Button {
                                showingBookPicker = true
                            } label: {
                                Label("Change Book/Chapter", systemImage: "book")
                            }
                        }
                    }

                    // Tool section
                    Section("Tools") {
                        // Notes modules
                        if !notesModules.isEmpty {
                            ForEach(notesModules, id: \.id) { module in
                                Button {
                                    notesModuleId = module.id
                                    toolPanelMode = .notes
                                } label: {
                                    if toolPanelMode == .notes && notesModuleId == module.id {
                                        Label(module.name, systemImage: "checkmark")
                                    } else {
                                        Text(module.name)
                                    }
                                }
                            }
                        }

                        // Commentary series
                        if !commentarySeries.isEmpty {
                            Divider()
                            ForEach(commentarySeries, id: \.self) { series in
                                Button {
                                    selectedCommentarySeries = series
                                    toolPanelMode = .commentary
                                } label: {
                                    if toolPanelMode == .commentary && selectedCommentarySeries == series {
                                        Label(series, systemImage: "checkmark")
                                    } else {
                                        Text(series)
                                    }
                                }
                            }
                        }

                        // Devotionals modules
                        if !devotionalsModules.isEmpty {
                            Divider()
                            ForEach(devotionalsModules, id: \.id) { module in
                                Button {
                                    devotionalsModuleId = module.id
                                    toolPanelMode = .devotionals
                                } label: {
                                    if toolPanelMode == .devotionals && devotionalsModuleId == module.id {
                                        Label(module.name, systemImage: "checkmark")
                                    } else {
                                        Text(module.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    // Combined view: Translation + Book | Tool
                    let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)
                    let book = try? BundledModuleDatabase.shared.getBook(id: currentBook)

                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            Text(translationAbbreviation).bold().font(.system(size: 14))
                            Text((book?.name ?? "") + " \(currentChapter)").font(.caption2).foregroundStyle(Color.primary)
                        }
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 1, height: 24)
                        VStack(spacing: 0) {
                            Text(toolPanelMode.rawValue).bold().font(.system(size: 14))
                            Text(toolDisplayName).font(.caption2).foregroundStyle(Color.primary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .modifier(ConditionalGlassButtonStyle())
            } else {
                // Standard button: Translation + Book only - opens book picker
                Button {
                    if readingMetaData == nil {
                        showingBookPicker = true
                    }
                } label: {
                    VStack {
                        let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)
                        let book = try? BundledModuleDatabase.shared.getBook(id: currentBook)
                        Text(translationAbbreviation).bold().font(.system(size: 14))
                        Text((book?.name ?? "") + " \(currentChapter)").font(.caption2).foregroundStyle(Color.primary)
                    }
                    .padding(.horizontal, 4)
                }
                .disabled(readingMetaData != nil)
                .modifier(ConditionalGlassButtonStyle())
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                showingOptionsMenu = true
            } label: {
                Image(systemName: "ellipsis")
            }
            .popover(isPresented: $showingOptionsMenu) {
                optionsMenuContent
            }
        }
    }

    @ViewBuilder
    private var optionsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Highlights section
            highlightsSectionContent

            // Bible options section
            VStack(alignment: .leading, spacing: 0) {
                if let hideToolbars = onHideToolbars {
                    Button {
                        showingOptionsMenu = false
                        hideToolbars()
                    } label: {
                        Label("Hide Toolbars", systemImage: "eye.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()
                }

                if !isHorizontalSplit {
                    // Show/Hide Tools only when not in horizontal split (tool panel has its own controls then)
                    Button {
                        notesPanelVisible.toggle()
                    } label: {
                        Label(
                            notesPanelVisible ? "Hide Tools" : "Show Tools",
                            systemImage: notesPanelVisible ? "rectangle.portrait" : "inset.filled.bottomhalf.rectangle.portrait"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Bible font size controls
            HStack(spacing: 0) {
                Button {
                    if userSettings.readerFontSize > 12 {
                        try? UserDatabase.shared.updateSettings { settings in
                            settings.readerFontSize = settings.readerFontSize - 2
                        }
                        userSettings.readerFontSize -= 2
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(userSettings.readerFontSize <= 12)

                Divider()
                    .frame(height: 20)

                Button {
                    if userSettings.readerFontSize < 30 {
                        try? UserDatabase.shared.updateSettings { settings in
                            settings.readerFontSize = settings.readerFontSize + 2
                        }
                        userSettings.readerFontSize += 2
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(userSettings.readerFontSize >= 30)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Tool options section (only in horizontal split mode)
            if isHorizontalSplit {
                // Section header
                Text("Tool Panel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 0) {
                    // Scroll link toggle
                    Button {
                        isScrollLinked.toggle()
                    } label: {
                        Label(
                            isScrollLinked ? "Unlink Scroll" : "Link Scroll",
                            systemImage: isScrollLinked ? "link.circle.fill" : "link.circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    // Split orientation toggle
                    if let toggleOrientation = onToggleSplitOrientation {
                        Button {
                            showingOptionsMenu = false
                            toggleOrientation()
                        } label: {
                            Label("Split Below", systemImage: "rectangle.split.1x2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Divider()
                    }

                    // Hide tool panel
                    if let hidePanel = onHideToolPanel {
                        Button {
                            showingOptionsMenu = false
                            hidePanel()
                        } label: {
                            Label("Hide Tools", systemImage: "rectangle.portrait")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)

                // Tool font size controls
                HStack(spacing: 0) {
                    Button {
                        if toolFontSize > 12 {
                            toolFontSize -= 2
                        }
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(toolFontSize <= 12)

                    Divider()
                        .frame(height: 20)

                    Button {
                        if toolFontSize < 24 {
                            toolFontSize += 2
                        }
                    } label: {
                        Image(systemName: "textformat.size.larger")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(toolFontSize >= 24)
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)
            }
        }
        .font(.body)
        .fontWeight(.regular)
        .padding(12)
        .background(Color(UIColor.systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private var highlightsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Style and color picker
            InlineHighlightPicker(onEditTheme: onEditTheme != nil ? { color, style, existingTheme in
                showingOptionsMenu = false
                // Small delay to let popover dismiss before showing sheet
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onEditTheme?(color, style, existingTheme)
                }
            } : nil)

            Divider()
                .padding(.horizontal, 8)

            // Highlight set chooser
            if !HighlightManager.shared.availableSets.isEmpty {
                Menu {
                    ForEach(HighlightManager.shared.availableSets, id: \.id) { set in
                        Button {
                            HighlightManager.shared.selectSet(set.id)
                        } label: {
                            if HighlightManager.shared.activeSetId == set.id {
                                Label(set.name, systemImage: "checkmark")
                            } else {
                                Text(set.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label {
                            Text(HighlightManager.shared.availableSets.first { $0.id == HighlightManager.shared.activeSetId }?.name ?? "Select Set")
                        } icon: {
                            Image(systemName: "folder")
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 8)
            }

            // Show/Hide Highlights
            Button {
                HighlightManager.shared.highlightsHidden.toggle()
            } label: {
                Label {
                    Text(HighlightManager.shared.highlightsHidden ? "Show Highlights" : "Hide Highlights")
                } icon: {
                    if HighlightManager.shared.highlightsHidden {
                        Image(systemName: "highlighter")
                    } else {
                        Image("highlighter.slash")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }
}
