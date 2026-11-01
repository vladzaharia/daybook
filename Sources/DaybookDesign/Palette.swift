import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Daybook's colour tokens, the one palette both apps draw with (docs/interface.md, "Design tokens"). The
// Mac's `DaybookStyle` and the iPhone's `PhoneStyle` name these values; neither keeps a copy. Colour has
// one job each: red is recording right now, amber is something you marked, teal is selected or
// actionable, neon mint is playing now, and the brand gradient is Daybook itself or work in progress.
//
// The public API is SwiftUI and plain values, plus each token's AppKit or UIKit twin (`nsColor`,
// `uiColor`) for the notes text views.

/// One colour token: its sRGB value in light and dark appearances, and with Increase Contrast.
public struct DaybookShade: Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32
    public let lightContrast: UInt32
    public let darkContrast: UInt32

    /// Without contrast values, Increase Contrast keeps the standard ones.
    public init(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightContrast = lightContrast ?? light
        self.darkContrast = darkContrast ?? dark
    }

    /// The value for an appearance, as `0xRRGGBB`.
    public func hex(dark isDark: Bool, increasedContrast: Bool) -> UInt32 {
        switch (isDark, increasedContrast) {
        case (false, false): return light
        case (true, false): return dark
        case (false, true): return lightContrast
        case (true, true): return darkContrast
        }
    }

    /// Light, dark, light with Increase Contrast, and dark with Increase Contrast.
    public var variants: [UInt32] { [light, dark, lightContrast, darkContrast] }

    /// The token as a colour that follows the appearance and Increase Contrast.
    public var color: Color { Color(shade: self) }

    #if canImport(AppKit)
    /// The token for AppKit text views: the same values, following the appearance.
    public var nsColor: NSColor { NSColor.daybookShade(self) }
    #elseif canImport(UIKit)
    /// The token for UIKit text views: the same values, following the traits.
    public var uiColor: UIColor { UIColor.daybookShade(self) }
    #endif

    #if DEBUG
    /// Debug: every token draws its Increase Contrast value, for snapshots. The system setting
    /// can't be turned on for one app, and a high-contrast `NSAppearance` can't be made by name.
    nonisolated(unsafe) public static var simulatesIncreasedContrast = false
    #endif

    static var forcesContrast: Bool {
        #if DEBUG
        simulatesIncreasedContrast
        #else
        false
        #endif
    }
}

/// Every colour token. `Shade` holds the values; the rest are the colours made from them.
public enum DaybookPalette {
    public enum Shade {
        /// Electric Teal: selection, focus, checkboxes, the meter, page bullets. Never text (`link`).
        public static let accent = DaybookShade(light: 0x00806F, dark: 0x00A3A0, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
        /// Filled buttons with white labels (4.5:1 or better).
        public static let prominentFill = DaybookShade(light: 0x00796B, dark: 0x007F73, lightContrast: 0x005F52, darkContrast: 0x005F52)
        /// The reading surface.
        public static let paper = DaybookShade(light: 0xFDFCFA, dark: 0x18181B, lightContrast: 0xFFFFFF, darkContrast: 0x000000)
        /// Bookmarks, and nothing else.
        public static let bookmark = DaybookShade(light: 0xA86400, dark: 0xFFD23F, lightContrast: 0x8A5200, darkContrast: 0xFFDF70)
        public static let neonMint = DaybookShade(light: 0x00B894, dark: 0x3DFFD0)
        public static let neonCyan = DaybookShade(light: 0x0096C7, dark: 0x33E1FF)
        public static let neonViolet = DaybookShade(light: 0x7C3AED, dark: 0xB388FF)
        public static let neonMagenta = DaybookShade(light: 0xD6249F, dark: 0xFF4FD8)
        public static let playFill = DaybookShade(light: 0x00796B, dark: 0x3DFFD0)
        public static let onPlayFill = DaybookShade(light: 0xFFFFFF, dark: 0x05201B)

        // The Ink scale: text on paper. Contrast is against `paper`.
        public static let title = DaybookShade(light: 0x1A1917, dark: 0xF5F4F0, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        public static let body = DaybookShade(light: 0x2B2A26, dark: 0xDFDDD7, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        public static let secondary = DaybookShade(light: 0x66625A, dark: 0xA29F98, lightContrast: 0x45423C, darkContrast: 0xC9C6BF)
        public static let meta = DaybookShade(light: 0x78736A, dark: 0x8A877F, lightContrast: 0x5E5A52, darkContrast: 0xA9A6A0)
        /// Placeholders and disabled text only; never information.
        public static let faint = DaybookShade(light: 0xB4AFA5, dark: 0x5A5853, lightContrast: 0x86817A, darkContrast: 0x86827C)
        public static let link = DaybookShade(light: 0x00796B, dark: 0x34D9C3, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
        public static let warning = DaybookShade(light: 0xB45309, dark: 0xFFB054, lightContrast: 0x8A3F00, darkContrast: 0xFFC37A)
        public static let error = DaybookShade(light: 0xC4271D, dark: 0xFF6961, lightContrast: 0x9E1B12, darkContrast: 0xFF8A84)
        /// Recording, right now: the dot, the clock, Stop. Nothing else is red.
        public static let record = DaybookShade(light: 0xD92D20, dark: 0xFF453A)
        /// Stop's fill; white labels keep 4.5:1 on it.
        public static let recordFill = DaybookShade(light: 0xD92D20, dark: 0xE5243B)

        /// The core tokens by name: the twenty each app once kept its own copy of.
        public static let all: [String: DaybookShade] = [
            "accent": accent, "prominentFill": prominentFill, "paper": paper, "bookmark": bookmark,
            "neonMint": neonMint, "neonCyan": neonCyan, "neonViolet": neonViolet, "neonMagenta": neonMagenta,
            "playFill": playFill, "onPlayFill": onPlayFill,
            "title": title, "body": body, "secondary": secondary, "meta": meta, "faint": faint,
            "link": link, "warning": warning, "error": error, "record": record, "recordFill": recordFill
        ]

        // MARK: Inks for one place each

        /// Text on an accent wash (a tag chip, a tinted button, an action tile): `link` a step darker in
        /// Light Mode, so it keeps 4.5:1 on the 12–14% wash.
        public static let onWash = DaybookShade(light: 0x006B5E, dark: 0x34D9C3, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
        /// A bookmark count on its 20% amber pill.
        public static let bookmarkCount = DaybookShade(light: 0x8A5200, dark: 0xFFD23F, lightContrast: 0x6E4100, darkContrast: 0xFFDF70)
        /// A glyph for audio that's live (playing, listening): neon mint in Dark Mode, where neon reads as
        /// light; link ink in Light Mode, where mint is too faint (2.4:1) to read as a glyph.
        public static let liveGlyph = DaybookShade(light: 0x00796B, dark: 0x3DFFD0, lightContrast: 0x005F52, darkContrast: 0x3DFFD0)
        /// Behind a search match on the page and in the transcript: opaque, so the match's ink is the
        /// same on any paper.
        public static let findHighlight = DaybookShade(light: 0xFFE14D, dark: 0xE6C229, lightContrast: 0xFFD60A, darkContrast: 0xFFD60A)
        /// A search match's words: dark in both appearances, on `findHighlight`.
        public static let onFind = DaybookShade(light: 0x1A1917, dark: 0x1A1917, lightContrast: 0x000000, darkContrast: 0x000000)
        /// Warning words on a warning wash (an attention chip, a problem box's title): `warning` a step
        /// darker in Light Mode, where the 8–9% wash takes it under 4.5:1.
        public static let onAttention = DaybookShade(light: 0x9C4706, dark: 0xFFB054, lightContrast: 0x8A3F00, darkContrast: 0xFFC37A)

        /// The inks above by name.
        public static let roles: [String: DaybookShade] = [
            "onWash": onWash, "bookmarkCount": bookmarkCount, "liveGlyph": liveGlyph,
            "findHighlight": findHighlight, "onFind": onFind, "onAttention": onAttention
        ]

        /// Speaker inks, assigned by first appearance: speaker names, the inspector's dots and bars, and
        /// an owner chip's fill. Tailwind 700s in Light Mode, deep enough for 12 pt names; 300s in Dark.
        public static let speakers: [DaybookShade] = [
            DaybookShade(light: 0x0369A1, dark: 0x7DD3FC), DaybookShade(light: 0xA21CAF, dark: 0xF0ABFC),
            DaybookShade(light: 0x15803D, dark: 0x86EFAC), DaybookShade(light: 0xC2410C, dark: 0xFDBA74),
            DaybookShade(light: 0x0E7490, dark: 0x67E8F9), DaybookShade(light: 0xBE123C, dark: 0xFDA4AF)
        ]
        /// An owner chip's text on its speaker's 14% wash: the Tailwind 800s in Light Mode (the 700s fall
        /// to about 4.1:1 there), the same 300s in Dark.
        public static let ownerText: [DaybookShade] = [
            DaybookShade(light: 0x075985, dark: 0x7DD3FC), DaybookShade(light: 0x86198F, dark: 0xF0ABFC),
            DaybookShade(light: 0x166534, dark: 0x86EFAC), DaybookShade(light: 0x9A3412, dark: 0xFDBA74),
            DaybookShade(light: 0x155E75, dark: 0x67E8F9), DaybookShade(light: 0x9F1239, dark: 0xFDA4AF)
        ]

        /// Every token by name, the role inks, speakers, owners, and the Live Activity's fills and labels
        /// included, for tests that resolve each one.
        public static var every: [String: DaybookShade] {
            var every = all.merging(roles) { first, _ in first }
            for (index, shade) in speakers.enumerated() { every["speaker\(index)"] = shade }
            for (index, shade) in ownerText.enumerated() { every["owner\(index)"] = shade }
            for (name, ink) in ActivityInk.named {
                every["activity.\(name).fill"] = ink.fill
                every["activity.\(name).label"] = ink.label
            }
            return every
        }
    }

    public static let accent = Shade.accent.color
    public static let prominentFill = Shade.prominentFill.color
    public static let paper = Shade.paper.color
    public static let bookmark = Shade.bookmark.color
    public static let neonMint = Shade.neonMint.color
    public static let neonCyan = Shade.neonCyan.color
    public static let neonViolet = Shade.neonViolet.color
    public static let neonMagenta = Shade.neonMagenta.color
    public static let playFill = Shade.playFill.color
    public static let onPlayFill = Shade.onPlayFill.color
    /// A glyph for live audio: mint in Dark Mode, link ink in Light (`Shade.liveGlyph`).
    public static let liveGlyph = Shade.liveGlyph.color
    /// Behind a search match (`FindHighlight`).
    public static let findHighlight = Shade.findHighlight.color
    /// The system's quaternary fill: chips, the meter's resting bars, the timeline's track.
    public static let quietFill = Color.platformQuaternaryFill
    /// Something that needs the person: Ink.warning on a 9% wash (the pause box, problem chips).
    public static let attentionFill = DaybookWash.attention.color
    /// An accent wash behind text in `Ink.onWash`: tag chips, tinted buttons (14%).
    public static let accentWash = DaybookWash.accent.color

    /// Speaker inks, assigned by first appearance (`Shade.speakers`).
    public static let speakerInks: [Color] = Shade.speakers.map(\.color)
    /// A speaker's ink; secondary ink for nobody in particular.
    public static func speakerInk(_ index: Int?) -> Color {
        guard let index else { return Ink.secondary }
        return speakerInks[abs(index) % speakerInks.count]
    }
    /// The text of a speaker's owner chip, on `speakerInk(index)` at 14% (`Shade.ownerText`).
    public static func ownerInk(_ index: Int?) -> Color {
        guard let index else { return Ink.secondary }
        return ownerInks[abs(index) % ownerInks.count]
    }
    private static let ownerInks: [Color] = Shade.ownerText.map(\.color)

    /// Mint into cyan into violet: Daybook itself, or work in progress. Never text or small glyphs.
    public static let brandColors = [neonMint, neonCyan, neonViolet]

    /// What the brand gradient is drawing, which sets its direction.
    public enum GradientRole: Sendable {
        /// Progress bars and lines: left to right, the way the work goes.
        case progress
        /// The mark, an empty state's symbol, Welcome's bullets: corner to corner.
        case mark
    }

    public static func brandGradient(_ role: GradientRole) -> LinearGradient {
        switch role {
        case .progress: return brandGradient(from: .leading, to: .trailing)
        case .mark: return brandGradient(from: .topLeading, to: .bottomTrailing)
        }
    }

    public static func brandGradient(from start: UnitPoint = .leading, to end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: brandColors, startPoint: start, endPoint: end)
    }

    /// Text on paper.
    public enum Ink {
        public static let title = Shade.title.color
        public static let body = Shade.body.color
        public static let secondary = Shade.secondary.color
        public static let meta = Shade.meta.color
        public static let faint = Shade.faint.color
        public static let link = Shade.link.color
        public static let warning = Shade.warning.color
        public static let error = Shade.error.color
        public static let record = Shade.record.color
        public static let recordFill = Shade.recordFill.color
        /// Text on an accent wash (`Shade.onWash`).
        public static let onWash = Shade.onWash.color
        /// A bookmark count on its amber pill (`Shade.bookmarkCount`).
        public static let bookmarkCount = Shade.bookmarkCount.color
        /// A search match's words (`Shade.onFind`).
        public static let onFind = Shade.onFind.color
        /// Warning words on the warning wash (`Shade.onAttention`).
        public static let onAttention = Shade.onAttention.color
    }

    /// A filled button's fill and label, as the Live Activity draws them on the Lock Screen and in the
    /// Dynamic Island. Every label keeps 4.5:1 on its fill in every appearance.
    public struct ActivityInk: Hashable, Sendable {
        public let fill: DaybookShade
        public let label: DaybookShade

        public init(fill: DaybookShade, label: DaybookShade) {
            self.fill = fill
            self.label = label
        }

        /// Bookmark is amber, so its label is dark where the amber is light.
        public static let bookmark = ActivityInk(fill: DaybookShade(light: 0xA86400, dark: 0xFFD23F, lightContrast: 0x8A5200, darkContrast: 0xFFDF70),
                                                 label: DaybookShade(light: 0xFFFFFF, dark: 0x1F1600, lightContrast: 0xFFFFFF, darkContrast: 0x1F1600))
        /// Resume isn't recording yet, so it isn't red: ink on paper, inverted.
        public static let resume = ActivityInk(fill: DaybookShade(light: 0x1A1917, dark: 0xF5F4F0, lightContrast: 0x000000, darkContrast: 0xFFFFFF),
                                               label: DaybookShade(light: 0xFFFFFF, dark: 0x1A1917, lightContrast: 0xFFFFFF, darkContrast: 0x000000))
        public static let stop = ActivityInk(fill: DaybookShade(light: 0xD92D20, dark: 0xE5243B, lightContrast: 0xB4221A, darkContrast: 0xC81E30),
                                             label: DaybookShade(light: 0xFFFFFF, dark: 0xFFFFFF, lightContrast: 0xFFFFFF, darkContrast: 0xFFFFFF))
        public static let all = [bookmark, resume, stop]
        static let named: [(String, ActivityInk)] = [("bookmark", bookmark), ("resume", resume), ("stop", stop)]
    }
}

/// WCAG 2 contrast between two sRGB colours, 1...21: what the token tests hold every ink to.
public enum DaybookContrast {
    /// Relative luminance of `0xRRGGBB`.
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }

    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color` laid at `opacity` over `background`, as a wash draws it.
    public static func composite(_ color: UInt32, opacity: Double, over background: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let top = Double((color >> shift) & 0xFF), bottom = Double((background >> shift) & 0xFF)
            return UInt32((top * opacity + bottom * (1 - opacity)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    /// The opaque colour a wash makes over `paper` in an appearance. The quiet fill is the system's
    /// quaternary fill as both platforms draw it: rgba(116, 116, 128, 0.08) in Light, rgba(118, 118, 128,
    /// 0.18) in Dark.
    public static func flattened(_ wash: DaybookWash, over paper: UInt32, dark: Bool, increasedContrast: Bool) -> UInt32 {
        switch wash {
        case .none:
            return paper
        case .quiet:
            return composite(dark ? 0x767680 : 0x747480, opacity: dark ? 0.18 : 0.08, over: paper)
        case .tint(let shade, let light, let darkOpacity):
            return composite(shade.hex(dark: dark, increasedContrast: increasedContrast), opacity: dark ? darkOpacity : light, over: paper)
        }
    }

    /// Words in `pair.ink` on `pair.wash` laid over the paper, in an appearance.
    public static func ratio(_ pair: DaybookInkPair, dark: Bool, increasedContrast: Bool) -> Double {
        let paper = DaybookPalette.Shade.paper.hex(dark: dark, increasedContrast: increasedContrast)
        return ratio(pair.ink.hex(dark: dark, increasedContrast: increasedContrast),
                     flattened(pair.wash, over: paper, dark: dark, increasedContrast: increasedContrast))
    }
}

/// What sits behind words in a chip or a box, as values the token tests can lay over paper.
public enum DaybookWash: Hashable, Sendable {
    /// Nothing: the words are on the paper.
    case none
    /// The system's quaternary fill (`DaybookPalette.quietFill`).
    case quiet
    /// A shade at an opacity in Light Mode and another in Dark.
    case tint(DaybookShade, light: Double, dark: Double)

    /// The 14% accent wash: tag chips, tinted buttons.
    public static let accent = DaybookWash.tint(DaybookPalette.Shade.accent, light: 0.14, dark: 0.14)
    /// The 9% warning wash: an attention chip, the pause box.
    public static let attention = DaybookWash.tint(DaybookPalette.Shade.warning, light: 0.09, dark: 0.09)

    /// The wash as SwiftUI draws it, following the appearance.
    public var color: Color {
        switch self {
        case .none: return .clear
        case .quiet: return DaybookPalette.quietFill
        case .tint(let shade, let light, let dark):
            return light == dark ? shade.color.opacity(light) : Color(shade: shade, opacity: light, darkOpacity: dark)
        }
    }
}

/// Words and the wash they sit on: what a chip or a box draws, and what the token tests hold to 4.5:1.
public struct DaybookInkPair: Hashable, Sendable {
    public let ink: DaybookShade
    public let wash: DaybookWash

    public init(ink: DaybookShade, wash: DaybookWash) {
        self.ink = ink
        self.wash = wash
    }
}

// MARK: - Platform colours

extension Color {
    init(shade: DaybookShade, opacity: Double = 1, darkOpacity: Double = 1) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor.daybookShade(shade, opacity: opacity, darkOpacity: darkOpacity))
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor.daybookShade(shade, opacity: opacity, darkOpacity: darkOpacity))
        #endif
    }

    static var platformQuaternaryFill: Color {
        #if canImport(AppKit)
        Color(nsColor: .quaternarySystemFill)
        #elseif canImport(UIKit)
        Color(uiColor: .quaternarySystemFill)
        #endif
    }

    /// The system's tertiary label: a resting meter, a dot that isn't live.
    static var platformTertiaryLabel: Color {
        #if canImport(AppKit)
        Color(nsColor: .tertiaryLabelColor)
        #elseif canImport(UIKit)
        Color(uiColor: .tertiaryLabel)
        #endif
    }
}

#if canImport(AppKit)
extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// The shade, following the appearance; at an opacity (another in Dark Mode) for a wash.
    fileprivate static func daybookShade(_ shade: DaybookShade, opacity: Double = 1, darkOpacity: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let contrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua || DaybookShade.forcesContrast
            let color = NSColor(rgb: shade.hex(dark: isDark, increasedContrast: contrast))
            let alpha = isDark ? darkOpacity : opacity
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
        }
    }
}
#elseif canImport(UIKit)
extension UIColor {
    fileprivate convenience init(daybookRGB rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// The shade, following the traits; at an opacity (another in Dark Mode) for a wash.
    fileprivate static func daybookShade(_ shade: DaybookShade, opacity: Double = 1, darkOpacity: Double = 1) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let color = UIColor(daybookRGB: shade.hex(dark: isDark,
                                                      increasedContrast: traits.accessibilityContrast == .high || DaybookShade.forcesContrast))
            let alpha = isDark ? darkOpacity : opacity
            return alpha < 1 ? color.withAlphaComponent(alpha) : color
        }
    }
}
#endif
