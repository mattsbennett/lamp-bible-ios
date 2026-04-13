//
//  ReadingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-02-12.
//

import SwiftUI

struct ReadingsView: View {
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()
    @State private var completedReadingIds: Set<String> = UserDatabase.shared.getCompletedReadingIds()
    @State private var readerCount: Int = UserDatabase.shared.getSettings().planReaderCount
    let planMetaData: PlanMetaData
    let stackHorizontally: Bool

    var body: some View {
        ConditionalStack(isHorizonalStack: stackHorizontally) {
            let readings = planMetaData.readingMetaData
            ForEach(readings.indices, id: \.self) { index in
                let readingMetaData = planMetaData.readingMetaData.first(where: { $0.index == index })!
                VStack(alignment: .leading) {
                    HStack {
                        let readingId = readingMetaData.id

                        Button {
                            if completedReadingIds.contains(readingId) {
                                try? UserDatabase.shared.removeCompletedReading(readingId)
                                completedReadingIds.remove(readingId)
                            } else {
                                try? UserDatabase.shared.addCompletedReading(readingId)
                                completedReadingIds.insert(readingId)
                            }
                            WidgetDataService.shared.refreshWidget()
                        } label: {
                            HStack {
                                if completedReadingIds.contains(readingId) {
                                    Image(systemName: "checkmark").frame(width: 17)
                                } else {
                                    Image(systemName: "circle").frame(width: 17)
                                }
                                Text(readingMetaData.description).font(.body).foregroundStyle(Color.primary)
                            }
                        }
                        Spacer()
                        if userSettings.planExternalBible != nil && userSettings.planExternalBible != "None" {
                            Button {
                                let app = externalBibleApps.first(where: { $0.name == userSettings.planExternalBible })
                                if let url = app?.getFullUrl(sv: readingMetaData.sv, ev: readingMetaData.ev) {
                                    if UIApplication.shared.canOpenURL(url) {
                                        UIApplication.shared.open(url)

                                        if !completedReadingIds.contains(readingId) {
                                            try? UserDatabase.shared.addCompletedReading(readingId)
                                            completedReadingIds.insert(readingId)
                                            WidgetDataService.shared.refreshWidget()
                                        }
                                    }
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: 2)
                                    Image("book.and.external.fill")
                                        .foregroundColor(Color.accentColor)
                                        .font(.title3)
                                }
                            }
                            .frame(width: 57, height: 57)
                            .clipShape(Circle())
                            .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.bottom, 10)
                    Spacer()
                    HStack {
                        Label("\(readingMetaData.genre)", systemImage: "bookmark.fill")
                        Spacer()
                        ReaderSplitControl(
                            chapterVerseCounts: readingMetaData.chapterVerseCounts,
                            readerCount: $readerCount
                        )
                        Spacer()
                        Label("\(readingMetaData.readingTime)", systemImage: "clock").labelStyle(TrailingIconLabelStyle())
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }
                .id(index)
                .padding()
                .if(stackHorizontally) { view in
                    view.frame(width: 325)
                }
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                        )
                )
            }
            Spacer()
        }
        .onAppear {
            userSettings = UserDatabase.shared.getSettings()
            completedReadingIds = UserDatabase.shared.getCompletedReadingIds()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            userSettings = UserDatabase.shared.getSettings()
            completedReadingIds = UserDatabase.shared.getCompletedReadingIds()
        }
        .onChange(of: readerCount) { _, newValue in
            try? UserDatabase.shared.updateSettings { $0.planReaderCount = newValue }
        }
    }
}

// MARK: - Reader Split Control

struct ReaderSplitControl: View {
    let chapterVerseCounts: [Int]
    @Binding var readerCount: Int

    private var totalVerses: Int { chapterVerseCounts.reduce(0, +) }

    private var labelContent: Text {
        if readerCount <= 1 {
            return Text("\(totalVerses)v")
        }
        let counts = chapterVerseCounts.map { count -> Int in
            let floor = count / readerCount
            let ceil = floor + (count % readerCount == 0 ? 0 : 1)
            let floorRemainder = count - floor * readerCount
            let ceilRemainder = ceil * readerCount - count
            return ceilRemainder <= floorRemainder ? ceil : floor
        }
        var result = Text("\(counts[0])")
        for count in counts.dropFirst() {
            result = result + Text(" · ") + Text("\(count)")
        }
        return result + Text(" ea.")
    }

    private var personIcon: String {
        switch readerCount {
        case 2: return "person.2.fill"
        case 3...: return "person.3.fill"
        default: return "person.fill"
        }
    }

    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            HStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    Image(systemName: personIcon)
                        .font(.caption)
                    if readerCount > 3 {
                        Text("\(readerCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color(.systemBackground))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.secondary, lineWidth: 0.5)
                            )
                            .offset(x: -4, y: -4)
                    }
                }
                labelContent
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            VStack(spacing: 8) {
                Text("Readers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        if readerCount > 1 { readerCount -= 1 }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(readerCount <= 1)

                    Text("\(readerCount)")
                        .font(.body)
                        .monospacedDigit()
                        .frame(minWidth: 20)

                    Button {
                        if readerCount < 20 { readerCount += 1 }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(readerCount >= 20)
                }
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }
}
