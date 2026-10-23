import XCTest
@testable import DaybookCore

final class ReprocessingTests: XCTestCase {
    let track = UUID()
    let words = "We should ask Jordan to review the calendar migration tomorrow"
    func original() -> Meeting {
        let raw = TranscriptSegment(trackID: track, start: 10, end: 14, text: words)
        var meeting = Meeting(transcripts: [TrackTranscript(trackID: track, segments: [raw], createdAt: Date(timeIntervalSince1970: 1))])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        meeting.correctSegment(id: raw.id, text: "We should ask Jorden to review the calendar migration tomorrow")
        return meeting
    }
    func rerun(_ meeting: inout Meeting, segments: [TranscriptSegment], time: Double = 2) -> [CorrectionTransferIssue] {
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: segments, createdAt: Date(timeIntervalSince1970: time)))
        return meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
    }
    func testCorrectionTransfersToNewIDsUsingSourceTimesDespiteTimelineOffset() {
        var meeting = original()
        let editedID = meeting.unifiedTranscript[0].id
        meeting.tracks = [RecordingTrack(id: track, relativePath: "fixture.wav", fileName: "fixture.wav", offset: -40)]
        let new = TranscriptSegment(trackID: track, start: 10.1, end: 14.1, text: words)
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: [new], createdAt: Date(timeIntervalSince1970: 2)))
        let issues = meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts, tracks: meeting.tracks))
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(meeting.unifiedTranscript[0].id, editedID)
        XCTAssertEqual(meeting.unifiedTranscript[0].text, "We should ask Jorden to review the calendar migration tomorrow")
        XCTAssertEqual(meeting.unifiedTranscript[0].start, -29.9, accuracy: 0.001)
        XCTAssertEqual(meeting.unifiedTranscript[0].provenance[0].segmentID, new.id)
        XCTAssertEqual(meeting.transcripts[1].segments[0].text, words)
    }
    func testCloseOriginalWordingTransfersButUnrelatedSpeechDoesNot() {
        var close = original()
        let issues = rerun(&close, segments: [TranscriptSegment(trackID: track, start: 10, end: 14, text: "We should ask Jordan to review the calendar migration today")])
        XCTAssertTrue(issues.isEmpty)
        var unrelated = original()
        let new = TranscriptSegment(trackID: track, start: 10, end: 14, text: "This is a completely different passage about the weather")
        let review = rerun(&unrelated, segments: [new])
        XCTAssertEqual(review.count, 1)
        XCTAssertEqual(review[0].candidateSegmentIDs, [new.id])
        XCTAssertEqual(unrelated.unifiedTranscript[0].text, new.text)
        XCTAssertTrue(review[0].originalSegment.text.contains("Jorden"))
    }
    func testRepeatedWordsElsewhereCannotReceiveCorrection() {
        var meeting = original()
        let new = TranscriptSegment(trackID: track, start: 100, end: 104, text: words)
        XCTAssertEqual(rerun(&meeting, segments: [new]).count, 1)
        XCTAssertEqual(meeting.unifiedTranscript[0].text, words)
    }
    func testSplitPassageRequiresReviewAndCanBeExplicitlyApplied() {
        var meeting = original()
        let first = TranscriptSegment(trackID: track, start: 10, end: 12, text: "We should ask Jordan to review")
        let second = TranscriptSegment(trackID: track, start: 12, end: 14, text: "the calendar migration tomorrow")
        let issues = rerun(&meeting, segments: [first, second])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(Set(issues[0].candidateSegmentIDs), Set([first.id, second.id]))
        XCTAssertTrue(meeting.resolveCorrectionTransfer(id: issues[0].id, targetSegmentID: first.id))
        XCTAssertNil(meeting.correctionTransferIssues)
        XCTAssertTrue(meeting.unifiedTranscript[0].text.contains("Jorden"))
        XCTAssertTrue(meeting.revisions.contains { $0.field.hasPrefix("correction-transfer:") })
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertNil(meeting.correctionTransferIssues)
        XCTAssertTrue(meeting.unifiedTranscript[0].text.contains("Jorden"))
    }
    func testAmbiguousCandidatesDoNotDuplicateOrSilentlyDropCorrection() {
        var meeting = original()
        let candidates = [TranscriptSegment(trackID: track, start: 10, end: 14, text: words),
                          TranscriptSegment(trackID: track, start: 10.1, end: 14.1, text: words)]
        let issues = rerun(&meeting, segments: candidates)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].candidateSegmentIDs.count, 2)
        XCTAssertTrue(meeting.unifiedTranscript.allSatisfy { $0.text == words })
        // An unresolved correction persists through subsequent runs and can apply when a unique match exists.
        let next = TranscriptSegment(trackID: track, start: 10, end: 14, text: words)
        XCTAssertTrue(rerun(&meeting, segments: [next], time: 3).isEmpty)
        XCTAssertTrue(meeting.unifiedTranscript[0].text.contains("Jorden"))
    }
    func testExplicitDismissalDoesNotReappearOnNextFusion() {
        var meeting = original()
        let new = TranscriptSegment(trackID: track, start: 100, end: 104, text: words)
        let issue = rerun(&meeting, segments: [new])[0]
        XCTAssertTrue(meeting.resolveCorrectionTransfer(id: issue.id, targetSegmentID: nil))
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertNil(meeting.correctionTransferIssues)
        XCTAssertTrue(meeting.revisions.contains { $0.field == "segment:\(issue.id.uuidString)" })
    }
    func testSummaryRefreshPreservesCompletionOnlyForExactTextAndOwner() {
        var meeting = Meeting(summary: MeetingSummary(overview: "Old", actionItems: [
            ActionItem(text: "Review the migration", owner: "Jordan", completed: true)
        ]))
        meeting.setSummary(MeetingSummary(overview: "New", actionItems: [
            ActionItem(text: "Review the migration", owner: "Jordan"),
            ActionItem(text: "Review the migration", owner: "Alex"),
            ActionItem(text: "Review a different migration", owner: "Jordan")
        ]))
        XCTAssertEqual(meeting.summary?.actionItems.map(\.completed), [true, false, false])
        XCTAssertEqual(meeting.revisions.filter { $0.field == "summary" }.count, 1)
    }
    func testNewOptionalMetadataDecodesLegacyRecords() throws {
        var meeting = original()
        meeting.folderID = UUID(); meeting.tags = ["work"]; meeting.templateID = "custom-template"
        meeting.transcripts[0].processingSettings = ProcessingSettings(modelID: "whisper-small", parameters: ["quality": "accurate"])
        meeting.transcripts[0].words = [TranscriptWord(text: "hello", start: 1, end: 2, confidence: 0.9)]
        meeting.speakers = [Speaker(id: "speaker", name: "Person", sourceTrackID: track, embedding: [1, 0], embeddingModelID: "model-v1")]
        let bytes = try JSONEncoder().encode(meeting)
        let roundTrip = try JSONDecoder().decode(Meeting.self, from: bytes)
        XCTAssertEqual(roundTrip, meeting)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for key in ["folderID", "tags", "templateID", "timedNotes", "speakerMatches", "correctionTransferIssues"] { object.removeValue(forKey: key) }
        var transcripts = try XCTUnwrap(object["transcripts"] as? [[String: Any]])
        transcripts[0].removeValue(forKey: "processingSettings"); transcripts[0].removeValue(forKey: "words")
        object["transcripts"] = transcripts
        var speakers = try XCTUnwrap(object["speakers"] as? [[String: Any]])
        speakers[0].removeValue(forKey: "embedding"); speakers[0].removeValue(forKey: "embeddingModelID"); speakers[0].removeValue(forKey: "analysisSettings")
        object["speakers"] = speakers
        let legacy = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.folderID); XCTAssertNil(legacy.tags); XCTAssertNil(legacy.templateID)
        XCTAssertNil(legacy.transcripts[0].processingSettings); XCTAssertNil(legacy.transcripts[0].words)
        XCTAssertNil(legacy.speakers[0].embeddingModelID)
    }
}
