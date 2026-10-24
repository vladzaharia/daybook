import SwiftUI

/// Which ink a status uses (docs/interface.md, "Colour has a job").
public enum StatusTone: Equatable, Sendable {
    /// Fine; nothing to say beyond the fact. Secondary ink.
    case calm
    /// Work in progress: the brand-gradient line when there's a fraction.
    case working
    /// A recorder or device connected now: teal.
    case linked
    /// Recording right now: the red dot.
    case recording
    /// Needs the person: orange.
    case attention
}

/// One status line: "Soundcore Work  Connected · 80% · 1 new". Plain values, so each app's model
/// says what a state reads and tests can check it.
public struct StatusLineItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var symbol: String
    public var title: String
    public var text: String
    public var tone: StatusTone
    /// 0...1 for work in progress.
    public var progress: Double?
    /// A shorter way to say it, when `text` doesn't fit on one line.
    public var shortText: String?

    public init(id: String, symbol: String, title: String, text: String, tone: StatusTone, progress: Double? = nil, shortText: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.text = text
        self.tone = tone
        self.progress = progress
        self.shortText = shortText
    }

    public var accessibilityLabel: String { "\(title), \(text)" }
}

/// Type and spacing for status lines and chips on each platform.
public struct StatusMetrics: Equatable, Sendable {
    public var titleSize: CGFloat
    public var textSize: CGFloat
    public var glyphSize: CGFloat
    public var glyphColumn: CGFloat
    public var spacing: CGFloat
    /// Follows Dynamic Type (iPhone) instead of fixed sizes (Mac chrome).
    public var usesTextStyles: Bool

    public init(titleSize: CGFloat, textSize: CGFloat, glyphSize: CGFloat, glyphColumn: CGFloat, spacing: CGFloat, usesTextStyles: Bool) {
        self.titleSize = titleSize
        self.textSize = textSize
        self.glyphSize = glyphSize
        self.glyphColumn = glyphColumn
        self.spacing = spacing
        self.usesTextStyles = usesTextStyles
    }

    /// The iPhone status sheet: subheadline, a 22 pt glyph column.
    public static let phone = StatusMetrics(titleSize: 15, textSize: 15, glyphSize: 15, glyphColumn: 22, spacing: 8, usesTextStyles: true)
    /// Mac surfaces (Floating Notes): 12 pt, an 18 pt glyph column.
    public static let mac = StatusMetrics(titleSize: 12, textSize: 12, glyphSize: 12, glyphColumn: 18, spacing: 6, usesTextStyles: false)

    var titleFont: Font { usesTextStyles ? .subheadline.weight(.medium) : .system(size: titleSize, weight: .medium) }
    var textFont: Font { usesTextStyles ? .subheadline : .system(size: textSize) }
    var glyphFont: Font { usesTextStyles ? .subheadline.weight(.medium) : .system(size: glyphSize, weight: .medium) }
}

/// A status line: glyph, title, and what's happening, in one row; the gradient line under it while
/// work runs. Recording swaps the glyph for the red dot.
public struct StatusLineView: View {
    private let line: StatusLineItem
    private let metrics: StatusMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ line: StatusLineItem, metrics: StatusMetrics = .phone) {
        self.line = line
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing) {
                StatusGlyph(symbol: line.symbol, tone: line.tone, animates: line.tone == .working && line.progress == nil && !reduceMotion,
                            font: metrics.glyphFont, dot: metrics.glyphSize * 0.62)
                    .frame(width: metrics.glyphColumn)
                Text(line.title)
                    .font(metrics.titleFont)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    lineText(line.text)
                    if let short = line.shortText { lineText(short) }
                    lineText(line.text).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if line.tone == .working, let progress = line.progress {
                WorkProgressLine(fraction: progress).padding(.leading, metrics.glyphColumn + metrics.spacing)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
    }

    private func lineText(_ text: String) -> some View {
        Text(text)
            .font(metrics.textFont)
            .foregroundStyle(line.tone == .attention ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

/// A status's glyph in its tone's ink, or the red dot while recording.
struct StatusGlyph: View {
    let symbol: String
    let tone: StatusTone
    var animates = false
    let font: Font
    let dot: CGFloat

    var body: some View {
        switch tone {
        case .recording:
            Circle().fill(DaybookPalette.Ink.record).frame(width: dot, height: dot)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
                .accessibilityHidden(true)
        default:
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(ink)
                .symbolEffect(.variableColor.iterative, isActive: animates)
                .accessibilityHidden(true)
        }
    }

    private var ink: Color {
        switch tone {
        case .linked: return DaybookPalette.accent
        case .attention: return DaybookPalette.Ink.warning
        case .working: return DaybookPalette.Ink.link
        default: return DaybookPalette.Ink.meta
        }
    }
}

/// Work in progress: the 2 pt brand-gradient line, as in a list row that's transcribing.
public struct WorkProgressLine: View {
    private let fraction: Double
    private let height: CGFloat

    public init(fraction: Double, height: CGFloat = 2) {
        self.fraction = fraction
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DaybookPalette.quietFill)
                Capsule().fill(DaybookPalette.brandGradient())
                    .frame(width: max(height, proxy.size.width * min(1, max(0, fraction))))
                    .daybookGlow(DaybookPalette.neonCyan, radius: 3)
            }
        }
        .frame(height: height)
        .daybookMotion(.linear(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A compact status: glyph (or the red dot) and a short label in a quiet capsule. The iPhone's
/// multipoint line ("● Also recording on Studio Mac") and the Mac's Floating Notes status bar.
public struct StatusChip: View {
    public struct Metrics: Equatable, Sendable {
        public var textSize: CGFloat
        public var glyphSize: CGFloat
        public var horizontalPadding: CGFloat
        public var height: CGFloat
        public var usesTextStyles: Bool
        public init(textSize: CGFloat, glyphSize: CGFloat, horizontalPadding: CGFloat, height: CGFloat, usesTextStyles: Bool) {
            self.textSize = textSize
            self.glyphSize = glyphSize
            self.horizontalPadding = horizontalPadding
            self.height = height
            self.usesTextStyles = usesTextStyles
        }
        /// The iPhone's multipoint line: footnote, 10 pt padding.
        public static let phone = Metrics(textSize: 13, glyphSize: 13, horizontalPadding: 10, height: 30, usesTextStyles: true)
        /// A Mac title-bar chip: 11 pt, 20 pt tall.
        public static let mac = Metrics(textSize: 11, glyphSize: 10.5, horizontalPadding: 7, height: 20, usesTextStyles: false)
    }

    private let symbol: String?
    private let text: String?
    private let tone: StatusTone
    private let showsDot: Bool
    private let progress: Double?
    private let filled: Bool
    private let truncates: Bool
    private let metrics: Metrics
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - showsDot: The red recording dot after the glyph (a device recording along).
    ///   - progress: Work in progress: the gradient line along the chip's foot.
    ///   - filled: A quiet capsule behind it; off for a bare glyph and label.
    ///   - truncates: The label gives way to a narrow container (a sentence); chips in a row keep theirs.
    public init(symbol: String?, text: String?, tone: StatusTone, showsDot: Bool = false, progress: Double? = nil,
                filled: Bool = true, truncates: Bool = false, metrics: Metrics = .phone) {
        self.symbol = symbol
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
        self.progress = progress
        self.filled = filled
        self.truncates = truncates
        self.metrics = metrics
    }

    public var body: some View {
        HStack(spacing: metrics.glyphSize * 0.4) {
            if let symbol {
                StatusGlyph(symbol: symbol, tone: tone == .recording ? .linked : tone,
                            animates: tone == .working && progress == nil && !reduceMotion,
                            font: metrics.usesTextStyles ? .footnote.weight(.medium) : .system(size: metrics.glyphSize, weight: .medium),
                            dot: metrics.glyphSize * 0.6)
            }
            if showsDot || (tone == .recording && symbol == nil) {
                Circle().fill(DaybookPalette.Ink.record).frame(width: metrics.glyphSize * 0.55, height: metrics.glyphSize * 0.55)
                    .daybookGlow(DaybookPalette.Ink.record, radius: 2)
                    .accessibilityHidden(true)
            }
            if let text {
                Text(text)
                    .font(metrics.usesTextStyles ? .footnote.weight(.medium) : .system(size: metrics.textSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(tone == .attention ? DaybookPalette.Ink.warning : DaybookPalette.Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !truncates, vertical: false)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, filled ? metrics.horizontalPadding : 2)
        .frame(minHeight: metrics.height)
        .background {
            if filled {
                Capsule(style: .circular).fill(tone == .attention ? DaybookPalette.attentionFill : DaybookPalette.quietFill)
            }
        }
        .overlay {
            if filled && contrast == .increased { Capsule(style: .circular).strokeBorder(DaybookPalette.Ink.meta.opacity(0.6), lineWidth: 1) }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                WorkProgressLine(fraction: progress)
                    .padding(.horizontal, filled ? metrics.horizontalPadding : 2)
                    .padding(.bottom, filled ? 2 : 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
