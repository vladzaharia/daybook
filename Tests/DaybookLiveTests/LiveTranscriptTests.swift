import DaybookCaptions
@testable import DaybookLive
import XCTest

/// Turning a streaming recognizer's pieces into captions: words, passages that close at a sentence's
/// end, a pause, or a length limit, and a tentative tail that keeps its identity as it grows.
final class LiveTranscriptTests: XCTestCase {
    private func token(_ text: String, _ start: Double, _ end: Double? = nil) -> LiveToken {
        LiveToken(text: text, start: start, end: end ?? start + 0.2)
    }

    func testPiecesBecomeWordsAndASentenceCloses() {
        var builder = LiveTranscriptBuilder()
        builder.add([token("▁Hel", 0.0), token("lo", 0.2), token("▁the", 0.5), token("re", 0.7)])
        XCTAssertEqual(builder.segments.map(\.text), ["Hello there"])
        XCTAssertEqual(builder.segments.map(\.isTentative), [true])
        let tentativeID = builder.segments[0].id
        builder.add([token("▁friend", 1.0), token(".", 1.2), token("▁Next", 1.5)])
        XCTAssertEqual(builder.segments.map(\.text), ["Hello there friend.", "Next"])
        XCTAssertEqual(builder.segments.map(\.isTentative), [false, true])
        XCTAssertEqual(builder.segments[0].id, tentativeID, "the passage keeps its identity when it becomes final, so views don't flicker")
        XCTAssertEqual(builder.segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(builder.segments[0].end, 1.4, accuracy: 0.001)
    }

    func testAPauseClosesAPassageAndControlTokensAreNeverWords() {
        var builder = LiveTranscriptBuilder()
        builder.add([token("<en-US>", 0), token("▁so", 0.1), token("▁yes", 0.4), token("<blank>", 0.6)])
        XCTAssertEqual(builder.segments.map(\.text), ["so yes"])
        XCTAssertFalse(builder.advance(to: 0.9), "still within the pause")
        XCTAssertTrue(builder.advance(to: 1.5), "a quiet stretch ends the passage")
        XCTAssertEqual(builder.segments.map(\.isTentative), [false])
        builder.add([token("▁later", 3)])
        XCTAssertEqual(builder.segments.map(\.text), ["so yes", "later"])
        // A pause between words splits passages even without a quiet call in between.
        builder.add([token("▁and", 3.3), token("▁much", 5.0)])
        XCTAssertEqual(builder.segments.map(\.text), ["so yes", "later and", "much"])
    }

    func testLongPassagesCloseAtTheLimitAndFinishKeepsWhatStands() {
        var builder = LiveTranscriptBuilder()
        builder.maximumSeconds = 3
        builder.add((0..<10).map { token("▁w\($0)", Double($0) * 0.5) })
        XCTAssertGreaterThan(builder.segments.count, 1)
        XCTAssertTrue(builder.segments.dropLast().allSatisfy { $0.end - $0.start <= 3.01 })
        builder.finish()
        XCTAssertTrue(builder.segments.allSatisfy { !$0.isTentative })
        XCTAssertEqual(builder.segments.map(\.text).joined(separator: " "), (0..<10).map { "w\($0)" }.joined(separator: " "))
    }

    func testPunctuationAfterAPlacedWordStillEndsTheSentence() {
        var builder = LiveTranscriptBuilder()
        builder.add([token("▁Done", 0)])
        builder.add([token("▁now", 0.3)])
        builder.add([token("?", 0.5), token("▁Yes", 0.8)])
        XCTAssertEqual(builder.segments.map(\.text), ["Done now?", "Yes"])
        XCTAssertEqual(builder.segments.map(\.isTentative), [false, true])
    }
}
