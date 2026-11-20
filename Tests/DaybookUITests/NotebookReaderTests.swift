#if canImport(PencilKit) && DEBUG
import DaybookCore
import PencilKit
import XCTest

@testable import DaybookUI

@MainActor
final class NotebookReaderTests: XCTestCase {
    func testBehaviorStrokeSummariesInPagePoints() throws {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let drawing = SyntheticInk.drawing("hello", origin: CGPoint(x: 100, y: 200), start: start)
        let strokes = NotebookReader.strokes(of: drawing)
        XCTAssertEqual(strokes.count, drawing.strokes.count)
        XCTAssertEqual(Set(strokes.map(\.key)).count, strokes.count, "keys are unique")
        let box = strokes.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        XCTAssertGreaterThan(box.minX, 90)
        XCTAssertLessThan(box.maxX, 100 + 46 * 5)
        XCTAssertGreaterThan(box.minY, 190)
        XCTAssertEqual(strokes[0].start, start)
        XCTAssertGreaterThan(strokes[0].end, strokes[0].start)
    }

    func testBehaviorKeysSurviveDataRoundTrip() throws {
        let drawing = SyntheticInk.drawing("world", start: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let again = try PKDrawing(data: drawing.dataRepresentation())
        XCTAssertEqual(NotebookReader.strokes(of: again).map(\.key), NotebookReader.strokes(of: drawing).map(\.key))
    }

    func testBehaviorTwoTimedClustersBecomeTwoPassages() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let drawing = SyntheticInk.page(passages: [
            .init(.words("hello"), at: CGPoint(x: 60, y: 80), size: 34, after: 0),
            .init(.sketch, at: CGPoint(x: 80, y: 360), size: 120, after: 30),
        ], start: start)
        let page = NotebookPage(order: 1)
        let reading = await NotebookReader.read(drawing, sha256: "abc", page: page) { moment in (nil, moment.timeIntervalSince(start)) }
        XCTAssertEqual(reading.passages.count, 2)
        XCTAssertEqual(reading.passages.map(\.time), [0, 30], "each timed from its first stroke")
        XCTAssertLessThan(reading.passages[0].y, reading.passages[1].y, "reading order is top to bottom")
        XCTAssertEqual(reading.groupingVersion, PassageGrouping.version)
        XCTAssertEqual(reading.drawingSHA256, "abc")
    }
}
#endif
