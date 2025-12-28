//
//  NotesPanelView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import RealmSwift
import SwiftUI

struct NotesPanelView: View {
    let book: Int
    let chapter: Int
    @Binding var scrollToVerse: Int?
    @ObservedRealmObject var user: User

    @State private var note: Note?
    @State private var sections: [NoteSection] = []
    @State private var isLoading: Bool = true
    @State private var saveState: SaveState = .idle
    @State private var showingAddVerseSheet: Bool = false
    @State private var newVerseStart: String = ""
    @State private var newVerseEnd: String = ""
    @State private var saveTask: Task<Void, Never>?

    // Locking state
    @State private var isReadOnly: Bool = false
    @State private var showingLockConflict: Bool = false
    @State private var lockConflictInfo: (lockedBy: String, lockedAt: Date)?
    @State private var lockRefreshTask: Task<Void, Never>?

    // Conflict state
    @State private var showingConflictResolution: Bool = false
    @State private var currentConflict: NoteConflict?

    // Keyboard state (to disable scroll-linking while editing)
    @State private var isKeyboardVisible: Bool = false

    private let storage = ICloudNoteStorage.shared
    private let lockRefreshInterval: UInt64 = 60_000_000_000 // 60 seconds in nanoseconds

    var bookName: String {
        RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first?.name ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("\(bookName) \(chapter) Notes")
                    .font(.headline)
                    .padding(.leading)
                Spacer()
                saveStateIndicator
            }
            .padding(.vertical, 10)
            .padding(.trailing)
            .background(Color(UIColor.secondarySystemBackground))

            Divider()

            // Read-only banner
            if isReadOnly {
                HStack {
                    Image(systemName: "eye")
                    Text("Read-only mode")
                    Spacer()
                    Button("Edit") {
                        Task { await tryAcquireLock() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.2))
                .font(.caption)
            }

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(sections.indices, id: \.self) { index in
                                NoteSectionView(
                                    section: $sections[index],
                                    isReadOnly: isReadOnly,
                                    onContentChange: { scheduleSave() }
                                )
                                .id(sections[index].id)
                            }

                            // Add verse button (hidden in read-only mode)
                            if !isReadOnly {
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
        .sheet(isPresented: $showingAddVerseSheet) {
            addVerseSheet
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

    private var addVerseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Start verse", text: $newVerseStart)
                        .keyboardType(.numberPad)
                    TextField("End verse (optional)", text: $newVerseEnd)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Verse Number")
                } footer: {
                    Text("Enter a single verse number, or a range (e.g., 16-17)")
                }
            }
            .navigationTitle("Add Verse Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddVerseSheet = false
                        newVerseStart = ""
                        newVerseEnd = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addVerseSection()
                    }
                    .disabled(newVerseStart.isEmpty)
                }
            }
        }
        .presentationDetents([.height(250)])
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
        isReadOnly = false
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
                isReadOnly = false
                startLockRefresh()
            case .lockedByOther(let lockedBy, let lockedAt):
                lockConflictInfo = (lockedBy, lockedAt)
                showingLockConflict = true
            }
        } catch {
            print("Failed to acquire lock: \(error)")
            // Allow editing anyway if lock acquisition fails
            isReadOnly = false
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
        guard let start = Int(newVerseStart) else { return }

        let end = Int(newVerseEnd) ?? start
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
        newVerseStart = ""
        newVerseEnd = ""
    }
}

struct NoteSectionView: View {
    @Binding var section: NoteSection
    let isReadOnly: Bool
    let onContentChange: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            Text(section.displayTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(section.isGeneral ? .primary : .accentColor)

            // Text editor or read-only text
            if isReadOnly {
                Text(section.content.isEmpty ? "No notes" : section.content)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .padding(8)
                    .foregroundStyle(section.content.isEmpty ? .tertiary : .primary)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
            } else {
                ZStack(alignment: .topLeading) {
                    if section.content.isEmpty && !isFocused {
                        Text("Add your notes...")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }

                    TextEditor(text: $section.content)
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

#Preview {
    struct PreviewWrapper: View {
        @State var scrollToVerse: Int? = nil

        var body: some View {
            NotesPanelView(
                book: 43,
                chapter: 3,
                scrollToVerse: $scrollToVerse,
                user: RealmManager.shared.realm.objects(User.self).first!
            )
        }
    }

    return PreviewWrapper()
}
