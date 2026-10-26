import Foundation

public struct SpeakerMatchingConfiguration: Codable, Equatable, Sendable {
    public var minimumSimilarity: Double
    public var minimumMargin: Double
    public init(minimumSimilarity: Double = 0.82, minimumMargin: Double = 0.06) {
        self.minimumSimilarity = minimumSimilarity; self.minimumMargin = minimumMargin
    }
}

public struct SpeakerMatch: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case matched, invalidConfiguration, invalidEmbedding, unknownSource, noComparableCandidates, belowThreshold, ambiguous, conflictingAssignment
    }
    public var id: String { sourceSpeakerID }
    public var sourceSpeakerID: String
    /// Non-nil only for accepted matches. Rejected candidates never establish an identity.
    public var targetSpeakerID: String?
    public var candidateSpeakerID: String?
    public var similarity: Double?
    public var runnerUpSimilarity: Double?
    @Extensible public var status: Status
    public var reason: String
    public var configuration: SpeakerMatchingConfiguration
    public var createdAt: Date
    public init(sourceSpeakerID: String, targetSpeakerID: String? = nil, candidateSpeakerID: String? = nil,
                similarity: Double? = nil, runnerUpSimilarity: Double? = nil, status: Status, reason: String,
                configuration: SpeakerMatchingConfiguration = .init(), createdAt: Date = Date()) {
        self.sourceSpeakerID = sourceSpeakerID; self.targetSpeakerID = targetSpeakerID; self.candidateSpeakerID = candidateSpeakerID
        self.similarity = similarity; self.runnerUpSimilarity = runnerUpSimilarity; self.status = status; self.reason = reason
        self.configuration = configuration; self.createdAt = createdAt
    }
}

/// Compares embeddings supplied by a single meeting. It does not maintain a global voice identity store.
public enum SpeakerMatcher {
    public static func match(incoming: [Speaker], in meeting: Meeting,
                             configuration: SpeakerMatchingConfiguration = .init(), allowSameSource: Bool = false) -> [SpeakerMatch] {
        let incomingIDs = Set(incoming.map(\.id))
        let validConfiguration = configuration.minimumSimilarity.isFinite && configuration.minimumMargin.isFinite
            && (0...1).contains(configuration.minimumSimilarity) && (0...1).contains(configuration.minimumMargin)
        func report(_ speaker: Speaker, status: SpeakerMatch.Status, reason: String) -> SpeakerMatch {
            SpeakerMatch(sourceSpeakerID: speaker.id, status: status, reason: reason, configuration: configuration)
        }
        func canonical(_ id: String) -> String {
            var current = id
            var visited = Set<String>()
            while visited.insert(current).inserted,
                  let target = meeting.speakerMatches?.last(where: { $0.sourceSpeakerID == current && $0.status == .matched })?.targetSpeakerID,
                  meeting.speakers.contains(where: { $0.id == target }), !visited.contains(target) { current = target }
            return current
        }
        var results = incoming.map { speaker -> SpeakerMatch in
            guard validConfiguration else { return report(speaker, status: .invalidConfiguration, reason: "Speaker matching thresholds must be finite numbers from zero to one.") }
            guard let source = speaker.sourceTrackID else { return report(speaker, status: .unknownSource, reason: "This speaker has no source recording identity.") }
            guard let embedding = speaker.embedding, valid(embedding), let space = speaker.embeddingModelID, !space.isEmpty else {
                return report(speaker, status: .invalidEmbedding, reason: "A finite, nonzero embedding and its known model identity are required.")
            }
            var scores: [String: Double] = [:]
            for candidate in meeting.speakers {
                guard !incomingIDs.contains(candidate.id), let candidateSource = candidate.sourceTrackID,
                      allowSameSource || candidateSource != source, candidate.embeddingModelID == space,
                      let other = candidate.embedding, let score = cosineSimilarity(embedding, other) else { continue }
                let identity = canonical(candidate.id)
                scores[identity] = max(scores[identity] ?? -1, score)
            }
            let ranked = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let best = ranked.first else {
                return report(speaker, status: .noComparableCandidates, reason: "No eligible speaker in this meeting has the same embedding model and dimensions.")
            }
            let runner = ranked.dropFirst().first?.value
            var result = SpeakerMatch(sourceSpeakerID: speaker.id, candidateSpeakerID: best.key, similarity: best.value,
                runnerUpSimilarity: runner, status: .matched, reason: "Matched within this meeting using embedding similarity and separation from alternatives.", configuration: configuration)
            guard best.value >= configuration.minimumSimilarity else {
                result.status = .belowThreshold; result.reason = "The closest speaker is below the chosen similarity threshold."; return result
            }
            guard runner == nil || best.value - runner! >= configuration.minimumMargin else {
                result.status = .ambiguous; result.reason = "Multiple speakers are too similar to choose an identity reliably."; return result
            }
            result.targetSpeakerID = best.key
            return result
        }
        // One source's distinct incoming clusters may not silently collapse onto the same identity.
        let sources = Dictionary(incoming.map { ($0.id, $0.sourceTrackID) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [Int]] = [:]
        for index in results.indices where results[index].status == .matched {
            let source = sources[results[index].sourceSpeakerID] ?? nil
            let key = "\(source?.uuidString ?? "unknown"):\(results[index].targetSpeakerID ?? "")"
            groups[key, default: []].append(index)
        }
        for contenders in groups.values where contenders.count > 1 {
            let sorted = contenders.sorted { (results[$0].similarity ?? -1) > (results[$1].similarity ?? -1) }
            let separated = (results[sorted[0]].similarity ?? -1) - (results[sorted[1]].similarity ?? -1) >= configuration.minimumMargin
            for index in sorted.dropFirst(separated ? 1 : 0) {
                results[index].targetSpeakerID = nil; results[index].status = .conflictingAssignment
                results[index].reason = "Another cluster from this recording also matches that speaker. Keep these labels separate for review."
            }
        }
        return results
    }

    public static func cosineSimilarity(_ first: [Float], _ second: [Float]) -> Double? {
        guard first.count == second.count, valid(first), valid(second) else { return nil }
        let a = first.map(Double.init), b = second.map(Double.init)
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = sqrt(a.reduce(0) { $0 + $1 * $1 }) * sqrt(b.reduce(0) { $0 + $1 * $1 })
        guard denominator > 0, denominator.isFinite else { return nil }
        let value = dot / denominator
        return value.isFinite ? min(1, max(-1, value)) : nil
    }

    private static func valid(_ vector: [Float]) -> Bool {
        !vector.isEmpty && vector.allSatisfy(\.isFinite) && vector.contains { $0 != 0 }
    }
}

/// Speech two recordings both captured: `weight` words that one recording labelled
/// `sourceSpeakerID` while the meeting already attributes them to `targetSpeakerID`.
public struct SpeakerCooccurrence: Equatable, Sendable {
    public var sourceSpeakerID: String
    public var targetSpeakerID: String
    public var weight: Double
    public init(sourceSpeakerID: String, targetSpeakerID: String, weight: Double) {
        self.sourceSpeakerID = sourceSpeakerID; self.targetSpeakerID = targetSpeakerID; self.weight = weight
    }
}

extension SpeakerMatcher {
    /// Maps one recording's speaker labels onto existing speakers from shared speech rather than
    /// voice embeddings, which don't transfer well between a laptop microphone and a room recorder.
    /// A label matches when one speaker accounts for at least `minimumShare` of its shared words
    /// and there are at least `minimumWeight` of them. If several labels from the recording claim
    /// the same speaker, only the one with clearly the most shared words keeps it.
    /// `similarity` reports the share; `runnerUpSimilarity` the next speaker's share.
    public static func matchByCooccurrence(_ observations: [SpeakerCooccurrence], minimumShare: Double = 0.7,
                                           minimumWeight: Double = 6) -> [SpeakerMatch] {
        let configuration = SpeakerMatchingConfiguration(minimumSimilarity: minimumShare, minimumMargin: 0)
        let grouped = Dictionary(grouping: observations.filter { $0.weight.isFinite && $0.weight > 0 }, by: \.sourceSpeakerID)
        var results = grouped.keys.sorted().map { source -> SpeakerMatch in
            var totals: [String: Double] = [:]
            for observation in grouped[source]! { totals[observation.targetSpeakerID, default: 0] += observation.weight }
            let total = totals.values.reduce(0, +)
            let ranked = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let best = ranked[0]
            var match = SpeakerMatch(sourceSpeakerID: source, candidateSpeakerID: best.key, similarity: best.value / total,
                                     runnerUpSimilarity: ranked.dropFirst().first.map { $0.value / total }, status: .matched,
                                     reason: "Matched because both recordings heard the same words from this speaker.",
                                     configuration: configuration, createdAt: Date(timeIntervalSince1970: 0))
            if total < minimumWeight || best.value / total < minimumShare {
                match.status = .belowThreshold
                match.reason = "Too little shared speech, or it was split between speakers."
            } else {
                match.targetSpeakerID = best.key
            }
            return match
        }
        let weights = Dictionary(grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.weight }) }, uniquingKeysWith: +)
        for target in Set(results.compactMap(\.targetSpeakerID)) {
            let contenders = results.indices.filter { results[$0].targetSpeakerID == target }
                .sorted { (weights[results[$0].sourceSpeakerID] ?? 0) > (weights[results[$1].sourceSpeakerID] ?? 0) }
            guard contenders.count > 1 else { continue }
            let clear = (weights[results[contenders[0]].sourceSpeakerID] ?? 0) >= 2 * (weights[results[contenders[1]].sourceSpeakerID] ?? 0)
            for index in contenders.dropFirst(clear ? 1 : 0) {
                results[index].targetSpeakerID = nil; results[index].status = .conflictingAssignment
                results[index].reason = "Another speaker label from this recording shares speech with that speaker. Keep these labels separate for review."
            }
        }
        return results
    }
}
