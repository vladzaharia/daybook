import Foundation

// The person's answers to unsure words (docs/architecture.md, "Unsure words"). An answer is never removed from the
// stored list: taking one back (Undo) marks it withdrawn, so a merge of two copies is a union that needs no common
// ancestor and no knowing what a copy lacks. Two copies of one answer merge from their own two records alone.

/// The person's answer to a flag: the words kept as they are, or the earlier reading taken (which is also a correction,
/// in Version History). Synced with the conversation; it keeps the flag cleared on every device and after the transcript
/// is fused again, for as long as the words it was about read the same (`TranscriptFlags.answered`).
public struct TranscriptFlagDismissal: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, ExtensibleSyncEnum {
        case kept
        case alternative
        public static let syncFallback = Outcome.kept
    }

    /// The flag's ID.
    public var id: UUID
    public var trackID: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    /// The words as they read when the person answered.
    public var text: String
    @Extensible public var outcome: Outcome
    /// When the person last gave this answer.
    public var dismissedAt: Date
    /// The earlier reading the person saw (`TranscriptFlag.alternative`): a later flag over the same words that offers
    /// another one is new evidence, not answered.
    public var alternative: String?
    /// When the person took the answer back (Undo), if they did. The answer counts only while this is nil or earlier
    /// than `dismissedAt`: answering again after taking back counts as answered.
    public var withdrawnAt: Date?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()
    /// The whole of an answer this version can't read (a newer Daybook's shape), written back as it came. A flag with such
    /// an answer counts as answered here (`TranscriptFlags.answered`): no mark, no actions, and nothing here replaces,
    /// withdraws, or changes the record. It is kept and merged by its `id` alone, and always wins over a readable copy.
    public private(set) var unread: SyncJSONValue?

    public init(flag: TranscriptFlag, outcome: Outcome, at date: Date = Date()) {
        id = flag.id; trackID = flag.trackID; start = flag.start; end = flag.end; text = flag.text
        self.outcome = outcome; dismissedAt = date; alternative = flag.alternative
    }

    /// Whether this version's answer stands: not taken back, or given again since. False for an answer it can't read
    /// (`unread`), which stands for the version that wrote it.
    public var isActive: Bool {
        guard unread == nil else { return false }
        guard let withdrawnAt else { return true }
        return dismissedAt > withdrawnAt
    }

    /// Two copies of an answer merged: the later of its two answers (its words, outcome, and earlier reading), and the
    /// later of its two withdrawals, so it stands if it was answered after it was last taken back, whichever device did
    /// which. An answer a newer version wrote that this one can't read wins over one it can. Commutative, associative,
    /// and idempotent.
    static func combined(_ x: TranscriptFlagDismissal, _ y: TranscriptFlagDismissal) -> TranscriptFlagDismissal {
        if x.unread != nil || y.unread != nil {
            guard let a = x.unread, let b = y.unread else { return x.unread != nil ? x : y }
            return SyncEncoding.string(a) >= SyncEncoding.string(b) ? x : y
        }
        let a = (x.dismissedAt, SyncEncoding.string(x)), b = (y.dismissedAt, SyncEncoding.string(y))
        var result = b > a ? y : x
        result.withdrawnAt = [x.withdrawnAt, y.withdrawnAt].compactMap { $0 }.max()
        result.unknownFields = UnknownFields.merged(base: nil, x.unknownFields, y.unknownFields)
        return result
    }

    /// Two copies' answers merged: every answer either has, once (`combined` where both have it). Needs nothing else: not
    /// a common ancestor, and not the absence of an answer in one copy, which says nothing (a copy that never saw it, or
    /// an older Daybook that kept the list whole). Deterministic, commutative, and idempotent; two devices answering at
    /// once never conflict.
    public static func merged(_ lhs: [TranscriptFlagDismissal]?, _ rhs: [TranscriptFlagDismissal]?) -> [TranscriptFlagDismissal]? {
        guard lhs != nil || rhs != nil else { return nil }
        var byID: [UUID: TranscriptFlagDismissal] = [:]
        for answer in (lhs ?? []) + (rhs ?? []) { byID[answer.id] = byID[answer.id].map { combined($0, answer) } ?? answer }
        let kept = byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return kept.isEmpty ? nil : kept
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, trackID, start, end, text, outcome, dismissedAt, alternative, withdrawnAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    private init(unread value: SyncJSONValue) {
        if case .object(let fields) = value, case .string(let text)? = fields["id"], let found = UUID(uuidString: text) { id = found }
        else { id = SyncEncoding.uuid("unread-transcript-flag-answer:\(SyncEncoding.string(value))") }
        trackID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); start = 0; end = 0; text = ""
        _outcome = Extensible(wrappedValue: .kept); dismissedAt = .distantPast
        unread = value
    }

    /// Reads one answer; one this version can't read is kept as it came (`unread`), so a list never fails as a whole and
    /// a newer version's answers survive a round trip.
    public init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var answer = TranscriptFlagDismissal(unread: .null)
            answer.id = try values.decode(UUID.self, forKey: .id)
            answer.trackID = try values.decode(UUID.self, forKey: .trackID)
            answer.start = try values.decode(TimeInterval.self, forKey: .start)
            answer.end = try values.decode(TimeInterval.self, forKey: .end)
            answer.text = try values.decode(String.self, forKey: .text)
            answer._outcome = try values.decode(Extensible<Outcome>.self, forKey: .outcome)
            answer.dismissedAt = try values.decode(Date.self, forKey: .dismissedAt)
            answer.alternative = try values.decodeIfPresent(String.self, forKey: .alternative)
            answer.withdrawnAt = try values.decodeIfPresent(Date.self, forKey: .withdrawnAt)
            answer.unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
            answer.unread = nil
            self = answer
        } catch {
            self = TranscriptFlagDismissal(unread: try SyncJSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let unread { try unread.encode(to: encoder); return }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(trackID, forKey: .trackID)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
        try values.encode(_outcome, forKey: .outcome)
        try values.encode(dismissedAt, forKey: .dismissedAt)
        try values.encodeIfPresent(alternative, forKey: .alternative)
        try values.encodeIfPresent(withdrawnAt, forKey: .withdrawnAt)
        try unknownFields.encode(to: encoder)
    }
}

extension TranscriptFlags {
    /// How far apart, in seconds, two readings of one word may sit and still be the same place: a transcription run
    /// again times its words a little differently, and the recognizers' passages start where they like.
    static let drift = 1.0

    /// A span's words (those with letters or digits) with their time, shared out over the span by length.
    static func timedWords(_ text: String, start: Double, end: Double) -> [(key: String, start: Double, end: Double)] {
        guard start.isFinite, end.isFinite, end >= start else { return [] }
        let pieces = text.split(whereSeparator: \.isWhitespace)
        let length = Double(max(1, pieces.reduce(0) { $0 + $1.count }))
        var offset = 0.0
        var result: [(key: String, start: Double, end: Double)] = []
        for piece in pieces {
            let first = start + (end - start) * offset / length
            offset += Double(piece.count)
            let key = wordKey(piece)
            if !key.isEmpty { result.append((key, first, start + (end - start) * offset / length)) }
        }
        return result
    }

    /// Whether an earlier reading a flag offers is the one an answer was given to, or a part of it (a phrase split in two
    /// offers each half): its words are the answer's, side by side, or both are nothing.
    private static func offers(_ offered: String, within reading: [String]) -> Bool {
        let words = key(of: offered).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return reading.isEmpty }
        return reading.count >= words.count && (0...(reading.count - words.count)).contains { Array(reading[$0..<($0 + words.count)]) == words }
    }

    /// The flags `answers` answer, by ID. An answer covers a flag word by word: each of the flag's words (its letters and
    /// digits, and when it was said in its recording) has to be one of an answer's words of the same recording, the
    /// nearest of that key in time within `drift` of it. A word one answered word stands for is never two: keeping one
    /// "Friday" doesn't answer a second, separate "Friday". Neither the way the words are grouped nor a run's small
    /// timing differences matter. A flag that offers an earlier reading answers only an answer to that reading: another
    /// is new evidence. Answers that were taken back answer nothing.
    static func answered(_ flags: [TranscriptFlag], by answers: [TranscriptFlagDismissal]) -> Set<UUID> {
        // An answer this version can't read answers the flag with its ID, whatever its words: it is the newer version's.
        let unread = Set(answers.filter { $0.unread != nil }.map(\.id))
        let byID = Set(flags.filter { unread.contains($0.id) }.map(\.id))
        let active = answers.filter(\.isActive)
        guard !active.isEmpty, !flags.isEmpty else { return byID }
        struct Slot { var flag: Int; var word: Int; var start: Double; var end: Double }
        var slots: [UUID: [String: [Slot]]] = [:]
        var counts = [Int](repeating: 0, count: flags.count)
        for (index, flag) in flags.enumerated() where flag.unread == nil {
            let words = timedWords(flag.text, start: flag.start, end: flag.end)
            counts[index] = words.count
            for (word, found) in words.enumerated() {
                slots[flag.trackID, default: [:]][found.key, default: []].append(Slot(flag: index, word: word, start: found.start, end: found.end))
            }
        }
        var covered = [Set<Int>](repeating: [], count: flags.count)
        for answer in active {
            let reading = answer.alternative.map { key(of: $0).split(separator: " ").map(String.init) }
            for word in timedWords(answer.text, start: answer.start, end: answer.end) {
                var nearest: (slot: Slot, distance: Double)?
                for slot in slots[answer.trackID]?[word.key] ?? [] {
                    if let offered = flags[slot.flag].alternative, !(reading.map { offers(offered, within: $0) } ?? false) { continue }
                    guard max(slot.start - word.end, word.start - slot.end) <= drift else { continue }
                    let distance = abs((slot.start + slot.end) / 2 - (word.start + word.end) / 2)
                    if distance < nearest?.distance ?? .infinity { nearest = (slot, distance) }
                }
                if let slot = nearest?.slot { covered[slot.flag].insert(slot.word) }
            }
        }
        return byID.union(flags.indices.filter { counts[$0] > 0 && covered[$0].count == counts[$0] }.map { flags[$0].id })
    }
}

extension Meeting {
    /// The flags that show now, by passage (`TranscriptFlags.marks`).
    public var transcriptFlagMarks: [UUID: [TranscriptFlagMark]] { TranscriptFlags.marks(in: self) }

    /// Keeps a flag's words as they are: the flag is cleared here and on every device. Nothing in the transcript changes.
    @discardableResult public mutating func keepFlaggedWords(_ flagID: UUID, at date: Date = Date()) -> Bool {
        guard let flag = transcriptFlags?.first(where: { $0.id == flagID && $0.unread == nil }) else { return false }
        return answer(flag, .kept, at: date)
    }

    /// Takes a flag's alternative reading: the passage is corrected with it (in Version History, as any correction), and
    /// the flag is cleared. False when the flag has no alternative or doesn't show.
    @discardableResult public mutating func useFlagAlternative(_ flagID: UUID, at date: Date = Date()) -> Bool {
        guard let mark = transcriptFlagMarks.values.lazy.flatMap({ $0 }).first(where: { $0.flag.id == flagID }),
              let index = unifiedTranscript.firstIndex(where: { $0.id == mark.segmentID }),
              let text = mark.replacing(in: unifiedTranscript[index].text) else { return false }
        correctSegment(id: mark.segmentID, text: text)
        answer(mark.flag, .alternative, at: date)
        return true
    }

    /// Takes back the answer to a flag (Undo): it's marked withdrawn, never removed, so merging it with another device's
    /// copy takes it back there too and nothing else with it. False when it isn't answered here: an answer a newer
    /// version wrote that this one can't read is never touched.
    @discardableResult public mutating func withdrawFlagAnswer(_ flagID: UUID, at date: Date = Date()) -> Bool {
        guard var answers = transcriptFlagDismissals, let index = answers.firstIndex(where: { $0.id == flagID && $0.isActive }) else { return false }
        answers[index].withdrawnAt = max(date, answers[index].dismissedAt)
        transcriptFlagDismissals = answers
        updatedAt = max(updatedAt, date)
        return true
    }

    /// Takes back Use (Undo): the passage reads as it did before, if it still reads as Use wrote it, and the flag's answer
    /// is withdrawn. Only that passage and that answer change; anything else done since stays. The passage's Version
    /// History keeps both corrections.
    @discardableResult public mutating func takeBackFlagAlternative(_ flagID: UUID, in passageID: UUID, from written: String, to original: String,
                                                                    at date: Date = Date()) -> Bool {
        // An answer this version can't read (a newer Daybook's) is never taken back here, nor the passage with it.
        guard transcriptFlagDismissals?.contains(where: { $0.id == flagID && $0.isActive }) == true else { return false }
        if unifiedTranscript.first(where: { $0.id == passageID })?.text == written { correctSegment(id: passageID, text: original) }
        return withdrawFlagAnswer(flagID, at: date)
    }

    @discardableResult private mutating func answer(_ flag: TranscriptFlag, _ outcome: TranscriptFlagDismissal.Outcome, at date: Date) -> Bool {
        var answers = transcriptFlagDismissals ?? []
        guard TranscriptFlags.answered([flag], by: answers).isEmpty else { return false }
        var given = TranscriptFlagDismissal(flag: flag, outcome: outcome, at: date)
        if let index = answers.firstIndex(where: { $0.id == flag.id }) {
            // Answered again after it was taken back: the same answer, given later than it was withdrawn.
            given.dismissedAt = max(date, (answers[index].withdrawnAt ?? .distantPast).addingTimeInterval(0.001))
            given.withdrawnAt = answers[index].withdrawnAt
            given.unknownFields = answers[index].unknownFields
            answers[index] = given
        } else {
            answers.append(given)
        }
        transcriptFlagDismissals = answers
        updatedAt = max(updatedAt, date)
        return true
    }
}
