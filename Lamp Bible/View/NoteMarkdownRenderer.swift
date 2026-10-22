//
//  NoteMarkdownRenderer.swift
//  Lamp Bible
//

import UIKit

/// A note's Markdown as the reader sees it, drawn natively.
///
/// Read line by line, as the notes editor reads it (`setLineBreaks`): a note
/// typed as plain text breaks its lines where it was typed, where Markdown
/// would run them together. Each line may open a heading, a list item, a
/// quote or a rule; within it, emphasis, code, links and escapes are read by
/// Foundation's own inline Markdown.
enum NoteMarkdown {
    /// An app link to a verse, `lampbible://verse/<start>[/<end>]`, and where
    /// its text ended up.
    struct VerseLink: Equatable {
        let range: NSRange
        let verseId: Int
        let endVerseId: Int?
    }

    struct Rendered {
        let text: NSMutableAttributedString
        let verseLinks: [VerseLink]
    }

    static func render(_ markdown: String, fontSize: CGFloat) -> Rendered {
        let out = NSMutableAttributedString()
        var links: [VerseLink] = []
        let lines = markdown.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let block = Block(raw)
            let style = paragraphStyle(fontSize: fontSize, block: block)
            var attributes = baseAttributes(fontSize: block.fontSize(fontSize), bold: block.isHeading)
            attributes[.paragraphStyle] = style
            if block.isQuote { attributes[.foregroundColor] = UIColor.secondaryLabel }

            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: attributes)) }
            if let prefix = block.prefix {
                out.append(NSAttributedString(string: prefix, attributes: attributes))
            }
            if block.isRule {
                var rule = attributes
                rule[.foregroundColor] = UIColor.separator
                out.append(NSAttributedString(string: "———", attributes: rule))
                continue
            }
            let line = inline(block.text, attributes: attributes, fontSize: block.fontSize(fontSize), bold: block.isHeading)
            for link in line.links {
                links.append(VerseLink(
                    range: NSRange(location: link.range.location + out.length, length: link.range.length),
                    verseId: link.verseId, endVerseId: link.endVerseId
                ))
            }
            out.append(line.text)
        }
        return Rendered(text: out, verseLinks: links)
    }

    // MARK: Blocks

    /// What one line opens, and the text after its marker.
    struct Block {
        enum Kind: Equatable { case text, heading(Int), bullet, ordered(String), quote, rule }
        let kind: Kind
        let level: Int
        let text: String

        init(_ line: String) {
            if let m = line.wholeMatch(of: #/(#{1,6})\s+(.*)/#) {
                kind = .heading(m.1.count); level = 0; text = String(m.2)
            } else if line.wholeMatch(of: #/\s*(?:-{3,}|\*{3,}|_{3,})\s*/#) != nil {
                kind = .rule; level = 0; text = ""
            } else if let m = line.wholeMatch(of: #/(\s*)[-*+]\s+(.*)/#) {
                kind = .bullet; level = Block.level(m.1); text = String(m.2)
            } else if let m = line.wholeMatch(of: #/(\s*)(\d{1,9}[.)])\s+(.*)/#) {
                kind = .ordered(String(m.2)); level = Block.level(m.1); text = String(m.3)
            } else if let m = line.wholeMatch(of: #/>\s?(.*)/#) {
                kind = .quote; level = 0; text = String(m.1)
            } else {
                kind = .text; level = 0; text = line
            }
        }

        /// Nesting from indentation: the editor indents a nested item by
        /// at least two spaces.
        private static func level(_ indent: Substring) -> Int {
            min(indent.replacingOccurrences(of: "\t", with: "    ").count / 2, 6)
        }

        var isHeading: Bool { if case .heading = kind { return true } else { return false } }
        var isQuote: Bool { kind == .quote }
        var isRule: Bool { kind == .rule }

        var prefix: String? {
            switch kind {
            case .bullet: return "•\t"
            case .ordered(let marker): return "\(marker)\t"
            default: return nil
            }
        }

        func fontSize(_ base: CGFloat) -> CGFloat {
            switch kind {
            case .heading(1): return base * 1.3
            case .heading(2): return base * 1.2
            case .heading: return base * 1.1
            default: return base
            }
        }
    }

    private static func paragraphStyle(fontSize: CGFloat, block: Block) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.35
        let step = fontSize * 1.4
        switch block.kind {
        case .bullet, .ordered:
            let indent = CGFloat(block.level) * step
            style.firstLineHeadIndent = indent
            style.headIndent = indent + step
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + step)]
            style.defaultTabInterval = step
        case .quote:
            style.firstLineHeadIndent = fontSize
            style.headIndent = fontSize
        default:
            break
        }
        return style
    }

    static func baseAttributes(fontSize: CGFloat, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize, bold: bold, italic: false, code: false),
            .foregroundColor: UIColor.label,
        ]
    }

    // MARK: Inline

    private struct InlineLink {
        let range: NSRange
        let verseId: Int
        let endVerseId: Int?
    }

    private static func inline(
        _ text: String, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat, bold: Bool
    ) -> (text: NSAttributedString, links: [InlineLink]) {
        guard !text.isEmpty else { return (NSAttributedString(), []) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return (NSAttributedString(string: text, attributes: attributes), [])
        }
        let out = NSMutableAttributedString()
        var links: [InlineLink] = []
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runAttributes = attributes
            let intent = run.inlinePresentationIntent ?? []
            runAttributes[.font] = font(
                size: fontSize,
                bold: bold || intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                code: intent.contains(.code)
            )
            if intent.contains(.strikethrough) {
                runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                runAttributes[.foregroundColor] = UIColor.systemBlue
                if let verse = verseLink(url) {
                    links.append(InlineLink(
                        range: NSRange(location: out.length, length: (piece as NSString).length),
                        verseId: verse.start, endVerseId: verse.end
                    ))
                }
            }
            out.append(NSAttributedString(string: piece, attributes: runAttributes))
        }
        return (out, links)
    }

    /// `lampbible://verse/<start>[/<end>]`, the app's link to a passage.
    static func verseLink(_ url: URL) -> (start: Int, end: Int?)? {
        guard url.scheme == "lampbible", url.host == "verse" else { return nil }
        let parts = url.path.split(separator: "/").compactMap { Int($0) }
        guard let start = parts.first else { return nil }
        return (start, parts.count > 1 ? parts[1] : nil)
    }

    private static func font(size: CGFloat, bold: Bool, italic: Bool, code: Bool) -> UIFont {
        if code {
            return .monospacedSystemFont(ofSize: size * 0.95, weight: bold ? .semibold : .regular)
        }
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
