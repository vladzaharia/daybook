import XCTest
@testable import DaybookCore

final class TrackDerivationTests: XCTestCase {
    func testDerivedTrackIsTranscribedInPlaceOfItsOriginal() {
        let microphone = RecordingTrack(source: .microphone, relativePath: "Originals/mic.caf", fileName: "microphone.caf", offset: 0.2)
        let call = RecordingTrack(source: .systemAudio, relativePath: "Originals/call.caf", fileName: "systemAudio.caf", offset: 0.25)
        let cleaned = RecordingTrack(source: .microphone, relativePath: "Originals/clean.caf", fileName: "microphone.echo-cancelled.caf",
                                     offset: 0.2, derivedFrom: microphone.id, processing: RecordingTrack.echoCancelledProcessing)
        var meeting = Meeting(tracks: [microphone, call, cleaned])
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [call.id, cleaned.id])
        XCTAssertTrue(meeting.hasUntranscribedTranscribableAudio)
        meeting.transcripts = [TrackTranscript(trackID: call.id, segments: []), TrackTranscript(trackID: cleaned.id, segments: [])]
        XCTAssertFalse(meeting.hasUntranscribedTranscribableAudio, "the original needs no transcript of its own")
        // Without a derivative, every track is transcribed.
        XCTAssertEqual(Meeting(tracks: [microphone, call]).transcribableTracks.count, 2)
    }

    func testCaptureDetailsAreOptionalAndRoundTrip() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","source":"microphone","relativePath":"Originals/a.caf","fileName":"a.caf","createdAt":0,"sha256":""}"#
        let decoded = try JSONDecoder().decode(RecordingTrack.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.capture)
        XCTAssertNil(decoded.derivedFrom)
        var track = decoded
        var report = EchoRemovalReport(outcome: .applied)
        report.delay = EchoDelayEstimate(delaySeconds: 0.07, confidence: 40, frames: 12)
        report.echoReturnLossEnhancementDB = 31
        track.capture = TrackCaptureDetails(method: "microphone", clockRate: 1.000_05, outputRoute: "speakers", echoRemoval: report)
        let again = try JSONDecoder().decode(RecordingTrack.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(again, track)
        XCTAssertEqual(EchoRemovalReport.skipped(.headphones).detail, EchoRemovalSkipReason.headphones.explanation)
    }
}
