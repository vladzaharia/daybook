import AVFoundation
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// What the person hears when a recording is interrupted or stops by itself: a Resume that fails says
/// why, the widgets and the Live Activity offer Resume only once it can work (Stop during the call), and a
/// recording that stops in the pocket ends its activity as stopped and posts a time-sensitive notification.
/// A scripted audio session and synthetic audio; nothing reaches ActivityKit or the notification center.
@MainActor
final class RecordingInterruptionsTests: XCTestCase {
    private func makeModel(rig: RecorderRig) throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             environment: try .test(self))
    }

    private var callHolding: Error { NSError(domain: NSOSStatusErrorDomain, code: 561_017_449) }   // '!pri': another app has priority

    // MARK: Resume

    func testBehaviorAResumeThatFailsSaysWhyAndStaysPaused() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(1)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused for the call") { model.recorder.isPaused }
        rig.session.send(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(model.recorder.canResume)

        // Another app still holds the audio session.
        rig.session.activationError = callHolding
        do {
            try await model.resumeRecording()
            XCTFail("resumed while another app held the microphone")
        } catch let error as RecordingCommandError {
            XCTAssertEqual(String(localized: error.localizedStringResource), "Couldn’t resume recording. Open Daybook to try again.")
        }
        XCTAssertEqual(model.notice, "Couldn’t resume recording. Try again.")
        XCTAssertNotNil(model.noticeDetails, "the system's words, behind Details")
        XCTAssertTrue(model.recorder.isPaused, "still paused, with Resume")
        XCTAssertTrue(model.recorder.canResume)

        rig.session.activationError = nil
        try await model.resumeRecording()
        XCTAssertEqual(model.recorder.state, .recording)
        XCTAssertNil(model.recorder.lastFailure)
        try await model.stopRecording()
    }

    func testBehaviorAnAutomaticResumeThatFailsSaysWhyToo() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(1)
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused for the call") { model.recorder.isPaused }
        rig.session.activationError = callHolding
        // iOS asks to continue, but the session can't be had.
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("the failure is said") { model.notice != nil }
        XCTAssertEqual(model.notice, "Couldn’t resume recording. Try again.")
        XCTAssertTrue(model.recorder.isPaused)
        rig.session.activationError = nil
        try await model.stopRecording()
    }

    // MARK: What the widgets and the Live Activity offer while paused

    func testBehaviorResumeIsOfferedOnlyOnceTheCallIsOver() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(1)
        XCTAssertNil(model.activityState().canResume, "recording: nothing to resume")
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("paused for the call") { model.recorder.isPaused }

        // During the call: the frozen clock and Stop.
        let duringCall = model.activityState()
        XCTAssertEqual(duringCall.phase, .paused)
        XCTAssertEqual(duringCall.canResume, false)
        XCTAssertFalse(duringCall.offersResume)
        var shared = SharedRecordingState()
        shared.phase = .paused
        shared.canResume = false
        XCTAssertFalse(shared.offersResume, "the widgets offer Stop")

        rig.session.send(.interruptionEnded(shouldResume: false))
        let after = model.activityState()
        XCTAssertEqual(after.canResume, true)
        XCTAssertTrue(after.offersResume)
        shared.canResume = true
        XCTAssertTrue(shared.offersResume, "the widgets offer Resume")
        try await model.stopRecording()
    }

    func testBehaviorAPausedStateFromAnEarlierBuildStillOffersResume() throws {
        let earlier = #"{"phase":"paused","timerStart":800000000,"frozenElapsed":12,"level":0,"bookmarkCount":0}"#
        let activity = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: Data(earlier.utf8))
        XCTAssertNil(activity.canResume)
        XCTAssertTrue(activity.offersResume)
        let widget = try JSONDecoder().decode(SharedRecordingState.self, from: Data(#"{"phase":"paused","bookmarkCount":0}"#.utf8))
        XCTAssertTrue(widget.offersResume)
    }

    func testBehaviorTheActivitysLevelChangesOnlyWhenTheMicrophoneGoesSilent() async throws {
        let rig = RecorderRig(signal: .tone(frequency: 440, amplitude: 0.3))
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        XCTAssertEqual(model.activityState().level, 1, "hearing")
        rig.pump(0.2)
        rig.recorder.updateLevels()
        XCTAssertEqual(model.activityState().level, 1, "the voice getting louder or quieter sends nothing")
        try await model.stopRecording()
    }

    // MARK: Stopped by itself

    func testBehaviorARecordingThatStopsByItselfEndsAsStoppedAndNotifiesThePocket() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        var posted: [PhoneNotices.Notice] = []
        model.notices = PhoneNotices(post: { posted.append($0) }, remove: { _ in }, askPermission: {})
        try await model.startRecording()
        rig.pump(5)
        // Daybook isn't in front: the phone is in a pocket.
        model.scenePhaseChanged(.background)
        let stopped = await rig.recorder.stop()
        let recording = try XCTUnwrap(stopped)
        rig.recorder.onUnexpectedStop?(recording)
        try await waitUntil("filed and said") { model.lastFiling != nil && model.notice != nil }

        guard case .saved(let id, _)? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        XCTAssertEqual(model.notice, "Recording stopped. Everything up to 0:05 is saved.")
        let notice = try XCTUnwrap(posted.first)
        XCTAssertEqual(notice.id, PhoneNotices.recordingStoppedID)
        XCTAssertEqual(notice.title, "Recording stopped")
        XCTAssertEqual(notice.body, "Everything up to 0:05 is saved.")
        XCTAssertTrue(notice.timeSensitive)
        XCTAssertEqual(notice.destination, .conversation(id), "opening it shows what was saved")
        model.scenePhaseChanged(.active)
    }

    func testBehaviorAStopAsTheRecordingStopsByItselfWaitsForThatStop() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        rig.pump(5)
        // Storage gives out (the recorder finishes what it has, then says so) just as the person taps Stop.
        let byItself = Task { @MainActor in
            let recording = await rig.recorder.stop()
            rig.recorder.onUnexpectedStop?(recording)
        }
        let stop = Task { @MainActor () -> String in
            do {
                try await model.stopRecording()
                return model.lastStopResult.sentence
            } catch {
                return "threw \(error)"
            }
        }
        await byItself.value
        let said = await stop.value

        XCTAssertEqual(said, "Saved to Daybook.")
        guard case .saved? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        XCTAssertNil(model.activities.savingOn, "the person's Stop left the activity to the stop under way")
        XCTAssertEqual(model.activities.endedOn?.phase, .stopped)
        XCTAssertEqual(model.activities.endedOn?.endLine, "Everything up to then is saved", "never “No audio was recorded”")
        XCTAssertEqual(model.notice, "Recording stopped. Everything up to 0:05 is saved.")
        XCTAssertNil(model.stopUnderway)
    }

    func testBehaviorTheStoppedActivityAndNotificationSayWhatsSaved() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let stopped = RecordingActivityAttributes.ContentState(phase: .stopped, timerStart: started, frozenElapsed: 3_734, level: 0, bookmarkCount: 2)
        XCTAssertEqual(stopped.title(isStale: false), "Recording stopped")
        XCTAssertEqual(stopped.title(isStale: true), "Recording stopped", "it never reads as unconfirmed")
        XCTAssertNil(stopped.staleDate(from: started))
        XCTAssertTrue(stopped.hasEnded)
        XCTAssertEqual(stopped.endLine, "Everything up to then is saved")
        XCTAssertEqual(RecordingActivityController.dismissal(for: stopped, now: started), .default, "stays until the person has seen it")
        var saved = stopped
        saved.phase = .saved
        XCTAssertEqual(RecordingActivityController.dismissal(for: saved, now: started), .after(started.addingTimeInterval(8)))

        // The writer's own error when storage fills up.
        let full = PhoneNotices.recordingStoppedText(savedUpTo: 3_734, because: NSError(domain: AVFoundationErrorDomain, code: -11807))
        XCTAssertEqual(full.title, "Recording stopped")
        XCTAssertEqual(full.body, "Everything up to 1:02:14 is saved. Free up space to record again.")
        XCTAssertEqual(PhoneNotices.recordingStoppedText(savedUpTo: 3_734, because: PhoneRecorderError.encoderUnavailable("x")).body,
                       "Everything up to 1:02:14 is saved.")
        XCTAssertEqual(PhoneNotices.recordingStoppedText(savedUpTo: nil, because: nil, otherwise: "No audio was recorded.").body,
                       "No audio was recorded.")
        let nothing = PhoneAppModel.stoppedActivity(recording: nil, bookmarks: 0)
        XCTAssertEqual(nothing.endLine, "No audio was recorded")
    }

    func testBehaviorFreeUpSpaceIsAskedOnlyWhenStorageIsFull() {
        let gigabyte: Int64 = 1_000_000_000
        // Out of space, however the writer says it.
        XCTAssertTrue(PhoneNotices.isStorageFull(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue), spaceLeft: nil))
        XCTAssertTrue(PhoneNotices.isStorageFull(CocoaError(.fileWriteOutOfSpace), spaceLeft: nil))
        XCTAssertTrue(PhoneNotices.isStorageFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), spaceLeft: nil))
        let underneath = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
                                 userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(PhoneNotices.isStorageFull(underneath, spaceLeft: 50 * gigabyte), "the writer's own error, out of space underneath")
        XCTAssertEqual(PhoneNotices.recordingStoppedText(savedUpTo: 65, because: underneath).body,
                       "Everything up to 1:05 is saved. Free up space to record again.")

        // Storage that couldn't keep up is full only when little is left.
        XCTAssertTrue(PhoneNotices.isStorageFull(PhoneRecorderError.diskBacklog, spaceLeft: gigabyte / 5))
        XCTAssertEqual(PhoneNotices.recordingStoppedText(savedUpTo: 65, because: PhoneRecorderError.diskBacklog, spaceLeft: gigabyte / 5).body,
                       "Everything up to 1:05 is saved. Free up space to record again.")
        XCTAssertFalse(PhoneNotices.isStorageFull(PhoneRecorderError.diskBacklog, spaceLeft: 50 * gigabyte), "slow, with space to spare")
        XCTAssertEqual(PhoneNotices.recordingStoppedText(savedUpTo: 65, because: PhoneRecorderError.diskBacklog, spaceLeft: 50 * gigabyte).body,
                       "Everything up to 1:05 is saved.")
        XCTAssertFalse(PhoneNotices.isStorageFull(PhoneRecorderError.diskBacklog, spaceLeft: nil), "space unknown: never guessed")

        // Anything else isn't about space.
        XCTAssertFalse(PhoneNotices.isStorageFull(PhoneRecorderError.encoderUnavailable("append"), spaceLeft: 0))
        XCTAssertFalse(PhoneNotices.isStorageFull(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue), spaceLeft: 0))
        XCTAssertFalse(PhoneNotices.isStorageFull(nil, spaceLeft: 0))
    }
}
