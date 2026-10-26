import DaybookIntelligence
import Foundation

/// The progress of this Mac's current processing job or model download. Engines report it from any
/// thread, as often as they like (a download reports per network chunk); it reaches the main actor
/// at most ten times a second, the latest value winning, in one hop. Views that draw it can observe
/// this object; `onChange` tells `AppState`, which republishes only when the whole percent or the
/// message changes, so the rest of the window isn't redrawn for every report.
@MainActor
final class ActivityProgress: ObservableObject {
    @Published private(set) var value: IntelligenceProgress
    /// After each change on the main actor; `visible` when the percent or message changed.
    var onChange: (_ visible: Bool) -> Void = { _ in }
    nonisolated let throttle: Throttle

    init(_ initial: IntelligenceProgress, interval: TimeInterval = 0.1) {
        value = initial
        throttle = Throttle(interval: interval)
    }

    /// From any thread: delivered on the main actor within `interval`, coalesced with later reports.
    nonisolated func report(_ progress: IntelligenceProgress) {
        guard let delay = throttle.offer(progress) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let latest = self.throttle.take() else { return }
                self.apply(latest)
            }
        }
    }

    /// At once, on the main actor (a job starting or ending); reports still in flight are dropped.
    func set(_ progress: IntelligenceProgress) {
        throttle.discard()
        apply(progress)
    }

    private func apply(_ progress: IntelligenceProgress) {
        let visible = Int(progress.fraction * 100) != Int(value.fraction * 100) || progress.message != value.message
        value = progress
        onChange(visible)
    }

    /// The latest report and whether a delivery is already on its way.
    final class Throttle: @unchecked Sendable {
        private let lock = NSLock()
        private let interval: TimeInterval
        private var pending: IntelligenceProgress?
        private var scheduled = false
        private var lastDelivery = Date.distantPast

        init(interval: TimeInterval) { self.interval = interval }

        /// Keeps `progress` as the latest; returns the delay to schedule a delivery after, or nil
        /// when one is already scheduled.
        func offer(_ progress: IntelligenceProgress) -> TimeInterval? {
            lock.withLock {
                pending = progress
                guard !scheduled else { return nil }
                scheduled = true
                return max(0, interval - Date().timeIntervalSince(lastDelivery))
            }
        }

        func take() -> IntelligenceProgress? {
            lock.withLock {
                defer { pending = nil; scheduled = false; lastDelivery = Date() }
                return pending
            }
        }

        func discard() { lock.withLock { pending = nil } }
    }
}
