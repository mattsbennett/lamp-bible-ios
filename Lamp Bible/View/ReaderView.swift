//
//  ReaderView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-29.
//

import Foundation
import RealmSwift
import SwiftUI

struct ReaderView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var date: Date
    @State private var readingMetaData: [ReadingMetaData]? = nil
    @State private var currentReadingIndex: Int = 0
    @State private var isLoading: Bool = false
    @State private var showingBookPicker: Bool = false
    @State private var showingCrossReferenceSheet: Bool = false
    @State private var showingDisplayOptions: Bool = false
    @State private var crossReferenceVerse: Verse? = nil
    @State private var verses: Results<Verse>
    @State private var initialScrollItem: String? = nil
    @State private var translation: Translation
    @State private var showingTranslationPopover: Bool = false
    @SceneStorage("readerCurrentVerseId") var currentVerseId: Int = 1001001

    let LOADING_NEXT_CHAPTER = "next_chapter"
    let LOADING_PREV_CHAPTER = "prev_chapter"
    let LOADING_CURRENT = "current"
    let LOADING_TRANSLATION = "translation"
    let LOADING_READING = "reading"
    
    init(
        user: User,
        date: Binding<Date>,
        readingMetaData: [ReadingMetaData]? = nil,
        translation: Translation = RealmManager.shared.realm.objects(User.self).first!.readerTranslation!,
        verses: Results<Verse> = RealmManager.shared.realm.objects(Verse.self).filter("id == -1")
    ) {
        self.user = user
        _date = date
        _readingMetaData = State(initialValue: readingMetaData)
        _translation = State(initialValue: translation)
        _verses = State(initialValue: verses)
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
                                Button("\(verse.v)") {
                                    crossReferenceVerse = verse
                                    showingCrossReferenceSheet = true
                                }
                                    .padding(.trailing, -20)
                                    .frame(width: user.readerFontSize > 22 ? 35 : 20)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .font(.system(size: CGFloat(user.readerFontSize)))
                                    .id("v_button_\(verse.id)")
                                    .foregroundStyle(isCrossRefs ? .accentColor : Color.secondary)
                                    .disabled(!isCrossRefs)
                                Text(verse.t)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(10)
                                    .padding(.horizontal, 15)
                                    .id("v_text_\(verse.id)")
                                    .font(.system(size: CGFloat(user.readerFontSize)))
                                    // onAppear affects scrolling performance, so only use it when
                                    // there may be more than one chapter loaded (so header updates)
                                    .if(readingMetaData != nil) { view in
                                        view.onAppear {
                                            currentVerseId = verse.id
                                        }
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
                    showingDisplayOptions: $showingDisplayOptions,
                    showingBookPicker: $showingBookPicker,
                    readerDismiss: dismiss
                )
            }
            .sheet(isPresented: $showingBookPicker) {
                BookListView(
                    currentVerseId: $currentVerseId,
                    showingBookPicker: $showingBookPicker
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

