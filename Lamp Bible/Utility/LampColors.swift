//
//  LampColors.swift
//  Lamp Bible
//

import LampCore
import SwiftUI
import UIKit

// The colours Lamp gives a meaning to, as this app draws them. The rules for
// which is which are core's (Documentation/ColorRules.md, `LampColorRole`):
// red is the app, blue takes you somewhere in the text, and every other
// colour carries one meaning only. The accent is the AccentColor asset.
//
// Use the role, not the hue: a view asking for `.lampLink` says why its text
// is blue, and changes with the rule.

extension UIColor {
    /// A colour that follows light and dark appearance, from core's values.
    convenience init(_ themed: LampThemedColor) {
        self.init { traits in
            let rgb = traits.userInterfaceStyle == .dark ? themed.dark : themed.light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }

    /// One of core's colours that holds in either appearance.
    convenience init(_ rgb: LampRGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    /// Anything in text that takes you somewhere: verse references,
    /// cross-references, footnote markers, web links. Core's own blue, softer
    /// than the system's and readable in dense text, the one link style both
    /// apps draw.
    static let lampLink = UIColor(LampColorRole.link.color)

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = UIColor.systemPurple

    /// The same role inside running text on a reading surface (a lexicon
    /// entry's Strong's links): the system purple deepened in light and
    /// softened in dark, so a link reads as purple without glowing.
    static let lampOriginalLanguageInText = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xC2 / 255, green: 0x93 / 255, blue: 0xEC / 255, alpha: 1)
            : UIColor(red: 0x89 / 255, green: 0x44 / 255, blue: 0xAB / 255, alpha: 1)
    }

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = UIColor(LampColorRole.wordsOfChrist.color)

    /// Behind the words searched for, wherever a match is shown: the system
    /// yellow's wash in light, and in dark a solid deep amber under cream
    /// words (`lampOnFindMatch`), as the wash goes olive on charcoal.
    static let lampFindMatch = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(LampColorRole.findMatchDarkGround)
            : UIColor.systemYellow.withAlphaComponent(LampColorRole.findMatchOpacity)
    }

    /// The words on a find match's ground: the label colour in light, core's
    /// cream (`findMatchDarkText`) on the dark amber.
    static let lampOnFindMatch = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(LampColorRole.findMatchDarkText)
            : .label
    }
}

extension Color {
    /// Anything in text that takes you somewhere. Set it on links explicitly:
    /// SwiftUI draws a link in the tint, which is the accent.
    static let lampLink = Color(uiColor: .lampLink)

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = Color(uiColor: .lampOriginalLanguage)

    /// Original-language links inside running text on a reading surface.
    static let lampOriginalLanguageInText = Color(uiColor: .lampOriginalLanguageInText)

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = Color(uiColor: .lampWordsOfChrist)

    /// Behind the words searched for.
    static let lampFindMatch = Color(uiColor: .lampFindMatch)

    /// The words on a find match's ground.
    static let lampOnFindMatch = Color(uiColor: .lampOnFindMatch)
}

extension Text {
    /// Words searched for, wherever a match is shown, a result's row as much
    /// as a passage: on the find ground, in `lampOnFindMatch`, and bold, as
    /// core's colour rules mark them. Bold alone, with no ground, was tried
    /// for rows and was too easy to miss as a hit.
    static func findMatch<S: StringProtocol>(_ text: S) -> Text {
        var marked = AttributedString(String(text))
        marked.backgroundColor = .lampFindMatch
        marked.foregroundColor = .lampOnFindMatch
        return Text(marked).bold()
    }
}

extension NSMutableAttributedString {
    /// Marks words searched for in text being read as `Text.findMatch` marks
    /// them: on the find ground, in `lampOnFindMatch`, and bold in the
    /// text's own face and size.
    func markFindMatch(in range: NSRange) {
        addAttribute(.backgroundColor, value: UIColor.lampFindMatch, range: range)
        addAttribute(.foregroundColor, value: UIColor.lampOnFindMatch, range: range)
        enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? UIFont,
                  let bold = font.fontDescriptor.withSymbolicTraits(
                      font.fontDescriptor.symbolicTraits.union(.traitBold)
                  )
            else { return }
            addAttribute(.font, value: UIFont(descriptor: bold, size: font.pointSize), range: run)
        }
    }
}

extension DevotionalMeta {
    /// The category's own hue, telling the suggested kinds of writing apart
    /// at a glance; always shown with the category's name, which is all that
    /// tells a kind the writer named apart from another.
    var kindColor: Color {
        switch category {
        case "devotional": .purple
        case "exhortation": .blue
        case "reflection": .green
        case "study": .orange
        case "prayer": .pink
        default: .gray
        }
    }
}
