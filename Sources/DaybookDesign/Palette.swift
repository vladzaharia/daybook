import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Daybook's design tokens, shared by the Mac (`DaybookStyle`) and the iPhone (`PhoneStyle`), so the
// two apps draw the same ink (docs/interface.md, "Design tokens"). Colour has one job each: red is
// recording right now, amber is something you marked, teal is selected or actionable, neon mint is
// playing now, and the brand gradient is Daybook itself or work in progress.
//
// The public API is SwiftUI and plain values only. Each app builds its own AppKit or UIKit twin from
// a token's `DaybookShade` (the notes text views need one), so nothing here names a platform type.

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

    /// The token as a colour that follows the appearance and Increase Contrast.
    public var color: Color { Color(shade: self) }

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

        /// Every token by name, for tests that keep the apps' own copies in step.
        public static let all: [String: DaybookShade] = [
            "accent": accent, "prominentFill": prominentFill, "paper": paper, "bookmark": bookmark,
            "neonMint": neonMint, "neonCyan": neonCyan, "neonViolet": neonViolet, "neonMagenta": neonMagenta,
            "playFill": playFill, "onPlayFill": onPlayFill,
            "title": title, "body": body, "secondary": secondary, "meta": meta, "faint": faint,
            "link": link, "warning": warning, "error": error, "record": record, "recordFill": recordFill
        ]
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
    /// The system's quaternary fill: chips, the meter's resting bars, the timeline's track.
    public static let quietFill = Color.platformQuaternaryFill
    /// Something that needs the person: Ink.warning on a 9% wash (the pause box, problem boxes).
    public static let attentionFill = Ink.warning.opacity(0.09)

    /// Mint into cyan into violet: Daybook itself, or work in progress. Never text or small glyphs.
    public static let brandColors = [neonMint, neonCyan, neonViolet]
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
    }
}

/// The spacing scale: 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64.
public enum DaybookSpacing {
    public static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    public static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
}

/// Three curves; motion answers only something the person did or a change of state.
public enum DaybookMotion {
    public static let hover = Animation.easeOut(duration: 0.12)
    public static let state = Animation.snappy(duration: 0.25)
    public static let page = Animation.easeInOut(duration: 0.35)
    /// What every curve becomes under Reduce Motion.
    public static let reduced = Animation.easeOut(duration: 0.15)
}

/// Type: New York for titles only, SF for everything else, monospaced digits for every time.
public enum DaybookType {
    public static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    public static func clock(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    /// Times in a margin lane: a fixed size, so "1:02:03" always fits.
    public static let marginTime = Font.system(size: 11).monospacedDigit()
}

extension View {
    /// Animates `value` with `animation`, or a short fade under Reduce Motion.
    public func daybookMotion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(DesignMotion(animation: animation, value: value))
    }

    /// A soft halo for neon in Dark Mode only. Light Mode, Increase Contrast, and Reduce
    /// Transparency get none, because there it reads as blur rather than light.
    public func daybookGlow(_ color: Color, radius: CGFloat = 4) -> some View {
        modifier(DesignGlow(color: color, radius: radius))
    }
}

private struct DesignMotion<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? DaybookMotion.reduced : animation, value: value)
    }
}

private struct DesignGlow: ViewModifier {
    let color: Color
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if scheme == .dark && contrast == .standard && !reduceTransparency {
            content.shadow(color: color.opacity(0.6), radius: radius)
        } else {
            content
        }
    }
}

// MARK: - Platform colours, kept out of the public API

extension Color {
    init(shade: DaybookShade) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let contrast = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua || DaybookShade.forcesContrast
            return NSColor(rgb: shade.hex(dark: isDark, increasedContrast: contrast))
        })
        #elseif canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: shade.hex(dark: traits.userInterfaceStyle == .dark,
                                   increasedContrast: traits.accessibilityContrast == .high || DaybookShade.forcesContrast))
        })
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
}
#elseif canImport(UIKit)
extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Times as the interface shows them: "0:14", "12:31", "1:02:03". Internal, so neither app's own
/// `TimeLabel` is shadowed.
enum ClockFormat {
    static func short(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 && value > 0 ? "−" : ""
        return sign + (value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60))
    }
}
