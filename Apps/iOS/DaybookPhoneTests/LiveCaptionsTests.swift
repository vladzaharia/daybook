import AVFoundation
import DaybookCaptions
import DaybookDesign
import DaybookKit
import DaybookLink
import DaybookUI
import XCTest
@testable import DaybookPhone

/// Live captions: tentative text replaced in place, finals kept, saved phone-locally by conversation
/// with the phone track once filed, removed with the conversation, mapped across a pause, and never
/// in the recording's way, even when the captioner fails. No speech recognition runs here.
@MainActor
final class LiveCaptionsTests: XCTestCase {
    /// A captioner that fails at once; the recording must not notice.
    final class FailingCaptioner: LiveCaptioning, @unchecked Sendable {
        let updates: AsyncStream<[LiveCaptionSegment]>
        let states: AsyncStream<LiveCaptionState>
        private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
        private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation

        init() {
            (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream()
            (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream()
        }

        func start(locale: Locale, sourceFormat: AVAudioFormat?) async { statesContinuation.yield(.failed("The recognizer stopped.")) }
        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {}
        func finish() async { updatesContinuation.finish(); statesContinuation.finish() }
    }

    /// A captioner whose live speaker model missed what it heard (shed under heat, say): its line waits
    /// for speakers from the recording.
    final class SpeakerlessCaptioner: LiveCaptioning, @unchecked Sendable {
        let updates: AsyncStream<[LiveCaptionSegment]>
        let states: AsyncStream<LiveCaptionState>
        private let updatesContinuation: AsyncStream<[LiveCaptionSegment]>.Continuation
        private let statesContinuation: AsyncStream<LiveCaptionState>.Continuation

        init() {
            (updates, updatesContinuation) = AsyncStream<[LiveCaptionSegment]>.makeStream()
            (states, statesContinuation) = AsyncStream<LiveCaptionState>.makeStream()
        }

        func start(locale: Locale, sourceFormat: AVAudioFormat?) async {
            statesContinuation.yield(.listening)
            updatesContinuation.yield([LiveCaptionSegment(start: 0.2, end: 1.4, text: "Nobody knew who said this", isTentative: false,
                                                          needsSpeaker: true)])
        }
        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {}
        func finish() async { updatesContinuation.finish(); statesContinuation.finish() }
    }

    private func makeModel(rig: RecorderRig, captioner: any LiveCaptioning) throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
        let settings = PhoneSettings(defaults: makeTestDefaults("LiveCaptionsTests"))
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: settings)
        model.captions.makeCaptioner = { captioner }
        return model
    }

    func testCaptionsRideAlongAndAreSavedWithThePhoneTrack() async throws {
        let rig = RecorderRig()
        let captioner = ScriptedCaptioner(lines: [])
        let model = try makeModel(rig: rig, captioner: captioner)
        try await model.startRecording()
        try await waitUntil("listening") { model.captions.state == .listening }
        rig.pump(2)
        XCTAssertGreaterThan(captioner.buffersSeen, 0, "the recorder's input reaches the captioner")
        captioner.apply(text: "Budget agreed", start: 0.4, end: 1.5, isFinal: true)
        captioner.apply(text: "Next", start: 1.6, end: 1.8, isFinal: false)
        captioner.apply(text: "Next we", start: 1.6, end: 1.9, isFinal: false)
        try await waitUntil("shown") { model.captions.segments.map(\.text) == ["Budget agreed", "Next we"] }
        XCTAssertEqual(model.captions.segments.map(\.isTentative), [false, true])
        let id = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()

        let track = try XCTUnwrap(model.library.controller.meeting(id)?.tracks.first)
        let saved = try XCTUnwrap(model.captions.store.captions(for: id))
        XCTAssertEqual(saved.trackID, track.id, "filed with its recording by the time Stop returns")
        XCTAssertEqual(saved.segments.map(\.text), ["Budget agreed", "Next we"])
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false], "what stood at Stop is kept as heard")
        let file = try FileManager.default.attributesOfItem(atPath: model.captions.store.url(for: id).path)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600, "readable by this user only, as on the Mac")
        XCTAssertTrue(model.library.controller.meeting(id)?.showsLiveCaptions == true, "until a Mac's transcript arrives")
        XCTAssertFalse(saved.segments.isEmpty)
        XCTAssertFalse(model.captions.store.url(for: id).path.contains("/Meetings/"), "never inside what syncs")

        // Moving the conversation to the Trash removes them.
        _ = try await model.library.controller.moveToTrash(id)
        try await waitUntil("captions removed") { model.captions.store.captions(for: id) == nil }
    }

    func testATranscriptMadeAfterTheCaptionsReplacesThemOnThisIPhoneToo() async throws {
        let rig = RecorderRig()
        let captioner = ScriptedCaptioner(lines: [])
        let model = try makeModel(rig: rig, captioner: captioner)
        try await model.startRecording()
        try await waitUntil("listening") { model.captions.state == .listening }
        rig.pump(2)
        captioner.apply(text: "Heard live", start: 0.2, end: 1, isFinal: true)
        try await waitUntil("shown") { model.captions.segments.count == 1 }
        let id = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()
        let saved = try XCTUnwrap(model.captions.store.captions(for: id))
        var meeting = try XCTUnwrap(model.library.controller.meeting(id))
        XCTAssertEqual(SavedCaptions.shown(saved, for: meeting), saved, "until a transcript exists")

        // A transcript from before the captions (an earlier recording of the conversation) doesn't cover them.
        let track = try XCTUnwrap(meeting.tracks.first)
        meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [], createdAt: saved.createdAt.addingTimeInterval(-600))]
        XCTAssertNotNil(LiveCaptionStore.shown(saved, for: meeting), "the rule the Mac uses")
        await model.captions.store.prune(meetings: [meeting], keeping: nil)
        XCTAssertNotNil(model.captions.store.captions(for: id))

        // The Mac's transcript lands: the captions go from this iPhone, as they do from the Mac.
        meeting.transcripts.append(TrackTranscript(trackID: track.id, segments: [], createdAt: Date()))
        XCTAssertNil(LiveCaptionStore.shown(saved, for: meeting))
        model.captions.prune(meetings: [meeting], trashed: [])
        try await waitUntil("replaced captions removed") { model.captions.store.captions(for: id) == nil }
    }

    func testCaptionsOfARecordingNotFiledYetStayUntilItsConversationGoesToTheTrash() async throws {
        let model = try makeModel(rig: RecorderRig(), captioner: ScriptedCaptioner(lines: []))
        let store = model.captions.store
        // A recording the app was killed during saved its captions as it listened; its conversation joins
        // the library only when recovery files it (as one just stopped does when it's filed).
        let unfiled = UUID()
        try await store.save(LiveCaptions(meetingID: unfiled, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0, end: 1, text: "Said before the crash", isTentative: false)]))
        try await model.library.reload()

        // Meanwhile the library changes, which prunes: another conversation goes to the Trash with its captions.
        let other = Meeting(id: UUID(), title: "Standup")
        model.library.controller.add(other)
        try await store.save(LiveCaptions(meetingID: other.id, localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0, end: 1, text: "Trashed", isTentative: false)]))
        _ = try await model.library.controller.moveToTrash(other.id)
        try await waitUntil("the trashed conversation's captions removed") { store.captions(for: other.id) == nil }
        XCTAssertNotNil(store.captions(for: unfiled), "a recording not filed yet keeps its captions")

        // Filed, its captions stay with it, and go when it goes to the Trash.
        model.library.controller.add(Meeting(id: unfiled, title: "Recovered"))
        _ = try await model.library.controller.moveToTrash(unfiled)
        try await waitUntil("removed with its conversation") { store.captions(for: unfiled) == nil }
    }

    func testARecordingFiledWithCaptionsTheSpeakerModelMissedWaitsForItsSpeakersAtOnce() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig, captioner: SpeakerlessCaptioner())
        try await model.startRecording()
        try await waitUntil("heard") { model.captions.segments.count == 1 }
        rig.pump(2)
        let id = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()

        // Filing gives them their recording before it returns, so the speaker pass that starts after filing
        // finds them, with nothing else to set it off.
        XCTAssertEqual(model.captions.waitingForSpeakers().map(\.meetingID), [id])
        XCTAssertEqual(model.captions.waitingForSpeakers().first?.trackID, model.library.controller.meeting(id)?.tracks.first?.id)
    }

    func testAFailingCaptionerNeverStopsTheRecording() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig, captioner: FailingCaptioner())
        try await model.startRecording()
        try await waitUntil("failed") { model.captions.state == .failed("The recognizer stopped.") }
        rig.pump(3)
        XCTAssertEqual(model.recorder.state, .recording)
        try await model.stopRecording()
        let filed = try XCTUnwrap(model.library.conversations.first)
        XCTAssertEqual(filed.tracks.first?.duration ?? 0, 3, accuracy: 0.01)
        XCTAssertNil(model.notice)
    }

    func testCaptionsTheSpeakerModelMissedWaitForTheirRecordingThenKeepTheirLabels() async throws {
        let captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: try temporaryDirectory("captions")), makeCaptioner: { nil })
        func saved(track: UUID?, missed: Bool?, at date: Date) throws -> LiveCaptions {
            let value = LiveCaptions(meetingID: UUID(), trackID: track, localeIdentifier: "en_US", segments: [
                LiveCaptionSegment(start: 0, end: 2, text: "In a pocket", isTentative: false, needsSpeaker: missed)], createdAt: date)
            try captions.store.save(value)
            return value
        }
        let waiting = try saved(track: UUID(), missed: true, at: Date(timeIntervalSince1970: 100))
        let newer = try saved(track: UUID(), missed: true, at: Date(timeIntervalSince1970: 200))
        _ = try saved(track: nil, missed: true, at: Date())  // not filed yet: no recording to read
        _ = try saved(track: UUID(), missed: nil, at: Date())  // the live model heard it all
        XCTAssertEqual(captions.waitingForSpeakers().map(\.meetingID), [newer.meetingID, waiting.meetingID], "newest first")

        var labelled = waiting
        labelled.segments[0].speaker = LiveCaptionSpeaker(slot: "S1", name: "Priya")
        labelled.segments[0].needsSpeaker = nil
        labelled.updatedAt = Date()
        captions.saveLabelled(labelled)
        try await waitUntil("labelled") { captions.store.captions(for: waiting.meetingID)?.segments.first?.speaker?.name == "Priya" }
        try await waitUntil("an open page reads them again") { captions.lastSave == labelled.updatedAt }
        XCTAssertEqual(captions.waitingForSpeakers().map(\.meetingID), [newer.meetingID])

        // Captions that changed while the pass ran are left as they are.
        var stale = newer
        stale.segments = [LiveCaptionSegment(start: 0, end: 1, text: "Something else", isTentative: false)]
        captions.saveLabelled(stale)
        // Whatever the store does next comes after it: a save of something else, then a look.
        try await captions.store.save(LiveCaptions(meetingID: UUID(), localeIdentifier: "en_US"))
        XCTAssertEqual(captions.store.captions(for: newer.meetingID)?.segments.map(\.text), ["In a pocket"])
    }

    func testARecordersCaptionsJoinThePhonesAndGoToAMacOnlyOnceEach() async throws {
        let rig = RecorderRig()
        let captioner = ScriptedCaptioner(lines: [])
        let model = try makeModel(rig: rig, captioner: captioner)
        try await model.startRecording()
        try await waitUntil("listening") { model.captions.state == .listening }
        rig.pump(2)
        captioner.apply(text: "Heard on the phone.", start: 0.5, end: 1.5, isFinal: true)
        try await waitUntil("the phone's own line") { model.captions.segments.map(\.text) == ["Heard on the phone."] }
        model.recorder.updateLevels()  // as the meter does: the recording's start, from its first sample
        let start = try XCTUnwrap(model.recorder.startedAt)
        // The recorder began two seconds before this iPhone: its 4 s is this recording's 2 s.
        model.recorderCaptioned(.init(recorderID: "sim", name: "Soundcore", startedAt: start.addingTimeInterval(-2), segments: [
            LiveCaptionSegment(start: 4, end: 5, text: "Heard by the recorder.", isTentative: false),
            LiveCaptionSegment(start: 6, end: 7, text: "heard on the phone", isTentative: false)]))
        try await waitUntil("both") { model.captions.segments.count == 2 }
        XCTAssertEqual(model.captions.segments.map(\.text), ["Heard on the phone.", "Heard by the recorder."],
                       "the recorder's copy of what the phone heard is left out")
        XCTAssertEqual(model.captions.segments[1].start, 2, accuracy: 0.01)
        XCTAssertEqual(model.captions.segments.map { LiveCaptionLabels.speaker($0, names: model.captions.sourceNames) },
                       [nil, "Soundcore"], "a recorder's line says which recorder heard it")
        XCTAssertEqual(model.captions.segments.map { CaptionLine($0, names: model.captions.sourceNames).speaker }, [nil, "Soundcore"],
                       "as the strip draws it, on the Mac too")

        // What goes to a Mac recording it too: each line once, then only what changes.
        var share = CaptionShare()
        let first = share.changes(model.captions.segments, names: model.captions.sourceNames)
        XCTAssertEqual(first.map(\.text), ["Heard on the phone.", "Heard by the recorder."])
        XCTAssertEqual(first.map(\.device), [nil, "Soundcore"])
        XCTAssertTrue(share.changes(model.captions.segments, names: model.captions.sourceNames).isEmpty)
        var revised = model.captions.segments
        revised[0].text = "Heard on the phone, clearly."
        XCTAssertEqual(share.changes(revised, names: model.captions.sourceNames).map(\.text), ["Heard on the phone, clearly."])
        XCTAssertTrue(model.macsShowingCaptions(try XCTUnwrap(model.recorder.captureID)).isEmpty, "no Mac here to send them to")

        let id = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()
        let saved = try XCTUnwrap(model.captions.store.captions(for: id))
        XCTAssertEqual(saved.segments.count, 2)
        XCTAssertEqual(saved.sourceNames?[LiveCaptionSource.device("sim").rawValue], "Soundcore")
    }

    func testCaptionsOffMeansNoCaptioner() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig, captioner: ScriptedCaptioner(lines: []))
        model.settings.liveCaptions = false
        model.captions.makeCaptioner = PhoneAppModel.captioner(settings: model.settings, options: model.options)
        try await model.startRecording()
        XCTAssertNil(model.recorder.audioTap)
        XCTAssertFalse(model.captions.isShowing)
        rig.pump(1)
        try await model.stopRecording()
    }
}
