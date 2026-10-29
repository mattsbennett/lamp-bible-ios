import SwiftUI
import LampCore

/// A Strong's key to analyse, for a sheet or a pushed page.
struct StrongsAnalysisItem: Identifiable, Hashable {
    let key: String
    var id: String { key }
}

/// How many renderings and companions the analysis lists.
private let strongsAnalysisListed = 8

/// A key's headword and short meaning, from the bundled lexicons: for Greek
/// Dodson's short definition, which is a gloss; for Hebrew Strong's own
/// definition, the shortest the bundle has.
struct StrongsHeadword: Sendable {
    let lemma: String?
    let transliteration: String?
    let gloss: String?

    static func lookUp(_ key: String) -> StrongsHeadword {
        let database = BundledModuleDatabase.shared
        if key.hasPrefix("G") {
            let strongs = try? database.getDictionaryEntry(moduleId: "strongs_greek", key: key)
            let dodson = try? database.getDictionaryEntry(moduleId: "dodson_greek", key: key)
            return StrongsHeadword(
                lemma: strongs?.lemma ?? dodson?.lemma,
                transliteration: strongs?.transliteration,
                gloss: dodson?.senses.first?.shortDefinition?.plainText
                    ?? strongs?.senses.first?.definition?.plainText
            )
        }
        let strongs = try? database.getDictionaryEntry(moduleId: "strongs_hebrew", key: key)
        return StrongsHeadword(
            lemma: strongs?.lemma,
            transliteration: strongs?.transliteration,
            gloss: strongs?.senses.first?.definition?.plainText
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
    @AppStorage("strongs.analysis.bookChartAsRing") private var showsRing = false

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
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: key) { await load() }
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
    }

    private func content(_ analysis: LampStrongsAnalysis) -> some View {
        List {
            Section { summary(analysis) }
            if !analysis.renderings.isEmpty {
                Section {
                    renderings(analysis)
                } header: {
                    Text("Rendered As")
                } footer: {
                    Text("Tap one to filter the verse list below.")
                }
            }
            Section {
                Picker("Chart", selection: $showsRing) {
                    Text("Bars").tag(false)
                    Text("Ring").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                if showsRing {
                    share(analysis)
                } else {
                    books(analysis)
                }
            } header: {
                Text("By Book")
            } footer: {
                Text(showsRing
                    ? "Where its \(analysis.occurrenceCount) occurrences fall, the books holding most first. Tap a book to filter the verse list below."
                    : "↑ more often, ↓ less often than a book of its length would hold, by a margin chance would rarely give. Tap a book to filter the verse list below.")
            }
            if !analysis.companions.isEmpty {
                Section {
                    companions(analysis)
                } header: {
                    Text("Found With")
                } footer: {
                    Text("Most certain first: a word that shares many verses with this one leads one that shares a few, however rare it is.")
                }
            }
            verses(analysis)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Summary

    private var languageName: String {
        key.hasPrefix("H") ? "Hebrew" : key.hasPrefix("G") ? "Greek" : "original-language"
    }

    private func summary(_ analysis: LampStrongsAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headword.lemma ?? analysis.key)
                    .font(.title.weight(.semibold))
                Text(analysis.key)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            if let transliteration = headword.transliteration, !transliteration.isEmpty {
                Text(transliteration)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            if let gloss = headword.gloss, !gloss.isEmpty {
                Text(gloss)
            }
            Text("\(analysis.occurrenceCount) times in \(analysis.verseCount) verses of the \(analysis.translationAbbreviation ?? analysis.translationName)")
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
            Text("\(analysis.ratePerThousandWords, format: .number.precision(.fractionLength(0...2))) per 1,000 tagged \(languageName) words")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Renderings

    private func renderings(_ analysis: LampStrongsAnalysis) -> some View {
        ForEach(analysis.renderings.prefix(strongsAnalysisListed)) { rendering in
            let isSelected = renderingFilter == rendering.id
            Button {
                renderingFilter = isSelected ? nil : rendering.id
                shownVerseCount = 50
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rendering.text.isEmpty ? "(no English word)" : rendering.text)
                            .foregroundStyle(.primary)
                        let variants = rendering.variants
                            .filter { $0.text != rendering.text }
                            .prefix(3)
                            .map(\.text)
                        if !variants.isEmpty {
                            Text(variants.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(rendering.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .opacity(isSelected ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    // MARK: Books

    private func books(_ analysis: LampStrongsAnalysis) -> some View {
        let most = max(analysis.books.map(\.occurrenceCount).max() ?? 1, 1)
        return ForEach(analysis.books) { book in
            let isSelected = bookFilter == book.id
            Button {
                bookFilter = isSelected ? nil : book.id
                shownVerseCount = 50
            } label: {
                HStack(spacing: 8) {
                    Text(book.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .frame(width: 112, alignment: .leading)
                    Capsule()
                        .fill(barColor(book.expectation))
                        .frame(
                            width: book.occurrenceCount > 0
                                ? max(3, 140 * CGFloat(book.occurrenceCount) / CGFloat(most))
                                : 0,
                            height: 10
                        )
                    Spacer(minLength: 0)
                    Text("\(book.occurrenceCount)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: book.expectation == .fewer ? "arrow.down" : "arrow.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(barColor(book.expectation))
                        .opacity(book.expectation == .asExpected ? 0 : 1)
                        .frame(width: 14)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(book.occurrenceCount == 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(book.name), \(book.occurrenceCount) times\(expectationPhrase(book.expectation))")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// Blue against orange, a pair that stays apart for most colour vision,
    /// and not the app's red accent, which beside orange reads as one warm
    /// colour.
    // MARK: Share

    /// The share as core slices it for a deck's ring (`LampPresentationChart`):
    /// the books holding most, the rest gathered as "Others".
    @ViewBuilder
    private func share(_ analysis: LampStrongsAnalysis) -> some View {
        let chart = LampPresentationChart(
            source: .init(strongs: analysis.key, translationID: analysis.translationID),
            by: .book,
            style: .share
        )
        let slices = chart.values(from: analysis)
        let total = slices.reduce(0) { $0 + $1.value }
        let bookIDs = Dictionary(analysis.books.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        StrongsShareRing(slices: slices, total: Int(total)) { index in
            shareColor(index, of: slices)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
            let bookID = bookIDs[slice.label]
            let isSelected = bookID != nil && bookFilter == bookID
            Button {
                guard let bookID else { return }
                bookFilter = isSelected ? nil : bookID
                shownVerseCount = 50
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(shareColor(index, of: slices))
                        .frame(width: 10, height: 10)
                    Text(slice.label)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
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
            .disabled(bookID == nil)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    private func barColor(_ expectation: LampStrongsAnalysis.Expectation) -> Color {
        switch expectation {
        case .more: .blue
        case .fewer: .orange
        case .asExpected: .secondary.opacity(0.5)
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

    private func verseRow(
        _ reference: Int,
        bookNames: [Int: String],
        analysis: LampStrongsAnalysis
    ) -> some View {
        let book = reference / 1_000_000
        let chapter = (reference % 1_000_000) / 1_000
        let verse = reference % 1_000
        return Button {
            onNavigateToVerse?(reference)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(bookNames[book] ?? "Book \(book)") \(chapter):\(verse)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(highlighted(reference, in: analysis))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onNavigateToVerse == nil)
    }

    /// The verse with each of the key's words in it bold and tinted. Offsets
    /// count Characters, as the analysis gives them.
    private func highlighted(_ reference: Int, in analysis: LampStrongsAnalysis) -> AttributedString {
        let text = analysis.verseTexts[reference] ?? ""
        var value = AttributedString(text)
        let length = value.characters.count
        for occurrence in occurrencesByVerse[reference] ?? []
        where occurrence.startOffset >= 0 && occurrence.startOffset < occurrence.endOffset
            && occurrence.endOffset <= length {
            let characters = value.characters
            let start = characters.index(characters.startIndex, offsetBy: occurrence.startOffset)
            let end = characters.index(characters.startIndex, offsetBy: occurrence.endOffset)
            value[start..<end].inlinePresentationIntent = .stronglyEmphasized
            value[start..<end].foregroundColor = Color.accentColor
        }
        return value
    }
}

/// A ring of the whole, largest slice first from twelve o'clock, with the
/// total in its hole: the one number a share otherwise leaves you to add up.
private struct StrongsShareRing: View {
    let slices: [LampPresentationChart.Value]
    let total: Int
    let color: (Int) -> Color

    var body: some View {
        ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let hole = radius * 0.6
                let sum = slices.reduce(0) { $0 + $1.value }
                guard sum > 0 else { return }
                var start = Angle.degrees(-90)
                for (index, slice) in slices.enumerated() {
                    let sweep = Angle.degrees(360 * slice.value / sum)
                    var path = Path()
                    path.addArc(center: centre, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
                    path.addArc(center: centre, radius: hole, startAngle: start + sweep, endAngle: start, clockwise: true)
                    path.closeSubpath()
                    context.fill(path, with: .color(color(index)))
                    // A hairline in the row's own colour, so neighbouring
                    // slices of one hue stay apart.
                    context.stroke(path, with: .color(Color(uiColor: .secondarySystemGroupedBackground)), lineWidth: 1.5)
                    start += sweep
                }
            }
            VStack(spacing: 0) {
                Text("\(total)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("in all")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.label), \(Int($0.value))" }.joined(separator: "; "))
    }
}
