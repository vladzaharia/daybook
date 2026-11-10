import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// The part of `AVAudioEngine` the microphone uses, so its restart rules are tested without a device.
protocol MicrophoneEngine: AnyObject {
    /// Called on the main queue when the input device or its format changes (the engine has stopped).
    var onConfigurationChange: (() -> Void)? { get set }
    /// Starts delivering the input (the system's default, or the Mac's built-in microphone) and returns its
    /// format. Throws when it can't start: no device, or one that reports 0 Hz for a moment after a switch.
    func start(builtIn: Bool, deliver: @escaping CaptureBufferHandler, report: @escaping CaptureEventHandler) throws -> AVAudioFormat
    func stop()
}

/// The default input device through AVAudioEngine, without Apple voice processing.
///
/// Voice processing (`setVoiceProcessingEnabled`) is deliberately off: it ducks other audio
/// (including the call the person is listening to), applies gain control and noise suppression
/// that cannot be undone, and cancels echo against its own output path rather than against the
/// call track Daybook records. Daybook keeps the raw microphone as the original and removes the
/// call's echo offline from the recorded call track instead.
///
/// When the input device or its format changes (AirPods connecting, or switching to the hands-free
/// profile when an app opens their microphone), the engine stops. This source starts again on the
/// new input and continues; the writer converts the new format to the file's. Restarts are limited
/// by rate, not count (more than `restartLimit` in `restartWindow` is a failure), so AirPods coming
/// and going all day never end a recording. A start that fails (a new device reporting 0 Hz for a
/// moment) is tried again after 0.25, 0.5, 1, and 2 s, then on the built-in microphone, before the
/// microphone counts as failed.
final class MicrophoneSource: CaptureAudioSource, @unchecked Sendable {
    let method = "microphone"
    private let engine: MicrophoneEngine
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) async -> Void
    private var onBuffer: CaptureBufferHandler?
    private var onEvent: CaptureEventHandler?
    // Main-actor state once started.
    private var running = false
    private var restarting = false
    private var restartPending: Cause?
    private var restartTimes: [TimeInterval] = []

    static let restartLimit = 10
    static let restartWindow: TimeInterval = 60
    /// Waits before each further try of a start that failed.
    static let retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]

    init(engine: MicrophoneEngine = AVMicrophoneEngine(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.engine = engine
        self.now = now
        self.pause = pause
    }

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        self.onBuffer = onBuffer
        self.onEvent = onEvent
        engine.onConfigurationChange = { [weak self] in
            Task { @MainActor in await self?.follow(.deviceChanged) }
        }
        _ = try engine.start(builtIn: false, deliver: onBuffer, report: onEvent)
        running = true
    }

    func stop() async {
        running = false
        engine.onConfigurationChange = nil
        engine.stop()
        onBuffer = nil
    }

    @MainActor func restart(_ reason: CaptureRestartReason) async {
        await follow(reason == .stalled ? Cause.stalled : Cause.audioSystemRestarted)
    }

    private enum Cause: Equatable { case deviceChanged, stalled, audioSystemRestarted }

    /// Follows the new input (or starts the engine again) instead of ending the recording. One restart at a time;
    /// a change that arrives during one is followed once it's done.
    @MainActor private func follow(_ cause: Cause) async {
        guard running, let deliver = onBuffer, let report = onEvent else { return }
        guard !restarting else {
            restartPending = restartPending ?? cause
            return
        }
        let time = now()
        restartTimes = restartTimes.filter { time - $0 < Self.restartWindow } + [time]
        guard restartTimes.count <= Self.restartLimit else {
            running = false
            engine.stop()
            report(.failed(RecordingError.interrupted(cause == .deviceChanged
                ? "The microphone kept changing, so recording stopped. Everything up to then is saved."
                : "The microphone stopped delivering audio, so recording stopped. Everything up to then is saved.")))
            return
        }
        restarting = true
        defer { restarting = false }
        engine.stop()
        var lastError: Error = RecordingError.noMicrophone
        for delay in [0] + Self.retryDelays {
            if delay > 0 { await pause(delay) }
            guard running else { return }
            do {
                let format = try engine.start(builtIn: false, deliver: deliver, report: report)
                report(cause == .deviceChanged ? .deviceChanged(note(cause, format: format)) : .restarted(note(cause, format: format)))
                await followPending()
                return
            } catch {
                lastError = error
                engine.stop()
            }
        }
        // The input that's there won't start: the Mac's own microphone, before giving up.
        guard running else { return }
        if let format = try? engine.start(builtIn: true, deliver: deliver, report: report) {
            report(.deviceChanged("The microphone couldn’t start, so recording moved to the Mac’s built-in microphone (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)."))
            await followPending()
            return
        }
        engine.stop()
        running = false
        report(.failed(lastError))
    }

    @MainActor private func followPending() async {
        guard let pending = restartPending else { return }
        restartPending = nil
        restarting = false
        await follow(pending)
    }

    private func note(_ cause: Cause, format: AVAudioFormat) -> String {
        let now = "now \(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
        switch cause {
        case .deviceChanged: return "The microphone changed (\(now)); recording continued."
        case .stalled: return CaptureRestartReason.stalled.note("microphone") + " (\(now))"
        case .audioSystemRestarted: return CaptureRestartReason.audioSystemRestarted.note("microphone") + " (\(now))"
        }
    }
}

/// The live engine: a fresh `AVAudioEngine` for each start, so nothing a failed or restarted audio system left
/// behind carries over.
final class AVMicrophoneEngine: MicrophoneEngine, @unchecked Sendable {
    var onConfigurationChange: (() -> Void)?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    func start(builtIn: Bool, deliver: @escaping CaptureBufferHandler, report: @escaping CaptureEventHandler) throws -> AVAudioFormat {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if builtIn {
            guard let device = Self.builtInInput(), let unit = input.audioUnit else { throw RecordingError.noMicrophone }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw RecordingError.noMicrophone }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { throw RecordingError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let copied = PCMTrackWriter.copy(buffer) else {
                report(.failed(RecordingError.invalidAudio))
                return
            }
            let hostSeconds = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            deliver(copied, hostSeconds)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
        return format
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    /// The Mac's own microphone: the built-in device with input streams.
    static func builtInInput() -> AudioDeviceID? {
        let devices: [AudioObjectID] = (try? CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)) ?? []
        return devices.first { device in
            let transport: UInt32? = CoreAudioProperty.scalar(device, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
        }
    }
}
