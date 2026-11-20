import AVFoundation
import CoreAudio
import CoreMedia
import DaybookKit
import Foundation

/// The part of `AVAudioEngine` the microphone uses, so its restart rules are tested without a device.
protocol MicrophoneEngine: AnyObject {
    /// Called on the main queue when the input device or its format changes and the engine has stopped for it; a
    /// configuration notice the engine keeps running through is not a change.
    var onConfigurationChange: (() -> Void)? { get set }
    /// Sets `device` (a Core Audio UID; nil leaves the system's default input) on the input before anything starts,
    /// starts delivering it, and returns its format. Throws when it can't start: no device, one that's gone, or one
    /// that reports 0 Hz for a moment after a switch.
    func start(device: String?, deliver: @escaping CaptureBufferHandler, report: @escaping CaptureEventHandler) throws -> AVAudioFormat
    func stop()
}

/// The chosen input through AVAudioEngine, without Apple voice processing.
///
/// Voice processing (`setVoiceProcessingEnabled`) is deliberately off: it ducks other audio
/// (including the call the person is listening to), applies gain control and noise suppression
/// that cannot be undone, and cancels echo against its own output path rather than against the
/// call track Daybook records. Daybook keeps the raw microphone as the original and removes the
/// call's echo offline from the recorded call track instead.
///
/// The input is `MicrophoneChoice`'s: the person's choice, or Automatic, which records the default input unless that's
/// a Bluetooth headset no other app is recording from (then the built-in microphone, so headphones never switch to
/// call mode for Daybook). It's set on the engine's input unit before the engine starts.
///
/// When the input or its format changes (AirPods connecting, or switching to the hands-free profile when an app opens
/// their microphone), when an input comes or goes or the default input changes so the choice resolves elsewhere, when
/// the input in use stops being alive, or when the person chooses another, this source starts again on the input the
/// choice resolves to now and continues; the writer converts the new format to the file's. Restarts are limited by
/// rate, not count (more than `restartLimit` in `restartWindow` is a failure), so AirPods coming and going all day
/// never end a recording. A start that fails (a new device reporting 0 Hz for a moment) is tried again after 0.25, 0.5,
/// 1, and 2 s, then on the built-in microphone, before the microphone counts as failed.
final class MicrophoneSource: CaptureAudioSource, @unchecked Sendable {
    let method = "microphone"
    private let engine: MicrophoneEngine
    private let devices: MicrophoneDevices
    private let reportInput: @Sendable (MicrophoneChoice.Device?) -> Void
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) async -> Void
    private var onBuffer: CaptureBufferHandler?
    private var onEvent: CaptureEventHandler?
    // Main-actor state once started.
    private var running = false
    private var restarting = false
    private var restartPending: Cause?
    private var restartTimes: [TimeInterval] = []
    /// The input recording now; nil when the system's default is used without a list to choose from.
    private var current: MicrophoneChoice.Device?

    static let restartLimit = 10
    static let restartWindow: TimeInterval = 60
    /// Waits before each further try of a start that failed.
    static let retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2]

    /// - Parameter reportInput: Told the input in use as it changes, and nil once stopped (Floating Notes names it).
    init(engine: MicrophoneEngine = AVMicrophoneEngine(),
         devices: MicrophoneDevices = CoreAudioMicrophoneDevices(),
         reportInput: @escaping @Sendable (MicrophoneChoice.Device?) -> Void = { MicrophoneInUse.report($0) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.engine = engine
        self.devices = devices
        self.reportInput = reportInput
        self.now = now
        self.pause = pause
    }

    /// The input being recorded.
    var currentInput: MicrophoneChoice.Device? { current }

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        self.onBuffer = onBuffer
        self.onEvent = onEvent
        engine.onConfigurationChange = { [weak self] in
            Task { @MainActor in await self?.follow(.deviceChanged) }
        }
        let snapshot = devices.snapshot()
        let chosen = snapshot.resolved
        do {
            _ = try engine.start(device: deviceToSet(chosen, in: snapshot), deliver: onBuffer, report: onEvent)
            current = chosen
        } catch {
            // A chosen input that won't start: the Mac's own microphone, rather than no recording.
            engine.stop()
            guard let builtIn = snapshot.builtIn, builtIn.id != chosen?.id,
                  (try? engine.start(device: deviceToSet(builtIn, in: snapshot), deliver: onBuffer, report: onEvent)) != nil else { throw error }
            current = builtIn
        }
        running = true
        devices.onChange = { [weak self] in
            Task { @MainActor in await self?.follow(.inputsChanged) }
        }
        devices.follow(current?.id)
        reportInput(current)
    }

    func stop() async {
        running = false
        engine.onConfigurationChange = nil
        devices.onChange = nil
        devices.follow(nil)
        engine.stop()
        onBuffer = nil
        current = nil
        reportInput(nil)
    }

    @MainActor func restart(_ reason: CaptureRestartReason) async {
        await follow(reason == .stalled ? Cause.stalled : Cause.audioSystemRestarted)
    }

    private enum Cause: Equatable {
        /// The engine's input or format changed.
        case deviceChanged
        /// An input came or went, the default changed, the input in use died, or the person chose another.
        case inputsChanged
        case stalled, audioSystemRestarted

        var isRestart: Bool { self == .stalled || self == .audioSystemRestarted }
    }

    /// Follows the input the choice resolves to (or starts the engine again) instead of ending the recording. One
    /// restart at a time; a change that arrives during one is followed once it's done. A change that leaves the choice
    /// where it was (another app's device coming or going) restarts nothing.
    @MainActor private func follow(_ cause: Cause) async {
        guard running, let deliver = onBuffer, let report = onEvent else { return }
        guard !restarting else {
            restartPending = restartPending ?? cause
            return
        }
        if cause == .inputsChanged, devices.snapshot().resolved?.id == current?.id { return }
        let time = now()
        restartTimes = restartTimes.filter { time - $0 < Self.restartWindow } + [time]
        guard restartTimes.count <= Self.restartLimit else {
            running = false
            engine.stop()
            report(.failed(RecordingError.interrupted(cause.isRestart
                ? "The microphone stopped delivering audio, so recording stopped. Everything up to then is saved."
                : "The microphone kept changing, so recording stopped. Everything up to then is saved.")))
            return
        }
        restarting = true
        defer { restarting = false }
        engine.stop()
        var lastError: Error = RecordingError.noMicrophone
        var snapshot = devices.snapshot()
        for delay in [0] + Self.retryDelays {
            if delay > 0 {
                await pause(delay)
                // An input that died meanwhile has left the list, so the next try resolves past it.
                snapshot = devices.snapshot()
            }
            guard running else { return }
            let target = snapshot.resolved
            do {
                let format = try engine.start(device: deviceToSet(target, in: snapshot), deliver: deliver, report: report)
                moved(to: target)
                report(cause.isRestart ? .restarted(note(cause, format: format)) : .deviceChanged(note(cause, format: format)))
                await followPending()
                return
            } catch {
                lastError = error
                engine.stop()
            }
        }
        // The input that's there won't start: the Mac's own microphone, before giving up.
        guard running else { return }
        if let builtIn = snapshot.builtIn,
           let format = try? engine.start(device: deviceToSet(builtIn, in: snapshot), deliver: deliver, report: report) {
            moved(to: builtIn)
            report(.deviceChanged("The microphone couldn’t start, so recording moved to the Mac’s built-in microphone (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)."))
            await followPending()
            return
        }
        engine.stop()
        running = false
        report(.failed(lastError))
    }

    /// The device to set on the engine: none when the input is the system's default, which the engine records on its
    /// own. Setting one, even the default's, makes the engine reconfigure once after it starts (macOS 27.0), posting a
    /// configuration change and now and then stopping for it; so only an input that isn't the default is set.
    private func deviceToSet(_ device: MicrophoneChoice.Device?, in snapshot: MicrophoneChoice.Snapshot) -> String? {
        guard let device, device.id != snapshot.systemDefault else { return nil }
        return device.id
    }

    @MainActor private func moved(to device: MicrophoneChoice.Device?) {
        current = device
        devices.follow(device?.id)
        reportInput(device)
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
        case .deviceChanged, .inputsChanged:
            guard let name = current?.name else { return "The microphone changed (\(now)); recording continued." }
            return "The microphone changed to \(name) (\(now)); recording continued."
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

    func start(device: String?, deliver: @escaping CaptureBufferHandler, report: @escaping CaptureEventHandler) throws -> AVAudioFormat {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            // On the input unit before it starts, so the system's default input (idle AirPods, say) is never opened.
            guard let object = CoreAudioInputs.object(for: device) else { throw RecordingError.noMicrophone }
            try input.auAudioUnit.setDeviceID(object)
        }
        // The device's own format. The node's output format is the previous device's until the engine starts, and
        // a tap at the wrong rate is never created (macOS 27.0: "Failed to create tap, config change pending").
        let format = input.inputFormat(forBus: 0)
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
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            // A device or format that really changed stops the engine. After a start on a set device the engine
            // posts one notice while it keeps running; following that restarted the engine, which set the device
            // and posted again, ten times in two seconds (v0.8.0's recordings).
            guard let engine, !engine.isRunning else { return }
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
}
