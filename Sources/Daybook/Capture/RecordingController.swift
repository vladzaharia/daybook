import AppKit
import AVFoundation
import CoreMedia
import DaybookDevices
import DaybookKit
import Foundation
import IOKit.pwr_mgt
import Observation

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
    /// Free bytes on the volume that holds a folder, for the space watch; nil when it can't be read.
    var freeSpace: (URL) -> Int64? = { _ in nil }
    /// Keeps the Mac from idle-sleeping while true.
    var keepAwake: @MainActor (Bool) -> Void = { _ in }
    /// Starts hearing the audio system (coreaudiod) restart; the returned object stops listening when released.
    var observeAudioServiceRestarts: (@escaping @Sendable () -> Void) -> AnyObject? = { _ in nil }
    /// How the track writers buffer, and when one is given up on.
    var writing = CaptureWriting()

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
            hostTime: { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) },
            freeSpace: { url in
                (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
            },
            keepAwake: { RecordingAwake.assertion.hold($0) },
            observeAudioServiceRestarts: { AudioServiceRestartMonitor(onRestart: $0) })
    }
}

/// How track writers buffer while the disk is busy, and when one that stopped moving is given up on.
struct CaptureWriting {
    /// Seconds of audio a writer holds before it drops (and counts) what arrives.
    var maximumBacklog: TimeInterval = PCMTrackWriter.defaultBacklog
    /// A writer with audio waiting that hasn't finished any for this long stops its track: the microphone's stops
    /// the recording, the call's only the call.
    var stallLimit: TimeInterval = 60
    /// Runs on a writer's queue before each buffer; tests stall the disk with it.
    var beforeWrite: (@Sendable (CapturedTrackRole) -> Void)?
}

/// A call source that delivered nothing through `RecordingController.stalledRestartLimit` restarts.
struct CallAudioStalled: LocalizedError {
    var errorDescription: String? { "call audio stopped arriving, even after restarting" }
}

/// The idle-sleep assertion a recording holds.
@MainActor
enum RecordingAwake {
    static let assertion = SleepAssertion(reason: "Recording a conversation")
}

/// Records the microphone and the call as separate native PCM tracks on one host-clock timeline.
///
/// Call audio comes from a Core Audio process tap on the detected call app when one is known, and
/// from ScreenCaptureKit (all Mac playback except Daybook) otherwise or if the tap fails; when neither starts and no
/// call app is known, the microphone records alone (`computerAudioLeftOut`). Device
/// and route changes are followed rather than ending the recording. After Stop, `CaptureFinalizer`
/// removes the call's echo from the microphone; this controller only captures.
///
/// A recording ends only when someone stops it, the microphone fails for good, a writer stops moving for a
/// minute, or the Mac is put to sleep. Its 15 Hz meter timer also watches: a source that delivers nothing for 3 s
/// is restarted, the free space is measured against the byte rate every 30 s, and the microphone's rolling hearing
/// check says when it hears nothing.
@MainActor
@Observable
final class RecordingController {
    enum State: String { case idle, starting, recording, stopping }
    private(set) var state: State = .idle
    private(set) var lastError: String?
    private(set) var lastResult: CaptureResult?
    private(set) var startedAt: Date?
    /// How the call is being recorded (process tap or ScreenCaptureKit) and why.
    private(set) var systemAudioCapture: SystemAudioCaptureInfo?
    /// The current output route; `.headphones` means the call cannot echo into the microphone.
    private(set) var outputRoute: AudioOutputRoute?
    /// Call audio was audible within the last few seconds. Changes rarely, so any view may read it;
    /// per-source meters are on `levels`.
    private(set) var isCallAudioDetected = false
    /// Seconds of recording the disk has room for at the current rate, once that's under `spaceWarning`; nil above.
    private(set) var spaceLeft: TimeInterval?
    /// Call audio stopped to leave the disk's last minutes to the microphone.
    private(set) var callStoppedForSpace = false
    /// The last recording ended because the Mac went to sleep. The devices recording along aren't stopped for it.
    @ObservationIgnored private(set) var stoppedForSleep = false
    /// Live "You" and "Call" meters; see `CaptureLevelMonitor`.
    let levels = CaptureLevelMonitor()
    var isRecording: Bool { state == .recording }
    /// Monotonic time shared with audio-track offsets, unaffected by wall-clock edits.
    var elapsedTime: TimeInterval {
        guard let manifest else { return 0 }
        return max(0, environment.hostTime() - manifest.hostTimeSeconds)
    }
    /// What an unexpected stop says when its cause isn't one of Daybook's own.
    static let unexpectedStopSentence = "Recording stopped unexpectedly. What was recorded is saved."
    /// Called after an unexpected stop (device failure, revoked permission, sleep) with the partial recording,
    /// complete and safe to import, and one sentence saying why it stopped.
    @ObservationIgnored var onUnexpectedStop: ((CaptureResult, String) -> Void)?
    /// Copies each source's live audio to captions (`LiveCaptionsController.prepare`). Set before
    /// `start`; it's read once when a recording starts and dropped when it ends.
    @ObservationIgnored var captionTap: CaptureCaptionTap?

    private let environment: CaptureEnvironment
    @ObservationIgnored private var microphone: CaptureAudioSource?
    @ObservationIgnored private var system: CaptureAudioSource?
    @ObservationIgnored private var microphoneWriter: PCMTrackWriter?
    @ObservationIgnored private var systemWriter: PCMTrackWriter?
    private var manifest: CaptureSessionManifest?
    private var directory: URL?
    private var warnings: [String] = []
    /// The system's own words for problems, kept for each track's capture notes.
    private var technicalNotes: [CapturedTrackRole: [String]] = [:]
    private var routeEvents: [AudioRouteEvent] = []
    @ObservationIgnored private var routeObservation: AnyObject?
    @ObservationIgnored private var meterTimer: Timer?
    private var cancelStart = false
    /// Computer audio couldn't start for a recording with no call app, which then records the microphone alone.
    private var callAudioLeftOut = false
    /// Follows the Mac going to sleep for as long as the controller lives (cancelled when it goes).
    @ObservationIgnored nonisolated(unsafe) private var sleepWatch: Task<Void, Never>?
    /// This recording's caption tap, on its session timeline.
    @ObservationIgnored private var activeCaptionTap: CaptureCaptionTap?
    /// Host time each source last started (or was restarted), for the stall watch.
    @ObservationIgnored private var sourceStarted: [CapturedTrackRole: TimeInterval] = [:]
    /// Restarts in a row with no audio arriving between them.
    @ObservationIgnored private var stalledRestarts: [CapturedTrackRole: Int] = [:]
    @ObservationIgnored private var restartsInFlight: Set<CapturedTrackRole> = []
    @ObservationIgnored private var lastSpaceCheck: TimeInterval = -.infinity
    @ObservationIgnored private var serviceObservation: AnyObject?

    /// No buffer for this long while recording restarts a source.
    static let stallSeconds: TimeInterval = 3
    /// A call source restarted this many times without a buffer has failed.
    static let stalledRestartLimit = 3
    static let spaceCheckInterval: TimeInterval = 30
    /// Under this much room the recording warns.
    static let spaceWarning: TimeInterval = 30 * 60
    /// Under this much room call audio stops, leaving the rest to the microphone.
    static let spaceCallLimit: TimeInterval = 3 * 60

    /// Runs as the Mac goes to sleep, once the recording has stopped: saving it, and anything already on
    /// its way to other devices. Sleep waits for it, at most `sleepGrace`. (The devices recording along
    /// aren't stopped for sleep; see `stoppedForSleep`.)
    @ObservationIgnored var beforeSleep: (@MainActor () async -> Void)?
    static let sleepGrace: Duration = .seconds(5)
    @ObservationIgnored private var sleepGate: SystemSleepGate?

    init(environment: CaptureEnvironment = .live) {
        self.environment = environment
        sleepWatch = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification) {
                self?.stopForSleep()
            }
        }
        // The notification doesn't hold sleep back; the power notification can, briefly, so stops
        // sent to other devices leave before the network goes.
        sleepGate = SystemSleepGate(grace: Self.sleepGrace) { [weak self] in
            self?.stopForSleep()
            await self?.beforeSleep?()
        }
    }

    deinit { sleepWatch?.cancel() }

    /// The Mac is going to sleep anyway (the lid, the Apple menu): idle sleep is held off while recording. This
    /// Mac's tracks stop; devices recording along keep going (`stoppedForSleep`).
    private func stopForSleep() {
        if state == .recording { stoppedForSleep = true }
        captureFailed(RecordingError.interrupted(Self.sleepSentence))
    }

    static let sleepSentence = "Recording stopped because the Mac went to sleep. Everything up to then is saved."

    /// `callApp` is the meeting app to record on its own (from `MeetingMonitor` or the running
    /// apps); without it, call audio is all Mac playback.
    func start(in directory: URL, includeSystemAudio: Bool = true, callApp: CallAppTarget? = nil) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .starting
        lastError = nil
        lastResult = nil
        cancelStart = false
        callAudioLeftOut = false
        stoppedForSleep = false
        spaceLeft = nil
        callStoppedForSpace = false
        sourceStarted = [:]
        stalledRestarts = [:]
        restartsInFlight = []
        lastSpaceCheck = -.infinity
        warnings = []
        technicalNotes = [:]
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

            // Call audio starts first, so permission prompts are answered before the microphone runs. A call app's
            // audio that can't be recorded at all stops the start; without a call app (a conversation in the room, or
            // a call Daybook can't name) the microphone records alone and the conversation says how to add the rest.
            if includeSystemAudio {
                let writer = makeWriter(.systemAudio, manifest: manifest, directory: directory)
                systemWriter = writer
                let callCaptions = captions?.call
                do {
                    let (source, info) = try await SystemAudioSelector.start(target: callApp, provider: environment.systemAudio,
                        onBuffer: { buffer, time in writer.append(buffer, hostTimeSeconds: time); callCaptions?(buffer, time) },
                        onEvent: { [weak self] event in Task { @MainActor in self?.systemEvent(event) } })
                    system = source
                    sourceStarted[.systemAudio] = environment.hostTime()
                    systemAudioCapture = info
                    writer.setMethod(info.method.rawValue)
                    if let reason = info.fallbackReason, callApp != nil {
                        warnings.append(reason)
                        if let detail = info.fallbackDetail { technicalNotes[.systemAudio, default: []].append("\(reason) \(detail)") }
                    }
                } catch where callApp == nil {
                    systemWriter = nil
                    callAudioLeftOut = true
                    warn(Self.computerAudioLeftOut, error: error, track: .microphone)
                }
            }
            try checkStartCancellation()
            let micWriter = makeWriter(.microphone, manifest: manifest, directory: directory, method: "microphone")
            microphoneWriter = micWriter
            let mic = environment.makeMicrophone()
            microphone = mic
            let microphoneCaptions = captions?.microphone
            try await mic.start(onBuffer: { buffer, time in micWriter.append(buffer, hostTimeSeconds: time); microphoneCaptions?(buffer, time) },
                                onEvent: { [weak self] event in Task { @MainActor in self?.microphoneEvent(event) } })
            sourceStarted[.microphone] = environment.hostTime()
            try checkStartCancellation()
            state = .recording
            environment.keepAwake(true)
            serviceObservation = environment.observeAudioServiceRestarts { [weak self] in
                Task { @MainActor in self?.audioServiceRestarted() }
            }
            startMetering()
        } catch {
            let message = CapturedTrackRole.speaksPlainly(error) ? error.localizedDescription : "Recording couldn’t start."
            lastError = message
            warn(message, error: error)
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
        let hook = environment.writing.beforeWrite
        return PCMTrackWriter(role: role, directory: directory, manifest: manifest, method: method,
                              maximumBacklog: environment.writing.maximumBacklog, beforeWrite: hook.map { hook in { @Sendable in hook(role) } }) { [weak self] error in
            Task { @MainActor in self?.writerFailed(role, error) }
        }
    }

    private func checkStartCancellation() throws {
        if cancelStart { throw CancellationError() }
        if let lastError { throw RecordingError.interrupted(lastError) }
    }

    // MARK: Source and writer events

    /// A source's own note on a device change ("now 24000 Hz, 1 ch") goes in its track's capture
    /// notes; the conversation says it in one plain sentence.
    private func microphoneEvent(_ event: CaptureSourceEvent) {
        switch event {
        case .deviceChanged(let note):
            microphoneWriter?.markDiscontinuity(note)
            warnings.append(Self.microphoneChanged)
        case .restarted(let note):
            microphoneWriter?.markDiscontinuity(note)
            warnings.append(Self.microphoneRestarted)
        case .failed(let error):
            captureFailed(error)
        }
    }

    static let microphoneChanged = "The microphone changed partway through the recording."
    static let microphoneRestarted = "The microphone stopped for a moment and was restarted, leaving a short gap."
    static let callAudioRestarted = "Call audio restarted partway through, leaving a short gap."
    static let callStoppedForSpace = "The disk is almost full, so call audio stopped. The microphone kept recording."
    static let callWriterStalled = "The disk couldn’t keep up with call audio, so it stopped. The microphone kept recording."
    /// Computer audio couldn't start for a recording without a call app, so the microphone recorded alone.
    static let computerAudioLeftOut = "Computer audio isn’t included. Allow Screen & System Audio Recording in Settings › Recording."

    /// Call audio problems never end the recording: a failed tap falls back to ScreenCaptureKit,
    /// and anything else stops only the call track.
    private func systemEvent(_ event: CaptureSourceEvent) {
        guard state == .recording || state == .starting else { return }
        switch event {
        case .deviceChanged(let note), .restarted(let note):
            systemWriter?.markDiscontinuity(note)
            warnings.append(Self.callAudioRestarted)
        case .failed(let error):
            Task { await systemFailed(error) }
        }
    }

    /// A write that failed: the microphone's ends the recording; the call's only the call.
    private func writerFailed(_ role: CapturedTrackRole, _ error: Error) {
        if role == .microphone { captureFailed(error); return }
        guard state == .recording, system != nil else { return }
        endCallTrack("Call audio stopped. The microphone kept recording.", error: error)
    }

    private func systemFailed(_ error: Error) async {
        guard state == .recording, let current = system else { return }
        guard current.method == "process-tap", let writer = systemWriter else {
            await stopCallTrack(reason: "Call audio stopped. The microphone kept recording.", error: error)
            return
        }
        if case ProcessTapError.silent = error, !environment.systemAudio.screenCaptureAuthorized {
            // Possibly just a quiet call. Switching would show a permission prompt mid-call, so keep
            // the tap (it records again as soon as the app plays sound) and say why it may be silent.
            warnings.append("The call stayed silent. If its audio is missing, allow Daybook in System Settings › Privacy & Security › Screen & System Audio Recording.")
            return
        }
        if error is CallAudioStalled, !environment.systemAudio.screenCaptureAuthorized {
            // A tap that delivers nothing even rebuilt; switching would ask for a permission mid-call, so only the call stops.
            await stopCallTrack(reason: "Call audio stopped. The microphone kept recording.", error: error)
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
            sourceStarted[.systemAudio] = environment.hostTime()
            stalledRestarts[.systemAudio] = 0
            writer.setMethod(SystemAudioCaptureInfo.Method.screenCaptureKit.rawValue)
            let reason = "Recording only the call app stopped working, so all Mac audio is recorded from here on."
            systemAudioCapture = SystemAudioCaptureInfo(method: .screenCaptureKit, capturedApps: systemAudioCapture?.capturedApps,
                                                        fallbackReason: reason, switchedAt: elapsedTime)
            warn(reason, error: error, track: .systemAudio)
        } catch {
            warn("Call audio stopped and couldn’t switch to all Mac audio. The microphone kept recording.", error: error, track: .systemAudio)
        }
    }

    private func stopCallTrack(reason: String, error: Error? = nil) async {
        warn(reason, error: error, track: .systemAudio)
        let current = system
        system = nil
        await current?.stop()
    }

    /// The same, letting go of the call source at once (the meter timer may look again before the stop is done).
    private func endCallTrack(_ reason: String, error: Error? = nil) {
        warn(reason, error: error, track: .systemAudio)
        let current = system
        system = nil
        Task { await current?.stop() }
    }

    /// One plain sentence for the person; when the error isn't one of Daybook's own, its words are
    /// kept in that track's capture notes, which the conversation's capture details show.
    private func warn(_ sentence: String, error: Error? = nil, track role: CapturedTrackRole = .microphone) {
        warnings.append(sentence)
        guard let error, !CapturedTrackRole.speaksPlainly(error) else { return }
        technicalNotes[role, default: []].append("\(sentence) \(error.localizedDescription)")
    }

    private func captureFailed(_ error: Error) {
        guard state == .recording || state == .starting else { return }
        let message = CapturedTrackRole.speaksPlainly(error) ? error.localizedDescription : Self.unexpectedStopSentence
        lastError = message
        if state == .starting { return }
        warn(message, error: error)
        state = .stopping
        Task {
            if let result = await finishCapture() { onUnexpectedStop?(result, message) }
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

    /// Called by the meter timer; internal so tests can sample without waiting on it. Besides the levels and the
    /// hearing check, it watches the sources, the writers, and the disk.
    func updateLevels() {
        guard state == .recording else { return }
        let now = environment.hostTime()
        levels.update(microphone: microphoneWriter?.meter.read(), call: system == nil ? nil : systemWriter?.meter.read(),
                      hostTime: now, elapsed: elapsedTime)
        if levels.isCallAudioDetected != isCallAudioDetected { isCallAudioDetected = levels.isCallAudioDetected }
        watchWriters()
        guard state == .recording else { return }
        watchSources(at: now)
        watchSpace(at: now)
    }

    // MARK: Watching

    /// A writer with audio waiting that hasn't finished any for `stallLimit` (a disk that stopped answering): the
    /// microphone's ends the recording, the call's stops only the call.
    private func watchWriters() {
        let limit = environment.writing.stallLimit
        if let writer = microphoneWriter, writer.progress.stalledFor > limit {
            captureFailed(PCMTrackWriterError.diskBacklog)
        } else if system != nil, let writer = systemWriter, writer.progress.stalledFor > limit {
            endCallTrack(Self.callWriterStalled)
        }
    }

    /// A source that delivered nothing for `stallSeconds` is started again: the microphone's engine, the tap
    /// rebuilt, ScreenCaptureKit once. A call source that stays silent through `stalledRestartLimit` restarts has
    /// failed (a tap falls back to ScreenCaptureKit; ScreenCaptureKit's call track ends).
    private func watchSources(at now: TimeInterval) {
        for role in [CapturedTrackRole.microphone, .systemAudio] {
            guard let source = role == .microphone ? microphone : system,
                  let writer = role == .microphone ? microphoneWriter : systemWriter,
                  !restartsInFlight.contains(role) else { continue }
            let started = sourceStarted[role] ?? manifest?.hostTimeSeconds ?? now
            let delivered = writer.progress.delivered ?? -.infinity
            if delivered > started { stalledRestarts[role] = 0 }
            guard now - max(delivered, started) > Self.stallSeconds else { continue }
            if role == .systemAudio, stalledRestarts[role, default: 0] >= Self.stalledRestartLimit {
                stalledRestarts[role] = 0
                sourceStarted[role] = now
                Task { await systemFailed(CallAudioStalled()) }
                continue
            }
            stalledRestarts[role, default: 0] += 1
            sourceStarted[role] = now
            restartsInFlight.insert(role)
            Task {
                await source.restart(.stalled)
                restartsInFlight.remove(role)
            }
        }
    }

    /// Every 30 s, the room left on the disk at the recording's byte rate: under 30 minutes it warns; under 3, call
    /// audio stops so the microphone has what's left.
    private func watchSpace(at now: TimeInterval) {
        guard now - lastSpaceCheck >= Self.spaceCheckInterval, let directory else { return }
        let writers = [microphoneWriter, system == nil ? nil : systemWriter].compactMap { $0 }
        let rate = writers.map(\.bytesPerSecond).reduce(0, +)
        guard rate > 0 else { return }
        lastSpaceCheck = now
        guard let free = environment.freeSpace(directory) else { return }
        let left = Double(max(0, free)) / rate
        let low = left <= Self.spaceWarning ? left : nil
        if low != spaceLeft { spaceLeft = low }
        if left <= Self.spaceCallLimit, system != nil {
            callStoppedForSpace = true
            endCallTrack(Self.callStoppedForSpace)
            // Measured again at once, at the microphone's rate alone.
            lastSpaceCheck = -.infinity
        }
    }

    /// coreaudiod restarted: every device is new, so both sources start again.
    private func audioServiceRestarted() {
        guard state == .recording else { return }
        let now = environment.hostTime()
        for (role, source) in [(CapturedTrackRole.microphone, microphone), (.systemAudio, system)] {
            guard let source else { continue }
            sourceStarted[role] = now
            restartsInFlight.insert(role)
            Task {
                await source.restart(.audioSystemRestarted)
                restartsInFlight.remove(role)
            }
        }
    }

    // MARK: Finishing

    private func finishCapture() async -> CaptureResult? {
        meterTimer?.invalidate()
        meterTimer = nil
        serviceObservation = nil
        environment.keepAwake(false)
        if let microphone { await microphone.stop() }
        microphone = nil
        if let system { await system.stop() }
        system = nil
        routeObservation = nil
        var tracks: [CapturedAudioTrack] = []
        for writer in [microphoneWriter, systemWriter].compactMap({ $0 }) {
            let outcome = await writer.finish()
            if let track = outcome.track {
                tracks.append(track)
                // What a busy disk cost, said for the conversation too.
                if track.lostSeconds > 0 { warnings.append(RecordingWords.lostAudio(track.lostSeconds, of: track.role.audioName)) }
            }
            if let error = outcome.error { warnings.append(error) }
        }
        // The system's words for what went wrong, with the track they're about.
        for index in tracks.indices {
            guard let extra = technicalNotes[tracks[index].role], !extra.isEmpty else { continue }
            tracks[index].notes = (tracks[index].notes ?? []) + extra
        }
        technicalNotes = [:]
        microphoneWriter = nil
        systemWriter = nil
        activeCaptionTap = nil
        var result: CaptureResult?
        if let manifest, let directory {
            if tracks.isEmpty { warnings.append("No audio was recorded.") }
            if manifest.includeSystemAudio && !callAudioLeftOut && !tracks.contains(where: { $0.role == .systemAudio }) {
                warnings.append("No system audio was received. Check the call’s output and recording permission.")
            }
            let completed = CaptureResult(id: manifest.id, startedAt: manifest.startedAt, endedAt: Date(), tracks: tracks,
                                          warnings: Array(Set(warnings)).sorted(), directory: directory,
                                          systemAudio: systemAudioCapture, outputRoutes: routeEvents.isEmpty ? nil : routeEvents)
            // A full disk fails both the track and this; why the recording stopped is the error to keep.
            do { try CaptureJSON.persist(completed, at: directory.appendingPathComponent("capture-result.json")) }
            catch { lastError = lastError ?? "The audio is saved, but its recording details couldn’t be." }
            lastResult = completed
            result = completed
        }
        self.manifest = nil
        self.directory = nil
        startedAt = nil
        isCallAudioDetected = false
        spaceLeft = nil
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
