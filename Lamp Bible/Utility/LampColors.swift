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

    /// Anything in text that takes you somewhere: verse references,
    /// cross-references, footnote markers, web links.
    static let lampLink = UIColor.systemBlue

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = UIColor.systemPurple

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = UIColor(LampColorRole.wordsOfChrist.color)

    /// Behind the words searched for.
    static let lampFindMatch = UIColor.systemYellow
        .withAlphaComponent(LampColorRole.findMatchOpacity)
}

extension Color {
    /// Anything in text that takes you somewhere. Set it on links explicitly:
    /// SwiftUI draws a link in the tint, which is the accent.
    static let lampLink = Color(uiColor: .lampLink)

    /// Strong's numbers, Greek and Hebrew words, lexicon references.
    static let lampOriginalLanguage = Color(uiColor: .lampOriginalLanguage)

    /// Red-letter text, and only that.
    static let lampWordsOfChrist = Color(uiColor: .lampWordsOfChrist)

    /// Behind the words searched for.
    static let lampFindMatch = Color(uiColor: .lampFindMatch)
}

extension Text {
    /// Words searched for, marked as Safari marks a find: on a yellow ground,
    /// in the text's own colour.
    static func findMatch<S: StringProtocol>(_ text: S) -> Text {
        var marked = AttributedString(String(text))
        marked.backgroundColor = .lampFindMatch
        return Text(marked)
    }
}

extension DevotionalCategory {
    /// The category's own hue, telling the kinds of writing apart at a
    /// glance; always shown with the category's name.
    var kindColor: Color {
        switch self {
        case .devotional: .purple
        case .exhortation: .blue
        case .reflection: .green
        case .study: .orange
        case .prayer: .pink
        case .testimony: .teal
        case .other: .gray
        }
    }
}
