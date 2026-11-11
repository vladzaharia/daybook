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
        state.processor.enqueue(first)
        state.processor.enqueue(second)
        try await waitUntil("the first to be transcribing") { rig.inference.isWaiting(on: firstAudio) }
        XCTAssertEqual(state.processor.queue.queuedIDs, [second])

        // Quitting stops the running job and empties the queue, and keeps both owed.
        state.cancelProcessing()
        try await waitUntil("the job to stop") { state.processor.queue.runningID == nil && state.processor.queue.task == nil }
        XCTAssertTrue(state.processor.queue.isOwed(first) && state.processor.queue.isOwed(second))

        let next = await relaunch(rig)
        XCTAssertEqual(next.processor.queue.awaitingModels, [first, second], "Both are queued again, waiting for this Mac's models")
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
        for id in state.processor.queue.awaitingModels.sorted(by: { $0.uuidString < $1.uuidString }) { state.processor.enqueue(id) }
    }

    func testBehaviorWorkDaybookDidntComeBackFromTwiceIsLeftToThePerson() async throws {
        let rig = try await rig()
        let audio = try rig.audio("heavy.wav", frequency: 320)
        let id = try await rig.macConversation("All hands", at: Date(), seconds: 0.5, audio: audio)
        try rig.inference.block(audio)
        rig.state.processor.enqueue(id)
        try await waitUntil("it to be transcribing") { rig.inference.isWaiting(on: audio) }

        // Daybook crashes mid-run (nothing quit it): the next launch tries the work once more.
        let second = await relaunch(rig)
        XCTAssertEqual(second.processor.queue.awaitingModels, [id], "Queued again after one crash")
        modelsArrive(second, rig)
        try await waitUntil("it to run again") { second.processor.queue.runningID == id }

        // A quit ends that run as it stops it, so it doesn't count: the next launch queues it again.
        second.cancelProcessing()
        try await waitUntil("the job to stop") { second.processor.queue.runningID == nil && second.processor.queue.task == nil }
        let third = await relaunch(rig, after: second)
        XCTAssertEqual(third.processor.queue.awaitingModels, [id], "A quit isn't a crash")
        modelsArrive(third, rig)
        try await waitUntil("it to run again") { third.processor.queue.runningID == id }

        // It crashes a second time: the next launch leaves it to the person.
        let fourth = await relaunch(rig, after: third)
        XCTAssertTrue(fourth.processor.queue.awaitingModels.isEmpty && fourth.processor.queue.queuedIDs.isEmpty, "Not queued again")
        XCTAssertFalse(fourth.processor.queue.isOwed(id), "Settled")
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
        state.processor.enqueue(failing)
        try await rig.processed(failing)
        XCTAssertEqual(rig.meeting(failing)?.status, .failed)
        XCTAssertFalse(state.processor.queue.isOwed(failing), "A failure is settled: Try Again is the person's")

        try rig.inference.block(pausedAudio)
        state.processor.enqueue(paused)
        try await waitUntil("it to be transcribing") { rig.inference.isWaiting(on: pausedAudio) }
        state.pauseProcessing(paused)
        try await waitUntil("it to pause") { state.processor.queue.paused.contains(paused) && state.processor.queue.runningID == nil }
        XCTAssertFalse(state.processor.queue.isOwed(paused), "Paused by the person: it resumes only when asked")
        state.cancelProcessing()

        let next = await relaunch(rig)
        XCTAssertTrue(next.processor.queue.awaitingModels.isEmpty && next.processor.queue.queuedIDs.isEmpty, "Nothing is queued again")
        try rig.inference.unblock(pausedAudio)
    }

    func testBehaviorARecordingWaitingForModelsStillWaitsAfterARelaunch() async throws {
        let rig = try await rig()
        let id = try await rig.macConversation("Interview", at: Date(), seconds: 0.5, audio: rig.audio("talk.wav", frequency: 410))
        rig.state.installedModels = []
        rig.state.processor.enqueue(id)
        XCTAssertEqual(rig.state.processor.queue.awaitingModels, [id])
        let next = await relaunch(rig)
        XCTAssertEqual(next.processor.queue.awaitingModels, [id], "A download after the relaunch starts it")
    }

    func testBehaviorFinishedWorkIsntOwedAndAConversationQueuedAgainAsItFinishesStaysOwed() async throws {
        let rig = try await rig()
        let state = rig.state
        let audio = try rig.audio("done.wav", frequency: 350)
        try rig.inference.script(audio, [(0, "We agreed on Friday.")])
        let id = try await rig.macConversation("Planning", at: Date(), seconds: 0.5, audio: audio)
        state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertFalse(state.processor.queue.isOwed(id))

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
        rig.state.processor.enqueue(id)
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
        state.processor.enqueue(running)
        state.processor.enqueue(next)
        state.processor.enqueue(later, mode: .summaryOnly)
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

    // MARK: Transcript first (uxf-01)

    /// With what transcribes here and no summary model, a recording is transcribed at once and ends at its transcript;
    /// its summary is owed, across a relaunch too, and once the model arrives every conversation waiting for it is
    /// summarized, the oldest first.
    func testBehaviorWithoutTheSummaryModelAJobTranscribesThenIsSummarizedOnceTheModelArrives() async throws {
        let rig = try await rig()
        let state = rig.state
        let summaryModel = state.summaryModel
        state.installedModels.remove(summaryModel)
        XCTAssertTrue(state.canProcess, "What transcribes is here")
        XCTAssertFalse(state.summarizesLocally)
        let older = try await rig.waitingConversation("Monday sync", audio: rig.audio("older.wav", frequency: 310), script: [(0, "Older agenda.")])
        let newer = try await rig.waitingConversation("Tuesday sync", audio: rig.audio("newer.wav", frequency: 520), script: [(0, "Newer agenda.")])
        state.update(older) { $0.date = Date().addingTimeInterval(-7200) }
        state.processor.enqueue(newer)
        state.processor.enqueue(older)
        XCTAssertTrue(state.processor.queue.awaitingModels.isEmpty, "A transcript doesn't wait for the summary model")
        try await rig.processed(newer, older)

        XCTAssertEqual(state.processor.queue.awaitingSummaryModel, [older, newer])
        XCTAssertTrue(rig.inference.summarized.isEmpty, "Nothing summarized without the model")
        for id in [older, newer] {
            let meeting = try XCTUnwrap(rig.meeting(id))
            XCTAssertFalse(meeting.unifiedTranscript.isEmpty, "The transcript reads")
            XCTAssertNil(meeting.summary)
            XCTAssertEqual(meeting.status, .imported)
            XCTAssertEqual(state.processingStatus(for: meeting), .transcribed)
            XCTAssertTrue(state.summaryWaitsForModel(meeting))
            XCTAssertEqual(state.processor.queue.owedWork(id)?.mode, .summaryOnly, "A Summarize is owed")
        }
        XCTAssertFalse(state.localCapabilities.summarizes)
        XCTAssertEqual(state.missingSelectedModels, [summaryModel])
        // While the summary model downloads, Floating Notes' chip says the transcript is ready, and what the summary waits for.
        state.processor.queue.downloadingID = summaryModel
        let shown = FloatingStatusInputs.conversation(try XCTUnwrap(rig.meeting(newer)), state: state)
        XCTAssertEqual(shown.ready, false, "Transcript ready, with the wait")
        let waiting = try XCTUnwrap(shown.summaryWaits)
        XCTAssertTrue(waiting.hasPrefix("Waiting to summarize after the download · "), waiting)
        XCTAssertEqual(FloatingStatus.workChip(shown, words: state.statusWords, models: nil)?.detail, "Transcript ready · \(waiting)")
        state.processor.queue.downloadingID = nil

        // Owed across a relaunch: the next launch waits for the model again.
        await state.flush()
        ProcessingQueue.drainWrites()
        let saved = ProcessingQueue(owedURL: rig.root.appendingPathComponent("local-queue.json"))
        saved.loadOwedWork()
        XCTAssertEqual(saved.owedWork(older)?.mode, .summaryOnly)
        // A Summarize asked for meanwhile waits for the model too, rather than running.
        state.processor.enqueue(newer, mode: .summaryOnly)
        XCTAssertTrue(state.processor.queue.queuedIDs.isEmpty)
        XCTAssertEqual(state.processor.queue.awaitingSummaryModel, [older, newer])

        // The model arrives: both are summarized, the oldest first, and nothing is owed.
        state.installedModels.insert(summaryModel)
        try await rig.processed(older, newer)
        try await waitUntil("both summaries") { rig.inference.summarized.count == 2 }
        try await rig.processed(older, newer)
        XCTAssertTrue(rig.inference.summarized[0].contains("Older agenda"), "Date order")
        XCTAssertTrue(rig.inference.summarized[1].contains("Newer agenda"))
        XCTAssertTrue(state.processor.queue.awaitingSummaryModel.isEmpty)
        for id in [older, newer] {
            let meeting = try XCTUnwrap(rig.meeting(id))
            XCTAssertNotNil(meeting.summary)
            XCTAssertEqual(state.processingStatus(for: meeting), .done)
            XCTAssertFalse(state.processor.queue.isOwed(id))
        }
    }

    /// A model download doesn't hold the queue: what waited for the models that transcribe goes on as soon as they're
    /// here, while the summary model still downloads, and its summary waits for that.
    func testBehaviorWhatWaitedForModelsTranscribesWhileTheSummaryModelDownloads() async throws {
        let rig = try await rig()
        let state = rig.state
        let installed = state.installedModels
        let id = try await rig.waitingConversation("First call", audio: rig.audio("first.wav", frequency: 360), script: [(0, "Kickoff notes.")])
        state.installedModels = []
        state.processor.enqueue(id)
        XCTAssertEqual(state.processor.queue.awaitingModels, [id])
        // The models that transcribe arrive; the summary model is still on its way.
        state.installedModels = installed.subtracting([state.summaryModel])
        state.processor.queue.downloadingID = state.summaryModel
        state.takeUpWorkWaitingForModels()
        try await rig.processed(id)
        XCTAssertFalse(try XCTUnwrap(rig.meeting(id)).unifiedTranscript.isEmpty, "Transcribed beside the download")
        XCTAssertEqual(state.processor.queue.awaitingSummaryModel, [id])
        state.processor.queue.downloadingID = nil
    }
}
