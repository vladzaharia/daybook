import DaybookCore
import XCTest
@testable import DaybookIntelligence

final class TranscriptBuilderTests: XCTestCase {
    private func track(_ source: AudioSource = .imported, offset: Double? = nil) -> RecordingTrack {
        RecordingTrack(source: source, relativePath: "Originals/test.caf", fileName: "test.caf", offset: offset)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> RecognizedWord {
        RecognizedWord(text: text, start: start, end: end, confidence: 0.95)
    }

    private func result(_ words: [RecognizedWord], text: String? = nil) -> RecognitionResult {
        RecognitionResult(segments: [RecognizedSegment(start: words.first?.start ?? 0,
            end: words.last?.end ?? 1, text: text ?? words.map(\.text).joined(), confidence: 0.9, words: words)], language: "en", duration: 30)
    }

    private func analysis(_ turns: [(String, Double, Double)]) -> SpeakerAnalysis {
        SpeakerAnalysis(turns: turns.map { SpeakerTurn(speakerID: $0.0, start: $0.1, end: $0.2, confidence: 0.9) }, embeddings: [:])
    }

    func testWordTimestampsSplitAnASRSegmentAtActualSpeakerChanges() {
        let source = track(.systemAudio, offset: 100)
        let words = [word(" Hello", 0, 0.4), word(" there.", 0.4, 1), word(" Hi", 1.2, 1.5), word(" Alex.", 1.5, 2)]
        let turns = analysis([("speaker_0", 0, 1.1), ("speaker_1", 1.1, 2.1)])
        let segments = TranscriptBuilder.segments(result: result(words), speakers: turns, track: source)
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Hi Alex."])
        XCTAssertEqual(segments.map(\.speakerID), ["\(source.id):speaker_0", "\(source.id):speaker_1"])
        XCTAssertEqual(segments.map(\.start), [0, 1.2], "Track offsets belong to fusion, not original transcript timestamps")
        XCTAssertEqual(segments.map(\.end), [1, 2])
        XCTAssertTrue(segments.allSatisfy { $0.trackID == source.id })
    }

    func testMissingDiarizationDoesNotInventSpeakerFromSource() {
        for source in AudioSource.allCases {
            let segments = TranscriptBuilder.segments(result: result([word(" Hello.", 0, 1)]), speakers: nil, track: track(source))
            XCTAssertEqual(segments.count, 1)
            XCTAssertNil(segments.first?.speakerID, "A microphone or system track is not proof of speaker identity")
        }
    }

    func testWordsOutsideDiarizationTurnsRemainUnknown() {
        let source = track()
        let words = [word(" Known", 0, 0.5), word(" uncertain", 1, 1.5), word(" again", 2, 2.5)]
        let segments = TranscriptBuilder.segments(result: result(words), speakers: analysis([("A", 0, 0.6), ("A", 2, 3)]), track: source)
        XCTAssertEqual(segments.map(\.text), ["Known", "uncertain", "again"])
        XCTAssertEqual(segments.map(\.speakerID), ["\(source.id):A", nil, "\(source.id):A"])
    }

    func testLongSilenceSeparatesSameSpeakerPassages() {
        let words = [word(" First.", 0, 0.5), word(" Next.", 2.5, 3)]
        let segments = TranscriptBuilder.segments(result: result(words), speakers: analysis([("A", 0, 4)]), track: track())
        XCTAssertEqual(segments.map(\.text), ["First.", "Next."])
        XCTAssertEqual(segments.map(\.start), [0, 2.5])
    }

    func testWhitespaceOnlyRecognitionSegmentsAreIgnored() {
        let recognition = RecognitionResult(segments: [
            RecognizedSegment(start: 0, end: 1, text: " \n\t", confidence: 1, words: []),
            RecognizedSegment(start: 2, end: 3, text: "  Keep this. \n", confidence: 0.8, words: [])
        ], language: nil, duration: 3)
        let segments = TranscriptBuilder.segments(result: recognition, speakers: nil, track: track())
        XCTAssertEqual(segments.map(\.text), ["Keep this."])
        XCTAssertEqual(segments.map(\.start), [2])
    }

    func testWhitespaceWordBetweenSpeakersDoesNotCreateEmptyPassage() {
        let words = [word(" Hello", 0, 0.4), word(" \n", 0.5, 0.9), word(" world.", 1, 1.4)]
        let segments = TranscriptBuilder.segments(result: result(words), speakers: analysis([("A", 0, 0.4), ("B", 1, 1.4)]), track: track())
        XCTAssertEqual(segments.map(\.text), ["Hello", "world."])
        XCTAssertFalse(segments.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func testWhitespaceTokensWithinOneSpeakerPreserveWordSeparation() {
        let words = [word("Hello", 0, 0.4), word(" ", 0.4, 0.5), word("world", 0.5, 1), word(".", 1, 1.1)]
        let segments = TranscriptBuilder.segments(result: result(words), speakers: analysis([("A", 0, 2)]), track: track())
        XCTAssertEqual(segments.map(\.text), ["Hello world."])
    }

    func testSpeakerLabelsAreNamespacedAcrossSourceRecordings() {
        let first = track(.microphone)
        let second = track(.soundcore)
        let recognized = result([word(" Same model label.", 0, 1)])
        let turns = analysis([("speaker_0", 0, 1)])
        let firstSegment = TranscriptBuilder.segments(result: recognized, speakers: turns, track: first).first!
        let secondSegment = TranscriptBuilder.segments(result: recognized, speakers: turns, track: second).first!
        XCTAssertNotEqual(firstSegment.speakerID, secondSegment.speakerID)
        XCTAssertEqual(firstSegment.speakerID, "\(first.id):speaker_0")
        XCTAssertEqual(secondSegment.speakerID, "\(second.id):speaker_0")
    }

    func testWordCrossingTurnBoundaryUsesGreatestOverlap() {
        let source = track()
        let segments = TranscriptBuilder.segments(result: result([word(" Boundary", 0.8, 1.4)]),
            speakers: analysis([("A", 0, 1), ("B", 1, 2)]), track: source)
        XCTAssertEqual(segments.first?.speakerID, "\(source.id):B")
    }

    func testSegmentOnlyRecognitionFallsBackToTurnOverlap() {
        let source = track()
        let recognition = RecognitionResult(segments: [RecognizedSegment(start: 1, end: 4, text: "No word alignment available.", confidence: 0.75, words: [])], language: "en", duration: 4)
        let segments = TranscriptBuilder.segments(result: recognition, speakers: analysis([("A", 0, 1.5), ("B", 1.5, 4)]), track: source)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.speakerID, "\(source.id):B")
        XCTAssertEqual(segments.first?.confidence, 0.75)
        XCTAssertEqual(segments.first?.text, "No word alignment available.")
    }
}
