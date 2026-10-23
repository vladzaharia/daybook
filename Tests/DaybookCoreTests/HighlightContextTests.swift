import XCTest
@testable import DaybookCore

final class HighlightContextTests: XCTestCase {
    func testAlignedDeviceHighlightUsesMeetingTimeAndKeepsAnnotationSeparate() throws {
        let track = UUID()
        let spoken = TranscriptSegment(trackID: track, start: 50, end: 54, text: "Words that were actually spoken")
        let marker = Highlight(trackID: track, time: 40, text: "User's private reminder")
        let meeting = Meeting(tracks: [RecordingTrack(id: track, relativePath: "audio.wav", fileName: "wearable.wav")],
            unifiedTranscript: [spoken], alignmentReports: [.init(trackID: track, method: .anchors, offset: 10)], highlights: [marker])
        let context = try XCTUnwrap(meeting.highlightContexts(before: 5, after: 5).first)
        XCTAssertTrue(context.isAligned); XCTAssertEqual(context.markerTime, 50)
        XCTAssertEqual(context.sourceName, "wearable.wav")
        XCTAssertEqual(context.highlight.text, "User's private reminder")
        XCTAssertEqual(context.speechContext.map(\.text), ["Words that were actually spoken"])
    }
    func testUnalignedDeviceHighlightUsesLatestSourceTranscriptAndDuration() throws {
        let track = UUID()
        let old = TranscriptSegment(trackID: track, start: 20, end: 22, text: "Old recognition")
        let newer = TranscriptSegment(trackID: track, start: 24, end: 26, text: "New recognition")
        let unrelated = TranscriptSegment(trackID: UUID(), start: 24, end: 26, text: "Other source")
        let meeting = Meeting(transcripts: [TrackTranscript(trackID: track, segments: [old], createdAt: Date(timeIntervalSince1970: 1)), TrackTranscript(trackID: track, segments: [newer], createdAt: Date(timeIntervalSince1970: 2))],
            unifiedTranscript: [unrelated], alignmentReports: [.init(trackID: track, method: .unaligned)], highlights: [Highlight(trackID: track, time: 20, duration: 10)])
        let context = try XCTUnwrap(meeting.highlightContexts(before: 0, after: 0).first)
        XCTAssertFalse(context.isAligned); XCTAssertEqual(context.markerTime, 20)
        XCTAssertEqual(context.rangeEnd, 30)
        XCTAssertEqual(context.speechContext.map(\.text), ["New recognition"])
    }
}
