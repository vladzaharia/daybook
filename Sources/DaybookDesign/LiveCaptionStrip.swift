import SwiftUI

/// One line of live captions, as a caption strip draws it.
public struct CaptionLine: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    /// Words still being revised: lighter ink.
    public var isTentative: Bool
    /// Who it's from ("You", "Call"), when a strip shows more than one source.
    public var source: String?
    /// Who said it, when live speakers named the voice ("Priya"); shown before the words, never cut off.
    public var speaker: String?

    public init(id: UUID, text: String, isTentative: Bool, source: String? = nil, speaker: String? = nil) {
        self.id = id
        self.text = text
        self.isTentative = isTentative
        self.source = source
        self.speaker = speaker
    }
}

/// How a caption strip sets its lines: how many, and how large the newest is against the rest. Every
/// style draws the same way (the label on top, the newest line in Body ink, earlier ones in Secondary,
/// words still being revised in Meta); under touch the sizes follow Dynamic Type.
public struct CaptionStripStyle: Equatable, Sendable {
    /// Lines shown, newest last.
    public var lines: Int
    public var newestSize: CGFloat
    public var newestWeight: Font.Weight
    public var olderSize: CGFloat
    /// The most lines the newest caption wraps to, cut from its start; nil lets it wrap whole.
    public var newestLineLimit: Int?
    /// The same for earlier captions, cut at their end.
    public var olderLineLimit: Int?
    public var labelSize: CGFloat
    /// The label follows Dynamic Type at this style (iPhone); nil keeps `labelSize`.
    public var labelStyle: Font.TextStyle?
    /// Between the label and the lines.
    public var spacing: CGFloat
    /// Between the lines.
    public var lineSpacing: CGFloat
    /// Between the wrapped lines of one caption.
    public var textLineSpacing: CGFloat
    public var showsLabel: Bool
    /// The label's glyph in a column this wide, so a row beside the strip can put its own glyph in the
    /// same column (Listen Live's Listening line); nil sets the label as a plain label.
    public var glyphColumn: CGFloat?
    /// Between the glyph column and the label's words.
    public var glyphGap: CGFloat
    /// A lane for each line's source, right-aligned at this width; nil hides sources.
    public var sourceLane: CGFloat?
    /// The gap between the source lane and the words.
    public var laneGap: CGFloat
    /// In a window, the lines grow with View › Make Text Bigger, as the page's do.
    public var followsReadingScale: Bool

    public init(lines: Int, newestSize: CGFloat, newestWeight: Font.Weight = .medium, olderSize: CGFloat,
                newestLineLimit: Int?, olderLineLimit: Int?, labelSize: CGFloat, labelStyle: Font.TextStyle? = nil,
                spacing: CGFloat, lineSpacing: CGFloat? = nil, textLineSpacing: CGFloat = 0, showsLabel: Bool = true,
                glyphColumn: CGFloat? = nil, glyphGap: CGFloat = DaybookSpacing.s3, sourceLane: CGFloat? = nil, laneGap: CGFloat = 8,
                followsReadingScale: Bool = false) {
        self.lines = lines
        self.newestSize = newestSize
        self.newestWeight = newestWeight
        self.olderSize = olderSize
        self.newestLineLimit = newestLineLimit
        self.olderLineLimit = olderLineLimit
        self.labelSize = labelSize
        self.labelStyle = labelStyle
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing * 0.6
        self.textLineSpacing = textLineSpacing
        self.showsLabel = showsLabel
        self.glyphColumn = glyphColumn
        self.glyphGap = glyphGap
        self.sourceLane = sourceLane
        self.laneGap = laneGap
        self.followsReadingScale = followsReadingScale
    }

    /// iPhone, pocket: two lines in a strip above the controls.
    public static let strip = CaptionStripStyle(lines: 2, newestSize: 19, olderSize: 15, newestLineLimit: 2, olderLineLimit: 1,
                                                labelSize: 12, labelStyle: .caption, spacing: 6, lineSpacing: 4)
    /// iPhone, notebook: a column on the right page.
    public static let page = CaptionStripStyle(lines: 4, newestSize: 21, olderSize: 17, newestLineLimit: 2, olderLineLimit: 2,
                                               labelSize: 12, labelStyle: .caption, spacing: 6, lineSpacing: 4)
    /// iPhone, table: large type on the standing half, readable across a table.
    public static let stage = CaptionStripStyle(lines: 2, newestSize: 34, olderSize: 24, newestLineLimit: 3, olderLineLimit: 1,
                                                labelSize: 15, labelStyle: .subheadline, spacing: 10, lineSpacing: 8)
    /// Mac, Floating Notes: two lines with You or Call in the notes' time lane (28 pt from a 16 pt inset).
    public static let panel = CaptionStripStyle(lines: 2, newestSize: 14, olderSize: 12.5, newestLineLimit: 2, olderLineLimit: 1,
                                                labelSize: 9.5, spacing: 5, sourceLane: 28)
    /// Mac, Floating Notes when compact: the newest line only, no label.
    public static let panelCompact = CaptionStripStyle(lines: 1, newestSize: 13, olderSize: 12, newestLineLimit: 1, olderLineLimit: 1,
                                                       labelSize: 9.5, spacing: 3, showsLabel: false, sourceLane: 28)
    /// Mac, a recorder's Listen Live page: six lines in the page's body type, each whole, the label's
    /// glyph in the column the Listening line above uses.
    public static let feed = CaptionStripStyle(lines: 6, newestSize: DaybookFont.body.size(.window), newestWeight: .regular,
                                               olderSize: DaybookFont.body.size(.window), newestLineLimit: nil, olderLineLimit: nil,
                                               labelSize: 11, spacing: DaybookSpacing.s2, lineSpacing: DaybookSpacing.s1,
                                               textLineSpacing: DaybookFont.bodyLineSpacing(.window), glyphColumn: 24,
                                               followsReadingScale: true)
    /// iPhone, the status sheet and the Duo's panel: three lines while a recorder listens live.
    public static let sheet = CaptionStripStyle(lines: 3, newestSize: 16, newestWeight: .regular, olderSize: 15,
                                                newestLineLimit: 3, olderLineLimit: 2, labelSize: 12, labelStyle: .caption,
                                                spacing: 6, lineSpacing: 4)
}

/// Live captions as calm closed captions: the newest line larger and in body ink, earlier lines
/// smaller and quieter, words still being heard in lighter ink, and a small "Live captions ·
/// tentative" label, because they're never the transcript. Before there are lines, `status` says
/// why ("Listening…", "Getting captions ready…").
public struct LiveCaptionStrip: View {
    private let lines: [CaptionLine]
    private let status: String?
    private let style: CaptionStripStyle
    private let label: String
    @Environment(\.daybookDensity) private var density
    @Environment(\.readingScale) private var readingScale
    /// Under touch the lines follow Dynamic Type like body text, from the style's sizes at the default size.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// How much the lines are scaled: Dynamic Type under touch; on the Mac fixed, or the page's reading
    /// scale for a style that follows it.
    private var scale: CGFloat {
        if density == .touch { return typeScale }
        return style.followsReadingScale ? readingScale : 1
    }

    public init(lines: [CaptionLine], status: String?, style: CaptionStripStyle, label: String = "Live captions · tentative") {
        self.lines = Array(lines.suffix(style.lines))
        self.status = status
        self.style = style
        self.label = label
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            if style.showsLabel {
                row(source: nil) { labelView }
            }
            if lines.isEmpty {
                if let status {
                    row(source: nil) {
                        Text(status)
                            .font(.system(size: style.olderSize * scale))
                            .foregroundStyle(DaybookPalette.Ink.meta)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: style.lineSpacing) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let newest = index == lines.count - 1
                        row(source: line.source) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                if let speaker = line.speaker {
                                    Text(speaker)
                                        .font(.system(size: (newest ? style.newestSize : style.olderSize) * 0.8 * scale, weight: .semibold))
                                        .foregroundStyle(DaybookPalette.Ink.meta)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                Text(line.text)
                                    .font(.system(size: (newest ? style.newestSize : style.olderSize) * scale,
                                                  weight: newest ? style.newestWeight : .regular))
                                    .foregroundStyle(line.isTentative ? DaybookPalette.Ink.meta
                                                     : newest ? DaybookPalette.Ink.body : DaybookPalette.Ink.secondary)
                                    .lineSpacing(style.textLineSpacing * scale)
                                    .lineLimit(newest ? style.newestLineLimit : style.olderLineLimit)
                                    // The newest line keeps its latest words; earlier ones read from their start.
                                    .truncationMode(newest ? .head : .tail)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .daybookMotion(DaybookMotion.fade, value: lines.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(lines.last.map { [$0.speaker ?? $0.source, $0.text].compactMap { $0 }.joined(separator: ": ") } ?? status ?? "")
    }

    /// "LIVE CAPTIONS · TENTATIVE" on top: their glyph, then the words, in Meta.
    @ViewBuilder
    private var labelView: some View {
        let font = style.labelStyle.map { Font.system($0).weight(.semibold) } ?? .system(size: style.labelSize, weight: .semibold)
        Group {
            if let column = style.glyphColumn {
                HStack(spacing: style.glyphGap) {
                    Image(systemName: "captions.bubble").frame(width: column)
                    Text(label)
                }
            } else {
                Label(label, systemImage: "captions.bubble")
            }
        }
        .font(font)
        .textCase(.uppercase)
        .tracking(0.5)
        .foregroundStyle(DaybookPalette.Ink.meta)
        .lineLimit(1)
    }

    /// Words in the text column; with a source lane, the source right-aligned in it.
    @ViewBuilder
    private func row(source: String?, @ViewBuilder content: () -> some View) -> some View {
        if let lane = style.sourceLane {
            HStack(alignment: .firstTextBaseline, spacing: style.laneGap) {
                Text(source ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DaybookPalette.Ink.meta)
                    .lineLimit(1)
                    .frame(width: lane, alignment: .trailing)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
