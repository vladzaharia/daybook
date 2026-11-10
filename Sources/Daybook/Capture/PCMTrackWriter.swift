import AVFoundation
import DaybookCore
import DaybookKit
import Foundation

/// Thread-safe level meter fed by capture callbacks and read by the UI timer.
///
/// Every source moves alike, whatever its buffer size (a tap's 10 ms, the microphone's 85 ms): the level is
/// RMS smoothed with a 300 ms time constant, and the peak holds for a second. It also keeps when it last heard
/// anything, for the rolling hearing check (`CaptureLevelMonitor.isNotHearing`).
final class AudioLevelMeter: @unchecked Sendable {
    struct Reading: Equatable {
        /// Root-mean-square level, smoothed over about 300 ms, in dBFS.
        var rms: Float
        /// The highest sample magnitude in the last second, in dBFS.
        var peak: Float
        /// Host time of the most recent buffer whose level exceeded `audibleThreshold`.
        var lastAudibleHostTime: TimeInterval?
        /// Host time of the most recent buffer with any non-zero sample; all-zero input usually means a muted,
        /// unplugged, or denied device (or a MacBook's microphone with its lid closed).
        var lastSignalHostTime: TimeInterval?
        /// Host time of the most recent buffer above `hearingFloor`.
        var lastHeardHostTime: TimeInterval?
        static let silent = Reading(rms: -160, peak: -160)
    }

    static let audibleThreshold: Float = -50
    /// Below this a microphone hears nothing a person could have said (a real room is 30 dB louder).
    static let hearingFloor: Float = -90
    static let timeConstant: TimeInterval = 0.3
    static let peakHold: TimeInterval = 1
    private let lock = NSLock()
    private var reading = Reading.silent
    private var meanSquare: Float = 0
    private var peakHeldUntil: TimeInterval = -.infinity

    func record(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard let level = AudioBufferLevel.measure(buffer), buffer.format.sampleRate > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let weight = Float(1 - exp(-duration / Self.timeConstant))
        let power = level.rms <= -160 ? 0 : pow(10, level.rms / 10)
        lock.lock()
        meanSquare += weight * (power - meanSquare)
        reading.rms = max(-160, 10 * log10(max(meanSquare, 1e-16)))
        if level.peak >= reading.peak || hostTime >= peakHeldUntil {
            reading.peak = level.peak
            peakHeldUntil = hostTime + Self.peakHold
        }
        if level.hasSignal { reading.lastSignalHostTime = hostTime }
        if level.rms >= Self.hearingFloor { reading.lastHeardHostTime = hostTime }
        if level.rms >= Self.audibleThreshold { reading.lastAudibleHostTime = hostTime }
        lock.unlock()
    }

    func read() -> Reading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    func reset() {
        lock.lock(); reading = .silent; meanSquare = 0; peakHeldUntil = -.infinity; lock.unlock()
    }
}

/// All file mutation happens on a serial queue, never the real-time input thread.
///
/// Timing: every buffer's host time is compared with the time predicted from the most recent
/// clock anchor (at most about a second old), so slow device-clock drift is never mistaken for a
/// gap. A track never stops for its clock (the iPhone's rule): a gap over 80 ms and up to five
/// minutes is padded with silence (5 ms ramps at its seams, so it doesn't click); a longer one
/// isn't padded and the next anchor starts a new clock segment; a jump back over 100 ms drops the
/// audio that overlaps what's written and resyncs. Each is kept in the track's `gaps`. Anchors are
/// kept in the sidecar so drift can be measured and corrected after recording.
///
/// Writing behind (a busy disk) holds up to `maximumBacklog` seconds of audio; past that a buffer
/// is dropped and counted, and the gap code pads the hole once writing catches up, so the track
/// says what was lost. `progress` lets the controller stop a writer that hasn't moved in a minute.
///
/// A buffer in a different format (a device switch, AirPods changing profile) is converted to the
/// file's format so the recording continues; the next anchor is marked as a resync.
final class PCMTrackWriter: @unchecked Sendable {
    struct Outcome { var track: CapturedAudioTrack?; var error: String? }
    /// Where writing stands, in the host times stamped on the buffers.
    struct Progress: Equatable {
        /// The latest buffer handed to the writer.
        var delivered: TimeInterval?
        /// `delivered` as the writer last finished a buffer (or at the first buffer): when it last moved.
        var advanced: TimeInterval?
        /// Audio waiting to be written, in seconds.
        var backlog: TimeInterval = 0
        /// Seconds of audio dropped because the backlog was full.
        var dropped: TimeInterval = 0
        /// Seconds the writer has had audio waiting without finishing any of it.
        var stalledFor: TimeInterval {
            guard backlog > 0, let delivered, let advanced else { return 0 }
            return max(0, delivered - advanced)
        }
    }

    let role: CapturedTrackRole
    let meter = AudioLevelMeter()
    private let queue = DispatchQueue(label: "app.daybook.audio-writer", qos: .userInitiated)
    private let url: URL
    private let metadataURL: URL
    private let manifest: CaptureSessionManifest
    private let failure: (Error) -> Void
    private var method: String?
    private var file: AVAudioFile?
    private var track: CapturedAudioTrack?
    private var errorMessage: String?
    private var isFinished = false
    private var lastMetadataWrite: TimeInterval = -.infinity
    private var lastAnchor: ClockAnchor?
    private var pendingResync = false
    private let converter = PCMFormatConverter()
    private var notes: [String] = []
    private var gaps: [CaptureGap] = []
    /// The last frame written, per channel (float audio), so padding ramps from it.
    private var lastSamples: [Float]?
    private let maximumBacklog: TimeInterval
    private let beforeWrite: (@Sendable () -> Void)?
    // Shared with the input's thread under `progressLock`.
    private let progressLock = NSLock()
    private var shared = Progress()
    /// Dropped since the last buffer accepted: the next one's gap is lost audio.
    private var droppedSinceAccepted: TimeInterval = 0
    /// Bytes a second of the file's format, once it's known.
    private var fileBytesPerSecond: Double = 0
    static let anchorInterval: TimeInterval = 1
    static let smallestGap: TimeInterval = 0.08
    static let largestPaddedGap: TimeInterval = 300
    static let backwardTolerance: TimeInterval = 0.1
    /// Seconds of audio the writer holds while the disk is busy.
    static let defaultBacklog: TimeInterval = 30
    static let rampSeconds: TimeInterval = 0.005

    /// `beforeWrite` runs on the writing queue before each buffer (tests stall the disk with it).
    init(role: CapturedTrackRole, directory: URL, manifest: CaptureSessionManifest, method: String? = nil,
         maximumBacklog: TimeInterval = PCMTrackWriter.defaultBacklog, beforeWrite: (@Sendable () -> Void)? = nil,
         failure: @escaping (Error) -> Void) {
        self.role = role
        self.url = directory.appendingPathComponent(role.rawValue + ".caf")
        self.metadataURL = directory.appendingPathComponent(role.rawValue + ".json")
        self.manifest = manifest
        self.method = method
        self.maximumBacklog = maximumBacklog
        self.beforeWrite = beforeWrite
        self.failure = failure
    }

    /// Where writing stands; any thread.
    var progress: Progress { progressLock.withLock { shared } }

    /// Bytes a second this track adds to the disk, once its first buffer is written; any thread.
    var bytesPerSecond: Double { progressLock.withLock { fileBytesPerSecond } }

    func append(_ buffer: AVAudioPCMBuffer, hostTimeSeconds: TimeInterval) {
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        // A full backlog drops the buffer, counted; the gap it leaves is padded once writing catches up.
        let lostBefore = progressLock.withLock { () -> TimeInterval? in
            shared.delivered = hostTimeSeconds
            if shared.advanced == nil { shared.advanced = hostTimeSeconds }
            guard shared.backlog + seconds <= maximumBacklog else {
                shared.dropped += seconds
                droppedSinceAccepted += seconds
                return nil
            }
            shared.backlog += seconds
            defer { droppedSinceAccepted = 0 }
            return droppedSinceAccepted
        }
        // The meter hears what the source delivers, written or not.
        meter.record(buffer, hostTime: hostTimeSeconds)
        guard let lostBefore else { return }
        queue.async { [self] in
            defer {
                progressLock.withLock {
                    shared.backlog = max(0, shared.backlog - seconds)
                    shared.advanced = shared.delivered
                }
            }
            guard !isFinished, errorMessage == nil, buffer.frameLength > 0 else { return }
            beforeWrite?()
            do { try write(buffer, hostTimeSeconds: hostTimeSeconds, lost: lostBefore) }
            catch {
                recordFailure(error)
                failure(error)
            }
        }
    }

    /// Records how this track is being captured, once the capture path is known.
    func setMethod(_ value: String) {
        queue.async { [self] in
            method = value
            track?.method = value
        }
    }

    /// The next buffer starts a new clock segment (for example, after the source restarted on a
    /// new device with the same format).
    func markDiscontinuity(_ note: String? = nil) {
        queue.async { [self] in
            pendingResync = true
            if let note { notes.append(note) }
        }
    }

    /// `lost` is how much audio was dropped just before this buffer, which its gap then stands for.
    private func write(_ input: AVAudioPCMBuffer, hostTimeSeconds: TimeInterval, lost: TimeInterval = 0) throws {
        // Moves on past audio a backward clock jump overlaps.
        var hostTimeSeconds = hostTimeSeconds
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: input.format.settings,
                                   commonFormat: input.format.commonFormat, interleaved: input.format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let rate = input.format.sampleRate * Double(input.format.streamDescription.pointee.mBytesPerFrame)
                * (input.format.isInterleaved ? 1 : Double(input.format.channelCount))
            progressLock.withLock { fileBytesPerSecond = rate }
            let offset = hostTimeSeconds - manifest.hostTimeSeconds
            track = CapturedAudioTrack(role: role, url: url,
                startedAt: manifest.startedAt.addingTimeInterval(offset), firstSampleHostTimeSeconds: hostTimeSeconds,
                offsetSeconds: offset, sampleRate: input.format.sampleRate,
                channelCount: input.format.channelCount, frameCount: 0, clockAnchors: [], method: method)
        }
        guard let file, var current = track else { throw RecordingError.audioFormatChanged }
        // Whatever reached the file is counted, even if a later step returns early or throws.
        defer { track = current }
        var buffer = input
        if input.format != file.processingFormat {
            if let from = converter.inputFormat, from != input.format { try drainConverter(into: file, track: &current) }
            buffer = try convert(input, to: file.processingFormat)
        } else if converter.inputFormat != nil {
            try drainConverter(into: file, track: &current)
            pendingResync = true
            notes.append("The \(role.rawValue) returned to its original format.")
        }
        guard buffer.frameLength > 0 else { return }

        // Compare with the time predicted from the latest anchor, so drift never reads as a gap. The
        // track never stops for its clock: gaps are padded, long ones skipped, and overlaps dropped.
        if let anchor = lastAnchor {
            let expected = anchor.hostTime + Double(current.frameCount - anchor.frame) / current.sampleRate
            let gap = hostTimeSeconds - expected
            guard gap.isFinite else { throw RecordingError.invalidAudio }
            if gap > Self.largestPaddedGap {
                // Too long to fill: the audio resumes on a new clock segment, placed by its own anchor.
                gaps.append(CaptureGap(kind: lost > 0 ? .lost : .skipped, frame: current.frameCount, seconds: gap))
                pendingResync = true
            } else if gap > Self.smallestGap {
                gaps.append(CaptureGap(kind: lost > 0 ? .lost : .padded, frame: current.frameCount, seconds: gap))
                try writeSilence(seconds: gap, format: buffer.format, to: file, track: &current, before: buffer)
                pendingResync = true
            } else if gap < -Self.backwardTolerance && !pendingResync {
                // The clock went back: what overlaps the written audio is dropped (buffer after buffer, until the
                // stamps reach the timeline again), and the clock resyncs where the audio continues.
                let overlap = Int64((-gap * current.sampleRate).rounded())
                let dropped = Double(min(overlap, Int64(buffer.frameLength))) / current.sampleRate
                if let last = gaps.last, last.kind == .overlap, last.frame == current.frameCount { gaps[gaps.count - 1].seconds += dropped }
                else { gaps.append(CaptureGap(kind: .overlap, frame: current.frameCount, seconds: dropped)) }
                current.gaps = gaps
                guard overlap < Int64(buffer.frameLength), let rest = Self.tail(of: buffer, dropping: AVAudioFrameCount(overlap)) else { return }
                buffer = rest
                hostTimeSeconds += Double(overlap) / current.sampleRate
                pendingResync = true
            } else if lost > 0 {
                // Dropped audio the timing hides (a sliver under the smallest gap): still said.
                gaps.append(CaptureGap(kind: .lost, frame: current.frameCount, seconds: lost))
            }
        }
        current.gaps = gaps.isEmpty ? nil : gaps
        lastSamples = Self.lastFrame(of: buffer)
        if lastAnchor == nil || pendingResync || hostTimeSeconds - lastAnchor!.hostTime >= Self.anchorInterval {
            let anchor = ClockAnchor(frame: current.frameCount, hostTime: hostTimeSeconds, resync: pendingResync && lastAnchor != nil ? true : nil)
            current.clockAnchors = (current.clockAnchors ?? []) + [anchor]
            lastAnchor = anchor
            pendingResync = false
        }
        try file.write(from: buffer)
        current.frameCount += Int64(buffer.frameLength)
        current.notes = notes.isEmpty ? nil : notes
        if hostTimeSeconds - lastMetadataWrite >= 10 {
            try persistTrack(current)
            lastMetadataWrite = hostTimeSeconds
        }
    }

    /// Silence for a gap, ramping over 5 ms from the last frame written and into `next`'s first, so neither seam
    /// clicks; the captured samples themselves are never changed.
    private func writeSilence(seconds: TimeInterval, format: AVAudioFormat, to file: AVAudioFile, track: inout CapturedAudioTrack,
                              before next: AVAudioPCMBuffer? = nil) throws {
        let count = AVAudioFrameCount((seconds * track.sampleRate).rounded())
        guard count > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        silence.frameLength = count
        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        let ramp = min(Int(count) / 2, Int((Self.rampSeconds * track.sampleRate).rounded()))
        if ramp > 0, format.commonFormat == .pcmFormatFloat32 {
            let channels = Int(format.channelCount)
            func set(_ frame: Int, _ values: [Float], _ scale: Float) {
                guard let data = silence.floatChannelData else { return }
                for channel in 0..<min(channels, values.count) {
                    if format.isInterleaved { data[0][frame * channels + channel] = values[channel] * scale }
                    else { data[channel][frame] = values[channel] * scale }
                }
            }
            if let last = lastSamples {
                for index in 0..<ramp { set(index, last, 1 - Float(index + 1) / Float(ramp + 1)) }
            }
            if let first = next.flatMap(Self.firstFrame) {
                for index in 0..<ramp { set(Int(count) - ramp + index, first, Float(index + 1) / Float(ramp + 1)) }
            }
        }
        try file.write(from: silence)
        track.frameCount += Int64(count)
    }

    /// One sample per channel at `frame` of float audio; nil for other formats.
    private static func samples(of buffer: AVAudioPCMBuffer, at frame: Int) -> [Float]? {
        guard let data = buffer.floatChannelData, frame >= 0, frame < Int(buffer.frameLength) else { return nil }
        let channels = Int(buffer.format.channelCount)
        return (0..<channels).map { buffer.format.isInterleaved ? data[0][frame * channels + $0] : data[$0][frame] }
    }

    static func firstFrame(of buffer: AVAudioPCMBuffer) -> [Float]? { samples(of: buffer, at: 0) }
    static func lastFrame(of buffer: AVAudioPCMBuffer) -> [Float]? { samples(of: buffer, at: Int(buffer.frameLength) - 1) }

    /// The buffer without its first `count` frames.
    static func tail(of buffer: AVAudioPCMBuffer, dropping count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count < buffer.frameLength,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - count) else { return nil }
        rest.frameLength = buffer.frameLength - count
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(rest.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let input = source[index].mData, let output = destination[index].mData else { return nil }
            memcpy(output, input + Int(count) * bytesPerFrame, Int(rest.frameLength) * bytesPerFrame)
        }
        return rest
    }

    /// Converts a buffer from a new device format to the file's format, keeping one converter per
    /// input format so resampling state carries across buffers.
    private func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        do {
            if try converter.prepare(from: input.format, to: format) {
                pendingResync = true
                notes.append("The \(role.rawValue) changed to \(Int(input.format.sampleRate)) Hz, \(input.format.channelCount) ch; converted to the recording’s format.")
            }
            return try converter.convert(input)
        } catch PCMFormatConverter.Failure.buffer {
            throw RecordingError.invalidAudio
        } catch PCMFormatConverter.Failure.conversion(let error?) {
            throw error
        } catch is PCMFormatConverter.Failure {
            throw RecordingError.audioFormatChanged
        }
    }

    /// Returns once every buffer appended so far has been written.
    func waitUntilWritten() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// Writes the frames a sample-rate converter still holds (its look-ahead) and retires it.
    private func drainConverter(into file: AVAudioFile, track: inout CapturedAudioTrack) throws {
        guard let output = converter.drain() else { return }
        try file.write(from: output)
        track.frameCount += Int64(output.frameLength)
    }

    /// The first failure, as one plain sentence; the system's words go in the track's notes.
    private func recordFailure(_ error: Error) {
        guard errorMessage == nil else { return }
        if CapturedTrackRole.speaksPlainly(error) { errorMessage = error.localizedDescription; return }
        errorMessage = "The \(role.spokenName) recording stopped early. What was recorded is saved."
        notes.append("Writing stopped early: \(error.localizedDescription)")
    }

    func finish() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isFinished = true
                if let file, var current = track, errorMessage == nil {
                    do { try drainConverter(into: file, track: &current); track = current }
                    catch { recordFailure(error) }
                }
                file = nil // Close the CAF before callers import/read it.
                if var track {
                    // Audio dropped after the last buffer written has no gap to pad; it's lost all the same.
                    let lost = progressLock.withLock { () -> TimeInterval in
                        defer { droppedSinceAccepted = 0 }
                        return droppedSinceAccepted
                    }
                    if lost > 0 { gaps.append(CaptureGap(kind: .lost, frame: track.frameCount, seconds: lost)) }
                    track.gaps = gaps.isEmpty ? nil : gaps
                    if let summary = Self.gapSummary(gaps) { notes.append(summary) }
                    if track.lostSeconds > 0 { notes.append(RecordingWords.lostAudio(track.lostSeconds, of: role.audioName)) }
                    track.notes = notes.isEmpty ? nil : notes
                    self.track = track
                    do { try persistTrack(track) }
                    catch { errorMessage = errorMessage ?? "The \(role.spokenName) recording is saved, but its details couldn’t be." }
                }
                continuation.resume(returning: Outcome(track: track, error: errorMessage))
            }
        }
    }

    /// The capture details' line for the silence put in: "3 gaps were filled with silence (8.2 s in all)."
    static func gapSummary(_ gaps: [CaptureGap]) -> String? {
        let filled = gaps.filter { $0.kind == .padded || $0.kind == .lost }
        let skipped = gaps.filter { $0.kind == .skipped }
        var parts: [String] = []
        if !filled.isEmpty {
            let total = RecordingWords.seconds(filled.map(\.seconds).reduce(0, +))
            parts.append(filled.count == 1 ? "1 gap was filled with silence (\(total))." : "\(filled.count) gaps were filled with silence (\(total) in all).")
        }
        if !skipped.isEmpty {
            let total = RecordingWords.seconds(skipped.map(\.seconds).reduce(0, +))
            parts.append(skipped.count == 1 ? "1 gap longer than five minutes was left out (\(total))."
                                            : "\(skipped.count) gaps longer than five minutes were left out (\(total) in all).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func persistTrack(_ track: CapturedAudioTrack) throws {
        try CaptureJSON.persist(track, at: metadataURL)
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let input = source[index].mData, let output = destination[index].mData else { return nil }
            memcpy(output, input, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }
}

enum PCMTrackWriterError: LocalizedError {
    case diskBacklog
    var errorDescription: String? { "The disk couldn’t keep up with the recording. Everything up to then is saved." }
}
