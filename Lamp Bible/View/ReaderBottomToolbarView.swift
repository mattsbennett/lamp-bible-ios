//
//  ReaderPlanToolbar.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-08.
//

import SwiftUI
import RealmSwift

struct ReaderBottomToolbarView: ToolbarContent {
    @Binding var readingMetaData: [ReadingMetaData]?
    @Binding var currentReadingIndex: Int
    @Binding var date: Date
    @Binding var translation: Translation
    @Binding var currentVerseId: Int
    let loadPrev: () -> Void
    let loadNext: () -> Void

    var body: some ToolbarContent {
        if let metaData = readingMetaData {
            if metaData.count > 1 {
                ToolbarItem(placement: .bottomBar) {
                    Button(action: {
                        currentReadingIndex -= 1
                    }) {
                        Image(systemName: "chevron.left")
                    }
                    .padding(.vertical)
                    .disabled(currentReadingIndex == 0)
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            ToolbarItem(placement: .bottomBar) {
                VStack {
                    HStack {
                        Text(date, format: .dateTime.weekday().day().month())
                        Divider()
                        Text("Portion")
                            .padding(.trailing, -3)
                        ForEach(0..<currentReadingIndex + 1, id: \.self) { _ in
                            Image("lampflame.fill")
                                .font(.system(size: 11))
                                .padding(.trailing, -11)
                                .padding(.leading, -3)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    Text(metaData[currentReadingIndex].description)
                        .font(.system(size: 16))
                }
                .padding(.top, 5)
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            if metaData.count > 1 {
                ToolbarItem(placement: .bottomBar) {
                    Button(action: {
                        currentReadingIndex += 1
                    }) {
                        Image(systemName: "chevron.right")
                    }
                    .padding(.vertical)
                    .disabled(currentReadingIndex == metaData.count - 1)
                }
            }
        } else {
            let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)
            let (_, lastChapter, lastBook) = splitVerseId(translation.verses.last!.id)
            let (_, firstChapter, firstBook) = splitVerseId(translation.verses.first!.id)
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    loadPrev()
                }) {
                    Image(systemName: "chevron.left")
                }
                .padding(.vertical)
                .disabled(currentBook == firstBook && currentChapter == firstChapter)
            }
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    loadNext()
                }) {
                    Image(systemName: "chevron.right")
                }
                .padding(.vertical)
                .disabled(currentBook == lastBook && currentChapter == lastChapter)
            }
        }
    }
}
