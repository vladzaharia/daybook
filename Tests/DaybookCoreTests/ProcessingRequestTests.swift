import DaybookCore
import Foundation
import XCTest

/// Requests the iPhone writes and Macs claim: every transition, and merging copies from devices
/// that changed them independently.
final class ProcessingRequestTests: XCTestCase {
    private let phone = ProcessingRequest.Device(id: "phone", name: "Alex’s iPhone")
    private let studio = ProcessingRequest.Device(id: "studio", name: "Mac Studio")
    private let laptop = ProcessingRequest.Device(id: "laptop", name: "MacBook Pro")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func request(_ mode: ProcessingRequest.Mode = .newAudio) -> ProcessingRequest {
        ProcessingRequest(meetingID: UUID(), mode: mode, requestedBy: phone, createdAt: start)
    }

    // MARK: Transitions

    func testANewRequestIsOpenUnclaimedAndClaimableByAnyDevice() {
        let request = request()
        XCTAssertTrue(request.isOpen)
        XCTAssertNil(request.activeClaim(at: at(1)))
        XCTAssertTrue(request.isClaimable(by: studio, at: at(1)))
        XCTAssertTrue(request.isClaimable(by: laptop, at: at(1)))
    }

    func testAClaimHoldsUntilItsLeaseRunsOut() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(10), lease: 60))
        XCTAssertEqual(claimed.claim?.device, studio)
        XCTAssertEqual(claimed.claim?.claimedAt, at(10))
        XCTAssertEqual(claimed.claim?.expiresAt, at(70))
        XCTAssertTrue(claimed.isClaimed(by: studio, at: at(69)))
        XCTAssertNil(claimed.claimed(by: laptop, at: at(69)), "Another Mac can't take a live claim")
        XCTAssertFalse(claimed.isClaimable(by: laptop, at: at(69)))
        XCTAssertTrue(claimed.isClaimable(by: laptop, at: at(70)), "Expired claims are reclaimable")
    }

    func testTakingOverAnExpiredClaimStartsAStrictlyNewerOne() throws {
        let first = try XCTUnwrap(request().claimed(by: studio, at: at(100), lease: 60))
        // The laptop's clock runs behind: its "now" is before the studio's claim started.
        let takeover = try XCTUnwrap(first.claimed(by: laptop, at: at(200), lease: 60))
        XCTAssertEqual(takeover.claim?.device, laptop)
        let skewed = try XCTUnwrap(first.claimed(by: laptop, at: at(50).addingTimeInterval(600), lease: 60))
        XCTAssertGreaterThan(skewed.claim!.claimedAt, first.claim!.claimedAt)
        XCTAssertEqual(ProcessingRequest.merged([first], [takeover])?.first?.claim?.device, laptop, "The takeover wins the merge")
    }

    func testClaimingAgainByTheHolderOnlyExtendsTheLease() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 60))
        let again = try XCTUnwrap(claimed.claimed(by: studio, at: at(30), lease: 60))
        XCTAssertEqual(again.claim?.claimedAt, at(0))
        XCTAssertEqual(again.claim?.heartbeat, at(30))
        XCTAssertEqual(again.claim?.expiresAt, at(90))
    }

    func testRenewalExtendsTheLeaseAndReportsProgress() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 60))
        let renewed = try XCTUnwrap(claimed.renewed(by: studio, at: at(45), lease: 60, stage: .identifyingSpeakers, fraction: 0.4))
        XCTAssertEqual(renewed.claim?.heartbeat, at(45))
        XCTAssertEqual(renewed.claim?.expiresAt, at(105))
        XCTAssertEqual(renewed.claim?.stage, .identifyingSpeakers)
        XCTAssertEqual(renewed.claim?.fraction, 0.4)
        let keeps = try XCTUnwrap(renewed.renewed(by: studio, at: at(50), lease: 60))
        XCTAssertEqual(keeps.claim?.stage, .identifyingSpeakers, "A heartbeat without progress keeps the last report")
        XCTAssertEqual(try XCTUnwrap(renewed.renewed(by: studio, at: at(50), fraction: 7)).claim?.fraction, 1, "Progress is clamped")
        XCTAssertNil(claimed.renewed(by: laptop, at: at(45)), "Only the holder renews")
    }

    func testAMacWakingFromSleepRenewsItsExpiredClaimIfNobodyTookIt() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 60))
        let woke = try XCTUnwrap(claimed.renewed(by: studio, at: at(3_600), lease: 60))
        XCTAssertTrue(woke.isClaimed(by: studio, at: at(3_601)))
        let taken = try XCTUnwrap(claimed.claimed(by: laptop, at: at(3_000)))
        XCTAssertNil(taken.renewed(by: studio, at: at(3_600)), "Once another Mac took it over, the old holder can't renew")
    }

    func testAClockRunningAheadDoesNotTakeOverALiveClaim() throws {
        // Each Mac judges leases by its own clock, from when it first saw a heartbeat.
        let studioClock = ClaimObservations(), laptopClock = ClaimObservations()
        let skew: TimeInterval = 15 * 60
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 600, observations: studioClock))
        XCTAssertFalse(claimed.isClaimable(by: laptop, at: at(5 + skew), observations: laptopClock), "live, though the laptop's clock says it expired")
        XCTAssertNil(claimed.claimed(by: laptop, at: at(5 + skew), observations: laptopClock))
        // The studio renews; the heartbeat reaches the laptop two minutes later.
        let renewed = try XCTUnwrap(claimed.renewed(by: studio, at: at(300), lease: 600, observations: studioClock))
        let seen = at(300 + skew + 120)
        XCTAssertFalse(renewed.isClaimable(by: laptop, at: seen, observations: laptopClock))
        XCTAssertTrue(renewed.isClaimed(by: studio, at: at(899), observations: studioClock), "the holder's own view is unchanged")
        // With no newer heartbeat, it expires a full lease after the laptop first saw the last one.
        XCTAssertFalse(renewed.isClaimable(by: laptop, at: seen.addingTimeInterval(599), observations: laptopClock))
        XCTAssertTrue(renewed.isClaimable(by: laptop, at: seen.addingTimeInterval(600), observations: laptopClock))
        let takeover = try XCTUnwrap(renewed.claimed(by: laptop, at: seen.addingTimeInterval(600), observations: laptopClock))
        XCTAssertEqual(ProcessingRequest.merged([renewed], [takeover])?.first?.claim?.device, laptop)
    }

    func testAHeartbeatThatArrivesLateStillGetsItsWholeLease() throws {
        let studioClock = ClaimObservations(), laptopClock = ClaimObservations()
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 600, observations: studioClock))
        // Nine minutes in transit: by the timestamps it has a minute left; it gets ten from arrival.
        XCTAssertFalse(claimed.isClaimable(by: laptop, at: at(540), observations: laptopClock))
        XCTAssertFalse(claimed.isClaimable(by: laptop, at: at(1_100), observations: laptopClock))
        XCTAssertTrue(claimed.isClaimable(by: laptop, at: at(1_140), observations: laptopClock))
        // One whose own expiry is long past by this clock is stale at once, whenever it arrives.
        let fresh = ClaimObservations()
        XCTAssertTrue(claimed.isClaimable(by: laptop, at: at(600 + ClaimObservations.staleAfter), observations: fresh))
    }

    func testReleasingHandsTheRequestBackAtOnce() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 600))
        let released = try XCTUnwrap(claimed.released(by: studio, at: at(30)))
        XCTAssertNil(released.activeClaim(at: at(30)))
        XCTAssertTrue(released.isClaimable(by: laptop, at: at(30)))
        XCTAssertNil(claimed.released(by: laptop, at: at(30)))
        // The release is newer than the claim it ends, so it survives merging with the old copy.
        XCTAssertNil(ProcessingRequest.merged([claimed], [released])?.first?.activeClaim(at: at(30)))
    }

    func testExpiringDropsOnlyStaleClaims() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 60))
        XCTAssertNil(claimed.expired(at: at(59)), "A live claim isn't expired")
        let expired = try XCTUnwrap(claimed.expired(at: at(60)))
        XCTAssertNil(expired.claim)
        XCTAssertTrue(expired.isOpen)
        XCTAssertNil(request().expired(at: at(60)), "Nothing to expire")
        XCTAssertNil(ProcessingRequest.merged([claimed], [expired])?.first?.activeClaim(at: at(60)), "Merged, the stale claim is still free to take")
    }

    func testCompletingAndFailingAreFinal() throws {
        let claimed = try XCTUnwrap(request().claimed(by: studio, at: at(0), lease: 60))
        XCTAssertNil(claimed.completed(by: laptop, at: at(10)), "Not while another Mac holds a live claim")
        let done = try XCTUnwrap(claimed.completed(by: studio, at: at(20)))
        XCTAssertFalse(done.isOpen)
        XCTAssertEqual(done.outcome?.result, .completed)
        XCTAssertEqual(done.outcome?.device, studio)
        XCTAssertNil(done.claimed(by: laptop, at: at(1_000)), "A finished request is never claimed again")
        XCTAssertNil(done.failed(by: studio, at: at(30), reason: "Late"), "An outcome isn't replaced")
        XCTAssertNil(done.renewed(by: studio, at: at(30)))

        let failed = try XCTUnwrap(claimed.failed(by: studio, at: at(20), reason: "Download the speech model."))
        XCTAssertEqual(failed.outcome?.result, .failed)
        XCTAssertEqual(failed.outcome?.message, "Download the speech model.")
        XCTAssertNotNil(request().completed(by: laptop, at: at(5)), "An unclaimed request can be finished by any device")
        XCTAssertNotNil(claimed.completed(by: laptop, at: at(61)), "So can one whose claim expired")
    }

    // MARK: Merging

    func testMergeIsAUnionByIDThatIgnoresOrder() throws {
        let a = request(), b = request(.summaryOnly), c = request(.speakerRefresh)
        let left = [a, b], right = [c, a]
        let merged = try XCTUnwrap(ProcessingRequest.merged(left, right))
        XCTAssertEqual(Set(merged.map(\.id)), [a.id, b.id, c.id])
        XCTAssertEqual(merged, ProcessingRequest.merged(right, left), "Both devices reach the same list")
        XCTAssertNil(ProcessingRequest.merged(nil, nil))
        XCTAssertEqual(ProcessingRequest.merged([a], nil), [a])
    }

    func testTheNewestClaimWinsAndAFinishedOutcomeBeatsAnyClaim() throws {
        let base = request()
        let studioClaim = try XCTUnwrap(base.claimed(by: studio, at: at(0), lease: 60))
        let laptopClaim = try XCTUnwrap(base.claimed(by: laptop, at: at(5), lease: 60))
        XCTAssertEqual(ProcessingRequest.merged([studioClaim], [laptopClaim])?.first?.claim?.device, laptop)
        XCTAssertEqual(ProcessingRequest.merged([laptopClaim], [studioClaim])?.first?.claim?.device, laptop)
        // The loser learns it lost: it no longer holds the request after merging.
        let merged = try XCTUnwrap(ProcessingRequest.merged([studioClaim], [laptopClaim])?.first)
        XCTAssertFalse(merged.isClaimed(by: studio, at: at(6)))

        let renewed = try XCTUnwrap(studioClaim.renewed(by: studio, at: at(30), stage: .summarizing, fraction: 0.9))
        XCTAssertEqual(ProcessingRequest.merged([studioClaim], [renewed])?.first?.claim?.stage, .summarizing, "The later heartbeat wins")

        let done = try XCTUnwrap(studioClaim.completed(by: studio, at: at(40)))
        let result = try XCTUnwrap(ProcessingRequest.merged([done], [laptopClaim])?.first)
        XCTAssertEqual(result.outcome?.result, .completed)
        XCTAssertFalse(result.isOpen)
    }

    func testTwoOutcomesResolveTheSameWayOnEveryDevice() throws {
        let base = request()
        let failed = try XCTUnwrap(base.failed(by: studio, at: at(10), reason: "Out of memory"))
        let completed = try XCTUnwrap(base.completed(by: laptop, at: at(20)))
        XCTAssertEqual(ProcessingRequest.merged([failed], [completed]), ProcessingRequest.merged([completed], [failed]))
        XCTAssertEqual(ProcessingRequest.merged([failed], [completed])?.first?.outcome?.result, .completed, "The later outcome")
    }

    func testMeetingMergeKeepsEveryDevicesRequests() throws {
        var base = Meeting(title: "Standup")
        base.processingRequests = nil
        var phoneCopy = base, macCopy = base
        let asked = ProcessingRequest(meetingID: base.id, mode: .newAudio, requestedBy: phone, createdAt: start)
        phoneCopy.upsertProcessingRequest(asked)
        // The Mac already had the request from an earlier sync and claimed it.
        let claimed = try XCTUnwrap(asked.claimed(by: studio, at: at(5)))
        macCopy.upsertProcessingRequest(claimed)
        let again = ProcessingRequest(meetingID: base.id, mode: .summaryOnly, requestedBy: phone, createdAt: at(6))
        phoneCopy.upsertProcessingRequest(again)

        let merged = MeetingMerge.merge(base: base, local: phoneCopy, remote: macCopy)
        let requests = try XCTUnwrap(merged.meeting.processingRequests)
        XCTAssertEqual(requests.map(\.id), [asked.id, again.id])
        XCTAssertEqual(requests.first?.claim?.device, studio)
        XCTAssertTrue(merged.warnings.isEmpty, "Requests merge without conflicts")
        XCTAssertEqual(merged.meeting.openProcessingRequests.count, 2)
    }

    func testRequestsAreAnAdditiveField() throws {
        let meeting = Meeting(title: "Before requests existed")
        let encoded = try JSONEncoder().encode(meeting)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("processingRequests"), "No field until the first request")
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: encoded).processingRequests)

        var asked = meeting
        let claimed = try XCTUnwrap(ProcessingRequest(meetingID: meeting.id, mode: .fullRetranscription, templateID: "planning",
                                                      requestedBy: phone, createdAt: start).claimed(by: studio, at: at(1)))
        asked.upsertProcessingRequest(claimed)
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(asked))
        XCTAssertEqual(restored.processingRequests, [claimed])
    }
}
