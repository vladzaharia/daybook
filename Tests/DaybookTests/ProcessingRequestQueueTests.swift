import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Requests other devices make, carried out by this Mac's queue: claimed with a lease, renewed while
/// they run, completed or failed, given back on pause and cancel, taken over when stale, never run
/// while another Mac holds them, and left alone when this Mac lacks the models. Fake inference,
/// temporary libraries, and a temporary sync folder; no models, no microphone.
@MainActor
final class ProcessingRequestQueueTests: XCTestCase {
    func testBackgroundPhotosFinishBeforeAQueuedSummaryStarts() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        let audio = try rig.audio("photo-queue.wav", frequency: 440)
        try rig.inference.script(audio, [(0, "Plan the launch.")])
        let id = try await rig.macConversation("Planning", at: Date(), seconds: 5, audio: audio)
        let bytes = try XCTUnwrap(PhotoDemo.jpeg(PhotoDemo.board(["LAUNCH PLAN"])))
        await rig.state.library.acquireLock()
        let photo = try await rig.state.library.addPhoto(data: bytes, to: id)
        rig.state.library.releaseLock()
        rig.inference.blockPhotos(true)
        rig.state.readPhotosWhenIdle(id)
        try await waitUntil("photo reading") { rig.inference.readingPhotos }
        rig.state.enqueue(id)
        XCTAssertNil(rig.state.processingID)
        XCTAssertEqual(rig.state.queuedIDs, [id])
        XCTAssertTrue(rig.inference.summarized.isEmpty)
        rig.inference.blockPhotos(false)
        try await waitUntil("photo reading to finish") { rig.state.readingPhotoID == nil }
        try await waitUntil("the summary") { rig.inference.summarized.count == 1 }
        try await rig.processed()
        XCTAssertNotNil(rig.meeting(id)?.photo(photo.id)?.analysis)
        XCTAssertEqual(rig.inference.summarized.count, 1)
        XCTAssertEqual(rig.meeting(id)?.status, .ready, rig.meeting(id)?.errorMessage ?? "")
        await rig.tearDown()
    }
    private func rig(models: Bool = true) async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: models)
        rig.state.requestTiming = RequestTiming(lease: 600, renewInterval: .milliseconds(40))
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    private func request(_ rig: MultiSourceRig, _ id: UUID) -> ProcessingRequest? { rig.meeting(id)?.processingRequests?.first }

    /// Waits until every request on the conversation has an outcome, then for the queue to be idle.
    /// (An idle queue alone also holds before queued work has started.)
    private func answered(_ rig: MultiSourceRig, _ id: UUID) async throws {
        try await waitUntil("\(rig.meeting(id)?.title ?? "the conversation")'s requests to be answered") {
            rig.meeting(id)?.processingRequests?.allSatisfy { $0.outcome != nil } == true
        }
        try await rig.processed()
    }

    func testClaimsRenewsAndCompletesARequestFromThePhone() async throws {
        let rig = try await rig()
        let audio = try rig.audio("phone.wav", frequency: 440)
        let id = try await rig.waitingConversation("From the phone", audio: audio, script: [(0, "Shipping the beta on Friday.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        try rig.inference.block(audio)
        let me = rig.state.library.thisDevice

        rig.state.pickUpRequests()
        try await waitUntil("the job to start") { rig.inference.isWaiting(on: audio) }
        let claimed = try XCTUnwrap(request(rig, id)?.claim)
        XCTAssertEqual(claimed.device, me)
        XCTAssertEqual(claimed.expiresAt.timeIntervalSince(claimed.claimedAt), 600, accuracy: 1, "Claimed with the lease")
        XCTAssertEqual(rig.state.runningJob?.requestID, request(rig, id)?.id)
        XCTAssertEqual(rig.state.requestOrigin(for: try XCTUnwrap(rig.meeting(id))), "Requested from Pocket iPhone")
        // What the phone sees through sync: this Mac is transcribing it.
        if case .processing(let progress) = ProcessingStatus(try XCTUnwrap(rig.meeting(id))) {
            XCTAssertEqual(progress.device, me)
            XCTAssertEqual(progress.stage, .transcribing)
        } else { XCTFail("The phone should see it processing") }

        try await waitUntil("a heartbeat") { (self.request(rig, id)?.claim?.heartbeat ?? .distantPast) > claimed.heartbeat }
        let renewed = try XCTUnwrap(request(rig, id)?.claim)
        XCTAssertEqual(renewed.claimedAt, claimed.claimedAt, "Renewing keeps the claim")
        XCTAssertGreaterThan(renewed.expiresAt, claimed.expiresAt)
        XCTAssertEqual(renewed.stage, .transcribing)
        XCTAssertNotNil(renewed.fraction)

        try rig.inference.unblock(audio)
        try await answered(rig, id)
        let done = try XCTUnwrap(request(rig, id))
        XCTAssertEqual(done.outcome?.result, .completed)
        XCTAssertEqual(done.outcome?.device, me)
        XCTAssertEqual(ProcessingStatus(try XCTUnwrap(rig.meeting(id))), .done)
        XCTAssertEqual(rig.inference.transcribed.count, 1)
    }

    func testAJobForTheSameConversationCarriesTheRequestAndCompletesOthersItSatisfied() async throws {
        let rig = try await rig()
        let audio = try rig.audio("synced.wav", frequency: 330)
        let id = try await rig.waitingConversation("Synced", audio: audio, script: [(0, "Budget review.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        rig.state.library.requestProcessing(id, mode: .summaryOnly, by: .phone)

        // Queued on this Mac for its own reasons (new audio from sync): it takes the request on.
        rig.state.enqueue(id)
        try await answered(rig, id)
        let requests = try XCTUnwrap(rig.meeting(id)?.processingRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.outcome?.result == .completed }, "Both are done: one carried, one satisfied")
        XCTAssertEqual(rig.inference.summarized.count, 1, "Summarized once")
    }

    func testAFailedRequestsReasonSurfacesInProcessingStatus() async throws {
        let rig = try await rig()
        let audio = try rig.audio("silent.wav", frequency: 220)
        // Nothing is said in it, so there's nothing to summarize.
        let id = try await rig.waitingConversation("Silence", audio: audio, script: [])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)

        rig.state.pickUpRequests()
        try await answered(rig, id)
        let failed = try XCTUnwrap(request(rig, id))
        XCTAssertEqual(failed.outcome?.result, .failed)
        let reason = try XCTUnwrap(failed.outcome?.message)
        XCTAssertEqual(reason, AppError.noSpeech.localizedDescription)

        // The phone (no local queue) and this Mac read the same failure, with the Mac's reason.
        let meeting = try XCTUnwrap(rig.meeting(id))
        guard case .failed(let failure) = ProcessingStatus(meeting) else { return XCTFail("Should read as failed") }
        XCTAssertEqual(failure.reason, reason)
        XCTAssertEqual(failure.device, rig.state.library.thisDevice)
        XCTAssertEqual(failure.request?.id, failed.id)
        guard case .failed(let local) = rig.state.processingStatus(for: meeting) else { return XCTFail("The Mac too") }
        XCTAssertEqual(local.reason, reason)
    }

    func testPauseAndCancelGiveTheClaimBack() async throws {
        let rig = try await rig()
        let audio = try rig.audio("long.wav", frequency: 500)
        let id = try await rig.waitingConversation("Long", audio: audio, script: [(0, "Quarterly planning.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        try rig.inference.block(audio)
        let me = rig.state.library.thisDevice

        rig.state.pickUpRequests()
        try await waitUntil("the job to start") { rig.inference.isWaiting(on: audio) }
        XCTAssertTrue(try XCTUnwrap(request(rig, id)).isClaimed(by: me, at: Date()))

        rig.state.pauseProcessing(id)
        try await waitUntil("the pause") { rig.state.processingID == nil }
        let paused = try XCTUnwrap(request(rig, id))
        XCTAssertTrue(paused.isOpen)
        XCTAssertNil(paused.activeClaim(at: Date()), "Given back: any Mac may take it")
        XCTAssertTrue(rig.state.pausedIDs.contains(id))
        rig.state.pickUpRequests()
        XCTAssertFalse(rig.state.queuedIDs.contains(id), "Paused here: not claimed again until resumed")

        // Resume claims it again; Cancel gives it back again.
        rig.state.enqueue(id)
        try await waitUntil("the job to run again") { rig.inference.isWaiting(on: audio) }
        XCTAssertTrue(try XCTUnwrap(request(rig, id)).isClaimed(by: me, at: Date()))
        rig.state.cancelProcessing()
        try await waitUntil("the cancel") { rig.state.processingID == nil }
        XCTAssertNil(try XCTUnwrap(request(rig, id)).activeClaim(at: Date()))
        XCTAssertTrue(try XCTUnwrap(request(rig, id)).isOpen, "Cancelling isn't failing")
        try rig.inference.unblock(audio)
    }

    func testAStaleClaimIsTakenOverAndALiveOneIsLeftAlone() async throws {
        let rig = try await rig()
        let staleAudio = try rig.audio("stale.wav", frequency: 610)
        let liveAudio = try rig.audio("live.wav", frequency: 720)
        let stale = try await rig.waitingConversation("Stale", audio: staleAudio, script: [(0, "Hiring plan.")])
        let live = try await rig.waitingConversation("Live", audio: liveAudio, script: [(0, "Roadmap.")])
        let gone = ProcessingRequest.Device(id: "vanished-mac", name: "Old Mac")
        let busy = ProcessingRequest.Device(id: "busy-mac", name: "Studio Mac")
        let past = Date().addingTimeInterval(-3600)
        rig.state.update(stale) { $0.upsertProcessingRequest(ProcessingRequest(meetingID: stale, mode: .newAudio, requestedBy: .phone, createdAt: past,
            claim: .init(device: gone, claimedAt: past, heartbeat: past, expiresAt: past.addingTimeInterval(600)))) }
        rig.state.update(live) { $0.upsertProcessingRequest(ProcessingRequest(meetingID: live, mode: .newAudio, requestedBy: .phone, createdAt: past,
            claim: .init(device: busy, claimedAt: Date(), heartbeat: Date(), expiresAt: Date().addingTimeInterval(600)))) }

        rig.state.pickUpRequests()
        try await answered(rig, stale)
        let takenOver = try XCTUnwrap(request(rig, stale))
        XCTAssertEqual(takenOver.outcome?.result, .completed)
        XCTAssertEqual(takenOver.outcome?.device, rig.state.library.thisDevice, "This Mac took over the stale claim")
        XCTAssertGreaterThan(try XCTUnwrap(takenOver.claim).claimedAt, past, "With a newer claim, which wins every merge")
        let held = try XCTUnwrap(request(rig, live))
        XCTAssertTrue(held.isOpen, "Another Mac holds it")
        XCTAssertEqual(held.claim?.device, busy)
        XCTAssertEqual(rig.inference.transcribed.count, 1, "Only the stale one ran here")
        // Queueing it by hand on this Mac doesn't take it from the Mac that holds it.
        rig.state.enqueue(live)
        try await rig.processed()
        XCTAssertEqual(request(rig, live)?.claim?.device, busy)
    }

    func testMissingModelsLeaveTheRequestUnclaimedAndPresenceSaysSo() async throws {
        let rig = try await rig(models: false)
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let phone = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { phone.tearDown() }
        let audio = try rig.audio("phone-models.wav", frequency: 880)
        try rig.inference.script(audio, [(0, "Notes from the walk.")])
        let id = try await phone.file(audio, recordingID: UUID(), start: Date().addingTimeInterval(-60), duration: 0.5)
        await phone.synchronize()

        await rig.state.synchronizeLibrary()
        let waiting = try XCTUnwrap(request(rig, id))
        XCTAssertTrue(waiting.isOpen)
        XCTAssertNil(waiting.claim, "No models: left for a Mac that has them")
        XCTAssertFalse(rig.state.queuedIDs.contains(id))
        XCTAssertEqual(rig.state.sync.replica.device?.canProcess, false)
        await phone.synchronize()
        let seen = await phone.sync.knownDevices()
        let mac = try XCTUnwrap(seen.first { $0.id == rig.state.sync.deviceID })
        XCTAssertEqual(mac.deviceClass, .mac)
        XCTAssertEqual(mac.canProcess, false)
        // The phone reads it plainly: waiting for a Mac, and no Mac that can process has been seen.
        await phone.synchronize()
        XCTAssertEqual(phone.library.processingStatus(for: id), .requested(.device(waiting)))
        XCTAssertNil(seen.latestProcessor)

        // Models arrive: presence says so, and the request is claimed and run.
        rig.state.installedModels = [rig.state.transcriptionModel, rig.state.summaryModel, rig.state.processingPreferences.speakerModelID]
        XCTAssertEqual(rig.state.sync.replica.device?.canProcess, true)
        try await answered(rig, id)
        XCTAssertEqual(request(rig, id)?.outcome?.result, .completed)
        await rig.state.synchronizeLibrary()
        await phone.synchronize()
        let after = await phone.sync.knownDevices()
        XCTAssertEqual(after.first { $0.id == rig.state.sync.deviceID }?.canProcess, true)
        XCTAssertEqual(after.latestProcessor?.id, rig.state.sync.deviceID)
        XCTAssertEqual(phone.library.processingStatus(for: id), .done, "Done on the phone too")
    }

    func testTwoMacsRacingForOneRequestOnlyOneRunsIt() async throws {
        let a = try await rig(), b = try await rig()
        let cloud = try temporaryFolder("Cloud")
        try a.connectSync(cloud); try b.connectSync(cloud)
        let phone = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { phone.tearDown() }
        let audio = try a.audio("race.wav", frequency: 990)
        try a.inference.script(audio, [(0, "Who runs this?")]); try b.inference.script(audio, [(0, "Who runs this?")])
        try a.inference.block(audio); try b.inference.block(audio)
        let id = try await phone.file(audio, recordingID: UUID(), start: Date().addingTimeInterval(-60), duration: 0.5)
        await phone.synchronize()

        // Both Macs see the request before either has published a claim: both claim and start.
        await a.state.synchronizeLibrary()
        try await waitUntil("Mac A to start") { a.inference.isWaiting(on: audio) }
        await b.state.synchronizeLibrary()
        try await waitUntil("Mac B to start") { b.inference.isWaiting(on: audio) }
        XCTAssertTrue(try XCTUnwrap(request(a, id)).isClaimed(by: a.state.library.thisDevice, at: Date()))
        XCTAssertTrue(try XCTUnwrap(request(b, id)).isClaimed(by: b.state.library.thisDevice, at: Date()))

        // Their claims meet in the sync folder. The newest claim wins on both; the other Mac stops.
        await a.state.synchronizeLibrary()
        await b.state.synchronizeLibrary()
        await a.state.synchronizeLibrary()
        try await waitUntil("Mac A to stop") { a.state.processingID == nil }
        XCTAssertEqual(request(a, id)?.claim?.device, b.state.library.thisDevice)
        XCTAssertFalse(a.state.pausedIDs.contains(id), "Losing a claim isn't a pause")
        XCTAssertTrue(request(a, id)?.isOpen == true, "Mac A neither completes nor fails it")

        try a.inference.unblock(audio); try b.inference.unblock(audio)
        try await answered(b, id)
        XCTAssertEqual(a.inference.transcribed, [], "Mac A never ran it to the end")
        XCTAssertEqual(b.inference.transcribed.count, 1)
        await b.state.synchronizeLibrary(); await a.state.synchronizeLibrary()
        XCTAssertEqual(request(a, id)?.outcome?.device, b.state.library.thisDevice)
        XCTAssertEqual(a.inference.transcribed, [], "Nor afterwards")
    }

    func testAMacNeverRunsARequestAnotherMacHolds() async throws {
        let a = try await rig(), b = try await rig()
        let cloud = try temporaryFolder("Cloud")
        try a.connectSync(cloud); try b.connectSync(cloud)
        let phone = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { phone.tearDown() }
        let audio = try a.audio("held.wav", frequency: 1_100)
        try a.inference.script(audio, [(0, "One Mac only.")]); try b.inference.script(audio, [(0, "One Mac only.")])
        try a.inference.block(audio)
        let id = try await phone.file(audio, recordingID: UUID(), start: Date().addingTimeInterval(-60), duration: 0.5)
        await phone.synchronize()

        await a.state.synchronizeLibrary()
        try await waitUntil("Mac A to start") { a.inference.isWaiting(on: audio) }
        // A pass during the work publishes Mac A's claim.
        await a.state.synchronizeLibrary()
        await b.state.synchronizeLibrary()
        XCTAssertFalse(b.state.queuedIDs.contains(id))
        XCTAssertNil(b.state.processingID, "Mac B sees Mac A's claim and leaves it")
        if case .processing(let progress) = b.state.processingStatus(for: try XCTUnwrap(b.meeting(id))) {
            XCTAssertEqual(progress.device, a.state.library.thisDevice)
        } else { XCTFail("Mac B shows it processing on Mac A") }

        try a.inference.unblock(audio)
        try await answered(a, id)
        XCTAssertEqual(b.inference.transcribed, [])
        XCTAssertEqual(request(a, id)?.outcome?.result, .completed)
    }

    func testAClaimSurvivesSleepUnlessAnotherMacTookItOver() async throws {
        let rig = try await rig()
        rig.state.requestTiming = RequestTiming(lease: 600, renewInterval: .seconds(3600))
        let audio = try rig.audio("sleep.wav", frequency: 1_210)
        let id = try await rig.waitingConversation("Sleep", audio: audio, script: [(0, "Before the lid closed.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        try rig.inference.block(audio)
        rig.state.pickUpRequests()
        try await waitUntil("the job to start") { rig.inference.isWaiting(on: audio) }
        let claimed = try XCTUnwrap(request(rig, id)?.claim)

        // Asleep past the lease, and nobody took it: waking renews the same claim.
        var asleep = try XCTUnwrap(request(rig, id))
        var stale = try XCTUnwrap(asleep.claim)
        stale.heartbeat = Date().addingTimeInterval(-1_200)
        stale.expiresAt = Date().addingTimeInterval(-600)
        asleep.claim = stale
        rig.state.update(id) { $0.upsertProcessingRequest(asleep) }
        XCTAssertEqual(request(rig, id)?.claim, stale)
        await rig.state.systemDidWake()
        let renewed = try XCTUnwrap(request(rig, id)?.claim)
        XCTAssertEqual(renewed.claimedAt, claimed.claimedAt)
        XCTAssertGreaterThan(renewed.expiresAt, Date())
        XCTAssertEqual(rig.state.processingID, id)

        // Another Mac took it over while this one slept: waking stops the work, without pausing it.
        let other = ProcessingRequest.Device(id: "other-mac", name: "Studio Mac")
        var takenOver = try XCTUnwrap(request(rig, id))
        takenOver.claim = .init(device: other, claimedAt: Date(), heartbeat: Date(), expiresAt: Date().addingTimeInterval(600))
        rig.state.update(id) { $0.upsertProcessingRequest(takenOver) }
        XCTAssertEqual(request(rig, id)?.claim?.device, other)
        await rig.state.systemDidWake()
        try await waitUntil("the job to stop") { rig.state.processingID == nil }
        XCTAssertFalse(rig.state.pausedIDs.contains(id))
        XCTAssertEqual(request(rig, id)?.claim?.device, other)
        XCTAssertTrue(request(rig, id)?.isOpen == true)
        try rig.inference.unblock(audio)
    }

    func testClaimsLeftByAQuitOrCrashRunAgainAtLaunchOrGoBackWithoutModels() async throws {
        let rig = try await rig()
        let audio = try rig.audio("crash.wav", frequency: 1_320)
        let id = try await rig.waitingConversation("Crash", audio: audio, script: [(0, "Where were we?")])
        let me = rig.state.library.thisDevice
        // As the library was when this Mac stopped mid-job: its own live claim.
        rig.state.update(id) { $0.upsertProcessingRequest(ProcessingRequest(meetingID: id, mode: .newAudio, requestedBy: .phone,
            claim: .init(device: me, claimedAt: Date(), heartbeat: Date(), expiresAt: Date().addingTimeInterval(600)))) }
        await rig.state.flush()

        // Relaunched without the models: the claim goes back for another Mac.
        let relaunched = AppState(libraryURL: rig.root, defaults: rig.defaults)
        await relaunched.initialize()
        XCTAssertEqual(relaunched.library.thisDevice, me, "The same replica")
        XCTAssertNil(relaunched.meetings.first { $0.id == id }?.processingRequests?.first?.activeClaim(at: Date()))

        // With them, it runs again and finishes.
        relaunched.sources.inference = rig.inference
        relaunched.sources.alignAudio = { _, _, _, _ in nil }
        relaunched.installedModels = [relaunched.transcriptionModel, relaunched.summaryModel, relaunched.processingPreferences.speakerModelID]
        try await waitUntil("the job to finish") {
            relaunched.meetings.first { $0.id == id }?.processingRequests?.first?.outcome != nil && relaunched.processingID == nil
        }
        XCTAssertEqual(relaunched.meetings.first { $0.id == id }?.processingRequests?.first?.outcome?.result, .completed)
        await relaunched.flush()
    }
}
