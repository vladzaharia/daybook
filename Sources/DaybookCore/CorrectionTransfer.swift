import Foundation

public struct CorrectionTransferIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { originalSegment.id }
    /// Includes the user's corrected text and the prior source timestamps/text for review.
    public var originalSegment: TranscriptSegment
    public var candidateSegmentIDs: [UUID]
    public var reason: String
    public init(originalSegment: TranscriptSegment, candidateSegmentIDs: [UUID] = [], reason: String) {
        self.originalSegment = originalSegment; self.candidateSegmentIDs = candidateSegmentIDs; self.reason = reason
    }
}

/// A fusion result with saved corrections already carried over to it, worked out off the main actor
/// (`Meeting.preparingFusion`) and applied with `Meeting.applyFusion(_:)`.
public struct PreparedFusion: Sendable {
    public let result: FusionResult
    let transferred: CorrectionTransfer.Result
    /// What the transfer read. Applied to a conversation where any of it changed since, the transfer
    /// is worked out again there, so a correction made meanwhile is never lost.
    let basis: CorrectionTransfer.Basis
}

extension Meeting {
    /// Carries saved corrections over to a fusion result, for `applyFusion(_:)` later. Pure: run it
    /// off the main actor on a snapshot.
    public func preparingFusion(_ result: FusionResult) -> PreparedFusion {
        PreparedFusion(result: result, transferred: CorrectionTransfer.apply(to: result.segments, in: self), basis: .init(self))
    }

    /// Applies a prepared fusion, as `applyFusion(_ result:)` does.
    @discardableResult public mutating func applyFusion(_ prepared: PreparedFusion) -> [CorrectionTransferIssue] {
        guard prepared.basis == .init(self) else { return applyFusion(prepared.result) }
        return applyFusion(prepared.result, transferred: prepared.transferred)
    }
}

enum CorrectionTransfer {
    struct Result: Sendable { var segments: [TranscriptSegment]; var issues: [CorrectionTransferIssue] }
    private struct Proposal { var original: TranscriptSegment; var candidates: [Int]; var reviewCandidates: [Int] }

    /// Everything `apply` reads from the conversation.
    struct Basis: Equatable, Sendable {
        var revisions: [MeetingRevision]
        var unifiedTranscript: [TranscriptSegment]
        var issues: [CorrectionTransferIssue]?
        var transcripts: [TrackTranscript]
        init(_ meeting: Meeting) {
            revisions = meeting.revisions; unifiedTranscript = meeting.unifiedTranscript
            issues = meeting.correctionTransferIssues; transcripts = meeting.transcripts
        }
    }

    static func apply(to segments: [TranscriptSegment], in meeting: Meeting) -> Result {
        var seen = Set<UUID>()
        let edits = meeting.revisions.filter { $0.field.hasPrefix("segment:") }.sorted { $0.date > $1.date }
        // Looked up by ID, once: each transcript run's passages are flattened a single time.
        let transferred = Set(meeting.revisions.lazy.map(\.field).filter { $0.hasPrefix("correction-transfer:") })
        let unified = Dictionary(meeting.unifiedTranscript.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = Dictionary((meeting.correctionTransferIssues ?? []).map { ($0.id, $0.originalSegment) }, uniquingKeysWith: { first, _ in first })
        let raw = Dictionary(meeting.transcripts.lazy.flatMap(\.segments).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var originals: [TranscriptSegment] = []
        for edit in edits {
            guard let id = UUID(uuidString: String(edit.field.dropFirst(8))), seen.insert(id).inserted else { continue }
            guard !transferred.contains("correction-transfer:\(id.uuidString)") else { continue }
            if var original = unified[id] ?? pending[id] ?? raw[id] {
                // The revision is authoritative even after a prior fusion no longer displays this passage.
                original.text = edit.newValue
                if original.provenance.isEmpty, let source = raw[id] {
                    original.provenance = [provenance(source)]
                }
                originals.append(original)
            }
        }

        // Passages by their own identity and by every source passage they cite.
        var byIdentity: [UUID: [Int]] = [:]
        for (index, candidate) in segments.enumerated() {
            for identity in Set([candidate.id] + candidate.provenance.map(\.segmentID)) { byIdentity[identity, default: []].append(index) }
        }
        let proposals = originals.map { original -> Proposal in
            let identities = Set(original.provenance.map(\.segmentID) + [original.id])
            let exact = Set(identities.flatMap { byIdentity[$0] ?? [] }).sorted()
            if exact.count > 1 {
                // A fused passage keeps the identity of its first source's segment, while another
                // recording's segment can be cited by several passages. Prefer the passage with the
                // corrected identity, then one whose cited source times clearly overlap the most.
                let sameID = exact.filter { segments[$0].id == original.id }
                if sameID.count == 1 { return Proposal(original: original, candidates: sameID, reviewCandidates: exact) }
                let scored = exact.map { ($0, sharedSourceTime(original.provenance, segments[$0].provenance)) }.sorted { $0.1 > $1.1 }
                if scored[0].1 > 0, scored[0].1 >= 2 * scored[1].1 {
                    return Proposal(original: original, candidates: [scored[0].0], reviewCandidates: exact)
                }
            }
            if !exact.isEmpty { return Proposal(original: original, candidates: exact, reviewCandidates: exact) }
            let timed = segments.indices.filter { index in
                let candidateSources = segments[index].provenance.isEmpty ? [provenance(segments[index])] : segments[index].provenance
                return original.provenance.contains { old in candidateSources.contains { corresponds(old, $0) } }
            }
            let review = segments.indices.filter { index in
                let sources = segments[index].provenance.isEmpty ? [provenance(segments[index])] : segments[index].provenance
                return original.provenance.contains { old in sources.contains { new in
                    old.trackID == new.trackID && min(old.end, new.end) > max(old.start, new.start)
                } }
            }
            return Proposal(original: original, candidates: timed, reviewCandidates: review)
        }

        var output = segments
        var issues: [CorrectionTransferIssue] = []
        let unique = proposals.filter { $0.candidates.count == 1 }
        var applied = Set<Int>()
        for proposal in proposals {
            guard let target = proposal.candidates.first, proposal.candidates.count == 1 else {
                issues.append(CorrectionTransferIssue(originalSegment: proposal.original,
                    candidateSegmentIDs: (proposal.candidates.isEmpty ? proposal.reviewCandidates : proposal.candidates).map { segments[$0].id },
                    reason: proposal.candidates.isEmpty
                        ? "The new transcript changed this passage’s source timing or wording, or its source is unaligned. Review the saved correction before applying it."
                        : "More than one new passage matches this correction. Choose the intended passage after reviewing the source audio."))
                continue
            }
            let contenders = unique.filter { $0.candidates[0] == target }
            guard Set(contenders.map { $0.original.text }).count == 1 else {
                issues.append(CorrectionTransferIssue(originalSegment: proposal.original,
                    candidateSegmentIDs: [segments[target].id],
                    reason: "Different saved corrections match the same new passage. Review which wording to keep."))
                continue
            }
            guard applied.insert(target).inserted else { continue }
            output[target].id = proposal.original.id
            output[target].text = proposal.original.text
        }
        return Result(segments: output, issues: issues)
    }

    /// Seconds of the same source segments that both passages cite.
    private static func sharedSourceTime(_ old: [SegmentProvenance], _ new: [SegmentProvenance]) -> Double {
        old.reduce(0) { total, a in
            total + new.filter { $0.segmentID == a.segmentID }.reduce(0) { $0 + max(0, min(a.end, $1.end) - max(a.start, $1.start)) }
        }
    }

    private static func provenance(_ segment: TranscriptSegment) -> SegmentProvenance {
        SegmentProvenance(trackID: segment.trackID, segmentID: segment.id, start: segment.start,
                          end: segment.end, text: segment.text, confidence: segment.confidence)
    }

    private static func corresponds(_ old: SegmentProvenance, _ new: SegmentProvenance) -> Bool {
        guard old.trackID == new.trackID, old.start.isFinite, old.end.isFinite, new.start.isFinite, new.end.isFinite,
              old.end > old.start, new.end > new.start,
              abs(old.start - new.start) <= 0.75, abs(old.end - new.end) <= 0.75 else { return false }
        let overlap = min(old.end, new.end) - max(old.start, new.start)
        guard overlap / max(old.end - old.start, new.end - new.start) >= 0.8 else { return false }
        let a = tokens(old.text), b = tokens(new.text)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Close wording is accepted only for a substantial passage with strong source-time agreement.
        guard min(a.count, b.count) >= 4 else { return false }
        var previous = Array(0...b.count)
        for i in a.indices {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i + 1
            for j in b.indices {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (a[i] == b[j] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count)) >= 0.85
    }

    private static func tokens(_ value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
