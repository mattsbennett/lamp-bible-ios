//
//  NoteMarkdownRenderer.swift
//  Lamp Bible
//

import ImageIO
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
    static func render(_ markdown: String, fontSize: CGFloat, media: [String: URL] = [:]) -> Rendered {
        let out = NSMutableAttributedString()
        var links: [VerseLink] = []
        let lines = markdown.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            if let picture = raw.wholeMatch(of: #/\s*!\[([^\]]*)\]\(media/([^)\s]+)\)\s*/#) {
                let attributes = baseAttributes(fontSize: fontSize)
                if index > 0 { out.append(NSAttributedString(string: "\n", attributes: attributes)) }
                out.append(self.picture(
                    media[String(picture.2)], caption: String(picture.1), fontSize: fontSize
                ))
                continue
            }
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
            for picture in line.pictures {
                out.append(NSAttributedString(string: "\n", attributes: baseAttributes(fontSize: fontSize)))
                out.append(self.picture(media[picture.id], caption: picture.caption, fontSize: fontSize))
            }
        }
        return Rendered(text: out, verseLinks: links)
    }

    // MARK: Pictures

    /// A picture, as wide as the note up to its own width, with its caption
    /// under it. One not on this device yet, as before a sync brings it,
    /// is named where it will be.
    private static func picture(_ url: URL?, caption: String, fontSize: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = fontSize * 0.3
        style.paragraphSpacing = fontSize * 0.3
        var captionAttributes = baseAttributes(fontSize: fontSize * 0.85)
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
    ) -> (text: NSAttributedString, links: [InlineLink], pictures: [(id: String, caption: String)]) {
        guard !text.isEmpty else { return (NSAttributedString(), [], []) }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return (NSAttributedString(string: text, attributes: attributes), [], [])
        }
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
                code: intent.contains(.code)
            )
            if intent.contains(.strikethrough) {
                runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let id = mediaID(run.imageURL) {
                // The span stays in its sentence, marked as having a picture.
                out.append(NSAttributedString(string: piece, attributes: runAttributes))
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
                if let verse = verseLink(url) {
                    links.append(InlineLink(
                        range: NSRange(location: out.length, length: (piece as NSString).length),
                        verseId: verse.start, endVerseId: verse.end
                    ))
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
