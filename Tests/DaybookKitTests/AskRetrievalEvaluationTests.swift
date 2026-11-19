import DaybookCore
import XCTest
@testable import DaybookKit

/// Retrieval's recall on the synthetic evaluation library (Tests/DaybookKitTests/AskEvaluation): deterministic and
/// model-free, so it guards ranking changes. The numbers are in docs/validation.md; the questions marked "held" were
/// not looked at while the ranking was tuned.
final class AskRetrievalEvaluationTests: XCTestCase {
    private func library() throws -> AskEvaluation.Library {
        let folder = try XCTUnwrap(Bundle.module.url(forResource: "AskEvaluation", withExtension: nil))
        return try AskEvaluation.load(library: folder.appendingPathComponent("library.json"), questions: folder.appendingPathComponent("questions.json"))
    }

    private func results(_ library: AskEvaluation.Library, heldOut: Bool) throws -> [AskEvaluation.RetrievalResult] {
        let index = LibraryPassageIndex()
        return try library.questions.filter { $0.answerable && $0.isHeldOut == heldOut }.map { question in
            try AskEvaluation.result(of: question, retrieval: AskEvaluation.retrieve(question, in: library, index: index), in: library)
        }
    }

    func testTheLibraryHasTwentyConversationsAndSixtyQuestionsAThirdHeldOut() throws {
        let library = try library()
        XCTAssertEqual(library.meetings.count, 20)
        XCTAssertEqual(library.questions.count, 60)
        XCTAssertEqual(library.questions.filter(\.isHeldOut).count, 20)
        XCTAssertEqual(Set(library.questions.map(\.id)).count, 60)
        XCTAssertEqual(library.questions.filter { !$0.answerable && !$0.personal }.count, 9, "About 15% have no answer")
    }

    func testRetrievalFindsTheEvidenceOnTheTuningQuestions() throws {
        let library = try library()
        let found = try results(library, heldOut: false)
        let recall = AskEvaluation.recall(found)
        print("Ask retrieval, tuning: \(recall)")
        for miss in found where !miss.inEvidence { print("  not in evidence: \(miss.id) \(miss.question)") }
        XCTAssertGreaterThanOrEqual(recall.inEvidencePercent, 85)
        XCTAssertGreaterThanOrEqual(recall.atThreePercent, 70)
    }

    func testRetrievalFindsTheEvidenceOnTheHeldOutQuestions() throws {
        let library = try library()
        let recall = AskEvaluation.recall(try results(library, heldOut: true))
        print("Ask retrieval, held out: \(recall)")
        XCTAssertGreaterThanOrEqual(recall.inEvidencePercent, 80)
    }

    func testNoPersonalConversationIsReadWhileTheLockIsLocked() throws {
        let library = try library()
        let personal = Set(library.meetings.filter { $0.effectivePlacement == .personal }.map(\.id))
        XCTAssertEqual(personal.count, 2)
        let index = LibraryPassageIndex()
        for question in library.questions {
            let retrieval = try AskEvaluation.retrieve(question, in: library, index: index, locked: true)
            let read = Set((retrieval.evidence?.conversations ?? []).map(\.meetingID))
            XCTAssertTrue(read.isDisjoint(with: personal), question.text)
            XCTAssertTrue(Set(retrieval.closest).isDisjoint(with: personal), question.text)
        }
    }

    func testRetrievalAloneEndsSomeQuestionsNothingAnswers() throws {
        let library = try library()
        let index = LibraryPassageIndex()
        let unanswerable = library.questions.filter { !$0.answerable && !$0.personal }
        let stopped = try unanswerable.filter { try AskEvaluation.retrieve($0, in: library, index: index).evidence == nil }
        print("Ask retrieval stopped \(stopped.count) of \(unanswerable.count) unanswerable questions before any model ran")
        for question in unanswerable where !stopped.contains(question) { print("  read: \(question.id) \(question.text)") }
        // A question that names dates nothing is from, or has no word in the library, reads nothing.
        XCTAssertTrue(stopped.contains { $0.text.contains("August") }, "No conversation is from August")
        XCTAssertFalse(stopped.isEmpty)
    }
}
