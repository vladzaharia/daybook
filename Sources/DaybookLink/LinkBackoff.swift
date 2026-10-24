import Foundation

/// Exponential backoff with jitter for reconnection.
public struct LinkBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    public var multiplier: Double
    /// ± this fraction of each delay, so phones that lost the Mac together don't retry together.
    public var jitter: Double

    public init(initial: TimeInterval = 0.5, maximum: TimeInterval = 30, multiplier: Double = 2, jitter: Double = 0.2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// The delay before retry number `attempt` (0 is the first retry).
    public func delay(attempt: Int, random: Double = Double.random(in: -1...1)) -> TimeInterval {
        let base = min(maximum, initial * pow(multiplier, Double(max(0, attempt))))
        return max(0, base * (1 + jitter * max(-1, min(1, random))))
    }
}
