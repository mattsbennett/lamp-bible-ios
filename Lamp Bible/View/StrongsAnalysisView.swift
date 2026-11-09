import SwiftUI
import LampCore
import LampModuleKit

/// A Strong's key to analyse, for a sheet or a pushed page.
struct StrongsAnalysisItem: Identifiable, Hashable {
    let key: String
    var id: String { key }
}

/// How many renderings and companions the analysis lists.
private let strongsAnalysisListed = 8

/// A key's headword and short meaning, from the bundled lexicons keyed by
/// Strong's: the lemma Strong's gives, else another's; for a meaning a
/// lexicon's own gloss (TBESG's, for Greek, which has the Septuagint's extended
/// numbers too), else Dodson's short definition, which is a gloss, else
/// Strong's own definition, the shortest the bundle has for Hebrew.
struct StrongsHeadword: Sendable {
    let lemma: String?
    let transliteration: String?
    let gloss: String?

    static func lookUp(_ key: String) -> StrongsHeadword {
        let database = BundledModuleDatabase.shared
        let language = BundledModuleDatabase.Lexicon.language(ofStrongs: key)
        let entries = database.lexicons()
            .filter { $0.language == language && $0.isKeyedByStrongs }
            .compactMap { lexicon in
                (try? database.getDictionaryEntry(moduleId: lexicon.moduleId, key: key))
                    .map { (lexicon: lexicon.lexiconKey, entry: $0) }
            }
        let strongs = entries.first { $0.lexicon == "strongs" }?.entry
        let dodson = entries.first { $0.lexicon == "dodson" }?.entry
        return StrongsHeadword(
            lemma: strongs?.lemma ?? entries.first?.entry.lemma,
            transliteration: strongs?.transliteration
                ?? entries.lazy.compactMap(\.entry.transliteration).first,
            gloss: entries.lazy.compactMap { $0.entry.senses.first?.gloss }.first
                ?? dodson?.senses.first?.shortDefinition?.plainText
                ?? strongs?.senses.first?.definition?.plainText
        )
    }
}

/// The analysis in a sheet of its own, from the Strong's sheet or the results
/// of a Strong's search. A companion opens its own analysis on the same stack.
struct StrongsAnalysisSheet: View {
    let key: String
    let translationId: String
    var onNavigateToVerse: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            analysis(of: key)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                    }
                }
                .navigationDestination(for: StrongsAnalysisItem.self) { item in
                    analysis(of: item.key)
                }
        }
    }

    private func analysis(of key: String) -> StrongsAnalysisView {
        StrongsAnalysisView(
            key: key,
            translationId: translationId,
            onNavigateToVerse: onNavigateToVerse.map { navigate in
                { verse in
                    dismiss()
                    navigate(verse)
                }
            }
        )
    }
}

/// What the current translation's tags say about one Strong's key
/// (`LampStrongsAnalysis`): how often it occurs, the English that renders it,
/// where in the canon it gathers, and the keys found with it. The phone's
/// share of the Mac's analysis, without its comparison of translations, its
/// grammar or its chapters.
struct StrongsAnalysisView: View {
    let key: String
    let translationId: String
    var onNavigateToVerse: ((Int) -> Void)? = nil

    @State private var analysis: LampStrongsAnalysis?
    @State private var isLoading = true
    @State private var headword = StrongsHeadword(lemma: nil, transliteration: nil, gloss: nil)
    @State private var companionHeadwords: [String: StrongsHeadword] = [:]
    @State private var occurrencesByVerse: [Int: [LampStrongsAnalysis.Occurrence]] = [:]
    @State private var renderingFilter: String?
    @State private var bookFilter: Int?
    @State private var shownVerseCount = 50
    @State private var previewReference: VersePreviewReference?
    @State private var septuagint = SeptuagintLoader()
    /// Collapsed to begin with: the Septuagint is a second subject, and
    /// opening it costs a search of the Hebrew text a word.
    @State private var isShowingSeptuagint = false
    @State private var septuagintPreview: SeptuagintPreview?
    @AppStorage("strongs.analysis.bookChartAsRing") private var showsRing = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("strongs.analysis.renderingChartAsRing") private var showsRenderingRing = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Counting \(key)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let analysis, analysis.occurrenceCount > 0 {
                content(analysis)
            } else {
                ContentUnavailableView(
                    "Not Tagged Here",
                    systemImage: "chart.bar.xaxis",
                    description: Text("No word in this translation is tagged \(key).")
                )
            }
        }
        // The key is in the headword's pill; the bar says what the page is.
        .navigationTitle("Word Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: key) { await load() }
        .sheet(item: $previewReference) { preview in
            VersePreviewSheet(
                title: Self.referenceTitle(
                    preview.id,
                    bookNames: Dictionary((analysis?.books ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                ),
                verseId: preview.id,
                translationId: translationId,
                highlightQuery: key,
                highlightMode: .strongs,
                onOpen: onNavigateToVerse.map { navigate in { navigate(preview.id) } }
            )
        }
        .sheet(item: $septuagintPreview) { preview in
            VersePreviewSheet(
                title: Self.referenceTitle(preview.id, bookNames: [:]),
                verseId: preview.id,
                translationId: translationId,
                highlightQuery: preview.key,
                highlightMode: .strongs,
                onOpen: onNavigateToVerse.map { navigate in { navigate(preview.id) } }
            )
        }
    }

    private func load() async {
        let key = key
        let translationId = translationId
        // A pass over every tagged verse of the translation, and a few
        // lexicon lookups: off the main thread.
        let loaded = await Task.detached(priority: .userInitiated) {
            let analysis = try? TranslationDatabase.shared.analyzeStrongs(key: key, translationId: translationId)
            var companions: [String: StrongsHeadword] = [:]
            for companion in analysis?.companions.prefix(strongsAnalysisListed) ?? [] {
                companions[companion.key] = StrongsHeadword.lookUp(companion.key)
            }
            return (analysis, StrongsHeadword.lookUp(key), companions)
        }.value
        guard !Task.isCancelled else { return }
        analysis = loaded.0
        headword = loaded.1
        companionHeadwords = loaded.2
        occurrencesByVerse = Dictionary(grouping: loaded.0?.occurrences ?? [], by: \.reference)
        isLoading = false
        await septuagint.loadWords(key: key)
    }

    private func content(_ analysis: LampStrongsAnalysis) -> some View {
        List {
            Section {
                summary(analysis)
            } footer: {
                // The rate, outside the card: the card keeps to the figures
                // and the chart.
                Text("About \(analysis.ratePerThousandWords.formatted(.number.precision(.fractionLength(0...1)))) in every 1,000 tagged \(languageName) words of the \(analysis.translationAbbreviation ?? analysis.translationName).")
            }
            if !analysis.renderings.isEmpty {
                Section {
                    Picker("Chart", selection: $showsRenderingRing) {
                        Text("List").tag(false)
                        Text("Ring").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    if showsRenderingRing {
                        renderingShare(analysis)
                    } else {
                        renderings(analysis)
                    }
                } header: {
                    sectionHeader("Rendered As")
                } footer: {
                    Text(showsRenderingRing
                        ? "How its \(analysis.occurrenceCount) occurrences are rendered, the commonest first. Tap one to filter the verse list below."
                        : "Tap one to filter the verse list below.")
                }
            }
            Section {
                Picker("Chart", selection: $showsRing) {
                    Text("Bars").tag(false)
                    Text("Ring").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                if showsRing {
                    bookShare(analysis)
                } else {
                    books(analysis)
                }
            } header: {
                sectionHeader("By Book")
            } footer: {
                Text(showsRing
                    ? "Where its \(analysis.occurrenceCount) occurrences fall, the books holding most first. Tap a book to filter the verse list below."
                    : "Expected is the share a book of its length would hold. ↑ More and ↓ fewer mark a gap too wide to be chance. Tap a book to filter the verse list below.")
            }
            if !analysis.companions.isEmpty {
                Section {
                    companions(analysis)
                } header: {
                    sectionHeader("Found With")
                } footer: {
                    Text("Most certain first: a word that shares many verses with this one leads one that shares a few, however rare it is.")
                }
            }
            if !septuagint.words.isEmpty {
                septuagintSection
            }
            verses(analysis)
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        // The card at the top sits as far below the bar as it does from the
        // sheet's sides.
        .contentMargins(.top, 16, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 36)
        // An opaque bar over the list: rows pass cleanly under its edge rather
        // than ghosting through a blur or being sliced by an invisible one.
        .toolbarBackground(LampTheme.groupedBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay(alignment: .top) {
            // The bar's lower edge, drawn: rows go under a line, not into air.
            Rectangle()
                .fill(LampTheme.hairline)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    /// A section's title, set as a heading rather than a grey caption.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color(uiColor: .label))
            .textCase(nil)
            .padding(.top, 6)
    }

    // MARK: Summary

    private var languageName: String {
        key.hasPrefix("H") ? "Hebrew" : key.hasPrefix("G") ? "Greek" : "original-language"
    }

    private func summary(_ analysis: LampStrongsAnalysis) -> some View {
        let booksWithIt = analysis.booksWithOccurrences
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(headword.lemma ?? analysis.key)
                        .font(.system(size: 44, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(analysis.key)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(LampTheme.tileFill, in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let transliteration = headword.transliteration, !transliteration.isEmpty {
                        Text(transliteration)
                            .font(.system(.title3, design: .serif))
                            .italic()
                            .foregroundStyle(LampTheme.readerText.opacity(0.8))
                    }
                    if let gloss = headword.gloss, !gloss.isEmpty {
                        Text(gloss)
                            .font(.title3.weight(.medium))
                    }
                }
            }

            // The figures that answer "how common is it": a label over a large
            // number, its unit small beside it, to take in at a glance.
            HStack(alignment: .top, spacing: 0) {
                statTile(label: "Occurrences", value: "\(analysis.occurrenceCount)", unit: "")
                statTile(label: "Verses", value: "\(analysis.verseCount)", unit: "")
                statTile(label: "Books", value: "\(booksWithIt)", unit: "of \(analysis.books.count)")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(analysis.occurrenceCount) times in \(analysis.verseCount) verses, in \(booksWithIt) of \(analysis.books.count) books")

            if analysis.books.count > 1 {
                StrongsCanonStrip(books: analysis.books, color: barColor)
            }
        }
        .padding(.vertical, 12)
        .listRowBackground(heroBackground)
    }

    /// The headword card's ground: a step lighter than the sheet in dark, so
    /// it stands off it, and warmed at its top corner by a soft glow of the
    /// accent, the one place the analysis is lit rather than laid out.
    private var heroBackground: some View {
        LampTheme.heroCard
            .overlay {
                RadialGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.13 : 0.16), Color.accentColor.opacity(0)],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 300
                )
            }
    }

    private func statTile(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(LampTheme.caption)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Renderings

    @ViewBuilder
    private func renderings(_ analysis: LampStrongsAnalysis) -> some View {
        let listed = Array(analysis.renderings.prefix(strongsAnalysisListed))
        let most = max(listed.map(\.count).max() ?? 1, 1)
        // Renderings used more than once get a row and a bar; those used once
        // share one row of chips, where a bar each told nothing.
        let repeated = listed.filter { $0.count > 1 || listed.count <= 3 }
        let once = listed.filter { !($0.count > 1 || listed.count <= 3) }
        ForEach(repeated) { rendering in
            renderingRow(rendering, most: most)
        }
        if !once.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Once each")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(once) { rendering in
                        renderingChip(rendering)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private func renderingRow(_ rendering: LampStrongsAnalysis.Rendering, most: Int) -> some View {
        let isSelected = renderingFilter == rendering.id
        return Button {
            renderingFilter = isSelected ? nil : rendering.id
            shownVerseCount = 50
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rendering.text.isEmpty ? "(no English word)" : rendering.text)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        let variants = rendering.variants
                            .filter { $0.text != rendering.text }
                            .prefix(3)
                            .map(\.text)
                        if !variants.isEmpty {
                            Text(variants.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if isSelected {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    Text("\(rendering.count)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                StrongsBarTrack(
                    fraction: CGFloat(rendering.count) / CGFloat(most),
                    // A neutral share: colour in this view means more or
                    // fewer than expected, and the accent means chosen.
                    color: isSelected ? Color.accentColor : StrongsBarTrack.neutral,
                    height: 6
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A rendering used once: a chip that filters the verses to it.
    private func renderingChip(_ rendering: LampStrongsAnalysis.Rendering) -> some View {
        let isSelected = renderingFilter == rendering.id
        return Button {
            renderingFilter = isSelected ? nil : rendering.id
            shownVerseCount = 50
        } label: {
            Text(rendering.text.isEmpty ? "(no English word)" : rendering.text)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.14) : LampTheme.tileFill)
                )
                .overlay {
                    if isSelected { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rendering.text.isEmpty ? "no English word" : rendering.text), once")
        .accessibilityHint("Filters the verse list")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Books

    /// The books in runs of one canon division (Gospels, Paul's Letters…),
    /// in order, so a long list has landmarks.
    private func bookGroups(_ books: [LampStrongsAnalysis.Division]) -> [(name: String, books: [LampStrongsAnalysis.Division])] {
        var groups: [(name: String, books: [LampStrongsAnalysis.Division])] = []
        for book in books {
            let name = LampStrongsAnalysis.canonSections.first { $0.books.contains(book.id) }?.name ?? ""
            if let last = groups.last, last.name == name {
                groups[groups.count - 1].books.append(book)
            } else {
                groups.append((name, [book]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func books(_ analysis: LampStrongsAnalysis) -> some View {
        let most = max(analysis.books.map(\.occurrenceCount).max() ?? 1, 1)
        ForEach(Array(bookGroups(analysis.books).enumerated()), id: \.offset) { _, group in
            if !group.name.isEmpty {
                Text(group.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(LampTheme.caption)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 2, trailing: 16))
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(group.books) { book in
                bookRow(book, most: most)
            }
        }
    }

    private func bookRow(_ book: LampStrongsAnalysis.Division, most: Int) -> some View {
        let isSelected = bookFilter == book.id
        let isEmpty = book.occurrenceCount == 0
        return Button {
            // A book without the word has no verses to filter to.
            guard !isEmpty else { return }
            bookFilter = isSelected ? nil : book.id
            shownVerseCount = 50
        } label: {
            HStack(spacing: 10) {
                Text(book.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .leading)
                StrongsBarTrack(
                    fraction: CGFloat(book.occurrenceCount) / CGFloat(most),
                    color: barColor(book.expectation),
                    height: 10
                )
                Text(isEmpty ? "–" : "\(book.occurrenceCount)")
                    .font(.subheadline.weight(isEmpty ? .regular : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                    .frame(minWidth: 24, alignment: .trailing)
                Image(systemName: book.expectation == .fewer ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(barColor(book.expectation))
                    .opacity(book.expectation == .asExpected ? 0 : 1)
                    .frame(width: 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not disabled, which would fade the row past reading: a zero is
        // a finding too.
        .allowsHitTesting(!isEmpty)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.name), \(book.occurrenceCount) times\(expectationPhrase(book.expectation))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Share

    /// A share as core slices it for a deck's ring (`LampPresentationChart`):
    /// the largest first, the rest gathered as "Others", each named slice a
    /// way to filter the verses.
    @ViewBuilder
    private func share(
        _ analysis: LampStrongsAnalysis,
        by grouping: LampPresentationChart.Grouping,
        filterIDs: [String: String],
        selectedID: String?,
        toggle: @escaping (String) -> Void
    ) -> some View {
        let chart = LampPresentationChart(
            source: .init(strongs: analysis.key, translationID: analysis.translationID),
            by: grouping,
            style: .share
        )
        let slices = chart.values(from: analysis)
        let total = slices.reduce(0) { $0 + $1.value }
        StrongsShareRing(slices: slices, total: Int(total)) { index in
            shareColor(index, of: slices)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        // "Others" names nothing to filter by, so its row is no button.
        ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
            let filterID = filterIDs[slice.label]
            let isSelected = filterID != nil && selectedID == filterID
            Button {
                if let filterID { toggle(filterID) }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(shareColor(index, of: slices))
                        .frame(width: 10, height: 10)
                    Text(slice.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(slice.value))")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("\(total > 0 ? Int((slice.value / total * 100).rounded()) : 0)%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(filterID == nil)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// The books' share, filtering by book.
    @ViewBuilder
    private func bookShare(_ analysis: LampStrongsAnalysis) -> some View {
        share(
            analysis,
            by: .book,
            filterIDs: Dictionary(analysis.books.map { ($0.name, String($0.id)) }, uniquingKeysWith: { first, _ in first }),
            selectedID: bookFilter.map(String.init)
        ) { id in
            let book = Int(id)
            bookFilter = bookFilter == book ? nil : book
            shownVerseCount = 50
        }
    }

    /// The renderings' share, filtering by rendering. Core labels the one with
    /// no English of its own "(no English)".
    @ViewBuilder
    private func renderingShare(_ analysis: LampStrongsAnalysis) -> some View {
        share(
            analysis,
            by: .rendering,
            filterIDs: Dictionary(
                analysis.renderings.map { ($0.text.isEmpty ? "(no English)" : $0.text, $0.id) },
                uniquingKeysWith: { first, _ in first }
            ),
            selectedID: renderingFilter
        ) { id in
            renderingFilter = renderingFilter == id ? nil : id
            shownVerseCount = 50
        }
    }

    /// One hue, deepest for the largest slice, as a deck's ring has it; the
    /// gathered rest faintest, being a remainder rather than a finding.
    private func shareColor(_ index: Int, of slices: [LampPresentationChart.Value]) -> Color {
        let isOthers = index == slices.count - 1 && slices.count == LampPresentationChart.shareSlices
            && slices[index].label == "Others"
        guard !isOthers else { return Color.accentColor.opacity(0.2) }
        guard slices.count > 1 else { return .accentColor }
        return Color.accentColor.opacity(1 - 0.6 * Double(index) / Double(slices.count - 1))
    }

    /// Blue against orange, a pair that stays apart for most colour vision,
    /// and not the app's red accent, which beside orange reads as one warm
    /// colour.
    private func barColor(_ expectation: LampStrongsAnalysis.Expectation) -> Color {
        switch expectation {
        case .more: .blue
        case .fewer: .orange
        case .asExpected: StrongsBarTrack.neutral
        }
    }

    private func expectationPhrase(_ expectation: LampStrongsAnalysis.Expectation) -> String {
        switch expectation {
        case .more: ", more than its length predicts"
        case .fewer: ", fewer than its length predicts"
        case .asExpected: ""
        }
    }

    // MARK: Companions

    private func companions(_ analysis: LampStrongsAnalysis) -> some View {
        // In the order given, by how certain each association is. Sorted by
        // how many times chance it is instead, a pairing from two verses would
        // lead.
        ForEach(analysis.companions.prefix(strongsAnalysisListed)) { companion in
            let companionHeadword = companionHeadwords[companion.key]
            NavigationLink(value: StrongsAnalysisItem(key: companion.key)) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(companionHeadword?.lemma ?? companion.key)
                                .font(.headline)
                            Text(companion.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let gloss = companionHeadword?.gloss, !gloss.isEmpty {
                            Text(gloss)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(companion.sharedVerseCount) shared")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Septuagint

    /// For a Greek word the lexicon gives Hebrew for, and collapsed: the
    /// Hebrew it renders in the Septuagint, each word followable to its own
    /// analysis where it has a number, then each one's Old Testament verses
    /// with the Septuagint's Greek. Nothing here is counted above.
    private var septuagintSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isShowingSeptuagint) {
                ForEach(septuagint.words) { word in
                    translatesRow(word)
                }
                if septuagint.words.allSatisfy({ $0.references == nil }) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                ForEach(septuagint.words) { word in
                    if let references = word.references, !references.isEmpty {
                        SeptuagintWordGroup(word: word, references: references, loader: septuagint) { reference, key in
                            septuagintPreview = SeptuagintPreview(id: reference, key: key)
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Translates")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Marks either side of each separator keep the words in
                    // the lexicon's order left to right, rather than letting
                    // the Hebrew run them right to left as one phrase.
                    Text("\u{200E}" + septuagint.words
                        .map { LampSeptuagintSection.word($0.hebrew) }
                        .joined(separator: "\u{200E}  ·  \u{200E}"))
                        .font(.title3)
                        .lineLimit(1)
                }
            }
            .task(id: isShowingSeptuagint) {
                guard isShowingSeptuagint else { return }
                await septuagint.loadCounts(key: key)
            }
        } header: {
            sectionHeader("Septuagint")
        } footer: {
            Text("The Hebrew this word renders in the Greek Old Testament. The verses are each Hebrew word’s, not this word’s: the Septuagint doesn’t always use it there, and none are counted above.")
        }
    }

    /// A Hebrew word the Greek renders, with its meaning, followable to its
    /// own analysis where it has a number. A word the lexicon couldn't pin to
    /// one number is still shown: it is still what the Greek translates.
    @ViewBuilder
    private func translatesRow(_ word: SeptuagintLoader.Word) -> some View {
        if let strongs = word.hebrew.strongs {
            NavigationLink(value: StrongsAnalysisItem(key: strongs)) {
                hebrewWord(word, number: strongs)
            }
        } else {
            hebrewWord(word, number: nil)
        }
    }

    private func hebrewWord(_ word: SeptuagintLoader.Word, number: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LampSeptuagintSection.word(word.hebrew))
                    .font(.title3)
                if let number {
                    Text(number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let gloss = word.gloss, !gloss.isEmpty {
                Text(gloss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Verses

    private func filteredReferences(_ analysis: LampStrongsAnalysis) -> [Int] {
        guard renderingFilter != nil || bookFilter != nil else { return analysis.references }
        return analysis.references.filter { reference in
            if let bookFilter, reference / 1_000_000 != bookFilter { return false }
            if let renderingFilter {
                return occurrencesByVerse[reference]?.contains { $0.renderingID == renderingFilter } == true
            }
            return true
        }
    }

    @ViewBuilder
    private func verses(_ analysis: LampStrongsAnalysis) -> some View {
        let references = filteredReferences(analysis)
        let bookNames = Dictionary(analysis.books.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        Section {
            ForEach(references.prefix(shownVerseCount), id: \.self) { reference in
                verseRow(reference, bookNames: bookNames, analysis: analysis)
            }
            if references.count > shownVerseCount {
                Button("Show All \(references.count) Verses") {
                    shownVerseCount = references.count
                }
            }
        } header: {
            HStack {
                Text(versesTitle(references.count, analysis: analysis, bookNames: bookNames))
                Spacer()
                if renderingFilter != nil || bookFilter != nil {
                    Button("Show All") {
                        renderingFilter = nil
                        bookFilter = nil
                        shownVerseCount = 50
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }
    }

    private func versesTitle(_ count: Int, analysis: LampStrongsAnalysis, bookNames: [Int: String]) -> String {
        var title = "\(count) Verses"
        if let renderingFilter,
           let rendering = analysis.renderings.first(where: { $0.id == renderingFilter }) {
            title += " · “\(rendering.text)”"
        }
        if let bookFilter, let name = bookNames[bookFilter] {
            title += " · \(name)"
        }
        return title
    }

    /// As a search hit is shown: the reference over the verse cut around
    /// the key's first word, every one of its words marked as a find. A tap
    /// opens the verse over the analysis, with its context and a button to
    /// open it in the reader.
    private func verseRow(
        _ reference: Int,
        bookNames: [Int: String],
        analysis: LampStrongsAnalysis
    ) -> some View {
        Button {
            previewReference = VersePreviewReference(id: reference)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.referenceTitle(reference, bookNames: bookNames))
                    .font(.headline)
                    .foregroundStyle(.primary)
                SearchResultRow.snippetText(fromMarked: marked(reference, in: analysis), limit: 120)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func referenceTitle(_ reference: Int, bookNames: [Int: String]) -> String {
        let book = reference / 1_000_000
        return "\(bookNames[book] ?? BookOsisCache.shared.displayName(for: book)) \((reference % 1_000_000) / 1_000):\(reference % 1_000)"
    }

    /// The verse with each of the key's words wrapped in `<mark>`, as a
    /// search marks its hits. Offsets count Characters, as the analysis
    /// gives them.
    private func marked(_ reference: Int, in analysis: LampStrongsAnalysis) -> String {
        let characters = Array(analysis.verseTexts[reference] ?? "")
        var marked = ""
        var cursor = 0
        let spans = (occurrencesByVerse[reference] ?? [])
            .filter { $0.startOffset >= 0 && $0.startOffset < $0.endOffset && $0.endOffset <= characters.count }
            .sorted { $0.startOffset < $1.startOffset }
        for span in spans where span.startOffset >= cursor {
            marked += String(characters[cursor..<span.startOffset])
                + "<mark>" + String(characters[span.startOffset..<span.endOffset]) + "</mark>"
            cursor = span.endOffset
        }
        return marked + String(characters[cursor...])
    }
}

/// A ring of the whole, largest slice first from twelve o'clock, with the
/// total in its hole: the one number a share otherwise leaves you to add up.
/// A slice tapped is read out in the hole, its name, count and share, and
/// the rest fade: shades of one hue are hard to match to their rows by eye.
/// Tapping it again, or the hole, goes back to the total.
private struct StrongsShareRing: View {
    let slices: [LampPresentationChart.Value]
    let total: Int
    let color: (Int) -> Color

    @State private var selected: Int?

    private static let size: CGFloat = 140
    private static let holeRatio: CGFloat = 0.6

    private var sum: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let hole = radius * Self.holeRatio
                let sum = sum
                guard sum > 0 else { return }
                var start = Angle.degrees(-90)
                for (index, slice) in slices.enumerated() {
                    let sweep = Angle.degrees(360 * slice.value / sum)
                    var path = Path()
                    path.addArc(center: centre, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
                    path.addArc(center: centre, radius: hole, startAngle: start + sweep, endAngle: start, clockwise: true)
                    path.closeSubpath()
                    let isFaded = selected != nil && selected != index
                    context.fill(path, with: .color(color(index).opacity(isFaded ? 0.25 : 1)))
                    // A hairline in the row's own colour, so neighbouring
                    // slices of one hue stay apart.
                    context.stroke(path, with: .color(Color(uiColor: .secondarySystemGroupedBackground)), lineWidth: 1.5)
                    start += sweep
                }
            }
            .contentShape(Circle())
            .onTapGesture(coordinateSpace: .local) { location in
                let tapped = slice(at: location)
                withAnimation(.easeOut(duration: 0.15)) {
                    selected = tapped == selected ? nil : tapped
                }
            }
            readout
                .frame(width: Self.size * Self.holeRatio - 8)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size, height: Self.size)
        .onChange(of: slices.map(\.label)) { selected = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.label), \(Int($0.value))" }.joined(separator: "; "))
    }

    @ViewBuilder
    private var readout: some View {
        if let selected, slices.indices.contains(selected) {
            let slice = slices[selected]
            VStack(spacing: 0) {
                Text(slice.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                Text("\(Int(slice.value))")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(Self.share(slice.value, of: sum))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 0) {
                Text("\(total)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("in all")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func share(_ value: Double, of sum: Double) -> String {
        guard sum > 0 else { return "" }
        let percent = 100 * value / sum
        return percent > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// The slice under `location`, or nil in the hole or outside the ring.
    /// The slices run clockwise from twelve o'clock.
    private func slice(at location: CGPoint) -> Int? {
        let radius = Self.size / 2
        let dx = location.x - radius, dy = location.y - radius
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= radius * Self.holeRatio, distance <= radius, sum > 0 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }
        var end = 0.0
        for (index, slice) in slices.enumerated() {
            end += 360 * slice.value / sum
            if angle < end { return index }
        }
        return slices.indices.last
    }
}

/// A bar of a whole: a faint track the full width, filled to the share.
/// Even a count of one reads as a bar on its track rather than a dot.
private struct StrongsBarTrack: View {
    let fraction: CGFloat
    let color: Color
    let height: CGFloat

    /// "As expected": a mid grey, clear of its track and quieter than the text.
    static let neutral = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x8E / 255, green: 0x8E / 255, blue: 0x95 / 255, alpha: 1)
            : UIColor(red: 0x76 / 255, green: 0x76 / 255, blue: 0x7C / 255, alpha: 1)
    })

    /// The empty track: plain enough to read as "none", firm enough to see.
    static let track = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3E / 255, alpha: 1)
            : UIColor(red: 0xE8 / 255, green: 0xE8 / 255, blue: 0xED / 255, alpha: 1)
    })

    var body: some View {
        Capsule()
            .fill(Self.track)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    if fraction > 0 {
                        // At least a short bar, never a dot: one occurrence is
                        // still plainly more than none.
                        Capsule()
                            .fill(color)
                            .frame(width: max(height * 2, proxy.size.width * min(fraction, 1)))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// The key's whole spread through the canon at a glance: a column for each
/// book in canonical order, coloured as the book list colours it, over the
/// canon's divisions, with the tallest column's count as the scale and the
/// book that stands out most named over its column.
private struct StrongsCanonStrip: View {
    let books: [LampStrongsAnalysis.Division]
    let color: (LampStrongsAnalysis.Expectation) -> Color

    private static let chartHeight: CGFloat = 84
    private static let labelBand: CGFloat = 18

    private var spacing: CGFloat { books.count > 40 ? 1.5 : 3 }

    /// Runs of neighbouring books in one canon division, in order.
    private var runs: [(name: String, count: Int)] {
        var runs: [(name: String, count: Int)] = []
        for book in books {
            let name = LampStrongsAnalysis.canonSections.first { $0.books.contains(book.id) }?.name ?? ""
            if let last = runs.last, last.name == name {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((name, 1))
            }
        }
        return runs
    }

    /// The book read most above expectation, named on the chart.
    private var standout: (index: Int, book: LampStrongsAnalysis.Division)? {
        books.enumerated()
            .filter { $0.element.expectation == .more }
            .max { $0.element.keyness < $1.element.keyness }
            .map { ($0.offset, $0.element) }
    }

    private func columnWidth(in width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(books.count - 1)) / CGFloat(books.count)
    }

    var body: some View {
        let most = max(books.map(\.occurrenceCount).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let column = columnWidth(in: proxy.size.width)
                let standoutCentre = standout.map { (column + spacing) * CGFloat($0.index) + column / 2 }
                ZStack(alignment: .topLeading) {
                    // The scale: a dotted line at the tallest column, with its
                    // count at the end away from the standout book's name, which
                    // shares its height when that book's column is the tallest.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: Self.labelBand))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: Self.labelBand))
                    }
                    .stroke(LampTheme.rule, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    Text("\(most) times")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LampTheme.caption)
                        .frame(
                            maxWidth: .infinity,
                            alignment: (standoutCentre ?? .infinity) < proxy.size.width / 2 ? .trailing : .leading
                        )
                    // The baseline the columns stand on.
                    Rectangle()
                        .fill(LampTheme.caption.opacity(0.5))
                        .frame(height: 1)
                        .offset(y: Self.labelBand + Self.chartHeight)

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(books) { book in
                            let isEmpty = book.occurrenceCount == 0
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(isEmpty ? LampTheme.rule : color(book.expectation))
                                .frame(height: isEmpty ? 2 : max(6, Self.chartHeight * CGFloat(book.occurrenceCount) / CGFloat(most)))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: Self.chartHeight + Self.labelBand, alignment: .bottom)

                    // A mark under each book read more or less than expected,
                    // so a short column's colour is never lost: one or two
                    // occurrences make a column too low to see its hue.
                    HStack(spacing: spacing) {
                        ForEach(books) { book in
                            Group {
                                if book.expectation == .asExpected {
                                    Color.clear
                                } else {
                                    Image(systemName: book.expectation == .more ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                        .font(.system(size: min(7, max(5, column - 1)), weight: .bold))
                                        .foregroundStyle(color(book.expectation))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 9)
                    .offset(y: Self.labelBand + Self.chartHeight + 4)

                    if let standout, let centre = standoutCentre {
                        let barTop = Self.labelBand + Self.chartHeight
                            - max(4, Self.chartHeight * CGFloat(standout.book.occurrenceCount) / CGFloat(most))
                        Text(standout.book.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color(.more))
                            .fixedSize()
                            .position(
                                x: min(max(centre, 36), proxy.size.width - 36),
                                y: max(barTop - 9, 7)
                            )
                    }
                }
            }
            .frame(height: Self.chartHeight + Self.labelBand + 13)

            // The canon's divisions under their columns.
            GeometryReader { proxy in
                let column = columnWidth(in: proxy.size.width)
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        VStack(spacing: 4) {
                            Capsule()
                                .fill(LampTheme.rule)
                                .frame(height: 2)
                            Text(run.count >= 3 ? run.name : "")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(LampTheme.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(width: column * CGFloat(run.count) + spacing * CGFloat(run.count - 1))
                    }
                }
            }
            .frame(height: 22)

            StrongsExpectationLegend()
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Occurrences by book, \(books.first?.name ?? "") to \(books.last?.name ?? ""); the most in one book, \(most)")
    }
}

/// What the colours of the bars mean, beside the bars themselves.
private struct StrongsExpectationLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item("More than expected", .blue)
            item("Fewer", .orange)
            item("As expected", StrongsBarTrack.neutral)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func item(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).lineLimit(1)
        }
    }
}

// MARK: - Septuagint

/// Where the phone finds what core's `LampSeptuagintSection` works on: the
/// Hebrew a Greek word renders in the Septuagint, the Hebrew text that says
/// where that Hebrew stands, and the Septuagint to read beside it.
///
/// No module is named: the note comes from whichever bundled Greek lexicon
/// carries it (TBESG's reading of Abbott-Smith), the Hebrew text is the
/// translation in Hebrew with Strong's tags, and the Septuagint is the Greek
/// one that numbers its verses the Septuagint's way, as on the Mac.
enum StrongsSeptuagint {
    /// The most verses listed under one Hebrew word, as on the Mac. דָּבָר
    /// stands in over a thousand; the rest are in that word's own analysis.
    static let shownVerses = 25

    /// The Hebrew a Greek key's entries name, in the order the lexicons
    /// print it, without the same word twice.
    static func words(forGreekKey key: String) -> [LampSeptuagintHebrew] {
        guard BundledModuleDatabase.Lexicon.language(ofStrongs: key) == "greek" else { return [] }
        let database = BundledModuleDatabase.shared
        let normalized = LampStrongsKey.normalized(key)
        let keys = normalized == key ? [key] : [key, normalized]
        let entrySenses = database.lexicons()
            .filter { $0.language == "greek" && $0.isKeyedByStrongs }
            .flatMap { lexicon in
                Self.senses(fromJSON: keys.lazy
                    .compactMap { try? database.getDictionaryEntry(moduleId: lexicon.moduleId, key: $0) }
                    .first?.sensesJson)
            }
        return LampSeptuagintSection.words(in: entrySenses)
    }

    /// An entry's senses with their Septuagint notes, read as core reads them:
    /// either spelling of the field, a word with nothing to print skipped, a
    /// padded number ("H07941") normalized. Core's own reader is private to
    /// its library; until it is shared, only the note is read here, since the
    /// phone reads the rest of a sense itself.
    static func senses(fromJSON json: String?) -> [LampDictionarySense] {
        guard let data = json?.data(using: .utf8),
              let senses = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return senses.map { sense in
            let notes = (sense["septuagintHebrew"] ?? sense["septuagint_hebrew"]) as? [[String: Any]] ?? []
            return LampDictionarySense(septuagintHebrew: notes.compactMap { note in
                func field(_ name: String) -> String? {
                    let value = (note[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value?.isEmpty == false ? value : nil
                }
                guard let text = field("text") else { return nil }
                return LampSeptuagintHebrew(
                    text: text,
                    stem: field("stem"),
                    strongs: field("strongs").flatMap(LampStrongsKey.typedKey)
                )
            })
        }
    }

    /// The Hebrew Old Testament, by its language, with tags to count by.
    static func hebrewText(in translations: [TranslationModule]) -> TranslationModule? {
        translations.first {
            ["hbo", "he", "heb", "hebrew"].contains($0.language.lowercased()) && $0.features?.strongs == true
        }
    }

    /// The Septuagint: a Greek text that numbers its verses the Septuagint's
    /// way, as its own versification says, where a name can't be trusted to.
    static func septuagintText(in translations: [TranslationModule]) -> TranslationModule? {
        translations.first {
            ["grc", "el", "ell", "greek"].contains($0.language.lowercased())
                && LampVersification.Scheme(moduleValue: $0.versification) == .septuagint
        }
    }

    /// The Septuagint's Greek for each of `references`, numbered as the Hebrew
    /// text numbers them, where the Septuagint has the verse. Throws if
    /// cancelled part way, since a verse not read would look like one the
    /// text lacks.
    static func greek(
        for references: [Int],
        hebrew: TranslationModule,
        septuagint: TranslationModule
    ) async throws -> [Int: String] {
        let database = TranslationDatabase.shared
        return try await LampSeptuagintSection.greek(
            for: references,
            hebrewNumbering: database.versification(of: hebrew),
            septuagintNumbering: database.versification(of: septuagint)
        ) { book, chapter in
            Dictionary(
                try database.getChapter(translationId: septuagint.id, book: book, chapter: chapter)
                    .verses.map { ($0.verse, $0.text) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
}

/// The Septuagint section's data, in three loads, each paid for only when
/// something asks: the words with the analysis, since without them there is
/// no section; each word's verses in the Hebrew text when the section is
/// opened; and the Greek beside them when a word is.
@MainActor @Observable
final class SeptuagintLoader {
    struct Word: Identifiable {
        let hebrew: LampSeptuagintHebrew
        /// What the Hebrew word means, from the lexicons, for a reader who
        /// doesn't read Hebrew.
        let gloss: String?
        /// The Old Testament verses the word stands in: nil until counted,
        /// and empty for a word with no number to count by.
        var references: [Int]?

        var id: String { "\(hebrew.text)|\(hebrew.strongs ?? "")" }
    }

    struct Verse: Identifiable {
        let reference: Int
        /// The Septuagint's Greek for the verse, where it has that verse.
        let greek: String?

        var id: Int { reference }
    }

    private(set) var words: [Word] = []
    /// The verses listed under a word, by its id, once read.
    private(set) var verses: [String: [Verse]] = [:]
    /// The Greek text's name, for saying which text is missing a verse.
    private(set) var septuagintName: String?

    private var loadedKey: String?
    private var countedKey: String?
    private var reading: Set<String> = []

    func loadWords(key: String) async {
        guard loadedKey != key else { return }
        loadedKey = key
        words = []
        verses = [:]
        countedKey = nil
        let found = await Task.detached(priority: .userInitiated) {
            StrongsSeptuagint.words(forGreekKey: key).map { hebrew in
                Word(hebrew: hebrew, gloss: hebrew.strongs.flatMap { StrongsHeadword.lookUp($0).gloss })
            }
        }.value
        guard loadedKey == key else { return }
        words = found
    }

    /// Where each Hebrew word stands, counted in the Hebrew text itself rather
    /// than in a translation that tags it.
    func loadCounts(key: String) async {
        guard countedKey != key, loadedKey == key, !words.isEmpty else { return }
        countedKey = key
        let hebrew = words.map(\.hebrew)
        let counted = await Task.detached(priority: .userInitiated) { () -> [[Int]] in
            let database = TranslationDatabase.shared
            guard let text = StrongsSeptuagint.hebrewText(in: (try? database.getAllTranslations()) ?? []) else {
                return hebrew.map { _ in [] }
            }
            return hebrew.map { word in
                word.strongs.flatMap { try? database.strongsReferences(translationId: text.id, key: $0) } ?? []
            }
        }.value
        guard countedKey == key, counted.count == words.count else { return }
        for index in words.indices {
            words[index].references = counted[index]
        }
    }

    /// The first of a word's verses, each with the Septuagint's Greek.
    func loadVerses(for word: Word) async {
        guard verses[word.id] == nil, !reading.contains(word.id),
              let references = word.references, !references.isEmpty else { return }
        reading.insert(word.id)
        defer { reading.remove(word.id) }
        let shown = Array(references.prefix(StrongsSeptuagint.shownVerses))
        let reader = Task.detached(priority: .userInitiated) { () throws -> (name: String?, greek: [Int: String]) in
            let translations = (try? TranslationDatabase.shared.getAllTranslations()) ?? []
            guard let hebrew = StrongsSeptuagint.hebrewText(in: translations),
                  let septuagint = StrongsSeptuagint.septuagintText(in: translations)
            else { return (nil, [:]) }
            return (septuagint.name, try await StrongsSeptuagint.greek(for: shown, hebrew: hebrew, septuagint: septuagint))
        }
        // Stopped part way, when the word or the sheet is closed, the verses
        // are dropped rather than kept: one not reached would read as missing
        // from the Greek. Opening the word again reads them afresh.
        guard let read = try? await withTaskCancellationHandler(
            operation: { try await reader.value },
            onCancel: { reader.cancel() }
        ) else { return }
        septuagintName = read.name
        verses[word.id] = shown.map { Verse(reference: $0, greek: read.greek[$0]) }
    }
}

/// A Septuagint verse to open over the analysis, with the Hebrew word's key
/// to mark in the translation being read.
private struct SeptuagintPreview: Identifiable {
    let id: Int
    let key: String
}

/// One Hebrew word's Old Testament verses, each with the Septuagint's Greek,
/// read when it is opened. A verse tapped opens in the translation being
/// read, the Hebrew word's English marked, for a reader without Greek.
private struct SeptuagintWordGroup: View {
    let word: SeptuagintLoader.Word
    /// Every verse the word stands in: the heading's count, even when only
    /// the first few are listed.
    let references: [Int]
    let loader: SeptuagintLoader
    let onPreview: (Int, String) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let listed = loader.verses[word.id] {
                ForEach(listed) { verse in
                    row(verse)
                }
                if references.count > listed.count, let strongs = word.hebrew.strongs {
                    NavigationLink(value: StrongsAnalysisItem(key: strongs)) {
                        Text("All \(references.count) verses in \(strongs)")
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } label: {
            Text(LampSeptuagintSection.heading(word.hebrew, verses: references.count))
                .font(.subheadline.weight(.semibold))
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await loader.loadVerses(for: word)
        }
    }

    private func row(_ verse: SeptuagintLoader.Verse) -> some View {
        Button {
            onPreview(verse.reference, word.hebrew.strongs ?? "")
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(StrongsAnalysisView.referenceTitle(verse.reference, bookNames: [:]))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let greek = verse.greek {
                    Text(greek)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary)
                } else {
                    Text(LampSeptuagintSection.missingVerse(in: loader.septuagintName))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
