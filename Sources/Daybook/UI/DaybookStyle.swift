import AppKit
import DaybookDesign
import DaybookUI
import SwiftUI

// The Mac's names for the shared design (docs/interface.md, "Design tokens"). Every value is
// DaybookDesign's (`DaybookPalette`, `DaybookSpacing`, `DaybookMotion`, `DaybookFont`) or DaybookUI's
// (`ReadingGeometry`); nothing here keeps a copy, so a change there reaches both apps at once.

// MARK: - Color

enum DaybookStyle {
    /// Electric Teal: the tint for selection, focus, checkboxes, and the playhead. Never text (`Ink.link`).
    static let accent = DaybookPalette.accent
    /// Filled buttons with white labels (4.5:1 or better in both appearances).
    static let prominentFill = DaybookPalette.prominentFill
    /// The reading surface behind the page, the transcript, and floating notes: barely warmer than white.
    /// In dark mode one step below the list column (`#1E1E1E`), so the page recedes and neon reads brighter.
    static let paper = DaybookPalette.paper
    /// Bookmarks, and nothing else. Neon amber in dark mode.
    static let bookmark = DaybookPalette.bookmark
    /// Status lines that need the person, notices, quote blocks, and the find bar.
    static let quietFill = DaybookPalette.quietFill
    /// The player's play button: deep teal with white in light mode, neon mint with near-black in dark.
    static let playFill = DaybookPalette.playFill
    static let onPlayFill = DaybookPalette.onPlayFill

    // MARK: Neon, for decoration only: glows, gradients, and glyphs. Never a text background.

    static let neonMint = DaybookPalette.neonMint
    static let neonCyan = DaybookPalette.neonCyan
    static let neonMagenta = DaybookPalette.neonMagenta
    static let neonViolet = DaybookPalette.neonViolet
    /// A glyph for audio that's live (playing, listening): neon mint in Dark Mode, link ink in Light
    /// (`DaybookPalette.liveGlyph`, which follows the appearance itself).
    static func liveGlyph(_ scheme: ColorScheme) -> Color { DaybookPalette.liveGlyph }
    /// Daybook's signature, corner to corner: the Privacy lock and Welcome's bullets. Progress draws it
    /// left to right (`WorkProgress`).
    static let brandGradient = DaybookPalette.brandGradient(.mark)

    /// Text on paper. Chrome keeps the system label colours.
    typealias Ink = DaybookPalette.Ink

    /// Speaker names in the transcript and the dots in the inspector, assigned by first appearance.
    static let speakerInks = DaybookPalette.speakerInks
    static func speakerInk(_ index: Int?) -> Color { DaybookPalette.speakerInk(index) }

    // MARK: Page geometry

    /// The text measure: about 72 characters at the body size.
    static let measure = ReadingGeometry.measure
    /// Times hang in this margin to the left of the measure.
    static let margin = ReadingGeometry.margin
    /// Below this detail width, times fold inline and the measure fills the column.
    static let narrowWidth = ReadingGeometry.narrowBelow
}

extension DaybookPalette.Ink {
    /// The Ink scale for the notes `NSTextView`, the same values as the colours above.
    static let titleNS = DaybookPalette.Shade.title.nsColor
    static let bodyNS = DaybookPalette.Shade.body.nsColor
    static let secondaryNS = DaybookPalette.Shade.secondary.nsColor
    static let metaNS = DaybookPalette.Shade.meta.nsColor
    static let faintNS = DaybookPalette.Shade.faint.nsColor
}

/// Text on paper reads `Ink.body`, `Ink.meta`, and so on.
typealias Ink = DaybookStyle.Ink

/// The spacing scale: 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64.
typealias Space = DaybookSpacing

/// Shared components the Mac's own views name.
typealias FlowLayout = DaybookDesign.FlowLayout
typealias FindHighlight = DaybookDesign.FindHighlight
typealias DaybookMark = DaybookDesign.DaybookMark

// MARK: - Type

/// View › Make Text Bigger's steps for the reading surface (`readingScale`, DaybookDesign).
enum ReadingScale {
    static let steps: [CGFloat] = [12, 13, 14, 16, 18, 20, 22].map { $0 / 14 }
    static func bigger(_ value: Double) -> Double { Double(steps.first { $0 > CGFloat(value) + 0.001 } ?? steps.last!) }
    static func smaller(_ value: Double) -> Double { Double(steps.last { $0 < CGFloat(value) - 0.001 } ?? steps.first!) }
}

/// The Mac's type roles, from `DaybookFont` at the window's density. The reading roles take the reading scale.
enum TypeStyle {
    static func docTitle(_ scale: CGFloat = 1) -> Font { DaybookFont.docTitle.font(.window, scale: scale) }
    static let docTitleSmall = DaybookFont.sheetTitle.font(.window)
    static func byline(_ scale: CGFloat = 1) -> Font { DaybookFont.byline.font(.window, scale: scale) }
    static func lede(_ scale: CGFloat = 1) -> Font { DaybookFont.lede.font(.window, scale: scale) }
    static func heading(_ scale: CGFloat = 1) -> Font { DaybookFont.heading.font(.window, scale: scale) }
    static func body(_ scale: CGFloat = 1) -> Font { DaybookFont.body.font(.window, scale: scale) }
    static func speaker(_ scale: CGFloat = 1) -> Font { DaybookFont.speaker.font(.window, scale: scale) }
    static func margin(_ scale: CGFloat = 1) -> Font { DaybookFont.marginTime.font(.window, scale: scale) }
    static let status = DaybookFont.status.font(.window)
    static let statusLead = DaybookFont.statusLead.font(.window)
    static let colophon = DaybookFont.colophon.font(.window)
    static let rowTitle = DaybookFont.rowTitle.font(.window)
    static let rowDetail = DaybookFont.rowDetail.font(.window)
    static let panelTitle = DaybookFont.docTitle.font(.panel)
    static let panelTime = Font.system(size: 13, weight: .medium).monospacedDigit()
    /// Line spacing that brings 14 pt body text to a 22 pt line.
    static func bodyLineSpacing(_ scale: CGFloat = 1) -> CGFloat { DaybookFont.bodyLineSpacing(.window, scale: scale) }
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

// MARK: - Glow and motion

extension View {
    /// A soft neon glow in dark mode; nothing in light mode, Increase Contrast, or Reduce Transparency
    /// (`daybookGlow`, whose curve this is).
    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View { daybookGlow(color, radius: radius) }

    /// Animates changes to `value`, falling back to a short fade under Reduce Motion (`daybookMotion`).
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View { daybookMotion(animation, value: value) }
}

/// Daybook's curves (`DaybookMotion`). Use `motion(_:value:)` so Reduce Motion is honoured everywhere.
typealias Motion = DaybookMotion

// MARK: - Components

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
