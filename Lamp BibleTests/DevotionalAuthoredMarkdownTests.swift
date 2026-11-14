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

/// The writing list previews each piece by its opening prose, so the
/// Markdown around that prose must not show.
final class WritingExcerptTests: XCTestCase {
    func testHeadingsAndMarkersAreLeftOut() {
        let markdown = """
        # Title

        Paul has **spent** seven chapters[^1] showing that the [law](lampbible://verse/45001001) cannot save.

        > A quotation that follows.

        [^1]: A note.
        """
        XCTAssertEqual(
            DevotionalListRow.excerpt(fromMarkdown: markdown),
            "Paul has spent seven chapters showing that the law cannot save. A quotation that follows."
        )
    }

    func testListsAndRulesGiveTheirTextOnly() {
        let markdown = """
        ---
        1. First point
        - second point
        """
        XCTAssertEqual(DevotionalListRow.excerpt(fromMarkdown: markdown), "First point second point")
    }

    func testNothingToShowIsNil() {
        XCTAssertNil(DevotionalListRow.excerpt(fromMarkdown: "## Only a heading\n\n---\n"))
    }
}

/// A quiz answer's first sentence is set heavier as its gist, but only when
/// there is more after it and it is short enough to read as one.
final class QuizAnswerLeadTests: XCTestCase {
    func testTheFirstSentenceIsTheLead() {
        let text = "Love is patient. It keeps no record of wrongs."
        let range = QuizSheetView.firstSentenceRange(in: text)
        XCTAssertEqual(range.map { (text as NSString).substring(with: $0) }, "Love is patient.")
    }

    func testOneSentenceHasNoLead() {
        XCTAssertNil(QuizSheetView.firstSentenceRange(in: "Love is patient."))
    }

    func testALongFirstSentenceHasNoLead() {
        let long = String(repeating: "word ", count: 40) + "end. Then more."
        XCTAssertNil(QuizSheetView.firstSentenceRange(in: long))
    }
}

/// A long quiz answer is broken into short paragraphs without moving any
/// character, so the annotations' offsets stay true.
final class QuizAnswerParagraphTests: XCTestCase {
    func testEverySecondSentenceEndsAParagraph() {
        let text = "One is here and it is long enough to count. Two follows it with more words in it. "
            + "Three carries on the thought a little further. Four closes the answer with a last idea. "
            + "Five is an afterthought, added only to make the whole answer run long enough."
        let result = QuizSheetView.paragraphed(text)
        XCTAssertEqual(result.count, text.count)
        XCTAssertEqual(result.components(separatedBy: "\n").count, 3, result)
        XCTAssertTrue(result.hasPrefix("One is here and it is long enough to count. Two follows it with more words in it.\nThree"))
    }

    /// The Colossians 1 answer that broke after "(cf.": an abbreviation's
    /// stop, or one inside brackets, ends no paragraph, and the break moves
    /// on to the next sentence that does end.
    func testNoParagraphEndsAfterAnAbbreviationOrInsideBrackets() {
        let text = "Paul calls it a mystery now revealed to the saints. "
            + "That God's redemptive purpose in Christ extends to Gentiles, not just Israel. "
            + "This was latent in OT promises (cf. Genesis 12:3; Isaiah 49:6) but only fully revealed through the apostolic gospel. "
            + "Paul describes himself as a steward (lit. a household manager. See v.25) of this revelation, e.g. in his sufferings. "
            + "The goal is corporate maturity."
        let result = QuizSheetView.paragraphed(text)
        XCTAssertEqual(result.count, text.count)
        XCTAssertEqual(result.components(separatedBy: "\n"), [
            "Paul calls it a mystery now revealed to the saints. That God's redemptive purpose in Christ extends to Gentiles, not just Israel.",
            "This was latent in OT promises (cf. Genesis 12:3; Isaiah 49:6) but only fully revealed through the apostolic gospel. "
                + "Paul describes himself as a steward (lit. a household manager. See v.25) of this revelation, e.g. in his sufferings.",
            "The goal is corporate maturity.",
        ])
        let lead = QuizSheetView.firstSentenceRange(in: "Compare it (cf. Gen. 1:1) with this. Then more.")
        XCTAssertEqual(lead.map { ("Compare it (cf. Gen. 1:1) with this. Then more." as NSString).substring(with: $0) },
                       "Compare it (cf. Gen. 1:1) with this.")
    }

    func testAShortAnswerIsLeftWhole() {
        let text = "Love is patient. It is kind. It keeps no record of wrongs."
        XCTAssertEqual(QuizSheetView.paragraphed(text), text)
    }
}

/// A verse reference in quiz text never breaks between book and verse, and
/// keeping it together moves no character.
final class QuizReferenceSpacingTests: XCTestCase {
    func testSpacesInsideAReferenceDoNotBreak() {
        let json = #"{"text":"What does Hosea 3:1 say?","annotations":[{"type":"scripture","start":10,"end":19,"data":{"sv":28003001}}]}"#
        let parsed = QuizTextParser.parse(json)
        let result = QuizSheetView.keepingReferencesTogether(parsed.text, annotations: parsed.annotations ?? [])
        XCTAssertEqual(result.count, parsed.text.count)
        XCTAssertEqual(result, "What does Hosea\u{00A0}3:1 say?")
    }

    func testTextWithoutReferencesIsUnchanged() {
        XCTAssertEqual(QuizSheetView.keepingReferencesTogether("Love is patient", annotations: []), "Love is patient")
    }
}
