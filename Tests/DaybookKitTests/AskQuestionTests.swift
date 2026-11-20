import XCTest
@testable import DaybookKit

/// When what is typed in the search field reads as a question (docs/interface.md, "Asking a question").
final class AskQuestionTests: XCTestCase {
    func testBehaviorAQuestionMarkMakesAQuestion() {
        XCTAssertTrue(AskQuestion.readsAsQuestion("pricing?"))
        XCTAssertTrue(AskQuestion.readsAsQuestion("  What did Sam commit to?  "))
        XCTAssertTrue(AskQuestion.readsAsQuestion("Wie viel kostet das？"))
    }

    func testBehaviorAQuestionWordOrAuxiliaryOpensAQuestionOfThreeWordsOrMore() {
        for text in ["who owns the release notes", "What did we decide", "when is the beta", "where was the offsite held", "why did pricing change",
                     "how do we ship", "did Sam send it", "do we have a date", "does it export", "is the beta on", "are we late today",
                     "was it approved yesterday", "were there any blockers", "can we move the date", "should we hold the 14th"] {
            XCTAssertTrue(AskQuestion.readsAsQuestion(text), text)
        }
    }

    func testBehaviorShortAndOrdinarySearchesAreNotQuestions() {
        for text in ["", "   ", "how to", "do not", "what", "pricing", "release notes", "beta date 14th", "weekly sync", "sam", "#launch",
                     "the question is who", "who"] {
            XCTAssertFalse(AskQuestion.readsAsQuestion(text), text)
        }
    }

    func testBehaviorTextWithNoWordsIsNotAQuestionEvenWithAMark() {
        XCTAssertFalse(AskQuestion.readsAsQuestion("?"))
        XCTAssertFalse(AskQuestion.readsAsQuestion(" ?? "))
    }

    func testBehaviorTheFirstWordIsReadWholeSoAWordThatStartsLikeAnOpenerIsNot() {
        XCTAssertFalse(AskQuestion.readsAsQuestion("whatever the plan was"))
        XCTAssertFalse(AskQuestion.readsAsQuestion("island trip planning notes"))
        XCTAssertTrue(AskQuestion.readsAsQuestion("What’s the date today"), "a curly apostrophe doesn't split a word")
    }

    func testBehaviorTheRowsWordsAndASourceReadAsTheDesignSaysThem() {
        XCTAssertEqual(AskPageWords.askRow("Who owns it?"), "Ask “Who owns it?”")
        XCTAssertEqual(AskPageWords.waiting(for: "Weekly sync"), "Waiting for “Weekly sync”")
        XCTAssertEqual(AskPageWords.waiting(for: nil), "Waiting for another job")
        XCTAssertEqual(AskPageWords.timestamp(862), "14:22")
        XCTAssertEqual(AskPageWords.timestamp(3723), "1:02:03")
        XCTAssertEqual(AskPageWords.colophon(model: "Gemma 4 12B"), "Answered on this Mac with Gemma 4 12B")
    }

    func testBehaviorTheReadingLineAppearsOnlyWhenDatesOrPeopleWereFound() {
        XCTAssertNil(AskPageWords.reading(scope: "All Conversations", query: AskQuery(question: "q")))
        let range = AskDateRange(start: Date(), end: Date(), label: "October 2026")
        let query = AskQuery(question: "q", people: ["Sam"], dates: range)
        XCTAssertEqual(AskPageWords.reading(scope: "All Conversations", query: query), "All Conversations · October 2026 · Sam")
    }
}
