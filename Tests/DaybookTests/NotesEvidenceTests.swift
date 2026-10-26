import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import XCTest
@testable import Daybook

final class NotesEvidenceTests: XCTestCase {
    func testNotesAreContextWithExplicitKnownAndUnknownTiming() {
        let meeting = Meeting(notes: "Agenda\nPrivate reminder", timedNotes: [
            TimedNote(text: "Agenda"), TimedNote(time: 72, text: "Private reminder")])
        let evidence = MeetingEvidence.notes(meeting)
        XCTAssertTrue(evidence.contains("not a spoken quotation"))
        XCTAssertTrue(evidence.contains("written outside recording; time unknown"))
        XCTAssertTrue(evidence.contains("written at meeting time 01:12"))
        XCTAssertTrue(evidence.contains("not additional evidence"))
        XCTAssertEqual(MeetingEvidence.transcript(meeting), "")
    }

    func testUnalignedHighlightUsesOnlySourceLocalSpeechAndDeclaresProvenance() throws {
        let wearableID = UUID(), computerID = UUID()
        let wearableSpeech = TranscriptSegment(trackID: wearableID, start: 50, end: 55, text: "Wearable-only speech")
        let computerSpeech = TranscriptSegment(trackID: computerID, start: 50, end: 55, text: "Unrelated computer speech")
        let meeting = Meeting(tracks: [.init(id: wearableID, source: .soundcore, relativePath: "wearable.wav", fileName: "wearable.wav")],
            transcripts: [.init(trackID: wearableID, segments: [wearableSpeech])], unifiedTranscript: [computerSpeech],
            alignmentReports: [.init(trackID: wearableID, method: .unaligned)],
            highlights: [.init(trackID: wearableID, time: 52, text: "My annotation")])
        let evidence = try XCTUnwrap(MeetingEvidence.highlights(meeting))
        XCTAssertTrue(evidence.contains("wearable.wav"))
        XCTAssertTrue(evidence.contains("unaligned source-local timeline"))
        XCTAssertTrue(evidence.contains("do not imply overlap with other sources"))
        XCTAssertTrue(evidence.contains("User annotation: My annotation"))
        XCTAssertTrue(evidence.contains("Wearable-only speech"))
        XCTAssertFalse(evidence.contains("Unrelated computer speech"))
    }

    func testAlignedHighlightIncludesContextBeforeAndAfterNotDistantSpeech() throws {
        let trackID = UUID()
        let meeting = Meeting(unifiedTranscript: [
            .init(trackID: trackID, start: 65, end: 70, text: "Lead-in"),
            .init(trackID: trackID, start: 120, end: 125, text: "Explanation after the mark"),
            .init(trackID: trackID, start: 200, end: 205, text: "Distant topic")],
            alignmentReports: [.init(trackID: trackID, method: .anchors, offset: 10)],
            highlights: [.init(trackID: trackID, time: 80, text: "Pay attention")])
        let evidence = try XCTUnwrap(MeetingEvidence.highlights(meeting))
        XCTAssertTrue(evidence.contains("MARKED MOMENT [01:30]"))
        XCTAssertTrue(evidence.contains("meeting timeline"))
        XCTAssertTrue(evidence.contains("Lead-in"))
        XCTAssertTrue(evidence.contains("Explanation after the mark"))
        XCTAssertFalse(evidence.contains("Distant topic"))
    }

    func testHighlightWithoutRecordedSpeechDoesNotTurnAnnotationIntoSpeech() throws {
        let meeting = Meeting(highlights: [.init(time: 30, text: "Check this assertion")])
        let evidence = try XCTUnwrap(MeetingEvidence.highlights(meeting))
        XCTAssertTrue(evidence.contains("User annotation: Check this assertion"))
        XCTAssertTrue(evidence.contains("No transcribed speech is available"))
        XCTAssertTrue(evidence.contains("Do not invent details"))
        XCTAssertEqual(MeetingEvidence.transcript(meeting), "")
    }

    func testTimelineInterleavesTimedNotesButExcludesUnknownTimesAndUnalignedMarkers() {
        let trackID = UUID()
        let timed = TimedNote(time: 20, text: "Written during recording")
        let untimed = TimedNote(text: "Before recording")
        let meeting = Meeting(unifiedTranscript: [.init(trackID: trackID, start: 10, end: 12, text: "Speech")],
            highlights: [.init(time: 30), .init(trackID: UUID(), time: 40)], timedNotes: [untimed, timed])
        let items = MeetingTimelineItem.items(in: meeting)
        XCTAssertEqual(items.map(\.time), [10, 20, 30])
        XCTAssertTrue(items.contains { $0.id == "note:\(timed.id)" })
        XCTAssertFalse(items.contains { $0.id == "note:\(untimed.id)" })
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
    }

    func testTranscriptKeepsUnknownSpeakerRatherThanInventingSourceSpeaker() {
        let meeting = Meeting(unifiedTranscript: [.init(trackID: UUID(), start: 2, end: 3, text: "Hello")])
        XCTAssertEqual(MeetingEvidence.transcript(meeting), "[00:02] Unknown speaker: Hello")
        XCTAssertNil(MeetingEvidence.highlights(meeting))
    }

    func testPlaybackMapsExactTimelinePointThroughOffsetAndClockDrift() throws {
        let track = RecordingTrack(relativePath: "wearable.wav", fileName: "wearable.wav", duration: 200)
        let meeting = Meeting(tracks: [track], unifiedTranscript: [
            .init(trackID: track.id, start: 10, end: 12, text: "Earlier speech"),
            .init(trackID: track.id, start: 90, end: 95, text: "Later speech")],
            alignmentReports: [.init(trackID: track.id, method: .anchors, offset: 10, rate: 1.02)])
        let position = try XCTUnwrap(MeetingPlaybackPosition.resolve(61, in: meeting))
        XCTAssertEqual(position.trackID, track.id)
        XCTAssertEqual(position.seconds, 50, accuracy: 0.000_001)
    }

    func testPlaybackSkipsUnalignedAndOutOfRangeSources() throws {
        let unknown = RecordingTrack(relativePath: "unknown.wav", fileName: "unknown.wav", duration: 100, offset: 0)
        let late = RecordingTrack(relativePath: "late.wav", fileName: "late.wav", duration: 100, offset: 50)
        let short = RecordingTrack(relativePath: "short.wav", fileName: "short.wav", duration: 5, offset: 0)
        let available = RecordingTrack(relativePath: "available.wav", fileName: "available.wav", duration: 100, offset: -20)
        let meeting = Meeting(tracks: [unknown, late, short, available],
            alignmentReports: [.init(trackID: unknown.id, method: .unaligned)])
        let position = try XCTUnwrap(MeetingPlaybackPosition.resolve(10, in: meeting))
        XCTAssertEqual(position.trackID, available.id)
        XCTAssertEqual(position.seconds, 30)
    }

    func testPlaybackRejectsUnknownAlignmentAndInvalidTimelineTimes() {
        let track = RecordingTrack(relativePath: "audio.wav", fileName: "audio.wav")
        XCTAssertNil(MeetingPlaybackPosition.resolve(10, in: Meeting(tracks: [track])))
        let invalid = Meeting(tracks: [track], alignmentReports: [.init(trackID: track.id, method: .anchors, rate: 0)])
        XCTAssertNil(MeetingPlaybackPosition.resolve(10, in: invalid))
        XCTAssertNil(MeetingPlaybackPosition.resolve(.nan, in: invalid))
        XCTAssertNil(MeetingPlaybackPosition.resolve(.infinity, in: invalid))
    }

    func testPlaybackSupportsEarlierWearableTimelineAndExactFileBoundary() throws {
        let track = RecordingTrack(relativePath: "audio.wav", fileName: "audio.wav", duration: 100, offset: -20)
        let meeting = Meeting(tracks: [track])
        XCTAssertEqual(try XCTUnwrap(MeetingPlaybackPosition.resolve(-10, in: meeting)).seconds, 10)
        XCTAssertEqual(try XCTUnwrap(MeetingPlaybackPosition.resolve(80, in: meeting)).seconds, 100)
        XCTAssertNil(MeetingPlaybackPosition.resolve(80.01, in: meeting))
        XCTAssertNil(MeetingPlaybackPosition.resolve(-21, in: meeting))
    }
}

@MainActor
final class NotesPersistenceTests: XCTestCase {
    func testInactiveCaptureDoesNotInventZeroMarkerAndReviewKeepsSourceTime() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanup(root, defaults) }
        let id = state.newMeeting()
        state.addHighlight(id)
        XCTAssertTrue(state.meetings.first?.highlights.isEmpty == true)
        let track = RecordingTrack(relativePath: "review.wav", fileName: "review.wav", duration: 100, offset: 10)
        state.update(id) { $0.tracks = [track] }
        state.addPlaybackHighlight(id, trackID: track.id, seconds: 12.5)
        state.addPlaybackHighlight(id, trackID: UUID(), seconds: 12.5)
        state.addPlaybackHighlight(id, trackID: track.id, seconds: .nan)
        state.addPlaybackHighlight(id, trackID: track.id, seconds: -1)
        await state.flush()
        let highlights = try XCTUnwrap(state.meetings.first?.highlights)
        XCTAssertEqual(highlights.count, 1)
        XCTAssertEqual(highlights.first?.trackID, track.id)
        XCTAssertEqual(highlights.first?.time, 12.5)
    }

    func testLegacyAndPostMeetingNotesStayUntimedAcrossEditsAndRestart() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanup(root, defaults) }
        let id = state.newMeeting()
        state.update(id) { $0.notes = "Legacy agenda"; $0.timedNotes = nil }
        state.editNotes(id, text: "Legacy agenda revised\nReflection after meeting")
        await state.flush()
        let original = try XCTUnwrap(state.meetings.first?.timedNotes)
        XCTAssertEqual(original.count, 2)
        XCTAssertTrue(original.allSatisfy { $0.time == nil })
        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        XCTAssertEqual(restarted.meetings.first?.timedNotes, original)
        XCTAssertTrue(restarted.meetings.first?.revisions.contains { $0.field == "notes" } == true)
    }

    func testSavedCaptureAnchorsSurvivePostMeetingEditAndNewParagraph() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanup(root, defaults) }
        let id = state.newMeeting()
        // A persisted capture fixture exercises the edit/restart path without opening an audio device.
        let captured = TimedNote(time: 42.375, text: "Decision")
        state.update(id) { $0.notes = "Decision"; $0.timedNotes = [captured] }
        state.editNotes(id, text: "Decision clarified\nAfterward")
        await state.flush()
        let store = try MeetingStore(rootURL: root)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.timedNotes?.first?.id, captured.id)
        XCTAssertEqual(saved.timedNotes?.map(\.time), [42.375, nil])
        XCTAssertEqual(saved.timedNotes?.map(\.text), ["Decision clarified", "Afterward"])
        XCTAssertNil(state.recordingID)
        XCTAssertEqual(state.recorder.elapsedTime, 0)
    }

    private func makeState() async throws -> (AppState, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookNotesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.errorMessage)
        return (state, root, defaults)
    }

    private func cleanup(_ root: URL, _ defaults: UserDefaults) {
        try? FileManager.default.removeItem(at: root)
    }
}
