import DaybookCore
import DaybookDevices
import XCTest
@testable import DaybookKit

/// The Markdown export names recordings by where they came from, never by the names their files
/// arrived with, which can say more than the person meant to share.
final class MeetingExportTests: XCTestCase {
    func testUnalignedSourcesAndTheirBookmarksAreNamedByWhereTheyCameFrom() throws {
        let interview = RecordingTrack(source: .imported, relativePath: "Originals/a.m4a", fileName: "Dana — salary talk.m4a")
        let memo = RecordingTrack(source: .imported, relativePath: "Originals/b.m4a", fileName: "Voice memo 0412.m4a")
        let phone = RecordingTrack(source: .microphone, relativePath: "Originals/c.m4a", fileName: "Recording-7F3A.m4a",
                                   device: DeviceRecordingIdentity(kind: DaybookPhoneIntegration.id, serial: "phone", recordingID: "7F3A"))
        let soundcore = RecordingTrack(source: .soundcore, relativePath: "Originals/d.wav", fileName: "Soundcore-1780000000-ab12cd34.wav")
        let tracks = [interview, memo, phone, soundcore]
        let meeting = Meeting(title: "Planning", tracks: tracks,
                              transcripts: tracks.map { TrackTranscript(trackID: $0.id, segments: [TranscriptSegment(trackID: $0.id, start: 1, end: 2, text: "Hello")]) },
                              alignmentReports: tracks.map { TrackAlignment(trackID: $0.id, method: .unaligned, explanation: "No shared speech.") },
                              highlights: [Highlight(trackID: interview.id, time: 1, text: "Ask about the offer")])

        let markdown = MeetingExport.markdown(meeting)

        let headings = markdown.split(separator: "\n").filter { $0.hasPrefix("## Unaligned source: ") }
        XCTAssertEqual(headings, ["## Unaligned source: Imported recording 1", "## Unaligned source: Imported recording 2",
                                  "## Unaligned source: iPhone", "## Unaligned source: Soundcore Work"])
        XCTAssertTrue(markdown.contains("], Imported recording 1, unaligned source-local timeline"), markdown)
        for track in tracks {
            XCTAssertFalse(markdown.contains(track.fileName), "\(track.fileName) in\n\(markdown)")
            XCTAssertFalse(markdown.contains((track.fileName as NSString).deletingPathExtension), markdown)
        }
    }

    func testADerivedRecordingSaysHowItWasMade() {
        let microphone = RecordingTrack(source: .microphone, relativePath: "Originals/m.caf", fileName: "microphone.caf")
        let cleaned = RecordingTrack(source: .microphone, relativePath: "Originals/e.caf", fileName: "microphone-echo-cancelled.caf",
                                     derivedFrom: microphone.id, processing: RecordingTrack.echoCancelledProcessing)
        let meeting = Meeting(tracks: [microphone, cleaned])
        XCTAssertEqual(MeetingExport.sourceName(of: microphone, in: meeting), "Microphone")
        XCTAssertEqual(MeetingExport.sourceName(of: cleaned, in: meeting), "Microphone, echo removed")
    }
}
