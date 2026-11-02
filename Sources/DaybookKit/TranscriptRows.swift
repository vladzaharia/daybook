import DaybookCore
import Foundation

// The transcript as both apps' pages lay it out, row by row (`TranscriptLayout` groups it into turns once per
// version of a conversation): what each row is, what it's called as a scroll target, which passages the person
// corrected, and what Find in Conversation steps through.

/// The transcript flattened into rows, so each passage, note, and photo is its own scroll target and lazy row: a
/// turn's header (its speaker and first time), then each of its passages.
public enum TranscriptRow: Identifiable, Equatable, Sendable {
    case turn(speakerID: String?, first: TranscriptSegment)
    case passage(TranscriptSegment)
    case note(TimedNote)
    case photo(MeetingPhoto, Double)

    /// A passage and a photo are named by their own IDs, so a search hit, a summary line's evidence, or a photo's
    /// Show in Transcript scrolls to it by the ID it already has.
    public var id: String {
        switch self {
        case .turn(_, let first): return "turn:\(first.id.uuidString)"
        case .passage(let segment): return segment.id.uuidString
        case .note(let note): return "note:\(note.id.uuidString)"
        case .photo(let photo, _): return photo.id.uuidString
        }
    }

    /// The words Find in Conversation looks in: a passage's, a note's, a photo's caption.
    public var findableText: String? {
        switch self {
        case .turn: return nil
        case .passage(let segment): return segment.text
        case .note(let note): return note.text
        case .photo(let photo, _): return photo.displayCaption
        }
    }

    public static func rows(in meeting: Meeting) -> [TranscriptRow] { rows(from: TranscriptBlock.blocks(in: meeting)) }

    public static func rows(from blocks: [TranscriptBlock]) -> [TranscriptRow] {
        blocks.flatMap { block -> [TranscriptRow] in
            switch block {
            case .turn(_, let speakerID, let segments):
                guard let first = segments.first else { return [] }
                return [.turn(speakerID: speakerID, first: first)] + segments.map(TranscriptRow.passage)
            case .note(let note):
                return [.note(note)]
            case .photo(let photo, let time):
                return [.photo(photo, time)]
            }
        }
    }
}

/// Passages the person corrected, read from Version History once per redraw of the page, so a row asks a set.
public enum TranscriptCorrections {
    public static func segmentIDs(in meeting: Meeting) -> Set<UUID> {
        var ids = Set<UUID>()
        for revision in meeting.revisions where revision.field.hasPrefix("segment:") {
            if let id = UUID(uuidString: String(revision.field.dropFirst("segment:".count))) { ids.insert(id) }
        }
        return ids
    }
}

/// Find in Conversation: the rows whose words hold what's typed, in the order they read, and where the person is
/// among them. Matching is the page's own (`FindHighlight`): case and diacritics ignored.
public struct TranscriptFindMatches: Equatable, Sendable {
    /// The matching rows' IDs, top to bottom.
    public private(set) var ids: [String]
    /// The one shown now, when there are any.
    public private(set) var current: Int?

    public init(ids: [String] = [], current: Int? = nil) {
        self.ids = ids
        self.current = ids.isEmpty ? nil : current.map { min(max(0, $0), ids.count - 1) }
    }

    /// The rows of `rows` that hold `query`.
    public init(query: String, in rows: [TranscriptRow]) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { self.init(); return }
        let ids = rows.compactMap { row -> String? in
            guard let text = row.findableText, Self.contains(text, query) else { return nil }
            return row.id
        }
        self.init(ids: ids, current: ids.isEmpty ? nil : 0)
    }

    public static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public var count: Int { ids.count }
    public var currentID: String? { current.map { ids[$0] } }

    /// "3 of 12", or "No matches"; nothing before anything is typed.
    public func label(query: String) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let current else { return "No matches" }
        return "\(current + 1) of \(ids.count)"
    }

    /// Steps to the next match, or the one before, going round at either end.
    public mutating func step(_ delta: Int) {
        guard !ids.isEmpty else { return }
        let from = current ?? (delta > 0 ? -1 : 0)
        current = ((from + delta) % ids.count + ids.count) % ids.count
    }

    /// The same query over a changed transcript: stays on the row it was on when that still matches, else the
    /// first match after where it was.
    public func refreshed(query: String, in rows: [TranscriptRow]) -> TranscriptFindMatches {
        var next = TranscriptFindMatches(query: query, in: rows)
        guard let currentID, !next.ids.isEmpty else { return next }
        if let same = next.ids.firstIndex(of: currentID) {
            next.current = same
        } else if let old = rows.firstIndex(where: { $0.id == currentID }) {
            let positions = Dictionary(rows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            next.current = next.ids.firstIndex { (positions[$0] ?? 0) > old } ?? 0
        }
        return next
    }
}
