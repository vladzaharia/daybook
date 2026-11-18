import XCTest
@testable import DaybookCore

/// Strokes grouped into passages by time and place: pure functions of what the UI measures from a drawing.
final class PassageGroupingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let page = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// A stroke 12 points high, 40 wide, beginning `at` seconds in and lasting `lasting`.
    private func stroke(at: TimeInterval, x: Double = 20, y: Double = 100, width: Double = 40, height: Double = 12,
                        lasting: TimeInterval = 0.5, points: Int = 20) -> NotebookStroke {
        let began = start.addingTimeInterval(at)
        return NotebookStroke(key: NotebookStroke.key(began: began, pointCount: points, firstX: x, firstY: y), x: x, y: y, width: width, height: height,
                              start: began, end: began.addingTimeInterval(lasting))
    }

    func testBehaviorShortPausesFormOnePassage() {
        // A word, a breath, the next word far across the page: short pauses join whatever the place.
        let strokes = [stroke(at: 0), stroke(at: 1.5, x: 80), stroke(at: 3.5, x: 150), stroke(at: 5.5, x: 300, y: 400)]
        let groups = PassageGrouping.group(strokes, page: page)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].strokes.count, 4)
        XCTAssertEqual(groups[0].x, 20); XCTAssertEqual(groups[0].y, 100)
        XCTAssertEqual(groups[0].width, 320); XCTAssertEqual(groups[0].height, 312)
        XCTAssertEqual(groups[0].start, start)
        XCTAssertEqual(groups[0].end, start.addingTimeInterval(6))
    }

    func testBehaviorLongPauseStartsNewPassage() {
        // Right next to the earlier ink, but after more than nearPause.
        let strokes = [stroke(at: 0), stroke(at: 1), stroke(at: 30, x: 65), stroke(at: 31, x: 110)]
        let groups = PassageGrouping.group(strokes, page: page)
        XCTAssertEqual(groups.map(\.strokes.count), [2, 2])
        XCTAssertLessThan(groups[0].end, groups[1].start)
        XCTAssertNotEqual(groups[0].id, groups[1].id)
        XCTAssertNotEqual(groups[0].digest, groups[1].digest)
    }

    func testBehaviorMediumPauseJoinsOnlyWhenNear() {
        // A pause of 8 s: joins ink right after the passage, and doesn't join ink far below it.
        let near = PassageGrouping.group([stroke(at: 0), stroke(at: 8.5, x: 70)], page: page)
        XCTAssertEqual(near.count, 1)
        let below = PassageGrouping.group([stroke(at: 0), stroke(at: 8.5, x: 20, y: 400)], page: page)
        XCTAssertEqual(below.count, 2)
        let far = PassageGrouping.group([stroke(at: 0), stroke(at: 8.5, x: 360, y: 100)], page: page)
        XCTAssertEqual(far.count, 2, "more than two line heights across")
        // The next line down is within one and a half line heights (18 points at least).
        let nextLine = PassageGrouping.group([stroke(at: 0), stroke(at: 8.5, x: 20, y: 125)], page: page)
        XCTAssertEqual(nextLine.count, 1)
    }

    func testBehaviorLaterUnderlineInsideEarlierPassageJoinsIt() {
        // Two lines written, then (after a long pause and an unrelated note elsewhere) an underline under the first word.
        let strokes = [stroke(at: 0, x: 20, y: 100, width: 120), stroke(at: 2, x: 20, y: 130, width: 120),
                       stroke(at: 60, x: 20, y: 400, width: 100),
                       stroke(at: 100, x: 25, y: 112, width: 90, height: 0, lasting: 0.3)]
        let groups = PassageGrouping.group(strokes, page: page)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].strokes.count, 3, "the underline went back to the first passage")
        XCTAssertEqual(groups[0].end, start.addingTimeInterval(100.3))
        XCTAssertEqual(groups[1].strokes.count, 1)
        // A long later group isn't a revisit, however much it covers.
        let many = (0..<8).map { stroke(at: 100 + Double($0), x: 25, y: 105, width: 80) }
        XCTAssertEqual(PassageGrouping.group(Array(strokes.prefix(3)) + many, page: page).count, 3)
    }

    func testBehaviorPassageIDStableWhenLaterStrokesAdded() {
        let first = [stroke(at: 0), stroke(at: 1, x: 70)]
        let before = PassageGrouping.group(first, page: page)
        let after = PassageGrouping.group(first + [stroke(at: 2, x: 120)], page: page)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(before[0].id, after[0].id, "the passage is named by its first stroke")
        XCTAssertNotEqual(before[0].digest, after[0].digest, "but its strokes changed")
        XCTAssertEqual(before[0].id, NotebookPassage.id(page: page, firstStroke: first[0].key))
        XCTAssertNotEqual(before[0].id, NotebookPassage.id(page: UUID(), firstStroke: first[0].key), "another page, another passage")
    }

    func testBehaviorDigestIgnoresOrder() {
        XCTAssertEqual(PassageGrouping.digest(of: ["b", "a", "c"]), PassageGrouping.digest(of: ["c", "a", "b"]))
        XCTAssertNotEqual(PassageGrouping.digest(of: ["a", "b"]), PassageGrouping.digest(of: ["a", "b", "c"]))
        XCTAssertNotEqual(PassageGrouping.digest(of: ["a b"]), PassageGrouping.digest(of: ["a", "b"]))
        XCTAssertEqual(PassageGrouping.digest(of: ["a"]).count, 16)
        XCTAssertEqual(PassageGrouping.digest(of: ["a"]), String(AudioDigest.sha256(data: Data("a".utf8)).prefix(16)))
    }

    func testBehaviorDuplicateKeysUniquedInDrawingOrder() {
        XCTAssertEqual(NotebookStroke.uniqued(["a", "b", "a", "a", "b"]), ["a", "b", "a#2", "a#3", "b#2"])
        XCTAssertEqual(NotebookStroke.uniqued([]), [])
        let began = start
        // The key is the start in milliseconds, the point count, and the first point rounded.
        let reference = Int((began.timeIntervalSinceReferenceDate * 1000).rounded())
        XCTAssertEqual(NotebookStroke.key(began: began, pointCount: 31, firstX: 10.4, firstY: -3.6), "\(reference)-31-10--4")
        XCTAssertEqual(NotebookStroke.key(began: began, pointCount: 31, firstX: 10.2, firstY: -3.6),
                       NotebookStroke.key(began: began.addingTimeInterval(0.0001), pointCount: 31, firstX: 9.6, firstY: -4.4), "rounded alike")
        XCTAssertNotEqual(NotebookStroke.key(began: began, pointCount: 31, firstX: 10, firstY: 10), NotebookStroke.key(began: began, pointCount: 32, firstX: 10, firstY: 10))
    }

    func testBehaviorSameStrokesAnyOrderSameGroups() {
        var strokes = [stroke(at: 0), stroke(at: 1, x: 70), stroke(at: 30, y: 300), stroke(at: 31, x: 70, y: 300), stroke(at: 31, x: 130, y: 300),
                       stroke(at: 80, y: 500, points: 3)]
        // Two strokes the lasso copied: the same start and key, another place.
        strokes.append(stroke(at: 80, y: 500, points: 3))
        let expected = PassageGrouping.group(strokes, page: page)
        XCTAssertEqual(expected.count, 3)
        var random = SystemRandomNumberGenerator()
        for _ in 0..<12 {
            XCTAssertEqual(PassageGrouping.group(strokes.shuffled(using: &random), page: page), expected)
        }
        XCTAssertEqual(PassageGrouping.group(strokes.reversed(), page: page), expected)
        XCTAssertTrue(PassageGrouping.group([], page: page).isEmpty)
        // Groups come in the order they were begun.
        XCTAssertEqual(expected.map(\.start), expected.map(\.start).sorted())
    }

    func testBehaviorKindSketchWithoutWordsOrLowCoverage() {
        XCTAssertEqual(PassageKind.decide(words: nil, textCoverage: 1), .sketch)
        XCTAssertEqual(PassageKind.decide(words: "", textCoverage: 1), .sketch)
        XCTAssertEqual(PassageKind.decide(words: " \n ", textCoverage: nil), .sketch)
        XCTAssertEqual(PassageKind.decide(words: "budget", textCoverage: nil), .writing, "coverage unknown")
        XCTAssertEqual(PassageKind.decide(words: "budget", textCoverage: 0.6), .writing)
        XCTAssertEqual(PassageKind.decide(words: "budget", textCoverage: 0.59), .sketch, "a drawing with a label in it")
        XCTAssertEqual(PassageKind.decide(words: "budget", textCoverage: 1), .writing)
        XCTAssertEqual(PassageKind.writingCoverage, 0.6)
    }
}
