import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookTestSupport
import XCTest
@testable import Daybook

/// The Mac's side of asking across conversations: the page's states driven by a scripted answerer, cancellation, the
/// queue rule, and every way the Personal lock and a Focus keep a Personal conversation out of an answer.
@MainActor
final class AskControllerTests: XCTestCase {
    private let track = UUID()
    private let now = Date(timeIntervalSince1970: 1_763_000_000)

    private func meeting(_ title: String, placement: LibraryPlacement = .work, text: String) -> Meeting {
        var meeting = Meeting(title: title, date: now, updatedAt: now, speakers: [Speaker(id: "s", name: "Sam")], status: .ready, placement: placement)
        meeting.unifiedTranscript = [TranscriptSegment(trackID: track, start: 5, end: 12, text: text, speakerID: "s")]
        return meeting
    }

    /// An answerer that cites the first passage it is given, and can be held open.
    private final class Answerer: QuestionAnswering, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [AskEvidence] = []
        private var _open: Bool
        private let fails: Bool
        var error: (any Error)?
        var calls: [AskEvidence] { lock.withLock { _calls } }
        init(open: Bool = true, fails: Bool = false) { _open = open; self.fails = fails }
        func release() { lock.withLock { _open = true } }
        private var isOpen: Bool { lock.withLock { _open } }

        func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                    sentence emit: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply {
            lock.withLock { _calls.append(evidence) }
            progress(.init(0, "Answering"))
            while !isOpen { try await Task.sleep(for: .milliseconds(5)) }
            if let error { throw error }
            if fails { struct Boom: Error {}; throw Boom() }
            guard let conversation = evidence.conversations.first, let passage = conversation.passages.first else {
                return AskReply(answer: AskAnswer(status: .notFound(.modelSaidSo), closest: [], query: query))
            }
            let citation = AskCitation(kind: .passage, meetingID: conversation.meetingID, conversationTitle: conversation.title, date: conversation.date,
                                       segmentID: passage.segmentID, time: passage.time, speaker: passage.speaker, text: passage.text)
            let sentence = AskSentence(text: "Sam said it.", citations: [citation], quote: passage.text)
            emit(sentence)
            return AskReply(answer: AskAnswer(status: .answered, sentences: [sentence], closest: [conversation.meetingID], query: query))
        }
    }

    /// A controller over a small library, a lock, and a queue of its own.
    @MainActor private final class Harness {
        var meetings: [Meeting]
        var personal = AskScope.Personal.included
        var running: String?
        var scope = AskScope()
        var holds = 0
        var released = 0
        let answerer: Answerer
        lazy var controller: AskController = {
            let controller = AskController(dependencies: .init(
                engine: { [answerer] index in AskEngine(answerer: answerer, index: index, retryDelay: .milliseconds(5)) },
                meetings: { [unowned self] in meetings }, vocabulary: { [] }, people: { ["Sam"] },
                scope: { [unowned self] in (scope.with(personal), "All Conversations") },
                personal: { [unowned self] in personal },
                isPersonal: { [unowned self] id in meetings.first { $0.id == id }?.effectivePlacement == .personal },
                isJobRunning: { [unowned self] in running != nil }, jobName: { [unowned self] in running },
                holdQueue: { [unowned self] in holds += 1 }, releaseQueue: { [unowned self] in released += 1 },
                modelName: { _ in "Gemma 4 12B" }))
            controller.pollInterval = .milliseconds(5)
            return controller
        }()
        init(_ meetings: [Meeting], answerer: Answerer) { self.meetings = meetings; self.answerer = answerer }
        var balanced: Bool { holds == released }
    }

    /// Conversations about other things, so the question's words are rare in the library and retrieval reads them.
    private func fillers() -> [Meeting] {
        ["gardening", "orchestra", "plumbing", "marathon", "bakery", "glacier", "harbor", "violin"].enumerated().map { index, topic in
            meeting("Filler \(index)", text: "We spoke at length about \(topic) and the \(topic) season.")
        }
    }

    private func harness(open: Bool = true, fails: Bool = false) -> Harness {
        Harness([meeting("Weekly sync", text: "I'll get the comparison sheet over to finance by Friday."),
                 meeting("Therapy notes", placement: .personal, text: "The comparison sheet for my budget worries me.")] + fillers(),
                answerer: Answerer(open: open, fails: fails))
    }

    private let question = "What about the comparison sheet?"

    // MARK: States

    func testBehaviorAnAnswerStreamsItsSentencesThenFinishesWithItsModel() async throws {
        let h = harness()
        h.controller.ask(question)
        XCTAssertTrue(h.controller.isShown)
        XCTAssertEqual(h.controller.question, question)
        try await waitUntil("the answer") { h.controller.stage == .answered }
        XCTAssertEqual(h.controller.sentences.map(\.text), ["Sam said it."])
        XCTAssertEqual(h.controller.reply?.answer.status, .answered)
        XCTAssertEqual(h.controller.modelName, "Gemma 4 12B")
        try await waitUntil("the hold to end") { h.balanced }
        XCTAssertEqual(h.holds, 1)
    }

    func testBehaviorNothingFoundIsAnAnswerOfNothingFoundWithoutAskingTheModel() async throws {
        let h = harness()
        h.controller.ask("What about the quarterly zeppelin audit?")
        try await waitUntil("the answer") { h.controller.stage == .answered }
        XCTAssertEqual(h.controller.reply?.answer.status, .notFound(.nothingFound))
        XCTAssertTrue(h.answerer.calls.isEmpty)
    }

    func testBehaviorAFailedAnswerSaysSoAndAsksAgain() async throws {
        let h = harness(fails: true)
        h.controller.ask(question)
        try await waitUntil("the failure") { h.controller.stage == .failed }
        try await waitUntil("the hold to end") { h.balanced }
        XCTAssertTrue(h.controller.isShown)
        h.controller.askAgain()
        try await waitUntil("a second try") { h.answerer.calls.count == 2 }
    }

    func testBehaviorAWaitThatRanOutSaysSoAndAsksAgain() async throws {
        let h = harness()
        h.answerer.error = AskError.waitedTooLong
        h.controller.ask(question)
        try await waitUntil("the wait to end") { h.controller.stage == .busy }
        try await waitUntil("the hold to end") { h.balanced }
        h.answerer.error = nil
        h.controller.askAgain()
        try await waitUntil("the answer") { h.controller.stage == .answered }
    }

    func testBehaviorWithoutTheSummaryModelItSaysSoAndHoldsNothing() {
        let controller = AskController(dependencies: .init(
            engine: { _ in nil }, meetings: { [] }, vocabulary: { [] }, people: { [] }, scope: { (AskScope(), "All Conversations") },
            personal: { .included }, isPersonal: { _ in false }, isJobRunning: { false }, jobName: { nil }, holdQueue: { XCTFail("held") },
            releaseQueue: {}, modelName: { _ in nil }))
        controller.ask(question)
        XCTAssertEqual(controller.stage, .needsModel)
        XCTAssertTrue(controller.isShown)
    }

    func testBehaviorTheSameQuestionInTheSameScopeIsShownNotAskedAgain() async throws {
        let h = harness()
        h.controller.ask(question)
        try await waitUntil("the answer") { h.controller.stage == .answered }
        h.controller.leavePage()
        XCTAssertFalse(h.controller.isShown)
        h.controller.ask(question)
        XCTAssertTrue(h.controller.isShown)
        XCTAssertEqual(h.answerer.calls.count, 1)
    }

    // MARK: Waiting and cancelling

    func testBehaviorAQuestionWaitsBehindTheRunningJobAndSaysWhich() async throws {
        let h = harness()
        h.running = "Roadmap review"
        h.controller.ask(question)
        try await waitUntil("the wait") { h.controller.stage == .waiting("Roadmap review") }
        XCTAssertTrue(h.answerer.calls.isEmpty, "the model is the job's until it ends")
        h.running = nil
        try await waitUntil("the answer") { h.controller.stage == .answered }
    }

    func testBehaviorANewQuestionCancelsTheOneRunning() async throws {
        let h = harness(open: false)
        h.controller.ask(question)
        try await waitUntil("the model") { h.answerer.calls.count == 1 }
        h.controller.ask("What about the finance sheet?")
        XCTAssertEqual(h.controller.question, "What about the finance sheet?")
        h.answerer.release()
        try await waitUntil("the second answer") { h.controller.stage == .answered }
        XCTAssertEqual(h.controller.question, "What about the finance sheet?")
        try await waitUntil("both holds to end") { h.balanced }
        XCTAssertEqual(h.holds, 2)
    }

    func testBehaviorClosingCancelsAndLeavesNothing() async throws {
        let h = harness(open: false)
        h.controller.ask(question)
        try await waitUntil("the model") { h.answerer.calls.count == 1 }
        h.controller.close()
        XCTAssertNil(h.controller.question)
        XCTAssertFalse(h.controller.isShown)
        XCTAssertTrue(h.controller.sentences.isEmpty)
        try await waitUntil("the hold to end") { h.balanced }
        h.answerer.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(h.controller.reply, "an answer that arrives after the page closed isn't kept")
    }

    func testBehaviorCancellingWhileWaitingReleasesTheHold() async throws {
        let h = harness()
        h.running = "Roadmap review"
        h.controller.ask(question)
        try await waitUntil("the wait") { h.controller.stage == .waiting("Roadmap review") }
        h.controller.close()
        try await waitUntil("the hold to end") { h.balanced }
        XCTAssertTrue(h.answerer.calls.isEmpty)
    }

    // MARK: Personal

    func testBehaviorLockedPersonalIsNeverReadAndUnlockedAllIncludesIt() async throws {
        let h = harness()
        h.personal = .locked
        h.controller.ask(question)
        try await waitUntil("the answer") { h.controller.stage == .answered }
        XCTAssertEqual(h.answerer.calls.last?.conversations.map(\.title), ["Weekly sync"])

        h.personal = .included
        h.scope = AskScope(search: .personal)
        h.controller.ask(question)
        try await waitUntil("the Personal answer") { h.answerer.calls.count == 2 && h.controller.stage == .answered }
        XCTAssertEqual(h.answerer.calls.last?.conversations.map(\.title), ["Therapy notes"])
    }

    func testBehaviorLockingClearsAnAnswerThatCitesPersonalAndKeepsOneThatDoesNot() async throws {
        let h = harness()
        h.scope = AskScope(search: .personal)
        h.controller.ask(question)
        try await waitUntil("the answer") { h.controller.stage == .answered }
        XCTAssertFalse(h.controller.sentences.isEmpty)
        h.personal = .locked
        h.controller.personalHidden()
        XCTAssertEqual(h.controller.stage, .hidden)
        XCTAssertTrue(h.controller.sentences.isEmpty)
        XCTAssertNil(h.controller.reply, "cleared, not dimmed")

        h.personal = .included
        h.scope = AskScope(search: .work)
        h.controller.ask(question)
        try await waitUntil("the Work answer") { h.controller.stage == .answered }
        h.personal = .locked
        h.controller.personalHidden()
        XCTAssertEqual(h.controller.stage, .answered, "it cites nothing Personal")
        XCTAssertFalse(h.controller.sentences.isEmpty)
    }

    func testBehaviorLockingCancelsAnAnswerBeingWrittenThatCouldCitePersonal() async throws {
        let h = harness(open: false)
        h.controller.ask(question)
        try await waitUntil("the model") { h.answerer.calls.count == 1 }
        XCTAssertTrue(h.answerer.calls[0].conversations.contains { $0.title == "Therapy notes" })
        h.personal = .locked
        h.controller.personalHidden()
        XCTAssertEqual(h.controller.stage, .hidden)
        XCTAssertTrue(h.controller.sentences.isEmpty)
        h.answerer.release()
        try await waitUntil("the hold to end") { h.balanced }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.controller.stage, .hidden, "what it wrote after is never shown")
        XCTAssertNil(h.controller.reply)
    }

    func testBehaviorAnAnswerThatArrivesAfterThePersonalLockedCitingPersonalIsCleared() async throws {
        let h = harness()
        h.scope = AskScope(search: .personal)
        h.personal = .included
        h.controller.ask(question)
        try await waitUntil("the answer") { h.controller.stage == .answered }
        // A conversation moved to Personal after it was answered: the lock hides what cites it too.
        h.meetings[0].placement = .personal
        h.personal = .locked
        h.controller.personalHidden()
        XCTAssertEqual(h.controller.stage, .hidden)
    }

    func testBehaviorLockingDropsPersonalFromTheIndexAndKeepsTheRest() async throws {
        let h = harness()
        let personal = h.meetings[1].id, work = h.meetings[0].id
        h.controller.index.update(h.meetings, personal: .included)
        XCTAssertTrue(h.controller.index.contains(personal))
        h.personal = .locked
        h.controller.personalHidden()
        XCTAssertFalse(h.controller.index.contains(personal))
        XCTAssertTrue(h.controller.index.contains(work))
        // The index that follows the library while locked never reads Personal again.
        try await Task.sleep(for: .milliseconds(100))
        h.controller.refreshIndex()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(h.controller.index.contains(personal))
        XCTAssertTrue(h.controller.index.contains(work))
    }

    // MARK: The app's own lock and Focus

    private func appRig() async throws -> (state: AppState, answerer: Answerer, work: UUID, personal: UUID) {
        let defaults = makeTestDefaults("AskControllerTests")
        defaults.set(false, forKey: "showsFloatingNotesWhileRecording")
        let state = AppState(libraryURL: makeTemporaryFolder("AskControllerTests"), defaults: defaults)
        await state.initialize()
        state.personalLock.authenticator = FakePersonalLockAuthenticator(answers: true)
        let work = state.library.newMeeting(title: "Weekly sync", date: now, placement: .work)
        let personal = state.library.newMeeting(title: "Therapy notes", date: now, placement: .personal)
        for (id, text) in [(work, "I'll get the comparison sheet over to finance by Friday."), (personal, "The comparison sheet for my budget worries me.")] {
            state.update(id) { meeting in
                meeting.speakers = [Speaker(id: "s", name: "Sam")]
                meeting.unifiedTranscript = [TranscriptSegment(trackID: self.track, start: 5, end: 12, text: text, speakerID: "s")]
            }
        }
        for (index, topic) in ["gardening", "orchestra", "plumbing", "marathon", "bakery", "glacier", "harbor", "violin"].enumerated() {
            let id = state.library.newMeeting(title: "Filler \(index)", date: now, placement: .work)
            state.update(id) { meeting in
                meeting.speakers = [Speaker(id: "s", name: "Sam")]
                meeting.unifiedTranscript = [TranscriptSegment(trackID: self.track, start: 5, end: 12, text: "We spoke at length about \(topic) and the \(topic) season.", speakerID: "s")]
            }
        }
        let answerer = Answerer()
        state.ask = state.makeAskController(engine: { index in AskEngine(answerer: answerer, index: index) })
        return (state, answerer, work, personal)
    }

    func testBehaviorTheSearchFieldsScopeAndTheLocksStateAtTheMomentOfAskingBuildTheScope() async throws {
        let rig = try await appRig()
        let state = rig.state
        state.window.searchScope = .all
        await state.personalLock.setRequired(true)
        state.ask.ask(question)
        try await waitUntil("the locked answer") { state.ask.stage == .answered }
        XCTAssertEqual(rig.answerer.calls.last?.conversations.map(\.title), ["Weekly sync"], "All never includes Personal while locked")
        XCTAssertEqual(state.ask.scope?.personal, .locked)

        _ = await state.personalLock.unlock()
        state.window.searchScope = .all
        state.ask.ask("What about the comparison sheet and finance?")
        try await waitUntil("the unlocked answer") { rig.answerer.calls.count == 2 && state.ask.stage == .answered }
        XCTAssertEqual(Set(rig.answerer.calls.last?.conversations.map(\.title) ?? []), ["Weekly sync", "Therapy notes"], "All includes Personal when unlocked")
        XCTAssertEqual(state.ask.scope?.personal, .included)
    }

    func testBehaviorTheLockLockingClearsAnAnswerThatCitesPersonalThroughTheApp() async throws {
        let rig = try await appRig()
        let state = rig.state
        await state.personalLock.setRequired(true)
        _ = await state.personalLock.unlock()
        state.window.searchScope = .personal
        state.ask.ask(question)
        try await waitUntil("the answer") { state.ask.stage == .answered }
        XCTAssertFalse(state.ask.sentences.isEmpty)
        state.personalLock.lock()
        XCTAssertEqual(state.ask.stage, .hidden)
        XCTAssertTrue(state.ask.sentences.isEmpty)
        XCTAssertNil(state.ask.reply)
        XCTAssertFalse(state.ask.index.contains(rig.personal))
    }

    func testBehaviorAFocusThatHidesPersonalLeavesItOutOfAskingAndClearsTheAnswer() async throws {
        let rig = try await appRig()
        let state = rig.state
        state.window.searchScope = .personal
        state.ask.ask(question)
        try await waitUntil("the answer") { state.ask.stage == .answered }
        state.personalLock.apply(PersonalFocus(showsPersonal: false))
        XCTAssertEqual(state.ask.stage, .hidden)
        XCTAssertTrue(state.ask.sentences.isEmpty)
        XCTAssertFalse(state.ask.index.contains(rig.personal))

        state.window.searchScope = .all
        state.ask.ask(question)
        try await waitUntil("the Work answer") { rig.answerer.calls.count == 2 && state.ask.stage == .answered }
        XCTAssertEqual(rig.answerer.calls.last?.conversations.map(\.title), ["Weekly sync"])
        XCTAssertEqual(state.ask.scope?.personal, .hiddenByFocus)
    }

    // MARK: The queue

    func testBehaviorNoJobStartsWhileAQuestionHoldsTheQueueAndItRunsOnceItEnds() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let mic = try rig.audio("ask-mic.wav", frequency: 220, seconds: 0.5)
        try rig.inference.script(mic, [(0, "We should ship the calendar feature tomorrow")])
        let id = try await rig.macConversation("Design review", at: Date(timeIntervalSince1970: 1_780_000_000), seconds: 60, audio: mic)
        let processor = rig.state.processor
        processor.holdForAsk()
        processor.enqueue(id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(processor.queue.runningID)
        XCTAssertTrue(processor.queue.isQueued(id), "it waits behind the question")
        XCTAssertNotEqual(rig.meeting(id)?.status, .failed)
        processor.releaseAsk()
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertNil(rig.meeting(id)?.errorMessage)
    }

    func testBehaviorAJobReadyWhileAQuestionIsAnsweredWaitsForItAndIsNeverMarkedFailed() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let answerer = Answerer(open: false)
        state.ask = state.makeAskController(engine: { index in AskEngine(answerer: answerer, index: index) })
        let known = state.library.newMeeting(title: "Weekly sync", date: now, placement: .work)
        state.update(known) { meeting in
            meeting.speakers = [Speaker(id: "s", name: "Sam")]
            meeting.unifiedTranscript = [TranscriptSegment(trackID: self.track, start: 5, end: 12, text: "The comparison sheet goes to finance.", speakerID: "s")]
        }
        let mic = try rig.audio("ask-mic2.wav", frequency: 330, seconds: 0.5)
        try rig.inference.script(mic, [(0, "We should ship the calendar feature tomorrow")])
        let id = try await rig.macConversation("Design review", at: Date(timeIntervalSince1970: 1_780_000_000), seconds: 60, audio: mic)

        state.ask.ask("What about the comparison sheet?")
        try await waitUntil("the model") { answerer.calls.count == 1 }
        // A recording stops and its job becomes ready while the question is being answered.
        state.processor.enqueue(id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(state.processor.queue.runningID, "the job waits for the answer")
        XCTAssertNotEqual(rig.meeting(id)?.status, .failed)

        answerer.release()
        try await waitUntil("the answer") { state.ask.stage == .answered }
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
        XCTAssertNil(rig.meeting(id)?.errorMessage)
        XCTAssertEqual(state.processor.askHolds, 0)
    }

    func testBehaviorAQuestionWaitsForTheRunningJobAndGoesAheadOfQueuedOnes() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let answerer = Answerer()
        state.ask = state.makeAskController(engine: { index in AskEngine(answerer: answerer, index: index) })
        let known = state.library.newMeeting(title: "Weekly sync", date: now, placement: .work)
        state.update(known) { meeting in
            meeting.speakers = [Speaker(id: "s", name: "Sam")]
            meeting.unifiedTranscript = [TranscriptSegment(trackID: self.track, start: 5, end: 12, text: "The comparison sheet goes to finance.", speakerID: "s")]
        }
        // A job that is running (the queue's own claim of it) and one queued after it.
        let running = UUID()
        state.processor.queue.runningID = running
        state.ask.ask("What about the comparison sheet?")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(answerer.calls.isEmpty, "behind the job that runs")
        XCTAssertEqual(state.processor.askHolds, 1, "and ahead of queued jobs: none starts meanwhile")
        state.processor.queue.runningID = nil
        try await waitUntil("the answer") { state.ask.stage == .answered }
        try await waitUntil("the hold to end") { state.processor.askHolds == 0 }
    }

    func testBehaviorACancelledOrFailedQuestionNeverLeavesTheQueueStuck() async throws {
        let rig = try await MultiSourceRig.make(in: self)
        addTeardownBlock { await rig.tearDown() }
        let state = rig.state
        let failing = Answerer(open: true, fails: true)
        let gated = Answerer(open: false)
        let known = state.library.newMeeting(title: "Weekly sync", date: now, placement: .work)
        state.update(known) { meeting in
            meeting.speakers = [Speaker(id: "s", name: "Sam")]
            meeting.unifiedTranscript = [TranscriptSegment(trackID: self.track, start: 5, end: 12, text: "The comparison sheet goes to finance.", speakerID: "s")]
        }
        state.ask = state.makeAskController(engine: { index in AskEngine(answerer: failing, index: index) })
        state.ask.ask("What about the comparison sheet?")
        try await waitUntil("the failure") { state.ask.stage == .failed }
        try await waitUntil("the hold to end") { state.processor.askHolds == 0 }

        state.ask = state.makeAskController(engine: { index in AskEngine(answerer: gated, index: index) })
        state.ask.ask("What about the comparison sheet?")
        try await waitUntil("the model") { gated.calls.count == 1 }
        XCTAssertEqual(state.processor.askHolds, 1)
        state.ask.close()
        try await waitUntil("the hold to end") { state.processor.askHolds == 0 }

        // The queue runs a job as before.
        let mic = try rig.audio("ask-mic3.wav", frequency: 440, seconds: 0.5)
        try rig.inference.script(mic, [(0, "We should ship the calendar feature tomorrow")])
        let id = try await rig.macConversation("Design review", at: Date(timeIntervalSince1970: 1_780_000_000), seconds: 60, audio: mic)
        state.processor.enqueue(id)
        try await rig.processed(id)
        XCTAssertEqual(rig.meeting(id)?.status, .ready)
    }
}

private extension AskScope {
    /// This scope with what the lock allows.
    func with(_ personal: AskScope.Personal) -> AskScope {
        var scope = self
        scope.personal = personal
        return scope
    }
}
