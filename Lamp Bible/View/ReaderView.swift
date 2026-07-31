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
    /// Destination shown when the threshold is reached — a chapter ("Genesis 49")
    /// or, in plan mode, a reading ("Genesis 1-2")
    let label: String?
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
                if isThresholdReached, let label {
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
    /// Verse currently being read aloud, highlighted so you can follow along.
    /// Deliberately absent from `buildKey()` — see `applySpokenVerse`.
    var spokenVerseId: Int? = nil

    // Debug/perf toggle: render as simplified plain text to isolate TextKit/interaction overhead.
    // Enable by setting: UserDefaults.standard.set(true, forKey: "readerSimplifiedText")
    private var isSimplifiedText: Bool {
        UserDefaults.standard.bool(forKey: "readerSimplifiedText")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Move the read-aloud cursor. Cheap by design: it repositions one sibling view
    /// in the gutter, leaving the attributed string and verse positions untouched,
    /// so advancing a verse costs nothing near the text rendering path.
    private func applySpokenVerse(_ textView: UITextView, coordinator: Coordinator, afterRebuild: Bool) {
        // A rebuild replaces the ranges the cursor was resolved against, and a width
        // change moves the gutter, so re-resolve on both even if the verse hasn't
        // moved.
        let width = textView.bounds.width
        guard afterRebuild
                || coordinator.appliedSpokenVerseId != spokenVerseId
                || coordinator.appliedSpokenIndicatorWidth != width else { return }
        coordinator.appliedSpokenVerseId = spokenVerseId
        coordinator.appliedSpokenIndicatorWidth = width

        coordinator.updateSpokenVerseCursor(verseId: spokenVerseId, animated: !afterRebuild)
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
        let didRebuild = context.coordinator.lastBuildKey != effectiveKey
        if didRebuild {
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

        applySpokenVerse(textView, coordinator: context.coordinator, afterRebuild: didRebuild)

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
        var appliedSpokenVerseId: Int?
        var appliedSpokenIndicatorWidth: CGFloat = 0

        /// Cursor in the left gutter marking the verse being read aloud.
        ///
        /// A sibling view rather than a text attribute or a custom draw pass: it
        /// can't disturb text layout or the user's own highlights, and it can slide
        /// from one verse to the next.
        private var spokenCursor: UIView?

        func updateSpokenVerseCursor(verseId: Int?, animated: Bool) {
            guard let textView else { return }

            guard let verseId,
                  let range = verseTextRanges[verseId],
                  range.location + range.length <= textView.attributedText.length,
                  let layoutManager = textView.layoutManager as? CompactBackgroundLayoutManager
            else {
                hideSpokenCursor()
                return
            }

            let container = textView.textContainer
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var verseRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            guard !verseRect.isNull, verseRect.height > 0 else {
                hideSpokenCursor()
                return
            }

            verseRect.origin.y += textView.textContainerInset.top
            // The bounding rect carries the line spacing added below the final line;
            // drop it so the cursor spans the verse's visible height.
            if layoutManager.lineSpacingTrim > 0, verseRect.height > layoutManager.lineSpacingTrim {
                verseRect.size.height -= layoutManager.lineSpacingTrim * 0.66
            }

            let cursorWidth: CGFloat = 4
            // Sit in the left gutter, 4pt clear of the text's leading edge.
            let gutter = textView.textContainerInset.left
            let frame = CGRect(
                x: max(0, gutter - 4 - cursorWidth),
                y: verseRect.minY,
                width: cursorWidth,
                height: verseRect.height
            )

            let cursor = spokenCursor ?? makeSpokenCursor(in: textView, width: cursorWidth)
            cursor.backgroundColor = .label

            if cursor.isHidden || !animated {
                cursor.frame = frame
                if cursor.isHidden {
                    cursor.isHidden = false
                    cursor.alpha = 0
                    UIView.animate(withDuration: 0.15) { cursor.alpha = 1 }
                }
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState]
                ) {
                    cursor.frame = frame
                }
            }
        }

        private func makeSpokenCursor(in textView: UITextView, width: CGFloat) -> UIView {
            let cursor = UIView()
            cursor.layer.cornerRadius = width / 2
            cursor.isUserInteractionEnabled = false
            cursor.isHidden = true
            textView.addSubview(cursor)
            spokenCursor = cursor
            return cursor
        }

        private func hideSpokenCursor() {
            guard let cursor = spokenCursor, !cursor.isHidden else { return }
            UIView.animate(withDuration: 0.15, animations: {
                cursor.alpha = 0
            }, completion: { _ in
                cursor.isHidden = true
            })
        }

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
                UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                    guard let self = self else { return }
                    HighlightManager.shared.highlightEntireVerse(verse.ref)
                },
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

/// Everything that changes the words read-aloud would speak. Scroll position,
/// pull progress and highlight changes deliberately aren't in here.
private struct PlanSpeechInputs: Equatable {
    let readingId: String
    let readingDescription: String
    let translationId: String
    let firstRef: Int
    let lastRef: Int
    let verseCount: Int

    var speechId: String {
        "plan-reading-\(readingId)-\(translationId)-\(firstRef)-\(lastRef)-\(verseCount)"
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

    // Read aloud state for plan mode
    @State private var planSpeech = TextSpeechController()
    @State private var planSpeechRequest: TextSpeechRequest?
    @State private var planSpeechUnavailableMessage: String?
    @State private var showingSpeechTransport = false
    /// Scroll-driven toolbar collapse, distinct from the tap-driven `toolbarsHidden`
    /// immersive mode — this one leaves the status bar alone. A binding so split
    /// view can share it with the tool panel and collapse both headers together.
    @Binding var toolbarsCollapsed: Bool
    @AppStorage("readAloudFollowsText") private var readAloudFollowsText: Bool = true

    // Theme editing state
    @State private var themeEditColor: HighlightColor?
    @State private var themeEditStyle: HighlightStyle = .highlight
    @State private var themeEditExisting: HighlightTheme?
    @State private var showingThemeEditor: Bool = false
    @State private var pendingThemeEdit: Bool = false

    let LOADING_NEXT_CHAPTER = "next_chapter"
    let LOADING_PREV_CHAPTER = "prev_chapter"
    let LOADING_NEXT_BOOK = "next_book"
    let LOADING_PREV_BOOK = "prev_book"
    let LOADING_CURRENT = "current"
    let LOADING_TRANSLATION = "translation"
    let LOADING_READING = "reading"
    let LOADING_HISTORY = "history"

    @State private var isHistoryNavigation: Bool = false
    /// Incremented per load so a slow background read can't clobber a newer one
    @State private var loadGeneration: Int = 0
    /// True while a background content read is in flight. Scroll position is
    /// meaningless against soon-to-be-replaced content, so verse commits and the
    /// scroll spy stay suppressed until the new content lands.
    @State private var isFetchingContent: Bool = false

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
        toolbarsCollapsed: Binding<Bool> = .constant(false),
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
        _toolbarsCollapsed = toolbarsCollapsed
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
                .font(.caption)
                .foregroundStyle(.primary)
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
                toolbarsCollapsed = false
            }
        }
    }

    /// What to read for a given navigation. Resolving this is cheap; running it
    /// is not, so the read happens off the main thread.
    private enum VerseFetch {
        case chapter(translationId: String, book: Int, chapter: Int)
        case range(translationId: String, startRef: Int, endRef: Int)

        func run() throws -> (verses: [TranslationVerse], headings: [TranslationHeading]) {
            switch self {
            case let .chapter(translationId, book, chapter):
                let content = try TranslationDatabase.shared.getChapter(
                    translationId: translationId, book: book, chapter: chapter
                )
                return (content.verses, content.headings)
            case let .range(translationId, startRef, endRef):
                let verses = try TranslationDatabase.shared.getVerseRange(
                    translationId: translationId, startRef: startRef, endRef: endRef
                )
                return (verses, [])  // No headings for verse ranges
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

        // Resolve what to read. These are cheap metadata lookups; the verse text
        // itself is fetched on a background queue below.
        var fetch: VerseFetch?

        switch loadingCase {
        case LOADING_PREV_CHAPTER:
            let (newBook, newChapter) = getPreviousChapter(book: currentBook, chapter: currentChapter)
            fetch = .chapter(translationId: translationId, book: newBook, chapter: newChapter)

        case LOADING_NEXT_CHAPTER:
            let (newBook, newChapter) = getNextChapter(book: currentBook, chapter: currentChapter, translationId: translationId)
            fetch = .chapter(translationId: translationId, book: newBook, chapter: newChapter)

        case LOADING_PREV_BOOK:
            fetch = .chapter(translationId: translationId, book: max(1, currentBook - 1), chapter: 1)

        case LOADING_NEXT_BOOK:
            fetch = .chapter(translationId: translationId, book: min(66, currentBook + 1), chapter: 1)

        case LOADING_READING:
            // The index can outrun the readings when a plan or date changes
            if let readings = readingMetaData, readings.indices.contains(currentReadingIndex) {
                let reading = readings[currentReadingIndex]
                fetch = .range(translationId: translationId, startRef: reading.sv, endRef: reading.ev)
            }

        case LOADING_HISTORY:
            if let targetId = targetVerseId {
                let (_, targetChapter, targetBook) = splitVerseId(targetId)
                fetch = .chapter(translationId: translationId, book: targetBook, chapter: targetChapter)
            }

        case LOADING_CURRENT:
            fetch = .chapter(translationId: translationId, book: currentBook, chapter: currentChapter)

        case LOADING_TRANSLATION:
            // Use explicitly passed translation ID, or fall back to current translation
            let newTranslationId = forTranslationId ?? translationId
            translationId = newTranslationId
            // Reload highlight sets for the new translation
            HighlightManager.shared.loadSetsForTranslation(newTranslationId)
            fetch = .chapter(translationId: newTranslationId, book: currentBook, chapter: currentChapter)

        default:
            break
        }

        // Bump the generation so a slower earlier load can't overwrite this one
        loadGeneration &+= 1
        let generation = loadGeneration

        guard let fetch else {
            // LOADING_HISTORY without a target, or an unknown case: the original
            // behaviour left the existing verses in place. The generation bump
            // above already superseded any in-flight read, so release the flag
            // here — nothing else will.
            isFetchingContent = false
            applyLoadedVerses(nil, loadingCase: loadingCase, targetVerseId: targetVerseId)
            return
        }

        isFetchingContent = true

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: (verses: [TranslationVerse], headings: [TranslationHeading])
            do {
                loaded = try fetch.run()
            } catch {
                print("ReaderView: Error loading verses: \(error)")
                loaded = ([], [])
            }

            DispatchQueue.main.async {
                // A newer load owns the flag, so leave it set when superseded
                guard generation == loadGeneration else { return }
                isFetchingContent = false
                applyLoadedVerses(loaded, loadingCase: loadingCase, targetVerseId: targetVerseId)
            }
        }
    }

    /// Main-thread tail of `loadVerses`: publish the content and run the
    /// navigation side effects in the same order as before.
    private func applyLoadedVerses(
        _ loaded: (verses: [TranslationVerse], headings: [TranslationHeading])?,
        loadingCase: String,
        targetVerseId: Int?
    ) {
        if let loaded {
            verses = loaded.verses
            headings = loaded.headings
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

    // MARK: - Scroll-Trigger Navigation

    /// True when the reader is showing a plan's readings rather than free chapters.
    private var isPlanReadingMode: Bool {
        toolbarMode == .plan && plansWithReadings.indices.contains(selectedPlanIndex)
    }

    /// Readings of the currently selected plan, empty outside plan mode.
    private var currentPlanReadings: [ReadingMetaData] {
        guard isPlanReadingMode else { return [] }
        return plansWithReadings[selectedPlanIndex].readings
    }

    private var currentPlanReading: ReadingMetaData? {
        guard isPlanReadingMode,
              currentPlanReadings.indices.contains(planReadingIndex) else { return nil }
        return currentPlanReadings[planReadingIndex]
    }

    /// Identity of the passage read-aloud speaks. Cheap enough for the body to
    /// compute every pass; the spoken text itself is not — see
    /// `rebuildPlanSpeechRequest`.
    private var planSpeechInputs: PlanSpeechInputs? {
        guard toolbarMode == .plan, let reading = currentPlanReading, !verses.isEmpty else { return nil }
        return PlanSpeechInputs(
            readingId: reading.id,
            readingDescription: reading.description,
            translationId: translationId,
            firstRef: verses.first?.ref ?? 0,
            lastRef: verses.last?.ref ?? 0,
            verseCount: verses.count
        )
    }

    /// Rebuild the spoken text off the main thread whenever the passage changes.
    ///
    /// This walks every verse and queries the bundled database for book names, so
    /// it can't live in a computed property the body reads: scrolling updates
    /// `pullProgressTop`, which would rebuild the entire reading twice per frame.
    private func rebuildPlanSpeechRequest(for inputs: PlanSpeechInputs?) {
        guard let inputs else {
            // Never leave audio running for a passage that's gone — the transport is
            // keyed to the request and would vanish with it.
            planSpeech.stop()
            planSpeechRequest = nil
            return
        }

        let verses = self.verses
        let wpm = userSettings.planWpm
        DispatchQueue.global(qos: .userInitiated).async {
            let segments = ReaderSpeechTextBuilder.planReadingSegments(
                readingDescription: inputs.readingDescription,
                verses: verses
            )
            let translation = try? TranslationDatabase.shared.getTranslation(id: inputs.translationId)
            let language = translation?.language
            let hasVoice = SpeechVoiceCatalog.hasVoice(for: language)
            let request = TextSpeechRequest(
                id: inputs.speechId,
                title: inputs.readingDescription,
                // The translation, not the plan: which words are being read matters
                // here, and the plan name is already on the reader's bottom bar.
                subtitle: translation?.abbreviation,
                segments: segments,
                languageCode: language,
                wordsPerMinute: wpm
            )
            DispatchQueue.main.async {
                // Drop the result if a newer passage has superseded this one
                guard inputs == planSpeechInputs else { return }
                guard !request.isEmpty else {
                    planSpeechRequest = nil
                    planSpeechUnavailableMessage = nil
                    return
                }
                guard hasVoice else {
                    // Better to say why than to read Greek with an English voice.
                    planSpeechRequest = nil
                    planSpeechUnavailableMessage = Self.noVoiceMessage(for: language)
                    return
                }
                planSpeechRequest = request
                planSpeechUnavailableMessage = nil
            }
        }
    }

    /// Verse to highlight as read-aloud speaks it, scoped to the request actually
    /// playing so a stale controller state can't light up the wrong verse.
    private var spokenVerseId: Int? {
        guard let planSpeechRequest, planSpeech.isActive(for: planSpeechRequest.id) else { return nil }
        return planSpeech.currentVerseId
    }

    /// Clearance from the bottom of the window to the top of the floating bottom
    /// bar. The bar is drawn by the navigation controller outside SwiftUI's safe
    /// area accounting — a `GeometryReader` here reports a bottom inset of zero —
    /// so the lift has to be stated rather than derived. Measured against the
    /// standard bottom bar; a taller one would need this raised.
    private static let bottomBarClearance: CGFloat = 94

    /// How much of the passage the floating bottom bar covers. Measured from the
    /// view hierarchy: its container runs from y=788 to the bottom of an 874pt
    /// window. Unlike the navigation bar it contributes nothing to
    /// `adjustedContentInset`, so nothing can derive this.
    private static let bottomBarObscuredHeight: CGFloat = 86

    /// Drops the button onto the row the bottom bar occupied, so collapsing moves
    /// it into the vacated space rather than leaving it hovering mid-page.
    /// Measured from the same layout as `bottomBarClearance`.
    private static let collapsedBarClearance: CGFloat = 36

    /// Kept out of the reader's body expression, which is already at the
    /// type-checker's limit — inlining even this much tips it over.
    @ViewBuilder
    private var floatingSpeechButton: some View {
        if isPlanSpeechActive {
            GeometryReader { proxy in
                SpeechFloatingButton(
                    controller: planSpeech,
                    onOpenTransport: { showingSpeechTransport = true }
                )
                // Measured from the window's bottom edge, deliberately ignoring
                // `safeAreaInsets.bottom`. This overlay spans the raw window and
                // reports a zero bottom inset while the bar is up, but once the bar
                // goes the home indicator becomes that inset — so including it made
                // the button drop on our animation and then hop back up on
                // SwiftUI's, which read as an overshoot. Both clearances already
                // account for the safe area.
                .position(
                    x: proxy.size.width / 2,
                    y: proxy.size.height - SpeechFloatingButton.diameter / 2
                        - (toolbarsHidden || toolbarsCollapsed
                           ? Self.collapsedBarClearance
                           : Self.bottomBarClearance)
                )
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Whether this reading is the one being spoken — gates the floating transport
    /// so it can't linger over a passage the audio has moved on from.
    private var isPlanSpeechActive: Bool {
        guard let planSpeechRequest else { return false }
        return planSpeech.isActive(for: planSpeechRequest.id)
    }

    /// Keep the spoken verse on screen without fighting the reader: stay out of the
    /// way while they're scrolling, and only move when the verse has actually left
    /// the viewport.
    private func followSpokenVerse(_ verseId: Int) {
        guard readAloudFollowsText, !isScrolling, !isProgrammaticScroll else { return }
        guard let y = positionTracker.positions[verseId] else { return }
        guard let scrollView = ScrollSyncCoordinator.shared.readerScrollView else { return }

        // The top bar is in `adjustedContentInset` (116pt, measured), but the
        // bottom bar floats over the content and contributes nothing to it — a
        // verse can sit well inside the scroll view's insets and still be entirely
        // hidden behind it. Its height has to be stated, and drops to zero once
        // the bar is collapsed.
        let bottomObscured = (toolbarsHidden || toolbarsCollapsed)
            ? scrollView.adjustedContentInset.bottom
            : max(scrollView.adjustedContentInset.bottom, Self.bottomBarObscuredHeight)

        let visibleTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - bottomObscured

        // The whole verse has to be visible, not just the point it starts at.
        // Testing the start alone leaves a verse that begins just above the bottom
        // edge sitting there with its body off-screen, which is the state this is
        // supposed to prevent. The next verse's start is where this one ends.
        let verseTop = y
        let verseBottom = positionTracker.positions.values.filter { $0 > y }.min()

        let trigger: CGFloat = 24
        let needsScroll: Bool
        if let verseBottom, verseBottom - verseTop < visibleBottom - visibleTop {
            needsScroll = verseTop < visibleTop + trigger || verseBottom > visibleBottom - trigger
        } else {
            // Taller than the viewport, or the last verse with nothing after it to
            // measure against: keeping its start in view is the best available.
            needsScroll = verseTop < visibleTop + trigger || verseTop > visibleBottom - trigger
        }
        guard needsScroll else { return }

        animateScroll = true
        // `scrollTo(anchor: .top)` lands at the safe-area top, which already
        // accounts for the navigation bar; this is the reading lead below it.
        scrollTargetY = max(0, y - 80)
    }

    static func noVoiceMessage(for languageCode: String?) -> String {
        let howToFix = "Add one in Settings › Accessibility › Spoken Content › Voices."
        guard let language = SpeechVoiceCatalog.languageName(for: languageCode) else {
            return "No speech voice is installed for this text. \(howToFix)"
        }
        return "No \(language) voice is installed, so this can't be read aloud. \(howToFix)"
    }

    /// Where the top/bottom scroll affordance goes. In plan mode it steps through
    /// the selected plan's readings; otherwise through chapters. `nil` means
    /// there's nowhere to go and the affordance is hidden.
    private struct ReaderNavTarget {
        let label: String?
        let action: () -> Void
    }

    private var previousNavTarget: ReaderNavTarget? {
        if isPlanReadingMode {
            // Deliberately not gated on loaded verses: if a reading fails to load,
            // navigation has to stay available or there's no way out.
            let target = planReadingIndex - 1
            guard currentPlanReadings.indices.contains(target) else { return nil }
            return ReaderNavTarget(
                label: currentPlanReadings[target].description,
                // Mirrors chapter navigation: pulling back lands at the end of
                // the previous unit, not its start.
                action: { goToPlanReading(at: target, scrollToEnd: true) }
            )
        }
        guard readingMetaData == nil, let firstVerse = verses.first,
              hasPreviousChapter(book: firstVerse.book, chapter: firstVerse.chapter) else {
            return nil
        }
        return ReaderNavTarget(label: previousChapterLabel, action: goToPreviousChapter)
    }

    private var nextNavTarget: ReaderNavTarget? {
        if isPlanReadingMode {
            let target = planReadingIndex + 1
            guard currentPlanReadings.indices.contains(target) else { return nil }
            return ReaderNavTarget(
                label: currentPlanReadings[target].description,
                action: { goToPlanReading(at: target, scrollToEnd: false) }
            )
        }
        guard readingMetaData == nil, let firstVerse = verses.first,
              hasNextChapter(book: firstVerse.book, chapter: firstVerse.chapter) else {
            return nil
        }
        return ReaderNavTarget(label: nextChapterLabel, action: goToNextChapter)
    }

    /// True when the verse already belongs to the plan reading on screen, meaning
    /// it's part of the loaded content and needs no fetch.
    private func isWithinCurrentPlanReading(_ verseId: Int) -> Bool {
        guard isPlanReadingMode,
              currentPlanReadings.indices.contains(planReadingIndex) else { return false }
        let reading = currentPlanReadings[planReadingIndex]
        return verseId >= reading.sv && verseId <= reading.ev
    }

    /// Plan-mode counterpart to `goToPreviousChapter` / `goToNextChapter`.
    private func goToPlanReading(at index: Int, scrollToEnd: Bool) {
        // Reset pull progress immediately to hide sticky buttons
        pullProgressTop = 0
        pullProgressBottom = 0

        animateScroll = false
        loadPlanReading(at: index, scrollToEnd: scrollToEnd)
    }

    private func openQuizSheet() {
        planSpeech.stop()
        showingQuizSheet = true
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
                                // Pull at top - previous reading in plan mode, else previous chapter
                                previousNavTarget?.action()
                            },
                            onPullToLoadNext: {
                                // Pull at bottom - next reading in plan mode, else next chapter
                                nextNavTarget?.action()
                            },
                            onPullProgressTop: { progress in
                                pullProgressTop = progress
                            },
                            onPullProgressBottom: { progress in
                                pullProgressBottom = progress
                            },
                            onToolbarCollapseChange: { collapsed in
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    toolbarsCollapsed = collapsed
                                }
                            },
                            toolbarsCollapsed: toolbarsCollapsed
                        )
                            .frame(width: 1, height: 1)

                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id("top")

                            // Previous button - previous reading in plan mode, else previous chapter
                            if let previousNavTarget {
                                ChapterNavigationButton(
                                    direction: .previous,
                                    progress: pullProgressTop,
                                    label: previousNavTarget.label,
                                    action: previousNavTarget.action
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
                                isUserScrolling: isScrolling,
                                spokenVerseId: spokenVerseId
                            )
                            .id("chapter_\(chapterNumber)_\(translationId)")

                            // Quiz card - shown in plan mode when quiz questions exist for this reading
                            if toolbarMode == .plan, quizModule != nil, !quizQuestions.isEmpty {
                                QuizCardView(
                                    questionCount: quizQuestions.count,
                                    onStart: openQuizSheet
                                )
                                .padding(.horizontal)
                                .padding(.top, 24)
                            }

                            // Next button (inline, hidden when sticky overlay shows)
                            if let nextNavTarget {
                                ChapterNavigationButton(
                                    direction: .next,
                                    progress: pullProgressBottom,
                                    label: nextNavTarget.label,
                                    action: nextNavTarget.action
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

                            if pendingScrollVerseId == nil && !isFetchingContent {
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

                            if pendingScrollVerseId == nil && !isFetchingContent {
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
                        // Check if target is in a different chapter. A plan reading
                        // can span chapters and already has those verses loaded, so
                        // a target inside it must scroll rather than reload —
                        // reloading swaps the reading for a single chapter and
                        // leaves the bottom toolbar pointing at the old reading.
                        if !isWithinCurrentPlanReading(verseId),
                           targetBook != currentBk || targetChapter != currentCh {
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
                if let nextNavTarget {
                    if bottomButtonAboveViewport {
                        // Stick at top (below nav bar) when scrolled up past visible area
                        // Leave space at top for last line of content to show through
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 44)  // Space for content
                            ChapterNavigationButton(
                                direction: .next,
                                progress: pullProgressBottom,
                                label: nextNavTarget.label,
                                action: nextNavTarget.action
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
                                label: nextNavTarget.label,
                                action: nextNavTarget.action
                            )
                            .background(Color(UIColor.systemBackground))
                        }
                    }
                }
            } // GeometryReader
            .overlay { floatingSpeechButton }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPlanSpeechActive)
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
                    },
                    onQuiz: quizModule != nil ? {
                        openQuizSheet()
                    } : nil
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
                    devotionalsModules: devotionalsModules,
                    onEditTheme: { color, style, existing in
                        themeEditColor = color
                        themeEditStyle = style
                        themeEditExisting = existing
                        pendingThemeEdit = true
                    }
                )
            }
            .toolbar {
                // Same placement and glyph as the quiz sheet's control, so the two
                // read-aloud surfaces look like one feature. Present for the whole of
                // plan mode — disabled while the text is still building — so the
                // ellipsis beside it never moves.
                if toolbarMode == .plan {
                    ToolbarItem(placement: .topBarTrailing) {
                        SpeechToolbarButton(
                            request: planSpeechRequest,
                            unavailableMessage: planSpeechUnavailableMessage,
                            controller: planSpeech,
                            onOpenTransport: { showingSpeechTransport = true }
                        )
                    }
                }
            }
            .sheet(isPresented: $showingSpeechTransport) {
                SpeechTransportSheet(controller: planSpeech, request: planSpeechRequest)
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
            .sheet(isPresented: $showingQuizSheet, onDismiss: {
                // The sheet may have changed the age group preference; pick up
                // the matching questions for the inline quiz card.
                loadQuizForCurrentReading()
            }) {
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
            .sheet(isPresented: $showingThemeEditor) {
                if let color = themeEditColor, let setId = HighlightManager.shared.activeSetId {
                    HighlightThemeEditorSheet(
                        setId: setId,
                        color: color,
                        style: themeEditStyle,
                        existingTheme: themeEditExisting
                    ) { theme in
                        try? ModuleDatabase.shared.saveHighlightTheme(theme)
                        // Trigger sync
                        if let set = try? ModuleDatabase.shared.getHighlightSet(id: setId) {
                            Task {
                                try? await ModuleSyncManager.shared.exportModule(id: set.moduleId)
                            }
                        }
                    }
                }
            }
            // Two separate ideas share this modifier: `toolbarsHidden` is the
            // tap-driven immersive mode, which also takes the status bar and swaps
            // in the collapsed header; `toolbarsCollapsed` is the lighter
            // scroll-driven one, which only moves the bars.
            .toolbar(toolbarsHidden || toolbarsCollapsed ? .hidden : .visible, for: .navigationBar, .bottomBar)
            .statusBarHidden(toolbarsHidden)
            .onChange(of: showingOptionsMenu) { _, isShowing in
                if !isShowing && pendingThemeEdit {
                    pendingThemeEdit = false
                    // Delay to allow popover dismissal animation to complete
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        showingThemeEditor = true
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                // In horizontal split, parent (SplitReaderView) handles the full-width collapsed header
                if (toolbarsHidden || toolbarsCollapsed) && !isHorizontalSplit {
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
                planSpeech.stop()
                // Switch back to chapter view
                loadVerses(loadingCase: LOADING_CURRENT)
            }
        }
        .onChange(of: date) { _, _ in
            planSpeech.stop()
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
        .onChange(of: planSpeechInputs, initial: true) { _, inputs in
            rebuildPlanSpeechRequest(for: inputs)
        }
        .onChange(of: spokenVerseId) { _, verseId in
            if let verseId {
                followSpokenVerse(verseId)
            }
        }
        .onDisappear {
            planSpeech.stop()
        }
    }

    private func commitVisibleVerseIfNeeded(_ verseId: Int) {
        // Commit verse state only after scroll settles.
        verseCommitDebouncer.debounce(delay: 0.12) {
            guard !isProgrammaticScroll else { return }
            // The verse belongs to content that's about to be replaced; committing
            // it can kick off a spurious chapter load that cancels the real one.
            guard !isFetchingContent else { return }
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
        currentReadingIndex = 0
    }

    /// Loads verses for the specified plan reading index within the selected plan.
    /// `scrollToEnd` lands on the reading's last verse instead of its first, which
    /// is what backwards scroll-trigger navigation wants.
    private func loadPlanReading(at index: Int, scrollToEnd: Bool = false) {
        guard selectedPlanIndex >= 0 && selectedPlanIndex < plansWithReadings.count else { return }
        let planReadings = plansWithReadings[selectedPlanIndex].readings
        guard index >= 0 && index < planReadings.count else { return }

        planSpeech.stop()

        let reading = planReadings[index]
        planReadingIndex = index
        // The bottom toolbar renders from currentReadingIndex, so keep the two in
        // step here rather than relying on callers to do it. Safe in plan mode:
        // the onChange handler for this only acts on the legacy readingMetaData
        // path, which is nil here.
        currentReadingIndex = index

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

        // Bump the generation so a slower earlier load can't overwrite this one
        loadGeneration &+= 1
        let generation = loadGeneration
        let translationId = self.translationId
        isFetchingContent = true

        DispatchQueue.global(qos: .userInitiated).async {
            let fetchedVerses = (try? TranslationDatabase.shared.getVerseRange(
                translationId: translationId,
                startRef: reading.sv,
                endRef: reading.ev
            )) ?? []

            // Headings for exactly the chapters the reading covers. Deriving them
            // from the fetched verses avoids probing chapters that don't exist.
            var seen = Set<Int>()
            var allHeadings: [TranslationHeading] = []
            for verse in fetchedVerses {
                let key = verse.book * 1000 + verse.chapter
                guard seen.insert(key).inserted else { continue }
                if let chapterHeadings = try? TranslationDatabase.shared.getHeadingsForChapter(
                    translationId: translationId,
                    book: verse.book,
                    chapter: verse.chapter
                ) {
                    allHeadings.append(contentsOf: chapterHeadings)
                }
            }

            DispatchQueue.main.async {
                // A newer load owns the flag, so leave it set when superseded
                guard generation == loadGeneration else { return }
                isFetchingContent = false

                if fetchedVerses.isEmpty {
                    // Every bundled translation covers every plan reading, so this
                    // means the selected translation doesn't have the range.
                    print("ReaderView: no verses for reading \(reading.sv)-\(reading.ev) in '\(translationId)'")
                }

                verses = fetchedVerses
                headings = allHeadings

                if scrollToEnd, let lastVerse = fetchedVerses.last {
                    currentVerseId = lastVerse.ref
                    visibleVerseId = lastVerse.ref
                    // Picked up by checkPendingScroll once positions are laid out
                    pendingScrollVerseId = lastVerse.ref
                }

                isLoading = true
                loadQuizForCurrentReading()
            }
        }
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
        // Read the age group live: `userSettings` is captured at init, and the
        // quiz sheet can change this preference while the reader is on screen.
        let ageGroup = UserDatabase.shared.getSettings().defaultQuizAgeGroup
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

// MARK: - Read Aloud Controls

/// Toolbar entry point for read-aloud, identical in the reader and the quiz so
/// one feature doesn't read as two.
///
/// Always rendered — disabled rather than removed when there's nothing to read —
/// so the items beside it never shift out from under a tap.
struct SpeechToolbarButton: View {
    let request: TextSpeechRequest?
    /// Set when read-aloud can't run for this passage. Shown on tap rather than
    /// leaving a dead control with no explanation.
    var unavailableMessage: String? = nil
    var controller: TextSpeechController
    /// Opens the full transport. Absent in contexts that don't offer one.
    var onOpenTransport: (() -> Void)? = nil
    @State private var showingUnavailable = false

    private var isPlaying: Bool {
        guard let request else { return false }
        return controller.isPlaying(for: request.id)
    }

    private var isActive: Bool {
        guard let request else { return false }
        return controller.isActive(for: request.id)
    }

    /// Where a transport exists it owns playback state, so this stays a stable way
    /// in rather than doubling as a play/pause toggle. Only the quiz, which has no
    /// transport, still toggles directly.
    private var opensTransport: Bool {
        onOpenTransport != nil
    }

    private var iconName: String {
        if opensTransport { return "speaker.wave.2" }
        if isPlaying { return "pause.fill" }
        if isActive { return "play.fill" }
        return "speaker.wave.2"
    }

    private var accessibilityLabel: String {
        if opensTransport { return "Read aloud controls" }
        if isPlaying { return "Pause reading aloud" }
        if isActive { return "Resume reading aloud" }
        return "Read aloud"
    }

    var body: some View {
        Button {
            if unavailableMessage != nil {
                showingUnavailable = true
            } else if opensTransport {
                onOpenTransport?()
            } else if let request {
                controller.toggle(request)
            }
        } label: {
            Image(systemName: iconName)
        }
        .disabled(request == nil && unavailableMessage == nil)
        .accessibilityLabel(accessibilityLabel)
        .alert("Can't Read Aloud", isPresented: $showingUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unavailableMessage ?? "")
        }
    }
}

/// Floating play/pause button that rides above the bottom toolbar while
/// read-aloud is running, ringed by overall progress.
///
/// Its own view, and the only place `spokenFraction` is read on this screen, so
/// the per-word progress updates invalidate this button alone and never reach
/// the reader's text layout.
struct SpeechFloatingButton: View {
    var controller: TextSpeechController
    var onOpenTransport: () -> Void

    static let diameter: CGFloat = 48
    private var diameter: CGFloat { Self.diameter }
    private let ringWidth: CGFloat = 3

    /// Ring and glyph only — the surface behind them is supplied by `surface`, so
    /// the glass sits under the progress ring rather than over it.
    private var content: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: ringWidth)
            Circle()
                .inset(by: ringWidth / 2)
                .trim(from: 0, to: max(controller.spokenFraction, 0.001))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: controller.spokenFraction)
            Image(systemName: controller.isPlayingAnything ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
        }
        .frame(width: diameter, height: diameter)
    }

    /// Liquid Glass where the OS has it; the app still ships to iOS 18, which
    /// falls back to a material and needs its own shadow to lift off the page.
    @ViewBuilder
    private var surface: some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }

    var body: some View {
        Button(action: { controller.isPlayingAnything ? controller.pause() : controller.resume() }) {
            surface
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(controller.isPlayingAnything ? "Pause reading aloud" : "Resume reading aloud")
        .accessibilityValue("\(Int(controller.spokenFraction * 100)) percent")
        .accessibilityHint("Double tap and hold for more controls")
        .onLongPressGesture(perform: onOpenTransport)
    }
}

/// Full read-aloud transport: play/pause, verse skip, stop, and a scrubber.
struct SpeechTransportSheet: View {
    var controller: TextSpeechController
    /// Needed to *start* playback: the toolbar button only opens this sheet, so
    /// the first tap of play happens here.
    var request: TextSpeechRequest?
    @Environment(\.dismiss) private var dismiss

    /// Non-nil only while a drag is in flight, so the thumb follows the finger
    /// instead of the speech position.
    @State private var scrubFraction: Double?

    private var displayedFraction: Double {
        scrubFraction ?? controller.spokenFraction
    }

    /// Falls back to the request while idle, when the controller holds nothing.
    private var displayedTitle: String {
        controller.title.isEmpty ? (request?.title ?? "") : controller.title
    }

    private var displayedSubtitle: String? {
        controller.title.isEmpty ? request?.subtitle : controller.subtitle
    }

    private func togglePlayback() {
        guard let request else { return }
        controller.toggle(request)
    }

    /// Verse skip needs verses to step between — `skipVerse` compares verse tags,
    /// so without them the buttons do nothing and are hidden. The scrubber stays
    /// either way: seeking falls back to the chunk boundaries every request has.
    private var showsVerseSkip: Bool {
        request?.hasVerseStructure ?? false
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text(displayedTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let subtitle = displayedSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                SpeechScrubber(fraction: displayedFraction) { fraction, isCommitted in
                    if isCommitted {
                        scrubFraction = nil
                        controller.seek(toFraction: fraction)
                    } else {
                        scrubFraction = fraction
                    }
                }
                .frame(height: 28)

                HStack {
                    Text(timeLabel(for: displayedFraction))
                    Spacer()
                    Text("-" + timeLabel(for: 1 - displayedFraction))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 44) {
                if showsVerseSkip {
                    Button { controller.skipVerse(by: -1) } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    .accessibilityLabel("Previous verse")
                }

                Button(action: togglePlayback) {
                    Image(systemName: controller.isPlayingAnything ? "pause.fill" : "play.fill")
                        .font(.system(size: 40))
                }
                .disabled(request == nil)
                .accessibilityLabel(controller.isPlayingAnything ? "Pause" : "Play")

                if showsVerseSkip {
                    Button { controller.skipVerse(by: 1) } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    .accessibilityLabel("Next verse")
                }
            }
            .foregroundStyle(Color.primary)

            Button {
                controller.stop()
                dismiss()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(Color(UIColor.label))
            .disabled(controller.playbackState == .idle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        // Close once playback finishes — but only on an actual transition, since
        // the sheet is now also the way to start, and so opens while idle.
        .onChange(of: controller.playbackState) { previous, state in
            if previous != .idle, state == .idle { dismiss() }
        }
    }

    private func timeLabel(for fraction: Double) -> String {
        let seconds = Int((controller.estimatedDuration * min(max(fraction, 0), 1)).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Scrubber that reports its fraction continuously while dragging and once on
/// release. Seeking speech is expensive — it tears down and rebuilds the
/// utterance queue — so only the release commits.
private struct SpeechScrubber: View {
    let fraction: Double
    let onChange: (Double, Bool) -> Void

    private let trackHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                // `Color(UIColor.label)`, not `Color.primary`: the latter is a
                // hierarchical style that blends with the sheet's vibrancy and
                // renders washed out. This needs a flat, opaque fill.
                Capsule()
                    .fill(Color(UIColor.label))
                    .frame(width: width * clamped, height: trackHeight)
                Circle()
                    .fill(Color(UIColor.label))
                    .frame(width: 20, height: 20)
                    .offset(x: width * clamped - 10)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(min(max($0.location.x / width, 0), 1), false) }
                    .onEnded { onChange(min(max($0.location.x / width, 0), 1), true) }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            let target = direction == .increment ? fraction + step : fraction - step
            onChange(min(max(target, 0), 1), true)
        }
    }
}

private enum ReaderSpeechTextBuilder {
    /// One segment per verse (plus the reference and any chapter headings) so the
    /// reader can follow along with what's being spoken. Chapter headings are
    /// attributed to the verse that follows them, so following doesn't stall.
    static func planReadingSegments(readingDescription: String, verses: [TranslationVerse]) -> [TextSpeechSegment] {
        var parts: [TextSpeechSegment] = []
        let description = normalized(readingDescription)
        if !description.isEmpty {
            parts.append(TextSpeechSegment(text: description))
        }

        var currentChapterKey: String?
        for verse in verses {
            let chapterKey = "\(verse.book)-\(verse.chapter)"
            if chapterKey != currentChapterKey {
                currentChapterKey = chapterKey
                let bookName = (try? BundledModuleDatabase.shared.getBook(id: verse.book))?.name ?? "Book \(verse.book)"
                let heading = "\(bookName) \(verse.chapter)"
                // A single-chapter reading is described as "Genesis 1" and its only
                // chapter heading is also "Genesis 1" — announcing both reads the
                // title twice. Multi-chapter readings don't collide.
                if heading != description {
                    parts.append(TextSpeechSegment(text: heading, verseId: verse.ref))
                }
            }

            let verseText = normalized(verse.text)
            if !verseText.isEmpty {
                parts.append(TextSpeechSegment(text: verseText, verseId: verse.ref))
            }
        }

        return parts
    }

    static func quizText(question: QuizQuestion, index: Int, count: Int, includeAnswer: Bool) -> String {
        var parts = [
            "Question \(index + 1) of \(count)",
            normalized(QuizTextParser.parse(question.questionJson).text)
        ].filter { !$0.isEmpty }

        if includeAnswer {
            let answer = normalized(QuizTextParser.parse(question.answerJson).text)
            if !answer.isEmpty {
                parts.append("Answer")
                parts.append(answer)
            }
        }

        return parts.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private enum QuizTextParser {
    /// Parse quiz text JSON into AnnotatedText; handles plain strings and annotated text objects.
    /// Normalizes crossref annotations to scripture so the renderer makes them tappable.
    static func parse(_ json: String) -> AnnotatedText {
        guard let data = json.data(using: .utf8) else {
            return AnnotatedText(text: json)
        }

        // Try as AnnotatedText (object with "text" and "annotations" keys)
        if var annotated = try? JSONDecoder().decode(AnnotatedText.self, from: data) {
            // Normalize crossref to scripture so the renderer treats them as tappable verse refs
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

// MARK: - Selectable Quiz Text

/// Quiz text rendered in a non-editable `UITextView` so it gets native text
/// selection and the system callout menu (Look Up, Translate, Copy, Share).
/// SwiftUI's `Text` can't offer that alongside tappable links, which the quiz
/// needs for scripture references.
private struct SelectableQuizText: UIViewRepresentable {
    let attributedText: NSAttributedString
    let onLinkTap: (URL) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]  // Use the attributes from the string
        textView.dataDetectorTypes = []
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onLinkTap = onLinkTap

        guard !textView.attributedText.isEqual(to: attributedText) else { return }
        textView.attributedText = attributedText
        context.coordinator.cachedSize = nil
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        if let cached = context.coordinator.cachedSize, abs(cached.width - width) < 1 {
            return cached
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var onLinkTap: (URL) -> Void
        var cachedSize: CGSize?

        init(onLinkTap: @escaping (URL) -> Void) {
            self.onLinkTap = onLinkTap
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            let handler = onLinkTap
            return UIAction(title: "") { _ in handler(url) }
        }

        func textView(
            _ textView: UITextView,
            menuConfigurationFor textItem: UITextItem,
            defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            // Suppress the link preview menu so a long press anywhere — including
            // on a scripture reference — falls through to text selection.
            nil
        }
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
    @State private var speech = TextSpeechController()
    @State private var showingSpeechTransport = false
    @AppStorage("quizContextAmount") private var contextAmount: SearchContextAmount = .oneVerse
    @AppStorage("quizAlwaysShowAnswers") private var alwaysShowAnswers: Bool = false

    /// Answers are visible either because this question was revealed by tapping,
    /// or because the always-show preference is on.
    private var isAnswerVisible: Bool {
        alwaysShowAnswers || showAnswer
    }

    init(quizModule: QuizModule, questions: [QuizQuestion], day: Int, sv: Int, ev: Int, readingDescription: String) {
        self.quizModule = quizModule
        self.day = day
        self.sv = sv
        self.ev = ev
        self.readingDescription = readingDescription
        // Seeded only so the first frame isn't empty; `.onAppear` re-derives it
        // from the selected age group, since the caller's copy may have been
        // loaded under a different one.
        self._questions = State(initialValue: questions)
        let settings = UserDatabase.shared.getSettings()
        self._selectedAgeGroup = State(initialValue: settings.defaultQuizAgeGroup)
    }

    private var currentQuestion: QuizQuestion? {
        guard currentIndex >= 0, currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    /// What read-aloud would speak right now. `nil` when there's nothing to read,
    /// which disables the control rather than removing it.
    ///
    /// The id folds in `isAnswerVisible` because revealing the answer changes the
    /// words, and the single source keeps the toolbar button and the stop action from
    /// ever disagreeing about which utterance is current.
    private var currentSpeechRequest: TextSpeechRequest? {
        guard let question = currentQuestion else { return nil }
        let text = ReaderSpeechTextBuilder.quizText(
            question: question,
            index: currentIndex,
            count: questions.count,
            includeAnswer: isAnswerVisible
        )
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TextSpeechRequest(
            id: "quiz-\(quizModule.id)-\(day)-\(selectedAgeGroup)-\(question.id)-answer-\(isAnswerVisible)",
            title: "Question \(currentIndex + 1) of \(questions.count)",
            // Questions are worded differently per age group, so which one is being
            // read is part of identifying the passage, not just a picker setting.
            subtitle: selectedAgeGroupLabel.map { "\(readingDescription) · \($0)" } ?? readingDescription,
            text: text,
            languageCode: quizLanguageCode,
            wordsPerMinute: UserDatabase.shared.getSettings().planWpm
        )
    }

    /// Human-readable name of the age group in play, for display rather than the
    /// raw id stored in settings.
    private var selectedAgeGroupLabel: String? {
        quizModule.ageGroups.first { $0.id == selectedAgeGroup }?.label
    }

    /// Whether the question on screen is the one being spoken. Moving between
    /// questions changes the request, so this also retires the button when the
    /// audio no longer matches what's displayed.
    private var isQuizSpeechActive: Bool {
        guard let currentSpeechRequest else { return false }
        return speech.isActive(for: currentSpeechRequest.id)
    }

    @ViewBuilder
    private var floatingSpeechButton: some View {
        if isQuizSpeechActive {
            SpeechFloatingButton(
                controller: speech,
                onOpenTransport: { showingSpeechTransport = true }
            )
            .padding(.bottom, 12)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Quiz modules don't declare a language, so read them in the device's.
    private var quizLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private var quizSpeechUnavailableMessage: String? {
        SpeechVoiceCatalog.hasVoice(for: quizLanguageCode)
            ? nil
            : ReaderView.noVoiceMessage(for: quizLanguageCode)
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
                            if isAnswerVisible {
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
                                    speech.stop()
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
                        // Room for the floating button to scroll clear of, so the
                        // last of the answer isn't stuck underneath it. Only while
                        // it's on screen — otherwise it's dead space.
                        .padding(.bottom, isQuizSpeechActive ? SpeechFloatingButton.diameter + 24 : 0)
                    }
                    // Anchored to the scroll area, which ends where the question
                    // navigation begins — so the button clears it without the
                    // measured offset the reader needs for its floating toolbar.
                    .overlay(alignment: .bottom) { floatingSpeechButton }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isQuizSpeechActive)

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
                ToolbarItemGroup(placement: .primaryAction) {
                    // Stop lives in the transport and the menu, not here: a toolbar
                    // item that appears on playback shoves the menu sideways mid-tap.
                    SpeechToolbarButton(
                        request: currentSpeechRequest,
                        unavailableMessage: quizSpeechUnavailableMessage,
                        controller: speech,
                        onOpenTransport: { showingSpeechTransport = true }
                    )

                    Menu {
                        Toggle(isOn: $alwaysShowAnswers) {
                            Label("Always Show Answers", systemImage: "eye")
                        }

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
            // A sheet presented from a sheet, which this view already relies on for
            // the passage preview below.
            .sheet(isPresented: $showingSpeechTransport) {
                SpeechTransportSheet(controller: speech, request: currentSpeechRequest)
            }
            .sheet(item: $previewState) { _ in
                PreviewSheet(
                    state: $previewState,
                    translationId: UserDatabase.shared.getSettings().readerTranslationId,
                    contextAmount: contextAmount
                )
            }
            .onAppear {
                // The seeded questions were loaded by the reader under whichever
                // age group was current then, which may no longer be the selected
                // one. Re-derive so the picker and the questions always agree.
                reloadQuestions()
            }
            .onChange(of: alwaysShowAnswers) {
                speech.stop()
            }
            .onDisappear {
                speech.stop()
            }
        }
    }

    // MARK: - Annotated Text Rendering

    @ViewBuilder
    private func quizAnnotatedText(for json: String) -> some View {
        let parsed = QuizTextParser.parse(json)
        SelectableQuizText(
            attributedText: buildQuizAttributedString(from: parsed),
            onLinkTap: { url in
                handleQuizURL(url, annotatedText: parsed)
            }
        )
    }

    /// Build an NSAttributedString with tappable links for scripture annotations.
    /// UIKit-flavoured because the quiz text is rendered by a UITextView, which is
    /// what provides selection and the native callout menu.
    private func buildQuizAttributedString(from annotatedText: AnnotatedText) -> NSAttributedString {
        let text = annotatedText.text
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        )

        guard let annotations = annotatedText.annotations else { return result }

        for annotation in annotations {
            guard annotation.start >= 0, annotation.end <= text.count, annotation.start < annotation.end else { continue }
            guard annotation.type == .scripture || annotation.type == .crossref,
                  let sv = annotation.data?.sv,
                  let url = URL(string: "lampbible://quiz-ref/\(sv)/\(annotation.data?.ev ?? sv)") else { continue }

            // Annotation offsets are in Characters; NSAttributedString wants UTF-16
            let startIdx = text.index(text.startIndex, offsetBy: annotation.start)
            let endIdx = text.index(text.startIndex, offsetBy: annotation.end)
            let nsRange = NSRange(startIdx..<endIdx, in: text)

            result.addAttributes([
                .link: url,
                .foregroundColor: UIColor.systemBlue
            ], range: nsRange)
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
        speech.stop()
        showAnswer = false
        currentIndex = index
    }

    private func saveAgeGroupPreference(_ ageGroup: String) {
        try? UserDatabase.shared.updateSettings { settings in
            settings.defaultQuizAgeGroup = ageGroup
        }
    }

    private func reloadQuestions() {
        speech.stop()
        questions = (try? BundledModuleDatabase.shared.getQuizQuestionsForReading(
            moduleId: quizModule.id, day: day, sv: sv, ev: ev, ageGroup: selectedAgeGroup
        )) ?? []
        currentIndex = 0
        showAnswer = false
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
