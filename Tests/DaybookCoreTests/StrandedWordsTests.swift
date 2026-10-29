import XCTest
@testable import DaybookCore

/// Words speaker analysis left between turns ("Unknown speaker: I" splitting a sentence) join the
/// turn they sit against, in stored transcripts and when fusing them.
final class StrandedWordsTests: XCTestCase {
    let mic = UUID(), call = UUID()

    func segment(_ track: UUID, _ start: Double, _ end: Double, _ text: String, _ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(trackID: track, start: start, end: end, text: text, speakerID: speaker)
    }

    func testAWordBetweenOnePersonsPassagesBecomesTheirs() {
        let segments = [segment(mic, 0, 5, "Hello, it's all right. Um", "me"), segment(mic, 5.1, 5.3, "I", nil),
                        segment(mic, 5.4, 9, "just came back from a shopping trip", "me")]
        XCTAssertEqual(segments.labellingStrandedWords().map(\.speakerID), ["me", "me", "me"])
        XCTAssertTrue(segments.hasStrandedWords)
        XCTAssertFalse(segments.labellingStrandedWords().hasStrandedWords)
    }

    func testBetweenTwoPeopleItJoinsTheNearerAndWithOneNeighbourThatOne() {
        let between = [segment(mic, 0, 2, "Shall we start?", "a"), segment(mic, 2.7, 2.9, "Yes", nil), segment(mic, 3.0, 5, "let's go", "b")]
        XCTAssertEqual(between.labellingStrandedWords()[1].speakerID, "b")
        let first = [segment(mic, 0, 0.2, "So", nil), segment(mic, 0.5, 3, "here's the plan", "a")]
        XCTAssertEqual(first.labellingStrandedWords()[0].speakerID, "a")
        let last = [segment(mic, 0, 3, "that's all", "a"), segment(mic, 3.4, 3.6, "thanks", nil)]
        XCTAssertEqual(last.labellingStrandedWords()[1].speakerID, "a")
    }

    func testSpeechAndFarOffWordsStayUnlabelled() {
        let segments = [segment(mic, 0, 2, "Hello", "a"), segment(mic, 2.2, 4, "four words of speech", nil),
                        segment(mic, 9, 9.3, "hm", nil), segment(mic, 12, 14, "bye", "a")]
        XCTAssertEqual(segments.labellingStrandedWords().map(\.speakerID), ["a", nil, nil, "a"], "speech nobody was found for, and a word far from anyone")
    }

    func testOnlyPassagesOfTheSameRecordingCount() {
        let segments = [segment(call, 0, 3, "Over the call", "caller"), segment(mic, 3.1, 3.3, "Right", nil)]
        XCTAssertEqual(segments.labellingStrandedWords().map(\.speakerID), ["caller", nil])
    }

    /// Regression: transcripts made before the builder joined such words still had them, and the
    /// conversation read "Me: … / Unknown speaker: I / Me: just came back …".
    func testFusionJoinsThemFromStoredTranscripts() {
        let transcript = TrackTranscript(trackID: mic, segments: [
            segment(mic, 0, 5, "Hello, it's all right. Um", "run:S1"), segment(mic, 5.1, 5.3, "I", nil),
            segment(mic, 5.4, 9, "just came back from a shopping trip to get goalie equipment", "run:S1"),
            segment(mic, 9.1, 9.3, "for", nil), segment(mic, 9.4, 12, "hockey.", "run:S1"),
        ])
        let track = RecordingTrack(id: mic, source: .microphone, relativePath: "mic.caf", fileName: "mic.caf")
        let fused = TranscriptFusion.fuse([transcript], tracks: [track])
        XCTAssertFalse(fused.segments.isEmpty)
        XCTAssertTrue(fused.segments.allSatisfy { $0.speakerID != nil }, "no one-word passages of no one")
        XCTAssertEqual(fused.segments.map(\.text).joined(separator: " "),
                       "Hello, it's all right. Um I just came back from a shopping trip to get goalie equipment for hockey.")
    }
}
