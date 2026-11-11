import Foundation
import Observation

/// A pretend Daybook on Apple Watch and the link to it, for tests and debug demos: never WatchConnectivity. It behaves
/// as the watch app does: it records on `.start` and stops on `.stop` (answering with its state), answers `.status` and
/// `.clock`, closes a segment every `segmentLength` of audio and sends it, sends again what a finished recording's
/// receipt asking for what's missing (`requestsMissing`) doesn't name, pushes its own Record and Stop as `.state`, and
/// publishes its state as its application context. Its transfers finish at once, so it has no moments-old transfer to
/// leave out of a resend (`WatchRecordingJournal.resendAfter`).
///
/// What arrives while Daybook isn't open on it (queued messages, the iPhone's context) waits until it is: when
/// `isReachable` turns true, or `runQueued()`.
@MainActor
@Observable
public final class SimulatedWatch: WatchTransport {
    public private(set) var isActivated = false
    public var activationError: String?
    public var isPaired = true { didSet { changed() } }
    public var isWatchAppInstalled = true { didSet { changed() } }
    /// Daybook is open on the watch. Turning it on runs what was queued for it.
    public var isReachable = true {
        didSet {
            changed()
            if isReachable && !oldValue { runQueued() }
        }
    }
    public private(set) var watchContext: WatchState?
    @ObservationIgnored public var onMessage: ((WatchMessage, ((WatchReply) -> Void)?) -> Void)?
    @ObservationIgnored public var onSegment: ((WatchStagedSegment) -> Void)?
    @ObservationIgnored public var onWatchContext: ((WatchState) -> Void)?
    @ObservationIgnored public var onChange: (() -> Void)?

    // MARK: The pretend watch

    /// Its installation ID: a new one is Daybook installed on it again.
    public var watchID: String
    /// How far its clock is ahead of the iPhone's.
    public var clockOffset: TimeInterval = 0
    public var battery: Int? = 82
    public var freeBytes: UInt64? = 20_000_000_000
    public var totalBytes: UInt64? = 32_000_000_000
    public var model = "Apple Watch Series 11"
    public var appVersion = "1.0 (1)"
    /// How much audio a segment holds before the next begins.
    public var segmentLength = WatchAudioFormat.segmentLength
    /// Segments are sent as each closes; off, they wait for `deliver(_:)`.
    public var deliversSegments = true
    /// Refuses a Start with these words.
    public var refusesStart: String?
    /// Answers this late; later than a message's timeout, it acts but the answer doesn't arrive in time.
    public var answerDelay: Duration?
    /// Segments, by index, this iPhone fails to keep: the transfer ends, but the segment never reaches the connection
    /// (staging failed). Each entry loses one arrival.
    public var losesOnArrival: [Int] = []
    /// Writes a segment's audio. By default a few bytes that name it; demos and tests may write real audio.
    @ObservationIgnored public var writeSegment: (URL, WatchSegment) throws -> Void = { url, segment in
        try Data("\(segment.recordingID) part \(segment.index)\n".utf8).write(to: url)
    }

    public private(set) var recording: WatchRecordingInfo?
    /// Finished recordings the iPhone hasn't said are imported.
    public private(set) var finished: [WatchRecordingInfo] = []
    /// What the iPhone sent that it answered, sent without an answer while it could hear (`tell`), queued, and
    /// published, in order.
    public private(set) var answered: [WatchMessage] = []
    public private(set) var told: [WatchMessage] = []
    public private(set) var queued: [WatchMessage] = []
    public private(set) var contexts: [PhoneContext] = []
    /// Segments closed but not sent yet.
    public private(set) var undelivered: [WatchSegment] = []
    /// Queued messages not yet run (Daybook wasn't open on the watch).
    public private(set) var waiting: [WatchMessage] = []
    /// Segments sent again because a receipt asking for what's missing didn't name them, in order.
    public private(set) var resent: [WatchSegment] = []
    /// Every segment closed, kept until its recording is imported.
    private var closed: [WatchSegment] = []

    /// The audio in the segment being written, and where the recording stands.
    private var pending: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private let staging: URL
    private let scratch: URL

    /// `stagingDirectory` is the devices' (`DeviceEnvironment.stagingDirectory`): segments are staged where the
    /// iPhone's own link stages them.
    public init(stagingDirectory: URL, watchID: String = UUID().uuidString) {
        staging = WatchStaging.folder(in: stagingDirectory)
        scratch = stagingDirectory.appendingPathComponent("SimulatedWatch-\(watchID)", isDirectory: true)
        self.watchID = watchID
    }

    private var now: Date { Date().addingTimeInterval(clockOffset) }

    /// Its state now, saying why it changed.
    public func state(_ change: WatchChange? = nil) -> WatchState {
        WatchState(watchID: watchID, recording: recording, isCapturing: recording != nil, finished: finished, change: change,
                   battery: battery, freeBytes: freeBytes, totalBytes: totalBytes, appVersion: appVersion, model: model, asOf: now)
    }

    // MARK: WatchTransport

    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        changed()
    }

    public func send(_ message: WatchMessage, timeout: Duration) async throws -> WatchReply {
        guard isActivated, isReachable else { throw WatchTransportError.unreachable }
        if let delay = answerDelay {
            guard delay <= timeout else {
                // It hears the message and acts, but its answer comes after the iPhone stopped waiting.
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self else { return }
                    _ = self.answer(message)
                    self.push(self.state(message.isStart ? .startedByPhone : nil))
                }
                try? await Task.sleep(for: timeout)
                throw WatchTransportError.timedOut
            }
            try? await Task.sleep(for: delay)
        }
        await Task.yield()
        return answer(message)
    }

    public func queue(_ message: WatchMessage) {
        queued.append(message)
        waiting.append(message)
        if isReachable { runQueued() }
    }

    public func tell(_ message: WatchMessage) {
        guard isActivated, isReachable else { return queue(message) }
        told.append(message)
        if case .received(let receipt) = message { take(receipt) }
    }

    public func updateContext(_ context: PhoneContext) {
        contexts.append(context)
        if isReachable { followContext() }
    }

    // MARK: What it does

    private func answer(_ message: WatchMessage) -> WatchReply {
        answered.append(message)
        switch message {
        case .start(let start):
            if let refusesStart { return .refused(refusesStart) }
            if recording == nil { begin(start.conversationID, change: .startedByPhone) }
            return .state(state(.startedByPhone))
        case .stop(let stop):
            let ended = end(stop, change: .stoppedByPhone)
            return .state(state(ended ? .stoppedByPhone : nil))
        case .status:
            return .state(state())
        case .clock(let phoneTime):
            return .clock(WatchClockSample(phoneSent: phoneTime, watchTime: now))
        case .received(let receipt):
            take(receipt)
            return .state(state())
        case .context, .state:
            return .refused("The watch doesn’t take that message.")
        }
    }

    /// Daybook runs on the watch: it runs what was queued for it, then follows the iPhone's latest context.
    public func runQueued() {
        let messages = waiting
        waiting = []
        for message in messages {
            switch message {
            case .stop(let stop): _ = end(stop, change: .stoppedByPhone)
            case .received(let receipt): take(receipt)
            default: break
            }
        }
        followContext()
    }

    /// A recording made along with a shared recording the iPhone no longer names stops.
    private func followContext() {
        guard let recording, let conversation = recording.conversationID, let context = contexts.last,
              context.sharedRecording?.conversationID != conversation else { return }
        _ = end(WatchStop(recordingID: recording.id), change: .stoppedByPhone)
    }

    /// Imported: it forgets the recording. Otherwise, for a finished one, when the receipt asks, every segment it doesn't
    /// name and that isn't on its way already (`undelivered`) goes again.
    private func take(_ receipt: WatchReceipt) {
        guard receipt.imported else {
            guard receipt.requestsMissing, finished.contains(where: { $0.id == receipt.recordingID }) else { return }
            let held = Set(receipt.segments)
            for segment in closed where segment.recordingID == receipt.recordingID && !held.contains(segment.index)
                && !undelivered.contains(where: { $0.recordingID == segment.recordingID && $0.index == segment.index }) {
                resent.append(segment)
                send(segment)
            }
            return
        }
        finished.removeAll { $0.id == receipt.recordingID }
        closed.removeAll { $0.recordingID == receipt.recordingID }
        publishContext(state())
    }

    /// The person taps Record on the watch: it joins the iPhone's shared recording when there is one and it records
    /// along, otherwise it records on its own. Pushed as its button.
    public func pressRecord() {
        guard recording == nil else { return }
        let shared = contexts.last.flatMap { $0.recordsAlong ? $0.sharedRecording : nil }
        begin(shared?.conversationID, change: shared == nil ? .startedOnWatch : .joined)
        push(state(shared == nil ? .startedOnWatch : .joined))
    }

    /// The person taps Stop on the watch. Pushed as its button.
    public func pressStop() {
        guard let recording else { return }
        _ = end(WatchStop(recordingID: recording.id), change: .stoppedOnWatch)
        push(state(.stoppedOnWatch))
    }

    /// Records `seconds` more audio, closing (and sending) a segment each time one is full.
    public func record(_ seconds: TimeInterval) {
        guard recording != nil else { return }
        var left = seconds
        while left > 0 {
            let take = min(left, segmentLength - pending)
            pending += take
            left -= take
            recording?.duration += take
            if pending >= segmentLength - 1e-9 { closeSegment() }
        }
        publishContext(state())
    }

    /// Sends segments held back (`deliversSegments` off), in the order given by index, or as they closed.
    public func deliver(_ order: [Int]? = nil) {
        let segments = order.map { indices in indices.compactMap { index in undelivered.first { $0.index == index } } } ?? undelivered
        for segment in segments {
            undelivered.removeAll { $0.index == segment.index && $0.recordingID == segment.recordingID }
            send(segment)
        }
    }

    private func begin(_ conversation: UUID?, change: WatchChange) {
        recording = WatchRecordingInfo(id: UUID().uuidString, conversationID: conversation, startedAt: now)
        pending = 0
        elapsed = 0
        publishContext(state(change))
    }

    /// Ends the recording `stop` names: its last segment closes and it's finished. False when it names another.
    private func end(_ stop: WatchStop, change: WatchChange) -> Bool {
        guard var current = recording, stop.recordingID == nil || stop.recordingID == current.id,
              stop.conversationID == nil || stop.conversationID == current.conversationID else { return false }
        if pending > 0 { closeSegment() }
        current = recording ?? current
        current.isFinished = true
        recording = nil
        finished.append(current)
        publishContext(state(change))
        return true
    }

    private func closeSegment() {
        guard var current = recording else { return }
        let index = current.segmentIndices.count
        current.segmentIndices.append(index)
        current.byteCount += UInt64(pending * 8_000)
        recording = current
        let segment = WatchSegment(recordingID: current.id, index: index, startOffset: elapsed, duration: pending, recording: current)
        closed.append(segment)
        elapsed += pending
        pending = 0
        if deliversSegments { send(segment) } else { undelivered.append(segment) }
    }

    /// Writes the segment's file and hands it over as WatchConnectivity would: staged first, then delivered.
    private func send(_ segment: WatchSegment) {
        if let lost = losesOnArrival.firstIndex(of: segment.index) {
            losesOnArrival.remove(at: lost)
            return
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appendingPathComponent(segment.fileName)
            try writeSegment(file, segment)
            let staged = try WatchStaging.stage(file, metadata: WatchPayload.dictionary(segment), in: staging)
            onSegment?(staged)
        } catch {
            assertionFailure("The simulated watch couldn't send a segment: \(error)")
        }
    }

    private func push(_ state: WatchState) {
        onMessage?(.state(state), nil)
    }

    private func publishContext(_ state: WatchState) {
        watchContext = state
        onWatchContext?(state)
    }

    private func changed() { onChange?() }
}

private extension WatchMessage {
    var isStart: Bool { if case .start = self { return true } else { return false } }
}
