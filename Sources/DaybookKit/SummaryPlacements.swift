import Combine
import DaybookCore
import Foundation

/// The summaries this device is placing, one `SummaryPlacementPlanner` per conversation, with the countdowns'
/// timer (docs/multipoint.md, "Where summaries run"). What this device can offer (`options`) and the person's
/// preferences are the same for every conversation, so a change to either reaches every countdown at once.
///
/// When a conversation settles (it started somewhere, or there's nowhere to run it but a Mac that isn't here),
/// `onSettled` says so and the app acts: runs it here or in the cloud, or writes the request a Mac carries
/// out. A caller that would rather wait for the answer uses `place(_:immediately:)`. The entry stays until
/// the app ends it, so the status can say "Summarizing with Claude Sonnet 5.5" while the cloud works.
@MainActor
public final class SummaryPlacements: ObservableObject {
    @Published public private(set) var planners: [UUID: SummaryPlacementPlanner] = [:]
    public private(set) var options: SummaryOptions
    public private(set) var preferences: CloudSummaryPreferences
    /// This device isn't a Mac: it may wait for one.
    public let waitsForMacs: Bool
    /// A conversation started somewhere, or waits with nowhere to run it (`.waiting`).
    public var onSettled: ((UUID, SummaryPlacementPlanner.Phase) -> Void)?
    /// Any planner changed in a way worth telling another device (a countdown began, retargeted, or ended).
    public var onChange: ((UUID) -> Void)?

    private let clock: () -> Date
    private let runsTimer: Bool
    private var timer: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<SummaryPlace?, Never>] = [:]

    /// `runsTimer: false` leaves the countdowns to `advance()`, for tests with a clock of their own.
    public init(options: SummaryOptions = SummaryOptions(thisDeviceCanSummarize: false, reachableMacs: [], cloud: nil),
                preferences: CloudSummaryPreferences = CloudSummaryPreferences(), waitsForMacs: Bool,
                clock: @escaping () -> Date = Date.init, runsTimer: Bool = true) {
        self.options = options
        self.preferences = preferences
        self.waitsForMacs = waitsForMacs
        self.clock = clock
        self.runsTimer = runsTimer
    }

    public subscript(id: UUID) -> SummaryPlacementPlanner? { planners[id] }

    /// The conversations counting down or waiting for a Mac: the ones a person can still choose for.
    public var undecided: [UUID] {
        planners.filter { if case .countingDown = $0.value.phase { return true }; return $0.value.phase == .waitingForMac }.map(\.key)
    }

    // MARK: Starting

    /// A conversation's summary is due (or, `immediately`, asked for). Returns where it started, when it
    /// did at once. A conversation already being placed keeps its planner, except that being asked for
    /// starts its countdown's default now.
    @discardableResult
    public func begin(_ id: UUID, immediately: Bool = false) -> SummaryPlace? {
        if var existing = planners[id] {
            if immediately, existing.perform(.startNow, at: clock()) { set(id, existing) }
            return existing.started
        }
        let planner = SummaryPlacementPlanner(options: options, preferences: preferences, at: clock(),
                                              immediately: immediately, waitsForMacs: waitsForMacs)
        set(id, planner)
        return planner.started
    }

    /// Begins placing and waits until it has started somewhere: the place, or nil when it was ended first
    /// (cancelled, paused, or it settled with nowhere to run it). Cancelling the waiting task ends it.
    public func place(_ id: UUID, immediately: Bool = false) async -> SummaryPlace? {
        if let started = begin(id, immediately: immediately) { return started }
        guard planners[id] != nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil); return }
                if let started = planners[id]?.started { continuation.resume(returning: started); return }
                waiters[id]?.resume(returning: nil)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(id) }
        }
    }

    // MARK: Changes

    /// The person chose. False when it doesn't apply now.
    @discardableResult
    public func perform(_ action: SummaryPlacementPlanner.Action, for id: UUID) -> Bool {
        guard var planner = planners[id], planner.perform(action, at: clock()) else { return false }
        set(id, planner)
        return true
    }

    /// What this device offers, or the preferences, changed: every conversation being placed follows.
    public func update(options: SummaryOptions? = nil, preferences: CloudSummaryPreferences? = nil) {
        if let options { self.options = options }
        if let preferences { self.preferences = preferences }
        let now = clock()
        for (id, planner) in planners {
            var changed = planner
            changed.update(options: options, preferences: preferences, at: now)
            if changed != planner { set(id, changed) }
        }
    }

    /// Countdowns that ran out start their default.
    public func advance() {
        let now = clock()
        for (id, planner) in planners {
            var changed = planner
            changed.advance(to: now)
            if changed != planner { set(id, changed) }
        }
        scheduleTimer()
    }

    /// Every countdown's default happens now, as when the app leaves the screen (the iPhone can't keep a
    /// timer in the background).
    public func startDefaultsNow() {
        for (id, planner) in planners {
            var changed = planner
            changed.perform(.startNow, at: clock())
            if changed != planner { set(id, changed) }
        }
    }

    /// Done with a conversation: its summary finished, failed, was cancelled, or it was handed to a Mac. A
    /// caller still waiting in `place` gets nil.
    public func end(_ id: UUID) {
        let had = planners.removeValue(forKey: id) != nil
        waiters.removeValue(forKey: id)?.resume(returning: nil)
        if had { onChange?(id) }
        scheduleTimer()
    }

    // MARK: Internals

    private func set(_ id: UUID, _ planner: SummaryPlacementPlanner) {
        let before = planners[id]
        planners[id] = planner
        if before?.phase != planner.phase || before?.actions != planner.actions { onChange?(id) }
        switch planner.phase {
        case .started(let place):
            if before?.started == nil {
                waiters.removeValue(forKey: id)?.resume(returning: place)
                onSettled?(id, planner.phase)
            }
        case .waiting:
            if before?.phase != .waiting {
                waiters.removeValue(forKey: id)?.resume(returning: nil)
                onSettled?(id, planner.phase)
            }
        case .countingDown, .waitingForMac:
            break
        }
        scheduleTimer()
    }

    /// One timer, for the countdown that runs out first.
    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        guard runsTimer, let next = planners.values.compactMap(\.deadline).min() else { return }
        let delay = max(0, next.timeIntervalSince(clock()))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 20))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
