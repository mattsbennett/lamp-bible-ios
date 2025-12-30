//
//  ToolPanelView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import RealmSwift
import SwiftUI

enum ToolPanelMode: String, CaseIterable {
    case notes = "Notes"
    case crossRefs = "Cross References"
    case tske = "Treasury of Scripture Knowledge (Enhanced)"
}

// Non-reactive position storage to avoid triggering re-renders during scroll
private class ToolPanelPositionTracker {
    var positions: [Int: CGFloat] = [:]
}

// Lightweight scroll debouncer that avoids Task creation overhead
private class ToolPanelScrollDebouncer {
    private var workItem: DispatchWorkItem?

    func debounce(delay: TimeInterval, action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
    }
}

struct ToolPanelView: View {
    let book: Int
    let chapter: Int
    let currentVerse: Int
    @Binding var scrollToVerse: Int?
    @ObservedRealmObject var user: User
    var onNavigateToVerse: ((Int) -> Void)?
    var onVisibleVerseChanged: ((Int) -> Void)?

    @AppStorage("toolPanelMode") private var panelMode: ToolPanelMode = .crossRefs
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("bottomToolbarMode") private var bottomToolbarMode: BottomToolbarMode = .navigation
    private let scrollDebouncer = ToolPanelScrollDebouncer()
    @State private var lastReportedVerse: Int = 0
    private let positionTracker = ToolPanelPositionTracker()
    @State private var isProgrammaticScroll: Bool = false
    @State private var note: Note?
    @State private var sections: [NoteSection] = []
    @State private var isLoading: Bool = true
    @State private var saveState: SaveState = .idle
    @State private var showingAddVerseSheet: Bool = false
    @State private var newVerseStart: Int = 1
    @State private var newVerseEnd: Int? = nil
    @State private var overlappingSection: NoteSection? = nil
    @State private var saveTask: Task<Void, Never>?

    // Editing state
    @State private var editingSection: NoteSection? = nil
    @State private var editingSectionIndex: Int? = nil
    @State private var editVerseStart: Int = 1
    @State private var editVerseEnd: Int? = nil
    @State private var editOverlappingSection: NoteSection? = nil

    // Locking state
    @AppStorage("notesIsReadOnly") private var isReadOnly: Bool = true
    @State private var showingLockConflict: Bool = false
    @State private var lockConflictInfo: (lockedBy: String, lockedAt: Date)?
    @State private var lockRefreshTask: Task<Void, Never>?

    // Conflict state
    @State private var showingConflictResolution: Bool = false
    @State private var currentConflict: NoteConflict?

    // Keyboard state (to disable scroll-linking while editing)
    @State private var isKeyboardVisible: Bool = false

    // UI state
    @State private var isMaximized: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @AppStorage("notesFontSize") private var notesFontSize: Int = 16
    @State private var animateToolPaneScroll: Bool = true

    // Sync status
    @State private var syncStatus: ICloudNoteStorage.SyncStatus = .synced
    @State private var syncCheckTask: Task<Void, Never>?

    private let storage = ICloudNoteStorage.shared
    private let lockRefreshInterval: UInt64 = 60_000_000_000 // 60 seconds in nanoseconds

    var bookName: String {
        RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first?.name ?? "Unknown"
    }

    var maxVerseInChapter: Int {
        RealmManager.shared.realm.objects(Verse.self)
            .filter("b == \(book) AND c == \(chapter)")
            .max(ofProperty: "v") ?? 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if user.notesEnabled {
                    Menu {
                        Picker("Mode", selection: $panelMode) {
                            ForEach(ToolPanelMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(panelMode.rawValue)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .modifier(ConditionalGlassButtonStyle())
                } else {
                    Text("Cross References")
                        .modifier(ConditionalGlassButtonStyle())
                }

                Spacer()

                if user.notesEnabled && panelMode == .notes {
                    notesStatusIndicator
                }

                // Options menu
                Button {
                    showingOptionsMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .padding(.horizontal, 3)
                        .padding(.vertical, 8)
                }
                .modifier(ConditionalGlassButtonStyle())
                .popover(isPresented: $showingOptionsMenu) {
                    optionsMenuContent
                }
            }
            .padding(.horizontal)
            .padding(.top, 2)
            .padding(.bottom, 6)

            if user.notesEnabled && panelMode == .notes {
                notesContent
            } else if panelMode == .tske {
                tskeContent
            } else {
                crossRefsContent
            }
        }
        .sheet(isPresented: $isMaximized) {
            maximizedNotesSheet
        }
        .sheet(isPresented: Binding(
            get: { !isMaximized && showingAddVerseSheet },
            set: { showingAddVerseSheet = $0 }
        )) {
            addVerseSheet
        }
        .sheet(item: Binding(
            get: { isMaximized ? nil : editingSection },
            set: { editingSection = $0 }
        )) { _ in
            editVerseSheet
        }
        .sheet(isPresented: $showingLockConflict) {
            if let info = lockConflictInfo {
                LockConflictView(
                    lockedBy: info.lockedBy,
                    lockedAt: info.lockedAt,
                    bookName: bookName,
                    chapter: chapter,
                    onAction: handleLockAction
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showingConflictResolution) {
            if let conflict = currentConflict {
                ConflictResolutionView(
                    conflict: conflict,
                    bookName: bookName,
                    onResolve: { versionId in
                        Task { await resolveConflict(keepVersionId: versionId) }
                    },
                    onCancel: {
                        showingConflictResolution = false
                        currentConflict = nil
                    }
                )
            }
        }
        .task {
            await loadNote()
        }
        .task {
            // Periodically check sync status while panel is visible
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                guard !Task.isCancelled else { break }
                await checkSyncStatus()
            }
        }
        .onChange(of: book) { _, _ in
            positionTracker.positions = [:]
            lastReportedVerse = 0
            animateToolPaneScroll = false  // Don't animate on chapter change
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
            // Scroll to current verse after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollToVerse = currentVerse
            }
        }
        .onChange(of: chapter) { _, _ in
            positionTracker.positions = [:]
            lastReportedVerse = 0
            animateToolPaneScroll = false  // Don't animate on chapter change
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
            // Scroll to current verse after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollToVerse = currentVerse
            }
        }
        .onDisappear {
            lockRefreshTask?.cancel()
            Task { await releaseLockIfNeeded() }
        }
        .toolbar {
            // Hide keyboard toolbar when bottom toolbar is in search mode
            if bottomToolbarMode != .search {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onAppear {
            isReadOnly = true // Default to read-only when panel opens
        }
        .onChange(of: panelMode) { _, _ in
            // Clear position tracking when switching modes to prevent stale data
            positionTracker.positions = [:]
            lastReportedVerse = 0
            // Suppress scroll detection and scroll tool pane to match Bible pane's current verse
            isProgrammaticScroll = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                scrollToVerse = currentVerse
            }
        }
    }

    private var optionsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Notes mode options
            if user.notesEnabled && panelMode == .notes {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        isReadOnly.toggle()
                        showingOptionsMenu = false
                    } label: {
                        Label(
                            isReadOnly ? "Edit" : "Read-Only",
                            systemImage: isReadOnly ? "square.and.pencil" : "book"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    Button {
                        showingOptionsMenu = false
                        isMaximized = true
                    } label: {
                        Label("Maximize", systemImage: "arrow.up.left.and.arrow.down.right")
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

            // Scroll link toggle
            Button {
                isScrollLinked.toggle()
                showingOptionsMenu = false
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
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Hide
            Button {
                showingOptionsMenu = false
                if user.notesEnabled && panelMode == .notes {
                    isReadOnly = true
                }
                try? RealmManager.shared.realm.write {
                    guard let thawedUser = user.thaw() else { return }
                    thawedUser.notesPanelVisible = false
                }
            } label: {
                Label("Hide Tools", systemImage: "rectangle.portrait")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Font size controls - compact row
            HStack(spacing: 0) {
                Button {
                    if notesFontSize > 12 {
                        notesFontSize -= 2
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notesFontSize <= 12)

                Divider()
                    .frame(height: 20)

                Button {
                    if notesFontSize < 24 {
                        notesFontSize += 2
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(notesFontSize >= 24)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .font(.body)
        .fontWeight(.regular)
        .padding(12)
        .background(Color(UIColor.systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
    }

    @State private var showingStatusPopover: Bool = false
    @State private var showingMaximizedStatusPopover: Bool = false

    @ViewBuilder
    private var notesStatusIndicator: some View {
        Button {
            showingStatusPopover = true
        } label: {
            HStack(spacing: 4) {
                // Save state icon
                switch saveState {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .saving:
                    ProgressView()
                        .scaleEffect(0.6)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }

                // Sync status icon
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
            .padding(.vertical, 1.2)
        }
        .modifier(ConditionalGlassButtonStyle())
        .popover(isPresented: $showingStatusPopover) {
            statusPopoverContent
        }
    }

    @ViewBuilder
    private var statusPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Save status row
            HStack {
                switch saveState {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("No unsaved changes")
                case .saving:
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved")
                case .error(let message):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // Sync status row
            HStack {
                switch syncStatus {
                case .synced:
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                    Text("Synced to iCloud")
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(.secondary)
                    Text("Syncing to iCloud...")
                case .notSynced:
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text("Waiting to sync")
                case .notAvailable:
                    Image(systemName: "xmark.icloud")
                        .foregroundStyle(.red)
                    Text("iCloud unavailable")
                }
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    private var maximizedNotesSheet: some View {
        NavigationStack {
            notesContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 12) {
                            Text("\(bookName) \(chapter)")
                                .font(.headline)

                            Button {
                                showingMaximizedStatusPopover = true
                            } label: {
                                HStack(spacing: 4) {
                                    // Save state icon
                                    switch saveState {
                                    case .idle, .saved:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .saving:
                                        ProgressView()
                                            .scaleEffect(0.6)
                                    case .error:
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }

                                    // Sync status icon
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
                                .imageScale(.small)
                            }
                            .popover(isPresented: $showingMaximizedStatusPopover) {
                                statusPopoverContent
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            isMaximized = false
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            isReadOnly.toggle()
                        } label: {
                            Image(systemName: isReadOnly ? "square.and.pencil" : "book")
                        }
                    }
                }
                .sheet(isPresented: $showingAddVerseSheet) {
                    addVerseSheet
                }
                .sheet(item: $editingSection) { _ in
                    editVerseSheet
                }
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else {
            let gaps = verseGaps()
            // Build sorted verse list from sections for scroll detection
            let sortedNoteVerses = sections.compactMap { $0.verseStart }.sorted()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections.indices, id: \.self) { index in
                            let section = sections[index]

                            // Show gap button before this section (if there's a gap)
                            if !isReadOnly && !section.isGeneral {
                                if let gap = gaps.first(where: { $0.after == nil && section.verseStart == $0.gapEnd + 1 }) {
                                    gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                                } else if let prevIndex = sections.prefix(index).lastIndex(where: { !$0.isGeneral }),
                                          let prevEnd = sections[prevIndex].verseEnd ?? sections[prevIndex].verseStart,
                                          let gap = gaps.first(where: { $0.after == prevEnd }) {
                                    gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                                }
                            }

                            NoteSectionView(
                                section: $sections[index],
                                isReadOnly: isReadOnly,
                                fontSize: notesFontSize,
                                translation: user.readerTranslation!,
                                onContentChange: { scheduleSave() },
                                onNavigateToVerse: { verse in
                                    // Close maximized sheet if open
                                    if isMaximized {
                                        isMaximized = false
                                    }
                                    // Construct full verseId from verse number within current chapter
                                    let verseId = book * 1000000 + chapter * 1000 + verse
                                    onNavigateToVerse?(verseId)
                                },
                                onNavigateToVerseId: { verseId in
                                    // Close maximized sheet if open
                                    if isMaximized {
                                        isMaximized = false
                                    }
                                    onNavigateToVerse?(verseId)
                                },
                                onEditVerseRange: section.isGeneral ? nil : {
                                    startEditingSection(section, at: index)
                                }
                            )
                            .id(sections[index].id)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear {
                                            if let verseStart = section.verseStart {
                                                positionTracker.positions[verseStart] = geo.frame(in: .named("notesScroll")).origin.y
                                            }
                                        }
                                        .onChange(of: geo.frame(in: .named("notesScroll")).origin.y) { _, newY in
                                            if let verseStart = section.verseStart {
                                                positionTracker.positions[verseStart] = newY
                                            }
                                        }
                                }
                            )
                        }

                        // Show "No verse notes" placeholder in read-only mode when no verse sections exist
                        if isReadOnly && !sections.contains(where: { !$0.isGeneral }) {
                            Text("No verse notes")
                                .font(.system(size: CGFloat(notesFontSize)))
                                .foregroundStyle(.tertiary)
                        }

                        // Show gap button after last verse section (only when verse sections exist)
                        if !isReadOnly {
                            if let lastVerseSection = sections.last(where: { !$0.isGeneral }),
                               let lastEnd = lastVerseSection.verseEnd ?? lastVerseSection.verseStart,
                               let gap = gaps.first(where: { $0.after == lastEnd }) {
                                gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                            }
                        }

                        // General add verse button (only shown when no verse notes exist)
                        if !isReadOnly && !sections.contains(where: { !$0.isGeneral }) {
                            Button {
                                showingAddVerseSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Add verse note")
                                }
                                .foregroundColor(.accentColor)
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: "notesScroll")
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { [self] _, _ in
                    // Don't scroll-link while keyboard is visible or if disabled
                    guard isScrollLinked && !isProgrammaticScroll && !isKeyboardVisible else { return }

                    scrollDebouncer.debounce(delay: 0.5) { [self] in
                        // Double-check flag inside callback (may have changed during debounce)
                        guard !isProgrammaticScroll else { return }

                        var foundVerse: Int? = nil
                        let positions = positionTracker.positions
                        for verse in sortedNoteVerses {
                            if let yPos = positions[verse] {
                                if yPos <= 50 {
                                    foundVerse = verse
                                }
                            }
                        }

                        if let verse = foundVerse, verse != lastReportedVerse {
                            lastReportedVerse = verse
                            onVisibleVerseChanged?(verse)
                        }
                    }
                }
                .scrollDismissesKeyboard(.never)
                .onChange(of: scrollToVerse) { _, newVerse in
                    // Don't scroll-link while keyboard is visible (user is editing)
                    guard !isKeyboardVisible else {
                        scrollToVerse = nil
                        return
                    }
                    if let verse = newVerse {
                        isProgrammaticScroll = true
                        // Try exact verse first
                        if let sectionId = findSectionId(forVerse: verse) {
                            if animateToolPaneScroll {
                                withAnimation {
                                    proxy.scrollTo(sectionId, anchor: .top)
                                }
                            } else {
                                proxy.scrollTo(sectionId, anchor: .top)
                            }
                        }
                        scrollToVerse = nil
                        animateToolPaneScroll = true  // Reset for future scrolls
                        // Reset programmatic scroll flag after animation + debounce time
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isProgrammaticScroll = false
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gapAddButton(gapStart: Int, gapEnd: Int) -> some View {
        Button {
            addVerseSectionWithRange(start: gapStart, end: gapEnd > gapStart ? gapEnd : nil)
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                if gapStart == gapEnd {
                    Text("Add note for verse \(gapStart)")
                } else {
                    Text("Add note for verses \(gapStart)-\(gapEnd)")
                }
            }
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var crossRefsContent: some View {
        // Get all verse IDs in this chapter that have cross references
        let chapterStart = book * 1000000 + chapter * 1000 + 1
        let chapterEnd = book * 1000000 + chapter * 1000 + 999
        let allCrossRefs = RealmManager.shared.realm.objects(CrossReference.self)
            .filter("id >= \(chapterStart) AND id <= \(chapterEnd)")
            .sorted(byKeyPath: "id", ascending: true)

        // Group cross refs by verse
        let groupedRefs = Dictionary(grouping: Array(allCrossRefs)) { crossRef in
            crossRef.id % 1000 // Extract verse number from id
        }
        let sortedVerses = groupedRefs.keys.sorted()

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if sortedVerses.isEmpty {
                        Text("No cross references for this chapter")
                            .font(.system(size: CGFloat(notesFontSize)))
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(sortedVerses, id: \.self) { verse in
                            if let refs = groupedRefs[verse] {
                                VStack(alignment: .leading, spacing: 8) {
                                    // Verse header
                                    Text("Verse \(verse)")
                                        .font(.headline)

                                    // Cross references as comma-separated buttons
                                    CrossRefFlowView(
                                        crossRefs: refs.sorted { $0.r < $1.r },
                                        translation: user.readerTranslation!,
                                        fontSize: notesFontSize,
                                        onNavigateToVerse: onNavigateToVerse
                                    )
                                }
                                .id("crossref_v\(verse)")
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .onAppear {
                                                positionTracker.positions[verse] = geo.frame(in: .named("crossRefScroll")).origin.y
                                            }
                                            .onChange(of: geo.frame(in: .named("crossRefScroll")).origin.y) { _, newY in
                                                positionTracker.positions[verse] = newY
                                            }
                                    }
                                )
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "crossRefScroll")
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { [self] _, _ in
                guard isScrollLinked && !isProgrammaticScroll else { return }

                scrollDebouncer.debounce(delay: 0.5) { [self] in
                    // Double-check flag inside callback (may have changed during debounce)
                    guard !isProgrammaticScroll else { return }

                    var foundVerse: Int? = nil
                    let positions = positionTracker.positions
                    for verse in sortedVerses {
                        if let yPos = positions[verse] {
                            if yPos <= 50 {
                                foundVerse = verse
                            }
                        }
                    }

                    if let verse = foundVerse, verse != lastReportedVerse {
                        lastReportedVerse = verse
                        onVisibleVerseChanged?(verse)
                    }
                }
            }
            .onChange(of: scrollToVerse) { _, newVerse in
                // Don't scroll-link while keyboard is visible
                guard !isKeyboardVisible else {
                    scrollToVerse = nil
                    return
                }
                if let verse = newVerse, groupedRefs[verse] != nil {
                    isProgrammaticScroll = true
                    if animateToolPaneScroll {
                        withAnimation {
                            proxy.scrollTo("crossref_v\(verse)", anchor: .top)
                        }
                    } else {
                        proxy.scrollTo("crossref_v\(verse)", anchor: .top)
                    }
                    scrollToVerse = nil
                    animateToolPaneScroll = true  // Reset for future scrolls
                    // Reset programmatic scroll flag after animation + debounce time
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isProgrammaticScroll = false
                    }
                }
            }
            .onChange(of: currentVerse) { _, newVerse in
                // Auto-scroll when current verse changes (from Bible panel scroll)
                guard !isKeyboardVisible else { return }
                guard isScrollLinked else { return }
                guard !isProgrammaticScroll else { return }  // Prevent feedback loop
                if groupedRefs[newVerse] != nil {
                    isProgrammaticScroll = true
                    if animateToolPaneScroll {
                        withAnimation {
                            proxy.scrollTo("crossref_v\(newVerse)", anchor: .top)
                        }
                    } else {
                        proxy.scrollTo("crossref_v\(newVerse)", anchor: .top)
                        animateToolPaneScroll = true  // Reset for future scrolls
                    }
                    // Reset programmatic scroll flag after animation + debounce time
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isProgrammaticScroll = false
                    }
                }
            }
        }
    }

    // MARK: - TSKe Content

    @ViewBuilder
    private var tskeContent: some View {
        // Get TSKe data for this chapter
        let tskBook = RealmManager.shared.realm.objects(TSKBook.self).filter("b == \(book)").first
        let tskChapter = RealmManager.shared.realm.objects(TSKChapter.self).filter("b == \(book) AND c == \(chapter)").first

        // Get all verse entries for this chapter
        let chapterStart = book * 1000000 + chapter * 1000 + 1
        let chapterEnd = book * 1000000 + chapter * 1000 + 999
        let allTskVerses = RealmManager.shared.realm.objects(TSKVerse.self)
            .filter("id >= \(chapterStart) AND id <= \(chapterEnd)")
            .sorted(byKeyPath: "id", ascending: true)

        // Extract verse numbers for scroll tracking
        let sortedVerses = allTskVerses.map { $0.id % 1000 }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // Book introduction (only for chapter 1)
                    if chapter == 1, let bookIntro = tskBook?.t, !bookIntro.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Book Introduction")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(bookIntro)
                                .font(.system(size: CGFloat(notesFontSize)))
                        }
                        .padding(.bottom, 8)

                        Divider()
                    }

                    // Chapter overview (with parsed segments)
                    if let chapter = tskChapter, !chapter.segmentsJson.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Chapter Overview")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            TSKSegmentsView(
                                segmentsJson: chapter.segmentsJson,
                                translation: user.readerTranslation!,
                                fontSize: notesFontSize,
                                onNavigateToVerse: onNavigateToVerse
                            )
                        }
                        .padding(.bottom, 8)

                        if !allTskVerses.isEmpty {
                            Divider()
                        }
                    }

                    // Verse topics - using isolated TSKVerseSection for better performance
                    if allTskVerses.isEmpty && tskBook == nil && tskChapter == nil {
                        Text("No TSKe data for this chapter")
                            .font(.system(size: CGFloat(notesFontSize)))
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(Array(allTskVerses), id: \.id) { tskVerse in
                            let verseNum = tskVerse.id % 1000
                            TSKVerseSection(
                                verseId: tskVerse.id,
                                translation: user.readerTranslation!,
                                fontSize: notesFontSize,
                                onNavigateToVerse: onNavigateToVerse
                            )
                            .id("tske_\(tskVerse.id)")  // Use full verseId to force refresh on chapter change
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear {
                                            positionTracker.positions[verseNum] = geo.frame(in: .named("tskeScroll")).origin.y
                                        }
                                        .onChange(of: geo.frame(in: .named("tskeScroll")).origin.y) { _, newY in
                                            positionTracker.positions[verseNum] = newY
                                        }
                                }
                            )
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("tskeScroll_\(book)_\(chapter)")  // Force full refresh when book/chapter changes
            .coordinateSpace(name: "tskeScroll")
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { [self] _, _ in
                guard isScrollLinked && !isProgrammaticScroll else { return }

                scrollDebouncer.debounce(delay: 0.5) { [self] in
                    // Double-check flag inside callback (may have changed during debounce)
                    guard !isProgrammaticScroll else { return }

                    var foundVerse: Int? = nil
                    let positions = positionTracker.positions
                    for verse in sortedVerses {
                        if let yPos = positions[verse] {
                            if yPos <= 50 {
                                foundVerse = verse
                            }
                        }
                    }

                    if let verse = foundVerse, verse != lastReportedVerse {
                        lastReportedVerse = verse
                        onVisibleVerseChanged?(verse)
                    }
                }
            }
            .onChange(of: scrollToVerse) { _, newVerse in
                guard !isKeyboardVisible else {
                    scrollToVerse = nil
                    return
                }
                if let verse = newVerse {
                    // Check if this verse has TSKe data
                    let verseId = book * 1000000 + chapter * 1000 + verse
                    let hasData = allTskVerses.contains { $0.id == verseId }

                    if hasData {
                        isProgrammaticScroll = true
                        if animateToolPaneScroll {
                            withAnimation {
                                proxy.scrollTo("tske_\(verseId)", anchor: .top)
                            }
                        } else {
                            proxy.scrollTo("tske_\(verseId)", anchor: .top)
                        }
                        scrollToVerse = nil
                        animateToolPaneScroll = true
                        // Reset programmatic scroll flag after animation + debounce time
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            isProgrammaticScroll = false
                        }
                    } else {
                        scrollToVerse = nil
                    }
                }
            }
            .onChange(of: currentVerse) { _, newVerse in
                guard !isKeyboardVisible else { return }
                guard isScrollLinked else { return }
                guard !isProgrammaticScroll else { return }  // Prevent feedback loop

                let verseId = book * 1000000 + chapter * 1000 + newVerse
                let hasData = allTskVerses.contains { $0.id == verseId }

                if hasData {
                    isProgrammaticScroll = true
                    if animateToolPaneScroll {
                        withAnimation {
                            proxy.scrollTo("tske_\(verseId)", anchor: .top)
                        }
                    } else {
                        proxy.scrollTo("tske_\(verseId)", anchor: .top)
                        animateToolPaneScroll = true
                    }
                    // Reset programmatic scroll flag after animation + debounce time
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isProgrammaticScroll = false
                    }
                }
            }
        }
    }

    private var addVerseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start verse", selection: $newVerseStart) {
                        ForEach(1...maxVerseInChapter, id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }

                    Picker("End verse", selection: $newVerseEnd) {
                        Text("Single verse").tag(nil as Int?)
                        ForEach((newVerseStart + 1)...max(newVerseStart + 1, maxVerseInChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse as Int?)
                        }
                    }
                } header: {
                    Text("Verse")
                } footer: {
                    if let overlap = overlappingSection {
                        Text("This overlaps with existing note: \(overlap.displayTitle)")
                            .foregroundColor(.orange)
                    } else {
                        Text("Select a single verse or a range")
                    }
                }

                if overlappingSection != nil {
                    Section {
                        Button {
                            scrollToOverlappingSection()
                        } label: {
                            Label("Edit existing note instead", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationTitle("Add Verse Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddVerseSheet = false
                        resetAddVerseForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addVerseSection()
                    }
                    .disabled(overlappingSection != nil)
                }
            }
            .onChange(of: newVerseStart) { _, _ in
                // Reset end verse if it's now invalid
                if let end = newVerseEnd, end <= newVerseStart {
                    newVerseEnd = nil
                }
                checkForOverlap()
            }
            .onChange(of: newVerseEnd) { _, _ in
                checkForOverlap()
            }
            .onAppear {
                checkForOverlap()
            }
        }
        .presentationDetents([.medium])
    }

    private func findSectionId(forVerse verse: Int) -> String? {
        // First look for exact match (verse is within a section's range)
        for section in sections {
            if let start = section.verseStart, let end = section.verseEnd {
                if verse >= start && verse <= end {
                    return section.id
                }
            } else if let start = section.verseStart, start == verse {
                return section.id
            }
        }

        // No exact match - find the closest verse section
        let verseSections = sections.filter { !$0.isGeneral && $0.verseStart != nil }
        guard !verseSections.isEmpty else { return nil }

        var closestSection: NoteSection? = nil
        var closestDistance = Int.max

        for section in verseSections {
            guard let start = section.verseStart else { continue }
            let end = section.verseEnd ?? start

            // Calculate distance to this section
            let distance: Int
            if verse < start {
                distance = start - verse
            } else if verse > end {
                distance = verse - end
            } else {
                distance = 0 // Should have been caught above, but just in case
            }

            if distance < closestDistance {
                closestDistance = distance
                closestSection = section
            }
        }

        return closestSection?.id
    }

    private func loadNote() async {
        isLoading = true
        saveState = .idle
        lockRefreshTask?.cancel()

        do {
            // Check for conflicts first
            let conflicts = try await storage.checkForConflicts()
            if let conflict = conflicts.first(where: { $0.book == book && $0.chapter == chapter }) {
                currentConflict = conflict
                showingConflictResolution = true
            }

            if let loadedNote = try await storage.readNote(book: book, chapter: chapter) {
                note = loadedNote
                sections = NoteParser.parseSections(from: loadedNote.content)

                // Try to acquire lock for editing
                await tryAcquireLock()
            } else {
                // No note exists yet, create empty sections
                note = Note(book: book, chapter: chapter)
                sections = [.general(content: "")]
                // New notes don't need locking until first save
            }
        } catch {
            print("Failed to load note: \(error)")
            note = Note(book: book, chapter: chapter)
            sections = [.general(content: "")]
        }

        isLoading = false

        // Check sync status
        await checkSyncStatus()
    }

    private func checkSyncStatus() async {
        syncStatus = await storage.getSyncStatus(book: book, chapter: chapter)
    }

    private func tryAcquireLock() async {
        do {
            let result = try await storage.acquireLock(book: book, chapter: chapter)
            switch result {
            case .acquired, .alreadyLockedByMe:
                startLockRefresh()
            case .lockedByOther(let lockedBy, let lockedAt):
                lockConflictInfo = (lockedBy, lockedAt)
                showingLockConflict = true
            }
        } catch {
            print("Failed to acquire lock: \(error)")
        }
    }

    private func handleLockAction(_ action: LockAction) {
        showingLockConflict = false
        switch action {
        case .viewReadOnly:
            isReadOnly = true
        case .editAnyway:
            isReadOnly = false
            startLockRefresh()
        case .cancel:
            break
        }
    }

    private func startLockRefresh() {
        lockRefreshTask?.cancel()
        lockRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: lockRefreshInterval)
                guard !Task.isCancelled else { break }
                try? await storage.refreshLock(book: book, chapter: chapter)
            }
        }
    }

    private func releaseLockIfNeeded() async {
        lockRefreshTask?.cancel()
        if !isReadOnly {
            try? await storage.releaseLock(book: book, chapter: chapter)
        }
    }

    private func resolveConflict(keepVersionId: String) async {
        guard let conflict = currentConflict else { return }

        do {
            try await storage.resolveConflict(conflict, keepVersionId: keepVersionId)
            showingConflictResolution = false
            currentConflict = nil
            // Reload the note after conflict resolution
            await loadNote()
        } catch {
            print("Failed to resolve conflict: \(error)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveState = .idle

        saveTask = Task {
            // Debounce: wait 1 second before saving
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !Task.isCancelled else { return }

            await saveNote()
        }
    }

    private func saveNote() async {
        guard var currentNote = note else { return }
        guard !isReadOnly else { return } // Don't save in read-only mode

        saveState = .saving

        let content = NoteParser.serializeSections(sections)
        currentNote.content = content
        currentNote.modified = Date()

        // Preserve lock info if we have it
        if !isReadOnly {
            currentNote.lockedBy = Note.deviceId
            currentNote.lockedAt = Date()
        }

        do {
            let result = try await storage.writeNote(currentNote)

            switch result {
            case .success:
                note = currentNote
                saveState = .saved

                // Check sync status after save
                await checkSyncStatus()

                // Clear "Saved" indicator after 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .saved = saveState {
                    saveState = .idle
                }

            case .conflict(let conflict):
                saveState = .idle
                currentConflict = conflict
                showingConflictResolution = true

            case .lockedByOther(let lockedBy, let lockedAt):
                saveState = .error("Locked by another device")
                lockConflictInfo = (lockedBy, lockedAt)
                showingLockConflict = true
            }
        } catch {
            saveState = .error("Save failed")
            print("Failed to save note: \(error)")
        }
    }

    private func addVerseSection() {
        let start = newVerseStart
        let end = newVerseEnd ?? start
        let newSection: NoteSection

        if end != start && end > start {
            newSection = .verseRange(start: start, end: end, content: "")
        } else {
            newSection = .verse(start, content: "")
        }

        // Insert in sorted order (after general, sorted by verse number)
        var insertIndex = sections.count
        for (index, section) in sections.enumerated() {
            if let existingStart = section.verseStart {
                if start < existingStart {
                    insertIndex = index
                    break
                }
            }
        }

        sections.insert(newSection, at: insertIndex)
        scheduleSave()

        showingAddVerseSheet = false
        resetAddVerseForm()
    }

    private func resetAddVerseForm() {
        newVerseStart = 1
        newVerseEnd = nil
        overlappingSection = nil
    }

    private func checkForOverlap() {
        let start = newVerseStart
        let end = newVerseEnd ?? start

        // Check if any existing section overlaps with this range
        for section in sections {
            guard let sectionStart = section.verseStart else { continue }
            let sectionEnd = section.verseEnd ?? sectionStart

            // Check for overlap: ranges overlap if one starts before the other ends
            let overlaps = start <= sectionEnd && end >= sectionStart

            if overlaps {
                overlappingSection = section
                return
            }
        }

        overlappingSection = nil
    }

    private func scrollToOverlappingSection() {
        if let section = overlappingSection {
            let targetVerse = section.verseStart
            showingAddVerseSheet = false
            resetAddVerseForm()
            // Delay scroll until after sheet dismissal animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                scrollToVerse = targetVerse
            }
        }
    }

    // MARK: - Editing

    private var editVerseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start verse", selection: $editVerseStart) {
                        ForEach(1...maxVerseInChapter, id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }

                    Picker("End verse", selection: $editVerseEnd) {
                        Text("Single verse").tag(nil as Int?)
                        ForEach((editVerseStart + 1)...max(editVerseStart + 1, maxVerseInChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse as Int?)
                        }
                    }
                } header: {
                    Text("Verse")
                } footer: {
                    if let overlap = editOverlappingSection {
                        Text("This overlaps with existing note: \(overlap.displayTitle)")
                            .foregroundColor(.orange)
                    } else {
                        Text("Select a single verse or a range")
                    }
                }

                if editOverlappingSection != nil {
                    Section {
                        Button {
                            scrollToEditOverlappingSection()
                        } label: {
                            Label("Edit existing note instead", systemImage: "square.and.pencil")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        deleteEditingSection()
                    } label: {
                        Label("Delete this verse note", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Verse Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editingSection = nil
                        resetEditVerseForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEditedVerseRange()
                    }
                    .disabled(editOverlappingSection != nil)
                }
            }
            .onChange(of: editVerseStart) { _, _ in
                // Reset end verse if it's now invalid
                if let end = editVerseEnd, end <= editVerseStart {
                    editVerseEnd = nil
                }
                checkForEditOverlap()
            }
            .onChange(of: editVerseEnd) { _, _ in
                checkForEditOverlap()
            }
        }
        .presentationDetents([.medium])
    }

    private func startEditingSection(_ section: NoteSection, at index: Int) {
        editingSectionIndex = index
        editVerseStart = section.verseStart ?? 1
        editVerseEnd = section.verseEnd != section.verseStart ? section.verseEnd : nil
        editOverlappingSection = nil
        editingSection = section
    }

    private func resetEditVerseForm() {
        editingSectionIndex = nil
        editVerseStart = 1
        editVerseEnd = nil
        editOverlappingSection = nil
    }

    private func checkForEditOverlap() {
        guard let editingIndex = editingSectionIndex else { return }
        let start = editVerseStart
        let end = editVerseEnd ?? start

        // Check if any OTHER existing section overlaps with this range
        for (index, section) in sections.enumerated() {
            guard index != editingIndex else { continue }
            guard let sectionStart = section.verseStart else { continue }
            let sectionEnd = section.verseEnd ?? sectionStart

            let overlaps = start <= sectionEnd && end >= sectionStart

            if overlaps {
                editOverlappingSection = section
                return
            }
        }

        editOverlappingSection = nil
    }

    private func scrollToEditOverlappingSection() {
        if let section = editOverlappingSection {
            let targetVerse = section.verseStart
            editingSection = nil
            resetEditVerseForm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                scrollToVerse = targetVerse
            }
        }
    }

    private func saveEditedVerseRange() {
        guard let index = editingSectionIndex, index < sections.count else { return }
        let start = editVerseStart
        let end = editVerseEnd ?? start
        let content = sections[index].content

        // Create updated section
        let updatedSection: NoteSection
        if end != start && end > start {
            updatedSection = .verseRange(start: start, end: end, content: content)
        } else {
            updatedSection = .verse(start, content: content)
        }

        // Remove old section
        sections.remove(at: index)

        // Insert in sorted order
        var insertIndex = sections.count
        for (i, section) in sections.enumerated() {
            if let existingStart = section.verseStart {
                if start < existingStart {
                    insertIndex = i
                    break
                }
            }
        }

        sections.insert(updatedSection, at: insertIndex)
        scheduleSave()

        editingSection = nil
        resetEditVerseForm()
    }

    private func deleteEditingSection() {
        guard let index = editingSectionIndex, index < sections.count else { return }
        sections.remove(at: index)
        scheduleSave()

        editingSection = nil
        resetEditVerseForm()
    }

    // MARK: - Gap Calculation

    private func verseGaps() -> [(after: Int?, gapStart: Int, gapEnd: Int)] {
        let verseSections = sections.filter { !$0.isGeneral }.sorted { ($0.verseStart ?? 0) < ($1.verseStart ?? 0) }

        var gaps: [(after: Int?, gapStart: Int, gapEnd: Int)] = []

        // Check gap before first verse section
        if let first = verseSections.first, let firstStart = first.verseStart, firstStart > 1 {
            gaps.append((after: nil, gapStart: 1, gapEnd: firstStart - 1))
        } else if verseSections.isEmpty && maxVerseInChapter > 0 {
            // No verse sections at all - entire chapter is a gap
            gaps.append((after: nil, gapStart: 1, gapEnd: maxVerseInChapter))
        }

        // Check gaps between sections
        for i in 0..<verseSections.count {
            let current = verseSections[i]
            let currentEnd = current.verseEnd ?? current.verseStart ?? 0

            if i + 1 < verseSections.count {
                let next = verseSections[i + 1]
                let nextStart = next.verseStart ?? 0

                if nextStart > currentEnd + 1 {
                    gaps.append((after: currentEnd, gapStart: currentEnd + 1, gapEnd: nextStart - 1))
                }
            } else {
                // After last section - check if there's a gap to end of chapter
                if currentEnd < maxVerseInChapter {
                    gaps.append((after: currentEnd, gapStart: currentEnd + 1, gapEnd: maxVerseInChapter))
                }
            }
        }

        return gaps
    }

    private func addVerseSectionWithRange(start: Int, end: Int?) {
        newVerseStart = start
        newVerseEnd = end
        overlappingSection = nil
        showingAddVerseSheet = true
    }
}

struct NoteSectionView: View {
    @Binding var section: NoteSection
    let isReadOnly: Bool
    let fontSize: Int
    let translation: Translation
    let onContentChange: () -> Void
    var onNavigateToVerse: ((Int) -> Void)?
    var onNavigateToVerseId: ((Int) -> Void)?
    var onEditVerseRange: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            if !section.displayTitle.isEmpty {
                if section.isGeneral {
                    Text(section.displayTitle)
                        .font(.headline)
                        .foregroundColor(.primary)
                } else if let verseStart = section.verseStart {
                    HStack {
                        Button {
                            onNavigateToVerse?(verseStart)
                        } label: {
                            Text(section.displayTitle)
                                .font(.headline)
                                .foregroundColor(.accentColor)
                        }

                        if !isReadOnly, let onEdit = onEditVerseRange {
                            Spacer()
                            Button {
                                onEdit()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // Text editor or read-only text
            if isReadOnly {
                let placeholder = section.isGeneral ? "No general notes" : "No notes"
                if section.content.isEmpty {
                    Text(placeholder)
                        .font(.system(size: CGFloat(fontSize)))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .foregroundStyle(.tertiary)
                } else {
                    InteractiveNoteContentView(
                        content: section.content,
                        fontSize: fontSize,
                        translation: translation,
                        onNavigateToVerse: onNavigateToVerseId
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if section.content.isEmpty && !isFocused {
                        Text("Add your notes...")
                            .font(.system(size: CGFloat(fontSize)))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }

                    TextEditor(text: $section.content)
                        .font(.system(size: CGFloat(fontSize)))
                        .focused($isFocused)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.never)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                        .onChange(of: section.content) { _, _ in
                            onContentChange()
                        }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Verse Reference Parser

struct ParsedVerseReference: Identifiable {
    let id = UUID()
    let range: Range<String.Index>
    let displayText: String
    let bookId: Int
    let chapter: Int
    let startVerse: Int
    let endVerse: Int?

    var verseId: Int {
        bookId * 1000000 + chapter * 1000 + startVerse
    }

    var endVerseId: Int? {
        guard let end = endVerse else { return nil }
        return bookId * 1000000 + chapter * 1000 + end
    }
}

class VerseReferenceParser {
    static let shared = VerseReferenceParser()

    private var bookNameToId: [String: Int] = [:]
    private var bookAbbrevToId: [String: Int] = [:]

    private init() {
        // Build lookup tables from realm
        let books = RealmManager.shared.realm.objects(Book.self)
        for book in books {
            // Full name (case insensitive)
            bookNameToId[book.name.lowercased()] = book.id
            // OSIS ID (e.g., "Gen", "Matt")
            bookAbbrevToId[book.osisId.lowercased()] = book.id
            // Paratext abbreviation
            if !book.osisParatextAbbreviation.isEmpty {
                bookAbbrevToId[book.osisParatextAbbreviation.lowercased()] = book.id
            }
        }
        // Add common abbreviations
        bookAbbrevToId["1sam"] = bookNameToId["1 samuel"]
        bookAbbrevToId["2sam"] = bookNameToId["2 samuel"]
        bookAbbrevToId["1ki"] = bookNameToId["1 kings"]
        bookAbbrevToId["2ki"] = bookNameToId["2 kings"]
        bookAbbrevToId["1chr"] = bookNameToId["1 chronicles"]
        bookAbbrevToId["2chr"] = bookNameToId["2 chronicles"]
        bookAbbrevToId["1cor"] = bookNameToId["1 corinthians"]
        bookAbbrevToId["2cor"] = bookNameToId["2 corinthians"]
        bookAbbrevToId["1thess"] = bookNameToId["1 thessalonians"]
        bookAbbrevToId["2thess"] = bookNameToId["2 thessalonians"]
        bookAbbrevToId["1tim"] = bookNameToId["1 timothy"]
        bookAbbrevToId["2tim"] = bookNameToId["2 timothy"]
        bookAbbrevToId["1pet"] = bookNameToId["1 peter"]
        bookAbbrevToId["2pet"] = bookNameToId["2 peter"]
        bookAbbrevToId["1jn"] = bookNameToId["1 john"]
        bookAbbrevToId["2jn"] = bookNameToId["2 john"]
        bookAbbrevToId["3jn"] = bookNameToId["3 john"]
        bookAbbrevToId["phil"] = bookNameToId["philippians"]
        bookAbbrevToId["phm"] = bookNameToId["philemon"]
        bookAbbrevToId["jas"] = bookNameToId["james"]
        bookAbbrevToId["rev"] = bookNameToId["revelation"]
    }

    /// Parse all verse references in the format [Book Chapter:Verse] or [Book Chapter:StartVerse-EndVerse]
    func parse(_ text: String) -> [ParsedVerseReference] {
        var references: [ParsedVerseReference] = []

        // Pattern: [Book Chapter:Verse] or [Book Chapter:Verse-EndVerse]
        // Book can be: "John", "1 John", "Genesis", "Gen", etc.
        let pattern = #"\[([1-3]?\s?[A-Za-z]+)\s+(\d+):(\d+)(?:-(\d+))?\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return references
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 4,
                  let fullRange = Range(match.range, in: text),
                  let bookRange = Range(match.range(at: 1), in: text),
                  let chapterRange = Range(match.range(at: 2), in: text),
                  let verseRange = Range(match.range(at: 3), in: text) else {
                continue
            }

            let bookStr = String(text[bookRange]).trimmingCharacters(in: .whitespaces)
            let chapterStr = String(text[chapterRange])
            let verseStr = String(text[verseRange])

            var endVerse: Int? = nil
            if match.numberOfRanges >= 5, match.range(at: 4).location != NSNotFound,
               let endVerseRange = Range(match.range(at: 4), in: text) {
                endVerse = Int(String(text[endVerseRange]))
            }

            guard let chapter = Int(chapterStr),
                  let startVerse = Int(verseStr),
                  let bookId = resolveBookId(bookStr) else {
                continue
            }

            // Validate that the verse exists
            let verseId = bookId * 1000000 + chapter * 1000 + startVerse
            let exists = RealmManager.shared.realm.objects(Verse.self)
                .filter("id == \(verseId)")
                .first != nil

            if exists {
                let displayText = String(text[fullRange])
                    .dropFirst() // Remove [
                    .dropLast()  // Remove ]
                references.append(ParsedVerseReference(
                    range: fullRange,
                    displayText: String(displayText),
                    bookId: bookId,
                    chapter: chapter,
                    startVerse: startVerse,
                    endVerse: endVerse
                ))
            }
        }

        return references
    }

    private func resolveBookId(_ bookStr: String) -> Int? {
        let normalized = bookStr.lowercased()

        // Try exact match first
        if let id = bookNameToId[normalized] {
            return id
        }

        // Try abbreviations
        if let id = bookAbbrevToId[normalized] {
            return id
        }

        // Try partial match (for things like "1 Jn" -> "1 John")
        for (name, id) in bookNameToId {
            if name.hasPrefix(normalized) {
                return id
            }
        }

        return nil
    }
}

// MARK: - Interactive Note Content View

struct InteractiveNoteContentView: View {
    let content: String
    let fontSize: Int
    let translation: Translation
    var onNavigateToVerse: ((Int) -> Void)?

    private var segments: [(text: String, reference: ParsedVerseReference?)] {
        let references = VerseReferenceParser.shared.parse(content)

        if references.isEmpty {
            return [(content, nil)]
        }

        var result: [(String, ParsedVerseReference?)] = []
        var currentIndex = content.startIndex

        for ref in references.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            // Add text before this reference
            if currentIndex < ref.range.lowerBound {
                let textBefore = String(content[currentIndex..<ref.range.lowerBound])
                result.append((textBefore, nil))
            }
            // Add the reference
            result.append((ref.displayText, ref))
            currentIndex = ref.range.upperBound
        }

        // Add remaining text after last reference
        if currentIndex < content.endIndex {
            let textAfter = String(content[currentIndex..<content.endIndex])
            result.append((textAfter, nil))
        }

        return result
    }

    var body: some View {
        // Use a custom layout that wraps text and inline buttons
        WrappingHStack(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let reference = segment.reference {
                    VerseReferenceButton(
                        reference: reference,
                        translation: translation,
                        fontSize: fontSize,
                        onNavigateToVerse: onNavigateToVerse
                    )
                } else {
                    Text(segment.text)
                        .font(.system(size: CGFloat(fontSize)))
                }
            }
        }
    }
}

struct VerseReferenceButton: View {
    let reference: ParsedVerseReference
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    @State private var showingPopover: Bool = false

    private var verses: Results<Verse> {
        if let endVerseId = reference.endVerseId {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id >= \(reference.verseId) AND id <= \(endVerseId)")
        } else {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id == \(reference.verseId)")
        }
    }

    private var inlineVerseText: AttributedString {
        var result = AttributedString()
        let versesArray = Array(verses)

        for (index, verse) in versesArray.enumerated() {
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4
            result.append(verseNum)
            result.append(AttributedString(" "))

            // Strip Strong's annotations for plain display
            var verseText = AttributedString(stripStrongsAnnotations(verse.t))
            verseText.font = .body
            result.append(verseText)

            if index < versesArray.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }

    @State private var contentHeight: CGFloat = 200

    private var navigationAction: (() -> Void)? {
        guard let navigate = onNavigateToVerse else { return nil }
        return {
            showingPopover = false
            navigate(reference.verseId)
        }
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(reference.displayText)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: reference.displayText,
                verseText: inlineVerseText,
                onNavigate: navigationAction,
                contentHeight: $contentHeight
            )
        }
    }
}

// MARK: - Cross Reference Flow View

struct CrossRefFlowView: View {
    let crossRefs: [CrossReference]
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(crossRefs.enumerated()), id: \.offset) { index, crossRef in
                HStack(spacing: 0) {
                    CrossRefButton(crossRef: crossRef, translation: translation, fontSize: fontSize, onNavigateToVerse: onNavigateToVerse)
                    if index < crossRefs.count - 1 {
                        Text(", ")
                            .font(.system(size: CGFloat(fontSize)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct CrossRefButton: View {
    let crossRef: CrossReference
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    @State private var showingPopover: Bool = false

    private var description: String {
        let (startVerse, startChapter, startBook) = splitVerseId(crossRef.sv)
        let startBookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(startBook)").first

        if let ev = crossRef.ev {
            let (endVerse, endChapter, endBook) = splitVerseId(ev)
            if startBook == endBook && startChapter == endChapter {
                return "\(startBookObj?.osisId ?? "") \(startChapter):\(startVerse)-\(endVerse)"
            } else {
                let endBookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(endBook)").first
                return "\(startBookObj?.osisId ?? "") \(startChapter):\(startVerse) - \(endBookObj?.osisId ?? "") \(endChapter):\(endVerse)"
            }
        } else {
            return "\(startBookObj?.osisId ?? "") \(startChapter):\(startVerse)"
        }
    }

    private var verses: Results<Verse> {
        if let ev = crossRef.ev {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id >= \(crossRef.sv) AND id <= \(ev)")
        } else {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id == \(crossRef.sv)")
        }
    }

    private var inlineVerseText: AttributedString {
        var result = AttributedString()
        let versesArray = Array(verses)

        for (index, verse) in versesArray.enumerated() {
            // Add verse number as superscript
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4
            result.append(verseNum)

            // Add space after verse number
            result.append(AttributedString(" "))

            // Add verse text (strip Strong's annotations for plain display)
            var verseText = AttributedString(stripStrongsAnnotations(verse.t))
            verseText.font = .body
            result.append(verseText)

            // Add space between verses (but not after last)
            if index < versesArray.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }

    @State private var contentHeight: CGFloat = 200

    private var navigationAction: (() -> Void)? {
        guard let navigate = onNavigateToVerse else { return nil }
        return {
            showingPopover = false
            navigate(crossRef.sv)
        }
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(description)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: description,
                verseText: inlineVerseText,
                onNavigate: navigationAction,
                contentHeight: $contentHeight
            )
        }
    }
}

// Simple flow layout for comma-separated items
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - TSKe Views

// Parsed segment content for TSKe views - defined at file scope for reuse
private enum TSKSegmentContent {
    case word(String, italic: Bool, trailingSpace: Bool)
    case ref(sv: Int, ev: Int?, displayText: String, trailingSeparator: String?)
}

private struct TSKParsedSegment: Identifiable {
    let id: Int
    let content: TSKSegmentContent
}

// Cache for book OSIS IDs to avoid repeated Realm queries
private class BookOsisCache {
    static let shared = BookOsisCache()
    private var cache: [Int: String] = [:]

    func getOsisId(for bookId: Int) -> String {
        if let cached = cache[bookId] {
            return cached
        }
        let osisId = RealmManager.shared.realm.objects(Book.self).filter("id == \(bookId)").first?.osisId ?? ""
        cache[bookId] = osisId
        return osisId
    }
}

/// Renders chapter overview segments (text + verse references) as flowing text
struct TSKSegmentsView: View {
    let segmentsJson: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    var separateRefs: Bool = false  // If true, add ", " between consecutive references

    // Cache parsed segments to avoid re-parsing on every render
    @State private var cachedSegments: [TSKParsedSegment] = []
    @State private var cachedJson: String = ""

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(cachedSegments) { segment in
                switch segment.content {
                case .word(let word, let italic, let trailingSpace):
                    Text(word + (trailingSpace ? " " : ""))
                        .font(italic ? .system(size: CGFloat(fontSize)).italic() : .system(size: CGFloat(fontSize)))
                case .ref(let sv, let ev, let displayText, let separator):
                    HStack(spacing: 0) {
                        TSKRefButton(
                            sv: sv,
                            ev: ev,
                            displayText: displayText,
                            translation: translation,
                            fontSize: fontSize,
                            onNavigateToVerse: onNavigateToVerse
                        )
                        if let sep = separator {
                            Text(sep)
                                .font(.system(size: CGFloat(fontSize)))
                        }
                    }
                }
            }
        }
        .onAppear {
            if cachedSegments.isEmpty || cachedJson != segmentsJson {
                cachedJson = segmentsJson
                cachedSegments = parseSegments()
            }
        }
        .onChange(of: segmentsJson) { _, newJson in
            cachedJson = newJson
            cachedSegments = parseSegments()
        }
    }

    private func parseSegments() -> [TSKParsedSegment] {
        guard let data = segmentsJson.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var contents: [TSKSegmentContent] = []
        var pendingSv: Int? = nil

        for (index, dict) in parsed.enumerated() {
            // Skip "Overview " prefix
            if index == 0, let text = dict["t"] as? String, text.hasPrefix("Overview") {
                continue
            }

            if let text = dict["t"] as? String {
                // Flush any pending sv before text
                if let sv = pendingSv {
                    let separator = separateRefs ? " " : nil
                    contents.append(.ref(sv: sv, ev: nil, displayText: buildRefDescription(sv: sv, ev: nil), trailingSeparator: separator))
                    pendingSv = nil
                }

                var cleaned = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                if cleaned == "-" {
                    cleaned = "- "
                }
                let isItalic = dict["i"] as? Bool ?? false

                // Split text into words for proper wrapping
                let words = splitIntoWords(cleaned)
                let textEndsWithSpace = cleaned.last?.isWhitespace == true
                for (wordIndex, word) in words.enumerated() {
                    // Add trailing space between words, or after last word if original text ended with space
                    let isLastWord = wordIndex == words.count - 1
                    let hasTrailingSpace = !isLastWord || textEndsWithSpace
                    contents.append(.word(word, italic: isItalic, trailingSpace: hasTrailingSpace))
                }

            } else if let sv = dict["sv"] as? Int {
                // Check if this same dict also has ev (complete range in one object)
                let evInSameDict = dict["ev"] as? Int

                // Flush any pending sv first
                if let prevSv = pendingSv {
                    let separator = separateRefs ? ", " : nil
                    contents.append(.ref(sv: prevSv, ev: nil, displayText: buildRefDescription(sv: prevSv, ev: nil), trailingSeparator: separator))
                    pendingSv = nil
                } else if separateRefs, let lastContent = contents.last {
                    // Check if we need separator before this ref
                    switch lastContent {
                    case .ref:
                        // Already has trailing separator from flush above
                        break
                    case .word(let lastWord, let lastItalic, _):
                        // Append comma to last word (keeps it attached, won't wrap separately)
                        contents.removeLast()
                        contents.append(.word(lastWord + ",", italic: lastItalic, trailingSpace: true))
                    }
                }

                if let ev = evInSameDict {
                    // Complete range in this dict - add it directly
                    contents.append(.ref(sv: sv, ev: ev, displayText: buildRefDescription(sv: sv, ev: ev), trailingSeparator: nil))
                } else {
                    // Just sv, ev might come in next dict
                    pendingSv = sv
                }

            } else if let ev = dict["ev"] as? Int {
                // Standalone ev (paired with previous sv from different dict)
                if let sv = pendingSv {
                    contents.append(.ref(sv: sv, ev: ev, displayText: buildRefDescription(sv: sv, ev: ev), trailingSeparator: nil))
                    pendingSv = nil
                }
            }
        }

        // Flush remaining pending sv
        if let sv = pendingSv {
            contents.append(.ref(sv: sv, ev: nil, displayText: buildRefDescription(sv: sv, ev: nil), trailingSeparator: nil))
        }

        // Add separators between consecutive refs when separateRefs is true
        if separateRefs {
            var result: [TSKSegmentContent] = []
            for (i, content) in contents.enumerated() {
                if case .ref(let sv, let ev, let display, let existingSeparator) = content {
                    // Check if next segment is also a ref
                    let nextIsRef = i + 1 < contents.count && {
                        if case .ref = contents[i + 1] { return true }
                        return false
                    }()
                    // Use ", " between consecutive refs, otherwise preserve existing separator
                    let separator = nextIsRef ? ", " : existingSeparator
                    result.append(.ref(sv: sv, ev: ev, displayText: display, trailingSeparator: separator))
                } else {
                    result.append(content)
                }
            }
            // Convert to ParsedSegments with stable IDs
            return result.enumerated().map { TSKParsedSegment(id: $0, content: $1) }
        }

        // Convert to ParsedSegments with stable IDs
        return contents.enumerated().map { TSKParsedSegment(id: $0, content: $1) }
    }

    /// Split text into words while preserving punctuation attached to words
    private func splitIntoWords(_ text: String) -> [String] {
        // Split on whitespace but keep words with attached punctuation together
        let components = text.components(separatedBy: .whitespaces)
        return components.filter { !$0.isEmpty }
    }

    private func buildRefDescription(sv: Int, ev: Int?) -> String {
        let (startVerse, startChapter, startBook) = splitVerseId(sv)
        let startOsisId = BookOsisCache.shared.getOsisId(for: startBook)

        if let ev = ev {
            let (endVerse, endChapter, endBook) = splitVerseId(ev)
            if startBook == endBook && startChapter == endChapter {
                return "\(startOsisId) \(startChapter):\(startVerse)-\(endVerse)"
            } else {
                let endOsisId = BookOsisCache.shared.getOsisId(for: endBook)
                return "\(startOsisId) \(startChapter):\(startVerse) - \(endOsisId) \(endChapter):\(endVerse)"
            }
        } else {
            return "\(startOsisId) \(startChapter):\(startVerse)"
        }
    }
}

struct TSKRefButton: View {
    let sv: Int
    let ev: Int?
    let displayText: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    @State private var showingPopover: Bool = false
    @State private var contentHeight: CGFloat = 200

    private var verses: Results<Verse> {
        if let ev = ev {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id >= \(sv) AND id <= \(ev)")
        } else {
            return RealmManager.shared.realm.objects(Verse.self)
                .filter("tr == \(translation.id) AND id == \(sv)")
        }
    }

    private var inlineVerseText: AttributedString {
        var result = AttributedString()
        let versesArray = Array(verses)

        for (index, verse) in versesArray.enumerated() {
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4
            result.append(verseNum)
            result.append(AttributedString(" "))

            var verseText = AttributedString(stripStrongsAnnotations(verse.t))
            verseText.font = .body
            result.append(verseText)

            if index < versesArray.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }

    private var navigationAction: (() -> Void)? {
        guard let navigate = onNavigateToVerse else { return nil }
        return {
            showingPopover = false
            navigate(sv)
        }
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(displayText)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .popover(isPresented: $showingPopover) {
            VersePopoverContent(
                title: displayText,
                verseText: inlineVerseText,
                onNavigate: navigationAction,
                contentHeight: $contentHeight
            )
        }
    }
}

/// Isolated view for a single verse's TSKe content - prevents cascade re-renders
struct TSKVerseSection: View {
    let verseId: Int
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    // Cache topics data on first render
    @State private var topics: [(id: String, heading: String, segmentsJson: String)] = []
    @State private var loadedVerseId: Int = 0

    private var verseNum: Int { verseId % 1000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verse \(verseNum)")
                .font(.headline)

            ForEach(topics, id: \.id) { topic in
                TSKTopicView(
                    heading: topic.heading,
                    segmentsJson: topic.segmentsJson,
                    translation: translation,
                    fontSize: fontSize,
                    onNavigateToVerse: onNavigateToVerse
                )
            }
        }
        .onAppear {
            if loadedVerseId != verseId {
                loadTopics()
            }
        }
        .onChange(of: verseId) { _, _ in
            loadTopics()
        }
    }

    private func loadTopics() {
        if let tskVerse = RealmManager.shared.realm.objects(TSKVerse.self).filter("id == \(verseId)").first {
            topics = Array(tskVerse.topics.map { (id: $0.id, heading: $0.h, segmentsJson: $0.segmentsJson) })
        } else {
            topics = []
        }
        loadedVerseId = verseId
    }
}

/// Displays a topic with its heading and segments (text + verse refs)
struct TSKTopicView: View {
    let heading: String
    let segmentsJson: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Topic heading (skip if empty)
            if !heading.isEmpty {
                Text(heading)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(heading == "Reciprocal" ? .secondary : .primary)
            }

            // Segments (reuse the same view as chapter overview, with separators)
            if !segmentsJson.isEmpty {
                TSKSegmentsView(
                    segmentsJson: segmentsJson,
                    translation: translation,
                    fontSize: fontSize,
                    onNavigateToVerse: onNavigateToVerse,
                    separateRefs: true
                )
            }
        }
        .padding(.leading, 8)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var scrollToVerse: Int? = nil

        var body: some View {
            ToolPanelView(
                book: 43,
                chapter: 3,
                currentVerse: 16,
                scrollToVerse: $scrollToVerse,
                user: RealmManager.shared.realm.objects(User.self).first!
            )
        }
    }

    return PreviewWrapper()
}
