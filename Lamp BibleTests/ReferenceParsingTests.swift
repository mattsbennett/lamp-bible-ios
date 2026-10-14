import XCTest
@testable import Lamp_Bible

/// Exercises the parser used by dictionary views, rather than a copy of it.
final class ReferenceParsingTests: XCTestCase {
    func testMixedMarkersKeepTheProvidedScriptureRangesInOrder() {
        let segments = parseLinkedTextWithReferences(
            "🌿 café ⟨G932⟩ (⟦Matt. 4:23⟧); ⦃BDB871⦄ ⟦9:35⟧",
            references: [
                VerseRef(sv: 40_004_023, ev: 40_004_025),
                VerseRef(sv: 40_009_035, ev: nil),
            ]
        )
        XCTAssertEqual(segments, [
            .text("🌿 café "), .strongs("G932"), .text(" ("),
            .verseRef(display: "Matt. 4:23", verseId: 40_004_023,
                endVerseId: 40_004_025, fullRef: "Matt. 4:23"),
            .text("); "), .bdbRef("BDB871"), .text(" "),
            .verseRef(display: "9:35", verseId: 40_009_035, fullRef: "Matt. 9:35"),
        ])
    }

    func testFallbackReferencesUseThePreviousBookAndChapter() {
        let segments = parseLinkedTextWithReferences(
            "⟦John 16:8⟧, ⟦9⟧; ⟦17:1⟧", references: []
        )
        XCTAssertEqual(segments, [
            .verseRef(display: "John 16:8", verseId: 43_016_008, fullRef: "John. 16:8"),
            .text(", "),
            .verseRef(display: "9", verseId: 43_016_009, fullRef: "John. 16:9"),
            .text("; "),
            .verseRef(display: "17:1", verseId: 43_017_001, fullRef: "John. 17:1"),
        ])
    }

    func testMissingMetadataContinuesFromTheLastProvidedReference() {
        let segments = parseLinkedTextWithReferences(
            "⟦Daniel (4:12⟧; ⟦14⟧)", references: [VerseRef(sv: 27_004_012, ev: nil)]
        )
        XCTAssertEqual(segments, [
            .text("Daniel ("),
            .verseRef(display: "4:12", verseId: 27_004_012, fullRef: "Dan. 4:12"),
            .text("; "),
            .verseRef(display: "14", verseId: 27_004_014, fullRef: "Dan. 4:14"),
            .text(")"),
        ])
    }

    func testInvalidFallbackReferenceStaysReadableWithoutALink() {
        XCTAssertEqual(parseLinkedTextWithReferences("See ⟦John 1000:1⟧.", references: []),
            [.text("See "), .text("John 1000:1"), .text(".")])
    }

    func testPlainTextAndMalformedMarkersArePreserved() {
        for text in ["No annotations 🌿", "Unclosed ⟦John 1:1", ""] {
            XCTAssertEqual(parseLinkedTextWithReferences(text, references: []), [.text(text)])
        }
    }
}
