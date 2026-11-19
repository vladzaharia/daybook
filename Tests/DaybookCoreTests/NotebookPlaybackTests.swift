import XCTest

@testable import DaybookCore

final class NotebookPlaybackTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Recording from t0, paused at 10 s (the recorder's clock holds 10), resumed at 40 s, so 30 s of silence in the audio.
    private var samples: [RecordingClockSample] {
        [RecordingClockSample(at: t0, elapsed: 0, running: true),
         RecordingClockSample(at: t0.addingTimeInterval(10), elapsed: 10, running: false),
         RecordingClockSample(at: t0.addingTimeInterval(40), elapsed: 10, running: true)]
    }

    private func meeting(passageAt offset: TimeInterval, time: TimeInterval) -> (Meeting, NotebookPage, NotebookPassage, UUID) {
        var meeting = Meeting(title: "Notes")
        var track = RecordingTrack(id: UUID(), source: .imported, relativePath: "a.m4a", fileName: "a.m4a", sha256: "x")
        track.clockSamples = samples
        meeting.tracks = [track]
        let page = NotebookPage(order: 1, now: t0)
        let passage = NotebookPassage(id: UUID(), kind: .writing, x: 0, y: 0, width: 10, height: 10, strokeCount: 1, strokeDigest: "d",
                                      start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + 2), trackID: track.id, time: time,
                                      words: "hi")
        return (meeting, page, passage, track.id)
    }

    func testBehaviorPassageWrittenWhileRunningStartsAtItsTime() throws {
        let (meeting, page, passage, track) = meeting(passageAt: 5, time: 5)
        let start = try XCTUnwrap(meeting.playbackStart(of: passage, on: page))
        XCTAssertEqual(start.trackID, track)
        XCTAssertEqual(start.seconds, 5, accuracy: 0.001)
    }

    func testBehaviorPassageTimedInsideAPauseStartsAtTheEndOfTheSilence() throws {
        // Written 25 s in, during the pause: the recorder's clock held at 10, so it's timed 10; the silence ends at 40 in the audio.
        let (meeting, page, passage, _) = meeting(passageAt: 25, time: 10)
        let start = try XCTUnwrap(meeting.playbackStart(of: passage, on: page))
        XCTAssertEqual(start.seconds, 40, accuracy: 0.001)
    }

    func testBehaviorPausedWithoutResumeHasNoEnd() {
        let ordered = [RecordingClockSample(at: t0, elapsed: 0, running: true), RecordingClockSample(at: t0.addingTimeInterval(10), elapsed: 10, running: false)]
        XCTAssertNil(RecordingClockMap.endOfPause(containing: t0.addingTimeInterval(20), samples: ordered))
        XCTAssertNil(RecordingClockMap.endOfPause(containing: t0.addingTimeInterval(5), samples: samples), "not in a pause")
    }

    func testBehaviorPassageWithoutRecordingStartsOnTheTimeline() throws {
        let meeting = Meeting(title: "Notes")
        let page = NotebookPage(order: 1, now: t0)
        let passage = NotebookPassage(id: UUID(), kind: .writing, x: 0, y: 0, width: 1, height: 1, strokeCount: 1, strokeDigest: "d",
                                      start: t0.addingTimeInterval(12), end: t0.addingTimeInterval(13), time: 12)
        let start = try XCTUnwrap(meeting.playbackStart(of: passage, on: page))
        XCTAssertNil(start.trackID)
        XCTAssertEqual(start.seconds, 12, accuracy: 0.001)
    }
}
