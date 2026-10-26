import SwiftUI
import UIKit

/// Daybook's design tokens on iPhone, from docs/interface.md. The Mac's DaybookStyle is the
/// reference; the values here are the same so a conversation reads the same on both.
///
/// Colour has one job each: red means recording right now, amber means something you marked,
/// teal means selected or actionable, neon mint means playing now, and the brand gradient means
/// Daybook itself or work in progress. Nothing else is red or amber.
enum PhoneStyle {
    /// Electric Teal: selection, focus, checkboxes, the play pill's fill, page bullets. Never text
    /// (use `Ink.link`).
    static let accent = Color(light: 0x00806F, dark: 0x00A3A0, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
    /// Prominent buttons, so white labels keep 4.5:1.
    static let prominentFill = Color(light: 0x00796B, dark: 0x007F73, lightContrast: 0x005F52, darkContrast: 0x005F52)
    /// The reading surface. Chrome stays on system materials.
    static let paper = Color(light: 0xFDFCFA, dark: 0x18181B, lightContrast: 0xFFFFFF, darkContrast: 0x000000)
    /// Bookmarks only.
    static let bookmark = Color(light: 0xA86400, dark: 0xFFD23F, lightContrast: 0x8A5200, darkContrast: 0xFFDF70)
    /// Playing now: the playhead rule and wash, the scrubber, the play button. Never text in light mode.
    static let neonMint = Color(light: 0x00B894, dark: 0x3DFFD0)
    /// The glow under progress and the mark; never a fill on its own.
    static let neonCyan = Color(light: 0x0096C7, dark: 0x33E1FF)
    /// Inside the brand gradient only.
    static let neonViolet = Color(light: 0x7C3AED, dark: 0xB388FF)
    /// Removed words in Version History.
    static let neonMagenta = Color(light: 0xD6249F, dark: 0xFF4FD8)
    /// The player's play button: deep teal with white in light mode, neon mint with ink in dark.
    static let playFill = Color(light: 0x00796B, dark: 0x3DFFD0)
    static let onPlayFill = Color(light: 0xFFFFFF, dark: 0x05201B)
    /// Daybook itself, or work in progress (progress bars). Never text, buttons, or small glyphs.
    static let brandGradient = LinearGradient(colors: [neonMint, neonCyan, neonViolet], startPoint: .leading, endPoint: .trailing)
    static let quietFill = Color(uiColor: .quaternarySystemFill)

    /// Speaker names, owner chips, and the dots in Info: assigned by first appearance. Vivid on
    /// dark, deep enough on light for small semibold names.
    static let speakerInks: [Color] = [
        Color(light: 0x0369A1, dark: 0x7DD3FC), Color(light: 0xA21CAF, dark: 0xF0ABFC), Color(light: 0x15803D, dark: 0x86EFAC),
        Color(light: 0xC2410C, dark: 0xFDBA74), Color(light: 0x0E7490, dark: 0x67E8F9), Color(light: 0xBE123C, dark: 0xFDA4AF),
    ]
    static func speakerInk(_ index: Int?) -> Color {
        guard let index else { return Ink.secondary }
        return speakerInks[abs(index) % speakerInks.count]
    }

    /// Text on paper. Contrast is against `paper`; only `faint` is below 4.5:1, and it never carries information.
    enum Ink {
        static let title = Color(uiColor: UIInk.title)
        static let body = Color(uiColor: UIInk.body)
        static let secondary = Color(uiColor: UIInk.secondary)
        static let meta = Color(uiColor: UIInk.meta)
        static let faint = Color(uiColor: UIInk.faint)
        static let link = Color(uiColor: UIInk.link)
        static let warning = Color(light: 0xB45309, dark: 0xFFB054, lightContrast: 0x8A3F00, darkContrast: 0xFFC37A)
        /// Destructive text buttons and unrecoverable errors. Not recording.
        static let error = Color(light: 0xC4271D, dark: 0xFF6961, lightContrast: 0x9E1B12, darkContrast: 0xFF8A84)
        /// Recording, right now: the dot, the clock, Stop. Nothing else is red.
        static let record = Color(light: 0xD92D20, dark: 0xFF453A)
        /// Stop's fill; white labels keep 4.5:1 on it.
        static let recordFill = Color(light: 0xD92D20, dark: 0xE5243B)
    }

    /// A filled button's fill and label ink, as light, dark, light with Increase Contrast, and dark
    /// with Increase Contrast. Every label keeps 4.5:1 on its fill (tests check it).
    struct FilledInk {
        let fill: [UInt32]
        let label: [UInt32]
        var fillColor: Color { Color(light: fill[0], dark: fill[1], lightContrast: fill[2], darkContrast: fill[3]) }
        var labelColor: Color { Color(light: label[0], dark: label[1], lightContrast: label[2], darkContrast: label[3]) }
    }

    /// The Live Activity's buttons. Bookmark is amber, so its label is dark where the amber is light.
    enum ActivityButton {
        static let bookmark = FilledInk(fill: [0xA86400, 0xFFD23F, 0x8A5200, 0xFFDF70], label: [0xFFFFFF, 0x1F1600, 0xFFFFFF, 0x1F1600])
        /// Resume isn't recording yet, so it isn't red: ink on paper, inverted.
        static let resume = FilledInk(fill: [0x1A1917, 0xF5F4F0, 0x000000, 0xFFFFFF], label: [0xFFFFFF, 0x1A1917, 0xFFFFFF, 0x000000])
        static let stop = FilledInk(fill: [0xD92D20, 0xE5243B, 0xB4221A, 0xC81E30], label: [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF])
        static let all = [bookmark, resume, stop]
    }

    /// The Ink scale for UIKit text views (the notes editor), so both draw the same ink.
    enum UIInk {
        static let title = UIColor.daybook(light: 0x1A1917, dark: 0xF5F4F0, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        static let body = UIColor.daybook(light: 0x2B2A26, dark: 0xDFDDD7, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        static let secondary = UIColor.daybook(light: 0x66625A, dark: 0xA29F98, lightContrast: 0x45423C, darkContrast: 0xC9C6BF)
        static let meta = UIColor.daybook(light: 0x78736A, dark: 0x8A877F, lightContrast: 0x5E5A52, darkContrast: 0xA9A6A0)
        static let faint = UIColor.daybook(light: 0xB4AFA5, dark: 0x5A5853, lightContrast: 0x86817A, darkContrast: 0x86827C)
        static let link = UIColor.daybook(light: 0x00796B, dark: 0x34D9C3, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
        static let bookmark = UIColor.daybook(light: 0xA86400, dark: 0xFFD23F, lightContrast: 0x8A5200, darkContrast: 0xFFDF70)
        static let accent = UIColor.daybook(light: 0x00806F, dark: 0x00A3A0, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
    }

    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
    }

    /// The page's geometry on iPhone. The Mac hangs a 56 pt time margin left of a 640 pt measure;
    /// a phone page is narrower, so the page text runs edge to edge (20 pt gutters) and only the
    /// timed blocks (your notes, bookmarks) keep a lane of times inside the column.
    enum Page {
        /// Side gutter of a page.
        static let gutter: CGFloat = 20
        /// Room kept clear on each side of the iPhone Duo's crease.
        static let creaseClearance: CGFloat = 24
        /// The widest a column of text gets, as on the Mac.
        static let measure: CGFloat = 640
        /// The lane of times beside timed notes and bookmarks, at the default text size.
        static let lane: CGFloat = 50
    }

    /// Type: New York for titles only, SF for everything else, monospaced digits for every time.
    /// Everything here follows Dynamic Type.
    enum Typeface {
        /// New York, for the recorder's and library's titles at a fixed size.
        static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .serif) }
        /// Every time uses monospaced digits.
        static func clock(_ size: CGFloat) -> Font { .system(size: size, weight: .medium).monospacedDigit() }
        static let marginTime = Font.system(size: 11, weight: .regular).monospacedDigit()

        /// The page title (Mac 28 pt).
        static let docTitle = Font.system(.title, design: .serif, weight: .semibold)
        /// A row or sheet title in New York.
        static let rowTitle = Font.system(.headline, design: .serif, weight: .semibold)
        static let byline = Font.subheadline.monospacedDigit()
        /// The summary's first paragraph (Mac 16 over a 14 pt body).
        static let lede = Font.title3
        static let heading = Font.headline
        static let body = Font.body
        static let speaker = Font.subheadline.weight(.semibold)
        static let time = Font.footnote.monospacedDigit()
        static let status = Font.subheadline
        static let statusLead = Font.subheadline.weight(.medium)
        static let colophon = Font.footnote
        static let bodyLineSpacing: CGFloat = 4
    }

    /// Three curves; motion answers only something the person did or a change of state.
    enum Motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let state = Animation.snappy(duration: 0.25)
        static let page = Animation.easeInOut(duration: 0.35)
    }
}

extension Color {
    /// A colour that follows the light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// A colour that follows the appearance and Increase Contrast.
    init(light: UInt32, dark: UInt32, lightContrast: UInt32, darkContrast: UInt32) {
        self.init(uiColor: UIColor.daybook(light: light, dark: dark, lightContrast: lightContrast, darkContrast: darkContrast))
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func daybook(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) -> UIColor {
        UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            if traits.accessibilityContrast == .high {
                return UIColor(rgb: isDark ? darkContrast ?? dark : lightContrast ?? light)
            }
            return UIColor(rgb: isDark ? dark : light)
        }
    }
}

/// Times as the interface shows them, as in Voice Memos and on the Mac: "0:14", "12:31", "1:02:03".
enum TimeLabel {
    static func short(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 ? "−" : ""
        return sign + (value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60))
    }
}

// MARK: - Components shared by every surface

/// The text link in content: `Ink.link`, no underline. System blue never appears on paper.
struct DaybookLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PhoneStyle.Ink.link)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DaybookLinkStyle {
    static var daybookLink: DaybookLinkStyle { .init() }
}

/// A soft halo for neon in Dark Mode only. Light Mode, Increase Contrast, and Reduce Transparency get
/// none, because there it reads as blur rather than light.
struct NeonGlow: ViewModifier {
    let color: Color
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if scheme == .dark && contrast == .standard && !reduceTransparency {
            content.shadow(color: color.opacity(0.55), radius: radius)
        } else {
            content
        }
    }
}

extension View {
    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View { modifier(NeonGlow(color: color, radius: radius)) }

    /// An animation that becomes a short fade under Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.15) : animation, value: value)
    }
}

/// Progress in the brand gradient, with a cyan glow in Dark Mode: work in progress, downloads.
struct GradientProgressStyle: ProgressViewStyle {
    var width: CGFloat? = 160
    var height: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View {
        GradientProgressBar(fraction: configuration.fractionCompleted ?? 0, width: width, height: height)
    }
}

private struct GradientProgressBar: View {
    let fraction: Double
    let width: CGFloat?
    let height: CGFloat
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(PhoneStyle.brandGradient)
                        .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                        .neonGlow(PhoneStyle.neonCyan, radius: 3)
                        .animation(.easeOut(duration: 0.3), value: fraction)
                }
            }
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

extension ProgressViewStyle where Self == GradientProgressStyle {
    static var brand: GradientProgressStyle { GradientProgressStyle() }
    static func brand(width: CGFloat?, height: CGFloat = 4) -> GradientProgressStyle { GradientProgressStyle(width: width, height: height) }
}
