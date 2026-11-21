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

    /// Two devices each move a passage before they sync: the merged copy keeps one device's transcript, and both moves.
    func testBehaviorMovesMadeOnTwoDevicesAtOnceBothShowOnceTheyMerge() {
        let base = conversation()
        var phone = base, mac = base
        phone.giveSpeaker("S2", toPassages: [base.unifiedTranscript[0].id], at: Date(timeIntervalSince1970: 10))
        mac.giveSpeaker("S1", toPassages: [base.unifiedTranscript[2].id], at: Date(timeIntervalSince1970: 11))
        for (local, remote) in [(phone, mac), (mac, phone)] {
            let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
            XCTAssertEqual(merged.unifiedTranscript.map(\.speakerID), ["S2", "S1", "S1"])
            XCTAssertEqual(merged.passageSpeakers.count, 2)
        }
    }

    /// Entries of one instant read in the order of their IDs, never in the order a device happens to hold them, so every
    /// device agrees which is the latest.
    func testBehaviorEntriesOfOneInstantReadTheSameOnEveryDevice() throws {
        var meeting = conversation()
        let id = meeting.unifiedTranscript[1].id
        let instant = Date(timeIntervalSince1970: 20)
        let a = MeetingRevision(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")), date: instant,
                                kind: .segmentSpeaker(id), oldValue: "S1", newValue: "S2")
        let b = MeetingRevision(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000B")), date: instant,
                                kind: .segmentSpeaker(id), oldValue: "S1", newValue: "S3")
        meeting.revisions = [a, b]
        XCTAssertEqual(meeting.passageSpeakers[id], "S3")
        meeting.revisions = [b, a]
        XCTAssertEqual(meeting.passageSpeakers[id], "S3")
    }

    /// The new transcript's passage that is the moved one keeps its ID, so processing again after that, Version History,
    /// and a later move all find it, even once the run it was first heard in is gone.
    func testBehaviorAMoveSurvivesASecondProcessingAgain() {
        var meeting = conversation()
        let moved = meeting.unifiedTranscript[1]
        meeting.giveSpeaker("S2", toPassages: [moved.id])
        func rerun(_ at: TimeInterval) {
            let run = meeting.unifiedTranscript.map {
                TranscriptSegment(trackID: track, start: $0.start + 0.05, end: $0.end + 0.05, text: $0.text, speakerID: "S1")
            }
            meeting.transcripts.append(TrackTranscript(trackID: track, segments: run, createdAt: Date(timeIntervalSince1970: at)))
            meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        }
        rerun(2)
        XCTAssertEqual(meeting.unifiedTranscript[1].id, moved.id, "the moved passage keeps its identity")
        meeting.transcripts.removeFirst()
        rerun(3)
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(meeting.unifiedTranscript[1].id, moved.id)
        XCTAssertNil(meeting.correctionTransferIssues)
    }

    /// A move the new transcript has no one passage for (two moved passages heard as one, a passage split in two) isn't
    /// guessed onto one: it's up for review, as a correction is, and Review gives the passage chosen that speaker.
    func testBehaviorAMoveTheNewTranscriptCantPlaceIsUpForReviewNotGuessed() throws {
        var meeting = conversation()
        let (first, second, third) = (meeting.unifiedTranscript[0], meeting.unifiedTranscript[1], meeting.unifiedTranscript[2])
        let priya = try XCTUnwrap(meeting.speaker(named: "Priya"))
        meeting.giveSpeaker("S2", toPassages: [first.id])
        meeting.giveSpeaker(priya, toPassages: [second.id])
        meeting.giveSpeaker("S1", toPassages: [third.id])
        let rerun = [
            TranscriptSegment(trackID: track, start: 0, end: 9, text: "Shall we start with the budget Yes the numbers are in", speakerID: "S1"),
            TranscriptSegment(trackID: track, start: 10, end: 12, text: "Good then", speakerID: "S2"),
            TranscriptSegment(trackID: track, start: 12, end: 14, text: "the offsite", speakerID: "S2"),
        ]
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: rerun, createdAt: Date(timeIntervalSince1970: 2)))
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["S1", "S2", "S2"], "the new transcript's reading, nothing guessed")
        let issues = try XCTUnwrap(meeting.correctionTransferIssues)
        XCTAssertEqual(Set(issues.map(\.id)), [first.id, second.id, third.id])
        XCTAssertEqual(Set(issues.compactMap(\.speakerID)), ["S2", priya, "S1"])
        XCTAssertFalse(issues.contains { meeting.correctsWords($0) }, "none of them is a correction of the words")

        // Review: the passage picked gets the speaker, and keeps the new transcript's words.
        let target = meeting.unifiedTranscript[0]
        XCTAssertTrue(meeting.resolveCorrectionTransfer(id: second.id, targetSegmentID: target.id))
        XCTAssertEqual(meeting.unifiedTranscript[0].speakerID, priya)
        XCTAssertEqual(meeting.unifiedTranscript[0].text, target.text)
        // Processed again, the reviewed one isn't asked about again, and the passage it went to keeps it.
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(Set((meeting.correctionTransferIssues ?? []).map(\.id)), [first.id, third.id])
        XCTAssertEqual(meeting.unifiedTranscript[0].speakerID, priya)
    }

    /// Each run of speaker detection names its speakers after itself ("<run>:S1"), so a run that finds speakers again
    /// never reuses an ID for someone else: a moved passage keeps the speaker the person chose, not the new run's S2.
    func testBehaviorFindingSpeakersAgainNeverHandsAMovedPassageToTheNewRunsNamesake() {
        let segments = [
            TranscriptSegment(trackID: track, start: 0, end: 4, text: "Shall we start with the budget", speakerID: "run1:S1"),
            TranscriptSegment(trackID: track, start: 5, end: 9, text: "Yes the numbers are in", speakerID: "run1:S1"),
            TranscriptSegment(trackID: track, start: 10, end: 14, text: "Good then the offsite", speakerID: "run1:S2"),
        ]
        var meeting = Meeting(transcripts: [TrackTranscript(trackID: track, segments: segments, createdAt: Date(timeIntervalSince1970: 1))],
                              speakers: [Speaker(id: "run1:S1", name: "Speaker 1"), Speaker(id: "run1:S2", name: "Speaker 2")])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        meeting.giveSpeaker("run1:S2", toPassages: [meeting.unifiedTranscript[1].id])
        // The second run hears the people in another order: its S2 is the one the first run called S1.
        let again = zip(meeting.unifiedTranscript, ["run2:S2", "run2:S2", "run2:S1"]).map { passage, label in
            TranscriptSegment(trackID: track, start: passage.start, end: passage.end, text: passage.text, speakerID: label)
        }
        meeting.speakers += [Speaker(id: "run2:S1", name: "Speaker 3"), Speaker(id: "run2:S2", name: "Speaker 4")]
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: again, createdAt: Date(timeIntervalSince1970: 2)))
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript.map(\.speakerID), ["run2:S2", "run1:S2", "run2:S1"])
    }
}
