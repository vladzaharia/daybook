import Foundation

// Unsure words (docs/architecture.md, "Unsure words"): places in a conversation's transcript that may have been heard
// wrong, marked quietly where they read, for the person to answer when they like. Two signals make one kind of flag:
//
// - the recording's latest transcript and its previous one, over the same audio, read the words differently (the
//   earlier reading is offered as the alternative);
// - the recognizer gave the words a low confidence.
//
// Flags are worked out with the unified transcript, after fusion (`Meeting.applyFusion`, off the main actor through
// `Meeting.preparingFusion`), and nothing waits for them. Each is anchored in its recording's own time, which fusing
// again, a recording placed again, and renaming or relabelling speakers leave where it was; it's found in the unified
// transcript by the recording's citations (`SegmentProvenance`), the way corrections find their passages. Text the
// person typed is never flagged, and a flag the person answered (`TranscriptFlagDismissal`) stays answered while the
// words it was about read the same.

/// A place in the transcript that may have been heard wrong.
public struct TranscriptFlag: Codable, Equatable, Identifiable, Sendable {
    public enum Reason: String, ExtensibleSyncEnum {
        /// The recording's latest transcript and its previous one read these words differently.
        case disagreement
        /// The recognizer was unsure of these words.
        case lowConfidence
        public static let syncFallback = Reason.lowConfidence
    }

    /// Worked out from what it marks (`TranscriptFlags.id`), so two devices deriving the same flag give it the same ID.
    public var id: UUID
    /// The recording whose transcript it marks.
    public var trackID: UUID
    /// Where the words are, in seconds of the recording.
    public var start: TimeInterval
    public var end: TimeInterval
    /// The words as the latest transcript reads them.
    public var text: String
    @Extensible public var reason: Reason
    /// The lowest confidence (0–1) the recognizer gave these words, when it gave one.
    public var confidence: Double?
    /// The previous transcript's reading of the same audio: its words, or "" where it heard none. Nil without one.
    public var alternative: String?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(id: UUID? = nil, trackID: UUID, start: TimeInterval, end: TimeInterval, text: String, reason: Reason,
                confidence: Double? = nil, alternative: String? = nil) {
        self.id = id ?? TranscriptFlags.id(trackID: trackID, reason: reason.rawValue, start: start, end: end, text: text)
        self.trackID = trackID; self.start = start; self.end = end; self.text = text; self.reason = reason
        self.confidence = confidence; self.alternative = alternative
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, trackID, start, end, text, reason, confidence, alternative
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        trackID = try values.decode(UUID.self, forKey: .trackID)
        start = try values.decode(TimeInterval.self, forKey: .start)
        end = try values.decode(TimeInterval.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        _reason = try values.decode(Extensible<Reason>.self, forKey: .reason)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        alternative = try values.decodeIfPresent(String.self, forKey: .alternative)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(trackID, forKey: .trackID)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
        try values.encode(_reason, forKey: .reason)
        try values.encodeIfPresent(confidence, forKey: .confidence)
        try values.encodeIfPresent(alternative, forKey: .alternative)
        try unknownFields.encode(to: encoder)
    }
}

/// The person's answer to a flag: the words kept as they are, or the earlier reading taken (which is also a correction,
/// in Version History). Synced with the conversation; it keeps the flag cleared on every device and after the transcript
/// is fused again, for as long as the words it was about read the same.
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
    public var dismissedAt: Date
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(flag: TranscriptFlag, outcome: Outcome, at date: Date = Date()) {
        id = flag.id; trackID = flag.trackID; start = flag.start; end = flag.end; text = flag.text
        self.outcome = outcome; dismissedAt = date
    }

    /// The same flag, or a flag worked out again over the same words of the same recording at about the same place
    /// (a later transcript that reads them the same way).
    public func answers(_ flag: TranscriptFlag) -> Bool {
        if flag.id == id { return true }
        guard flag.trackID == trackID, min(end, flag.end) - max(start, flag.start) > -TranscriptFlags.timeSlack else { return false }
        return TranscriptFlags.key(of: flag.text) == TranscriptFlags.key(of: text)
    }

    /// Three copies' answers merged one by one: every answer either side gave, once; where both changed one (two devices
    /// answered at once), the earlier. An answer both had before that one side took back (Undo) is gone, unless the other
    /// side answered it again. Without a common ancestor, every answer either side has. Deterministic, commutative, and
    /// idempotent; two devices answering at once never conflict.
    public static func merged(base: [TranscriptFlagDismissal]?, _ lhs: [TranscriptFlagDismissal]?,
                              _ rhs: [TranscriptFlagDismissal]?) -> [TranscriptFlagDismissal]? {
        guard lhs != nil || rhs != nil else { return nil }
        let ancestor = Dictionary((base ?? []).map { ($0.id, $0) }, uniquingKeysWith: earlier)
        let a = Dictionary((lhs ?? []).map { ($0.id, $0) }, uniquingKeysWith: earlier)
        let b = Dictionary((rhs ?? []).map { ($0.id, $0) }, uniquingKeysWith: earlier)
        var kept: [TranscriptFlagDismissal] = []
        for id in Set(a.keys).union(b.keys) {
            let old = ancestor[id]
            switch (a[id], b[id]) {
            case let (x?, y?):
                // The side that changed it wins; both changed it, the earlier.
                if x == old { kept.append(y) } else if y == old { kept.append(x) } else { kept.append(earlier(x, y)) }
            case let (x?, nil), let (nil, x?):
                // New on one side, or answered again there while the other took it back.
                if old == nil || x != old { kept.append(x) }
            case (nil, nil): break
            }
        }
        kept.sort { $0.id.uuidString < $1.id.uuidString }
        return kept.isEmpty ? nil : kept
    }

    private static func earlier(_ x: TranscriptFlagDismissal, _ y: TranscriptFlagDismissal) -> TranscriptFlagDismissal {
        let a = (x.dismissedAt, SyncEncoding.string(x)), b = (y.dismissedAt, SyncEncoding.string(y))
        return b < a ? y : x
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, trackID, start, end, text, outcome, dismissedAt
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        trackID = try values.decode(UUID.self, forKey: .trackID)
        start = try values.decode(TimeInterval.self, forKey: .start)
        end = try values.decode(TimeInterval.self, forKey: .end)
        text = try values.decode(String.self, forKey: .text)
        _outcome = try values.decode(Extensible<Outcome>.self, forKey: .outcome)
        dismissedAt = try values.decode(Date.self, forKey: .dismissedAt)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(trackID, forKey: .trackID)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
        try values.encode(text, forKey: .text)
        try values.encode(_outcome, forKey: .outcome)
        try values.encode(dismissedAt, forKey: .dismissedAt)
        try unknownFields.encode(to: encoder)
    }
}

/// A flag where it shows: the passage of the unified transcript, and the flagged words' place in its text.
public struct TranscriptFlagMark: Equatable, Sendable {
    public var flag: TranscriptFlag
    public var segmentID: UUID
    /// The words' range in the passage's text, in UTF-16 offsets.
    public var range: Range<Int>

    public init(flag: TranscriptFlag, segmentID: UUID, range: Range<Int>) {
        self.flag = flag; self.segmentID = segmentID; self.range = range
    }

    /// The flagged words as the passage reads them.
    public func words(in text: String) -> String? {
        guard let range = Range(NSRange(location: range.lowerBound, length: range.count), in: text) else { return nil }
        return String(text[range])
    }

    /// The alternative reading as it goes in the flagged words' place: its words, without the punctuation at its ends
    /// (the passage keeps its own). Nil without one; "" where the earlier transcript heard nothing.
    public var alternativeWords: String? {
        guard let alternative = flag.alternative?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return TranscriptFlags.core(of: alternative).map { String(alternative[$0]) } ?? ""
    }

    /// The passage with the alternative reading in place of the flagged words. Nil without an alternative, when the
    /// passage doesn't hold the words there any more, or when nothing would be left of it.
    public func replacing(in text: String) -> String? {
        guard let alternative = alternativeWords,
              let range = Range(NSRange(location: range.lowerBound, length: range.count), in: text) else { return nil }
        guard alternative.isEmpty else {
            return text.replacingCharacters(in: range, with: alternative)
        }
        // Words taken out: the space on one side goes with them, and at the start, the punctuation after them too.
        var before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        while before.last?.isWhitespace == true { before.removeLast() }
        while after.first?.isWhitespace == true { after.removeFirst() }
        if before.isEmpty {
            while let first = after.first, first.isPunctuation || first.isWhitespace { after.removeFirst() }
        }
        let joined = before.isEmpty || after.isEmpty || after.first?.isPunctuation == true ? before + after : before + " " + after
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }
}

public enum TranscriptFlags {
    /// Seconds two readings of the same words may sit apart and still be the same place.
    static let timeSlack = 0.5
    /// Words compared only with words of the other transcript within this many seconds: two runs over the same audio
    /// place a word within a second of each other, and the band keeps the comparison linear in the recording's length.
    static let window = 3.0
    /// The most words a disagreement may cover on either side; longer differences are about coverage (one run missed a
    /// stretch, or heard background speech), not a word heard wrong.
    static let longestDisagreement = 12
    /// The most words the latest transcript may add where the earlier one heard nothing and still be flagged.
    static let longestAddition = 4
    /// Above this share of differing words, the two transcripts aren't readings of the same speech (another language,
    /// another stretch of audio) and aren't compared.
    static let comparableShare = 0.5

    /// Words below this confidence are flagged, by recognizer family (`ModelProvenance.family`); a recognizer not listed
    /// gives none. Each was set from its confidences over words it got right and wrong (docs/validation.md, "Unsure
    /// words in the transcript"): below 0.5, 76% of Parakeet's flagged words were wrong and 0.3% of its right words
    /// were flagged on clean speech (Apple Speech: 71%, 0.7%), and above it the false flags multiply. Whisper's word
    /// probabilities weren't measured, so its runs are flagged only where transcripts disagree.
    static let confidenceFloors: [String: Double] = ["parakeet": 0.5, "apple-speech": 0.5]

    /// The confidence below which `transcript`'s words are flagged, or nil when its recognizer's confidences aren't used.
    public static func confidenceFloor(for transcript: TrackTranscript) -> Double? {
        confidenceFloors[family(of: transcript)]
    }

    static func family(of transcript: TrackTranscript) -> String {
        if let family = transcript.processingSettings?.model?.family { return family }
        let id = transcript.processingSettings?.modelID ?? transcript.modelID
        return id.split(separator: "/").first.map(String.init) ?? id
    }

    /// The flags of a conversation's transcript as it is now, for storing with it (`Meeting.transcriptFlags`): for each
    /// recording in the unified transcript, where its latest transcript and the previous one that reads differently
    /// disagree, and the words its latest transcript is unsure of, less those in passages the person corrected, those
    /// another recording heard the same way, and those not in the transcript. The person's answers aren't read here
    /// (`marks` reads them), so two devices fusing the same transcripts store the same flags whatever answers have
    /// reached each. Pure; run it off the main actor.
    public static func flags(for meeting: Meeting) -> [TranscriptFlag] {
        var heard = Set<UUID>()
        for segment in meeting.unifiedTranscript {
            heard.insert(segment.trackID)
            for source in segment.provenance { heard.insert(source.trackID) }
        }
        let removed = Set(meeting.tracks.filter(\.isRemoved).map(\.id))
        let runs = Dictionary(grouping: meeting.transcripts.filter { heard.contains($0.trackID) && !removed.contains($0.trackID) },
                              by: \.trackID)
        var found: [TranscriptFlag] = []
        for (trackID, transcripts) in runs {
            // The latest run as fusion picks it (the first of the newest), and the others newest first.
            guard let latest = transcripts.max(by: { $0.createdAt < $1.createdAt }) else { continue }
            let others = transcripts.enumerated().filter { $0.element.id != latest.id }
                .sorted { $0.element.createdAt == $1.element.createdAt ? $0.offset > $1.offset : $0.element.createdAt > $1.element.createdAt }
                .map(\.element)
            let words = tokens(latest)
            var covered = Set<Int>()
            // The run before the latest that reads differently: a speaker-only run repeats its run's words.
            let keys = words.map(\.key)
            if let previous = others.lazy.map(tokens).first(where: { $0.map(\.key) != keys }) {
                for flag in disagreements(words, previous, trackID: trackID) {
                    found.append(flag.flag)
                    covered.formUnion(flag.indices)
                }
            }
            if let floor = confidenceFloor(for: latest) {
                found += unsure(words, below: floor, skipping: covered, trackID: trackID)
            }
        }
        var seen = Set<UUID>()
        return locate(found, in: meeting).map(\.flag).filter { seen.insert($0.id).inserted }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    /// The conversation's stored flags that show now, by passage, each passage's in reading order: those the person
    /// hasn't answered, outside passages they corrected, that another recording didn't hear the same way, and that the
    /// passage still reads.
    public static func marks(in meeting: Meeting) -> [UUID: [TranscriptFlagMark]] {
        guard let flags = meeting.transcriptFlags, !flags.isEmpty else { return [:] }
        let dismissals = meeting.transcriptFlagDismissals ?? []
        let open = flags.filter { flag in !dismissals.contains { $0.answers(flag) } }
        var bySegment: [UUID: [TranscriptFlagMark]] = [:]
        for mark in locate(open, in: meeting) {
            // Two flags over the same words show once.
            guard !(bySegment[mark.segmentID] ?? []).contains(where: { $0.range.overlaps(mark.range) }) else { continue }
            bySegment[mark.segmentID, default: []].append(mark)
        }
        for key in bySegment.keys { bySegment[key]?.sort { $0.range.lowerBound < $1.range.lowerBound } }
        return bySegment
    }

    /// The ID a flag over `text` of a recording at `start`–`end` gets, the same on every device.
    static func id(trackID: UUID, reason: String, start: TimeInterval, end: TimeInterval, text: String) -> UUID {
        SyncEncoding.uuid("transcript-flag:\(trackID.uuidString):\(reason):\(Int((start * 1000).rounded())):\(Int((end * 1000).rounded())):\(key(of: text))")
    }

    // MARK: Words

    /// A word as compared: its letters and digits folded (`key`), as written, when, how sure, and its passage in the run.
    struct Token: Equatable {
        var key: String
        var text: String
        var start: Double
        var end: Double
        var confidence: Double?
        var segment: Int
    }

    /// Where `text`'s letters and digits begin and end, without the punctuation or symbols around them ("Friday." reads
    /// "Friday", "$20" reads "20"). Nil when it has none.
    static func core<S: StringProtocol>(of text: S) -> Range<S.Index>? {
        func isWordy(_ character: Character) -> Bool { character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
        guard let first = text.firstIndex(where: isWordy), let last = text.lastIndex(where: isWordy) else { return nil }
        return first..<text.index(after: last)
    }

    /// A word's letters and digits, case, accents, and width folded: punctuation and casing never make two readings differ.
    static func wordKey(_ word: some StringProtocol) -> String {
        let folded = String(word).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Words as compared, joined: what makes two readings of a stretch the same.
    static func key(of text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map(wordKey).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A run's words, in time order: its recognizer's words (`TrackTranscript.words`) with their confidences, else, for a
    /// run saved without them, its passages' words with times shared out by length. Words of punctuation alone are left
    /// out.
    static func tokens(_ run: TrackTranscript) -> [Token] {
        let segments = run.segments.enumerated().sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
        var result: [Token] = []
        if let words = run.words, !words.isEmpty {
            let starts = segments.map(\.start)
            var last = 0
            for word in words.enumerated().sorted(by: { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }).map(\.element) {
                let pieces = word.text.split(whereSeparator: \.isWhitespace)
                guard !pieces.isEmpty, word.start.isFinite, word.end.isFinite else { continue }
                // The passage holding the word: the last starting by its middle, never one before the last word's.
                let middle = (word.start + word.end) / 2
                let segment = max(last, firstIndex(in: starts) { $0 > middle + 0.001 } - 1)
                last = segment
                let share = (word.end - word.start) / Double(pieces.count)
                for (index, piece) in pieces.enumerated() {
                    let key = wordKey(piece)
                    guard !key.isEmpty else { continue }
                    result.append(Token(key: key, text: String(piece), start: word.start + share * Double(index),
                                        end: word.start + share * Double(index + 1), confidence: word.confidence, segment: segment))
                }
            }
        } else {
            for (index, segment) in segments.enumerated() where segment.start.isFinite && segment.end.isFinite {
                let pieces = segment.text.split(whereSeparator: \.isWhitespace)
                let length = Double(max(1, pieces.reduce(0) { $0 + $1.count }))
                var offset = 0.0
                for piece in pieces {
                    let start = segment.start + (segment.end - segment.start) * offset / length
                    offset += Double(piece.count)
                    let end = segment.start + (segment.end - segment.start) * offset / length
                    let key = wordKey(piece)
                    guard !key.isEmpty else { continue }
                    result.append(Token(key: key, text: String(piece), start: start, end: end, confidence: nil, segment: index))
                }
            }
        }
        return result
    }

    /// The first index whose element satisfies `isAfter`, in an array where every such element follows every other.
    private static func firstIndex(in values: [Double], where isAfter: (Double) -> Bool) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if isAfter(values[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    // MARK: Disagreement

    /// One step of an alignment of two runs' words: indices into the latest run (`a`) and the earlier one (`b`); nil
    /// on the side that lacks the word.
    struct Step: Equatable {
        var a: Int?
        var b: Int?
    }

    /// The fewest word edits that turn `b` into `a`, as steps, each word compared only with the other run's words
    /// heard within `window` seconds of it: a banded edit distance, so different passage boundaries don't matter and the
    /// work grows with the recording's length rather than its square. Ties keep words side by side. Nil when the runs
    /// are too far apart in time to compare.
    static func alignment(_ a: [Token], _ b: [Token], window: Double = TranscriptFlags.window) -> [Step]? {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return a.indices.map { Step(a: $0, b: nil) } + b.indices.map { Step(a: nil, b: $0) } }
        /// The time between word i - 1 and word i: where a cut after i words falls.
        func boundaries(_ words: [Token]) -> [Double] {
            var times = [words[0].start]
            for index in 1..<words.count { times.append((words[index - 1].end + words[index].start) / 2) }
            times.append(words[words.count - 1].end)
            for index in 1..<times.count { times[index] = max(times[index], times[index - 1]) }
            return times
        }
        let ta = boundaries(a), tb = boundaries(b)
        // Each row's band: the cuts in b within the window of the row's cut in a, then widened so every row reaches the next.
        var lo = [Int](repeating: 0, count: n + 1), hi = lo
        for i in 0...n {
            let first = firstIndex(in: tb) { $0 >= ta[i] - window }
            let after = firstIndex(in: tb) { $0 > ta[i] + window }
            if after > first { lo[i] = min(first, m); hi[i] = min(after - 1, m) }
            else { lo[i] = max(min(first, m + 1) - 1, 0); hi[i] = min(first, m) }
        }
        lo[0] = 0; hi[n] = m
        for i in stride(from: n - 1, through: 0, by: -1) { lo[i] = min(lo[i], lo[i + 1]) }
        for i in 1...n { hi[i] = max(hi[i], hi[i - 1]) }
        for i in 0...n { hi[i] = max(hi[i], lo[i]) }
        for i in stride(from: n - 1, through: 0, by: -1) { hi[i] = max(hi[i], lo[i + 1] - 1) }
        guard (0...n).reduce(0, { $0 + hi[$1] - lo[$1] + 1 }) <= 4_000_000 else { return nil }

        let unreachable = Int32.max
        var cost: [[Int32]] = [], move: [[UInt8]] = []
        cost.reserveCapacity(n + 1); move.reserveCapacity(n + 1)
        for i in 0...n {
            var rowCost = [Int32](repeating: unreachable, count: hi[i] - lo[i] + 1)
            var rowMove = [UInt8](repeating: 0, count: rowCost.count)
            for j in lo[i]...hi[i] {
                let k = j - lo[i]
                if i == 0 && j == 0 { rowCost[k] = 0; continue }
                var best = unreachable, how: UInt8 = 0
                if i > 0, j > 0, (lo[i - 1]...hi[i - 1]).contains(j - 1), cost[i - 1][j - 1 - lo[i - 1]] != unreachable {
                    best = cost[i - 1][j - 1 - lo[i - 1]] + (a[i - 1].key == b[j - 1].key ? 0 : 1); how = 0
                }
                if i > 0, (lo[i - 1]...hi[i - 1]).contains(j), cost[i - 1][j - lo[i - 1]] != unreachable,
                   cost[i - 1][j - lo[i - 1]] + 1 < best {
                    best = cost[i - 1][j - lo[i - 1]] + 1; how = 1
                }
                if k > 0, rowCost[k - 1] != unreachable, rowCost[k - 1] + 1 < best {
                    best = rowCost[k - 1] + 1; how = 2
                }
                rowCost[k] = best; rowMove[k] = how
            }
            cost.append(rowCost); move.append(rowMove)
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch move[i][j - lo[i]] {
            case 0: steps.append(Step(a: i - 1, b: j - 1)); i -= 1; j -= 1
            case 1: steps.append(Step(a: i - 1, b: nil)); i -= 1
            default: steps.append(Step(a: nil, b: j - 1)); j -= 1
            }
        }
        return steps.reversed()
    }

    /// Stretches where the alignment's words differ: the latest run's words (`a`) and the earlier run's (`b`), each a
    /// range of indices. Two stretches with a single shared word between them are one, so a phrase reads whole.
    static func differences(_ steps: [Step], _ a: [Token], _ b: [Token]) -> [(a: Range<Int>, b: Range<Int>)] {
        var result: [(a: Range<Int>, b: Range<Int>)] = []
        var nextA = 0, nextB = 0
        var open: (a: Int, b: Int)?
        for step in steps {
            let same = step.a.flatMap { x in step.b.map { y in a[x].key == b[y].key } } ?? false
            if same {
                if let start = open { result.append((start.a..<nextA, start.b..<nextB)); open = nil }
            } else if open == nil {
                open = (nextA, nextB)
            }
            if step.a != nil { nextA += 1 }
            if step.b != nil { nextB += 1 }
        }
        if let start = open { result.append((start.a..<nextA, start.b..<nextB)) }
        var merged: [(a: Range<Int>, b: Range<Int>)] = []
        for difference in result {
            if let last = merged.last, difference.a.lowerBound - last.a.upperBound <= 1, difference.b.lowerBound - last.b.upperBound <= 1 {
                merged[merged.count - 1] = (last.a.lowerBound..<difference.a.upperBound, last.b.lowerBound..<difference.b.upperBound)
            } else {
                merged.append(difference)
            }
        }
        // Only the spacing differs ("ice cream", "icecream"): the same reading.
        return merged.filter { difference in
            difference.a.map { a[$0].key }.joined() != difference.b.map { b[$0].key }.joined()
        }
    }

    /// Flags where the latest run (`latest`) and an earlier one (`earlier`) of one recording read differently, each with
    /// the latest run's word indices it covers. A flag stays within one of the latest run's passages; a word the
    /// latest run left out is flagged with the word beside it, so there's always something to mark.
    static func disagreements(_ latest: [Token], _ earlier: [Token], trackID: UUID) -> [(flag: TranscriptFlag, indices: Range<Int>)] {
        guard !latest.isEmpty, let steps = alignment(latest, earlier) else { return [] }
        let differences = differences(steps, latest, earlier)
        // Each earlier word's place among the latest run's words: the word it was aligned with, else the latest word
        // before it (the first, before any).
        var partner = [Int](repeating: 0, count: earlier.count)
        var lastA: Int?
        for step in steps {
            if let x = step.a { lastA = x }
            if let y = step.b { partner[y] = step.a ?? lastA ?? 0 }
        }
        let differing = differences.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        guard Double(differing) <= comparableShare * Double(max(latest.count, earlier.count)) else { return [] }
        func text(_ words: some Sequence<Token>) -> String { words.map(\.text).joined(separator: " ") }
        var flags: [(flag: TranscriptFlag, indices: Range<Int>)] = []
        for difference in differences {
            var a = difference.a, b = difference.b
            if a.isEmpty {
                // Words only the earlier run heard: marked on the word beside them, the nearer one in time.
                guard b.count <= longestDisagreement else { continue }
                let before = a.lowerBound - 1, after = a.upperBound
                let gapBefore = before >= 0 && b.lowerBound > 0 ? earlier[b.lowerBound].start - latest[before].end : .infinity
                let gapAfter = after < latest.count && b.upperBound < earlier.count ? latest[after].start - earlier[b.upperBound - 1].end : .infinity
                if gapBefore.isInfinite && gapAfter.isInfinite { continue }
                if gapBefore <= gapAfter { a = before..<a.upperBound; b = (b.lowerBound - 1)..<b.upperBound }
                else { a = a.lowerBound..<(after + 1); b = b.lowerBound..<(b.upperBound + 1) }
            } else if b.isEmpty {
                guard a.count <= longestAddition else { continue }
            } else {
                guard a.count <= longestDisagreement, b.count <= longestDisagreement else { continue }
            }
            // One flag per passage of the latest run; the earlier words go with the part holding the words they were
            // aligned with, and a part that reads the same as its earlier words (a shared word between two
            // differences, alone in its passage) isn't one.
            let parts = Dictionary(grouping: a, by: { latest[$0].segment }).values.map { $0.min()!..<($0.max()! + 1) }
                .sorted { $0.lowerBound < $1.lowerBound }
            var alternatives = Array(repeating: [Token](), count: parts.count)
            for index in b {
                let place = partner[index]
                let part = parts.firstIndex { $0.contains(place) }
                    ?? parts.indices.min { distance(Double(place), parts[$0]) < distance(Double(place), parts[$1]) }!
                alternatives[part].append(earlier[index])
            }
            for (part, alternative) in zip(parts, alternatives) {
                let words = latest[part]
                guard words.map(\.key).joined() != alternative.map(\.key).joined() else { continue }
                let confidences = words.compactMap(\.confidence)
                let flag = TranscriptFlag(trackID: trackID, start: words.first!.start, end: words.last!.end, text: text(words),
                                          reason: .disagreement, confidence: confidences.min(), alternative: text(alternative))
                flags.append((flag, part))
            }
        }
        return flags
    }

    /// How far word `place` is from the words `part`: zero inside it.
    private static func distance(_ place: Double, _ part: Range<Int>) -> Double {
        place < Double(part.lowerBound) ? Double(part.lowerBound) - place : max(0, place - Double(part.upperBound - 1))
    }

    /// Flags over the words the recognizer gave less than `floor`, neighbours in one passage together, leaving out the
    /// words already flagged (`skipping`).
    static func unsure(_ words: [Token], below floor: Double, skipping: Set<Int>, trackID: UUID) -> [TranscriptFlag] {
        var flags: [TranscriptFlag] = []
        var run: [Int] = []
        func close() {
            guard let first = run.first, let last = run.last else { return }
            let span = words[first...last]
            flags.append(TranscriptFlag(trackID: trackID, start: span.first!.start, end: span.last!.end,
                                        text: span.map(\.text).joined(separator: " "), reason: .lowConfidence,
                                        confidence: span.compactMap(\.confidence).min()))
            run = []
        }
        for (index, word) in words.enumerated() {
            guard !skipping.contains(index), let confidence = word.confidence, confidence < floor else { close(); continue }
            if let last = run.last, last != index - 1 || words[last].segment != word.segment { close() }
            run.append(index)
        }
        close()
        return flags
    }

    // MARK: Where flags show

    /// Each flag's place in the unified transcript: the passage citing its recording at its time (the passage's own
    /// recording and time when it cites none) that reads its words, nearest where the time says. A flag is left out when
    /// it falls in a passage the person corrected, when another recording heard every one of its words the same way
    /// (`SegmentProvenance.wordIndices`), or when no passage reads it.
    static func locate(_ flags: [TranscriptFlag], in meeting: Meeting) -> [TranscriptFlagMark] {
        guard !flags.isEmpty else { return [] }
        let segments = meeting.unifiedTranscript
        let corrected = meeting.correctedSegmentIDs
        // Per recording: the passages citing it, with the span they cite in its own time.
        var spans: [UUID: [(segment: Int, start: Double, end: Double)]] = [:]
        for (index, segment) in segments.enumerated() {
            if segment.provenance.isEmpty {
                guard let clock = meeting.clock(of: segment.trackID), clock.rate > 0 else { continue }
                spans[segment.trackID, default: []].append((index, (segment.start - clock.offset) / clock.rate, (segment.end - clock.offset) / clock.rate))
            } else {
                for source in segment.provenance { spans[source.trackID, default: []].append((index, source.start, source.end)) }
            }
        }
        // Each word's letters and digits: the mark leaves the punctuation around them alone.
        var words: [Int: [(key: String, range: Range<Int>)]] = [:]
        func wordsOf(_ index: Int) -> [(key: String, range: Range<Int>)] {
            if let cached = words[index] { return cached }
            let text = segments[index].text
            let found = text.split(whereSeparator: \.isWhitespace).map { piece -> (key: String, range: Range<Int>) in
                let range = NSRange(core(of: piece) ?? piece.startIndex..<piece.endIndex, in: text)
                return (wordKey(piece), range.location..<(range.location + range.length))
            }
            words[index] = found
            return found
        }
        var marks: [TranscriptFlagMark] = []
        for flag in flags {
            let keys = flag.text.split(whereSeparator: \.isWhitespace).map(wordKey).filter { !$0.isEmpty }
            guard !keys.isEmpty else { continue }
            var candidates: [(segment: Int, start: Double, end: Double, overlap: Double)] = []
            for span in spans[flag.trackID] ?? [] {
                let overlap: Double = min(span.end, flag.end) - max(span.start, flag.start)
                if overlap > -timeSlack { candidates.append((span.segment, span.start, span.end, overlap)) }
            }
            // Passages beside it count only when none holds its time.
            if candidates.contains(where: { $0.overlap > 0 }) { candidates.removeAll { $0.overlap <= 0 } }
            candidates.sort { $0.overlap == $1.overlap ? $0.segment < $1.segment : $0.overlap > $1.overlap }
            // The person's words are theirs.
            guard !candidates.contains(where: { $0.overlap > 0 && corrected.contains(segments[$0.segment].id) }) else { continue }
            for span in candidates where !corrected.contains(segments[span.segment].id) {
                let all = wordsOf(span.segment)
                let positions: [Int] = all.indices.filter { !all[$0].key.isEmpty }
                guard positions.count >= keys.count else { continue }
                let starts: [Int] = (0...(positions.count - keys.count)).filter { offset in
                    keys.indices.allSatisfy { all[positions[offset + $0]].key == keys[$0] }
                }
                guard !starts.isEmpty else { continue }
                let length: Double = span.end - span.start
                let share: Double = length > 0 ? min(1, max(0, (flag.start - span.start) / length)) : 0
                let expected: Double = share * Double(all.count)
                func distance(_ start: Int) -> Double { abs(Double(positions[start]) - expected) }
                let chosen = starts.min { distance($0) < distance($1) }!
                let indices: [Int] = keys.indices.map { positions[chosen + $0] }
                let segment = segments[span.segment]
                // Fusion numbers a passage's words with letters or digits (punctuation alone goes with the word before).
                let fused = Set(keys.indices.map { chosen + $0 })
                let corroborated = segment.provenance.contains { source in
                    guard source.trackID != flag.trackID, let supported = source.wordIndices else { return false }
                    return Set(supported).isSuperset(of: fused)
                }
                if !corroborated {
                    marks.append(TranscriptFlagMark(flag: flag, segmentID: segment.id,
                                                    range: all[indices.first!].range.lowerBound..<all[indices.last!].range.upperBound))
                }
                break
            }
        }
        return marks
    }
}

extension Meeting {
    /// The flags that show now, by passage (`TranscriptFlags.marks`).
    public var transcriptFlagMarks: [UUID: [TranscriptFlagMark]] { TranscriptFlags.marks(in: self) }

    /// Keeps a flag's words as they are: the flag is cleared here and on every device. Nothing in the transcript changes.
    @discardableResult public mutating func keepFlaggedWords(_ flagID: UUID, at date: Date = Date()) -> Bool {
        guard let flag = transcriptFlags?.first(where: { $0.id == flagID }) else { return false }
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

    @discardableResult private mutating func answer(_ flag: TranscriptFlag, _ outcome: TranscriptFlagDismissal.Outcome, at date: Date) -> Bool {
        guard !(transcriptFlagDismissals ?? []).contains(where: { $0.answers(flag) }) else { return false }
        transcriptFlagDismissals = (transcriptFlagDismissals ?? []) + [TranscriptFlagDismissal(flag: flag, outcome: outcome, at: date)]
        updatedAt = max(updatedAt, date)
        return true
    }
}
