import DaybookKit
import XCTest
@testable import DaybookPhone

/// A conversation a Mac recorded with a recorder along, as the iPhone sees it through sync: the Mac's
/// summary is in, and the recorder's audio hasn't arrived yet (docs/multipoint.md, "Mac first").
@MainActor
final class AwaitingRecordingStatusTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func meeting() -> Meeting {
        let track = UUID()
        var meeting = Meeting(title: "Design review",
                              tracks: [RecordingTrack(id: track, source: .microphone, relativePath: "m.caf", fileName: "m.caf", offset: 0, sha256: "m")],
                              transcripts: [TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 0, end: 2, text: "Hi")])],
                              summary: MeetingSummary(overview: "Hi"))
        var link = CompanionRecording(deviceID: "recorder", deviceKind: "soundcore.work", deviceName: "Soundcore Work",
                                      macStartedAt: now.addingTimeInterval(-900), state: .stopped, startedByDaybook: true)
        link.macEndedAt = now.addingTimeInterval(-60)
        link.recordingID = "1800000000"
        meeting.companions = [link]
        return meeting
    }

    func testTheRowAndThePageSayWhatTheyreWaitingFor() {
        let status = ProcessingStatus(meeting(), now: now)
        XCTAssertEqual(StatusPresentation.row(status), RowStatus(kind: .waiting, text: "Waiting for Soundcore Work audio"))
        let page = StatusPresentation.page(status, meeting: meeting(), sighting: nil, now: now)
        XCTAssertEqual(page?.kind, .line)
        XCTAssertEqual(page?.title, "Waiting for audio from Soundcore Work")
        XCTAssertFalse(status.isPending, "The Mac's summary is in: nothing on it waits")
    }
}
