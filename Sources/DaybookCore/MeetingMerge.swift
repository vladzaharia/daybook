import Foundation

public struct MeetingMergeResult: Sendable {
    public var meeting: Meeting
    public var warnings: [String]
}

/// A deterministic three-way merge. Independent changes survive; competing values remain in history.
public enum MeetingMerge {
    public static func merge(base: Meeting?, local: Meeting, remote: Meeting) -> MeetingMergeResult {
        precondition(local.id == remote.id && (base == nil || base?.id == local.id), "Only versions of the same meeting can be merged")
        var result = local
        var conflicts: [MeetingRevision] = []
        var warnings: [String] = []
        func choose<T: Encodable & Equatable>(_ field: String, _ lhs: T, _ rhs: T, _ ancestor: T?) -> T {
            if lhs == rhs { return lhs }
            if let ancestor {
                if lhs == ancestor { return rhs }
                if rhs == ancestor { return lhs }
            }
            let a = SyncEncoding.string(lhs), b = SyncEncoding.string(rhs)
            let smaller = min(a, b), larger = max(a, b)
            let id = SyncEncoding.uuid("\(local.id):\(field):\(smaller):\(larger)")
            conflicts.append(MeetingRevision(id: id, date: max(local.updatedAt, remote.updatedAt), field: "sync:\(field)", oldValue: smaller, newValue: larger))
            warnings.append("Concurrent edits to \(field) in \(local.title) were preserved in History.")
            return a > b ? lhs : rhs
        }
        func items<T: Codable & Equatable & Identifiable>(_ field: String, _ lhs: [T], _ rhs: [T], _ ancestor: [T]) -> [T] {
            var order: [T.ID] = []
            for item in ancestor where !order.contains(item.id) { order.append(item.id) }
            let added = Set((lhs + rhs).map(\.id)).subtracting(order).sorted { String(describing: $0) < String(describing: $1) }
            order += added
            return order.compactMap { id in
                let a = lhs.first { $0.id == id }, b = rhs.first { $0.id == id }, old = ancestor.first { $0.id == id }
                if let a, let b { return choose("\(field):\(id)", a, b, old) }
                return a ?? b ?? old
            }
        }
        result.title = choose("title", local.title, remote.title, base?.title)
        result.date = choose("date", local.date, remote.date, base?.date)
        result.kind = choose("kind", local.kind, remote.kind, base?.kind)
        let notes = choose("notes", MergedNotes(local), MergedNotes(remote), base.map(MergedNotes.init))
        result.notes = notes.text; result.timedNotes = notes.anchors
        result.folderID = choose("folder", local.folderID, remote.folderID, base.map(\.folderID))
        result.templateID = choose("template", local.templateID, remote.templateID, base.map(\.templateID))
        if local.tags != nil || remote.tags != nil {
            let old = Set(base?.tags ?? []), a = Set(local.tags ?? []), b = Set(remote.tags ?? [])
            let removed = old.subtracting(a).union(old.subtracting(b))
            result.tags = old.subtracting(removed).union(a.subtracting(old)).union(b.subtracting(old)).sorted()
        }
        result.tracks = items("track", local.tracks, remote.tracks, base?.tracks ?? [])
        result.transcripts = items("transcript-run", local.transcripts, remote.transcripts, base?.transcripts ?? [])
        result.speakers = items("speaker", local.speakers, remote.speakers, base?.speakers ?? [])
        result.highlights = items("highlight", local.highlights, remote.highlights, base?.highlights ?? [])
        result.speakerMatches = items("speaker-match", local.speakerMatches ?? [], remote.speakerMatches ?? [], base?.speakerMatches ?? [])
        if result.speakerMatches?.isEmpty == true { result.speakerMatches = nil }
        // These are one derived view. Mixing a transcript with another run's clock transform
        // would change playback/highlight timing, and its review candidates would be invalid.
        let view = choose("transcript-view", MergedTranscriptView(local), MergedTranscriptView(remote), base.map(MergedTranscriptView.init))
        result.unifiedTranscript = view.segments
        result.alignmentReports = view.alignments
        result.correctionTransferIssues = view.correctionIssues
        result.summary = choose("summary", local.summary, remote.summary, base.map(\.summary))
        // Completion is a separate user decision from generated prose; exact task+owner identity survives.
        if var summary = result.summary {
            for index in summary.actionItems.indices {
                let item = summary.actionItems[index]
                let a = local.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                let b = remote.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                let old = base?.summary?.actionItems.first { $0.text == item.text && $0.owner == item.owner }
                if let a, let b { summary.actionItems[index].completed = choose("action:\(item.text)", a.completed, b.completed, old?.completed) }
            }
            result.summary = summary
        }
        result.status = choose("status", local.status, remote.status, base?.status)
        result.errorMessage = choose("processing-message", local.errorMessage, remote.errorMessage, base.map(\.errorMessage))
        var revisions: [UUID: MeetingRevision] = [:]
        for revision in (base?.revisions ?? []) + local.revisions + remote.revisions + conflicts {
            if let old = revisions[revision.id], SyncEncoding.string(old) > SyncEncoding.string(revision) { continue }
            revisions[revision.id] = revision
        }
        result.revisions = revisions.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        result.updatedAt = max(local.updatedAt, remote.updatedAt)
        return MeetingMergeResult(meeting: result, warnings: Array(Set(warnings)).sorted())
    }
}

private struct MergedTranscriptView: Codable, Equatable {
    var segments: [TranscriptSegment]
    var alignments: [TrackAlignment]
    var correctionIssues: [CorrectionTransferIssue]?
    init(_ meeting: Meeting) {
        segments = meeting.unifiedTranscript; alignments = meeting.alignmentReports
        correctionIssues = meeting.correctionTransferIssues
    }
}
private struct MergedNotes: Codable, Equatable {
    var text: String
    var anchors: [TimedNote]?
    init(_ meeting: Meeting) { text = meeting.notes; anchors = meeting.timedNotes }
}

enum SyncEncoding {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func string<T: Encodable>(_ value: T) -> String {
        (try? data(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable value>"
    }
    static func uuid(_ seed: String) -> UUID {
        let hex = String(AudioDigest.sha256(data: Data(seed.utf8)).prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return UUID(uuidString: parts.joined(separator: "-"))!
    }
}
