//
//  MarkdownDevotionalConverter.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-15.
//

import Foundation

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

    /// Convert markdown string to content blocks
    static func markdownToBlocks(_ markdown: String) -> [DevotionalContentBlock] {
        var blocks: [DevotionalContentBlock] = []
        let lines = markdown.components(separatedBy: .newlines)

        var currentParagraph: [String] = []
        var inList = false
        var listItems: [DevotionalListItem] = []
        var listType: DevotionalListType = .bullet
        var inBlockquote = false
        var blockquoteLines: [String] = []
        var inTable = false
        var tableLines: [String] = []

        func flushParagraph() {
            if !currentParagraph.isEmpty {
                let text = currentParagraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(DevotionalContentBlock(
                        type: .paragraph,
                        content: parseAnnotatedText(text)
                    ))
                }
                currentParagraph = []
            }
        }

        func flushList() {
            if !listItems.isEmpty {
                blocks.append(DevotionalContentBlock(
                    type: .list,
                    listType: listType,
                    items: listItems
                ))
                listItems = []
                inList = false
            }
        }

        func flushBlockquote() {
            if !blockquoteLines.isEmpty {
                let text = blockquoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(DevotionalContentBlock(
                        type: .blockquote,
                        content: parseAnnotatedText(text)
                    ))
                }
                blockquoteLines = []
                inBlockquote = false
            }
        }

        func flushTable() {
            if !tableLines.isEmpty {
                if let tableData = parseGFMTable(tableLines) {
                    blocks.append(DevotionalContentBlock(type: .table, tableData: tableData))
                }
                tableLines = []
                inTable = false
            }
        }

        // Helper to check if a line is a list item
        func isListItemLine(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.firstMatch(of: /^(\d+)\.\s/) != nil || t.firstMatch(of: /^[-*+]\s/) != nil
        }

        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip frontmatter separator and footnote definitions
            if trimmed == "---" { continue }
            if trimmed.starts(with: "[^") && trimmed.contains("]:") { continue }

            // Empty line - flush current block (but be smart about lists)
            if trimmed.isEmpty {
                flushParagraph()
                flushBlockquote()
                flushTable()

                // Only flush list if the next non-empty line is NOT a list item
                if inList {
                    var nextIsListItem = false
                    for j in (lineIndex + 1)..<lines.count {
                        let nextTrimmed = lines[j].trimmingCharacters(in: .whitespaces)
                        if !nextTrimmed.isEmpty {
                            nextIsListItem = isListItemLine(lines[j])
                            break
                        }
                    }
                    if !nextIsListItem {
                        flushList()
                    }
                    // If next is a list item, don't flush - continue the list
                } else {
                    flushList()
                }
                continue
            }

            // Table line detection: lines containing | are potential table rows
            if trimmed.contains("|") {
                let isTableRow = trimmed.hasPrefix("|") || trimmed.hasSuffix("|")
                if isTableRow {
                    if !inTable {
                        flushParagraph()
                        flushList()
                        flushBlockquote()
                        inTable = true
                    }
                    tableLines.append(trimmed)
                    continue
                }
            }

            // Non-table line ends a table
            if inTable {
                flushTable()
            }

            // Image block: ![caption](media/id)
            if let (caption, mediaId) = parseImageBlock(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                blocks.append(DevotionalContentBlock(
                    type: .image,
                    mediaId: mediaId,
                    caption: caption.isEmpty ? nil : DevotionalAnnotatedText(text: caption),
                    alignment: .center
                ))
                continue
            }

            // Audio block: [caption](media/id) - must be the only content on the line
            if let (caption, mediaId) = parseAudioBlock(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                blocks.append(DevotionalContentBlock(
                    type: .audio,
                    mediaId: mediaId,
                    caption: caption.isEmpty ? nil : DevotionalAnnotatedText(text: caption),
                    showWaveform: true
                ))
                continue
            }

            // Heading
            if let (level, text) = parseHeading(trimmed) {
                flushParagraph()
                flushList()
                flushBlockquote()
                blocks.append(DevotionalContentBlock(
                    type: .heading,
                    content: parseAnnotatedText(text),
                    level: level
                ))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                let quoteText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blockquoteLines.append(quoteText)
                inBlockquote = true
                continue
            }

            // Numbered list (allow empty items with .* instead of .+)
            // Check indentation level for nesting
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let indentLevel = leadingSpaces / 2  // 2+ spaces = one nesting level (also handles 3-space indent)

            if let match = trimmed.firstMatch(of: /^(\d+)\.\s*(.*)$/) {
                flushParagraph()
                flushBlockquote()
                if !inList || listType != .numbered {
                    flushList()
                    listType = .numbered
                }
                inList = true
                let newItem = DevotionalListItem(
                    content: parseAnnotatedText(String(match.2))
                )
                appendListItem(newItem, atIndent: indentLevel, to: &listItems)
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                flushBlockquote()
                if !inList || listType != .bullet {
                    flushList()
                    listType = .bullet
                }
                inList = true
                let itemText = String(trimmed.dropFirst(2))
                let newItem = DevotionalListItem(
                    content: parseAnnotatedText(itemText)
                )
                appendListItem(newItem, atIndent: indentLevel, to: &listItems)
                continue
            }

            // Continue current state
            if inBlockquote {
                blockquoteLines.append(trimmed)
            } else if inList {
                // Only continue list item if line is indented (starts with whitespace)
                let isIndented = line.first?.isWhitespace == true
                if isIndented && !listItems.isEmpty {
                    // Continuation of list item (indented text, not a new bullet/number)
                    appendTextToLastItem(trimmed, in: &listItems)
                } else {
                    // Non-indented line ends the list and starts a paragraph
                    flushList()
                    currentParagraph.append(trimmed)
                }
            } else {
                currentParagraph.append(trimmed)
            }
        }

        // Flush remaining
        flushParagraph()
        flushList()
        flushBlockquote()
        flushTable()

        return blocks
    }

    /// Append a list item at the given indent level, nesting under the last item if needed.
    private static func appendListItem(_ item: DevotionalListItem, atIndent indent: Int, to items: inout [DevotionalListItem]) {
        if indent > 0 && !items.isEmpty {
            // Nest under the last top-level item
            var lastItem = items[items.count - 1]
            if indent == 1 {
                // Direct child of last item
                if lastItem.children == nil {
                    lastItem.children = []
                }
                lastItem.children!.append(item)
            } else {
                // Deeper nesting: recurse into last item's children
                if lastItem.children == nil {
                    lastItem.children = []
                }
                appendListItem(item, atIndent: indent - 1, to: &lastItem.children!)
            }
            items[items.count - 1] = lastItem
        } else {
            items.append(item)
        }
    }

    /// Append continuation text to the deepest last item in the list.
    private static func appendTextToLastItem(_ text: String, in items: inout [DevotionalListItem]) {
        guard !items.isEmpty else { return }
        var lastItem = items[items.count - 1]
        if var children = lastItem.children, !children.isEmpty {
            // Recurse into children
            appendTextToLastItem(text, in: &children)
            lastItem.children = children
        } else {
            // Append to this item's content
            lastItem = DevotionalListItem(
                content: DevotionalAnnotatedText(
                    text: lastItem.content.text + " " + text
                ),
                children: lastItem.children
            )
        }
        items[items.count - 1] = lastItem
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

        // Content
        switch devotional.content {
        case .blocks(let blocks):
            lines.append(contentsOf: blocksToMarkdownLines(blocks))

        case .structured(let structured):
            if let intro = structured.introduction {
                lines.append(contentsOf: blocksToMarkdownLines(intro))
            }
            if let sections = structured.sections {
                for section in sections {
                    lines.append(contentsOf: sectionToMarkdownLines(section))
                }
            }
            if let conclusion = structured.conclusion {
                lines.append(contentsOf: blocksToMarkdownLines(conclusion))
            }
        }

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
        blocksToMarkdownLines(blocks).joined(separator: "\n")
    }

    /// Convert content blocks and footnotes to markdown string (for editor use)
    static func contentToMarkdown(_ devotional: Devotional) -> String {
        var lines: [String] = []

        // Content blocks
        lines.append(contentsOf: blocksToMarkdownLines(devotional.contentBlocks))

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

    private static func blocksToMarkdownLines(_ blocks: [DevotionalContentBlock]) -> [String] {
        var lines: [String] = []

        for block in blocks {
            switch block.type {
            case .paragraph:
                if let content = block.content {
                    let text = annotatedTextToMarkdown(content)
                    // Skip if this looks like a footnote definition or horizontal rule
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if trimmed.starts(with: "[^") && trimmed.contains("]:") { continue }
                    if trimmed == "---" { continue }
                    lines.append(text)
                    lines.append("")
                }

            case .heading:
                if let content = block.content {
                    let level = block.level ?? 1
                    let prefix = String(repeating: "#", count: level)
                    lines.append("\(prefix) \(content.text)")
                    lines.append("")
                }

            case .blockquote:
                if let content = block.content {
                    let quoteLines = content.text.components(separatedBy: .newlines)
                    for (index, quoteLine) in quoteLines.enumerated() {
                        if quoteLines.count > 1 && index < quoteLines.count - 1 {
                            // Trailing two spaces = markdown hard line break (<br>)
                            lines.append("> \(quoteLine)  ")
                        } else {
                            lines.append("> \(quoteLine)")
                        }
                    }
                    lines.append("")
                }

            case .list:
                if let items = block.items {
                    let isNumbered = block.listType == .numbered
                    appendListItemsAsMarkdown(items, isNumbered: isNumbered, depth: 0, to: &lines)
                    lines.append("")
                }

            case .image:
                // Export image with reference to media folder
                // The actual file copying is handled by DevotionalImportExportManager
                if let mediaId = block.mediaId {
                    let caption = block.caption?.text ?? ""
                    // Use mediaId as filename - actual extension will be added during export
                    lines.append("![\(caption)](media/\(mediaId))")
                    lines.append("")
                }

            case .audio:
                // Export audio with link to media folder
                if let mediaId = block.mediaId {
                    let caption = block.caption?.text ?? "Audio"
                    // Use markdown link syntax for audio files
                    lines.append("[\(caption)](media/\(mediaId))")
                    lines.append("")
                }

            case .table:
                if let tableData = block.tableData {
                    // Header row
                    lines.append("| " + tableData.headers.joined(separator: " | ") + " |")
                    // Separator row
                    lines.append("| " + tableData.headers.map { _ in "---" }.joined(separator: " | ") + " |")
                    // Data rows
                    for row in tableData.rows {
                        lines.append("| " + row.joined(separator: " | ") + " |")
                    }
                    lines.append("")
                }
            }
        }

        return lines
    }

    /// Recursively export list items to markdown with proper indentation.
    private static func appendListItemsAsMarkdown(_ items: [DevotionalListItem], isNumbered: Bool, depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for (index, item) in items.enumerated() {
            let prefix = isNumbered ? "\(index + 1)." : "-"
            lines.append("\(indent)\(prefix) \(annotatedTextToMarkdown(item.content))")
            if let children = item.children {
                appendListItemsAsMarkdown(children, isNumbered: isNumbered, depth: depth + 1, to: &lines)
            }
        }
    }

    private static func sectionToMarkdownLines(_ section: DevotionalSection) -> [String] {
        var lines: [String] = []

        let level = section.level ?? 2
        let prefix = String(repeating: "#", count: level)
        lines.append("\(prefix) \(section.title)")
        lines.append("")

        if let blocks = section.blocks {
            lines.append(contentsOf: blocksToMarkdownLines(blocks))
        }

        if let subsections = section.subsections {
            for subsection in subsections {
                lines.append(contentsOf: sectionToMarkdownLines(subsection))
            }
        }

        return lines
    }

    // MARK: - Annotation Parsing

    /// Parse markdown text into DevotionalAnnotatedText
    static func parseAnnotatedText(_ text: String) -> DevotionalAnnotatedText {
        var annotations: [DevotionalAnnotation] = []
        var footnoteRefs: [DevotionalFootnoteRef] = []
        var cleanText = text

        // Parse bold (**text** or __text__)
        annotations.append(contentsOf: parseEmphasis(text: &cleanText, pattern: "\\*\\*(.+?)\\*\\*", style: .bold))
        annotations.append(contentsOf: parseEmphasis(text: &cleanText, pattern: "__(.+?)__", style: .bold))

        // Parse italic (*text* or _text_)
        annotations.append(contentsOf: parseEmphasis(text: &cleanText, pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", style: .italic))
        annotations.append(contentsOf: parseEmphasis(text: &cleanText, pattern: "(?<!_)_(?!_)(.+?)(?<!_)_(?!_)", style: .italic))

        // Parse links [text](url) - including scripture references
        annotations.append(contentsOf: parseLinks(text: &cleanText))

        // Parse footnote references LAST so offsets are relative to the final clean text
        // (after emphasis markers and link syntax have been removed)
        footnoteRefs.append(contentsOf: parseFootnoteReferences(text: &cleanText))

        // Parse inline scripture references (e.g., John 3:16, Rom 8:28-30)
        annotations.append(contentsOf: parseScriptureReferences(cleanText))

        return DevotionalAnnotatedText(
            text: cleanText,
            annotations: annotations.isEmpty ? nil : annotations,
            footnoteRefs: footnoteRefs.isEmpty ? nil : footnoteRefs
        )
    }

    private static func parseEmphasis(text: inout String, pattern: String, style: DevotionalEmphasisStyle) -> [DevotionalAnnotation] {
        var annotations: [DevotionalAnnotation] = []

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return annotations
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Process matches in reverse to maintain indices
        var offsetAdjustment = 0

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range, in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { continue }

            let content = String(text[contentRange])

            // Calculate positions after marker removal
            let startOffset = text.distance(from: text.startIndex, to: fullRange.lowerBound)
            let endOffset = startOffset + content.count

            annotations.append(DevotionalAnnotation(
                type: .emphasis,
                start: startOffset - offsetAdjustment,
                end: endOffset - offsetAdjustment,
                data: DevotionalAnnotationData(style: style)
            ))

            // Remove markers from text
            text.replaceSubrange(fullRange, with: content)
            offsetAdjustment += (match.range.length - content.count)
        }

        return annotations
    }

    private static func parseLinks(text: inout String) -> [DevotionalAnnotation] {
        var annotations: [DevotionalAnnotation] = []

        let pattern = "\\[(.+?)\\]\\((.+?)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return annotations
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var offsetAdjustment = 0

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range, in: text),
                  let textRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text) else { continue }

            let linkText = String(text[textRange])
            let url = String(text[urlRange])

            let startOffset = text.distance(from: text.startIndex, to: fullRange.lowerBound) - offsetAdjustment
            let endOffset = startOffset + linkText.count

            // Check if URL is a scripture reference (lampbible://verse/...)
            if url.hasPrefix("lampbible://verse/") {
                let parts = url.replacingOccurrences(of: "lampbible://verse/", with: "").components(separatedBy: "/")
                if let sv = Int(parts[0]) {
                    let ev = parts.count > 1 ? Int(parts[1]) : nil
                    annotations.append(DevotionalAnnotation(
                        type: .scripture,
                        start: startOffset,
                        end: endOffset,
                        data: DevotionalAnnotationData(sv: sv, ev: ev)
                    ))
                }
            } else if url.hasPrefix("lampbible://strongs/") {
                let key = url.replacingOccurrences(of: "lampbible://strongs/", with: "")
                annotations.append(DevotionalAnnotation(
                    type: .strongs,
                    start: startOffset,
                    end: endOffset,
                    data: DevotionalAnnotationData(strongs: key)
                ))
            } else {
                // Regular link
                annotations.append(DevotionalAnnotation(
                    type: .link,
                    start: startOffset,
                    end: endOffset,
                    data: DevotionalAnnotationData(url: url)
                ))
            }

            // Replace markdown link with just the text
            text.replaceSubrange(fullRange, with: linkText)
            offsetAdjustment += (match.range.length - linkText.count)
        }

        return annotations
    }

    private static func parseFootnoteReferences(text: inout String) -> [DevotionalFootnoteRef] {
        var footnoteRefs: [DevotionalFootnoteRef] = []

        // Match [^id] but NOT [^id]: (which is a footnote definition)
        let pattern = "\\[\\^([^\\]]+)\\](?!:)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return footnoteRefs
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return footnoteRefs }

        // Collect match info using NSRange (offset and length)
        var matchInfo: [(id: String, offset: Int, length: Int)] = []
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let idRange = match.range(at: 1)
            let footnoteId = nsText.substring(with: idRange)
            matchInfo.append((id: footnoteId, offset: match.range.location, length: match.range.length))
        }

        // Calculate adjusted offsets (accounting for previous removals)
        var totalRemoved = 0
        for info in matchInfo {
            footnoteRefs.append(DevotionalFootnoteRef(
                id: info.id,
                offset: info.offset - totalRemoved
            ))
            totalRemoved += info.length
        }

        // Remove all matches from text (in reverse order to keep indices valid)
        for info in matchInfo.reversed() {
            let startIdx = text.index(text.startIndex, offsetBy: info.offset)
            let endIdx = text.index(startIdx, offsetBy: info.length)
            text.removeSubrange(startIdx..<endIdx)
        }

        return footnoteRefs
    }

    private static func parseScriptureReferences(_ text: String) -> [DevotionalAnnotation] {
        // This is a simplified pattern - could be expanded for more book name variants
        let pattern = "(?:(?:1|2|3|I|II|III)\\s+)?(?:Genesis|Exodus|Leviticus|Numbers|Deuteronomy|Joshua|Judges|Ruth|Samuel|Kings|Chronicles|Ezra|Nehemiah|Esther|Job|Psalms?|Proverbs|Ecclesiastes|Song\\s+of\\s+Solomon|Isaiah|Jeremiah|Lamentations|Ezekiel|Daniel|Hosea|Joel|Amos|Obadiah|Jonah|Micah|Nahum|Habakkuk|Zephaniah|Haggai|Zechariah|Malachi|Matthew|Matt|Mark|Luke|John|Jn|Acts|Romans|Rom|Corinthians|Cor|Galatians|Gal|Ephesians|Eph|Philippians|Phil|Colossians|Col|Thessalonians|Thess|Timothy|Tim|Titus|Philemon|Hebrews|Heb|James|Peter|Pet|Jude|Revelation|Rev)\\s+\\d+(?::\\d+(?:-\\d+)?)?(?:,\\s*\\d+(?::\\d+(?:-\\d+)?)?)*"

        // For now, return empty - scripture reference parsing would require book lookup
        // which is already handled by link parsing above
        return []
    }

    // MARK: - Table Parsing

    /// Parse GFM table lines into DevotionalTableData
    private static func parseGFMTable(_ lines: [String]) -> DevotionalTableData? {
        // Need at least header row + separator + one data row
        guard lines.count >= 3 else { return nil }

        // Verify second line is separator (contains only |, -, :, and spaces)
        let separator = lines[1].trimmingCharacters(in: .whitespaces)
        let separatorChars = CharacterSet(charactersIn: "|-: ")
        guard separator.unicodeScalars.allSatisfy({ separatorChars.contains($0) }) else { return nil }

        func parseCells(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
            if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        let headers = parseCells(lines[0])
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        for i in 2..<lines.count {
            let cells = parseCells(lines[i])
            rows.append(cells)
        }

        return DevotionalTableData(headers: headers, rows: rows)
    }

    // MARK: - Helper Methods

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var text = line

        while text.hasPrefix("#") {
            level += 1
            text = String(text.dropFirst())
        }

        guard level > 0, level <= 6 else { return nil }

        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return (level, text)
    }

    /// Parse image block: ![caption](media/id)
    private static func parseImageBlock(_ line: String) -> (caption: String, mediaId: String)? {
        // Pattern: ![caption](media/id)
        let pattern = "^!\\[([^\\]]*)\\]\\(media/([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)),
              match.numberOfRanges >= 3 else {
            return nil
        }

        let caption = nsLine.substring(with: match.range(at: 1))
        let mediaId = nsLine.substring(with: match.range(at: 2))
        return (caption, mediaId)
    }

    /// Parse audio block: [caption](media/id) - standalone link to media folder
    private static func parseAudioBlock(_ line: String) -> (caption: String, mediaId: String)? {
        // Pattern: [caption](media/id) - but NOT ![caption] (image)
        guard !line.hasPrefix("!") else { return nil }

        let pattern = "^\\[([^\\]]*)\\]\\(media/([^)]+)\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsLine = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)),
              match.numberOfRanges >= 3 else {
            return nil
        }

        let caption = nsLine.substring(with: match.range(at: 1))
        let mediaId = nsLine.substring(with: match.range(at: 2))
        return (caption, mediaId)
    }

    private static func parseFrontmatter(_ lines: [String]) -> DevotionalMeta {
        var id = UUID().uuidString
        var title = "Untitled"
        var subtitle: String? = nil
        var author: String? = nil
        var date: String? = nil
        var tags: [String]? = nil
        var category: DevotionalCategory? = nil
        var series: DevotionalSeriesInfo? = nil
        var keyScriptures: [DevotionalKeyScripture]? = nil

        var currentKey: String? = nil
        var inSeries = false
        var inKeyScriptures = false
        var seriesData: [String: String] = [:]
        var currentScripture: [String: Any] = [:]
        var scripturesList: [[String: Any]] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Nested YAML handling
            if trimmed.hasPrefix("- ") && inKeyScriptures {
                // New scripture entry
                if !currentScripture.isEmpty {
                    scripturesList.append(currentScripture)
                }
                currentScripture = [:]
                let content = String(trimmed.dropFirst(2))
                if let colonIndex = content.firstIndex(of: ":") {
                    let key = String(content[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(content[content.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    currentScripture[key] = value
                }
                continue
            }

            if trimmed.hasPrefix("  ") && (inSeries || inKeyScriptures) {
                let content = trimmed.trimmingCharacters(in: .whitespaces)
                if let colonIndex = content.firstIndex(of: ":") {
                    let key = String(content[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(content[content.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")

                    if inSeries {
                        seriesData[key] = value
                    } else if inKeyScriptures {
                        if key == "sv" || key == "ev" {
                            currentScripture[key] = Int(value)
                        } else {
                            currentScripture[key] = value
                        }
                    }
                }
                continue
            }

            // Top-level keys
            inSeries = false
            if !currentScripture.isEmpty {
                scripturesList.append(currentScripture)
                currentScripture = [:]
            }
            inKeyScriptures = false

            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            // Remove quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            switch key {
            case "id":
                id = value
            case "title":
                title = value
            case "subtitle":
                subtitle = value
            case "author":
                author = value
            case "date":
                date = value
            case "tags":
                // Parse YAML array: [tag1, tag2] or tag1, tag2
                let tagsString = value.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                tags = tagsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
            case "category":
                category = DevotionalCategory(rawValue: value)
            case "series":
                inSeries = true
                seriesData = [:]
            case "keyScriptures":
                inKeyScriptures = true
                scripturesList = []
            default:
                break
            }
        }

        // Finalize series
        if !seriesData.isEmpty {
            series = DevotionalSeriesInfo(
                id: seriesData["id"],
                name: seriesData["name"],
                order: seriesData["order"].flatMap { Int($0) }
            )
        }

        // Finalize key scriptures
        if !currentScripture.isEmpty {
            scripturesList.append(currentScripture)
        }
        if !scripturesList.isEmpty {
            keyScriptures = scripturesList.compactMap { dict in
                guard let sv = dict["sv"] as? Int else { return nil }
                return DevotionalKeyScripture(
                    sv: sv,
                    ev: dict["ev"] as? Int,
                    label: dict["ref"] as? String
                )
            }
        }

        return DevotionalMeta(
            id: id,
            title: title,
            subtitle: subtitle,
            author: author,
            date: date,
            tags: tags,
            category: category,
            series: series,
            keyScriptures: keyScriptures,
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
