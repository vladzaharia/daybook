import Foundation

/// One device's imports: one transfer at a time, the rest waiting. A disconnect puts the interrupted
/// recording back at the front and suspends the queue until the method reconnects, because
/// transfers can't resume mid-file.
public struct DeviceImportQueue: Equatable {
    public struct Item: Equatable, Identifiable {
        public let recording: DeviceRecording
        /// The method the recording comes through.
        public let method: ConnectionMethodKind
        /// The conversation to add the recording to, or nil for a new conversation.
        public var attachTo: UUID?
        /// Failed attempts so far, for the retry policy.
        public var attempts = 0
        /// Queued by automatic import rather than by the person.
        public var isAutomatic = false
        public var id: String { recording.id }

        public init(recording: DeviceRecording, method: ConnectionMethodKind, attachTo: UUID? = nil, attempts: Int = 0, isAutomatic: Bool = false) {
            self.recording = recording
            self.method = method
            self.attachTo = attachTo
            self.attempts = attempts
            self.isAutomatic = isAutomatic
        }
    }

    public private(set) var current: Item?
    public private(set) var waiting: [Item] = []
    /// Finished in this batch.
    public private(set) var imported = 0
    /// Failed in this batch.
    public private(set) var failed = 0
    /// Waiting for the method to reconnect.
    public private(set) var isSuspended = false

    public var isActive: Bool { current != nil || !waiting.isEmpty }
    /// Everything in this batch, done or not, for "Importing 1 of 3".
    public var total: Int { imported + failed + (current == nil ? 0 : 1) + waiting.count }
    /// The 1-based position of the current recording in the batch.
    public var position: Int { min(total, imported + failed + 1) }
    public var ids: [String] { (current.map { [$0.id] } ?? []) + waiting.map(\.id) }
    public var isAutomaticBatch: Bool { (current.map { [$0] } ?? []).allSatisfy(\.isAutomatic) && waiting.allSatisfy(\.isAutomatic) }

    public func contains(_ id: String) -> Bool { current?.id == id || waiting.contains { $0.id == id } }
    public func isWaiting(_ id: String) -> Bool { waiting.contains { $0.id == id } }

    /// Adds recordings that aren't already queued, oldest first. Returns the IDs added.
    @discardableResult
    public mutating func enqueue(_ recordings: [DeviceRecording], method: ConnectionMethodKind, attachTo: UUID? = nil,
                          automatic: Bool = false) -> [String] {
        if !isActive { imported = 0; failed = 0 }
        var added: [String] = []
        let ordered = recordings.sorted { ($0.sortDate ?? .distantPast, $0.id) < ($1.sortDate ?? .distantPast, $1.id) }
        for recording in ordered where !contains(recording.id) && !added.contains(recording.id) && !recording.isInProgress {
            waiting.append(Item(recording: recording, method: method, attachTo: attachTo, isAutomatic: automatic))
            added.append(recording.id)
        }
        return added
    }

    /// The next recording to start, without starting it.
    public var next: Item? { current == nil && !isSuspended ? waiting.first : nil }

    /// Starts the next recording when nothing is transferring and the queue isn't suspended.
    public mutating func startNext() -> Item? {
        guard current == nil, !isSuspended, !waiting.isEmpty else { return nil }
        current = waiting.removeFirst()
        return current
    }

    /// The current recording arrived and is in the library.
    public mutating func finishCurrent() {
        guard current != nil else { return }
        current = nil; imported += 1
    }

    /// The current recording failed. With `requeue` (a disconnect) it goes back to the front and the
    /// queue waits for a reconnect; otherwise it counts as failed and the queue moves on.
    public mutating func failCurrent(requeue: Bool) {
        guard let item = current else { return }
        current = nil
        if requeue { waiting.insert(item, at: 0); isSuspended = true } else { failed += 1 }
    }

    /// Puts the current recording back at the front for another attempt.
    public mutating func retryCurrent() {
        guard var item = current else { return }
        item.attempts += 1
        current = nil
        waiting.insert(item, at: 0)
    }

    /// Stops the current transfer without counting it. Returns what was stopped.
    @discardableResult
    public mutating func stopCurrent() -> Item? {
        defer { current = nil }
        return current
    }

    /// Takes a waiting recording out of the queue.
    public mutating func remove(_ id: String) { waiting.removeAll { $0.id == id } }

    /// Takes every waiting recording from one method out (that method was forgotten or turned off).
    public mutating func remove(method: ConnectionMethodKind) { waiting.removeAll { $0.method == method } }

    /// Stops everything and forgets the batch.
    public mutating func stopAll() {
        current = nil; waiting = []; imported = 0; failed = 0; isSuspended = false
    }

    public mutating func suspend() { isSuspended = true }
    public mutating func resume() { isSuspended = false }

    /// Overall progress through the batch, given the current transfer's fraction.
    public func fraction(current fraction: Double?) -> Double {
        guard total > 0 else { return 0 }
        let currentPart = current == nil ? 0 : min(1, max(0, fraction ?? 0))
        return min(1, (Double(imported + failed) + currentPart) / Double(total))
    }

    /// Bytes still to come in the batch: the rest of the current recording plus everything waiting.
    public func remainingBytes(currentReceived: UInt64) -> UInt64 {
        let size = current?.recording.byteCount ?? 0
        let currentLeft = size > currentReceived ? size - currentReceived : 0
        return currentLeft + waiting.reduce(0) { $0 + ($1.recording.byteCount ?? 0) }
    }

    public init(current: Item? = nil, waiting: [Item] = [], imported: Int = 0, failed: Int = 0, isSuspended: Bool = false) {
        self.current = current
        self.waiting = waiting
        self.imported = imported
        self.failed = failed
        self.isSuspended = isSuspended
    }
}

/// Retries: a stall or integrity failure gets one quiet retry before the person hears about it.
/// A disconnect doesn't count as an attempt; the recording waits for the reconnect.
public struct DeviceRetryPolicy: Equatable {
    public var maximumAttempts = 2

    public init(maximumAttempts: Int = 2) { self.maximumAttempts = maximumAttempts }

    public func shouldRetry(_ error: DeviceTransferError, attempts: Int) -> Bool {
        error.isRetryable && attempts + 1 < maximumAttempts
    }
}

/// Estimates time left from what has arrived so far. It says nothing until it has about ten seconds
/// of samples, so early bursts don't produce wild guesses.
public struct TransferRateEstimator: Equatable {
    public static let minimumSampleTime: TimeInterval = 10
    private var start: Date?
    private var startBytes: UInt64 = 0
    private var latest: Date?
    private var latestBytes: UInt64 = 0
    /// Bytes from transfers that already finished in this batch.
    private var carried: UInt64 = 0

    public mutating func reset() { self = TransferRateEstimator() }

    /// Records the running byte count of the current transfer.
    public mutating func record(bytes: UInt64, at date: Date) {
        if start == nil { start = date; startBytes = carried + bytes }
        latest = date; latestBytes = carried + bytes
    }

    /// Keeps the rate across recordings in the same batch.
    public mutating func transferFinished() { carried = latestBytes }

    public var bytesPerSecond: Double? {
        guard let start, let latest else { return nil }
        let elapsed = latest.timeIntervalSince(start)
        guard elapsed >= Self.minimumSampleTime, latestBytes > startBytes else { return nil }
        return Double(latestBytes - startBytes) / elapsed
    }

    public func secondsLeft(remainingBytes: UInt64) -> TimeInterval? {
        guard let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(remainingBytes) / rate
    }

    /// "about 6 min left", "less than a minute left".
    public static func label(secondsLeft: TimeInterval) -> String {
        if secondsLeft < 60 { return "less than a minute left" }
        return "about \(DurationLabel.format(secondsLeft)) left"
    }
}
