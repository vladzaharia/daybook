import Foundation

/// Which of a writer's clock anchors a recording keeps (`ClockAnchor`). A writer takes one about every second, to judge
/// gaps against the latest; the sidecar or journal keeps every one for the first minute of each clock run (the start,
/// and after each resync), where the drift fit has least to go on, then one every ten seconds. Resyncs are always kept.
/// A 4-hour run keeps about 1,500 anchors rather than 14,400, so the sidecar rewritten during a recording stays small,
/// and the fit (`ClockDriftEstimator`) still sees the whole run.
public struct ClockAnchorSchedule: Equatable, Sendable {
    /// Every anchor is kept for this long after a run starts.
    public static let denseSpan: TimeInterval = 60
    /// After that, one about this often.
    public static let sparseInterval: TimeInterval = 10

    private var runStart: TimeInterval?
    private var lastKept: TimeInterval?

    public init() {}

    /// Whether to keep `anchor`. A writer offers each anchor it takes, in order, with a new schedule for each file.
    public mutating func keeps(_ anchor: ClockAnchor) -> Bool {
        guard let runStart, let lastKept, anchor.resync != true else {
            runStart = anchor.hostTime
            lastKept = anchor.hostTime
            return true
        }
        guard anchor.hostTime - runStart < Self.denseSpan || anchor.hostTime - lastKept >= Self.sparseInterval else { return false }
        self.lastKept = anchor.hostTime
        return true
    }
}
