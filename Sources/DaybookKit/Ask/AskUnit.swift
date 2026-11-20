import DaybookCore
import Foundation

/// One searchable piece of a conversation, as the keyword index holds it (docs/architecture.md, "Ask across
/// conversations"). A transcript chunk, a note, and a bookmark are what an answer may rest on; a summary line and a
/// commitment only help find the conversation, and stand for the passage they came from.
public struct AskUnit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case transcript, summaryLine, commitment, note, bookmark }

    public var kind: Kind
    public var meetingID: UUID
    /// A transcript chunk's passages, as positions in the conversation's unified transcript; a summary line's or a
    /// commitment's single evidence passage, when one was found; nil for a note or a bookmark.
    public var passages: Range<Int>?
    public var text: String
    /// Seconds into the conversation: a chunk's first passage, a note's or bookmark's time. Nil for a note written
    /// outside the recording.
    public var start: TimeInterval?
    /// A chunk's speakers, folded (`AskWords.folded`), in the order they first speak.
    public var speakers: [String] = []
    /// Of a chunk's speakers, those who said something in the words of a commitment ("I'll", "let me").
    public var committers: [String] = []
    /// A commitment's owner.
    public var owner: String?
    /// A note's position among the paragraphs, and a bookmark's ID.
    public var paragraph: Int?
    public var highlightID: UUID?
}

/// The index of one conversation: its units, and for each term the units holding it. Built once per version of the
/// conversation's content (`LibraryPassageIndex`).
struct ConversationAskIndex: Sendable {
    struct Posting: Sendable { var unit: Int32; var count: Int32 }

    var units: [AskUnit] = []
    var lengths: [Int32] = []
    var postings: [String: [Posting]] = [:]
    var totalLength = 0

    /// A chunk closes near this much speech, or this many tokens (257 a minute of talk, so about 4 a second).
    static let chunkSeconds = 60.0, chunkTokens = 250
    static let tokensPerWord = 1.84

    init(_ meeting: Meeting) {
        let transcript = meeting.unifiedTranscript
        addChunks(of: meeting, transcript)
        addSummary(of: meeting, transcript)
        addNotes(of: meeting)
    }

    private mutating func add(_ unit: AskUnit) {
        let terms = AskWords.terms(unit.text)
        guard !terms.isEmpty else { return }
        let index = Int32(units.count)
        units.append(unit)
        lengths.append(Int32(terms.count))
        totalLength += terms.count
        var counts: [String: Int32] = [:]
        for term in terms { counts[term, default: 0] += 1 }
        for (term, count) in counts { postings[term, default: []].append(Posting(unit: index, count: count)) }
    }

    // MARK: Transcript

    /// Consecutive passages closed near 60 seconds or 250 tokens, sooner at a change of speaker once there's a fair
    /// amount, each starting with the one before's last passage so a thought that crosses a boundary stays whole.
    private mutating func addChunks(of meeting: Meeting, _ transcript: [TranscriptSegment]) {
        guard !transcript.isEmpty else { return }
        func tokens(_ segment: TranscriptSegment) -> Int {
            Int((Double(segment.text.split(whereSeparator: \.isWhitespace).count) * Self.tokensPerWord).rounded(.up))
        }
        var first = 0
        var next = 0
        while next < transcript.count {
            var spent = 0
            var end = next
            while end < transcript.count {
                spent += tokens(transcript[end])
                end += 1
                let seconds = transcript[end - 1].end - transcript[first].start
                if seconds >= Self.chunkSeconds || spent >= Self.chunkTokens { break }
                if end < transcript.count, transcript[end].speakerID != transcript[end - 1].speakerID,
                   seconds >= Self.chunkSeconds / 2, spent >= Self.chunkTokens / 2 { break }
            }
            addChunk(of: meeting, transcript, first..<end)
            guard end < transcript.count else { break }
            // The next chunk starts with this one's last passage, and always takes at least one new one.
            first = end - 1
            next = end
        }
    }

    private mutating func addChunk(of meeting: Meeting, _ transcript: [TranscriptSegment], _ range: Range<Int>) {
        var speakers: [String] = [], committers: [String] = []
        for segment in transcript[range] {
            guard let name = meeting.speakerName(segment.speakerID).map(AskWords.folded) else { continue }
            if !speakers.contains(name) { speakers.append(name) }
            if Self.promises(segment.text), !committers.contains(name) { committers.append(name) }
        }
        add(AskUnit(kind: .transcript, meetingID: meeting.id, passages: range, text: transcript[range].map(\.text).joined(separator: " "),
                    start: transcript[range.lowerBound].start, speakers: speakers, committers: committers))
    }

    /// Whether a passage says someone will do something. "I can't", "I won't", "I will not", and "I'll not" don't.
    static func promises(_ text: String) -> Bool {
        text.range(of: #"\b(I'll|I’ll|I will|let me|I can|I'm going to|I’m going to|we'll|we’ll|we will)\b(?!['’]t)(?!\s+not\b)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Summary

    /// The overview, each section's bullets, and each commitment with its owner, every one pointing at the passage it
    /// came from. They stand for that passage, never as evidence themselves (`AskRetriever`).
    private mutating func addSummary(of meeting: Meeting, _ transcript: [TranscriptSegment]) {
        guard let summary = meeting.summary, !transcript.isEmpty else { return }
        let evidence = SummaryEvidenceIndex(meeting)
        let positions = Dictionary(transcript.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func passage(for text: String, owner: String? = nil) -> Range<Int>? {
            evidence.segment(for: text, owner: owner).flatMap { positions[$0] }.map { $0..<($0 + 1) }
        }
        func line(_ text: String) {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            add(AskUnit(kind: .summaryLine, meetingID: meeting.id, passages: passage(for: text), text: text))
        }
        line(summary.overview)
        for section in summary.sections {
            for bullet in section.body.split(whereSeparator: \.isNewline) {
                line(String(bullet).replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression))
            }
        }
        for item in summary.actionItems {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            add(AskUnit(kind: .commitment, meetingID: meeting.id, passages: passage(for: text, owner: item.owner), text: text,
                        owner: item.owner.map(AskWords.folded)))
        }
    }

    // MARK: Notes and bookmarks

    /// Each paragraph of the notes with its time, as the summary reads them (handwriting through its recognized
    /// words; a sketch has none), and each bookmark that has words.
    private mutating func addNotes(of meeting: Meeting) {
        let paragraphs = meeting.notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let times = meeting.paragraphTimes()
        let ink = meeting.inkPlacements()
        for (index, text) in paragraphs.enumerated() {
            if text == NoteInk.placeholder, index < ink.count, ink[index] != nil { continue }
            add(AskUnit(kind: .note, meetingID: meeting.id, text: text, start: index < times.count ? times[index] : nil, paragraph: index))
        }
        for highlight in meeting.highlights where !highlight.text.isEmpty && !BookmarkMarks.automaticLabels.contains(highlight.text) {
            add(AskUnit(kind: .bookmark, meetingID: meeting.id, text: highlight.text, start: highlight.time, highlightID: highlight.id))
        }
    }
}
