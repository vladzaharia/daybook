import AVFoundation
import DaybookKit
import Foundation
import XCTest
@testable import Daybook

/// The live microphone on this Mac: owner-run, since it opens a microphone. Run with
/// `DAYBOOK_HARDWARE_TESTS=1 swift test --filter MicrophoneHardwareTests`; it counts audio and keeps none.
///
/// Guards v0.8.0's regression on macOS 27.0: with the input device set on the engine's input unit, the tap took the
/// node's stale output format and delivered nothing, and the engine posted a configuration change after every start,
/// which the source followed with a restart, ten times in two seconds, until its rate limit ended the recording.
final class MicrophoneHardwareTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAYBOOK_HARDWARE_TESTS"] == "1",
                          "Opens this Mac's microphone; set DAYBOOK_HARDWARE_TESTS=1 to run.")
    }

    /// The engine on the system's default input, nothing set: audio arrives steadily and no change is posted.
    func testBehaviorTheDefaultInputDeliversAudioWithoutAConfigurationChange() async throws {
        let engine = AVMicrophoneEngine()
        let seconds = Counter()
        var changes = 0
        engine.onConfigurationChange = { changes += 1 }
        let format = try engine.start(device: nil, deliver: { buffer, _ in
            seconds.add(Double(buffer.frameLength) / buffer.format.sampleRate)
        }, report: { event in
            if case .failed(let error) = event { XCTFail("the engine failed: \(error)") }
        })
        defer { engine.stop() }
        XCTAssertGreaterThan(format.sampleRate, 0)
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(seconds.value, 1.5, "two seconds on the default input delivered \(seconds.value) s of audio")
        XCTAssertEqual(changes, 0)
    }

    /// An input set on the engine (one that isn't the default): the source records it through the engine's one
    /// reconfiguration after the start, restarting if that stopped the engine, and audio arrives.
    @MainActor
    func testBehaviorAnInputSetOnTheEngineIsRecordedThroughTheSource() async throws {
        let live = CoreAudioInputs.snapshot(preference: .automatic)
        let builtIn = try XCTUnwrap(live.builtIn, "this Mac has no built-in microphone")
        // The inputs as they are, with the default claimed elsewhere, so the built-in microphone is set explicitly.
        let devices = ClaimedDefault(devices: live.devices, preference: .device(builtIn))
        let seconds = Counter()
        var failures: [String] = []
        let microphone = MicrophoneSource(engine: AVMicrophoneEngine(), devices: devices, reportInput: { _ in })
        try await microphone.start(onBuffer: { buffer, _ in
            seconds.add(Double(buffer.frameLength) / buffer.format.sampleRate)
        }, onEvent: { event in if case .failed(let error) = event { failures.append("\(error)") } })
        try await Task.sleep(for: .seconds(2.5))
        await microphone.stop()
        XCTAssertEqual(failures, [])
        XCTAssertGreaterThan(seconds.value, 1.5, "2.5 s on \(builtIn.name), set explicitly, delivered \(seconds.value) s of audio")
    }

    /// The whole recorder on the live microphone: five seconds in, the track holds them, nothing warned, nothing stopped.
    @MainActor
    func testBehaviorTheRecorderKeepsRecordingTheMicrophone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RecordingController()
        var stoppedFor: String?
        recorder.onUnexpectedStop = { _, why in stoppedFor = why }
        try await recorder.start(in: directory, includeSystemAudio: false)
        try await Task.sleep(for: .seconds(5))
        XCTAssertNil(stoppedFor, "the recording ended on its own")
        let stopped = await recorder.stop()
        let result = try XCTUnwrap(stopped, "the recording was no longer running after five seconds")
        let microphone = try XCTUnwrap(result.tracks.first { $0.role == .microphone })
        XCTAssertGreaterThan(microphone.duration, 4, "five seconds recorded \(microphone.duration) s")
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(microphone.notes ?? [], [], "no device change or restart happened")
    }

    /// The live inputs with the system's default reported as another device, so the choice is set on the engine.
    private final class ClaimedDefault: MicrophoneDevices, @unchecked Sendable {
        let devices: [MicrophoneChoice.Device]
        let preference: MicrophoneChoice.Preference
        var onChange: (() -> Void)?
        init(devices: [MicrophoneChoice.Device], preference: MicrophoneChoice.Preference) {
            self.devices = devices; self.preference = preference
        }
        func snapshot() -> MicrophoneChoice.Snapshot {
            MicrophoneChoice.Snapshot(devices: devices, systemDefault: "not-this-one", preference: preference)
        }
        func follow(_ id: String?) {}
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0.0
        var value: Double { lock.withLock { total } }
        func add(_ seconds: Double) { lock.withLock { total += seconds } }
    }
}
