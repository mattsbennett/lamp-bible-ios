//
//  CommentaryRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-04.
//

import SwiftUI
import UIKit

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

            case .hebrew:
                result[range].font = style.hebrewFont
                result[range].foregroundColor = style.strongsColor.opacity(0.8)

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
                        let urlString = ev != nil ? "lampbible://verse/\(sv)/\(ev!)" : "lampbible://verse/\(sv)"
                        if let url = URL(string: urlString) {
                            result.addAttribute(.link, value: url, range: range)
                        }
                    }

                case .strongs:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }
                    if let key = annotation.data?.strongs ?? annotation.id,
                       let url = URL(string: "lampbible://strongs/\(key)") {
                        result.addAttribute(.link, value: url, range: range)
                    }

                case .greek:
                    result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .hebrew:
                     result.addAttribute(.foregroundColor, value: UIColor(style.strongsColor).withAlphaComponent(0.8), range: range)

                case .footnote:
                    result.addAttribute(.foregroundColor, value: UIColor(style.footnoteColor), range: range)
                    result.addAttribute(.baselineOffset, value: 4, range: range)
                    let fnFont = style.uiFootnoteFont ?? UIFont.preferredFont(forTextStyle: .footnote)
                    result.addAttribute(.font, value: fnFont, range: range)
                    if let id = annotation.id,
                       let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                       let url = URL(string: "lampbible://footnote/\(encodedId)") {
                        result.addAttribute(.link, value: url, range: range)
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
                    if let lexiconId = annotation.data?.lexiconId ?? annotation.id,
                       let url = URL(string: "lampbible://lexicon/\(lexiconId)") {
                        result.addAttribute(.link, value: url, range: range)
                    }

                case .bold:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
                    }

                case .italic:
                    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
                        result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
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
                if let encodedId = ref.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "lampbible://footnote/\(encodedId)") {
                    marker.addAttribute(.link, value: url, range: range)
                }

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
        shouldReportMatchOffset: Bool = false,
        scrollCoordinateSpace: String = "commentaryScroll"
    ) {
        self.annotatedText = annotatedText
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLexiconTap = onLexiconTap
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

private struct AnnotatedUITextViewRepresentable: UIViewRepresentable {
    let annotatedText: AnnotatedText
    let style: CommentaryRenderer.Style
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLexiconTap: ((String) -> Void)?

    // Scroll-to-match support
    var shouldReportMatchOffset: Bool = false
    var onFirstMatchOffset: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:] // Use attributes from annotated text

        // Disable editing features that might trigger system services
        textView.allowsEditingTextAttributes = false

        // Ensure default font and color are set for visibility
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label

        // Disable data detectors to prevent "com.apple.private.coreservices.canmaplsdatabase" logs
        // and avoid performance hits from system link detection
        textView.dataDetectorTypes = []

        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)

        // Performance optimization: Draw on background thread
        textView.layer.drawsAsynchronously = true

        textView.delegate = context.coordinator

        // Explicitly set text content type to none to avoid any smart suggestions
        textView.textContentType = .none

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

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
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
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
        Coordinator(self)
    }


    class Coordinator: NSObject, UITextViewDelegate {
        var parent: AnnotatedUITextViewRepresentable
        var lastText: String = ""
        var lastBodyFontSize: CGFloat = 0
        var cachedSize: CGSize?

        init(_ parent: AnnotatedUITextViewRepresentable) {
            self.parent = parent
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            handleURL(URL)
            return false
        }

        private func handleURL(_ url: URL) {
            guard url.scheme == "lampbible" else { return }

            let pathComponents = url.pathComponents

            // Handle URL-encoded components (e.g. from addingPercentEncoding)
            let valueRaw = pathComponents.count >= 2 ? pathComponents[1] : ""
            let value = valueRaw.removingPercentEncoding ?? valueRaw

            let type = url.host ?? ""

            switch type {
            case "verse":
                if let sv = Int(value) {
                    let ev = pathComponents.count >= 3 ? Int(pathComponents[2]) : nil
                    parent.onScriptureTap?(sv, ev)
                }
            case "strongs":
                parent.onStrongsTap?(value)
            case "footnote":
                parent.onFootnoteTap?(value)
            case "lexicon":
                parent.onLexiconTap?(value)
            default:
                break
            }
        }
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
