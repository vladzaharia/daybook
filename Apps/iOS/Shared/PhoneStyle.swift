import DaybookDesign
import SwiftUI
import UIKit

/// The iPhone's names for the shared design (docs/interface.md, "Design tokens"), in the app and the
/// widgets alike. Every value is DaybookDesign's (`DaybookPalette`, `DaybookSpacing`, `DaybookMotion`,
/// `DaybookFont` under touch); nothing here keeps a copy, so the iPhone and the Mac draw the same ink.
///
/// Colour has one job each: red means recording right now, amber means something you marked,
/// teal means selected or actionable, neon mint means playing now, and the brand gradient means
/// Daybook itself or work in progress. Nothing else is red or amber.
enum PhoneStyle {
    /// Electric Teal: selection, focus, checkboxes, the play pill's fill, page bullets. Never text
    /// (use `Ink.link`).
    static let accent = DaybookPalette.accent
    /// Prominent buttons, so white labels keep 4.5:1.
    static let prominentFill = DaybookPalette.prominentFill
    /// The reading surface. Chrome stays on system materials.
    static let paper = DaybookPalette.paper
    /// Bookmarks only.
    static let bookmark = DaybookPalette.bookmark
    /// Playing now: the playhead rule and wash, the scrubber, the play button. Never text in light mode.
    static let neonMint = DaybookPalette.neonMint
    /// The glow under progress and the mark; never a fill on its own.
    static let neonCyan = DaybookPalette.neonCyan
    /// Inside the brand gradient only.
    static let neonViolet = DaybookPalette.neonViolet
    /// Removed words in Version History.
    static let neonMagenta = DaybookPalette.neonMagenta
    /// The player's play button: deep teal with white in light mode, neon mint with ink in dark.
    static let playFill = DaybookPalette.playFill
    static let onPlayFill = DaybookPalette.onPlayFill
    /// Daybook itself, or work in progress (progress bars), left to right. Never text, buttons, or small glyphs.
    static let brandGradient = DaybookPalette.brandGradient(.progress)
    static let quietFill = DaybookPalette.quietFill

    /// Speaker names, owner chips, and the dots in Info: assigned by first appearance.
    static let speakerInks = DaybookPalette.speakerInks
    static func speakerInk(_ index: Int?) -> Color { DaybookPalette.speakerInk(index) }

    /// Text on paper. Contrast is against `paper`; only `faint` is below 4.5:1, and it never carries information.
    typealias Ink = DaybookPalette.Ink

    /// A filled button's fill and label ink, as light, dark, light with Increase Contrast, and dark
    /// with Increase Contrast (`DaybookPalette.ActivityInk`). Every label keeps 4.5:1 on its fill.
    struct FilledInk {
        let ink: DaybookPalette.ActivityInk
        var fill: [UInt32] { ink.fill.variants }
        var label: [UInt32] { ink.label.variants }
        var fillColor: Color { ink.fill.color }
        var labelColor: Color { ink.label.color }
    }

    /// The Live Activity's buttons. Bookmark is amber, so its label is dark where the amber is light.
    enum ActivityButton {
        static let bookmark = FilledInk(ink: .bookmark)
        /// Resume isn't recording yet, so it isn't red: ink on paper, inverted.
        static let resume = FilledInk(ink: .resume)
        static let stop = FilledInk(ink: .stop)
        static let all = [bookmark, resume, stop]
    }

    typealias Space = DaybookSpacing

    /// Type: New York for titles only, SF for everything else, monospaced digits for every time.
    /// Everything here follows Dynamic Type (`DaybookFont` under touch).
    enum Typeface {
        /// New York, for the recorder's and library's titles, at a text style so it follows Dynamic
        /// Type: `.title` is 28 pt at the default size, `.title2` 22 pt, `.title3` 20 pt.
        static func title(_ style: Font.TextStyle = .title) -> Font { .system(style, design: .serif, weight: .semibold) }
        /// Every time uses monospaced digits.
        static func clock(_ size: CGFloat) -> Font { DaybookType.clock(size) }
        /// Times in a lane beside notes: 11 pt at the default size, following Dynamic Type.
        static let marginTime = DaybookFont.marginTime.font(.touch)

        /// The page title (Mac 28 pt).
        static let docTitle = DaybookFont.docTitle.font(.touch)
        /// A sheet's title in New York (`DaybookFont.sheetTitle`).
        static let sheetTitle = DaybookFont.sheetTitle.font(.touch)
        /// The sheet title's earlier name; list rows' titles are SF (`DaybookFont.rowTitle`).
        static let rowTitle = sheetTitle
        static let byline = DaybookFont.byline.font(.touch)
        /// The summary's first paragraph (Mac 16 over a 14 pt body).
        static let lede = DaybookFont.lede.font(.touch)
        static let heading = DaybookFont.heading.font(.touch)
        static let body = DaybookFont.body.font(.touch)
        static let speaker = DaybookFont.speaker.font(.touch)
        static let time = DaybookFont.time.font(.touch)
        static let status = DaybookFont.status.font(.touch)
        static let statusLead = DaybookFont.statusLead.font(.touch)
        static let colophon = DaybookFont.colophon.font(.touch)
        static let bodyLineSpacing = DaybookFont.bodyLineSpacing(.touch)
    }

    /// Daybook's curves (`DaybookMotion`); motion answers only something the person did or a change of state.
    typealias Motion = DaybookMotion
}

/// Shared components the iPhone's own views name.
typealias FlowLayout = DaybookDesign.FlowLayout
typealias FindHighlight = DaybookDesign.FindHighlight

extension View {
    /// A soft halo for neon in Dark Mode only (`daybookGlow`, whose curve this is).
    func neonGlow(_ color: Color, radius: CGFloat = 6) -> some View { daybookGlow(color, radius: radius) }

    /// An animation that becomes a short fade under Reduce Motion (`daybookMotion`).
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View { daybookMotion(animation, value: value) }
}
