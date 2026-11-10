import AVFoundation
import DaybookKit
import DaybookUI
import Foundation
import Observation
import XCTest
@testable import DaybookPhone

/// The player stands aside for the recorder, which owns the audio session, and the Lock Screen never shows who a
/// conversation was with, or a Personal one by its name. Silent synthetic audio, played muted; nothing is recorded.
@MainActor
final class PlaybackControllerTests: XCTestCase {
    /// The recorder's state, as the app model has it.
    @Observable final class Recorder { var isActive = false }

    /// A recording that's already on this iPhone.
    private struct Here: AudioProviding {
        let url: URL
        @MainActor func availability(of track: RecordingTrack, in meetingID: UUID) async -> AudioAvailability { .local }
        @MainActor func localAudio(for track: RecordingTrack, in meetingID: UUID, progress: @escaping @Sendable (Double) -> Void) async throws -> URL { url }
    }

    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
        super.tearDown()
    }

    private func silence(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackController-\(UUID().uuidString).wav")
        files.append(url)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testBehaviorTheLockScreenNeverSaysWhoWasThereOrNamesAPersonalConversation() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var meeting = Meeting(title: "Offer conversation with Dana", date: date)
        meeting.speakers = [Speaker(id: "a", name: "Dana"), Speaker(id: "b", name: "Alex")]
        let work = PlaybackController.nowPlaying(meeting)
        XCTAssertEqual(work.title, "Offer conversation with Dana")
        XCTAssertEqual(work.subtitle, date.formatted(date: .abbreviated, time: .shortened), "when it was, never who was there")

        meeting.placement = .personal
        XCTAssertEqual(PlaybackController.nowPlaying(meeting).title, "Daybook conversation", "anyone holding the phone sees it")
        XCTAssertEqual(PlaybackController.nowPlaying(Meeting(title: "", date: date)).title, "Untitled Conversation")
    }

    func testBehaviorARecordingStopsPlaybackAndNothingPlaysUntilItEnds() async throws {
        let url = try silence(seconds: 3)
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.wav", fileName: "a.wav", duration: 3)
        let meeting = Meeting(title: "Weekly product sync", tracks: [track])
        let recorder = Recorder()
        let player = PlaybackController()
        player.muted = true
        player.follow { recorder.isActive }
        defer { player.close() }

        player.play(.source(track, 0), in: meeting, provider: Here(url: url))
        await waitUntil { player.phase == .ready }
        XCTAssertEqual(player.phase, .ready)
        guard player.isPlaying else { throw XCTSkip("No audio output to play to") }

        // A recording starts from anywhere (the Lock Screen, a Shortcut, a Mac): the player stands aside by itself.
        recorder.isActive = true
        await waitUntil { !player.isPlaying }
        XCTAssertFalse(player.isPlaying)

        // A Lock Screen or AirPods press, or the page's Play, can't take the session from the recorder.
        player.resume()
        XCTAssertFalse(player.isPlaying)
        player.toggle()
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isActive(for: meeting.id), "the conversation stays open in its player")

        recorder.isActive = false
        player.resume()
        XCTAssertTrue(player.isPlaying, "once the recording is filed, it plays again")
    }

    func testBehaviorAConversationWithoutARecordingSaysSo() {
        let player = PlaybackController()
        let meeting = Meeting(title: "Notes")
        player.play(.timeline(0), in: meeting, provider: Here(url: URL(fileURLWithPath: "/dev/null")))
        XCTAssertEqual(player.phase, .unavailable("This conversation has no recording to play."))
        XCTAssertTrue(player.isActive(for: meeting.id))
        player.close()
        XCTAssertEqual(player.phase, .idle)
    }

    func testBehaviorAPageSheetClosesOnAFirmSwipeDown() {
        XCTAssertFalse(PageSheetDrag.closes(translation: 40, predicted: 80))
        XCTAssertTrue(PageSheetDrag.closes(translation: 130, predicted: 130))
        XCTAssertTrue(PageSheetDrag.closes(translation: 60, predicted: 300), "a flick")
        XCTAssertEqual(PageSheetDrag.dimming(0), 1)
        XCTAssertEqual(PageSheetDrag.dimming(120), 0.5)
        XCTAssertEqual(PageSheetDrag.dimming(400), 0)
    }

    func testBehaviorTheMoreMenuListsWhatCanBeDoneNowInTheMacsOrder() {
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60)
        var meeting = Meeting(title: "Weekly product sync", tracks: [track])
        meeting.summary = MeetingSummary(overview: "Shipping")
        let groups = ConversationActionMenuItems.shown(PhoneActions.groups(for: meeting), on: .iPhone)
        let titles = groups.flatMap { $0.actions.map(\.title) }
        XCTAssertEqual(groups.first?.actions.map(\.title), ["Copy Summary", "Share"])
        XCTAssertTrue(titles.contains("Add Recording…"))
        XCTAssertFalse(titles.contains("Version History…"), "no changes yet: left out, as an iPhone's menus do")
        XCTAssertEqual(titles.last, "Move to Trash…")
    }
}
