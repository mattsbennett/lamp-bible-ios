//
//  ReaderView.swift
//  Lamp Bible
//
//  Created by Matthew Bennett on 2023-12-29.
//

import Foundation
import SwiftUI
import UIKit
import GRDB

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

    func verseAtOffset(_ offset: CGFloat, verses: [TranslationVerse]) -> Int? {
        let currentPositions = positions
        guard !currentPositions.isEmpty else { return nil }

        var result: Int? = nil
        // Iterate through verses in order to find the one at this offset
        for verse in verses {
            if let yPos = currentPositions[verse.ref] {
                if yPos <= offset + 50 {
                    result = verse.ref
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
    let verses: [TranslationVerse]
    let headings: [TranslationHeading]
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let bookName: String
    let chapter: Int
    let showBookTitle: Bool
    let showStrongsHints: Bool
    let onAddNote: (TranslationVerse) -> Void
    let onShowStrongs: (AnnotatedWord) -> Void
    var onSearchText: ((String) -> Void)?
    @Binding var scrollToVerseId: Int?
    let positionTracker: VersePositionTracker
    let onScrollToPosition: ((CGFloat) -> Void)?
    let onPositionsCalculated: (([Int: CGFloat]) -> Void)?
    // True while scrolling (drag OR deceleration)
    let isUserScrolling: Bool

    // Debug/perf toggle: render as simplified plain text to isolate TextKit/interaction overhead.
    // Enable by setting: UserDefaults.standard.set(true, forKey: "readerSimplifiedText")
    private var isSimplifiedText: Bool {
        UserDefaults.standard.bool(forKey: "readerSimplifiedText")
    }

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
        textView.isSelectable = !isSimplifiedText
        textView.isScrollEnabled = false
        // Big scrolling text: keep it opaque to avoid expensive blending/compositing while scrolling.
        textView.backgroundColor = UIColor.systemBackground
        textView.isOpaque = true
        textView.textContainerInset = UIEdgeInsets(top: 0, left: 15, bottom: 20, right: 15)
        // Performance optimization: Draw on background thread
        textView.layer.drawsAsynchronously = true
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        if !isSimplifiedText {
            textView.delegate = context.coordinator

            // Add tap gesture for verse numbers - configure to not interfere with selection
            let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
            tapGesture.delegate = context.coordinator
            textView.addGestureRecognizer(tapGesture)

            // Create edit menu interaction upfront to avoid "_UIReparentingView" warning
            let editMenuInteraction = UIEditMenuInteraction(delegate: context.coordinator)
            textView.addInteraction(editMenuInteraction)
            context.coordinator.editMenuInteraction = editMenuInteraction
        } else {
            // Extra simplification: avoid text interactions entirely.
            textView.delegate = nil
            textView.isUserInteractionEnabled = false
        }

        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // Update parent reference (struct may have been recreated)
        context.coordinator.parent = self

        // Only rebuild if content actually changed
        let currentKey = context.coordinator.buildKey()
        let effectiveKey = isSimplifiedText ? (currentKey + "-simplified") : currentKey
        if context.coordinator.lastBuildKey != effectiveKey {
            context.coordinator.lastBuildKey = effectiveKey

            if isSimplifiedText {
                textView.attributedText = buildSimplifiedAttributedString()
            } else {
                let attributedString = buildAttributedString(coordinator: context.coordinator)
                textView.attributedText = attributedString
            }

            textView.invalidateIntrinsicContentSize()

            // Content changed; positions need recalculation (but not during sizeThatFits).
            if !isSimplifiedText {
                context.coordinator.markVersePositionsDirty()
            }
        }

        // Note: Scroll-to-verse is handled by onChange(of: versePositions) in ReaderView
        // This ensures scrolling happens after positions are calculated

        // While scrolling, disable UITextView interactions entirely to reduce overhead.
        if !isSimplifiedText {
            let allowInteraction = !isUserScrolling
            if textView.isUserInteractionEnabled != allowInteraction {
                textView.isUserInteractionEnabled = allowInteraction
            }
            if textView.isSelectable != allowInteraction {
                textView.isSelectable = allowInteraction
                if !allowInteraction {
                    textView.selectedRange = NSRange(location: 0, length: 0)
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }

        // Update parent reference
        context.coordinator.parent = self

        // Return cached size if width hasn't changed (avoids expensive recalc during scroll)
        if let cached = context.coordinator.cachedSize, context.coordinator.cachedWidth == width {
            return cached
        }

        // Ensure text container knows about the width for proper layout
        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)

            // Width change affects glyph positions.
            if !isSimplifiedText {
                context.coordinator.markVersePositionsDirty()
            }
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))

        // Cache the calculated size
        context.coordinator.cachedSize = size
        context.coordinator.cachedWidth = width

        // Verse positions are needed for scroll-to-verse and scroll sync, but calculating them
        // in sizeThatFits can be called repeatedly during scrolling and is expensive.
        // Coalesce to once per content/width change.
        if !isSimplifiedText {
            context.coordinator.scheduleVersePositionCalculation(containerWidth: containerWidth)
        }

        return CGSize(width: width, height: size.height)
    }

    private func buildSimplifiedAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineHeightMultiple = 1.2

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]

        // Keep headings minimal and consistent.
        if showBookTitle && chapter == 1 {
            result.append(NSAttributedString(string: "\(bookName)\n", attributes: textAttributes))
        }
        result.append(NSAttributedString(string: "\(bookName) \(chapter)\n", attributes: textAttributes))

        for (index, verse) in verses.enumerated() {
            result.append(NSAttributedString(string: "\(verse.verse) ", attributes: textAttributes))
            result.append(NSAttributedString(string: verse.text, attributes: textAttributes))
            if index < verses.count - 1 {
                result.append(NSAttributedString(string: " ", attributes: textAttributes))
            }
        }

        return result
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

        // Section heading styles
        let sectionHeadingParagraphStyle = NSMutableParagraphStyle()
        sectionHeadingParagraphStyle.paragraphSpacingBefore = lineSpacing * 1.5
        sectionHeadingParagraphStyle.paragraphSpacing = lineSpacing * 0.5

        let sectionHeadingAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .paragraphStyle: sectionHeadingParagraphStyle,
            .foregroundColor: UIColor.secondaryLabel
        ]

        // Build heading lookup by full verse reference (book*1000000 + chapter*1000 + verse)
        var headingsByRef: [Int: [TranslationHeading]] = [:]
        for heading in headings {
            let ref = heading.book * 1000000 + heading.chapter * 1000 + heading.beforeVerse
            headingsByRef[ref, default: []].append(heading)
        }

        // Chapter title style for mid-content chapter headings (multi-chapter readings)
        let midChapterTitleParagraphStyle = NSMutableParagraphStyle()
        midChapterTitleParagraphStyle.paragraphSpacingBefore = lineSpacing * 2.5
        midChapterTitleParagraphStyle.paragraphSpacing = lineSpacing * 0.5
        midChapterTitleParagraphStyle.alignment = .center

        let midChapterTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize * 1.1, weight: .semibold),
            .paragraphStyle: midChapterTitleParagraphStyle,
            .foregroundColor: UIColor.secondaryLabel
        ]

        // Track current chapter for multi-chapter readings
        var currentChapter: Int? = nil

        // Add verses
        for (index, verse) in verses.enumerated() {
            // Detect chapter change and insert chapter heading
            if verse.chapter != currentChapter {
                // Only show chapter heading if not the first verse (first chapter title is shown separately)
                // or if this is a verse range that starts mid-chapter
                if currentChapter != nil || (index == 0 && verse.verse > 1) {
                    // Get book name for this chapter
                    let chapterBookName = (try? BundledModuleDatabase.shared.getBook(id: verse.book))?.name ?? bookName
                    let midChapterTitle = NSAttributedString(string: "\(chapterBookName) \(verse.chapter)\n", attributes: midChapterTitleAttributes)
                    result.append(midChapterTitle)
                }
                currentChapter = verse.chapter
            }

            // Render any section headings before this verse
            let verseRef = verse.book * 1000000 + verse.chapter * 1000 + verse.verse
            if let verseHeadings = headingsByRef[verseRef] {
                for heading in verseHeadings {
                    let headingText = NSAttributedString(string: "\(heading.text)\n", attributes: sectionHeadingAttributes)
                    result.append(headingText)
                }
            }
            // Handle poetry stanza break (adds extra vertical space)
            if let poetry = verse.poetry, poetry.stanzaBreak == true {
                let stanzaBreakStyle = NSMutableParagraphStyle()
                stanzaBreakStyle.paragraphSpacingBefore = lineSpacing * 1.5
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: stanzaBreakStyle]))
            }
            // Handle paragraph break (adds extra vertical space before verse)
            else if verse.paragraph && index > 0 {
                let paragraphBreakStyle = NSMutableParagraphStyle()
                paragraphBreakStyle.paragraphSpacingBefore = lineSpacing
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraphBreakStyle]))
            }

            let verseStart = result.length

            // Poetry indentation
            let poetryIndent = verse.poetry?.indent ?? 0
            let indentString = poetryIndent > 0 ? String(repeating: "    ", count: poetryIndent) : ""

            // Verse number (superscript style)
            let verseNumberAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.75),
                .foregroundColor: UIColor.secondaryLabel,
                .baselineOffset: fontSize * 0.3,
                .paragraphStyle: paragraphStyle,
                .verseId: verse.ref
            ]

            let verseNumberStart = result.length
            // Add poetry indentation before verse number
            if !indentString.isEmpty {
                result.append(NSAttributedString(string: indentString, attributes: textAttributes))
            }
            let verseNumber = NSAttributedString(string: "\(verse.verse) ", attributes: verseNumberAttributes)
            result.append(verseNumber)
            coordinator.verseNumberRanges[verse.ref] = NSRange(location: verseNumberStart, length: verseNumber.length)

            // Verse text - check for Strong's annotations
            if let annotations = verse.annotations, !annotations.isEmpty {
                // New GRDB annotation format - render with offset-based annotations
                let verseText = verse.text
                var currentIndex = 0

                // Sort annotations: by start position, then by priority (strongs first for interactivity)
                let sortedAnnotations = annotations.sorted { a, b in
                    if a.start != b.start {
                        return a.start < b.start
                    }
                    // When same start, prefer strongs (interactive) over styling annotations
                    let priorityA = a.type == .strongs ? 0 : 1
                    let priorityB = b.type == .strongs ? 0 : 1
                    return priorityA < priorityB
                }

                // Find the active red letter range (if any) to apply styling to strongs words
                let redLetterRanges = annotations.filter { $0.type == .redLetter }.map { ($0.start, $0.end) }
                func isInRedLetter(_ index: Int) -> Bool {
                    redLetterRanges.contains { $0.0 <= index && index < $0.1 }
                }

                // Group overlapping Strong's annotations by position to collect multiple Strong's numbers
                var strongsGrouped: [Int: (end: Int, strongs: [String], morphology: String?)] = [:]
                for annotation in sortedAnnotations where annotation.type == .strongs {
                    if var existing = strongsGrouped[annotation.start] {
                        if let s = annotation.data?.strongs {
                            existing.strongs.append(s)
                        }
                        strongsGrouped[annotation.start] = existing
                    } else {
                        strongsGrouped[annotation.start] = (
                            end: annotation.end,
                            strongs: annotation.data?.strongs.map { [$0] } ?? [],
                            morphology: annotation.data?.morphology
                        )
                    }
                }

                for annotation in sortedAnnotations {
                    // Skip red letter annotations - we handle them by checking ranges for other annotations
                    if annotation.type == .redLetter {
                        continue
                    }

                    // Skip annotations that start before current position (overlapping)
                    if annotation.start < currentIndex {
                        continue
                    }

                    // Add plain text before this annotation
                    if annotation.start > currentIndex {
                        let startIdx = verseText.index(verseText.startIndex, offsetBy: currentIndex)
                        let endIdx = verseText.index(verseText.startIndex, offsetBy: min(annotation.start, verseText.count))
                        let plainPart = String(verseText[startIdx..<endIdx])
                        // Apply red letter styling if in red letter range
                        var plainAttributes = textAttributes
                        if isInRedLetter(currentIndex) {
                            plainAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: plainPart, attributes: plainAttributes))
                    }

                    // Add annotated text
                    let annotationStartIdx = verseText.index(verseText.startIndex, offsetBy: min(annotation.start, verseText.count))
                    let annotationEndIdx = verseText.index(verseText.startIndex, offsetBy: min(annotation.end, verseText.count))
                    let annotatedText = String(verseText[annotationStartIdx..<annotationEndIdx])

                    // Check if this annotation is within a red letter range
                    let inRedLetter = isInRedLetter(annotation.start)

                    switch annotation.type {
                    case .strongs:
                        // Get all Strong's numbers from overlapping annotations at this position
                        let grouped = strongsGrouped[annotation.start]
                        let strongsArray: [String] = grouped?.strongs ?? []
                        let annotatedWord = AnnotatedWord(
                            text: annotatedText,
                            strongs: strongsArray,
                            morphology: grouped?.morphology,
                            isAnnotated: !strongsArray.isEmpty
                        )
                        var strongsAttributes = textAttributes
                        strongsAttributes[.strongsWord] = annotatedWord

                        // Apply red letter color if in red letter range
                        if inRedLetter {
                            strongsAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }

                        if showStrongsHints {
                            strongsAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                            strongsAttributes[.underlineColor] = UIColor.secondaryLabel.withAlphaComponent(0.4)
                        }

                        result.append(NSAttributedString(string: annotatedText, attributes: strongsAttributes))

                    case .redLetter:
                        // Red letter is handled separately via isInRedLetter - shouldn't reach here
                        break

                    case .added:
                        var addedAttributes = textAttributes
                        addedAttributes[.font] = UIFont.italicSystemFont(ofSize: fontSize)
                        if inRedLetter {
                            addedAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: annotatedText, attributes: addedAttributes))

                    case .divineName:
                        var divineNameAttributes = textAttributes
                        // Small caps effect for divine name (LORD, GOD)
                        if let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withSymbolicTraits([.traitBold]) {
                            divineNameAttributes[.font] = UIFont(descriptor: descriptor, size: fontSize)
                        }
                        if inRedLetter {
                            divineNameAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: annotatedText, attributes: divineNameAttributes))

                    default:
                        // footnote, selah, variant - render as plain text (with red letter if applicable)
                        var defaultAttributes = textAttributes
                        if inRedLetter {
                            defaultAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: annotatedText, attributes: defaultAttributes))
                    }

                    currentIndex = annotation.end
                }

                // Add remaining plain text after last annotation
                if currentIndex < verseText.count {
                    let startIdx = verseText.index(verseText.startIndex, offsetBy: currentIndex)
                    let remainingText = String(verseText[startIdx...])
                    // Apply red letter styling if in red letter range
                    var remainingAttributes = textAttributes
                    if isInRedLetter(currentIndex) {
                        remainingAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                    }
                    result.append(NSAttributedString(string: remainingText, attributes: remainingAttributes))
                }
            } else if hasStrongsAnnotations(verse.text) {
                // Legacy regex format for old translations with {word|H1234} syntax
                let annotatedWords = parseAnnotatedVerse(verse.text)
                for word in annotatedWords {
                    if word.isAnnotated {
                        var strongsAttributes = textAttributes
                        strongsAttributes[.strongsWord] = word

                        if showStrongsHints {
                            strongsAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                            strongsAttributes[.underlineColor] = UIColor.secondaryLabel.withAlphaComponent(0.4)
                        }

                        let wordText = NSAttributedString(string: word.text, attributes: strongsAttributes)
                        result.append(wordText)
                    } else {
                        let plainText = NSAttributedString(string: word.text, attributes: textAttributes)
                        result.append(plainText)
                    }
                }
            } else {
                // No annotations - render plain text
                let verseText = NSAttributedString(string: verse.text, attributes: textAttributes)
                result.append(verseText)
            }

            // Store verse range for scrolling
            coordinator.verseRanges[verse.ref] = NSRange(location: verseStart, length: result.length - verseStart)

            // Add appropriate spacing between verses
            if index < verses.count - 1 {
                let nextVerse = verses[index + 1]
                // Poetry verses get newlines; check if current or next verse is poetry
                let isPoetry = verse.poetry != nil || nextVerse.poetry != nil
                let nextIsParagraph = nextVerse.paragraph
                let nextIsStanzaBreak = nextVerse.poetry?.stanzaBreak == true

                if isPoetry || nextIsParagraph || nextIsStanzaBreak {
                    result.append(NSAttributedString(string: "\n", attributes: textAttributes))
                } else {
                    result.append(NSAttributedString(string: " ", attributes: textAttributes))
                }
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

        private var versePositionsDirty: Bool = true
        private var lastVersePositionsContainerWidth: CGFloat = 0
        private var versePositionsWorkItem: DispatchWorkItem?

        // Cache size to prevent repeated calculations during scrolling
        var cachedSize: CGSize?
        var cachedWidth: CGFloat = 0

        init(_ parent: ChapterTextView) {
            self.parent = parent
        }

        func buildKey() -> String {
            // Create a key that uniquely identifies the content
            let verseIds = parent.verses.map { $0.ref }.description
            return "\(verseIds)-\(parent.fontSize)-\(parent.chapter)-\(parent.showStrongsHints)"
        }

        func markVersePositionsDirty() {
            versePositionsDirty = true
            cachedSize = nil // Invalidate size cache when content changes
        }

        func scheduleVersePositionCalculation(containerWidth: CGFloat) {
            guard versePositionsDirty || lastVersePositionsContainerWidth != containerWidth else { return }
            guard versePositionsWorkItem == nil else { return }

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.versePositionsWorkItem = nil
                guard let textView = self.textView else { return }
                guard !self.verseRanges.isEmpty else { return }

                // If container width changed, it affects layout -> positions.
                self.lastVersePositionsContainerWidth = containerWidth
                self.versePositionsDirty = false

                // Ensure layout once, then compute positions.
                textView.layoutManager.ensureLayout(for: textView.textContainer)
                self.calculateVersePositions()
            }
            versePositionsWorkItem = item
            DispatchQueue.main.async(execute: item)
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
            if let verseRef = attributes[.verseId] as? Int {
                if let verse = parent.verses.first(where: { $0.ref == verseRef }) {
                    // Get the verse number's actual rect from layout
                    if let verseRange = verseNumberRanges[verseRef] {
                        let glyphRange = textView.layoutManager.glyphRange(forCharacterRange: verseRange, actualCharacterRange: nil)
                        var rect = textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
                        // Adjust for text container inset
                        rect.origin.x += textView.textContainerInset.left
                        rect.origin.y += textView.textContainerInset.top

                        // Show menu at the verse location
                        showVerseMenu(for: verse, at: rect, in: textView)
                    }
                }
            }
        }

        private func showVerseMenu(for verse: TranslationVerse, at rect: CGRect, in textView: UITextView) {
            // Store for the delegate callback
            currentVerse = verse

            // Use UIEditMenuInteraction to show menu at the verse location
            let menuConfig = UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY))
            editMenuInteraction?.presentEditMenu(with: menuConfig)
        }

        // Store state for menu presentation
        var editMenuInteraction: UIEditMenuInteraction?
        var currentVerse: TranslationVerse?

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

            let actions: [UIAction] = [
                UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                    self?.parent.onAddNote(verse)
                }
            ]

            return UIMenu(children: actions)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            // Return the rect where the menu should point to
            if let verse = currentVerse,
               let range = verseNumberRanges[verse.ref],
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
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()

    private var showStrongsHints: Bool { userSettings.showStrongsHints }

    @Binding var date: Date
    @State private var readingMetaData: [ReadingMetaData]? = nil
    @State private var currentReadingIndex: Int = 0
    @State private var isLoading: Bool = false
    @State private var showingBookPicker: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @State private var showingSearch: Bool = false
    @State private var bottomSearchText: String = ""
    @State private var verses: [TranslationVerse] = []
    @State private var headings: [TranslationHeading] = []
    @State private var initialScrollItem: String? = nil
    @SceneStorage("readerTranslationId") private var translationId: String = ""  // GRDB translation ID (session)
    @State private var translationAbbreviation: String = ""  // For display
    @State private var translationName: String = ""  // For display
    @SceneStorage("readerCurrentVerseId") var currentVerseId: Int = 1001001
    @Binding var visibleVerseId: Int
    @Binding var scrollOrigin: ScrollOrigin
    private let scrollDebouncer = ScrollDebouncer()
    private let verseCommitDebouncer = ScrollDebouncer()
    @Binding var requestScrollToVerseId: Int?
    @Binding var requestScrollAnimated: Bool
    @State private var internalScrollToVerseId: Int? = nil
    @State private var scrollTargetY: CGFloat? = nil
    @State private var animateScroll: Bool = true
    @StateObject private var positionTracker = VersePositionTracker()
    @State private var pendingScrollVerseId: Int? = nil  // Tracks verse to scroll to after positions update
    @State private var scrollCleanupId: UUID = UUID() // To prevent race conditions in scroll cleanup
    @State private var isProgrammaticScroll: Bool = false  // Ignore scroll detection during programmatic scrolls
    @State private var isUserDragging: Bool = false // Track active user interaction
    @State private var isScrolling: Bool = false // True during drag AND deceleration

    @State private var selectedStrongsWord: AnnotatedWord? = nil  // For Strong's popover
    @Binding var toolbarsHidden: Bool  // Hide/show toolbars on tap
    @State private var toolbarMode: BottomToolbarMode = .search
    @State private var plansWithReadings: [PlanWithReadings] = []  // Plans with their readings for plan mode
    @State private var selectedPlanIndex: Int = 0  // Which plan is currently selected
    @State private var planReadingIndex: Int = 0  // Index within the selected plan's readings
    @State private var requestedToolbarMode: BottomToolbarMode? = nil  // Mode to switch to on appear
    @State private var hasAppliedInitialMode: Bool = false

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
        date: Binding<Date>,
        readingMetaData: [ReadingMetaData]? = nil,
        translationId: String? = nil,
        onVerseAction: ((Int, VerseAction) -> Void)? = nil,
        requestScrollToVerseId: Binding<Int?> = .constant(nil),
        requestScrollAnimated: Binding<Bool> = .constant(true),
        visibleVerseId: Binding<Int> = .constant(1001001),
        scrollOrigin: Binding<ScrollOrigin> = .constant(.none),
        toolbarsHidden: Binding<Bool> = .constant(false),
        initialToolbarMode: BottomToolbarMode? = nil
    ) {
        _date = date
        _readingMetaData = State(initialValue: readingMetaData)
        _requestedToolbarMode = State(initialValue: initialToolbarMode)
        _hasAppliedInitialMode = State(initialValue: false)

        // Load user settings
        let settings = UserDatabase.shared.getSettings()
        _userSettings = State(initialValue: settings)

        // Translation is stored in @SceneStorage - only set if explicitly provided
        // Scene storage persists the session translation across view recreation
        // If empty, it will be set to user.readerTranslationId in onAppear
        if let explicitTranslationId = translationId {
            _translationId = SceneStorage(wrappedValue: explicitTranslationId, "readerTranslationId")
        }

        // Load translation metadata (will be updated in onAppear if needed)
        let metadataId = translationId ?? settings.readerTranslationId
        if let translation = try? TranslationDatabase.shared.getTranslation(id: metadataId) {
            _translationAbbreviation = State(initialValue: translation.abbreviation)
            _translationName = State(initialValue: translation.name)
        } else {
            _translationAbbreviation = State(initialValue: metadataId)
            _translationName = State(initialValue: metadataId)
        }

        _visibleVerseId = visibleVerseId
        _scrollOrigin = scrollOrigin
        self.onVerseAction = onVerseAction
        _requestScrollToVerseId = requestScrollToVerseId
        _requestScrollAnimated = requestScrollAnimated
        _toolbarsHidden = toolbarsHidden
    }

    private var bookName: String {
        guard let firstVerse = verses.first else { return "" }
        return (try? BundledModuleDatabase.shared.getBook(id: firstVerse.book))?.name ?? ""
    }

    private var chapterNumber: Int {
        verses.first?.chapter ?? 1
    }

    private var showBookTitle: Bool {
        verses.first?.chapter == 1
    }

    @ViewBuilder
    private var bookPickerSheet: some View {
        BookListView(
            currentVerseId: $currentVerseId,
            showingBookPicker: $showingBookPicker,
            translationId: $translationId,
            translationAbbreviation: $translationAbbreviation,
            loadVersesClosure: {
                loadVerses(loadingCase: LOADING_CURRENT)
            },
            onTranslationChange: { newTranslationId in
                // Update translation metadata
                if let translation = try? TranslationDatabase.shared.getTranslation(id: newTranslationId) {
                    translationAbbreviation = translation.abbreviation
                    translationName = translation.name
                }

                // Check if in plan mode - reload the plan reading, otherwise load chapter
                if toolbarMode == .plan && planReadingIndex >= 0 {
                    loadPlanReading(at: planReadingIndex)
                } else {
                    loadVerses(loadingCase: LOADING_TRANSLATION, forTranslationId: newTranslationId)
                }
            }
        )
    }

    @ViewBuilder
    private var searchSheet: some View {
        SearchView(
            isPresented: $showingSearch,
            translationId: translationId,
            requestScrollToVerseId: $requestScrollToVerseId,
            requestScrollAnimated: $requestScrollAnimated,
            initialSearchText: bottomSearchText,
            fontSize: Int(userSettings.readerFontSize)
        )
    }

    @ViewBuilder
    private var collapsedHeader: some View {
        let (currentVerse, currentChapter, currentBook) = splitVerseId(currentVerseId)
        let book = try? BundledModuleDatabase.shared.getBook(id: currentBook)

        VStack(spacing: 0) {
            Text("\(translationAbbreviation) · \(book?.name ?? "") \(currentChapter)")
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

    func loadVerses(loadingCase: String, targetVerseId: Int? = nil, forTranslationId: String? = nil) {
        let (_, currentChapter, currentBook) = splitVerseId(currentVerseId)

        // Save current scroll position to history before navigating away
        // (skip for reading plan and history navigation)
        if !isHistoryNavigation && loadingCase != LOADING_READING {
            NavigationHistory.shared.updateCurrentPosition(to: currentVerseId)
        }

        // Clear positions and scroll target when loading new verses
        positionTracker.positions = [:]
        scrollTargetY = nil

        do {
            switch loadingCase {
            case LOADING_PREV_CHAPTER:
                let (newBook, newChapter) = getPreviousChapter(book: currentBook, chapter: currentChapter)
                let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: newBook, chapter: newChapter)
                verses = content.verses
                headings = content.headings

            case LOADING_NEXT_CHAPTER:
                let (newBook, newChapter) = getNextChapter(book: currentBook, chapter: currentChapter, translationId: translationId)
                let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: newBook, chapter: newChapter)
                verses = content.verses
                headings = content.headings

            case LOADING_PREV_BOOK:
                let newBook = max(1, currentBook - 1)
                let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: newBook, chapter: 1)
                verses = content.verses
                headings = content.headings

            case LOADING_NEXT_BOOK:
                let newBook = min(66, currentBook + 1)
                let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: newBook, chapter: 1)
                verses = content.verses
                headings = content.headings

            case LOADING_READING:
                let reading = readingMetaData![currentReadingIndex]
                verses = try TranslationDatabase.shared.getVerseRange(translationId: translationId, startRef: reading.sv, endRef: reading.ev)
                headings = []  // No headings for verse ranges

            case LOADING_HISTORY:
                if let targetId = targetVerseId {
                    let (_, targetChapter, targetBook) = splitVerseId(targetId)
                    let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: targetBook, chapter: targetChapter)
                    verses = content.verses
                    headings = content.headings
                }

            case LOADING_CURRENT:
                let content = try TranslationDatabase.shared.getChapter(translationId: translationId, book: currentBook, chapter: currentChapter)
                verses = content.verses
                headings = content.headings

            case LOADING_TRANSLATION:
                // Use explicitly passed translation ID, or fall back to current translation
                let newTranslationId = forTranslationId ?? translationId
                translationId = newTranslationId
                let content = try TranslationDatabase.shared.getChapter(translationId: newTranslationId, book: currentBook, chapter: currentChapter)
                verses = content.verses
                headings = content.headings

            default:
                break
            }
        } catch {
            print("ReaderView: Error loading verses: \(error)")
            verses = []
            headings = []
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
        } else if let firstVerse = verses.first {
            currentVerseId = firstVerse.ref
            pendingScrollVerseId = nil
        }

        // Record navigation in history (skip for reading plan and history navigation)
        if !isHistoryNavigation && loadingCase != LOADING_READING {
            NavigationHistory.shared.recordNavigation(to: currentVerseId, isHistoryNavigation: false)
        }

        isLoading = true
        isHistoryNavigation = false
    }

    /// Get the previous chapter (handles book boundaries)
    private func getPreviousChapter(book: Int, chapter: Int) -> (book: Int, chapter: Int) {
        if chapter > 1 {
            return (book, chapter - 1)
        } else if book > 1 {
            // Go to last chapter of previous book
            let prevBook = book - 1
            let lastChapter = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: prevBook)) ?? 1
            return (prevBook, lastChapter)
        }
        return (book, chapter)  // Already at beginning
    }

    /// Get the next chapter (handles book boundaries)
    private func getNextChapter(book: Int, chapter: Int, translationId: String) -> (book: Int, chapter: Int) {
        let chapterCount = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: book)) ?? 999
        if chapter < chapterCount {
            return (book, chapter + 1)
        } else if book < 66 {
            // Go to first chapter of next book
            return (book + 1, 1)
        }
        return (book, chapter)  // Already at end
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            // UIKit scroll spy for real-time scroll sync
                            ReaderScrollSpy(
                            versePositions: positionTracker.positions,
                            onVerseIdChange: { (verseId: Int) -> Void in
                                // Avoid expensive SwiftUI scroll geometry tracking; instead update
                                // verse state on a trailing debounce.
                                guard !isProgrammaticScroll else { return }

                                // If the other panel is in control and we aren't being actively dragged, yield
                                if !isUserDragging && scrollOrigin == .toolPanel {
                                    return
                                }

                                // Enforce our claim
                                if scrollOrigin != .bible {
                                    scrollOrigin = .bible
                                }
                            },
                            onUserScrollEndedAtVerseId: { (verseId: Int) -> Void in
                                // Commit verse state only after user scrolling settles.
                                commitVisibleVerseIfNeeded(verseId)
                            },
                            onScrollFullyStopped: { () -> Void in
                                // Re-enable text interactions when scroll completely stops
                                isScrolling = false
                            }
                        )
                            .frame(width: 1, height: 1)

                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id("top")

                            ChapterTextView(
                                verses: Array(verses),
                                headings: headings,
                                fontSize: CGFloat(userSettings.readerFontSize),
                                lineSpacing: 12,
                                bookName: bookName,
                                chapter: chapterNumber,
                                showBookTitle: showBookTitle,
                                showStrongsHints: showStrongsHints,
                                onAddNote: { (verse: TranslationVerse) -> Void in
                                    onVerseAction?(verse.verse, .addNote)
                                },
                                onShowStrongs: { (annotatedWord: AnnotatedWord) -> Void in
                                    selectedStrongsWord = annotatedWord
                                },
                                onSearchText: { (text: String) -> Void in
                                    bottomSearchText = text
                                    showingSearch = true
                                },
                                scrollToVerseId: $internalScrollToVerseId,
                                positionTracker: positionTracker,
                                onScrollToPosition: { (yPosition: CGFloat) -> Void in
                                    scrollTargetY = yPosition
                                },
                                onPositionsCalculated: nil,
                                isUserScrolling: isScrolling
                            )
                            .id("chapter_\(chapterNumber)_\(translationId)")

                            // Overscroll padding: allows last line to scroll to top for scroll-sync
                            Color.clear
                                .frame(height: max(0, geometry.size.height - 50))
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
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { (_: DragGesture.Value) -> Void in
                            isUserDragging = true
                            isScrolling = true
                            // Immediate claim on interaction start
                            if scrollOrigin != .bible {
                                scrollOrigin = .bible
                            }
                        }
                        .onEnded { (_: DragGesture.Value) -> Void in
                            isUserDragging = false
                            // Keep isScrolling true - it will be cleared by onScrollFullyStopped
                            // when UIScrollView reports deceleration is complete
                        }
                )
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
                .onChange(of: currentReadingIndex) {
                    // Only load via LOADING_READING if readingMetaData exists (legacy path)
                    // Plan mode uses loadPlanReading instead via onPlanReadingChanged
                    if readingMetaData != nil {
                        loadVerses(loadingCase: LOADING_READING)

                        if let readingId = readingMetaData?[currentReadingIndex].id {
                            if !UserDatabase.shared.isReadingCompleted(readingId) {
                                try? UserDatabase.shared.addCompletedReading(readingId)
                            }
                        }
                    }
                }

                .onChange(of: requestScrollToVerseId) {
                    if let verseId = requestScrollToVerseId {
                        isProgrammaticScroll = true // Ensure we flag this early
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
                            var didScroll = false
                            if let yPos = positionTracker.positions[verseId] {
                                scrollTargetY = max(0, yPos + 1 - 20)
                                didScroll = true
                            } else {
                                // Fallback: try to find nearest verse position
                                let targetVerse = verseId % 1000
                                let positions = positionTracker.positions
                                if !positions.isEmpty {
                                    // Find the closest verse that we have a position for
                                    let sortedVerses = positions.keys.sorted()
                                    if let closestId = sortedVerses.last(where: { ($0 % 1000) <= targetVerse }) ?? sortedVerses.first,
                                       let yPos = positions[closestId] {
                                        scrollTargetY = max(0, yPos + 1 - 20)
                                        didScroll = true
                                    }
                                }
                            }
                            // If scroll failed, still reset scrollOrigin to prevent it from getting stuck
                            if !didScroll {
                                isProgrammaticScroll = false
                                if scrollOrigin == .toolPanel {
                                    scrollOrigin = .none
                                }
                            }
                        }
                        requestScrollToVerseId = nil
                    }
                }
                .onChange(of: scrollTargetY) {
                    if let targetY = scrollTargetY {
                        // Block scroll detection during programmatic scroll
                        isProgrammaticScroll = true
                        scrollDebouncer.cancel()

                        // Generate a new ID for this scroll job
                        let jobId = UUID()
                        scrollCleanupId = jobId

                        // Small delay for anchor view to render
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            guard scrollCleanupId == jobId else { return }

                            if animateScroll {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("scrollTarget", anchor: .top)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    guard scrollCleanupId == jobId else { return }
                                    scrollTargetY = nil
                                    isProgrammaticScroll = false
                                }
                            } else {
                                proxy.scrollTo("scrollTarget", anchor: .top)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    guard scrollCleanupId == jobId else { return }
                                    scrollTargetY = nil
                                    animateScroll = true
                                    isProgrammaticScroll = false
                                }
                            }
                        }
                    }
                }
                } // ScrollViewReader
            } // GeometryReader
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ReaderBottomToolbarView(
                    readingMetaData: $readingMetaData,
                    currentReadingIndex: $currentReadingIndex,
                    date: $date,
                    translationId: $translationId,
                    translationAbbreviation: $translationAbbreviation,
                    currentVerseId: $currentVerseId,
                    showingSearch: $showingSearch,
                    searchText: $bottomSearchText,
                    toolbarMode: $toolbarMode,
                    selectedPlanIndex: $selectedPlanIndex,
                    plansWithReadings: plansWithReadings,
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
                    },
                    onPlanReadingChanged: { index in
                        planReadingIndex = index
                        loadPlanReading(at: index)
                    },
                    onPlanChanged: { planIndex in
                        selectedPlanIndex = planIndex
                        planReadingIndex = 0
                        loadPlanReading(at: 0)
                    }
                )
            }
            .toolbar {
                ReaderNavigationToolbarView(
                    userSettings: $userSettings,
                    readingMetaData: $readingMetaData,
                    translationId: $translationId,
                    translationAbbreviation: $translationAbbreviation,
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
                    translationId: translationId,
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
            // Initialize translation from user default if not already set in scene storage
            if translationId.isEmpty {
                translationId = userSettings.readerTranslationId
            }
            // Always update the display metadata to match the current translationId
            if let translation = try? TranslationDatabase.shared.getTranslation(id: translationId) {
                translationAbbreviation = translation.abbreviation
                translationName = translation.name
            }

            // Load plan readings for plan mode
            loadPlanReadings()

            // Apply initial toolbar mode if provided (must be after loadPlanReadings)
            if !hasAppliedInitialMode, let mode = requestedToolbarMode {
                // Only apply plan mode if there are readings
                if mode == .plan && plansWithReadings.isEmpty {
                    toolbarMode = .search  // Fall back to search if no plan readings
                } else {
                    toolbarMode = mode
                }
                hasAppliedInitialMode = true
            }

            // Determine which content to load based on mode
            let effectiveMode = (plansWithReadings.isEmpty && requestedToolbarMode == .plan) ? .search : (requestedToolbarMode ?? toolbarMode)

            if readingMetaData != nil {
                initialScrollItem = "top"
                currentReadingIndex = 0
                loadVerses(loadingCase: LOADING_READING)

                if let readingId = readingMetaData?[0].id {
                    if !UserDatabase.shared.isReadingCompleted(readingId) {
                        try? UserDatabase.shared.addCompletedReading(readingId)
                    }
                }
            } else if effectiveMode == .plan && !plansWithReadings.isEmpty {
                // Start in plan mode with first reading
                loadPlanReading(at: 0)
            } else {
                loadVerses(loadingCase: LOADING_CURRENT)
                // Always scroll to top since headers are now part of ChapterTextView
                initialScrollItem = "top"
            }
        }
        .onChange(of: toolbarMode) { _, newMode in
            if newMode == .plan {
                if !plansWithReadings.isEmpty {
                    // Switch to plan reading
                    loadPlanReading(at: planReadingIndex)
                } else {
                    // No plan readings available, switch back to search
                    toolbarMode = .search
                }
            } else if readingMetaData == nil {
                // Switch back to chapter view
                loadVerses(loadingCase: LOADING_CURRENT)
            }
        }
        .onChange(of: date) { _, _ in
            // Reload plan readings when date changes
            loadPlanReadings()
            if toolbarMode == .plan {
                if !plansWithReadings.isEmpty {
                    loadPlanReading(at: 0)
                } else {
                    // No readings for this date, switch back to search
                    toolbarMode = .search
                }
            }
        }
    }

    private func commitVisibleVerseIfNeeded(_ verseId: Int) {
        // Commit verse state only after scroll settles.
        verseCommitDebouncer.debounce(delay: 0.12) {
            guard !isProgrammaticScroll else { return }
            guard verseId != currentVerseId else { return }

            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                currentVerseId = verseId
                visibleVerseId = verseId
            }

            NavigationHistory.shared.updateCurrentPosition(to: verseId)
        }
    }

    /// Loads today's readings from the user's selected plans
    private func loadPlanReadings() {
        let plans = (try? BundledModuleDatabase.shared.getAllPlans()) ?? []
        let plansMetaData = PlansMetaData(plans: plans, date: date)

        // Build list of plans with their readings
        var plansWithReadingsTemp: [PlanWithReadings] = []
        for planMeta in plansMetaData.planMetaData {
            if userSettings.isPlanSelected(planMeta.id) && !planMeta.readingMetaData.isEmpty {
                plansWithReadingsTemp.append(PlanWithReadings(
                    id: planMeta.id,
                    name: planMeta.plan.name,
                    readings: planMeta.readingMetaData
                ))
            }
        }

        plansWithReadings = plansWithReadingsTemp
        // Reset indices, keeping selectedPlanIndex if still valid
        if selectedPlanIndex >= plansWithReadings.count {
            selectedPlanIndex = 0
        }
        planReadingIndex = 0
    }

    /// Loads verses for the specified plan reading index within the selected plan
    private func loadPlanReading(at index: Int) {
        guard selectedPlanIndex >= 0 && selectedPlanIndex < plansWithReadings.count else { return }
        let currentPlanReadings = plansWithReadings[selectedPlanIndex].readings
        guard index >= 0 && index < currentPlanReadings.count else { return }

        let reading = currentPlanReadings[index]
        planReadingIndex = index

        // Mark reading as completed
        if !UserDatabase.shared.isReadingCompleted(reading.id) {
            try? UserDatabase.shared.addCompletedReading(reading.id)
        }

        // Update currentVerseId to the start of the reading so toolbar and tool pane update correctly
        currentVerseId = reading.sv
        visibleVerseId = reading.sv

        // Load the verses for this reading
        if let fetchedVerses = try? TranslationDatabase.shared.getVerseRange(
            translationId: translationId,
            startRef: reading.sv,
            endRef: reading.ev
        ) {
            verses = fetchedVerses

            // Fetch headings for all chapters in the verse range
            var allHeadings: [TranslationHeading] = []
            if !fetchedVerses.isEmpty {
                let startBook = reading.sv / 1000000
                let startChapter = (reading.sv % 1000000) / 1000
                let endBook = reading.ev / 1000000
                let endChapter = (reading.ev % 1000000) / 1000

                // Collect headings for each book/chapter in the range
                for book in startBook...endBook {
                    let firstChapter = (book == startBook) ? startChapter : 1
                    let lastChapter = (book == endBook) ? endChapter : 150  // Use high number, will be limited by actual chapters
                    for chapter in firstChapter...lastChapter {
                        if let chapterHeadings = try? TranslationDatabase.shared.getHeadingsForChapter(
                            translationId: translationId,
                            book: book,
                            chapter: chapter
                        ) {
                            allHeadings.append(contentsOf: chapterHeadings)
                        }
                    }
                }
            }

            headings = allHeadings
            initialScrollItem = "top"
        }
    }
}

struct ReaderViewPreview: View {
    @State var date: Date = Date.now
    @State var toolbarsHidden: Bool = false

    var body: some View {
        ReaderView(
            date: $date,
            toolbarsHidden: $toolbarsHidden
        )
    }
}

#Preview {
    ReaderViewPreview()
}

