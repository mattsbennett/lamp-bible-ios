//
//  CommentaryRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-04.
//

import SwiftUI
import UIKit

// MARK: - Custom Tappable Attributes

/// Custom attribute key for indexed tappable items (avoids iOS URL resolution delay)
private let CommentaryTappableIndexKey = NSAttributedString.Key("commentaryTappableIndex")

/// Custom attribute key for direct tap action data (for non-indexed rendering)
private let CommentaryTapActionKey = NSAttributedString.Key("commentaryTapAction")

/// Tap action data stored in attributed string for non-indexed rendering
private enum CommentaryTapAction {
    case verse(sv: Int, ev: Int?)
    case strongs(key: String)
    case footnote(id: String)
    case lexicon(id: String)
    case media(id: String)
}

// MARK: - First Match Scroll Offset (for scroll-to-match in preview sheets)

/// Preference key to collect first match offset from text views for scroll-to-match
struct CommentaryMatchOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        // Take the first non-nil value (we only want the first match)
        if value == nil {
            value = nextValue()
        }
    }
}

// MARK: - Commentary Renderer

/// Tappable item extracted from commentary annotations for preview sheet navigation
struct CommentaryTappableItem: Equatable, Identifiable {
    let index: Int
    let type: ItemType

    var id: Int { index }

    enum ItemType: Equatable {
        case verse(verseId: Int, endVerseId: Int?, displayText: String)
        case strongs(key: String, displayText: String)
        case footnote(id: String)
        case lexicon(id: String, displayText: String)
        case media(id: String, displayText: String)
    }

    var displayText: String {
        switch type {
        case .verse(_, _, let text): return text
        case .strongs(_, let text): return text
        case .footnote(let id): return id
        case .lexicon(_, let text): return text
        case .media(_, let text): return text
        }
    }
}

/// Utility for rendering AnnotatedText to AttributedString with proper styling
struct CommentaryRenderer {

    // MARK: - Configuration

    struct Style {
        var bodyFont: Font = .body
        var uiBodyFont: UIFont? = nil // Explicit UIKit font (e.g. for dynamic sizing)
        var footnoteFont: Font = .footnote
        var greekFont: Font = .body.italic()
        var hebrewFont: Font = .body
        var scriptureColor: Color = .accentColor
        var strongsColor: Color = .accentColor
        var footnoteColor: Color = .secondary
        var abbreviationColor: Color = .orange
        var searchTerms: [String] = []  // Search terms to highlight

        var uiFootnoteFont: UIFont? {
            if let base = uiBodyFont {
                // Return footnote font proportionally smaller than body
                return base.withSize(max(10, base.pointSize - 4))
            }
            return nil
        }

        var uiCaptionFont: UIFont? {
            if let base = uiBodyFont {
                return base.withSize(max(10, base.pointSize - 5))
            }
            return nil
        }
    }

    /// Result of rendering with tappable items for navigation
    struct RenderResult {
        let attributedString: NSAttributedString
        let tappableItems: [CommentaryTappableItem]
    }

    static var defaultStyle = Style()

    // MARK: - Rendering


    /// Render AnnotatedText to AttributedString
    static func render(_ annotatedText: AnnotatedText, style: Style = defaultStyle) -> AttributedString {
        var result = AttributedString(annotatedText.text)
        result.font = style.bodyFont
        // Do not set base foregroundColor here; let UITextView.textColor handle it dynamically

        // Sort annotations by start position (reverse order for safe index manipulation)
        guard let annotations = annotatedText.annotations else {
            return result
        }

        let sortedAnnotations = annotations.sorted { $0.start > $1.start }

        for annotation in sortedAnnotations {
            guard annotation.start >= 0,
                  annotation.start < annotation.end else {
                continue
            }

            let startIndex = result.index(result.startIndex, offsetByUnicodeScalars: annotation.start)
            let endIndex = result.index(result.startIndex, offsetByUnicodeScalars: annotation.end)

            guard startIndex < endIndex, startIndex < result.endIndex else { continue }
            let range = startIndex..<endIndex

            switch annotation.type {
            case .scripture:
                result[range].foregroundColor = style.scriptureColor
                let urlString: String
                if let sv = annotation.data?.sv {
                    if let ev = annotation.data?.ev {
                        urlString = "lampbible://verse/\(sv)/\(ev)"
                    } else {
                        urlString = "lampbible://verse/\(sv)"
                    }
                    result[range].link = URL(string: urlString)
                }

            case .strongs:
                result[range].foregroundColor = style.strongsColor
                result[range].font = style.bodyFont.bold()
                if let strongsKey = annotation.data?.strongs ?? annotation.id {
                    let key = strongsKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    result[range].link = URL(string: "lampbible://strongs/\(key)")
                }

            case .greek:
                result[range].font = style.greekFont
                result[range].foregroundColor = style.strongsColor.opacity(0.8)
                // Add link if strongs data is present
                if let key = annotation.data?.strongs {
                    result[range].link = URL(string: "lampbible://strongs/\(key)")
                }

            case .hebrew:
                result[range].font = style.hebrewFont
                result[range].foregroundColor = style.strongsColor.opacity(0.8)
                // Add link if strongs data is present
                if let key = annotation.data?.strongs {
                    result[range].link = URL(string: "lampbible://strongs/\(key)")
                }

            case .footnote:
                result[range].foregroundColor = style.footnoteColor
                result[range].baselineOffset = 4.0
                if let uiFootnote = style.uiFootnoteFont {
                     result[range].font = Font(uiFootnote)
                } else {
                     result[range].font = style.footnoteFont
                }
                if let id = annotation.id, !id.isEmpty {
                    // SwiftUI doesn't have a direct 'link' attribute for arbitrary clicks,
                    // but AnnotatedText usually handles this via `onFootnoteTap` and text ranges.
                    // This renderer is mostly for non-interactive SwiftUI previews if used directly.
                }
                result[range].font = style.footnoteFont
                result[range].baselineOffset = 4
                if let id = annotation.id {
                    result[range].link = URL(string: "lampbible://footnote/\(id)")
                }

            case .crossref:
                result[range].foregroundColor = style.scriptureColor

            case .abbrev:
                result[range].foregroundColor = style.abbreviationColor

            case .page:
                result[range].foregroundColor = style.footnoteColor
                result[range].font = style.footnoteFont

            case .lexiconRef:
                result[range].foregroundColor = style.strongsColor
                if let lexiconId = annotation.data?.lexiconId ?? annotation.id {
                    result[range].link = URL(string: "lampbible://lexicon/\(lexiconId)")
                }

            case .bold:
                result[range].font = style.bodyFont.bold()

            case .italic:
                result[range].font = style.bodyFont.italic()

            case .media:
                // Media annotations indicate inline media references
                // Render as a placeholder icon - actual media display handled at view level
                result[range].foregroundColor = style.scriptureColor
                if let mediaId = annotation.data?.mediaId {
                    result[range].link = URL(string: "lampbible://media/\(mediaId)")
                }
            }
        }

        // Insert footnote reference markers
        if let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                guard ref.offset >= 0 else { continue }
                let insertIndex = result.index(result.startIndex, offsetByUnicodeScalars: ref.offset)
                var marker = AttributedString("[\(ref.id)]")
                marker.foregroundColor = style.footnoteColor
                marker.font = style.footnoteFont
                marker.baselineOffset = 4
                marker.link = URL(string: "lampbible://footnote/\(ref.id)")

                result.insert(marker, at: insertIndex)
            }
        }

        return result
    }

    // MARK: - UIKit Rendering (Robust)

    static func renderUIKit(_ annotatedText: AnnotatedText, style: Style = defaultStyle) -> NSAttributedString {
        let text = annotatedText.text
        let result = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: result.length)

        // Base Attributes
        let baseFont = style.uiBodyFont ?? UIFont.preferredFont(forTextStyle: .body)
        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

        // Helper to convert indices
        func getRange(_ start: Int, _ end: Int) -> NSRange? {
            // Assume unicode scalar offsets (matching legacy logic)
            let scalars = text.unicodeScalars
            guard start >= 0, end > start, start < scalars.count, end <= scalars.count else { return nil }

            let startIdx = scalars.index(scalars.startIndex, offsetBy: start)
            let endIdx = scalars.index(scalars.startIndex, offsetBy: end)

            return NSRange(startIdx..<endIdx, in: text)
        }

        if let annotations = annotatedText.annotations {
            for annotation in annotations {
                guard let range = getRange(annotation.start, annotation.end) else { continue }

                switch annotation.type {
                case .scripture:
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)
                    if let sv = annotation.data?.sv {
                        let ev = annotation.data?.ev
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.verse(sv: sv, ev: ev), range: range)
                    }

                case .strongs:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    if let key = annotation.data?.strongs ?? annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.strongs(key: key), range: range)
                    }

                case .greek:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    // Add tap action if strongs data is present
                    if let key = annotation.data?.strongs {
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.strongs(key: key), range: range)
                    }

                case .hebrew:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    // Add tap action if strongs data is present
                    if let key = annotation.data?.strongs {
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.strongs(key: key), range: range)
                    }

                case .footnote:
                    result.addAttribute(.foregroundColor, value: UIColor(style.footnoteColor), range: range)
                    result.addAttribute(.baselineOffset, value: 4, range: range)
                    let fnFont = style.uiFootnoteFont ?? UIFont.preferredFont(forTextStyle: .footnote)
                    result.addAttribute(.font, value: fnFont, range: range)
                    if let id = annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.footnote(id: id), range: range)
                    }

                case .crossref:
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)

                case .abbrev:
                    result.addAttribute(.foregroundColor, value: UIColor(style.abbreviationColor), range: range)

                case .page:
                    // Usually hidden or subtle
                    result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                    result.addAttribute(.font, value: style.uiCaptionFont ?? UIFont.preferredFont(forTextStyle: .caption1), range: range)

                case .lexiconRef:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let lexiconId = annotation.data?.lexiconId ?? annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.lexicon(id: lexiconId), range: range)
                    }

                case .bold:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .italic:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .media:
                    // Media annotations indicate inline media references
                    // Render with accent color - actual media display handled at view level
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)
                    if let mediaId = annotation.data?.mediaId {
                        result.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.media(id: mediaId), range: range)
                    }
                }
            }
        }

        // Insert Footnotes (Order matters: Reverse to keep indices valid)
        if let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                let scalars = text.unicodeScalars
                guard ref.offset >= 0, ref.offset <= scalars.count else { continue }
                let idx = scalars.index(scalars.startIndex, offsetBy: ref.offset)
                let nsRange = NSRange(idx..<idx, in: text)

                // Create Marker
                let marker = NSMutableAttributedString(string: "[\(ref.id)]")
                let fnFont = UIFont.preferredFont(forTextStyle: .footnote)
                let range = NSRange(location: 0, length: marker.length)

                marker.addAttribute(.font, value: fnFont, range: range)
                marker.addAttribute(.foregroundColor, value: UIColor(style.footnoteColor), range: range)
                marker.addAttribute(.baselineOffset, value: 4, range: range)
                // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                marker.addAttribute(CommentaryTapActionKey, value: CommentaryTapAction.footnote(id: ref.id), range: range)

                result.insert(marker, at: nsRange.location)
            }
        }

        // Line and paragraph spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 8
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        // Apply search term highlighting with yellow background
        if !style.searchTerms.isEmpty {
            let fullString = result.string
            let fullStringLower = fullString.lowercased()

            for term in style.searchTerms {
                let termLower = term.lowercased()
                var searchStartIndex = fullStringLower.startIndex

                while let range = fullStringLower.range(of: termLower, range: searchStartIndex..<fullStringLower.endIndex) {
                    let nsRange = NSRange(range, in: fullString)
                    result.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.4), range: nsRange)
                    searchStartIndex = range.upperBound
                }
            }
        }

        return result
    }

    // MARK: - UIKit Rendering with Tappable Items (for prev/next navigation)

    /// Render AnnotatedText to NSAttributedString with indexed URLs for prev/next navigation
    /// URLs include indices: lampbible://type/index/value
    static func renderUIKitWithItems(_ annotatedText: AnnotatedText, style: Style = defaultStyle, baseOffset: Int = 0) -> RenderResult {
        let text = annotatedText.text
        let result = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: result.length)
        var tappableItems: [CommentaryTappableItem] = []
        var itemIndex = baseOffset

        // Base Attributes
        let baseFont = style.uiBodyFont ?? UIFont.preferredFont(forTextStyle: .body)
        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

        // Helper to convert indices
        func getRange(_ start: Int, _ end: Int) -> NSRange? {
            let scalars = text.unicodeScalars
            guard start >= 0, end > start, start < scalars.count, end <= scalars.count else { return nil }

            let startIdx = scalars.index(scalars.startIndex, offsetBy: start)
            let endIdx = scalars.index(scalars.startIndex, offsetBy: end)

            return NSRange(startIdx..<endIdx, in: text)
        }

        // Helper to get display text from range
        func getDisplayText(_ start: Int, _ end: Int) -> String {
            let scalars = text.unicodeScalars
            guard start >= 0, end > start, start < scalars.count, end <= scalars.count else { return "" }

            let startIdx = scalars.index(scalars.startIndex, offsetBy: start)
            let endIdx = scalars.index(scalars.startIndex, offsetBy: end)
            let startStringIdx = startIdx.samePosition(in: text) ?? text.startIndex
            let endStringIdx = endIdx.samePosition(in: text) ?? text.endIndex

            return String(text[startStringIdx..<endStringIdx])
        }

        if let annotations = annotatedText.annotations {
            for annotation in annotations {
                guard let range = getRange(annotation.start, annotation.end) else { continue }

                switch annotation.type {
                case .scripture:
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)
                    if let sv = annotation.data?.sv {
                        let ev = annotation.data?.ev
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .verse(verseId: sv, endVerseId: ev, displayText: displayText)
                        ))
                        itemIndex += 1
                    }

                case .strongs:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    if let key = annotation.data?.strongs ?? annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .strongs(key: key, displayText: displayText)
                        ))
                        itemIndex += 1
                    }

                case .greek:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    // Add tappable item if strongs data is present
                    if let key = annotation.data?.strongs {
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .strongs(key: key, displayText: displayText)
                        ))
                        itemIndex += 1
                    }

                case .hebrew:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    // Add tappable item if strongs data is present
                    if let key = annotation.data?.strongs {
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .strongs(key: key, displayText: displayText)
                        ))
                        itemIndex += 1
                    }

                case .footnote:
                    result.addAttribute(.foregroundColor, value: UIColor(style.footnoteColor), range: range)
                    result.addAttribute(.baselineOffset, value: 4, range: range)
                    let fnFont = style.uiFootnoteFont ?? UIFont.preferredFont(forTextStyle: .footnote)
                    result.addAttribute(.font, value: fnFont, range: range)
                    if let id = annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .footnote(id: id)
                        ))
                        itemIndex += 1
                    }

                case .crossref:
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)

                case .abbrev:
                    result.addAttribute(.foregroundColor, value: UIColor(style.abbreviationColor), range: range)

                case .page:
                    result.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
                    result.addAttribute(.font, value: style.uiCaptionFont ?? UIFont.preferredFont(forTextStyle: .caption1), range: range)

                case .lexiconRef:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let lexiconId = annotation.data?.lexiconId ?? annotation.id {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .lexicon(id: lexiconId, displayText: displayText)
                        ))
                        itemIndex += 1
                    }

                case .bold:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .italic:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .media:
                    // Media annotations indicate inline media references
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)
                    if let mediaId = annotation.data?.mediaId {
                        result.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: range)
                        let displayText = getDisplayText(annotation.start, annotation.end)
                        tappableItems.append(CommentaryTappableItem(
                            index: itemIndex,
                            type: .media(id: mediaId, displayText: displayText)
                        ))
                        itemIndex += 1
                    }
                }
            }
        }

        // Insert Footnotes (Order matters: Reverse to keep indices valid)
        // Note: Footnote refs are tracked separately from inline footnote annotations
        if let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                let scalars = text.unicodeScalars
                guard ref.offset >= 0, ref.offset <= scalars.count else { continue }
                let idx = scalars.index(scalars.startIndex, offsetBy: ref.offset)
                let nsRange = NSRange(idx..<idx, in: text)

                // Create Marker
                let marker = NSMutableAttributedString(string: "[\(ref.id)]")
                let fnFont = UIFont.preferredFont(forTextStyle: .footnote)
                let markerRange = NSRange(location: 0, length: marker.length)

                marker.addAttribute(.font, value: fnFont, range: markerRange)
                marker.addAttribute(.foregroundColor, value: UIColor(style.footnoteColor), range: markerRange)
                marker.addAttribute(.baselineOffset, value: 4, range: markerRange)
                // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                marker.addAttribute(CommentaryTappableIndexKey, value: itemIndex, range: markerRange)
                tappableItems.append(CommentaryTappableItem(
                    index: itemIndex,
                    type: .footnote(id: ref.id)
                ))
                itemIndex += 1

                result.insert(marker, at: nsRange.location)
            }
        }

        // Line and paragraph spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.paragraphSpacing = 8
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        // Apply search term highlighting with yellow background
        if !style.searchTerms.isEmpty {
            let fullString = result.string
            let fullStringLower = fullString.lowercased()

            for term in style.searchTerms {
                let termLower = term.lowercased()
                var searchStartIndex = fullStringLower.startIndex

                while let searchRange = fullStringLower.range(of: termLower, range: searchStartIndex..<fullStringLower.endIndex) {
                    let nsRange = NSRange(searchRange, in: fullString)
                    result.addAttribute(.backgroundColor, value: UIColor.yellow.withAlphaComponent(0.4), range: nsRange)
                    searchStartIndex = searchRange.upperBound
                }
            }
        }

        return RenderResult(attributedString: result, tappableItems: tappableItems)
    }

    /// Render a footnote to AttributedString
    static func renderFootnote(_ footnote: CommentaryFootnote, style: Style = defaultStyle) -> AttributedString {
        var result = AttributedString("\(footnote.id). ")
        result.font = style.footnoteFont.bold()

        let content = render(footnote.content, style: style)
        result.append(content)

        return result
    }

    /// Render multiple footnotes as a combined AttributedString
    static func renderFootnotes(_ footnotes: [CommentaryFootnote], style: Style = defaultStyle) -> AttributedString {
        var result = AttributedString()

        for (index, footnote) in footnotes.enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            result.append(renderFootnote(footnote, style: style))
        }

        return result
    }

}

// MARK: - SwiftUI View for Annotated Text

struct AnnotatedTextView: View {
    let annotatedText: AnnotatedText
    let style: CommentaryRenderer.Style
    let onScriptureTap: ((Int, Int?) -> Void)?  // (sv, ev?) for verse ranges
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLexiconTap: ((String) -> Void)?  // lexicon entry ID
    let onMediaTap: ((String) -> Void)?  // media ID

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var scrollCoordinateSpace: String = "commentaryScroll"

    @State private var localMatchOffset: CGFloat? = nil

    init(
        _ annotatedText: AnnotatedText,
        style: CommentaryRenderer.Style = CommentaryRenderer.defaultStyle,
        onScriptureTap: ((Int, Int?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLexiconTap: ((String) -> Void)? = nil,
        onMediaTap: ((String) -> Void)? = nil,
        shouldReportMatchOffset: Bool = false,
        scrollCoordinateSpace: String = "commentaryScroll"
    ) {
        self.annotatedText = annotatedText
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLexiconTap = onLexiconTap
        self.onMediaTap = onMediaTap
        self.shouldReportMatchOffset = shouldReportMatchOffset
        self.scrollCoordinateSpace = scrollCoordinateSpace
    }

    var body: some View {
        AnnotatedUITextViewRepresentable(
            annotatedText: annotatedText,
            style: style,
            onScriptureTap: onScriptureTap,
            onStrongsTap: onStrongsTap,
            onFootnoteTap: onFootnoteTap,
            onLexiconTap: onLexiconTap,
            onMediaTap: onMediaTap,
            shouldReportMatchOffset: shouldReportMatchOffset,
            onFirstMatchOffset: shouldReportMatchOffset ? { offset in
                localMatchOffset = offset
            } : nil
        )
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: CommentaryMatchOffsetPreferenceKey.self,
                        value: shouldReportMatchOffset && localMatchOffset != nil
                            ? geometry.frame(in: .named(scrollCoordinateSpace)).minY + (localMatchOffset ?? 0)
                            : nil
                    )
            }
        )
    }
}

// MARK: - Tappable Commentary Text View

/// Custom UITextView that uses tap gestures instead of URL-based link handling
/// This avoids the iOS URL resolution delay ("canmaplsdatabase" error)
private class TappableCommentaryTextView: UITextView {
    // For indexed taps (renderUIKitWithItems)
    var onTappableIndexTap: ((Int) -> Void)?

    // For direct action taps (renderUIKit)
    var onScriptureTap: ((Int, Int?) -> Void)?
    var onStrongsTap: ((String) -> Void)?
    var onFootnoteTap: ((String) -> Void)?
    var onLexiconTap: ((String) -> Void)?
    var onMediaTap: ((String) -> Void)?

    // Use TextKit 1 for reliable character index calculation
    private let textKit1LayoutManager = NSLayoutManager()
    private let textKit1TextContainer = NSTextContainer()
    private let textKit1TextStorage = NSTextStorage()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        // Set up TextKit 1 stack
        textKit1TextStorage.addLayoutManager(textKit1LayoutManager)
        textKit1LayoutManager.addTextContainer(textKit1TextContainer)
        textKit1TextContainer.widthTracksTextView = true
        textKit1TextContainer.heightTracksTextView = false

        super.init(frame: frame, textContainer: textKit1TextContainer)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        // Adjust for text container inset
        let textContainerOffset = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        let locationInTextContainer = CGPoint(
            x: location.x - textContainerOffset.x,
            y: location.y - textContainerOffset.y
        )

        // Get character index at tap location
        let characterIndex = textKit1LayoutManager.characterIndex(
            for: locationInTextContainer,
            in: textKit1TextContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard characterIndex < textKit1TextStorage.length else { return }

        let attributes = textKit1TextStorage.attributes(at: characterIndex, effectiveRange: nil)

        // Handle indexed taps (for prev/next navigation)
        if let tappableIndex = attributes[CommentaryTappableIndexKey] as? Int {
            onTappableIndexTap?(tappableIndex)
            return
        }

        // Handle direct action taps (non-indexed)
        if let action = attributes[CommentaryTapActionKey] as? CommentaryTapAction {
            switch action {
            case .verse(let sv, let ev):
                onScriptureTap?(sv, ev)
            case .strongs(let key):
                onStrongsTap?(key)
            case .footnote(let id):
                onFootnoteTap?(id)
            case .lexicon(let id):
                onLexiconTap?(id)
            case .media(let id):
                onMediaTap?(id)
            }
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

private struct AnnotatedUITextViewRepresentable: UIViewRepresentable {
    let annotatedText: AnnotatedText
    let style: CommentaryRenderer.Style
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLexiconTap: ((String) -> Void)?
    let onMediaTap: ((String) -> Void)?

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> TappableCommentaryTextView {
        let textView = TappableCommentaryTextView()
        textView.isEditable = false
        textView.isSelectable = false  // Disable selection for instant tap response
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]
        textView.allowsEditingTextAttributes = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.layer.drawsAsynchronously = true
        textView.textContentType = .none
        return textView
    }

    func updateUIView(_ textView: TappableCommentaryTextView, context: Context) {
        // Set up tap handlers
        textView.onScriptureTap = onScriptureTap
        textView.onStrongsTap = onStrongsTap
        textView.onFootnoteTap = onFootnoteTap
        textView.onLexiconTap = onLexiconTap
        textView.onMediaTap = onMediaTap

        // Ensure dynamic colors update correctly
        textView.textColor = .label

        let nsAttributed = CommentaryRenderer.renderUIKit(annotatedText, style: style)
        textView.attributedText = nsAttributed

        // Invalidate layout if text or font size changed
        let currentFontSize = style.uiBodyFont?.pointSize ?? 0
        if context.coordinator.lastText != annotatedText.text || context.coordinator.lastBodyFontSize != currentFontSize {
            context.coordinator.lastText = annotatedText.text
            context.coordinator.lastBodyFontSize = currentFontSize
            context.coordinator.cachedSize = nil
            textView.invalidateIntrinsicContentSize()
        }

        // Report first match offset if requested
        if shouldReportMatchOffset, let callback = onFirstMatchOffset, !style.searchTerms.isEmpty {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()
                if let matchRange = self.findFirstMatchRange(in: annotatedText.text) {
                    // Calculate rect for the match
                    if let start = textView.position(from: textView.beginningOfDocument, offset: matchRange.location),
                       let end = textView.position(from: start, offset: matchRange.length),
                       let textRange = textView.textRange(from: start, to: end) {
                        let rect = textView.firstRect(for: textRange)
                        if !rect.isNull && !rect.isInfinite {
                            callback(rect.origin.y)
                        }
                    }
                }
            }
        }
    }

    /// Find the first match range in the text for scroll-to-match
    private func findFirstMatchRange(in content: String) -> NSRange? {
        let contentLower = content.lowercased()
        var earliestRange: NSRange? = nil
        for term in style.searchTerms {
            let termLower = term.lowercased()
            if let range = contentLower.range(of: termLower) {
                let nsRange = NSRange(range, in: content)
                if earliestRange == nil || nsRange.location < earliestRange!.location {
                    earliestRange = nsRange
                }
            }
        }
        return earliestRange
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableCommentaryTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        // Return cached size if width hasn't changed significantly
        if let cached = context.coordinator.cachedSize,
           abs(cached.width - width) < 1 {
            return cached
        }

        // Ensure text container width matches, so layout manager calculates correct height
        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var lastText: String = ""
        var lastBodyFontSize: CGFloat = 0
        var cachedSize: CGSize?
    }
}

// MARK: - Annotated Text View With Navigation Support

/// Annotated text view that supports prev/next navigation through tappable items
/// Uses indexed URLs and reports parsed items for sheet navigation
struct AnnotatedTextViewWithItems: View {
    let annotatedText: AnnotatedText
    let style: CommentaryRenderer.Style
    let baseOffset: Int
    let onLinkTap: (Int) -> Void
    let onItemsParsed: (([CommentaryTappableItem]) -> Void)?

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var scrollCoordinateSpace: String = "commentaryScroll"

    @State private var localMatchOffset: CGFloat? = nil

    init(
        _ annotatedText: AnnotatedText,
        style: CommentaryRenderer.Style = CommentaryRenderer.defaultStyle,
        baseOffset: Int = 0,
        onLinkTap: @escaping (Int) -> Void,
        onItemsParsed: (([CommentaryTappableItem]) -> Void)? = nil,
        shouldReportMatchOffset: Bool = false,
        scrollCoordinateSpace: String = "commentaryScroll"
    ) {
        self.annotatedText = annotatedText
        self.style = style
        self.baseOffset = baseOffset
        self.onLinkTap = onLinkTap
        self.onItemsParsed = onItemsParsed
        self.shouldReportMatchOffset = shouldReportMatchOffset
        self.scrollCoordinateSpace = scrollCoordinateSpace
    }

    var body: some View {
        AnnotatedUITextViewWithItemsRepresentable(
            annotatedText: annotatedText,
            style: style,
            baseOffset: baseOffset,
            onLinkTap: onLinkTap,
            onItemsParsed: onItemsParsed,
            shouldReportMatchOffset: shouldReportMatchOffset,
            onFirstMatchOffset: shouldReportMatchOffset ? { offset in
                localMatchOffset = offset
            } : nil
        )
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: CommentaryMatchOffsetPreferenceKey.self,
                        value: shouldReportMatchOffset && localMatchOffset != nil
                            ? geometry.frame(in: .named(scrollCoordinateSpace)).minY + (localMatchOffset ?? 0)
                            : nil
                    )
            }
        )
    }
}

private struct AnnotatedUITextViewWithItemsRepresentable: UIViewRepresentable {
    let annotatedText: AnnotatedText
    let style: CommentaryRenderer.Style
    let baseOffset: Int
    let onLinkTap: (Int) -> Void
    let onItemsParsed: (([CommentaryTappableItem]) -> Void)?

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> TappableCommentaryTextView {
        let textView = TappableCommentaryTextView()
        textView.isEditable = false
        textView.isSelectable = false  // Disable selection for instant tap response
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]
        textView.allowsEditingTextAttributes = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.layer.drawsAsynchronously = true
        textView.textContentType = .none
        return textView
    }

    func updateUIView(_ textView: TappableCommentaryTextView, context: Context) {
        // Set up tap handler
        textView.onTappableIndexTap = onLinkTap
        textView.textColor = .label

        let currentFontSize = style.uiBodyFont?.pointSize ?? 0
        if context.coordinator.lastText != annotatedText.text || context.coordinator.lastBodyFontSize != currentFontSize {
            context.coordinator.lastText = annotatedText.text
            context.coordinator.lastBodyFontSize = currentFontSize
            context.coordinator.cachedSize = nil

            let renderResult = CommentaryRenderer.renderUIKitWithItems(annotatedText, style: style, baseOffset: baseOffset)
            textView.attributedText = renderResult.attributedString
            textView.invalidateIntrinsicContentSize()

            // Report parsed items
            DispatchQueue.main.async { [items = renderResult.tappableItems] in
                self.onItemsParsed?(items)
            }
        }

        // Report first match offset if requested
        if shouldReportMatchOffset, let callback = onFirstMatchOffset, !style.searchTerms.isEmpty {
            DispatchQueue.main.async {
                textView.layoutIfNeeded()
                if let matchRange = self.findFirstMatchRange(in: annotatedText.text) {
                    if let start = textView.position(from: textView.beginningOfDocument, offset: matchRange.location),
                       let end = textView.position(from: start, offset: matchRange.length),
                       let textRange = textView.textRange(from: start, to: end) {
                        let rect = textView.firstRect(for: textRange)
                        if !rect.isNull && !rect.isInfinite {
                            callback(rect.origin.y)
                        }
                    }
                }
            }
        }
    }

    private func findFirstMatchRange(in content: String) -> NSRange? {
        let contentLower = content.lowercased()
        var earliestRange: NSRange? = nil
        for term in style.searchTerms {
            let termLower = term.lowercased()
            if let range = contentLower.range(of: termLower) {
                let nsRange = NSRange(range, in: content)
                if earliestRange == nil || nsRange.location < earliestRange!.location {
                    earliestRange = nsRange
                }
            }
        }
        return earliestRange
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableCommentaryTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        if let cached = context.coordinator.cachedSize, abs(cached.width - width) < 1 {
            return cached
        }

        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        var lastText: String = ""
        var lastBodyFontSize: CGFloat = 0
        var cachedSize: CGSize?
    }
}

// MARK: - Commentary Unit View

struct CommentaryUnitView: View {
    let unit: CommentaryUnit
    let abbreviations: [CommentaryAbbreviation]?
    let style: CommentaryRenderer.Style
    let onScriptureTap: ((Int, Int?) -> Void)?  // (sv, ev?) for verse ranges
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String, CommentaryFootnote) -> Void)?

    // Display options
    var hideVerseReference: Bool = false  // Hide "v. X" when context already shows it

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var scrollCoordinateSpace: String = "commentaryScroll"

    init(
        unit: CommentaryUnit,
        abbreviations: [CommentaryAbbreviation]? = nil,
        style: CommentaryRenderer.Style = CommentaryRenderer.defaultStyle,
        onScriptureTap: ((Int, Int?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String, CommentaryFootnote) -> Void)? = nil,
        hideVerseReference: Bool = false,
        shouldReportMatchOffset: Bool = false,
        scrollCoordinateSpace: String = "commentaryScroll"
    ) {
        self.unit = unit
        self.abbreviations = abbreviations
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.hideVerseReference = hideVerseReference
        self.shouldReportMatchOffset = shouldReportMatchOffset
        self.scrollCoordinateSpace = scrollCoordinateSpace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title (for sections/pericopae) or verse reference (for verses)
            if let title = unit.title, !title.isEmpty {
                Text(title)
                    .font(titleFont)
                    .fontWeight(.semibold)
            } else if unit.type == .verse, !hideVerseReference {
                Text(verseReference)
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }

            // Introduction
            if let intro = unit.introduction {
                AnnotatedTextView(
                    intro,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: { id in handleFootnoteTap(id) },
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
            }

            // Translation
            if let translation = unit.translation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translation")
                        .font(.system(size: (style.uiBodyFont?.pointSize ?? 17) - 4))
                        .foregroundColor(.secondary)

                    AnnotatedTextView(
                        translation,
                        style: translationStyle,
                        onScriptureTap: onScriptureTap,
                        onStrongsTap: onStrongsTap,
                        onFootnoteTap: { id in handleFootnoteTap(id) }
                    )
                    .italic()
                }
                .padding(.vertical, 4)
            }

            // Commentary
            if let commentary = unit.commentary {
                AnnotatedTextView(
                    commentary,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: { id in handleFootnoteTap(id) },
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
            }

        }
    }

    private var titleFont: Font {
        let baseSize = style.uiBodyFont?.pointSize ?? 17
        switch unit.type {
        case .section:
            return unit.level == 1 ? .system(size: baseSize + 5, weight: .bold) : .system(size: baseSize + 3, weight: .bold)
        case .pericope:
            return .system(size: baseSize, weight: .bold)
        case .verse:
            return .system(size: baseSize - 2, weight: .semibold)
        }
    }

    /// Format verse reference like "v. 5" or "vv. 5-7" with optional suffix
    private var verseReference: String {
        let startVerse = unit.sv % 1000
        let suffix = unit.suffix ?? ""

        if let ev = unit.ev {
            let endVerse = ev % 1000
            if endVerse != startVerse {
                return "vv. \(startVerse)\(suffix)–\(endVerse)"
            }
        }
        return "v. \(startVerse)\(suffix)"
    }

    private var translationStyle: CommentaryRenderer.Style {
        var s = style
        s.bodyFont = style.bodyFont.italic()
        if let uiFont = s.uiBodyFont {
             if let descriptor = uiFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                 s.uiBodyFont = UIFont(descriptor: descriptor, size: 0)
             }
        }
        return s
    }

    private func handleFootnoteTap(_ footnoteId: String) {
        guard let footnotes = unit.footnotes else {
            print("CommentaryUnitView: No footnotes available in unit")
            return
        }

        // Try exact match first, then case-insensitive/trimmed
        if let footnote = footnotes.first(where: { $0.id == footnoteId }) ??
                          footnotes.first(where: { $0.id.trimmingCharacters(in: .whitespaces) == footnoteId }) {
            onFootnoteTap?(footnoteId, footnote)
        } else {
            print("CommentaryUnitView: Footnote ID '\(footnoteId)' not found. Available: \(footnotes.map { $0.id })")
        }
    }
}

// MARK: - Commentary Unit View With Navigation Support

/// Commentary unit view that supports prev/next navigation through tappable items
/// Collects items from introduction, translation, and commentary sections
struct CommentaryUnitViewWithItems: View {
    let unit: CommentaryUnit
    let abbreviations: [CommentaryAbbreviation]?
    let style: CommentaryRenderer.Style
    let baseOffset: Int
    let onLinkTap: (Int) -> Void
    let onItemsParsed: (([CommentaryTappableItem]) -> Void)?
    let onFootnoteTap: ((String, CommentaryFootnote) -> Void)?

    // Display options
    var hideVerseReference: Bool = false

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var scrollCoordinateSpace: String = "commentaryScroll"

    // Track items from each section
    @State private var introItems: [CommentaryTappableItem] = []
    @State private var translationItems: [CommentaryTappableItem] = []
    @State private var commentaryItems: [CommentaryTappableItem] = []

    init(
        unit: CommentaryUnit,
        abbreviations: [CommentaryAbbreviation]? = nil,
        style: CommentaryRenderer.Style = CommentaryRenderer.defaultStyle,
        baseOffset: Int = 0,
        onLinkTap: @escaping (Int) -> Void,
        onItemsParsed: (([CommentaryTappableItem]) -> Void)? = nil,
        onFootnoteTap: ((String, CommentaryFootnote) -> Void)? = nil,
        hideVerseReference: Bool = false,
        shouldReportMatchOffset: Bool = false,
        scrollCoordinateSpace: String = "commentaryScroll"
    ) {
        self.unit = unit
        self.abbreviations = abbreviations
        self.style = style
        self.baseOffset = baseOffset
        self.onLinkTap = onLinkTap
        self.onItemsParsed = onItemsParsed
        self.onFootnoteTap = onFootnoteTap
        self.hideVerseReference = hideVerseReference
        self.shouldReportMatchOffset = shouldReportMatchOffset
        self.scrollCoordinateSpace = scrollCoordinateSpace
    }

    private var introOffset: Int { baseOffset }
    private var translationOffset: Int { baseOffset + introItems.count }
    private var commentaryOffset: Int { baseOffset + introItems.count + translationItems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title (for sections/pericopae) or verse reference (for verses)
            if let title = unit.title, !title.isEmpty {
                Text(title)
                    .font(titleFont)
                    .fontWeight(.semibold)
            } else if unit.type == .verse, !hideVerseReference {
                Text(verseReference)
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }

            // Introduction
            if let intro = unit.introduction {
                AnnotatedTextViewWithItems(
                    intro,
                    style: style,
                    baseOffset: introOffset,
                    onLinkTap: handleLinkTap,
                    onItemsParsed: { items in
                        introItems = items
                        reportAllItems()
                    },
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
            }

            // Translation
            if let translation = unit.translation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translation")
                        .font(.system(size: (style.uiBodyFont?.pointSize ?? 17) - 4))
                        .foregroundColor(.secondary)

                    AnnotatedTextViewWithItems(
                        translation,
                        style: translationStyle,
                        baseOffset: translationOffset,
                        onLinkTap: handleLinkTap,
                        onItemsParsed: { items in
                            translationItems = items
                            reportAllItems()
                        }
                    )
                    .italic()
                }
                .padding(.vertical, 4)
            }

            // Commentary
            if let commentary = unit.commentary {
                AnnotatedTextViewWithItems(
                    commentary,
                    style: style,
                    baseOffset: commentaryOffset,
                    onLinkTap: handleLinkTap,
                    onItemsParsed: { items in
                        commentaryItems = items
                        reportAllItems()
                    },
                    shouldReportMatchOffset: shouldReportMatchOffset,
                    scrollCoordinateSpace: scrollCoordinateSpace
                )
            }
        }
    }

    private var titleFont: Font {
        let baseSize = style.uiBodyFont?.pointSize ?? 17
        switch unit.type {
        case .section:
            return unit.level == 1 ? .system(size: baseSize + 5, weight: .bold) : .system(size: baseSize + 3, weight: .bold)
        case .pericope:
            return .system(size: baseSize, weight: .bold)
        case .verse:
            return .system(size: baseSize - 2, weight: .semibold)
        }
    }

    private var verseReference: String {
        let startVerse = unit.sv % 1000
        let suffix = unit.suffix ?? ""

        if let ev = unit.ev {
            let endVerse = ev % 1000
            if endVerse != startVerse {
                return "vv. \(startVerse)\(suffix)–\(endVerse)"
            }
        }
        return "v. \(startVerse)\(suffix)"
    }

    private var translationStyle: CommentaryRenderer.Style {
        var s = style
        s.bodyFont = style.bodyFont.italic()
        if let uiFont = s.uiBodyFont {
            if let descriptor = uiFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                s.uiBodyFont = UIFont(descriptor: descriptor, size: 0)
            }
        }
        return s
    }

    private func handleLinkTap(_ index: Int) {
        // Check if it's a footnote tap
        let allItems = introItems + translationItems + commentaryItems
        if let item = allItems.first(where: { $0.index == index }) {
            if case .footnote(let id) = item.type {
                handleFootnoteTap(id)
                return
            }
        }
        // Otherwise forward to parent
        onLinkTap(index)
    }

    private func handleFootnoteTap(_ footnoteId: String) {
        guard let footnotes = unit.footnotes else { return }

        if let footnote = footnotes.first(where: { $0.id == footnoteId }) ??
                          footnotes.first(where: { $0.id.trimmingCharacters(in: .whitespaces) == footnoteId }) {
            onFootnoteTap?(footnoteId, footnote)
        }
    }

    private func reportAllItems() {
        let allItems = introItems + translationItems + commentaryItems
        onItemsParsed?(allItems)
    }
}

// MARK: - Helper Extensions

extension AttributedString {
    func index(_ index: AttributedString.Index, offsetByUnicodeScalars offset: Int) -> AttributedString.Index {
        var result = index
        var remaining = offset
        let chars = self.characters

        // Get underlying string to work with scalars
        let string = String(chars)
        let scalars = string.unicodeScalars

        // Find target scalar position
        var scalarIdx = scalars.startIndex
        var charOffset = 0
        var scalarCount = 0

        for char in string {
            let charScalarCount = char.unicodeScalars.count
            if scalarCount + charScalarCount > offset {
                // Target is within this character - but we can only index by whole characters
                // in AttributedString, so return the character containing this scalar
                break
            }
            scalarCount += charScalarCount
            charOffset += 1
        }

        // Now advance by charOffset characters in AttributedString
        result = index
        for _ in 0..<charOffset {
            guard result < self.endIndex else { break }
            result = self.index(afterCharacter: result)
        }

        return result
    }
}
