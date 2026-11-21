import XCTest
@testable import DaybookWatchLink

final class WatchWordsTests: XCTestCase {
    private func line(_ edit: (inout WatchWords.Status) -> Void) -> String? {
        var status = WatchWords.Status()
        edit(&status)
        return WatchWords.statusLine(status)
    }

    func testAProblemComesFirst() {
        XCTAssertEqual(line { $0.problem = "Couldn’t resume"; $0.isRecording = true }, "Couldn’t resume")
    }

    func testAStartInProgressSaysSo() {
        XCTAssertEqual(line { $0.starting = true }, "Starting…")
    }

    func testPausedSaysPaused() {
        XCTAssertEqual(line { $0.isRecording = true; $0.isCapturing = false; $0.isJoined = true }, "Paused")
    }

    func testARecordingSaysWhereItGoes() {
        XCTAssertEqual(line { $0.isRecording = true; $0.isCapturing = true; $0.isReachable = true }, "On Watch")
        XCTAssertEqual(line { $0.isRecording = true; $0.isCapturing = true; $0.isReachable = true; $0.isJoined = true }, "With iPhone")
        XCTAssertEqual(line { $0.isRecording = true; $0.isCapturing = true; $0.isReachable = false }, "Sends later")
    }

    func testSendingAfterStop() {
        XCTAssertEqual(line { $0.isSending = true; $0.isReachable = true }, "Sending to iPhone…")
        XCTAssertEqual(line { $0.isSending = true; $0.isReachable = false }, "Waiting for iPhone")
        XCTAssertNil(line { _ in })
    }

    func testTheStoppedNoticeBodyIsASentence() {
        XCTAssertEqual(WatchWords.stoppedBody("Apple Watch storage is full"), "Apple Watch storage is full.")
        XCTAssertEqual(WatchWords.stoppedBody("Apple Watch storage is full."), "Apple Watch storage is full.")
    }

    func testTheClockFreezesAtTheLengthItIsGiven() {
        XCTAssertEqual(WatchWords.clock(0), "0:00")
        XCTAssertEqual(WatchWords.clock(65.9), "1:05")
        XCTAssertEqual(WatchWords.clock(3725), "1:02:05")
        XCTAssertEqual(WatchWords.clock(-3), "0:00")
    }

    func testAStopWithNoReasonHasNoBody() {
        XCTAssertEqual(WatchWords.stoppedBody(""), "")
    }
}
