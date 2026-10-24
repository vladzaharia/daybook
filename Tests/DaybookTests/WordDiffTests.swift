import XCTest
@testable import Daybook

final class WordDiffTests: XCTestCase {
    func testTokensKeepTrailingWhitespaceWithTheirWord() {
        XCTAssertEqual(WordDiff.tokens("Ship the  sink\nfix").map(String.init), ["Ship ", "the  ", "sink\n", "fix"])
        XCTAssertEqual(WordDiff.tokens("").count, 0)
    }

    func testChangesMarkOnlyTheReplacedWord() {
        let old = WordDiff.tokens("We should ship the sink fix today")
        let new = WordDiff.tokens("We should ship the sync fix today")
        let changes = WordDiff.changes(old: old, new: new)
        XCTAssertEqual(Array(changes.removed), [4])
        XCTAssertEqual(Array(changes.inserted), [4])
    }

    func testMarkedTextReadsTheSameAsTheOriginal() {
        let old = "Alex will send the deck.\nThen review."
        let new = "Alex will send the final deck.\nThen review on Friday."
        let marked = WordDiff.marked(old: old, new: new)
        XCTAssertEqual(String(marked.old.characters), old)
        XCTAssertEqual(String(marked.new.characters), new)
    }

    func testWhitespaceOnlyChangesAreNotMarked() {
        let changes = WordDiff.changes(old: WordDiff.tokens("one two"), new: WordDiff.tokens("one  two"))
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertTrue(changes.inserted.isEmpty)
    }
}
