import DaybookCore
import DaybookIntelligence
import Foundation
import Observation
import SwiftUI

/// The progress of this Mac's current processing job or model download. Engines report it from any
/// thread, as often as they like (a download reports per network chunk); it reaches the main actor
/// at most ten times a second, the latest value winning, in one hop. A view that reads `value`
/// redraws only when what it shows changes: the percent, the message, or the step. A report that
/// moves a bar by less than a percent is kept (`value` is always the latest) without a redraw. A
/// report that names no step (reading photos) keeps the step before it. `onChange` tells `AppState`
/// of every delivery, which renews the request's claim and tells connected iPhones.
@MainActor
@Observable
final class ActivityProgress {
    /// The latest report. Reading it follows only visible changes (`isVisibleChange`).
    var value: IntelligenceProgress {
        _ = visibleChanges
        return latest
    }
    /// The latest report, always current; reading it alone follows nothing.
    @ObservationIgnored private var latest: IntelligenceProgress
    /// Bumped when the percent, the message, or the step changes: what `value`'s readers follow.
    private var visibleChanges = 0
    /// After each change on the main actor; `visible` when the percent, message, or step changed.
    @ObservationIgnored var onChange: (_ visible: Bool) -> Void = { _ in }
    nonisolated let throttle: Throttle

    init(_ initial: IntelligenceProgress, interval: TimeInterval = 0.1) {
        latest = initial
        throttle = Throttle(interval: interval)
    }

    /// From any thread: delivered on the main actor within `interval`, coalesced with later reports.
    nonisolated func report(_ progress: IntelligenceProgress) {
        guard let delay = throttle.offer(progress) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let latest = self.throttle.take() else { return }
                self.apply(latest.continuing(self.latest.stage))
            }
        }
    }

    /// At once, on the main actor (a job starting or ending); reports still in flight are dropped.
    func set(_ progress: IntelligenceProgress) {
        throttle.discard()
        apply(progress)
    }

    /// At once, on the main actor: the work moves on to `stage` before any report from it says so (this Mac marks a
    /// conversation summarizing before its countdown). Reports still in flight from the step before are dropped.
    func enter(_ stage: ProcessingRequest.Stage) {
        set(IntelligenceProgress(latest.fraction, latest.message, stage: stage))
    }

    private func apply(_ progress: IntelligenceProgress) {
        let visible = Self.isVisibleChange(from: latest, to: progress)
        latest = progress
        if visible { visibleChanges &+= 1 }
        onChange(visible)
    }

    /// What progress views show: a whole percent, the message, and the step it names.
    nonisolated static func isVisibleChange(from old: IntelligenceProgress, to new: IntelligenceProgress) -> Bool {
        Int(new.fraction * 100) != Int(old.fraction * 100) || new.message != old.message || new.stage != old.stage
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
                pending = progress.continuing(pending?.stage)
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

/// Draws `content` in a view of its own: what it reads of a job's or a download's progress
/// (`AppState.processingProgress`, `downloadProgress`) redraws only it, never the view around it.
struct ActivityReader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

extension IntelligenceProgress {
    /// The report, in `stage` when it names none itself: the step before it goes on.
    func continuing(_ stage: ProcessingRequest.Stage?) -> IntelligenceProgress {
        self.stage != nil || stage == nil ? self : IntelligenceProgress(fraction, message, stage: stage)
    }
}
