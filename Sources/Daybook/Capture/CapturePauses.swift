import AVFoundation
import DaybookKit
import Foundation

/// A pause the person made during a recording, in seconds of the recording's session timeline. One still open (Daybook
/// quit while paused) has no end.
struct CapturePause: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval?

    /// The capture notes' line for it: "Paused 1:02–3:04; the gap is silent.", as the iPhone's recordings say theirs.
    var note: String {
        let span = end.map { "\(TimeLabel.short(start))–\(TimeLabel.short($0))" } ?? "from \(TimeLabel.short(start))"
        return "Paused \(span); the gap is silent."
    }

    /// The pauses with an open one ended at `end` (the recording's end).
    static func closed(_ pauses: [CapturePause], at end: TimeInterval) -> [CapturePause] {
        pauses.map { CapturePause(start: $0.start, end: $0.end ?? max($0.start, end)) }
    }
}

/// The person's pauses of the recording under way, on the host clock, shared with each track's writer and the caption
/// taps on the capture threads (docs/capture.md, "Pausing").
///
/// A pause keeps the sources running and the files growing: whatever a source captures from the moment of Pause until
/// Resume is written as silence (`PCMTrackWriter`), and captions are given silence for it, so neither the kept recording
/// nor anything made from it (captions, the transcript, the summary) holds what was said, and both tracks keep their
/// length on the session's timeline. A buffer is judged by the host time its source stamped on it, so audio captured
/// before Pause but delivered after it is kept, and audio captured after it never is, wherever it is when Pause comes.
final class CapturePauses: @unchecked Sendable {
    private struct Span { var start: TimeInterval; var end: TimeInterval? }

    /// The session's zero on the host clock (`CaptureSessionManifest.hostTimeSeconds`).
    let origin: TimeInterval
    private let lock = NSLock()
    private var spans: [Span] = []

    init(origin: TimeInterval) {
        self.origin = origin
    }

    var isPaused: Bool { lock.withLock { spans.last.map { $0.end == nil } ?? false } }

    /// The pauses so far, in session seconds; one still open has no end.
    var record: [CapturePause] {
        lock.withLock { spans.map { CapturePause(start: $0.start - origin, end: $0.end.map { $0 - origin }) } }
    }

    /// A pause from `host` on. False while one is open.
    @discardableResult
    func begin(at host: TimeInterval) -> Bool {
        lock.withLock {
            guard spans.last.map({ $0.end != nil }) ?? true else { return false }
            spans.append(Span(start: host, end: nil))
            return true
        }
    }

    /// The open pause ends at `host`. False when none is open.
    @discardableResult
    func end(at host: TimeInterval) -> Bool {
        lock.withLock {
            guard let last = spans.indices.last, spans[last].end == nil else { return false }
            spans[last].end = max(spans[last].start, host)
            return true
        }
    }

    /// The frames of a buffer whose first frame was captured at `host`, `frames` long at `rate`, that were captured
    /// during a pause: ranges of frame indices, in order. Frame `i` was captured at `host + i / rate`.
    func pausedFrames(from host: TimeInterval, frames: Int, rate: Double) -> [Range<Int>] {
        guard frames > 0, rate > 0 else { return [] }
        let spans = lock.withLock { self.spans }
        var ranges: [Range<Int>] = []
        for span in spans {
            let first = Self.frame(at: span.start, from: host, rate: rate, limit: frames)
            let end = span.end.map { Self.frame(at: $0, from: host, rate: rate, limit: frames) } ?? frames
            guard first < end else { continue }
            if let last = ranges.last, last.upperBound >= first { ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, end) }
            else { ranges.append(first..<end) }
        }
        return ranges
    }

    /// Whether any of a buffer from `host`, `seconds` long, was captured during a pause.
    func overlaps(from host: TimeInterval, seconds: TimeInterval) -> Bool {
        let spans = lock.withLock { self.spans }
        return spans.contains { $0.start < host + seconds && ($0.end.map { $0 > host } ?? true) }
    }

    /// A copy of `buffer` with what was captured during a pause silent, for captions; nil when none of it was.
    func silenced(_ buffer: AVAudioPCMBuffer, at host: TimeInterval) -> AVAudioPCMBuffer? {
        let ranges = pausedFrames(from: host, frames: Int(buffer.frameLength), rate: buffer.format.sampleRate)
        guard !ranges.isEmpty, let copy = PCMTrackWriter.copy(buffer) else { return nil }
        Self.zero(copy, ranges)
        return copy
    }

    /// The first frame at or after `time`, between 0 and `limit`.
    private static func frame(at time: TimeInterval, from host: TimeInterval, rate: Double, limit: Int) -> Int {
        let value = ((time - host) * rate).rounded(.up)
        guard value.isFinite else { return value > 0 ? limit : 0 }
        return Int(min(Double(limit), max(0, value)))
    }

    /// Sets the frames in `ranges` to silence, in any PCM format.
    static func zero(_ buffer: AVAudioPCMBuffer, _ ranges: [Range<Int>]) {
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let length = Int(buffer.frameLength)
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            for range in ranges {
                let lower = max(0, range.lowerBound), upper = min(length, range.upperBound)
                guard lower < upper else { continue }
                memset(data + lower * bytesPerFrame, 0, (upper - lower) * bytesPerFrame)
            }
        }
    }
}
