import XCTest

@testable import DaybookCore

final class NotebookModeEditingTests: XCTestCase {
    private let at = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testBehaviorErasuresAreKeptOncePerStrokeAndBounded() {
        var meeting = Meeting(title: "Notes")
        let page = NotebookPage(order: 1, now: at)
        meeting.addPage(page)
        meeting.recordErasures([ErasedStroke(key: "a", madeAt: at, erasedAt: at.addingTimeInterval(5), time: 12)], on: page.id, now: at)
        meeting.recordErasures([ErasedStroke(key: "a", madeAt: at, erasedAt: at.addingTimeInterval(9)),
                                ErasedStroke(key: "b", madeAt: at, erasedAt: at.addingTimeInterval(6))], on: page.id, now: at)
        XCTAssertEqual(meeting.page(page.id)?.erased?.map(\.key), ["a", "b"])
        XCTAssertEqual(meeting.page(page.id)?.erased?.first?.time, 12, "the copy that knows where in the recording it was is kept")
        let many = (0..<(ErasedStroke.capacity + 30)).map { ErasedStroke(key: "k\($0)", madeAt: at, erasedAt: at.addingTimeInterval(Double($0))) }
        meeting.recordErasures(many, on: page.id, now: at)
        XCTAssertEqual(meeting.page(page.id)?.erased?.count, ErasedStroke.capacity)
    }

    func testBehaviorPageTurnsAreLoggedOnceAndInOrder() {
        var meeting = Meeting(title: "Notes")
        let one = UUID(), two = UUID()
        let later = PageTurn(at: at.addingTimeInterval(60), pages: [two], time: 61)
        let first = PageTurn(at: at, pages: [one], time: 1)
        meeting.logPageTurn(later)
        meeting.logPageTurn(first)
        meeting.logPageTurn(first)
        XCTAssertEqual(meeting.pageTurns?.map(\.time), [1, 61])
        meeting.logPageTurn(PageTurn(at: at.addingTimeInterval(90), pages: []))
        XCTAssertEqual(meeting.pageTurns?.last?.pages, [], "closing the notebook is a turn to no pages")
    }
}
