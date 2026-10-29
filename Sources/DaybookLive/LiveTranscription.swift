import DaybookCaptions
import Foundation

/// One sub-word piece a streaming recognizer emitted, with its time in the audio it was fed.
/// SentencePiece marks a word's start with "▁" (or a leading space).
public struct LiveToken: Equatable, Sendable {
    public var text: String
    /// Seconds from the first sample fed to the recognizer.
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double = 1) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// A streaming recognizer for one capture. Its tokens are final once emitted: cache-aware streaming
/// models never revise earlier output, so captions are tentative only until their sentence closes.
/// Called from one task at a time.
public protocol LiveTranscribing: AnyObject, Sendable {
    /// Feeds 16 kHz mono samples and returns the tokens decoded since the last call, in order.
    func transcribe(_ samples: [Float]) async throws -> [LiveToken]
    /// The audio ended: decodes what's left and returns the last tokens.
    func finish() async throws -> [LiveToken]
    /// Biases decoding toward these terms from the next audio on; empty turns it off.
    func setVocabulary(_ terms: [String]) async
}

extension LiveTranscribing {
    /// Recognizers that can't be biased ignore vocabulary.
    public func setVocabulary(_ terms: [String]) async {}
}

/// Turns a recognizer's tokens into caption segments: words from SentencePiece pieces, passages that
/// close at the end of a sentence, a pause, or a length limit. The open passage is tentative and
/// keeps its ID as it grows; a closed one is final. Times stay on the recognizer's timeline.
public struct LiveTranscriptBuilder: Sendable {
    /// A pause this long between words, or after the last word, ends a passage.
    public var pause: TimeInterval = 0.8
    /// Passages longer than this close at the next word boundary.
    public var maximumSeconds: TimeInterval = 12

    struct Word: Equatable { var text: String; var start: TimeInterval; var end: TimeInterval }

    public private(set) var segments: [LiveCaptionSegment] = []
    private var open: [Word] = []
    private var openID = UUID()
    /// A word being assembled from pieces, not yet known to be complete.
    private var pending: Word?

    public init() {}

    /// Adds tokens in order. Returns whether the segments changed.
    @discardableResult
    public mutating func add(_ tokens: [LiveToken]) -> Bool {
        guard !tokens.isEmpty else { return false }
        for token in tokens {
            let raw = token.text.replacingOccurrences(of: "▁", with: " ")
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, !Self.isControl(piece) else {
                if raw.hasPrefix(" "), let word = pending { append(word); pending = nil }
                continue
            }
            let startsWord = raw.hasPrefix(" ") || pending == nil
            let isPunctuation = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            if isPunctuation, var word = pending {
                word.text += piece; word.end = max(word.end, token.end); pending = word
                continue
            }
            if isPunctuation, pending == nil, let last = open.last {
                // Punctuation after a word already placed in the passage.
                open[open.count - 1].text = last.text + piece
                open[open.count - 1].end = max(last.end, token.end)
                closeIfSentenceEnded()
                continue
            }
            if startsWord {
                if let word = pending { append(word) }
                // A word after a pause starts a new passage at once, not when it's complete.
                if let last = open.last, let first = open.first,
                   token.start - last.end >= pause || token.end - first.start > maximumSeconds { close() }
                pending = Word(text: piece, start: token.start, end: token.end)
            } else if var word = pending {
                word.text += piece
                word.end = max(word.end, token.end)
                pending = word
            }
        }
        if let word = pending, Self.endsSentence(word.text) { append(word); pending = nil }
        rebuild()
        return true
    }

    /// No word arrived up to `time` (the end of the audio decoded so far): a passage whose last word
    /// ended `pause` before it closes. Returns whether the segments changed.
    @discardableResult
    public mutating func advance(to time: TimeInterval) -> Bool {
        let lastEnd = pending?.end ?? open.last?.end
        guard let lastEnd, time - lastEnd >= pause else { return false }
        if let word = pending { append(word); pending = nil }
        guard !open.isEmpty else { return false }
        close()
        rebuild()
        return true
    }

    /// The audio ended: everything stands as heard.
    public mutating func finish() {
        if let word = pending { append(word); pending = nil }
        if !open.isEmpty { close() }
        rebuild()
    }

    // MARK: Assembly

    private mutating func append(_ word: Word) {
        if let previous = open.last ?? pending, let first = open.first {
            if word.start - previous.end >= pause || word.end - first.start > maximumSeconds { close() }
        }
        open.append(word)
        closeIfSentenceEnded()
    }

    private mutating func closeIfSentenceEnded() {
        if let last = open.last, Self.endsSentence(last.text) { close() }
    }

    /// The open passage becomes final.
    private mutating func close() {
        guard !open.isEmpty else { return }
        let segment = Self.segment(open, id: openID, tentative: false)
        if let index = segments.firstIndex(where: { $0.id == openID }) { segments[index] = segment } else { segments.append(segment) }
        open = []
        openID = UUID()
    }

    /// Final passages, then the open one (with any word still being assembled) as tentative.
    private mutating func rebuild() {
        segments.removeAll { $0.id == openID }
        let words = open + (pending.map { [$0] } ?? [])
        if !words.isEmpty { segments.append(Self.segment(words, id: openID, tentative: true)) }
    }

    private static func segment(_ words: [Word], id: UUID, tentative: Bool) -> LiveCaptionSegment {
        LiveCaptionSegment(id: id, start: words[0].start, end: words.map(\.end).max() ?? words[0].end,
                           text: words.map(\.text).joined(separator: " "), isTentative: tentative)
    }

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…。？！".contains(last)
    }

    /// "<blank>", "<unk>", language tags such as "<en-US>": never words.
    static func isControl(_ piece: String) -> Bool { piece.hasPrefix("<") && piece.hasSuffix(">") }
}
