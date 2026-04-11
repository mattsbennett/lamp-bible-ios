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

// MARK: - Custom Layout Manager for Compact Backgrounds

/// Custom NSLayoutManager that draws background colors with reduced height
/// and rounded corners to match text height rather than full line height
class CompactBackgroundLayoutManager: NSLayoutManager {

    /// Amount to trim from bottom of background rects (where line spacing is added)
    var lineSpacingTrim: CGFloat = 0

    /// Corner radius for highlight backgrounds (0 = square corners)
    var cornerRadius: CGFloat = 3

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: UIColor) {
        guard let context = UIGraphicsGetCurrentContext() else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        context.saveGState()
        context.setFillColor(color.cgColor)

        for i in 0..<rectCount {
            var rect = rectArray[i]

            // Adjust rect to trim line spacing
            if lineSpacingTrim > 0 && rect.height > lineSpacingTrim {
                rect.origin.y += lineSpacingTrim / 3  // Shift down to center
                rect.size.height -= lineSpacingTrim
            }

            // Draw with rounded corners
            let path = UIBezierPath(roundedRect: rect, cornerRadius: min(cornerRadius, rect.height / 2))
            context.addPath(path.cgPath)
        }

        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - Custom Text View with Compact Selection

/// Custom UITextView that adjusts selection highlight height to match text (excluding line spacing).
/// The trim is computed dynamically per-rect from the paragraph style's lineSpacing so that
/// body text (which has lineSpacing) gets trimmed while headings (which don't) keep full height.
class CompactSelectionTextView: UITextView {

    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let originalRects = super.selectionRects(for: range)
        let renderedRects = originalRects.map(\.rect).filter { !$0.isNull && !$0.isEmpty }
        let spansMultipleLines = Set(renderedRects.map { Int($0.midY.rounded()) }).count > 1

        // UIKit's full-height rects look more consistent for multi-line selections,
        // especially when the first or last line is only partially selected.
        guard !spansMultipleLines else { return originalRects }

        return originalRects.map { original in
            // Find character at this rect's position to read the paragraph style's lineSpacing
            let adjustedPoint = CGPoint(
                x: original.rect.midX - textContainerInset.left,
                y: original.rect.midY - textContainerInset.top
            )
            var fraction: CGFloat = 0
            let charIndex = layoutManager.characterIndex(
                for: adjustedPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )

            var trim: CGFloat = 0
            if charIndex < textStorage.length,
               let style = textStorage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle {
                trim = style.lineSpacing
            }

            guard trim > 0 else { return original }
            return CompactSelectionRect(original: original, heightTrim: trim)
        }
    }
}

/// Custom UITextSelectionRect that reduces height to exclude line spacing
private class CompactSelectionRect: UITextSelectionRect {
    private let original: UITextSelectionRect
    private let heightTrim: CGFloat

    init(original: UITextSelectionRect, heightTrim: CGFloat) {
        self.original = original
        self.heightTrim = heightTrim
        super.init()
    }

    override var rect: CGRect {
        var r = original.rect
        if r.height > heightTrim {
            r.origin.y += heightTrim / 3  // Shift down to center
            r.size.height -= heightTrim
        }
        return r
    }

    override var writingDirection: NSWritingDirection { original.writingDirection }
    override var containsStart: Bool { original.containsStart }
    override var containsEnd: Bool { original.containsEnd }
    override var isVertical: Bool { original.isVertical }
}

// MARK: - Chapter Navigation Button

enum ChapterNavigationDirection {
    case previous
    case next
}

/// Minimal arrow button for navigating between chapters with circular progress indicator
struct ChapterNavigationButton: View {
    let direction: ChapterNavigationDirection
    let progress: CGFloat  // 0 = no pull, 1 = threshold reached, can exceed 1
    let chapterLabel: String?  // e.g., "Genesis 49" - shown when threshold reached
    let action: () -> Void

    private let circleSize: CGFloat = 30

    private var iconName: String {
        switch direction {
        case .previous:
            return "arrow.up"
        case .next:
            return "arrow.down"
        }
    }

    // Clamp progress to 0...1 for visual calculations
    private var clampedProgress: CGFloat {
        min(1.0, max(0, progress))
    }

    // Whether threshold has been reached
    private var isThresholdReached: Bool {
        progress >= 1.0
    }

    // Stroke color
    private var strokeColor: Color {
        Color.secondary.opacity(0.4 + clampedProgress * 0.3)
    }

    // Fill color when threshold reached
    private var fillColor: Color {
        Color.secondary
    }

    // Arrow color - inverts when threshold reached
    private var arrowColor: Color {
        if isThresholdReached {
            return Color(UIColor.systemBackground)
        } else {
            return Color.secondary.opacity(0.4 + clampedProgress * 0.3)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isThresholdReached {
                    // Filled circle when threshold reached
                    Circle()
                        .fill(fillColor)
                        .frame(width: circleSize, height: circleSize)
                } else {
                    // Progress stroke - draws clockwise from top
                    Circle()
                        .trim(from: 0, to: clampedProgress)
                        .stroke(strokeColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: circleSize, height: circleSize)
                        .rotationEffect(.degrees(-90))  // Start from top (12 o'clock)
                }

                // Arrow icon
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(arrowColor)
            }
            .overlay {
                // Chapter label as overlay so it doesn't affect layout
                if isThresholdReached, let label = chapterLabel {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .offset(y: direction == .previous ? -30 : 30)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isThresholdReached)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}

// MARK: - Bottom Button Position Tracking

/// PreferenceKey to track the bottom button's vertical position
struct BottomButtonMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

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
    let highlightsByVerse: [Int: [HighlightEntry]]  // Highlights keyed by verse ref
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
        let layoutManager = CompactBackgroundLayoutManager()
        // Trim line spacing from highlight backgrounds so they fit the text height
        layoutManager.lineSpacingTrim = lineSpacing * 1.2
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = CompactSelectionTextView(frame: .zero, textContainer: textContainer)
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

            // Preserve selection during rebuild
            let savedSelection = textView.selectedRange

            if isSimplifiedText {
                textView.attributedText = buildSimplifiedAttributedString()
            } else {
                let attributedString = buildAttributedString(coordinator: context.coordinator)
                textView.attributedText = attributedString
            }

            // Restore selection if it was valid
            if savedSelection.length > 0 && savedSelection.location + savedSelection.length <= textView.attributedText.length {
                textView.selectedRange = savedSelection
            }

            textView.invalidateIntrinsicContentSize()

            // Content changed; positions need recalculation (but not during sizeThatFits).
            if !isSimplifiedText {
                context.coordinator.markVersePositionsDirty()
            }
        }

        // Note: Scroll-to-verse is handled by onChange(of: versePositions) in ReaderView
        // This ensures scrolling happens after positions are calculated

        // Keep text view always selectable - only disable user interaction during active scrolling
        // to reduce overhead, but this doesn't affect selectability
        if !isSimplifiedText {
            // Always keep selectable
            if !textView.isSelectable {
                textView.isSelectable = true
            }
            // Always keep user interaction enabled (removing scroll optimization that was causing issues)
            if !textView.isUserInteractionEnabled {
                textView.isUserInteractionEnabled = true
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
        coordinator.verseTextRanges.removeAll()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineHeightMultiple = 1.2

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]

        // Superscription (verse 0) uses muted italic text like headings
        let superscriptionAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.italicSystemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.secondaryLabel
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
            var hadHeadingsBeforeVerse = false
            if let verseHeadings = headingsByRef[verseRef] {
                hadHeadingsBeforeVerse = true
                for heading in verseHeadings {
                    let headingText = NSAttributedString(string: "\(heading.text)\n", attributes: sectionHeadingAttributes)
                    result.append(headingText)
                }
            }

            let verseStart = result.length

            let verseParagraphStyle = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            if let poetry = verse.poetry, poetry.stanzaBreak == true {
                verseParagraphStyle.paragraphSpacingBefore = lineSpacing * 1.5
            } else if verse.paragraph && index > 0 {
                verseParagraphStyle.paragraphSpacingBefore = lineSpacing
            } else if hadHeadingsBeforeVerse {
                verseParagraphStyle.paragraphSpacingBefore = lineSpacing
            }

            // Poetry indentation
            let poetryIndent = verse.poetry?.indent ?? 0
            let indentString = poetryIndent > 0 ? String(repeating: "    ", count: poetryIndent) : ""

            // Verse number (superscript style)
            let verseNumberAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.75),
                .foregroundColor: UIColor.secondaryLabel,
                .baselineOffset: fontSize * 0.3,
                .paragraphStyle: verseParagraphStyle,
                .verseId: verse.ref
            ]

            // Use muted styling for superscriptions (verse 0)
            let isSuperscription = verse.verse == 0
            var verseTextAttributes = isSuperscription ? superscriptionAttributes : textAttributes
            verseTextAttributes[.paragraphStyle] = verseParagraphStyle

            let verseNumberStart = result.length
            // Add poetry indentation before verse number (skip for superscriptions)
            if !indentString.isEmpty && !isSuperscription {
                var indentAttributes = textAttributes
                indentAttributes[.paragraphStyle] = verseParagraphStyle
                result.append(NSAttributedString(string: indentString, attributes: indentAttributes))
            }
            // Skip verse number for superscriptions (verse 0)
            if !isSuperscription {
                let verseNumber = NSAttributedString(string: "\(verse.verse) ", attributes: verseNumberAttributes)
                result.append(verseNumber)
                coordinator.verseNumberRanges[verse.ref] = NSRange(location: verseNumberStart, length: verseNumber.length)
            }

            // Track where verse text content starts (for highlight positioning)
            let verseTextStart = result.length

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
                    // Must split at red-letter boundaries to apply correct styling
                    if annotation.start > currentIndex {
                        var segmentStart = currentIndex
                        let segmentEnd = min(annotation.start, verseText.count)

                        while segmentStart < segmentEnd {
                            // Find the next boundary (red-letter start or end)
                            var nextBoundary = segmentEnd
                            for (rlStart, rlEnd) in redLetterRanges {
                                if rlStart > segmentStart && rlStart < nextBoundary {
                                    nextBoundary = rlStart
                                }
                                if rlEnd > segmentStart && rlEnd < nextBoundary {
                                    nextBoundary = rlEnd
                                }
                            }

                            let startIdx = verseText.index(verseText.startIndex, offsetBy: segmentStart)
                            let endIdx = verseText.index(verseText.startIndex, offsetBy: nextBoundary)
                            let plainPart = String(verseText[startIdx..<endIdx])

                            var plainAttributes = verseTextAttributes
                            if isInRedLetter(segmentStart) {
                                plainAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                            }
                            result.append(NSAttributedString(string: plainPart, attributes: plainAttributes))

                            segmentStart = nextBoundary
                        }
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
                        var strongsAttributes = verseTextAttributes
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
                        var addedAttributes = verseTextAttributes
                        addedAttributes[.font] = UIFont.italicSystemFont(ofSize: fontSize)
                        if inRedLetter {
                            addedAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: annotatedText, attributes: addedAttributes))

                    case .divineName:
                        var divineNameAttributes = verseTextAttributes
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
                        var defaultAttributes = verseTextAttributes
                        if inRedLetter {
                            defaultAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: annotatedText, attributes: defaultAttributes))
                    }

                    currentIndex = annotation.end
                }

                // Add remaining plain text after last annotation
                // Must split at red-letter boundaries to apply correct styling
                if currentIndex < verseText.count {
                    var segmentStart = currentIndex
                    let segmentEnd = verseText.count

                    while segmentStart < segmentEnd {
                        // Find the next boundary (red-letter start or end)
                        var nextBoundary = segmentEnd
                        for (rlStart, rlEnd) in redLetterRanges {
                            if rlStart > segmentStart && rlStart < nextBoundary {
                                nextBoundary = rlStart
                            }
                            if rlEnd > segmentStart && rlEnd < nextBoundary {
                                nextBoundary = rlEnd
                            }
                        }

                        let startIdx = verseText.index(verseText.startIndex, offsetBy: segmentStart)
                        let endIdx = verseText.index(verseText.startIndex, offsetBy: nextBoundary)
                        let plainPart = String(verseText[startIdx..<endIdx])

                        var plainAttributes = verseTextAttributes
                        if isInRedLetter(segmentStart) {
                            plainAttributes[.foregroundColor] = UIColor(red: 0.78, green: 0.32, blue: 0.32, alpha: 1.0)
                        }
                        result.append(NSAttributedString(string: plainPart, attributes: plainAttributes))

                        segmentStart = nextBoundary
                    }
                }
            } else if hasStrongsAnnotations(verse.text) {
                // Legacy regex format for old translations with {word|H1234} syntax
                let annotatedWords = parseAnnotatedVerse(verse.text)
                for word in annotatedWords {
                    if word.isAnnotated {
                        var strongsAttributes = verseTextAttributes
                        strongsAttributes[.strongsWord] = word

                        if showStrongsHints {
                            strongsAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                            strongsAttributes[.underlineColor] = UIColor.secondaryLabel.withAlphaComponent(0.4)
                        }

                        let wordText = NSAttributedString(string: word.text, attributes: strongsAttributes)
                        result.append(wordText)
                    } else {
                        let plainText = NSAttributedString(string: word.text, attributes: verseTextAttributes)
                        result.append(plainText)
                    }
                }
            } else {
                // No annotations - render plain text
                let verseText = NSAttributedString(string: verse.text, attributes: verseTextAttributes)
                result.append(verseText)
            }

            // Store verse text range (for highlight positioning - text content only, no verse number)
            let verseTextLength = result.length - verseTextStart
            coordinator.verseTextRanges[verse.ref] = NSRange(location: verseTextStart, length: verseTextLength)

            // Store verse range for scrolling
            coordinator.verseRanges[verse.ref] = NSRange(location: verseStart, length: result.length - verseStart)

            // Add appropriate spacing between verses
            if index < verses.count - 1 {
                let nextVerse = verses[index + 1]
                // Poetry verses get newlines; check if current or next verse is poetry
                let isPoetry = verse.poetry != nil || nextVerse.poetry != nil
                let nextIsParagraph = nextVerse.paragraph
                let nextIsStanzaBreak = nextVerse.poetry?.stanzaBreak == true
                let nextVerseRef = nextVerse.book * 1000000 + nextVerse.chapter * 1000 + nextVerse.verse
                let nextHasHeading = headingsByRef[nextVerseRef] != nil
                let nextHasChapterTitle = nextVerse.chapter != verse.chapter

                if isPoetry || nextIsParagraph || nextIsStanzaBreak || nextHasHeading || nextHasChapterTitle {
                    result.append(NSAttributedString(string: "\n", attributes: textAttributes))
                } else {
                    result.append(NSAttributedString(string: " ", attributes: textAttributes))
                }
            }
        }

        // Apply highlights from HighlightManager
        applyHighlights(to: result, coordinator: coordinator)

        return result
    }

    /// Apply highlights to the attributed string based on passed-in highlights
    private func applyHighlights(to result: NSMutableAttributedString, coordinator: Coordinator) {
        // Get highlights for each verse from the passed-in dictionary
        for verse in verses {
            guard let highlights = highlightsByVerse[verse.ref], !highlights.isEmpty else { continue }

            // Get the text range for this verse
            guard let verseTextRange = coordinator.verseTextRanges[verse.ref] else { continue }

            for highlight in highlights {
                // Calculate the NSRange within the attributed string
                // highlight.sc and highlight.ec are character offsets within the verse text
                let highlightStart = verseTextRange.location + highlight.sc
                let highlightLength = min(highlight.ec - highlight.sc, verseTextRange.length - highlight.sc)

                guard highlightLength > 0 && highlightStart < result.length else { continue }

                let highlightRange = NSRange(
                    location: highlightStart,
                    length: min(highlightLength, result.length - highlightStart)
                )

                // Apply styling based on highlight style
                switch highlight.highlightStyle {
                case .highlight:
                    // Background color fill with alpha
                    let backgroundColor = highlight.highlightColor.uiColor.withAlphaComponent(0.4)
                    result.addAttribute(.backgroundColor, value: backgroundColor, range: highlightRange)

                case .underlineSolid:
                    result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: highlightRange)
                    result.addAttribute(.underlineColor, value: highlight.highlightColor.uiColor, range: highlightRange)

                case .underlineDashed:
                    let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
                    result.addAttribute(.underlineStyle, value: style, range: highlightRange)
                    result.addAttribute(.underlineColor, value: highlight.highlightColor.uiColor, range: highlightRange)

                case .underlineDotted:
                    let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    result.addAttribute(.underlineStyle, value: style, range: highlightRange)
                    result.addAttribute(.underlineColor, value: highlight.highlightColor.uiColor, range: highlightRange)
                }
            }
        }
    }

    class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
        var parent: ChapterTextView
        weak var textView: UITextView?
        var verseRanges: [Int: NSRange] = [:]
        var verseNumberRanges: [Int: NSRange] = [:]
        var verseTextRanges: [Int: NSRange] = [:]  // Verse text content ranges (excluding verse number)
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
            // Create a key that uniquely identifies the content (including highlights)
            let verseIds = parent.verses.map { $0.ref }.description
            let highlightCount = parent.highlightsByVerse.values.reduce(0) { $0 + $1.count }
            return "\(verseIds)-\(parent.fontSize)-\(parent.chapter)-\(parent.showStrongsHints)-\(highlightCount)"
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

                // If text container isn't sized yet, retry after a delay
                if textView.textContainer.size.width <= 0 {
                    self.versePositionsDirty = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.scheduleVersePositionCalculation(containerWidth: containerWidth)
                    }
                    return
                }

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
            guard range.length > 0 else {
                return UIMenu(children: suggestedActions)
            }

            var actions = suggestedActions

            // Only show highlight actions when selection overlaps actual verse text
            let selectionOverlapsVerseText = verseTextRanges.values.contains { verseRange in
                range.location < verseRange.location + verseRange.length &&
                range.location + range.length > verseRange.location
            }

            if selectionOverlapsVerseText {
                // Check if selection overlaps with existing highlights
                let overlappingHighlights = findHighlightsInRange(range)

                if !overlappingHighlights.isEmpty {
                    // Add Remove Highlight action
                    let removeAction = UIAction(title: "Remove Highlight", image: UIImage(systemName: "highlighter"), attributes: .destructive) { [weak self] _ in
                        self?.removeHighlightsInRange(range)
                    }
                    actions.insert(removeAction, at: 0)
                } else {
                    // Add Highlight action
                    let highlightAction = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                        self?.createHighlightForSelection(range)
                    }
                    actions.insert(highlightAction, at: 0)
                }
            }

            // Add Search action
            if let onSearch = parent.onSearchText {
                let selectedText = (textView.text as NSString).substring(with: range)
                let searchAction = UIAction(title: "Search", image: UIImage(systemName: "magnifyingglass")) { _ in
                    onSearch(selectedText)
                }
                let insertIndex = min(1, actions.count)
                actions.insert(searchAction, at: insertIndex)
            }

            return UIMenu(children: actions)
        }

        /// Find highlights that overlap with the given text range
        private func findHighlightsInRange(_ range: NSRange) -> [(verseRef: Int, highlight: HighlightEntry)] {
            var results: [(verseRef: Int, highlight: HighlightEntry)] = []

            for (verseRef, verseTextRange) in verseTextRanges {
                let selectionStart = range.location
                let selectionEnd = range.location + range.length
                let verseStart = verseTextRange.location
                let verseEnd = verseTextRange.location + verseTextRange.length

                // Check if selection overlaps with this verse
                if selectionStart < verseEnd && selectionEnd > verseStart {
                    // Get highlights for this verse
                    let highlights = parent.highlightsByVerse[verseRef] ?? []

                    for highlight in highlights {
                        // Convert highlight character offsets to absolute positions
                        let highlightAbsStart = verseStart + highlight.sc
                        let highlightAbsEnd = verseStart + highlight.ec

                        // Check if selection overlaps with this highlight
                        if selectionStart < highlightAbsEnd && selectionEnd > highlightAbsStart {
                            results.append((verseRef: verseRef, highlight: highlight))
                        }
                    }
                }
            }

            return results
        }

        /// Remove highlights that overlap with the given text range (supports partial removal with whitespace trimming)
        private func removeHighlightsInRange(_ range: NSRange) {
            let selectionStart = range.location
            let selectionEnd = range.location + range.length

            guard let text = textView?.text else { return }

            Task { @MainActor in
                for (verseRef, verseTextRange) in verseTextRanges {
                    let verseStart = verseTextRange.location
                    let verseEnd = verseTextRange.location + verseTextRange.length

                    // Check if selection overlaps with this verse
                    guard selectionStart < verseEnd && selectionEnd > verseStart else { continue }

                    // Get verse text for whitespace trimming
                    let verseTextStart = text.index(text.startIndex, offsetBy: verseStart)
                    let verseTextEnd = text.index(text.startIndex, offsetBy: min(verseEnd, text.count))
                    let verseText = String(text[verseTextStart..<verseTextEnd])

                    // Convert selection to verse-relative offsets
                    let selScInVerse = max(0, selectionStart - verseStart)
                    let selEcInVerse = min(verseTextRange.length, selectionEnd - verseStart)

                    // Get highlights for this verse
                    let highlights = parent.highlightsByVerse[verseRef] ?? []

                    for highlight in highlights {
                        // Check if selection overlaps with this highlight
                        guard selScInVerse < highlight.ec && selEcInVerse > highlight.sc else { continue }

                        guard let highlightId = highlight.id else {
                            print("[Highlight] WARNING: Highlight has no ID - reloading...")
                            let (_, chapter, book) = splitVerseId(verseRef)
                            HighlightManager.shared.loadHighlightsForChapter(book: book, chapter: chapter)
                            return
                        }

                        do {
                            // Determine removal type based on overlap
                            let coversStart = selScInVerse <= highlight.sc
                            let coversEnd = selEcInVerse >= highlight.ec

                            if coversStart && coversEnd {
                                // Selection covers entire highlight → remove
                                print("[Highlight] Removing entire highlight id=\(highlightId)")
                                try HighlightManager.shared.removeHighlight(highlight)
                            } else if coversStart {
                                // Selection covers start → shrink highlight to start after selection
                                var newSc = selEcInVerse
                                // Trim leading whitespace from new start
                                while newSc < highlight.ec {
                                    let charIndex = verseText.index(verseText.startIndex, offsetBy: newSc)
                                    if verseText[charIndex].isWhitespace {
                                        newSc += 1
                                    } else {
                                        break
                                    }
                                }
                                if newSc < highlight.ec {
                                    print("[Highlight] Shrinking highlight id=\(highlightId) start: \(highlight.sc) -> \(newSc)")
                                    try HighlightManager.shared.updateHighlight(highlight, newSc: newSc, newEc: highlight.ec)
                                } else {
                                    // Nothing left after trimming
                                    try HighlightManager.shared.removeHighlight(highlight)
                                }
                            } else if coversEnd {
                                // Selection covers end → shrink highlight to end before selection
                                var newEc = selScInVerse
                                // Trim trailing whitespace from new end
                                while newEc > highlight.sc {
                                    let charIndex = verseText.index(verseText.startIndex, offsetBy: newEc - 1)
                                    if verseText[charIndex].isWhitespace {
                                        newEc -= 1
                                    } else {
                                        break
                                    }
                                }
                                if newEc > highlight.sc {
                                    print("[Highlight] Shrinking highlight id=\(highlightId) end: \(highlight.ec) -> \(newEc)")
                                    try HighlightManager.shared.updateHighlight(highlight, newSc: highlight.sc, newEc: newEc)
                                } else {
                                    // Nothing left after trimming
                                    try HighlightManager.shared.removeHighlight(highlight)
                                }
                            } else {
                                // Selection in middle → split into two highlights
                                print("[Highlight] Splitting highlight id=\(highlightId) at \(selScInVerse)-\(selEcInVerse)")

                                // Calculate trimmed bounds for "before" part (trim trailing whitespace)
                                var beforeEc = selScInVerse
                                while beforeEc > highlight.sc {
                                    let charIndex = verseText.index(verseText.startIndex, offsetBy: beforeEc - 1)
                                    if verseText[charIndex].isWhitespace {
                                        beforeEc -= 1
                                    } else {
                                        break
                                    }
                                }

                                // Calculate trimmed bounds for "after" part (trim leading whitespace)
                                var afterSc = selEcInVerse
                                while afterSc < highlight.ec {
                                    let charIndex = verseText.index(verseText.startIndex, offsetBy: afterSc)
                                    if verseText[charIndex].isWhitespace {
                                        afterSc += 1
                                    } else {
                                        break
                                    }
                                }

                                // Update or remove the "before" part
                                if beforeEc > highlight.sc {
                                    try HighlightManager.shared.updateHighlight(highlight, newSc: highlight.sc, newEc: beforeEc)
                                } else {
                                    try HighlightManager.shared.removeHighlight(highlight)
                                }

                                // Create the "after" part if it has content
                                if afterSc < highlight.ec {
                                    try HighlightManager.shared.addHighlight(
                                        ref: verseRef,
                                        startChar: afterSc,
                                        endChar: highlight.ec,
                                        style: highlight.highlightStyle,
                                        color: highlight.highlightColor
                                    )
                                }
                            }
                        } catch {
                            print("[Highlight] Error modifying highlight: \(error)")
                        }
                    }
                }
            }

            // Clear selection
            textView?.selectedRange = NSRange(location: 0, length: 0)
        }

        /// Create a highlight for the given text range (auto-trims whitespace)
        private func createHighlightForSelection(_ range: NSRange) {
            print("[Highlight] Creating highlight for range: \(range), verseTextRanges count: \(verseTextRanges.count)")

            guard let text = textView?.text else { return }

            // Find which verse this selection is in
            for (verseRef, verseTextRange) in verseTextRanges {
                // Check if selection overlaps with this verse's text
                let selectionStart = range.location
                let selectionEnd = range.location + range.length
                let verseStart = verseTextRange.location
                let verseEnd = verseTextRange.location + verseTextRange.length

                // Check for overlap
                if selectionStart < verseEnd && selectionEnd > verseStart {
                    // Calculate character offsets within the verse text
                    var sc = max(0, selectionStart - verseStart)
                    var ec = min(verseTextRange.length, selectionEnd - verseStart)

                    // Auto-trim whitespace from selection
                    let verseTextStart = text.index(text.startIndex, offsetBy: verseStart)
                    let verseTextEnd = text.index(text.startIndex, offsetBy: min(verseEnd, text.count))
                    let verseText = String(text[verseTextStart..<verseTextEnd])

                    // Trim leading whitespace
                    while sc < ec {
                        let charIndex = verseText.index(verseText.startIndex, offsetBy: sc)
                        if verseText[charIndex].isWhitespace {
                            sc += 1
                        } else {
                            break
                        }
                    }

                    // Trim trailing whitespace
                    while ec > sc {
                        let charIndex = verseText.index(verseText.startIndex, offsetBy: ec - 1)
                        if verseText[charIndex].isWhitespace {
                            ec -= 1
                        } else {
                            break
                        }
                    }

                    if ec > sc {
                        print("[Highlight] Adding highlight to verse \(verseRef), sc: \(sc), ec: \(ec) (trimmed)")

                        // Check if highlights are hidden
                        if HighlightManager.shared.highlightsHidden {
                            // Check for overlapping highlights
                            let overlapping = HighlightManager.shared.getOverlappingHighlights(ref: verseRef, startChar: sc, endChar: ec)

                            if overlapping.isEmpty {
                                // No overlap - silently enable highlights and create
                                Task { @MainActor in
                                    HighlightManager.shared.highlightsHidden = false
                                    do {
                                        try HighlightManager.shared.addHighlight(ref: verseRef, startChar: sc, endChar: ec)
                                        print("[Highlight] Highlight added (auto-enabled visibility)")
                                    } catch {
                                        print("[Highlight] Error adding highlight: \(error)")
                                    }
                                }
                            } else {
                                // Has overlap - show dialog
                                showHighlightConflictDialog(verseRef: verseRef, sc: sc, ec: ec)
                            }
                        } else {
                            // Highlights visible - just add normally
                            Task { @MainActor in
                                do {
                                    try HighlightManager.shared.addHighlight(ref: verseRef, startChar: sc, endChar: ec)
                                    print("[Highlight] Highlight added successfully")
                                } catch {
                                    print("[Highlight] Error adding highlight: \(error)")
                                }
                            }
                        }

                        // Clear selection after highlighting
                        textView?.selectedRange = NSRange(location: 0, length: 0)
                        return // Only highlight once per selection
                    }
                }
            }
            print("[Highlight] No matching verse found for selection")
        }

        /// Show dialog when highlighting would overlap existing highlights while highlights are hidden
        private func showHighlightConflictDialog(verseRef: Int, sc: Int, ec: Int) {
            guard let viewController = textView?.window?.rootViewController else {
                print("[Highlight] No view controller found for alert")
                return
            }

            // Find the topmost presented controller
            var topController = viewController
            while let presented = topController.presentedViewController {
                topController = presented
            }

            let alert = UIAlertController(
                title: "Highlights Hidden",
                message: "This selection overlaps with existing highlights that are currently hidden.",
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: "Show Highlights", style: .default) { _ in
                Task { @MainActor in
                    HighlightManager.shared.highlightsHidden = false
                }
            })

            alert.addAction(UIAlertAction(title: "Modify Existing", style: .destructive) { _ in
                Task { @MainActor in
                    HighlightManager.shared.highlightsHidden = false
                    do {
                        try HighlightManager.shared.addHighlight(ref: verseRef, startChar: sc, endChar: ec)
                        print("[Highlight] Highlight added (overwrote existing)")
                    } catch {
                        print("[Highlight] Error adding highlight: \(error)")
                    }
                }
            })

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            topController.present(alert, animated: true)
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
    @ObservedObject private var highlightManager = HighlightManager.shared

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
    @State private var positionsVersion: Int = 0  // Incremented when positions are calculated
    @State private var scrollCleanupId: UUID = UUID() // To prevent race conditions in scroll cleanup
    @State private var scrollContainerId: UUID = UUID() // Forces ScrollView recreation when needed
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

    // Quiz state for plan mode
    @State private var quizModule: QuizModule? = nil
    @State private var quizQuestions: [QuizQuestion] = []
    @State private var showingQuizSheet: Bool = false

    let LOADING_NEXT_CHAPTER = "next_chapter"
    let LOADING_PREV_CHAPTER = "prev_chapter"
    let LOADING_NEXT_BOOK = "next_book"
    let LOADING_PREV_BOOK = "prev_book"
    let LOADING_CURRENT = "current"
    let LOADING_TRANSLATION = "translation"
    let LOADING_READING = "reading"
    let LOADING_HISTORY = "history"

    @State private var isHistoryNavigation: Bool = false

    // Pull-to-refresh progress (0.0 to 1.0+) for arrow scaling
    @State private var pullProgressTop: CGFloat = 0
    @State private var pullProgressBottom: CGFloat = 0
    // Track when bottom button should stick at top (scrolled above visible area)
    @State private var bottomButtonAboveViewport: Bool = false

    var onVerseAction: ((Int, VerseAction) -> Void)?

    // Initial verse to scroll to on load (handled internally with proper timing)
    private let initialVerseId: Int?
    @State private var hasAppliedInitialVerseId: Bool = false

    // Initial translation to use on load (overrides SceneStorage)
    private let initialTranslationId: String?
    @State private var hasAppliedInitialTranslationId: Bool = false

    // Horizontal split toolbar integration
    private let isHorizontalSplit: Bool
    @Binding private var toolPanelMode: ToolPanelMode
    private let toolDisplayName: String
    @Binding private var isScrollLinked: Bool
    @Binding private var toolFontSize: Int
    private let onHideToolPanel: (() -> Void)?
    private let onToggleSplitOrientation: (() -> Void)?
    private let notesModules: [Module]
    private let commentarySeries: [String]
    private let devotionalsModules: [Module]

    init(
        date: Binding<Date>,
        readingMetaData: [ReadingMetaData]? = nil,
        translationId: String? = nil,
        initialVerseId: Int? = nil,
        onVerseAction: ((Int, VerseAction) -> Void)? = nil,
        requestScrollToVerseId: Binding<Int?> = .constant(nil),
        requestScrollAnimated: Binding<Bool> = .constant(true),
        visibleVerseId: Binding<Int> = .constant(1001001),
        scrollOrigin: Binding<ScrollOrigin> = .constant(.none),
        toolbarsHidden: Binding<Bool> = .constant(false),
        initialToolbarMode: BottomToolbarMode? = nil,
        // Horizontal split toolbar integration
        isHorizontalSplit: Bool = false,
        toolPanelMode: Binding<ToolPanelMode> = .constant(.commentary),
        toolDisplayName: String = "",
        isScrollLinked: Binding<Bool> = .constant(true),
        toolFontSize: Binding<Int> = .constant(16),
        onHideToolPanel: (() -> Void)? = nil,
        onToggleSplitOrientation: (() -> Void)? = nil,
        notesModules: [Module] = [],
        commentarySeries: [String] = [],
        devotionalsModules: [Module] = []
    ) {
        self.isHorizontalSplit = isHorizontalSplit
        _toolPanelMode = toolPanelMode
        self.toolDisplayName = toolDisplayName
        _isScrollLinked = isScrollLinked
        _toolFontSize = toolFontSize
        self.onHideToolPanel = onHideToolPanel
        self.onToggleSplitOrientation = onToggleSplitOrientation
        self.notesModules = notesModules
        self.commentarySeries = commentarySeries
        self.devotionalsModules = devotionalsModules

        self.initialVerseId = initialVerseId
        self.initialTranslationId = translationId
        _date = date
        _readingMetaData = State(initialValue: readingMetaData)
        _requestedToolbarMode = State(initialValue: initialToolbarMode)
        _hasAppliedInitialMode = State(initialValue: false)

        // Load user settings
        let settings = UserDatabase.shared.getSettings()
        _userSettings = State(initialValue: settings)

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
            HStack(spacing: 4) {
                Text("\(translationAbbreviation) · \(book?.name ?? "") \(currentChapter)")
                // Show active tool in split-right view
                if isHorizontalSplit && !toolDisplayName.isEmpty {
                    Text("· \(toolDisplayName)")
                }
            }
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
                // Reload highlight sets for the new translation
                HighlightManager.shared.loadSetsForTranslation(newTranslationId)
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
            // Set pendingScrollVerseId - the onPositionsCalculated callback will
            // trigger the scroll when verse positions are ready
            pendingScrollVerseId = targetId
        } else if let firstVerse = verses.first {
            currentVerseId = firstVerse.ref
            pendingScrollVerseId = nil
        }

        // Record navigation in history (skip for reading plan and history navigation)
        if !isHistoryNavigation && loadingCase != LOADING_READING {
            NavigationHistory.shared.recordNavigation(to: currentVerseId, isHistoryNavigation: false)
        }

        // Load highlights for the new chapter
        let (_, newChapter, newBook) = splitVerseId(currentVerseId)
        HighlightManager.shared.loadHighlightsForChapter(book: newBook, chapter: newChapter)

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

    /// Check if there's a previous chapter available
    private func hasPreviousChapter(book: Int, chapter: Int) -> Bool {
        return !(book == 1 && chapter == 1)
    }

    /// Check if there's a next chapter available
    private func hasNextChapter(book: Int, chapter: Int) -> Bool {
        if book == 66 {
            let chapterCount = (try? TranslationDatabase.shared.getChapterCount(translationId: translationId, book: 66)) ?? 22
            return chapter < chapterCount
        }
        return true
    }

    /// Get the label for the previous chapter (e.g., "Genesis 49")
    private var previousChapterLabel: String? {
        guard let firstVerse = verses.first,
              hasPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter) else {
            return nil
        }
        let (prevBook, prevChapter) = getPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter)
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: prevBook))?.name ?? "Book \(prevBook)"
        return "\(bookName) \(prevChapter)"
    }

    /// Get the label for the next chapter (e.g., "Exodus 1")
    private var nextChapterLabel: String? {
        guard let firstVerse = verses.first,
              hasNextChapter(book: firstVerse.book, chapter: firstVerse.chapter) else {
            return nil
        }
        let (nextBook, nextChapter) = getNextChapter(book: firstVerse.book, chapter: firstVerse.chapter, translationId: translationId)
        let bookName = (try? BundledModuleDatabase.shared.getBook(id: nextBook))?.name ?? "Book \(nextBook)"
        return "\(bookName) \(nextChapter)"
    }

    /// Navigate to the previous chapter, scrolling to the end
    private func goToPreviousChapter() {
        // Reset pull progress immediately to hide sticky buttons
        pullProgressTop = 0
        pullProgressBottom = 0

        guard let firstVerse = verses.first else { return }
        let (prevBook, prevChapter) = getPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter)

        // Don't navigate if already at beginning
        if prevBook == firstVerse.book && prevChapter == firstVerse.chapter {
            return
        }

        // Get the last verse of the previous chapter to scroll there
        let lastVerseRef = (try? TranslationDatabase.shared.getLastVerseRef(translationId: translationId, book: prevBook, chapter: prevChapter)) ?? (prevBook * 1000000 + prevChapter * 1000 + 1)

        // Use LOADING_HISTORY with targetVerseId to scroll to the last verse
        animateScroll = false
        loadVerses(loadingCase: LOADING_HISTORY, targetVerseId: lastVerseRef)
    }

    /// Navigate to the next chapter, scrolling to the beginning
    private func goToNextChapter() {
        // Reset pull progress immediately to hide sticky buttons
        pullProgressTop = 0
        pullProgressBottom = 0

        // Simply load next chapter - it scrolls to first verse by default
        loadVerses(loadingCase: LOADING_NEXT_CHAPTER)
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
                            },
                            onPullToLoadPrevious: {
                                // Pull-to-refresh at top - load previous chapter
                                if readingMetaData == nil, let firstVerse = verses.first,
                                   hasPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter) {
                                    goToPreviousChapter()
                                }
                            },
                            onPullToLoadNext: {
                                // Pull-to-refresh at bottom - load next chapter
                                if readingMetaData == nil, let firstVerse = verses.first,
                                   hasNextChapter(book: firstVerse.book, chapter: firstVerse.chapter) {
                                    goToNextChapter()
                                }
                            },
                            onPullProgressTop: { progress in
                                pullProgressTop = progress
                            },
                            onPullProgressBottom: { progress in
                                pullProgressBottom = progress
                            }
                        )
                            .frame(width: 1, height: 1)

                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id("top")

                            // Previous chapter button (only show for non-plan readings)
                            if readingMetaData == nil, let firstVerse = verses.first,
                               hasPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter) {
                                ChapterNavigationButton(
                                    direction: .previous,
                                    progress: pullProgressTop,
                                    chapterLabel: previousChapterLabel,
                                    action: goToPreviousChapter
                                )
                                .padding(.bottom, 20)
                            }

                            ChapterTextView(
                                verses: Array(verses),
                                headings: headings,
                                fontSize: CGFloat(userSettings.readerFontSize),
                                lineSpacing: 12,
                                bookName: bookName,
                                chapter: chapterNumber,
                                showBookTitle: showBookTitle,
                                showStrongsHints: showStrongsHints,
                                highlightsByVerse: highlightManager.highlightsHidden ? [:] : highlightManager.highlightsByVerse,
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
                                onPositionsCalculated: { (_: [Int: CGFloat]) -> Void in
                                    // Signal that positions were calculated - onChange handler will check pendingScrollVerseId
                                    positionsVersion += 1
                                },
                                isUserScrolling: isScrolling
                            )
                            .id("chapter_\(chapterNumber)_\(translationId)")

                            // Quiz card - shown in plan mode when quiz questions exist for this reading
                            if toolbarMode == .plan, quizModule != nil, !quizQuestions.isEmpty {
                                QuizCardView(
                                    questionCount: quizQuestions.count,
                                    onStart: { showingQuizSheet = true }
                                )
                                .padding(.horizontal)
                                .padding(.top, 24)
                            }

                            // Next chapter button (inline, hidden when sticky overlay shows)
                            if readingMetaData == nil, let firstVerse = verses.first,
                               hasNextChapter(book: firstVerse.book, chapter: firstVerse.chapter) {
                                ChapterNavigationButton(
                                    direction: .next,
                                    progress: pullProgressBottom,
                                    chapterLabel: nextChapterLabel,
                                    action: goToNextChapter
                                )
                                .background(
                                    GeometryReader { buttonGeo in
                                        Color.clear.preference(
                                            key: BottomButtonMinYKey.self,
                                            value: buttonGeo.frame(in: .global).minY
                                        )
                                    }
                                )
                                .padding(.top, 16)
                                .opacity(bottomButtonAboveViewport || pullProgressBottom > 0 ? 0 : 1)
                            }

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
                    .task(id: scrollContainerId) {
                        isProgrammaticScroll = true
                        scrollDebouncer.cancel()
                        proxy.scrollTo("top", anchor: .top)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("top", anchor: .top)
                            if let scrollView = ScrollSyncCoordinator.shared.readerScrollView {
                                let topOffset = -scrollView.adjustedContentInset.top
                                scrollView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)
                            }

                            if pendingScrollVerseId == nil {
                                isProgrammaticScroll = false
                            }
                        }
                    }
                }
                .id(scrollContainerId)
                .onPreferenceChange(BottomButtonMinYKey.self) { minY in
                    // Button is above viewport if its top is above the safe area + space for content
                    let threshold = geometry.safeAreaInsets.top + 44
                    let isAbove = minY < threshold
                    if isAbove != bottomButtonAboveViewport {
                        bottomButtonAboveViewport = isAbove
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

                        // SwiftUI can preserve the previous relative offset while the new
                        // content tree lays out. Force a second reset on the underlying
                        // UIScrollView after layout settles.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("top", anchor: .top)
                            if let scrollView = ScrollSyncCoordinator.shared.readerScrollView {
                                let topOffset = -scrollView.adjustedContentInset.top
                                scrollView.setContentOffset(CGPoint(x: 0, y: topOffset), animated: false)
                            }

                            if pendingScrollVerseId == nil {
                                isProgrammaticScroll = false
                            }
                        }

                        // Fallback: use UIKit scroll after layout settles
                        if pendingScrollVerseId != nil {
                            Task { @MainActor in
                                // Wait for view to be added to window and laid out
                                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
                                await checkPendingScroll()
                            }
                        }
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
                .onChange(of: positionsVersion) {
                    // When positions are calculated, check if we have a pending scroll
                    guard let targetId = pendingScrollVerseId else { return }
                    let positions = positionTracker.positions

                    if let yPos = positions[targetId] {
                        // Exact match found
                        pendingScrollVerseId = nil
                        scrollTargetY = max(0, yPos + 1 - 20)
                    } else if !positions.isEmpty {
                        // No exact match - find closest verse at or before target
                        let targetVerse = targetId % 1000
                        let targetChapterPrefix = targetId / 1000 * 1000

                        // Look for verses in the same chapter
                        let chapterPositions = positions.filter { ($0.key / 1000 * 1000) == targetChapterPrefix }
                        if let closestEntry = chapterPositions
                            .filter({ ($0.key % 1000) <= targetVerse })
                            .max(by: { $0.key < $1.key }) {
                            pendingScrollVerseId = nil
                            scrollTargetY = max(0, closestEntry.value + 1 - 20)
                        }
                    }
                }
                } // ScrollViewReader

                // Sticky overlay for bottom button
                if readingMetaData == nil,
                   let firstVerse = verses.first,
                   hasNextChapter(book: firstVerse.book, chapter: firstVerse.chapter) {
                    if bottomButtonAboveViewport {
                        // Stick at top (below nav bar) when scrolled up past visible area
                        // Leave space at top for last line of content to show through
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 44)  // Space for content
                            ChapterNavigationButton(
                                direction: .next,
                                progress: pullProgressBottom,
                                chapterLabel: nextChapterLabel,
                                action: goToNextChapter
                            )
                            .background(Color(UIColor.systemBackground))
                            Spacer()
                        }
                    } else if pullProgressBottom > 0 {
                        // Stick at bottom during overscroll
                        VStack {
                            Spacer()
                            ChapterNavigationButton(
                                direction: .next,
                                progress: pullProgressBottom,
                                chapterLabel: nextChapterLabel,
                                action: goToNextChapter
                            )
                            .background(Color(UIColor.systemBackground))
                        }
                    }
                }
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
                    },
                    // Horizontal split integration
                    isHorizontalSplit: isHorizontalSplit,
                    toolPanelMode: $toolPanelMode,
                    toolDisplayName: toolDisplayName,
                    isScrollLinked: $isScrollLinked,
                    toolFontSize: $toolFontSize,
                    onHideToolPanel: onHideToolPanel,
                    onToggleSplitOrientation: onToggleSplitOrientation,
                    notesModules: notesModules,
                    commentarySeries: commentarySeries,
                    devotionalsModules: devotionalsModules
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
            .sheet(isPresented: $showingQuizSheet) {
                if let module = quizModule,
                   selectedPlanIndex >= 0,
                   selectedPlanIndex < plansWithReadings.count,
                   planReadingIndex >= 0,
                   planReadingIndex < plansWithReadings[selectedPlanIndex].readings.count {
                    let reading = plansWithReadings[selectedPlanIndex].readings[planReadingIndex]
                    let parts = reading.id.split(separator: "_")
                    let dayNum = parts.count >= 4 ? Int(parts[parts.count - 3]) ?? 0 : 0
                    QuizSheetView(
                        quizModule: module,
                        questions: quizQuestions,
                        day: dayNum,
                        sv: reading.sv,
                        ev: reading.ev,
                        readingDescription: reading.description
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            .toolbar(toolbarsHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(toolbarsHidden)
            .safeAreaInset(edge: .top) {
                // In horizontal split, parent (SplitReaderView) handles the full-width collapsed header
                if toolbarsHidden && !isHorizontalSplit {
                    collapsedHeader
                }
            }
        }
        .onAppear {
            // Validate currentVerseId - reset to Genesis 1:1 if invalid
            // Valid verse IDs are >= 1001001 (book 1, chapter 1, verse 1)
            if currentVerseId < 1001001 {
                currentVerseId = 1001001
            }

            // Initialize translation from user default if not already set in scene storage
            if translationId.isEmpty {
                translationId = userSettings.readerTranslationId
            }
            // Always update the display metadata to match the current translationId
            if let translation = try? TranslationDatabase.shared.getTranslation(id: translationId) {
                translationAbbreviation = translation.abbreviation
                translationName = translation.name
            }

            // Load highlight sets for this translation
            HighlightManager.shared.loadSetsForTranslation(translationId)

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

            // Handle initial translation (from deep links)
            if let initTranslation = initialTranslationId, !hasAppliedInitialTranslationId {
                hasAppliedInitialTranslationId = true
                translationId = initTranslation
                if let translation = try? TranslationDatabase.shared.getTranslation(id: initTranslation) {
                    translationAbbreviation = translation.abbreviation
                    translationName = translation.name
                }
            }

            // Handle initial verse navigation (from deep links)
            if let verseId = initialVerseId, !hasAppliedInitialVerseId {
                hasAppliedInitialVerseId = true

                // If in plan mode, find and load the matching reading
                if toolbarMode == .plan, !plansWithReadings.isEmpty {
                    for (planIdx, plan) in plansWithReadings.enumerated() {
                        if let readingIdx = plan.readings.firstIndex(where: { $0.sv == verseId }) {
                            selectedPlanIndex = planIdx
                            currentReadingIndex = readingIdx
                            loadPlanReading(at: readingIdx)
                            return
                        }
                    }
                }

                currentVerseId = verseId
                animateScroll = false
                loadVerses(loadingCase: LOADING_HISTORY, targetVerseId: verseId)
                return
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

    /// Checks for a pending scroll and performs it if positions are available
    @MainActor
    private func checkPendingScroll(retryCount: Int = 0) async {
        guard let targetId = pendingScrollVerseId else { return }

        let positions = positionTracker.positions

        // If positions aren't ready yet, wait and retry
        if positions.isEmpty && retryCount < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05s
            await checkPendingScroll(retryCount: retryCount + 1)
            return
        }

        // Update the coordinator with latest positions before trying to scroll
        if !positions.isEmpty {
            ScrollSyncCoordinator.shared.updateReaderVersePositions(positions)
        }

        // Try to scroll using the UIKit-based ScrollSyncCoordinator
        if ScrollSyncCoordinator.shared.scrollReaderToVerseId(targetId) {
            pendingScrollVerseId = nil
            return
        }

        // If scroll view not ready yet, retry
        if ScrollSyncCoordinator.shared.readerScrollView == nil && retryCount < 20 {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05s
            await checkPendingScroll(retryCount: retryCount + 1)
            return
        }

        // Final fallback - try SwiftUI scroll target
        if let yPos = positions[targetId] {
            pendingScrollVerseId = nil
            scrollTargetY = max(0, yPos + 1 - 20)
        } else {
            // Try to find closest verse
            let targetVerse = targetId % 1000
            let targetChapterPrefix = targetId / 1000 * 1000
            let chapterPositions = positions.filter { ($0.key / 1000 * 1000) == targetChapterPrefix }
            if let closestEntry = chapterPositions
                .filter({ ($0.key % 1000) <= targetVerse })
                .max(by: { $0.key < $1.key }) {
                pendingScrollVerseId = nil
                scrollTargetY = max(0, closestEntry.value + 1 - 20)
            }
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

        // Plan navigation swaps the content in-place, so clear any stale
        // positions and force the same scroll reset path used for chapter loads.
        positionTracker.positions = [:]
        scrollTargetY = nil
        pendingScrollVerseId = nil
        scrollContainerId = UUID()

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
            isLoading = true
        }

        loadQuizForCurrentReading()
    }

    /// Loads quiz questions for the current plan reading if a quiz module exists
    private func loadQuizForCurrentReading() {
        guard toolbarMode == .plan,
              selectedPlanIndex >= 0,
              selectedPlanIndex < plansWithReadings.count else {
            quizModule = nil
            quizQuestions = []
            return
        }

        let plan = plansWithReadings[selectedPlanIndex]
        let readings = plan.readings
        guard planReadingIndex >= 0, planReadingIndex < readings.count else {
            quizModule = nil
            quizQuestions = []
            return
        }
        let reading = readings[planReadingIndex]

        // Extract dayNum from reading.id format: "{planId}_{dayNum}_{readingIndex}_{year}"
        let parts = reading.id.split(separator: "_")
        guard parts.count >= 4, let dayNum = Int(parts[parts.count - 3]) else {
            quizModule = nil
            quizQuestions = []
            return
        }

        // Find quiz module for this plan (bundled first, then user)
        let module = (try? BundledModuleDatabase.shared.getQuizModulesForPlan(planId: plan.id))?.first
            ?? (try? ModuleDatabase.shared.getQuizModulesForPlan(planId: plan.id))?.first

        guard let module else {
            quizModule = nil
            quizQuestions = []
            return
        }

        quizModule = module
        let ageGroup = userSettings.defaultQuizAgeGroup
        quizQuestions = (try? BundledModuleDatabase.shared.getQuizQuestionsForReading(
            moduleId: module.id, day: dayNum, sv: reading.sv, ev: reading.ev, ageGroup: ageGroup
        )) ?? []
    }
}

// MARK: - Quiz Card View (inline after verses)

struct QuizCardView: View {
    let questionCount: Int
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiz Available")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("\(questionCount) question\(questionCount == 1 ? "" : "s") about this reading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quiz Sheet View

struct QuizSheetView: View {
    let quizModule: QuizModule
    let day: Int
    let sv: Int
    let ev: Int
    let readingDescription: String
    @State var questions: [QuizQuestion]
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var showAnswer: Bool = false
    @State private var selectedAgeGroup: String
    @State private var previewState: PreviewSheetState? = nil
    @AppStorage("quizContextAmount") private var contextAmount: SearchContextAmount = .oneVerse

    init(quizModule: QuizModule, questions: [QuizQuestion], day: Int, sv: Int, ev: Int, readingDescription: String) {
        self.quizModule = quizModule
        self.day = day
        self.sv = sv
        self.ev = ev
        self.readingDescription = readingDescription
        self._questions = State(initialValue: questions)
        let settings = UserDatabase.shared.getSettings()
        self._selectedAgeGroup = State(initialValue: settings.defaultQuizAgeGroup)
    }

    private var currentQuestion: QuizQuestion? {
        guard currentIndex >= 0, currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Age group picker
                if quizModule.ageGroups.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quizModule.ageGroups) { group in
                                Button {
                                    selectedAgeGroup = group.id
                                    saveAgeGroupPreference(group.id)
                                    reloadQuestions()
                                } label: {
                                    Text(group.label)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedAgeGroup == group.id ? Color.accentColor : Color.secondary.opacity(0.15))
                                        .foregroundStyle(selectedAgeGroup == group.id ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 10)

                    Divider()
                }

                if questions.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.circle")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("No questions available")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Try selecting a different age group")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                } else if let question = currentQuestion {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Progress
                            HStack {
                                Text("Question \(currentIndex + 1) of \(questions.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                // Theme badge
                                if let theme = question.themeEnum {
                                    Text(theme.rawValue.capitalized)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }


                            }

                            // Question text with tappable references
                            quizAnnotatedText(for: question.questionJson)

                            // Answer
                            if showAnswer {
                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Answer")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    quizAnnotatedText(for: question.answerJson)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            } else {
                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        showAnswer = true
                                    }
                                } label: {
                                    Text("Show Answer")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.accentColor.opacity(0.12))
                                        .foregroundStyle(.accent)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding()
                    }

                    // Navigation
                    Divider()
                    HStack {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(currentIndex == 0 ? .tertiary : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if currentIndex > 0 { goToQuestion(currentIndex - 1) }
                            }

                        Spacer()

                        // Progress dots
                        HStack(spacing: 6) {
                            ForEach(0..<questions.count, id: \.self) { i in
                                Circle()
                                    .fill(i == currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                                    .frame(width: 7, height: 7)
                            }
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundStyle(currentIndex == questions.count - 1 ? .tertiary : .primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if currentIndex < questions.count - 1 { goToQuestion(currentIndex + 1) }
                            }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Quiz: \(readingDescription)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Menu {
                            Picker("Context", selection: $contextAmount) {
                                ForEach(SearchContextAmount.allCases, id: \.self) { amount in
                                    Text(amount.label).tag(amount)
                                }
                            }
                        } label: {
                            Label("Preview Context", systemImage: "rectangle.expand.vertical")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(item: $previewState) { _ in
                PreviewSheet(
                    state: $previewState,
                    translationId: UserDatabase.shared.getSettings().readerTranslationId,
                    contextAmount: contextAmount
                )
            }
        }
    }

    // MARK: - Annotated Text Rendering

    @ViewBuilder
    private func quizAnnotatedText(for json: String) -> some View {
        let parsed = parseQuizAnnotatedText(json)
        let attrString = buildQuizAttributedString(from: parsed)
        Text(attrString)
            .font(.body)
            .environment(\.openURL, OpenURLAction { url in
                handleQuizURL(url, annotatedText: parsed)
                return .handled
            })
    }

    /// Build a SwiftUI AttributedString with tappable links for scripture annotations
    private func buildQuizAttributedString(from annotatedText: AnnotatedText) -> AttributedString {
        var result = AttributedString(annotatedText.text)
        guard let annotations = annotatedText.annotations else { return result }

        let text = annotatedText.text
        for annotation in annotations {
            guard annotation.start >= 0, annotation.end <= text.count, annotation.start < annotation.end else { continue }

            let startIdx = text.index(text.startIndex, offsetBy: annotation.start)
            let endIdx = text.index(text.startIndex, offsetBy: annotation.end)
            let attrStart = AttributedString.Index(startIdx, within: result)
            let attrEnd = AttributedString.Index(endIdx, within: result)
            guard let attrStart, let attrEnd else { continue }
            let range = attrStart..<attrEnd

            if annotation.type == .scripture || annotation.type == .crossref,
               let sv = annotation.data?.sv {
                let ev = annotation.data?.ev ?? sv
                result[range].link = URL(string: "lampbible://quiz-ref/\(sv)/\(ev)")
                result[range].foregroundColor = .blue
            }
        }

        return result
    }

    /// Handle tapped scripture reference URL from quiz text
    private func handleQuizURL(_ url: URL, annotatedText: AnnotatedText) {
        guard url.scheme == "lampbible", url.host == "quiz-ref" else { return }
        let parts = url.pathComponents.compactMap { Int($0) }
        guard parts.count >= 2 else { return }
        let tappedSv = parts[0]
        let tappedEv = parts[1]

        // Build all verse PreviewItems from this annotated text for prev/next navigation
        let annotations = annotatedText.annotations ?? []
        var previewItems: [PreviewItem] = []
        var tappedItem: PreviewItem? = nil
        let text = annotatedText.text

        for (i, annotation) in annotations.enumerated() {
            if (annotation.type == .scripture || annotation.type == .crossref),
               let sv = annotation.data?.sv {
                let ev = annotation.data?.ev ?? sv
                let displayText: String
                if annotation.start >= 0, annotation.end <= text.count, annotation.start < annotation.end {
                    let s = text.index(text.startIndex, offsetBy: annotation.start)
                    let e = text.index(text.startIndex, offsetBy: annotation.end)
                    displayText = String(text[s..<e])
                } else {
                    displayText = ""
                }
                let item = PreviewItem.verse(index: i, verseId: sv, endVerseId: ev != sv ? ev : nil, displayText: displayText)
                previewItems.append(item)
                if sv == tappedSv && ev == tappedEv {
                    tappedItem = item
                }
            }
        }

        if let tappedItem {
            previewState = PreviewSheetState(currentItem: tappedItem, allItems: previewItems)
        }
    }

    // MARK: - Navigation & Data

    private func goToQuestion(_ index: Int) {
        guard index >= 0, index < questions.count else { return }
        showAnswer = false
        currentIndex = index
    }

    private func saveAgeGroupPreference(_ ageGroup: String) {
        try? UserDatabase.shared.updateSettings { settings in
            settings.defaultQuizAgeGroup = ageGroup
        }
    }

    private func reloadQuestions() {
        questions = (try? BundledModuleDatabase.shared.getQuizQuestionsForReading(
            moduleId: quizModule.id, day: day, sv: sv, ev: ev, ageGroup: selectedAgeGroup
        )) ?? []
        currentIndex = 0
        showAnswer = false
    }

    /// Parse quiz text JSON into AnnotatedText — handles plain strings and annotated text objects.
    /// Normalizes crossref annotations to scripture so the renderer makes them tappable.
    private func parseQuizAnnotatedText(_ json: String) -> AnnotatedText {
        guard let data = json.data(using: .utf8) else {
            return AnnotatedText(text: json)
        }

        // Try as AnnotatedText (object with "text" and "annotations" keys)
        if var annotated = try? JSONDecoder().decode(AnnotatedText.self, from: data) {
            // Normalize crossref → scripture so the renderer treats them as tappable verse refs
            annotated.annotations = annotated.annotations?.map { annotation in
                if annotation.type == .crossref, annotation.data?.sv != nil {
                    var normalized = annotation
                    normalized.type = .scripture
                    return normalized
                }
                return annotation
            }
            return annotated
        }

        // Try as plain JSON string
        if let plainString = try? JSONDecoder().decode(String.self, from: data) {
            return AnnotatedText(text: plainString)
        }

        // Fallback: raw string
        return AnnotatedText(text: json)
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
