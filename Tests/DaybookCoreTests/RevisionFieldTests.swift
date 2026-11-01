import Foundation
import XCTest
@testable import DaybookCore

/// What a Version History entry changed: one spelling on disk, read back as the same kind, and the
/// person's renames and corrections found from it.
final class RevisionFieldTests: XCTestCase {
    private let id = UUID(uuidString: "6F3C1D2A-9B8E-4C7D-A1B2-3C4D5E6F7A8B")!

    func testBehaviorEachKindIsWrittenAsBeforeAndReadsBackTheSame() {
        let written: [(RevisionField, String)] = [
            (.notes, "notes"),
            (.summary, "summary"),
            (.speaker("S2"), "speaker:S2"),
            (.segment(id), "segment:\(id.uuidString)"),
            (.photo(id), "photo:\(id.uuidString)"),
            (.photoCaption(id), "photo-caption:\(id.uuidString)"),
            (.bookmark(id), "bookmark:\(id.uuidString)"),
            (.correctionTransfer(id), "correction-transfer:\(id.uuidString)"),
            (.source(id.uuidString), "source:\(id.uuidString)"),
            (.source("restored:\(id.uuidString)"), "source:restored:\(id.uuidString)"),
            (.sync("summary"), "sync:summary")
        ]
        for (kind, raw) in written {
            XCTAssertEqual(kind.rawValue, raw)
            XCTAssertEqual(RevisionField(rawValue: raw), kind, raw)
        }
    }

    func testBehaviorAKindWhoseNameStartsAnothersIsReadAsItself() {
        XCTAssertEqual(RevisionField(rawValue: "photo-caption:\(id.uuidString)"), .photoCaption(id))
        XCTAssertEqual(RevisionField(rawValue: "photo:\(id.uuidString)"), .photo(id))
        XCTAssertEqual(RevisionField(rawValue: "speakers:S1"), .unknown("speakers:S1"))
        XCTAssertEqual(RevisionField(rawValue: "notes:extra"), .unknown("notes:extra"))
        // A speaker's ID is whatever follows the first colon.
        XCTAssertEqual(RevisionField(rawValue: "speaker:track:S1"), .speaker("track:S1"))
    }

    func testBehaviorAKindThisVersionDoesntKnowIsKeptAsWritten() {
        for raw in ["outline", "outline:\(id.uuidString)", "segment:not-an-id", ""] {
            XCTAssertEqual(RevisionField(rawValue: raw), .unknown(raw))
            XCTAssertEqual(RevisionField(rawValue: raw).rawValue, raw)
        }
        var revision = MeetingRevision(field: "outline:1", oldValue: "", newValue: "x")
        XCTAssertEqual(revision.kind, .unknown("outline:1"))
        revision.kind = .segment(id)
        XCTAssertEqual(revision.field, "segment:\(id.uuidString)")
    }

    func testBehaviorAConversationKnowsWhichSpeakersThePersonRenamedAndWhichPassagesTheyCorrected() {
        let track = UUID()
        var meeting = Meeting(title: "Edits")
        meeting.speakers = [Speaker(id: "S1", name: "Speaker 1"), Speaker(id: "S2", name: "Speaker 2")]
        meeting.unifiedTranscript = [TranscriptSegment(trackID: track, start: 0, end: 1, text: "helo"),
                                     TranscriptSegment(trackID: track, start: 1, end: 2, text: "there")]
        XCTAssertFalse(meeting.hasPersonMadeContent)
        meeting.renameSpeaker(id: "S2", name: "Dana")
        meeting.correctSegment(id: meeting.unifiedTranscript[0].id, text: "hello")
        meeting.revisions.append(MeetingRevision(kind: .photo(id), oldValue: "", newValue: "added"))
        XCTAssertEqual(meeting.renamedSpeakerIDs, ["S2"])
        XCTAssertEqual(meeting.correctedSegmentIDs, [meeting.unifiedTranscript[0].id])
        XCTAssertEqual(meeting.revisions.map(\.field), ["speaker:S2", "segment:\(meeting.unifiedTranscript[0].id.uuidString)",
                                                       "photo:\(id.uuidString)"])
        XCTAssertTrue(meeting.hasPersonMadeContent)
        XCTAssertEqual(meeting.handRename(of: "S2")?.newValue, "Dana")
        XCTAssertNil(meeting.handRename(of: "S1"))
    }
}
