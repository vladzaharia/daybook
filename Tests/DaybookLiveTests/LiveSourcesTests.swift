import AVFoundation
import DaybookCaptions
import DaybookKit
@testable import DaybookLive
import DaybookModelStore
import DaybookTestSupport
import XCTest

/// Captures sharing the live models (a Mac's You and Call), speakers out of sight, and labelling
/// saved captions afterwards from the recording. Scripted models through the same composition the
/// apps use (`LiveCaptioners`); no model runs here.
final class LiveSourcesTests: XCTestCase {
    typealias Scripted = LiveCaptionerTests

    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSourcesTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func install(_ key: String) throws -> ModelInstallation {
        let model = try XCTUnwrap(ModelCatalog.builtIn.model(key))
        let receipt = ModelInstallReceipt(model: model, revision: try XCTUnwrap(model.latestRevision))
        return ModelInstallation(receipt: receipt, directory: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    /// Counts loads of the shared models and the per-capture parts made over them.
    final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
        subscript(key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
    }

    /// The model a capture's recognizer is made over: one object, however many captures use it.
    final class SharedModel: @unchecked Sendable {}

    /// A recognizer that says what it heard: "Loud." for a capture whose audio is loud, else "Quiet.".
    final class LevelTranscriber: LiveTranscribing, @unchecked Sendable {
        let shared: SharedModel
        private var fed = 0
        private var said = false
        init(shared: SharedModel) { self.shared = shared }

        func transcribe(_ samples: [Float]) async throws -> [LiveToken] {
            let start = Double(fed) / 16_000
            fed += samples.count
            guard !said else { return [] }
            said = true
            let word = (samples.map(abs).max() ?? 0) > 0.4 ? "▁Loud" : "▁Quiet"
            return [LiveToken(text: word, start: start, end: start + 0.3), LiveToken(text: ".", start: start + 0.3, end: start + 0.4)]
        }

        func finish() async throws -> [LiveToken] { [] }
    }

    private func parts(_ loads: Loads, speakers: [(slot: Int, from: Double, to: Double)] = [(0, 0, 100)]) -> LiveParts {
        LiveParts(transcriber: { use, installation, _ in
            let shared = try await use.shared(.transcription, installation) { loads.add("recognizer"); return SharedModel() }
            loads.add("capture")
            return LevelTranscriber(shared: shared)
        }, diarizer: { use, installation in
            _ = try await use.shared(.diarization, installation) { loads.add("speakers"); return SharedModel() }
            return Scripted.ScriptedDiarizer(speakers)
        }, embedding: { use, installation, _ in
            _ = try await use.shared(.embedding, installation) { loads.add("voices"); return SharedModel() }
            return Scripted.LoudnessEmbedding()
        })
    }

    private func collect(_ captioner: any LiveCaptioning) -> Task<[LiveCaptionSegment], Never> {
        Task { var last: [LiveCaptionSegment] = []; for await snapshot in captioner.updates { last = snapshot }; return last }
    }

    // MARK: Two captures, one set of models

    func testYouAndCallShareTheLoadedModelsAndEachCaptionsItsOwnAudio() async throws {
        let loads = Loads()
        let host = LiveModelHost(idleRelease: .zero)
        var captioners = LiveCaptioners(host: host, policy: .mac)
        captioners.parts = parts(loads)
        let models = LiveModelSet(transcription: try install("nemotron-3.5-asr-streaming/latin-1120ms"),
                                  diarization: try install("nemotron-3-diarization/live"))
        // As the Mac makes them: the microphone's and the call's captioners, counting from the recording's start.
        let you = try XCTUnwrap(captioners.captioner(models: models, locale: Locale(identifier: "en_US"), backlog: 128, timelineOrigin: 0, fallback: { nil }))
        let call = try XCTUnwrap(captioners.captioner(models: models, locale: Locale(identifier: "en_US"), backlog: 1_024, timelineOrigin: 0, fallback: { nil }))
        let youHeard = collect(you), callHeard = collect(call)
        await you.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)
        await call.start(locale: Locale(identifier: "en_US"), sourceFormat: nil)

        // The microphone at 44.1 kHz in 100 ms buffers, quiet; the call at 48 kHz stereo in 10 ms IO cycles, loud.
        let mic = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let tap = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for index in 0..<20 {
            you.append(Self.tone(mic, frames: 4_410, level: 0.1), at: AVAudioTime(sampleTime: AVAudioFramePosition(index * 4_410), atRate: 44_100))
            for cycle in 0..<10 {
                let frame = (index * 10 + cycle) * 480
                call.append(Self.tone(tap, frames: 480, level: 0.8), at: AVAudioTime(sampleTime: AVAudioFramePosition(frame), atRate: 48_000))
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        await you.finish()
        await call.finish()
        let mine = await youHeard.value, theirs = await callHeard.value
        XCTAssertEqual(mine.map(\.text), ["Quiet."], "the microphone's captions are its own")
        XCTAssertEqual(theirs.map(\.text), ["Loud."], "and the call's its own")
        XCTAssertEqual(mine.first?.speaker?.slot, "S1")
        XCTAssertEqual(theirs.first?.speaker?.slot, "S1", "each capture has its own speaker slots")
        XCTAssertEqual(loads["recognizer"], 1, "the recognizer loads once for both")
        XCTAssertEqual(loads["speakers"], 1, "and the speaker model")
        XCTAssertEqual(loads["capture"], 2, "each capture gets its own decoder state")
        var loaded = await host.loadedCount
        for _ in 0..<200 where loaded > 0 {
            try await Task.sleep(for: .milliseconds(10))
            loaded = await host.loadedCount
        }
        XCTAssertEqual(loaded, 0, "models released after both end")
    }

    static func tone(_ format: AVAudioFormat, frames: Int, level: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frames { buffer.floatChannelData![channel][index] = level * sin(Float(index) * 0.2) }
        }
        return buffer
    }

    // MARK: Out of sight

    /// Records the size of each batch the speaker model is given.
    final class BatchDiarizer: LiveDiarizing, @unchecked Sendable {
        let frameSeconds = 0.01
        let speakerSlots = 2
        private let lock = NSLock()
        private var sizes: [Int] = []
        private var pending = 0
        var batches: [Int] { lock.withLock { sizes } }

        func diarize(_ samples: [Float]) throws -> [LiveSpeakerFrames] {
            lock.withLock { sizes.append(samples.count) }
            pending += samples.count
            let frames = pending / 160
            pending -= frames * 160
            return frames > 0 ? [LiveSpeakerFrames(probabilities: Array(repeating: [0.9, 0], count: frames).flatMap { $0 }, frames: frames, speakers: 2)] : []
        }

        func finish() throws -> [LiveSpeakerFrames] { [] }
    }

    func testOutOfSightSpeakersGoOnInBatches() async throws {
        let inner = ScriptedCaptioner(lines: [])
        let diarizer = BatchDiarizer()
        let governor = LiveLoadGovernor(policy: .iPhone, conditions: { LiveConditions(isVisible: false) })
        let captioner = SpeakerLabelledCaptioner(inner: inner, backlog: 256, timelineOrigin: 0, governor: governor,
                                                 makeSpeakers: { LiveSpeakerSession(diarizer: diarizer) })
        let heard = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        for index in 0..<100 { captioner.append(Scripted.buffer(), at: Scripted.time(Double(index) * 0.1)) }
        inner.apply(text: "In my pocket", start: 1, end: 3, isFinal: true)
        try await waitUntil("labelled in the background") { captioner.lastLabels.first??.slot == "S1" }
        await captioner.finish()
        let segments = await heard.value
        XCTAssertEqual(segments.first?.speaker?.slot, "S1", "speakers go on out of sight")
        XCTAssertNil(segments.first?.needsSpeaker)
        let batches = diarizer.batches
        XCTAssertEqual(batches.reduce(0, +), 160_000, "it heard all ten seconds")
        XCTAssertTrue(batches.dropLast().allSatisfy { $0 >= 64_000 }, "four seconds at a time: \(batches)")
    }

    func testShedSpeakersLeaveTheirCaptionsWaitingForTheRecording() async throws {
        let inner = ScriptedCaptioner(lines: [])
        let diarizer = Scripted.ScriptedDiarizer([(0, 0, 20)])
        // Low Power Mode until four seconds in, then not.
        let clock = Clock()
        let governor = LiveLoadGovernor(policy: .iPhone, interval: 0, conditions: { LiveConditions(lowPowerMode: clock.now < 4) })
        let captioner = SpeakerLabelledCaptioner(inner: inner, backlog: 256, timelineOrigin: 0, governor: governor,
                                                 makeSpeakers: { LiveSpeakerSession(diarizer: diarizer) })
        let heard = collect(captioner)
        await captioner.start(locale: .current, sourceFormat: nil)
        for index in 0..<40 { captioner.append(Scripted.buffer(), at: Scripted.time(Double(index) * 0.1)) }
        try await waitUntil("the first four seconds shed") { captioner.consumed >= 40 }
        clock.now = 10
        for index in 40..<80 { captioner.append(Scripted.buffer(), at: Scripted.time(Double(index) * 0.1)) }
        inner.apply(text: "While it was shed", start: 0.5, end: 3, isFinal: true)
        inner.apply(text: "Once it came back", start: 5, end: 7, isFinal: true)
        try await waitUntil("the second labelled") { captioner.lastLabels.count == 2 && captioner.lastLabels[1] != nil }
        await captioner.finish()
        let segments = await heard.value
        XCTAssertNil(segments[0].speaker)
        XCTAssertEqual(segments[0].needsSpeaker, true, "the speaker model never heard it")
        XCTAssertEqual(segments[1].speaker?.slot, "S1")
        XCTAssertNil(segments[1].needsSpeaker)
        XCTAssertTrue(LiveSpeakerPass.isNeeded(LiveCaptions(meetingID: UUID(), localeIdentifier: "en_US", segments: segments)))
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        var now: Double {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    // MARK: Afterwards, from the recording

    func testThePassLabelsEveryCaptionFromTheWholeRecording() async throws {
        // Priya (loud) for four seconds, then someone quieter for four.
        let audio = (0..<80).map { index in Array(repeating: Float(index < 40 ? 0.8 : 0.1), count: 1_600).enumerated().map { $0.element * sin(Float($0.offset) * 0.3) } }
        let voices = [KnownVoice(id: "p", name: "Priya", embeddingSpace: "test-space", embeddings: [[1, 0, 0]])]
        let session = LiveSpeakerSession(diarizer: Scripted.ScriptedDiarizer([(0, 0, 4), (1, 4, 8)]),
                                         embedding: Scripted.LoudnessEmbedding(), voices: voices)
        let saved = [
            LiveCaptionSegment(start: 0.5, end: 3, text: "Can we ship Friday?", isTentative: false, needsSpeaker: true),
            LiveCaptionSegment(start: 4.5, end: 6, text: "I think so.", isTentative: false,
                               speaker: LiveCaptionSpeaker(slot: "S4"), needsSpeaker: nil),
        ]
        let labelled = try await LiveSpeakerPass.label(saved, audio: Chunks(audio), session: session)
        XCTAssertEqual(labelled.map { $0.speaker?.slot }, ["S1", "S2"], "every caption from the one pass, live labels included")
        XCTAssertEqual(labelled.map { $0.speaker?.name }, ["Priya", nil])
        XCTAssertEqual(labelled.map(\.needsSpeaker), [nil, nil])
        XCTAssertEqual(labelled.map(\.text), saved.map(\.text), "the words are untouched")
    }

    func testCaptionsAreLabelledFromARecordingFileWithTheInstalledModels() async throws {
        let loads = Loads()
        var captioners = LiveCaptioners(host: LiveModelHost(idleRelease: .zero), policy: .iPhone)
        captioners.parts = parts(loads, speakers: [(1, 0, 3)])
        let models = LiveModelSet(diarization: try install("nemotron-3-diarization/live"))
        // Three seconds of an AAC recording at 48 kHz, as the iPhone files them.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("recording.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                   AVNumberOfChannelsKey: 1])
            for _ in 0..<3 { try file.write(from: Self.tone(format, frames: 48_000, level: 0.3)) }
        }
        var captions = LiveCaptions(meetingID: UUID(), localeIdentifier: "en_US", segments: [
            LiveCaptionSegment(start: 0.4, end: 2.5, text: "Recorded in a pocket", isTentative: false, needsSpeaker: true)])
        let result = try await captioners.labelSpeakers(captions, recording: url, models: models)
        let labelled = try XCTUnwrap(result)
        XCTAssertEqual(labelled.segments.map { $0.speaker?.slot }, ["S2"])
        XCTAssertFalse(LiveSpeakerPass.isNeeded(labelled))
        XCTAssertEqual(loads["speakers"], 1)

        // Nothing waiting, or no speaker model: nothing to do.
        let none = try await captioners.labelSpeakers(labelled, recording: url, models: models)
        XCTAssertNil(none)
        captions.segments[0].needsSpeaker = true
        let withoutModel = try await captioners.labelSpeakers(captions, recording: url, models: LiveModelSet())
        XCTAssertNil(withoutModel)
        // A recording that can't be read leaves the captions as they were.
        let unreadable = try await captioners.labelSpeakers(captions, recording: root.appendingPathComponent("missing.m4a"), models: models)
        XCTAssertNil(unreadable)
    }

    func testARecordingReadsBackAsSixteenKilohertzMono() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("recording.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: Self.tone(format, frames: 110_250, level: 0.3))
        }
        var total = 0
        for try await chunk in LiveRecordingAudio(url: url) { total += chunk.count }
        XCTAssertEqual(Double(total), 2.5 * 16_000, accuracy: 1_600, "two and a half seconds (the resampler keeps its last few milliseconds)")
    }
}

/// Audio chunks as an async sequence, for the pass.
struct Chunks: AsyncSequence {
    typealias Element = [Float]
    let chunks: [[Float]]
    init(_ chunks: [[Float]]) { self.chunks = chunks }
    struct AsyncIterator: AsyncIteratorProtocol {
        var rest: ArraySlice<[Float]>
        mutating func next() async throws -> [Float]? { rest.popFirst() }
    }
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(rest: chunks[...]) }
}
