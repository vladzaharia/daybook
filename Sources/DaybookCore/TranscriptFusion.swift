import Foundation

public struct TrackAlignment: Codable, Equatable, Identifiable, Sendable {
    /// `audio`: measured from the recordings' sound. `timestamps`: placed only by wall-clock start
    /// times, the weakest evidence. Older libraries only contain the first four.
    public enum Method: String, Codable, Sendable { case reference, provided, anchors, unaligned, audio, timestamps }
    public var id: UUID { trackID }
    public var trackID: UUID
    @Extensible public var method: Method
    public var offset: TimeInterval
    public var rate: Double
    public var matchedAnchors: Int
    public var residual: TimeInterval?
    public var explanation: String
    /// How sure the timing is (0–1), when the method measures it.
    public var confidence: Double?
    /// The recording the timing was measured against, when not the timeline itself.
    public var referenceTrackID: UUID?
    public init(trackID: UUID, method: Method, offset: TimeInterval = 0, rate: Double = 1,
                matchedAnchors: Int = 0, residual: TimeInterval? = nil, explanation: String = "",
                confidence: Double? = nil, referenceTrackID: UUID? = nil) {
        self.trackID = trackID; self.method = method; self.offset = offset; self.rate = rate
        self.matchedAnchors = matchedAnchors; self.residual = residual; self.explanation = explanation
        self.confidence = confidence; self.referenceTrackID = referenceTrackID
    }
    /// Clock drift against the meeting timeline in parts per million.
    public var driftPPM: Double { (rate - 1) * 1_000_000 }
}

public struct FusionResult: Sendable {
    public var segments: [TranscriptSegment]
    public var alignments: [TrackAlignment]
    /// What fusion did per source; stored on the meeting by `Meeting.applyFusion`.
    public var summary: FusionSummary? = nil
    /// Speakers fusion introduced (the person recording); `applyFusion` adds those not yet present.
    public var addedSpeakers: [Speaker] = []
    /// Passages left out as background audio (`FusionInputs.background`): every source passage they
    /// came from was judged a TV, radio, or music. `applyFusion` keeps them in `Meeting.backgroundPassages`.
    public var backgroundSegments: [TranscriptSegment] = []
    public var unalignedTrackIDs: [UUID] { alignments.filter { $0.method == .unaligned }.map(\.trackID) }
}

/// Places every recording's transcript on one meeting timeline and fuses them into a single
/// transcript. Raw transcripts are never mutated or discarded.
/// Clock transforms use meetingTime = trackTime * rate + offset.
///
/// Timing, per recording, in order of preference: an offset known from capture or set by the
/// person (`provided`); an audio alignment measured against an already placed recording
/// (`audio`); distinct shared phrases (`anchors`); wall-clock start times (`timestamps`).
/// Otherwise the recording stays out of the unified transcript (`unaligned`).
///
/// Wording: words from all placed recordings are aligned in time and text (a word transition
/// network, as in ROVER) and voted on, weighted by each source's role for that speech, how it was
/// placed, and recognition confidence. Speech heard by several recordings appears once; provenance
/// lists every recording and which words each supported. See `docs/alignment.md`.
public enum TranscriptFusion {
    public static func fuse(_ transcripts: [TrackTranscript], tracks: [RecordingTrack] = []) -> FusionResult {
        fuse(transcripts, tracks: tracks, inputs: FusionInputs())
    }

    /// Fusion with placements, stored audio alignments, start dates, and speakers.
    public static func fuse(_ transcripts: [TrackTranscript], tracks: [RecordingTrack], inputs: FusionInputs) -> FusionResult {
        MultiSourceFusion(transcripts: transcripts, tracks: tracks, inputs: inputs).run()
    }

    /// Fuses everything a meeting stores: transcripts, tracks, measured audio alignments, speakers,
    /// and renamed speakers. Apply the result with `Meeting.applyFusion`.
    public static func fuse(meeting: Meeting, recordingStartDates: [UUID: Date] = [:], options: FusionOptions = .init()) -> FusionResult {
        fuse(meeting.transcripts, tracks: meeting.tracks,
             inputs: FusionInputs(meeting: meeting, recordingStartDates: recordingStartDates, options: options))
    }

    static func valid(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private struct Anchor { var source: Double; var reference: Double }
    private struct AnchorText {
        var id: UUID
        var start: Double
        var words: [String]
        var counts: [String: Int]
        var qualifies: Bool
        init(_ segment: TranscriptSegment) {
            id = segment.id; start = segment.start; words = tokens(segment.text)
            counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
            qualifies = words.count >= 4 && words.joined(separator: " ").count >= 20
        }
    }
    /// Text-anchor timing of `source` against `reference` segments whose times are already on the
    /// meeting timeline less `referenceOffset`.
    ///
    /// From fusion version 2 a fit's rate stays within `ClockRate.maximumDriftPPM`, and it's measured at all only when
    /// the phrases span at least `rateSpan(overlap:)`; otherwise the fit is an offset at rate 1. A few phrases a few
    /// seconds apart can't tell a clock's drift from the phrases' own timing noise, and a rate stored from them would
    /// misplace the end of a long recording by minutes. Its confidence grows with the span, full from two minutes.
    static func estimate(_ source: [TranscriptSegment], reference: [TranscriptSegment], trackID: UUID,
                         referenceOffset: Double, version: Int = FusionSummary.currentVersion) -> TrackAlignment {
        let failure = TrackAlignment(trackID: trackID, method: .unaligned,
                                     explanation: "Insufficient consistent shared phrases. Original transcript retained separately; set a verified time offset to combine it.")
        let candidates = reference.map(AnchorText.init).filter(\.qualifies)
        let sources = source.map(AnchorText.init).filter(\.qualifies)
        var anchors: [Anchor] = []
        var usedReferenceIDs = Set<UUID>()
        for segment in sources {
            let matches = candidates.map { ($0, similarity(segment, $0)) }.filter { $0.1 >= 0.80 }.sorted { $0.1 > $1.1 }
            guard let best = matches.first, matches.count == 1 || best.1 - matches[1].1 > 0.10,
                  !usedReferenceIDs.contains(best.0.id) else { continue }
            // Repeated phrases on either source cannot establish timing.
            guard sources.filter({ similarity($0, segment) >= 0.90 }).count == 1 else { continue }
            usedReferenceIDs.insert(best.0.id)
            anchors.append(Anchor(source: segment.start, reference: best.0.start + referenceOffset))
        }
        guard anchors.count >= 3 else { return failure }
        // Bound consensus work for long recordings while retaining anchors across the full timeline.
        if anchors.count > 120 {
            anchors.sort { $0.source < $1.source }
            anchors = (0..<120).map { anchors[$0 * (anchors.count - 1) / 119] }
        }
        // RANSAC-style pair hypotheses tolerate unrelated or mistranscribed matching phrases.
        let drift = version >= 2 ? ClockRate.maximumDriftPPM / 1_000_000 : 0.03
        var hypotheses: [(Double, Double)] = anchors.map { (1, $0.reference - $0.source) }
        for i in anchors.indices {
            for j in anchors.indices where j > i {
                let span = anchors[j].source - anchors[i].source
                guard abs(span) >= 10 else { continue }
                let rate = (anchors[j].reference - anchors[i].reference) / span
                guard abs(rate - 1) <= drift else { continue }
                hypotheses.append((rate, anchors[i].reference - rate * anchors[i].source))
            }
        }
        var best: (rate: Double, offset: Double, inliers: [Anchor], residual: Double)?
        for (rate, offset) in hypotheses {
            let inliers = anchors.filter { abs($0.reference - ($0.source * rate + offset)) <= 1.5 }
            guard inliers.count >= 3 else { continue }
            let residual = inliers.reduce(0) { $0 + abs($1.reference - ($1.source * rate + offset)) } / Double(inliers.count)
            if best == nil || inliers.count > best!.inliers.count || (inliers.count == best!.inliers.count && residual < best!.residual) {
                best = (rate, offset, inliers, residual)
            }
        }
        guard let fit = best, fit.inliers.count >= max(3, Int(ceil(Double(anchors.count) * 0.6))),
              let first = fit.inliers.map(\.source).min(), let last = fit.inliers.map(\.source).max(), last - first >= 10 else { return failure }
        // Refine over the consensus, limiting drift to the same interval.
        let meanX = fit.inliers.reduce(0) { $0 + $1.source } / Double(fit.inliers.count)
        let meanY = fit.inliers.reduce(0) { $0 + $1.reference } / Double(fit.inliers.count)
        let denominator = fit.inliers.reduce(0) { $0 + pow($1.source - meanX, 2) }
        let fitted = denominator > 0 ? fit.inliers.reduce(0) { $0 + ($1.source - meanX) * ($1.reference - meanY) } / denominator : 1
        let span = last - first
        let rate: Double
        if version >= 2 {
            // The stretch of the source the reference also covers, at the offset alone.
            let shift = meanY - meanX
            let valid = Self.valid(source), others = Self.valid(reference)
            let sourceStart = valid.map(\.start).min() ?? 0, sourceEnd = valid.map(\.end).max() ?? 0
            let referenceStart = (others.map(\.start).min() ?? 0) + referenceOffset - shift
            let referenceEnd = (others.map(\.end).max() ?? 0) + referenceOffset - shift
            let covered = min(sourceEnd, referenceEnd) - max(sourceStart, referenceStart)
            rate = span >= rateSpan(overlap: max(0, covered)) && abs(fitted - 1) <= drift ? fitted : 1
        } else {
            guard (0.97...1.03).contains(fitted) else { return failure }
            rate = fitted
        }
        let offset = meanY - rate * meanX
        let residual = fit.inliers.reduce(0) { $0 + abs($1.reference - ($1.source * rate + offset)) } / Double(fit.inliers.count)
        var confidence: Double?
        if version >= 2 {
            let count = min(1, Double(fit.inliers.count) / 12), closeness = max(0, 1 - residual / 1.5)
            confidence = ((0.45 + 0.4 * count + 0.15 * closeness) * (0.7 + 0.3 * min(1, span / 120)) * 100).rounded() / 100
        }
        let measured = version < 2 || rate != 1
        return TrackAlignment(trackID: trackID, method: .anchors, offset: offset, rate: rate,
                              matchedAnchors: fit.inliers.count, residual: residual,
                              explanation: measured
                                ? "Aligned using \(fit.inliers.count) distinct shared phrases; clock drift estimated from their timestamps. Short replies and differing wording remain separate."
                                : "Aligned using \(fit.inliers.count) distinct shared phrases. Short replies and differing wording remain separate.",
                              confidence: confidence)
    }

    /// How far apart, in the source's seconds, phrase anchors must be before their fit measures a clock rate: ten
    /// minutes, or 30% of the stretch both recordings cover when that's longer.
    static func rateSpan(overlap: TimeInterval) -> TimeInterval { max(600, 0.3 * overlap) }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func similarity(_ first: AnchorText, _ second: AnchorText) -> Double {
        let a = first.words, b = second.words
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        if a == b { return 1 }
        // A multiset upper bound skips unrelated passages without allocating an edit-distance table.
        // Cached tokenization also avoids repeating Unicode normalization for every candidate pair.
        let shared = first.counts.reduce(0) { $0 + min($1.value, second.counts[$1.key] ?? 0) }
        guard 2 * Double(shared) / Double(a.count + b.count) >= 0.8 else { return 0 }
        // Ordered token overlap penalizes reordered words and differing segmentation.
        var previous = Array(repeating: 0, count: b.count + 1)
        var current = Array(repeating: 0, count: b.count + 1)
        for word in a {
            current[0] = 0
            for j in b.indices { current[j + 1] = word == b[j] ? previous[j] + 1 : max(previous[j + 1], current[j]) }
            swap(&previous, &current)
        }
        return 2 * Double(previous[b.count]) / Double(a.count + b.count)
    }
}
