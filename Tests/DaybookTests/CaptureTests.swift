import AVFoundation
import CoreAudio
import DaybookTestSupport
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

/// The monitor driven by scripted looks and times: nothing reads the real window list or audio server.
@MainActor
final class MeetingMonitorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let zoom = MeetingCandidate(bundleID: "us.zoom.xos", appName: "Zoom", windowTitle: "Zoom Meeting", hasInputActivity: true,
                                        hasOutputActivity: true, hasMeetingWindow: true, isBrowser: false)

    private func makeMonitor(endsRecording: Bool = true) -> (MeetingMonitor, ended: () -> Int) {
        let monitor = MeetingMonitor(read: { _ in .failed })
        var ends = 0
        monitor.onMeetingEnded = { _ in ends += 1; return endsRecording }
        return (monitor, { ends })
    }

    private func started(_ monitor: MeetingMonitor) {
        monitor.apply(.seen([zoom], windowsReadable: true), at: epoch)
        monitor.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(6))
        XCTAssertTrue(monitor.isMeetingActive)
    }

    func testOneFailedLookKeepsTheCallRecording() {
        let (monitor, ended) = makeMonitor()
        started(monitor)
        monitor.apply(.failed, at: epoch.addingTimeInterval(8))
        XCTAssertTrue(monitor.isMeetingActive, "one look that couldn't be made is unknown, not the end of the call")
        XCTAssertEqual(monitor.statusText, "Recording a Zoom call.", "and it passes unremarked")
        monitor.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(10))
        // Seen again, the call carries on: an absence starting later gets the whole grace again.
        monitor.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(12))
        monitor.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(56))
        XCTAssertTrue(monitor.isMeetingActive)
        XCTAssertEqual(ended(), 0, "never ended and started again as a second conversation")
        XCTAssertEqual(monitor.activeCandidate?.bundleID, zoom.bundleID)
    }

    func testLooksThatKeepFailingEndTheCallOnlyAfterTheEndGrace() {
        let (monitor, ended) = makeMonitor()
        started(monitor)
        for second in stride(from: 8.0, through: 52, by: 2) {
            monitor.apply(.failed, at: epoch.addingTimeInterval(second))
        }
        XCTAssertTrue(monitor.isMeetingActive)
        XCTAssertEqual(monitor.statusText, MeetingMonitor.cantCheck, "several failed looks in a row are said")
        monitor.apply(.failed, at: epoch.addingTimeInterval(53))
        XCTAssertFalse(monitor.isMeetingActive)
        XCTAssertEqual(ended(), 1)
        XCTAssertEqual(monitor.statusText, MeetingMonitor.endedAndStopped)
    }

    func testWithoutWindowTitlesACallContinuesOnItsAppsAudioAndNothingNewStarts() {
        let (monitor, ended) = makeMonitor()
        started(monitor)
        let audioOnly = MeetingCandidate(bundleID: zoom.bundleID, appName: "Zoom", windowTitle: "Zoom", hasInputActivity: true,
                                         hasOutputActivity: true, hasMeetingWindow: false, isBrowser: false)
        monitor.apply(.seen([audioOnly], windowsReadable: false), at: epoch.addingTimeInterval(8))
        monitor.apply(.seen([audioOnly], windowsReadable: false), at: epoch.addingTimeInterval(80))
        XCTAssertTrue(monitor.isMeetingActive, "a revoked permission doesn't end a call whose app still plays")
        monitor.apply(.seen([], windowsReadable: false), at: epoch.addingTimeInterval(82))
        monitor.apply(.seen([], windowsReadable: false), at: epoch.addingTimeInterval(127))
        XCTAssertEqual(ended(), 1, "its audio ending does")

        let (fresh, _) = makeMonitor()
        fresh.apply(.seen([audioOnly], windowsReadable: false), at: epoch)
        fresh.apply(.seen([audioOnly], windowsReadable: false), at: epoch.addingTimeInterval(30))
        XCTAssertFalse(fresh.isMeetingActive)
        XCTAssertEqual(fresh.statusText, MeetingMonitor.needsPermission)
    }

    func testTheEndedLineSaysWhetherARecordingStopped() {
        let (automatic, _) = makeMonitor(endsRecording: true)
        started(automatic)
        automatic.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(8))
        automatic.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(53))
        XCTAssertEqual(automatic.statusText, "The call ended, so recording stopped.")
        automatic.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(55))
        XCTAssertEqual(automatic.statusText, "The call ended, so recording stopped.", "kept until another call shows up")
        automatic.apply(.seen([zoom], windowsReadable: true), at: epoch.addingTimeInterval(57))
        XCTAssertEqual(automatic.statusText, "Checking whether the Zoom call has started…")

        let (manual, _) = makeMonitor(endsRecording: false)
        started(manual)
        manual.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(8))
        manual.apply(.seen([], windowsReadable: true), at: epoch.addingTimeInterval(53))
        XCTAssertEqual(manual.statusText, "The call ended.", "a recording someone started themselves goes on")
    }

    func testTheMonitorLooksOffTheMainThreadAndStopsLookingWhenStopped() async throws {
        let looks = LookLog()
        let monitor = MeetingMonitor(interval: .milliseconds(5)) { _ in
            looks.record(onMain: Thread.isMainThread)
            return .seen([], windowsReadable: true)
        }
        monitor.startMonitoring()
        XCTAssertEqual(monitor.statusText, MeetingMonitor.listening)
        try await waitUntil("a few looks") { looks.count >= 3 }
        monitor.stopMonitoring()
        let stoppedAt = looks.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(looks.count, stoppedAt + 1, "at most the look already under way")
        XCTAssertFalse(looks.anyOnMain, "never on the main thread")
        XCTAssertEqual(monitor.statusText, MeetingMonitor.off)
    }

    func testCandidatesComeFromOneProcessListAndTheTitledWindows() {
        let rules = MeetingAppRule.defaults
        let processes = [
            AudioProcessInfo(objectID: 1, pid: 10, bundleID: "us.zoom.xos", isRunningOutput: true, isRunningInput: true),
            AudioProcessInfo(objectID: 2, pid: 11, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true, isRunningInput: true),
            AudioProcessInfo(objectID: 3, pid: 12, bundleID: "com.google.Chrome.helper", isRunningOutput: true),
            AudioProcessInfo(objectID: 4, pid: 13, bundleID: "com.spotify.client", isRunningOutput: true)
        ]
        let windows = [
            MeetingActivityReader.Window(bundleID: "us.zoom.xos", title: "ZOOM MEETING"),
            MeetingActivityReader.Window(bundleID: "com.apple.Safari", title: "Meet - Weekly sync"),
            MeetingActivityReader.Window(bundleID: "com.google.Chrome", title: "Inbox"),
            MeetingActivityReader.Window(bundleID: "com.spotify.client", title: "Zoom Meeting playlist")
        ]
        let found = MeetingActivityReader.candidates(rules: rules, processes: processes, windows: windows)
        let byApp = Dictionary(uniqueKeysWithValues: found.map { ($0.bundleID, $0) })
        XCTAssertEqual(Set(byApp.keys), ["us.zoom.xos", "com.apple.Safari", "com.google.Chrome"], "never an app outside the rules")
        XCTAssertEqual(byApp["us.zoom.xos"]?.canStart, true, "titles match in any case")
        XCTAssertEqual(byApp["us.zoom.xos"]?.windowTitle, "ZOOM MEETING")
        let safari = byApp["com.apple.Safari"]
        XCTAssertEqual(safari?.hasInputActivity, true, "Safari's call audio is in WebKit's process, as the tap records it")
        XCTAssertEqual(safari?.canStart, true)
        let chrome = byApp["com.google.Chrome"]
        XCTAssertEqual(chrome?.hasMeetingWindow, false)
        XCTAssertEqual(chrome?.canStart, false, "a browser only playing audio beside an unrelated window isn't a call")
    }

    func testAProcessListThatCantBeReadIsUnknownNotEmpty() {
        XCTAssertNil(try? CoreAudioProperty.readArray(AudioObjectID(kAudioObjectUnknown), kAudioHardwarePropertyProcessObjectList) as [AudioObjectID],
                     "an object the audio server can't answer for throws")
        XCTAssertEqual(CoreAudioProperty.array(AudioObjectID(kAudioObjectUnknown), kAudioHardwarePropertyProcessObjectList) as [AudioObjectID], [],
                       "while the forgiving read stays empty")
    }
}

/// What a scripted look saw of its own thread, from whichever thread it ran on.
private final class LookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var looks = 0
    private var onMain = false
    var count: Int { lock.withLock { looks } }
    var anyOnMain: Bool { lock.withLock { onMain } }
    func record(onMain main: Bool) { lock.withLock { looks += 1; onMain = onMain || main } }
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
        // The padded gap starts a new clock segment.
        XCTAssertEqual(track.clockAnchors?.last?.resync, true)
        XCTAssertEqual(track.clockAnchors?.last?.frame, 14_400)
        let file = try AVAudioFile(forReading: track.url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][1_000], 0.25, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][8_000], 0, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][16_000], 0.25, accuracy: 0.0001)
    }

    /// A device switch (for example AirPods changing profile) no longer ends the recording: the new
    /// format is converted to the file's, and the clock restarts with a resync anchor.
    func testFormatChangeIsConvertedAndRecordingContinues() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        writer.append(audio(), hostTimeSeconds: 50)
        writer.append(audio(frames: 4_410, rate: 44_100), hostTimeSeconds: 50.1)
        writer.append(audio(frames: 4_410, rate: 44_100), hostTimeSeconds: 50.2)
        let outcome = await writer.finish()
        let track = try XCTUnwrap(outcome.track)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(track.sampleRate, 48_000)
        // Two 0.1 s buffers at 44.1 kHz become 9 600 frames at 48 kHz once the converter is drained.
        XCTAssertEqual(Double(track.frameCount), 14_400, accuracy: 2)
        XCTAssertEqual(try AVAudioFile(forReading: track.url).length, track.frameCount)
        XCTAssertTrue(track.clockAnchors?.contains { $0.resync == true } == true)
        XCTAssertFalse(track.notes?.isEmpty ?? true)
    }

    /// A device clock 900 ppm fast accumulates more than 100 ms of drift over two minutes. The old
    /// cumulative check stopped the recording; drift must neither stop it nor insert silence.
    func testSlowClockDriftNeitherStopsRecordingNorInsertsSilence() async throws {
        for drift in [900e-6, -900e-6] {
            let directory = try temporaryDirectory()
            let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 10, includeSystemAudio: false)
            let writer = PCMTrackWriter(role: .systemAudio, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
            let buffers = 1_300
            for index in 0..<buffers {
                writer.append(audio(frames: 800, rate: 8_000), hostTimeSeconds: 10 + Double(index) * 0.1 / (1 + drift))
                if index % 100 == 99 { await writer.waitUntilWritten() }
            }
            let outcome = await writer.finish()
            let track = try XCTUnwrap(outcome.track)
            XCTAssertNil(outcome.error)
            XCTAssertEqual(track.frameCount, Int64(buffers * 800))
            let anchors = try XCTUnwrap(track.clockAnchors)
            // About one anchor per second of host time.
            XCTAssertTrue((115...132).contains(anchors.count), "\(anchors.count) anchors")
            XCTAssertFalse(anchors.contains { $0.resync == true })
            XCTAssertEqual(track.clock.driftPPM, drift * 1e6, accuracy: 5)
        }
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

    /// The iPhone's rule on the Mac: a clock that jumps back half a second drops what overlaps the written audio and
    /// resyncs; the track never stops.
    func testBackwardClockJumpDropsTheOverlapAndKeepsRecording() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        writer.append(audio(frames: 48_000), hostTimeSeconds: 50)
        writer.append(audio(frames: 48_000), hostTimeSeconds: 50.5)
        writer.append(audio(frames: 48_000), hostTimeSeconds: 51.5)
        let outcome = await writer.finish()
        let track = try XCTUnwrap(outcome.track)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(track.frameCount, 48_000 * 5 / 2, "the half second that overlapped is dropped")
        XCTAssertEqual(track.gaps, [CaptureGap(kind: .overlap, frame: 48_000, seconds: 0.5)])
        XCTAssertEqual(track.clockAnchors?.first { $0.resync == true }?.hostTime ?? 0, 51, accuracy: 1e-9,
                       "the audio after the jump continues where the timeline is")
        XCTAssertEqual(try AVAudioFile(forReading: track.url).length, track.frameCount)
    }

    /// A source that returns 8 s later is padded (so transcript times hold), with 5 ms ramps at the seams so the silence
    /// doesn't click; one gone longer than five minutes isn't padded, and starts a new clock segment instead.
    func testForwardJumpsArePaddedWithRampsUpToFiveMinutesAndSkippedBeyond() async throws {
        let directory = try temporaryDirectory()
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 50, includeSystemAudio: false)
        let writer = PCMTrackWriter(role: .microphone, directory: directory, manifest: manifest) { XCTFail($0.localizedDescription) }
        writer.append(audio(), hostTimeSeconds: 50)
        writer.append(audio(), hostTimeSeconds: 58.1)
        writer.append(audio(), hostTimeSeconds: 58.2 + 400)
        let outcome = await writer.finish()
        let track = try XCTUnwrap(outcome.track)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(track.frameCount, 4_800 * 3 + 8 * 48_000, "8 s padded, the 400 s gap not")
        XCTAssertEqual(track.gaps?.map(\.kind), [.padded, .skipped])
        XCTAssertEqual(track.gaps?[0].seconds ?? 0, 8, accuracy: 1e-6)
        XCTAssertEqual(track.gaps?[1].seconds ?? 0, 400, accuracy: 1e-6)
        let resyncs = track.clockAnchors?.filter { $0.resync == true } ?? []
        XCTAssertEqual(resyncs.last?.hostTime ?? 0, 458.2, accuracy: 1e-9, "the audio after the long gap is placed by its own anchor")
        XCTAssertTrue(track.notes?.contains("1 gap was filled with silence (8 s). 1 gap longer than five minutes was left out (7 min).") == true,
                      "\(track.notes ?? [])")

        let file = try AVAudioFile(forReading: track.url)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: read)
        let samples = read.floatChannelData![0]
        let padStart = 4_800, padEnd = 4_800 + 8 * 48_000
        XCTAssertEqual(samples[padStart - 1], 0.25, accuracy: 1e-6, "the captured audio is untouched")
        XCTAssertEqual(samples[padStart], 0.25 * 240 / 241, accuracy: 1e-4, "the silence ramps down from the last sample")
        XCTAssertEqual(samples[padStart + 240], 0, accuracy: 1e-6, "and is silent after 5 ms")
        XCTAssertEqual(samples[padStart + 100_000], 0, accuracy: 1e-6)
        XCTAssertEqual(samples[padEnd - 1], 0.25 * 240 / 241, accuracy: 1e-4, "it ramps up into the next buffer")
        XCTAssertEqual(samples[padEnd], 0.25, accuracy: 1e-6)
    }
}
