import Accelerate
import Foundation

/// How sure a voice must be before Daybook labels or suggests a speaker profile. Labels need a
/// close match that clearly beats every other profile; anything less is at most a suggestion.
public struct SpeakerProfileMatching: Codable, Equatable, Sendable {
    /// Cosine similarity at or above which a speaker is labelled with the profile.
    public var labelSimilarity: Double
    /// How much the best profile must beat the next one by, to label.
    public var margin: Double
    /// Cosine similarity at or above which the profile is suggested.
    public var suggestionSimilarity: Double
    /// Speech (without overlap) a speaker needs before Daybook labels it, in seconds.
    public var minimumLabelSeconds: Double

    /// Defaults to the conversation's voice-matching thresholds (Settings › Models › Voice matching):
    /// a label at 0.82 or above, by 0.06 over the next profile; a suggestion 0.12 below that.
    public init(labelSimilarity: Double = 0.82, margin: Double = 0.06, suggestionSimilarity: Double? = nil, minimumLabelSeconds: Double = 4) {
        let label = labelSimilarity.isFinite ? min(0.99, max(0.5, labelSimilarity)) : 0.82
        self.labelSimilarity = label
        self.margin = margin.isFinite ? min(0.5, max(0, margin)) : 0.06
        self.suggestionSimilarity = min(label, max(0.4, suggestionSimilarity ?? label - 0.12))
        self.minimumLabelSeconds = max(0, minimumLabelSeconds)
    }

    /// A label already given stays while the voice is at least this alike (so it doesn't flicker).
    public var keepSimilarity: Double { labelSimilarity - 0.04 }
    /// Daybook learns from a recognized speaker only when it's this alike and clear by twice the margin.
    public var learnSimilarity: Double { min(0.99, labelSimilarity + 0.04) }
    public var learnMargin: Double { margin * 2 }
    /// …and close to the voiceprints the person chose, not only to learned ones.
    public var anchorSimilarity: Double { labelSimilarity - 0.04 }
}

/// How a profile learns, and how much its voiceprints count.
public struct SpeakerProfileLearning: Equatable, Sendable {
    /// Voiceprints kept per profile and embedding space; the least useful are retired beyond these.
    public var maximumPersonChosen = 8
    public var maximumRecognized = 16
    /// A voiceprint counts half as much after this long (measured from the profile's newest one).
    public var halfLifeDays = 180.0
    /// What a recognized voiceprint counts for, against a named one's 1.
    public var recognizedWeight = 0.5
    /// Learned voiceprints can lift a voice's similarity at most this far above what the person's own
    /// voiceprints give, so automatic learning can't move a profile onto someone else.
    public var automaticLift = 0.08
    /// Speech without overlap a named speaker needs for a voiceprint, in seconds.
    public var minimumNamedSeconds = 2.0
    /// A recognized speaker teaches the profile only with this much clean speech, and this share of its
    /// recording's speech (a distant or background voice doesn't).
    public var minimumLearnSeconds = 15.0
    public var minimumLearnShare = 0.1
    /// A named voice this unlike the profile's named voiceprints is left out (a slip of the name, or a
    /// broken embedding), while the name stays.
    public var outlierSimilarity = 0.4
    /// A recognized voice this alike to a voiceprint the profile has adds nothing new.
    public var duplicateSimilarity = 0.97

    public init() {}
}

/// One profile's similarity to a voice.
public struct SpeakerProfileCandidate: Equatable, Sendable {
    public var profileID: UUID
    /// Against every voiceprint, learned ones within `SpeakerProfileLearning.automaticLift`.
    public var similarity: Double
    /// Against the voiceprints the person chose (named or confirmed) only.
    public var anchorSimilarity: Double
}

/// What a voice is, by the profiles.
public struct SpeakerProfileIdentification: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case recognized, suggested, unknown }
    public var decision: Decision
    public var best: SpeakerProfileCandidate?
    public var runnerUp: SpeakerProfileCandidate?
    public var profileID: UUID? { decision == .unknown ? nil : best?.profileID }
}

/// Every profile's voiceprints, ready to compare voices with (on the Mac when it processes, and on
/// the iPhone for live identification: `SpeakerProfileBook(metadata:)` then `identify(_:matching:)`).
///
/// Each profile keeps a centroid per kind of recording (microphone, room recorder, call audio) and per
/// embedding space, so it recognizes one voice through different microphones; a voice is as alike to
/// the profile as to its closest centroid. Voiceprints count by origin (named over recognized), by
/// how much speech made them, and by age. Learned voiceprints never outweigh the person's own in a
/// centroid, and can't lift a match more than `automaticLift` above what the person's own voiceprints
/// give; a profile without any of the person's voiceprints in a space matches nothing there.
public struct SpeakerProfileBook: Sendable {
    struct Exemplar: Sendable {
        var voiceprint: Voiceprint
        var unit: [Float]
        var personChosen: Bool
        var weight: Double
        var condition: String
    }

    struct Model: Sendable {
        var exemplars: [Exemplar]
        /// Exemplar dot products (they're unit vectors).
        var gram: [[Double]]
        /// Condition → (exemplar index, weight in the full centroid).
        var full: [String: [(Int, Double)]]
        /// Condition → (exemplar index, weight) of the person's voiceprints only.
        var anchors: [String: [(Int, Double)]]
    }

    public let profiles: [UUID: SpeakerProfile]
    public let learning: SpeakerProfileLearning
    /// Profile → embedding space → model.
    let models: [UUID: [String: Model]]

    public init(metadata: LibraryMetadata, learning: SpeakerProfileLearning = .init()) {
        self.init(profiles: metadata.activeSpeakerProfiles, voiceprints: (metadata.voiceprints ?? []).compactMap(\.value), learning: learning)
    }

    public init(profiles: [SpeakerProfile], voiceprints: [Voiceprint], learning: SpeakerProfileLearning = .init()) {
        self.learning = learning
        self.profiles = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var grouped: [UUID: [String: [Voiceprint]]] = [:]
        for print in voiceprints where self.profiles[print.profileID] != nil && print.vector.isUsable {
            grouped[print.profileID, default: [:]][print.vector.space, default: []].append(print)
        }
        var models: [UUID: [String: Model]] = [:]
        for (profile, spaces) in grouped {
            for (space, prints) in spaces {
                let dimensions = Self.dominantDimensions(prints)
                let usable = prints.filter { $0.vector.values.count == dimensions }.sorted { $0.id < $1.id }
                if let model = Self.model(usable, learning: learning) { models[profile, default: [:]][space] = model }
            }
        }
        self.models = models
    }

    /// Profiles that can match a voice in `space`.
    public func profiles(in space: String) -> [UUID] {
        models.compactMap { $0.value[space]?.anchors.isEmpty == false ? $0.key : nil }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Every profile that can match the voice, most alike first. `excludingSource` leaves out
    /// voiceprints learned from that very speaker, so a voice is never recognized by itself.
    public func candidates(for vector: VoiceVector, excluding: Set<UUID> = [],
                           excludingSource: (meetingID: UUID, speakerIDs: Set<String>)? = nil) -> [SpeakerProfileCandidate] {
        guard vector.isUsable, let unit = Self.unit(vector.values) else { return [] }
        var result: [SpeakerProfileCandidate] = []
        for (profile, spaces) in models where !excluding.contains(profile) {
            guard let model = spaces[vector.space], model.exemplars.first?.unit.count == unit.count,
                  let score = score(unit, model, excludingSource: excludingSource) else { continue }
            result.append(SpeakerProfileCandidate(profileID: profile, similarity: score.full, anchorSimilarity: score.anchor))
        }
        return result.sorted { $0.similarity == $1.similarity ? $0.profileID.uuidString < $1.profileID.uuidString : $0.similarity > $1.similarity }
    }

    /// Recognized when the best profile is at least `labelSimilarity` alike and beats the next by
    /// `margin`; suggested when it's at least `suggestionSimilarity` alike; otherwise unknown.
    public func identify(_ vector: VoiceVector, matching: SpeakerProfileMatching = .init(), excluding: Set<UUID> = []) -> SpeakerProfileIdentification {
        let ranked = candidates(for: vector, excluding: excluding)
        return Self.decide(ranked, matching: matching)
    }

    static func decide(_ ranked: [SpeakerProfileCandidate], matching: SpeakerProfileMatching) -> SpeakerProfileIdentification {
        guard let best = ranked.first else { return SpeakerProfileIdentification(decision: .unknown) }
        let runner = ranked.dropFirst().first
        let clear = best.similarity - (runner?.similarity ?? -1) >= matching.margin
        let decision: SpeakerProfileIdentification.Decision
        if best.similarity >= matching.labelSimilarity && clear { decision = .recognized }
        else if best.similarity >= matching.suggestionSimilarity { decision = .suggested }
        else { decision = .unknown }
        return SpeakerProfileIdentification(decision: decision, best: best, runnerUp: runner)
    }

    // MARK: Scoring

    private func score(_ unit: [Float], _ model: Model, excludingSource: (meetingID: UUID, speakerIDs: Set<String>)?) -> (full: Double, anchor: Double)? {
        let dots = model.exemplars.map { Self.dot(unit, $0.unit) }
        let excluded: Set<Int> = excludingSource.map { source in
            Set(model.exemplars.indices.filter {
                model.exemplars[$0].voiceprint.meetingID == source.meetingID && source.speakerIDs.contains(model.exemplars[$0].voiceprint.speakerID)
            })
        } ?? []
        func best(_ centroids: [String: [(Int, Double)]]) -> Double? {
            var top: Double?
            for members in centroids.values {
                let kept = members.filter { !excluded.contains($0.0) }
                guard !kept.isEmpty else { continue }
                var numerator = 0.0, squared = 0.0
                for (i, wi) in kept {
                    numerator += wi * dots[i]
                    for (j, wj) in kept { squared += wi * wj * model.gram[i][j] }
                }
                guard squared > 0 else { continue }
                let cosine = min(1, max(-1, numerator / squared.squareRoot()))
                top = max(top ?? -1, cosine)
            }
            return top
        }
        guard let anchor = best(model.anchors) else { return nil }
        let full = best(model.full) ?? anchor
        return (max(anchor, min(full, anchor + learning.automaticLift)), anchor)
    }

    // MARK: Building

    private static func model(_ prints: [Voiceprint], learning: SpeakerProfileLearning) -> Model? {
        guard let newest = prints.map(\.recordedAt).max() else { return nil }
        var exemplars: [Exemplar] = []
        for print in prints {
            guard let unit = unit(print.vector.values) else { continue }
            let chosen = print.origin.isPersonChosen && print.$origin.isKnown
            exemplars.append(Exemplar(voiceprint: print, unit: unit, personChosen: chosen,
                                      weight: weight(print, personChosen: chosen, newest: newest, learning: learning),
                                      condition: print.condition ?? "unknown"))
        }
        guard !exemplars.isEmpty else { return nil }
        let gram = exemplars.map { a in exemplars.map { b in dot(a.unit, b.unit) } }
        var full: [String: [(Int, Double)]] = [:], anchors: [String: [(Int, Double)]] = [:]
        for condition in Set(exemplars.map(\.condition)) {
            let members = exemplars.indices.filter { exemplars[$0].condition == condition }
            let chosen = members.filter { exemplars[$0].personChosen }, learned = members.filter { !exemplars[$0].personChosen }
            let chosenWeight = chosen.reduce(0) { $0 + exemplars[$1].weight }
            let learnedWeight = learned.reduce(0) { $0 + exemplars[$1].weight }
            // Learned voiceprints never outweigh the person's own in a centroid that has them.
            let scale = chosenWeight > 0 && learnedWeight > chosenWeight ? chosenWeight / learnedWeight : 1
            full[condition] = chosen.map { ($0, exemplars[$0].weight) } + learned.map { ($0, exemplars[$0].weight * scale) }
            if !chosen.isEmpty { anchors[condition] = chosen.map { ($0, exemplars[$0].weight) } }
        }
        return Model(exemplars: exemplars, gram: gram, full: full, anchors: anchors)
    }

    /// Origin × how much speech made it × age, from the profile's newest voiceprint (so the same
    /// voiceprints weigh the same on every device, whenever they're compared).
    static func weight(_ print: Voiceprint, personChosen: Bool, newest: Date, learning: SpeakerProfileLearning) -> Double {
        let origin = personChosen ? 1 : learning.recognizedWeight
        let quality = min(1, max(0.25, print.speechSeconds / 30))
        let days = max(0, newest.timeIntervalSince(print.recordedAt) / 86_400)
        let decay = max(personChosen ? 0.25 : 0.1, pow(0.5, days / max(1, learning.halfLifeDays)))
        return origin * quality * decay
    }

    private static func dominantDimensions(_ prints: [Voiceprint]) -> Int {
        let counts = Dictionary(prints.map { ($0.vector.values.count, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? 0
    }

    static func unit(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return nil }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return values.map { Float(Double($0) / norm) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in vDSP_dotpr(x.baseAddress!, 1, y.baseAddress!, 1, &sum, vDSP_Length(count)) } }
        return Double(sum)
    }

    /// Cosine similarity of two raw vectors, nil when either can't be compared.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, let x = unit(a), let y = unit(b) else { return nil }
        return min(1, max(-1, dot(x, y)))
    }
}
