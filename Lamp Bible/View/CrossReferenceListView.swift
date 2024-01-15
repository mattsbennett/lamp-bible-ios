//
//  CrossReferenceListView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-01.
//

import SwiftUI
import RealmSwift

struct CrossReferenceListView: View {
    @Binding var translation: Translation
    @Binding var crossReferenceVerse: Verse?
    @Binding var showingCrossReferenceSheet: Bool
    
    var body: some View {
        let (verse, chapter, book) = splitVerseId(crossReferenceVerse!.id)
        let sort = RealmManager.shared.realm.objects(User.self).first!.readerCrossReferenceSort
        let parentBook = RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first
        let crossReferences = RealmManager.shared.realm.objects(CrossReference.self).filter("id == \(crossReferenceVerse!.id)").sorted(byKeyPath: sort, ascending: true)
        NavigationView {
            VStack {
                Text(crossReferenceVerse!.t)
                    .padding(.top, 20)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(5)
                List {
                    Section(header: Text("Cross References")) {
                        ForEach(Array(crossReferences.enumerated()), id: \.element.uniqueId) { index, crossReference in
                            let (startVerse, startChapter, startBook) = splitVerseId(crossReference.sv)
                            let (endVerse, endChapter, endBook) = crossReference.ev != nil ? splitVerseId(crossReference.ev!) : (-1, -1, -1)
                            let startBookObj = RealmManager.shared.realm.objects(Book.self).filter("id == \(startBook)").first
                            let endBookObj = endVerse != -1 ? RealmManager.shared.realm.objects(Book.self).filter("id == \(endBook)").first : nil
                            let endString = endBookObj != nil ? " - \(endBookObj!.osisId) \(endChapter):\(endVerse)" : ""
                            let verses = endBookObj != nil ? RealmManager.shared.realm.objects(Verse.self).filter("tr = \(translation.id) AND id >= \(crossReference.sv) AND id <= \(crossReference.ev!)") : RealmManager.shared.realm.objects(Verse.self).filter("tr = \(translation.id) AND id = \(crossReference.sv)")
                            let description = (endString != "" && startBook == endBook && startChapter == endChapter)
                                ? "\(startBookObj!.osisId) \(startChapter):\(startVerse)-\(endVerse)"
                                : "\(startBookObj!.osisId) \(startChapter):\(startVerse)\(endString)"

                            NavigationLink(destination: CrossReferenceDetailView(description: description, verses: verses)) {
                                Text(description)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cross References: \(parentBook!.osisId) \(chapter):\(verse)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showingCrossReferenceSheet = false
                    } label: {
                        Text(Image(systemName: "xmark"))
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text("Cross References").bold()
                        Text("\(parentBook!.osisId) \(chapter):\(verse)").font(.caption)
                    }
                }
            }
        }
    }
}
