import CoreGraphics

/// How the notebook lays its pages on a display: two facing pages split at the crease when two fit, one page otherwise.
/// Decided by geometry alone, never by the device (docs/notebook.md).
public enum NotebookLayout: Equatable, Sendable {
    /// Two facing pages, both drawn at this scale.
    case spread(scale: CGFloat)
    case single(scale: CGFloat)

    /// The band over each page: its tools, its label, and the recorder pill.
    public static let band: CGFloat = 108
    public static let margin: CGFloat = 12
    /// Room kept clear on each side of the crease.
    public static let creaseClearance: CGFloat = 16
    /// A spread smaller than this scales to a single page instead.
    public static let minimumSpreadScale: CGFloat = 0.7
    /// Under a single page: the tools take the foot there, since the band's room goes to the pill.
    public static let foot: CGFloat = 56
    /// Between two pages when there is no crease.
    public static let gutter: CGFloat = 24

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
        let tall = (size.height - band - margin) / page.height
        let tallSingle = (size.height - band - foot) / page.height
        if let crease {
            let left = crease - margin - creaseClearance
            let right = size.width - crease - creaseClearance - margin
            let scale = min(left / page.width, right / page.width, tall)
            if scale >= minimumSpreadScale { return .spread(scale: scale) }
        } else {
            let scale = min((size.width - 2 * margin - gutter) / 2 / page.width, tall)
            if scale >= minimumSpreadScale { return .spread(scale: scale) }
        }
        return .single(scale: max(0.1, min((size.width - 2 * margin) / page.width, tallSingle)))
    }

    /// Where each page's frame falls in the safe area, left to right, for pages of this size: a spread with a crease puts
    /// each page against it, clear by `creaseClearance`; without one the pair is centred with the gutter between; a single
    /// page is centred.
    public func frames(in size: CGSize, crease: CGFloat?, page: CGSize) -> [CGRect] {
        let width = page.width * scale, height = page.height * scale
        let reserve = isSpread ? Self.margin : Self.foot
        let top = Self.band + max(0, (size.height - Self.band - reserve - height) / 2)
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
}
