import Foundation

public struct CorrectionTransferIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { originalSegment.id }
    /// Includes the user's corrected text and the prior source timestamps/text for review.
    public var originalSegment: TranscriptSegment
    public var candidateSegmentIDs: [UUID]
    public var reason: String
    /// The speaker the person gave the passage (`Meeting.passageSpeakers`), which the passage it's applied to gets; nil
    /// for a passage they only corrected. A passage they gave a speaker without correcting it keeps the new words.
    public var speakerID: String?
    public init(originalSegment: TranscriptSegment, candidateSegmentIDs: [UUID] = [], reason: String, speakerID: String? = nil) {
        self.originalSegment = originalSegment; self.candidateSegmentIDs = candidateSegmentIDs; self.reason = reason
        self.speakerID = speakerID
    }
}

/// A fusion result with saved corrections already carried over to it, and the transcript's flags worked out
/// (`TranscriptFlags`), off the main actor (`Meeting.preparingFusion`); applied with `Meeting.applyFusion(_:)`.
public struct PreparedFusion: Sendable {
    public let result: FusionResult
    let transferred: CorrectionTransfer.Result
    let flags: [TranscriptFlag]
    let ranking: TranscriptFlags.Ranking?
    /// What the transfer read. Applied to a conversation where any of it changed since, the transfer
    /// is worked out again there, so a correction made meanwhile is never lost.
    let basis: CorrectionTransfer.Basis
}

extension Meeting {
    /// Whether the issue is about words the person corrected (a `.segment` entry), not only the speaker they gave it.
    public func correctsWords(_ issue: CorrectionTransferIssue) -> Bool {
        issue.speakerID == nil || revisions.contains { $0.kind == .segment(issue.id) }
    }

    /// Carries saved corrections over to a fusion result and finds the words the transcript may have wrong, for
    /// `applyFusion(_:)` later. Pure: run it off the main actor on a snapshot.
    public func preparingFusion(_ result: FusionResult, ranking: TranscriptFlags.Ranking? = nil) -> PreparedFusion {
        let transferred = CorrectionTransfer.apply(to: result.segments, in: self)
        var fused = self
        fused.applyFusion(result, transferred: transferred, ranking: ranking)
        return PreparedFusion(result: result, transferred: transferred, flags: fused.transcriptFlags ?? [], ranking: ranking,
                              basis: .init(self))
    }

    /// Applies a prepared fusion, as `applyFusion(_ result:)` does.
    @discardableResult public mutating func applyFusion(_ prepared: PreparedFusion) -> [CorrectionTransferIssue] {
        guard prepared.basis == .init(self) else { return applyFusion(prepared.result, ranking: prepared.ranking) }
        return applyFusion(prepared.result, transferred: prepared.transferred, flags: prepared.flags)
    }
}

enum CorrectionTransfer {
    struct Result: Sendable { var segments: [TranscriptSegment]; var issues: [CorrectionTransferIssue] }
    /// Where one passage the person changed goes: its words if they corrected them (`corrects`), its speaker if they gave
    /// it one (`speakerID`).
    private struct Proposal {
        var original: TranscriptSegment; var candidates: [Int]; var reviewCandidates: [Int]
        var corrects = true; var speakerID: String?
    }

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
        let edits = meeting.revisions.compactMap { revision -> (id: UUID, edit: MeetingRevision)? in
            guard case .segment(let id) = revision.kind else { return nil }
            return (id, revision)
        }.sorted { $0.edit.date > $1.edit.date }
        // Looked up by ID, once: each transcript run's passages are flattened a single time.
        let transferred = Set(meeting.revisions.compactMap { revision -> UUID? in
            guard case .correctionTransfer(let id) = revision.kind else { return nil }
            return id
        })
        let unified = Dictionary(meeting.unifiedTranscript.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = Dictionary((meeting.correctionTransferIssues ?? []).map { ($0.id, $0.originalSegment) }, uniquingKeysWith: { first, _ in first })
        let raw = Dictionary(meeting.transcripts.lazy.flatMap(\.segments).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func original(_ id: UUID) -> TranscriptSegment? {
            guard var original = unified[id] ?? pending[id] ?? raw[id] else { return nil }
            if original.provenance.isEmpty, let source = raw[id] {
                original.provenance = [provenance(source)]
            }
            return original
        }
        // A passage the person gave another speaker goes over as a corrected one does, to the same passage only: a speaker
        // the conversation still has, the passage's words as they read (`Meeting.passageSpeakers`). In passage order, so
        // every device decides alike.
        let known = Set(meeting.speakers.map(\.id))
        let pins = meeting.passageSpeakers.filter { known.contains($0.value) }
        var originals: [(segment: TranscriptSegment, corrects: Bool, speakerID: String?)] = []
        for (id, edit) in edits {
            guard seen.insert(id).inserted, !transferred.contains(id), var segment = original(id) else { continue }
            // The revision is authoritative even after a prior fusion no longer displays this passage.
            segment.text = edit.newValue
            if let pin = pins[id] { segment.speakerID = pin }
            originals.append((segment, true, pins[id]))
        }
        for (id, speakerID) in pins.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard seen.insert(id).inserted, !transferred.contains(id), var segment = original(id) else { continue }
            segment.speakerID = speakerID
            originals.append((segment, false, speakerID))
        }

        // Passages by their own identity and by every source passage they cite.
        var byIdentity: [UUID: [Int]] = [:]
        for (index, candidate) in segments.enumerated() {
            for identity in Set([candidate.id] + candidate.provenance.map(\.segmentID)) { byIdentity[identity, default: []].append(index) }
        }
        func propose(_ original: TranscriptSegment) -> Proposal {
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
        let proposals = originals.map { item -> Proposal in
            var proposal = propose(item.segment)
            proposal.corrects = item.corrects
            proposal.speakerID = item.speakerID
            return proposal
        }

        var output = segments
        var issues: [CorrectionTransferIssue] = []
        let unique = proposals.filter { $0.candidates.count == 1 }
        var applied = Set<Int>()
        for proposal in proposals {
            func review(_ candidates: [Int], _ reason: String) {
                issues.append(CorrectionTransferIssue(originalSegment: proposal.original, candidateSegmentIDs: candidates.map { segments[$0].id },
                                                      reason: reason, speakerID: proposal.speakerID))
            }
            guard let target = proposal.candidates.first, proposal.candidates.count == 1 else {
                review(proposal.candidates.isEmpty ? proposal.reviewCandidates : proposal.candidates, proposal.candidates.isEmpty
                    ? "The new transcript changed this passage’s source timing or wording, or its source is unaligned. Review the saved correction before applying it."
                    : "More than one new passage matches this correction. Choose the intended passage after reviewing the source audio.")
                continue
            }
            let contenders = unique.filter { $0.candidates[0] == target }
            if proposal.corrects, Set(contenders.filter(\.corrects).map(\.original.text)).count > 1 {
                review([target], "Different saved corrections match the same new passage. Review which wording to keep.")
                continue
            }
            if proposal.speakerID != nil, Set(contenders.compactMap(\.speakerID)).count > 1 {
                review([target], "Passages given to different speakers match the same new passage. Review who said it.")
                continue
            }
            // The passage keeps its identity, so what the person did to it is found again next time (and in Version History).
            if applied.insert(target).inserted { output[target].id = proposal.original.id }
            if proposal.corrects { output[target].text = proposal.original.text }
            if let speakerID = proposal.speakerID { output[target].speakerID = speakerID }
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
