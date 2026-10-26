import DaybookCore
import Foundation

/// One conversation that matches a library search, and where it matched.
public struct SearchHit: Identifiable, Equatable, Sendable {
    public enum Field: Equatable, Sendable { case title, summary, notes, transcript }
    public let meetingID: UUID
    public var id: UUID { meetingID }
    public let field: Field
    /// The matched text with some context, and the matched range within it.
    public let snippet: String
    public let match: Range<String.Index>?
    public let segmentID: UUID?
    public let speaker: String?
    public let time: TimeInterval?
    public let matchCount: Int
}

public enum LibrarySearch {
    public static func hits(in meetings: [Meeting], text: String, tokens: [SearchToken], scope: SearchScope) -> [SearchHit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = meetings.filter { meeting in
            switch scope {
            case .all: return true
            case .work: return LibrarySection.work.contains(meeting)
            case .personal: return LibrarySection.personal.contains(meeting)
            case .folder(let id): return meeting.folderID == id
            }
        }
        .filter { meeting in
            tokens.allSatisfy { token in
                switch token {
                case .tag(let tag): return (meeting.tags ?? []).contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
                case .speaker(let name): return meeting.speakers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                }
            }
        }
        let results = scoped.compactMap { meeting -> (SearchHit, Int)? in
            guard !query.isEmpty else {
                let preview = meeting.summary?.overview ?? meeting.notes
                return (SearchHit(meetingID: meeting.id, field: .title, snippet: String(preview.prefix(160)), match: nil,
                                  segmentID: nil, speaker: nil, time: nil, matchCount: 0), 0)
            }
            return hit(in: meeting, query: query)
        }
        // Best field first, then the newest conversation.
        let dates = Dictionary(scoped.map { ($0.id, $0.date) }, uniquingKeysWith: { first, _ in first })
        return results.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? (dates[lhs.0.meetingID] ?? .distantPast) > (dates[rhs.0.meetingID] ?? .distantPast) : lhs.1 < rhs.1
        }.map(\.0)
    }

    private static func hit(in meeting: Meeting, query: String) -> (SearchHit, Int)? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let range = meeting.title.range(of: query, options: options) {
            return (SearchHit(meetingID: meeting.id, field: .title, snippet: meeting.title, match: range, segmentID: nil, speaker: nil, time: nil, matchCount: 1), 0)
        }
        if let summary = meeting.summary {
            let texts = [summary.overview] + summary.sections.map(\.body) + summary.actionItems.map(\.text)
            for text in texts {
                if let range = text.range(of: query, options: options) {
                    let (snippet, match) = excerpt(text, around: range)
                    return (SearchHit(meetingID: meeting.id, field: .summary, snippet: snippet, match: match, segmentID: nil, speaker: nil, time: nil, matchCount: 1), 1)
                }
            }
        }
        if let range = meeting.notes.range(of: query, options: options) {
            let (snippet, match) = excerpt(meeting.notes, around: range)
            return (SearchHit(meetingID: meeting.id, field: .notes, snippet: snippet, match: match, segmentID: nil, speaker: nil, time: nil, matchCount: 1), 2)
        }
        let matches = meeting.unifiedTranscript.filter { $0.text.range(of: query, options: options) != nil }
        if let first = matches.first, let range = first.text.range(of: query, options: options) {
            let (snippet, match) = excerpt(first.text, around: range)
            return (SearchHit(meetingID: meeting.id, field: .transcript, snippet: snippet, match: match, segmentID: first.id,
                              speaker: meeting.speakerName(first.speakerID), time: first.start, matchCount: matches.count), 3)
        }
        return nil
    }

    /// About 40 characters before and 100 after the match, cut at word boundaries, with ellipses.
    public static func excerpt(_ text: String, around range: Range<String.Index>) -> (String, Range<String.Index>?) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.index(range.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(range.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
        var start = lower, end = upper
        if start != flat.startIndex, let space = flat[start..<range.lowerBound].firstIndex(of: " ") { start = flat.index(after: space) }
        if end != flat.endIndex, let space = flat[range.upperBound..<end].lastIndex(of: " ") { end = space }
        let prefix = start == flat.startIndex ? "" : "…", suffix = end == flat.endIndex ? "" : "…"
        let snippet = prefix + flat[start..<end] + suffix
        let matched = String(flat[range])
        let matchRange = snippet.range(of: matched, options: [.caseInsensitive, .diacriticInsensitive])
        return (snippet, matchRange)
    }
}

/// Library search results, kept until the query or the library changes, so drawing the list (which
/// asks for them more than once) doesn't search every transcript each time. A small library is
/// searched at once; a large one off the main actor, keeping the previous results on screen until
/// the new ones are ready (`onUpdate`).
@MainActor
public final class LibrarySearchMemo {
    public struct Key: Equatable, Sendable {
        public var text: String
        public var tokens: [SearchToken]
        public var scope: SearchScope
        /// Changes whenever the library's conversations do.
        public var revision: Int
        public init(text: String, tokens: [SearchToken], scope: SearchScope, revision: Int) {
            self.text = text; self.tokens = tokens; self.scope = scope; self.revision = revision
        }
    }

    /// Transcript passages above which a search runs off the main actor.
    public var backgroundThreshold = 20_000
    /// The results changed after a search off the main actor.
    public var onUpdate: () -> Void = {}
    /// Searches run (tests).
    public private(set) var searches = 0
    private var key: Key?
    private var hits: [SearchHit] = []
    private var pending: Task<Void, Never>?

    public init() {}

    public func hits(for key: Key, in meetings: [Meeting]) -> [SearchHit] {
        guard key != self.key else { return hits }
        self.key = key
        pending?.cancel(); pending = nil
        searches += 1
        let passages = meetings.reduce(0) { $0 + $1.unifiedTranscript.count }
        guard passages >= backgroundThreshold else {
            hits = LibrarySearch.hits(in: meetings, text: key.text, tokens: key.tokens, scope: key.scope)
            return hits
        }
        pending = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                LibrarySearch.hits(in: meetings, text: key.text, tokens: key.tokens, scope: key.scope)
            }.value
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.hits = found
            self.pending = nil
            self.onUpdate()
        }
        return hits
    }

    /// Waits for a search running off the main actor (tests).
    public func settle() async { await pending?.value }
}
