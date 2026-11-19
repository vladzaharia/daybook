import DaybookCore
import Foundation

/// One indexed piece a question matched, and how well.
public struct AskHit: Equatable, Sendable {
    public var unit: AskUnit
    public var score: Double
}

/// What retrieval found for a question.
public struct AskRetrieval: Sendable {
    public var query: AskQuery
    /// The best pieces an answer may rest on, best first: transcript chunks, notes, and bookmarks, with the passage
    /// a summary line or a commitment came from standing for it. At most three come from one conversation among the
    /// first twelve, so one long meeting doesn't take every slot.
    public var hits: [AskHit]
    /// What the model is given, or nil when nothing scored above the floor: no model runs then.
    public var evidence: AskEvidence?
    /// Conversations in the order they ranked, summary lines and commitments counted, for the search results shown
    /// under "Nothing here answers that."
    public var closest: [UUID]
}

/// A question to ranked, budgeted evidence (docs/architecture.md, "Ask across conversations"): the scope's
/// conversations (the lock and a Focus decide which Personal ones, if any), the query's people and dates as filters,
/// BM25 over the index's units with summary lines and commitments weighted a little above transcript chunks, a small
/// recency tie-break, and the best chunks widened by a passage on each side and cut to a budget.
public struct AskRetriever: Sendable {
    public var index: LibraryPassageIndex
    /// Tokens of passages, notes, and bookmarks the model may be given. About 4,000 suits every built-in model: the
    /// 5,400-token whole-read limit less the instructions, the question, and room to write.
    public var budget = AskRetriever.defaultBudget
    /// The best score below which nothing is read: no word shared with the question is rare enough to mean anything
    /// (less in a small library).
    public var floor = 2.5
    /// The most ranked pieces kept.
    public var limit = 16

    public static let defaultBudget = 4_000
    static let k1 = 1.2, b = 0.75

    public init(index: LibraryPassageIndex) { self.index = index }

    /// - Parameters:
    ///   - people: names beyond the speakers of the scope's conversations (speaker profiles').
    ///   - vocabulary: the person's terms, whose spellings a question that names one also searches.
    ///   - now, calendar: today, for "last month", and the time zone dates are read and shown in.
    /// - Throws: `CancellationError`, between conversations.
    public func retrieve(_ question: String, scope: AskScope, in meetings: [Meeting], vocabulary: [GlossaryTerm] = [], people: [String] = [],
                         now: Date = Date(), calendar: Calendar = .current) throws -> AskRetrieval {
        let inScope = scope.conversations(in: meetings)
        var known = people
        for meeting in inScope {
            for speaker in meeting.speakers where !speaker.name.hasPrefix("Speaker ") && !known.contains(speaker.name) { known.append(speaker.name) }
        }
        let query = AskQueryParser.parse(question, people: known, vocabulary: vocabulary, now: now, calendar: calendar)
        let candidates = inScope.filter { query.dates?.contains($0.date) ?? true }
        var indexes: [ConversationAskIndex] = []
        for meeting in candidates {
            try Task.checkCancellation()
            indexes.append(index.index(for: meeting))
        }
        let scored = score(query, candidates, indexes)
        let closest = conversationsRanked(scored, candidates)
        let hits = select(scored, candidates, indexes)
        // Asked about one conversation, it is read whatever it shares with the question. A small library can't score as
        // high as a large one (a word's weight grows with the pieces it isn't in), so the floor is at most 0.6 of the
        // most a word found once can weigh.
        let units = indexes.reduce(0) { $0 + $1.units.count }
        let minimum = scope.conversation == nil ? min(floor, 0.6 * log(1 + (Double(units) - 0.5) / 1.5)) : 0
        guard let best = scored.first?.score, best >= minimum else {
            return AskRetrieval(query: query, hits: hits, evidence: nil, closest: closest)
        }
        let evidence = evidence(for: hits, question: question, candidates, indexes, now: now, calendar: calendar)
        return AskRetrieval(query: query, hits: hits, evidence: evidence, closest: closest)
    }

    // MARK: Scoring

    private struct Scored { var conversation: Int; var unit: Int; var score: Double }

    /// BM25 over the candidates' units, best first. Corpus statistics are worked out over exactly these conversations.
    private func score(_ query: AskQuery, _ candidates: [Meeting], _ indexes: [ConversationAskIndex]) -> [Scored] {
        let units = indexes.reduce(0) { $0 + $1.units.count }
        guard units > 0, !query.terms.isEmpty else { return [] }
        let average = Double(indexes.reduce(0) { $0 + $1.totalLength }) / Double(units)
        var idf: [String: Double] = [:]
        for term in query.terms {
            let frequency = indexes.reduce(0) { $0 + ($1.postings[term.text]?.count ?? 0) }
            idf[term.text] = log(1 + (Double(units - frequency) + 0.5) / (Double(frequency) + 0.5))
        }
        let dates = candidates.map(\.date)
        let oldest = dates.min() ?? Date(), span = max((dates.max() ?? Date()).timeIntervalSince(oldest), 1)
        var scored: [Scored] = []
        for (position, conversation) in indexes.enumerated() {
            var sums: [Int32: Double] = [:]
            for term in query.terms {
                guard let postings = conversation.postings[term.text], let weight = idf[term.text] else { continue }
                for posting in postings {
                    let count = Double(posting.count), length = Double(conversation.lengths[Int(posting.unit)])
                    sums[posting.unit, default: 0] += term.weight * weight * count * (Self.k1 + 1)
                        / (count + Self.k1 * (1 - Self.b + Self.b * length / average))
                }
            }
            let recency = 1 + 0.03 * candidates[position].date.timeIntervalSince(oldest) / span
            for (unit, sum) in sums {
                let piece = conversation.units[Int(unit)]
                guard let factor = factor(of: piece, for: query) else { continue }
                // A piece in the words of a promise, by the person asked about, counts more, but only when it shares a word
                // with the question: nothing rises over the floor on how it was said alone.
                let bonus = query.kind == .commitment && Self.promised(piece, by: query.people) ? Self.promiseBonus : 0
                scored.append(Scored(conversation: position, unit: Int(unit), score: (sum + bonus) * factor * recency))
            }
        }
        return scored.sorted { $0.score > $1.score }
    }

    /// Added to the score of a piece in which someone (one of `people`, or anyone with none named) says they will do something.
    static let promiseBonus = 3.0

    /// Whether `unit` is someone saying they will do something: a transcript chunk with a passage in the words of a
    /// commitment, or a summary's commitment.
    static func promised(_ unit: AskUnit, by people: [String]) -> Bool {
        switch unit.kind {
        case .transcript: return unit.committers.contains { name in people.isEmpty || people.contains { AskWords.sameName($0, name) } }
        case .commitment: return people.isEmpty || (unit.owner.map { owner in people.contains { AskWords.sameName($0, owner) } } ?? false)
        case .summaryLine, .note, .bookmark: return false
        }
    }

    /// How much a unit's score counts for this question, or nil when the question's people rule it out.
    private func factor(of unit: AskUnit, for query: AskQuery) -> Double? {
        var factor: Double
        switch unit.kind {
        case .summaryLine: factor = query.kind == .decision ? 1.35 : 1.15
        case .commitment: factor = query.kind == .commitment ? 1.6 : 1.15
        case .transcript, .note, .bookmark: factor = 1
        }
        guard !query.people.isEmpty else {
            return unit.kind == .transcript && query.kind == .commitment && !unit.committers.isEmpty ? factor * 1.15 : factor
        }
        let said = unit.speakers.contains { speaker in query.people.contains { AskWords.sameName($0, speaker) } }
        let owns = unit.owner.map { owner in query.people.contains { AskWords.sameName($0, owner) } } ?? false
        let promised = unit.committers.contains { speaker in query.people.contains { AskWords.sameName($0, speaker) } }
        if query.filtersPeople {
            // Their own words and commitments; a summary line or a note counts when it names them.
            switch unit.kind {
            case .transcript: guard said else { return nil }
            case .commitment: guard owns else { return nil }
            case .summaryLine, .note, .bookmark:
                let text = AskWords.folded(unit.text)
                guard query.people.contains(where: { name in
                    [name, name.split(separator: " ").first.map(String.init) ?? name].contains { text.contains(AskWords.folded($0)) }
                }) else { return nil }
            }
        } else if said || owns {
            factor *= 1.3
        }
        if query.kind == .commitment, promised { factor *= 1.35 }
        return factor
    }

    private func conversationsRanked(_ scored: [Scored], _ candidates: [Meeting]) -> [UUID] {
        var ids: [UUID] = []
        for item in scored {
            let id = candidates[item.conversation].id
            if !ids.contains(id) { ids.append(id) }
            if ids.count == 8 { break }
        }
        return ids
    }

    // MARK: Hits

    /// The ranked pieces an answer may rest on. A summary line or a commitment stands for the passage it came from, and
    /// is passed over when none was found; a piece whose passages are already covered adds nothing.
    private func select(_ scored: [Scored], _ candidates: [Meeting], _ indexes: [ConversationAskIndex]) -> [AskHit] {
        var hits: [AskHit] = []
        var perConversation: [Int: Int] = [:]
        var covered: [Int: Set<Int>] = [:]
        for item in scored {
            let unit = indexes[item.conversation].units[item.unit]
            if let passages = unit.passages, covered[item.conversation, default: []].isSuperset(of: Set(passages)) { continue }
            if unit.passages == nil, unit.kind == .summaryLine || unit.kind == .commitment { continue }
            if hits.count < 12, perConversation[item.conversation, default: 0] >= 3 { continue }
            perConversation[item.conversation, default: 0] += 1
            if let passages = unit.passages { covered[item.conversation, default: []].formUnion(passages) }
            hits.append(AskHit(unit: unit, score: item.score))
            if hits.count == limit { break }
        }
        return hits
    }

    // MARK: Evidence

    private func tokens(_ text: String) -> Int {
        Int((Double(text.split(whereSeparator: \.isWhitespace).count) * ConversationAskIndex.tokensPerWord).rounded(.up)) + 8
    }

    /// The hits' passages, each chunk widened by a passage on each side, in rank order until the budget is spent, then
    /// laid out by conversation in the order they happened, passages in the order they were said.
    private func evidence(for hits: [AskHit], question: String, _ candidates: [Meeting], _ indexes: [ConversationAskIndex],
                          now: Date, calendar: Calendar) -> AskEvidence? {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var passages: [UUID: Set<Int>] = [:], notes: [UUID: Set<Int>] = [:], bookmarks: [UUID: Set<UUID>] = [:]
        var spent = 0
        for hit in hits {
            guard let meeting = byID[hit.unit.meetingID] else { continue }
            switch hit.unit.kind {
            case .note:
                guard let paragraph = hit.unit.paragraph, spent + tokens(hit.unit.text) <= budget else { continue }
                if notes[meeting.id, default: []].insert(paragraph).inserted { spent += tokens(hit.unit.text) }
            case .bookmark:
                guard let id = hit.unit.highlightID, spent + tokens(hit.unit.text) <= budget else { continue }
                if bookmarks[meeting.id, default: []].insert(id).inserted { spent += tokens(hit.unit.text) }
            case .transcript, .summaryLine, .commitment:
                guard let range = hit.unit.passages else { continue }
                let transcript = meeting.unifiedTranscript
                let wide = max(0, range.lowerBound - 1)..<min(transcript.count, range.upperBound + 1)
                for choice in [wide, range] {
                    let new = choice.filter { !passages[meeting.id, default: []].contains($0) }
                    let cost = new.reduce(0) { $0 + tokens(transcript[$1].text) }
                    guard spent + cost <= budget else { continue }
                    passages[meeting.id, default: []].formUnion(new)
                    spent += cost
                    break
                }
            }
        }
        var conversations: [AskEvidence.Conversation] = []
        var passageNumber = 0, noteNumber = 0, bookmarkNumber = 0
        let ids = Set(passages.keys).union(notes.keys).union(bookmarks.keys)
        let chosen = ids.compactMap { byID[$0] }.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
        for meeting in chosen {
            var conversation = AskEvidence.Conversation(
                label: "C\(conversations.count + 1)", meetingID: meeting.id,
                title: meeting.title.isEmpty || meeting.title == "Untitled meeting" ? nil : meeting.title,
                date: meeting.date, started: Self.started(meeting.date, calendar: calendar), passages: [], notes: [], bookmarks: [])
            for position in (passages[meeting.id] ?? []).sorted() {
                let segment = meeting.unifiedTranscript[position]
                passageNumber += 1
                conversation.passages.append(.init(label: "P\(passageNumber)", segmentID: segment.id, time: segment.start,
                                                   speaker: meeting.speakerName(segment.speakerID), text: segment.text))
            }
            if let wanted = notes[meeting.id] {
                let paragraphs = meeting.notes.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let times = meeting.paragraphTimes()
                for paragraph in wanted.sorted() where paragraph < paragraphs.count {
                    noteNumber += 1
                    conversation.notes.append(.init(label: "N\(noteNumber)", paragraph: paragraph, time: paragraph < times.count ? times[paragraph] : nil,
                                                    text: paragraphs[paragraph]))
                }
            }
            for highlight in meeting.highlights.sorted(by: { $0.time < $1.time }) where bookmarks[meeting.id]?.contains(highlight.id) == true {
                bookmarkNumber += 1
                conversation.bookmarks.append(.init(label: "B\(bookmarkNumber)", highlightID: highlight.id, time: highlight.time, text: highlight.text))
            }
            conversations.append(conversation)
        }
        guard !conversations.isEmpty else { return nil }
        return AskEvidence(question: question, today: Self.today(now, calendar: calendar), conversations: conversations, tokens: spent)
    }

    /// "Wednesday 2026-11-18, 14:05, America/Vancouver".
    static func started(_ date: Date, calendar: Calendar) -> String {
        format(date, "EEEE yyyy-MM-dd, HH:mm", calendar) + ", " + calendar.timeZone.identifier
    }

    /// "Wednesday 2026-11-18, America/Vancouver".
    static func today(_ date: Date, calendar: Calendar) -> String {
        format(date, "EEEE yyyy-MM-dd", calendar) + ", " + calendar.timeZone.identifier
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
