//
//  DevotionalBlockRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import SwiftUI
import UIKit

// MARK: - Footnote Helper

/// Strip ^ prefix from footnote IDs (handles old data that may have included the caret)
private func cleanFootnoteId(_ id: String) -> String {
    id.hasPrefix("^") ? String(id.dropFirst()) : id
}

// MARK: - Custom Tappable Attribute

/// Custom attribute key for tap action data (avoids iOS URL resolution delay)
private let DevotionalTapActionKey = NSAttributedString.Key("devotionalTapAction")

/// Tap action data stored in attributed string
private enum DevotionalTapAction {
    case verse(sv: Int, ev: Int?, translationId: String?)
    case strongs(key: String)
    case footnote(id: String)
    case externalURL(url: URL)
}

// MARK: - Lampbible URL Parser

/// Parses lampbible:// URLs in both formats:
/// - Human-readable: lampbible://gen1:1 or lampbible://gen1:1-5?translation=NIV
/// - Legacy numeric: lampbible://verse/43003016 or lampbible://verse/43003016/43003020?translation=NIV
enum LampbibleURL {
    case verse(verseId: Int, endVerseId: Int?, translationId: String?)
    case strongs(key: String)
    case external(url: URL)

    /// Parse a URL into a LampbibleURL
    static func parse(_ url: URL) -> LampbibleURL? {
        guard url.scheme == "lampbible" else {
            return .external(url: url)
        }

        // Extract translation from query string
        let translationId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "translation" })?
            .value

        let urlString = url.absoluteString
        // Remove query string for path parsing
        let pathOnly = urlString.split(separator: "?").first.map(String.init) ?? urlString

        // Handle legacy format: lampbible://verse/43003016
        if pathOnly.hasPrefix("lampbible://verse/") {
            let pathParts = pathOnly.dropFirst("lampbible://verse/".count).split(separator: "/")
            if let first = pathParts.first, let verseId = Int(first) {
                let endVerseId = pathParts.count > 1 ? Int(pathParts[1]) : nil
                return .verse(verseId: verseId, endVerseId: endVerseId, translationId: translationId)
            }
        }

        // Handle strongs format: lampbible://strongs/G1234
        if pathOnly.hasPrefix("lampbible://strongs/") {
            let key = String(pathOnly.dropFirst("lampbible://strongs/".count))
            if !key.isEmpty {
                return .strongs(key: key)
            }
        }

        // Handle human-readable format: lampbible://gen1:1 or lampbible://gen1:1-5
        // Pattern: bookOsisId + chapter + ":" + verse + optional("-" + endVerse)
        let path = String(pathOnly.dropFirst("lampbible://".count)).lowercased()

        // Use NSRegularExpression for compatibility
        let pattern = "^([a-z0-9]+)(\\d+):(\\d+)(?:-(\\d+))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) else {
            return nil
        }

        // Extract capture groups
        guard match.numberOfRanges >= 4,
              let osisRange = Range(match.range(at: 1), in: path),
              let chapterRange = Range(match.range(at: 2), in: path),
              let verseRange = Range(match.range(at: 3), in: path) else {
            return nil
        }

        let osisId = String(path[osisRange])
        guard let chapter = Int(path[chapterRange]),
              let verse = Int(path[verseRange]) else { return nil }

        // Look up book ID from OSIS ID
        guard let bookId = lookupBookId(osisId: osisId) else { return nil }

        let verseId = bookId * 1000000 + chapter * 1000 + verse
        var endVerseId: Int? = nil

        // Check for end verse (optional capture group 4)
        if match.numberOfRanges >= 5 && match.range(at: 4).location != NSNotFound,
           let endVerseRange = Range(match.range(at: 4), in: path),
           let endVerse = Int(path[endVerseRange]), endVerse > verse {
            endVerseId = bookId * 1000000 + chapter * 1000 + endVerse
        }

        return .verse(verseId: verseId, endVerseId: endVerseId, translationId: translationId)
    }

    /// Parse a URL string into a LampbibleURL
    static func parse(_ urlString: String) -> LampbibleURL? {
        guard let url = URL(string: urlString) else { return nil }
        return parse(url)
    }

    /// Look up book ID from OSIS ID
    private static func lookupBookId(osisId: String) -> Int? {
        // Cache for OSIS ID to book ID mapping
        struct Cache {
            static var osisToBookId: [String: Int]? = nil
        }

        if Cache.osisToBookId == nil {
            Cache.osisToBookId = [:]
            if let books = try? BundledModuleDatabase.shared.getAllBooks() {
                for book in books {
                    Cache.osisToBookId?[book.osisId.lowercased()] = book.id
                }
            }
        }

        return Cache.osisToBookId?[osisId.lowercased()]
    }
}

// MARK: - Devotional Renderer Style

struct DevotionalRendererStyle {
    var bodyFont: Font = .body
    var uiBodyFont: UIFont? = nil
    var textColor: Color = .primary
    var uiTextColor: UIColor = .label
    var headingFonts: [Int: Font] = [
        1: .system(size: 28, weight: .bold),
        2: .system(size: 24, weight: .bold),
        3: .system(size: 20, weight: .semibold),
        4: .system(size: 18, weight: .semibold),
        5: .system(size: 16, weight: .medium),
        6: .system(size: 14, weight: .medium)
    ]
    var blockquoteFont: Font = .body
    var blockquoteColor: Color = .secondary
    var listItemFont: Font = .body
    var scriptureColor: Color = .accentColor
    var strongsColor: Color = .accentColor
    var emphasisBoldColor: Color = .primary
    var emphasisItalicColor: Color = .primary
    var quoteColor: Color = .secondary
    var linkColor: Color = .blue
    var lineSpacing: CGFloat = 9       // fontSize * 0.5 at 18pt
    var paragraphSpacing: CGFloat = 14 // fontSize * 0.8 at 18pt
    var headingSpacing: CGFloat = 22   // fontSize * 1.2 at 18pt
    var listItemSpacing: CGFloat = 4   // Tighter spacing between list items

    // Multiplier for present mode
    var presentModeMultiplier: CGFloat = 1.0

    // Present mode removes indentation but keeps colors
    var isPresentMode: Bool = false

    static var `default` = DevotionalRendererStyle()

    func scaledBodyFont(multiplier: CGFloat) -> Font {
        guard multiplier != 1.0, let baseSize = uiBodyFont?.pointSize else {
            return bodyFont
        }
        return .system(size: baseSize * multiplier)
    }
}

// MARK: - Devotional Block Renderer

struct DevotionalBlockRenderer {

    // MARK: - Render to AttributedString

    /// Render DevotionalAnnotatedText to AttributedString
    static func render(_ annotatedText: DevotionalAnnotatedText, style: DevotionalRendererStyle = .default) -> AttributedString {
        var result = AttributedString(annotatedText.text)
        result.font = style.bodyFont

        // Calculate footnote font size relative to body font (matching visual edit mode)
        let baseFontSize = style.uiBodyFont?.pointSize ?? 17
        let footnoteFontSize = baseFontSize * 0.7
        let footnoteBaselineOffset = baseFontSize * 0.3

        guard let annotations = annotatedText.annotations else {
            // Still need to handle footnote refs even without other annotations (skip in present mode)
            if !style.isPresentMode, let footnoteRefs = annotatedText.footnoteRefs {
                let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
                for ref in sortedRefs {
                    guard ref.offset >= 0 else { continue }
                    let insertIndex = result.index(result.startIndex, offsetByUnicodeScalars: ref.offset)
                    let cleanId = cleanFootnoteId(ref.id)
                    var marker = AttributedString("[\(cleanId)]")
                    marker.foregroundColor = .accentColor
                    marker.font = .system(size: footnoteFontSize)
                    marker.baselineOffset = footnoteBaselineOffset
                    marker.link = URL(string: "lampbible://footnote/\(cleanId)")
                    result.insert(marker, at: insertIndex)
                }
            }
            return result
        }

        // Sort annotations by start position (reverse order for safe index manipulation)
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
                if let sv = annotation.data?.sv {
                    let urlString: String
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
                if let strongsKey = annotation.data?.strongs {
                    let key = strongsKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    result[range].link = URL(string: "lampbible://strongs/\(key)")
                }

            case .greek:
                result[range].font = style.bodyFont.italic()
                result[range].foregroundColor = style.strongsColor.opacity(0.8)

            case .hebrew:
                result[range].foregroundColor = style.strongsColor.opacity(0.8)

            case .link:
                result[range].foregroundColor = style.linkColor
                if let urlString = annotation.data?.url, let url = URL(string: urlString) {
                    result[range].link = url
                }

            case .emphasis:
                switch annotation.data?.style {
                case .bold:
                    result[range].font = style.bodyFont.bold()
                case .italic:
                    result[range].font = style.bodyFont.italic()
                case .underline:
                    result[range].underlineStyle = .single
                case .none:
                    break
                }

            case .quote:
                result[range].foregroundColor = style.quoteColor
                result[range].font = style.bodyFont.italic()
            }
        }

        // Insert footnote reference markers as [N] with superscript styling (skip in present mode)
        if !style.isPresentMode, let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                guard ref.offset >= 0 else { continue }
                let insertIndex = result.index(result.startIndex, offsetByUnicodeScalars: ref.offset)
                let cleanId = cleanFootnoteId(ref.id)
                var marker = AttributedString("[\(cleanId)]")
                marker.foregroundColor = .accentColor
                marker.font = .system(size: footnoteFontSize)
                marker.baselineOffset = footnoteBaselineOffset
                marker.link = URL(string: "lampbible://footnote/\(cleanId)")

                result.insert(marker, at: insertIndex)
            }
        }

        return result
    }

    // MARK: - UIKit Rendering

    static func renderUIKit(_ annotatedText: DevotionalAnnotatedText, style: DevotionalRendererStyle = .default) -> NSAttributedString {
        let text = annotatedText.text
        let result = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: result.length)

        // Base Attributes
        let baseFont = style.uiBodyFont ?? UIFont.preferredFont(forTextStyle: .body)
        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: style.uiTextColor, range: fullRange)

        // Helper to convert indices
        func getRange(_ start: Int, _ end: Int) -> NSRange? {
            let scalars = text.unicodeScalars
            guard start >= 0, end > start, start < scalars.count, end <= scalars.count else { return nil }

            let startIdx = scalars.index(scalars.startIndex, offsetBy: start)
            let endIdx = scalars.index(scalars.startIndex, offsetBy: end)

            return NSRange(startIdx..<endIdx, in: text)
        }

        // Check if we have scripture annotations - if not, auto-parse from plain text
        let hasScriptureAnnotations = annotatedText.annotations?.contains { $0.type == .scripture } ?? false

        if !hasScriptureAnnotations {
            // Auto-parse verse references from plain text
            let parser = VerseReferenceParser.shared
            let refs = parser.parse(text)
            for ref in refs {
                let nsRange = NSRange(ref.range, in: text)
                let verseId = ref.bookId * 1000000 + ref.chapter * 1000 + ref.startVerse
                let endVerseId = ref.endVerse.map { ref.bookId * 1000000 + ref.chapter * 1000 + $0 }
                // Extract translation from text after reference
                let translationId = extractTranslationAfterRange(text: text, range: ref.range)
                result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: nsRange)
                result.addAttribute(DevotionalTapActionKey, value: DevotionalTapAction.verse(sv: verseId, ev: endVerseId, translationId: translationId), range: nsRange)
            }
        }

        if let annotations = annotatedText.annotations {
            for annotation in annotations {
                guard let range = getRange(annotation.start, annotation.end) else { continue }

                switch annotation.type {
                case .scripture:
                    result.addAttribute(.foregroundColor, value: UIColor(style.scriptureColor), range: range)
                    if let sv = annotation.data?.sv {
                        let ev = annotation.data?.ev
                        // Get translation from annotation data or extract from text after annotation
                        let translationId = annotation.data?.translationId ?? extractTranslationAfterIndex(text: text, index: annotation.end)
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(DevotionalTapActionKey, value: DevotionalTapAction.verse(sv: sv, ev: ev, translationId: translationId), range: range)
                    }

                case .strongs:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    if let key = annotation.data?.strongs {
                        // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                        result.addAttribute(DevotionalTapActionKey, value: DevotionalTapAction.strongs(key: key), range: range)
                    }

                case .greek:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .hebrew:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)

                case .link:
                    result.addAttribute(.foregroundColor, value: UIColor(style.linkColor), range: range)
                    if let urlString = annotation.data?.url, let url = URL(string: urlString) {
                        // Use custom tappable attribute for external URLs too
                        result.addAttribute(DevotionalTapActionKey, value: DevotionalTapAction.externalURL(url: url), range: range)
                    }

                case .emphasis:
                    switch annotation.data?.style {
                    case .bold:
                        if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                            result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                        }
                    case .italic:
                        if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                            result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                        }
                    case .underline:
                        result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                    case .none:
                        break
                    }

                case .quote:
                    result.addAttribute(.foregroundColor, value: UIColor(style.quoteColor), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                }
            }
        }

        // Insert Footnotes as [N] with superscript styling (skip in present mode)
        if !style.isPresentMode, let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            // Calculate relative font size (70% of body, 30% baseline offset)
            let footnoteFontSize = baseFont.pointSize * 0.7
            let footnoteBaselineOffset = baseFont.pointSize * 0.3

            for ref in sortedRefs {
                let scalars = text.unicodeScalars
                guard ref.offset >= 0, ref.offset <= scalars.count else { continue }
                let idx = scalars.index(scalars.startIndex, offsetBy: min(ref.offset, scalars.count))
                let nsRange = NSRange(idx..<idx, in: text)

                let cleanId = cleanFootnoteId(ref.id)
                let marker = NSMutableAttributedString(string: "[\(cleanId)]")
                let fnFont = UIFont.systemFont(ofSize: footnoteFontSize)
                let markerRange = NSRange(location: 0, length: marker.length)

                marker.addAttribute(.font, value: fnFont, range: markerRange)
                marker.addAttribute(.foregroundColor, value: UIColor.tintColor, range: markerRange)
                marker.addAttribute(.baselineOffset, value: footnoteBaselineOffset as NSNumber, range: markerRange)
                // Use custom tappable attribute instead of URL to avoid iOS URL resolution delay
                marker.addAttribute(DevotionalTapActionKey, value: DevotionalTapAction.footnote(id: cleanId), range: markerRange)

                result.insert(marker, at: nsRange.location)
            }
        }

        // Line and paragraph spacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        paragraphStyle.paragraphSpacing = style.paragraphSpacing
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))

        return result
    }

    /// Extract translation ID from text after a string range
    private static func extractTranslationAfterRange(text: String, range: Range<String.Index>) -> String? {
        let afterRef = String(text[range.upperBound...])
        return extractTranslationFromStart(afterRef)
    }

    /// Extract translation ID from text after a character index
    private static func extractTranslationAfterIndex(text: String, index: Int) -> String? {
        let scalars = text.unicodeScalars
        guard index < scalars.count else { return nil }
        let endIdx = scalars.index(scalars.startIndex, offsetBy: index)
        guard let endStringIdx = endIdx.samePosition(in: text) else { return nil }
        let afterAnnotation = String(text[endStringIdx...])
        return extractTranslationFromStart(afterAnnotation)
    }

    /// Extract translation from the start of a string
    private static func extractTranslationFromStart(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Get first word by splitting on whitespace AND newlines
        let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map { String($0) }
        guard let word = firstWord else { return nil }
        // Strip punctuation and check
        let cleaned = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        return isKnownTranslation(cleaned)
    }

    /// Check if a string is a known translation ID, returns normalized ID or nil
    private static func isKnownTranslation(_ id: String) -> String? {
        let knownTranslations: Set<String> = [
            "NIV", "ESV", "KJV", "NKJV", "NLT", "NASB", "NASB95", "NASB20",
            "CSB", "HCSB", "RSV", "NRSV", "ASV", "AMP", "MSG", "NET", "NCV",
            "CEV", "GNT", "GNB", "TEV", "TLB", "PHILLIPS", "WEB", "YLT",
            "DARBY", "DRB", "ERV", "EXB", "GW", "ICB", "ISV", "JUB", "LEB",
            "MEV", "MOUNCE", "NABRE", "NIRV", "NIVUK", "OJB", "RGT", "TPT",
            "VOICE", "WE", "WYC", "BSB", "LSB", "NRSVUE"
        ]
        if knownTranslations.contains(id) { return id }
        // Check plural form (e.g., "KJVs", "BSBs")
        if id.hasSuffix("S"), id.count > 1 {
            let singular = String(id.dropLast())
            if knownTranslations.contains(singular) { return singular }
        }
        return nil
    }
}

// MARK: - SwiftUI Views for Devotional Content

struct DevotionalAnnotatedTextView: View {
    let annotatedText: DevotionalAnnotatedText
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?, String?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    init(
        _ annotatedText: DevotionalAnnotatedText,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?, String?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.annotatedText = annotatedText
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLinkTap = onLinkTap
    }

    var body: some View {
        DevotionalUITextViewRepresentable(
            annotatedText: annotatedText,
            style: style,
            onScriptureTap: onScriptureTap,
            onStrongsTap: onStrongsTap,
            onFootnoteTap: onFootnoteTap,
            onLinkTap: onLinkTap
        )
    }
}

// MARK: - Tappable Devotional Text View

/// Custom UITextView that uses tap gestures instead of URL-based link handling
/// This avoids the iOS URL resolution delay ("canmaplsdatabase" error)
private class TappableDevotionalTextView: UITextView {
    var onScriptureTap: ((Int, Int?, String?) -> Void)?
    var onStrongsTap: ((String) -> Void)?
    var onFootnoteTap: ((String) -> Void)?
    var onLinkTap: ((URL) -> Void)?

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

        if let action = attributes[DevotionalTapActionKey] as? DevotionalTapAction {
            switch action {
            case .verse(let sv, let ev, let translationId):
                onScriptureTap?(sv, ev, translationId)
            case .strongs(let key):
                onStrongsTap?(key)
            case .footnote(let id):
                onFootnoteTap?(id)
            case .externalURL(let url):
                onLinkTap?(url)
            }
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

private struct DevotionalUITextViewRepresentable: UIViewRepresentable {
    let annotatedText: DevotionalAnnotatedText
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?, String?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    func makeUIView(context: Context) -> TappableDevotionalTextView {
        let textView = TappableDevotionalTextView()
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

    func updateUIView(_ textView: TappableDevotionalTextView, context: Context) {
        // Set up tap handlers
        textView.onScriptureTap = onScriptureTap
        textView.onStrongsTap = onStrongsTap
        textView.onFootnoteTap = onFootnoteTap
        textView.onLinkTap = onLinkTap

        textView.textColor = .label
        let nsAttributed = DevotionalBlockRenderer.renderUIKit(annotatedText, style: style)
        textView.attributedText = nsAttributed
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableDevotionalTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        // No longer need coordinator state since tap handling is in the text view
    }
}

// MARK: - Content Block View

struct DevotionalContentBlockView: View {
    let block: DevotionalContentBlock
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?, String?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    // Media context for image/audio blocks
    let mediaRefs: [DevotionalMediaReference]?
    let devotionalId: String?
    let moduleId: String?
    let onImageTap: ((DevotionalMediaReference, URL?) -> Void)?

    init(
        block: DevotionalContentBlock,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?, String?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil,
        mediaRefs: [DevotionalMediaReference]? = nil,
        devotionalId: String? = nil,
        moduleId: String? = nil,
        onImageTap: ((DevotionalMediaReference, URL?) -> Void)? = nil
    ) {
        self.block = block
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLinkTap = onLinkTap
        self.mediaRefs = mediaRefs
        self.devotionalId = devotionalId
        self.moduleId = moduleId
        self.onImageTap = onImageTap
    }

    var body: some View {
        switch block.type {
        case .paragraph:
            if let content = block.content {
                DevotionalAnnotatedTextView(
                    content,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap
                )
            }

        case .heading:
            if let content = block.content {
                Text(content.text)
                    .font(headingFont)
                    .fontWeight(.bold)
            }

        case .blockquote:
            if let content = block.content {
                DevotionalAnnotatedTextView(
                    content,
                    style: blockquoteStyle,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap
                )
                .padding(.leading, style.isPresentMode ? 0 : 20)
            }

        case .list:
            if let items = block.items {
                VStack(alignment: .leading, spacing: style.listItemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        listItemView(item: item, index: index, depth: 0)
                    }
                }
            }

        case .image:
            imageBlockView

        case .audio:
            audioBlockView
        }
    }

    // MARK: - Image Block

    @ViewBuilder
    private var imageBlockView: some View {
        if let mediaId = block.mediaId,
           let mediaRef = mediaRefs?.first(where: { $0.id == mediaId }),
           let devId = devotionalId,
           let modId = moduleId {
            let imageURL = DevotionalMediaStorage.shared.getMediaURL(
                for: mediaRef,
                devotionalId: devId,
                moduleId: modId
            )
            ImageBlockView(
                block: block,
                mediaRef: mediaRef,
                imageURL: imageURL,
                alignment: block.alignment ?? .center,
                onTap: {
                    onImageTap?(mediaRef, imageURL)
                }
            )
        } else {
            // Placeholder for missing media
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Image not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
        }
    }

    // MARK: - Audio Block

    @ViewBuilder
    private var audioBlockView: some View {
        if let mediaId = block.mediaId,
           let mediaRef = mediaRefs?.first(where: { $0.id == mediaId }),
           let devId = devotionalId,
           let modId = moduleId {
            let audioURL = DevotionalMediaStorage.shared.getMediaURL(
                for: mediaRef,
                devotionalId: devId,
                moduleId: modId
            )
            if style.isPresentMode && block.autoplay == true {
                PresentModeAudioBlockView(
                    block: block,
                    mediaRef: mediaRef,
                    audioURL: audioURL
                )
            } else {
                AudioBlockView(
                    block: block,
                    mediaRef: mediaRef,
                    audioURL: audioURL,
                    showWaveform: block.showWaveform ?? true
                )
            }
        } else {
            // Placeholder for missing media
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Audio not found")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    private var headingFont: Font {
        let level = block.level ?? 1
        return style.headingFonts[level] ?? .system(size: 16, weight: .bold)
    }

    private var blockquoteStyle: DevotionalRendererStyle {
        var s = style
        s.bodyFont = style.blockquoteFont
        s.textColor = style.blockquoteColor
        s.uiTextColor = UIColor.secondaryLabel
        s.paragraphSpacing = 0  // No paragraph spacing - VStack padding handles inter-block spacing
        // In present mode, links should inherit the blockquote text color
        if style.isPresentMode {
            s.linkColor = style.blockquoteColor
            s.scriptureColor = style.blockquoteColor
            s.strongsColor = style.blockquoteColor
        }
        return s
    }

    private var listItemContentStyle: DevotionalRendererStyle {
        var s = style
        s.paragraphSpacing = 0  // No extra paragraph spacing within list items
        return s
    }

    @ViewBuilder
    private func listItemView(item: DevotionalListItem, index: Int, depth: Int) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 8) {
                // Bullet or number
                if block.listType == .numbered {
                    Text("\(index + 1).")
                        .font(style.listItemFont)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                } else {
                    Text("•")
                        .font(style.listItemFont)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: style.listItemSpacing) {
                    DevotionalAnnotatedTextView(
                        item.content,
                        style: listItemContentStyle,
                        onScriptureTap: onScriptureTap,
                        onStrongsTap: onStrongsTap,
                        onFootnoteTap: onFootnoteTap,
                        onLinkTap: onLinkTap
                    )

                    // Nested items
                    if let children = item.children {
                        ForEach(Array(children.enumerated()), id: \.offset) { childIndex, child in
                            listItemView(item: child, index: childIndex, depth: depth + 1)
                        }
                    }
                }
            }
            .padding(.leading, style.isPresentMode ? 0 : CGFloat(depth) * 20)
        )
    }
}

// MARK: - Full Devotional Content Renderer

struct DevotionalContentRenderer: View {
    let content: DevotionalContent
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?, String?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    // Media context
    let mediaRefs: [DevotionalMediaReference]?
    let devotionalId: String?
    let moduleId: String?
    let onImageTap: ((DevotionalMediaReference, URL?) -> Void)?

    init(
        content: DevotionalContent,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?, String?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil,
        mediaRefs: [DevotionalMediaReference]? = nil,
        devotionalId: String? = nil,
        moduleId: String? = nil,
        onImageTap: ((DevotionalMediaReference, URL?) -> Void)? = nil
    ) {
        self.content = content
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLinkTap = onLinkTap
        self.mediaRefs = mediaRefs
        self.devotionalId = devotionalId
        self.moduleId = moduleId
        self.onImageTap = onImageTap
    }

    var body: some View {
        // Use custom spacing logic to match visual editor behavior
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case .blocks(let blocks):
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    DevotionalContentBlockView(
                        block: block,
                        style: style,
                        onScriptureTap: onScriptureTap,
                        onStrongsTap: onStrongsTap,
                        onFootnoteTap: onFootnoteTap,
                        onLinkTap: onLinkTap,
                        mediaRefs: mediaRefs,
                        devotionalId: devotionalId,
                        moduleId: moduleId,
                        onImageTap: onImageTap
                    )
                    .padding(.bottom, spacingAfter(block: block, nextBlock: blocks.indices.contains(index + 1) ? blocks[index + 1] : nil))
                }

            case .structured(let structured):
                renderStructuredContent(structured)
            }
        }
    }

    /// Calculate spacing after a block based on the next block type
    /// - Consecutive blockquotes get zero spacing (matching visual editor)
    /// - All other blocks get normal paragraph + line spacing
    private func spacingAfter(block: DevotionalContentBlock, nextBlock: DevotionalContentBlock?) -> CGFloat {
        // No spacing after the last block
        guard nextBlock != nil else { return 0 }

        // Consecutive blockquotes get zero spacing
        if block.type == .blockquote, nextBlock?.type == .blockquote {
            return 0
        }

        // All other blocks get normal spacing
        return style.paragraphSpacing + style.lineSpacing
    }

    @ViewBuilder
    private func renderStructuredContent(_ structured: DevotionalStructuredContent) -> some View {
        // Introduction
        if let intro = structured.introduction {
            ForEach(Array(intro.enumerated()), id: \.element.id) { index, block in
                DevotionalContentBlockView(
                    block: block,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap,
                    mediaRefs: mediaRefs,
                    devotionalId: devotionalId,
                    moduleId: moduleId,
                    onImageTap: onImageTap
                )
                .padding(.bottom, spacingAfter(block: block, nextBlock: intro.indices.contains(index + 1) ? intro[index + 1] : nil))
            }
        }

        // Sections
        if let sections = structured.sections {
            ForEach(sections) { section in
                renderSection(section)
            }
        }

        // Conclusion
        if let conclusion = structured.conclusion {
            ForEach(Array(conclusion.enumerated()), id: \.element.id) { index, block in
                DevotionalContentBlockView(
                    block: block,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap,
                    mediaRefs: mediaRefs,
                    devotionalId: devotionalId,
                    moduleId: moduleId,
                    onImageTap: onImageTap
                )
                .padding(.bottom, spacingAfter(block: block, nextBlock: conclusion.indices.contains(index + 1) ? conclusion[index + 1] : nil))
            }
        }
    }

    @ViewBuilder
    private func renderSection(_ section: DevotionalSection) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                // Section title
                Text(section.title)
                    .font(sectionFont(level: section.level ?? 1))
                    .fontWeight(.bold)
                    .padding(.bottom, style.paragraphSpacing + style.lineSpacing)

                // Section blocks
                if let blocks = section.blocks {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        DevotionalContentBlockView(
                            block: block,
                            style: style,
                            onScriptureTap: onScriptureTap,
                            onStrongsTap: onStrongsTap,
                            onFootnoteTap: onFootnoteTap,
                            onLinkTap: onLinkTap,
                            mediaRefs: mediaRefs,
                            devotionalId: devotionalId,
                            moduleId: moduleId,
                            onImageTap: onImageTap
                        )
                        .padding(.bottom, spacingAfter(block: block, nextBlock: blocks.indices.contains(index + 1) ? blocks[index + 1] : nil))
                    }
                }

                // Subsections
                if let subsections = section.subsections {
                    ForEach(subsections) { subsection in
                        renderSection(subsection)
                    }
                }
            }
        )
    }

    private func sectionFont(level: Int) -> Font {
        style.headingFonts[level] ?? .system(size: 16, weight: .bold)
    }
}

// MARK: - Footnotes Renderer

struct DevotionalFootnotesView: View {
    let footnotes: [DevotionalFootnote]
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?, String?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            ForEach(footnotes) { footnote in
                let cleanId = cleanFootnoteId(footnote.id)
                HStack(alignment: .top, spacing: 6) {
                    Text("[\(cleanId)]")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                        .frame(minWidth: 24, alignment: .trailing)

                    Group {
                        switch footnote.content {
                        case .plain(let text):
                            Text(text)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        case .annotated(let annotatedText):
                            DevotionalAnnotatedTextView(
                                annotatedText,
                                style: footnoteStyle,
                                onScriptureTap: onScriptureTap,
                                onStrongsTap: onStrongsTap,
                                onLinkTap: onLinkTap
                            )
                        }
                    }
                }
                .id("footnote-\(cleanId)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var footnoteStyle: DevotionalRendererStyle {
        var s = style
        s.bodyFont = .footnote
        s.textColor = .secondary
        return s
    }
}

