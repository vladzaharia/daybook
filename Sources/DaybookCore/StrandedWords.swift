import Foundation

/// Speaker analysis leaves short gaps between turns (at a change of speaker, around a breath), and a
/// word that falls in one comes out with no speaker: "Unknown speaker: I" splitting one person's
/// sentence in two. Such a word belongs to the turn it sits against.
public enum StrandedWords {
    /// The most words a passage can have and still be a stranded word rather than speech.
    public static let maximumWords = 3
    /// How far a stranded word can be from the labelled passage it joins, in seconds.
    public static let maximumGap: TimeInterval = 1
}

extension Array where Element == TranscriptSegment {
    /// Short unlabelled passages take the speaker of the labelled passage of the same recording they
    /// sit against: the one on both sides when it's the same speaker, else the nearer one within
    /// `StrandedWords.maximumGap`. Longer unlabelled passages, and ones with nothing labelled close
    /// by, stay unlabelled. Order and everything else are unchanged.
    public func labellingStrandedWords() -> [TranscriptSegment] {
        guard contains(where: { $0.speakerID == nil }), contains(where: { $0.speakerID != nil }) else { return self }
        var result = self
        for trackID in Set(map(\.trackID)) {
            let indices = self.indices.filter { self[$0].trackID == trackID }.sorted {
                self[$0].start == self[$1].start ? $0 < $1 : self[$0].start < self[$1].start
            }
            for (position, index) in indices.enumerated() {
                let segment = self[index]
                guard segment.speakerID == nil, segment.text.split(whereSeparator: \.isWhitespace).count <= StrandedWords.maximumWords else { continue }
                let before = indices[..<position].last { self[$0].speakerID != nil }.map { self[$0] }
                let after = indices[(position + 1)...].first { self[$0].speakerID != nil }.map { self[$0] }
                let gapBefore = before.map { Swift.max(0, segment.start - $0.end) }
                let gapAfter = after.map { Swift.max(0, $0.start - segment.end) }
                let near = { (gap: TimeInterval?) in gap.map { $0 <= StrandedWords.maximumGap } ?? false }
                if near(gapBefore), near(gapAfter), before?.speakerID == after?.speakerID {
                    result[index].speakerID = before?.speakerID
                } else if near(gapBefore), !near(gapAfter) || gapBefore! <= gapAfter! {
                    result[index].speakerID = before?.speakerID
                } else if near(gapAfter) {
                    result[index].speakerID = after?.speakerID
                }
            }
        }
        return result
    }

    /// Whether `labellingStrandedWords()` would label anything.
    public var hasStrandedWords: Bool { labellingStrandedWords() != self }
}
