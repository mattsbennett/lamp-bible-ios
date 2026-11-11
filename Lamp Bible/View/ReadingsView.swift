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
    /// The opening verse of the next reading not yet read, for the card
    /// that invites the reader in.
    @State private var upNext: (ref: Int, text: String)?
    /// The day card folded to a band, for those who go straight to the
    /// readings below it: kept on this device, for every plan.
    @AppStorage("plans.cardCollapsed") private var isCardCollapsed = false
    @Binding var date: Date
    let planMetaData: PlanMetaData
    let stackHorizontally: Bool

    private var readings: [ReadingMetaData] { planMetaData.readingMetaData }

    /// The Bible app chosen in Settings to open readings in, if one is and
    /// it's still installed: one removed since would leave buttons that do
    /// nothing.
    private var externalApp: ExternalBibleApp? {
        guard let name = userSettings.planExternalBible else { return nil }
        return externalBibleApps.first { $0.name == name && $0.isInstalled }
    }

    /// Whether the readings are read aloud in turns, as Settings sets: one
    /// reader, the usual case, shows nothing of it.
    private var sharesAmongReaders: Bool { readerCount > 1 }

    private func isRead(_ reading: ReadingMetaData) -> Bool {
        completedReadingIds.contains(reading.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
                .if(stackHorizontally) { view in
                    view.frame(maxWidth: 560)
                }
            VStack(alignment: .leading, spacing: 10) {
                Text("^[\(readings.count) Reading](inflect: true)")
                    .lampSectionHeader()
                    .padding(.horizontal, 6)
                    .accessibilityAddTraits(.isHeader)
                readingsList
            }
        }
        .task(id: readings.first(where: { !isRead($0) })?.sv) {
            await loadUpNext()
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

    // MARK: - Hero

    /// The day at a glance: which plan, where it stands in the year, how far
    /// through the day's readings, and the way through them. Set on the
    /// plan's own warm ground so the day's task is the first thing seen.
    /// It folds to a band, so the readings can sit higher on the screen.
    private var hero: some View {
        let readCount = readings.filter(isRead).count
        return Group {
            if isCardCollapsed {
                heroBand(readCount: readCount)
            } else {
                heroCard(readCount: readCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            HeroBackground()
                .clipShape(RoundedRectangle(cornerRadius: LampTheme.Radius.panel, style: .continuous))
        }
        .shadow(color: Color(red: 0.55, green: 0.1, blue: 0.2).opacity(0.22), radius: 18, y: 8)
    }

    private func heroCard(readCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heroEyebrow)
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Laid over the line rather than in it, so the card is no
                // taller for it.
                .overlay(alignment: .trailing) {
                    foldButton
                }
                .padding(.bottom, 6)
            Text(planMetaData.plan.name)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            summary(readCount: readCount)
                .padding(.top, 8)
            progressBar(readCount: readCount)
                .padding(.top, 14)
            if let reading = readings.first(where: { !isRead($0) }),
               let upNext, upNext.ref == reading.sv {
                upNextExcerpt(reading: reading, text: upNext.text)
                    .padding(.top, 18)
            }
            readThroughButton
                .padding(.top, 18)
        }
        .padding(20)
    }

    /// The card folded: the plan and how far through the day it is, in one
    /// band that opens the card again.
    private func heroBand(readCount: Int) -> some View {
        Button {
            withAnimation(.snappy) { isCardCollapsed = false }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(planMetaData.plan.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    readStatus(readCount: readCount)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                    foldGlyph
                }
                progressBar(readCount: readCount)
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 16, trailing: 20))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(planMetaData.plan.name)
        .accessibilityValue(readCount == readings.count ? "All read" : "\(readCount) of \(readings.count) read")
        .accessibilityHint("Shows the whole card")
        .accessibilityAddTraits(.isButton)
    }

    /// Folds the card to its band.
    private var foldButton: some View {
        Button {
            withAnimation(.snappy) { isCardCollapsed = true }
        } label: {
            foldGlyph
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -7)
        .accessibilityLabel("Collapse")
    }

    /// A chevron on a disc of light, pointing the way the card will go.
    private var foldGlyph: some View {
        Image(systemName: isCardCollapsed ? "chevron.down" : "chevron.up")
            .font(.footnote.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.2), in: Circle())
    }

    /// "Day 310 of 365": where a year-long plan stands on this date.
    private var heroEyebrow: String {
        let calendar = Calendar.current
        let date = planMetaData.date
        guard let duration = planMetaData.plan.duration, duration >= 365,
              let day = calendar.ordinality(of: .day, in: .year, for: date),
              let days = calendar.range(of: .day, in: .year, for: date)?.count
        else {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()
        }
        return "DAY \(day) OF \(days)"
    }

    // MARK: - Summary

    private func summary(readCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("^[\(readings.count) reading](inflect: true)")
            if planMetaData.isFullyResolved {
                Text("·")
                Text("\(planMetaData.readingTime) min")
            }
            Spacer()
            readStatus(readCount: readCount)
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.92))
    }

    /// "1 of 3 read", or once they all are, saying so.
    @ViewBuilder
    private func readStatus(readCount: Int) -> some View {
        if readCount == readings.count {
            Label("All read", systemImage: "checkmark.circle.fill")
                .fontWeight(.semibold)
        } else {
            Text("\(readCount) of \(readings.count) read")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    /// One segment per reading, filled as each is read.
    private func progressBar(readCount: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(readings, id: \.id) { reading in
                Capsule()
                    .fill(isRead(reading) ? Color.white : Color.white.opacity(0.28))
                    .frame(height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(readCount) of \(readings.count) read")
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
            NavigationLink {
                reader(at: next)
            } label: {
                HeroButtonLabel(
                    title: allRead ? "Read Again" : started ? "Continue Reading" : "Start Reading",
                    systemImage: "book.fill",
                    prominent: !allRead
                )
            }
            .buttonStyle(HeroButtonStyle())
        } else if let app = externalApp, let next {
            Button {
                openExternally(next, in: app)
            } label: {
                HeroButtonLabel(
                    title: allRead ? "Read Again in \(app.name)"
                        : started ? "Continue in \(app.name)" : "Start in \(app.name)",
                    systemImage: "arrow.up.forward.app",
                    prominent: !allRead
                )
            }
            .buttonStyle(HeroButtonStyle())
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

    // MARK: - Up Next

    /// The next reading's opening words, set in the reader's serif, so the
    /// day opens on the text itself rather than only a list of it.
    private func upNextExcerpt(reading: ReadingMetaData, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT · \(verseReference(reading.sv).uppercased())")
                .font(.caption2.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.78))
            Text(Self.excerpt(text))
                .font(.system(size: 18, weight: .regular, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A verse cut where it pauses, not mid-word: at the last sentence end
    /// that fits, or else the last clause, so the card holds three lines.
    static func excerpt(_ text: String, limit: Int = 150) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let minimum = limit / 3
        func lastIndex(of marks: Set<Character>) -> String.Index? {
            var found: String.Index?
            var index = head.startIndex
            while index < head.endIndex {
                if marks.contains(head[index]), head.distance(from: head.startIndex, to: index) >= minimum {
                    found = index
                }
                index = head.index(after: index)
            }
            return found
        }
        if let end = lastIndex(of: [".", "?", "!"]) {
            return String(head[...end])
        }
        if let end = lastIndex(of: [",", ";", ":"]) {
            return String(head[..<end]) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Hosea 3:1"
    private func verseReference(_ ref: Int) -> String {
        let book = ref / 1_000_000
        let chapter = (ref % 1_000_000) / 1_000
        let verse = ref % 1_000
        return "\(BookOsisCache.shared.displayName(for: book)) \(chapter):\(verse)"
    }

    /// Reads the verse off the main thread: it's a database query, and this
    /// runs whenever the next reading changes.
    private func loadUpNext() async {
        guard let reading = readings.first(where: { !isRead($0) }) else {
            upNext = nil
            return
        }
        if upNext?.ref == reading.sv { return }
        let translationId = userSettings.readerTranslationId
        let ref = reading.sv
        let text = await Task.detached(priority: .utility) {
            (try? TranslationDatabase.shared.getVerse(translationId: translationId, ref: ref))?.text
        }.value
        guard !Task.isCancelled else { return }
        if let text, !text.isEmpty {
            upNext = (ref, text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            upNext = nil
        }
    }

    // MARK: - Readings

    /// The day's readings in one card on a phone; on a wide screen, each its
    /// own card side by side.
    @ViewBuilder
    private var readingsList: some View {
        if stackHorizontally {
            ConditionalStack(isHorizonalStack: true) {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    row(reading)
                        .frame(width: 325)
                        .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
                        .id(index)
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    if index > 0 {
                        Divider().padding(.leading, 62)
                    }
                    row(reading)
                        .id(index)
                }
            }
            .background(LampTheme.card, in: RoundedRectangle(cornerRadius: LampTheme.Radius.card, style: .continuous))
        }
    }

    private func row(_ reading: ReadingMetaData) -> some View {
        let read = isRead(reading)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    toggleRead(reading)
                } label: {
                    Image(systemName: read ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: read)
                        .frame(width: 48, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reading.description)
                .accessibilityValue(read ? "Read" : "Not read")
                .accessibilityHint(read ? "Marks this reading unread" : "Marks this reading read")

                opener(for: reading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.description)
                            .font(.headline)
                            .foregroundStyle(read ? .secondary : .primary)
                        Text(details(reading))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }

                if let glyph = openerGlyph {
                    // The same way in as the name, so the whole row's end
                    // answers a tap; once is enough for VoiceOver.
                    opener(for: reading) {
                        Image(systemName: glyph)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHidden(true)
                }
            }

            // Below the name rather than beside it, which left "2 Chronicles
            // 36" too narrow a column to keep to one line; side by side
            // where they fit, else one above the other. Beside the Bible
            // app's button the chip counts the readers by its figure alone,
            // on every row alike, so they keep to one line on a phone and
            // the day's readings stay on its screen.
            if sharesAmongReaders || externalApp != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        readingActions(reading, chip: externalApp == nil ? .chip : .shortChip)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        readingActions(reading, chip: .chip)
                    }
                }
                .padding(.leading, 54)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 14))
    }

    @ViewBuilder
    private func readingActions(_ reading: ReadingMetaData, chip: ReaderSplitControl.Style) -> some View {
        // How many verses each reader takes in turn.
        if sharesAmongReaders {
            ReaderSplitControl(
                chapterVerseCounts: reading.chapterVerseCounts,
                isResolved: reading.isResolved,
                readerCount: $readerCount,
                style: chip
            )
            .fixedSize()
        }

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
            .buttonBorderShape(.capsule)
            .fixedSize()
            .accessibilityLabel("Open \(reading.description) in \(app.name)")
        }
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

// MARK: - Hero Pieces

/// The day card's ground: a deep, warm red rising into amber at one corner.
/// Fixed colours rather than the accent's, which lightens in dark mode and
/// would take white text below a readable contrast.
private struct HeroBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.80, green: 0.18, blue: 0.27),
                    Color(red: 0.52, green: 0.10, blue: 0.26),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.98, green: 0.62, blue: 0.33).opacity(0.62), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 260
            )
            // A faint grain of light along the top edge, as on glass.
            LinearGradient(
                colors: [.white.opacity(0.10), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

private struct HeroButtonLabel: View {
    let title: String
    let systemImage: String
    /// Solid while there's reading left; once all is read it steps back,
    /// leaving the readings to say they're done.
    let prominent: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(prominent ? Color(red: 0.70, green: 0.13, blue: 0.24) : .white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.2)),
                in: Capsule()
            )
            .contentShape(Capsule())
    }
}

private struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Reader Split Control

struct ReaderSplitControl: View {
    let chapterVerseCounts: [Int]
    /// False while the translation database could not be read, so the counts
    /// are unknown rather than zero.
    var isResolved: Bool = true
    @Binding var readerCount: Int
    /// `.chip` names what the number counts, for a reading's row on the
    /// home screen; `.compact` is the reader toolbar's short form.
    var style: Style = .compact

    enum Style {
        case compact
        case chip
        /// The chip with the readers counted by its figure alone, as the
        /// toolbar's short form counts them, to fit beside the Bible app's
        /// button.
        case shortChip
    }

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

    /// "27 verses", or "3 readers · 9 · 9 · 9 ea.": what the chip counts,
    /// said in words rather than a bare "27v".
    private var chipText: Text {
        guard isResolved else { return Text("Verses unknown") }
        guard readerCount > 1, !chapterVerseCounts.isEmpty else {
            return Text("^[\(totalVerses) verse](inflect: true)")
        }
        return Text("\(readerCount) readers · ") + labelContent
    }

    /// "9 · 9 · 9 ea.", the readers left to the figure beside it. One
    /// reader's "27 verses" is short already, and says what it counts.
    private var shortChipText: Text {
        guard isResolved, readerCount > 1, !chapterVerseCounts.isEmpty else { return chipText }
        return labelContent
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            switch style {
            case .compact:
                compactLabel
            case .chip, .shortChip:
                HStack(spacing: 5) {
                    if style == .shortChip {
                        countedPersonIcon(font: .caption.weight(.semibold))
                    } else {
                        Image(systemName: personIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    (style == .shortChip ? shortChipText : chipText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LampTheme.tileFill, in: Capsule())
                .contentShape(Capsule())
            }
        }
        .if(style != .compact) { view in
            view
                .accessibilityLabel("Readers: \(readerCount)")
                .accessibilityValue(chipText)
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

    private var compactLabel: some View {
        HStack(spacing: 4) {
            countedPersonIcon(font: .caption)
            labelContent
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One, two or three people for as many readers; past three, a badge
    /// with the count.
    private func countedPersonIcon(font: Font) -> some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: personIcon)
                .font(font)
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
    }
}
