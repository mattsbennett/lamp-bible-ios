//
//  LampTheme.swift
//  Lamp Bible
//
//  The app's shared look: the surfaces things sit on, the greys text is set
//  in, the spacing and corner radii, and how scripture is typeset. Colours
//  that carry a meaning (link, original language, words of Christ, find
//  match) are roles, in LampColors.swift; this file is the neutral rest.
//
//  Ask for the token, not the value: a card says `LampTheme.Radius.card`, so
//  every card changes together.
//

import SwiftUI
import UIKit
import CoreText
import LampModuleKit

enum LampTheme {

    // MARK: - Spacing

    /// One spacing scale for padding and gaps, on a 4pt grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner radii

    enum Radius {
        /// Number tiles, chips and badges.
        static let tile: CGFloat = 10
        /// Grouped cards, menus' sections, list blocks.
        static let card: CGFloat = 14
        /// Panels and large sheets' inner surfaces.
        static let panel: CGFloat = 20
    }

    // MARK: - Surfaces

    /// The page scripture and other long text is read on.
    static let readerBackground = Color(uiColor: .lampReaderBackground)
    /// The study panel under the reader: a step off the page, so the two
    /// panes read as two surfaces.
    static let panelBackground = Color(uiColor: .lampPanelBackground)
    /// A menu's or popover's ground: lifted off the page in dark, where a
    /// black menu over a black page had no edge.
    static let menuBackground = Color(uiColor: .lampMenuBackground)
    /// A group of controls on a menu's ground.
    static let menuCard = Color(uiColor: .lampMenuCard)
    /// A feature card that leads a screen (the word analysis's summary): the
    /// card colour in light; in dark a step lighter than an ordinary card, so
    /// it stands off a near-black sheet.
    static let heroCard = Color(uiColor: .lampHeroCard)
    /// A sheet's own ground, opaque, so what is behind never reads through.
    static let sheetBackground = Color(uiColor: .lampSheetBackground)
    /// A grouped screen's ground (Settings-style lists, menus).
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    /// A card on the grouped ground.
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    /// Opaque fill for floating controls over text (the reader's search bar),
    /// so nothing reads through them.
    static let chromeFill = Color(uiColor: .lampChromeFill)
    /// The hairline round a floating control or card.
    static let hairline = Color(uiColor: .lampHairline)
    /// A visible rule: a quotation's bar, a divider that has to be seen.
    static let rule = Color(uiColor: .systemGray3)
    /// Quiet fill for an unselected tile or chip.
    static let tileFill = Color(uiColor: .lampTileFill)

    // MARK: - Text

    /// Scripture and long-form body text: a touch softer than pure black or
    /// white, which glare in a long read.
    static let readerText = Color(uiColor: .lampReaderText)
    /// Verse numbers and other small marks set inside body text.
    static let verseNumber = Color(uiColor: .lampVerseNumber)
    /// Small labels above content (section captions, metadata labels). Darker
    /// than `.tertiary`, which is too faint at caption sizes.
    static let caption = Color(uiColor: .lampCaption)

    // MARK: - Typography

    /// Scripture's typeface: New York, the system serif, as the Mac reader's.
    static func serif(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        if italic, let slanted = descriptor.withSymbolicTraits(.traitItalic) {
            descriptor = slanted
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// A caption set in small capitals, letter-spaced, for overlines such as a
    /// book's name above its chapter number.
    static func overline(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [
                [UIFontDescriptor.FeatureKey.type: kUpperCaseType,
                 UIFontDescriptor.FeatureKey.selector: kUpperCaseSmallCapsSelector],
                [UIFontDescriptor.FeatureKey.type: kLowerCaseType,
                 UIFontDescriptor.FeatureKey.selector: kLowerCaseSmallCapsSelector],
            ],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// How scripture is set at a given body size. One place for the reader's
    /// measure, leading and the size of everything that hangs off the body.
    struct Scripture {
        let bodySize: CGFloat
        /// The space the reader has chosen between lines, in points; without
        /// one, a book's leading of 1.5.
        var chosenLineSpacing: CGFloat? = nil

        /// Line pitch as a multiple of the body size: about 1.5, a book's
        /// leading, not the near double-spacing a screen tends to drift to.
        static let leading: CGFloat = 1.5
        /// The reader's side margins.
        static let margin: CGFloat = 22
        /// The widest a line runs, about 65 characters, on wide screens.
        static let measure: CGFloat = 640

        /// Extra space under each line, on top of the font's own line height.
        var lineSpacing: CGFloat {
            if let chosenLineSpacing { return chosenLineSpacing }
            let natural = LampTheme.serif(size: bodySize).lineHeight
            return max(0, bodySize * Self.leading - natural)
        }
        /// Space before a new paragraph.
        var paragraphSpacing: CGFloat { bodySize * 0.55 }
        /// Space above a section heading.
        var headingSpacingBefore: CGFloat { bodySize * 1.35 }
        /// Space between a section heading and its first verse.
        var headingSpacingAfter: CGFloat { bodySize * 0.3 }

        var verseNumberSize: CGFloat { max(11, bodySize * 0.68) }
        var verseNumberBaselineOffset: CGFloat { bodySize * 0.33 }
        var headingSize: CGFloat { bodySize * 1.06 }
    }
}

extension LampTextScale {
    /// The space between the reader's lines, in points: the Mac's scale under
    /// the Mac's key, so a setting reads the same on both.
    static let readerLineSpacing = LampTextScale(
        minimum: 2,
        maximum: 16,
        step: 1,
        defaultValue: 7
    )
    static let readerLineSpacingKey = "reader.lineSpacing"
}

// MARK: - View helpers

extension View {
    /// A line under the navigation title, where the OS draws one (iOS 26).
    @ViewBuilder
    func lampNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}

extension View {
    /// Text scrolling under a floating header stops at a firm edge rather
    /// than showing faintly through it.
    @ViewBuilder
    func lampHardTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

// MARK: - UIKit colours

extension UIColor {
    fileprivate static func lampDynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    /// White in light; in dark a near black (#121213, as the book reader's
    /// page), since pure black behind off-white text haloes over a long read.
    static let lampReaderBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 1)
            : .systemBackground
    }
    static let lampReaderText = lampDynamic(light: 0x1C1C1E, dark: 0xE9E7E3)
    static let lampVerseNumber = lampDynamic(light: 0x5F5F65, dark: 0xB4B4BB)
    static let lampCaption = lampDynamic(light: 0x6C6C70, dark: 0xA1A1A8)
    static let lampPanelBackground = lampDynamic(light: 0xF5F5F7, dark: 0x1E1E20)
    /// A sheet: white in light; in dark a step above the page and the
    /// dimmed reader behind it, so the sheet's edge shows.
    static let lampSheetBackground = lampDynamic(light: 0xFFFFFF, dark: 0x202022)
    static let lampHeroCard = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x26 / 255, green: 0x26 / 255, blue: 0x29 / 255, alpha: 1)
            : .secondarySystemGroupedBackground
    }
    static let lampMenuBackground = lampDynamic(light: 0xF2F2F7, dark: 0x1C1C1E)
    static let lampMenuCard = lampDynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let lampChromeFill = lampDynamic(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let lampTileFill = lampDynamic(light: 0xF2F2F5, dark: 0x38383C)
    static let lampHairline = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.08)
    }

    /// A highlight colour's swatch: the page's wash, made a little stronger so
    /// colours tell apart at a glance, dark ones especially.
    static func lampSwatchFill(_ color: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = color.resolvedColor(with: traits)
            return resolved.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.62 : 0.38)
        }
    }

    /// The fill behind highlighted scripture. Lighter in dark appearance than
    /// light, so a highlight tints the page rather than drowning the text.
    static func lampHighlightFill(_ color: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = color.resolvedColor(with: traits)
            guard traits.userInterfaceStyle == .dark else {
                return resolved.withAlphaComponent(0.30)
            }
            // On black a saturated tint goes muddy (yellow turns olive): lift
            // it a quarter toward white first, so it reads as a soft wash.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
            let lift: CGFloat = 0.35
            return UIColor(
                red: r + (1 - r) * lift,
                green: g + (1 - g) * lift,
                blue: b + (1 - b) * lift,
                alpha: 0.36
            )
        }
    }
}
