import Observation
import SwiftUI

/// The last few seconds of one input's level, oldest first, for a `RollingLevelMeter`. Fed about
/// fifteen times a second; only the meters that read it redraw.
@MainActor
@Observable
public final class LevelTrail {
    /// Oldest first, 0...1.
    public private(set) var values: [Double]
    public let capacity: Int

    public init(capacity: Int = 96) {
        self.capacity = max(1, capacity)
        values = Array(repeating: 0, count: max(1, capacity))
    }

    public func append(_ value: Double) {
        var next = values
        next.removeFirst(max(0, next.count - capacity + 1))
        next.append(max(0, min(1, value.isFinite ? value : 0)))
        values = next
    }

    /// A pause or a new recording: the meter falls flat.
    public func reset() {
        values = Array(repeating: 0, count: capacity)
    }
}

/// The last few seconds of input as mirrored teal bars, newest on the right, older bars fading so
/// the eye goes to now. Flat and grey while paused. Under Reduce Motion it doesn't scroll: the same
/// bars light from the left to the current level.
public struct RollingLevelMeter: View {
    public struct Metrics: Equatable, Sendable {
        public var barWidth: CGFloat
        public var gap: CGFloat
        public init(barWidth: CGFloat = 3, gap: CGFloat = 2.5) {
            self.barWidth = barWidth
            self.gap = gap
        }
        /// The iPhone's recording surfaces.
        public static let phone = Metrics()
        /// Floating Notes: finer bars for a short meter.
        public static let panel = Metrics(barWidth: 2, gap: 2)
    }

    private let source: Source
    private let isLive: Bool
    private let metrics: Metrics
    private let tint: Color
    private let label: String

    private enum Source {
        case trail(LevelTrail)
        case values([Double])
    }

    /// Reads the trail itself, so only the meter redraws as levels arrive.
    public init(trail: LevelTrail, isLive: Bool, metrics: Metrics = .phone, tint: Color = DaybookPalette.accent,
                accessibilityLabel: String = "Input level") {
        source = .trail(trail)
        self.isLive = isLive
        self.metrics = metrics
        self.tint = tint
        label = accessibilityLabel
    }

    public init(values: [Double], isLive: Bool, metrics: Metrics = .phone, tint: Color = DaybookPalette.accent,
                accessibilityLabel: String = "Input level") {
        source = .values(values)
        self.isLive = isLive
        self.metrics = metrics
        self.tint = tint
        label = accessibilityLabel
    }

    public var body: some View {
        let values: [Double]
        switch source {
        case .trail(let trail): values = trail.values
        case .values(let given): values = given
        }
        return MeterCanvas(values: values, isLive: isLive, metrics: metrics, tint: tint)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isLive ? "\(Int((values.last ?? 0) * 100)) percent" : "Paused")
    }
}

private struct MeterCanvas: View {
    let values: [Double]
    let isLive: Bool
    let metrics: RollingLevelMeter.Metrics
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let resting = Color.platformTertiaryLabel.opacity(contrast == .increased ? 0.8 : 0.5)
        Canvas { context, size in
            let step = metrics.barWidth + metrics.gap
            let count = max(1, Int((size.width + metrics.gap) / step))
            let radius = metrics.barWidth / 2
            if reduceMotion {
                // Still bars, lit from the left up to the newest level.
                let level = isLive ? pow(values.last ?? 0, 0.8) : 0
                let lit = Int((Double(count) * level).rounded())
                for index in 0..<count {
                    let rect = CGRect(x: CGFloat(index) * step, y: size.height * 0.2, width: metrics.barWidth, height: size.height * 0.6)
                    let color = index < lit ? tint : resting
                    context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
                }
                return
            }
            let shown = values.suffix(count)
            let start = size.width - CGFloat(shown.count) * step + metrics.gap
            for (index, value) in shown.enumerated() {
                let shaped = pow(value, 1.6)
                let bar = max(metrics.barWidth, CGFloat(shaped) * size.height)
                let rect = CGRect(x: start + CGFloat(index) * step, y: (size.height - bar) / 2, width: metrics.barWidth, height: bar)
                // Older bars fade a little, so the eye goes to now.
                let age = Double(index) / Double(max(1, shown.count - 1))
                let color = isLive ? tint.opacity(contrast == .increased ? 0.6 + 0.4 * age : 0.35 + 0.65 * age) : resting
                context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
            }
        }
    }
}
