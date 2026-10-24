import SwiftUI

/// One line of live captions, as a caption strip draws it.
public struct CaptionLine: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    /// Words still being revised: lighter ink.
    public var isTentative: Bool
    /// Who it's from ("You", "Call"), when a strip shows more than one source.
    public var source: String?

    public init(id: UUID, text: String, isTentative: Bool, source: String? = nil) {
        self.id = id
        self.text = text
        self.isTentative = isTentative
        self.source = source
    }
}

/// How a caption strip sets its lines: how many, and how large the newest is against the rest.
public struct CaptionStripStyle: Equatable, Sendable {
    /// Lines shown, newest last.
    public var lines: Int
    public var newestSize: CGFloat
    public var newestWeight: Font.Weight
    public var olderSize: CGFloat
    public var newestLineLimit: Int
    public var olderLineLimit: Int
    public var labelSize: CGFloat
    /// The label follows Dynamic Type at this style (iPhone); nil keeps `labelSize`.
    public var labelStyle: Font.TextStyle?
    /// Between the label and the lines.
    public var spacing: CGFloat
    /// Between the lines.
    public var lineSpacing: CGFloat
    public var showsLabel: Bool
    /// A lane for each line's source, right-aligned at this width; nil hides sources.
    public var sourceLane: CGFloat?
    /// The gap between the source lane and the words.
    public var laneGap: CGFloat

    public init(lines: Int, newestSize: CGFloat, newestWeight: Font.Weight = .medium, olderSize: CGFloat,
                newestLineLimit: Int, olderLineLimit: Int, labelSize: CGFloat, labelStyle: Font.TextStyle? = nil,
                spacing: CGFloat, lineSpacing: CGFloat? = nil, showsLabel: Bool = true, sourceLane: CGFloat? = nil, laneGap: CGFloat = 8) {
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
        self.showsLabel = showsLabel
        self.sourceLane = sourceLane
        self.laneGap = laneGap
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

    public init(lines: [CaptionLine], status: String?, style: CaptionStripStyle, label: String = "Live captions · tentative") {
        self.lines = Array(lines.suffix(style.lines))
        self.status = status
        self.style = style
        self.label = label
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: style.spacing) {
            if style.showsLabel {
                row(source: nil) {
                    Label(label, systemImage: "captions.bubble")
                        .font(style.labelStyle.map { Font.system($0).weight(.semibold) } ?? .system(size: style.labelSize, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(DaybookPalette.Ink.meta)
                        .lineLimit(1)
                }
            }
            if lines.isEmpty {
                if let status {
                    row(source: nil) {
                        Text(status)
                            .font(.system(size: style.olderSize))
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
                            Text(line.text)
                                .font(.system(size: newest ? style.newestSize : style.olderSize, weight: newest ? style.newestWeight : .regular))
                                .foregroundStyle(line.isTentative ? DaybookPalette.Ink.meta
                                                 : newest ? DaybookPalette.Ink.body : DaybookPalette.Ink.secondary)
                                .lineLimit(newest ? style.newestLineLimit : style.olderLineLimit)
                                // The newest line keeps its latest words; earlier ones read from their start.
                                .truncationMode(newest ? .head : .tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .transition(.opacity)
                    }
                }
                .daybookMotion(.easeOut(duration: 0.2), value: lines.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(lines.last.map { [$0.source, $0.text].compactMap { $0 }.joined(separator: ": ") } ?? status ?? "")
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
