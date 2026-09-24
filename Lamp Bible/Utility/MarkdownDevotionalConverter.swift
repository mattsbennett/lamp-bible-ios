//
//  MarkdownDevotionalConverter.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation
import LampModuleKit
import LampCore

/// Two-way converter between Devotional content and Markdown
struct MarkdownDevotionalConverter {

    // MARK: - Markdown to Devotional

    /// Parse markdown string into a complete Devotional object
    static func parseMarkdown(_ markdown: String) -> Devotional? {
        // Check for YAML frontmatter
        guard markdown.hasPrefix("---") else {
            // No frontmatter - create minimal devotional
            let blocks = markdownToBlocks(markdown)
            return Devotional(
                meta: DevotionalMeta(
                    id: UUID().uuidString,
                    title: extractTitle(from: blocks) ?? "Untitled"
                ),
                content: .blocks(blocks)
            )
        }

        // Parse frontmatter
        let lines = markdown.components(separatedBy: .newlines)
        var frontmatterEnd: Int? = nil

        for (index, line) in lines.enumerated() {
            if index == 0 { continue } // Skip opening ---
            if line == "---" {
                frontmatterEnd = index
                break
            }
        }

        guard let endIndex = frontmatterEnd else {
            // Malformed frontmatter
            return nil
        }

        // Parse YAML frontmatter
        let frontmatterLines = Array(lines[1..<endIndex])
        let meta = parseFrontmatter(frontmatterLines)

        // Parse content
        let contentLines = Array(lines[(endIndex + 1)...])
        let contentMarkdown = contentLines.joined(separator: "\n")
        let blocks = markdownToBlocks(contentMarkdown)

        // Extract summary if present (first paragraph before content)
        var summary: DevotionalTextField? = nil
        var contentBlocks = blocks

        if let firstBlock = blocks.first,
           firstBlock.type == .paragraph,
           let content = firstBlock.content {
            // Check if there's a ## Summary heading
            if contentMarkdown.lowercased().hasPrefix("## summary") {
                summary = .plain(content.text)
                contentBlocks = Array(blocks.dropFirst())
            }
        }

        return Devotional(
            meta: meta,
            summary: summary,
            content: .blocks(contentBlocks),
            footnotes: parseFootnotes(from: markdown)
        )
    }

    /// Decode the shared Markdown parser into iOS's richer block model.
    static func markdownToBlocks(_ markdown: String) -> [DevotionalContentBlock] {
        guard let data = try? LampPortableDevotionalContent.blocksJSON(from: markdown),
              let blocks = try? JSONDecoder().decode([DevotionalContentBlock].self, from: data)
        else {
            // The authored Markdown remains in `markdownContent` even if a newer
            // block shape cannot be decoded by this version of the app.
            return markdown.isEmpty ? [] : [.paragraph(markdown)]
        }
        return blocks
    }

    static func shouldRetainContentJSON(_ devotional: Devotional) -> Bool {
        guard devotional.markdownContent == nil,
              let data = try? JSONEncoder().encode(devotional.content) else { return false }
        return LampPortableDevotionalMedia.plainMarkdown(
            from: String(decoding: data, as: UTF8.self)
        ) == nil
    }

    static func revisingContent(
        _ content: DevotionalContent, with markdown: String
    ) throws -> DevotionalContent {
        let original = try JSONEncoder().encode(content)
        let revised = try LampPortableDevotionalContent.replacingMarkdown(
            markdown, in: String(decoding: original, as: UTF8.self)
        )
        return try JSONDecoder().decode(DevotionalContent.self, from: Data(revised.utf8))
    }

    // MARK: - Devotional to Markdown

    /// Convert a full Devotional to markdown with frontmatter
    static func devotionalToMarkdown(_ devotional: Devotional) -> String {
        var lines: [String] = []

        // Frontmatter
        lines.append("---")
        lines.append("id: \"\(devotional.meta.id)\"")
        lines.append("title: \"\(escapeYamlString(devotional.meta.title))\"")

        if let subtitle = devotional.meta.subtitle {
            lines.append("subtitle: \"\(escapeYamlString(subtitle))\"")
        }

        if let author = devotional.meta.author {
            lines.append("author: \"\(escapeYamlString(author))\"")
        }

        if let date = devotional.meta.date {
            lines.append("date: \"\(date)\"")
        }

        if let tags = devotional.meta.tags, !tags.isEmpty {
            let tagList = tags.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("tags: [\(tagList)]")
        }

        if let category = devotional.meta.category {
            lines.append("category: \"\(category.rawValue)\"")
        }

        if let series = devotional.meta.series {
            lines.append("series:")
            lines.append("  id: \"\(series.id ?? "")\"")
            lines.append("  name: \"\(escapeYamlString(series.name ?? ""))\"")
            if let order = series.order {
                lines.append("  order: \(order)")
            }
        }

        if let keyScriptures = devotional.meta.keyScriptures, !keyScriptures.isEmpty {
            lines.append("keyScriptures:")
            for scripture in keyScriptures {
                if let label = scripture.label {
                    lines.append("  - ref: \"\(label)\"")
                }
                lines.append("    sv: \(scripture.sv)")
                if let ev = scripture.ev {
                    lines.append("    ev: \(ev)")
                }
            }
        }

        lines.append("---")
        lines.append("")

        // Summary
        if let summary = devotional.summary {
            lines.append("## Summary")
            lines.append("")
            switch summary {
            case .plain(let text):
                lines.append(text)
            case .annotated(let annotated):
                lines.append(annotatedTextToMarkdown(annotated))
            }
            lines.append("")
        }

        // All block and section rendering is shared with Mac.
        lines.append(portableMarkdown(devotional.content))

        // Footnotes
        if let footnotes = devotional.footnotes, !footnotes.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            for footnote in footnotes {
                switch footnote.content {
                case .plain(let text):
                    lines.append("[^\(footnote.id)]: \(text)")
                case .annotated(let annotated):
                    lines.append("[^\(footnote.id)]: \(annotatedTextToMarkdown(annotated))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Convert content blocks to markdown string
    static func blocksToMarkdown(_ blocks: [DevotionalContentBlock]) -> String {
        portableMarkdown(.blocks(blocks))
    }

    /// Convert content blocks and footnotes to markdown string (for editor use)
    static func contentToMarkdown(_ devotional: Devotional) -> String {
        var lines: [String] = []

        lines.append(portableMarkdown(devotional.content))

        // Footnotes (with --- separator)
        if let footnotes = devotional.footnotes, !footnotes.isEmpty {
            lines.append("")
            lines.append("---")
            lines.append("")
            for footnote in footnotes {
                switch footnote.content {
                case .plain(let text):
                    lines.append("[^\(footnote.id)]: \(text)")
                case .annotated(let annotated):
                    lines.append("[^\(footnote.id)]: \(annotatedTextToMarkdown(annotated))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func portableMarkdown(_ content: DevotionalContent) -> String {
        guard let data = try? JSONEncoder().encode(content) else { return "" }
        return LampPortableDevotionalContent.markdown(
            from: String(decoding: data, as: UTF8.self)
        ) ?? ""
    }

    private static func parseFrontmatter(_ lines: [String]) -> DevotionalMeta {
        let parsed = LampDevotionalFrontmatter(lines: lines)
        let series = parsed.series.isEmpty ? nil : DevotionalSeriesInfo(
            id: parsed.series["id"],
            name: parsed.series["name"],
            order: parsed.series["order"].flatMap(Int.init)
        )
        let scriptures = parsed.scriptures.map {
            DevotionalKeyScripture(
                sv: $0.startReference, ev: $0.endReference, label: $0.label
            )
        }
        return DevotionalMeta(
            id: parsed.values["id"] ?? UUID().uuidString,
            title: parsed.values["title"] ?? "Untitled",
            subtitle: parsed.values["subtitle"],
            author: parsed.values["author"],
            date: parsed.values["date"],
            tags: parsed.tags.isEmpty ? nil : parsed.tags,
            category: parsed.values["category"].flatMap(DevotionalCategory.init(rawValue:)),
            series: series,
            keyScriptures: scriptures.isEmpty ? nil : scriptures,
            created: Int(Date().timeIntervalSince1970)
        )
    }

    /// Parse footnote definitions from markdown
    static func parseFootnotes(from markdown: String) -> [DevotionalFootnote]? {
        let pattern = "\\[\\^([^\\]]+)\\]:\\s*(.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return nil
        }

        let nsMarkdown = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: nsMarkdown.length))

        guard !matches.isEmpty else { return nil }

        return matches.compactMap { match -> DevotionalFootnote? in
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: markdown),
                  let contentRange = Range(match.range(at: 2), in: markdown) else { return nil }

            let id = String(markdown[idRange])
            let content = String(markdown[contentRange])

            return DevotionalFootnote(
                id: id,
                content: .plain(content)
            )
        }
    }

    private static func extractTitle(from blocks: [DevotionalContentBlock]) -> String? {
        for block in blocks {
            if block.type == .heading, let content = block.content {
                return content.text
            }
        }
        return nil
    }

    private static func annotatedTextToMarkdown(_ annotated: DevotionalAnnotatedText) -> String {
        var text = annotated.text

        // Annotations are relative to text BEFORE footnotes were removed during parsing.
        // Footnote offsets are relative to the FINAL clean text (after everything removed).
        //
        // Strategy: First apply annotations to clean text, then insert footnotes.
        // But annotations may overlap with where footnotes should go, so we need to
        // track how annotation insertions shift positions.

        guard let annotations = annotated.annotations, !annotations.isEmpty else {
            // No annotations - just insert footnote refs directly
            if let footnoteRefs = annotated.footnoteRefs, !footnoteRefs.isEmpty {
                let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
                for ref in sortedRefs {
                    guard ref.offset >= 0, ref.offset <= text.count else { continue }
                    let insertIndex = text.index(text.startIndex, offsetBy: ref.offset)
                    text.insert(contentsOf: "[^\(ref.id)]", at: insertIndex)
                }
            }
            return text
        }

        // Process annotations first (sorted by start position, reverse order)
        let sorted = annotations.sorted { $0.start > $1.start }

        // Track how much we've expanded the text at each position
        // We'll use this to adjust footnote positions later
        var expansions: [(originalPos: Int, expansion: Int)] = []

        for annotation in sorted {
            guard annotation.start >= 0, annotation.end <= text.count else { continue }

            let startIndex = text.index(text.startIndex, offsetBy: annotation.start)
            let endIndex = text.index(text.startIndex, offsetBy: annotation.end)
            let range = startIndex..<endIndex
            let annotatedText = String(text[range])

            var replacement: String? = nil

            switch annotation.type {
            case .emphasis:
                switch annotation.data?.style {
                case .bold:
                    replacement = "**\(annotatedText)**"
                case .italic:
                    replacement = "*\(annotatedText)*"
                case .underline, .none:
                    break
                }

            case .scripture:
                if let sv = annotation.data?.sv {
                    let ev = annotation.data?.ev
                    let url = ev != nil ? "lampbible://verse/\(sv)/\(ev!)" : "lampbible://verse/\(sv)"
                    replacement = "[\(annotatedText)](\(url))"
                }

            case .strongs:
                if let key = annotation.data?.strongs {
                    replacement = "[\(annotatedText)](lampbible://strongs/\(key))"
                }

            case .link:
                if let url = annotation.data?.url {
                    replacement = "[\(annotatedText)](\(url))"
                }

            case .quote, .greek, .hebrew:
                break
            }

            if let replacement = replacement {
                let expansion = replacement.count - annotatedText.count
                text.replaceSubrange(range, with: replacement)
                expansions.append((originalPos: annotation.start, expansion: expansion))
            }
        }

        // Now insert footnote references, adjusting for annotation expansions
        if let footnoteRefs = annotated.footnoteRefs, !footnoteRefs.isEmpty {
            let sortedRefs = footnoteRefs.sorted { $0.offset > $1.offset }
            for ref in sortedRefs {
                // Calculate adjusted offset based on expansions from annotations
                // that occurred BEFORE this position (lower position values)
                var adjustedOffset = ref.offset
                for (pos, exp) in expansions {
                    if pos < ref.offset {
                        adjustedOffset += exp
                    }
                }

                guard adjustedOffset >= 0, adjustedOffset <= text.count else { continue }
                let insertIndex = text.index(text.startIndex, offsetBy: adjustedOffset)
                text.insert(contentsOf: "[^\(ref.id)]", at: insertIndex)
            }
        }

        return text
    }

    private static func escapeYamlString(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
