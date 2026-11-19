import CoreGraphics

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
    public func frames(in size: CGSize, crease: CGFloat?, page: CGSize) -> [CGRect] {
        let width = page.width * scale, height = page.height * scale
        let top = max(0, (size.height - height) / 2)
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
    public static func resolve(available: CGFloat, textScale: CGFloat = 1) -> NotebookPillFit {
        let scale = max(1, textScale)
        func fits(_ content: CGFloat) -> Bool { (content * scale + padding) * minimumScale <= available }
        if fits(status + meter + paging + gap) { return .oneRow(meter: true) }
        if fits(status + paging + gap) { return .oneRow(meter: false) }
        return .twoRows
    }
}
