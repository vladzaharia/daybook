import Accelerate
import AVFoundation
import DaybookCore
import DaybookTestSupport
import XCTest
@testable import Daybook

// MARK: - Fakes (no microphone, tap, or ScreenCaptureKit stream is ever opened)

final class FakeCaptureSource: CaptureAudioSource, ProcessTapReporting, @unchecked Sendable {
    let method: String
    var startError: Error?
    var capturedBundleIDs: [String] = []
    private(set) var started = false
    private(set) var stopped = false
    private(set) var onBuffer: CaptureBufferHandler?
    private(set) var onEvent: CaptureEventHandler?

    init(method: String, startError: Error? = nil) { self.method = method; self.startError = startError }

    func start(onBuffer: @escaping CaptureBufferHandler, onEvent: @escaping CaptureEventHandler) async throws {
        if let startError { throw startError }
        started = true
        self.onBuffer = onBuffer
        self.onEvent = onEvent
    }

    func stop() async { stopped = true; onBuffer = nil }
    func emit(_ buffer: AVAudioPCMBuffer, at host: TimeInterval) { onBuffer?(buffer, host) }
    func send(_ event: CaptureSourceEvent) { onEvent?(event) }
}

final class FakeSystemAudio: SystemAudioProviding {
    var supportsProcessTaps = true
    var screenCaptureAuthorized = true
    var tapCreationError: Error?
    var tapStartError: Error?
    var screenError: Error?
    private(set) var taps: [FakeCaptureSource] = []
    private(set) var screens: [FakeCaptureSource] = []
    private(set) var tapTargets: [CallAppTarget] = []

    func makeProcessTap(for target: CallAppTarget) throws -> CaptureAudioSource {
        tapTargets.append(target)
        if let tapCreationError { throw tapCreationError }
        let tap = FakeCaptureSource(method: "process-tap", startError: tapStartError)
        tap.capturedBundleIDs = [target.bundleID, target.bundleID + ".helper"]
        taps.append(tap)
        return tap
    }

    func makeScreenCapture() async throws -> CaptureAudioSource {
        if let screenError { throw screenError }
        let screen = FakeCaptureSource(method: "screen-capture-kit")
        screens.append(screen)
        return screen
    }
}

final class FakeHostClock: @unchecked Sendable { var now: TimeInterval = 100 }

struct FakeError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - Synthetic audio for capture tests

enum CallSignals {
    /// Syllable-enveloped, band-limited noise: enough like speech for delay and echo tests.
    static func speech(seconds: Double, rate: Double, seed: UInt64, level: Float = 0.1, active: [ClosedRange<Double>]? = nil) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func random() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        let count = Int(seconds * rate)
        var output = [Float](repeating: 0, count: count)
        var low = 0.0, band = 0.0
        var time = 0.0
        while time < seconds {
            let length = 0.12 + 0.16 * random(), gap = 0.03 + 0.05 * random() + (random() < 0.15 ? 0.4 : 0)
            let start = Int(time * rate), frames = min(Int(length * rate), count - start)
            let centre = 500 + 1_800 * random()
            let f = 2 * sin(Double.pi * centre / rate), q = 0.25
            for index in 0..<max(0, frames) {
                let noise = random() * 2 - 1
                // State-variable band-pass around a moving "formant".
                low += f * band
                let high = noise - low - q * band
                band += f * high
                let envelope = sin(Double.pi * Double(index) / Double(frames))
                output[start + index] = Float(band * envelope * envelope)
            }
            time += length + gap
        }
        let rms = (output.map { Double($0 * $0) }.reduce(0, +) / Double(max(1, count))).squareRoot()
        let gain = rms > 0 ? Double(level) / rms : 0
        for index in 0..<count {
            let t = Double(index) / rate
            output[index] = active == nil || active!.contains(where: { $0.contains(t) }) ? Float(Double(output[index]) * gain) : 0
        }
        return output
    }

    /// Delay, a few reflections, and a short decaying tail.
    static func echo(of signal: [Float], rate: Double, delay: Double, gain: Float) -> [Float] {
        let first = Int(delay * rate)
        var response = [Float](repeating: 0, count: first + Int(0.06 * rate))
        response[first] = gain
        for (offset, value) in [(0.003, 0.4), (0.007, -0.3), (0.012, 0.2)] { response[first + Int(offset * rate)] += gain * Float(value) }
        var seed: UInt64 = 7
        for index in (first + Int(0.004 * rate))..<response.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 1000
            response[index] += gain * 0.1 * noise * Float(exp(-Double(index - first) / (0.02 * rate)))
        }
        let padded = [Float](repeating: 0, count: response.count - 1) + signal
        var output = [Float](repeating: 0, count: signal.count)
        // vDSP_conv correlates; a reversed filter pointer with stride −1 convolves.
        response.withUnsafeBufferPointer { filter in
            vDSP_conv(padded, 1, filter.baseAddress! + response.count - 1, -1, &output, 1, vDSP_Length(signal.count), vDSP_Length(response.count))
        }
        return output
    }

    static func buffer(_ channels: [[Float]], rate: Double, from start: Int, frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            for frame in 0..<frames { buffer.floatChannelData![index][frame] = start + frame < channel.count ? channel[start + frame] : 0 }
        }
        return buffer
    }

    static func tone(rate: Double = 48_000, channels: Int = 1, level: Float = 0.2, frames: Int = 4_800) -> AVAudioPCMBuffer {
        let samples = (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 440 / rate)) * level }
        return buffer(Array(repeating: samples, count: channels), rate: rate, from: 0, frames: frames)
    }

    static func upsampled(_ signal: [Float], from input: Double, to output: Double) -> [Float] {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: output, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        let source = buffer([signal], rate: input, from: 0, frames: signal.count)
        let capacity = AVAudioFrameCount(Double(signal.count) * output / input) + 1_024
        let destination = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
        var supplied = false
        var result: [Float] = []
        while true {
            destination.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: destination, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .endOfStream; return nil }
                supplied = true; outStatus.pointee = .haveData; return source
            }
            result += Array(UnsafeBufferPointer(start: destination.floatChannelData![0], count: Int(destination.frameLength)))
            if status != .haveData || destination.frameLength == 0 { break }
        }
        return result
    }

    static func sha256(_ url: URL) throws -> String { try AudioDigest.sha256(fileURL: url) }
}

// MARK: - Choosing how to record the call

final class SystemAudioSelectionTests: XCTestCase {
    private let zoom = CallAppTarget(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
    private let noBuffers: CaptureBufferHandler = { _, _ in }
    private let noEvents: CaptureEventHandler = { _ in }

    func testKnownCallAppIsRecordedWithAProcessTap() async throws {
        let provider = FakeSystemAudio()
        let (source, info) = try await SystemAudioSelector.start(target: zoom, provider: provider, onBuffer: noBuffers, onEvent: noEvents)
        XCTAssertEqual(source.method, "process-tap")
        XCTAssertEqual(info.method, .processTap)
        XCTAssertEqual(info.capturedApps, ["us.zoom.xos", "us.zoom.xos.helper"])
        XCTAssertNil(info.fallbackReason)
        XCTAssertTrue(provider.screens.isEmpty)
        XCTAssertTrue(provider.taps[0].started)
    }

    func testUnknownCallAppRecordsAllMacAudio() async throws {
        let provider = FakeSystemAudio()
        let (source, info) = try await SystemAudioSelector.start(target: nil, provider: provider, onBuffer: noBuffers, onEvent: noEvents)
        XCTAssertEqual(source.method, "screen-capture-kit")
        XCTAssertEqual(info.method, .screenCaptureKit)
        XCTAssertTrue(info.fallbackReason?.contains("No call app") == true)
        XCTAssertTrue(provider.tapTargets.isEmpty)
    }

    func testTapThatCannotBeCreatedOrStartedFallsBackToScreenCaptureKit() async throws {
        let creation = FakeSystemAudio()
        creation.tapCreationError = FakeError(message: "tap refused")
        let (_, first) = try await SystemAudioSelector.start(target: zoom, provider: creation, onBuffer: noBuffers, onEvent: noEvents)
        XCTAssertEqual(first.method, .screenCaptureKit)
        XCTAssertEqual(first.fallbackReason, "Couldn’t record Zoom on its own, so all Mac audio is recorded.", "one plain sentence")
        XCTAssertEqual(first.fallbackDetail, "tap refused", "the system's words, for the capture notes")

        let starting = FakeSystemAudio()
        starting.tapStartError = FakeError(message: "aggregate failed")
        let (source, second) = try await SystemAudioSelector.start(target: zoom, provider: starting, onBuffer: noBuffers, onEvent: noEvents)
        XCTAssertEqual(source.method, "screen-capture-kit")
        XCTAssertFalse(second.fallbackReason?.contains("aggregate failed") == true)
        XCTAssertEqual(second.fallbackDetail, "aggregate failed")
        XCTAssertTrue(starting.taps[0].stopped, "a half-started tap is torn down")
    }

    func testOlderSystemsWithoutProcessTapsUseScreenCaptureKit() async throws {
        let provider = FakeSystemAudio()
        provider.supportsProcessTaps = false
        let (_, info) = try await SystemAudioSelector.start(target: zoom, provider: provider, onBuffer: noBuffers, onEvent: noEvents)
        XCTAssertEqual(info.method, .screenCaptureKit)
        XCTAssertTrue(info.fallbackReason?.contains("14.2") == true)
        XCTAssertTrue(provider.tapTargets.isEmpty)
    }

    func testFailureOfBothPathsIsReported() async {
        let provider = FakeSystemAudio()
        provider.tapCreationError = FakeError(message: "tap refused")
        provider.screenError = RecordingError.noDisplay
        do {
            _ = try await SystemAudioSelector.start(target: zoom, provider: provider, onBuffer: noBuffers, onEvent: noEvents)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, RecordingError.noDisplay.localizedDescription)
        }
    }

    func testCallAppProcessesIncludeHelpersButNeverDaybook() {
        let chrome = CallAppTarget(bundleID: "com.google.Chrome", displayName: "Chrome", isBrowser: true)
        let processes = [
            AudioProcessInfo(objectID: 1, pid: 10, bundleID: "com.google.Chrome", isRunningOutput: false),
            AudioProcessInfo(objectID: 2, pid: 11, bundleID: "com.google.Chrome.helper", isRunningOutput: true),
            AudioProcessInfo(objectID: 3, pid: 12, bundleID: "com.google.ChromeCanary", isRunningOutput: true),
            AudioProcessInfo(objectID: 4, pid: 13, bundleID: "com.spotify.client", isRunningOutput: true),
            AudioProcessInfo(objectID: 5, pid: 99, bundleID: "com.google.Chrome.helper", isRunningOutput: true)
        ]
        XCTAssertEqual(AudioProcessCatalog.processes(for: chrome, in: processes, excluding: 99).map(\.objectID), [1, 2])
        let safari = CallAppTarget(bundleID: "com.apple.Safari", displayName: "Safari", isBrowser: true)
        XCTAssertTrue(safari.owns(bundleID: "com.apple.WebKit.GPU"))
        let arc = CallAppTarget(bundleID: "company.thebrowser.Browser", displayName: "Arc", isBrowser: true)
        XCTAssertTrue(arc.owns(bundleID: "company.thebrowser.browser.helper"))
    }

    func testManualRecordingTargetsTheAppInACall() {
        let rules = MeetingAppRule.defaults
        let musicInBrowser = [CallAppResolver.Activity(bundleID: "com.google.Chrome.helper", input: false, output: true)]
        XCTAssertNil(CallAppResolver.choose(rules: rules, activity: musicInBrowser))
        let browserCall = [CallAppResolver.Activity(bundleID: "com.google.Chrome.helper", input: true, output: true)]
        XCTAssertEqual(CallAppResolver.choose(rules: rules, activity: browserCall)?.bundleID, "com.google.Chrome")
        let both = browserCall + [CallAppResolver.Activity(bundleID: "us.zoom.xos", input: true, output: true)]
        XCTAssertEqual(CallAppResolver.choose(rules: rules, activity: both)?.bundleID, "us.zoom.xos")
    }

    func testOutputRouteClassification() {
        let ispk = AudioOutputRoute.fourCC("ispk"), hdpn = AudioOutputRoute.fourCC("hdpn")
        XCTAssertEqual(AudioOutputRoute.classify(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: ispk, name: "MacBook Pro Speakers"), .speakers)
        XCTAssertEqual(AudioOutputRoute.classify(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: hdpn, name: "External Headphones"), .headphones)
        XCTAssertEqual(AudioOutputRoute.classify(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil, name: "Alex’s AirPods Pro"), .headphones)
        XCTAssertEqual(AudioOutputRoute.classify(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil, name: "Kitchen Speaker"), .bluetooth)
        XCTAssertEqual(AudioOutputRoute.classify(transportType: kAudioDeviceTransportTypeHDMI, dataSource: nil, name: "LG UltraFine"), .speakers)
    }
}

// MARK: - The recording controller with fake devices

@MainActor
final class RecordingControllerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookCapture-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testCallAppIsTappedRoutesAndLevelsAreTrackedAndATapFailureFallsBackMidCall() async throws {
        let clock = FakeHostClock()
        let system = FakeSystemAudio()
        let mic = FakeCaptureSource(method: "microphone")
        var routeHandler: (@Sendable (AudioOutputRoute) -> Void)?
        let speakers = AudioOutputRoute(kind: .speakers, deviceName: "MacBook Pro Speakers", transport: "built-in")
        let environment = CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { mic }, systemAudio: system,
            currentRoute: { speakers }, observeRoutes: { handler in routeHandler = handler; return NSObject() },
            hostTime: { clock.now })
        let recorder = RecordingController(environment: environment)
        let directory = try temporaryDirectory()
        let zoom = CallAppTarget(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false)
        try await recorder.start(in: directory, includeSystemAudio: true, callApp: zoom)
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(recorder.systemAudioCapture?.method, .processTap)
        XCTAssertEqual(system.tapTargets, [zoom])
        let tap = system.taps[0]

        for index in 0..<20 {
            clock.now = 100 + Double(index) * 0.1
            mic.emit(CallSignals.tone(), at: clock.now)
            tap.emit(CallSignals.tone(channels: 2, level: 0.1), at: clock.now)
        }
        recorder.updateLevels()
        XCTAssertGreaterThan(recorder.levels.microphone.rms, -20)
        XCTAssertGreaterThan(recorder.levels.call.rms, -26)
        XCTAssertTrue(recorder.levels.isCallAudioDetected)
        XCTAssertTrue(recorder.isCallAudioDetected)
        XCTAssertFalse(recorder.levels.isMicrophoneSilent)

        // AirPods connect mid-call.
        routeHandler?(AudioOutputRoute(kind: .headphones, deviceName: "AirPods Pro", transport: "bluetooth"))
        await settle { recorder.outputRoute?.kind == .headphones }
        XCTAssertEqual(recorder.outputRoute?.kind, .headphones)

        // The tap's silence watchdog fires: capture continues through ScreenCaptureKit.
        tap.send(.failed(ProcessTapError.silent("Zoom")))
        await settle { recorder.systemAudioCapture?.method == .screenCaptureKit }
        XCTAssertEqual(recorder.systemAudioCapture?.method, .screenCaptureKit)
        XCTAssertNotNil(recorder.systemAudioCapture?.switchedAt)
        XCTAssertTrue(tap.stopped)
        XCTAssertEqual(recorder.state, .recording)
        let screen = try XCTUnwrap(system.screens.first)
        for index in 20..<30 {
            clock.now = 100.2 + Double(index) * 0.1
            mic.emit(CallSignals.tone(), at: clock.now)
            screen.emit(CallSignals.tone(channels: 2, level: 0.1), at: clock.now)
        }
        // The microphone moves to the AirPods' hands-free profile at a lower rate.
        mic.send(.deviceChanged("The microphone changed (now 24000 Hz, 1 ch); recording continued."))
        await settle { false }
        clock.now = 104
        mic.emit(CallSignals.tone(rate: 24_000, frames: 2_400), at: clock.now)

        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(result.systemAudio?.method, .screenCaptureKit)
        XCTAssertTrue(result.systemAudio?.fallbackReason?.contains("all Mac audio") == true)
        XCTAssertEqual(result.outputRoutes?.map(\.route.kind), [.speakers, .headphones])
        XCTAssertEqual(result.outputRouteSummary, .mixed)
        let micTrack = try XCTUnwrap(result.tracks.first { $0.role == .microphone })
        let callTrack = try XCTUnwrap(result.tracks.first { $0.role == .systemAudio })
        XCTAssertEqual(micTrack.method, "microphone")
        XCTAssertEqual(callTrack.method, "screen-capture-kit")
        XCTAssertEqual(micTrack.sampleRate, 48_000)
        XCTAssertTrue(micTrack.clockAnchors?.contains { $0.resync == true } == true, "the device change starts a new clock segment")
        XCTAssertTrue(callTrack.clockAnchors?.contains { $0.resync == true } == true, "the switch to ScreenCaptureKit starts a new clock segment")
        XCTAssertEqual(try AVAudioFile(forReading: micTrack.url).length, micTrack.frameCount)
        // The saved metadata round-trips, including the new capture details.
        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(recovered.systemAudio, result.systemAudio)
        XCTAssertEqual(recovered.outputRoutes, result.outputRoutes)
        XCTAssertEqual(recovered.tracks.first { $0.role == .microphone }?.clockAnchors, micTrack.clockAnchors)
    }

    /// A silent tap may just be a quiet call. Without Screen Recording permission already granted,
    /// switching would prompt mid-call, so the tap stays and a warning explains the silence.
    func testSilentTapWithoutScreenPermissionKeepsTheTapAndWarns() async throws {
        let system = FakeSystemAudio()
        system.screenCaptureAuthorized = false
        let mic = FakeCaptureSource(method: "microphone")
        let environment = CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { mic }, systemAudio: system,
            currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
            observeRoutes: { _ in nil }, hostTime: { 100 })
        let recorder = RecordingController(environment: environment)
        try await recorder.start(in: try temporaryDirectory(), includeSystemAudio: true,
                                 callApp: CallAppTarget(bundleID: "us.zoom.xos", displayName: "Zoom", isBrowser: false))
        let tap = system.taps[0]
        tap.send(.failed(ProcessTapError.silent("Zoom")))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(system.screens.isEmpty)
        XCTAssertFalse(tap.stopped)
        XCTAssertEqual(recorder.systemAudioCapture?.method, .processTap)
        mic.emit(CallSignals.tone(), at: 100)
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertTrue(result.warnings.contains { $0.contains("stayed silent") })
    }

    func testCallTrackFailureKeepsTheMicrophoneRecording() async throws {
        let clock = FakeHostClock()
        let system = FakeSystemAudio()
        let mic = FakeCaptureSource(method: "microphone")
        let environment = CaptureEnvironment(
            microphoneAuthorization: { true }, makeMicrophone: { mic }, systemAudio: system,
            currentRoute: { AudioOutputRoute(kind: .speakers, deviceName: "Speakers", transport: nil) },
            observeRoutes: { _ in nil }, hostTime: { clock.now })
        let recorder = RecordingController(environment: environment)
        try await recorder.start(in: try temporaryDirectory(), includeSystemAudio: true, callApp: nil)
        XCTAssertEqual(recorder.systemAudioCapture?.method, .screenCaptureKit)
        let screen = system.screens[0]
        mic.emit(CallSignals.tone(), at: 100)
        screen.emit(CallSignals.tone(channels: 2), at: 100)
        screen.send(.failed(FakeError(message: "stream stopped")))
        await settle { screen.stopped }
        XCTAssertTrue(screen.stopped)
        XCTAssertEqual(recorder.state, .recording)
        mic.emit(CallSignals.tone(), at: 100.1)
        let result = try await XCTUnwrapAsync(await recorder.stop())
        XCTAssertEqual(result.tracks.first { $0.role == .microphone }?.frameCount, 9_600)
        XCTAssertTrue(result.warnings.contains("Call audio stopped. The microphone kept recording."))
        XCTAssertFalse(result.warnings.contains { $0.contains("stream stopped") }, "the system's words stay out of the warning")
        let callNotes = result.tracks.first { $0.role == .systemAudio }?.notes ?? []
        XCTAssertTrue(callNotes.contains { $0.contains("stream stopped") }, "and go in the call audio's capture notes")
    }

    func testDeniedMicrophoneNeverStartsCallCapture() async throws {
        let system = FakeSystemAudio()
        let environment = CaptureEnvironment(
            microphoneAuthorization: { false }, makeMicrophone: { FakeCaptureSource(method: "microphone") }, systemAudio: system,
            currentRoute: { AudioOutputRoute(kind: .unknown, deviceName: "", transport: nil) },
            observeRoutes: { _ in nil }, hostTime: { 100 })
        let recorder = RecordingController(environment: environment)
        do {
            try await recorder.start(in: try temporaryDirectory(), includeSystemAudio: true, callApp: nil)
            XCTFail("expected microphone denial")
        } catch {
            XCTAssertEqual(error.localizedDescription, RecordingError.microphoneDenied.localizedDescription)
        }
        XCTAssertTrue(system.screens.isEmpty && system.taps.isEmpty)
        XCTAssertEqual(recorder.state, .idle)
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}

// MARK: - Finalizing a call: echo removal and provenance

final class CaptureFinalizerTests: XCTestCase {
    private let rate = 16_000.0

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookFinalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    struct Capture {
        var result: CaptureResult
        var far: [Float]
        var near: [Float]
        var mic: [Float]
    }

    /// Writes a staged capture the way RecordingController does: a 16 kHz microphone and a 48 kHz
    /// stereo call track starting 50 ms later, with sidecars and clock anchors.
    static func stageCapture(in directory: URL, seconds: Double = 14, echoGain: Float = 0.5, routes: [AudioOutputRoute.Kind] = [.speakers]) async throws -> Capture {
        let rate = 16_000.0
        let far = CallSignals.speech(seconds: seconds, rate: rate, seed: 3, level: 0.1)
        let near = CallSignals.speech(seconds: seconds, rate: rate, seed: 4, level: 0.08, active: [9...12])
        let echo = echoGain > 0 ? CallSignals.echo(of: far, rate: rate, delay: 0.07, gain: echoGain) : [Float](repeating: 0, count: far.count)
        var noiseState: UInt64 = 0x2545_F491_4F6C_DD1D
        let mic = zip(echo, near).map { pair -> Float in
            noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
            return pair.0 + pair.1 + 0.0005 * (Float(noiseState >> 40) / Float(1 << 24) * 2 - 1)
        }
        let call48 = CallSignals.upsampled(far, from: rate, to: 48_000)
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_700_000_000), hostTimeSeconds: 50,
                                              includeSystemAudio: true)
        try CaptureJSON.persist(manifest, at: directory.appendingPathComponent("capture-session.json"))
        let micWriter = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest, method: "microphone") { XCTFail($0.localizedDescription) }
        let callWriter = PCMTrackWriter(role: .systemAudio, directory: directory, manifest: manifest, method: "process-tap") { XCTFail($0.localizedDescription) }
        let micFrames = 1_600, callFrames = 4_800
        var index = 0
        while index * micFrames < mic.count {
            micWriter.append(CallSignals.buffer([mic], rate: rate, from: index * micFrames, frames: min(micFrames, mic.count - index * micFrames)),
                             hostTimeSeconds: 50.2 + Double(index) * 0.1)
            if index * callFrames < call48.count - Int(0.05 * 48_000) {
                // The call track's first sample is far(t) at t = 0.05 s on the microphone's timeline.
                let start = index * callFrames + Int(0.05 * 48_000)
                let frames = min(callFrames, call48.count - start)
                let channel = Array(call48[start..<(start + frames)])
                callWriter.append(CallSignals.buffer([channel.map { $0 * 0.9 }, channel.map { $0 * 1.1 }], rate: 48_000, from: 0, frames: frames),
                                  hostTimeSeconds: 50.25 + Double(index) * 0.1)
            }
            if index % 50 == 49 { await micWriter.waitUntilWritten(); await callWriter.waitUntilWritten() }
            index += 1
        }
        let tracks = [await micWriter.finish().track, await callWriter.finish().track].compactMap { $0 }
        let result = CaptureResult(id: manifest.id, startedAt: manifest.startedAt, endedAt: manifest.startedAt.addingTimeInterval(seconds),
                                   tracks: tracks, warnings: [], directory: directory,
                                   systemAudio: SystemAudioCaptureInfo(method: .processTap, capturedApps: ["us.zoom.xos"]),
                                   outputRoutes: routes.enumerated().map { AudioRouteEvent(time: Double($0.offset), route: AudioOutputRoute(kind: $0.element, deviceName: "Output", transport: nil)) })
        try CaptureJSON.persist(result, at: directory.appendingPathComponent("capture-result.json"))
        return Capture(result: result, far: far, near: near, mic: mic)
    }

    func testEchoIsRemovedIntoADerivedTrackAndTheOriginalStaysByteIdentical() async throws {
        let directory = try temporaryDirectory()
        let capture = try await Self.stageCapture(in: directory)
        let micURL = directory.appendingPathComponent("microphone.caf"), callURL = directory.appendingPathComponent("systemAudio.caf")
        let before = (try CallSignals.sha256(micURL), try CallSignals.sha256(callURL))
        let finalized = CaptureFinalizer.finalize(capture.result)
        XCTAssertEqual(try CallSignals.sha256(micURL), before.0, "the original microphone is never modified")
        XCTAssertEqual(try CallSignals.sha256(callURL), before.1)
        let report = try XCTUnwrap(finalized.echoRemoval)
        XCTAssertEqual(report.outcome, .applied, report.detail ?? "")
        // The call starts 50 ms after the microphone; the echo arrives 70 ms after the call.
        XCTAssertEqual(try XCTUnwrap(report.delay).delaySeconds, 0.07, accuracy: 0.002)
        let derived = try XCTUnwrap(finalized.derivedTracks?.first)
        XCTAssertEqual(derived.processing, "echo-cancelled")
        XCTAssertEqual(derived.derivedFrom, .microphone)
        let micTrack = try XCTUnwrap(capture.result.tracks.first { $0.role == .microphone })
        XCTAssertEqual(derived.offsetSeconds, micTrack.offsetSeconds, accuracy: 0.001)
        XCTAssertEqual(derived.duration, micTrack.duration, accuracy: 0.01)

        // Echo-only stretch versus the double-talk stretch in the cleaned audio.
        let file = try AVAudioFile(forReading: derived.url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let cleaned = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        func energy(_ signal: [Float], _ seconds: Range<Double>) -> Double {
            signal[Int(seconds.lowerBound * rate)..<Int(seconds.upperBound * rate)].reduce(0) { $0 + Double($1 * $1) }
        }
        let erle = 10 * log10(energy(capture.mic, 1..<8.5) / energy(cleaned, 1..<8.5))
        XCTAssertGreaterThanOrEqual(erle, 20)
        let kept = 10 * log10(energy(cleaned, 9.3..<11.7) / energy(capture.near, 9.3..<11.7))
        XCTAssertGreaterThan(kept, -3, "near-end speech survives double talk")

        // The decision is saved, and finalizing again reuses it.
        let saved = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(saved.echoRemoval, report)
        XCTAssertEqual(saved.derivedTracks?.first?.url.lastPathComponent, CaptureFinalizer.echoCancelledFileName)
        let modified = try FileManager.default.attributesOfItem(atPath: derived.url.path)[.modificationDate] as? Date
        let again = CaptureFinalizer.finalize(saved)
        XCTAssertEqual(again.echoRemoval, report)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: derived.url.path)[.modificationDate] as? Date, modified)
    }

    func testHeadphonesAndMissingCallAudioSkipWithAReason() async throws {
        let headphones = try await Self.stageCapture(in: try temporaryDirectory(), echoGain: 0, routes: [.headphones])
        let skipped = CaptureFinalizer.finalize(headphones.result)
        XCTAssertEqual(skipped.echoRemoval?.outcome, .skipped)
        XCTAssertEqual(skipped.echoRemoval?.skipReason, .headphones)
        XCTAssertNil(skipped.derivedTracks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: headphones.result.directory.appendingPathComponent(CaptureFinalizer.echoCancelledFileName).path))

        // Headphones reported, but the call still leaked into the microphone: it is removed anyway.
        let leaky = try await Self.stageCapture(in: try temporaryDirectory(), echoGain: 0.3, routes: [.headphones])
        let cleaned = CaptureFinalizer.finalize(leaky.result)
        XCTAssertEqual(cleaned.echoRemoval?.outcome, .applied)
        XCTAssertTrue(cleaned.echoRemoval?.detail?.contains("Headphones") == true)

        var micOnly = headphones.result
        micOnly.tracks.removeAll { $0.role == .systemAudio }
        micOnly.echoRemoval = nil
        XCTAssertEqual(CaptureFinalizer.finalize(micOnly).echoRemoval?.skipReason, .noCallTrack)
    }
}

// MARK: - From staged capture to library tracks

@MainActor
final class CallIngestTests: XCTestCase {
    func testFinishedCallBecomesOriginalsPlusADerivedTrackThatIsTranscribedInstead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookIngest-\(UUID().uuidString)")
        let defaults = makeTestDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let meetingID = UUID()
        let staging = root.appendingPathComponent("Staging/\(meetingID.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try await CaptureFinalizerTests.stageCapture(in: staging, seconds: 10)
        let micHash = try CallSignals.sha256(staging.appendingPathComponent("microphone.caf"))

        // Opening the library imports the staged recording exactly as finishing one does.
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        await state.flush()
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == meetingID })
        XCTAssertEqual(meeting.tracks.count, 3)
        let original = try XCTUnwrap(meeting.tracks.first { $0.source == .microphone && $0.derivedFrom == nil })
        let call = try XCTUnwrap(meeting.tracks.first { $0.source == .systemAudio })
        let derived = try XCTUnwrap(meeting.tracks.first { $0.derivedFrom != nil })
        XCTAssertEqual(derived.derivedFrom, original.id)
        XCTAssertEqual(derived.processing, RecordingTrack.echoCancelledProcessing)
        XCTAssertEqual(try XCTUnwrap(derived.offset), try XCTUnwrap(original.offset), accuracy: 0.001)
        XCTAssertEqual(original.sha256, micHash, "the library keeps the captured microphone byte for byte")
        let storedURL = await state.audioURL(for: original, meetingID: meetingID)
        let storedOriginal = try XCTUnwrap(storedURL)
        XCTAssertEqual(try CallSignals.sha256(storedOriginal), micHash)
        XCTAssertEqual(original.capture?.echoRemoval?.outcome, .applied)
        XCTAssertEqual(call.capture?.method, "process-tap")
        XCTAssertEqual(call.capture?.capturedApps, ["us.zoom.xos"])
        XCTAssertEqual(derived.capture?.method, "echo-cancelled")
        XCTAssertNotNil(original.capture?.clockRate)

        // Transcription uses the derived track in place of the original.
        XCTAssertEqual(Set(meeting.transcribableTracks.map(\.id)), [call.id, derived.id])
        XCTAssertEqual(state.defaultProcessingMode(for: meeting), .newAudio)
        var transcribed = meeting
        transcribed.transcripts = [call.id, derived.id].map { TrackTranscript(trackID: $0, segments: []) }
        XCTAssertFalse(transcribed.hasUntranscribedTranscribableAudio)
        XCTAssertEqual(state.defaultProcessingMode(for: transcribed), .summaryOnly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "staging is removed after durable import")

        // The provenance survives a restart.
        let reopened = AppState(libraryURL: root, defaults: defaults)
        await reopened.initialize()
        let saved = try XCTUnwrap(reopened.meetings.first { $0.id == meetingID })
        XCTAssertEqual(saved.tracks.first { $0.id == derived.id }?.derivedFrom, original.id)
        XCTAssertEqual(saved.tracks.first { $0.id == original.id }?.capture, original.capture)
    }
}
