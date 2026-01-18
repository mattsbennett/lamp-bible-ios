//
//  DevotionalBlockRenderer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import SwiftUI
import UIKit

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

        guard let annotations = annotatedText.annotations else {
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

        // Insert footnote reference markers
        if let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                guard ref.offset >= 0 else { continue }
                let insertIndex = result.index(result.startIndex, offsetByUnicodeScalars: ref.offset)
                var marker = AttributedString("[\(ref.id)]")
                marker.foregroundColor = .secondary
                marker.font = .footnote
                marker.baselineOffset = 4
                marker.link = URL(string: "lampbible://footnote/\(ref.id)")

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
                    if let key = annotation.data?.strongs,
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

                case .link:
                    result.addAttribute(.foregroundColor, value: UIColor(style.linkColor), range: range)
                    if let urlString = annotation.data?.url, let url = URL(string: urlString) {
                        result.addAttribute(.link, value: url, range: range)
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

        // Insert Footnotes
        if let footnoteRefs = annotatedText.footnoteRefs {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                let scalars = text.unicodeScalars
                guard ref.offset >= 0, ref.offset <= scalars.count else { continue }
                let idx = scalars.index(scalars.startIndex, offsetBy: ref.offset)
                let nsRange = NSRange(idx..<idx, in: text)

                let marker = NSMutableAttributedString(string: "[\(ref.id)]")
                let fnFont = UIFont.preferredFont(forTextStyle: .footnote)
                let markerRange = NSRange(location: 0, length: marker.length)

                marker.addAttribute(.font, value: fnFont, range: markerRange)
                marker.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: markerRange)
                marker.addAttribute(.baselineOffset, value: 4, range: markerRange)
                if let encodedId = ref.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                   let url = URL(string: "lampbible://footnote/\(encodedId)") {
                    marker.addAttribute(.link, value: url, range: markerRange)
                }

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
}

// MARK: - SwiftUI Views for Devotional Content

struct DevotionalAnnotatedTextView: View {
    let annotatedText: DevotionalAnnotatedText
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    init(
        _ annotatedText: DevotionalAnnotatedText,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?) -> Void)? = nil,
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

private struct DevotionalUITextViewRepresentable: UIViewRepresentable {
    let annotatedText: DevotionalAnnotatedText
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
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
        textView.delegate = context.coordinator
        textView.textContentType = .none

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.textColor = .label
        let nsAttributed = DevotionalBlockRenderer.renderUIKit(annotatedText, style: style)
        textView.attributedText = nsAttributed
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: DevotionalUITextViewRepresentable

        init(_ parent: DevotionalUITextViewRepresentable) {
            self.parent = parent
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            handleURL(URL)
            return false
        }

        private func handleURL(_ url: URL) {
            guard url.scheme == "lampbible" else {
                // External URL
                parent.onLinkTap?(url)
                return
            }

            let pathComponents = url.pathComponents
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
            default:
                break
            }
        }
    }
}

// MARK: - Content Block View

struct DevotionalContentBlockView: View {
    let block: DevotionalContentBlock
    let style: DevotionalRendererStyle
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    init(
        block: DevotionalContentBlock,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.block = block
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLinkTap = onLinkTap
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
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String) -> Void)?
    let onLinkTap: ((URL) -> Void)?

    init(
        content: DevotionalContent,
        style: DevotionalRendererStyle = .default,
        onScriptureTap: ((Int, Int?) -> Void)? = nil,
        onStrongsTap: ((String) -> Void)? = nil,
        onFootnoteTap: ((String) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.content = content
        self.style = style
        self.onScriptureTap = onScriptureTap
        self.onStrongsTap = onStrongsTap
        self.onFootnoteTap = onFootnoteTap
        self.onLinkTap = onLinkTap
    }

    var body: some View {
        // Use paragraphSpacing + lineSpacing for VStack spacing to match visual editor
        // (visual editor has paragraphSpacing after newlines plus line height contribution)
        VStack(alignment: .leading, spacing: style.paragraphSpacing + style.lineSpacing) {
            switch content {
            case .blocks(let blocks):
                ForEach(blocks) { block in
                    DevotionalContentBlockView(
                        block: block,
                        style: style,
                        onScriptureTap: onScriptureTap,
                        onStrongsTap: onStrongsTap,
                        onFootnoteTap: onFootnoteTap,
                        onLinkTap: onLinkTap
                    )
                }

            case .structured(let structured):
                renderStructuredContent(structured)
            }
        }
    }

    @ViewBuilder
    private func renderStructuredContent(_ structured: DevotionalStructuredContent) -> some View {
        // Introduction
        if let intro = structured.introduction {
            ForEach(intro) { block in
                DevotionalContentBlockView(
                    block: block,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap
                )
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
            ForEach(conclusion) { block in
                DevotionalContentBlockView(
                    block: block,
                    style: style,
                    onScriptureTap: onScriptureTap,
                    onStrongsTap: onStrongsTap,
                    onFootnoteTap: onFootnoteTap,
                    onLinkTap: onLinkTap
                )
            }
        }
    }

    @ViewBuilder
    private func renderSection(_ section: DevotionalSection) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: style.paragraphSpacing + style.lineSpacing) {
                // Section title
                Text(section.title)
                    .font(sectionFont(level: section.level ?? 1))
                    .fontWeight(.bold)

                // Section blocks
                if let blocks = section.blocks {
                    ForEach(blocks) { block in
                        DevotionalContentBlockView(
                            block: block,
                            style: style,
                            onScriptureTap: onScriptureTap,
                            onStrongsTap: onStrongsTap,
                            onFootnoteTap: onFootnoteTap,
                            onLinkTap: onLinkTap
                        )
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
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(footnotes) { footnote in
                HStack(alignment: .top, spacing: 8) {
                    Text("[\(footnote.id)]")
                        .font(.footnote.bold())
                        .foregroundColor(.secondary)

                    Group {
                        switch footnote.content {
                        case .plain(let text):
                            Text(text)
                                .font(.footnote)
                        case .annotated(let annotatedText):
                            DevotionalAnnotatedTextView(
                                annotatedText,
                                style: footnoteStyle,
                                onScriptureTap: onScriptureTap,
                                onStrongsTap: onStrongsTap
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private var footnoteStyle: DevotionalRendererStyle {
        var s = style
        s.bodyFont = .footnote
        return s
    }
}

