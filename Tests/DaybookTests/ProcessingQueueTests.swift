import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// This Mac's processing queue across a quit, a restart, or a crash (`ProcessingQueue`, owed work): what it was doing
/// or had waiting is queued again at the next launch, while what the person paused, what failed, and what's done stay
/// as they are. A fake inference engine, synthetic audio, temporary libraries.
@MainActor
final class ProcessingQueueTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: true)
        addTeardownBlock { await rig.tearDown() }
        return rig
    }

    /// The same library opened again, as the next launch opens it: without models, so nothing runs and what's queued
    /// waits for them. `after` is the launch before (the rig's own by default); unless the test quit it, it crashed.
    private func relaunch(_ rig: MultiSourceRig, after earlier: AppState? = nil) async -> AppState {
        await (earlier ?? rig.state).flush()
        ProcessingQueue.drainWrites()
        let next = AppState(libraryURL: rig.root, defaults: rig.defaults)
        await next.initialize()
        addTeardownBlock { await next.flush() }
        return next
    }

    func testBehaviorWorkAQuitInterruptedIsQueuedAgainAtTheNextLaunch() async throws {
        let rig = try await rig()
        let state = rig.state
        let start = Date()
        let first = try await rig.macConversation("Design review", at: start, seconds: 0.5, audio: rig.audio("one.wav", frequency: 300))
        let second = try await rig.macConversation("Standup", at: start, seconds: 0.5, audio: rig.audio("two.wav", frequency: 500))
        let firstAudio = rig.root.appendingPathComponent("one.wav")
        try rig.inference.block(firstAudio)
        state.enqueue(first)
        state.enqueue(second)
        try await waitUntil("the first to be transcribing") { rig.inference.isWaiting(on: firstAudio) }
        XCTAssertEqual(state.queuedIDs, [second])

        // Quitting stops the running job and empties the queue, and keeps both owed.
        state.cancelProcessing()
        try await waitUntil("the job to stop") { state.processingID == nil && state.processingTask == nil }
        XCTAssertTrue(state.queue.isOwed(first) && state.queue.isOwed(second))

        let next = await relaunch(rig)
        XCTAssertEqual(next.awaitingModels, [first, second], "Both are queued again, waiting for this Mac's models")
        guard case .requested(.models) = next.processingStatus(for: try XCTUnwrap(next.meetings.first { $0.id == first })) else {
            return XCTFail("Waiting for models, not 'Not transcribed yet'")
        }
        try rig.inference.unblock(firstAudio)
    }

    /// The models arrive in a relaunched `state`, as when a download finishes: what waited for them starts, on the rig's
    /// fake engine.
    private func modelsArrive(_ state: AppState, _ rig: MultiSourceRig) {
        state.sources.inference = rig.inference
        state.sources.alignAudio = { _, _, _, _ in nil }
        state.installedModels = [state.transcriptionModel, state.summaryModel, state.processingPreferences.speakerModelID]
        for id in state.awaitingModels.sorted(by: { $0.uuidString < $1.uuidString }) { state.enqueue(id) }
    }

    func testBehaviorWorkDaybookDidntComeBackFromTwiceIsLeftToThePerson() async throws {
        let rig = try await rig()
        let audio = try rig.audio("heavy.wav", frequency: 320)
        let id = try await rig.macConversation("All hands", at: Date(), seconds: 0.5, audio: audio)
        try rig.inference.block(audio)
        rig.state.enqueue(id)
        try await waitUntil("it to be transcribing") { rig.inference.isWaiting(on: audio) }

        // Daybook crashes mid-run (nothing quit it): the next launch tries the work once more.
        let second = await relaunch(rig)
        XCTAssertEqual(second.awaitingModels, [id], "Queued again after one crash")
        modelsArrive(second, rig)
        try await waitUntil("it to run again") { second.processingID == id }

        // A quit ends that run as it stops it, so it doesn't count: the next launch queues it again.
        second.cancelProcessing()
        try await waitUntil("the job to stop") { second.processingID == nil && second.processingTask == nil }
        let third = await relaunch(rig, after: second)
        XCTAssertEqual(third.awaitingModels, [id], "A quit isn't a crash")
        modelsArrive(third, rig)
        try await waitUntil("it to run again") { third.processingID == id }

        // It crashes a second time: the next launch leaves it to the person.
        let fourth = await relaunch(rig, after: third)
        XCTAssertTrue(fourth.awaitingModels.isEmpty && fourth.queuedIDs.isEmpty, "Not queued again")
        XCTAssertFalse(fourth.queue.isOwed(id), "Settled")
        ProcessingQueue.drainWrites()
        let saved = ProcessingQueue(owedURL: rig.root.appendingPathComponent("local-queue.json"))
        saved.loadOwedWork()
        XCTAssertFalse(saved.isOwed(id), "Nor at the launch after")
        let meeting = try XCTUnwrap(fourth.meetings.first { $0.id == id })
        XCTAssertEqual(meeting.status, .imported, "Transcribe is the person's")
        XCTAssertEqual(meeting.errorMessage, "Processing was interrupted. Your audio and notes are saved.")

        // The launches that crashed stop now.
        rig.state.cancelProcessing()
        third.cancelProcessing()
        try rig.inference.unblock(audio)
    }

    func testBehaviorWorkThePersonPausedOrThatFailedIsntQueuedAgain() async throws {
        let rig = try await rig()
        let state = rig.state
        let start = Date()
        let pausedAudio = try rig.audio("paused.wav", frequency: 300)
        let failingAudio = try rig.audio("failing.wav", frequency: 500)
        let paused = try await rig.macConversation("Paused", at: start, seconds: 0.5, audio: pausedAudio)
        let failing = try await rig.macConversation("Failing", at: start, seconds: 0.5, audio: failingAudio)
        try rig.inference.fail(failingAudio, with: AppError.libraryUnavailable)
        state.enqueue(failing)
        try await rig.processed(failing)
        XCTAssertEqual(rig.meeting(failing)?.status, .failed)
        XCTAssertFalse(state.queue.isOwed(failing), "A failure is settled: Try Again is the person's")

        try rig.inference.block(pausedAudio)
        state.enqueue(paused)
        try await waitUntil("it to be transcribing") { rig.inference.isWaiting(on: pausedAudio) }
        state.pauseProcessing(paused)
        try await waitUntil("it to pause") { state.pausedIDs.contains(paused) && state.processingID == nil }
        XCTAssertFalse(state.queue.isOwed(paused), "Paused by the person: it resumes only when asked")
        state.cancelProcessing()

        let next = await relaunch(rig)
        XCTAssertTrue(next.awaitingModels.isEmpty && next.queuedIDs.isEmpty, "Nothing is queued again")
        try rig.inference.unblock(pausedAudio)
    }

    func testBehaviorARecordingWaitingForModelsStillWaitsAfterARelaunch() async throws {
        let rig = try await rig()
        let id = try await rig.macConversation("Interview", at: Date(), seconds: 0.5, audio: rig.audio("talk.wav", frequency: 410))
        rig.state.installedModels = []
        rig.state.enqueue(id)
        XCTAssertEqual(rig.state.awaitingModels, [id])
        let next = await relaunch(rig)
        XCTAssertEqual(next.awaitingModels, [id], "A download after the relaunch starts it")
    }

    func testBehaviorFinishedWorkIsntOwedAndAConversationQueuedAgainAsItFinishesStaysOwed() async throws {
        let rig = try await rig()
        let state = rig.state
        let audio = try rig.audio("done.wav", frequency: 350)
        try rig.inference.script(audio, [(0, "We agreed on Friday.")])
        let id = try await rig.macConversation("Planning", at: Date(), seconds: 0.5, audio: audio)
        state.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertFalse(state.queue.isOwed(id))

        // A job that queues its conversation again as it finishes (its notes changed meanwhile) leaves it owed.
        let queue = ProcessingQueue(owedURL: nil)
        let job = state.makeJob(meetingID: id, mode: .summaryOnly)
        queue.owe(id, mode: .summaryOnly, upgrade: nil)
        queue.start(job)
        queue.add(job)
        queue.finishRunning()
        queue.settle(id)
        XCTAssertTrue(queue.isOwed(id))
        _ = queue.next()
        queue.settle(id)
        XCTAssertFalse(queue.isOwed(id))
    }

    /// An error that says what kind of failure it is, in words the older reading wouldn't recognize.
    private struct EngineGaveUp: LocalizedError, ProcessingFailureClassifying {
        var errorDescription: String? { "The engine gave up." }
        var failureKind: ProcessingRequest.FailureKind { .modelCouldNotStart }
    }

    func testBehaviorALocalJobsFailureKeepsTheKindItWasCaughtWith() async throws {
        let rig = try await rig()
        let audio = try rig.audio("odd.wav", frequency: 380)
        let id = try await rig.macConversation("Interview", at: Date(), seconds: 0.5, audio: audio)
        try rig.inference.fail(audio, with: EngineGaveUp())
        rig.state.enqueue(id)
        try await rig.processed(id)
        let meeting = try XCTUnwrap(rig.meeting(id))
        guard case .failed(let failure) = rig.state.processingStatus(for: meeting) else { return XCTFail("Failed") }
        XCTAssertEqual(failure.kind, .modelCouldNotStart, "As the error said, with no request to keep it")
        XCTAssertEqual(failure.reason, "The engine gave up.", "Its words stay for Details")
        guard case .failed(let read) = ProcessingStatus(meeting) else { return XCTFail("Failed") }
        XCTAssertEqual(read.kind, .other, "Read back from the words alone, it would be another kind")
    }

    func testBehaviorAQueuedConversationSaysWhatItWaitsForAndWhy() async throws {
        let rig = try await rig()
        let state = rig.state
        let start = Date()
        let runningAudio = try rig.audio("running.wav", frequency: 300)
        let running = try await rig.macConversation("Roadmap review", at: start, seconds: 0.5, audio: runningAudio)
        let next = try await rig.macConversation("Standup", at: start, seconds: 0.5, audio: rig.audio("next.wav", frequency: 500))
        let later = try await rig.macConversation("Retro", at: start, seconds: 0.5, audio: rig.audio("later.wav", frequency: 700))
        try rig.inference.block(runningAudio)
        state.enqueue(running)
        state.enqueue(next)
        state.enqueue(later, mode: .summaryOnly)
        try await waitUntil("the first to be transcribing") { rig.inference.isWaiting(on: runningAudio) }
        XCTAssertEqual(state.waitingWords(for: next)?.line, "Waiting to transcribe after “Roadmap review”")
        XCTAssertEqual(state.waitingWords(for: next)?.short, "Waiting to transcribe")
        XCTAssertEqual(state.waitingWords(for: later)?.line, "Waiting to summarize · 2 ahead", "Worded by the job's mode")
        XCTAssertEqual(state.queuedMode(later), .summaryOnly)
        XCTAssertNil(state.waitingWords(for: running), "Running, not waiting")
        XCTAssertFalse(state.queueWaitsForDownload)
        try rig.inference.unblock(runningAudio)
        try await rig.processed(running, next, later)

        // Held back by a model download rather than by another conversation.
        let held = ProcessingQueue(owedURL: nil)
        held.add(state.makeJob(meetingID: next, mode: .newAudio))
        held.downloadingID = "whisper/base"
        XCTAssertEqual(held.waiting(next, title: { _ in nil })?.behind, .download)
    }
}
