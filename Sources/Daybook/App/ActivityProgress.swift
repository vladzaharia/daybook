import DaybookCore
import DaybookIntelligence
import Foundation
import SwiftUI

/// The progress of this Mac's current processing job or model download. Engines report it from any
/// thread, as often as they like (a download reports per network chunk); it reaches the main actor
/// at most ten times a second, the latest value winning, in one hop. Views that draw it observe this
/// object (`ActivityReader`), so nothing else in the window redraws, and they redraw only when what
/// they show changes: the percent, the message, or the step. A report that moves a bar by less than
/// a percent is kept (`value` is always the latest) without a redraw. A report that names no step
/// (reading photos) keeps the step before it. `onChange` tells `AppState` of every delivery, which
/// renews the request's claim and tells connected iPhones.
@MainActor
final class ActivityProgress: ObservableObject {
    /// Never reports: what a view observes when the activity it would show isn't its own (a list row
    /// that isn't being processed), so it keeps its identity without redrawing at progress pace.
    static let idle = ActivityProgress(IntelligenceProgress(0, ""))

    /// The latest report. Setting it publishes only a visible change (`isVisibleChange`).
    private(set) var value: IntelligenceProgress
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
                self.apply(latest.continuing(self.value.stage))
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
        set(IntelligenceProgress(value.fraction, value.message, stage: stage))
    }

    private func apply(_ progress: IntelligenceProgress) {
        let visible = Self.isVisibleChange(from: value, to: progress)
        if visible { objectWillChange.send() }
        value = progress
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

/// Draws `content` again whenever the activities report, without redrawing anything around it: a
/// progress bar, a percentage, a status line that names the stage.
struct ActivityReader<Content: View>: View {
    @ObservedObject var processing: ActivityProgress
    @ObservedObject var download: ActivityProgress
    @ViewBuilder var content: () -> Content

    /// An activity left out is one that never moves (`ActivityProgress.idle`).
    @MainActor
    init(processing: ActivityProgress? = nil, download: ActivityProgress? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.processing = processing ?? .idle
        self.download = download ?? .idle
        self.content = content
    }

    var body: some View { content() }
}

extension IntelligenceProgress {
    /// The report, in `stage` when it names none itself: the step before it goes on.
    func continuing(_ stage: ProcessingRequest.Stage?) -> IntelligenceProgress {
        self.stage != nil || stage == nil ? self : IntelligenceProgress(fraction, message, stage: stage)
    }
}
