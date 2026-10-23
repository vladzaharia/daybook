import Foundation

public struct TrackAlignment: Codable, Equatable, Identifiable, Sendable {
    public enum Method: String, Codable, Sendable { case reference, provided, anchors, unaligned }
    public var id: UUID { trackID }
    public var trackID: UUID
    public var method: Method
    public var offset: TimeInterval
    public var rate: Double
    public var matchedAnchors: Int
    public var residual: TimeInterval?
    public var explanation: String
    public init(trackID: UUID, method: Method, offset: TimeInterval = 0, rate: Double = 1,
                matchedAnchors: Int = 0, residual: TimeInterval? = nil, explanation: String = "") {
        self.trackID = trackID; self.method = method; self.offset = offset; self.rate = rate
        self.matchedAnchors = matchedAnchors; self.residual = residual; self.explanation = explanation
    }
}

public struct FusionResult: Sendable {
    public var segments: [TranscriptSegment]
    public var alignments: [TrackAlignment]
    public var unalignedTrackIDs: [UUID] { alignments.filter { $0.method == .unaligned }.map(\.trackID) }
}

/// Conservative text-anchor alignment. Raw transcripts are never mutated or discarded.
/// Clock transforms use meetingTime = trackTime * rate + offset.
public enum TranscriptFusion {
    public static func fuse(_ transcripts: [TrackTranscript], tracks: [RecordingTrack] = []) -> FusionResult {
        // Keep the initial usable source as the timeline origin when attaching another recording.
        // Replacing a source's model run must not change that source's position in the meeting.
        var sourceOrder: [UUID] = []
        for transcript in transcripts where !sourceOrder.contains(transcript.trackID) { sourceOrder.append(transcript.trackID) }
        let grouped = Dictionary(grouping: transcripts, by: \.trackID)
        let latest = sourceOrder.compactMap { id in grouped[id]?.max { $0.createdAt < $1.createdAt } }
        func explicitOffset(_ transcript: TrackTranscript) -> TimeInterval? {
            let value = transcript.knownOffset ?? tracks.first(where: { $0.id == transcript.trackID })?.offset
            return value?.isFinite == true ? value : nil
        }
        let ordered = latest.filter { !valid($0.segments).isEmpty } + latest.filter { valid($0.segments).isEmpty }
        guard let reference = ordered.first else { return FusionResult(segments: [], alignments: []) }
        let referenceOffset = explicitOffset(reference) ?? 0
        let referenceSegments = valid(reference.segments)
        var combined = referenceSegments.map { transformed($0, offset: referenceOffset, rate: 1) }
        var alignments = [TrackAlignment(trackID: reference.trackID, method: .reference,
                                        offset: referenceOffset, explanation: "Reference recording for the meeting timeline.")]
        for transcript in ordered.dropFirst() {
            let segments = valid(transcript.segments)
            let alignment: TrackAlignment
            if let offset = explicitOffset(transcript) {
                alignment = TrackAlignment(trackID: transcript.trackID, method: .provided, offset: offset,
                                           explanation: "Timing established by recording capture or manual alignment. Short replies and differing wording remain separate.")
            } else {
                alignment = estimate(segments, reference: referenceSegments, trackID: transcript.trackID, referenceOffset: referenceOffset)
            }
            alignments.append(alignment)
            guard alignment.method != .unaligned else { continue }
            for segment in segments {
                let candidate = transformed(segment, offset: alignment.offset, rate: alignment.rate)
                let candidateWords = tokens(candidate.text)
                // Similar words elsewhere in a meeting are distinct utterances. Both time and text must agree.
                let match = combined.indices.filter { index in
                    let existing = combined[index]
                    guard !existing.provenance.contains(where: { $0.trackID == segment.trackID }) else { return false }
                    let overlap = min(existing.end, candidate.end) - max(existing.start, candidate.start)
                    let shorterDuration = max(0.1, min(existing.end - existing.start, candidate.end - candidate.start))
                    guard candidateWords.count >= 4, overlap / shorterDuration >= 0.45,
                          abs(existing.start - candidate.start) <= 2.0 else { return false }
                    // Short acknowledgments can be different people replying at nearly the same time.
                    // Lexical differences (especially negation or an extra clause) are evidence, even
                    // when an ASR confidence estimate favors one version. Keep those passages intact.
                    return tokens(existing.text) == candidateWords
                }.min { abs(combined[$0].start - candidate.start) < abs(combined[$1].start - candidate.start) }
                if let index = match {
                    let old = combined[index]
                    var preferred = (candidate.confidence ?? 0.5) > (old.confidence ?? 0.5) ? candidate : old
                    preferred.provenance = old.provenance + candidate.provenance
                    combined[index] = preferred
                } else { combined.append(candidate) }
            }
        }
        combined.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        return FusionResult(segments: combined, alignments: alignments)
    }

    private static func valid(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func transformed(_ segment: TranscriptSegment, offset: Double, rate: Double) -> TranscriptSegment {
        var copy = segment
        copy.start = segment.start * rate + offset; copy.end = segment.end * rate + offset
        if copy.provenance.isEmpty {
            copy.provenance = [SegmentProvenance(trackID: segment.trackID, segmentID: segment.id, start: segment.start,
                                                 end: segment.end, text: segment.text, confidence: segment.confidence)]
        }
        return copy
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
    private static func estimate(_ source: [TranscriptSegment], reference: [TranscriptSegment], trackID: UUID,
                                 referenceOffset: Double) -> TrackAlignment {
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
        var hypotheses: [(Double, Double)] = anchors.map { (1, $0.reference - $0.source) }
        for i in anchors.indices {
            for j in anchors.indices where j > i {
                let span = anchors[j].source - anchors[i].source
                guard abs(span) >= 10 else { continue }
                let rate = (anchors[j].reference - anchors[i].reference) / span
                guard (0.97...1.03).contains(rate) else { continue }
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
        // Refine over the consensus, limiting drift to the same conservative interval.
        let meanX = fit.inliers.reduce(0) { $0 + $1.source } / Double(fit.inliers.count)
        let meanY = fit.inliers.reduce(0) { $0 + $1.reference } / Double(fit.inliers.count)
        let denominator = fit.inliers.reduce(0) { $0 + pow($1.source - meanX, 2) }
        let rate = denominator > 0 ? fit.inliers.reduce(0) { $0 + ($1.source - meanX) * ($1.reference - meanY) } / denominator : 1
        guard (0.97...1.03).contains(rate) else { return failure }
        let offset = meanY - rate * meanX
        let residual = fit.inliers.reduce(0) { $0 + abs($1.reference - ($1.source * rate + offset)) } / Double(fit.inliers.count)
        return TrackAlignment(trackID: trackID, method: .anchors, offset: offset, rate: rate,
                              matchedAnchors: fit.inliers.count, residual: residual,
                              explanation: "Aligned using \(fit.inliers.count) distinct shared phrases; clock drift estimated from their timestamps. Short replies and differing wording remain separate.")
    }

    private static func tokens(_ text: String) -> [String] {
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
