import Accelerate
import CoreML
import DaybookCore
import DaybookKit
import DaybookLive
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
        let embedder = try WeSpeakerSpanEmbedder(fbank: models.fbankModel, embedding: models.embeddingModel)
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

/// Community-1's FBank and WeSpeaker models over one stretch of audio. The recipe lives in DaybookLive
/// (`WeSpeakerEmbedder`), which live captions use on the Mac and the iPhone too, so every voice
/// profile Daybook makes is in the same space.
typealias WeSpeakerSpanEmbedder = WeSpeakerEmbedder
