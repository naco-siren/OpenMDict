//
//  FeudPalette.swift
//  OpenMDict-iOS
//
//  Shared colors and fonts for the Phrase Feud mode. Consolidated here so
//  the board / cards / banner / overlays all stay visually consistent and
//  any future themed tweak (e.g. "British Family Feud" black-and-red era)
//  is a single-file edit.
//
//  Color values estimated from broadcast set descriptions (Steve Harvey
//  era, post-2010). Not officially published anywhere, so these are reasonable
//  approximations that read as "Family Feud" on screen rather than exact
//  matches.
//

import UIKit

@available(iOS 26, *)
enum FeudPalette {

    // MARK: - Colors

    /// Deep navy — the board's interior background, behind all cards.
    static let boardBackground = UIColor(rgb: 0x0A2A66)

    /// Slightly lighter navy — for gradients / hairlines if needed.
    static let boardBackgroundLight = UIColor(rgb: 0x1E4D9B)

    /// Bright "stage bulb" yellow used for the marquee dots, the arch's
    /// inner stroke, and the answer board's gold ring. Bumped from a
    /// muted goldenrod (0xD4A017) to a vivid yellow that reads as
    /// illuminated lights at on-screen scale — closer to the broadcast's
    /// actual bulb color than the more muted "metallic gold" of the set
    /// chrome.
    static let goldBorder = UIColor(rgb: 0xFFEE00)

    /// Dark gold — used for shadowed gradients on the board frame.
    static let goldBorderDark = UIColor(rgb: 0xB8860B)

    /// Card slot in the un-revealed state. Near-black so revealed cards pop.
    static let cardUnrevealed = UIColor(rgb: 0x0C1B3A)

    /// Card slot in the revealed state — saturated medium blue.
    static let cardRevealed = UIColor(rgb: 0x1F4DB8)

    /// Score chip background (post-2008 Harvey-era is blue, was red before).
    static let scoreChipBackground = UIColor(rgb: 0x1F4DB8)

    /// Strike-X overlay tint.
    static let strikeRed = UIColor(rgb: 0xD32F2F)

    /// Dark brown frame around the question banner — distinct from the
    /// gold board border so the banner reads as a separate "monitor"
    /// element rather than blending into the board chrome.
    static let frameDarkBrown = UIColor(rgb: 0x4A2F0C)

    /// Bright saffron-yellow used for question text (on the dark blue
    /// banner interior). Pure white was too washed-out alongside the gold
    /// board frame; this ties the banner visually to the rest of the set.
    static let goldText = UIColor(rgb: 0xFFD700)

    /// Pure black for the stage backdrop. Dots tile on top of this.
    static let archBackground = UIColor.black

    /// Lighter blue used as the middle stop in the score-area gradient.
    static let cardScoreLight = UIColor(rgb: 0x4D7FE8)

    // MARK: - Answer card gradient stops

    /// Top + bottom stops of the answer-area (left side) gradient.
    /// Very dark navy — needs strong contrast against the middle stop so
    /// the gradient reads at small card sizes.
    static let gradientDeep = UIColor(rgb: 0x07153B)

    /// Middle stop of the answer-area (left) gradient AND top/bottom
    /// stops of the score-area (right) gradient.
    static let gradientMid = UIColor(rgb: 0x2A5BC8)

    /// Middle stop of the score-area (right) gradient.
    /// The score side is overall brighter than the answer side — visual
    /// emphasis on the number.
    static let gradientBright = UIColor(rgb: 0x6798F0)

    // MARK: - Fonts

    /// Answer-card text font. Helvetica Neue Bold (non-condensed) reads
    /// as a wide, broadcast-weight sans — closer to the stage typography
    /// (Berthold Akzidenz Grotesk BE) than the previous Condensed cut,
    /// which felt too narrow for short single-word answers.
    static func answerFont(size: CGFloat) -> UIFont {
        UIFont(name: "HelveticaNeue-Bold", size: size)
            ?? .systemFont(ofSize: size, weight: .bold)
    }

    /// Numeral font — score chips and slot numbers. Arial Bold since 2010
    /// on the broadcast (the regular-weight Arial reads too thin
    /// next to the bold answer text).
    static func numberFont(size: CGFloat) -> UIFont {
        UIFont(name: "Arial-BoldMT", size: size)
            ?? .systemFont(ofSize: size, weight: .heavy)
    }

    /// Question banner font — readable medium weight (the broadcast's
    /// Clarendon Bold reads quite heavy on TV but feels too thick on a
    /// phone screen, where it competes with the band/dot chrome around
    /// it; medium gives enough emphasis without the visual weight).
    static func bannerFont(size: CGFloat) -> UIFont {
        .systemFont(ofSize: size, weight: .medium)
    }
}

// MARK: - UIColor hex helper

extension UIColor {
    /// Convenience for inline hex literals like `0xD4A017` (RGB, alpha=1).
    convenience init(rgb: Int) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
