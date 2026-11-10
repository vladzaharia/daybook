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

    private var runs: Bool { isLive && frozenAt == nil }

    public var body: some View {
        TimelineView(.periodic(from: anchor ?? .now, by: anchor == nil ? 0.5 : 1)) { _ in
            let seconds = frozenAt ?? elapsed()
            let text = DaybookTime.short(seconds)
            Text(text)
                .font(DaybookType.clock(size, weight: weight))
                .foregroundStyle(runs ? DaybookPalette.Ink.record : DaybookPalette.Ink.title)
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: false))
                .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: Int(seconds))
                // Red to title ink as it pauses or stops: a cross-fade, never a jump.
                .animation(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: reduceMotion), value: runs)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(runs ? spokenLive(text) : spokenFrozen(text))
                .accessibilityAddTraits(runs ? .updatesFrequently : [])
        }
    }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    /// Once a second on a countdown's own phase: each tick lands as the whole seconds left to `deadline` change, so
    /// every view counting down to the same moment says the same number, whenever each began ("Summarizing in 7 s"
    /// never sits beside "6 s").
    public static func countdown(to deadline: Date, now: Date = Date()) -> PeriodicTimelineSchedule {
        .periodic(from: CountdownPhase.tick(before: deadline, at: now), by: 1)
    }
}

/// Where a countdown's ticks fall: a whole number of seconds before its deadline, where its seconds left, rounded
/// up as every countdown says them, change.
public enum CountdownPhase {
    /// The countdown's latest tick at or before `now` (the deadline itself once it has passed).
    public static func tick(before deadline: Date, at now: Date) -> Date {
        deadline.addingTimeInterval(-max(0, deadline.timeIntervalSince(now)).rounded(.up))
    }
}

extension View {
    /// Text whose number changes on its own (a countdown, a percent): its digits roll as the clock's do, a fade
    /// under Reduce Motion. The roll is keyed to `value`, so it plays however the change arrives (a TimelineView's
    /// tick, a Task), where `.numericText()` alone plays only inside an animation that rarely surrounds it.
    public func daybookNumberRoll<Value: Equatable>(value: Value, countsDown: Bool = false) -> some View {
        modifier(NumberRoll(value: value, countsDown: countsDown))
    }
}

private struct NumberRoll<Value: Equatable>: ViewModifier {
    let value: Value
    let countsDown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: countsDown))
            .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: value)
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

        /// A density's metrics: the iPhone's header under touch, the title band's on the Mac.
        public static func `for`(_ density: DaybookDensity) -> Metrics { density == .touch ? .phone : .panel }

        func font(weight: Font.Weight, plus: CGFloat = 0) -> Font {
            textStyle.map { Font.system($0).weight(weight) } ?? .system(size: size + plus, weight: weight)
        }
    }

    private let phase: Phase
    private let title: String
    private let detail: String?
    private let detailIsWarning: Bool
    private let detailYields: Bool
    private let override: Metrics?
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The Saved mark's size under touch, which follows Dynamic Type with the phone's footnote.
    @ScaledMetric(relativeTo: .footnote) private var touchGlyph: CGFloat = 14

    /// - Parameters:
    ///   - detailYields: The detail takes only the room left over (and truncates), so the label's ideal
    ///     width is the phase alone. For a bar that fits its other items first.
    ///   - metrics: An explicit size; nil takes the surface's density's.
    public init(_ phase: Phase, title: String, detail: String? = nil, detailIsWarning: Bool = false, detailYields: Bool = false,
                metrics: Metrics? = nil) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.detailIsWarning = detailIsWarning
        self.detailYields = detailYields
        override = metrics
    }

    private var metrics: Metrics { override ?? .for(density) }

    /// Under touch at the accessibility sizes the detail takes a line of its own under the phase, so
    /// neither is cut off ("RECORDING · S…").
    private var stacks: Bool { metrics.textStyle != nil && typeSize.isAccessibilitySize && detail != nil }

    public var body: some View {
        if stacks {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: metrics.dot * 0.65) {
                    glyph
                    titleText
                }
                if let detail {
                    Text(detail)
                        .font(metrics.font(weight: .regular, plus: 0.5))
                        .foregroundStyle(detailIsWarning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            row
        }
    }

    private var titleText: some View {
        Text(title)
            .font(metrics.font(weight: .semibold))
            .foregroundStyle(ink)
            .textCase(.uppercase)
            .tracking(metrics.tracking)
            .lineLimit(1)
            .fixedSize()
    }

    private var row: some View {
        HStack(spacing: metrics.dot * 0.65) {
            glyph
            titleText
            if let detail, detailYields {
                // All of it, a readable start of it, or none: cut to its first letter it says nothing.
                ViewThatFits(in: .horizontal) {
                    detailText(detail).fixedSize()
                    detailText(detail).frame(minWidth: metrics.size * 7, idealWidth: metrics.size * 7, maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else if let detail {
                detailText(detail).layoutPriority(-1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailText(_ detail: String) -> some View {
        Text("· \(detail)")
            .font(metrics.font(weight: .regular, plus: 0.5))
            .foregroundStyle(detailIsWarning ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .recording:
            Circle().fill(DaybookPalette.Ink.record).frame(width: metrics.dot, height: metrics.dot)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
        case .saved:
            // Drawn on as it lands (a fade under Reduce Motion); the title says it for VoiceOver.
            DoneMark(size: metrics.textStyle == nil ? metrics.size + 1 : touchGlyph)
                .accessibilityHidden(true)
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
