import SwiftUI

/// A symbol on a tinted square tile: a Settings row's, a status card's, a device page's header. Teal while
/// what it stands for is connected, orange while something needs you, neutral otherwise.
public struct DaybookTile: View {
    public enum Tone: Hashable, Sendable { case neutral, active, attention }

    private let symbol: String
    private let tone: Tone
    private let size: DaybookTileSize
    @Environment(\.daybookDensity) private var density
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 1
    @ScaledMetric(relativeTo: .subheadline) private var subheadlineScale: CGFloat = 1
    @ScaledMetric(relativeTo: .title) private var titleScale: CGFloat = 1

    public init(symbol: String, tone: Tone = .neutral, size: DaybookTileSize = .row) {
        self.symbol = symbol
        self.tone = tone
        self.size = size
    }

    /// The tile's side here: grown with Dynamic Type under touch, up to the size's limit.
    private var side: CGFloat {
        guard density == .touch else { return size.base }
        switch size.textStyle {
        case .subheadline: return size.side(scale: subheadlineScale)
        case .title: return size.side(scale: titleScale)
        default: return size.side(scale: bodyScale)
        }
    }

    public var body: some View {
        let side = side
        Image(systemName: symbol)
            .font(.system(size: side * 0.5, weight: .medium))
            .foregroundStyle(Self.ink(tone))
            .frame(width: side, height: side)
            .background(Self.fill(tone).opacity(0.12), in: DaybookRadius.shape(side * 0.24))
            .accessibilityHidden(true)
    }

    static func ink(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: return DaybookPalette.Ink.secondary
        case .active: return DaybookPalette.accent
        case .attention: return DaybookPalette.Ink.warning
        }
    }

    static func fill(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: return .gray
        case .active: return DaybookPalette.accent
        case .attention: return DaybookPalette.Ink.warning
        }
    }
}

/// One figure in a quiet tile: a label with its glyph, the value, and a line of detail under it
/// ("Charging", "of recording left", "Nearly full"). A warning draws all three in warning ink; a value
/// not confirmed recently is quieter.
public struct FigureTile: View {
    private let label: String
    private let symbol: String
    private let value: String
    private let detail: String?
    private let warning: Bool
    private let stale: Bool
    private let accessibility: String?
    @Environment(\.daybookDensity) private var density

    public init(label: String, symbol: String, value: String, detail: String? = nil, warning: Bool = false, stale: Bool = false,
                accessibility: String? = nil) {
        self.label = label
        self.symbol = symbol
        self.value = value
        self.detail = detail
        self.warning = warning
        self.stale = stale
        self.accessibility = accessibility
    }

    public var body: some View {
        let touch = density == .touch
        VStack(alignment: .leading, spacing: touch ? 4 : DaybookSpacing.s2) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(warning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
                Text(label)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(touch ? .footnote : DaybookFont.status.font(.window))
            Text(value)
                .font(touch ? .title3.weight(.semibold).monospacedDigit() : .system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(warning ? DaybookPalette.Ink.warning : stale ? DaybookPalette.Ink.secondary : DaybookPalette.Ink.body)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .font(touch ? .footnote : DaybookFont.colophon.font(.window))
                .foregroundStyle(warning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(DaybookSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DaybookPalette.quietFill, in: DaybookRadius.shape(DaybookRadius.box))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility ?? [label, value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Cards of rows

/// The measurements every card of rows shares, so rows in every card line up.
public enum StatusCardMetrics {
    public static let radius = DaybookRadius.card
    /// Inside a card, on every side of every row.
    public static let padding = DaybookSpacing.s3
    public static let rowVertical: CGFloat = 10
    /// Between the glyph column and the text.
    public static let gap = DaybookSpacing.s3
}

/// The glyph column's width at the person's text size: a card tile, grown with Dynamic Type under touch.
struct StatusGlyphColumn: DynamicProperty {
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.daybookDensity) private var density
    var value: CGFloat { density == .touch ? DaybookTileSize.card.side(scale: scale) : DaybookTileSize.card.base }
}

/// One full-width card: the quiet fill, the card radius, an inset divider between rows. The divider above
/// a row starts where that row's text does: past the glyph column, or at the card's edge for a row with no
/// column (`statusRowAtCardEdge()`).
public struct StatusCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { StatusDivider(atCardEdge: row.containerValues.statusRowAtCardEdge) }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DaybookPalette.quietFill, in: DaybookRadius.shape(StatusCardMetrics.radius))
        .clipShape(DaybookRadius.shape(StatusCardMetrics.radius))
    }
}

extension ContainerValues {
    /// The row's text starts at the card's edge, with no glyph column before it.
    @Entry var statusRowAtCardEdge = false
}

extension View {
    /// In a `StatusCard`, a row whose text starts at the card's edge (no glyph column): the divider above it does too.
    /// Set it on the card's row itself (where it's listed in the card), not inside a row's body.
    public func statusRowAtCardEdge(_ atEdge: Bool = true) -> some View {
        containerValue(\.statusRowAtCardEdge, atEdge)
    }
}

/// The divider between a card's rows, from where the text starts.
public struct StatusDivider: View {
    private let glyph = StatusGlyphColumn()
    private let atCardEdge: Bool
    /// - Parameter atCardEdge: The row under it has no glyph column, so its text, and the divider, start at the edge.
    public init(atCardEdge: Bool = false) { self.atCardEdge = atCardEdge }
    public var body: some View {
        Divider().padding(.leading, StatusCardMetrics.padding + (atCardEdge ? 0 : glyph.value + StatusCardMetrics.gap))
    }
}

/// A row in a card: a fixed-width glyph column (empty for a row under another), then the content, so
/// text in sibling rows lines up whatever the symbols' widths. 44 pt tall at least under touch.
public struct StatusRow<Glyph: View, Content: View>: View {
    private let alignment: VerticalAlignment
    private let glyph: Glyph
    private let content: Content
    private let width = StatusGlyphColumn()
    @Environment(\.daybookDensity) private var density

    public init(alignment: VerticalAlignment = .center, @ViewBuilder glyph: () -> Glyph, @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.glyph = glyph()
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: alignment, spacing: StatusCardMetrics.gap) {
            glyph.frame(width: width.value)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, StatusCardMetrics.padding)
        .padding(.vertical, density == .touch ? StatusCardMetrics.rowVertical : DaybookSpacing.s2)
        .frame(maxWidth: .infinity, minHeight: density == .touch ? TouchTarget.side : nil, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension StatusRow where Glyph == Color {
    /// A row under another (a recording on its recorder, a conversation under its Mac): indented to the text.
    public init(alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, glyph: { Color.clear }, content: content)
    }
}
