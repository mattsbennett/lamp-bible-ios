//
//  CrossReferenceDetailView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-01-14.
//

import SwiftUI
import RealmSwift

struct CrossReferenceDetailView: View {
    let description: String
    let verses: Results<Verse>

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(Array(verses.enumerated()), id: \.element.id) { index, verse in
                    if index == 0 {
                        Text(description)
                            .bold()
                            .padding(.top, 20)
                            .padding(.bottom, 20)
                            .font(.system(size: 20))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Spacer().frame(width: 5)
                        Text("\(verse.v)")
                            .padding(.trailing, -20)
                            .frame(width: 20)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(verse.t)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(10)
                            .padding(.horizontal, 15)
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }
}
