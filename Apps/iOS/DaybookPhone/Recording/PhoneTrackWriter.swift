import AVFoundation
import DaybookCore
import Foundation

/// Turns the microphone's buffers into AAC segments on one serial queue, never on the audio thread.
///
/// - The conversation's timeline starts at the first sample (`anchor`). Each segment records where
///   its first sample falls on that timeline, measured on the continuous clock so a device that
///   slept during an interruption still places the next segment correctly.
/// - Within a segment, each buffer's host time is compared with the time predicted from the latest
///   clock anchor, so slow drift never reads as a gap. Real gaps (the engine restarting on a new
///   route) are filled with silence up to five minutes; a longer one starts a new segment.
/// - A buffer in another format (AirPods at 16 kHz, a stereo USB mic) is converted to 48 kHz mono.
final class PhoneTrackWriter: @unchecked Sendable {
    struct SessionAnchor: Equatable, Sendable {
        var hostTime: TimeInterval
        var continuousTime: TimeInterval
        var date: Date
    }

    let meter = AudioLevelMeter()
    let format: RecordingFormat
    let directory: URL
    private let clock: any RecorderClock
    private let realTime: Bool
    private let queue = DispatchQueue(label: "local.daybook.phone.track-writer", qos: .userInitiated)
    private let failure: @Sendable (Error) -> Void
    private let segmentOpened: @Sendable () -> Void

    // Shared with other threads under `lock`.
    private let lock = NSLock()
    private var sessionAnchor: SessionAnchor?
    private var segments: [CaptureSegment]
    private var queued = 0
    private var accepting = true

    // Owned by `queue`.
    private var writer: AACSegmentWriter?
    private var converter: AVAudioConverter?
    private var lastAnchor: ClockAnchor?
    private var pendingResync = false
    private var pendingNotes: [String] = []
    private var failed = false
    private var nextIndex: Int

    static let anchorInterval: TimeInterval = 1
    static let smallestGap: TimeInterval = 0.08
    static let largestPaddedGap: TimeInterval = 300
    private static let maxQueued = 400

    init(directory: URL, format: RecordingFormat, clock: any RecorderClock, realTime: Bool,
         resumingFrom segments: [CaptureSegment] = [], anchor: SessionAnchor? = nil,
         segmentOpened: @escaping @Sendable () -> Void = {}, failure: @escaping @Sendable (Error) -> Void) {
        self.directory = directory
        self.format = format
        self.clock = clock
        self.realTime = realTime
        self.segments = segments
        self.sessionAnchor = anchor
        self.nextIndex = (segments.map(\.index).max() ?? -1) + 1
        self.segmentOpened = segmentOpened
        self.failure = failure
    }

    var anchor: SessionAnchor? { lock.withLock { sessionAnchor } }
    var snapshot: [CaptureSegment] { lock.withLock { segments } }

    /// Stops or restarts taking audio. An input can deliver one more buffer after it's told to stop;
    /// with intake off, that buffer is dropped instead of opening a stray segment.
    func setAcceptingAudio(_ value: Bool) {
        lock.withLock { accepting = value }
    }

    /// Called on the input's thread.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard lock.withLock({ accepting }) else { return }
        meter.record(buffer)
        let accepted = lock.withLock { () -> Bool in
            guard accepting else { return false }
            if sessionAnchor == nil {
                sessionAnchor = SessionAnchor(hostTime: hostTime, continuousTime: clock.continuousTime(forHostTime: hostTime),
                                              date: clock.date(forHostTime: hostTime))
            }
            guard queued < Self.maxQueued else { return false }
            queued += 1
            return true
        }
        guard accepted else {
            if lock.withLock({ accepting }) { failure(PhoneRecorderError.diskBacklog) }
            return
        }
        queue.async { [self] in
            defer { lock.withLock { queued -= 1 } }
            write(buffer, hostTime: hostTime)
        }
    }

    /// The next buffers start a new clock run (the input restarted on another device).
    func markDiscontinuity(_ note: String) {
        queue.async { [self] in
            pendingResync = true
            pendingNotes.append(note)
        }
    }

    /// Finishes the current segment so it's complete on disk. The next buffer opens a new one.
    @discardableResult
    func closeSegment() async -> CaptureSegment? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: finishSegment()) }
        }
    }

    /// For app termination: finish the segment before returning.
    func closeSegmentNow() {
        queue.sync { _ = finishSegment() }
    }

    /// Returns once every buffer appended so far has been handled.
    func waitUntilWritten() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Queue

    private func write(_ input: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard !failed, input.frameLength > 0 else { return }
        do {
            if writer == nil { try openSegment(firstSampleHostTime: hostTime) }
            var buffer = input
            if input.format != format.pcmFormat {
                buffer = try convert(input)
            } else if converter != nil {
                try drainConverter()
                pendingResync = true
                pendingNotes.append("The microphone returned to 48 kHz mono.")
            }
            guard buffer.frameLength > 0, let writer else { return }
            var frames = writer.framesWritten
            if let anchor = lastAnchor {
                let expected = anchor.hostTime + Double(frames - anchor.frame) / format.sampleRate
                let gap = hostTime - expected
                guard gap.isFinite else { throw PhoneRecorderError.encoderUnavailable("clock") }
                if gap > Self.largestPaddedGap {
                    _ = finishSegment()
                    try openSegment(firstSampleHostTime: hostTime)
                    return write(input, hostTime: hostTime)
                } else if gap > Self.smallestGap {
                    try writer.appendSilence(frames: Int64((gap * format.sampleRate).rounded()))
                    frames = writer.framesWritten
                    pendingResync = true
                } else if gap < -0.1 {
                    pendingResync = true
                }
            }
            var newAnchor: ClockAnchor?
            if lastAnchor == nil || pendingResync || hostTime - (lastAnchor?.hostTime ?? 0) >= Self.anchorInterval {
                let anchor = ClockAnchor(frame: frames, hostTime: hostTime, resync: pendingResync && lastAnchor != nil ? true : nil)
                lastAnchor = anchor
                newAnchor = anchor
                pendingResync = false
            }
            try writer.append(buffer)
            let total = writer.framesWritten
            let notes = pendingNotes
            pendingNotes = []
            lock.withLock {
                guard var current = segments.last, !current.closed else { return }
                current.frameCount = total
                if let newAnchor { current.clockAnchors.append(newAnchor) }
                if !notes.isEmpty { current.notes = (current.notes ?? []) + notes }
                segments[segments.count - 1] = current
            }
        } catch {
            failed = true
            failure(error)
        }
    }

    private func openSegment(firstSampleHostTime host: TimeInterval) throws {
        let index = nextIndex
        nextIndex += 1
        let fileName = String(format: "segment-%03d.m4a", index)
        writer = try AACSegmentWriter(url: directory.appendingPathComponent(fileName), format: format, realTime: realTime)
        lastAnchor = nil
        let start = lock.withLock { sessionAnchor.map { clock.continuousTime(forHostTime: host) - $0.continuousTime } } ?? 0
        let segment = CaptureSegment(index: index, fileName: fileName, startOffset: max(0, start), frameCount: 0, closed: false,
                                     firstSampleHostTime: host, clockAnchors: [], notes: nil)
        lock.withLock { segments.append(segment) }
        segmentOpened()
    }

    private func finishSegment() -> CaptureSegment? {
        guard let writer else { return nil }
        self.writer = nil
        lastAnchor = nil
        var closed = false
        var frames = writer.framesWritten
        do {
            try drainConverter(into: writer)
            frames = try writer.finish()
            closed = true
        } catch {
            // The fragments already on disk stay readable; recovery uses them.
            writer.cancel()
            pendingNotes.append("The segment couldn’t be finished: \(error.localizedDescription)")
        }
        converter = nil
        return lock.withLock { () -> CaptureSegment? in
            guard var current = segments.last, !current.closed else { return nil }
            current.frameCount = frames
            current.closed = closed
            segments[segments.count - 1] = current
            return current
        }
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let output = format.pcmFormat
        if converter?.inputFormat != input.format {
            try drainConverter()
            guard let created = AVAudioConverter(from: input.format, to: output) else { throw PhoneRecorderError.encoderUnavailable("converter") }
            if input.format.channelCount > output.channelCount { created.downmix = true }
            converter = created
            pendingResync = true
            pendingNotes.append("The microphone delivered \(Int(input.format.sampleRate)) Hz, \(input.format.channelCount) ch; converted to 48 kHz mono.")
        }
        guard let converter else { throw PhoneRecorderError.encoderUnavailable("converter") }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw PhoneRecorderError.encoderUnavailable("buffer") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? PhoneRecorderError.encoderUnavailable("convert") }
        return buffer
    }

    /// Writes what a sample-rate converter still holds and retires it.
    private func drainConverter(into target: AACSegmentWriter? = nil) throws {
        guard let converter, let writer = target ?? self.writer else { self.converter = nil; return }
        self.converter = nil
        guard let output = AVAudioPCMBuffer(pcmFormat: format.pcmFormat, frameCapacity: 8_192) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return }
        try writer.append(output)
    }
}
