import XCTest

@testable import DaybookPhone

/// The library's selection bar: at most five items, Trash last and outside More.
final class SelectionBarLayoutTests: XCTestCase {
  private func split(_ items: [String]) -> (bar: [String], more: [String], trash: String?) {
    SelectionBarLayout.split(items) { $0 == "Trash" }
  }

  func testFiveOrFewerItemsAllShowWithTrashLast() {
    let result = split(["Summarize", "Move", "Tags", "Merge", "Trash"])
    XCTAssertEqual(result.bar, ["Summarize", "Move", "Tags", "Merge"])
    XCTAssertTrue(result.more.isEmpty)
    XCTAssertEqual(result.trash, "Trash")
  }

  func testSixItemsFoldTheOverflowIntoMoreAndKeepTrashOutsideIt() {
    let result = split(["Summarize", "Move", "Tags", "Personal", "Merge", "Trash"])
    XCTAssertEqual(result.bar, ["Summarize", "Move", "Tags"])
    XCTAssertEqual(result.more, ["Personal", "Merge"])
    XCTAssertEqual(result.trash, "Trash")
    XCTAssertEqual(result.bar.count + 1 + 1, 5, "three items, More and Trash")
  }

  func testWithoutTrashTheBarStillHoldsFive() {
    let result = split(["A", "B", "C", "D", "E", "F"])
    XCTAssertEqual(result.bar, ["A", "B", "C", "D"])
    XCTAssertEqual(result.more, ["E", "F"])
    XCTAssertNil(result.trash)
  }
}
