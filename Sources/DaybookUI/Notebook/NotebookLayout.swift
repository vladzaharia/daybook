import CoreGraphics
import DaybookCore
import SwiftUI

/// How the notebook lays its pages on a display: two facing pages split at the crease when two fit, one page otherwise. The
/// display is the notebook: nothing is reserved above, below, or beside the pages for controls (they float over the paper and
/// collapse), so each page takes the largest size that fits its half inside the safe area. Decided by geometry alone, never
/// by the device (docs/notebook.md).
public enum NotebookLayout: Equatable, Sendable {
    /// Two facing pages, both drawn at this scale.
    case spread(scale: CGFloat)
    case single(scale: CGFloat)

    /// Kept clear at the display's edges, and above and below the pages.
    public static let margin: CGFloat = 8
    /// Room kept clear on each side of the crease.
    public static let creaseClearance: CGFloat = 16
    /// A spread smaller than this scales to a single page instead.
    public static let minimumSpreadScale: CGFloat = 0.7
    /// Between two pages when there is no crease.
    public static let gutter: CGFloat = 24
    /// The smallest strip under a page that holds its number and the caption line: with less, the number goes in the pill and the
    /// caption floats.
    public static let stripHeight: CGFloat = 34

    public var scale: CGFloat {
        switch self {
        case .spread(let scale), .single(let scale): return scale
        }
    }

    public var isSpread: Bool {
        if case .spread = self { return true }
        return false
    }

    /// How many pages show at once.
    public var pageCount: Int { isSpread ? 2 : 1 }

    /// - Parameters:
    ///   - size: The safe area.
    ///   - crease: The crease's x in it, when the display has one.
    ///   - page: The page's logical size.
    public static func resolve(size: CGSize, crease: CGFloat?, page: CGSize) -> NotebookLayout {
        guard page.width > 0, page.height > 0 else { return .single(scale: 1) }
        let tall = (size.height - 2 * margin) / page.height
        if let crease {
            let left = crease - margin - creaseClearance
            let right = size.width - crease - creaseClearance - margin
            let scale = min(left / page.width, right / page.width, tall)
            if scale >= minimumSpreadScale { return .spread(scale: scale) }
        } else {
            let scale = min((size.width - 2 * margin - gutter) / 2 / page.width, tall)
            if scale >= minimumSpreadScale { return .spread(scale: scale) }
        }
        return .single(scale: max(0.1, min((size.width - 2 * margin) / page.width, tall)))
    }

    /// Where each page's frame falls in the safe area, left to right, centred vertically: a spread with a crease puts each page
    /// against it, clear by `creaseClearance`; without one the pair is centred with the gutter between; a single page is centred.
    ///
    /// With `bottomAligned` the pages sit on their caption strip instead, freeing the band above them for the controls.
    public func frames(in size: CGSize, crease: CGFloat?, page: CGSize, bottomAligned: Bool = false) -> [CGRect] {
        let width = page.width * scale, height = page.height * scale
        let top = bottomAligned ? max(0, size.height - Self.stripHeight - height) : max(0, (size.height - height) / 2)
        switch self {
        case .single:
            return [CGRect(x: (size.width - width) / 2, y: top, width: width, height: height)]
        case .spread:
            if let crease {
                return [CGRect(x: crease - Self.creaseClearance - width, y: top, width: width, height: height),
                        CGRect(x: crease + Self.creaseClearance, y: top, width: width, height: height)]
            }
            let start = (size.width - 2 * width - Self.gutter) / 2
            return [CGRect(x: start, y: top, width: width, height: height),
                    CGRect(x: start + width + Self.gutter, y: top, width: width, height: height)]
        }
    }

    // MARK: Where the controls go

    /// Where the pill and the tools sit.
    public enum Controls: Equatable, Sendable {
        /// Expanded, in the free band above the pages (its height), off the paper; the pages sit on their strips.
        case band(height: CGFloat)
        /// As chips in the band above the pages (its height); they expand over the top of the page on a tap, and collapse again
        /// when a pen comes near or writing starts. The paper under the chips' place is never covered while collapsed.
        case chips(height: CGFloat)
        /// No room above the pages even for chips: they float over the page's top margin, collapsed, and expand only on a tap.
        case overPage

        /// Whether the controls start as chips.
        public var startsAsChips: Bool { if case .band = self { return false } else { return true } }
        /// Whether the pages sit on their strips to leave the band.
        public var bottomAligned: Bool { self != .overPage }
    }

    /// Distance of a chip, or of the band's contents, from the edge of what it floats over.
    public static let controlInset: CGFloat = 4
    /// The tools' height, and a chip's.
    public static let chipHeight: CGFloat = 44
    /// What the pill draws one row at (a 44 pt row and its padding), and two rows at.
    public static let pillRowHeight: CGFloat = 52, pillTwoRowHeight: CGFloat = 96

    /// The height of a pill in a given fit.
    public static func pillHeight(_ fit: NotebookPillFit) -> CGFloat { fit == .twoRows ? pillTwoRowHeight : pillRowHeight }

    /// Where the controls go. With the pages on their strips, the free height above them is the band: if it holds the expanded
    /// pill (beside the tools over a spread, under them over a single page) with `controlInset` above and below, they sit in it
    /// expanded; if it holds only a row of chips, they are chips there; otherwise they float over the page's top margin.
    public func controls(in size: CGSize, page: CGSize, pill: NotebookPillFit) -> Controls {
        let height = page.height * scale
        guard size.height - height >= Self.stripHeight else { return .overPage }
        let band = size.height - Self.stripHeight - height
        let content = isSpread ? max(Self.pillHeight(pill), Self.chipHeight)
                               : Self.pillHeight(pill) + Self.controlInset + Self.chipHeight
        if band >= content + 2 * Self.controlInset { return .band(height: band) }
        return band >= Self.chipHeight + 2 * Self.controlInset ? .chips(height: band) : .overPage
    }

    /// Whether a page's frame leaves a strip under it for its number and the caption line.
    public func hasStrip(under frame: CGRect, in size: CGSize) -> Bool { size.height - frame.maxY >= Self.stripHeight }
}

/// Whether a pen is close enough to a control floating over the paper that the control should step aside.
public enum PenProximity {
    /// How near, in points, counts.
    public static let distance: CGFloat = 40
    /// How long after a stroke ends the control stays away.
    public static let returnDelay: Duration = .milliseconds(700)

    public static func isNear(_ point: CGPoint?, _ frame: CGRect, within distance: CGFloat = PenProximity.distance) -> Bool {
        guard let point else { return false }
        return frame.insetBy(dx: -distance, dy: -distance).contains(point)
    }
}

/// What the recorder pill shows in the room it has: one row with the meter, one row without it, or the page controls on a
/// second row (only where one row can't hold the rest, as on the cover at the larger text sizes).
public enum NotebookPillFit: Equatable, Sendable {
    case oneRow(meter: Bool)
    case twoRows

    /// Widths at the default text size, from the pill as drawn: the status (dot, clock, Bookmark, Stop), the meter, the page
    /// controls, and the gap between rows' contents. A row may be drawn a little smaller to fit (`minimumScale`) before the meter
    /// goes, and before the page controls move to a second row.
    static let status: CGFloat = 214, meter: CGFloat = 42, paging: CGFloat = 143, gap: CGFloat = 8, padding: CGFloat = 16
    public static let minimumScale: CGFloat = 0.88

    /// - Parameters:
    ///   - available: The width the pill may take.
    ///   - textScale: How much larger than default the text is drawn (1 at the default size).
    public static func textScale(_ size: DynamicTypeSize) -> CGFloat {
        switch min(size, .xxxLarge) {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        default: return 1.3
        }
    }

    public static func resolve(available: CGFloat, textScale: CGFloat = 1) -> NotebookPillFit {
        let scale = max(1, textScale)
        func fits(_ content: CGFloat) -> Bool { (content * scale + padding) * minimumScale <= available }
        if fits(status + meter + paging + gap) { return .oneRow(meter: true) }
        if fits(status + paging + gap) { return .oneRow(meter: false) }
        return .twoRows
    }
}
