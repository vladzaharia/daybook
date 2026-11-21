import Foundation

/// The per-file quality bar a compressed copy must clear before it replaces its recording (docs/architecture.md,
/// "Compressing older recordings"): the speech model transcribes the same sample of the original and of the copy, and
/// the two must say nearly the same words. Measured on Daybook's own pipeline with its default models (docs/validation.md):
/// honest copies disagree by at most 3.3% (AAC 64 kbit/s) and 4.4% (AAC 48 kbit/s at 16 kHz) over a file, 4.9% in the
/// worst minute; a copy with one channel lost disagreed by 64%.
public enum TranscriptAgreement {
    /// How much disagreement a copy may show.
    public struct Bar: Equatable, Sendable {
        /// Over the whole sample: word-level edit distance over the original's word count.
        public var overall: Double
        /// In any one span (up to 60 s) with at least `spanMinimumWords` words; nil for no per-span bound.
        public var perSpan: Double?
        public init(overall: Double, perSpan: Double?) { self.overall = overall; self.perSpan = perSpan }

        /// A model that transcribes the same audio the same way every time (Parakeet: re-runs are bit-identical).
        public static let deterministic = Bar(overall: 0.05, perSpan: 0.08)
        /// One that doesn't (Whisper disagrees with itself by about 2.9%): a looser bound over the sample, none per span.
        public static let nondeterministic = Bar(overall: 0.12, perSpan: nil)
    }

    /// A span with fewer words than this isn't held to the per-span bound: one word in ten is already 10%.
    public static let spanMinimumWords = 30

    public struct Result: Equatable, Sendable {
        /// Disagreement over the whole sample; nil when the original's transcript of it had no words.
        public var disagreement: Double?
        /// The worst span held to the per-span bound.
        public var worstSpan: Double?
        public var words: Int
        public var passes: Bool
        public init(disagreement: Double?, worstSpan: Double?, words: Int, passes: Bool) {
            self.disagreement = disagreement; self.worstSpan = worstSpan; self.words = words; self.passes = passes
        }
    }

    /// Lowercased words, punctuation and symbols dropped (apostrophes and digits kept), so "Hello, world!" and
    /// "hello world" agree.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" ? $0 : " " }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0).replacingOccurrences(of: "’", with: "'") }
    }

    /// Word-level Levenshtein distance: insertions, deletions, and substitutions to turn one into the other.
    public static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count), current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The original's and the copy's transcripts of the same spans, judged against `bar`.
    public static func judge(_ spans: [(original: String, copy: String)], bar: Bar) -> Result {
        var errors = 0, total = 0, worst: Double?
        for span in spans {
            let a = words(span.original), b = words(span.copy)
            let d = distance(a, b)
            errors += d; total += a.count
            if a.count >= spanMinimumWords {
                let share = Double(d) / Double(a.count)
                worst = max(worst ?? share, share)
            }
        }
        guard total > 0 else {
            // Nothing said in the original's sample: the copy must say nothing too.
            let spoken = spans.contains { !words($0.copy).isEmpty }
            return Result(disagreement: nil, worstSpan: nil, words: 0, passes: !spoken)
        }
        let overall = Double(errors) / Double(total)
        let passes = overall <= bar.overall && (bar.perSpan.map { limit in (worst ?? 0) <= limit } ?? true)
        return Result(disagreement: overall, worstSpan: worst, words: total, passes: passes)
    }
}

/// Which stretches of a recording the quality bar listens to: where its transcript has speech, up to 10 minutes in all,
/// in spans of at most 60 s spread across the recording.
public enum TranscriptSample {
    public static let total: TimeInterval = 600
    public static let span: TimeInterval = 60

    /// Speech in a track by its own transcript, or, for an original transcribed through a copy made from it (the
    /// microphone through its echo-removed copy), by that copy's: the same timeline.
    public static func speech(of track: RecordingTrack, in meeting: Meeting) -> [ClosedRange<TimeInterval>] {
        let derived = Set(meeting.tracks.filter { $0.derivedFrom == track.id }.map(\.id))
        let own = meeting.transcripts.filter { $0.trackID == track.id }
        let runs = own.isEmpty ? meeting.transcripts.filter { derived.contains($0.trackID) } : own
        guard let latest = runs.max(by: { $0.createdAt < $1.createdAt }) else { return [] }
        let ranges = latest.segments.compactMap { segment -> ClosedRange<TimeInterval>? in
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start, segment.start >= 0 else { return nil }
            return segment.start...segment.end
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.5 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The spans to listen to: all the speech when there's 10 minutes or less (cut into 60 s spans), otherwise ten
    /// 60 s spans starting at even steps through the speech. Empty when there's no speech.
    public static func spans(_ speech: [ClosedRange<TimeInterval>], duration: TimeInterval? = nil) -> [ClosedRange<TimeInterval>] {
        let clipped = speech.compactMap { range -> ClosedRange<TimeInterval>? in
            guard let duration else { return range }
            let upper = min(range.upperBound, duration)
            return upper > range.lowerBound ? range.lowerBound...upper : nil
        }
        let spoken = clipped.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        guard spoken > 0 else { return [] }
        func cut(_ range: ClosedRange<TimeInterval>, from start: TimeInterval, length: TimeInterval) -> ClosedRange<TimeInterval> {
            start...min(range.upperBound, start + length)
        }
        if spoken <= total {
            return clipped.flatMap { range in
                stride(from: range.lowerBound, to: range.upperBound, by: span).map { cut(range, from: $0, length: span) }
            }.filter { $0.upperBound - $0.lowerBound > 0.25 }
        }
        let count = Int(total / span)
        var result: [ClosedRange<TimeInterval>] = []
        for k in 0..<count {
            // A point through the speech (by speaking time), then up to 60 s of the stretch it falls in.
            var target = (Double(k) + 0.5) / Double(count) * spoken
            for range in clipped {
                let length = range.upperBound - range.lowerBound
                if target <= length {
                    let start = max(range.lowerBound, min(range.lowerBound + target, range.upperBound - span))
                    result.append(cut(range, from: start, length: span))
                    break
                }
                target -= length
            }
        }
        return result
    }
}

/// What the quality bar did for a copy, kept on its `TrackEncoding`.
public struct TranscriptCheck: Codable, Equatable, Sendable {
    /// The check ran (false: skipped, with the reason).
    public var ran: Bool
    /// Why it didn't: "no speech" or "no model".
    public var skipped: String?
    /// The transcription model it used (`ModelReference.id`).
    public var model: String?
    public var sampleSeconds: Double?
    /// Word-level disagreement between the original's transcript of the sample and the copy's.
    public var disagreement: Double?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(ran: Bool, skipped: String? = nil, model: String? = nil, sampleSeconds: Double? = nil, disagreement: Double? = nil) {
        self.ran = ran; self.skipped = skipped; self.model = model; self.sampleSeconds = sampleSeconds; self.disagreement = disagreement
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case ran, skipped, model, sampleSeconds, disagreement }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ran = try values.decode(Bool.self, forKey: .ran)
        skipped = try values.decodeIfPresent(String.self, forKey: .skipped)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        sampleSeconds = try values.decodeIfPresent(Double.self, forKey: .sampleSeconds)
        disagreement = try values.decodeIfPresent(Double.self, forKey: .disagreement)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ran, forKey: .ran)
        try values.encodeIfPresent(skipped, forKey: .skipped)
        try values.encodeIfPresent(model, forKey: .model)
        try values.encodeIfPresent(sampleSeconds, forKey: .sampleSeconds)
        try values.encodeIfPresent(disagreement, forKey: .disagreement)
        try unknownFields.encode(to: encoder)
    }
}
