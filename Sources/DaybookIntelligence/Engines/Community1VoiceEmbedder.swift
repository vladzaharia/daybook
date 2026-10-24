import Accelerate
import CoreML
import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// Community-1 as a voice-profile model for another diarizer's turns (Nemotron 3): each speaker's
/// clearest stretches of speech go through the same FBank and WeSpeaker ResNet34 models
/// Community-1 clusters with, and their embeddings are averaged by duration, as Community-1's own
/// speaker centroids are. The vectors therefore live in the space the install declares
/// (`fluid-community1-embedding-df2625ac79a7ac6b` for the built-in model), so profiles saved from
/// Community-1 runs and from Nemotron runs compare with each other.
extension Community1Diarizer: EmbeddingVoices {
    func embedVoices(url: URL, analysis: SpeakerAnalysis, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        let plan = VoiceSpans.select(analysis.turns)
        let embedder = try WeSpeakerSpanEmbedder(models: models)
        let total = max(1, plan.values.reduce(0) { $0 + $1.count })
        var done = 0
        var result = analysis
        result.embeddings = [:]
        progress(.init(0, "Making voice profiles"))
        for speaker in plan.keys.sorted() {
            var embedded: [(vector: [Float], weight: Double)] = []
            for span in plan[speaker] ?? [] {
                try Task.checkCancellation()
                let samples = try AudioSlabReader.samples(url: url, from: span.start, to: span.end)
                let vector = try embedder.embed(samples)
                if !vector.isEmpty, vector.allSatisfy(\.isFinite) { embedded.append((vector, span.end - span.start)) }
                done += 1
                progress(.init(Double(done) / Double(total), "Making voice profiles"))
            }
            if let mean = VoiceSpans.average(embedded) { result.embeddings[speaker] = mean }
        }
        result.embeddingModelID = result.embeddings.isEmpty ? nil : embeddingSpace
        progress(.init(1, "Voice profiles complete"))
        return result
    }
}

/// Which stretches of speech make each speaker's voice profile.
enum VoiceSpans {
    struct Span: Equatable { var start: Double; var end: Double }

    /// Per speaker: stretches where only that speaker talks, at least `minimumSeconds` long, split
    /// into pieces of at most `maximumSeconds` (the embedding model's window), longest first, at
    /// most `limit` of them. A speaker who never talks alone long enough falls back to the longest
    /// of their turns of at least `fallbackSeconds`, overlap and all; one with none gets no profile.
    static func select(_ turns: [SpeakerTurn], minimumSeconds: Double = 1.0, fallbackSeconds: Double = 0.5,
                       maximumSeconds: Double = 10, limit: Int = 12) -> [String: [Span]] {
        let speakers = Set(turns.map(\.speakerID))
        var result: [String: [Span]] = [:]
        for speaker in speakers {
            let own = merge(turns.filter { $0.speakerID == speaker }.map { Span(start: $0.start, end: $0.end) })
            let others = merge(turns.filter { $0.speakerID != speaker }.map { Span(start: $0.start, end: $0.end) })
            var pieces: [Span] = []
            for span in subtract(others, from: own) where span.end - span.start >= minimumSeconds {
                var start = span.start
                while span.end - start >= minimumSeconds {
                    let end = min(span.end, start + maximumSeconds)
                    pieces.append(Span(start: start, end: end))
                    start = end
                }
            }
            if pieces.isEmpty, let longest = own.max(by: { $0.end - $0.start < $1.end - $1.start }),
               longest.end - longest.start >= fallbackSeconds {
                pieces = [Span(start: longest.start, end: min(longest.end, longest.start + maximumSeconds))]
            }
            let chosen = pieces.sorted { ($0.end - $0.start, -$0.start) > ($1.end - $1.start, -$1.start) }.prefix(limit)
            if !chosen.isEmpty { result[speaker] = chosen.sorted { $0.start < $1.start } }
        }
        return result
    }

    /// The duration-weighted mean of raw embeddings; nil for none or mismatched sizes.
    static func average(_ items: [(vector: [Float], weight: Double)]) -> [Float]? {
        guard let size = items.first?.vector.count, size > 0, items.allSatisfy({ $0.vector.count == size }) else { return nil }
        let totalWeight = items.reduce(0) { $0 + max(0, $1.weight) }
        guard totalWeight > 0 else { return nil }
        var sum = [Double](repeating: 0, count: size)
        for item in items {
            for index in 0..<size { sum[index] += Double(item.vector[index]) * max(0, item.weight) }
        }
        return sum.map { Float($0 / totalWeight) }
    }

    static func merge(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = result.last, span.start <= last.end { result[result.count - 1].end = max(last.end, span.end) }
            else { result.append(span) }
        }
        return result
    }

    /// `spans` minus `holes`; both sorted and merged.
    static func subtract(_ holes: [Span], from spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans {
            var start = span.start
            for hole in holes where hole.end > start && hole.start < span.end {
                if hole.start > start { result.append(Span(start: start, end: hole.start)) }
                start = max(start, hole.end)
            }
            if span.end > start { result.append(Span(start: start, end: span.end)) }
        }
        return result
    }
}

/// One embedding for one stretch of audio from Community-1's FBank and WeSpeaker models: the span
/// is repeated to fill the 10-second window and every frame is weighted, so only that speaker
/// shapes it. This mirrors FluidAudio 0.17.7's internal `OfflineEmbeddingExtractor.embedSpan`
/// (its public `embedSpans` arrives after 0.17.7), including the silence-aware FBank re-centering.
struct WeSpeakerSpanEmbedder {
    let fbank: MLModel
    let embedding: MLModel
    private let audioShape: [NSNumber]
    private let audioCount: Int
    private let weightShape: [NSNumber]
    private let weightCount: Int

    /// Ten seconds at 16 kHz, the window the FBank model takes.
    static let window = 160_000

    init(models: OfflineDiarizerModels) throws {
        fbank = models.fbankModel
        embedding = models.embeddingModel
        guard let audio = fbank.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
              let weights = embedding.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint,
              embedding.modelDescription.inputDescriptionsByName["fbank_features"] != nil,
              embedding.modelDescription.outputDescriptionsByName["embedding"] != nil else {
            throw LocalIntelligenceError.invalidSpeakerOutput
        }
        audioShape = Self.shape(audio, last: Self.window)
        audioCount = min(Self.window, audioShape.last?.intValue ?? Self.window)
        weightShape = Self.shape(weights, last: 589)
        weightCount = weightShape.last?.intValue ?? 589
    }

    func embed(_ span: [Float]) throws -> [Float] {
        guard !span.isEmpty else { return [] }
        var window = [Float]()
        window.reserveCapacity(audioCount)
        while window.count < audioCount { window.append(contentsOf: span.prefix(audioCount - window.count)) }

        let audio = try MLMultiArray(shape: audioShape, dataType: .float32)
        let audioPointer = audio.dataPointer.bindMemory(to: Float.self, capacity: audio.count)
        audioPointer.update(repeating: 0, count: audio.count)
        window.withUnsafeBufferPointer { audioPointer.update(from: $0.baseAddress!, count: min(audio.count, window.count)) }
        guard let features = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: audio)]))
            .featureValue(for: "fbank_features")?.multiArrayValue else { throw LocalIntelligenceError.invalidSpeakerOutput }
        Self.recenterOnSignal(features, audio: window)

        let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
        let weightPointer = weights.dataPointer.bindMemory(to: Float.self, capacity: weights.count)
        weightPointer.update(repeating: 0, count: weights.count)
        weightPointer.update(repeating: 1, count: min(weightCount, weights.count))
        let output = try embedding.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "fbank_features": MLFeatureValue(multiArray: features), "weights": MLFeatureValue(multiArray: weights)]))
        guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { throw LocalIntelligenceError.invalidSpeakerOutput }
        return Self.floats(vector)
    }

    /// A fixed input shape: the first enumerated shape, else the declared one; unknown sizes become 1
    /// and the last dimension `last`.
    private static func shape(_ constraint: MLMultiArrayConstraint, last: Int) -> [NSNumber] {
        let declared = constraint.shapeConstraint.enumeratedShapes.first ?? constraint.shape
        guard !declared.isEmpty else { return [1, NSNumber(value: last)] }
        return declared.enumerated().map { index, size in
            size.intValue > 0 ? size : NSNumber(value: index == declared.count - 1 ? last : 1)
        }
    }

    /// FBank subtracts each band's mean over all frames; frames of exact digital silence sit at the
    /// log floor and would pull that mean down. Re-centers on the frames that hold signal, as
    /// FluidAudio's `SilenceAwareFbank` does (25 ms frames every 10 ms). No-op without silent frames.
    static func recenterOnSignal(_ features: MLMultiArray, audio: [Float]) {
        guard features.dataType == .float32, features.shape.count == 4 else { return }
        let bands = features.shape[2].intValue, frames = features.shape[3].intValue
        let bandStride = features.strides[2].intValue, frameStride = features.strides[3].intValue
        var nonZeroBefore = [Int](repeating: 0, count: audio.count + 1)
        for index in audio.indices { nonZeroBefore[index + 1] = nonZeroBefore[index] + (audio[index] != 0 ? 1 : 0) }
        let silent = (0..<frames).map { frame -> Bool in
            let start = min(frame * 160, audio.count), end = min(start + 400, audio.count)
            return nonZeroBefore[end] == nonZeroBefore[start]
        }
        let voiced = silent.indices.filter { !silent[$0] }
        guard !voiced.isEmpty, voiced.count < silent.count else { return }
        let pointer = features.dataPointer.bindMemory(to: Float.self, capacity: features.count)
        for band in 0..<bands {
            let row = pointer + band * bandStride
            let mean = voiced.reduce(Float(0)) { $0 + row[$1 * frameStride] } / Float(voiced.count)
            for frame in 0..<frames { row[frame * frameStride] -= mean }
        }
    }

    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let contiguous = array.strides.map(\.intValue) == shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
        if array.dataType == .float32, contiguous {
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            return Array(UnsafeBufferPointer(start: pointer, count: array.count))
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}
