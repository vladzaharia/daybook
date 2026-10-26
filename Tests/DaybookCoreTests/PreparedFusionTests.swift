import XCTest
@testable import DaybookCore

/// Carrying corrections over to a new fusion can be worked out off the main actor and applied later:
/// the same result as applying it at once, and a correction made in between is never lost.
final class PreparedFusionTests: XCTestCase {
    private let track = UUID()
    private let words = "We should ask Jordan to review the calendar migration tomorrow"

    private func corrected() -> Meeting {
        let raw = TranscriptSegment(trackID: track, start: 10, end: 14, text: words)
        var meeting = Meeting(transcripts: [TrackTranscript(trackID: track, segments: [raw], createdAt: Date(timeIntervalSince1970: 1))])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        meeting.correctSegment(id: raw.id, text: "We should ask Jorden to review the calendar migration tomorrow")
        let rerun = TranscriptSegment(trackID: track, start: 10.1, end: 14.1, text: words)
        meeting.transcripts.append(TrackTranscript(trackID: track, segments: [rerun], createdAt: Date(timeIntervalSince1970: 2)))
        return meeting
    }

    func testAPreparedFusionAppliesExactlyAsADirectOne() {
        let meeting = corrected()
        let result = TranscriptFusion.fuse(meeting.transcripts)
        var direct = meeting, prepared = meeting
        let directIssues = direct.applyFusion(result)
        let preparedIssues = prepared.applyFusion(meeting.preparingFusion(result))
        direct.updatedAt = prepared.updatedAt
        XCTAssertEqual(prepared, direct)
        XCTAssertEqual(preparedIssues, directIssues)
        XCTAssertTrue(prepared.unifiedTranscript[0].text.contains("Jorden"))
    }

    func testACorrectionMadeAfterPreparingIsCarriedOverToo() {
        let meeting = corrected()
        let result = TranscriptFusion.fuse(meeting.transcripts)
        let prepared = meeting.preparingFusion(result)
        var current = meeting
        current.correctSegment(id: current.unifiedTranscript[0].id, text: "We should ask Jorden to review the calendar migration on Friday")
        current.applyFusion(prepared)
        XCTAssertEqual(current.unifiedTranscript[0].text, "We should ask Jorden to review the calendar migration on Friday")
    }
}
