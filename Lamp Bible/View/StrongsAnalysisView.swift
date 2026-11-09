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
/// Strong's. The lemma and gloss are core's, as the Mac names a word: the
/// lemma Strong's gives, else another's, and a lexicon's own gloss (TBESG's,
/// for Greek, which has the Septuagint's extended numbers too), read as its
/// head where it lists senses of one word. Where no lexicon has a gloss, the
/// phone's card still says something, as it always has: Dodson's short
/// definition, which is a gloss, else Strong's own definition, the shortest
/// the bundle has for Hebrew.
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
                    .map { (lexicon: lexicon, entry: $0) }
            }
        let named = LampStrongsHeadword.merging(entries.map { found in
            LampDictionaryResult(
                entryID: found.entry.id,
                moduleID: found.lexicon.moduleId,
                moduleName: found.lexicon.name,
                key: found.entry.key,
                lemma: found.entry.lemma,
                transliteration: found.entry.transliteration,
                pronunciation: found.entry.pronunciation,
                senses: LampDictionarySense.senses(fromJSON: found.entry.sensesJson)
            )
        })[LampStrongsKey.normalized(key)]
        let strongs = entries.first { $0.lexicon.lexiconKey == "strongs" }?.entry
        let dodson = entries.first { $0.lexicon.lexiconKey == "dodson" }?.entry
        return StrongsHeadword(
            lemma: named?.lemma,
            transliteration: named?.transliteration,
            gloss: named?.shortGloss
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
    /// The books a search was narrowed to, which its analysis opens on.
    var bookRange: ClosedRange<Int>? = nil
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
            initialBookRange: bookRange,
            onNavigateToVerse: onNavigateToVerse.map { navigate in
                { verse in
                    dismiss()
                    navigate(verse)
                }
            }
        )
    }
}

/// What the translation's tags say about one Strong's key
/// (`LampStrongsAnalysis`): how often it occurs, the English that renders it,
/// its forms and grammar, where in the canon it gathers, the keys found with
/// it, and how the other translations tag it. The Mac's analysis in the
/// phone's own design: one page under the headword card, each part a section
/// of it, and every figure a way to narrow the verse list at its foot.
struct StrongsAnalysisView: View {
    let key: String
    let translationId: String
    /// The books the analysis opens on, a search's own; the toolbar's menu
    /// chooses others.
    var initialBookRange: ClosedRange<Int>? = nil
    var onNavigateToVerse: ((Int) -> Void)? = nil

    @State private var analysis: LampStrongsAnalysis?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var headword = StrongsHeadword(lemma: nil, transliteration: nil, gloss: nil)
    @State private var companionHeadwords: [String: StrongsHeadword] = [:]
    @State private var occurrencesByVerse: [Int: [LampStrongsAnalysis.Occurrence]] = [:]
    /// What the verse list is narrowed to: a rendering, form, parsing, book
    /// or chapter, chosen from the figure that counts it.
    @State private var filter: LampStrongsFilter?
    @State private var shownVerseCount = 50
    @State private var previewReference: VersePreviewReference?
    /// The books chosen from the toolbar, once chosen; until then, those the
    /// analysis opened on.
    @State private var chosenRange: BookRangeChoice?
    /// The other translations that tag the key, as each is worked out.
    @State private var compared: [LampStrongsAnalysis] = []
    @State private var isComparing = false
    @State private var showsAllRenderings = false
    @State private var showsAllForms = false
    @State private var showsAllCompanions = false
    @State private var septuagint = SeptuagintLoader()
    /// Collapsed to begin with: the Septuagint is a second subject, and
    /// opening it costs a search of the Hebrew text a word.
    @State private var isShowingSeptuagint = false
    @State private var septuagintPreview: SeptuagintPreview?
    @AppStorage("strongs.analysis.spreadGrouping") private var spreadGrouping: LampStrongsSpreadGrouping = .books
    @AppStorage("strongs.analysis.measure") private var measure: LampStrongsSpreadMeasure = .occurrences
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("strongs.analysis.renderingChartAsRing") private var showsRenderingRing = false
    @AppStorage("strongs.analysis.formChartAsRing") private var showsFormRing = false

    private struct BookRangeChoice: Equatable {
        let range: ClosedRange<Int>?
    }

    /// What one load answers: a change of either works it out again.
    private struct LoadRequest: Equatable {
        let key: String
        let bookRange: ClosedRange<Int>?
    }

    private struct Loaded: Sendable {
        let analysis: LampStrongsAnalysis?
        let headword: StrongsHeadword
        let companions: [String: StrongsHeadword]
    }

    private var bookRange: ClosedRange<Int>? { chosenRange.map(\.range) ?? initialBookRange }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Counting \(key)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn’t Analyse \(key)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if let analysis, analysis.occurrenceCount > 0 {
                content(analysis)
            } else {
                ContentUnavailableView(
                    "Not Tagged Here",
                    systemImage: "chart.bar.xaxis",
                    description: Text(bookRange == nil
                        ? "No word in this translation is tagged \(key)."
                        : "No word in \(SearchBookRange.name(of: bookRange)) is tagged \(key) in this translation.")
                )
            }
        }
        // The key is in the headword's pill; the bar says what the page is.
        .navigationTitle("Word Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                bookRangeMenu
            }
        }
        .task(id: LoadRequest(key: key, bookRange: bookRange)) { await load() }
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
        let range = bookRange
        isLoading = true
        loadError = nil
        filter = nil
        shownVerseCount = 50
        compared = []
        isComparing = false
        // A pass over the translation's tagged verses, or its index, and a
        // few lexicon lookups: off the main thread.
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<Loaded, Error> in
            Result {
                let analysis = try TranslationDatabase.shared.analyzeStrongs(
                    key: key, translationId: translationId, bookRange: range
                )
                var companions: [String: StrongsHeadword] = [:]
                for companion in analysis?.companions ?? [] {
                    companions[companion.key] = StrongsHeadword.lookUp(companion.key)
                }
                return Loaded(analysis: analysis, headword: StrongsHeadword.lookUp(key), companions: companions)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch loaded {
        case .success(let loaded):
            analysis = loaded.analysis
            headword = loaded.headword
            companionHeadwords = loaded.companions
            occurrencesByVerse = Dictionary(grouping: loaded.analysis?.occurrences ?? [], by: \.reference)
        case .failure(let error):
            analysis = nil
            loadError = error.localizedDescription
        }
        isLoading = false
        guard loadError == nil else { return }
        await septuagint.loadWords(key: key)
        await loadComparison(key: key, range: range)
    }

    /// The other translations that tag the key, each worked out in turn
    /// behind the first and shown as it arrives: counts only, without the
    /// verses' text, which nothing here reads.
    private func loadComparison(key: String, range: ClosedRange<Int>?) async {
        let current = translationId
        let others = ((try? TranslationDatabase.shared.getAllTranslations()) ?? [])
            .filter { $0.features?.strongs == true && $0.id != current }
            .map(\.id)
        guard !others.isEmpty else { return }
        isComparing = true
        for other in others {
            let found = await Task.detached(priority: .utility) {
                try? TranslationDatabase.shared.analyzeStrongs(
                    key: key, translationId: other, bookRange: range, includingVerseText: false
                )
            }.value
            guard !Task.isCancelled else { return }
            // A translation that tags none of the key's language has
            // nothing to compare.
            if let found, found.wordCount > 0 {
                compared.append(found)
            }
        }
        isComparing = false
    }

    private func content(_ analysis: LampStrongsAnalysis) -> some View {
        List {
            Section {
                summary(analysis)
            } footer: {
                // The rate, outside the card: the card keeps to the figures
                // and the chart.
                Text(rateLine(analysis))
            }
            definitionSection
            if !analysis.renderings.isEmpty {
                renderingsSection(analysis)
            }
            if !analysis.forms.isEmpty {
                formsSection(analysis)
            }
            if !analysis.grammar.isEmpty {
                grammarSection(analysis)
            }
            spreadSection(analysis)
            if !analysis.companions.isEmpty {
                companionsSection(analysis)
            }
            if !compared.isEmpty || isComparing {
                compareSection(analysis)
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

    /// A small heading over a run of rows inside a section.
    private func rowCaption(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(LampTheme.caption)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 2, trailing: 16))
            .accessibilityAddTraits(.isHeader)
    }

    /// Choosing the filter already in force widens it a step, a chapter to
    /// its book, else clears it, so the same tap both narrows and widens.
    private func choose(_ next: LampStrongsFilter?) {
        guard let next else { return }
        filter = filter == next ? next.widened : next
        shownVerseCount = 50
    }

    // MARK: Books in range

    /// The books analysed: every book, a testament, a part of the canon, or
    /// one book, in the key's own testament, as a search narrows its books.
    private var bookRangeMenu: some View {
        let testament = key.hasPrefix("G") ? SearchBookRange.newTestament
            : key.hasPrefix("H") ? SearchBookRange.oldTestament : 1...66
        let parts = LampStrongsAnalysis.canonSections.filter { testament.contains($0.books.lowerBound) }
        return Menu {
            Picker("Books", selection: Binding(
                get: { bookRange },
                set: { chosenRange = BookRangeChoice(range: $0) }
            )) {
                Text(SearchBookRange.name(of: nil)).tag(ClosedRange<Int>?.none)
                if testament != 1...66 {
                    Text(SearchBookRange.name(of: testament)).tag(Optional(testament))
                } else {
                    Text(SearchBookRange.name(of: SearchBookRange.oldTestament)).tag(Optional(SearchBookRange.oldTestament))
                    Text(SearchBookRange.name(of: SearchBookRange.newTestament)).tag(Optional(SearchBookRange.newTestament))
                }
                ForEach(parts, id: \.name) { part in
                    Text(part.name).tag(Optional(part.books))
                }
            }
            Menu("One Book") {
                ForEach(Array(testament), id: \.self) { book in
                    Button {
                        chosenRange = BookRangeChoice(range: book...book)
                    } label: {
                        if bookRange == book...book {
                            Label(BookOsisCache.shared.displayName(for: book), systemImage: "checkmark")
                        } else {
                            Text(BookOsisCache.shared.displayName(for: book))
                        }
                    }
                }
            }
        } label: {
            Label(
                "Books: \(rangeName(bookRange))",
                systemImage: bookRange == nil ? "books.vertical" : "books.vertical.fill"
            )
        }
    }

    /// A range by the name the menu gives it: a part of the canon by its own.
    private func rangeName(_ range: ClosedRange<Int>?) -> String {
        if let range, range.count > 1,
           let part = LampStrongsAnalysis.canonSections.first(where: { $0.books == range }) {
            return part.name
        }
        return SearchBookRange.name(of: range)
    }

    // MARK: Summary

    private var languageName: String {
        key.hasPrefix("H") ? "Hebrew" : key.hasPrefix("G") ? "Greek" : "original-language"
    }

    private func rateLine(_ analysis: LampStrongsAnalysis) -> String {
        let rate = analysis.ratePerThousandWords.formatted(.number.precision(.fractionLength(0...1)))
        let books = bookRange.map { range -> String in
            let name = rangeName(range)
            let takesThe = ["Gospels", "General Letters", "Major Prophets", "Minor Prophets", "Law",
                            "New Testament", "Old Testament"].contains(name)
            return " in \(takesThe ? "the " : "")\(name)"
        } ?? ""
        return "About \(rate) in every 1,000 tagged \(languageName) words of the \(analysis.translationAbbreviation ?? analysis.translationName)\(books)."
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
                    // As the Mac's card has it, and the dictionary's entries.
                    PronounceButton(key: analysis.key, size: 20)
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

    // MARK: Definition

    /// The whole entry, a page of its own: what someone looking a word up
    /// came for, one tap from the figures without pushing them down.
    private var definitionSection: some View {
        Section {
            NavigationLink {
                StrongsDefinitionPage(key: key, translationId: translationId, onNavigateToVerse: onNavigateToVerse)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Definition")
                        Text("The whole entry, in each dictionary that has the word")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "character.book.closed")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    // MARK: Renderings

    private func renderingsSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            Picker("Chart", selection: $showsRenderingRing) {
                Text("List").tag(false)
                Text("Ring").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if showsRenderingRing {
                share(of: LampStrongsGrouping.renderings.divisions(of: analysis))
            } else {
                renderings(analysis)
            }
        } header: {
            sectionHeader("Rendered As")
        } footer: {
            Text(showsRenderingRing
                ? "How its \(analysis.occurrenceCount) occurrences are rendered, the commonest first. Tap one to filter the verse list below."
                : "What translators reached for, not what the word means. Tap one to filter the verse list below.")
        }
    }

    @ViewBuilder
    private func renderings(_ analysis: LampStrongsAnalysis) -> some View {
        let listed = showsAllRenderings
            ? analysis.renderings
            : Array(analysis.renderings.prefix(strongsAnalysisListed))
        countRows(
            listed.map { rendering in
                CountedRow(
                    id: rendering.id,
                    title: rendering.text.isEmpty ? "(no English word)" : rendering.text,
                    detail: rendering.variants
                        .filter { $0.text != rendering.text }
                        .prefix(3)
                        .map(\.text)
                        .joined(separator: ", "),
                    count: rendering.count,
                    filter: .rendering(id: rendering.id, text: rendering.text)
                )
            },
            isOriginalLanguage: false
        )
        if !showsAllRenderings && analysis.renderings.count > strongsAnalysisListed {
            Button("Show All \(analysis.renderings.count) Renderings") {
                showsAllRenderings = true
            }
        }
    }

    // MARK: Forms and grammar

    private func formsSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            Picker("Chart", selection: $showsFormRing) {
                Text("List").tag(false)
                Text("Ring").tag(true)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if showsFormRing {
                share(of: LampStrongsGrouping.forms.divisions(of: analysis), isOriginalLanguage: true)
            } else {
                forms(analysis)
            }
        } header: {
            sectionHeader("Forms")
        } footer: {
            Text(showsFormRing
                ? "How its \(analysis.occurrenceCount) occurrences are spelled, the commonest first. Tap one to filter the verse list below."
                : "Each spelling the word takes where it occurs. Tap one to filter the verse list below.")
        }
    }

    @ViewBuilder
    private func forms(_ analysis: LampStrongsAnalysis) -> some View {
        let listed = showsAllForms ? analysis.forms : Array(analysis.forms.prefix(strongsAnalysisListed))
        countRows(
            listed.map { form in
                CountedRow(id: form.id, title: form.text, detail: "", count: form.count, filter: .form(form.text))
            },
            isOriginalLanguage: true
        )
        if !showsAllForms && analysis.forms.count > strongsAnalysisListed {
            Button("Show All \(analysis.forms.count) Forms") {
                showsAllForms = true
            }
        }
    }

    /// Each feature's values as chips beside their counts, so a parsing reads
    /// at a glance without a bar for every tense and case.
    private func grammarSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            ForEach(LampGrammarFeature.allCases, id: \.self) { feature in
                let values = analysis.grammar.filter { $0.feature == feature }
                if !values.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(feature.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LampTheme.caption)
                            .accessibilityAddTraits(.isHeader)
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(values, id: \.value) { value in
                                filterChip(
                                    value.value,
                                    count: value.count,
                                    filter: .grammar(feature: feature, value: value.value)
                                )
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
                }
            }
        } header: {
            sectionHeader("Grammar")
        } footer: {
            Text("How it is parsed where it occurs. Tap one to filter the verse list below.")
        }
    }

    /// A figure the verse list can be narrowed to: a rendering or a form.
    private struct CountedRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let count: Int
        let filter: LampStrongsFilter
    }

    /// Those used more than once get a row and a bar; those used once share
    /// one row of chips, where a bar each told nothing.
    @ViewBuilder
    private func countRows(_ rows: [CountedRow], isOriginalLanguage: Bool) -> some View {
        let most = max(rows.map(\.count).max() ?? 1, 1)
        let repeated = rows.filter { $0.count > 1 || rows.count <= 3 }
        let once = rows.filter { !($0.count > 1 || rows.count <= 3) }
        ForEach(repeated) { row in
            countRow(row, most: most, isOriginalLanguage: isOriginalLanguage)
        }
        if !once.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Once each")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LampTheme.caption)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(once) { row in
                        filterChip(row.title, count: nil, filter: row.filter, isOriginalLanguage: isOriginalLanguage)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
        }
    }

    private func countRow(_ row: CountedRow, most: Int, isOriginalLanguage: Bool) -> some View {
        let isSelected = filter == row.filter
        return Button {
            choose(row.filter)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(isOriginalLanguage ? .system(.title3, design: .serif) : .body)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        if !row.detail.isEmpty {
                            Text(row.detail)
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
                    Text("\(row.count)")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                }
                StrongsBarTrack(
                    fraction: CGFloat(row.count) / CGFloat(most),
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

    /// A chip that narrows the verses to its figure, its count beside it
    /// where there is one to give.
    private func filterChip(
        _ title: String,
        count: Int?,
        filter chipFilter: LampStrongsFilter,
        isOriginalLanguage: Bool = false
    ) -> some View {
        let isSelected = filter == chipFilter
        return Button {
            choose(chipFilter)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(isOriginalLanguage
                        ? .system(.subheadline, design: .serif).weight(isSelected ? .semibold : .regular)
                        : .subheadline.weight(isSelected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
            }
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
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? "\(title), once")
        .accessibilityHint("Filters the verse list")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Spread

    /// Occurrences unless a rate means something here: the grid shades
    /// chapters and has none to give.
    private var activeMeasure: LampStrongsSpreadMeasure {
        spreadGrouping.usesMeasure ? measure : .occurrences
    }

    private var spreadTitle: String {
        switch spreadGrouping {
        case .books: "By Book"
        case .sections: "By Section"
        case .chapters: "By Chapter"
        }
    }

    /// Where the word occurs, and nothing else: renderings and forms have
    /// their own sections above. Books and sections are bars, chapters the
    /// grid, so how it is drawn follows from what it is grouped by.
    private func spreadSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            spreadMenus
            if let grouping = spreadGrouping.bars {
                spreadBars(analysis, grouping: grouping)
            } else {
                chapterGrid(analysis)
            }
        } header: {
            sectionHeader(spreadTitle)
        } footer: {
            Text(spreadFootnote)
        }
    }

    /// What to group by and what to count, as menus that state the choice in
    /// a word: segmented bars would outweigh the chart.
    private var spreadMenus: some View {
        HStack(spacing: 20) {
            Menu {
                Picker("Group By", selection: $spreadGrouping) {
                    ForEach(LampStrongsSpreadGrouping.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                menuLabel("By \(spreadGrouping.title)")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            if spreadGrouping.usesMeasure {
                Menu {
                    Picker("Measure", selection: $measure) {
                        ForEach(LampStrongsSpreadMeasure.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    menuLabel(measure.title)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
        }
        .font(.subheadline.weight(.medium))
    }

    private var spreadFootnote: String {
        guard spreadGrouping.usesMeasure else {
            return "A square for each chapter, darker where the word is commoner. Tap one to filter the verse list below."
        }
        let share = activeMeasure == .occurrences ? " Beside each count, its share of them all." : ""
        return "Expected is the share a part of its length would hold. ↑ More and ↓ fewer mark a gap too wide to be chance.\(share) Tap one to filter the verse list below."
    }

    /// The figure a bar is drawn to: a count, or a rate to two places.
    private func measureLabel(_ bar: LampStrongsSpreadBar) -> String {
        guard bar.occurrenceCount > 0 else { return "–" }
        switch activeMeasure {
        case .occurrences: return "\(bar.occurrenceCount)"
        case .perThousandWords: return bar.value.formatted(.number.precision(.fractionLength(2)))
        }
    }

    @ViewBuilder
    private func spreadBars(_ analysis: LampStrongsAnalysis, grouping: LampStrongsGrouping) -> some View {
        let entries = grouping.divisions(of: analysis)
        let bars = LampStrongsSpread.bars(entries.map(\.division), measure: activeMeasure)
        if grouping == .books {
            let barsByBook = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                    if let bar = barsByBook[book.id] {
                        barRow(bar, filter: .book(number: book.id), nameWidth: 112)
                        if openBook == book.id, !book.chapters.isEmpty {
                            chapterStrip(book)
                        }
                    }
                }
            }
        } else {
            ForEach(Array(zip(entries, bars)), id: \.0.id) { entry, bar in
                barRow(bar, filter: entry.filter, nameWidth: 132)
            }
        }
    }

    /// The book whose chapters show beneath it: the one the list is narrowed
    /// to, or whose chapter it is narrowed to.
    private var openBook: Int? {
        switch filter {
        case .book(let number): number
        case .chapter(let book, _): book
        default: nil
        }
    }

    private func barRow(_ bar: LampStrongsSpreadBar, filter barFilter: LampStrongsFilter?, nameWidth: CGFloat) -> some View {
        let isSelected = barFilter != nil && (filter == barFilter || {
            if case .book(let book) = barFilter, case .chapter(book, _) = filter { return true }
            return false
        }())
        let isEmpty = bar.occurrenceCount == 0
        return Button {
            // A part without the word has no verses to filter to, and a
            // section names several books, which no one filter says.
            guard !isEmpty else { return }
            choose(barFilter)
        } label: {
            HStack(spacing: 10) {
                Text(bar.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .frame(width: nameWidth, alignment: .leading)
                StrongsBarTrack(
                    fraction: CGFloat(bar.share),
                    color: barColor(bar.expectation),
                    height: 10
                )
                Text(measureLabel(bar))
                    .font(.subheadline.weight(isEmpty ? .regular : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                    .frame(minWidth: 24, alignment: .trailing)
                // Its share of every occurrence, which was all a ring of the
                // same figures said; a part without the word leaves it blank.
                if activeMeasure == .occurrences {
                    Text(isEmpty ? "" : LampStrongsSpread.percent(bar.fractionOfOccurrences))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                Image(systemName: bar.expectation == .fewer ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(barColor(bar.expectation))
                    .opacity(bar.expectation == .asExpected ? 0 : 1)
                    .frame(width: 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Not disabled, which would fade the row past reading: a zero is
        // a finding too.
        .allowsHitTesting(!isEmpty && barFilter != nil)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bar.name), \(bar.occurrenceCount) times\(isEmpty ? "" : ", \(LampStrongsSpread.percent(bar.fractionOfOccurrences))")\(expectationPhrase(bar.expectation))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The chosen book's chapters as short columns, each a way to narrow the
    /// verses to that chapter. Tapping the chosen one goes back to the book.
    private func chapterStrip(_ book: LampStrongsAnalysis.Division) -> some View {
        let most = max(book.chapters.map(\.occurrenceCount).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Chapters of \(book.name)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LampTheme.caption)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(book.chapters) { chapter in
                        let chapterFilter = LampStrongsFilter.chapter(book: book.id, number: chapter.number)
                        let isChosen = filter == chapterFilter
                        let isEmpty = chapter.occurrenceCount == 0
                        VStack(spacing: 3) {
                            Capsule()
                                .fill(isChosen ? Color.accentColor : isEmpty ? StrongsBarTrack.track : StrongsBarTrack.neutral)
                                .frame(width: 10, height: isEmpty ? 3 : max(5, 44 * CGFloat(chapter.occurrenceCount) / CGFloat(most)))
                            Text("\(chapter.number)")
                                .font(.caption2.weight(isChosen ? .bold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(isChosen ? Color.accentColor : LampTheme.caption)
                        }
                        .frame(minWidth: 20, minHeight: 62, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isEmpty { choose(chapterFilter) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Chapter \(chapter.number), \(chapter.occurrenceCount) times")
                        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
        .listRowSeparator(.hidden, edges: .top)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))
    }

    /// Every chapter of each book holding the word, shaded against the
    /// busiest chapter anywhere, so one occurrence never looks like many.
    @ViewBuilder
    private func chapterGrid(_ analysis: LampStrongsAnalysis) -> some View {
        ForEach(LampStrongsGrid.rows(from: analysis.books)) { row in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name)
                        .font(.subheadline.weight(openBook == row.id ? .semibold : .regular))
                        .foregroundStyle(openBook == row.id ? Color.accentColor : Color.primary)
                    Spacer(minLength: 8)
                    Text("\(row.occurrenceCount)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                FlowLayout(spacing: 3, lineSpacing: 3) {
                    ForEach(row.cells) { cell in
                        let cellFilter = LampStrongsFilter.chapter(book: row.id, number: cell.number)
                        let isChosen = filter == cellFilter
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(cell.occurrenceCount == 0
                                ? StrongsBarTrack.track
                                : Color.accentColor.opacity(0.25 + 0.75 * cell.intensity))
                            .frame(width: 15, height: 15)
                            .overlay {
                                if isChosen {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.primary, lineWidth: 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if cell.occurrenceCount > 0 { choose(cellFilter) }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(row.name) \(cell.number), \(cell.occurrenceCount) times")
                            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
        }
    }

    // MARK: Share

    /// Each part's share as core slices it, the largest six and the rest as
    /// "Other", each named slice a way to filter the verses.
    @ViewBuilder
    private func share(of entries: [LampStrongsChartDivision], isOriginalLanguage: Bool = false) -> some View {
        let slices = LampStrongsShare.slices(from: entries.map(\.division))
        let filters = Dictionary(
            entries.map { (String($0.division.id), $0.filter) },
            uniquingKeysWith: { first, _ in first }
        )
        let total = slices.reduce(0) { $0 + $1.value }
        StrongsShareRing(slices: slices, total: total) { index in
            shareColor(index, of: slices)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        // "Other" names nothing to filter by, so its row is no button.
        ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
            let sliceFilter = slice.isOther ? nil : filters[slice.id] ?? nil
            let isSelected = sliceFilter != nil && filter == sliceFilter
            Button {
                choose(sliceFilter)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(shareColor(index, of: slices))
                        .frame(width: 10, height: 10)
                    // A form in the serif its list sets it in; "Other"
                    // is English, whatever the slices name.
                    Text(slice.name)
                        .font(isOriginalLanguage && !slice.isOther
                            ? .system(.body, design: .serif).weight(isSelected ? .semibold : .regular)
                            : .subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(slice.value)")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text(LampStrongsSpread.percent(slice.fraction))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sliceFilter == nil)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// One hue, deepest for the largest slice; the gathered rest faintest,
    /// being a remainder rather than a finding.
    private func shareColor(_ index: Int, of slices: [LampStrongsShare.Slice]) -> Color {
        guard slices.indices.contains(index), !slices[index].isOther else { return Color.accentColor.opacity(0.2) }
        let named = slices.filter { !$0.isOther }.count
        guard named > 1 else { return .accentColor }
        return Color.accentColor.opacity(1 - 0.6 * Double(index) / Double(named - 1))
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

    // MARK: Companions

    private func companionsSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            // In the order given, by how certain each association is. Sorted
            // by how many times chance it is instead, a pairing from two
            // verses would lead.
            let listed = showsAllCompanions
                ? analysis.companions
                : Array(analysis.companions.prefix(strongsAnalysisListed))
            ForEach(listed) { companion in
                companionRow(companion)
            }
            if !showsAllCompanions && analysis.companions.count > strongsAnalysisListed {
                Button("Show All \(analysis.companions.count) Words") {
                    showsAllCompanions = true
                }
            }
        } header: {
            sectionHeader("Found With")
        } footer: {
            Text("Strongest association first, which is not the largest multiple: a high multiple over a few shared verses says less than a smaller one over many.")
        }
    }

    private func companionRow(_ companion: LampStrongsAnalysis.Companion) -> some View {
        let companionHeadword = companionHeadwords[companion.key]
        return NavigationLink(value: StrongsAnalysisItem(key: companion.key)) {
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
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(companion.lift.formatted(.number.precision(.fractionLength(1))))× chance")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("\(companion.sharedVerseCount) of its \(companion.verseCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("\(companion.sharedVerseCount) of its \(companion.verseCount) verses are shared with this word")
    }

    // MARK: Compare

    private func compareSection(_ analysis: LampStrongsAnalysis) -> some View {
        Section {
            ForEach(
                LampStrongsAnalysisOrder.ordered([analysis] + compared, activeTranslationID: translationId),
                id: \.translationID
            ) { other in
                compareRow(other, isRead: other.translationID == translationId)
            }
            if isComparing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Counting the other translations…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            sectionHeader("Compare")
        } footer: {
            Text("Counts depend on how each translation was tagged, so they don’t all measure the same thing.")
        }
    }

    private func compareRow(_ other: LampStrongsAnalysis, isRead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(other.translationAbbreviation ?? other.translationName)
                    .font(.headline)
                if isRead {
                    Text("Reading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // A translation can tag the language and still leave this
                // word untagged: the WEB leaves out "love" in John 13:35.
                Text(other.occurrenceCount == 0
                    ? "None tagged"
                    : "\(other.occurrenceCount) in \(other.verseCount) \(other.verseCount == 1 ? "verse" : "verses")")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            let renderings = other.renderings.prefix(3)
                .map { "\($0.text.isEmpty ? "—" : $0.text) (\($0.count))" }
                .joined(separator: ", ")
            if !renderings.isEmpty {
                Text(renderings)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Septuagint

    /// For a Greek word the lexicon gives Hebrew for, and collapsed: the
    /// Hebrew it renders in the Septuagint, each word followable to its own
    /// analysis where it has a number, then each one's Old Testament verses
    /// in the English being read, with the Septuagint's Greek under them.
    /// Nothing here is counted above. Said for a reader with no Hebrew: each
    /// word by its transliteration and the English it is rendered by.
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
                        SeptuagintWordGroup(
                            word: word,
                            references: references,
                            translationId: translationId,
                            loader: septuagint
                        ) { reference, key in
                            septuagintPreview = SeptuagintPreview(id: reference, key: key)
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // Marks either side of each separator keep the words in
                    // the lexicon's order left to right, rather than letting
                    // the Hebrew run them right to left as one phrase.
                    Text("\u{200E}" + septuagint.words
                        .map { LampSeptuagintSection.word($0.hebrew) }
                        .joined(separator: "\u{200E}  ·  \u{200E}"))
                        .font(.title3)
                        .lineLimit(1)
                    let said = septuagint.words.compactMap(\.transliteration).filter { !$0.isEmpty }
                    if !said.isEmpty {
                        Text(said.joined(separator: "  ·  "))
                            .font(.subheadline.italic())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .task(id: isShowingSeptuagint) {
                guard isShowingSeptuagint else { return }
                await septuagint.loadCounts(key: key, translationId: translationId)
            }
        } header: {
            sectionHeader(LampSeptuagintSection.title)
        } footer: {
            Text(LampSeptuagintSection.note(greek: headword.lemma))
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

    /// The Hebrew with its number, and under it the word as someone with no
    /// Hebrew reads it: its transliteration and the English the translation
    /// being read renders it by, else the lexicons' meaning.
    private func hebrewWord(_ word: SeptuagintLoader.Word, number: String?) -> some View {
        let rendering = septuagint.renderings[word.id]
        let transliteration = word.transliteration.flatMap { $0.isEmpty ? nil : $0 }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LampSeptuagintSection.word(word.hebrew))
                    .font(.title3)
                if let number {
                    Text(number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if transliteration != nil || rendering != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let transliteration {
                        Text(transliteration)
                            .italic()
                    }
                    if let rendering {
                        Text("“\(rendering)”")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if rendering == nil, let gloss = word.gloss, !gloss.isEmpty {
                Text(gloss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Verses

    /// The verses holding an occurrence the filter leaves, in order.
    private func filteredReferences(_ analysis: LampStrongsAnalysis) -> [Int] {
        guard let filter else { return analysis.references }
        let matching = Set(analysis.occurrences(matching: filter).map(\.reference))
        return analysis.references.filter(matching.contains)
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
                Text(versesTitle(references.count))
                Spacer()
                if filter != nil {
                    Button("Show All") {
                        filter = nil
                        shownVerseCount = 50
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }
    }

    /// "12 Verses · rendered “love”": what a tap above did, said where its
    /// effect is.
    private func versesTitle(_ count: Int) -> String {
        let title = count == 1 ? "1 Verse" : "\(count) Verses"
        return filter.map { "\(title) · \($0.narrowing)" } ?? title
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

/// A key's whole entry from one dictionary at a time, as the Mac's analysis
/// has it: the dictionaries with an entry for the key, in the order the
/// reader set for its language and without those hidden, the first of them
/// to begin with, and a menu to read another. The one chosen is kept across
/// words, so someone reading one lexicon keeps reading it.
private struct StrongsDefinitionPage: View {
    let key: String
    let translationId: String
    var onNavigateToVerse: ((Int) -> Void)? = nil

    @AppStorage("strongs.analysis.definitionLexicon") private var chosenLexicon = ""
    @State private var entries: [LexiconEntry]?

    /// The dictionaries with an entry, each once, in the reader's order.
    private var lexicons: [(key: String, name: String)] {
        var seen = Set<String>()
        return (entries ?? []).compactMap { entry in
            seen.insert(entry.lexiconKey).inserted ? (entry.lexiconKey, entry.lexiconName) : nil
        }
    }

    private var shownLexicon: String? {
        LampStrongsDefinitionChoice.shown(
            among: lexicons.map(\.key),
            chosen: chosenLexicon.isEmpty ? nil : chosenLexicon,
            preferred: nil
        )
    }

    var body: some View {
        Group {
            if let entries {
                if let shownLexicon {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(entries.filter { $0.lexiconKey == shownLexicon }) { entry in
                                LexiconEntryView(
                                    entry: entry,
                                    senses: entry.parsedSenses,
                                    translationId: translationId,
                                    onNavigateToVerse: onNavigateToVerse,
                                    baseFontSize: CGFloat(UserDatabase.shared.getSettings().readerFontSize) * 0.92
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                } else {
                    ContentUnavailableView(
                        "Not in Any Dictionary",
                        systemImage: "character.book.closed",
                        description: Text("No dictionary on this iPhone has an entry for \(key).")
                    )
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Definition")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if lexicons.count > 1, let shownLexicon {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Dictionary", selection: Binding(
                            get: { shownLexicon },
                            set: { chosenLexicon = $0 }
                        )) {
                            ForEach(lexicons, id: \.key) { lexicon in
                                Text(lexicon.name).tag(lexicon.key)
                            }
                        }
                    } label: {
                        Label("Dictionary", systemImage: "character.book.closed")
                    }
                }
            }
        }
        .task(id: key) {
            let key = key
            entries = await Task.detached(priority: .userInitiated) {
                StrongsDefinitionPage.entries(for: key)
            }.value
        }
    }

    /// Every entry for the key, in the order the reader set for its
    /// language, without the dictionaries the reader hid.
    nonisolated static func entries(for key: String) -> [LexiconEntry] {
        let settings = UserDatabase.shared.getSettings()
        let isHebrew = key.hasPrefix("H")
        let hidden = Set(LampModuleSelection.identifiers(
            in: isHebrew ? settings.hiddenHebrewLexicons : settings.hiddenGreekLexicons
        ))
        return LexiconLookup.sortedEntries(
            for: key,
            orderString: isHebrew ? settings.hebrewLexiconOrder : settings.greekLexiconOrder
        )
        .filter { !hidden.contains($0.lexiconKey) }
    }
}

/// A ring of the whole, largest slice first from twelve o'clock, with the
/// total in its hole: the one number a share otherwise leaves you to add up.
/// A slice tapped is read out in the hole, its name, count and share, and
/// the rest fade: shades of one hue are hard to match to their rows by eye.
/// Tapping it again, or the hole, goes back to the total.
private struct StrongsShareRing: View {
    let slices: [LampStrongsShare.Slice]
    let total: Int
    let color: (Int) -> Color

    @State private var selected: Int?

    private static let size: CGFloat = 140
    private static let holeRatio: CGFloat = 0.6

    var body: some View {
        ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let hole = radius * Self.holeRatio
                var start = Angle.degrees(-90)
                for (index, slice) in slices.enumerated() {
                    let sweep = Angle.degrees(360 * slice.fraction)
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
                let tapped = LampStrongsShareHit.index(
                    at: location,
                    in: CGSize(width: Self.size, height: Self.size),
                    fractions: slices.map(\.fraction),
                    thickness: Double(1 - Self.holeRatio)
                )
                withAnimation(.easeOut(duration: 0.15)) {
                    selected = tapped == selected ? nil : tapped
                }
            }
            readout
                .frame(width: Self.size * Self.holeRatio - 8)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size, height: Self.size)
        .onChange(of: slices.map(\.id)) { selected = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slices.map { "\($0.name), \($0.value)" }.joined(separator: "; "))
    }

    @ViewBuilder
    private var readout: some View {
        if let selected, slices.indices.contains(selected) {
            let slice = slices[selected]
            VStack(spacing: 0) {
                Text(slice.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                Text("\(slice.value)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(LampStrongsSpread.percent(slice.fraction))
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
                LampDictionarySense.senses(fromJSON: keys.lazy
                    .compactMap { try? database.getDictionaryEntry(moduleId: lexicon.moduleId, key: $0) }
                    .first?.sensesJson)
            }
        return LampSeptuagintSection.words(in: entrySenses)
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
/// no section; each word's verses in the Hebrew text, and what the
/// translation being read renders it by, when the section is opened; and the
/// verses in that translation's English with the Greek under them when a
/// word is.
@MainActor @Observable
final class SeptuagintLoader {
    struct Word: Identifiable {
        let hebrew: LampSeptuagintHebrew
        /// How to say it, for a reader who doesn't read Hebrew.
        let transliteration: String?
        /// What it means, from the lexicons, where the translation being read
        /// gives no rendering of its own.
        let gloss: String?
        /// The Old Testament verses the word stands in: nil until counted,
        /// and empty for a word with no number to count by.
        var references: [Int]?

        var id: String { "\(hebrew.text)|\(hebrew.strongs ?? "")" }
    }

    struct Verse: Identifiable {
        /// In the Hebrew text's numbering.
        let reference: Int
        /// The verse in the translation being read: its number there, and
        /// the verse with the word marked where its own tag puts it, or no
        /// text where it doesn't tag the word here, rather than a guess at a
        /// likely word. Nil where it has no such verse.
        let english: LampSeptuagintSection.English?
        /// The Septuagint's Greek for the verse, where it has that verse.
        let greek: String?

        var id: Int { reference }
    }

    /// What opening a word gives: its verses with the Greek beside them, or
    /// why there is no Greek to give. Said apart from a verse the Greek text
    /// hasn't got, since that is a claim about the text.
    enum Listing {
        case rows([Verse])
        case withoutSeptuagint
        /// A text couldn't be read: the one named, where it is known.
        case unreadable(String?)
    }

    /// What reading a word's English and Greek came to.
    private enum Outcome: Sendable {
        case read(septuagint: String, english: [Int: LampSeptuagintSection.English], greek: [Int: String])
        case withoutSeptuagint
        case unreadable(String?)
        /// Stopped part way, when the word or the sheet was closed.
        case cutShort
    }

    private(set) var words: [Word] = []
    /// What the translation being read most often renders each word by, by
    /// its id: the English a reader with no Hebrew goes by.
    private(set) var renderings: [String: String] = [:]
    /// What is listed under a word, by its id, once read.
    private(set) var verses: [String: Listing] = [:]
    /// The Greek text's name, for saying which text is missing a verse.
    private(set) var septuagintName: String?

    private var loadedKey: String?
    private var countedKey: String?
    private var reading: Set<String> = []

    func loadWords(key: String) async {
        guard loadedKey != key else { return }
        loadedKey = key
        words = []
        renderings = [:]
        verses = [:]
        countedKey = nil
        let found = await Task.detached(priority: .userInitiated) {
            StrongsSeptuagint.words(forGreekKey: key).map { hebrew in
                let headword = hebrew.strongs.map(StrongsHeadword.lookUp)
                return Word(hebrew: hebrew, transliteration: headword?.transliteration, gloss: headword?.gloss)
            }
        }.value
        guard loadedKey == key else { return }
        words = found
    }

    /// Where each Hebrew word stands, counted in the Hebrew text itself rather
    /// than in a translation that tags it, and what the translation being
    /// read most often renders it by. A rendering missed only leaves the
    /// word's heading in Hebrew, so it isn't tried again.
    func loadCounts(key: String, translationId: String) async {
        guard countedKey != key, loadedKey == key, !words.isEmpty else { return }
        countedKey = key
        let hebrew = words.map(\.hebrew)
        let counted = await Task.detached(priority: .userInitiated) { () -> [(references: [Int], rendering: String?)] in
            let database = TranslationDatabase.shared
            guard let text = StrongsSeptuagint.hebrewText(in: (try? database.getAllTranslations()) ?? []) else {
                return hebrew.map { _ in ([], nil) }
            }
            return hebrew.map { word in
                guard let strongs = word.strongs else { return ([], nil) }
                // Reading the Hebrew text itself, its "rendering" would be
                // the Hebrew again.
                let english = translationId == text.id ? nil
                    : (try? database.analyzeStrongs(key: strongs, translationId: translationId, includingVerseText: false))
                return (
                    (try? database.strongsReferences(translationId: text.id, key: strongs)) ?? [],
                    english.flatMap(LampSeptuagintSection.rendering(in:))
                )
            }
        }.value
        guard countedKey == key, counted.count == words.count else { return }
        for index in words.indices {
            words[index].references = counted[index].references
            if let rendering = counted[index].rendering {
                renderings[words[index].id] = rendering
            }
        }
    }

    /// The first of a word's verses, each in the English of the translation
    /// being read, the word marked where that translation tags it, and with
    /// the Septuagint's Greek.
    func loadVerses(for word: Word, translationId: String) async {
        // A read that failed is worth trying again when the word is opened
        // again. The other outcomes are settled.
        if case .unreadable = verses[word.id] { verses[word.id] = nil }
        guard verses[word.id] == nil, !reading.contains(word.id),
              let references = word.references, !references.isEmpty else { return }
        reading.insert(word.id)
        defer { reading.remove(word.id) }
        let shown = Array(references.prefix(StrongsSeptuagint.shownVerses))
        let strongs = word.hebrew.strongs
        let reader = Task.detached(priority: .userInitiated) { () -> Outcome in
            let database = TranslationDatabase.shared
            let translations: [TranslationModule]
            do {
                translations = try database.getAllTranslations()
            } catch {
                return .unreadable(nil)
            }
            guard let septuagint = StrongsSeptuagint.septuagintText(in: translations) else {
                return .withoutSeptuagint
            }
            guard let hebrew = StrongsSeptuagint.hebrewText(in: translations) else {
                return .unreadable(septuagint.name)
            }
            // The English first, from the translation being read. A verse it
            // doesn't tag the word in keeps its number and no text, never a
            // guess at the word.
            var english: [Int: LampSeptuagintSection.English] = [:]
            if let strongs, translationId != hebrew.id,
               let reading = translations.first(where: { $0.id == translationId }) {
                do {
                    if let analysis = try database.analyzeStrongs(key: strongs, translationId: translationId) {
                        english = LampSeptuagintSection.english(
                            for: shown,
                            hebrewNumbering: database.versification(of: hebrew),
                            englishNumbering: database.versification(of: reading),
                            analysis: analysis
                        )
                    }
                } catch {
                    return Task.isCancelled ? .cutShort : .unreadable(reading.name)
                }
                if Task.isCancelled { return .cutShort }
            }
            do {
                return .read(
                    septuagint: septuagint.name,
                    english: english,
                    greek: try await StrongsSeptuagint.greek(for: shown, hebrew: hebrew, septuagint: septuagint)
                )
            } catch {
                return error is CancellationError || Task.isCancelled
                    ? .cutShort : .unreadable(septuagint.name)
            }
        }
        let outcome = await withTaskCancellationHandler(
            operation: { await reader.value },
            onCancel: { reader.cancel() }
        )
        switch outcome {
        case .read(let name, let english, let greek):
            septuagintName = name
            verses[word.id] = .rows(shown.map { Verse(reference: $0, english: english[$0], greek: greek[$0]) })
        case .withoutSeptuagint:
            verses[word.id] = .withoutSeptuagint
        case .unreadable(let name):
            verses[word.id] = .unreadable(name)
        case .cutShort:
            // Dropped rather than kept: a verse not reached would read as
            // missing from the Greek, or as untagged in the English. Opening
            // the word again reads them afresh.
            break
        }
    }
}

/// A Septuagint verse to open over the analysis, with the Hebrew word's key
/// to mark in the translation being read.
private struct SeptuagintPreview: Identifiable {
    let id: Int
    let key: String
}

/// One Hebrew word's Old Testament verses, each in the English of the
/// translation being read with the word marked, and the Septuagint's Greek
/// under it, read when it is opened. A verse tapped opens in that
/// translation, the Hebrew word's English marked.
private struct SeptuagintWordGroup: View {
    let word: SeptuagintLoader.Word
    /// Every verse the word stands in: the heading's count, even when only
    /// the first few are listed.
    let references: [Int]
    /// The translation whose English the verses are shown in.
    let translationId: String
    let loader: SeptuagintLoader
    let onPreview: (Int, String) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            switch loader.verses[word.id] {
            case .rows(let listed):
                ForEach(listed) { verse in
                    row(verse)
                }
                allVerses(beyond: listed.count)
            case .withoutSeptuagint:
                note(LampSeptuagintSection.withoutSeptuagint)
                allVerses(beyond: 0)
            case .unreadable(let name):
                note(LampSeptuagintSection.unreadable(name))
                allVerses(beyond: 0)
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } label: {
            Text(LampSeptuagintSection.heading(
                word.hebrew,
                transliteration: word.transliteration,
                rendering: loader.renderings[word.id],
                verses: references.count
            ))
            .font(.subheadline.weight(.semibold))
        }
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await loader.loadVerses(for: word, translationId: translationId)
        }
    }

    /// The word's own analysis, for its verses past the ones listed.
    @ViewBuilder
    private func allVerses(beyond listed: Int) -> some View {
        if references.count > listed, let strongs = word.hebrew.strongs {
            NavigationLink(value: StrongsAnalysisItem(key: strongs)) {
                Text("All \(references.count) verses in \(strongs)")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// The verse in English with the word marked, and the Greek under it.
    /// The reference is the English one where the English is read: the
    /// number a reader of it looks the verse up by, and opens it at.
    private func row(_ verse: SeptuagintLoader.Verse) -> some View {
        let reference = verse.english?.reference ?? verse.reference
        return Button {
            onPreview(reference, word.hebrew.strongs ?? "")
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(StrongsAnalysisView.referenceTitle(reference, bookNames: [:]))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let snippet = verse.english?.snippet {
                    SearchResultRow.snippetText(fromMarked: Self.marked(snippet), limit: 160)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                if let greek = verse.greek {
                    Text(greek)
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(.secondary)
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

    /// The snippet with its word in `<mark>`, as the verse list marks a find.
    private static func marked(_ snippet: LampStrongsContext.Snippet) -> String {
        (snippet.isTrimmedAtStart ? "…" : "") + snippet.before
            + "<mark>" + snippet.word + "</mark>"
            + snippet.after + (snippet.isTrimmedAtEnd ? "…" : "")
    }
}
