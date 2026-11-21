import XCTest
@testable import DaybookCore

/// Giving a passage to another speaker: recorded in Version History, undone from it, carried over to a new transcript,
/// synced like any edit, and never a change to a speaker's voice.
final class PassageSpeakerTests: XCTestCase {
    private let track = UUID()

    /// Two people the speaker model heard as one ("S1") and the other it found ("S2"), over three passages.
    private func conversation() -> Meeting {
        let segments = [
            TranscriptSegment(trackID: track, start: 0, end: 4, text: "Shall we start with the budget", speakerID: "S1"),
            TranscriptSegment(trackID: track, start: 5, end: 9, text: "Yes the numbers are in", speakerID: "S1"),
            TranscriptSegment(trackID: track, start: 10, end: 14, text: "Good then the offsite", speakerID: "S2"),
        ]
        var meeting = Meeting(transcripts: [TrackTranscript(trackID: track, segments: segments, createdAt: Date(timeIntervalSince1970: 1))],
                              speakers: [Speaker(id: "S1", name: "Speaker 1", embedding: [1, 0]), Speaker(id: "S2", name: "Speaker 2", embedding: [0, 1])])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        return meeting
    }

    func testBehaviorGivingPassagesToASpeakerMovesOnlyThemAndRecordsEach() {
        var meeting = conversation()
        let second = meeting.unifiedTranscript[1]
        XCTAssertTrue(meeting.giveSpeaker("S2", toPassages: [second.id]))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["S1", "S2", "S2"])
        let entry = try! XCTUnwrap(meeting.revisions.last)
        XCTAssertEqual(entry.kind, .segmentSpeaker(second.id))
        XCTAssertEqual(entry.oldValue, "S1")
        XCTAssertEqual(entry.newValue, "S2")
        XCTAssertTrue(entry.kind.isPersonsEdit)
        XCTAssertEqual(meeting.passageSpeakers, [second.id: "S2"])
    }

    func testBehaviorSeveralConsecutivePassagesMoveTogetherAndSameOrUnknownSpeakersChangeNothing() {
        var meeting = conversation()
        let ids = meeting.unifiedTranscript.prefix(2).map(\.id)
        XCTAssertTrue(meeting.giveSpeaker("S2", toPassages: ids))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["S2", "S2", "S2"])
        XCTAssertEqual(meeting.revisions.count, 2)
        let before = meeting
        XCTAssertFalse(meeting.giveSpeaker("S2", toPassages: ids), "already theirs")
        XCTAssertFalse(meeting.giveSpeaker("nobody", toPassages: ids), "not a speaker here")
        XCTAssertEqual(meeting, before)
    }

    func testBehaviorANewSpeakerIsNamedLikeARenameAndAnExistingNameIsReused() {
        var meeting = conversation()
        let priya = try! XCTUnwrap(meeting.speaker(named: "  Priya "))
        XCTAssertEqual(meeting.speakerName(priya), "Priya")
        XCTAssertNil(meeting.speakers.first { $0.id == priya }?.embedding, "no voice to learn from")
        XCTAssertTrue(meeting.revisions.contains { $0.kind == .speaker(priya) && $0.newValue == "Priya" })
        XCTAssertEqual(meeting.speaker(named: "priya"), priya)
        XCTAssertEqual(meeting.speaker(named: "Speaker 2"), "S2")
        XCTAssertNil(meeting.speaker(named: "   "))
        XCTAssertEqual(meeting.speakers.count, 3)
        let voices = meeting.speakers.compactMap(\.embedding)
        XCTAssertTrue(meeting.giveSpeaker(priya, toPassages: [meeting.unifiedTranscript[0].id]))
        XCTAssertEqual(meeting.speakers.compactMap(\.embedding), voices, "moving a passage never touches a voice")
    }

    func testBehaviorUndoingFromVersionHistoryGivesThePassageBackAndTheTranscriptsOwnReadingStands() {
        var meeting = conversation()
        let id = meeting.unifiedTranscript[1].id
        meeting.giveSpeaker("S2", toPassages: [id])
        let entry = try! XCTUnwrap(meeting.revisions.last)
        XCTAssertEqual(meeting.passageSpeakers[id], "S2")
        // Version History's Restore, and the undo the library writes (the entry reversed).
        meeting.giveSpeaker(entry.oldValue, toPassages: [id], at: entry.date.addingTimeInterval(1))
        XCTAssertEqual(meeting.unifiedTranscript[1].speakerID, "S1")
        XCTAssertNil(meeting.passageSpeakers[id], "back to what the transcript said: not pinned")
    }

    func testBehaviorAMoveSurvivesProcessingAgainEvenWhenTheNewRunHasNewPassages() {
        var meeting = conversation()
        let moved = meeting.unifiedTranscript[1]
        meeting.giveSpeaker("S2", toPassages: [moved.id])
        // Identify Speakers Again or a new run: every passage new, the same recording's time.
        let rerun = meeting.unifiedTranscript.map {
            TranscriptSegment(trackID: track, start: $0.start + 0.05, end: $0.end + 0.05, text: $0.text, speakerID: "S1")
        }
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: rerun, createdAt: Date(timeIntervalSince1970: 2)))
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Shall we start with the budget", "Yes the numbers are in", "Good then the offsite"])
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["S1", "S2", "S1"], "only the moved passage keeps the person's choice")
    }

    func testBehaviorAMoveToAnotherPersonsSpeakerKeepsItsPassageThroughTheSameFusionToo() {
        var meeting = conversation()
        let priya = try! XCTUnwrap(meeting.speaker(named: "Priya"))
        meeting.giveSpeaker(priya, toPassages: [meeting.unifiedTranscript[0].id])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript[0].speakerID, priya)
        XCTAssertEqual(meeting.speakers.filter { $0.id == priya }.count, 1)
    }

    func testBehaviorTheMoveAndItsNewSpeakerSyncLikeAnyEdit() {
        let base = conversation()
        var phone = base
        let priya = try! XCTUnwrap(phone.speaker(named: "Priya"))
        phone.giveSpeaker(priya, toPassages: [phone.unifiedTranscript[1].id])
        let mac = base
        for (local, remote) in [(phone, mac), (mac, phone)] {
            let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
            XCTAssertEqual(merged.unifiedTranscript[1].speakerID, priya)
            XCTAssertTrue(merged.speakers.contains { $0.id == priya && $0.name == "Priya" })
            XCTAssertEqual(merged.passageSpeakers, phone.passageSpeakers)
            XCTAssertTrue(merged.revisions.contains { $0.kind == .segmentSpeaker(phone.unifiedTranscript[1].id) })
        }
    }

    func testBehaviorTheEntryIsWrittenAsBeforeAndReadsBackAsItself() {
        let id = UUID()
        XCTAssertEqual(RevisionField.segmentSpeaker(id).rawValue, "segment-speaker:\(id.uuidString)")
        XCTAssertEqual(RevisionField(rawValue: "segment-speaker:\(id.uuidString)"), .segmentSpeaker(id))
        XCTAssertEqual(RevisionField(rawValue: "segment-speaker:nope"), .unknown("segment-speaker:nope"))
    }
}
