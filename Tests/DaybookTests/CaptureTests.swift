import AVFoundation
import XCTest
@testable import Daybook

final class MeetingDetectionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func candidate(input: Bool = true, output: Bool = false, window: Bool = true, browser: Bool = false) -> MeetingCandidate {
        .init(bundleID: browser ? "com.google.Chrome" : "us.zoom.xos", appName: "Meeting app", windowTitle: "Meeting",
              hasInputActivity: input, hasOutputActivity: output, hasMeetingWindow: window, isBrowser: browser)
    }

    func testRunningAppAndAudioSettingsDoNotStartRecording() {
        var machine = MeetingDetectionStateMachine()
        let merelyOpen = candidate(input: false, window: false)
        let audioSettings = candidate(input: true, output: true, window: false)
        XCTAssertNil(machine.update([merelyOpen], at: epoch))
        XCTAssertNil(machine.update([audioSettings], at: epoch.addingTimeInterval(60)))
        XCTAssertNil(machine.activeBundleID)
    }

    func testStartRequiresContinuousEvidenceAndDebounces() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate()
        XCTAssertNil(machine.update([call], at: epoch))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(5)))
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(6)))
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(11)))
        XCTAssertEqual(machine.update([call], at: epoch.addingTimeInterval(12)), .started(call))
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(20)))
    }

    func testMutedNativeCallContinuesUntilMeetingWindowCloses() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate()
        _ = machine.update([call], at: epoch)
        _ = machine.update([call], at: epoch.addingTimeInterval(6))
        let muted = candidate(input: false)
        XCTAssertNil(machine.update([muted], at: epoch.addingTimeInterval(100)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(101)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(145)))
        XCTAssertEqual(machine.update([], at: epoch.addingTimeInterval(146)), .ended)
    }

    func testBrowserTabStayingOpenDoesNotPreventEnd() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate(browser: true)
        _ = machine.update([call], at: epoch)
        _ = machine.update([call], at: epoch.addingTimeInterval(6))
        let endedTab = candidate(input: false, browser: true)
        XCTAssertNil(machine.update([endedTab], at: epoch.addingTimeInterval(10)))
        XCTAssertEqual(machine.update([endedTab], at: epoch.addingTimeInterval(55)), .ended)
    }

    func testManualStopSuppressesUntilOriginalCallEnds() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate()
        _ = machine.update([call], at: epoch)
        _ = machine.update([call], at: epoch.addingTimeInterval(6))
        machine.suppressCurrentMeeting()
        XCTAssertNil(machine.activeBundleID)
        XCTAssertEqual(machine.suppressedBundleID, call.bundleID)
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(100)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(101)))
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(110)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(120)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(165)))
        XCTAssertNil(machine.suppressedBundleID)
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(166)))
        XCTAssertEqual(machine.update([call], at: epoch.addingTimeInterval(172)), .started(call))
    }

    func testReceivingAudioCanStartMutedMeeting() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate(input: false, output: true)
        XCTAssertNil(machine.update([call], at: epoch))
        XCTAssertEqual(machine.update([call], at: epoch.addingTimeInterval(6)), .started(call))
    }

    func testBrowserPlaybackBesideDormantMeetingTabDoesNotStartRecording() {
        var machine = MeetingDetectionStateMachine()
        let dormantTabWithMusic = candidate(input: false, output: true, browser: true)
        XCTAssertNil(machine.update([dormantTabWithMusic], at: epoch))
        XCTAssertNil(machine.update([dormantTabWithMusic], at: epoch.addingTimeInterval(60)))
        XCTAssertNil(machine.activeBundleID)
    }

    func testBrowserMeetingContinuesOnOutputAfterMicrophoneMutes() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate(browser: true)
        _ = machine.update([call], at: epoch)
        XCTAssertEqual(machine.update([call], at: epoch.addingTimeInterval(6)), .started(call))
        let muted = candidate(input: false, output: true, browser: true)
        XCTAssertNil(machine.update([muted], at: epoch.addingTimeInterval(100)))
        XCTAssertEqual(machine.activeBundleID, call.bundleID)
    }

    func testBriefActivityLossDoesNotSplitMeeting() {
        var machine = MeetingDetectionStateMachine()
        let call = candidate(browser: true)
        _ = machine.update([call], at: epoch)
        _ = machine.update([call], at: epoch.addingTimeInterval(6))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(10)))
        XCTAssertNil(machine.update([call], at: epoch.addingTimeInterval(40)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(50)))
        XCTAssertNil(machine.update([], at: epoch.addingTimeInterval(80)))
        XCTAssertEqual(machine.update([], at: epoch.addingTimeInterval(95)), .ended)
    }
}

final class PCMTrackWriterTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func audio(frames: UInt32 = 4_800, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.25 }
        return buffer
    }

    func testTracksHaveSharedClockOffsetsAndPersistReadableAudio() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000), hostTimeSeconds: 50, includeSystemAudio: true)
        let mic = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        let system = PCMTrackWriter(role: .systemAudio, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        mic.append(audio(), hostTimeSeconds: 50.2)
        system.append(audio(), hostTimeSeconds: 50.5)
        let micOutcome = await mic.finish()
        let systemOutcome = await system.finish()
        let micTrack = try XCTUnwrap(micOutcome.track)
        let systemTrack = try XCTUnwrap(systemOutcome.track)
        XCTAssertNil(micOutcome.error)
        XCTAssertNil(systemOutcome.error)
        XCTAssertEqual(micTrack.offsetSeconds, 0.2, accuracy: 0.00001)
        XCTAssertEqual(systemTrack.offsetSeconds, 0.5, accuracy: 0.00001)
        XCTAssertEqual(systemTrack.startedAt.timeIntervalSince(micTrack.startedAt), 0.3, accuracy: 0.00001)
        XCTAssertEqual(try AVAudioFile(forReading: micTrack.url).length, 4_800)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let saved = try decoder.decode(CapturedAudioTrack.self, from: Data(contentsOf: directory.appendingPathComponent("systemAudio.json")))
        XCTAssertEqual(saved.offsetSeconds, 0.5, accuracy: 0.00001)
        XCTAssertEqual(saved.frameCount, 4_800)
    }

    func testClockGapsArePaddedToPreserveTranscriptTiming() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        writer.append(audio(), hostTimeSeconds: 50)
        writer.append(audio(), hostTimeSeconds: 50.3)
        let outcome = await writer.finish()
        let track = try XCTUnwrap(outcome.track)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(track.duration, 0.4, accuracy: 1.0 / 48_000)
        let file = try AVAudioFile(forReading: track.url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][1_000], 0.25, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][8_000], 0, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][16_000], 0.25, accuracy: 0.0001)
    }

    func testFormatChangePreservesPartialRecording() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let failure = expectation(description: "format change reported")
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { _ in failure.fulfill() }
        writer.append(audio(), hostTimeSeconds: 50)
        writer.append(audio(rate: 44_100), hostTimeSeconds: 50.1)
        let outcome = await writer.finish()
        await fulfillment(of: [failure], timeout: 2)
        let track = try XCTUnwrap(outcome.track)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(track.frameCount, 4_800)
        XCTAssertEqual(try AVAudioFile(forReading: track.url).length, 4_800)
    }

    func testAudioBufferCopyOwnsItsSamples() {
        let original = audio()
        let copy = PCMTrackWriter.copy(original)!
        original.floatChannelData![0][0] = 0.75
        XCTAssertEqual(copy.floatChannelData![0][0], 0.25, accuracy: 0.0001)
    }

    func testInterruptedRecordingRecoveryPreservesSubsecondTimingAndReadsActualFrames() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000.123), hostTimeSeconds: 50, includeSystemAudio: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("capture-session.json"))
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        writer.append(audio(), hostTimeSeconds: 50.2)
        writer.append(audio(), hostTimeSeconds: 50.3)
        let outcome = await writer.finish()
        var oldSidecar = try XCTUnwrap(outcome.track)
        oldSidecar.frameCount = 4_800
        try encoder.encode(oldSidecar).write(to: directory.appendingPathComponent("microphone.json"))
        let recovered = try XCTUnwrap(CaptureRecovery.recover(in: directory))
        XCTAssertEqual(recovered.id, manifest.id)
        XCTAssertEqual(recovered.tracks.count, 1)
        XCTAssertEqual(recovered.tracks[0].frameCount, 9_600)
        XCTAssertEqual(recovered.tracks[0].offsetSeconds, 0.2, accuracy: 0.00001)
        XCTAssertEqual(recovered.tracks[0].startedAt.timeIntervalSince1970, 1_000.323, accuracy: 0.00001)
        XCTAssertFalse(recovered.warnings.isEmpty)
    }

    func testBackwardClockJumpStopsWithoutCorruptingPartialAudio() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let failure = expectation(description: "clock jump reported")
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { _ in failure.fulfill() }
        writer.append(audio(), hostTimeSeconds: 50)
        writer.append(audio(), hostTimeSeconds: 49)
        let outcome = await writer.finish()
        await fulfillment(of: [failure], timeout: 2)
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.track?.frameCount, 4_800)
    }
}
