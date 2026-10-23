import XCTest
@testable import DaybookCore

final class TranscriptFusionTests: XCTestCase {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let phrases = ["We should ship the calendar feature tomorrow", "Jordan will review the database migration next", "The onboarding experiment improved activation rates substantially", "Let us schedule another review for Monday"]
    func segment(_ track: UUID, _ time: Double, _ text: String, confidence: Double = 0.7) -> TranscriptSegment {
        TranscriptSegment(trackID: track, start: time, end: time + 4, text: text, speakerID: "\(track)-speaker-1", confidence: confidence)
    }
    func testOffsetAndDriftAlignmentDeduplicatesAndPreservesProvenance() throws {
        let original = phrases.enumerated().map { segment(a, Double($0.offset) * 100 + 15, $0.element) }
        let wearable = phrases.enumerated().map { segment(b, Double($0.offset) * 100 / 1.012, $0.element, confidence: 0.95) }
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: original, knownOffset: 0),
            TrackTranscript(trackID: b, segments: wearable)
        ])
        XCTAssertEqual(result.segments.count, 4)
        let alignment = try XCTUnwrap(result.alignments.first { $0.trackID == b })
        XCTAssertEqual(alignment.method, .anchors)
        XCTAssertEqual(alignment.offset, 15, accuracy: 0.01)
        XCTAssertEqual(alignment.rate, 1.012, accuracy: 0.0001)
        XCTAssertTrue(result.segments.allSatisfy { $0.provenance.count == 2 && $0.trackID == b })
        XCTAssertEqual(original[0].start, 15)
        XCTAssertEqual(wearable[0].start, 0)
    }
    func testUnmatchedTrackIsNotBlindlyInterleaved() {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: phrases.enumerated().map { segment(a, Double($0.offset) * 10, $0.element) }),
            TrackTranscript(trackID: b, segments: [segment(b, 0, "An entirely different conversation about gardening this weekend")])
        ])
        XCTAssertEqual(result.segments.count, 4)
        XCTAssertEqual(result.unalignedTrackIDs, [b])
    }
    func testRepeatedUtteranceElsewhereRemainsDistinct() {
        var reference = phrases.enumerated().map { segment(a, Double($0.offset) * 30, $0.element) }
        reference.append(segment(a, 300, phrases[0]))
        let second = phrases.enumerated().map { segment(b, Double($0.offset) * 30, $0.element) }
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: reference, knownOffset: 0),
            TrackTranscript(trackID: b, segments: second, knownOffset: 0)
        ])
        XCTAssertEqual(result.segments.count, 5)
        XCTAssertEqual(result.segments.filter { $0.text == phrases[0] }.count, 2)
        XCTAssertEqual(result.segments.last?.provenance.count, 1)
    }
    func testOnlyRepeatedPhrasesCannotEstablishAlignment() {
        let repeated = (0..<5).map { segment(a, Double($0) * 30, phrases[0]) }
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: repeated),
            TrackTranscript(trackID: b, segments: repeated.map { segment(b, $0.start + 5, $0.text) })
        ])
        XCTAssertEqual(result.unalignedTrackIDs, [b])
        XCTAssertEqual(result.segments.count, 5)
    }
    func testConflictingOverlappingPassagesAreBothPreserved() {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: [segment(a, 0, "The launch is definitely scheduled for Tuesday")], knownOffset: 0),
            TrackTranscript(trackID: b, segments: [segment(b, 0, "We have cancelled all plans until further notice")], knownOffset: 0)
        ])
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertTrue(result.unalignedTrackIDs.isEmpty)
    }
    func testKnownCaptureOffsetsWorkWithoutTextAnchors() {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: [segment(a, 10, "Hello everybody welcome to the meeting")]),
            TrackTranscript(trackID: b, segments: [segment(b, 0, "Hello everybody welcome to the meeting")])
        ], tracks: [RecordingTrack(id: a, relativePath: "a.wav", fileName: "a", offset: 0),
                    RecordingTrack(id: b, relativePath: "b.wav", fileName: "b", offset: 10)])
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].provenance.count, 2)
    }
    func testManualNegativeOffsetKeepsOriginalReferenceAndEarlierPassages() throws {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: [segment(a, 0, phrases[0])]),
            TrackTranscript(trackID: b, segments: [segment(b, 0, "A conversation before the computer recording started"), segment(b, 15, phrases[0])], knownOffset: -15)
        ])
        XCTAssertTrue(result.unalignedTrackIDs.isEmpty)
        XCTAssertEqual(result.alignments.first?.trackID, a)
        XCTAssertEqual(result.alignments.first?.method, .reference)
        XCTAssertEqual(result.segments.first?.start, -15)
        XCTAssertEqual(result.segments.count, 2)
        let provided = try XCTUnwrap(result.alignments.first { $0.trackID == b })
        XCTAssertEqual(provided.method, .provided)
        XCTAssertEqual(provided.offset, -15)
        let meeting = Meeting(alignmentReports: result.alignments)
        XCTAssertEqual(meeting.alignedTime(for: Highlight(trackID: b, time: 2)), -13)
    }
    func testAddingLongerRecordingDoesNotChangeTimelineOrigin() {
        let original = TrackTranscript(trackID: a, segments: phrases.enumerated().map { segment(a, Double($0.offset) * 30 + 10, $0.element) })
        var wearable = phrases.enumerated().map { segment(b, Double($0.offset) * 30, $0.element) }
        wearable.append(segment(b, 200, "Extra closing words after the original recording ended"))
        let result = TranscriptFusion.fuse([original, TrackTranscript(trackID: b, segments: wearable)])
        XCTAssertEqual(result.alignments.first?.trackID, a)
        XCTAssertEqual(result.segments.first?.start, 10)
        XCTAssertEqual(result.segments.last?.start, 210)
    }
    func testRepeatedShortAcknowledgmentsRemainDistinctEvenWhenTheyOverlap() {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: [segment(a, 0, "Yes"), segment(a, 0.5, "Yes")], knownOffset: 0),
            TrackTranscript(trackID: b, segments: [segment(b, 0.2, "Yes")], knownOffset: 0)
        ])
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertTrue(result.segments.allSatisfy { $0.provenance.count == 1 })
    }
    func testNegationAndPartialCompoundVariantsAreNotDiscardedByConfidence() {
        let first = [segment(a, 0, "We will launch the product tomorrow", confidence: 0.95),
                     segment(a, 10, "We approved the calendar update", confidence: 0.95)]
        let second = [segment(b, 0, "We will not launch the product tomorrow", confidence: 0.5),
                      segment(b, 10, "We approved the calendar update but rejected the database migration", confidence: 0.5)]
        let result = TranscriptFusion.fuse([TrackTranscript(trackID: a, segments: first, knownOffset: 0), TrackTranscript(trackID: b, segments: second, knownOffset: 0)])
        XCTAssertEqual(result.segments.count, 4)
        XCTAssertTrue(result.segments.contains { $0.text.contains("not launch") })
        XCTAssertTrue(result.segments.contains { $0.text.contains("rejected") })
    }
    func testDifferentSegmentBoundariesPreserveAllSourceWords() {
        let first = TrackTranscript(trackID: a, segments: [segment(a, 0, "Please review the calendar update and schedule the next planning meeting")], knownOffset: 0)
        let second = TrackTranscript(trackID: b, segments: [segment(b, 0, "Please review the calendar update"), segment(b, 2, "and schedule the next planning meeting")], knownOffset: 0)
        let result = TranscriptFusion.fuse([first, second])
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(Set(result.segments.flatMap(\.provenance).map(\.segmentID)), Set((first.segments + second.segments).map(\.id)))
    }
    func testSingleCoincidentalPhraseDoesNotAlignTracks() {
        let result = TranscriptFusion.fuse([
            TrackTranscript(trackID: a, segments: phrases.enumerated().map { segment(a, Double($0.offset) * 10, $0.element) }),
            TrackTranscript(trackID: b, segments: [segment(b, 100, phrases[0])])
        ])
        XCTAssertEqual(result.unalignedTrackIDs, [b])
    }
    func testLatestRunIsSynthesizedWithoutDuplicatingEarlierRun() {
        let early = TrackTranscript(trackID: a, segments: [segment(a, 0, "Old text")], createdAt: Date(timeIntervalSince1970: 1))
        let later = TrackTranscript(trackID: a, segments: [segment(a, 0, "Correct text")], createdAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(TranscriptFusion.fuse([early, later]).segments.map(\.text), ["Correct text"])
    }
    func testUserCorrectionSurvivesPreferredSourceChanging() throws {
        let first = TrackTranscript(trackID: a, segments: [segment(a, 0, phrases[0], confidence: 0.5)], knownOffset: 0)
        let second = TrackTranscript(trackID: b, segments: [segment(b, 0, phrases[0], confidence: 0.9)], knownOffset: 0)
        var meeting = Meeting(transcripts: [first])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        let originalID = try XCTUnwrap(meeting.unifiedTranscript.first?.id)
        meeting.correctSegment(id: originalID, text: "We should ship the calendar feature next week")
        meeting.transcripts.append(second)
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript.count, 1)
        XCTAssertEqual(meeting.unifiedTranscript[0].id, originalID)
        XCTAssertEqual(meeting.unifiedTranscript[0].trackID, b)
        XCTAssertEqual(meeting.unifiedTranscript[0].text, "We should ship the calendar feature next week")
        XCTAssertEqual(meeting.unifiedTranscript[0].provenance.count, 2)
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts))
        XCTAssertEqual(meeting.unifiedTranscript[0].text, "We should ship the calendar feature next week")
    }
}
