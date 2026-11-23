//
//  NoteMarkdownRenderer.swift
//  Lamp Bible
//

import ImageIO
import LampCore
import UIKit

/// A note's Markdown as the reader sees it, drawn natively.
///
/// Read line by line, as the notes editor reads it (`setLineBreaks`): a note
/// typed as plain text breaks its lines where it was typed, where Markdown
/// would run them together. Each line may open a heading, a list item, a
/// quote or a rule; within it, emphasis, code, links and escapes are read by
/// Foundation's own inline Markdown. A line that is only a picture, as the
/// editor writes one (`![caption](media/<id>)`), is drawn as the picture. A
/// picture within a line, as a notes module marks a span of its sentence
/// with one, leaves the span in the sentence, marked, and is drawn after
/// the line with the span as its caption.
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

    /// `media` is where each of the note's pictures is on this device, by id.
    /// `serif` and `lineSpacing` are the tool panel's settings; without them
    /// a note is set as it always was, in sans, its lines a third of its size
    /// apart. `linksTapped` keeps each link's target on its text, for a text
    /// view that opens it, as a note's doesn't.
    /// `options`: a note's by default, each typed line its own; prose (an
    /// agent's reply) reads with a writing's, a soft wrap joining.
    static func render(
        _ markdown: String, fontSize: CGFloat, serif: Bool = false, lineSpacing: CGFloat? = nil,
        media: [String: URL] = [:], linksTapped: Bool = false, options: LampProseOptions = .note
    ) -> Rendered {
        let out = NSMutableAttributedString()
        var links: [VerseLink] = []
        // Read by core as the note editor reads it (LampProse), laid out a
        // line at a time.
        let lines = Self.lines(LampProse.blocks(markdown, options: options))
        for (index, line) in lines.enumerated() {
            let base = baseAttributes(fontSize: fontSize, serif: serif)
            switch line.content {
            case .gap:
                // A blank line between blocks, where the writer left one.
                if index > 0 { out.append(NSAttributedString(string: "\n", attributes: base)) }
                continue
            case let .picture(path, caption):
                if index > 0 { out.append(NSAttributedString(string: "\n", attributes: base)) }
                let drawn = NSMutableAttributedString(
                    attributedString: self.picture(mediaURL(path, in: media), caption: caption, fontSize: fontSize, serif: serif)
                )
                // In a quotation, set in with it.
                if line.quoted {
                    let shift = fontSize * CGFloat(line.quoteDepth)
                    drawn.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: drawn.length)) { value, range, _ in
                        guard let inset = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                        inset.firstLineHeadIndent += shift
                        inset.headIndent += shift
                        drawn.addAttribute(.paragraphStyle, value: inset, range: range)
                    }
                }
                out.append(drawn)
                continue
            default:
                break
            }
            let block = line.block
            var style = paragraphStyle(fontSize: fontSize, block: block, lineSpacing: lineSpacing)
            // Set in a step for each quotation holding it (a quote line's
            // style takes the first), so a quotation within one shows.
            let steps = line.quoteDepth - (block.kind == .quote ? 1 : 0)
            if steps > 0, let inset = style.mutableCopy() as? NSMutableParagraphStyle {
                let shift = fontSize * CGFloat(steps)
                inset.firstLineHeadIndent += shift
                inset.headIndent += shift
                inset.tabStops = inset.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + shift) }
                style = inset
            }
            var attributes = baseAttributes(fontSize: block.fontSize(fontSize), bold: block.isHeading, serif: serif)
            attributes[.paragraphStyle] = style
            if line.quoted { attributes[.foregroundColor] = UIColor.secondaryLabel }

            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: attributes)) }
            if let prefix = block.prefix {
                out.append(NSAttributedString(string: prefix, attributes: attributes))
            }
            switch line.content {
            case .rule:
                var rule = attributes
                rule[.foregroundColor] = UIColor.separator
                out.append(NSAttributedString(string: "———", attributes: rule))
                continue
            case let .plain(words, code):
                var plain = attributes
                if code {
                    plain[.font] = font(size: block.fontSize(fontSize), bold: false, italic: false, code: true, serif: serif)
                    plain[.backgroundColor] = UIColor.secondarySystemFill
                }
                out.append(NSAttributedString(string: words, attributes: plain))
                continue
            case let .text(text):
                let drawn = inline(
                    parsed: text.text, attributes: attributes, fontSize: block.fontSize(fontSize), bold: block.isHeading,
                    serif: serif, linksTapped: linksTapped
                )
                for link in drawn.links {
                    links.append(VerseLink(
                        range: NSRange(location: link.range.location + out.length, length: link.range.length),
                        verseId: link.verseId, endVerseId: link.endVerseId
                    ))
                }
                out.append(drawn.text)
                for picture in drawn.pictures {
                    out.append(NSAttributedString(string: "\n", attributes: base))
                    out.append(self.picture(media[picture.id], caption: picture.caption, fontSize: fontSize, serif: serif))
                }
            default:
                break
            }
        }
        return Rendered(text: out, verseLinks: links)
    }

    /// Where a picture's `media/<id>` is on this device.
    private static func mediaURL(_ path: String, in media: [String: URL]) -> URL? {
        guard path.hasPrefix("media/") else { return nil }
        return media[String(path.dropFirst("media/".count))]
    }

    // MARK: Lines

    /// One line as it's drawn: how it's set (`block`), whether a quotation
    /// holds it, and what's on it.
    struct Line {
        enum Content {
            case text(LampProseText)
            /// Words drawn as they are: code, a recording's caption, HTML.
            case plain(String, code: Bool)
            case picture(path: String, caption: String)
            case rule
            /// A blank line between blocks.
            case gap
        }
        let block: Block
        /// How many quotations hold it.
        let quoteDepth: Int
        var quoted: Bool { quoteDepth > 0 }
        let content: Content
    }

    /// The blocks laid out a line at a time, as the note editor shows them:
    /// a paragraph a line for each typed line, a list's items with their
    /// markers (numbered from where the writer began) and their nesting, a
    /// quotation's lines in it, and a blank line between blocks.
    static func lines(_ blocks: [LampProseBlock]) -> [Line] {
        var out: [Line] = []
        func add(_ blocks: [LampProseBlock], depth: Int, quoted: Int, top: Bool) {
            for (index, block) in blocks.enumerated() {
                // A blank line between blocks, in a quotation or an item as
                // at the top; a list nested under an item's words follows
                // them straight on.
                if index > 0, top || !isList(block) {
                    out.append(Line(block: Block(kind: .text), quoteDepth: top ? 0 : quoted, content: .gap))
                }
                // A list item's second line on is set under its words.
                let follow = Block(kind: depth > 0 ? .continued : (quoted > 0 ? .quote : .text), level: depth)
                switch block {
                case let .heading(level, text):
                    out.append(Line(block: Block(kind: .heading(level)), quoteDepth: quoted, content: .text(text)))
                case let .paragraph(text):
                    for line in text.lines {
                        // A picture on a line of its own is the picture,
                        // its caption under it, as one alone in its block.
                        if let picture = pictureAlone(line) {
                            out.append(Line(block: follow, quoteDepth: quoted, content: .picture(path: picture.path, caption: picture.caption)))
                        } else {
                            out.append(Line(block: follow, quoteDepth: quoted, content: .text(line)))
                        }
                    }
                case let .quote(inner):
                    add(inner, depth: depth, quoted: quoted + 1, top: false)
                case let .list(ordered, start, items):
                    for (number, item) in items.enumerated() {
                        let marker: Block.Kind = switch item.checked {
                        case .some(true): .ordered("☑\u{FE0E}")
                        case .some(false): .ordered("☐")
                        case .none: ordered ? .ordered("\(start + number).") : .bullet
                        }
                        // The item's first line carries its marker; the rest of
                        // it, and anything nested, follows under its words.
                        let opening = out.count
                        add(item.blocks, depth: depth + 1, quoted: quoted, top: false)
                        if opening < out.count, case .text = out[opening].content,
                           [.continued, .heading(1), .heading(2), .heading(3), .heading(4), .heading(5), .heading(6)].contains(out[opening].block.kind) {
                            let first = out[opening]
                            out[opening] = Line(block: Block(kind: marker, level: depth), quoteDepth: first.quoteDepth, content: first.content)
                        } else {
                            out.insert(Line(block: Block(kind: marker, level: depth), quoteDepth: quoted, content: .plain("", code: false)), at: opening)
                        }
                    }
                case let .code(_, code):
                    for line in code.components(separatedBy: "\n") {
                        out.append(Line(block: follow, quoteDepth: quoted, content: .plain(line, code: true)))
                    }
                case let .table(headers, rows):
                    // A row a line, its cells apart by a bar (which no
                    // verse reference reads across), each as written in it:
                    // emphasis kept, and a verse link to tap. A break within
                    // a cell is a space, so the row stays a line.
                    for row in [headers] + rows {
                        var joined = AttributedString()
                        for (column, cell) in row.enumerated() {
                            if column > 0 { joined.append(AttributedString(" | ")) }
                            var text = cell.text
                            while let newline = text.characters.firstIndex(of: "\n") {
                                let range = newline..<text.characters.index(after: newline)
                                // The space takes the break's attributes, so a
                                // link across it stays one link.
                                var space = AttributedString(" ")
                                space.mergeAttributes(text[range].runs.first?.attributes ?? AttributeContainer())
                                text.replaceSubrange(range, with: space)
                            }
                            joined.append(text)
                        }
                        out.append(Line(block: follow, quoteDepth: quoted, content: .text(LampProseText(joined))))
                    }
                case let .html(html):
                    for line in html.components(separatedBy: "\n") {
                        out.append(Line(block: follow, quoteDepth: quoted, content: .plain(line, code: false)))
                    }
                case let .footnote(label, inner):
                    // A note's own footnotes are kept outside its text; one
                    // written in is shown as written.
                    let opening = out.count
                    add(inner, depth: depth, quoted: quoted, top: false)
                    if opening < out.count, case let .text(first) = out[opening].content {
                        var labelled = AttributedString("[^\(label)]: ")
                        labelled.append(first.text)
                        out[opening] = Line(block: out[opening].block, quoteDepth: out[opening].quoteDepth, content: .text(LampProseText(labelled)))
                    } else {
                        // Opening with a picture, or empty: the label on its own.
                        out.insert(Line(block: follow, quoteDepth: quoted, content: .plain("[^\(label)]:", code: false)), at: opening)
                    }
                case let .audio(caption, _):
                    // A recording, which a note here can't play: its words.
                    out.append(Line(block: follow, quoteDepth: quoted, content: .plain(caption, code: false)))
                case let .picture(caption, path):
                    out.append(Line(block: follow, quoteDepth: quoted, content: .picture(path: path, caption: caption)))
                case .rule:
                    out.append(Line(block: Block(kind: .rule), quoteDepth: quoted, content: .rule))
                }
            }
        }
        add(blocks, depth: 0, quoted: 0, top: true)
        return out
    }

    private static func isList(_ block: LampProseBlock) -> Bool {
        if case .list = block { return true }
        return false
    }

    /// The picture a line holds and nothing else (but space): one run
    /// carrying its address, as core gives a picture.
    private static func pictureAlone(_ line: LampProseText) -> (path: String, caption: String)? {
        var picture: (path: String, caption: String)?
        for run in line.text.runs {
            let words = String(line.text[run.range].characters)
            if let url = run.imageURL {
                // A note's own picture, not one that's a link, which the
                // inline path keeps to tap.
                guard picture == nil, run.link == nil, url.relativeString.hasPrefix("media/") else { return nil }
                picture = (url.relativeString, words == "\u{FFFC}" ? "" : words)
            } else if !words.allSatisfy(\.isWhitespace) {
                return nil
            }
        }
        return picture
    }

    // MARK: Pictures

    /// A picture, as wide as the note up to its own width, with its caption
    /// under it. One not on this device yet, as before a sync brings it,
    /// is named where it will be.
    static func picture(_ url: URL?, caption: String, fontSize: CGFloat, serif: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = fontSize * 0.3
        style.paragraphSpacing = fontSize * 0.3
        var captionAttributes = baseAttributes(fontSize: fontSize * 0.85, serif: serif)
        captionAttributes[.foregroundColor] = UIColor.secondaryLabel
        captionAttributes[.paragraphStyle] = style

        let out = NSMutableAttributedString()
        if let url, let image = NotePictures.image(at: url) {
            let attachment = NotePictureAttachment()
            attachment.image = image
            out.append(NSAttributedString(attachment: attachment))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
            if !caption.isEmpty {
                out.append(NSAttributedString(string: "\n" + caption, attributes: captionAttributes))
            }
        } else {
            let symbol = NSTextAttachment()
            symbol.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize * 0.85))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            out.append(NSAttributedString(attachment: symbol))
            out.append(NSAttributedString(
                string: " " + (caption.isEmpty ? "Picture" : caption), attributes: captionAttributes
            ))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    // MARK: Blocks

    /// What one line opens, and the text after its marker.
    struct Block {
        /// `continued`: a line under a list item's words, its marker on the
        /// item's first.
        enum Kind: Equatable { case text, heading(Int), bullet, ordered(String), quote, rule, continued }
        let kind: Kind
        /// How deep in lists: the tree's own, not counted from indentation.
        let level: Int

        init(kind: Kind, level: Int = 0) {
            self.kind = kind
            self.level = min(level, 6)
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

    private static func paragraphStyle(fontSize: CGFloat, block: Block, lineSpacing: CGFloat?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing ?? fontSize * 0.35
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
        case .continued:
            let indent = CGFloat(block.level) * step
            style.firstLineHeadIndent = indent
            style.headIndent = indent
        default:
            break
        }
        return style
    }

    static func baseAttributes(fontSize: CGFloat, bold: Bool = false, serif: Bool = false) -> [NSAttributedString.Key: Any] {
        [
            .font: font(size: fontSize, bold: bold, italic: false, code: false, serif: serif),
            .foregroundColor: UIColor.label,
        ]
    }

    // MARK: Inline

    struct InlineLink {
        let range: NSRange
        let verseId: Int
        let endVerseId: Int?
    }

    private static func inline(
        _ text: String, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat, bold: Bool, serif: Bool,
        linksTapped: Bool = false
    ) -> (text: NSAttributedString, links: [InlineLink], pictures: [(id: String, caption: String)]) {
        guard !text.isEmpty else { return (NSAttributedString(), [], []) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return (NSAttributedString(string: text, attributes: attributes), [], [])
        }
        return inline(parsed: parsed, attributes: attributes, fontSize: fontSize, bold: bold, serif: serif, linksTapped: linksTapped)
    }

    /// Inline text already read, its runs carrying Foundation's attributes
    /// (`inlinePresentationIntent`, `link`, `imageURL`), as
    /// `AttributedString(markdown:)` and core's `LampProseText` both give it.
    /// `raisesFootnotes`: a footnote's marker drawn as its number, raised,
    /// with `footnoteNumbers` saying what each label is shown as; otherwise
    /// it's left as written, for the host to style (a note's are).
    static func inline(
        parsed: AttributedString, attributes: [NSAttributedString.Key: Any], fontSize: CGFloat, bold: Bool, serif: Bool,
        linksTapped: Bool = false, raisesFootnotes: Bool = false, footnoteNumbers: [String: String] = [:]
    ) -> (text: NSAttributedString, links: [InlineLink], pictures: [(id: String, caption: String)]) {
        let out = NSMutableAttributedString()
        var links: [InlineLink] = []
        var pictures: [(id: String, caption: String)] = []
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runAttributes = attributes
            let intent = run.inlinePresentationIntent ?? []
            runAttributes[.font] = font(
                size: fontSize,
                bold: bold || intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized),
                code: intent.contains(.code),
                serif: serif
            )
            if intent.contains(.strikethrough) {
                runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if raisesFootnotes, let label = run[LampFootnoteReferenceAttribute.self] {
                // A footnote's marker, `[^1]`, as the editor draws it: its
                // number raised and small. Any review marker in it is kept.
                runAttributes[.font] = font(size: fontSize * 0.7, bold: bold, italic: false, code: false, serif: serif)
                runAttributes[.baselineOffset] = fontSize * 0.35
                if let url = run.link {
                    runAttributes[.foregroundColor] = UIColor.lampLink
                    if linksTapped { runAttributes[.link] = url }
                }
                // Each one: references alike in a row are one run.
                let shown = piece.replacing(#/\[\^([^\]]*)\]/#) { match in
                    let written = String(match.output.1)
                    return footnoteNumbers[LampWritingReviewMarkdown.unmarked(written)].map {
                        LampWritingReviewMarkdown.markers(in: written) + $0
                    } ?? written
                }
                out.append(NSAttributedString(string: shown == piece ? (footnoteNumbers[label] ?? label) : shown, attributes: runAttributes))
                continue
            }
            if let id = mediaID(run.imageURL) {
                // The span stays in its sentence, marked as having a picture.
                var caption = runAttributes
                caption[.pictureCaption] = true
                out.append(NSAttributedString(string: piece, attributes: caption))
                let symbol = NSTextAttachment()
                symbol.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: fontSize * 0.7))?
                    .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
                out.append(NSAttributedString(string: "\u{2009}", attributes: runAttributes))
                out.append(NSAttributedString(attachment: symbol))
                pictures.append((id, piece))
                continue
            }
            if mediaID(run.link) != nil {
                // A recording, which a note here can't play: its words, as words.
                out.append(NSAttributedString(string: piece, attributes: runAttributes))
                continue
            }
            if let url = run.link {
                runAttributes[.foregroundColor] = UIColor.lampLink
                if linksTapped { runAttributes[.link] = url }
                if let verse = verseLink(url) {
                    let length = (piece as NSString).length
                    // One link split into runs (by a break or its formatting)
                    // is one link.
                    if let last = links.last, NSMaxRange(last.range) == out.length,
                       last.verseId == verse.start, last.endVerseId == verse.end {
                        links[links.count - 1] = InlineLink(
                            range: NSRange(location: last.range.location, length: last.range.length + length),
                            verseId: verse.start, endVerseId: verse.end
                        )
                    } else {
                        links.append(InlineLink(
                            range: NSRange(location: out.length, length: length),
                            verseId: verse.start, endVerseId: verse.end
                        ))
                    }
                }
            }
            out.append(NSAttributedString(string: piece, attributes: runAttributes))
        }
        return (out, links, pictures)
    }

    /// The id a `media/<id>` link names, as a note's Markdown links its media.
    private static func mediaID(_ url: URL?) -> String? {
        guard let path = url?.relativeString, path.hasPrefix("media/") else { return nil }
        let id = String(path.dropFirst("media/".count))
        return id.isEmpty ? nil : id
    }

    /// `lampbible://verse/<start>[/<end>]`, the app's link to a passage.
    static func verseLink(_ url: URL) -> (start: Int, end: Int?)? {
        guard url.scheme == "lampbible", url.host == "verse" else { return nil }
        let parts = url.path.split(separator: "/").compactMap { Int($0) }
        guard let start = parts.first else { return nil }
        return (start, parts.count > 1 ? parts[1] : nil)
    }

    private static func font(size: CGFloat, bold: Bool, italic: Bool, code: Bool, serif: Bool) -> UIFont {
        if code {
            return .monospacedSystemFont(ofSize: size * 0.95, weight: bold ? .semibold : .regular)
        }
        if serif { return LampTheme.serif(size: size, weight: bold ? .semibold : .regular, italic: italic) }
        let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard italic, let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension NSAttributedString.Key {
    /// A picture's caption drawn in its sentence: the picture's words, not
    /// the writer's prose, so nothing reads it as part of the text around.
    static let pictureCaption = NSAttributedString.Key("LampPictureCaption")
}

/// A picture in a note, laid out against the line it sits on: as wide as the
/// note, but never wider than the picture.
final class NotePictureAttachment: NSTextAttachment {
    override func attachmentBounds(
        for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint, characterIndex charIndex: Int
    ) -> CGRect {
        guard let image, image.size.width > 0 else { return .zero }
        let available = lineFrag.width - (textContainer?.lineFragmentPadding ?? 0) * 2
        let width = min(image.size.width, max(available, 1))
        return CGRect(x: 0, y: 0, width: width, height: width * image.size.height / image.size.width)
    }
}

/// Note pictures, read at a size fit to draw: a photo at its full size would
/// cost that much memory each time a note shows it. Their corners are
/// rounded as the editor rounds them.
enum NotePictures {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(at url: URL, maxPixels: Int = 1600) -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let scale = UITraitCollection.current.displayScale
        let size = CGSize(width: CGFloat(thumbnail.width) / scale, height: CGFloat(thumbnail.height) / scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).addClip()
            UIImage(cgImage: thumbnail, scale: scale, orientation: .up).draw(in: CGRect(origin: .zero, size: size))
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
