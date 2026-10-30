import AppKit
import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI

// MARK: - Color

enum DaybookStyle {
    /// Electric Teal: the tint for selection, focus, links, checkboxes, and the playhead. Vivid, yet text
    /// on it or in it stays legible (light 4.7:1 as text; dark 5.5:1 as text, 3:1 under white marks).
    static let accent = Color(light: 0x00806F, dark: 0x00A3A0, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
    /// Filled buttons with white labels (4.5:1 or better in both appearances).
    static let prominentFill = Color(light: 0x00796B, dark: 0x007F73, lightContrast: 0x005F52, darkContrast: 0x005F52)
    /// The reading surface behind the page, the transcript, and floating notes: barely warmer than white.
    /// In dark mode one step below the list column (`#1E1E1E`), so the page recedes and neon reads brighter.
    static let paper = Color(light: 0xFDFCFA, dark: 0x18181B, lightContrast: 0xFFFFFF, darkContrast: 0x000000)
    /// Bookmarks, and nothing else. Neon amber in dark mode.
    static let bookmark = Color(light: 0xA86400, dark: 0xFFD23F, lightContrast: 0x8A5200, darkContrast: 0xFFDF70)
    /// Status lines that need the person, notices, quote blocks, and the find bar.
    static let quietFill = Color(nsColor: .quaternarySystemFill)
    /// The player's play button: deep teal with white in light mode, neon mint with near-black in dark.
    static let playFill = Color(light: 0x00796B, dark: 0x3DFFD0)
    static let onPlayFill = Color(light: 0xFFFFFF, dark: 0x05201B)

    // MARK: Neon, for decoration only: glows, gradients, and glyphs. Never a text background.

    static let neonMint = Color(light: 0x00B894, dark: 0x3DFFD0)
    static let neonCyan = Color(light: 0x0096C7, dark: 0x33E1FF)
    /// A glyph for audio that's live (playing, listening): neon mint in Dark Mode, where neon reads as
    /// light; link ink in Light Mode, where mint is too faint (2.4:1) to read as a glyph.
    static func liveGlyph(_ scheme: ColorScheme) -> Color { scheme == .dark ? neonMint : Ink.link }
    static let neonMagenta = Color(light: 0xD6249F, dark: 0xFF4FD8)
    static let neonViolet = Color(light: 0x7C3AED, dark: 0xB388FF)
    /// Daybook's signature: mint into cyan into violet. The app glyph, empty states, and Welcome.
    static let brandGradient = LinearGradient(colors: [neonMint, neonCyan, neonViolet], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Text on paper. Chrome keeps the system label colours.
    enum Ink {
        static let titleNS     = NSColor.daybook(light: 0x1A1917, dark: 0xF5F4F0, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        static let bodyNS      = NSColor.daybook(light: 0x2B2A26, dark: 0xDFDDD7, lightContrast: 0x000000, darkContrast: 0xFFFFFF)
        static let secondaryNS = NSColor.daybook(light: 0x66625A, dark: 0xA29F98, lightContrast: 0x45423C, darkContrast: 0xC9C6BF)
        static let metaNS      = NSColor.daybook(light: 0x78736A, dark: 0x8A877F, lightContrast: 0x5E5A52, darkContrast: 0xA9A6A0)
        static let faintNS     = NSColor.daybook(light: 0xB4AFA5, dark: 0x5A5853, lightContrast: 0x86817A, darkContrast: 0x86827C)

        static let title = Color(nsColor: titleNS), body = Color(nsColor: bodyNS), secondary = Color(nsColor: secondaryNS)
        static let meta = Color(nsColor: metaNS), faint = Color(nsColor: faintNS)
        static let link    = Color(light: 0x00796B, dark: 0x34D9C3, lightContrast: 0x005F52, darkContrast: 0x5FE3D4)
        static let warning = Color(light: 0xB45309, dark: 0xFFB054, lightContrast: 0x8A3F00, darkContrast: 0xFFC37A)
        static let error   = Color(light: 0xC4271D, dark: 0xFF6961, lightContrast: 0x9E1B12, darkContrast: 0xFF8A84)
        static let record     = Color(light: 0xD92D20, dark: 0xFF453A)
        static let recordFill = Color(light: 0xD92D20, dark: 0xE5243B)
    }

    /// Speaker names in the transcript and the dots in the inspector, assigned by first appearance.
    /// Vivid on dark; deep enough on light for 12 pt names.
    static let speakerInks: [Color] = [
        Color(light: 0x0369A1, dark: 0x7DD3FC), Color(light: 0xA21CAF, dark: 0xF0ABFC), Color(light: 0x15803D, dark: 0x86EFAC),
        Color(light: 0xC2410C, dark: 0xFDBA74), Color(light: 0x0E7490, dark: 0x67E8F9), Color(light: 0xBE123C, dark: 0xFDA4AF)
    ]
    static func speakerInk(_ index: Int?) -> Color {
        guard let index else { return Ink.secondary }
        return speakerInks[abs(index) % speakerInks.count]
    }

    // MARK: Page geometry

    /// The text measure: about 72 characters at the body size.
    static let measure: CGFloat = 640
    /// Times hang in this margin to the left of the measure.
    static let margin: CGFloat = 56
    /// Below this detail width, times fold inline and the measure fills the column.
    static let narrowWidth: CGFloat = 600
}

extension NSColor {
    /// One dynamic colour for both frameworks: light, dark, and Increase Contrast variants.
    static func daybook(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let hex: UInt32
            switch match {
            case .darkAqua: hex = dark
            case .accessibilityHighContrastDarkAqua: hex = darkContrast ?? dark
            case .accessibilityHighContrastAqua: hex = lightContrast ?? light
            default: hex = light
            }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

/// Text on paper reads `Ink.body`, `Ink.meta`, and so on.
typealias Ink = DaybookStyle.Ink

/// The spacing scale: 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64.
enum Space {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
}

extension Color {
    init(light: UInt32, dark: UInt32, lightContrast: UInt32? = nil, darkContrast: UInt32? = nil) {
        self.init(nsColor: .daybook(light: light, dark: dark, lightContrast: lightContrast, darkContrast: darkContrast))
    }
}

// MARK: - Type

/// The reading surface (page, transcript, floating notes) scales with View › Make Text Bigger.
/// Chrome text never scales.
struct ReadingScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var readingScale: CGFloat {
        get { self[ReadingScaleKey.self] }
        set { self[ReadingScaleKey.self] = newValue }
    }
}

enum ReadingScale {
    static let steps: [CGFloat] = [12, 13, 14, 16, 18, 20, 22].map { $0 / 14 }
    static func bigger(_ value: Double) -> Double { Double(steps.first { $0 > CGFloat(value) + 0.001 } ?? steps.last!) }
    static func smaller(_ value: Double) -> Double { Double(steps.last { $0 < CGFloat(value) - 0.001 } ?? steps.first!) }
}

enum TypeStyle {
    static func docTitle(_ scale: CGFloat = 1) -> Font { .system(size: 28 * scale, weight: .semibold, design: .serif) }
    static let docTitleSmall = Font.system(size: 22, weight: .semibold, design: .serif)
    static func byline(_ scale: CGFloat = 1) -> Font { .system(size: 13 * scale).monospacedDigit() }
    static func lede(_ scale: CGFloat = 1) -> Font { .system(size: 16 * scale) }
    static func heading(_ scale: CGFloat = 1) -> Font { .system(size: 15 * scale, weight: .semibold) }
    static func body(_ scale: CGFloat = 1) -> Font { .system(size: 14 * scale) }
    static func speaker(_ scale: CGFloat = 1) -> Font { .system(size: 12 * scale, weight: .semibold) }
    static func margin(_ scale: CGFloat = 1) -> Font { .system(size: 11 * scale).monospacedDigit() }
    static let status = Font.system(size: 12)
    static let statusLead = Font.system(size: 12, weight: .medium)
    static let colophon = Font.system(size: 11)
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    static let rowDetail = Font.system(size: 12)
    static let panelTitle = Font.system(size: 17, weight: .semibold, design: .serif)
    static let panelTime = Font.system(size: 13, weight: .medium).monospacedDigit()
    /// Line spacing that brings 14 pt body text to a 22 pt line.
    static func bodyLineSpacing(_ scale: CGFloat = 1) -> CGFloat { 5 * scale }
}

// MARK: - Liquid Glass, only on the floating layer

extension View {
    /// Liquid Glass on macOS 26 and later; a material capsule with a hairline and shadow on macOS 15.
    @ViewBuilder
    func glassSurface(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    /// Glass buttons belong only inside floating strips (the player and the floating notes controls).
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Pins a bar to the top edge. On macOS 26 it joins the toolbar's scroll edge effect.
    @ViewBuilder
    func topBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: content)
        }
    }

    /// Pins a bar to the bottom edge, letting content scroll beneath it on macOS 26.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

    /// The quiet filled box used by status lines that need the person, notices, and quotes.
    func quietBox(cornerRadius: CGFloat = 8) -> some View {
        background(DaybookStyle.quietFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A text link in content: Ink.link, underline-free, brightens on hover. Replaces `.buttonStyle(.link)` (system blue).
struct DaybookLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { DaybookLinkLabel(configuration: configuration) }
}

/// Hover state lives in a view: a `ButtonStyle` isn't one, so `@State` on it never updates.
private struct DaybookLinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(Ink.link)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.6 : 1)
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .contentShape(Rectangle())
            .pointerStyle(isEnabled ? .link : nil)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}
extension ButtonStyle where Self == DaybookLinkStyle { static var daybookLink: DaybookLinkStyle { .init() } }

/// A soft neon glow in dark mode; nothing in light mode, Increase Contrast, or Reduce Transparency,
/// where it would read as blur rather than light.
struct NeonGlow: ViewModifier {
    let color: Color
    var radius: CGFloat = 6
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if scheme == .dark && contrast == .standard && !reduceTransparency {
            if radius <= 4 {
                content.shadow(color: color.opacity(0.6), radius: radius)
            } else {
                content.shadow(color: color.opacity(0.75), radius: radius).shadow(color: color.opacity(0.35), radius: radius * 2.5)
            }
        } else {
            content
        }
    }
}

extension View {
    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View { modifier(NeonGlow(color: color, radius: radius)) }
}

/// Daybook's few animation curves. Use `motion(_:value:)` so Reduce Motion is honoured everywhere.
enum Motion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let state = Animation.snappy(duration: 0.25)
    static let page = Animation.easeInOut(duration: 0.35)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.15) : animation, value: value)
    }
}

extension View {
    /// Animates changes to `value`, falling back to a short fade under Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

/// A 4 pt capsule filled with the brand gradient; the one moving neon while work is happening.
struct GradientProgressStyle: ProgressViewStyle {
    var width: CGFloat? = 160
    var height: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View {
        GradientProgressBar(fraction: configuration.fractionCompleted ?? 0, width: width, height: height)
    }
}

/// It steps without animating: progress arrives up to ten times a second, and easing every step kept the
/// window drawing frames for as long as a job ran.
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
                        .fill(DaybookStyle.brandGradient)
                        .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                        .neonGlow(DaybookStyle.neonCyan, radius: 3)
                }
            }
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

extension ProgressViewStyle where Self == GradientProgressStyle {
    static var brand: GradientProgressStyle { GradientProgressStyle() }
    static func brand(width: CGFloat?, height: CGFloat = 4) -> GradientProgressStyle { GradientProgressStyle(width: width, height: height) }
}

/// The Daybook mark: five waveform bars in the brand gradient on a deep tile, with an amber bookmark dot.
/// The same drawing as the app icon (`scripts/make-icon.swift`).
struct DaybookMark: View {
    var size: CGFloat = 96
    @Environment(\.colorScheme) private var scheme
    private static let bars: [CGFloat] = [100, 178, 248, 158, 82]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0x14 / 255, green: 0x32 / 255, blue: 0x2E / 255),
                                          Color(red: 0x0A / 255, green: 0x17 / 255, blue: 0x16 / 255)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                HStack(alignment: .center, spacing: size * 0.055) {
                    ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, height in
                        Capsule().frame(width: size * 0.07, height: size * height / 512 * 0.92)
                    }
                }
                .foregroundStyle(DaybookStyle.brandGradient)
                .neonGlow(DaybookStyle.neonCyan, radius: size / 12)
                // The tile is always dark, so its bars are always the dark-mode neon, glow included.
                .environment(\.colorScheme, .dark)
            }
            .overlay(alignment: .topTrailing) {
                Circle().fill(Color(red: 1, green: 0xD2 / 255, blue: 0x3F / 255))
                    .frame(width: size * 0.07, height: size * 0.07)
                    .padding(size * 0.17)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.18), radius: size / 12, y: size / 24)
            .accessibilityHidden(true)
    }
}

/// Sidebar rows: every symbol centred in one column sized like the system sidebar's icons,
/// then a gap a little wider than SwiftUI's default. Follows System Settings › Sidebar icon size.
struct SidebarLabelStyle: LabelStyle {
    @Environment(\.sidebarRowSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let (column, symbol, gap): (CGFloat, CGFloat, CGFloat) = switch size {
        case .small: (16, 12, 6)
        case .large: (24, 18, 8)
        default: (20, 15, 7)
        }
        HStack(spacing: gap) {
            configuration.icon
                .font(.system(size: symbol, weight: .regular))
                .frame(width: column, alignment: .center)
            configuration.title
        }
    }
}

extension LabelStyle where Self == SidebarLabelStyle {
    static var sidebar: SidebarLabelStyle { SidebarLabelStyle() }
}

/// Lets neighbouring glass shapes blend on macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
    }
}

// MARK: - Shared vocabulary

extension SummaryTemplate {
    /// Built-ins have their own symbol; the person's own templates are documents.
    var systemImage: String {
        switch id {
        case "planning": return "calendar"
        case "retrospective": return "arrow.uturn.backward.circle"
        case "customer-discovery": return "binoculars"
        case "design-review": return "paintbrush.pointed"
        case "decision-memo": return "checkmark.seal"
        default: return isBuiltIn ? kind.systemImage : "doc.text"
        }
    }
}

extension MeetingKind {
    var systemImage: String {
        switch self {
        case .auto: return "text.bubble"
        case .general: return "person.3"
        case .oneOnOne: return "person.2"
        case .scrum: return "sunrise"
        case .therapy: return "heart.text.square"
        case .personal: return "house"
        case .interview: return "person.crop.rectangle"
        case .lecture: return "graduationcap"
        }
    }
    /// Plain words for the Automatic template's guess: "looks like a 1:1".
    var looksLike: String {
        switch self {
        case .auto: return "Automatic"
        case .general: return "a meeting"
        case .oneOnOne: return "a 1:1"
        case .scrum: return "a standup"
        case .therapy: return "a therapy session"
        case .personal: return "a personal conversation"
        case .interview: return "an interview"
        case .lecture: return "a lecture"
        }
    }
}

extension AudioSource {
    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "desktopcomputer"
        case .soundcore: return "waveform.badge.microphone"
        case .imported: return "doc"
        }
    }
}

// MARK: - Components

/// Wraps subviews onto new lines, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Renders the Markdown subset local models produce: paragraphs, bullet and numbered lists,
/// headings, and inline emphasis. `Text` alone only understands the inline part.
struct MarkdownText: View {
    let source: String
    @Environment(\.readingScale) private var scale
    @Environment(\.findQuery) private var query
    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text, highlighting: query)).font(TypeStyle.body(scale)).lineSpacing(TypeStyle.bodyLineSpacing(scale))
                        .padding(.bottom, 4 * scale)
                case .heading(let text):
                    Text(Self.inline(text, highlighting: query)).font(TypeStyle.heading(scale))
                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Group {
                            if marker == "•" {
                                Circle().fill(DaybookStyle.accent.opacity(0.75)).frame(width: 5 * scale, height: 5 * scale)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * scale }
                            } else {
                                Text(marker).font(TypeStyle.body(scale).monospacedDigit()).foregroundStyle(Ink.secondary)
                            }
                        }
                        .frame(width: 16 * scale, alignment: .leading)
                        Text(Self.inline(text, highlighting: query)).font(TypeStyle.body(scale)).lineSpacing(TypeStyle.bodyLineSpacing(scale))
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    enum Block { case paragraph(String), heading(String), item(String, String) }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item("•", String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item(line[..<range.upperBound].trimmingCharacters(in: .whitespaces), String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(line[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flush()
        return blocks
    }

    /// Inline Markdown from a model, with its links dropped (`ModelText.inlineMarkdown`).
    static func inline(_ text: String) -> AttributedString { ModelText.inlineMarkdown(text) }

    /// Inline Markdown with the library search's matches marked, as transcript passages mark them.
    static func inline(_ text: String, highlighting query: String) -> AttributedString {
        FindHighlight.mark(inline(text), query: query)
    }
}

/// The library search's text, so the page can mark its matches.
struct FindQueryKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var findQuery: String {
        get { self[FindQueryKey.self] }
        set { self[FindQueryKey.self] = newValue }
    }
}

/// Marks every match of the search with the system find highlight, on the summary and in the transcript.
enum FindHighlight {
    static func mark(_ text: AttributedString, query: String) -> AttributedString {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return text }
        var text = text
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text[cursor...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = Color(nsColor: .findHighlightColor)
            text[range].foregroundColor = .black
            cursor = range.upperBound
        }
        return text
    }
}

/// Tags as removable chips followed by a field for adding another.
struct TagEditor: View {
    let tags: [String]
    let save: ([String]) -> Void
    var showTag: ((String) -> Void)?
    var alignment: HorizontalAlignment = .leading
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        FlowLayout(spacing: 4, alignment: alignment) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag, remove: { save(tags.filter { $0 != tag }) }, show: showTag.map { show in { show(tag) } })
            }
            TextField("Tag", text: $draft, prompt: Text("Add Tag…"))
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 80)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
        }
    }
    private func commit() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !tag.isEmpty else { return }
        save(tags + [tag])
    }
}

private struct TagChip: View {
    let tag: String
    let remove: () -> Void
    let show: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 2) {
            Text(tag)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Remove tag \(tag)")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Ink.link)
        .padding(.leading, 7).padding(.trailing, 5).padding(.vertical, 2)
        .background(DaybookStyle.accent.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { show?() }
        .contextMenu {
            if let show { Button("Show Conversations Tagged “\(tag)”", action: show) }
            Button("Remove Tag", action: remove)
        }
    }
}
