import CoreML
import DaybookCaptions
import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// Per-frame speaker activity from a streaming speaker model: `frames × speakers` probabilities,
/// frame-major, each frame `frameSeconds` long, following on from the previous call's frames.
public struct LiveSpeakerFrames: Equatable, Sendable {
    public var probabilities: [Float]
    public var frames: Int
    public var speakers: Int

    public init(probabilities: [Float], frames: Int, speakers: Int) {
        self.probabilities = probabilities; self.frames = frames; self.speakers = speakers
    }
}

/// A streaming speaker model for one capture. Its speaker slots stay with their voices for the whole
/// stream (the model keeps a cache of each speaker), which is what lets a name stick to a slot.
/// Called from one task at a time.
public protocol LiveDiarizing: AnyObject, Sendable {
    var frameSeconds: Double { get }
    var speakerSlots: Int { get }
    /// Feeds 16 kHz mono samples; returns the frames they completed.
    func diarize(_ samples: [Float]) throws -> [LiveSpeakerFrames]
    /// The audio ended: the last frames.
    func finish() throws -> [LiveSpeakerFrames]
}

/// Nemotron 3 Diarization's streaming path (`Nemotron3Diarizer`): eight slots, 10 ms frames, the
/// latency its preset fixes (2.88 s for "fast32").
final class NemotronLiveDiarizer: LiveDiarizing, @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer
    let frameSeconds = 0.01
    let speakerSlots: Int

    /// Each capture gets its own `Nemotron3Models` over the shared Core ML model: the models keep
    /// preallocated input and output arrays, which two streams must not share.
    init(shared: LoadedDiarizer) throws {
        let models = try Nemotron3Models(config: shared.config, model: shared.models.model,
                                         silenceEmbedding: shared.models.silenceEmbedding,
                                         preEncodeProjection: shared.models.preEncodeProjection)
        diarizer = Nemotron3Diarizer(config: shared.config, models: models)
        speakerSlots = shared.config.numSpeakers
    }

    func diarize(_ samples: [Float]) throws -> [LiveSpeakerFrames] {
        guard !samples.isEmpty else { return [] }
        diarizer.appendAudio(samples)
        return try diarizer.processBufferedAudio().map(Self.frames)
    }

    func finish() throws -> [LiveSpeakerFrames] { try diarizer.finishStream().map(Self.frames) }

    private static func frames(_ chunk: Nemotron3ChunkResult) -> LiveSpeakerFrames {
        LiveSpeakerFrames(probabilities: chunk.probabilities, frames: chunk.frameCount, speakers: chunk.numSpeakers)
    }

    /// Loads a preset's model on the Neural Engine and CPU (never the GPU, which a locked iPhone can't use).
    static func load(_ folder: URL, options: [String: String]) async throws -> (Nemotron3Models, Nemotron3Config) {
        guard let config = LiveDiarizationPreset.configuration(options) else { throw LiveModelError.unsupportedRole(.liveDiarization) }
        let models = try await Nemotron3Models.load(config: config, directory: folder, computeUnits: .cpuAndNeuralEngine)
        return (models, config)
    }
}

/// Who spoke when, on the capture's timeline, built as frames arrive: each slot's runs of activity
/// (above `threshold`, gaps under `gap` bridged), and the stretches where exactly one slot speaks,
/// which voice profiles are made from. Keeps the last `horizon` seconds.
public struct LiveSpeakerTimeline: Sendable {
    public struct Run: Equatable, Sendable {
        public var slot: Int
        public var start: TimeInterval
        public var end: TimeInterval
    }

    /// A stretch where only `slot` spoke, in the diarizer's own frames (which index its audio).
    public struct SoloSpan: Equatable, Sendable {
        public var slot: Int
        public var startFrame: Int
        public var endFrame: Int
    }

    public var threshold: Float = 0.5
    public var gap: TimeInterval = 0.3
    public var horizon: TimeInterval = 900
    /// Solo stretches shorter than this aren't worth a voice profile; longer ones are cut at `maximumSolo`.
    public var minimumSolo: TimeInterval = 1.5
    public var maximumSolo: TimeInterval = 10

    public let frameSeconds: Double
    public private(set) var runs: [Run] = []
    /// Frames seen so far.
    public private(set) var frame = 0
    private var open: [Int: (start: Int, last: Int)] = [:]
    private var solo: (slot: Int, start: Int)?
    private var finishedSolos: [SoloSpan] = []

    public init(frameSeconds: Double) { self.frameSeconds = frameSeconds }

    /// Appends frames; `time` maps a diarizer second to the capture's timeline (gaps in the audio
    /// the diarizer heard). Returns the solo stretches these frames completed.
    public mutating func append(_ chunk: LiveSpeakerFrames, time: (TimeInterval) -> TimeInterval) -> [SoloSpan] {
        let speakers = max(1, chunk.speakers)
        let usable = min(chunk.frames, chunk.probabilities.count / speakers)
        let gapFrames = Int((gap / frameSeconds).rounded())
        for index in 0..<usable {
            var active: [Int] = []
            for slot in 0..<speakers where chunk.probabilities[index * speakers + slot] > threshold { active.append(slot) }
            for slot in active {
                if let run = open[slot], frame - run.last <= gapFrames { open[slot] = (run.start, frame) }
                else {
                    if let run = open[slot] { close(slot, run, time: time) }
                    open[slot] = (frame, frame)
                }
            }
            for (slot, run) in open where frame - run.last > gapFrames {
                close(slot, run, time: time)
                open[slot] = nil
            }
            trackSolo(active.count == 1 ? active[0] : nil)
            frame += 1
        }
        let latest = time(Double(frame) * frameSeconds)
        runs.removeAll { $0.end < latest - horizon }
        defer { finishedSolos = [] }
        return finishedSolos
    }

    /// The audio ended: open runs and stretches close.
    public mutating func finish(time: (TimeInterval) -> TimeInterval) -> [SoloSpan] {
        for (slot, run) in open { close(slot, run, time: time) }
        open = [:]
        trackSolo(nil)
        defer { finishedSolos = [] }
        return finishedSolos
    }

    /// The slot that spoke most of `start…end` on the capture's timeline, counting runs still open up
    /// to `now` (diarizer seconds mapped by `time`); nil when nobody did.
    public func dominantSlot(from start: TimeInterval, to end: TimeInterval, time: (TimeInterval) -> TimeInterval) -> Int? {
        let span = max(end, start + 0.2)
        var overlap: [Int: TimeInterval] = [:]
        let openRuns = open.map { Run(slot: $0.key, start: time(Double($0.value.start) * frameSeconds),
                                      end: time(Double($0.value.last) * frameSeconds) + frameSeconds) }
        for run in runs + openRuns {
            let shared = min(span, run.end) - max(start, run.start)
            if shared > 0 { overlap[run.slot, default: 0] += shared }
        }
        return overlap.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// A run's end is its last frame's place plus one frame: the moment after it could fall past a
    /// gap in the audio, which would stretch the run across the gap.
    private mutating func close(_ slot: Int, _ run: (start: Int, last: Int), time: (TimeInterval) -> TimeInterval) {
        let start = time(Double(run.start) * frameSeconds), end = time(Double(run.last) * frameSeconds) + frameSeconds
        runs.append(Run(slot: slot, start: start, end: max(start, end)))
    }

    private mutating func trackSolo(_ slot: Int?) {
        let maximum = Int(maximumSolo / frameSeconds)
        if let current = solo, current.slot != slot || frame - current.start >= maximum {
            if Double(frame - current.start) * frameSeconds >= minimumSolo {
                finishedSolos.append(SoloSpan(slot: current.slot, startFrame: current.start, endFrame: frame))
            }
            solo = nil
        }
        if solo == nil, let slot { solo = (slot, frame) }
    }
}

/// Embeds one stretch of a single voice (16 kHz mono) in a known space.
public protocol LiveVoiceEmbedding: Sendable {
    var space: String { get }
    func embed(_ samples: [Float]) throws -> [Float]
}

/// WeSpeaker, as the live pipeline uses it.
struct WeSpeakerVoiceEmbedding: LiveVoiceEmbedding {
    let embedder: WeSpeakerEmbedder
    let space: String
    func embed(_ samples: [Float]) throws -> [Float] { try embedder.embed(samples) }
}

/// Names voices as they're heard: each slot's solo stretches are embedded and averaged (by duration,
/// as Community-1 averages its speakers), then compared with known voices in the same space. A slot
/// is named only when its closest person is similar enough and clearly closer than the next
/// (`SpeakerMatchingConfiguration`, the same thresholds speaker matching uses), and when two slots
/// claim one person only the clearly closer one keeps the name. Names stay tentative.
public struct LiveVoiceIdentifier: Sendable {
    public struct Match: Equatable, Sendable {
        public var voiceID: String
        public var name: String
        public var similarity: Double
    }

    public var configuration: SpeakerMatchingConfiguration
    /// A slot is compared only once this much of its solo speech is embedded.
    public var minimumSpeech: TimeInterval = 3
    /// Each slot keeps its newest embeddings, so a long capture follows a voice as it is now.
    public var keep = 8

    public let space: String
    private var voices: [KnownVoice]
    private var embedded: [Int: [(vector: [Float], seconds: TimeInterval)]] = [:]
    public private(set) var matches: [Int: Match] = [:]

    public init(voices: [KnownVoice], space: String, configuration: SpeakerMatchingConfiguration = .init()) {
        self.space = space
        self.configuration = configuration
        self.voices = voices.filter { $0.embeddingSpace == space && !$0.embeddings.isEmpty }
    }

    public var hasVoices: Bool { !voices.isEmpty }

    /// Adds one embedding of `slot`'s voice. Returns whether any slot's name changed.
    @discardableResult
    public mutating func observe(slot: Int, embedding: [Float], seconds: TimeInterval) -> Bool {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return false }
        var list = embedded[slot, default: []]
        list.append((embedding, seconds))
        if list.count > keep { list.removeFirst(list.count - keep) }
        embedded[slot] = list
        return rematch()
    }

    /// The duration-weighted mean of a slot's embeddings.
    func centroid(_ slot: Int) -> [Float]? {
        guard let items = embedded[slot], let size = items.first?.vector.count, items.allSatisfy({ $0.vector.count == size }) else { return nil }
        let total = items.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return nil }
        var sum = [Double](repeating: 0, count: size)
        for item in items { for index in 0..<size { sum[index] += Double(item.vector[index]) * item.seconds } }
        return sum.map { Float($0 / total) }
    }

    private mutating func rematch() -> Bool {
        var proposals: [Int: (Match, runnerUp: Double?)] = [:]
        for (slot, items) in embedded where items.reduce(0, { $0 + $1.seconds }) >= minimumSpeech {
            guard let vector = centroid(slot) else { continue }
            var scores: [(voice: KnownVoice, score: Double)] = []
            for voice in voices {
                let best = voice.embeddings.compactMap { SpeakerMatcher.cosineSimilarity(vector, $0) }.max()
                if let best { scores.append((voice, best)) }
            }
            scores.sort { $0.score == $1.score ? $0.voice.id < $1.voice.id : $0.score > $1.score }
            guard let top = scores.first, top.score >= configuration.minimumSimilarity else { continue }
            let runnerUp = scores.dropFirst().first?.score
            if let runnerUp, top.score - runnerUp < configuration.minimumMargin { continue }
            proposals[slot] = (Match(voiceID: top.voice.id, name: top.voice.name, similarity: top.score), runnerUp)
        }
        // One person, one slot: when two slots claim the same voice, the clearly closer one keeps it.
        var accepted: [Int: Match] = [:]
        for (voiceID, claims) in Dictionary(grouping: proposals, by: { $0.value.0.voiceID }) {
            let sorted = claims.sorted { $0.value.0.similarity > $1.value.0.similarity }
            guard let first = sorted.first else { continue }
            if sorted.count == 1 || first.value.0.similarity - sorted[1].value.0.similarity >= configuration.minimumMargin {
                accepted[first.key] = first.value.0
            }
            _ = voiceID
        }
        guard accepted != matches else { return false }
        matches = accepted
        return true
    }
}

/// The last stretch of 16 kHz audio the speaker pipeline fed its diarizer, indexed by the diarizer's
/// own sample count, so a solo stretch's frames find their samples.
struct LiveAudioRing: Sendable {
    let capacity: Int
    private var samples: [Float] = []
    /// Diarizer samples fed before `samples[0]`.
    private var base = 0

    init(seconds: Double) { capacity = Int(seconds * LiveAudio.sampleRate) }

    var end: Int { base + samples.count }

    mutating func append(_ more: [Float]) {
        samples.append(contentsOf: more)
        if samples.count > capacity + capacity / 2 {
            let drop = samples.count - capacity
            samples.removeFirst(drop)
            base += drop
        }
    }

    /// Samples `start..<end` (diarizer sample indices), when still held.
    func slice(_ start: Int, _ end: Int) -> [Float]? {
        guard start >= base, end <= self.end, start < end else { return nil }
        return Array(samples[(start - base)..<(end - base)])
    }
}
