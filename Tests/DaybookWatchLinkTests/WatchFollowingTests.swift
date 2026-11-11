import DaybookWatchLink
import XCTest

final class WatchFollowingTests: XCTestCase {
    private let standup = UUID()
    private let review = UUID()

    private func shared(_ conversation: UUID, startedAt: TimeInterval = 100) -> WatchSharedRecording {
        WatchSharedRecording(conversationID: conversation, title: nil, startedAt: Date(timeIntervalSince1970: startedAt))
    }

    private func context(_ shared: WatchSharedRecording?, recordsAlong: Bool = true, sentAt: TimeInterval = 200) -> PhoneContext {
        PhoneContext(sharedRecording: shared, recordsAlong: recordsAlong, phoneName: "Alex's iPhone",
                     sentAt: Date(timeIntervalSince1970: sentAt))
    }

    private func recording(_ conversation: UUID? = nil, startedAt: TimeInterval? = nil, began: TimeInterval? = nil,
                           id: String = "rec-1", own: Bool = false) -> WatchFollowing.Recording {
        WatchFollowing.Recording(id: id, conversationID: conversation, conversationStartedAt: startedAt.map(at),
                                 startedAt: began.map(at), isOwn: own)
    }

    /// A time on either clock, in seconds.
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: Joining

    func testOpeningDaybookJoinsTheSharedRecordingWithRecordAlongOn() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(standup)), at: at(201), recording: nil, canStart: true), .join(shared(standup)))
    }

    func testItDoesntJoinWithRecordAlongOffWithNothingSharedOrInTheBackground() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(standup), recordsAlong: false), at: at(201), recording: nil, canStart: true), .none)
        XCTAssertEqual(following.received(context(nil, sentAt: 300), at: at(301), recording: nil, canStart: true), .none)
        XCTAssertEqual(following.received(context(shared(standup), sentAt: 400), at: at(401), recording: nil, canStart: false), .none)
        // Opening Daybook moments later reads the newest context again.
        XCTAssertEqual(following.follow(recording: nil, canStart: true, at: at(420)), .join(shared(standup)))
    }

    func testAConversationStoppedOnTheWatchIsntJoinedAgain() {
        var following = WatchFollowing()
        following.leave(standup)
        XCTAssertEqual(following.received(context(shared(standup)), at: at(201), recording: nil, canStart: true), .none)
        XCTAssertEqual(following.received(context(shared(review), sentAt: 300), at: at(301), recording: nil, canStart: true),
                       .join(shared(review)))
    }

    // MARK: Freshness

    func testAStaleContextIsNeitherJoinedNorAdoptedButStillStops() {
        var following = WatchFollowing()
        // The application context waited an hour while the watch was away: the shared recording may have ended.
        XCTAssertEqual(following.received(context(shared(standup)), at: at(3_800), recording: nil, canStart: true), .none)
        XCTAssertEqual(following.follow(recording: recording(), canStart: true, at: at(3_800)), .none, "Nor adopted at a wrist start")
        XCTAssertFalse(following.isFresh(at: at(3_800)))
        // A stale context still ends a recording it no longer shares.
        XCTAssertEqual(following.received(context(shared(review), sentAt: 300), at: at(3_801), recording: recording(standup, startedAt: 100),
                                          canStart: true), .stop)
    }

    func testAnAnswerIsFreshWhateverTheClocksSayUntilItAges() {
        var following = WatchFollowing()
        // The iPhone's clock is five minutes behind the watch's: its answer is fresh as it arrives all the same.
        XCTAssertEqual(following.received(context(shared(standup)), answered: true, at: at(500), recording: nil, canStart: true),
                       .join(shared(standup)))
        XCTAssertTrue(following.isFresh(at: at(500 + WatchFollowing.freshness)))
        XCTAssertEqual(following.follow(recording: nil, canStart: true, at: at(500 + WatchFollowing.freshness + 1)), .none)
    }

    func testAContextSentMomentsAgoIsFresh() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(standup)), at: at(200 + WatchFollowing.freshness), recording: nil, canStart: true),
                       .join(shared(standup)))
        XCTAssertFalse(following.isFresh(at: at(200 + WatchFollowing.freshness + 1)))
    }

    func testARelaunchOutOfReachDoesntJoinFromTheSavedContext() throws {
        var following = WatchFollowing()
        _ = following.received(context(shared(standup)), at: at(201), recording: nil, canStart: false)
        var relaunched = try JSONDecoder().decode(WatchFollowing.self, from: JSONEncoder().encode(following))
        // Out of reach, the watch reads the iPhone's last application context: the same one, now an hour old.
        XCTAssertEqual(relaunched.received(context(shared(standup)), at: at(3_800), recording: nil, canStart: true), .none)
        XCTAssertEqual(relaunched.follow(recording: nil, canStart: true, at: at(3_800)), .none)
        // Back in reach, the iPhone's answer joins it if it's still going.
        XCTAssertEqual(relaunched.received(context(shared(standup), sentAt: 3_790), answered: true, at: at(3_801), recording: nil,
                                           canStart: true), .join(shared(standup)))
    }

    func testAnOlderContextChangesNothing() {
        var following = WatchFollowing()
        _ = following.received(context(nil, sentAt: 500), recording: nil, canStart: true)
        XCTAssertEqual(following.received(context(shared(standup), sentAt: 400), recording: nil, canStart: true), .none)
        XCTAssertNil(following.context?.sharedRecording)
    }

    // MARK: Adopting and stopping

    func testARecordingStartedOnTheWristAdoptsTheSharedRecording() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(nil), at: at(201), recording: recording(began: 195), canStart: true), .none,
                       "The iPhone hasn't started yet")
        XCTAssertEqual(following.received(context(shared(standup), sentAt: 300), at: at(301), recording: recording(began: 195),
                                          canStart: false), .adopt(shared(standup)))
    }

    func testAWristStartAdoptsOnlyAContextThatArrivedAfterIt() {
        var following = WatchFollowing()
        // The context arrived with Daybook in the background, and the person started on the wrist as it opened.
        XCTAssertEqual(following.received(context(shared(standup)), answered: true, at: at(201), recording: nil, canStart: false), .none)
        XCTAssertEqual(following.follow(recording: recording(began: 205), canStart: true, at: at(205)), .none,
                       "The context the watch had when it started may name a recording that just ended")
        XCTAssertEqual(following.received(context(shared(standup)), at: at(206), recording: recording(began: 205), canStart: true), .none,
                       "The same context again is no newer")
        // The iPhone heard of the recording and sent a context back.
        XCTAssertEqual(following.received(context(shared(standup), sentAt: 207), at: at(207), recording: recording(began: 205),
                                          canStart: true), .adopt(shared(standup)))
    }

    /// With Record Along off the iPhone ignores the watch's button: its recording stays the watch's, and adopts nothing.
    func testAWristRecordingAdoptsNothingWithRecordAlongOff() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(standup), recordsAlong: false, sentAt: 300), at: at(301),
                                          recording: recording(began: 295), canStart: true), .none)
        XCTAssertEqual(following.follow(recording: recording(began: 295), canStart: true, at: at(302)), .none)
        // Nor stops for the shared recording ending.
        XCTAssertEqual(following.received(context(nil, recordsAlong: false, sentAt: 310), at: at(311), recording: recording(began: 295),
                                          canStart: true), .none)
        // Turned on, the next shared recording is adopted.
        XCTAssertEqual(following.received(context(shared(review, startedAt: 320), sentAt: 321), at: at(321), recording: recording(began: 295),
                                          canStart: true), .adopt(shared(review, startedAt: 320)))
    }

    func testAWristRecordingDoesntAdoptAConversationTheWatchLeft() {
        var following = WatchFollowing()
        following.leave(standup)
        // The context still shows the conversation just stopped on the watch; the iPhone hasn't heard yet.
        XCTAssertEqual(following.received(context(shared(standup)), at: at(201), recording: recording(began: 195), canStart: true), .none)
    }

    func testAWristStopBeforeTheAdoptingContextLeavesTheSharedRecordingStartedForIt() {
        var following = WatchFollowing()
        // Started on the wrist at 200 and stopped at 203; the iPhone started the standup at 202 because of it.
        following.leave(nil, at: at(203))
        XCTAssertEqual(following.received(context(shared(standup, startedAt: 202), sentAt: 204), at: at(204), recording: nil,
                                          canStart: true), .none, "Recording doesn't start again by itself")
        // The iPhone's clock a few seconds ahead of the watch's.
        XCTAssertEqual(following.received(context(shared(standup, startedAt: 206), sentAt: 208), at: at(205), recording: nil,
                                          canStart: true), .none)
        XCTAssertEqual(following.follow(recording: recording(began: 204), canStart: true, at: at(209)), .none,
                       "Nor adopted by the next wrist recording")
        // A shared recording started afterwards is joined.
        XCTAssertEqual(following.received(context(shared(review, startedAt: 260), sentAt: 261), at: at(261), recording: nil,
                                          canStart: true), .join(shared(review, startedAt: 260)))
        XCTAssertTrue(following.left.isEmpty)
    }

    func testTheSharedRecordingEndingOrChangingStopsTheRecording() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(standup)), recording: recording(standup), canStart: true), .none)
        XCTAssertEqual(following.received(context(nil, sentAt: 300), recording: recording(standup), canStart: true), .stop)
        XCTAssertEqual(following.received(context(shared(review), sentAt: 400), recording: recording(standup), canStart: false), .stop)
    }

    /// The watch's own recording (the iPhone's Record with nothing recording there) adopts a shared recording that starts
    /// later, as the iPhone records it along (already recording), but never stops when it ends: the iPhone doesn't stop it.
    func testTheWatchsOwnRecordingAdoptsButNeverStopsWithTheSharedRecording() {
        var following = WatchFollowing()
        XCTAssertEqual(following.received(context(shared(review, startedAt: 310), sentAt: 311), at: at(311),
                                          recording: recording(began: 300, own: true), canStart: true), .adopt(shared(review, startedAt: 310)))
        let adopted = recording(review, startedAt: 310, began: 300, own: true)
        XCTAssertEqual(following.received(context(nil, sentAt: 400), at: at(401), recording: adopted, canStart: true), .none)
        XCTAssertEqual(following.received(context(shared(standup, startedAt: 450), sentAt: 451), at: at(451), recording: adopted,
                                          canStart: true), .none)
        // A wrist recording that adopted the same shared recording follows it.
        XCTAssertEqual(following.follow(recording: recording(standup, startedAt: 450, began: 300), canStart: true, at: at(452)), .none)
        XCTAssertEqual(following.follow(recording: recording(review, startedAt: 310, began: 300), canStart: true, at: at(452)), .stop)
        // The iPhone's own Stop still stops it.
        XCTAssertTrue(following.stops(WatchStop(recordingID: "rec-1", conversationID: review), recording: adopted))
    }

    func testAContextSentBeforeTheSharedRecordingStartedDoesntStopIt() {
        var following = WatchFollowing()
        // The iPhone's `.start` (shared recording at 250) arrived ahead of the context it sent at 240.
        XCTAssertEqual(following.received(context(nil, sentAt: 240), recording: recording(standup, startedAt: 250), canStart: true), .none)
        XCTAssertEqual(following.received(context(nil, sentAt: 260), recording: recording(standup, startedAt: 250), canStart: true), .stop)
    }

    // MARK: The iPhone's start and stop

    func testStartWhileOpenStartsAndWhileClosedRefuses() {
        var following = WatchFollowing()
        let start = WatchStart(conversationID: standup)
        XCTAssertEqual(following.start(start, recording: nil, canStart: true), .start)
        XCTAssertEqual(following.start(start, recording: nil, canStart: false), .refuse(WatchFollowing.openToRecord))
    }

    func testAStartForNoConversationRecordsOnItsOwn() {
        var following = WatchFollowing()
        let start = WatchStart(conversationID: nil)
        XCTAssertEqual(following.start(start, recording: nil, canStart: true), .start)
        XCTAssertEqual(following.start(start, recording: nil, canStart: false), .refuse(WatchFollowing.openToRecord))
        XCTAssertEqual(following.start(start, recording: recording(), canStart: false), .recording)
        XCTAssertEqual(following.start(start, recording: recording(standup), canStart: true), .replace)
        // No context stops it, and a fresh shared recording that comes after it is adopted.
        let own = recording(began: 300, own: true)
        XCTAssertEqual(following.received(context(nil, sentAt: 301), at: at(301), recording: own, canStart: true), .none)
        XCTAssertEqual(following.received(context(shared(review, startedAt: 310), sentAt: 311), at: at(311), recording: own,
                                          canStart: true), .adopt(shared(review, startedAt: 310)))
        XCTAssertFalse(following.stops(WatchStop(conversationID: review), recording: own))
    }

    func testStartForTheRecordingsOwnConversationOrNoneKeepsIt() {
        var following = WatchFollowing()
        let start = WatchStart(conversationID: standup)
        XCTAssertEqual(following.start(start, recording: recording(standup), canStart: false), .recording)
        XCTAssertEqual(following.start(start, recording: recording(), canStart: false), .adopt)
        XCTAssertEqual(following.start(start, recording: recording(review), canStart: true), .replace)
        XCTAssertEqual(following.start(start, recording: recording(review), canStart: false), .refuse(WatchFollowing.openToRecord))
    }

    func testAnExplicitStartBringsTheWatchBackToAConversationItLeft() {
        var following = WatchFollowing()
        following.leave(standup)
        XCTAssertEqual(following.start(WatchStart(conversationID: standup), recording: nil, canStart: false),
                       .refuse(WatchFollowing.openToRecord))
        XCTAssertEqual(following.left, [standup], "A refused start changes nothing")
        XCTAssertEqual(following.start(WatchStart(conversationID: standup), recording: nil, canStart: true), .start)
        XCTAssertTrue(following.left.isEmpty)
    }

    func testStopEndsOnlyTheRecordingAndConversationItNames() {
        let following = WatchFollowing()
        XCTAssertTrue(following.stops(WatchStop(), recording: recording(standup)))
        XCTAssertTrue(following.stops(WatchStop(recordingID: "rec-1", conversationID: standup), recording: recording(standup)))
        XCTAssertFalse(following.stops(WatchStop(recordingID: "rec-0"), recording: recording(standup)), "A late stop for an older recording")
        XCTAssertFalse(following.stops(WatchStop(conversationID: review), recording: recording(standup)))
        XCTAssertFalse(following.stops(WatchStop(conversationID: standup), recording: recording()), "Started on the wrist, not for it")
        XCTAssertFalse(following.stops(WatchStop(), recording: nil))
    }

    func testAStopThatArrivesWhileARecordingStartsAppliesOnceItHas() {
        var following = WatchFollowing()
        // The iPhone's `.start` for the standup is waiting for the microphone prompt; a stop arrives, and is held.
        XCTAssertFalse(following.stops(WatchStop(conversationID: standup), recording: nil), "Nothing to stop yet")
        let started = recording(standup, startedAt: 250, id: "rec-2")
        XCTAssertTrue(following.stops(WatchStop(), recording: started))
        XCTAssertTrue(following.stops(WatchStop(conversationID: standup), recording: started))
        XCTAssertFalse(following.stops(WatchStop(recordingID: "rec-1"), recording: started), "A stop for the recording before it")
        // A context that ended the standup arrived meanwhile: once the recording exists, the newest context stops it.
        XCTAssertEqual(following.received(context(nil, sentAt: 260), at: at(261), recording: nil, canStart: true), .none)
        XCTAssertEqual(following.follow(recording: started, canStart: true, at: at(262)), .stop)
        // Not knowing when the shared recording started, only a context that came after the recording stops it.
        XCTAssertEqual(following.follow(recording: recording(standup, began: 262), canStart: true, at: at(263)), .none)
        XCTAssertEqual(following.follow(recording: recording(standup, began: 260), canStart: true, at: at(263)), .stop)
    }

    func testItRemembersOnlyRecentConversationsAndSurvivesBeingStored() throws {
        var following = WatchFollowing()
        let conversations = (0..<(WatchFollowing.remembered + 5)).map { _ in UUID() }
        conversations.forEach { following.leave($0) }
        following.leave(nil, at: at(150))
        XCTAssertEqual(following.left, Array(conversations.suffix(WatchFollowing.remembered)))
        XCTAssertEqual(following.leftBefore, at(150))
        _ = following.received(context(shared(standup)), answered: true, at: at(201), recording: nil, canStart: false)
        let stored = try JSONEncoder().encode(following)
        XCTAssertEqual(try JSONDecoder().decode(WatchFollowing.self, from: stored), following)
    }
}
