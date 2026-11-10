import DaybookCaptions
import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// Saved live captions as both apps read them (`SavedCaptions`): each line replaced once the recording that
/// heard it is transcribed (or, for the device's own, a transcript covers its time), each recording's kept and
/// read together, each playing its own recording.
final class SavedCaptionsTests: XCTestCase {
    private let began = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SavedCaptionsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ text: String, _ start: TimeInterval) -> LiveCaptionSegment {
        LiveCaptionSegment(start: start, end: start + 3, text: text, isTentative: false)
    }

    private func track(_ name: String, startedAt: Date, duration: TimeInterval, phone: Bool = false) -> RecordingTrack {
        RecordingTrack(source: .microphone, relativePath: name, fileName: name, createdAt: startedAt.addingTimeInterval(duration + 60),
                       duration: duration, device: phone ? DeviceRecordingIdentity(kind: "daybook.iphone", serial: "i", recordingID: name) : nil,
                       startedAt: startedAt)
    }

    /// An iPhone began half an hour before a Mac joined. The Mac's transcript lands first: it covers the second
    /// half, so the iPhone keeps (and shows) its first half's captions until its own recording is transcribed.
    func testBehaviorAPhoneThatStartedThirtyMinutesFirstKeepsItsFirstHalfAfterTheMacsTranscriptLands() async throws {
        let phoneTrack = track("phone", startedAt: began, duration: 3_600, phone: true)
        let macTrack = track("mac", startedAt: began.addingTimeInterval(1_800), duration: 1_800)
        var meeting = Meeting(title: "Planning", date: began)
        meeting.tracks = [phoneTrack, macTrack]
        let captions = LiveCaptions(meetingID: meeting.id, captureID: UUID(), trackID: phoneTrack.id, localeIdentifier: "en_US",
                                    segments: [line("Before the Mac joined", 300), line("After the Mac joined", 2_400)],
                                    createdAt: began, startedAt: began)
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting), captions, "nothing transcribed yet")

        meeting.transcripts = [TrackTranscript(trackID: macTrack.id, segments: [], createdAt: began.addingTimeInterval(3_900))]
        meeting.unifiedTranscript = [TranscriptSegment(trackID: macTrack.id, start: 1_800, end: 1_805, text: "After the Mac joined.")]
        XCTAssertEqual(SavedCaptions.shown(captions, for: meeting)?.segments.map(\.text), ["Before the Mac joined"])
        XCTAssertFalse(SavedCaptions.standsIn(for: meeting), "after the transcript, for the half it doesn't cover")
        let store = LiveCaptionStore(libraryRoot: root)
        try await store.save(captions)
        await store.prune(meetings: [meeting], keeping: nil)
        XCTAssertNotNil(store.captions(for: meeting.id), "kept: the first half is still to read")

        meeting.transcripts.append(TrackTranscript(trackID: phoneTrack.id, segments: [], createdAt: began.addingTimeInterval(4_000)))
        XCTAssertNil(SavedCaptions.shown(captions, for: meeting))
        await store.prune(meetings: [meeting], keeping: nil)
        XCTAssertNil(store.captions(for: meeting.id), "every line replaced: gone")
    }

    /// Two recordings into one conversation: each keeps its captions, they read together (the first's first), each
    /// line plays its own recording, and the first's go once its own transcript lands.
    func testBehaviorEachRecordingsCaptionsReadTogetherAndPlayTheirOwnRecording() async throws {
        let first = track("first", startedAt: began, duration: 600)
        let second = track("second", startedAt: began.addingTimeInterval(3_600), duration: 600)
        var meeting = Meeting(title: "Planning", date: began)
        meeting.tracks = [first, second]
        let earlier = LiveCaptions(meetingID: meeting.id, captureID: UUID(), localeIdentifier: "en_US", segments: [line("First recording", 10)],
                                   createdAt: began, startedAt: began)
        let later = LiveCaptions(meetingID: meeting.id, captureID: UUID(), localeIdentifier: "en_US", segments: [line("Recorded into again", 10)],
                                 createdAt: began.addingTimeInterval(3_600), startedAt: began.addingTimeInterval(3_600))
        let store = LiveCaptionStore(libraryRoot: root)
        try await store.save(later)
        try await store.save(earlier)
        let read = await SavedCaptions.read(for: meeting, from: store)
        let shown = try XCTUnwrap(read)
        XCTAssertEqual(shown.segments.map(\.text), ["First recording", "Recorded into again"])
        XCTAssertEqual(SavedCaptions.playback(shown.segments[0], captions: shown, in: meeting), .source(first, 10))
        XCTAssertEqual(SavedCaptions.playback(shown.segments[1], captions: shown, in: meeting), .source(second, 10))
        XCTAssertEqual(SavedCaptions.playing(at: 11, trackID: second.id, captions: shown, in: meeting), shown.segments[1].id)
        XCTAssertEqual(SavedCaptions.playing(at: 11, trackID: first.id, captions: shown, in: meeting), shown.segments[0].id)
        XCTAssertEqual(SavedCaptions.hits(in: [meeting], query: "again", store: store).map(\.segment.text), ["Recorded into again"])

        meeting.transcripts = [TrackTranscript(trackID: first.id, segments: [], createdAt: began.addingTimeInterval(700))]
        let after = await SavedCaptions.read(for: meeting, from: store)
        XCTAssertEqual(after?.segments.map(\.text), ["Recorded into again"])
        await store.prune(meetings: [meeting], keeping: nil)
        XCTAssertEqual(store.captures(of: meeting.id).map(\.captureID), [later.captureID], "only the replaced recording's go")
    }

    /// The prune trigger reads transcripts only; the rule reads each recording, and a recording made from another
    /// (the microphone with the call's echo removed) counts as its original.
    func testBehaviorTheRuleReadsEachRecordingAndItsDerivedTrack() {
        var meeting = Meeting(title: "Planning", date: began)
        let original = track("mic", startedAt: began, duration: 600)
        var cleaned = track("mic-clean", startedAt: began, duration: 600)
        cleaned.derivedFrom = original.id
        meeting.tracks = [original, cleaned]
        meeting.transcripts = [TrackTranscript(trackID: cleaned.id, segments: [], createdAt: began.addingTimeInterval(700))]
        let coverage = LiveCaptionCoverage(meeting)
        XCTAssertEqual(coverage.recordings.map(\.trackID), [original.id], "one recording, transcribed through the one made from it")
        XCTAssertNotNil(coverage.recordings.first?.transcribedAt)
        XCTAssertTrue(coverage.otherTranscripts.isEmpty)
    }
}
