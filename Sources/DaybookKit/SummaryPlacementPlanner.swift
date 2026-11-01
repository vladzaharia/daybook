import DaybookCore
import Foundation

/// Where one conversation's summary runs, and the countdown that lets the person choose the cloud first
/// (docs/multipoint.md, "Where summaries run").
///
/// - With a cloud model on offer (a key, and the policy isn't Never), a summary that's due counts down
///   (15 s, or the setting) to its default: this device when it can summarize, else a Mac that can and is
///   reachable. Use the Cloud, Start Now, and, on a device that isn't a Mac, Wait for a Mac.
/// - With nowhere to run it but the cloud, it waits for a Mac, with Use the Cloud, and counts down once a
///   Mac is reachable.
/// - Always skips the countdown for the cloud. Without a cloud model on offer there's nothing to choose,
///   so it starts at once where it can, or waits as before.
/// - Asked for by the person or another device, it starts at once (`immediately`).
///
/// Pure: every change takes the time, so tests drive it with a clock of their own.
public struct SummaryPlacementPlanner: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Counting down to this device or a Mac; when the time runs out, the summary starts there.
        case countingDown(to: SummaryPlace, until: Date)
        /// Nothing here or on a reachable Mac can summarize it, and the cloud is on offer: it waits for a Mac.
        case waitingForMac
        /// Started: here, sent to a Mac, or in the cloud. Nothing changes it after this.
        case started(SummaryPlace)
        /// Nowhere to run it: nothing here, no Mac, no cloud. It waits for a Mac, as before there was a cloud.
        case waiting
    }

    /// What the person can do while it counts down or waits.
    public enum Action: String, CaseIterable, Equatable, Sendable {
        case useCloud, startNow, waitForMac

        /// The button's title.
        public var title: String {
            switch self {
            case .useCloud: return "Use the Cloud"
            case .startNow: return "Start Now"
            case .waitForMac: return "Wait for a Mac"
            }
        }
    }

    public private(set) var phase: Phase
    public private(set) var options: SummaryOptions
    public private(set) var preferences: CloudSummaryPreferences
    /// Started at once, wherever it can run: asked for, not just due.
    public let immediately: Bool
    /// This device isn't a Mac, so it may wait for one instead of summarizing itself.
    public let waitsForMacs: Bool
    /// The person chose Wait for a Mac: this device's own summarizer is passed over from then on.
    public private(set) var prefersMac = false

    public init(options: SummaryOptions, preferences: CloudSummaryPreferences, at now: Date,
                immediately: Bool = false, waitsForMacs: Bool = false) {
        self.options = options
        self.preferences = preferences
        self.immediately = immediately
        self.waitsForMacs = waitsForMacs
        phase = .waiting
        phase = plan(at: now)
    }

    // MARK: Reading

    /// The cloud model on offer: one the preferences resolve to, unless the policy is Never.
    public var cloud: CloudModel? { preferences.policy == .never ? nil : options.cloud }

    /// How long a countdown lasts: the setting (15 or 30 s), never less than a second.
    public var countdown: TimeInterval { TimeInterval(max(1, preferences.countdownSeconds)) }

    /// Where it started, once it has.
    public var started: SummaryPlace? {
        if case .started(let place) = phase { return place }
        return nil
    }

    /// When the countdown runs out.
    public var deadline: Date? {
        if case .countingDown(_, let until) = phase { return until }
        return nil
    }

    /// Whole seconds left in the countdown, rounded up: "in 12 s".
    public func secondsLeft(at now: Date) -> Int? {
        deadline.map { max(1, Int(($0.timeIntervalSince(now)).rounded(.up))) }
    }

    /// What the person can do now, in the order they're shown.
    public var actions: [Action] {
        switch phase {
        case .countingDown(let place, _):
            var actions: [Action] = cloud == nil ? [] : [.useCloud]
            actions.append(.startNow)
            if waitsForMacs, place == .thisDevice { actions.append(.waitForMac) }
            return actions
        case .waitingForMac:
            return cloud == nil ? [] : [.useCloud]
        case .started, .waiting:
            return []
        }
    }

    // MARK: Changes

    /// The person's choice. False when it doesn't apply now (nothing changes).
    @discardableResult
    public mutating func perform(_ action: Action, at now: Date) -> Bool {
        guard actions.contains(action) else { return false }
        switch action {
        case .useCloud:
            guard let cloud else { return false }
            phase = .started(.cloud(cloud))
        case .startNow:
            guard case .countingDown(let place, _) = phase else { return false }
            phase = .started(place)
        case .waitForMac:
            prefersMac = true
            // The person chose a Mac: one that's reachable gets it now; otherwise it waits for one.
            if let mac = options.reachableMacs.first { phase = .started(.mac(id: mac.id, name: mac.name)) }
            else { phase = cloud == nil ? .waiting : .waitingForMac }
        }
        return true
    }

    /// The countdown ran out: the default starts.
    public mutating func advance(to now: Date) {
        if case .countingDown(let place, let until) = phase, now >= until { phase = .started(place) }
    }

    /// What this device can offer changed: a Mac came or went, a key was added or removed, this device
    /// stopped (or started) being able to summarize, or the person changed the preferences. A countdown
    /// keeps its deadline when its target changes; one whose reason to wait went (no cloud on offer) starts
    /// now. Waiting turns into a fresh countdown when somewhere to run it appears. Started is final.
    public mutating func update(options: SummaryOptions? = nil, preferences: CloudSummaryPreferences? = nil, at now: Date) {
        if let options { self.options = options }
        if let preferences { self.preferences = preferences }
        switch phase {
        case .started:
            return
        case .countingDown(let place, let until):
            if self.preferences.policy == .always, let cloud {
                phase = .started(.cloud(cloud))
                return
            }
            let target = defaultPlace
            if cloud == nil {
                // Nothing to choose between any more: the default starts now, or it waits.
                phase = target.map { .started($0) } ?? .waiting
            } else if let target {
                // A countdown keeps its time; only where it ends up may change.
                if target != place { phase = .countingDown(to: target, until: until) }
            } else {
                phase = .waitingForMac
            }
        case .waitingForMac, .waiting:
            phase = plan(at: now)
        }
    }

    // MARK: Deciding

    /// The default: this device when it can summarize (and the person hasn't chosen a Mac), else the first
    /// reachable Mac that can.
    private var defaultPlace: SummaryPlace? {
        if options.thisDeviceCanSummarize && !prefersMac { return .thisDevice }
        return options.reachableMacs.first.map { .mac(id: $0.id, name: $0.name) }
    }

    private func plan(at now: Date) -> Phase {
        if preferences.policy == .always, let cloud { return .started(.cloud(cloud)) }
        guard let target = defaultPlace else { return cloud == nil ? .waiting : .waitingForMac }
        // Asked for, or nothing to offer instead: it starts where it can, now.
        if immediately || cloud == nil { return .started(target) }
        return .countingDown(to: target, until: now.addingTimeInterval(countdown))
    }
}

// MARK: - Words

extension SummaryPlacementPlanner {
    /// The status line, the same on both apps: "Summarizing on this Mac in 12 s", "Summarizing on Vlad's
    /// MacBook Pro in 12 s", "Waiting for a Mac to summarize", "Summarizing with Claude Sonnet 5.5". Nil when
    /// the processing status says it instead (started here or sent to a Mac, or waiting as before).
    /// `thisDevice` is how this device calls itself: "this Mac", "this iPhone".
    public func line(at now: Date, thisDevice: String) -> String? {
        switch phase {
        case .countingDown(let place, _):
            let seconds = secondsLeft(at: now) ?? 0
            return "Summarizing \(Self.where(place, thisDevice: thisDevice)) in \(seconds) s"
        case .waitingForMac:
            return "Waiting for a Mac to summarize"
        case .started(.cloud(let model)):
            return "Summarizing with \(model.name)"
        case .started, .waiting:
            return nil
        }
    }

    /// The same, short enough for a list row or a chip: "Summarizing in 12 s".
    public func shortLine(at now: Date) -> String? {
        switch phase {
        case .countingDown:
            return "Summarizing in \(secondsLeft(at: now) ?? 0) s"
        case .waitingForMac:
            return "Waiting for a Mac to summarize"
        case .started(.cloud(let model)):
            return "Summarizing with \(model.name)"
        case .started, .waiting:
            return nil
        }
    }

    /// "on this Mac", "on Vlad's MacBook Pro", "with Claude Sonnet 5.5".
    public static func `where`(_ place: SummaryPlace, thisDevice: String) -> String {
        switch place {
        case .thisDevice: return "on \(thisDevice)"
        case .mac(_, let name): return "on \(name)"
        case .cloud(let model): return "with \(model.name)"
        }
    }
}
