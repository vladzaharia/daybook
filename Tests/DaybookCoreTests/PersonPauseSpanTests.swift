import DaybookCore
import XCTest

/// The person's pauses hold for the whole conversation (docs/capture.md, "Pausing"): a word heard wholly inside one is
/// made up, and no other device's recording joins over one.
final class PersonPauseSpanTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func conversation(pauses: [PersonPause]?, startedAt: Date?) -> Meeting {
        var meeting = Meeting(title: "Design review", date: start)
        var track = RecordingTrack(source: .microphone, relativePath: "a.caf", fileName: "a.caf", duration: 600, offset: 0, sha256: "a")
        track.startedAt = startedAt
        track.capture = TrackCaptureDetails(method: "microphone", pauses: pauses)
        meeting.tracks = [track]
        return meeting
    }

    func testBehaviorAWordIsKeptUnlessWhollyInsideAPause() {
        let pauses = [PersonPause(start: 10, end: 20)]
        XCTAssertFalse(PersonPause.keepsWord(start: 12, end: 13, in: pauses))
        XCTAssertFalse(PersonPause.keepsWord(start: 10, end: 20, in: pauses))
        XCTAssertTrue(PersonPause.keepsWord(start: 9.8, end: 10.2, in: pauses), "said as it began: real")
        XCTAssertTrue(PersonPause.keepsWord(start: 19.9, end: 20.3, in: pauses))
        XCTAssertTrue(PersonPause.keepsWord(start: 25, end: 26, in: pauses))
        XCTAssertTrue(PersonPause.keepsWord(start: 12, end: 13, in: []))
    }

    func testBehaviorAnotherDevicesRecordingJoinsOnlyWellClearOfAPause() {
        let paused = conversation(pauses: [PersonPause(start: 120, end: 180)], startedAt: start)
        XCTAssertEqual(paused.personPauseSpans, [DateInterval(start: start.addingTimeInterval(120), end: start.addingTimeInterval(180))])
        XCTAssertFalse(PersonPause.admits(start: start.addingTimeInterval(150), duration: 10, into: paused), "inside")
        XCTAssertFalse(PersonPause.admits(start: start, duration: 600, into: paused), "across it")
        XCTAssertFalse(PersonPause.admits(start: start.addingTimeInterval(200), duration: 60, into: paused), "within the clocks' margin after it")
        XCTAssertFalse(PersonPause.admits(start: start.addingTimeInterval(30), duration: 70, into: paused), "within the margin before it")
        XCTAssertTrue(PersonPause.admits(start: start.addingTimeInterval(240), duration: 60, into: paused), "well after it")
        XCTAssertTrue(PersonPause.admits(start: start, duration: 60, into: paused), "well before it")
        XCTAssertFalse(PersonPause.admits(start: nil, duration: 60, into: paused), "a start that isn't known can't be told from the pause")

        let never = conversation(pauses: nil, startedAt: start)
        XCTAssertNil(never.personPauseSpans)
        XCTAssertTrue(PersonPause.admits(start: nil, duration: 60, into: never), "never paused: as before")

        let unplaced = conversation(pauses: [PersonPause(start: 120, end: 180)], startedAt: nil)
        XCTAssertFalse(PersonPause.admits(start: start.addingTimeInterval(400), duration: 10, into: unplaced),
                       "a pause that can't be placed holds the whole time")
    }

    func testBehaviorPausesDecodeFromATrackWrittenWithoutThem() throws {
        let details = try JSONDecoder().decode(TrackCaptureDetails.self, from: Data(#"{"method":"microphone"}"#.utf8))
        XCTAssertNil(details.pauses)
        let written = TrackCaptureDetails(method: "microphone", pauses: [PersonPause(start: 1, end: 2)])
        XCTAssertEqual(try JSONDecoder().decode(TrackCaptureDetails.self, from: JSONEncoder().encode(written)), written)
    }
}
