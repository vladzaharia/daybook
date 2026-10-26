import Foundation

/// Processing one device asks for and another carries out: usually the iPhone asks and a Mac runs
/// it. A request is synced library data on its conversation (`Meeting.processingRequests`), like
/// an edit. Requests are never removed; a finished one keeps its outcome as provenance, and Try
/// Again writes a new request.
///
/// Every change is a pure function returning the changed request, or nil when the change isn't
/// allowed (someone else holds the claim, or the request already finished). Devices merge their
/// copies with `merged(_:_:)`: union by ID, a finished outcome is final, and the newest claim wins.
public struct ProcessingRequest: Codable, Equatable, Identifiable, Sendable {
    /// What to do. Raw values are stored in the library and must not change.
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Transcribe recordings that have no transcript yet, then summarize. (Transcribe)
        case newAudio
        /// Summarize again, also after choosing another template. (Summarize Again)
        case summaryOnly
        /// Identify speakers again from the saved transcript. (Identify Speakers Again)
        case speakerRefresh
        /// Transcribe every recording again. (Transcribe Everything Again)
        case fullRetranscription
        public var id: String { rawValue }
    }

    /// What a device is doing, as it last reported over sync.
    public enum Stage: String, Codable, Sendable {
        case transcribing, identifyingSpeakers, summarizing
    }

    /// A device that asks for or runs processing.
    public struct Device: Codable, Hashable, Sendable {
        /// The sync replica's ID (`LibrarySyncController.deviceID`).
        public var id: String
        /// "Alex's MacBook Pro", for "Transcribing on …".
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// A device's hold on a request, renewed while it works. When the lease runs out the claim
    /// expires and any device may take the request over; until then its holder may renew it, so
    /// a Mac that sleeps briefly keeps its work.
    public struct Claim: Codable, Equatable, Sendable {
        public var device: Device
        public var claimedAt: Date
        /// The last renewal.
        public var heartbeat: Date
        public var expiresAt: Date
        /// Coarse progress as of the heartbeat; live progress travels over the local link.
        @ExtensibleOptional public var stage: Stage?
        public var fraction: Double?

        public init(device: Device, claimedAt: Date, heartbeat: Date, expiresAt: Date, stage: Stage? = nil, fraction: Double? = nil) {
            self.device = device; self.claimedAt = claimedAt; self.heartbeat = heartbeat; self.expiresAt = expiresAt
            self.stage = stage; self.fraction = fraction
        }

        /// How long the holder granted itself: from this heartbeat to its expiry, both by the holder's clock.
        public var lease: TimeInterval { max(0, expiresAt.timeIntervalSince(heartbeat)) }

        /// Whether the lease ran out, judged by this device's clock from when it first saw this heartbeat
        /// (`ClaimObservations`), not by comparing the holder's timestamps with this clock: a device whose clock
        /// runs ahead, or a heartbeat that took minutes to arrive, can't make a live claim look expired. Only a claim
        /// whose own expiry passed `ClaimObservations.staleAfter` ago by this clock, more than any clock difference
        /// explains, expires at once.
        public func isExpired(at now: Date, observations: ClaimObservations = .shared) -> Bool {
            if expiresAt.addingTimeInterval(ClaimObservations.staleAfter) <= now { return true }
            return observations.firstSeen(self, at: now).addingTimeInterval(lease) <= now
        }
    }

    /// How a request ended. Final: a finished request is never claimed again.
    public struct Outcome: Codable, Equatable, Sendable {
        public enum Result: String, Codable, Sendable { case completed, failed }
        @Extensible public var result: Result
        public var device: Device
        public var finishedAt: Date
        /// The device's reason, for a failure.
        public var message: String?

        public init(result: Result, device: Device, finishedAt: Date, message: String? = nil) {
            self.result = result; self.device = device; self.finishedAt = finishedAt; self.message = message
        }
    }

    /// How long a claim lasts without a renewal.
    public static let defaultLease: TimeInterval = 10 * 60

    public var id: UUID
    public var meetingID: UUID
    @Extensible public var mode: Mode
    /// The template to summarize with; nil uses the conversation's own choice.
    public var templateID: String?
    public var requestedBy: Device
    public var createdAt: Date
    public var claim: Claim?
    public var outcome: Outcome?

    /// A new, open request.
    public init(id: UUID = UUID(), meetingID: UUID, mode: Mode, templateID: String? = nil, requestedBy: Device,
                createdAt: Date = Date(), claim: Claim? = nil, outcome: Outcome? = nil) {
        self.id = id; self.meetingID = meetingID; self.mode = mode; self.templateID = templateID
        self.requestedBy = requestedBy; self.createdAt = createdAt; self.claim = claim; self.outcome = outcome
    }

    // MARK: State

    /// Not finished yet.
    public var isOpen: Bool { outcome == nil }

    /// This version knows what was asked. A request from a newer Daybook (a mode this one doesn't
    /// know) waits for a device that does: it's never claimed or finished here.
    public var isUnderstood: Bool { $mode.isKnown }

    /// The claim, while its lease lasts.
    public func activeClaim(at now: Date, observations: ClaimObservations = .shared) -> Claim? {
        guard isOpen, let claim, !claim.isExpired(at: now, observations: observations) else { return nil }
        return claim
    }

    /// Open, and unclaimed, claimed by this device, or claimed by one whose lease ran out.
    public func isClaimable(by device: Device, at now: Date, observations: ClaimObservations = .shared) -> Bool {
        guard isOpen, isUnderstood else { return false }
        guard let holder = activeClaim(at: now, observations: observations) else { return true }
        return holder.device.id == device.id
    }

    /// Whether `device` holds a live claim, for a Mac checking it still owns its work after a sync.
    public func isClaimed(by device: Device, at now: Date, observations: ClaimObservations = .shared) -> Bool {
        activeClaim(at: now, observations: observations)?.device.id == device.id
    }

    // MARK: Changes

    /// Claims the request for `device`. Taking over an expired claim starts a new one that's
    /// strictly newer than it, so the takeover wins the merge even when clocks disagree. Claiming
    /// again by the holder only extends the lease.
    public func claimed(by device: Device, at now: Date, lease: TimeInterval = defaultLease,
                        observations: ClaimObservations = .shared) -> ProcessingRequest? {
        guard isClaimable(by: device, at: now, observations: observations) else { return nil }
        var copy = self
        if let current = claim, current.device.id == device.id {
            copy.claim?.heartbeat = max(now, current.heartbeat)
            copy.claim?.expiresAt = max(now.addingTimeInterval(lease), current.expiresAt)
        } else {
            let start = claim.map { max(now, $0.claimedAt.addingTimeInterval(0.001)) } ?? now
            copy.claim = Claim(device: device, claimedAt: start, heartbeat: start, expiresAt: start.addingTimeInterval(lease))
        }
        copy.claim.map { observations.record($0, at: now) }
        return copy
    }

    /// Extends the holder's lease and records its progress. Allowed after the lease ran out as
    /// long as nobody else took the request over: that's a Mac waking from sleep.
    public func renewed(by device: Device, at now: Date, lease: TimeInterval = defaultLease,
                        stage: Stage? = nil, fraction: Double? = nil, observations: ClaimObservations = .shared) -> ProcessingRequest? {
        guard isOpen, let current = claim, current.device.id == device.id else { return nil }
        var copy = self
        copy.claim?.heartbeat = max(now, current.heartbeat)
        copy.claim?.expiresAt = max(now, current.heartbeat).addingTimeInterval(lease)
        copy.claim?.stage = stage ?? current.stage
        copy.claim?.fraction = fraction.map { $0.isFinite ? min(1, max(0, $0)) : 0 } ?? current.fraction
        copy.claim.map { observations.record($0, at: now) }
        return copy
    }

    /// Gives the request back (paused, cancelled, or this device can't run it): the claim expires
    /// now and any device may take it.
    public func released(by device: Device, at now: Date) -> ProcessingRequest? {
        guard isOpen, let current = claim, current.device.id == device.id else { return nil }
        var copy = self
        let heartbeat = max(now, current.heartbeat)
        copy.claim?.heartbeat = heartbeat
        copy.claim?.expiresAt = min(current.expiresAt, heartbeat)
        return copy
    }

    /// Drops a claim whose lease ran out by `now`, so the request reads as waiting again. Nil when
    /// there's nothing to expire. Devices that still hold the old claim keep it until they merge,
    /// where it is just as reclaimable.
    public func expired(at now: Date, observations: ClaimObservations = .shared) -> ProcessingRequest? {
        guard isOpen, let claim, claim.isExpired(at: now, observations: observations) else { return nil }
        var copy = self
        copy.claim = nil
        return copy
    }

    /// The work is done. Only refused while another device holds a live claim.
    public func completed(by device: Device, at now: Date, observations: ClaimObservations = .shared) -> ProcessingRequest? {
        finished(.completed, by: device, at: now, message: nil, observations: observations)
    }

    /// The work couldn't finish; `reason` is shown with Try Again.
    public func failed(by device: Device, at now: Date, reason: String, observations: ClaimObservations = .shared) -> ProcessingRequest? {
        finished(.failed, by: device, at: now, message: reason, observations: observations)
    }

    private func finished(_ result: Outcome.Result, by device: Device, at now: Date, message: String?,
                          observations: ClaimObservations) -> ProcessingRequest? {
        guard isClaimable(by: device, at: now, observations: observations) else { return nil }
        var copy = self
        copy.outcome = Outcome(result: result, device: device, finishedAt: now, message: message)
        return copy
    }

    // MARK: Merging

    /// Two devices' copies of a conversation's requests: every request either has, by ID. For the
    /// same request a finished outcome is final (the later one if both finished), and the newest
    /// claim wins: the later start, then the later heartbeat.
    public static func merged(_ lhs: [ProcessingRequest]?, _ rhs: [ProcessingRequest]?) -> [ProcessingRequest]? {
        guard lhs != nil || rhs != nil else { return nil }
        var byID: [UUID: ProcessingRequest] = [:]
        for request in (lhs ?? []) + (rhs ?? []) {
            byID[request.id] = byID[request.id].map { merge($0, request) } ?? request
        }
        let merged = byID.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        return merged.isEmpty ? nil : merged
    }

    static func merge(_ a: ProcessingRequest, _ b: ProcessingRequest) -> ProcessingRequest {
        // What was asked never changes; should copies disagree, both devices pick the same one.
        var result = a.request == b.request ? a : (SyncEncoding.string(a.request) <= SyncEncoding.string(b.request) ? a : b)
        result.claim = newer(a.claim, b.claim)
        switch (a.outcome, b.outcome) {
        case let (x?, y?): result.outcome = order(x) >= order(y) ? x : y
        case let (x?, nil), let (nil, x?): result.outcome = x
        case (nil, nil): result.outcome = nil
        }
        return result
    }

    private static func newer(_ a: Claim?, _ b: Claim?) -> Claim? {
        guard let a else { return b }
        guard let b else { return a }
        func key(_ claim: Claim) -> (Date, Date, Date, String) { (claim.claimedAt, claim.heartbeat, claim.expiresAt, claim.device.id) }
        if key(a) == key(b) { return SyncEncoding.string(a) >= SyncEncoding.string(b) ? a : b }
        return key(a) > key(b) ? a : b
    }

    private static func order(_ outcome: Outcome) -> (Date, String, String, String) {
        (outcome.finishedAt, outcome.result.rawValue, outcome.device.id, outcome.message ?? "")
    }

    /// The parts fixed when the request was made.
    private var request: Asked { Asked(id: id, meetingID: meetingID, mode: mode, templateID: templateID, requestedBy: requestedBy, createdAt: createdAt) }
    private struct Asked: Codable, Equatable {
        var id: UUID
        var meetingID: UUID
        @Extensible var mode: Mode
        var templateID: String?
        var requestedBy: Device
        var createdAt: Date
    }
}

/// When this device first saw each claim's heartbeat, by its own clock. Leases are judged from these moments
/// (`Claim.isExpired`), so another device's clock never decides when a claim expires here. One per process is one
/// per device (`shared`); tests give each simulated device its own. Kept in memory: after a relaunch a claim gets one
/// more lease, which is the safe direction.
public final class ClaimObservations: @unchecked Sendable {
    public static let shared = ClaimObservations()
    /// A claim whose holder's own expiry is this far behind this device's clock is stale whatever was observed.
    public static let staleAfter: TimeInterval = 30 * 60
    private struct Key: Hashable { var device: String; var claimedAt: Date; var heartbeat: Date; var expiresAt: Date }
    private let lock = NSLock()
    private var seen: [Key: Date] = [:]

    public init() {}

    private static func key(_ claim: ProcessingRequest.Claim) -> Key {
        Key(device: claim.device.id, claimedAt: claim.claimedAt, heartbeat: claim.heartbeat, expiresAt: claim.expiresAt)
    }

    /// When this device first saw the claim's current heartbeat: now, the first time it's asked.
    func firstSeen(_ claim: ProcessingRequest.Claim, at now: Date) -> Date {
        lock.withLock {
            let key = Self.key(claim)
            if let date = seen[key] { return date }
            seen[key] = now
            if seen.count > 10_000 { seen = seen.filter { now.timeIntervalSince($0.value) < 86_400 } }
            return now
        }
    }

    /// A heartbeat this device just wrote itself is seen from the moment it wrote it.
    func record(_ claim: ProcessingRequest.Claim, at now: Date) {
        lock.withLock {
            let key = Self.key(claim)
            seen[key] = min(seen[key] ?? now, now)
        }
    }
}

extension Meeting {
    /// Requests not finished yet, oldest first.
    public var openProcessingRequests: [ProcessingRequest] { (processingRequests ?? []).filter(\.isOpen) }

    /// Adds or replaces a request by ID.
    public mutating func upsertProcessingRequest(_ request: ProcessingRequest) {
        var requests = processingRequests ?? []
        if let index = requests.firstIndex(where: { $0.id == request.id }) { requests[index] = request } else { requests.append(request) }
        processingRequests = requests
    }
}
