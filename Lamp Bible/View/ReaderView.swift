//
//  ReaderView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-29.
//

import Foundation
import RealmSwift
import SwiftUI
import UIKit

// MARK: - Selectable Text View

struct SelectableText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]

        textView.attributedText = NSAttributedString(string: text, attributes: attributes)
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

// Preference key to track verse positions for scroll-linking
struct VersePositionPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var date: Date
    @State private var readingMetaData: [ReadingMetaData]? = nil
    @State private var currentReadingIndex: Int = 0
    @State private var isLoading: Bool = false
    @State private var showingBookPicker: Bool = false
    @State private var showingCrossReferenceSheet: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @State private var crossReferenceVerse: Verse? = nil
    @State private var verses: Results<Verse>
    @State private var initialScrollItem: String? = nil
    @State private var translation: Translation
    @SceneStorage("readerCurrentVerseId") var currentVerseId: Int = 1001001
    @State private var scrollDebounceTask: Task<Void, Never>?
    @Binding var requestScrollToVerseId: Int?

    let LOADING_NEXT_CHAPTER = "next_chapter"
    let LOADING_PREV_CHAPTER = "prev_chapter"
    let LOADING_CURRENT = "current"
    let LOADING_TRANSLATION = "translation"
    let LOADING_READING = "reading"

    var onVerseAction: ((Int, VerseAction) -> Void)?

    init(
        user: User,
        date: Binding<Date>,
        readingMetaData: [ReadingMetaData]? = nil,
        translation: Translation = RealmManager.shared.realm.objects(User.self).first!.readerTranslation!,
        verses: Results<Verse> = RealmManager.shared.realm.objects(Verse.self).filter("id == -1"),
        onVerseAction: ((Int, VerseAction) -> Void)? = nil,
        requestScrollToVerseId: Binding<Int?> = .constant(nil)
    ) {
        self.user = user
        _date = date
        _readingMetaData = State(initialValue: readingMetaData)
        _translation = State(initialValue: translation)
        _verses = State(initialValue: verses)
        self.onVerseAction = onVerseAction
        _requestScrollToVerseId = requestScrollToVerseId
    }
    
    @ViewBuilder
    private func verseButton(verse: Verse, hasCrossRefs: Bool) -> some View {
        if user.notesEnabled {
            // When notes are enabled, show a menu with options
            Menu {
                Button {
                    onVerseAction?(verse.v, .addNote)
                } label: {
                    Label("Add Note", systemImage: "note.text.badge.plus")
                }

                if hasCrossRefs {
                    Button {
                        crossReferenceVerse = verse
                        showingCrossReferenceSheet = true
                    } label: {
                        Label("Cross References", systemImage: "arrow.triangle.branch")
                    }
                }
            } label: {
                Text("\(verse.v)")
                    .font(.system(size: CGFloat(user.readerFontSize)))
                    .foregroundStyle(hasCrossRefs ? .accentColor : Color.secondary)
            }
            .padding(.trailing, -20)
            .frame(width: user.readerFontSize > 22 ? 35 : 20)
            .fixedSize(horizontal: true, vertical: false)
            .id("v_button_\(verse.id)")
        } else {
            // Original behavior: tap to show cross references
            Button("\(verse.v)") {
                crossReferenceVerse = verse
                showingCrossReferenceSheet = true
            }
            .padding(.trailing, -20)
            .frame(width: user.readerFontSize > 22 ? 35 : 20)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: CGFloat(user.readerFontSize)))
            .id("v_button_\(verse.id)")
            .foregroundStyle(hasCrossRefs ? .accentColor : Color.secondary)
            .disabled(!hasCrossRefs)
        }
    }

    func loadVerses(loadingCase: String) {
        let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)

        switch loadingCase {
            case LOADING_PREV_CHAPTER:
                verses = getPrevChapterVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_NEXT_CHAPTER:
                verses = getNextChapterVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_READING:
                verses = translation.verses.filter("id >= \(readingMetaData![currentReadingIndex].sv) && id <= \(readingMetaData![currentReadingIndex].ev)")
            case LOADING_CURRENT:
                fallthrough
            case LOADING_TRANSLATION:
                verses = translation.verses.filter("b == \(currentBook) && c == \(currentChapter)")
            default: break
        }
        
        currentVerseId = verses.first!.id
        isLoading = true
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack {
                        Text("")
                            .frame(height: 1)
                            .id("top")
                        ForEach(verses.indices, id: \.self) { index in
                            let verse = verses[index]
                            let isCrossRefs = RealmManager.shared.realm.objects(CrossReference.self).filter("id == \(verse.id)").count > 0

                            if verse.v == 1 {
                                let book = RealmManager.shared.realm.objects(Book.self).filter("id == \(verse.b)").first
                                if verse.c == 1 {
                                    Text(book!.name)
                                        .bold()
                                        .padding(.top, 20)
                                        .padding(.bottom, -10)
                                        .id("b_\(verse.b)")
                                        .font(.title)
                                }
                                Text("\(book!.name) \(verse.c)")
                                    .bold()
                                    .padding(.top, 20)
                                    .padding(.bottom, 20)
                                    .id("b_\(verse.b)_c_\(verse.c)")
                                    .font(.system(size: 20))
                            }
                            // Can't scroll to item inside HStack by id, so use a dummy target
                            Text("")
                                .frame(height: 1)
                                .id(String(verse.id))
                            HStack(alignment: .firstTextBaseline) {
                                Spacer()
                                    .frame(width: 5)
                                    .id("v_spacer_\(verse.id)")
                                verseButton(verse: verse, hasCrossRefs: isCrossRefs)
                                SelectableText(
                                    text: verse.t,
                                    fontSize: CGFloat(user.readerFontSize),
                                    lineSpacing: 10
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 15)
                                .id("v_text_\(verse.id)")
                                // Track verse position for scroll-linking
                                .if(readingMetaData != nil || (user.notesEnabled && user.notesPanelVisible)) { view in
                                    view.background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: VersePositionPreferenceKey.self,
                                                value: [verse.id: geo.frame(in: .named("readerScroll")).minY]
                                            )
                                        }
                                    )
                                }
                                .if(verse.id == verses.last!.id) { view in
                                    view.padding(.bottom, 20)
                                }
                            }
                        }
                        .onChange(of: initialScrollItem) {
                            guard initialScrollItem != nil else { return }
                            proxy.scrollTo(initialScrollItem, anchor: UnitPoint(x: 0.5, y: 0.01))
                        }
                        .onChange(of: isLoading) {
                            if isLoading {
                                proxy.scrollTo("top", anchor: .top)
                                isLoading = false
                            }
                        }
                        .onChange(of: translation) {
                            loadVerses(loadingCase: LOADING_TRANSLATION)
                        }
                        .onChange(of: currentReadingIndex) {
                            loadVerses(loadingCase: LOADING_READING)

                            if let readingId = readingMetaData?[currentReadingIndex].id {
                                if RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(readingId)'").count == 0 {
                                    try! RealmManager.shared.realm.write {
                                        guard let thawedUser = user.thaw() else {
                                            // Handle the inability to thaw the object
                                            return
                                        }
                                        thawedUser.addCompletedReading(id: readingId)
                                    }
                                }
                            }
                        }
                        .onChange(of: requestScrollToVerseId) {
                            if let verseId = requestScrollToVerseId {
                                withAnimation {
                                    proxy.scrollTo(String(verseId), anchor: .top)
                                }
                                requestScrollToVerseId = nil
                            }
                        }
                    }
//                    iOS 18 broke gestures on scrollviews
//                    .gesture(
//                        DragGesture()
//                            .onEnded { gesture in
//                                if gesture.translation.width < -150 {
//                                    // Perform action for left swipe
//                                    if readingMetaData == nil {
//                                        loadVerses(loadingCase: LOADING_NEXT_CHAPTER)
//                                    } else if currentReadingIndex < readingMetaData!.count - 1 {
//                                        currentReadingIndex += 1
//                                    }
//                                } else if gesture.translation.width > 150 {
//                                    // Perform action for right swipe
//                                    if readingMetaData == nil {
//                                        loadVerses(loadingCase: LOADING_PREV_CHAPTER)
//                                    } else if currentReadingIndex > 0 {
//                                        currentReadingIndex -= 1
//                                    }
//                                }
//                            }
//                    )
                }
            }
            .coordinateSpace(name: "readerScroll")
            .onPreferenceChange(VersePositionPreferenceKey.self) { positions in
                // Debounce: cancel any pending update and schedule a new one
                scrollDebounceTask?.cancel()
                scrollDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
                    guard !Task.isCancelled else { return }

                    // Find the verse closest to the top of the viewport (smallest positive Y)
                    let topVerse = positions
                        .filter { $0.value >= -50 } // Allow slightly above viewport
                        .min { $0.value < $1.value }

                    if let verseId = topVerse?.key, verseId != currentVerseId {
                        currentVerseId = verseId
                    }
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ReaderBottomToolbarView(
                    readingMetaData: $readingMetaData,
                    currentReadingIndex: $currentReadingIndex,
                    date: $date,
                    translation: $translation,
                    currentVerseId: $currentVerseId,
                    loadPrev: {
                        loadVerses(loadingCase: LOADING_PREV_CHAPTER)
                    },
                    loadNext: {
                        loadVerses(loadingCase: LOADING_NEXT_CHAPTER)
                    }
                )
            }
            .toolbar {
                ReaderNavigationToolbarView(
                    user: user,
                    readingMetaData: $readingMetaData,
                    translation: $translation,
                    currentVerseId: $currentVerseId,
                    showingBookPicker: $showingBookPicker,
                    showingOptionsMenu: $showingOptionsMenu,
                    readerDismiss: dismiss
                )
            }
            .sheet(isPresented: $showingBookPicker) {
                BookListView(
                    currentVerseId: $currentVerseId,
                    showingBookPicker: $showingBookPicker,
                    translation: $translation
                ) {
                    loadVerses(loadingCase: LOADING_CURRENT)
                }
            }
            .sheet(isPresented: $showingCrossReferenceSheet) {
                CrossReferenceListView(translation: $translation, crossReferenceVerse: $crossReferenceVerse, showingCrossReferenceSheet: $showingCrossReferenceSheet)
            }
        }
        .onAppear {
            if readingMetaData != nil {
                initialScrollItem = "top"
                currentReadingIndex = 0
                loadVerses(loadingCase: LOADING_READING)

                if let readingId = readingMetaData?[0].id {
                    if RealmManager.shared.realm.objects(CompletedReading.self).filter("id == '\(readingId)'").count == 0 {
                        try! RealmManager.shared.realm.write {
                            guard let thawedUser = user.thaw() else {
                                // Handle the inability to thaw the object
                                return
                            }
                            thawedUser.addCompletedReading(id: readingId)
                        }
                    }
                }
            } else {
                loadVerses(loadingCase: LOADING_CURRENT)

                let (verse, chapter, book) = splitVerseId(currentVerseId)
                if chapter == 1 {
                    initialScrollItem = "b_\(book)"
                } else if verse == 1 {
                    initialScrollItem = "b_\(book)_c_\(chapter)"
                } else {
                    initialScrollItem = String(currentVerseId)
                }
            }
        }
    }
}

struct ReaderViewPreview: View {
    @State var date: Date = Date.now
    
    var body: some View {
        ReaderView(
            user: RealmManager.shared.realm.objects(User.self).first!,
            date: $date
        )
    }
}

#Preview {
    ReaderViewPreview()
}

