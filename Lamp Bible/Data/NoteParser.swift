//
//  NoteParser.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation

struct NoteParser {
    // MARK: - Parsing

    /// Parse a markdown note file into a Note object
    static func parse(content: String, book: Int, chapter: Int) throws -> Note {
        let (frontmatter, body) = splitFrontmatter(content)

        var created = Date()
        var modified = Date()
        var lockedBy: String? = nil
        var lockedAt: Date? = nil

        if let fm = frontmatter {
            if let createdStr = extractFrontmatterValue(fm, key: "created"),
               let createdDate = parseISO8601(createdStr) {
                created = createdDate
            }
            if let modifiedStr = extractFrontmatterValue(fm, key: "modified"),
               let modifiedDate = parseISO8601(modifiedStr) {
                modified = modifiedDate
            }
            if let lockedByStr = extractFrontmatterValue(fm, key: "locked_by"), !lockedByStr.isEmpty {
                lockedBy = lockedByStr
            }
            if let lockedAtStr = extractFrontmatterValue(fm, key: "locked_at"),
               let lockedAtDate = parseISO8601(lockedAtStr) {
                lockedAt = lockedAtDate
            }
        }

        return Note(
            book: book,
            chapter: chapter,
            content: body.trimmingCharacters(in: .whitespacesAndNewlines),
            created: created,
            modified: modified,
            lockedBy: lockedBy,
            lockedAt: lockedAt
        )
    }

    /// Parse note content into sections (general notes + verse-specific sections)
    static func parseSections(from content: String) -> [NoteSection] {
        let lines = content.components(separatedBy: .newlines)
        var sections: [NoteSection] = []
        var currentSection: (id: String, verseStart: Int?, verseEnd: Int?, lines: [String])?

        // Regex for verse headings: ## v3 or ## v16-17
        let versePattern = try! NSRegularExpression(pattern: #"^## v(\d+)(?:-(\d+))?$"#)

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)

            if let match = versePattern.firstMatch(in: line, range: range) {
                // Save previous section
                if let section = currentSection {
                    let sectionContent = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    sections.append(NoteSection(
                        id: section.id,
                        verseStart: section.verseStart,
                        verseEnd: section.verseEnd,
                        content: sectionContent
                    ))
                }

                // Parse verse numbers
                let startRange = Range(match.range(at: 1), in: line)!
                let verseStart = Int(line[startRange])!

                var verseEnd = verseStart
                if match.range(at: 2).location != NSNotFound,
                   let endRange = Range(match.range(at: 2), in: line) {
                    verseEnd = Int(line[endRange]) ?? verseStart
                }

                let id = verseEnd != verseStart ? "v\(verseStart)-\(verseEnd)" : "v\(verseStart)"
                currentSection = (id: id, verseStart: verseStart, verseEnd: verseEnd, lines: [])
            } else {
                if currentSection != nil {
                    currentSection!.lines.append(line)
                } else {
                    // General notes (before any verse heading)
                    if currentSection == nil {
                        currentSection = (id: "general", verseStart: nil, verseEnd: nil, lines: [])
                    }
                    currentSection!.lines.append(line)
                }
            }
        }

        // Save final section
        if let section = currentSection {
            let sectionContent = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !sectionContent.isEmpty || section.verseStart != nil {
                sections.append(NoteSection(
                    id: section.id,
                    verseStart: section.verseStart,
                    verseEnd: section.verseEnd,
                    content: sectionContent
                ))
            }
        }

        // Ensure we always have a general section first (even if empty) when there are verse sections
        if !sections.isEmpty && sections[0].verseStart != nil {
            sections.insert(.general(content: ""), at: 0)
        }

        // If no sections at all, create an empty general section
        if sections.isEmpty {
            sections.append(.general(content: ""))
        }

        return sections
    }

    // MARK: - Serialization

    /// Serialize a Note object to markdown with YAML frontmatter
    static func serialize(note: Note, bookName: String? = nil) -> String {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]

        var output = "---\n"
        if let name = bookName {
            output += "book: \(name)\n"
        } else {
            output += "book: \(note.book)\n"
        }
        output += "chapter: \(note.chapter)\n"
        output += "created: \(iso8601.string(from: note.created))\n"
        output += "modified: \(iso8601.string(from: note.modified))\n"
        if let lockedBy = note.lockedBy {
            output += "locked_by: \(lockedBy)\n"
        }
        if let lockedAt = note.lockedAt {
            output += "locked_at: \(iso8601.string(from: lockedAt))\n"
        }
        output += "content_length: \(note.contentLength)\n"
        output += "---\n\n"
        output += note.content

        return output
    }

    /// Serialize sections back into note content (without frontmatter)
    static func serializeSections(_ sections: [NoteSection]) -> String {
        var output = ""

        for (index, section) in sections.enumerated() {
            if section.isGeneral {
                // General notes don't have a heading
                if !section.content.isEmpty {
                    output += section.content
                    if index < sections.count - 1 {
                        output += "\n\n"
                    }
                }
            } else {
                // Verse section
                if let start = section.verseStart {
                    if let end = section.verseEnd, end != start {
                        output += "## v\(start)-\(end)\n"
                    } else {
                        output += "## v\(start)\n"
                    }
                    output += section.content
                    if index < sections.count - 1 {
                        output += "\n\n"
                    }
                }
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    private static func splitFrontmatter(_ content: String) -> (frontmatter: String?, body: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("---") else {
            return (nil, content)
        }

        let afterFirstDelimiter = trimmed.dropFirst(3)

        guard let endRange = afterFirstDelimiter.range(of: "\n---") else {
            return (nil, content)
        }

        let frontmatter = String(afterFirstDelimiter[..<endRange.lowerBound])
        let bodyStart = afterFirstDelimiter.index(endRange.upperBound, offsetBy: 0, limitedBy: afterFirstDelimiter.endIndex) ?? afterFirstDelimiter.endIndex
        let body = String(afterFirstDelimiter[bodyStart...])

        return (frontmatter, body)
    }

    private static func extractFrontmatterValue(_ frontmatter: String, key: String) -> String? {
        let lines = frontmatter.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: .whitespaces)
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                if k == key {
                    return v
                }
            }
        }
        return nil
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
