import Foundation

/// Word normalization shared by the fusion stages.
enum FusionText {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lowercased, diacritic-folded letters and digits only ("Don't," → "dont").
    static func key(_ token: String) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posix)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    /// Whitespace-separated words with their keys. Punctuation-only tokens stay attached to a word.
    static func units(_ text: String) -> [(display: String, key: String)] {
        var result: [(display: String, key: String)] = []
        var leading = ""
        for token in text.split(whereSeparator: \.isWhitespace) {
            let display = String(token), normalized = key(display)
            if normalized.isEmpty {
                if result.isEmpty { leading += leading.isEmpty ? display : " " + display }
                else { result[result.count - 1].display += " " + display }
                continue
            }
            result.append((leading.isEmpty ? display : leading + " " + display, normalized))
            leading = ""
        }
        return result
    }

    /// Words whose loss would invert or change a statement. One recording's version is kept unless
    /// at least two others clearly omit it.
    static let negations: Set<String> = [
        "not", "no", "never", "none", "nobody", "nothing", "nowhere", "neither", "nor", "cannot", "cant", "dont", "doesnt",
        "didnt", "isnt", "arent", "wasnt", "werent", "wont", "wouldnt", "shouldnt", "couldnt", "havent", "hasnt", "hadnt",
        "aint", "mustnt", "neednt", "without"]
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion", "percent", "half", "quarter", "dozen"]
    static func isProtected(_ key: String) -> Bool {
        negations.contains(key) || numberWords.contains(key) || key.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }
}

/// The multi-source fusion pipeline behind `TranscriptFusion.fuse`. One instance per call.
final class MultiSourceFusion {
    private struct Word {
        var display: String
        var key: String
        var start: Double, end: Double
        var localStart: Double, localEnd: Double
        var confidence: Double?
        var segment: Int
        /// True when timed by the recognizer rather than spread evenly over the passage.
        var precise: Bool
        var mid: Double { (start + end) / 2 }
    }

    private struct Source {
        var transcript: TrackTranscript
        var track: RecordingTrack?
        var role: FusionSourceRole
        var alignment: TrackAlignment
        var segments: [TranscriptSegment]
        /// Each segment's span on the meeting timeline.
        var spans: [ClosedRange<Double>] = []
        var words: [Word] = []
        /// Number of words in each segment.
        var passageLengths: [Int] = []
        /// Timing tolerance of this source's words, seconds.
        var tolerance: Double
        /// Lower is more trustworthy timing.
        var precisionRank: Int
        var trackID: UUID { transcript.trackID }
    }

    private struct Entry: Hashable { var source: Int; var word: Int }

    private struct Column {
        var time: Double
        var tolerance: Double
        var entries: [Entry]
        /// Sources that were transcribing here: those without an entry vote for "no word".
        var participants: UInt64
    }

    private struct Fused {
        var column: Int
        var display: String
        var key: String
        var start: Double, end: Double
        var confidence: Double?
        var supporters: [Entry]
        var chosen: Entry
        var score: Double
        /// Each supporting source's share of `score`.
        var scores: [Int: Double]
    }

    private let transcripts: [TrackTranscript]
    private let tracks: [RecordingTrack]
    private let inputs: FusionInputs
    private let trackByID: [UUID: RecordingTrack]

    private var sources: [Source] = []
    private var columns: [Column] = []

    init(transcripts: [TrackTranscript], tracks: [RecordingTrack], inputs: FusionInputs) {
        self.transcripts = transcripts; self.tracks = tracks; self.inputs = inputs
        trackByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func run() -> FusionResult {
        // The latest run per recording, in order of first transcription. The first usable source
        // stays the timeline origin when more recordings are attached.
        var order: [UUID] = []
        for transcript in transcripts where !order.contains(transcript.trackID) { order.append(transcript.trackID) }
        let grouped = Dictionary(grouping: transcripts, by: \.trackID)
        let latest = order.compactMap { id in grouped[id]?.max { $0.createdAt < $1.createdAt } }
        // An original transcribed through a derived copy (the echo-cancelled microphone) is left
        // out, so the call heard through the speakers can't come back via the raw microphone.
        let transcribed = Set(latest.map(\.trackID))
        var supersededBy: [UUID: UUID] = [:]
        for track in tracks { if let original = track.derivedFrom, transcribed.contains(track.id) { supersededBy[original] = track.id } }
        let candidates = latest.filter { supersededBy[$0.trackID] == nil }
        let ordered = candidates.filter { !TranscriptFusion.valid($0.segments).isEmpty } + candidates.filter { TranscriptFusion.valid($0.segments).isEmpty }
        guard let reference = ordered.first else { return FusionResult(segments: [], alignments: []) }

        let placements = resolveTimeline(ordered: ordered, reference: reference)
        var alignments = ordered.compactMap { placements[$0.trackID] }
        for transcript in latest where supersededBy[transcript.trackID] != nil {
            let derived = supersededBy[transcript.trackID]!
            var report = placements[derived] ?? TrackAlignment(trackID: derived, method: .unaligned)
            report.trackID = transcript.trackID
            report.explanation = "Transcribed through its processed copy, which shares its timing; its own transcript isn't fused."
            alignments.append(report)
        }

        // Sources in fusion order: the call first (cleanest for remote speech), then the
        // microphone, then room recorders; otherwise by first transcription.
        func priority(_ role: FusionSourceRole) -> Int {
            switch role { case .call: return 0; case .microphone: return 1; case .room, .unknown: return 2 }
        }
        let placed = ordered.enumerated().filter { placements[$0.element.trackID].map { $0.method != .unaligned } ?? false }
            .filter { !TranscriptFusion.valid($0.element.segments).isEmpty }
            .sorted { lhs, rhs in
                let a = priority(FusionSourceRole(trackByID[lhs.element.trackID]?.source))
                let b = priority(FusionSourceRole(trackByID[rhs.element.trackID]?.source))
                return a == b ? lhs.offset < rhs.offset : a < b
            }.map(\.element).prefix(64)
        sources = placed.map { makeSource($0, placements: placements) }
        for index in sources.indices { integrate(index) }
        let (outputs, summary, added) = output()
        let reports = buildReports(summary: summary, latest: latest, supersededBy: supersededBy, placements: placements)
        var finalSummary = summary
        finalSummary.sources = reports
        return FusionResult(segments: outputs, alignments: alignments, summary: finalSummary, addedSpeakers: added)
    }

    // MARK: Timeline

    private func explicitOffset(_ transcript: TrackTranscript) -> Double? {
        let track = trackByID[transcript.trackID]
        let value = transcript.knownOffset ?? track?.offset ?? track?.derivedFrom.flatMap { trackByID[$0]?.offset }
        return value?.isFinite == true ? value : nil
    }

    /// Tracks sharing one clock: a recording and the copies derived from it.
    private func clockGroup(_ id: UUID) -> Set<UUID> {
        var group: Set<UUID> = [id]
        if let original = trackByID[id]?.derivedFrom { group.insert(original) }
        for track in tracks where track.derivedFrom != nil && group.contains(track.derivedFrom!) { group.insert(track.id) }
        return group
    }

    private func resolveTimeline(ordered: [TrackTranscript], reference: TrackTranscript) -> [UUID: TrackAlignment] {
        var result: [UUID: TrackAlignment] = [:]
        var clocks: [UUID: (offset: Double, rate: Double)] = [:]
        func place(_ alignment: TrackAlignment) {
            result[alignment.trackID] = alignment
            for id in clockGroup(alignment.trackID) where clocks[id] == nil { clocks[id] = (alignment.offset, alignment.rate) }
        }
        let given = inputs.placements.filter { $0.value.offset.isFinite && $0.value.rate.isFinite && $0.value.rate > 0 }
        func placement(_ id: UUID) -> TrackPlacement? {
            given[id] ?? trackByID[id]?.derivedFrom.flatMap { given[$0] }
        }
        let origin = placement(reference.trackID)
        place(TrackAlignment(trackID: reference.trackID, method: .reference, offset: origin?.offset ?? explicitOffset(reference) ?? 0,
                             rate: origin?.rate ?? 1, explanation: "Reference recording for the meeting timeline."))
        for transcript in ordered.dropFirst() {
            if let decided = placement(transcript.trackID) {
                let method: TrackAlignment.Method = [.reference, .unaligned].contains(decided.method) ? .provided : decided.method
                place(TrackAlignment(trackID: transcript.trackID, method: method, offset: decided.offset, rate: decided.rate,
                                     explanation: decided.explanation ?? "Timing established before fusion.",
                                     confidence: decided.confidence, referenceTrackID: decided.referenceTrackID))
            } else if let offset = explicitOffset(transcript) {
                place(TrackAlignment(trackID: transcript.trackID, method: .provided, offset: offset,
                                     explanation: "Timing established by recording capture or manual alignment.", confidence: 1))
            }
        }
        var remaining = ordered.dropFirst().filter { result[$0.trackID] == nil }
        while !remaining.isEmpty {
            var progressed = false
            for transcript in remaining {
                if let alignment = audioPlacement(transcript.trackID, clocks: clocks) { place(alignment); progressed = true }
            }
            remaining = remaining.filter { result[$0.trackID] == nil }
            if progressed { continue }
            // Shared phrases, against each recording already placed (the best fit wins).
            for transcript in remaining {
                let segments = TranscriptFusion.valid(transcript.segments)
                var best: TrackAlignment?
                for other in ordered where other.trackID != transcript.trackID {
                    guard let clock = clocks[other.trackID], result[other.trackID] != nil else { continue }
                    let placedSegments = TranscriptFusion.valid(other.segments).map { segment -> TranscriptSegment in
                        var copy = segment
                        copy.start = segment.start * clock.rate + clock.offset; copy.end = segment.end * clock.rate + clock.offset
                        return copy
                    }
                    var estimate = TranscriptFusion.estimate(segments, reference: placedSegments, trackID: transcript.trackID, referenceOffset: 0)
                    guard estimate.method == .anchors else { continue }
                    estimate.referenceTrackID = other.trackID == reference.trackID ? nil : other.trackID
                    if best == nil || estimate.matchedAnchors > best!.matchedAnchors
                        || (estimate.matchedAnchors == best!.matchedAnchors && (estimate.residual ?? 0) < (best!.residual ?? 0)) {
                        best = estimate
                    }
                }
                if let best { place(best); progressed = true }
            }
            remaining = remaining.filter { result[$0.trackID] == nil }
            if !progressed { break }
        }
        // Wall-clock starts: the weakest evidence, for recordings that share neither sound nor words.
        for transcript in remaining {
            guard let date = inputs.recordingStartDates[transcript.trackID] else { continue }
            guard let anchor = ordered.first(where: { clocks[$0.trackID] != nil && inputs.recordingStartDates[$0.trackID] != nil }),
                  let clock = clocks[anchor.trackID], let anchorDate = inputs.recordingStartDates[anchor.trackID] else { continue }
            let offset = clock.offset + clock.rate * date.timeIntervalSince(anchorDate)
            guard offset.isFinite else { continue }
            place(TrackAlignment(trackID: transcript.trackID, method: .timestamps, offset: offset, rate: clock.rate,
                                 explanation: "Placed only by the recordings’ start times, which can be off by seconds or minutes. Adjust timing if passages look out of place.",
                                 confidence: 0.2, referenceTrackID: anchor.trackID))
        }
        for transcript in ordered where result[transcript.trackID] == nil {
            result[transcript.trackID] = TrackAlignment(trackID: transcript.trackID, method: .unaligned,
                explanation: "Insufficient consistent shared sound or phrases. Original transcript retained separately; set a verified time offset to combine it.")
        }
        return result
    }

    /// The most confident usable audio measurement linking this recording to a placed one.
    private func audioPlacement(_ id: UUID, clocks: [UUID: (offset: Double, rate: Double)]) -> TrackAlignment? {
        let group = clockGroup(id)
        func digestMatches(_ trackID: UUID, _ digest: String) -> Bool {
            guard let stored = trackByID[trackID]?.sha256, !stored.isEmpty, !digest.isEmpty else { return true }
            return stored == digest
        }
        var best: TrackAlignment?
        for record in inputs.audioAlignments {
            guard let measured = record.alignment, measured.confidence >= inputs.options.minimumAudioConfidence,
                  measured.rate > 0, measured.rate.isFinite, measured.offset.isFinite,
                  digestMatches(record.trackID, record.trackDigest), digestMatches(record.referenceTrackID, record.referenceDigest) else { continue }
            var offset: Double, rate: Double, referenceID: UUID
            if group.contains(record.trackID), !group.contains(record.referenceTrackID), let clock = clocks[record.referenceTrackID] {
                // reference = o + r·this; meeting = O + R·reference.
                offset = clock.offset + clock.rate * measured.offset; rate = clock.rate * measured.rate; referenceID = record.referenceTrackID
            } else if group.contains(record.referenceTrackID), !group.contains(record.trackID), let clock = clocks[record.trackID] {
                // other = (this − o) / r; meeting = O + R·other.
                offset = clock.offset - clock.rate * measured.offset / measured.rate; rate = clock.rate / measured.rate; referenceID = record.trackID
            } else { continue }
            guard best == nil || measured.confidence > best!.confidence ?? 0 else { continue }
            let ppm = (rate - 1) * 1_000_000
            best = TrackAlignment(trackID: id, method: .audio, offset: offset, rate: rate, residual: nil,
                                  explanation: String(format: "Lined up from the recordings’ sound (confidence %.2f, clock drift %.0f ppm).", measured.confidence, ppm),
                                  confidence: measured.confidence, referenceTrackID: referenceID)
        }
        return best
    }

    // MARK: Words

    private func makeSource(_ transcript: TrackTranscript, placements: [UUID: TrackAlignment]) -> Source {
        let alignment = placements[transcript.trackID]!
        let track = trackByID[transcript.trackID]
        let segments = TranscriptFusion.valid(transcript.segments).enumerated()
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }.map(\.element)
        let tolerance: Double, rank: Int
        switch alignment.method {
        case .reference, .provided: tolerance = 0.3; rank = 0
        case .audio: tolerance = 0.3 + 0.2 * (1 - (alignment.confidence ?? 0.5)); rank = 1
        case .anchors: tolerance = max(0.6, alignment.residual ?? 1); rank = 2
        case .timestamps: tolerance = 2.5; rank = 3
        case .unaligned: tolerance = 2.5; rank = 4
        }
        var source = Source(transcript: transcript, track: track, role: FusionSourceRole(track?.source), alignment: alignment,
                            segments: segments, tolerance: tolerance, precisionRank: rank)
        let timed = (transcript.words ?? []).filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }.sorted { $0.start < $1.start }
        let starts = timed.map(\.start)
        func meeting(_ time: Double) -> Double { time * alignment.rate + alignment.offset }
        for (index, segment) in segments.enumerated() {
            source.spans.append(meeting(segment.start)...max(meeting(segment.start), meeting(segment.end)))
            let units = FusionText.units(segment.text)
            guard !units.isEmpty else { continue }
            // A caller may hand over segments already rescaled, citing their original times in a
            // provenance entry for themselves: word timings and provenance use the original clock,
            // and the segment's own times map onto it linearly.
            var own = (start: segment.start, end: segment.end)
            if segment.provenance.count == 1, let cited = segment.provenance.first, cited.segmentID == segment.id,
               cited.trackID == segment.trackID, cited.start.isFinite, cited.end.isFinite, cited.end >= cited.start {
                own = (cited.start, cited.end)
            }
            let span = own.end - own.start
            func given(_ time: Double) -> Double {
                span > 0 ? segment.start + (time - own.start) * (segment.end - segment.start) / span : segment.start + (time - own.start)
            }
            // Recognizer word timings when they spell exactly this passage.
            var placedWords: [Word]?
            if !timed.isEmpty {
                var lo = 0, hi = starts.count
                while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < own.start - 0.05 { lo = mid + 1 } else { hi = mid } }
                var pieces: [(display: String, key: String, start: Double, end: Double, confidence: Double?)] = []
                var cursor = lo
                while cursor < timed.count, timed[cursor].start <= own.end + 0.05 {
                    let word = timed[cursor]
                    let parts = FusionText.units(word.text)
                    for (offset, part) in parts.enumerated() {
                        let share = (word.end - word.start) / Double(parts.count)
                        pieces.append((part.display, part.key, word.start + share * Double(offset), word.start + share * Double(offset + 1), word.confidence))
                    }
                    cursor += 1
                }
                if pieces.map(\.key) == units.map(\.key) {
                    placedWords = zip(units, pieces).map { unit, piece in
                        Word(display: unit.display, key: unit.key, start: meeting(given(piece.start)), end: meeting(given(piece.end)),
                             localStart: piece.start, localEnd: piece.end, confidence: piece.confidence ?? segment.confidence,
                             segment: index, precise: true)
                    }
                }
            }
            if placedWords == nil {
                // Spread evenly by length over the passage.
                let weights = units.map { Double($0.display.count + 1) }
                let total = weights.reduce(0, +)
                var cursor = own.start
                placedWords = units.enumerated().map { offset, unit in
                    let length = span * weights[offset] / total
                    defer { cursor += length }
                    return Word(display: unit.display, key: unit.key, start: meeting(given(cursor)), end: meeting(given(cursor + length)),
                                localStart: cursor, localEnd: cursor + length, confidence: segment.confidence, segment: index, precise: false)
                }
            }
            source.words += placedWords!
        }
        source.passageLengths = [Int](repeating: 0, count: segments.count)
        for word in source.words { source.passageLengths[word.segment] += 1 }
        return source
    }


    private func tolerance(_ source: Int, _ word: Word) -> Double {
        sources[source].tolerance + (word.precise ? 0 : 0.75)
    }

    // MARK: Word transition network

    private enum Step { case both(Int, Int), word(Int), column(Int) }

    /// Adds one source's words to the network: aligned with the existing columns by
    /// time-constrained edit distance, then joined where they repeat speech already there, or kept
    /// as distinct speech (someone else talking at the same time).
    private func integrate(_ s: Int) {
        let words = sources[s].words
        guard !columns.isEmpty else {
            columns = words.indices.map { Column(time: words[$0].mid, tolerance: tolerance(s, words[$0]),
                                                 entries: [Entry(source: s, word: $0)], participants: UInt64(1) << UInt64(s)) }
            var time = -Double.infinity
            for index in columns.indices { time = max(time, columns[index].time); columns[index].time = time }
            return
        }
        var output: [Column] = []
        output.reserveCapacity(columns.count + words.count)
        for region in regions(source: s) {
            output += align(source: s, words: region.words, columns: Array(columns[region.columns]))
        }
        columns = output
    }

    /// Cuts the timeline where no match can cross (gaps wider than any tolerance) and every 240
    /// items, so each alignment table stays small.
    private func regions(source s: Int) -> [(words: Range<Int>, columns: Range<Int>)] {
        let words = sources[s].words
        let gap = (words.map { tolerance(s, $0) }.max() ?? 0) + (columns.map(\.tolerance).max() ?? 0)
        var cuts: [(word: Int, column: Int)] = [(0, 0)]
        var i = 0, j = 0, inRegion = (words: 0, columns: 0)
        var lastTime = -Double.infinity
        while i < words.count || j < columns.count {
            let wordTime = i < words.count ? words[i].mid : .infinity
            let columnTime = j < columns.count ? columns[j].time : .infinity
            let time = min(wordTime, columnTime)
            if inRegion.words + inRegion.columns > 0 && (time - lastTime > gap || inRegion.words >= 240 || inRegion.columns >= 240) {
                cuts.append((i, j)); inRegion = (0, 0)
            }
            if wordTime <= columnTime { i += 1; inRegion.words += 1 } else { j += 1; inRegion.columns += 1 }
            lastTime = max(lastTime, time)
        }
        cuts.append((words.count, columns.count))
        return zip(cuts, cuts.dropFirst()).map { ($0.word..<$1.word, $0.column..<$1.column) }.filter { !$0.0.isEmpty || !$0.1.isEmpty }
    }

    private func align(source s: Int, words range: Range<Int>, columns region: [Column]) -> [Column] {
        let bit = UInt64(1) << UInt64(s)
        let all = sources[s].words
        let words = Array(all[range])
        let n = words.count, m = region.count
        func entry(_ w: Int) -> Entry { Entry(source: s, word: range.lowerBound + w) }
        var output: [Column] = []
        var lastTime = -Double.infinity
        func append(_ column: Column) {
            var column = column
            column.time = max(column.time, lastTime)
            lastTime = column.time
            output.append(column)
        }
        func distinct(_ w: Int) -> Column {
            Column(time: words[w].mid, tolerance: tolerance(s, words[w]), entries: [entry(w)], participants: bit)
        }
        guard m > 0 else { words.indices.forEach { append(distinct($0)) }; return output }
        guard n > 0 else { region.forEach(append); return output }

        let columnKeys = region.map { Set($0.entries.map { sources[$0.source].words[$0.word].key }) }
        func limit(_ w: Int, _ c: Int) -> Double { tolerance(s, words[w]) + region[c].tolerance }
        func compatible(_ w: Int, _ c: Int) -> Bool { abs(words[w].mid - region[c].time) <= limit(w, c) }
        // Edit distance; a word may only pair with a column at a compatible time.
        let width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        var back = [UInt8](repeating: 2, count: (n + 1) * width)
        for c in 0...m { cost[c] = Int32(c) }
        for w in 1...n {
            cost[w * width] = Int32(w); back[w * width] = 1
            for c in 1...m {
                var best = cost[(w - 1) * width + c] + 1, direction: UInt8 = 1
                let left = cost[w * width + c - 1] + 1
                if left < best { best = left; direction = 2 }
                if compatible(w - 1, c - 1) {
                    let diagonal = cost[(w - 1) * width + c - 1] + (columnKeys[c - 1].contains(words[w - 1].key) ? 0 : 1)
                    if diagonal <= best { best = diagonal; direction = 0 }
                }
                cost[w * width + c] = best; back[w * width + c] = direction
            }
        }
        var steps: [Step] = []
        var w = n, c = m
        while w > 0 || c > 0 {
            switch back[w * width + c] {
            case 0: steps.append(.both(w - 1, c - 1)); w -= 1; c -= 1
            case 1: steps.append(.word(w - 1)); w -= 1
            default: steps.append(.column(c - 1)); c -= 1
            }
        }
        steps.reverse()

        // Decide which of this source's words repeat speech already in the network.
        var columnOf = [Int?](repeating: nil, count: n)
        var exact = [Bool](repeating: false, count: n)
        for step in steps { if case .both(let w, let c) = step { columnOf[w] = c; exact[w] = columnKeys[c].contains(words[w].key) } }
        func unique(_ w: Int, _ c: Int) -> Bool {
            let key = words[w].key
            return !region.indices.contains { $0 != c && columnKeys[$0].contains(key) && compatible(w, $0) }
                && !words.indices.contains { $0 != w && words[$0].key == key && abs(words[$0].mid - region[c].time) <= limit($0, c) }
        }
        func tight(_ w: Int, _ c: Int) -> Bool { abs(words[w].mid - region[c].time) <= limit(w, c) / 2 }
        let passages = Dictionary(grouping: words.indices, by: { words[$0].segment })
        var anchored = [Bool](repeating: false, count: n)
        for (segment, members) in passages {
            let passageLength = sources[s].passageLengths[segment]
            if passageLength < 4 {
                // Short replies ("yes", "okay") join only an unambiguous, closely timed counterpart:
                // two people can answer at once.
                if members.count == passageLength, members.allSatisfy({ exact[$0] && tight($0, columnOf[$0]!) && unique($0, columnOf[$0]!) }) {
                    members.forEach { anchored[$0] = true }
                }
                continue
            }
            // Someone talking over another person can share a few common words by chance; a repeat
            // of the same speech matches much more of it.
            let matches = members.filter { exact[$0] }.count
            guard matches >= 2, Double(matches) >= 0.3 * Double(members.count) else { continue }
            for w in members where exact[w] {
                let neighbour = members.contains(w - 1) && exact[w - 1] || members.contains(w + 1) && exact[w + 1]
                if neighbour || (words[w].key.count >= 2 && tight(w, columnOf[w]!) && unique(w, columnOf[w]!)) { anchored[w] = true }
            }
            let sorted = members.sorted()
            let seeds = sorted.filter { anchored[$0] }
            guard let first = seeds.first, let last = seeds.last else { continue }
            // Words between nearby matches belong to the same speech (substitutions, insertions).
            for (a, b) in zip(seeds, seeds.dropFirst()) where b - a <= 9 { for w in (a + 1)..<b { anchored[w] = true } }
            // Leading or trailing words fall inside the other sources' passages: they were
            // transcribing then and heard no such words, so these are voted on too.
            var covered: ClosedRange<Double>?
            for w in seeds {
                for other in region[columnOf[w]!].entries where other.source != s {
                    let span = sources[other.source].spans[sources[other.source].words[other.word].segment]
                    covered = covered.map { min($0.lowerBound, span.lowerBound)...max($0.upperBound, span.upperBound) } ?? span
                }
            }
            guard let span = covered else { continue }
            func inside(_ w: Int) -> Bool { words[w].mid >= span.lowerBound - 0.3 && words[w].mid <= span.upperBound + 0.3 }
            var w = first - 1
            while w >= sorted[0], inside(w) { anchored[w] = true; w -= 1 }
            w = last + 1
            while w <= sorted[sorted.count - 1], inside(w) { anchored[w] = true; w += 1 }
        }

        // Merge in alignment order.
        var originals: [Int] = []
        var inserted: [Int] = []
        var position = [Int?](repeating: nil, count: n)
        for step in steps {
            switch step {
            case .both(let w, let c):
                var column = region[c]
                if anchored[w] {
                    column.entries.append(entry(w))
                    column.tolerance = min(column.tolerance, tolerance(s, words[w]))
                    position[w] = output.count
                    originals.append(output.count); append(column)
                } else {
                    originals.append(output.count); append(column)
                    append(distinct(w))
                }
            case .word(let w):
                if anchored[w] {
                    position[w] = output.count; inserted.append(output.count)
                    append(Column(time: words[w].mid, tolerance: tolerance(s, words[w]), entries: [entry(w)], participants: bit))
                } else {
                    append(distinct(w))
                }
            case .column(let c):
                originals.append(output.count); append(region[c])
            }
        }
        // An inserted word is voted on by the sources transcribing on both sides of it.
        for index in inserted {
            let before = originals.last { $0 < index }.map { output[$0].participants }
            let after = originals.first { $0 > index }.map { output[$0].participants }
            output[index].participants = ((before ?? after ?? 0) & (after ?? before ?? 0)) | bit
        }
        // Inside each anchored stretch of one passage, this source votes "no word" where it has none.
        var stretch: (start: Int, end: Int)?
        for w in 0..<n {
            guard let at = position[w] else {
                if let open = stretch { for index in open.start...open.end { output[index].participants |= bit } }
                stretch = nil; continue
            }
            if let open = stretch, w > 0, words[w].segment == words[w - 1].segment, position[w - 1] != nil {
                stretch = (open.start, max(open.end, at))
            } else {
                if let open = stretch { for index in open.start...open.end { output[index].participants |= bit } }
                stretch = (at, at)
            }
        }
        if let open = stretch { for index in open.start...open.end { output[index].participants |= bit } }
        return output
    }

    // MARK: Voting

    /// How much a source's word counts. Remote speech: the call audio is the original signal;
    /// local speech: the microphone (echo-cancelled when available) is closest to the owner.
    /// Scaled by signal-to-noise ratio when measured, and by how the source was placed.
    private func weight(_ s: Int, callSpeech: Bool, localTime: Double) -> Double {
        var value: Double
        switch sources[s].role {
        case .call: value = callSpeech ? 1 : 0.6
        case .microphone: value = callSpeech ? 0.5 : 1
        case .room: value = callSpeech ? 0.5 : 0.8
        case .unknown: value = 1
        }
        if let profile = inputs.signalQuality[sources[s].trackID], let snr = profile.snr(at: localTime) {
            value *= min(1, max(0.3, 0.3 + 0.7 * Double(snr - 5) / 25))
        }
        switch sources[s].alignment.method {
        case .anchors: value *= 0.9
        case .timestamps: value *= 0.6
        default: break
        }
        return value
    }

    private func localTime(_ s: Int, meeting time: Double) -> Double {
        let alignment = sources[s].alignment
        return alignment.rate > 0 ? (time - alignment.offset) / alignment.rate : time
    }

    /// ROVER-style vote per column. Each source scores weight × (0.5 + 0.5 × confidence); sources
    /// that were transcribing but heard no word vote for nothing at confidence 0.5. A negation or
    /// number, or part of a run of three or more words only one source heard, is dropped only when
    /// at least two sources outvote it.
    private func vote() -> (words: [Fused?], disputed: Int) {
        var callMask: UInt64 = 0
        for s in sources.indices where sources[s].role == .call { callMask |= UInt64(1) << UInt64(s) }
        var lone = [Int?](repeating: nil, count: columns.count)
        for (index, column) in columns.enumerated() where column.entries.count == 1 {
            let s = column.entries[0].source
            if column.participants & ~(UInt64(1) << UInt64(s)) != 0 { lone[index] = s }
        }
        var inRun = [Bool](repeating: false, count: columns.count)
        var start = 0
        while start < columns.count {
            guard let s = lone[start] else { start += 1; continue }
            var end = start
            while end + 1 < columns.count, lone[end + 1] == s { end += 1 }
            if end - start >= 2 { for index in start...end { inRun[index] = true } }
            start = end + 1
        }
        var result = [Fused?](repeating: nil, count: columns.count)
        var disputed = 0
        for (index, column) in columns.enumerated() {
            let present = column.entries.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64($1.source)) }
            let callSpeech = (present | column.participants) & callMask != 0
            var order: [String] = []
            var tallies: [String: (score: Double, supporters: [Entry], best: Entry, bestScore: Double, scores: [Int: Double])] = [:]
            for entry in column.entries {
                let word = sources[entry.source].words[entry.word]
                let score = weight(entry.source, callSpeech: callSpeech, localTime: (word.localStart + word.localEnd) / 2)
                    * (0.5 + 0.5 * (word.confidence ?? 0.7))
                if var tally = tallies[word.key] {
                    tally.score += score; tally.supporters.append(entry); tally.scores[entry.source, default: 0] += score
                    if score > tally.bestScore { tally.best = entry; tally.bestScore = score }
                    tallies[word.key] = tally
                } else {
                    tallies[word.key] = (score, [entry], entry, score, [entry.source: score]); order.append(word.key)
                }
            }
            let silent = sources.indices.filter { column.participants & (UInt64(1) << UInt64($0)) != 0 && present & (UInt64(1) << UInt64($0)) == 0 }
            let silentScore = silent.reduce(0.0) { $0 + weight($1, callSpeech: callSpeech, localTime: localTime($1, meeting: column.time)) * 0.75 }
            if tallies.count > 1 || (!silent.isEmpty && !tallies.isEmpty) { disputed += 1 }
            let ranked = order.sorted { a, b in
                let x = tallies[a]!, y = tallies[b]!
                if x.score != y.score { return x.score > y.score }
                if x.supporters.count != y.supporters.count { return x.supporters.count > y.supporters.count }
                return (x.supporters.map(\.source).min() ?? 0) < (y.supporters.map(\.source).min() ?? 0)
            }
            guard let key = ranked.first, let tally = tallies[key] else { continue }
            if tally.score < silentScore {
                let protected = FusionText.isProtected(key) || inRun[index]
                guard protected && silent.count < 2 else { continue }
            }
            let timing = tally.supporters.min { a, b in
                let x = sources[a.source], y = sources[b.source]
                let wx = x.words[a.word], wy = y.words[b.word]
                return (x.precisionRank, wx.precise ? 0 : 1, a.source) < (y.precisionRank, wy.precise ? 0 : 1, b.source)
            }!
            let timed = sources[timing.source].words[timing.word]
            let chosen = sources[tally.best.source].words[tally.best.word]
            let confidence = tally.supporters.compactMap { sources[$0.source].words[$0.word].confidence }.max()
            result[index] = Fused(column: index, display: chosen.display, key: key, start: timed.start, end: timed.end,
                                  confidence: confidence, supporters: tally.supporters, chosen: tally.best, score: tally.score,
                                  scores: tally.scores)
        }
        return (result, disputed)
    }

    // MARK: Speakers

    private func rawLabel(_ entry: Entry) -> String? {
        let source = sources[entry.source]
        return source.segments[source.words[entry.word].segment].speakerID
    }

    /// Speaker per column. Sources are labelled in fusion order: call audio keeps its own speakers
    /// (remote participants); later sources' labels are mapped onto speakers already established
    /// where both heard the same words; on the microphone, the dominant voice absent from the call
    /// becomes the owner. A column takes the label of its earliest labelled source.
    private func speakerLabels() -> (labels: [String?], mappings: [FusionSpeakerMapping], owner: String?, ownerTrack: UUID?) {
        var labels = [String?](repeating: nil, count: columns.count)
        var mappings: [FusionSpeakerMapping] = []
        var owner: String?, ownerTrack: UUID?
        var established = Set<String>()
        var callMask: UInt64 = 0
        for s in sources.indices where sources[s].role == .call { callMask |= UInt64(1) << UInt64(s) }
        let callLabels = Set(sources.indices.filter { sources[$0].role == .call }
            .flatMap { s in sources[s].segments.compactMap(\.speakerID) })
        for s in sources.indices {
            let own = columns.indices.compactMap { index in columns[index].entries.first { $0.source == s }.map { (index, $0) } }
            var map: [String: String] = [:]
            let none = "\u{0}none"
            func key(_ label: String?) -> String { label ?? none }
            if sources[s].role != .call {
                var observations: [SpeakerCooccurrence] = []
                var tallies: [String: [String: Double]] = [:]
                for (index, entry) in own {
                    guard let target = labels[index] else { continue }
                    tallies[key(rawLabel(entry)), default: [:]][target, default: 0] += 1
                }
                for (label, targets) in tallies {
                    if label != none, inputs.namedSpeakerIDs.contains(label) || established.contains(label) { continue }
                    observations += targets.map { SpeakerCooccurrence(sourceSpeakerID: label, targetSpeakerID: $0.key, weight: $0.value) }
                }
                for match in SpeakerMatcher.matchByCooccurrence(observations) {
                    guard let target = match.targetSpeakerID else { continue }
                    map[match.sourceSpeakerID] = target
                    mappings.append(FusionSpeakerMapping(sourceSpeakerID: match.sourceSpeakerID == none ? nil : match.sourceSpeakerID,
                                                         trackID: sources[s].trackID, speakerID: target, reason: .sharedSpeech,
                                                         share: match.similarity ?? 0))
                }
                if sources[s].role == .microphone, callMask != 0, owner == nil {
                    // Local speech: microphone words the call didn't carry, not mapped to a remote voice.
                    var local: [String: Double] = [:]
                    for (index, entry) in own where columns[index].entries.allSatisfy({ callMask & (UInt64(1) << UInt64($0.source)) == 0 }) {
                        let label = key(rawLabel(entry))
                        if let mapped = map[label], callLabels.contains(mapped) { continue }
                        local[label, default: 0] += 1
                    }
                    let total = local.values.reduce(0, +)
                    if let dominant = local.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }),
                       total > 0, dominant.value / total >= 0.7 {
                        let identity = dominant.key != none && inputs.namedSpeakerIDs.contains(dominant.key) ? dominant.key : inputs.options.ownerSpeakerID
                        owner = identity; ownerTrack = sources[s].trackID
                        map[dominant.key] = identity
                        mappings.removeAll { $0.trackID == sources[s].trackID && $0.sourceSpeakerID == (dominant.key == none ? nil : dominant.key) }
                        mappings.append(FusionSpeakerMapping(sourceSpeakerID: dominant.key == none ? nil : dominant.key, trackID: sources[s].trackID,
                                                             speakerID: identity, reason: .owner, share: dominant.value / total))
                    }
                }
            }
            for (index, entry) in own where labels[index] == nil {
                let raw = rawLabel(entry)
                labels[index] = map[key(raw)] ?? raw
            }
            for segment in sources[s].segments { if let label = segment.speakerID { established.insert(map[label] ?? label) } }
            for target in map.values { established.insert(target) }
        }
        return (labels, mappings, owner, ownerTrack)
    }

    // MARK: Output

    private struct Home: Hashable { var source: Int; var segment: Int }

    private func output() -> ([TranscriptSegment], FusionSummary, [Speaker]) {
        let (fused, disputed) = vote()
        let (labels, mappings, owner, ownerTrack) = speakerLabels()
        // A column belongs to the passage of its earliest source. A word inserted inside another
        // source's passage (that source voted there but heard nothing) joins that passage.
        var homes = [Home?](repeating: nil, count: columns.count)
        var inherits = [Int?](repeating: nil, count: columns.count)
        for (index, column) in columns.enumerated() {
            guard let first = column.entries.min(by: { $0.source < $1.source }) else { continue }
            homes[index] = Home(source: first.source, segment: sources[first.source].words[first.word].segment)
            let earliestVoter = column.participants.trailingZeroBitCount
            if earliestVoter < first.source { inherits[index] = earliestVoter }
        }
        for index in columns.indices {
            guard let voter = inherits[index] else { continue }
            let nearby = (1...12).lazy.flatMap { distance in [index - distance, index + distance] }
                .first { $0 >= 0 && $0 < self.columns.count && inherits[$0] == nil && homes[$0]?.source == voter }
            if let neighbour = nearby { homes[index] = homes[neighbour] }
        }
        var groups: [Home: [Int]] = [:]
        var groupOrder: [Home] = []
        for index in columns.indices {
            guard let home = homes[index] else { continue }
            if groups[home] == nil { groupOrder.append(home) }
            groups[home, default: []].append(index)
        }
        var segments: [TranscriptSegment] = []
        for home in groupOrder {
            let members = groups[home]!
            let source = sources[home.source]
            let original = source.segments[home.segment]
            let kept = members.filter { fused[$0] != nil }
            guard !kept.isEmpty else { continue }
            let wordsInPassage = source.passageLengths[home.segment]
            let alone = members.allSatisfy { columns[$0].entries.allSatisfy { $0.source == home.source } }
            if alone && kept.count == members.count && members.count == wordsInPassage {
                // Only this recording heard it: keep the passage exactly as transcribed.
                var copy = original
                copy.start = original.start * source.alignment.rate + source.alignment.offset
                copy.end = original.end * source.alignment.rate + source.alignment.offset
                if copy.provenance.isEmpty {
                    copy.provenance = [SegmentProvenance(trackID: original.trackID, segmentID: original.id, start: original.start,
                                                         end: original.end, text: original.text, confidence: original.confidence)]
                }
                copy.speakerID = mostCommon(kept.map { labels[$0] }) ?? original.speakerID
                segments.append(copy)
                continue
            }
            // Speaker per word: unknown labels follow their neighbours, and brief flips inside one
            // passage (a word only another source heard) follow the surrounding speaker.
            var wordLabels = kept.map { labels[$0] }
            for index in wordLabels.indices where wordLabels[index] == nil {
                wordLabels[index] = wordLabels[..<index].last { $0 != nil } ?? wordLabels[(index + 1)...].first { $0 != nil } ?? nil
            }
            var runs = runsOf(wordLabels)
            var changed = true
            while changed && runs.count > 1 {
                changed = false
                for (position, run) in runs.enumerated() where run.count <= 2 {
                    let before = position > 0 ? runs[position - 1] : nil, after = position + 1 < runs.count ? runs[position + 1] : nil
                    let replacement: String??
                    if let before, let after, before.label == after.label { replacement = .some(before.label) }
                    else if before == nil, let after, after.count >= 3 { replacement = .some(after.label) }
                    else if after == nil, let before, before.count >= 3 { replacement = .some(before.label) }
                    else { replacement = nil }
                    if let label = replacement {
                        for index in run.range { wordLabels[index] = label }
                        runs = runsOf(wordLabels); changed = true; break
                    }
                }
            }
            // Dropped columns stay with the run before them so provenance keeps the source's words.
            for (number, run) in runs.enumerated() {
                let first = kept[run.range.lowerBound], last = kept[run.range.upperBound - 1]
                let span = members.filter { $0 >= (number == 0 ? members[0] : first) && $0 <= (number == runs.count - 1 ? members[members.count - 1] : last) }
                let words = run.range.map { fused[kept[$0]]! }
                let id = number == 0 ? original.id : SyncEncoding.uuid("fusion:\(original.id.uuidString):\(number)")
                // The passage plays from, and is credited to, the source whose votes carried it.
                let primary = words.reduce(into: [Int: Double]()) { totals, word in
                    for (source, score) in word.scores { totals[source, default: 0] += score }
                }.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key ?? home.source
                let confidences = words.compactMap(\.confidence)
                var provenance: [SegmentProvenance] = []
                var passages: [Home] = []
                var entriesByPassage: [Home: [Entry]] = [:]
                for column in span {
                    for entry in columns[column].entries {
                        let passage = Home(source: entry.source, segment: sources[entry.source].words[entry.word].segment)
                        if entriesByPassage[passage] == nil { passages.append(passage) }
                        entriesByPassage[passage, default: []].append(entry)
                    }
                }
                passages.sort { a, b in
                    if (a == home) != (b == home) { return a == home }
                    return (a.source, sources[a.source].segments[a.segment].start) < (b.source, sources[b.source].segments[b.segment].start)
                }
                for passage in passages {
                    let entries = entriesByPassage[passage]!.sorted { $0.word < $1.word }
                    let passageSource = sources[passage.source]
                    let sourceWords = entries.map { passageSource.words[$0.word] }
                    let supported = Set(entries)
                    let indices = words.enumerated().filter { !supported.isDisjoint(with: $0.element.supporters) }.map(\.offset)
                    let segment = passageSource.segments[passage.segment]
                    provenance.append(SegmentProvenance(trackID: passageSource.trackID, segmentID: segment.id,
                        start: sourceWords.map(\.localStart).min() ?? segment.start, end: sourceWords.map(\.localEnd).max() ?? segment.end,
                        text: sourceWords.map(\.display).joined(separator: " "), confidence: segment.confidence, wordIndices: indices))
                }
                segments.append(TranscriptSegment(id: id, trackID: sources[primary].trackID, start: words.map(\.start).min()!,
                    end: max(words.map(\.end).max()!, words.map(\.start).min()!), text: words.map(\.display).joined(separator: " "),
                    speakerID: run.label, confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
                    provenance: provenance))
            }
        }
        segments.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }

        // Per-source contribution counts.
        statistics = [:]
        for s in sources.indices { statistics[sources[s].trackID] = (sources[s].words.count, 0, 0, 0, 0) }
        var corroborated = 0, total = 0
        for (index, column) in columns.enumerated() {
            let sourcesHere = Set(column.entries.map(\.source))
            let winner = fused[index]
            if let winner {
                total += 1
                let supporting = Set(winner.supporters.map(\.source))
                if supporting.count >= 2 { corroborated += 1 }
                statistics[sources[winner.chosen.source].trackID]!.used += 1
                if supporting.count >= 2 { for s in supporting { statistics[sources[s].trackID]!.corroborated += 1 } }
            }
            for entry in column.entries {
                let id = sources[entry.source].trackID
                if sourcesHere.count >= 2 { statistics[id]!.merged += 1 }
                if winner == nil || winner!.key != sources[entry.source].words[entry.word].key { statistics[id]!.overruled += 1 }
            }
        }
        var added: [Speaker] = []
        if let owner, owner == inputs.options.ownerSpeakerID, !inputs.speakers.contains(where: { $0.id == owner }) {
            added.append(Speaker(id: owner, name: inputs.options.ownerName, sourceTrackID: ownerTrack))
        }
        let summary = FusionSummary(sources: [], words: total, corroboratedWords: corroborated, disputedWords: disputed,
                                    ownerSpeakerID: owner, speakerMappings: mappings)
        return (segments, summary, added)
    }

    private var statistics: [UUID: (words: Int, used: Int, corroborated: Int, merged: Int, overruled: Int)] = [:]

    private struct Run { var label: String?; var range: Range<Int>; var count: Int { range.count } }
    private func runsOf(_ labels: [String?]) -> [Run] {
        var runs: [Run] = []
        for (index, label) in labels.enumerated() {
            if let last = runs.last, last.label == label { runs[runs.count - 1].range = last.range.lowerBound..<(index + 1) }
            else { runs.append(Run(label: label, range: index..<(index + 1))) }
        }
        return runs
    }

    private func mostCommon(_ labels: [String?]) -> String? {
        let counts = Dictionary(labels.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    private func buildReports(summary: FusionSummary, latest: [TrackTranscript], supersededBy: [UUID: UUID],
                              placements: [UUID: TrackAlignment]) -> [FusionSourceReport] {
        latest.map { transcript in
            let id = transcript.trackID
            let role = FusionSourceRole(trackByID[id]?.source)
            let alignment = placements[supersededBy[id] ?? id]
            let included = sources.contains { $0.trackID == id }
            let stats = statistics[id]
            var note: String?
            if supersededBy[id] != nil { note = "Transcribed through its processed copy." }
            else if alignment?.method == .unaligned { note = "Couldn’t be placed on the meeting timeline; kept separately." }
            else if !included { note = "No usable speech." }
            return FusionSourceReport(trackID: id, role: role, transcriptID: transcript.id, included: included,
                method: alignment?.method ?? .unaligned, referenceTrackID: alignment?.referenceTrackID,
                offset: alignment?.offset ?? 0, rate: alignment?.rate ?? 1, confidence: alignment?.confidence,
                words: stats?.words ?? 0, wordsUsed: stats?.used ?? 0, wordsCorroborated: stats?.corroborated ?? 0,
                wordsMerged: stats?.merged ?? 0, wordsOverruled: stats?.overruled ?? 0, note: note)
        }
    }
}
