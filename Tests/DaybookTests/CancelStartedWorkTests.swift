import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Cancel for work that has started (`AppState.canCancelStarted`, `cancelStarted`): running work that carries no request
/// stops without being kept paused, paused work lets go of this Mac's own requests, and work that carries another device's
/// request is only ever paused, never dropped or left for this Mac to claim again. Fake inference, temporary libraries.
@MainActor
final class CancelStartedWorkTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: true)
        rig.state.requestTiming = RequestTiming(lease: 600, renewInterval: .milliseconds(40))
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    private func meeting(_ rig: MultiSourceRig, _ id: UUID) throws -> Meeting { try XCTUnwrap(rig.meeting(id)) }

    func testBehaviorRunningOwnWorkCancelsWithoutBeingKeptPaused() async throws {
        let rig = try await rig()
        let audio = try rig.audio("own.wav", frequency: 300)
        let id = try await rig.macConversation("Own", at: Date(), seconds: 0.5, audio: audio)
        try rig.inference.block(audio)
        rig.state.processor.enqueue(id)
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        XCTAssertTrue(rig.state.canCancelStarted(try meeting(rig, id)))

        rig.state.cancelStarted(id)
        try await waitUntil("it to stop") { rig.state.processor.queue.runningID == nil }
        XCTAssertFalse(rig.state.processor.queue.paused.contains(id), "Cancelled, not paused")
        XCTAssertTrue(rig.state.processor.queue.cancelledRunning.isEmpty, "Used up by the run it ended")
        try rig.inference.unblock(audio)
    }

    func testBehaviorACancelThatNeverReachedARunDoesNotTurnALaterPauseIntoOne() async throws {
        let rig = try await rig()
        let audio = try rig.audio("stale.wav", frequency: 320)
        let id = try await rig.macConversation("Stale", at: Date(), seconds: 0.5, audio: audio)
        rig.state.processor.queue.cancelledRunning.insert(id)
        try rig.inference.block(audio)
        rig.state.processor.enqueue(id)
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        XCTAssertTrue(rig.state.processor.queue.cancelledRunning.isEmpty, "Starting a run clears it")

        rig.state.pauseProcessing(id)
        try await waitUntil("it to pause") { rig.state.processor.queue.runningID == nil }
        XCTAssertTrue(rig.state.processor.queue.paused.contains(id), "A Pause is a Pause")
        try rig.inference.unblock(audio)
    }

    func testBehaviorRunningWorkThatCarriesARequestCannotBeCancelledOnlyPaused() async throws {
        let rig = try await rig()
        let audio = try rig.audio("carried.wav", frequency: 340)
        let id = try await rig.waitingConversation("Carried", audio: audio, script: [(0, "Planning.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        try rig.inference.block(audio)
        rig.state.pickUpRequests()
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        XCTAssertFalse(rig.state.canCancelStarted(try meeting(rig, id)))

        rig.state.cancelStarted(id)
        XCTAssertEqual(rig.state.processor.queue.runningID, id, "Cancel does nothing here")
        XCTAssertTrue(rig.state.processor.queue.cancelledRunning.isEmpty)
        rig.state.pauseProcessing(id)
        try await waitUntil("it to pause") { rig.state.processor.queue.runningID == nil }
        XCTAssertTrue(rig.state.processor.queue.paused.contains(id))
        try rig.inference.unblock(audio)
    }

    func testBehaviorPausedOwnWorkLetsGo() async throws {
        let rig = try await rig()
        let audio = try rig.audio("paused.wav", frequency: 360)
        let id = try await rig.macConversation("Paused", at: Date(), seconds: 0.5, audio: audio)
        try rig.inference.block(audio)
        rig.state.processor.enqueue(id)
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        rig.state.pauseProcessing(id)
        try await waitUntil("it to pause") { rig.state.processor.queue.paused.contains(id) && rig.state.processor.queue.runningID == nil }
        XCTAssertTrue(rig.state.canCancelStarted(try meeting(rig, id)))

        rig.state.cancelStarted(id)
        XCTAssertFalse(rig.state.processor.queue.paused.contains(id))
        try rig.inference.unblock(audio)
    }

    func testBehaviorPausedWorkWithAnotherDevicesRequestKeepsItAndStaysPaused() async throws {
        let rig = try await rig()
        let audio = try rig.audio("theirs.wav", frequency: 380)
        let id = try await rig.waitingConversation("Theirs", audio: audio, script: [(0, "Planning.")])
        rig.state.library.requestProcessing(id, mode: .newAudio, by: .phone)
        try rig.inference.block(audio)
        rig.state.pickUpRequests()
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        rig.state.pauseProcessing(id)
        try await waitUntil("it to pause") { rig.state.processor.queue.paused.contains(id) && rig.state.processor.queue.runningID == nil }
        XCTAssertFalse(rig.state.canCancelStarted(try meeting(rig, id)))

        rig.state.cancelStarted(id)
        XCTAssertTrue(rig.state.processor.queue.paused.contains(id), "Not left for this Mac to claim again")
        XCTAssertEqual(try meeting(rig, id).openProcessingRequests.count, 1, "The other device's request isn't dropped")
        try rig.inference.unblock(audio)
    }

    func testBehaviorPausedWorkWithOnlyThisMacsRequestWithdrawsIt() async throws {
        let rig = try await rig()
        let audio = try rig.audio("mine.wav", frequency: 400)
        let id = try await rig.waitingConversation("Mine", audio: audio, script: [(0, "Planning.")])
        rig.state.library.requestProcessing(id, mode: .newAudio)
        try rig.inference.block(audio)
        rig.state.pickUpRequests()
        try await waitUntil("it to run") { rig.inference.isWaiting(on: audio) }
        rig.state.pauseProcessing(id)
        try await waitUntil("it to pause") { rig.state.processor.queue.paused.contains(id) && rig.state.processor.queue.runningID == nil }
        XCTAssertTrue(rig.state.canCancelStarted(try meeting(rig, id)))

        rig.state.cancelStarted(id)
        XCTAssertFalse(rig.state.processor.queue.paused.contains(id))
        XCTAssertTrue(try meeting(rig, id).openProcessingRequests.isEmpty, "This Mac's own request is withdrawn")
        try rig.inference.unblock(audio)
    }
}
