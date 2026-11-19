import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookIntelligence

/// Asking end to end without a model: retrieval over a small library, the answering step on a scripted model, waiting
/// behind a running job, and cancelling.
final class AskEngineTests: XCTestCase {
    private let track = UUID()

    private func meeting(_ title: String, day: Int, placement: LibraryPlacement? = nil, _ lines: [(String, String)]) -> Meeting {
        let date = Date(timeIntervalSince1970: 1_760_000_000 + Double(day) * 86_400)
        var meeting = Meeting(title: title, date: date, updatedAt: date, speakers: [Speaker(id: "s", name: "Sam"), Speaker(id: "p", name: "Priya")],
                              status: .ready, placement: placement)
        meeting.unifiedTranscript = lines.enumerated().map { index, line in
            TranscriptSegment(trackID: track, start: Double(index) * 10, end: Double(index) * 10 + 9, text: line.1, speakerID: line.0)
        }
        return meeting
    }

    private lazy var library: [Meeting] = {
        let topics = ["gardening", "orchestra", "plumbing", "marathon", "bakery", "glacier", "harbor", "violin"]
        return [meeting("Weekly sync", day: 0, [("s", "I'll get the comparison sheet over to finance by Friday."), ("p", "Great, the board pack needs it too.")]),
                meeting("Private", day: 1, placement: .personal, [("s", "My comparison sheet for the vacation fund is ready.")])]
            + topics.enumerated().map { index, topic in
                meeting("Filler \(index)", day: 2 + index, placement: .work, [("p", "We spoke at length about \(topic) and the \(topic) season.")])
            }
    }()

    private let good = #"{"status":"answered","sentences":[{"text":"Sam said he would send the comparison sheet to finance by Friday.","cites":["P1"],"quote":"comparison sheet over to finance by Friday"}],"missing":null}"#

    /// Answers through the answering step on a scripted model, as the runtime's summary model would, after `busy` turns away.
    private final class Answerer: QuestionAnswering, @unchecked Sendable {
        let model: ScriptedSynthesisModel
        private let lock = NSLock()
        private var busy: Int
        private var _asked = 0
        var asked: Int { lock.withLock { _asked } }

        init(model: ScriptedSynthesisModel, busy: Int = 0) { self.model = model; self.busy = busy }

        func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                    sentence: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply {
            let turnedAway = lock.withLock { () -> Bool in _asked += 1; if busy > 0 { busy -= 1; return true }; return false }
            if turnedAway { throw LocalIntelligenceError.busy }
            progress(.init(0, "Answering"))
            return AskReply(answer: try await AskSynthesis.answer(evidence, model: model, closest: closest, query: query, sentence: sentence))
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [AskProgress] = []
        var all: [AskProgress] { lock.withLock { _all } }
        func add(_ event: AskProgress) { lock.withLock { _all.append(event) } }
    }

    private func ask(_ engine: AskEngine, _ question: String = "What did Sam commit to?", scope: AskScope = AskScope(), events: Events = Events()) async throws -> AskReply {
        try await engine.ask(question, scope: scope, in: library, now: Date(timeIntervalSince1970: 1_763_000_000), progress: { events.add($0) })
    }

    func testAnAnswerComesWithItsCitationsAndReportsProgressInOrder() async throws {
        let model = ScriptedSynthesisModel { _ in self.good }
        let engine = AskEngine(answerer: Answerer(model: model))
        let events = Events()
        let reply = try await ask(engine, events: events)
        XCTAssertEqual(reply.answer.status, .answered)
        XCTAssertEqual(reply.answer.sentences.first?.citations.first?.speaker, "Sam")
        XCTAssertEqual(reply.answer.query?.people, ["Sam"])
        XCTAssertEqual(events.all.first, .searching)
        XCTAssertEqual(events.all.last, .sentence(try XCTUnwrap(reply.answer.sentences.first)))
        XCTAssertTrue(events.all.contains(.answering))
        XCTAssertFalse(events.all.contains(.waiting))
        // What the model read: Sam's conversation, never the Personal one, and no summary.
        XCTAssertEqual(model.prompts.count, 1)
        XCTAssertTrue(model.prompts[0].contains("Weekly sync"))
    }

    func testNothingFoundIsNotFoundWithoutRunningAModel() async throws {
        let model = ScriptedSynthesisModel { _ in self.good }
        let answerer = Answerer(model: model)
        let reply = try await ask(AskEngine(answerer: answerer), "What is the refund policy for enterprise contracts?")
        XCTAssertEqual(reply.answer.status, .notFound(.nothingFound))
        XCTAssertEqual(answerer.asked, 0, "no model ran")
        XCTAssertNil(reply.statistics)
    }

    func testEverySentenceFailingTheQuoteCheckIsNotFoundWithTheClosestConversations() async throws {
        let model = ScriptedSynthesisModel { _ in
            #"{"status":"answered","sentences":[{"text":"Sam promised a refund.","cites":["P1"],"quote":"a refund by Monday morning"}],"missing":null}"#
        }
        let reply = try await ask(AskEngine(answerer: Answerer(model: model)))
        XCTAssertEqual(reply.answer.status, .notFound(.nothingVerified))
        XCTAssertEqual(reply.answer.dropped, 1)
        XCTAssertEqual(reply.answer.closest.first, library[0].id)
    }

    func testAPersonalConversationIsNeverGivenToTheModelWhileLocked() async throws {
        let model = ScriptedSynthesisModel { _ in self.good }
        let engine = AskEngine(answerer: Answerer(model: model))
        _ = try await ask(engine, "Whose comparison sheet is ready?", scope: AskScope(personal: .locked))
        XCTAssertFalse(model.prompts.joined().contains("vacation"))
        let open = try await ask(AskEngine(answerer: Answerer(model: ScriptedSynthesisModel { _ in self.good })), "Whose comparison sheet is ready?")
        XCTAssertNotNil(open)
    }

    func testAQuestionWaitsOnceBehindARunningJobAndThenIsAnswered() async throws {
        let model = ScriptedSynthesisModel { _ in self.good }
        let answerer = Answerer(model: model, busy: 3)
        let engine = AskEngine(answerer: answerer, retryDelay: .milliseconds(5))
        let events = Events()
        let reply = try await ask(engine, events: events)
        XCTAssertEqual(reply.answer.status, .answered)
        XCTAssertEqual(answerer.asked, 4)
        XCTAssertEqual(events.all.filter { $0 == .waiting }.count, 1, "it says so once")
        let waiting = try XCTUnwrap(events.all.firstIndex(of: .waiting)), answering = try XCTUnwrap(events.all.firstIndex(of: .answering))
        XCTAssertLessThan(waiting, answering)
    }

    func testCancellingWhileWaitingStopsAndShowsNothing() async throws {
        let model = ScriptedSynthesisModel { _ in self.good }
        let answerer = Answerer(model: model, busy: .max)
        let engine = AskEngine(answerer: answerer, retryDelay: .milliseconds(5))
        let events = Events()
        let task = Task { try await self.ask(engine, events: events) }
        while answerer.asked < 2 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled")
        } catch is CancellationError {
        }
        XCTAssertTrue(model.prompts.isEmpty)
        XCTAssertFalse(events.all.contains { if case .sentence = $0 { return true } else { return false } })
    }

    func testOtherErrorsEndTheQuestionRatherThanWaiting() async {
        struct Failure: Error {}
        let engine = AskEngine(answerer: Throwing(error: Failure()), retryDelay: .milliseconds(5))
        do {
            _ = try await ask(engine)
            XCTFail("An error")
        } catch is Failure {
        } catch {
            XCTFail("\(error)")
        }
    }

    private struct Throwing: QuestionAnswering {
        let error: any Error
        func answer(_ evidence: AskEvidence, closest: [UUID], query: AskQuery, progress: @escaping IntelligenceProgressHandler,
                    sentence: @escaping @Sendable (AskSentence) -> Void) async throws -> AskReply { throw error }
    }
}
