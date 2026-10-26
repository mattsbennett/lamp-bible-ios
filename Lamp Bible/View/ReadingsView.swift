//
//  ReadingsView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2024-02-12.
//

import SwiftUI

/// A day's readings in one plan: how much there is, a way through all of it
/// in order, and each reading on its own.
///
/// Every way into a reading says where it goes. The plan's button and each
/// reading itself open the in-app Bible, where that is on; the Bible app
/// chosen in Settings has a button of its own on each reading, named for it,
/// as the one thing here that leaves Lamp. The circle beside a reading only
/// marks it read, so the passage's name, what people tap, opens it rather
/// than ticking it off.
struct ReadingsView: View {
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()
    @State private var completedReadingIds: Set<String> = UserDatabase.shared.getCompletedReadingIds()
    @State private var readerCount: Int = UserDatabase.shared.getSettings().planReaderCount
    @Binding var date: Date
    let planMetaData: PlanMetaData
    let stackHorizontally: Bool

    private var readings: [ReadingMetaData] { planMetaData.readingMetaData }

    /// The Bible app chosen in Settings to open readings in, if one is.
    private var externalApp: ExternalBibleApp? {
        guard let name = userSettings.planExternalBible else { return nil }
        return externalBibleApps.first { $0.name == name && $0.application != nil }
    }

    private func isRead(_ reading: ReadingMetaData) -> Bool {
        completedReadingIds.contains(reading.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
                .padding(.horizontal, 5)
            readThroughButton
                .if(stackHorizontally) { view in
                    view.frame(maxWidth: 325)
                }
            ConditionalStack(isHorizonalStack: stackHorizontally) {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    card(reading)
                        .id(index)
                }
                Spacer()
            }
        }
        .onAppear {
            syncFromDatabase()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userDatabaseDidChange)) { _ in
            syncFromDatabase()
        }
        .onChange(of: readerCount) { _, newValue in
            // Guard against writing back a value we just read from the database
            guard newValue != userSettings.planReaderCount else { return }
            try? UserDatabase.shared.updateSettings { $0.planReaderCount = newValue }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        let readCount = readings.filter(isRead).count
        return HStack(spacing: 6) {
            Text("^[\(readings.count) reading](inflect: true)")
            if planMetaData.isFullyResolved {
                Text("·")
                Text("\(planMetaData.readingTime) min")
            }
            Spacer()
            if readCount == readings.count {
                Label("All read", systemImage: "checkmark")
                    .foregroundStyle(.tint)
            } else if readCount > 0 {
                Text("\(readCount) of \(readings.count) read")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Read Through

    /// Through the day's readings in order, from the first not yet read: in
    /// the in-app Bible, or, with that off, one at a time in the Bible app
    /// chosen in Settings, named on the button.
    @ViewBuilder
    private var readThroughButton: some View {
        let firstUnread = readings.first { !isRead($0) }
        let next = firstUnread ?? readings.first
        let allRead = firstUnread == nil
        let started = readings.contains(where: isRead)
        if userSettings.planInAppBible {
            readThroughStyle(allRead: allRead) {
                NavigationLink {
                    reader(at: next)
                } label: {
                    Label(
                        allRead ? "Read Again" : started ? "Continue Reading" : "Start Reading",
                        systemImage: "book.fill"
                    )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        } else if let app = externalApp, let next {
            readThroughStyle(allRead: allRead) {
                Button {
                    openExternally(next, in: app)
                } label: {
                    Label(
                        allRead ? "Read Again in \(app.name)"
                            : started ? "Continue in \(app.name)" : "Start in \(app.name)",
                        systemImage: "arrow.up.forward.app"
                    )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Prominent while there's reading left; once all is read it steps back,
    /// leaving the day's readings to say they're done.
    @ViewBuilder
    private func readThroughStyle<Content: View>(allRead: Bool, @ViewBuilder content: () -> Content) -> some View {
        if allRead {
            content()
                .buttonStyle(.bordered)
                .controlSize(.large)
        } else {
            content()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func reader(at reading: ReadingMetaData?) -> some View {
        SplitReaderView(
            date: $date,
            initialVerseId: reading?.sv,
            initialToolbarMode: .plan,
            initialPlanId: planMetaData.id
        )
    }

    // MARK: - Reading Card

    private func card(_ reading: ReadingMetaData) -> some View {
        let read = isRead(reading)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    toggleRead(reading)
                } label: {
                    Image(systemName: read ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reading.description)
                .accessibilityValue(read ? "Read" : "Not read")
                .accessibilityHint(read ? "Marks this reading unread" : "Marks this reading read")

                opener(for: reading) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reading.description)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(read ? .secondary : .primary)
                            Text(details(reading))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let glyph = openerGlyph {
                            Image(systemName: glyph)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }

            HStack {
                ReaderSplitControl(
                    chapterVerseCounts: reading.chapterVerseCounts,
                    isResolved: reading.isResolved,
                    readerCount: $readerCount
                )
                Spacer()
                // The way out to the other app, named so it's plain where it
                // goes, beside the in-app Bible's way in: the reading itself.
                if let app = externalApp {
                    Button {
                        openExternally(reading, in: app)
                    } label: {
                        // The arrow says it opens another app; each card
                        // repeating "Open in" said it louder than it needed.
                        Label(app.name, systemImage: "arrow.up.forward.app")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Open \(reading.description) in \(app.name)")
                }
            }
            .frame(minHeight: 32)
            .padding(.leading, 48)
        }
        .padding(EdgeInsets(top: 6, leading: 4, bottom: 10, trailing: 14))
        .if(stackHorizontally) { view in
            view.frame(width: 325)
        }
        .background(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
        )
    }

    private func details(_ reading: ReadingMetaData) -> String {
        reading.isResolved ? "\(reading.genre) · \(reading.readingTime) min" : reading.genre
    }

    /// What tapping a reading does: opens it in the in-app Bible, or else in
    /// the Bible app chosen in Settings, or else, with nowhere to open it,
    /// marks it as the circle does.
    @ViewBuilder
    private func opener<Label: View>(for reading: ReadingMetaData, @ViewBuilder label: () -> Label) -> some View {
        if userSettings.planInAppBible {
            NavigationLink {
                reader(at: reading)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        } else if let app = externalApp {
            Button {
                openExternally(reading, in: app)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens in \(app.name)")
        } else {
            Button {
                toggleRead(reading)
            } label: {
                label()
            }
            .buttonStyle(.plain)
        }
    }

    /// The sign at a reading's end of where tapping it goes: further into
    /// Lamp, or out to another app.
    private var openerGlyph: String? {
        if userSettings.planInAppBible { return "chevron.right" }
        if externalApp != nil { return "arrow.up.forward.app" }
        return nil
    }

    // MARK: - Actions

    private func toggleRead(_ reading: ReadingMetaData) {
        if completedReadingIds.contains(reading.id) {
            try? UserDatabase.shared.removeCompletedReading(reading.id)
            completedReadingIds.remove(reading.id)
        } else {
            try? UserDatabase.shared.addCompletedReading(reading.id)
            completedReadingIds.insert(reading.id)
        }
        WidgetDataService.shared.refreshWidget()
    }

    private func openExternally(_ reading: ReadingMetaData, in app: ExternalBibleApp) {
        guard let url = app.getFullUrl(sv: reading.sv, ev: reading.ev),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        if !completedReadingIds.contains(reading.id) {
            try? UserDatabase.shared.addCompletedReading(reading.id)
            completedReadingIds.insert(reading.id)
            WidgetDataService.shared.refreshWidget()
        }
    }

    private func syncFromDatabase() {
        let settings = UserDatabase.shared.getSettings()
        userSettings = settings
        completedReadingIds = UserDatabase.shared.getCompletedReadingIds()
        // Keep every plan's control in step — each ReadingsView holds its own copy
        readerCount = settings.planReaderCount
    }
}

// MARK: - Reader Split Control

struct ReaderSplitControl: View {
    let chapterVerseCounts: [Int]
    /// False while the translation database could not be read, so the counts
    /// are unknown rather than zero.
    var isResolved: Bool = true
    @Binding var readerCount: Int

    private var totalVerses: Int { chapterVerseCounts.reduce(0, +) }

    private var labelContent: Text {
        // Showing "0v" for a tally nobody could read states something false;
        // say nothing is known instead.
        guard isResolved else { return Text("—") }
        // A reading can legitimately resolve to no verses (e.g. the selected
        // translation doesn't cover the range), so never index into the counts.
        guard readerCount > 1, let firstCount = chapterVerseCounts.first else {
            return Text("\(totalVerses)v")
        }
        let split = { (count: Int) -> Int in
            let floor = count / readerCount
            let ceil = floor + (count % readerCount == 0 ? 0 : 1)
            let floorRemainder = count - floor * readerCount
            let ceilRemainder = ceil * readerCount - count
            return ceilRemainder <= floorRemainder ? ceil : floor
        }
        var result = Text("\(split(firstCount))")
        for count in chapterVerseCounts.dropFirst() {
            result = result + Text(" · ") + Text("\(split(count))")
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
                        .foregroundStyle(.tint)
                    if readerCount > 3 {
                        Text("\(readerCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color(.systemBackground))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.accentColor, lineWidth: 0.5)
                            )
                            .offset(x: -4, y: -4)
                    }
                }
                labelContent
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                    .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .disabled(readerCount >= 20)
                }
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
    }
}
