import Foundation

// Scoring for the speech evaluation harness (`Daybook --evaluate`, docs/validation.md). Pure value
// math with no models or audio, so every number the harness reports is unit-tested on synthetic data.

/// A word with its time span, as a reference (CTM) or a recognizer gives it.
public struct TimedWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

/// Who spoke from when to when, as a reference (RTTM) or a diarizer gives it.
public struct SpeakerSpan: Codable, Equatable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Speaker-attributed text: one speaker's words in order (an STM reference, or a transcript's speaker).
public struct SpeakerText: Codable, Equatable, Sendable {
    public var speaker: String
    public var text: String
    public init(speaker: String, text: String) { self.speaker = speaker; self.text = text }
}

// MARK: - Text

/// The normalization every word metric applies to both sides: lowercase, curly apostrophes
/// straightened, dashes and slashes split words, other punctuation and symbols dropped, and an
/// apostrophe kept only inside a word ("don't"). Numbers are not spelled out, so "5" and "five"
/// differ; references should write numbers the way the recognizer does.
public enum TranscriptNormalizer {
    public static func words(_ text: String) -> [String] {
        var output: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty { output.append(trimmed) }
            current = ""
        }
        for character in text.lowercased() {
            if character == "’" || character == "‘" || character == "'" || character == "`" { current.append("'"); continue }
            if character.isWhitespace || "-‐‑‒–—―/\\".contains(character) { flush(); continue }
            if character.isLetter || character.isNumber || character.unicodeScalars.contains(where: { CharacterSet.nonBaseCharacters.contains($0) }) {
                current.append(character)
            } else {
                // Punctuation and symbols end nothing by themselves ("U.S." → "us"), except as word breaks above.
                continue
            }
        }
        flush()
        return output
    }

    /// Characters for character error rate, for languages written without spaces (Japanese, Chinese):
    /// the normalized words' characters, spaces removed.
    public static func characters(_ text: String) -> [String] {
        words(text).joined().map(String.init)
    }
}

// MARK: - Word error rate

/// Edit counts between a reference and a hypothesis.
public struct ErrorCounts: Codable, Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    /// Reference tokens.
    public var referenceLength: Int
    public var hypothesisLength: Int

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceLength: Int = 0, hypothesisLength: Int = 0) {
        self.substitutions = substitutions; self.deletions = deletions; self.insertions = insertions
        self.referenceLength = referenceLength; self.hypothesisLength = hypothesisLength
    }

    public var errors: Int { substitutions + deletions + insertions }
    /// Errors per reference token. Nil when the reference is empty: no rate is defined, though any
    /// hypothesis tokens still count as insertions in `errors` and in pooled totals.
    public var rate: Double? { referenceLength == 0 ? nil : Double(errors) / Double(referenceLength) }

    public static func + (lhs: ErrorCounts, rhs: ErrorCounts) -> ErrorCounts {
        ErrorCounts(substitutions: lhs.substitutions + rhs.substitutions, deletions: lhs.deletions + rhs.deletions,
                    insertions: lhs.insertions + rhs.insertions, referenceLength: lhs.referenceLength + rhs.referenceLength,
                    hypothesisLength: lhs.hypothesisLength + rhs.hypothesisLength)
    }
}

public enum WordErrorRate {
    /// Minimum edits between token sequences. Two rows of memory, so hour-long transcripts are fine.
    /// Ties prefer substitutions, then deletions, as sclite reports them.
    public static func counts(reference: [String], hypothesis: [String]) -> ErrorCounts {
        let n = reference.count, m = hypothesis.count
        guard n > 0, m > 0 else {
            return ErrorCounts(deletions: n, insertions: m, referenceLength: n, hypothesisLength: m)
        }
        struct Cell { var cost: Int; var s: Int; var d: Int; var i: Int }
        var previous = (0...m).map { Cell(cost: $0, s: 0, d: 0, i: $0) }
        var current = previous
        for r in 1...n {
            current[0] = Cell(cost: r, s: 0, d: r, i: 0)
            for h in 1...m {
                let diagonal = previous[h - 1]
                if reference[r - 1] == hypothesis[h - 1] {
                    current[h] = diagonal
                    continue
                }
                var best = Cell(cost: diagonal.cost + 1, s: diagonal.s + 1, d: diagonal.d, i: diagonal.i)
                let up = previous[h]
                if up.cost + 1 < best.cost { best = Cell(cost: up.cost + 1, s: up.s, d: up.d + 1, i: up.i) }
                let left = current[h - 1]
                if left.cost + 1 < best.cost { best = Cell(cost: left.cost + 1, s: left.s, d: left.d, i: left.i + 1) }
                current[h] = best
            }
            swap(&previous, &current)
        }
        let last = previous[m]
        return ErrorCounts(substitutions: last.s, deletions: last.d, insertions: last.i, referenceLength: n, hypothesisLength: m)
    }

    /// Word error counts after normalizing both texts.
    public static func counts(reference: String, hypothesis: String) -> ErrorCounts {
        counts(reference: TranscriptNormalizer.words(reference), hypothesis: TranscriptNormalizer.words(hypothesis))
    }

    /// Character error counts after normalizing both texts (spaces removed).
    public static func characterCounts(reference: String, hypothesis: String) -> ErrorCounts {
        counts(reference: TranscriptNormalizer.characters(reference), hypothesis: TranscriptNormalizer.characters(hypothesis))
    }

    /// One alignment step: indices into the reference and hypothesis.
    public enum Step: Equatable, Sendable {
        case match(Int, Int), substitution(Int, Int), deletion(Int), insertion(Int)
    }

    /// The full alignment, for pairing words (word-timing error). Needs reference × hypothesis bytes
    /// of memory; `WordTimingError` aligns long transcripts in time windows to bound it.
    public static func align(reference: [String], hypothesis: [String]) -> [Step] {
        let n = reference.count, m = hypothesis.count
        if n == 0 { return (0..<m).map { .insertion($0) } }
        if m == 0 { return (0..<n).map { .deletion($0) } }
        // 0 diagonal, 1 up (deletion), 2 left (insertion)
        var moves = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        var previous = Array(0...m)
        var current = previous
        for h in 1...m { moves[h] = 2 }
        for r in 1...n {
            current[0] = r
            moves[r * (m + 1)] = 1
            for h in 1...m {
                let same = reference[r - 1] == hypothesis[h - 1]
                var cost = previous[h - 1] + (same ? 0 : 1), move: UInt8 = 0
                if previous[h] + 1 < cost { cost = previous[h] + 1; move = 1 }
                if current[h - 1] + 1 < cost { cost = current[h - 1] + 1; move = 2 }
                current[h] = cost
                moves[r * (m + 1) + h] = move
            }
            swap(&previous, &current)
        }
        var steps: [Step] = []
        var r = n, h = m
        while r > 0 || h > 0 {
            switch moves[r * (m + 1) + h] {
            case 0 where r > 0 && h > 0:
                steps.append(reference[r - 1] == hypothesis[h - 1] ? .match(r - 1, h - 1) : .substitution(r - 1, h - 1))
                r -= 1; h -= 1
            case 1 where r > 0:
                steps.append(.deletion(r - 1)); r -= 1
            default:
                if h > 0 { steps.append(.insertion(h - 1)); h -= 1 } else { steps.append(.deletion(r - 1)); r -= 1 }
            }
        }
        return steps.reversed()
    }
}

// MARK: - cpWER

/// Concatenated minimum-permutation word error rate (CHiME-6): each reference speaker's words are
/// compared with one hypothesis speaker's words, under the speaker mapping with the fewest errors.
/// Wrong words and words given to the wrong speaker both count.
public enum ConcatenatedPermutationWER {
    public struct Result: Codable, Equatable, Sendable {
        public var counts: ErrorCounts
        /// Reference speaker → hypothesis speaker (missing when unmatched).
        public var mapping: [String: String]
        public var rate: Double? { counts.rate }
    }

    public static func score(reference: [SpeakerText], hypothesis: [SpeakerText]) -> Result {
        let ref = grouped(reference), hyp = grouped(hypothesis)
        let size = max(ref.count, hyp.count)
        guard size > 0 else { return Result(counts: ErrorCounts(), mapping: [:]) }
        var counts = [[ErrorCounts]](repeating: [ErrorCounts](repeating: ErrorCounts(), count: size), count: size)
        for r in 0..<size {
            for h in 0..<size {
                let referenceWords = r < ref.count ? ref[r].words : []
                let hypothesisWords = h < hyp.count ? hyp[h].words : []
                counts[r][h] = WordErrorRate.counts(reference: referenceWords, hypothesis: hypothesisWords)
            }
        }
        let assignment = Hungarian.minimize(counts.map { $0.map { Double($0.errors) } })
        var total = ErrorCounts()
        var mapping: [String: String] = [:]
        for (r, h) in assignment.enumerated() {
            total = total + counts[r][h]
            if r < ref.count, h < hyp.count { mapping[ref[r].speaker] = hyp[h].speaker }
        }
        return Result(counts: total, mapping: mapping)
    }

    /// Each speaker's text in order of first appearance, normalized into words.
    private static func grouped(_ texts: [SpeakerText]) -> [(speaker: String, words: [String])] {
        var order: [String] = []
        var words: [String: [String]] = [:]
        for item in texts {
            if words[item.speaker] == nil { order.append(item.speaker) }
            words[item.speaker, default: []] += TranscriptNormalizer.words(item.text)
        }
        return order.map { ($0, words[$0] ?? []) }
    }
}

// MARK: - Diarization error rate

/// Diarization error rate and Jaccard error rate, scored on exact time spans (no frame
/// quantization). Speakers are mapped one to one to maximize overlap (DER) or minimize per-speaker
/// Jaccard error (JER), with the Hungarian algorithm, as md-eval and dscore do. Overlapping speech
/// is scored unless `ignoringOverlap`; `collar` seconds around each reference boundary are not scored.
public enum DiarizationErrorRate {
    public struct Result: Codable, Equatable, Sendable {
        /// Scored reference speech, in speaker-seconds (overlap counts once per speaker).
        public var referenceSeconds: Double
        public var missedSeconds: Double
        public var falseAlarmSeconds: Double
        public var confusionSeconds: Double
        /// Reference speaker → hypothesis speaker under the DER mapping.
        public var mapping: [String: String]
        /// Mean Jaccard error over reference speakers; nil without reference speech.
        public var jaccardErrorRate: Double?
        public var referenceSpeakers: Int
        public var hypothesisSpeakers: Int

        public var errorSeconds: Double { missedSeconds + falseAlarmSeconds + confusionSeconds }
        /// Nil without reference speech.
        public var rate: Double? { referenceSeconds > 0 ? errorSeconds / referenceSeconds : nil }
    }

    public static func score(reference: [SpeakerSpan], hypothesis: [SpeakerSpan], collar: Double = 0,
                             ignoringOverlap: Bool = false) -> Result {
        let ref = merged(reference), hyp = merged(hypothesis)
        let refSpeakers = ref.keys.sorted(), hypSpeakers = hyp.keys.sorted()
        // Unscored zones: ± collar around every reference boundary.
        var unscored: [(Double, Double)] = []
        if collar > 0 {
            for spans in ref.values {
                for span in spans { unscored += [(span.0 - collar, span.0 + collar), (span.1 - collar, span.1 + collar)] }
            }
            unscored = union(unscored)
        }
        var boundaries = Set<Double>()
        for spans in ref.values { for span in spans { boundaries.insert(span.0); boundaries.insert(span.1) } }
        for spans in hyp.values { for span in spans { boundaries.insert(span.0); boundaries.insert(span.1) } }
        for zone in unscored { boundaries.insert(zone.0); boundaries.insert(zone.1) }
        let times = boundaries.sorted()

        // Elementary intervals: who is active in each, and its scored length.
        struct Piece { var duration: Double; var ref: [Int]; var hyp: [Int] }
        var pieces: [Piece] = []
        var refCursor = [Int](repeating: 0, count: refSpeakers.count), hypCursor = [Int](repeating: 0, count: hypSpeakers.count)
        var zoneCursor = 0
        func active(_ spans: [(Double, Double)], _ cursor: inout Int, _ mid: Double) -> Bool {
            while cursor < spans.count, spans[cursor].1 <= mid { cursor += 1 }
            return cursor < spans.count && spans[cursor].0 <= mid
        }
        for index in times.indices.dropLast() {
            let start = times[index], end = times[index + 1], mid = (start + end) / 2
            guard end > start else { continue }
            if active(unscored, &zoneCursor, mid) { continue }
            let r = refSpeakers.indices.filter { active(ref[refSpeakers[$0]]!, &refCursor[$0], mid) }
            let h = hypSpeakers.indices.filter { active(hyp[hypSpeakers[$0]]!, &hypCursor[$0], mid) }
            if r.isEmpty && h.isEmpty { continue }
            if ignoringOverlap && r.count > 1 { continue }
            pieces.append(Piece(duration: end - start, ref: r, hyp: h))
        }

        var overlap = [[Double]](repeating: [Double](repeating: 0, count: hypSpeakers.count), count: refSpeakers.count)
        var refDuration = [Double](repeating: 0, count: refSpeakers.count), hypDuration = [Double](repeating: 0, count: hypSpeakers.count)
        for piece in pieces {
            for r in piece.ref { refDuration[r] += piece.duration; for h in piece.hyp { overlap[r][h] += piece.duration } }
            for h in piece.hyp { hypDuration[h] += piece.duration }
        }

        // DER mapping: maximize matched time.
        let size = max(refSpeakers.count, hypSpeakers.count)
        var mappedHyp = [Int?](repeating: nil, count: hypSpeakers.count)   // hyp index → ref index
        var mapping: [String: String] = [:]
        if size > 0 {
            let cost = (0..<size).map { r in (0..<size).map { h in r < refSpeakers.count && h < hypSpeakers.count ? -overlap[r][h] : 0 } }
            for (r, h) in Hungarian.minimize(cost).enumerated() where r < refSpeakers.count && h < hypSpeakers.count && overlap[r][h] > 0 {
                mappedHyp[h] = r
                mapping[refSpeakers[r]] = hypSpeakers[h]
            }
        }
        var result = Result(referenceSeconds: 0, missedSeconds: 0, falseAlarmSeconds: 0, confusionSeconds: 0, mapping: mapping,
                            jaccardErrorRate: nil, referenceSpeakers: refSpeakers.count, hypothesisSpeakers: hypSpeakers.count)
        for piece in pieces {
            let nRef = Double(piece.ref.count), nHyp = Double(piece.hyp.count)
            let correct = Double(piece.hyp.filter { h in mappedHyp[h].map { piece.ref.contains($0) } ?? false }.count)
            result.referenceSeconds += piece.duration * nRef
            result.missedSeconds += piece.duration * max(0, nRef - nHyp)
            result.falseAlarmSeconds += piece.duration * max(0, nHyp - nRef)
            result.confusionSeconds += piece.duration * (min(nRef, nHyp) - correct)
        }

        // JER mapping: minimize per-speaker Jaccard error; unmatched reference speakers count 1.
        if !refSpeakers.isEmpty {
            func jaccard(_ r: Int, _ h: Int) -> Double {
                let union = refDuration[r] + hypDuration[h] - overlap[r][h]
                return union > 0 ? 1 - overlap[r][h] / union : 1
            }
            let cost = (0..<size).map { r in (0..<size).map { h in r < refSpeakers.count && h < hypSpeakers.count ? jaccard(r, h) : 1 } }
            var errors = [Double](repeating: 1, count: refSpeakers.count)
            for (r, h) in Hungarian.minimize(cost).enumerated() where r < refSpeakers.count && h < hypSpeakers.count {
                errors[r] = jaccard(r, h)
            }
            result.jaccardErrorRate = errors.reduce(0, +) / Double(errors.count)
        }
        return result
    }

    /// Each speaker's spans, sorted and merged where they touch or overlap.
    private static func merged(_ spans: [SpeakerSpan]) -> [String: [(Double, Double)]] {
        var bySpeaker: [String: [(Double, Double)]] = [:]
        for span in spans where span.end > span.start && span.start.isFinite && span.end.isFinite {
            bySpeaker[span.speaker, default: []].append((span.start, span.end))
        }
        return bySpeaker.mapValues(union)
    }

    private static func union(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = result.last, span.0 <= last.1 { result[result.count - 1].1 = max(last.1, span.1) }
            else { result.append(span) }
        }
        return result
    }
}

// MARK: - Word timing

/// How far a recognizer's word times are from reference times, over words both agree on: the
/// hypothesis is aligned to the reference (normalized text) and only exact matches are timed.
public enum WordTimingError {
    public struct Result: Codable, Equatable, Sendable {
        public var matchedWords: Int
        public var referenceWords: Int
        public var meanStartError: Double?
        public var meanEndError: Double?
        public var medianStartError: Double?
        /// Share of matched words starting within 0.2 s of the reference.
        public var withinTwoTenths: Double?
    }

    /// `window` seconds of reference per alignment block bounds memory on long recordings.
    public static func measure(reference: [TimedWord], hypothesis: [TimedWord], window: Double = 300) -> Result {
        let ref = normalized(reference), hyp = normalized(hypothesis)
        var startErrors: [Double] = [], endErrors: [Double] = []
        // Blocks of reference words; each hypothesis word goes to the block its midpoint falls in,
        // with block edges halfway between neighbouring reference words.
        var blocks: [Range<Int>] = []
        var first = 0
        for index in ref.indices where index > first && ref[index].start - ref[first].start >= window {
            blocks.append(first..<index); first = index
        }
        if first < ref.count { blocks.append(first..<ref.count) }
        var hypIndex = 0
        for (number, block) in blocks.enumerated() {
            let upper = number + 1 < blocks.count ? (ref[block.upperBound - 1].end + ref[block.upperBound].start) / 2 : .infinity
            var blockHyp: [TimedWord] = []
            while hypIndex < hyp.count, (hyp[hypIndex].start + hyp[hypIndex].end) / 2 < upper { blockHyp.append(hyp[hypIndex]); hypIndex += 1 }
            let blockRef = Array(ref[block])
            for step in WordErrorRate.align(reference: blockRef.map(\.text), hypothesis: blockHyp.map(\.text)) {
                guard case .match(let r, let h) = step else { continue }
                startErrors.append(abs(blockHyp[h].start - blockRef[r].start))
                endErrors.append(abs(blockHyp[h].end - blockRef[r].end))
            }
        }
        guard !startErrors.isEmpty else { return Result(matchedWords: 0, referenceWords: ref.count) }
        let sorted = startErrors.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return Result(matchedWords: startErrors.count, referenceWords: ref.count,
                      meanStartError: startErrors.reduce(0, +) / Double(startErrors.count),
                      meanEndError: endErrors.reduce(0, +) / Double(endErrors.count),
                      medianStartError: median,
                      withinTwoTenths: Double(startErrors.filter { $0 <= 0.2 }.count) / Double(startErrors.count))
    }

    /// Words split and normalized like the text metrics; a word that normalizes into several keeps its span.
    private static func normalized(_ words: [TimedWord]) -> [TimedWord] {
        words.sorted { $0.start < $1.start }.flatMap { word in
            TranscriptNormalizer.words(word.text).map { TimedWord(text: $0, start: word.start, end: word.end) }
        }
    }
}

// MARK: - Assignment

/// Minimum-cost assignment on a square matrix (Kuhn–Munkres, O(n³)). Returns, for each row, its column.
public enum Hungarian {
    public static func minimize(_ cost: [[Double]]) -> [Int] {
        let n = cost.count
        guard n > 0 else { return [] }
        precondition(cost.allSatisfy { $0.count == n }, "Hungarian.minimize needs a square matrix")
        // Potentials formulation (1-indexed), e-maxx.
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minv[j] { minv[j] = current; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var assignment = [Int](repeating: 0, count: n)
        for j in 1...n where p[j] > 0 { assignment[p[j] - 1] = j - 1 }
        return assignment
    }
}
