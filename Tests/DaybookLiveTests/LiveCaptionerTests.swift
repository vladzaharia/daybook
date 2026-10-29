import AVFoundation
import DaybookCaptions
import DaybookKit
@testable import DaybookLive
import DaybookTestSupport
import XCTest

/// The live captioners with scripted models: local words on the capture's timeline, speakers and
/// names added to any captioner's words, backing off under load, and failures that end only the
/// captions. No model runs here.
final class LiveCaptionerTests: XCTestCase {
    /// A recognizer that "hears" scripted tokens once enough audio has been fed.
    final class ScriptedTranscriber: LiveTranscribing, @unchecked Sendable {
        let script: [(at: Double, tokens: [LiveToken])]
        private let lock = NSLock()
        private var fed = 0
        private var said = 0
        private(set) var finished = false
        var samplesFed: Int { lock.withLock { fed } }

        init(_ script: [(at: Double, tokens: [LiveToken])]) { self.script = script }

        func transcribe(_ samples: [Float]) async throws -> [LiveToken] {
            lock.withLock {
                fed += samples.count
                let heard = Double(fed) / 16_000
                let due = script.enumerated().filter { $0.offset >= said && $0.element.at <= heard }
                said += due.count
                return due.flatMap(\.element.tokens)
            }
        }

        func finish() async throws -> [LiveToken] {
            lock.withLock {
                finished = true
                defer { said = script.count }
                return script.dropFirst(said).flatMap(\.tokens)
            }
        }
    }

    /// A speaker model that reports scripted activity: `slot` speaks while fed time is in its span.
    final class ScriptedDiarizer: LiveDiarizing, @unchecked Sendable {
        let frameSeconds = 0.01
        let speakerSlots = 4
        let spans: [(slot: Int, from: Double, to: Double)]
        private var frame = 0
        private var pending = 0

        init(_ spans: [(slot: Int, from: Double, to: Double)]) { self.spans = spans }

        func diarize(_ samples: [Float]) throws -> [LiveSpeakerFrames] {
            pending += samples.count
            let frames = pending / 160
            pending -= frames * 160
            return frames > 0 ? [emit(frames)] : []
        }

        func finish() throws -> [LiveSpeakerFrames] { [] }

        private func emit(_ count: Int) -> LiveSpeakerFrames {
            var probabilities = [Float](repeating: 0, count: count * speakerSlots)
            for index in 0..<count {
                let time = Double(frame + index) * frameSeconds
                for span in spans where time >= span.from && time < span.to { probabilities[index * speakerSlots + span.slot] = 0.9 }
            }
            frame += count
            return LiveSpeakerFrames(probabilities: probabilities, frames: count, speakers: speakerSlots)
        }
    }

    /// Embeds by the span's loudness, so each scripted voice has its own direction.
    struct LoudnessEmbedding: LiveVoiceEmbedding {
        let space = "test-space"
        func embed(_ samples: [Float]) throws -> [Float] {
            let level = samples.map(abs).max() ?? 0
            return level > 0.4 ? [1, 0, 0] : [0, 1, 0]
        }
    }

    /// 100 ms of 16 kHz audio at `level`, stamped `seconds` into the capture.
    static func buffer(_ level: Float = 0.1) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: LiveAudio.format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = level * sin(Float(index) * 0.3) }
        return buffer
    }

    static func time(_ seconds: Double) -> AVAudioTime { AVAudioTime(sampleTime: AVAudioFramePosition(seconds * 16_000), atRate: 16_000) }

    private func collect(_ captioner: any LiveCaptioning) -> (Task<[LiveCaptionSegment], Never>, Task<[LiveCaptionState], Never>) {
        let updates = Task { var last: [LiveCaptionSegment] = []; for await snapshot in captioner.updates { last = snapshot }; return last }
        let states = Task { var all: [LiveCaptionState] = []; for await state in captioner.states { all.append(state) }; return all }
        return (updates, states)
    }

    // MARK: Local words

    func testLocalWordsArriveOnTheCapturesTimelineAndFinishFinal() async throws {
        let transcriber = ScriptedTranscriber([
            (0.5, [LiveToken(text: "▁Budget", start: 0.1, end: 0.4), LiveToken(text: "▁agreed", start: 0.4, end: 0.8), LiveToken(text: ".", start: 0.8, end: 0.9)]),
            (1.5, [LiveToken(text: "▁Next", start: 1.2, end: 1.4)]),
        ])
        let captioner = LocalStreamingCaptioner(timelineOrigin: 0, makeTranscriber: { _ in transcriber })
        let (updates, states) = collect(captioner)
        await captioner.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)
        // One second, then a ten-second gap (dropped audio), then a second more.
        for index in 0..<10 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        for index in 0..<10 { captioner.append(Self.buffer(), at: Self.time(11 + Double(index) * 0.1)) }
        try await waitUntil("all audio fed") { transcriber.samplesFed >= 32_000 }
        await captioner.finish()
        let segments = await updates.value
        XCTAssertEqual(segments.map(\.text), ["Budget agreed.", "Next"])
        XCTAssertEqual(segments.map(\.isTentative), [false, false], "what stands at the end is kept as heard")
        XCTAssertEqual(segments[0].start, 0.1, accuracy: 0.01)
        XCTAssertEqual(segments[1].start, 11.2, accuracy: 0.01, "words after the gap sit after it")
        let seen = await states.value
        XCTAssertEqual(seen.first, .preparing)
        XCTAssertTrue(seen.contains(.listening))
        XCTAssertEqual(seen.last, .finished)
        XCTAssertTrue(transcriber.finished)
    }

    func testARecognizerThatCantLoadEndsOnlyTheCaptions() async {
        struct Broken: Error, LocalizedError { var errorDescription: String? { "no model" } }
        let ended = Expectation()
        let captioner = LocalStreamingCaptioner(makeTranscriber: { _ in throw Broken() }, onEnd: { ended.fulfill() })
        let (_, states) = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        captioner.append(Self.buffer(), at: nil)  // never blocks, never throws
        await captioner.finish()
        let seen = await states.value
        XCTAssertEqual(seen.last, .failed("Live transcription couldn’t start: no model"))
        XCTAssertTrue(ended.isFulfilled, "its models are let go")
    }

    /// Records each vocabulary it's given, and the audio it had heard by then.
    final class VocabularyRecorder: LiveTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var fed = 0
        private var given: [(terms: [String], afterSamples: Int)] = []
        var vocabularies: [(terms: [String], afterSamples: Int)] { lock.withLock { given } }
        var samplesFed: Int { lock.withLock { fed } }

        func transcribe(_ samples: [Float]) async throws -> [LiveToken] { lock.withLock { fed += samples.count }; return [] }
        func finish() async throws -> [LiveToken] { [] }
        func setVocabulary(_ terms: [String]) async { lock.withLock { given.append((terms, fed)) } }
    }

    func testTheRecognizerIsBiasedTowardTheVocabularyAndFollowsItsChanges() async throws {
        let recognizer = VocabularyRecorder()
        let vocabulary = LiveVocabulary(terms: ["Daybook", " Priya ", "daybook", ""])
        let captioner = LocalStreamingCaptioner(timelineOrigin: 0, vocabulary: vocabulary, makeTranscriber: { _ in recognizer })
        await captioner.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)
        XCTAssertEqual(recognizer.vocabularies.map(\.terms), [["Daybook", "Priya"]], "given before any audio, each term once")
        XCTAssertEqual(recognizer.vocabularies.first?.afterSamples, 0)
        for index in 0..<10 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        try await waitUntil("a second fed") { recognizer.samplesFed >= 16_000 }
        // A term approved during the recording reaches it before its next audio.
        vocabulary.update(["Daybook", "Priya", "Nemotron"])
        for index in 10..<20 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        try await waitUntil("two seconds fed") { recognizer.samplesFed >= 32_000 }
        await captioner.finish()
        let given = recognizer.vocabularies
        XCTAssertEqual(given.map(\.terms), [["Daybook", "Priya"], ["Daybook", "Priya", "Nemotron"]])
        XCTAssertGreaterThanOrEqual(given[1].afterSamples, 16_000)
        XCTAssertLessThan(given[1].afterSamples, 32_000, "applied between batches, not at the end")
        // The same terms again change nothing.
        vocabulary.update(["Daybook", "Priya", "Nemotron"])
        XCTAssertEqual(vocabulary.current.version, 1)
    }

    func testWithoutVocabularyTheRecognizerIsNeverBiased() async throws {
        let recognizer = VocabularyRecorder()
        let captioner = LocalStreamingCaptioner(timelineOrigin: 0, vocabulary: LiveVocabulary(), makeTranscriber: { _ in recognizer })
        await captioner.start(locale: .current, sourceFormat: nil)
        for index in 0..<10 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        try await waitUntil("fed") { recognizer.samplesFed >= 16_000 }
        await captioner.finish()
        XCTAssertTrue(recognizer.vocabularies.isEmpty)
    }

    func testTheVocabularyIsCapped() {
        let many = (0..<(LiveVocabulary.limit + 20)).map { "Term \($0)" }
        XCTAssertEqual(LiveVocabulary(terms: many).current.terms.count, LiveVocabulary.limit)
    }

    func testCriticalConditionsPauseTheRecognizer() async throws {
        let transcriber = ScriptedTranscriber([])
        let governor = LiveLoadGovernor(policy: .iPhone, conditions: { LiveConditions(thermal: .critical) })
        let captioner = LocalStreamingCaptioner(timelineOrigin: 0, governor: governor, makeTranscriber: { _ in transcriber })
        await captioner.start(locale: .current, sourceFormat: nil)
        for index in 0..<20 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        try await Task.sleep(for: .milliseconds(200))
        await captioner.finish()
        XCTAssertEqual(transcriber.samplesFed, 0, "a hot phone lets the audio go")
    }

    // MARK: Speakers

    func testSpeakersAndNamesAreAddedToAnotherCaptionersWords() async throws {
        let inner = ScriptedCaptioner(lines: [])
        let voices = [KnownVoice(id: "p", name: "Priya", embeddingSpace: "test-space", embeddings: [[1, 0, 0]])]
        let captioner = SpeakerLabelledCaptioner(inner: inner, timelineOrigin: 0, makeSpeakers: {
            LiveSpeakerSession(diarizer: ScriptedDiarizer([(0, 0, 4), (1, 4, 8)]), embedding: LoudnessEmbedding(), voices: voices)
        })
        let (updates, _) = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        // Priya (loud) for four seconds, then someone quieter.
        for index in 0..<80 { captioner.append(Self.buffer(index < 40 ? 0.8 : 0.1), at: Self.time(Double(index) * 0.1)) }
        inner.apply(text: "Can we ship Friday?", start: 0.5, end: 3, isFinal: true)
        inner.apply(text: "I think so", start: 4.5, end: 6, isFinal: false)
        try await waitUntil("labelled") { captioner.lastLabels.count == 2 && captioner.lastLabels.allSatisfy { $0 != nil } }
        await captioner.finish()
        let segments = await updates.value
        XCTAssertEqual(segments.map(\.text), ["Can we ship Friday?", "I think so"])
        XCTAssertEqual(segments.map { $0.speaker?.slot }, ["S1", "S2"])
        XCTAssertEqual(segments.map { $0.speaker?.name }, ["Priya", nil], "only the voice that matched is named")
        XCTAssertEqual(segments.map(\.isTentative), [false, false])
    }

    func testWithoutASpeakerModelTheWordsGoOnUnlabelled() async throws {
        struct Missing: Error {}
        let inner = ScriptedCaptioner(lines: [])
        let captioner = SpeakerLabelledCaptioner(inner: inner, makeSpeakers: { throw Missing() })
        let (updates, states) = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        for _ in 0..<10 { captioner.append(Self.buffer(), at: nil) }
        inner.apply(text: "Still captioned", start: 0, end: 1, isFinal: true)
        try await waitUntil("forwarded") { captioner.lastLabels.count == 1 }
        await captioner.finish()
        let segments = await updates.value
        XCTAssertEqual(segments.map(\.text), ["Still captioned"])
        XCTAssertNil(segments[0].speaker)
        let seen = await states.value
        XCTAssertEqual(seen.filter { $0 == .finished }.count, 1, "said once, after the last labels")
    }

    func testSpeakersAreShedFirstUnderLoad() async throws {
        let inner = ScriptedCaptioner(lines: [])
        let governor = LiveLoadGovernor(policy: .iPhone, conditions: { LiveConditions(lowPowerMode: true) })
        let diarizer = ScriptedDiarizer([(0, 0, 10)])
        let captioner = SpeakerLabelledCaptioner(inner: inner, timelineOrigin: 0, governor: governor,
                                                 makeSpeakers: { LiveSpeakerSession(diarizer: diarizer) })
        let (updates, _) = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        for index in 0..<30 { captioner.append(Self.buffer(), at: Self.time(Double(index) * 0.1)) }
        inner.apply(text: "Low power", start: 0.2, end: 2, isFinal: true)
        try await Task.sleep(for: .milliseconds(200))
        await captioner.finish()
        let segments = await updates.value
        XCTAssertEqual(segments.map(\.text), ["Low power"])
        XCTAssertNil(segments[0].speaker, "Low Power Mode keeps the words and drops the speakers")
    }
}

/// A flag set once from any task.
final class Expectation: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fulfill() { lock.withLock { done = true } }
    var isFulfilled: Bool { lock.withLock { done } }
}
