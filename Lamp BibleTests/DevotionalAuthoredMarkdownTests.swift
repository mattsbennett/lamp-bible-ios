import XCTest
@testable import Lamp_Bible

/// A writing that came from the Mac has no blocks of its own: its body is
/// authored Markdown, wrapped in one paragraph because the portable format has
/// nowhere else to put it. Unwrapping it is what keeps the two devices holding
/// the same bytes.
final class DevotionalAuthoredMarkdownTests: XCTestCase {
    /// Every shape a flattener mangles: an image, a footnote, a nested list,
    /// a quote and a table.
    private let body = """
        This is a test. Test. Another test.

        ![Caption](media/32D89C7E-7EB3-45F7-9D24-8E8CC8EC0679)

        Asdf Handbag[^1]

        1. Test
        2. Test
           - Nest[^2]
        3. Test

        > A quote

        | One | Two |
        | --- | --- |
        | a | b |

        [^1]: First
        [^2]: Second
        """

    /// The wrapper the Mac's JSON document carries.
    private func wrapped(_ markdown: String) -> Devotional {
        Devotional(
            meta: DevotionalMeta(
                id: "B7FAA5A6", title: "Test Title",
                created: 1_769_317_935, lastModified: 1_788_132_249
            ),
            content: .blocks([.paragraph(markdown)])
        )
    }

    func testAWrappedBodyIsRecognisedAsAuthoredMarkdown() throws {
        let unwrapped = MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(wrapped(body))
        XCTAssertEqual(unwrapped.markdownContent, body)
    }

    /// The point of the unwrap: what gets stored is the body, character for
    /// character, not a block tree that happens to render like it.
    func testTheStoredEntryKeepsTheBodyCharacterForCharacter() throws {
        let entry = DevotionalEntry(
            from: MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(wrapped(body)),
            moduleId: "devotionals"
        )
        XCTAssertEqual(entry.contentJson, body)

        // And it survives being read back out and stored again, which is what
        // every sync that changes nothing does.
        let reread = try XCTUnwrap(entry.toDevotional())
        XCTAssertEqual(reread.markdownContent, body)
        let republished = DevotionalEntry(from: reread, moduleId: "devotionals")
        XCTAssertEqual(republished.contentJson, body)
        XCTAssertEqual(republished.lastModified, entry.lastModified)
    }

    /// Without the unwrap the authored text is stored as a block tree, so this
    /// device stops holding the bytes the other one sent. Both copies still
    /// carry the same change time, because nobody edited anything — which is
    /// the disagreement that cannot be settled.
    func testWithoutTheUnwrapTheStoredTextIsNoLongerWhatArrived() throws {
        let asBlocks = DevotionalEntry(from: wrapped(body), moduleId: "devotionals")
        XCTAssertNotEqual(asBlocks.contentJson, body)
        XCTAssertTrue(asBlocks.contentJson.hasPrefix("["), "stored as a block tree")

        let unwrapped = DevotionalEntry(
            from: MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(wrapped(body)),
            moduleId: "devotionals"
        )
        XCTAssertEqual(unwrapped.contentJson, body)
        XCTAssertEqual(unwrapped.lastModified, asBlocks.lastModified)
    }

    /// Genuine rich content keeps its structure; the unwrap must only catch a
    /// body that was never blocks to begin with.
    func testRealBlocksAreLeftAlone() throws {
        let rich = Devotional(
            meta: DevotionalMeta(id: "R1", title: "Rich"),
            content: .blocks([.heading("A heading", level: 2), .paragraph("Body.")])
        )
        XCTAssertNil(MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(rich).markdownContent)
    }

    /// A devotional that already carries its authored text is not touched.
    func testAnExistingMarkdownBodyIsNotReplaced() throws {
        var devotional = wrapped("wrapper text")
        devotional.markdownContent = "the real body"
        XCTAssertEqual(
            MarkdownDevotionalConverter.unwrappingAuthoredMarkdown(devotional).markdownContent,
            "the real body"
        )
    }
}
