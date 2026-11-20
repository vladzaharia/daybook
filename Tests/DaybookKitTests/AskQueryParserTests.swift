import DaybookCore
import XCTest
@testable import DaybookKit

/// A question becomes a query without a model: its words, the people and dates it names, and its kind.
final class AskQueryParserTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Wednesday 2026-11-18, noon in Vancouver.
    private var now: Date { date(2026, 11, 18, 12) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func parse(_ question: String, people: [String] = ["Sam Rivera", "Priya", "Will"], vocabulary: [GlossaryTerm] = []) -> AskQuery {
        AskQueryParser.parse(question, people: people, vocabulary: vocabulary, now: now, calendar: calendar)
    }

    private func range(_ question: String) -> AskDateRange? { parse(question).dates }

    // MARK: Words

    func testWordsAreLoweredStemmedAndWithoutQuestionWords() {
        let query = parse("What did we decide about the pricing of the Pro tier?")
        XCTAssertEqual(query.terms.map(\.text), ["decid", "pric", "pro", "tier"])
        XCTAssertEqual(AskWords.terms("We decided on pricing"), ["decid", "pric"], "'decide' meets 'decided'")
        XCTAssertEqual(AskWords.terms("It costs 12 dollars"), ["cost", "12", "dollar"], "short numbers count")
    }

    func testTheVocabularyBringsItsAlsoHeardAsSpellings() {
        let term = GlossaryTerm(term: "Orchard & Vane", aliases: ["Orchid and Vain"], approved: true)
        let unapproved = GlossaryTerm(term: "Kestrel", aliases: ["Castrol"], approved: false)
        let query = parse("What did Orchard & Vane ask for? Kestrel too", vocabulary: [term, unapproved])
        XCTAssertTrue(query.terms.map(\.text).contains("orchid"))
        XCTAssertTrue(query.terms.map(\.text).contains("vain"))
        XCTAssertFalse(query.terms.map(\.text).contains("castrol"), "only approved terms")
    }

    // MARK: People

    func testANamedPersonFiltersWhenTheQuestionIsAboutWhatTheySaidOrOwe() {
        for question in ["What did Sam commit to?", "Sam's plans for pricing", "Did Sam agree to the date?", "what did sam promise", "What does Sam Rivera owe?"] {
            let query = parse(question)
            XCTAssertEqual(query.people.count, 1, question)
            XCTAssertTrue(query.filtersPeople, question)
            XCTAssertFalse(query.terms.map(\.text).contains("sam"), "a filter isn't a word to find: \(question)")
        }
        XCTAssertEqual(parse("What did Sam commit to?").people, ["Sam Rivera"])
    }

    func testANamedPersonOtherwiseOnlyBoosts() {
        let query = parse("What was discussed with Priya about pricing?")
        XCTAssertEqual(query.people, ["Priya"])
        XCTAssertFalse(query.filtersPeople)
        XCTAssertTrue(query.terms.map(\.text).contains("priya"), "and the name stays a word to find")
    }

    func testOnlyNamesTheLibraryKnowsAreNamesAndAnAmbiguousOneNeedsACapital() {
        XCTAssertTrue(parse("What did Dana say about pricing?").people.isEmpty, "Dana isn't a known name")
        XCTAssertTrue(parse("What will we ship?").people.isEmpty, "'will' is a word")
        XCTAssertEqual(parse("What did Will say about the plan?").people, ["Will"])
    }

    // MARK: Dates

    func testToday() {
        XCTAssertEqual(range("What did we decide today?")?.start, date(2026, 11, 18))
        XCTAssertEqual(range("What did we decide today?")?.end, date(2026, 11, 19))
    }

    func testYesterday() {
        XCTAssertEqual(range("What came up yesterday?"), AskDateRange(start: date(2026, 11, 17), end: date(2026, 11, 18), label: "yesterday"))
    }

    func testThisWeekAndLastWeek() {
        XCTAssertEqual(range("What happened this week?"), AskDateRange(start: date(2026, 11, 15), end: date(2026, 11, 22), label: "this week"))
        XCTAssertEqual(range("What happened last week?"), AskDateRange(start: date(2026, 11, 8), end: date(2026, 11, 15), label: "last week"))
    }

    func testThisMonthAndLastMonth() {
        XCTAssertEqual(range("What did Sam commit to this month?"), AskDateRange(start: date(2026, 11, 1), end: date(2026, 12, 1), label: "this month"))
        XCTAssertEqual(range("What did Sam commit to last month?"), AskDateRange(start: date(2026, 10, 1), end: date(2026, 11, 1), label: "last month"))
    }

    func testThisYearAndLastYear() {
        XCTAssertEqual(range("What did we ship last year?")?.start, date(2025, 1, 1))
        XCTAssertEqual(range("What did we ship this year?")?.end, date(2027, 1, 1))
    }

    func testAMonthNameAndInAMonthAreTheLatestSuchMonthThatIsntInTheFuture() {
        XCTAssertEqual(range("What did we decide in March?"), AskDateRange(start: date(2026, 3, 1), end: date(2026, 4, 1), label: "March 2026"))
        XCTAssertEqual(range("What did we decide in December?")?.start, date(2025, 12, 1), "this December hasn't come")
        XCTAssertEqual(range("October pricing")?.start, date(2026, 10, 1))
        XCTAssertEqual(range("What did we decide in March 2025?")?.start, date(2025, 3, 1))
    }

    func testSinceAMonthRunsToTheEndOfToday() {
        let since = range("What has Sam said since October?")
        XCTAssertEqual(since?.start, date(2026, 10, 1))
        XCTAssertEqual(since?.end, date(2026, 11, 19))
        XCTAssertEqual(since?.label, "since October 2026")
    }

    func testMayIsAMonthOnlyAfterAPrepositionOrBesideAYear() {
        XCTAssertNil(range("What may we ship?"))
        XCTAssertEqual(range("What did we decide in May?")?.start, date(2026, 5, 1))
        XCTAssertEqual(range("May 2025 numbers")?.start, date(2025, 5, 1))
    }

    func testDatesNamedByEventsAreNotUnderstoodAndTheWordsStillSearch() {
        let query = parse("What did we decide before the offsite?")
        XCTAssertNil(query.dates)
        XCTAssertTrue(query.terms.map(\.text).contains("offsit"))
    }

    func testADatePhraseIsNotAWordToFind() {
        let query = parse("What did Sam commit to last month?")
        XCTAssertEqual(query.terms.map(\.text), ["commit"])
    }

    func testRangeContainsItsStartAndNotItsEnd() {
        let last = range("last month")!
        XCTAssertTrue(last.contains(date(2026, 10, 1)))
        XCTAssertTrue(last.contains(date(2026, 10, 31, 23)))
        XCTAssertFalse(last.contains(date(2026, 11, 1)))
    }

    // MARK: Kind

    func testTheKindOfQuestion() {
        XCTAssertEqual(parse("What did Sam commit to?").kind, .commitment)
        XCTAssertEqual(parse("What does Priya owe us?").kind, .commitment)
        XCTAssertEqual(parse("What are the next steps for Kestrel?").kind, .commitment)
        XCTAssertEqual(parse("What did we follow up on?").kind, .commitment)
        XCTAssertEqual(parse("What was decided about the launch?").kind, .decision)
        XCTAssertEqual(parse("What was agreed?").kind, .decision)
        XCTAssertEqual(parse("Where is the offsite?").kind, .general)
    }
}
