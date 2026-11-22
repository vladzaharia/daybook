import AVFoundation
import DaybookCore
import DaybookKit
import DaybookUI
import XCTest
@testable import DaybookPhone

/// The person's own pause on the iPhone (docs/iphone.md, "Pausing"): the microphone stops and the open part closes,
/// so nothing of the pause is heard, given to captions, or kept, and the joined file is silent through it; only the
/// person resumes it; it's offered only while nothing records along. Synthetic audio and a scripted session.
@MainActor
final class PersonPauseTests: XCTestCase {
    private func makeModel(rig: RecorderRig) throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             environment: try .test(self))
    }

    /// A tone through a two-second pause: the microphone stops, captions hear nothing of it, a call that comes and goes
    /// meanwhile doesn't resume it, and the joined file is silent there and keeps its place on the timeline.
    func testBehaviorThePersonsPauseStopsTheMicrophoneAndKeepsNothingOfIt() async throws {
        let rig = RecorderRig()
        let heard = TapLog()
        rig.recorder.audioTap = heard.handler()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Standup")
        rig.pump(3)
        // The microphone keeps handing over audio after it's told to stop, as an engine's last buffers can.
        let microphone = rig.inputs.current
        microphone.deliversAfterStop = true
        let paused = await rig.recorder.pauseByPerson()
        XCTAssertTrue(paused)
        XCTAssertEqual(rig.recorder.state, .paused(.person))
        XCTAssertTrue(rig.recorder.isPausedByPerson)
        XCTAssertTrue(rig.recorder.canResume, "the person resumes it whenever they like")
        XCTAssertNil(rig.recorder.pauseMessage)
        let again = await rig.recorder.pauseByPerson()
        XCTAssertFalse(again, "paused already")
        let heardBefore = heard.count

        microphone.pump(seconds: 2)
        XCTAssertEqual(heard.count, heardBefore, "nothing it hands over reaches captions while paused")
        // A call comes and goes meanwhile: it doesn't take the person's pause away.
        rig.session.send(.interruptionBegan(reason: nil))
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.recorder.state, .paused(.person))

        try await rig.recorder.resume()
        XCTAssertEqual(rig.recorder.state, .recording)
        XCTAssertFalse(rig.inputs.current === microphone, "the microphone was stopped: Resume starts it afresh")
        rig.pump(2)
        XCTAssertGreaterThan(heard.count, heardBefore)

        let recording = try await rig.stop()
        XCTAssertEqual(recording.duration, 7, accuracy: 0.01, "3 s, the 2 s pause, 2 s")
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.rms(0.3..<2.8), toneRMS, accuracy: 0.02)
        XCTAssertLessThan(audio.rms(3.2..<4.8), 0.003, "the pause is silence")
        XCTAssertEqual(audio.rms(5.2..<6.8), toneRMS, accuracy: 0.02)
        XCTAssertTrue(recording.capture.notes?.contains("Paused 0:03–0:05; the gap is silent.") == true, "\(recording.capture.notes ?? [])")
        let pause = try XCTUnwrap(recording.capture.pauses?.first, "kept with the track: nothing heard there is transcribed")
        XCTAssertEqual(recording.capture.pauses?.count, 1)
        XCTAssertEqual(pause.start, 3, accuracy: 0.01)
        XCTAssertEqual(pause.end, 5, accuracy: 0.01)
    }

    /// iOS ends Daybook while the person has it paused: what comes back ends where the pause began, with nothing of the
    /// pause, and it's filed as if Stop had ended it there, without saying Daybook quit while recording.
    func testBehaviorACrashWhilePausedRecoversOnlyWhatCameBefore() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Crash")
        rig.pump(3)
        await rig.recorder.pauseByPerson()
        rig.clock.advance(5)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()

        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).state, .paused)
        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertNil(recording.recovery, "whole up to the pause: nothing to recover from")
        XCTAssertFalse(recording.warnings.contains(RecordingWords.recoveredAfterQuit), "\(recording.warnings)")
        XCTAssertEqual(recording.duration, 3, accuracy: 0.01)
        XCTAssertEqual(recording.endedAt.timeIntervalSince(recording.startedAt), 3, accuracy: 0.01, "it ends where the pause began")
        XCTAssertNil(recording.capture.pauses, "no audio after it: nothing to leave out")
        let audio = try DecodedAudio(url: recording.audioURL)
        XCTAssertEqual(audio.rms(0.3..<2.8), toneRMS, accuracy: 0.02)
    }

    // MARK: Where it's offered

    func testBehaviorPauseIsOfferedOnlyWhileNothingRecordsAlong() {
        XCTAssertTrue(PhoneAppModel.recordsAlone(multipoint: nil, recorderOnly: false, recorders: []))
        XCTAssertTrue(PhoneAppModel.recordsAlone(multipoint: nil, recorderOnly: false, recorders: [.unavailable("Soundcore isn’t nearby."), .stopped]),
                      "a recorder that isn't recording along doesn't count")
        for state in [RecorderCascade.State.starting, .recording, .stopping] {
            XCTAssertFalse(PhoneAppModel.recordsAlone(multipoint: nil, recorderOnly: false, recorders: [state]), "\(state)")
        }
        XCTAssertFalse(PhoneAppModel.recordsAlone(multipoint: MultipointSession(conversationID: UUID(), role: .phoneLed), recorderOnly: false,
                                                  recorders: []), "a Mac recording along, or asked to")
        XCTAssertFalse(PhoneAppModel.recordsAlone(multipoint: nil, recorderOnly: true, recorders: []))
        XCTAssertFalse(PhoneAppModel.recordsAlone(multipoint: nil, recorderOnly: false, recorders: [], macRecordsIt: true),
                       "a Mac that says it records this conversation, asked or not")
    }

    /// A call that pauses the recording and an iOS end during it still say Daybook quit while recording.
    func testBehaviorAnInterruptedRecordingEndedByIOSStillSaysItQuit() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try await rig.recorder.start(in: folder, title: "Call")
        rig.pump(3)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused for the call") { rig.recorder.isPaused }
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()
        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertEqual(recording.recovery, .quitWhileRecording)
    }

    /// Recording alone, the recorder and the Live Activity offer Pause; paused, Resume, with nothing posted and nothing
    /// resuming it when Daybook comes back to the front.
    func testBehaviorTheModelsPauseIsOfferedAloneAndOnlyThePersonResumesIt() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        let log = PauseNoticeLog()
        model.notices = PhoneNotices(post: { log.posted.append($0) }, remove: { log.removed.append($0) }, askPermission: {})
        try await model.startRecording()
        rig.pump(1)
        XCTAssertTrue(model.canPauseRecording)
        let recording = model.activityState()
        XCTAssertEqual(recording.canPause, true)
        XCTAssertTrue(recording.offersPause)

        model.scenePhaseChanged(.background)
        try await model.pauseRecording()
        XCTAssertEqual(model.recorder.state, .paused(.person))
        XCTAssertFalse(model.canPauseRecording)
        let paused = model.activityState()
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNil(paused.canPause)
        XCTAssertFalse(paused.offersPause)
        XCTAssertTrue(paused.offersResume)
        XCTAssertEqual(paused.frozenElapsed ?? 0, 1, accuracy: 1e-6)
        XCTAssertTrue(log.posted.isEmpty, "the person paused it: nothing to say")
        model.scenePhaseChanged(.active)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.recorder.state, .paused(.person), "only the person resumes it")
        do {
            try await model.pauseRecording()
            XCTFail("paused twice")
        } catch {}

        try await model.resumeRecording()
        XCTAssertEqual(model.recorder.state, .recording)
        XCTAssertTrue(model.canPauseRecording)
        try await model.stopRecording()
        XCTAssertFalse(model.canPauseRecording)
        // A Resume left on the Lock Screen after the recording ended says so, not that nothing records.
        do {
            try await model.resumeRecording()
            XCTFail("resumed nothing")
        } catch RecordingCommandError.failed(let words) {
            XCTAssertEqual(words, RecordingDialogs.recordingEnded)
        }
    }

    func testBehaviorAnActivityFromAnEarlierBuildOffersNoPause() throws {
        let earlier = #"{"phase":"recording","timerStart":800000000,"level":1,"bookmarkCount":0}"#
        let activity = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: Data(earlier.utf8))
        XCTAssertNil(activity.canPause)
        XCTAssertFalse(activity.offersPause)
    }

    func testBehaviorThePersonsPauseSaysPausedWithResume() {
        let pause = PhoneRecorderStatus.pause(.paused(.person), message: nil, canResume: true)
        XCTAssertEqual(pause, RecordingStatusWords.personPaused)
        XCTAssertEqual(pause?.title, "Paused")
        XCTAssertEqual(pause?.message, "", "nothing more to say")
        XCTAssertEqual(pause?.canResume, true)
        XCTAssertEqual(pause?.kind, .info, "not a problem")
        XCTAssertEqual(PhoneRecorderStatus.pause(.paused(.interruption), message: PhoneRecorder.unspecifiedInterruption, canResume: false)?.kind,
                       .problem)
        XCTAssertEqual(pause?.showsBox, false, "the status above says Paused: Resume alone")
        XCTAssertEqual(PhoneRecorderStatus.pause(.paused(.interruption), message: PhoneRecorder.unspecifiedInterruption, canResume: false)?.showsBox,
                       true, "a call's pause keeps its box and its words")
    }
}

/// The notifications a test's app model posted and took away.
@MainActor
private final class PauseNoticeLog {
    var posted: [PhoneNotices.Notice] = []
    var removed: [String] = []
}

/// What the recorder's live tap was given.
final class TapLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0

    var count: Int { lock.withLock { buffers } }

    func handler() -> @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void {
        { @Sendable [self] _, _ in lock.withLock { buffers += 1 } }
    }
}
