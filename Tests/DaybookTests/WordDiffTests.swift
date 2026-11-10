import DaybookKit
import DaybookUI
import SwiftUI
import XCTest

/// Version History's word marks on the Mac: what changed, word by word (DaybookKit's `WordChanges`), drawn with
/// DaybookUI's `RevisionMarks`, as on the iPhone.
final class WordDiffTests: XCTestCase {
    func testTokensKeepTrailingWhitespaceWithTheirWord() {
        XCTAssertEqual(WordChanges.tokens("Ship the  sink\nfix").map(String.init), ["Ship ", "the  ", "sink\n", "fix"])
        XCTAssertEqual(WordChanges.tokens("").count, 0)
    }

    func testChangesMarkOnlyTheReplacedWord() {
        let old = WordChanges.tokens("We should ship the sink fix today")
        let new = WordChanges.tokens("We should ship the sync fix today")
        let changes = WordChanges.changes(old: old, new: new)
        XCTAssertEqual(Array(changes.removed), [4])
        XCTAssertEqual(Array(changes.inserted), [4])
    }

    func testMarkedTextReadsTheSameAsTheOriginal() {
        let old = "Alex will send the deck.\nThen review."
        let new = "Alex will send the final deck.\nThen review on Friday."
        for dark in [false, true] {
            let marked = WordChanges.marked(old: AttributedString(old), new: AttributedString(new),
                                            removed: RevisionMarks.removed(dark: dark), inserted: RevisionMarks.inserted(dark: dark))
            XCTAssertEqual(String(marked.old.characters), old)
            XCTAssertEqual(String(marked.new.characters), new)
            // Only the inserted words are washed, not the space after them.
            let washed = marked.new.runs[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self]
                .filter { $0.0 != nil }.map { String(marked.new[$0.1].characters) }
            XCTAssertTrue(washed.contains("final"), "\(washed)")
            XCTAssertFalse(washed.contains { $0.contains(" ") || $0.contains("\n") }, "\(washed)")
        }
    }

    func testWhitespaceOnlyChangesAreNotMarked() {
        let changes = WordChanges.changes(old: WordChanges.tokens("one two"), new: WordChanges.tokens("one  two"))
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertTrue(changes.inserted.isEmpty)
    }
}
