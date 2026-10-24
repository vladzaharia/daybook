import AVFoundation
import DaybookCaptions
import DaybookKit
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

    private func makeModel(rig: RecorderRig, captioner: any LiveCaptioning) throws -> PhoneAppModel {
        let library = try PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
        let settings = PhoneSettings(defaults: UserDefaults(suiteName: "LiveCaptionsTests-\(UUID().uuidString)")!)
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

        let saved = try XCTUnwrap(model.captions.store.captions(for: id))
        XCTAssertEqual(saved.segments.map(\.text), ["Budget agreed", "Next we"])
        XCTAssertEqual(saved.segments.map(\.isTentative), [false, false], "what stood at Stop is kept as heard")
        let track = try XCTUnwrap(model.library.controller.meeting(id)?.tracks.first)
        XCTAssertEqual(saved.trackID, track.id)
        XCTAssertTrue(model.library.controller.meeting(id)?.showsLiveCaptions == true, "until a Mac's transcript arrives")
        XCTAssertFalse(saved.segments.isEmpty)
        XCTAssertFalse(model.captions.store.url(for: id).path.contains("/Meetings/"), "never inside what syncs")

        // Moving the conversation to the Trash removes them.
        _ = try await model.library.controller.moveToTrash(id)
        try await waitUntil("captions removed") { model.captions.store.captions(for: id) == nil }
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
