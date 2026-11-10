import DaybookDesign
import SwiftUI

// One page geometry for both apps (docs/interface.md, "Geometry"): a text measure of at most 560 pt in a window
// (640 under touch), centred. From 600 pt wide, times hang in a 56 pt margin left of the measure (the Mac's detail
// column, the open Duo shown as one page), and so do they on each page of a Mac window's spread, at every width it
// gives them; narrower, timed blocks keep a lane of times inside the column and the rest runs edge to edge (every
// iPhone, each page of the Duo, a narrow Mac window).

/// Whether a page is wide enough for its margin to hang.
public enum ReadingWidth: Hashable, Sendable {
    /// 600 pt and wider: the 56 pt margin hangs left of the measure.
    case regular
    /// Narrower: a lane of times inside the column.
    case narrow

    /// - Parameter spreadPage: A page of a window's spread (`spreadPage`), which keeps its margin at every width.
    public init(width: CGFloat, spreadPage: Bool = false) {
        self = spreadPage || width >= ReadingGeometry.narrowBelow ? .regular : .narrow
    }
}

extension EnvironmentValues {
    /// The page's width class (`ReadingWidth`), set by `ReadingPage`.
    @Entry public var readingWidth: ReadingWidth = .regular
    /// The side of this page that meets the iPhone Duo's crease, if any. Reading columns and controls
    /// keep their respective clearances from it (`ReadingGeometry`).
    @Entry public var creaseEdge: Edge? = nil
    /// Whether this page is one of a window's two side by side (`PageSpread` without a crease): its margin hangs at
    /// every width the spread gives it, from just under 560 pt, rather than from 600.
    @Entry public var spreadPage = false
}

/// The page's measurements, and where its column sits in a container.
public enum ReadingGeometry {
    /// The text measure in a window: about 80 characters of the 15 pt body.
    public static let measure: CGFloat = 560
    /// The measure under touch: about 80 characters of Dynamic Type's 17 pt body.
    public static let touchMeasure: CGFloat = 640

    /// The measure at a density.
    public static func measure(_ density: DaybookDensity) -> CGFloat {
        density == .touch ? touchMeasure : measure
    }
    /// Times hang in this margin to the left of the measure, ending `marginGap` before the text.
    public static let margin: CGFloat = 56
    public static let marginGap: CGFloat = 8
    /// Below this width, times move into a lane and the measure fills the column.
    public static let narrowBelow: CGFloat = 600
    /// Room kept clear for controls on each side of the iPhone Duo's crease.
    public static let creaseClearance: CGFloat = 24
    /// The reading column's crease clearance, measured from the crease to its edge.
    public static let readingCreaseClearance: CGFloat = 16
    /// The lane of times beside timed blocks on a narrow page, at the default text size; it grows with
    /// Dynamic Type up to `laneGrowth` times.
    public static let lane: CGFloat = 50
    public static let laneGrowth: CGFloat = 1.9
    /// Between a lane's times and the text.
    public static let laneGap: CGFloat = 10

    /// A page's side gutters at a density: 20 pt under touch; 24 pt in a window, 32 on the side away
    /// from a hanging margin.
    public static func gutters(density: DaybookDensity, hangs: Bool) -> (leading: CGFloat, trailing: CGFloat) {
        if density == .touch { return (20, 20) }
        return (DaybookSpacing.s5, hangs ? DaybookSpacing.s6 : DaybookSpacing.s5)
    }

    /// Where a page's column sits.
    public struct Frame: Equatable, Sendable {
        /// From the container's leading edge to the column (its margin, when one hangs).
        public var leading: CGFloat
        /// The hanging margin's width; 0 on a narrow page.
        public var margin: CGFloat
        /// The text measure.
        public var measure: CGFloat
        /// From the measure's end to the container's trailing edge.
        public var trailing: CGFloat

        public var hangsMargin: Bool { margin > 0 }
        /// Where the text starts.
        public var textLeading: CGFloat { leading + margin }
    }

    /// The page's column in a container `width` wide. Control-oriented pages can keep the larger
    /// control clearance instead of the default reading clearance. A page of a window's spread
    /// (`spreadPage`) hangs its margin at every width.
    public static func frame(width: CGFloat, density: DaybookDensity, creaseEdge: Edge? = nil,
                             creaseClearance: CGFloat = ReadingGeometry.readingCreaseClearance,
                             spreadPage: Bool = false) -> Frame {
        let hangs = ReadingWidth(width: width, spreadPage: spreadPage) == .regular
        var (leading, trailing) = gutters(density: density, hangs: hangs)
        // `creaseClearance` is the entire inset at the crease, not extra to the page gutter.
        if creaseEdge == .leading { leading = creaseClearance }
        if creaseEdge == .trailing { trailing = creaseClearance }
        let widest = Self.measure(density)
        guard hangs else {
            let measure = min(widest, max(0, width - leading - trailing))
            return Frame(leading: leading, margin: 0, measure: measure, trailing: max(0, width - leading - measure))
        }
        let measure = min(widest, max(0, width - leading - trailing - margin))
        // Centred: the measure in the middle, the margin hanging into the space on its left.
        let start = max(leading, (width - measure) / 2 - margin)
        return Frame(leading: start, margin: margin, measure: measure, trailing: max(0, width - start - margin - measure))
    }
}

/// A scrolling page on paper: the column `ReadingGeometry` places, with `readingWidth` set for the rows in it.
public struct ReadingPage<Content: View>: View {
    private let lazy: Bool
    private let bottomInset: CGFloat
    private let content: Content
    @State private var width: CGFloat = 1000
    @Environment(\.daybookDensity) private var density
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.spreadPage) private var spreadPage

    /// - Parameters:
    ///   - lazy: Rows made as they scroll in (a long transcript).
    ///   - bottomInset: Room under the last row for something floating over the page (the player).
    public init(lazy: Bool = false, bottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.lazy = lazy
        self.bottomInset = bottomInset
        self.content = content()
    }

    public var body: some View {
        let frame = ReadingGeometry.frame(width: width, density: density, creaseEdge: creaseEdge, spreadPage: spreadPage)
        ScrollView {
            Group {
                if lazy { LazyVStack(alignment: .leading, spacing: 0) { content } }
                else { VStack(alignment: .leading, spacing: 0) { content } }
            }
            .frame(maxWidth: frame.margin + frame.measure, alignment: .leading)
            .padding(.leading, frame.leading)
            .padding(.top, density == .touch ? DaybookSpacing.s4 : DaybookSpacing.s6)
            .padding(.bottom, DaybookSpacing.s8 + bottomInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.readingWidth, ReadingWidth(width: width, spreadPage: spreadPage))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// One block of the page: something in the margin (a time, a glyph) and content in the measure. On a
/// regular page the margin hangs 56 pt wide and every block keeps it, so text shares one edge; on a
/// narrow page a block with something in the margin keeps a lane of times inside the column (growing
/// with Dynamic Type), and one without runs edge to edge.
public struct MarginRow<Margin: View, Content: View>: View {
    private let alignment: VerticalAlignment
    private let gutterDot: Color?
    private let margin: Margin
    private let content: Content
    @Environment(\.readingWidth) private var readingWidth
    @Environment(\.daybookDensity) private var density
    @ScaledMetric(relativeTo: .footnote) private var scaledLane = ReadingGeometry.lane

    /// - Parameter gutterDot: A 4 pt dot drawn in the 8 pt gutter between the margin and the text, never
    ///   moving the time.
    public init(alignment: VerticalAlignment = .firstTextBaseline, gutterDot: Color? = nil,
                @ViewBuilder margin: () -> Margin, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.gutterDot = gutterDot
        self.margin = margin()
        self.content = content()
    }

    /// The narrow page's lane, grown with Dynamic Type under touch.
    private var lane: CGFloat {
        density == .touch ? min(scaledLane, ReadingGeometry.lane * ReadingGeometry.laneGrowth) : ReadingGeometry.lane
    }

    public var body: some View {
        switch readingWidth {
        case .regular:
            HStack(alignment: alignment, spacing: 0) {
                HStack(spacing: 4) { margin }
                    .frame(width: ReadingGeometry.margin - ReadingGeometry.marginGap, alignment: .trailing)
                    .padding(.trailing, ReadingGeometry.marginGap)
                    .overlay(alignment: .trailing) {
                        if let gutterDot { Circle().fill(gutterDot).frame(width: 4, height: 4).offset(x: -2) }
                    }
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .narrow:
            if Margin.self == EmptyView.self {
                content.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: alignment, spacing: 0) {
                    HStack(spacing: 3) { margin }
                        .frame(width: max(0, lane - ReadingGeometry.laneGap), alignment: .trailing)
                        .padding(.trailing, ReadingGeometry.laneGap)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

extension MarginRow where Margin == EmptyView {
    public init(alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, gutterDot: nil, margin: { EmptyView() }, content: content)
    }
}

/// Summary and transcript side by side when there's room for two pages, else the single page with its
/// Summary | Transcript switch. On the open Duo the split is the crease (`crease`, from the leading
/// edge), each page keeping clear of it; on the Mac it's the middle of a column at least two pages wide,
/// with a hairline between pages that each keep their hanging margin (`spreadPage`).
public struct PageSpread<Leading: View, Trailing: View, Single: View>: View {
    private let crease: CGFloat?
    private let leading: Leading
    private let trailing: Trailing
    private let single: Single
    @State private var width: CGFloat

    /// - Parameter twoPagesFit: Whether the container had room for two pages when last measured (the Mac's detail
    ///   column, from the conversation before), so the first pass lays out the pages it will keep rather than making
    ///   the single page and then the spread. The spread's own width decides from then on.
    public init(crease: CGFloat? = nil, twoPagesFit: Bool = false, @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing, @ViewBuilder single: () -> Single) {
        self.crease = crease
        self.leading = leading()
        self.trailing = trailing()
        self.single = single()
        _width = State(initialValue: twoPagesFit && crease == nil ? PageSpreadLayout.minimumWidth : 0)
    }

    public var body: some View {
        Group {
            if let split = PageSpreadLayout.split(width: width, crease: crease) {
                HStack(spacing: 0) {
                    leading
                        .frame(width: split)
                        .environment(\.creaseEdge, crease == nil ? nil : .trailing)
                        .environment(\.spreadPage, crease == nil)
                    if crease == nil { Divider() }
                    trailing
                        .frame(maxWidth: .infinity)
                        .environment(\.creaseEdge, crease == nil ? nil : .leading)
                        .environment(\.spreadPage, crease == nil)
                }
            } else {
                single
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Where a spread splits, as plain values.
public enum PageSpreadLayout {
    /// The narrowest a page of a spread gets (the trailing one less the hairline, on the Mac).
    public static let minimumPage: CGFloat = 560
    /// The narrowest container that shows two pages without a crease.
    public static let minimumWidth: CGFloat = minimumPage * 2

    /// The leading page's width: the crease when there is one, the middle of a column wide enough for
    /// two pages, or nil for one page.
    public static func split(width: CGFloat, crease: CGFloat?) -> CGFloat? {
        if let crease { return crease > 0 && crease < width ? crease : nil }
        guard width >= minimumWidth else { return nil }
        return (width / 2).rounded(.down)
    }
}
