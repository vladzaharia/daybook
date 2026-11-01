import DaybookCore
import Foundation

/// Finds the passage a summary line came from, so tapping or clicking a next step, a summary bullet, or a bookmark
/// opens the transcript at its evidence, on both apps. Summaries don't store their sources, so this matches words:
/// rare words count more, the owner's own passages win ties, and a weak match (one common word) finds nothing rather
/// than something wrong. Lines are split as the page draws them (`SummaryMarkdown`).
public struct SummaryEvidenceIndex: Sendable {
    private let segments: [TranscriptSegment]
    private let speakerNames: [String?]
    private let documents: [Set<String>]
    private let frequency: [String: Int]

    /// The index for a conversation, built once per version of what it reads: its passages and speakers' names, and
    /// when it last changed. A sync merge can bring in another device's older edit without moving `updatedAt`
    /// (`MeetingMerge` keeps the later of the two), so the content counts too.
    public static func cached(for meeting: Meeting) -> SummaryEvidenceIndex {
        cache.index(for: meeting)
    }

    public init(_ meeting: Meeting) {
        segments = meeting.unifiedTranscript
        speakerNames = segments.map { meeting.speakerName($0.speakerID) }
        documents = segments.map { Set(Self.words($0.text)) }
        var frequency: [String: Int] = [:]
        for document in documents { for word in document { frequency[word, default: 0] += 1 } }
        self.frequency = frequency
    }

    /// The passage `text` most likely came from, or nil when nothing matches well enough. `owner` (a next step's)
    /// breaks ties toward what that person said.
    public func segment(for text: String, owner: String? = nil) -> UUID? {
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
    public static func words(_ text: String) -> [String] {
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
    public static func stem(_ word: String) -> String {
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

    private static let cache = IndexCache()

    /// The last few conversations' indexes, safe from any thread.
    private final class IndexCache: @unchecked Sendable {
        private struct Key: Hashable {
            var id: UUID
            var updatedAt: Date
            var passages: Int
            /// Each passage's ID, words, and speaker, and each speaker's name.
            var content: Int

            init(_ meeting: Meeting) {
                id = meeting.id; updatedAt = meeting.updatedAt; passages = meeting.unifiedTranscript.count
                var hasher = Hasher()
                for segment in meeting.unifiedTranscript {
                    hasher.combine(segment.id); hasher.combine(segment.text); hasher.combine(segment.speakerID)
                }
                for speaker in meeting.speakers { hasher.combine(speaker.id); hasher.combine(speaker.name) }
                content = hasher.finalize()
            }
        }
        private let lock = NSLock()
        private var entries: [Key: SummaryEvidenceIndex] = [:]

        func index(for meeting: Meeting) -> SummaryEvidenceIndex {
            let key = Key(meeting)
            if let hit = lock.withLock({ entries[key] }) { return hit }
            let index = SummaryEvidenceIndex(meeting)
            lock.withLock {
                // One version per conversation, and only a few conversations.
                entries = entries.filter { $0.key.id != meeting.id }
                if entries.count >= 8 { entries.removeAll() }
                entries[key] = index
            }
            return index
        }
    }
}
