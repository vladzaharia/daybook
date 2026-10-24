import SwiftUI

/// The elapsed time of a recording: red while recording, ink once paused or stopped (frozen there).
/// It ticks on its own; nothing around it redraws.
public struct ElapsedClock: View {
    private let size: CGFloat
    private let weight: Font.Weight
    private let isLive: Bool
    private let frozenAt: TimeInterval?
    private let anchor: Date?
    private let elapsed: () -> TimeInterval
    private let spokenLive: (String) -> String
    private let spokenFrozen: (String) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - isLive: Recording right now: the clock is red and runs.
    ///   - frozenAt: Paused or stopped here: the clock shows this in title ink.
    ///   - elapsed: The recording's time now, on the recorder's own clock.
    public init(size: CGFloat, weight: Font.Weight = .medium, isLive: Bool, frozenAt: TimeInterval? = nil,
                spokenLive: @escaping (String) -> String = { "Recording, \($0)" },
                spokenFrozen: @escaping (String) -> String = { "Paused at \($0)" },
                elapsed: @escaping () -> TimeInterval) {
        self.size = size
        self.weight = weight
        self.isLive = isLive
        self.frozenAt = frozenAt
        anchor = nil
        self.elapsed = elapsed
        self.spokenLive = spokenLive
        self.spokenFrozen = spokenFrozen
    }

    /// A clock that counts from `start`, ticking on the second it started.
    public init(since start: Date, size: CGFloat, weight: Font.Weight = .medium, isLive: Bool = true, frozenAt: TimeInterval? = nil,
                spokenLive: @escaping (String) -> String = { "Recording, \($0)" },
                spokenFrozen: @escaping (String) -> String = { "Paused at \($0)" }) {
        self.size = size
        self.weight = weight
        self.isLive = isLive
        self.frozenAt = frozenAt
        anchor = start
        elapsed = { max(0, Date().timeIntervalSince(start)) }
        self.spokenLive = spokenLive
        self.spokenFrozen = spokenFrozen
    }

    public var body: some View {
        TimelineView(.periodic(from: anchor ?? .now, by: anchor == nil ? 0.5 : 1)) { _ in
            let seconds = frozenAt ?? elapsed()
            let text = ClockFormat.short(seconds)
            Text(text)
                .font(DaybookType.clock(size, weight: weight))
                .foregroundStyle(isLive && frozenAt == nil ? DaybookPalette.Ink.record : DaybookPalette.Ink.title)
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: false))
                .animation(reduceMotion ? DaybookMotion.reduced : .snappy(duration: 0.3), value: Int(seconds))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(isLive && frozenAt == nil ? spokenLive(text) : spokenFrozen(text))
        }
    }
}

/// "● RECORDING · MacBook Pro Microphone": the phase in small capitals, then what it records from.
/// The dot is the one red mark besides the clock and Stop; other phases trade it for their glyph.
public struct RecordingPhaseLabel: View {
    public enum Phase: Equatable, Sendable {
        case starting, recording, paused, saving, saved, stopped
    }

    public struct Metrics: Equatable, Sendable {
        public var size: CGFloat
        public var dot: CGFloat
        public var tracking: CGFloat
        /// Follows Dynamic Type at this style (iPhone); nil keeps `size` (Mac chrome).
        public var textStyle: Font.TextStyle?
        public init(size: CGFloat, dot: CGFloat, tracking: CGFloat, textStyle: Font.TextStyle? = nil) {
            self.size = size
            self.dot = dot
            self.tracking = tracking
            self.textStyle = textStyle
        }
        /// The iPhone's recording header: footnote, a 9 pt dot.
        public static let phone = Metrics(size: 13, dot: 9, tracking: 0.6, textStyle: .footnote)
        /// Floating Notes' title band.
        public static let panel = Metrics(size: 10.5, dot: 7, tracking: 0.5)

        func font(weight: Font.Weight, plus: CGFloat = 0) -> Font {
            textStyle.map { Font.system($0).weight(weight) } ?? .system(size: size + plus, weight: weight)
        }
    }

    private let phase: Phase
    private let title: String
    private let detail: String?
    private let detailIsWarning: Bool
    private let detailYields: Bool
    private let metrics: Metrics

    /// - Parameter detailYields: The detail takes only the room left over (and truncates), so the
    ///   label's ideal width is the phase alone. For a bar that fits its other items first.
    public init(_ phase: Phase, title: String, detail: String? = nil, detailIsWarning: Bool = false, detailYields: Bool = false,
                metrics: Metrics = .phone) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.detailIsWarning = detailIsWarning
        self.detailYields = detailYields
        self.metrics = metrics
    }

    public var body: some View {
        HStack(spacing: metrics.dot * 0.65) {
            glyph
            Text(title)
                .font(metrics.font(weight: .semibold))
                .foregroundStyle(ink)
                .textCase(.uppercase)
                .tracking(metrics.tracking)
                .lineLimit(1)
                .fixedSize()
            if let detail {
                Text("· \(detail)")
                    .font(metrics.font(weight: .regular, plus: 0.5))
                    .foregroundStyle(detailIsWarning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .frame(minWidth: 0, idealWidth: detailYields ? 0 : nil, maxWidth: detailYields ? .infinity : nil, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .recording:
            Circle().fill(DaybookPalette.Ink.record).frame(width: metrics.dot, height: metrics.dot)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: metrics.size + 1, weight: .semibold))
                .foregroundStyle(DaybookPalette.accent)
        case .stopped:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: metrics.size, weight: .semibold))
                .foregroundStyle(DaybookPalette.Ink.warning)
        default:
            Circle().fill(Color.platformTertiaryLabel).frame(width: metrics.dot, height: metrics.dot)
        }
    }

    private var ink: Color {
        switch phase {
        case .recording: return DaybookPalette.Ink.record
        case .stopped: return DaybookPalette.Ink.warning
        default: return DaybookPalette.Ink.secondary
        }
    }
}
