import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation
import IOKit.pwr_mgt

/// Everything the controller needs from the system, injectable so tests drive it with fakes
/// instead of a real microphone, process tap, or ScreenCaptureKit stream.
struct CaptureEnvironment {
    /// Microphone permission; the live version prompts once when undetermined.
    var microphoneAuthorization: @MainActor () async -> Bool
    var makeMicrophone: @MainActor () -> CaptureAudioSource
    var systemAudio: SystemAudioProviding
    var currentRoute: () -> AudioOutputRoute
    /// Starts observing output-route changes; the returned object stops observing when released.
    var observeRoutes: (@escaping @Sendable (AudioOutputRoute) -> Void) -> AnyObject?
    var hostTime: () -> TimeInterval

    static var live: CaptureEnvironment {
        CaptureEnvironment(
            microphoneAuthorization: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return true
                case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
                default: return false
                }
            },
            makeMicrophone: { MicrophoneSource() },
            systemAudio: LiveSystemAudioProvider(),
            currentRoute: { AudioRouteMonitor.currentRoute() },
            observeRoutes: { handler in
                let monitor = AudioRouteMonitor()
                monitor.start(onChange: handler)
                return monitor
            },
            hostTime: { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) })
    }
}

/// Records the microphone and the call as separate native PCM tracks on one host-clock timeline.
///
/// Call audio comes from a Core Audio process tap on the detected call app when one is known, and
/// from ScreenCaptureKit (all Mac playback except Daybook) otherwise or if the tap fails. Device
/// and route changes are followed rather than ending the recording. After Stop, `CaptureFinalizer`
/// removes the call's echo from the microphone; this controller only captures.
@MainActor
final class RecordingController: ObservableObject {
    enum State: String { case idle, starting, recording, stopping }
    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: CaptureResult?
    @Published private(set) var startedAt: Date?
    /// How the call is being recorded (process tap or ScreenCaptureKit) and why.
    @Published private(set) var systemAudioCapture: SystemAudioCaptureInfo?
    /// The current output route; `.headphones` means the call cannot echo into the microphone.
    @Published private(set) var outputRoute: AudioOutputRoute?
    /// Call audio was audible within the last few seconds. Changes rarely, so it is safe to observe
    /// through AppState; per-source meters are on `levels`.
    @Published private(set) var isCallAudioDetected = false
    /// Live "You" and "Call" meters. Observe directly; see `CaptureLevelMonitor`.
    let levels = CaptureLevelMonitor()
    var isRecording: Bool { state == .recording }
    /// Monotonic time shared with audio-track offsets, unaffected by wall-clock edits.
    var elapsedTime: TimeInterval {
        guard let manifest else { return 0 }
        return max(0, environment.hostTime() - manifest.hostTimeSeconds)
    }
    /// Called after an unexpected stop (device failure, revoked permission, sleep).
    /// The partial recording is complete and safe to import at this point.
    var onUnexpectedStop: ((CaptureResult) -> Void)?
    /// Copies each source's live audio to captions (`LiveCaptionsController.prepare`). Set before
    /// `start`; it's read once when a recording starts and dropped when it ends.
    var captionTap: CaptureCaptionTap?

    private let environment: CaptureEnvironment
    private var microphone: CaptureAudioSource?
    private var system: CaptureAudioSource?
    private var microphoneWriter: PCMTrackWriter?
    private var systemWriter: PCMTrackWriter?
    private var manifest: CaptureSessionManifest?
    private var directory: URL?
    private var warnings: [String] = []
    private var routeEvents: [AudioRouteEvent] = []
    private var routeObservation: AnyObject?
    private var meterTimer: Timer?
    private var cancelStart = false
    private var observers: [NSObjectProtocol] = []
    /// This recording's caption tap, on its session timeline.
    private var activeCaptionTap: CaptureCaptionTap?

    /// Runs as the Mac goes to sleep, once the recording has stopped: what must reach other devices
    /// first (stopping the recorders that recorded along). Sleep waits for it, at most `sleepGrace`.
    var beforeSleep: (@MainActor () async -> Void)?
    static let sleepGrace: Duration = .seconds(5)
    private var sleepGate: SystemSleepGate?

    init(environment: CaptureEnvironment = .live) {
        self.environment = environment
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopForSleep() }
        })
        // The notification doesn't hold sleep back; the power notification can, briefly, so stops
        // sent to other devices leave before the network goes.
        sleepGate = SystemSleepGate(grace: Self.sleepGrace) { [weak self] in
            self?.stopForSleep()
            await self?.beforeSleep?()
        }
    }

    private func stopForSleep() {
        captureFailed(RecordingError.interrupted("Recording stopped because the Mac went to sleep. Everything up to then is saved."))
    }

    /// `callApp` is the meeting app to record on its own (from `MeetingMonitor` or the running
    /// apps); without it, call audio is all Mac playback.
    func start(in directory: URL, includeSystemAudio: Bool = true, callApp: CallAppTarget? = nil) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .starting
        lastError = nil
        lastResult = nil
        cancelStart = false
        warnings = []
        routeEvents = []
        systemAudioCapture = nil
        levels.reset()
        do {
            guard !["capture-session.json", "microphone.caf", "systemAudio.caf"].contains(where: {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }) else { throw RecordingError.outputDirectoryInUse }
            guard await environment.microphoneAuthorization() else { throw RecordingError.microphoneDenied }
            try checkStartCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let startDate = Date()
            let manifest = CaptureSessionManifest(id: UUID(), startedAt: startDate, hostTimeSeconds: environment.hostTime(),
                                                  includeSystemAudio: includeSystemAudio, callApp: includeSystemAudio ? callApp : nil)
            self.directory = directory
            self.manifest = manifest
            self.startedAt = startDate
            try CaptureJSON.persist(manifest, at: directory.appendingPathComponent("capture-session.json"))
            let captions = captionTap?.onSessionTimeline(from: manifest.hostTimeSeconds)
            activeCaptionTap = captions
            observeRoutes()

            // Call audio starts first, so permission prompts are answered before the microphone
            // runs and a dialog never leaves a microphone-only recording behind.
            if includeSystemAudio {
                let writer = makeWriter(.systemAudio, manifest: manifest, directory: directory)
                systemWriter = writer
                let callCaptions = captions?.call
                let (source, info) = try await SystemAudioSelector.start(target: callApp, provider: environment.systemAudio,
                    onBuffer: { buffer, time in writer.append(buffer, hostTimeSeconds: time); callCaptions?(buffer, time) },
                    onEvent: { [weak self] event in Task { @MainActor in self?.systemEvent(event) } })
                system = source
                systemAudioCapture = info
                writer.setMethod(info.method.rawValue)
                if let reason = info.fallbackReason, callApp != nil { warnings.append(reason) }
            }
            try checkStartCancellation()
            let micWriter = makeWriter(.microphone, manifest: manifest, directory: directory, method: "microphone")
            microphoneWriter = micWriter
            let mic = environment.makeMicrophone()
            microphone = mic
            let microphoneCaptions = captions?.microphone
            try await mic.start(onBuffer: { buffer, time in micWriter.append(buffer, hostTimeSeconds: time); microphoneCaptions?(buffer, time) },
                                onEvent: { [weak self] event in Task { @MainActor in self?.microphoneEvent(event) } })
            try checkStartCancellation()
            state = .recording
            startMetering()
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

    private func makeWriter(_ role: CapturedTrackRole, manifest: CaptureSessionManifest, directory: URL, method: String? = nil) -> PCMTrackWriter {
        PCMTrackWriter(role: role, directory: directory, manifest: manifest, method: method) { [weak self] error in
            Task { @MainActor in self?.writerFailed(role, error) }
        }
    }

    private func checkStartCancellation() throws {
        if cancelStart { throw CancellationError() }
        if let lastError { throw RecordingError.interrupted(lastError) }
    }

    // MARK: Source and writer events

    private func microphoneEvent(_ event: CaptureSourceEvent) {
        switch event {
        case .deviceChanged(let note):
            microphoneWriter?.markDiscontinuity(note)
            warnings.append(note)
        case .failed(let error):
            captureFailed(error)
        }
    }

    /// Call audio problems never end the recording: a failed tap falls back to ScreenCaptureKit,
    /// and anything else stops only the call track.
    private func systemEvent(_ event: CaptureSourceEvent) {
        guard state == .recording || state == .starting else { return }
        switch event {
        case .deviceChanged(let note):
            systemWriter?.markDiscontinuity(note)
            warnings.append(note)
        case .failed(let error):
            Task { await systemFailed(error) }
        }
    }

    private func writerFailed(_ role: CapturedTrackRole, _ error: Error) {
        if role == .microphone || error is PCMTrackWriterError { captureFailed(error); return }
        guard state == .recording else { return }
        Task { await stopCallTrack(reason: "Call audio stopped: \(error.localizedDescription) The microphone kept recording.") }
    }

    private func systemFailed(_ error: Error) async {
        guard state == .recording, let current = system else { return }
        guard current.method == "process-tap", let writer = systemWriter else {
            await stopCallTrack(reason: "Call audio stopped: \(error.localizedDescription) The microphone kept recording.")
            return
        }
        if case ProcessTapError.silent = error, !environment.systemAudio.screenCaptureAuthorized {
            // Possibly just a quiet call. Switching would show a permission prompt mid-call, so keep
            // the tap (it records again as soon as the app plays sound) and say why it may be silent.
            warnings.append("The call stayed silent. If its audio is missing, allow Daybook in System Settings › Privacy & Security › Screen & System Audio Recording.")
            return
        }
        system = nil
        await current.stop()
        do {
            let screen = try await environment.systemAudio.makeScreenCapture()
            writer.markDiscontinuity("Switched call capture to all Mac audio.")
            let callCaptions = activeCaptionTap?.call
            try await screen.start(onBuffer: { buffer, time in writer.append(buffer, hostTimeSeconds: time); callCaptions?(buffer, time) },
                                   onEvent: { [weak self] event in Task { @MainActor in self?.systemEvent(event) } })
            guard state == .recording else { await screen.stop(); return }
            system = screen
            writer.setMethod(SystemAudioCaptureInfo.Method.screenCaptureKit.rawValue)
            let reason = "Recording only the call app stopped working (\(error.localizedDescription)), so all Mac audio is recorded from here on."
            systemAudioCapture = SystemAudioCaptureInfo(method: .screenCaptureKit, capturedApps: systemAudioCapture?.capturedApps,
                                                        fallbackReason: reason, switchedAt: elapsedTime)
            warnings.append(reason)
        } catch {
            warnings.append("Call audio stopped and could not switch to all Mac audio: \(error.localizedDescription) The microphone kept recording.")
        }
    }

    private func stopCallTrack(reason: String) async {
        warnings.append(reason)
        let current = system
        system = nil
        await current?.stop()
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

    // MARK: Routes and meters

    private func observeRoutes() {
        let route = environment.currentRoute()
        outputRoute = route
        routeEvents = [AudioRouteEvent(time: 0, route: route)]
        routeObservation = environment.observeRoutes { [weak self] route in
            Task { @MainActor in self?.routeChanged(route) }
        }
    }

    private func routeChanged(_ route: AudioOutputRoute) {
        guard manifest != nil, route != outputRoute else { return }
        outputRoute = route
        routeEvents.append(AudioRouteEvent(time: elapsedTime, route: route))
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// Called by the meter timer; internal so tests can sample without waiting on it.
    func updateLevels() {
        guard state == .recording else { return }
        levels.update(microphone: microphoneWriter?.meter.read(), call: system == nil ? nil : systemWriter?.meter.read(),
                      hostTime: environment.hostTime(), elapsed: elapsedTime)
        if levels.isCallAudioDetected != isCallAudioDetected { isCallAudioDetected = levels.isCallAudioDetected }
    }

    // MARK: Finishing

    private func finishCapture() async -> CaptureResult? {
        meterTimer?.invalidate()
        meterTimer = nil
        if let microphone { await microphone.stop() }
        microphone = nil
        if let system { await system.stop() }
        system = nil
        routeObservation = nil
        var tracks: [CapturedAudioTrack] = []
        for writer in [microphoneWriter, systemWriter].compactMap({ $0 }) {
            let outcome = await writer.finish()
            if let track = outcome.track { tracks.append(track) }
            if let error = outcome.error { warnings.append(error) }
        }
        microphoneWriter = nil
        systemWriter = nil
        activeCaptionTap = nil
        var result: CaptureResult?
        if let manifest, let directory {
            if tracks.isEmpty { warnings.append("No audio samples were received.") }
            if manifest.includeSystemAudio && !tracks.contains(where: { $0.role == .systemAudio }) {
                warnings.append("No system audio was received. Check the meeting's output and recording permission.")
            }
            let completed = CaptureResult(id: manifest.id, startedAt: manifest.startedAt, endedAt: Date(), tracks: tracks,
                                          warnings: Array(Set(warnings)).sorted(), directory: directory,
                                          systemAudio: systemAudioCapture, outputRoutes: routeEvents.isEmpty ? nil : routeEvents)
            do { try CaptureJSON.persist(completed, at: directory.appendingPathComponent("capture-result.json")) }
            catch { lastError = "Audio was saved, but recording metadata could not be saved: \(error.localizedDescription)" }
            lastResult = completed
            result = completed
        }
        self.manifest = nil
        self.directory = nil
        startedAt = nil
        isCallAudioDetected = false
        levels.reset()
        state = .idle
        return result
    }
}

/// Holds system sleep back for at most `grace` while `prepare` runs (IOKit's will-sleep power
/// notification, which waits for an acknowledgement; `NSWorkspace.willSleepNotification` doesn't).
@MainActor
final class SystemSleepGate {
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let grace: Duration
    private let prepare: @MainActor () async -> Void

    init(grace: Duration, prepare: @escaping @MainActor () async -> Void) {
        self.grace = grace
        self.prepare = prepare
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let token = Int(bitPattern: argument)
            let gate = Unmanaged<SystemSleepGate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { gate.received(message, token: token) }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
        }
    }

    deinit {
        guard rootPort != 0 else { return }
        var notifier = self.notifier
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    private func received(_ message: UInt32, token: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            let port = rootPort, grace = self.grace, prepare = self.prepare
            Task { @MainActor in
                let done = OnceFlag()
                let allow = { if done.set() { IOAllowPowerChange(port, token) } }
                Task { @MainActor in try? await Task.sleep(for: grace); allow() }
                await prepare()
                allow()
            }
        default:
            break
        }
    }
}
