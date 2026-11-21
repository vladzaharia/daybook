import DaybookCore
import XCTest

/// The transcript quality bar: words compared, spans chosen.
final class TranscriptAgreementTests: XCTestCase {
    func testBehaviorWordsIgnoreCaseAndPunctuation() {
        XCTAssertEqual(TranscriptAgreement.words("Hello, World! It’s 3 o'clock."), ["hello", "world", "it's", "3", "o'clock"])
        XCTAssertEqual(TranscriptAgreement.distance(["a", "b", "c"], ["a", "x", "c", "d"]), 2)
        XCTAssertEqual(TranscriptAgreement.distance([], ["a"]), 1)
    }

    private func sentence(_ count: Int, changing changed: Int = 0) -> (String, String) {
        let words = (0..<count).map { "word\($0)" }
        var copy = words
        for index in 0..<changed { copy[index * (count / max(changed, 1))] = "other" }
        return (words.joined(separator: " "), copy.joined(separator: " "))
    }

    func testBehaviorTheBarsHold() {
        let spans = (0..<10).map { _ in sentence(100, changing: 4) }.map { (original: $0.0, copy: $0.1) }
        XCTAssertTrue(TranscriptAgreement.judge(spans, bar: .deterministic).passes, "4% everywhere")
        var oneBad = spans
        let bad = sentence(100, changing: 9)
        oneBad[3] = (bad.0, bad.1)
        let result = TranscriptAgreement.judge(oneBad, bar: .deterministic)
        XCTAssertFalse(result.passes, "9% in one span is over 8%")
        XCTAssertEqual(result.worstSpan ?? 0, 0.09, accuracy: 1e-9)
        XCTAssertTrue(TranscriptAgreement.judge(oneBad, bar: .nondeterministic).passes, "no per-span bound, 4.5% overall")
        let six = (0..<10).map { _ in sentence(100, changing: 6) }.map { (original: $0.0, copy: $0.1) }
        XCTAssertFalse(TranscriptAgreement.judge(six, bar: .deterministic).passes, "6% over the sample")
        let thirteen = (0..<10).map { _ in sentence(100, changing: 13) }.map { (original: $0.0, copy: $0.1) }
        XCTAssertFalse(TranscriptAgreement.judge(thirteen, bar: .nondeterministic).passes)
        // A short span isn't held to the per-span bound.
        let short = sentence(10, changing: 2)
        XCTAssertTrue(TranscriptAgreement.judge(spans + [(original: short.0, copy: short.1)], bar: .deterministic).passes)
        // Nothing heard in the original where its transcript has speech: nothing to compare, never a pass, whatever the
        // copy says (words 0 is how the caller tells "couldn't check" from a refusal).
        for copy in ["", "hello"] {
            let result = TranscriptAgreement.judge([(original: "", copy: copy), (original: " ,. ", copy: copy)], bar: .deterministic)
            XCTAssertFalse(result.passes, copy)
            XCTAssertEqual(result.words, 0)
            XCTAssertNil(result.disagreement)
        }
    }

    func testBehaviorSpansFollowTheSpeech() {
        XCTAssertEqual(TranscriptSample.spans([]), [])
        // Under ten minutes of speech: all of it, in spans of at most 60 s.
        let short = TranscriptSample.spans([10...100, 200...230])
        XCTAssertEqual(short, [10...70, 70...100, 200...230])
        // An hour of speech: ten 60 s spans spread through it.
        let long = TranscriptSample.spans([0...3_600])
        XCTAssertEqual(long.count, 10)
        XCTAssertTrue(long.allSatisfy { $0.upperBound - $0.lowerBound == 60 })
        XCTAssertLessThan(long.first!.lowerBound, 400)
        XCTAssertGreaterThan(long.last!.lowerBound, 3_000)
        // Clipped to the recording.
        XCTAssertEqual(TranscriptSample.spans([10...100], duration: 50), [10...50])
    }

    func testBehaviorSpeechComesFromTheTrackOrTheCopyMadeFromIt() {
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/m.caf", fileName: "m.caf")
        let echo = RecordingTrack(source: .microphone, relativePath: "Originals/e.caf", fileName: "e.caf", derivedFrom: mic.id, processing: "echo-cancelled")
        let segments = [TranscriptSegment(trackID: echo.id, start: 1, end: 4, text: "hi"), TranscriptSegment(trackID: echo.id, start: 4.2, end: 9, text: "there")]
        let meeting = Meeting(tracks: [mic, echo], transcripts: [TrackTranscript(trackID: echo.id, segments: segments)])
        XCTAssertEqual(TranscriptSample.speech(of: mic, in: meeting), [1...9])
        XCTAssertEqual(TranscriptSample.speech(of: echo, in: meeting), [1...9])
        XCTAssertEqual(TranscriptSample.speech(of: mic, in: Meeting(tracks: [mic])), [])
    }
}
