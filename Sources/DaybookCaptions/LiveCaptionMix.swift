import Foundation

/// When two sources' lines are the same speech: the word rules the mixer puts lines together by
/// (`LiveCaptionMixer`). Several devices in one room hear the same speech, and through a Mac's speakers its
/// microphone hears the call too; each recognizer cuts and spells it a little differently.
public enum LiveCaptionMix {
    /// How far apart two devices' captions of the same words may be: their clocks are matched only
    /// roughly, and each recognizer cuts its lines in its own places.
    public static let window: TimeInterval = 4
    /// The same, for two of one device's own sources (a Mac's You and Call), which share its clock.
    public static let ownWindow: TimeInterval = 2
    /// The share of the shorter line's words, in order, the longer must have for the two to be one utterance.
    public static let threshold = 0.6
    /// A line that runs past the words already shown by more than this (seconds) brings new words; less is
    /// the same words heard a moment later, or spelled differently.
    public static let runsOn: TimeInterval = 1

    /// Lowercased words without punctuation, accents, or apostrophes ("Let’s" and "lets" match).
    public static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The longest run of `a`'s words that appears in `b` in the same order (gaps allowed).
    public static func sharedRun(_ a: [String], _ b: [String]) -> Int { align(a, b).count }

    /// The words two lines share, in order (gaps allowed), as pairs of positions in each: one longest such run.
    public static func align(_ a: [String], _ b: [String]) -> [(a: Int, b: Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let columns = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * columns)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * columns + j] = a[i] == b[j] ? table[(i + 1) * columns + j + 1] + 1
                    : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
            }
        }
        var pairs: [(a: Int, b: Int)] = []
        pairs.reserveCapacity(Int(table[0]))
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }

    /// Whether two lines' words are one utterance: most of the shorter line's words are in the longer, in
    /// order; or one's ending is the other's beginning (recognizers cut lines in different places), at least
    /// three words long and mostly matching where they meet.
    public static func matches(_ a: [String], _ b: [String]) -> Bool {
        let pairs = align(a, b)
        guard let first = pairs.first, let last = pairs.last else { return false }
        if Double(pairs.count) >= threshold * Double(min(a.count, b.count)) { return true }
        guard pairs.count >= 3 else { return false }
        let dense = Double(pairs.count) >= threshold * Double(last.a - first.a + 1)
            && Double(pairs.count) >= threshold * Double(last.b - first.b + 1)
        let aThenB = last.a >= a.count - 2 && first.b <= 1
        let bThenA = last.b >= b.count - 2 && first.a <= 1
        return dense && (aThenB || bThenA)
    }

    /// One line's words with where each sits in its text, so the new words of a line can be shown as it
    /// wrote them.
    struct Words: Equatable, Sendable {
        let text: String
        let words: [String]
        /// The text split on spaces, and the piece each word is in.
        let pieces: [Substring]
        let pieceOfWord: [Int]

        init(_ text: String) {
            self.text = text
            let pieces = text.split(whereSeparator: \.isWhitespace)
            var words: [String] = [], pieceOfWord: [Int] = []
            for (index, piece) in pieces.enumerated() {
                for word in LiveCaptionMix.words(String(piece)) {
                    words.append(word)
                    pieceOfWord.append(index)
                }
            }
            self.pieces = pieces
            self.words = words
            self.pieceOfWord = pieceOfWord
        }

        /// The text of words `range`, as written.
        func text(_ range: Range<Int>) -> String {
            guard !range.isEmpty else { return "" }
            return pieces[pieceOfWord[range.lowerBound]...pieceOfWord[range.upperBound - 1]].joined(separator: " ")
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }
}
