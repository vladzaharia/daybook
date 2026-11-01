import SwiftUI

/// The spacing scale: 4 · 8 · 12 · 16 · 24 · 32 · 48 · 64.
public enum DaybookSpacing {
    public static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    public static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
}

/// Corner radii, every one continuous. A chip is a capsule; then each size of container has one radius,
/// so the same box has the same corners on both devices.
public enum DaybookRadius {
    /// A row's selection or hover wash, a small field.
    public static let row: CGFloat = 6
    /// A status or problem box, a figure tile, a quote.
    public static let box: CGFloat = 12
    /// A card of rows (the status sheet's), a device card.
    public static let card: CGFloat = 16
    /// A recorder control: Record, Bookmark, Stop, the pause panel.
    public static let control: CGFloat = 20
    /// A sheet's or a floating panel's own surface: the status panel, the player.
    public static let panel: CGFloat = 26

    /// A rounded rectangle at one of the radii above.
    public static func shape(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
    /// A chip's shape. Circular, because a continuous capsule leaves hairline ticks at its ends.
    public static var chip: Capsule { Capsule(style: .circular) }
}

/// The square tiles a symbol sits on: in a Settings row, in a status card, and at the top of a device's
/// page. Under touch each grows with Dynamic Type up to its limit; on the Mac it keeps its size.
public enum DaybookTileSize: Hashable, Sendable {
    case row
    case card
    case header

    /// The side at the default text size.
    public var base: CGFloat {
        switch self {
        case .row: return 30
        case .card: return 32
        case .header: return 56
        }
    }

    /// The largest it grows to with Dynamic Type.
    public var limit: CGFloat {
        switch self {
        case .row: return 42
        case .card: return 44
        case .header: return 56 * 1.35
        }
    }

    /// The text style it grows with.
    public var textStyle: Font.TextStyle {
        switch self {
        case .row: return .body
        case .card: return .subheadline
        case .header: return .title
        }
    }

    /// The side at a Dynamic Type scale (1 at the default size), capped at `limit`.
    public func side(scale: CGFloat) -> CGFloat { min(base * max(scale, 0), limit) }
}

/// Daybook's curves. Motion answers only something the person did or a change of state; nothing loops
/// except work in progress and the Listening dot. Go through `daybookMotion(_:value:)`,
/// `daybookTransition(_:)`, and `daybookBounce(value:)`, which honour Reduce Motion.
public enum DaybookMotion {
    /// Hovering a time, a header, a row: a tint or a fade.
    public static let hover = Animation.easeOut(duration: 0.12)
    /// Something appearing or going: a line, a box, a caption.
    public static let fade = Animation.easeOut(duration: 0.2)
    /// A change of state: a bookmark opening, a surface switching.
    public static let state = Animation.snappy(duration: 0.25)
    /// Digits and counts that roll: the clock, a count.
    public static let tick = Animation.snappy(duration: 0.3)
    /// Scrolling the page to a passage.
    public static let scroll = Animation.easeInOut(duration: 0.3)
    /// Turning between pages: Summary and Transcript, a page of the notebook.
    public static let page = Animation.easeInOut(duration: 0.35)
    /// Dimming: the old summary while the new one is written, the table's idle dim.
    public static let dim = Animation.easeInOut(duration: 0.6)
    /// Something small arriving: a bookmark landing in the log.
    public static let land = Animation.spring(response: 0.32, dampingFraction: 0.6)
    /// What every curve becomes under Reduce Motion.
    public static let reduced = Animation.easeOut(duration: 0.15)
    /// How long a done mark stays before it fades.
    public static let hold: Duration = .seconds(1.5)

    /// `animation`, or `reduced` in its place under Reduce Motion: for `withAnimation` where the
    /// view modifiers can't reach.
    public static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }

    /// A scroll to a passage: `scroll`, or none under Reduce Motion, where the page jumps.
    public static func scrollAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : scroll
    }
}

/// Times as the interface shows them, as in Voice Memos: "0:14", "12:31", "1:02:03". Whole seconds,
/// counted toward zero: a time before the start reads "−0:12", and less than a second before it
/// "0:00". The same rule as DaybookKit's `TimeLabel.short` (tests hold them equal), for what links only
/// this library: the widgets and the Live Activity.
public enum DaybookTime {
    public static func short(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 && value > 0 ? "−" : ""
        return sign + (value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60))
    }
}
