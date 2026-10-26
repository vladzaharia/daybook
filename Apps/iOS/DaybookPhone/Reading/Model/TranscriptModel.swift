import DaybookKit
import Foundation

/// The two sides of a conversation page.
enum PageMode: String, CaseIterable, Identifiable, Hashable {
    case summary, transcript
    var id: String { rawValue }
    var title: String { self == .summary ? "Summary" : "Transcript" }
}

/// The transcript as it reads: consecutive passages from one speaker form a turn, and timed notes
/// sit at their times. The same grouping as the Mac's transcript page.
enum TranscriptBlock: Identifiable, Equatable {
    case turn(id: String, speakerID: String?, segments: [TranscriptSegment])
    case note(TimedNote)
    case photo(MeetingPhoto, Double)

    var id: String {
        switch self {
        case .turn(let id, _, _): return "turn:" + id
        case .note(let note): return "note:\(note.id)"
        case .photo(let photo, _): return "photo:\(photo.id)"
        }
    }

    static func blocks(in meeting: Meeting) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for item in MeetingTimelineItem.items(in: meeting) {
            switch item {
            case .speech(let segment):
                if case .turn(let id, let speaker, var segments)? = blocks.last, speaker == segment.speakerID {
                    segments.append(segment)
                    blocks[blocks.count - 1] = .turn(id: id, speakerID: speaker, segments: segments)
                } else {
                    blocks.append(.turn(id: segment.id.uuidString, speakerID: segment.speakerID, segments: [segment]))
                }
            case .note(let note): blocks.append(.note(note))
            case .photo(let photo, let time): blocks.append(.photo(photo, time))
            case .highlight: break
            }
        }
        return blocks
    }
}

/// Where bookmarks fall in the transcript: the passage that holds each one, and the label shown
/// above it. Only the holder is marked, so a short conversation isn't washed amber from end to end.
struct BookmarkMarks: Equatable {
    var bookmarksBySegment: [UUID: [Highlight]] = [:]
    var labelSegments: [UUID: String] = [:]
    var holders: Set<UUID> { Set(bookmarksBySegment.keys) }

    init(meeting: Meeting) {
        for highlight in meeting.highlights {
            guard let holder = Self.holder(of: highlight, in: meeting) else { continue }
            bookmarksBySegment[holder, default: []].append(highlight)
            let label = highlight.text.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !Self.automaticLabels.contains(label), labelSegments[holder] == nil { labelSegments[holder] = label }
        }
    }

    /// Labels an earlier version wrote automatically; they read as no label.
    static let automaticLabels: Set<String> = ["Marked moment", "Marked during review"]

    /// The passage under a bookmark: the last one starting at or before it on the timeline.
    static func holder(of highlight: Highlight, in meeting: Meeting) -> UUID? {
        guard let time = meeting.alignedTime(for: highlight) else { return nil }
        let segments = meeting.unifiedTranscript
        return (segments.last { $0.start <= time + 0.01 } ?? segments.first)?.id
    }
}

/// Something to play: a passage (from its original recording), a time on the conversation's
/// timeline, or a time within one recording.
enum PlaybackTarget: Equatable {
    case segment(TranscriptSegment)
    case timeline(Double)
    case source(RecordingTrack, Double)

    /// The recording and the time within it, as the Mac resolves them.
    func resolve(in meeting: Meeting) -> (track: RecordingTrack, seconds: Double)? {
        switch self {
        case .segment(let segment):
            guard let track = meeting.tracks.first(where: { $0.id == segment.trackID }) else { return nil }
            let original = segment.provenance.first { $0.trackID == track.id }?.start ?? max(0, segment.start - (track.offset ?? 0))
            return (track, original)
        case .timeline(let seconds):
            if let position = MeetingPlaybackPosition.resolve(seconds, in: meeting),
               let track = meeting.tracks.first(where: { $0.id == position.trackID }) {
                return (track, position.seconds)
            }
            guard let track = meeting.tracks.first(where: { meeting.transcribableTracks.contains($0) }) ?? meeting.tracks.first else { return nil }
            return (track, max(0, seconds - (track.offset ?? 0)))
        case .source(let track, let seconds):
            return (track, max(0, seconds))
        }
    }
}

enum TranscriptFollow {
    /// The passage under the playhead, matched in the recording that is playing.
    static func segmentID(at position: TimeInterval, trackID: UUID, in meeting: Meeting) -> UUID? {
        let offset = meeting.tracks.first { $0.id == trackID }?.offset ?? 0
        return meeting.unifiedTranscript.first { segment in
            if let source = segment.provenance.first(where: { $0.trackID == trackID }) {
                return (source.start...max(source.start, source.end)).contains(position)
            }
            guard segment.trackID == trackID else { return false }
            return (segment.start...max(segment.start, segment.end)).contains(position + offset)
        }?.id
    }
}

/// Finds the passage a summary line came from, so tapping a next step, a summary bullet, or a
/// bookmark opens the transcript at its evidence. Summaries don't store their sources, so this
/// matches words: rare words count more, the owner's own passages win ties, and a weak match
/// (one common word) finds nothing rather than something wrong. Build it once per page.
struct EvidenceIndex {
    private let segments: [TranscriptSegment]
    private let speakerNames: [String?]
    private let documents: [Set<String>]
    private let frequency: [String: Int]

    /// The index for a conversation, built once per version of its transcript and speaker names.
    @MainActor
    static func cached(for meeting: Meeting) -> EvidenceIndex {
        let key = CacheKey(meeting)
        if let hit = cache[key] { return hit }
        if cache.count > 8 { cache.removeAll() }
        let index = EvidenceIndex(meeting)
        cache[key] = index
        return index
    }

    private struct CacheKey: Hashable {
        var id: UUID, count: Int, first: UUID?, last: UUID?, revisions: Int, names: [String]
        init(_ meeting: Meeting) {
            id = meeting.id; count = meeting.unifiedTranscript.count
            first = meeting.unifiedTranscript.first?.id; last = meeting.unifiedTranscript.last?.id
            revisions = meeting.revisions.count; names = meeting.speakers.map(\.name)
        }
    }

    @MainActor private static var cache: [CacheKey: EvidenceIndex] = [:]

    init(_ meeting: Meeting) {
        segments = meeting.unifiedTranscript
        speakerNames = segments.map { meeting.speakerName($0.speakerID) }
        documents = segments.map { Set(EvidenceIndex.words($0.text)) }
        var frequency: [String: Int] = [:]
        for document in documents { for word in document { frequency[word, default: 0] += 1 } }
        self.frequency = frequency
    }

    func segment(for text: String, owner: String? = nil) -> UUID? {
        guard !segments.isEmpty else { return nil }
        let query = Set(Self.words(text))
        guard !query.isEmpty else { return nil }
        let count = Double(segments.count)
        func weight(_ word: String) -> Double { log((count + 1) / Double((frequency[word] ?? 0) + 1)) + 1 }

        var best: (index: Int, score: Double, shared: Set<String>)?
        for (index, document) in documents.enumerated() {
            let shared = query.intersection(document)
            guard !shared.isEmpty else { continue }
            var score = shared.reduce(0) { $0 + weight($1) }
            if let owner, !owner.isEmpty, speakerNames[index]?.caseInsensitiveCompare(owner) == .orderedSame { score += 0.5 }
            if best == nil || score > best!.score + 1e-9 { best = (index, score, shared) }
        }
        guard let best else { return nil }
        // One shared word is evidence only when it's rare and the line is short.
        if best.shared.count < 2 {
            guard query.count <= 3, let word = best.shared.first, (frequency[word] ?? 0) == 1 else { return nil }
        }
        return segments[best.index].id
    }

    /// Content words, lowercased and lightly stemmed, without Markdown or common words.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { word -> String in
                var value = String(word)
                if value.hasSuffix("'s") { value.removeLast(2) }
                return stem(value.replacingOccurrences(of: "'", with: ""))
            }
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    /// Just enough stemming that "notes" meets "note" and "drafted" meets "draft".
    static func stem(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count > 4, word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, ["sses", "xes", "ches", "shes", "zes"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }

    static let stopWords = Set<String>([
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "day", "get", "has", "him", "his", "how", "new", "now", "old", "see", "two", "way", "who", "did", "its",
        "let", "say", "she", "too", "use", "that", "with", "have", "this", "will", "your", "from", "they", "know", "want",
        "been", "good", "much", "some", "time", "very", "when", "come", "here", "just", "like", "long", "make", "many",
        "more", "only", "over", "such", "take", "than", "them", "well", "were", "what", "about", "would", "there", "their",
        "which", "could", "other", "into", "then", "also", "should", "ill", "well", "okay", "yes", "really", "dont",
        "thing", "think", "going", "need", "able", "after", "before", "because", "where", "whether", "being", "does", "doe",
        "thi", "wa", "ha", "it", "im", "ive", "youre", "were", "lets", "let", "sure", "right",
    ])
}

/// One line of a summary section, for tapping through to its evidence.
enum SummaryLine: Equatable {
    case paragraph(String)
    case heading(String)
    case item(marker: String, text: String)

    var text: String {
        switch self {
        case .paragraph(let text), .heading(let text), .item(_, let text): return text
        }
    }

    /// Paragraphs, list items ("-", "*", "•", "1."), and headings, as the Mac's Markdown reader splits them.
    static func lines(_ source: String) -> [SummaryLine] {
        var lines: [SummaryLine] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { lines.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flush(); lines.append(.item(marker: "•", text: String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); lines.append(.item(marker: line[..<range.upperBound].trimmingCharacters(in: .whitespaces), text: String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); lines.append(.heading(String(line[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flush()
        return lines
    }

    /// Inline Markdown (bold, italics, code), keeping whitespace.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
