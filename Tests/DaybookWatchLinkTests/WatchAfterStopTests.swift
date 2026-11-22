import XCTest
@testable import DaybookWatchLink

final class WatchAfterStopTests: XCTestCase {
    private let stopped = Date(timeIntervalSince1970: 1_000)
    private let conversation = UUID()

    private func moment(_ change: WatchChange = .stoppedOnWatch, duration: TimeInterval = 723, conversation: UUID? = nil,
                        useConversation: Bool = true) -> WatchAfterStop? {
        WatchAfterStop(recordingID: "r", conversationID: useConversation ? (conversation ?? self.conversation) : nil, duration: duration,
                       stoppedAt: stopped, change: change)
    }

    func testAStopOnTheWristOrTheIPhoneHoldsTheMoment() throws {
        for change in [WatchChange.stoppedOnWatch, .stoppedByPhone] {
            XCTAssertEqual(try XCTUnwrap(moment(change)).title, "Saved · 12:03")
        }
    }

    func testARecordingThatEndedOnItsOwnOrHeardNothingHasNoMoment() {
        XCTAssertNil(moment(.endedOnItsOwn))
        XCTAssertNil(moment(.recovered))
        XCTAssertNil(moment(duration: 0.4))
    }

    func testTheSummaryShowsForTenSeconds() throws {
        let moment = try XCTUnwrap(moment())
        XCTAssertTrue(moment.isShowing(at: stopped.addingTimeInterval(9.9)))
        XCTAssertFalse(moment.isShowing(at: stopped.addingTimeInterval(10)))
    }

    func testKeepRecordingIsOfferedForFiveMinutesAndNotASecondMore() throws {
        XCTAssertEqual(WatchAfterStop.keepWindow, 300)
        let moment = try XCTUnwrap(moment())
        XCTAssertFalse(moment.isKeepOpen(at: stopped.addingTimeInterval(-1)), "Never before the Stop")
        XCTAssertTrue(moment.isKeepOpen(at: stopped))
        XCTAssertTrue(moment.isKeepOpen(at: stopped.addingTimeInterval(299.9)))
        XCTAssertFalse(moment.isKeepOpen(at: stopped.addingTimeInterval(300)))
        XCTAssertEqual(moment.keepEnds, stopped.addingTimeInterval(300))
    }

    func testARecordingWithNoConversationOffersNoKeepRecording() throws {
        let moment = try XCTUnwrap(moment(useConversation: false))
        XCTAssertFalse(moment.isKeepOpen(at: stopped.addingTimeInterval(1)))
        XCTAssertTrue(moment.isShowing(at: stopped.addingTimeInterval(1)), "The summary doesn't need a conversation")
    }

    /// A relaunch inside the window reads the Stop back from the preferences: the window is the Stop's, not a view's timer.
    func testTheWindowSurvivesARelaunch() throws {
        let kept = try JSONEncoder().encode(try XCTUnwrap(moment()))
        let relaunched = try JSONDecoder().decode(WatchAfterStop.self, from: kept)
        XCTAssertEqual(relaunched.conversationID, conversation)
        XCTAssertTrue(relaunched.isKeepOpen(at: stopped.addingTimeInterval(240)))
        XCTAssertFalse(relaunched.isKeepOpen(at: stopped.addingTimeInterval(301)))
        XCTAssertFalse(relaunched.isShowing(at: stopped.addingTimeInterval(240)), "Back in the app after the summary: Keep Recording only")
    }
}
