import AVFoundation
import DaybookCore
import Foundation

/// Thread-safe level meter fed by capture callbacks and read by the UI timer.
final class AudioLevelMeter: @unchecked Sendable {
    struct Reading: Equatable {
        /// Root-mean-square level of the latest buffers, in dBFS.
        var rms: Float
        /// Highest sample magnitude since the previous read, in dBFS.
        var peak: Float
        /// Host time of the most recent buffer whose level exceeded `audibleThreshold`.
        var lastAudibleHostTime: TimeInterval?
        /// True once any non-zero sample arrived; all-zero input usually means a muted or denied device.
        var receivedSignal: Bool
        static let silent = Reading(rms: -160, peak: -160, lastAudibleHostTime: nil, receivedSignal: false)
    }

    static let audibleThreshold: Float = -50
    private let lock = NSLock()
    private var reading = Reading.silent
    private var peakSinceRead: Float = -160

    func record(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) {
        guard let level = AudioBufferLevel.measure(buffer) else { return }
        lock.lock()
        reading.rms = level.rms
        peakSinceRead = max(peakSinceRead, level.peak)
        reading.peak = peakSinceRead
        if level.hasSignal { reading.receivedSignal = true }
        if level.rms >= Self.audibleThreshold { reading.lastAudibleHostTime = hostTime }
        lock.unlock()
    }

    /// The current reading; resets the peak hold.
    func read() -> Reading {
        lock.lock(); defer { lock.unlock() }
        let value = reading
        peakSinceRead = reading.rms
        return value
    }

    func reset() {
        lock.lock(); reading = .silent; peakSinceRead = -160; lock.unlock()
    }
}

/// All file mutation happens on a serial queue, never the real-time input thread.
///
/// Timing: every buffer's host time is compared with the time predicted from the most recent
/// clock anchor (at most about a second old), so slow device-clock drift is never mistaken for a
/// gap. Real gaps over 80 ms are padded with silence; jumps over five seconds forward or 100 ms
/// backward stop the track. Anchors are kept in the sidecar so drift can be measured and corrected
/// after recording.
///
/// A buffer in a different format (a device switch, AirPods changing profile) is converted to the
/// file's format so the recording continues; the next anchor is marked as a resync.
final class PCMTrackWriter: @unchecked Sendable {
    struct Outcome { var track: CapturedAudioTrack?; var error: String? }
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
    private let pendingSlots = DispatchSemaphore(value: 256)
    private let overflowLock = NSLock()
    private var overflowReported = false
    static let anchorInterval: TimeInterval = 1

    init(role: CapturedTrackRole, directory: URL, manifest: CaptureSessionManifest, method: String? = nil,
         failure: @escaping (Error) -> Void) {
        self.role = role
        self.url = directory.appendingPathComponent(role.rawValue + ".caf")
        self.metadataURL = directory.appendingPathComponent(role.rawValue + ".json")
        self.manifest = manifest
        self.method = method
        self.failure = failure
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTimeSeconds: TimeInterval) {
        guard pendingSlots.wait(timeout: .now()) == .success else {
            overflowLock.lock()
            let shouldReport = !overflowReported
            overflowReported = true
            overflowLock.unlock()
            if shouldReport { failure(PCMTrackWriterError.diskBacklog) }
            return
        }
        meter.record(buffer, hostTime: hostTimeSeconds)
        queue.async { [self] in
            defer { pendingSlots.signal() }
            guard !isFinished, errorMessage == nil, buffer.frameLength > 0 else { return }
            do { try write(buffer, hostTimeSeconds: hostTimeSeconds) }
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

    private func write(_ input: AVAudioPCMBuffer, hostTimeSeconds: TimeInterval) throws {
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: input.format.settings,
                                   commonFormat: input.format.commonFormat, interleaved: input.format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

        // Compare with the time predicted from the latest anchor, so drift never reads as a gap.
        if let anchor = lastAnchor, !pendingResync {
            let expected = anchor.hostTime + Double(current.frameCount - anchor.frame) / current.sampleRate
            let gap = hostTimeSeconds - expected
            guard gap.isFinite else { throw RecordingError.invalidAudio }
            if gap > 5 || gap < -0.1 {
                throw RecordingError.interrupted("The \(role.rawValue) audio clock was interrupted. Everything up to then is saved.")
            }
            if gap > 0.08 {
                try writeSilence(seconds: gap, format: buffer.format, to: file, track: &current)
                pendingResync = true
            }
        } else if let anchor = lastAnchor, pendingResync {
            // After a device change the new stream may start late; keep the timeline by padding.
            let expected = anchor.hostTime + Double(current.frameCount - anchor.frame) / current.sampleRate
            let gap = hostTimeSeconds - expected
            if gap.isFinite && gap > 0.08 && gap <= 5 {
                try writeSilence(seconds: gap, format: buffer.format, to: file, track: &current)
            }
        }
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

    private func writeSilence(seconds: TimeInterval, format: AVAudioFormat, to file: AVAudioFile, track: inout CapturedAudioTrack) throws {
        let count = AVAudioFrameCount((seconds * track.sampleRate).rounded())
        guard count > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        silence.frameLength = count
        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        try file.write(from: silence)
        track.frameCount += Int64(count)
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
                    track.notes = notes.isEmpty ? nil : notes
                    self.track = track
                    do { try persistTrack(track) }
                    catch { errorMessage = errorMessage ?? "The \(role.spokenName) recording is saved, but its details couldn’t be." }
                }
                continuation.resume(returning: Outcome(track: track, error: errorMessage))
            }
        }
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
