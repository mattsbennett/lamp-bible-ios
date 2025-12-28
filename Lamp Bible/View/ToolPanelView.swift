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
}

struct ToolPanelView: View {
    let book: Int
    let chapter: Int
    let currentVerse: Int
    @Binding var scrollToVerse: Int?
    @ObservedRealmObject var user: User
    var onNavigateToVerse: ((Int) -> Void)?

    @State private var panelMode: ToolPanelMode = .notes
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
                Menu {
                    Picker("Mode", selection: $panelMode) {
                        ForEach(ToolPanelMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(panelMode.rawValue)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .modifier(ConditionalGlassButtonStyle())

                Spacer()

                if panelMode == .notes {
                    saveStateIndicator
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

            switch panelMode {
            case .notes:
                notesContent
            case .crossRefs:
                crossRefsContent
            }
        }
        .sheet(isPresented: $isMaximized) {
            maximizedNotesSheet
        }
        .sheet(isPresented: $showingAddVerseSheet) {
            addVerseSheet
        }
        .sheet(item: $editingSection) { section in
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
        .onChange(of: book) { _, _ in
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
        }
        .onChange(of: chapter) { _, _ in
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
        }
        .onDisappear {
            lockRefreshTask?.cancel()
            Task { await releaseLockIfNeeded() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
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
    }

    private var optionsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Notes mode options
            if panelMode == .notes {
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

            // Hide
            Button {
                showingOptionsMenu = false
                if panelMode == .notes {
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

    @ViewBuilder
    private var saveStateIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Saving...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var maximizedNotesSheet: some View {
        NavigationStack {
            notesContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("\(bookName) \(chapter)")
                            .font(.headline)
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

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                                onContentChange: { scheduleSave() },
                                onNavigateToVerse: onNavigateToVerse,
                                onEditVerseRange: section.isGeneral ? nil : {
                                    startEditingSection(section, at: index)
                                }
                            )
                            .id(sections[index].id)
                        }

                        // Show "No verse notes" placeholder in read-only mode when no verse sections exist
                        if isReadOnly && !sections.contains(where: { !$0.isGeneral }) {
                            Text("No verse notes")
                                .font(.system(size: CGFloat(notesFontSize)))
                                .foregroundStyle(.tertiary)
                        }

                        // Show gap button after last verse section (or after general if no verse sections)
                        if !isReadOnly {
                            if let lastVerseSection = sections.last(where: { !$0.isGeneral }),
                               let lastEnd = lastVerseSection.verseEnd ?? lastVerseSection.verseStart,
                               let gap = gaps.first(where: { $0.after == lastEnd }) {
                                gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                            } else if !sections.contains(where: { !$0.isGeneral }),
                                      let gap = gaps.first(where: { $0.after == nil }) {
                                // No verse sections yet - show add button for first verse
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
                .scrollDismissesKeyboard(.never)
                .onChange(of: scrollToVerse) { _, newVerse in
                    // Don't scroll-link while keyboard is visible (user is editing)
                    guard !isKeyboardVisible else {
                        scrollToVerse = nil
                        return
                    }
                    if let verse = newVerse {
                        withAnimation {
                            // Try exact verse first
                            if let sectionId = findSectionId(forVerse: verse) {
                                proxy.scrollTo(sectionId, anchor: .top)
                            }
                        }
                        scrollToVerse = nil
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
                VStack(alignment: .leading, spacing: 20) {
                    if sortedVerses.isEmpty {
                        Text("No cross references for this chapter")
                            .font(.system(size: CGFloat(notesFontSize)))
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(sortedVerses, id: \.self) { verse in
                            if let refs = groupedRefs[verse] {
                                VStack(alignment: .leading, spacing: 8) {
                                    // Verse header - tappable to jump to verse
                                    Button {
                                        onNavigateToVerse?(verse)
                                    } label: {
                                        Text("Verse \(verse)")
                                            .font(.headline)
                                            .foregroundColor(.accentColor)
                                    }

                                    // Cross references as comma-separated buttons
                                    CrossRefFlowView(
                                        crossRefs: refs.sorted { $0.r < $1.r },
                                        translation: user.readerTranslation!,
                                        fontSize: notesFontSize
                                    )
                                }
                                .id("crossref_v\(verse)")
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollToVerse) { _, newVerse in
                // Don't scroll-link while keyboard is visible
                guard !isKeyboardVisible else {
                    scrollToVerse = nil
                    return
                }
                if let verse = newVerse, groupedRefs[verse] != nil {
                    withAnimation {
                        proxy.scrollTo("crossref_v\(verse)", anchor: .top)
                    }
                    scrollToVerse = nil
                }
            }
            .onChange(of: currentVerse) { _, newVerse in
                // Auto-scroll when current verse changes (from Bible panel scroll)
                guard !isKeyboardVisible else { return }
                if groupedRefs[newVerse] != nil {
                    withAnimation {
                        proxy.scrollTo("crossref_v\(newVerse)", anchor: .top)
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
        // First look for exact match
        for section in sections {
            if let start = section.verseStart, let end = section.verseEnd {
                if verse >= start && verse <= end {
                    return section.id
                }
            } else if let start = section.verseStart, start == verse {
                return section.id
            }
        }
        return nil
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
    let onContentChange: () -> Void
    var onNavigateToVerse: ((Int) -> Void)?
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
                Text(section.content.isEmpty ? placeholder : section.content)
                    .font(.system(size: CGFloat(fontSize)))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .foregroundStyle(section.content.isEmpty ? .tertiary : .primary)
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

// MARK: - Cross Reference Flow View

struct CrossRefFlowView: View {
    let crossRefs: [CrossReference]
    let translation: Translation
    let fontSize: Int

    var body: some View {
        FlowLayout(spacing: 0) {
            ForEach(Array(crossRefs.enumerated()), id: \.offset) { index, crossRef in
                HStack(spacing: 0) {
                    CrossRefButton(crossRef: crossRef, translation: translation, fontSize: fontSize)
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

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            Text(description)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .popover(isPresented: $showingPopover) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(description)
                        .font(.headline)
                        .padding(.bottom, 4)

                    ForEach(Array(verses), id: \.id) { verse in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(verse.v)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            Text(verse.t)
                        }
                    }
                }
                .padding()
                .frame(minWidth: 280, maxWidth: 400, minHeight: 200)
            }
            .presentationCompactAdaptation(.popover)
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
