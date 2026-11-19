import DaybookCore
import Foundation

/// A stretch of time a question names ("last month", "since October"), as a filter on conversations' dates.
public struct AskDateRange: Equatable, Sendable {
    public var start: Date
    /// Exclusive.
    public var end: Date
    /// What the question said, for the page's one meta line: "last month", "October 2026".
    public var label: String

    public init(start: Date, end: Date, label: String) { self.start = start; self.end = end; self.label = label }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// What a question asks, worked out from its words alone (`AskQueryParser`).
public struct AskQuery: Equatable, Sendable {
    /// What kind of thing the question wants, which favors some of what is indexed.
    public enum Kind: Equatable, Sendable { case general, commitment, decision }

    public struct Term: Equatable, Sendable {
        public var text: String
        public var weight: Double
        public init(_ text: String, weight: Double = 1) { self.text = text; self.weight = weight }
    }

    public var question: String
    public var terms: [Term]
    /// The people the question names, as the library spells them.
    public var people: [String]
    /// The question is about what these people said or owe: only their words and commitments count. Otherwise they
    /// only boost.
    public var filtersPeople: Bool
    public var dates: AskDateRange?
    public var kind: Kind

    public init(question: String, terms: [Term] = [], people: [String] = [], filtersPeople: Bool = false, dates: AskDateRange? = nil,
                kind: Kind = .general) {
        self.question = question; self.terms = terms; self.people = people; self.filtersPeople = filtersPeople
        self.dates = dates; self.kind = kind
    }
}

/// A question becomes a query without a model, so it's the same every time and tested: its words (stop list, light
/// stemming, question words removed, the vocabulary's Also Heard As spellings added), the people it names, the dates
/// it names, and the kind of thing it wants.
public enum AskQueryParser {
    /// - Parameters:
    ///   - people: the names the library knows (speakers, speaker profiles). A name in the question is a person only
    ///     when it is one of these.
    ///   - vocabulary: the person's terms; one named in the question brings its spellings.
    ///   - now: today, in `calendar`'s time zone.
    public static func parse(_ question: String, people known: [String] = [], vocabulary: [GlossaryTerm] = [], now: Date = Date(),
                             calendar: Calendar = .current) -> AskQuery {
        var rest = question
        let dates = dateRange(in: &rest, now: now, calendar: calendar)
        let (people, filters) = names(in: &rest, known: known)
        var terms: [AskQuery.Term] = []
        var seen = Set<String>()
        func add(_ text: String, weight: Double = 1) {
            for term in AskWords.terms(text) where seen.insert(term).inserted { terms.append(.init(term, weight: weight)) }
        }
        add(rest)
        let lowered = AskWords.folded(rest)
        for entry in vocabulary where entry.approved {
            let spellings = [entry.term] + entry.aliases
            guard spellings.contains(where: { spelling in
                let folded = AskWords.folded(spelling)
                return !folded.isEmpty && lowered.range(of: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: folded) + #"(?![\p{L}\p{N}])"#,
                                                        options: .regularExpression) != nil
            }) else { continue }
            for spelling in spellings { add(spelling) }
        }
        return AskQuery(question: question, terms: terms, people: people, filtersPeople: filters, dates: dates, kind: kind(of: question))
    }

    // MARK: Kind

    static func kind(of question: String) -> AskQuery.Kind {
        let words = Set(question.lowercased().split { !$0.isLetter }.map(String.init))
        let lowered = question.lowercased()
        if !words.isDisjoint(with: ["commit", "commits", "committed", "commitment", "commitments", "promise", "promised", "promises",
                                    "owe", "owes", "owed", "action", "actions"]) || lowered.contains("follow up") || lowered.contains("follow-up")
            || lowered.contains("next steps") { return .commitment }
        if !words.isDisjoint(with: ["decide", "decided", "decision", "decisions", "agreed", "agree", "settled"]) { return .decision }
        return .general
    }

    // MARK: People

    /// Words that are names and also words, so they count as a person only when written with a capital that isn't a
    /// sentence's first letter.
    private static let ambiguousNames: Set<String> = ["will", "mark", "may", "grant", "bill", "art", "rich", "hope", "joy", "dawn", "april", "june",
                                                      "august", "summer", "rose", "jack", "page", "case", "major", "frank", "guy", "gene"]

    /// The known people a question names, with whether it asks what they said or owe ("did Sam", "Sam's", "Sam
    /// commit"). A named person's words are taken out of `text`, unless they only boost, when they stay to be searched.
    private static func names(in text: inout String, known: [String]) -> (people: [String], filters: Bool) {
        var found: [String] = []
        var filters = false
        var remaining = text
        for name in known where !found.contains(where: { AskWords.sameName($0, name) }) {
            let folded = AskWords.folded(name)
            guard !folded.isEmpty else { continue }
            // The first name stands for the person, and so does the whole name.
            let spellings = [name] + (name.contains(" ") ? [String(name.split(separator: " ")[0])] : [])
            for spelling in spellings {
                let escaped = NSRegularExpression.escapedPattern(for: spelling)
                guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
                                                            options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range, in: text) else { continue }
                if ambiguousNames.contains(AskWords.folded(spelling)) {
                    let first = text[range].first
                    guard first?.isUppercase == true, text.distance(from: text.startIndex, to: range.lowerBound) > 0 else { continue }
                }
                found.append(name)
                let before = text[..<range.lowerBound].lowercased(), after = text[range.upperBound...].lowercased()
                let possessive = after.hasPrefix("'s") || after.hasPrefix("\u{2019}s")
                let asks = before.range(of: #"\b(did|does|do|has|have|will|would|could|can|was|is|are)\s+$"#, options: .regularExpression) != nil
                let acts = after.range(of: #"^\s+(said|say|says|commit|committed|commits|promise|promised|promises|owe|owes|owed|agree|agreed|decide|decided|mention|mentioned|think|thought|want|wants|wanted|ask|asked|will|would|take|took|own|owns|send|sent)\b"#,
                                       options: .regularExpression) != nil
                if possessive || asks || acts { filters = true; remaining = remaining.replacingOccurrences(of: String(text[range]), with: " ") }
                break
            }
        }
        if filters { text = remaining }
        return (found, filters)
    }

    // MARK: Dates

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                                 "november", "december"]

    /// The first stretch of time the question names, taken out of `text`. "last week", "this month", a month name
    /// ("in March", "since October", "March 2026"); not dates named by events.
    static func dateRange(in text: inout String, now: Date, calendar: Calendar) -> AskDateRange? {
        let monthNames = months.joined(separator: "|")
        let startOfToday = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        var range: AskDateRange?
        func interval(_ component: Calendar.Component, offset: Int, label: String) -> AskDateRange? {
            guard let anchor = calendar.date(byAdding: component, value: offset, to: startOfToday),
                  let span = calendar.dateInterval(of: component, for: anchor) else { return nil }
            return AskDateRange(start: span.start, end: span.end, label: label)
        }
        // Each phrase, the range it means, and the text it takes out.
        let fixed: [(String, () -> AskDateRange?)] = [
            (#"\btoday\b"#, { interval(.day, offset: 0, label: "today") }),
            (#"\byesterday\b"#, { interval(.day, offset: -1, label: "yesterday") }),
            (#"\bthis week\b"#, { interval(.weekOfYear, offset: 0, label: "this week") }),
            (#"\blast week\b"#, { interval(.weekOfYear, offset: -1, label: "last week") }),
            (#"\bthis month\b"#, { interval(.month, offset: 0, label: "this month") }),
            (#"\blast month\b"#, { interval(.month, offset: -1, label: "last month") }),
            (#"\bthis year\b"#, { interval(.year, offset: 0, label: "this year") }),
            (#"\blast year\b"#, { interval(.year, offset: -1, label: "last year") }),
        ]
        var stripped = text
        for (pattern, make) in fixed {
            guard let found = stripped.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            if range == nil { range = make() }
            stripped.replaceSubrange(found, with: " ")
        }
        // "since October", "in March", "March 2026", "October".
        let monthPattern = #"(?:\b(since|in|during|from|of|by)\s+)?\b("# + monthNames + #")\b(?:\s+(\d{4}))?"#
        if let regex = try? NSRegularExpression(pattern: monthPattern, options: .caseInsensitive) {
            for match in regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).reversed() {
                guard let whole = Range(match.range, in: stripped), let nameRange = Range(match.range(at: 2), in: stripped),
                      let month = months.firstIndex(of: stripped[nameRange].lowercased()).map({ $0 + 1 }) else { continue }
                let preposition = Range(match.range(at: 1), in: stripped).map { stripped[$0].lowercased() }
                let yearText = Range(match.range(at: 3), in: stripped).map { String(stripped[$0]) }
                // "may" is a month only after a preposition or beside a year: "what may we do" isn't one.
                if month == 5, preposition == nil, yearText == nil { continue }
                var components = DateComponents(); components.month = month; components.day = 1
                let thisYear = calendar.component(.year, from: now)
                components.year = yearText.flatMap(Int.init) ?? thisYear
                guard var start = calendar.date(from: components) else { continue }
                // A month name alone is the latest one that isn't in the future.
                if yearText == nil, start > now { components.year = thisYear - 1; start = calendar.date(from: components) ?? start }
                guard let monthEnd = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "LLLL yyyy"
                let label = formatter.string(from: start)
                let found: AskDateRange
                if preposition == "since" { found = AskDateRange(start: start, end: max(tomorrow, monthEnd), label: "since " + label) }
                else { found = AskDateRange(start: start, end: monthEnd, label: label) }
                // The first month named, in the order of the question, is the one that counts.
                range = found
                stripped.replaceSubrange(whole, with: " ")
            }
        }
        text = stripped
        return range
    }
}
