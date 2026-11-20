import XCTest
@testable import DaybookKit

/// How an answer is scored against a question's known facts, and the words Ask shows.
final class AskEvaluationScoringTests: XCTestCase {
    private func question(answerable: Bool = true, facts: [[String]] = [["twelve", "12"], ["november"]], forbidden: [String] = ["nine"]) -> AskEvaluation.Question {
        AskEvaluation.Question(id: "q", text: "?", category: "latest", split: "tune", scope: "all", conversation: nil, answerable: answerable,
                               personal: false, facts: facts, forbidden: forbidden, evidence: [])
    }

    private func answer(_ text: String) -> AskAnswer {
        AskAnswer(status: .answered, sentences: [AskSentence(text: text, citations: [], quote: "")])
    }

    func testAnAnswerWithEveryFactAndNoForbiddenWordIsCorrect() {
        XCTAssertEqual(AskEvaluation.outcome(of: answer("It is 12 dollars from November third."), for: question()), .correct)
    }

    func testAMissingFactOrAForbiddenWordIsWrong() {
        XCTAssertEqual(AskEvaluation.outcome(of: answer("It is twelve dollars."), for: question()), .wrong)
        XCTAssertEqual(AskEvaluation.outcome(of: answer("Twelve from November, replacing nine."), for: question()), .wrong)
    }

    func testNotFoundIsRightOnlyWhenNothingAnswers() {
        let notFound = AskAnswer(status: .notFound(.modelSaidSo))
        XCTAssertEqual(AskEvaluation.outcome(of: notFound, for: question()), .missed)
        XCTAssertEqual(AskEvaluation.outcome(of: notFound, for: question(answerable: false)), .rightlyNotFound)
        XCTAssertEqual(AskEvaluation.outcome(of: answer("Twelve in November."), for: question(answerable: false)), .wrong)
    }

    func testRecallCountsRanksAndEvidence() {
        func result(_ rank: Int?, _ inEvidence: Bool) -> AskEvaluation.RetrievalResult {
            .init(question: "", id: "", category: "", isHeldOut: false, rank: rank, inEvidence: inEvidence)
        }
        let recall = AskEvaluation.recall([result(1, true), result(3, true), result(5, true), result(nil, false)])
        XCTAssertEqual(recall, AskEvaluation.Recall(questions: 4, atOne: 1, atThree: 2, inEvidence: 3))
        XCTAssertEqual(recall.atThreePercent, 50)
    }

    func testTheWords() {
        XCTAssertEqual(AskWords.notFound, "Nothing here answers that.")
        XCTAssertEqual(AskWords.notFound(in: "Work"), "Nothing in Work answers that.")
        XCTAssertTrue(AskWords.sameName("Sam", "Sam Rivera"))
        XCTAssertTrue(AskWords.sameName("José", "jose"))
        XCTAssertFalse(AskWords.sameName("Sam Rivera", "Sam Okafor"))
    }
}
