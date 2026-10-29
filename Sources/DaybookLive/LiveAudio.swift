import AVFoundation
import DaybookCaptions
import Foundation

/// The audio every live model takes: 16 kHz mono, 32-bit float.
public enum LiveAudio {
    public static let sampleRate: Double = 16_000
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
}

/// Converts a capture's buffers, of any PCM format, to 16 kHz mono samples. The converter keeps its
/// filter state between buffers (a microphone's 85 ms buffers, a call's 10 ms IO cycles) and is
/// rebuilt when the format changes. Use from one task at a time.
final class LiveResampler: @unchecked Sendable {
    private let converter = CaptionConverter(output: LiveAudio.format)

    func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converted = converter.convert(buffer), converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}

/// The bounded wait between a capture's audio thread and a live pipeline's worker: `append` never
/// blocks, the oldest audio is dropped when the worker falls behind, and `fill` says how far behind.
final class LiveInput: @unchecked Sendable {
    struct Item: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer
        /// Seconds on the source's timeline, when known.
        var time: TimeInterval?
    }

    let stream: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation
    let capacity: Int
    private let lock = NSLock()
    private var remaining: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        remaining = self.capacity
        (stream, continuation) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(self.capacity))
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let result = continuation.yield(Item(buffer: buffer, time: time?.liveSeconds))
        if case .enqueued(let left) = result { lock.withLock { remaining = left } }
    }

    /// The worker took one: room for one more.
    func took() { lock.withLock { remaining = min(capacity, remaining + 1) } }

    /// How full the wait is, 0…1.
    var fill: Double { lock.withLock { 1 - Double(remaining) / Double(capacity) } }

    func finish() { continuation.finish() }
}

extension AVAudioTime {
    /// Seconds on the source's timeline: sample time at its rate when valid, else host time (as
    /// DaybookCaptions reads a buffer's time).
    var liveSeconds: TimeInterval? {
        if isSampleTimeValid, sampleRate > 0 { return Double(sampleTime) / sampleRate }
        if isHostTimeValid { return AVAudioTime.seconds(forHostTime: hostTime) }
        return nil
    }
}

/// Maps a live model's timeline (the audio it was fed, back to back) onto the capture's (which has
/// gaps where audio was dropped or shed), counting from `origin`, else from the first buffer
/// *appended*: every captioner wrapping the same capture then counts from the same moment, even
/// when one of them drops audio while its model loads. Thread-safe.
final class LiveTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: TimeInterval?
    private var map: CaptionTimeMap?

    init(origin: TimeInterval?) {
        self.origin = origin
        if let origin { map = CaptionTimeMap(origin: origin) }
    }

    /// A buffer was appended at `time` (source seconds): the first one fixes the origin.
    func appended(at time: TimeInterval?) {
        guard origin == nil else { return }
        lock.withLock { if map == nil { map = CaptionTimeMap(origin: time) } }
    }

    private var current: CaptionTimeMap {
        lock.withLock {
            if let map { return map }
            let created = CaptionTimeMap(origin: origin)
            map = created
            return created
        }
    }

    /// Notes a buffer about to be fed to the model: its source time and length.
    func feed(sourceTime: TimeInterval?, duration: TimeInterval) { current.feed(sourceTime: sourceTime, duration: duration) }

    /// A time on the model's timeline, on the capture's.
    func sourceTime(_ modelTime: TimeInterval) -> TimeInterval { current.sourceTime(modelTime) }
}
