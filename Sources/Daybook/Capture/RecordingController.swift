import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

enum CapturedTrackRole: String, Codable {
    case microphone
    case systemAudio
}

struct CapturedAudioTrack: Codable, Identifiable, Equatable {
    var id: CapturedTrackRole { role }
    var role: CapturedTrackRole
    var url: URL
    var startedAt: Date
    var firstSampleHostTimeSeconds: TimeInterval
    /// Add this to a transcript timestamp to place it on the session timeline.
    var offsetSeconds: TimeInterval
    var sampleRate: Double
    var channelCount: UInt32
    var frameCount: Int64
    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

struct CaptureResult: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var tracks: [CapturedAudioTrack]
    var warnings: [String]
    var directory: URL
}

struct CaptureSessionManifest: Codable {
    var id: UUID
    var startedAt: Date
    var hostTimeSeconds: TimeInterval
    var includeSystemAudio: Bool
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case noMicrophone
    case noDisplay
    case outputDirectoryInUse
    case invalidAudio
    case audioFormatChanged
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .microphoneDenied: return "Allow Daybook to use the microphone in System Settings → Privacy & Security → Microphone."
        case .noMicrophone: return "No microphone is available. Connect an input device and try again."
        case .noDisplay: return "System audio capture needs an active display and Screen & System Audio Recording permission."
        case .outputDirectoryInUse: return "This recording folder already contains captured audio. A new folder is required to preserve the existing recording."
        case .invalidAudio: return "The audio device supplied an unsupported audio buffer."
        case .audioFormatChanged: return "The audio device changed during recording. The completed audio has been preserved; start a new recording with the new device."
        case .interrupted(let reason): return reason
        }
    }
}

/// Records native PCM audio without a remote service. ScreenCaptureKit provides
/// system audio; no video output is registered and no screen images are stored.
@MainActor
final class RecordingController: ObservableObject {
    enum State: String { case idle, starting, recording, stopping }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: CaptureResult?
    @Published private(set) var startedAt: Date?
    var isRecording: Bool { state == .recording }
    /// Monotonic time shared with audio-track offsets, unaffected by wall-clock edits.
    var elapsedTime: TimeInterval {
        guard let manifest else { return 0 }
        return max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - manifest.hostTimeSeconds)
    }
    /// Called after an unexpected stop (device failure, revoked permission, sleep).
    /// The partial recording is complete and safe to import at this point.
    var onUnexpectedStop: ((CaptureResult) -> Void)?

    private var engine: AVAudioEngine?
    private var microphoneTapInstalled = false
    private var stream: SCStream?
    private var streamOutput: SystemAudioOutput?
    private var microphoneWriter: PCMTrackWriter?
    private var systemWriter: PCMTrackWriter?
    private var manifest: CaptureSessionManifest?
    private var directory: URL?
    private var warnings: [String] = []
    private var cancelStart = false
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.captureFailed(RecordingError.interrupted("Recording stopped because the Mac is going to sleep. Recorded audio has been preserved.")) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let changedEngine = notification.object as? AVAudioEngine, changedEngine === self.engine else { return }
                self.captureFailed(RecordingError.audioFormatChanged)
            }
        })
    }

    func start(in directory: URL, includeSystemAudio: Bool = true) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .starting
        lastError = nil
        lastResult = nil
        cancelStart = false
        warnings = []
        do {
            guard !["capture-session.json", "microphone.caf", "systemAudio.caf"].contains(where: {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }) else { throw RecordingError.outputDirectoryInUse }
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard granted else { throw RecordingError.microphoneDenied }
            try checkStartCancellation()

            // Request system permission before starting the mic, avoiding a partial
            // microphone-only recording while a permission dialog is unanswered.
            var filter: SCContentFilter?
            if includeSystemAudio {
                let content: SCShareableContent
                do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
                catch {
                    throw RecordingError.interrupted("System audio is unavailable. Allow Daybook in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch if macOS requests it. \(error.localizedDescription)")
                }
                guard let display = content.displays.first else { throw RecordingError.noDisplay }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
            try checkStartCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let startDate = Date()
            let anchor = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let manifest = CaptureSessionManifest(id: UUID(), startedAt: startDate, hostTimeSeconds: anchor, includeSystemAudio: includeSystemAudio)
            self.directory = directory
            self.manifest = manifest
            self.startedAt = startDate
            try Self.persist(manifest, at: directory.appendingPathComponent("capture-session.json"))

            let failure: (Error) -> Void = { [weak self] error in
                Task { @MainActor in self?.captureFailed(error) }
            }
            let micWriter = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest, failure: failure)
            self.microphoneWriter = micWriter
            let audioEngine = AVAudioEngine()
            self.engine = audioEngine
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 && format.channelCount > 0 else { throw RecordingError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                guard let copied = PCMTrackWriter.copy(buffer) else {
                    failure(RecordingError.invalidAudio)
                    return
                }
                let hostSeconds = time.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: time.hostTime)
                    : CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
                micWriter.append(copied, hostTimeSeconds: hostSeconds)
            }
            microphoneTapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()

            if let filter {
                let writer = PCMTrackWriter(role: .systemAudio, directory: directory, manifest: manifest, failure: failure)
                systemWriter = writer
                let output = SystemAudioOutput(writer: writer, failure: failure)
                streamOutput = output
                let configuration = SCStreamConfiguration()
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.showsCursor = false
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 2
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                self.stream = stream
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
            }
            try checkStartCancellation()
            state = .recording
        } catch {
            lastError = error.localizedDescription
            warnings.append(error.localizedDescription)
            state = .stopping
            _ = await finishCapture()
            throw error
        }
    }

    /// Always finalizes whatever audio was captured, even if one source failed.
    @discardableResult
    func stop() async -> CaptureResult? {
        if state == .starting {
            cancelStart = true
            return nil
        }
        guard state == .recording else { return nil }
        state = .stopping
        return await finishCapture()
    }

    private func checkStartCancellation() throws {
        if cancelStart { throw CancellationError() }
        if let lastError { throw RecordingError.interrupted(lastError) }
    }

    private func captureFailed(_ error: Error) {
        guard state == .recording || state == .starting else { return }
        lastError = error.localizedDescription
        if state == .starting { return }
        warnings.append(error.localizedDescription)
        state = .stopping
        Task {
            if let result = await finishCapture() { onUnexpectedStop?(result) }
        }
    }

    private func finishCapture() async -> CaptureResult? {
        engine?.stop()
        if microphoneTapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        engine = nil
        if let stream {
            do { try await stream.stopCapture() }
            catch { warnings.append("System audio stopped with: \(error.localizedDescription)") }
        }
        stream = nil
        // Drain all ScreenCaptureKit callbacks before closing the writers.
        if let output = streamOutput { await output.drain() }
        streamOutput = nil
        var tracks: [CapturedAudioTrack] = []
        for writer in [microphoneWriter, systemWriter].compactMap({ $0 }) {
            let outcome = await writer.finish()
            if let track = outcome.track { tracks.append(track) }
            if let error = outcome.error { warnings.append(error) }
        }
        microphoneWriter = nil
        systemWriter = nil
        var result: CaptureResult?
        if let manifest, let directory {
            if tracks.isEmpty { warnings.append("No audio samples were received.") }
            if manifest.includeSystemAudio && !tracks.contains(where: { $0.role == .systemAudio }) {
                warnings.append("No system audio was received. Check the meeting's output and recording permission.")
            }
            let completed = CaptureResult(id: manifest.id, startedAt: manifest.startedAt, endedAt: Date(), tracks: tracks,
                                          warnings: Array(Set(warnings)).sorted(), directory: directory)
            do { try Self.persist(completed, at: directory.appendingPathComponent("capture-result.json")) }
            catch { lastError = "Audio was saved, but recording metadata could not be saved: \(error.localizedDescription)" }
            lastResult = completed
            result = completed
        }
        self.manifest = nil
        self.directory = nil
        startedAt = nil
        state = .idle
        return result
    }

    private static func persist<T: Encodable>(_ value: T, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// All file mutation happens on a serial queue, never the real-time input thread.
final class PCMTrackWriter: @unchecked Sendable {
    struct Outcome { var track: CapturedAudioTrack?; var error: String? }
    private let queue = DispatchQueue(label: "app.daybook.audio-writer", qos: .userInitiated)
    private let role: CapturedTrackRole
    private let url: URL
    private let metadataURL: URL
    private let manifest: CaptureSessionManifest
    private let failure: (Error) -> Void
    private var file: AVAudioFile?
    private var track: CapturedAudioTrack?
    private var errorMessage: String?
    private var isFinished = false
    private var lastMetadataWrite: TimeInterval = -.infinity
    private let pendingSlots = DispatchSemaphore(value: 256)
    private let overflowLock = NSLock()
    private var overflowReported = false

    init(role: CapturedTrackRole, directory: URL, manifest: CaptureSessionManifest, failure: @escaping (Error) -> Void) {
        self.role = role
        self.url = directory.appendingPathComponent(role.rawValue + ".caf")
        self.metadataURL = directory.appendingPathComponent(role.rawValue + ".json")
        self.manifest = manifest
        self.failure = failure
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTimeSeconds: TimeInterval) {
        guard pendingSlots.wait(timeout: .now()) == .success else {
            overflowLock.lock()
            let shouldReport = !overflowReported
            overflowReported = true
            overflowLock.unlock()
            if shouldReport { failure(RecordingError.interrupted("The disk could not keep up with audio recording. Captured audio has been preserved.")) }
            return
        }
        queue.async { [self] in
            defer { pendingSlots.signal() }
            guard !isFinished, errorMessage == nil, buffer.frameLength > 0 else { return }
            do {
                if file == nil {
                    file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                           commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    let offset = hostTimeSeconds - manifest.hostTimeSeconds
                    track = CapturedAudioTrack(role: role, url: url,
                        startedAt: manifest.startedAt.addingTimeInterval(offset), firstSampleHostTimeSeconds: hostTimeSeconds,
                        offsetSeconds: offset, sampleRate: buffer.format.sampleRate,
                        channelCount: buffer.format.channelCount, frameCount: 0)
                }
                guard let file, var current = track, file.processingFormat == buffer.format else {
                    throw RecordingError.audioFormatChanged
                }
                // Preserve clock gaps as silence, so transcript seconds still map to
                // capture time. A large discontinuity likely means sleep/device loss.
                let expectedTime = current.firstSampleHostTimeSeconds + current.duration
                let gap = hostTimeSeconds - expectedTime
                guard gap.isFinite else { throw RecordingError.invalidAudio }
                if gap > 5 || gap < -0.1 {
                    throw RecordingError.interrupted("The \(role.rawValue) audio clock was interrupted. Recorded audio has been preserved.")
                }
                if gap > 0.08 {
                    let count = AVAudioFrameCount((gap * current.sampleRate).rounded())
                    if let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) {
                        silence.frameLength = count
                        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                        }
                        try file.write(from: silence)
                        current.frameCount += Int64(count)
                    }
                }
                try file.write(from: buffer)
                current.frameCount += Int64(buffer.frameLength)
                track = current
                if hostTimeSeconds - lastMetadataWrite >= 10 {
                    try persistTrack(current)
                    lastMetadataWrite = hostTimeSeconds
                }
            } catch {
                errorMessage = error.localizedDescription
                failure(error)
            }
        }
    }

    func finish() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isFinished = true
                file = nil // Close the CAF before callers import/read it.
                if let track {
                    do { try persistTrack(track) }
                    catch { errorMessage = errorMessage ?? error.localizedDescription }
                }
                continuation.resume(returning: Outcome(track: track, error: errorMessage))
            }
        }
    }

    private func persistTrack(_ track: CapturedAudioTrack) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(track).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
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

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.daybook.system-audio", qos: .userInitiated)
    private let writer: PCMTrackWriter
    private let failure: (Error) -> Void

    init(writer: PCMTrackWriter, failure: @escaping (Error) -> Void) {
        self.writer = writer
        self.failure = failure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            return
        }
        writer.append(buffer, hostTimeSeconds: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { failure(error) }

    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
