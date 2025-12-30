//
//  ReaderView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-29.
//

import Foundation
import RealmSwift
import SwiftUI
import UIKit

// MARK: - Verse Position Tracker

class VersePositionTracker: ObservableObject {
    // Use non-published property to avoid "Publishing changes from within view updates" warning
    // while still allowing synchronous access
    private var _positions: [Int: CGFloat] = [:]
    private let lock = NSLock()

    var positions: [Int: CGFloat] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _positions
        }
        set {
            lock.lock()
            _positions = newValue
            lock.unlock()
        }
    }

    func verseAtOffset(_ offset: CGFloat, verses: [Verse]) -> Int? {
        let currentPositions = positions
        guard !currentPositions.isEmpty else { return nil }

        var result: Int? = nil
        // Iterate through verses in order to find the one at this offset
        for verse in verses {
            if let yPos = currentPositions[verse.id] {
                if yPos <= offset + 50 {
                    result = verse.id
                } else {
                    break
                }
            }
        }
        return result
    }
}

// MARK: - Chapter Text View

struct ChapterTextView: UIViewRepresentable {
    let verses: [Verse]
    let crossRefVerseIds: Set<Int>
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let bookName: String
    let chapter: Int
    let showBookTitle: Bool
    let notesEnabled: Bool
    let showStrongsHints: Bool
    let onAddNote: (Verse) -> Void
    let onShowCrossRefs: (Verse) -> Void
    let onShowStrongs: (AnnotatedWord) -> Void
    var onSearchText: ((String) -> Void)?
    @Binding var scrollToVerseId: Int?
    let positionTracker: VersePositionTracker
    let onScrollToPosition: ((CGFloat) -> Void)?
    let onPositionsCalculated: (([Int: CGFloat]) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        // Use TextKit 1 explicitly for layoutManager access
        let textContainer = NSTextContainer()
        let layoutManager = NSLayoutManager()
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = UITextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 15, bottom: 20, right: 15)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.delegate = context.coordinator

        // Add tap gesture for verse numbers - configure to not interfere with selection
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        textView.addGestureRecognizer(tapGesture)

        // Create edit menu interaction upfront to avoid "_UIReparentingView" warning
        let editMenuInteraction = UIEditMenuInteraction(delegate: context.coordinator)
        textView.addInteraction(editMenuInteraction)
        context.coordinator.editMenuInteraction = editMenuInteraction

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Update parent reference (struct may have been recreated)
        context.coordinator.parent = self

        // Only rebuild if content actually changed
        let currentKey = context.coordinator.buildKey()
        if context.coordinator.lastBuildKey != currentKey {
            context.coordinator.lastBuildKey = currentKey
            let attributedString = buildAttributedString(coordinator: context.coordinator)
            textView.attributedText = attributedString
            textView.invalidateIntrinsicContentSize()
        }

        // Note: Scroll-to-verse is handled by onChange(of: versePositions) in ReaderView
        // This ensures scrolling happens after positions are calculated
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }

        // Update parent reference
        context.coordinator.parent = self

        // Ensure text container knows about the width for proper layout
        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }

        // Force layout to ensure glyph positions are calculated
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)

        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))

        // Calculate verse positions for local use (verseYPositions in coordinator)
        // This is used directly for scroll-to-verse
        context.coordinator.calculateVersePositionsLocal()

        // Update positionTracker synchronously - the lock handles thread safety
        // and we removed @Published to avoid "Publishing changes from within view updates"
        context.coordinator.updatePositionTracker()

        return CGSize(width: width, height: size.height)
    }

    private func buildAttributedString(coordinator: Coordinator) -> NSAttributedString {
        let result = NSMutableAttributedString()
        coordinator.verseRanges.removeAll()
        coordinator.verseNumberRanges.removeAll()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineHeightMultiple = 1.2

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]

        let headerParagraphStyle = NSMutableParagraphStyle()
        headerParagraphStyle.alignment = .center
        headerParagraphStyle.paragraphSpacingBefore = 20
        headerParagraphStyle.paragraphSpacing = 20

        let bookTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 28),
            .paragraphStyle: headerParagraphStyle,
            .foregroundColor: UIColor.label
        ]

        let chapterTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 20),
            .paragraphStyle: headerParagraphStyle,
            .foregroundColor: UIColor.label
        ]

        // Add book title if this is chapter 1
        if showBookTitle && chapter == 1 {
            let bookTitle = NSAttributedString(string: "\(bookName)\n", attributes: bookTitleAttributes)
            result.append(bookTitle)
        }

        // Add chapter title
        let chapterTitle = NSAttributedString(string: "\(bookName) \(chapter)\n", attributes: chapterTitleAttributes)
        result.append(chapterTitle)

        // Add verses
        for (index, verse) in verses.enumerated() {
            let verseStart = result.length

            // Verse number (superscript style)
            let hasCrossRefs = crossRefVerseIds.contains(verse.id)
            let verseNumberAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.75),
                .foregroundColor: hasCrossRefs ? UIColor.tintColor : UIColor.secondaryLabel,
                .baselineOffset: fontSize * 0.3,
                .paragraphStyle: paragraphStyle,
                .verseId: verse.id
            ]

            let verseNumberStart = result.length
            let verseNumber = NSAttributedString(string: "\(verse.v) ", attributes: verseNumberAttributes)
            result.append(verseNumber)
            coordinator.verseNumberRanges[verse.id] = NSRange(location: verseNumberStart, length: verseNumber.length)

            // Verse text - check for Strong's annotations
            if hasStrongsAnnotations(verse.t) {
                let annotatedWords = parseAnnotatedVerse(verse.t)
                for word in annotatedWords {
                    if word.isAnnotated {
                        // Annotated word - add optional underline hint and tap target
                        var strongsAttributes = textAttributes
                        strongsAttributes[.strongsWord] = word

                        if showStrongsHints {
                            // Dotted underline for annotated words
                            strongsAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                            strongsAttributes[.underlineColor] = UIColor.secondaryLabel.withAlphaComponent(0.4)
                        }

                        let wordText = NSAttributedString(string: word.text, attributes: strongsAttributes)
                        result.append(wordText)
                    } else {
                        // Plain text (punctuation, spaces, etc.)
                        let plainText = NSAttributedString(string: word.text, attributes: textAttributes)
                        result.append(plainText)
                    }
                }
            } else {
                // No annotations - render plain text
                let verseText = NSAttributedString(string: verse.t, attributes: textAttributes)
                result.append(verseText)
            }

            // Store verse range for scrolling
            coordinator.verseRanges[verse.id] = NSRange(location: verseStart, length: result.length - verseStart)

            // Add space between verses (or newline for last verse)
            if index < verses.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: textAttributes))
            }
        }

        return result
    }

    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var parent: ChapterTextView
        weak var textView: UITextView?
        var verseRanges: [Int: NSRange] = [:]
        var verseNumberRanges: [Int: NSRange] = [:]
        var verseYPositions: [Int: CGFloat] = [:]
        var lastBuildKey: String = ""

        init(_ parent: ChapterTextView) {
            self.parent = parent
        }

        func buildKey() -> String {
            // Create a key that uniquely identifies the content
            let verseIds = parent.verses.map { $0.id }.description
            return "\(verseIds)-\(parent.fontSize)-\(parent.chapter)-\(parent.showStrongsHints)"
        }

        func calculateVersePositionsLocal() {
            guard let textView = textView else { return }
            guard textView.textContainer.size.width > 0 else { return }
            guard !verseRanges.isEmpty else { return }

            verseYPositions.removeAll()

            for (verseId, range) in verseRanges {
                let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                verseYPositions[verseId] = rect.origin.y + textView.textContainerInset.top
            }
        }

        func updatePositionTracker() {
            guard !verseYPositions.isEmpty else { return }

            // The positions are relative to the text view's content
            var adjustedPositions: [Int: CGFloat] = [:]
            for (verseId, yPos) in verseYPositions {
                adjustedPositions[verseId] = yPos
            }
            // Update the position tracker (synchronous, thread-safe)
            parent.positionTracker.positions = adjustedPositions
            // Notify via callback asynchronously to avoid "Modifying state during view update" warning
            let callback = parent.onPositionsCalculated
            DispatchQueue.main.async {
                callback?(adjustedPositions)
            }
        }

        func hasPositions() -> Bool {
            return !verseYPositions.isEmpty
        }

        func calculateVersePositions() {
            calculateVersePositionsLocal()
            // Update synchronously - VersePositionTracker no longer uses @Published
            updatePositionTracker()
        }

        // MARK: - Tap Gesture

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let textView = textView else { return }

            // Skip if text is selected (user was doing long-press selection)
            if textView.selectedRange.length > 0 {
                return
            }

            let point = gesture.location(in: textView)
            let adjustedPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )

            let characterIndex = textView.layoutManager.characterIndex(
                for: adjustedPoint,
                in: textView.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            guard characterIndex < textView.attributedText.length else { return }

            let attributes = textView.attributedText.attributes(at: characterIndex, effectiveRange: nil)

            // Check if tapped on a Strong's annotated word
            if let annotatedWord = attributes[.strongsWord] as? AnnotatedWord {
                parent.onShowStrongs(annotatedWord)
                return
            }

            // Check if tapped on a verse number
            if let verseId = attributes[.verseId] as? Int {
                if let verse = parent.verses.first(where: { $0.id == verseId }) {
                    // Only show menu if there's something to show
                    let hasCrossRefs = parent.crossRefVerseIds.contains(verseId)
                    guard parent.notesEnabled || hasCrossRefs else { return }

                    // Get the verse number's actual rect from layout
                    if let verseRange = verseNumberRanges[verseId] {
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: verseRange, actualCharacterRange: nil)
                        var rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                        // Adjust for text container inset
                        rect.origin.x += textView.textContainerInset.left
                        rect.origin.y += textView.textContainerInset.top

                        // Show menu at the verse location
                        showVerseMenu(for: verse, hasCrossRefs: hasCrossRefs, at: rect, in: textView)
                    }
                }
            }
        }

        private func showVerseMenu(for verse: Verse, hasCrossRefs: Bool, at rect: CGRect, in textView: UITextView) {
            // Store for the delegate callback
            currentVerse = verse
            currentVerseHasCrossRefs = hasCrossRefs

            // Use UIEditMenuInteraction to show menu at the verse location
            let menuConfig = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY))
            editMenuInteraction?.presentEditMenu(with: menuConfig)
        }

        // Store state for menu presentation
        var editMenuInteraction: UIEditMenuInteraction?
        var currentVerse: Verse?
        var currentVerseHasCrossRefs: Bool = false

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Don't recognize tap simultaneously with long press
            if otherGestureRecognizer is UILongPressGestureRecognizer {
                return false
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Tap should wait for long press to fail
            if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UILongPressGestureRecognizer {
                return true
            }
            return false
        }

        // MARK: - UIEditMenuInteractionDelegate

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let verse = currentVerse else { return nil }

            var actions: [UIAction] = []

            if parent.notesEnabled {
                actions.append(UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                    self?.parent.onAddNote(verse)
                })
            }

            if currentVerseHasCrossRefs {
                actions.append(UIAction(title: "Cross References", image: UIImage(systemName: "arrow.triangle.branch")) { [weak self] _ in
                    self?.parent.onShowCrossRefs(verse)
                })
            }

            return UIMenu(children: actions)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            // Return the rect where the menu should point to
            if let verse = currentVerse,
               let verseId = verse.thaw()?.id,
               let range = verseNumberRanges[verseId],
               let textView = textView {
                let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                rect.origin.x += textView.textContainerInset.left
                rect.origin.y += textView.textContainerInset.top
                // Shrink rect to approximate the superscript verse number position
                // The superscript is in the upper portion of the line
                rect.size.height = rect.size.height * 0.75
                return rect
            }
            return CGRect(origin: configuration.sourcePoint, size: CGSize(width: 1, height: 1))
        }

        // MARK: - UITextViewDelegate (Text Selection Menu)

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let onSearch = parent.onSearchText else {
                return UIMenu(children: suggestedActions)
            }

            let selectedText = (textView.text as NSString).substring(with: range)

            let searchAction = UIAction(title: "Search", image: UIImage(systemName: "magnifyingglass")) { _ in
                onSearch(selectedText)
            }

            // Insert Search near the beginning (after first action, which is typically Copy)
            var actions = suggestedActions
            let insertIndex = min(1, actions.count)
            actions.insert(searchAction, at: insertIndex)

            return UIMenu(children: actions)
        }
    }
}

// Custom attribute keys for verse IDs and Strong's annotations
extension NSAttributedString.Key {
    static let verseId = NSAttributedString.Key("verseId")
    static let strongsWord = NSAttributedString.Key("strongsWord")  // Stores AnnotatedWord
}


private struct ScrollInfo: Equatable {
    let offset: CGFloat
    let topInset: CGFloat
}

// Lightweight scroll debouncer that avoids Task creation overhead
private class ScrollDebouncer {
    private var workItem: DispatchWorkItem?

    func debounce(delay: TimeInterval, action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedRealmObject var user: User
    @Binding var date: Date
    @State private var readingMetaData: [ReadingMetaData]? = nil
    @State private var currentReadingIndex: Int = 0
    @State private var isLoading: Bool = false
    @State private var showingBookPicker: Bool = false
    @State private var showingCrossReferenceSheet: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @State private var showingSearch: Bool = false
    @State private var bottomSearchText: String = ""
    @State private var crossReferenceVerse: Verse? = nil
    @State private var verses: Results<Verse>
    @State private var initialScrollItem: String? = nil
    @State private var translation: Translation
    @SceneStorage("readerCurrentVerseId") var currentVerseId: Int = 1001001
    @Binding var visibleVerseId: Int
    private let scrollDebouncer = ScrollDebouncer()
    @Binding var requestScrollToVerseId: Int?
    @Binding var requestScrollAnimated: Bool
    @State private var internalScrollToVerseId: Int? = nil
    @State private var scrollTargetY: CGFloat? = nil
    @State private var animateScroll: Bool = true
    @StateObject private var positionTracker = VersePositionTracker()
    @State private var pendingScrollVerseId: Int? = nil  // Tracks verse to scroll to after positions update
    @State private var isProgrammaticScroll: Bool = false  // Ignore scroll detection during programmatic scrolls
    @State private var selectedStrongsWord: AnnotatedWord? = nil  // For Strong's popover
    @AppStorage("showStrongsHints") private var showStrongsHints: Bool = false
    @State private var toolbarsHidden: Bool = false  // Hide/show toolbars on tap

    let LOADING_NEXT_CHAPTER = "next_chapter"
    let LOADING_PREV_CHAPTER = "prev_chapter"
    let LOADING_NEXT_BOOK = "next_book"
    let LOADING_PREV_BOOK = "prev_book"
    let LOADING_CURRENT = "current"
    let LOADING_TRANSLATION = "translation"
    let LOADING_READING = "reading"
    let LOADING_HISTORY = "history"

    @State private var isHistoryNavigation: Bool = false

    var onVerseAction: ((Int, VerseAction) -> Void)?

    init(
        user: User,
        date: Binding<Date>,
        readingMetaData: [ReadingMetaData]? = nil,
        translation: Translation = RealmManager.shared.realm.objects(User.self).first!.readerTranslation!,
        verses: Results<Verse> = RealmManager.shared.realm.objects(Verse.self).filter("id == -1"),
        onVerseAction: ((Int, VerseAction) -> Void)? = nil,
        requestScrollToVerseId: Binding<Int?> = .constant(nil),
        requestScrollAnimated: Binding<Bool> = .constant(true),
        visibleVerseId: Binding<Int> = .constant(1001001)
    ) {
        self.user = user
        _date = date
        _readingMetaData = State(initialValue: readingMetaData)
        _translation = State(initialValue: translation)
        _verses = State(initialValue: verses)
        _visibleVerseId = visibleVerseId
        self.onVerseAction = onVerseAction
        _requestScrollToVerseId = requestScrollToVerseId
        _requestScrollAnimated = requestScrollAnimated
    }

    private var crossRefVerseIds: Set<Int> {
        guard !verses.isEmpty else { return [] }
        let verseIds = Array(verses.map { $0.id })
        let crossRefs = RealmManager.shared.realm.objects(CrossReference.self)
            .filter("id IN %@", verseIds)
        return Set(crossRefs.map { $0.id })
    }

    private var bookName: String {
        guard let firstVerse = verses.first else { return "" }
        return RealmManager.shared.realm.objects(Book.self)
            .filter("id == \(firstVerse.b)").first?.name ?? ""
    }

    private var chapterNumber: Int {
        verses.first?.c ?? 1
    }

    private var showBookTitle: Bool {
        verses.first?.c == 1
    }

    @ViewBuilder
    private var bookPickerSheet: some View {
        BookListView(
            currentVerseId: $currentVerseId,
            showingBookPicker: $showingBookPicker,
            translation: $translation
        ) {
            loadVerses(loadingCase: LOADING_CURRENT)
        }
    }

    @ViewBuilder
    private var crossReferenceSheet: some View {
        CrossReferenceListView(
            translation: $translation,
            crossReferenceVerse: $crossReferenceVerse,
            showingCrossReferenceSheet: $showingCrossReferenceSheet
        )
    }

    @ViewBuilder
    private var searchSheet: some View {
        SearchView(
            isPresented: $showingSearch,
            translation: translation,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            initialSearchText: bottomSearchText,
            fontSize: Int(user.readerFontSize)
        )
    }

    @ViewBuilder
    private var collapsedHeader: some View {
        let currentVerse = RealmManager.shared.realm.objects(Verse.self).filter("id == \(currentVerseId)").first
        let book = currentVerse.flatMap { RealmManager.shared.realm.objects(Book.self).filter("id == \($0.b)").first }

        VStack(spacing: 0) {
            Text("\(translation.abbreviation) · \(book?.name ?? "") \(currentVerse?.c ?? 0)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(UIColor.systemBackground).ignoresSafeArea(edges: .top))

            // Gradient fade below the text
            LinearGradient(
                colors: [Color(UIColor.systemBackground), Color(UIColor.systemBackground).opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 30)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                toolbarsHidden = false
            }
        }
    }

    func loadVerses(loadingCase: String, targetVerseId: Int? = nil) {
        let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)

        // Save current scroll position to history before navigating away
        // (skip for reading plan and history navigation)
        if !isHistoryNavigation && loadingCase != LOADING_READING {
            NavigationHistory.shared.updateCurrentPosition(to: currentVerseId)
        }

        // Clear positions and scroll target when loading new verses
        positionTracker.positions = [:]
        scrollTargetY = nil

        switch loadingCase {
            case LOADING_PREV_CHAPTER:
                verses = getPrevChapterVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_NEXT_CHAPTER:
                verses = getNextChapterVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_PREV_BOOK:
                verses = getPrevBookVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_NEXT_BOOK:
                verses = getNextBookVerses(verseId: currentVerseId, verses: translation.verses)
            case LOADING_READING:
                verses = translation.verses.filter("id >= \(readingMetaData![currentReadingIndex].sv) && id <= \(readingMetaData![currentReadingIndex].ev)")
            case LOADING_HISTORY:
                if let targetId = targetVerseId {
                    let (_, targetChapter, targetBook) = splitVerseId(targetId)
                    verses = translation.verses.filter("b == \(targetBook) && c == \(targetChapter)")
                }
            case LOADING_CURRENT:
                fallthrough
            case LOADING_TRANSLATION:
                verses = translation.verses.filter("b == \(currentBook) && c == \(currentChapter)")
            default: break
        }

        // For history navigation, use the target verse (preserving scroll position)
        // Otherwise use the first verse of the new chapter
        if loadingCase == LOADING_HISTORY, let targetId = targetVerseId {
            currentVerseId = targetId
            // animateScroll is set by caller (onChange handler)
            pendingScrollVerseId = targetId

            // Scroll after layout completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                if let yPos = positionTracker.positions[targetId] {
                    pendingScrollVerseId = nil
                    scrollTargetY = max(0, yPos + 1 - 20)
                }
            }
        } else {
            currentVerseId = verses.first!.id
            pendingScrollVerseId = nil
        }

        // Record navigation in history (skip for reading plan and history navigation)
        if !isHistoryNavigation && loadingCase != LOADING_READING {
            NavigationHistory.shared.recordNavigation(to: currentVerseId, isHistoryNavigation: false)
        }

        isLoading = true
        isHistoryNavigation = false
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id("top")

                            ChapterTextView(
                                verses: Array(verses),
                                crossRefVerseIds: crossRefVerseIds,
                                fontSize: CGFloat(user.readerFontSize),
                                lineSpacing: 12,
                                bookName: bookName,
                                chapter: chapterNumber,
                                showBookTitle: showBookTitle,
                                notesEnabled: user.notesEnabled,
                                showStrongsHints: showStrongsHints,
                                onAddNote: { verse in
                                    onVerseAction?(verse.v, .addNote)
                                },
                                onShowCrossRefs: { verse in
                                    crossReferenceVerse = verse
                                    showingCrossReferenceSheet = true
                                },
                                onShowStrongs: { annotatedWord in
                                    selectedStrongsWord = annotatedWord
                                },
                                onSearchText: { text in
                                    bottomSearchText = text
                                    showingSearch = true
                                },
                                scrollToVerseId: $internalScrollToVerseId,
                                positionTracker: positionTracker,
                                onScrollToPosition: { yPosition in
                                    scrollTargetY = yPosition
                                },
                                onPositionsCalculated: nil
                            )
                            .id("chapter_\(chapterNumber)")
                        }
                        // Hidden scroll target - VStack positions the anchor at targetY
                        if let targetY = scrollTargetY {
                            VStack(spacing: 0) {
                                Color.clear
                                    .frame(height: targetY)
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id("scrollTarget")
                            }
                        }
                    }
                }
                .onScrollGeometryChange(for: ScrollInfo.self) { geometry in
                    ScrollInfo(offset: geometry.contentOffset.y, topInset: geometry.contentInsets.top)
                } action: { [self] _, newValue in
                    // Skip scroll detection entirely during programmatic scrolls
                    guard !isProgrammaticScroll else { return }

                    // Capture values for the debounced closure
                    let offset = newValue.offset
                    let topInset = newValue.topInset

                    // Use lightweight debouncer instead of Task to avoid overhead
                    scrollDebouncer.debounce(delay: 0.5) { [self] in
                        // Double-check flag in case it changed during debounce delay
                        guard !isProgrammaticScroll else { return }

                        let versesArray = Array(verses)
                        guard !versesArray.isEmpty else { return }

                        let adjustedOffset = max(0, offset + topInset)
                        var foundVerseId: Int? = nil
                        let positions = positionTracker.positions

                        if !positions.isEmpty {
                            for verse in versesArray {
                                if let yPos = positions[verse.id] {
                                    if yPos >= adjustedOffset {
                                        foundVerseId = verse.id
                                        break
                                    }
                                }
                            }
                            if foundVerseId == nil {
                                foundVerseId = versesArray.last?.id
                            }
                        }

                        if foundVerseId == nil {
                            foundVerseId = versesArray.first?.id
                        }

                        if let verseId = foundVerseId, verseId != currentVerseId {
                            currentVerseId = verseId
                            visibleVerseId = verseId
                            // Update history position as user scrolls
                            NavigationHistory.shared.updateCurrentPosition(to: verseId)
                        }
                    }
                }
                .onChange(of: initialScrollItem) {
                    guard initialScrollItem != nil else { return }
                    isProgrammaticScroll = true
                    scrollDebouncer.cancel()
                    proxy.scrollTo(initialScrollItem, anchor: UnitPoint(x: 0.5, y: 0.01))
                    // Reset flag after scroll settles
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isProgrammaticScroll = false
                    }
                }
                .onChange(of: isLoading) {
                    if isLoading {
                        // Block scroll detection during chapter load
                        isProgrammaticScroll = true
                        scrollDebouncer.cancel()
                        // Always scroll to top first to reset position
                        // The pending scroll will reposition after layout completes
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
                                    return
                                }
                                thawedUser.addCompletedReading(id: readingId)
                            }
                        }
                    }
                }
                .onChange(of: requestScrollToVerseId) {
                    if let verseId = requestScrollToVerseId {
                        let (_, targetChapter, targetBook) = splitVerseId(verseId)
                        let (_, currentCh, currentBk) = splitVerseId(currentVerseId)
                        // Use the requested animation setting
                        animateScroll = requestScrollAnimated
                        // Check if target is in a different chapter
                        if targetBook != currentBk || targetChapter != currentCh {
                            // Load the new chapter
                            loadVerses(loadingCase: LOADING_HISTORY, targetVerseId: verseId)
                        } else {
                            // Same chapter, just scroll
                            if let yPos = positionTracker.positions[verseId] {
                                scrollTargetY = max(0, yPos + 1 - 20)
                            }
                        }
                        requestScrollToVerseId = nil
                    }
                }
                .onChange(of: scrollTargetY) {
                    if scrollTargetY != nil {
                        // Block scroll detection during programmatic scroll
                        isProgrammaticScroll = true
                        scrollDebouncer.cancel()

                        // Small delay for anchor view to render
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            if animateScroll {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    proxy.scrollTo("scrollTarget", anchor: .top)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    scrollTargetY = nil
                                    isProgrammaticScroll = false
                                }
                            } else {
                                proxy.scrollTo("scrollTarget", anchor: .top)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    scrollTargetY = nil
                                    animateScroll = true
                                    isProgrammaticScroll = false
                                }
                            }
                        }
                    }
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
                    showingSearch: $showingSearch,
                    searchText: $bottomSearchText,
                    loadPrev: {
                        loadVerses(loadingCase: LOADING_PREV_CHAPTER)
                    },
                    loadNext: {
                        loadVerses(loadingCase: LOADING_NEXT_CHAPTER)
                    },
                    loadPrevBook: {
                        loadVerses(loadingCase: LOADING_PREV_BOOK)
                    },
                    loadNextBook: {
                        loadVerses(loadingCase: LOADING_NEXT_BOOK)
                    },
                    navigateToVerseId: { verseId in
                        isHistoryNavigation = true
                        animateScroll = false  // No animation for history navigation
                        loadVerses(loadingCase: LOADING_HISTORY, targetVerseId: verseId)
                    }
                )
            }
            .toolbar {
                ReaderNavigationToolbarView(
                    user: user,
                    readingMetaData: $readingMetaData,
                    translation: $translation,
                    currentVerseId: $currentVerseId,
                    showingBookPicker: $showingBookPicker,
                    showingOptionsMenu: $showingOptionsMenu,
                    readerDismiss: dismiss,
                    onHideToolbars: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toolbarsHidden = true
                        }
                    }
                )
            }
            .sheet(isPresented: $showingBookPicker) {
                bookPickerSheet
            }
            .sheet(isPresented: $showingCrossReferenceSheet) {
                crossReferenceSheet
            }
            .sheet(isPresented: $showingSearch, onDismiss: {
                bottomSearchText = ""
            }) {
                searchSheet
            }
            .sheet(item: $selectedStrongsWord) { word in
                LexiconSheetView(
                    word: word.text,
                    strongs: word.strongs,
                    morphology: word.morphology,
                    translation: translation,
                    onNavigateToVerse: { verseId in
                        requestScrollAnimated = false
                        requestScrollToVerseId = verseId
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .toolbar(toolbarsHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(toolbarsHidden)
            .safeAreaInset(edge: .top) {
                if toolbarsHidden {
                    collapsedHeader
                }
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
                                return
                            }
                            thawedUser.addCompletedReading(id: readingId)
                        }
                    }
                }
            } else {
                loadVerses(loadingCase: LOADING_CURRENT)
                // Always scroll to top since headers are now part of ChapterTextView
                initialScrollItem = "top"
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

