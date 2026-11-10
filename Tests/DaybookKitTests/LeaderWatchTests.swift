import DaybookCore
@testable import DaybookKit
import XCTest

/// Following the device that asked this one to record, on evidence rather than silence (docs/multipoint.md, "Who stops
/// whom"), with a fake clock, fake presence, and fake levels.
final class LeaderWatchTests: XCTestCase {
    private let conversation = UUID()
    private let silent = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ minutes: Double) -> Date { silent.addingTimeInterval(minutes * 60) }

    private func leader(seen minutes: Double, recording: UUID?, expires: Double? = nil, name: String? = "Alex’s iPhone") -> KnownSyncDevice {
        KnownSyncDevice(id: "phone", deviceClass: .phone, displayName: name, lastSeen: at(minutes),
                        activity: SyncDeviceActivity(recordingConversationID: recording, since: at(-20),
                                                     expiresAt: at(expires ?? minutes + 25)))
    }

    private func verdict(_ minutes: Double, _ evidence: LeaderWatch.Evidence, heard: Double? = nil) -> LeaderWatch.Verdict {
        LeaderWatch.verdict(silentSince: silent, evidence: evidence, lastHeardSpeech: heard.map(at), recordingSince: at(-20),
                            now: at(minutes))
    }

    func testBehaviorConnectedOrBrieflyQuietIsJustFollowing() {
        XCTAssertEqual(LeaderWatch.verdict(silentSince: nil, evidence: .unknown, lastHeardSpeech: nil, recordingSince: at(-60), now: at(90)),
                       .following)
        XCTAssertEqual(verdict(1.5, .unknown), .following, "under two minutes isn't mentioned")
        XCTAssertEqual(verdict(1.5, .stopped), .following, "nor acted on")
    }

    func testBehaviorSilentForTwoMinutesSaysSoAndKeepsRecording() {
        XCTAssertEqual(verdict(2, .unknown, heard: 1), .outOfReach)
        XCTAssertEqual(verdict(29, .unknown), .outOfReach, "before half an hour, even in a quiet room")
    }

    func testBehaviorSilentHalfAnHourWhileTheRoomTalksKeepsRecording() {
        XCTAssertEqual(verdict(31, .unknown, heard: 30), .outOfReach)
        XCTAssertEqual(verdict(39, .unknown, heard: 30), .outOfReach, "nine minutes of quiet isn't ten")
    }

    func testBehaviorSilentHalfAnHourInAQuietRoomStops() {
        XCTAssertEqual(verdict(41, .unknown, heard: 30), .quietAndUnreachable)
        XCTAssertEqual(verdict(31, .unknown, heard: nil), .quietAndUnreachable, "never heard since it began, 51 minutes ago")
    }

    func testBehaviorPresenceSayingItStillRecordsKeepsRecordingWhateverTheRoom() {
        XCTAssertEqual(verdict(45, .recording, heard: nil), .outOfReach)
    }

    func testBehaviorPresenceSayingItStoppedStops() {
        XCTAssertEqual(verdict(3, .stopped), .leaderStopped)
    }

    func testBehaviorEvidenceFromPresence() {
        XCTAssertEqual(LeaderWatch.evidence(nil, conversation: conversation, silentSince: silent, now: at(5)), .unknown)
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: -5, recording: conversation), conversation: conversation, silentSince: silent, now: at(5)),
                       .recording, "written before the link went quiet, not expired: still recording")
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: -5, recording: conversation), conversation: conversation, silentSince: silent, now: at(30)),
                       .unknown, "expired: no word either way")
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: 10, recording: nil), conversation: conversation, silentSince: silent, now: at(12)),
                       .stopped, "written since, recording nothing")
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: 10, recording: UUID()), conversation: conversation, silentSince: silent, now: at(12)),
                       .stopped, "written since, recording something else")
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: 0.5, recording: nil), conversation: conversation, silentSince: silent, now: at(12)),
                       .unknown, "within a minute of going quiet: two clocks a little apart may have it before")
        XCTAssertEqual(LeaderWatch.evidence(leader(seen: 10, recording: nil, name: nil), conversation: conversation, silentSince: silent,
                                            now: at(12)),
                       .unknown, "a record that keeps its activity to itself says nothing")
    }

    func testWordsBothDevicesSay() {
        XCTAssertEqual(LeaderWatch.outOfReach("Alex’s iPhone", here: "this Mac"), "Alex’s iPhone is out of reach. This Mac keeps recording.")
        XCTAssertEqual(LeaderWatch.outOfReach("Studio Mac", here: "this iPhone"), "Studio Mac is out of reach. This iPhone keeps recording.")
        XCTAssertEqual(LeaderWatch.leaderStopped("Studio Mac", here: "this iPhone"), "Studio Mac stopped recording, so this iPhone stopped too.")
        XCTAssertEqual(LeaderWatch.stoppedUnreachable("Alex’s iPhone", here: "this Mac"),
                       "Alex’s iPhone couldn’t be reached for 30 minutes and the room was quiet, so this Mac stopped recording.")
    }
}
