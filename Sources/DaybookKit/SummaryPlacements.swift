import DaybookCore
import Foundation
import Observation

/// The summaries this device is placing, one `SummaryPlacementPlanner` per conversation, with the countdowns'
/// timer (docs/multipoint.md, "Where summaries run"). What this device can offer (`options`) and the person's
/// preferences are the same for every conversation, so a change to either reaches every countdown at once.
///
/// When a conversation settles (it started somewhere, or there's nowhere to run it but a Mac that isn't here),
/// `onSettled` says so and the app acts: runs it here or in the cloud, or writes the request a Mac carries
/// out. A caller that would rather wait for the answer uses `place(_:immediately:)`. The entry stays until
/// the app ends it, so the status can say "Summarizing with Claude Sonnet 5.5" while the cloud works.
///
/// What the planner needs of each conversation (`SummaryPlacementPlanner.Conversation`: whether its placement lets it go
/// to the cloud) is asked of the app (`conversation`) as its planner begins and whenever anything changes, so a
/// conversation moved to Personal, or a switch turned off, mid-countdown loses the cloud at once.
@MainActor
@Observable
public final class SummaryPlacements {
    public private(set) var planners: [UUID: SummaryPlacementPlanner] = [:]
    public private(set) var options: SummaryOptions
    public private(set) var preferences: CloudSummaryPreferences
    /// This device isn't a Mac: it may wait for one.
    public let waitsForMacs: Bool
    /// A conversation started somewhere, or waits with nowhere to run it (`.waiting`).
    @ObservationIgnored public var onSettled: ((UUID, SummaryPlacementPlanner.Phase) -> Void)?
    /// Any planner changed in a way worth telling another device (a countdown began, retargeted, or ended).
    @ObservationIgnored public var onChange: ((UUID) -> Void)?
    /// What the planner needs of a conversation, from the app's library and Settings › Cloud (`CloudPlacements`), given
    /// what this device offers now.
    @ObservationIgnored public var conversation: (UUID, SummaryOptions) -> SummaryPlacementPlanner.Conversation = { _, _ in .init() }
    /// The person can see this device's countdowns now (docs/cloud.md, "When the cloud is chosen"): on the Mac, the session
    /// is unlocked and a Daybook window that shows them is on the screen (`AppState.countdownsVisible`); on the iPhone,
    /// Daybook is active on the screen (`PhoneSummaryPlacement.isOnScreen`). A countdown that ends in the cloud runs only
    /// while it's seen: unseen, it runs where it would have without the cloud (Don't Use the Cloud; after a failure here,
    /// nowhere), and it never goes back to the cloud on its own. Seen until the app says otherwise.
    public var countdownsAreSeen = true {
        didSet { if !countdownsAreSeen { keepUnseenOffTheCloud() } }
    }

    private let clock: () -> Date
    private let runsTimer: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<SummaryPlace?, Never>] = [:]

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
    /// starts its countdown's default now. A countdown that ends in the cloud goes on unchanged, whatever asked (Summarize
    /// Again, a template, Try Again, another device's request): only Start Now on that countdown, where it's seen, starts it
    /// early.
    @discardableResult
    public func begin(_ id: UUID, immediately: Bool = false) -> SummaryPlace? {
        if var existing = planners[id] {
            if immediately, !existing.endsInCloud, existing.perform(.startNow, at: clock()) { set(id, existing) }
            return existing.started
        }
        let planner = SummaryPlacementPlanner(options: options, preferences: preferences, at: clock(),
                                              immediately: immediately, waitsForMacs: waitsForMacs, conversation: conversation(id, options))
        set(id, planner)
        return planners[id]?.started
    }

    /// A summary the person asked the cloud for (an "Upgrade" to the cloud's better model, docs/multipoint.md): it starts
    /// there at once, with no countdown, while the cloud is on offer for it; otherwise (no key, Never, or its placement kept
    /// off the cloud) it's placed as a due one is.
    @discardableResult
    public func beginInCloud(_ id: UUID) -> SummaryPlace? {
        if planners[id] != nil {
            perform(.useCloud, for: id)
            return planners[id]?.started
        }
        var planner = SummaryPlacementPlanner(options: options, preferences: preferences, at: clock(), waitsForMacs: waitsForMacs,
                                              conversation: conversation(id, options))
        planner.perform(.useCloud, at: clock())
        set(id, planner)
        return planners[id]?.started
    }

    /// The summary on this device failed: the cloud is tried before the work fails, as the rules for this conversation allow
    /// (`SummaryPlacementPlanner.Conversation.localFailed`): at once under Always, after a countdown to it under Offer First
    /// (with Don't Use the Cloud), never without the cloud on offer for it. Returns where it started, when it did at once;
    /// a planner that settles `.waiting` means the cloud won't be tried. Any planner the conversation had is replaced.
    @discardableResult
    public func beginAfterLocalFailure(_ id: UUID) -> SummaryPlace? {
        planners.removeValue(forKey: id)
        var conversation = conversation(id, options)
        conversation.localFailed = true
        let planner = SummaryPlacementPlanner(options: options, preferences: preferences, at: clock(), waitsForMacs: waitsForMacs,
                                              conversation: conversation)
        set(id, planner)
        return planners[id]?.started
    }

    /// A summary the person asked to run on this device (Summarize on This Mac, after the cloud couldn't): it starts
    /// here at once, whatever the cloud preferences say. Nil, and nothing placed, when this device can't summarize.
    @discardableResult
    public func beginHere(_ id: UUID) -> SummaryPlace? {
        guard options.thisDeviceCanSummarize else { return nil }
        let here = SummaryOptions(thisDeviceCanSummarize: true, reachableMacs: [], cloud: nil)
        let planner = SummaryPlacementPlanner(options: here, preferences: preferences, at: clock(), immediately: true,
                                              waitsForMacs: waitsForMacs, conversation: conversation(id, here))
        set(id, planner)
        return planners[id]?.started
    }

    /// Begins placing and waits until it has started somewhere: the place, or nil when it was ended first
    /// (cancelled, paused, or it settled with nowhere to run it). Cancelling the waiting task ends it.
    public func place(_ id: UUID, immediately: Bool = false) async -> SummaryPlace? {
        if let started = begin(id, immediately: immediately) { return started }
        // Already settled with nowhere to run it (a retry after a failure the cloud can't take): nothing to wait for.
        guard let planner = planners[id], planner.phase != .waiting else { return nil }
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

    /// What this device offers, the preferences, or a conversation (its placement) changed: every conversation being
    /// placed follows, its own state asked again (`conversation`).
    public func update(options: SummaryOptions? = nil, preferences: CloudSummaryPreferences? = nil) {
        if let options { self.options = options }
        if let preferences { self.preferences = preferences }
        let now = clock()
        for (id, planner) in planners {
            var changed = planner
            var asked = conversation(id, self.options)
            asked.localFailed = planner.conversation.localFailed
            changed.update(options: options, preferences: preferences, conversation: asked, at: now)
            if changed != planner { set(id, changed) }
        }
    }

    /// Countdowns that ran out start their default; one that ends in the cloud, only while it's seen.
    public func advance() {
        let now = clock()
        for (id, planner) in planners {
            var changed = planner
            if !countdownsAreSeen, changed.endsInCloud { changed.perform(.useLocal, at: now) } else { changed.advance(to: now) }
            if changed != planner { set(id, changed) }
        }
        scheduleTimer()
    }

    /// Every countdown's default happens now, as when the app leaves the screen (the iPhone can't keep a
    /// timer in the background), except that one ending in the cloud doesn't go there: it was never seen to its end, and
    /// the cloud is never used without its countdown, so it runs where it would have without the cloud (Don't Use the
    /// Cloud; after a failure here, nowhere).
    public func startDefaultsNow() {
        for (id, planner) in planners {
            var changed = planner
            if case .countingDown(.cloud, _) = planner.phase { changed.perform(.useLocal, at: clock()) }
            else { changed.perform(.startNow, at: clock()) }
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

    /// Nobody can see the countdowns: each one that ends in the cloud runs where it would have without the cloud.
    private func keepUnseenOffTheCloud() {
        for (id, planner) in planners where planner.endsInCloud { set(id, planner) }
    }

    // MARK: Internals

    private func set(_ id: UUID, _ planner: SummaryPlacementPlanner) {
        var planner = planner
        // A countdown that comes to end in the cloud while nobody can see it (begun, retargeted, or after a failure here)
        // never runs there.
        if !countdownsAreSeen, planner.endsInCloud { planner.perform(.useLocal, at: clock()) }
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
