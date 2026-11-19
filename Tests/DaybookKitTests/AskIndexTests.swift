import DaybookCore
import DaybookTestSupport
import XCTest
@testable import DaybookKit

/// The keyword index and retrieval behind Ask: what is indexed and how it is chunked, how a conversation's piece follows
/// its content, the scope, lock, and Focus rules, ranking, the budget, and the floor. No model runs.
final class AskIndexTests: XCTestCase {
    private let track = UUID()

    /// A conversation of passages `(speaker, text)`, each 10 seconds long, starting at 0.
    private func meeting(_ title: String = "Weekly sync", date: Date = Date(timeIntervalSince1970: 1_760_000_000), placement: LibraryPlacement? = nil,
                         passages: [(String, String)], notes: String = "", speakers: [String: String] = ["s": "Sam", "p": "Priya"]) -> Meeting {
        var meeting = Meeting(title: title, date: date, updatedAt: date, speakers: speakers.sorted { $0.key < $1.key }.map { Speaker(id: $0.key, name: $0.value) },
                              status: .ready, placement: placement)
        meeting.unifiedTranscript = passages.enumerated().map { index, passage in
            TranscriptSegment(trackID: track, start: Double(index) * 10, end: Double(index) * 10 + 9, text: passage.1, speakerID: passage.0)
        }
        meeting.notes = notes
        return meeting
    }

    /// Conversations about other things, so a word the test looks for is rare in the library, as it is in a real one.
    private func filler() -> [Meeting] {
        let topics = ["gardening", "orchestra", "plumbing", "marathon", "bakery", "glacier", "harbor", "violin", "tractor", "lantern", "compass", "meadow"]
        return topics.enumerated().map { index, topic in
            meeting("Filler \(index)", date: Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 1000), placement: .work,
                    passages: [("p", "We spoke at length about \(topic) and the \(topic) season and nothing else at all.")])
        }
    }

    private func retrieve(_ question: String, _ meetings: [Meeting], scope: AskScope = AskScope(), index: LibraryPassageIndex = LibraryPassageIndex(),
                          now: Date = Date(timeIntervalSince1970: 1_763_000_000)) throws -> AskRetrieval {
        try AskRetriever(index: index).retrieve(question, scope: scope, in: meetings, now: now)
    }

    // MARK: Chunking

    func testChunksCloseNearSixtySecondsAndOverlapByAPassage() {
        let passages = (0..<20).map { ("s", "passage number \($0) says something quite ordinary today") }
        let meeting = meeting(passages: passages)
        let index = ConversationAskIndex(meeting)
        XCTAssertGreaterThan(index.units.count, 2)
        let ranges = index.units.compactMap(\.passages)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 20, "every passage is in a chunk")
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(next.lowerBound, previous.upperBound - 1, "a chunk starts with the last passage of the one before")
            XCTAssertGreaterThan(next.upperBound, previous.upperBound, "and always takes a new one")
        }
        for range in ranges.dropLast() {
            let seconds = meeting.unifiedTranscript[range.upperBound - 1].end - meeting.unifiedTranscript[range.lowerBound].start
            XCTAssertLessThanOrEqual(seconds, 70, "closed near 60 seconds")
        }
        XCTAssertEqual(index.units[0].start, 0, "a chunk keeps its first passage's time")
        XCTAssertEqual(index.units[1].start, meeting.unifiedTranscript[ranges[1].lowerBound].start)
    }

    func testAChunkClosesEarlierAtAChangeOfSpeaker() {
        var passages: [(String, String)] = []
        for _ in 0..<4 { passages.append(("s", "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty")) }
        for _ in 0..<4 { passages.append(("p", "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty")) }
        let index = ConversationAskIndex(meeting(passages: passages))
        XCTAssertEqual(index.units.first?.passages, 0..<4, "after a fair amount of speech, the speaker changes it")
        XCTAssertEqual(index.units.first?.speakers, ["sam"])
        XCTAssertEqual(index.units.dropFirst().first?.passages?.lowerBound, 3, "and the next starts with its last passage")
    }

    func testAChunkKeepsItsPassagesAndWhoSaidSomethingYouCanHold() {
        let meeting = meeting(passages: [("s", "I'll send the sheet to finance."), ("p", "Thanks, that helps.")])
        let unit = ConversationAskIndex(meeting).units[0]
        XCTAssertEqual(unit.speakers, ["sam", "priya"])
        XCTAssertEqual(unit.committers, ["sam"], "only Sam said what he would do")
        XCTAssertEqual(unit.passages, 0..<2)
    }

    func testEverythingTheLibraryHoldsIsIndexedAndSummaryLinesPointAtTheirPassage() {
        var meeting = meeting(passages: [("s", "We will ship the pricing change on Monday morning."), ("p", "Understood, the billing team is ready for that.")],
                              notes: "Check the invoice template\nBudget cap is firm")
        meeting.highlights = [Highlight(time: 3, text: "Pricing decision"), Highlight(time: 4, text: "Marked moment")]
        meeting.summary = MeetingSummary(overview: "The pricing change ships Monday.", sections: [SummarySection(heading: "Pricing", body: "- Ship the pricing change on Monday morning")],
                                         actionItems: [ActionItem(text: "Ship the pricing change on Monday morning", owner: "Sam")])
        let units = ConversationAskIndex(meeting).units
        XCTAssertEqual(Set(units.map(\.kind)).count, 5)
        XCTAssertEqual(units.filter { $0.kind == .note }.map(\.paragraph), [0, 1])
        XCTAssertEqual(units.filter { $0.kind == .bookmark }.map(\.text), ["Pricing decision"], "a bare bookmark has no words to find")
        XCTAssertEqual(units.first { $0.kind == .commitment }?.owner, "sam")
        XCTAssertEqual(units.first { $0.kind == .commitment }?.passages, 0..<1, "a commitment stands for the passage it came from")
    }

    // MARK: The cache follows content

    func testAConversationIsRebuiltWhenItsContentChangesEvenIfUpdatedAtDidNot() throws {
        var meeting = meeting(passages: [("s", "The pricing page needs three columns.")])
        let index = LibraryPassageIndex()
        XCTAssertTrue(try retrieve("pricing columns", [meeting], index: index).hits.first?.unit.text.contains("three columns") == true)
        // A sync merge can change a passage without moving updatedAt.
        meeting.unifiedTranscript[0].text = "The pricing page needs four panels."
        XCTAssertTrue(try retrieve("pricing panels", [meeting], index: index).hits.first?.unit.text.contains("four panels") == true)
        XCTAssertTrue(try retrieve("pricing columns", [meeting], index: index).hits.isEmpty || !(try retrieve("pricing columns", [meeting], index: index).hits.first!.unit.text.contains("three columns")))
    }

    func testARenamedSpeakerAndANewNoteAreIndexed() throws {
        var meeting = meeting(passages: [("s", "We will ship on Friday afternoon.")])
        let index = LibraryPassageIndex()
        index.update([meeting], personal: .included)
        meeting.speakers[meeting.speakers.firstIndex { $0.id == "s" }!].name = "Samuel"
        let unit = index.index(for: meeting).units[0]
        XCTAssertEqual(unit.speakers, ["samuel"])
        meeting.notes = "Remember the offsite budget"
        XCTAssertTrue(index.index(for: meeting).units.contains { $0.kind == .note })
    }

    func testUpdateDropsWhatLeftTheLibrary() {
        let a = meeting(passages: [("s", "alpha beta gamma")]), b = meeting(passages: [("s", "delta epsilon zeta")])
        let index = LibraryPassageIndex()
        index.update([a, b], personal: .included)
        XCTAssertEqual(index.conversationCount, 2)
        index.update([a], personal: .included)
        XCTAssertTrue(index.contains(a.id))
        XCTAssertFalse(index.contains(b.id), "a trashed or merged conversation is gone")
    }

    // MARK: The lock, and Focus

    func testALockedPersonalConversationIsNeverIndexedOrRead() throws {
        let work = meeting("Work", passages: [("s", "The budget review is on Thursday.")], notes: "")
        let personal = meeting("Private", placement: .personal, passages: [("s", "My budget for the vacation is large.")])
        let index = LibraryPassageIndex()
        index.update([work, personal], personal: .locked)
        XCTAssertTrue(index.contains(work.id))
        XCTAssertFalse(index.contains(personal.id), "not built while locked")
        let retrieval = try retrieve("budget", [work, personal], scope: AskScope(personal: .locked), index: index)
        XCTAssertEqual(retrieval.evidence?.conversations.map(\.meetingID), [work.id])
        XCTAssertFalse(retrieval.closest.contains(personal.id))
        // Even asked for directly, and even though it was built while unlocked.
        let open = LibraryPassageIndex()
        open.update([work, personal], personal: .included)
        XCTAssertTrue(open.contains(personal.id))
        let asked = try retrieve("budget vacation", [work, personal], scope: AskScope(search: .personal, personal: .locked), index: open)
        XCTAssertNil(asked.evidence, "the Personal scope reads nothing while locked")
        open.dropPersonal()
        XCTAssertFalse(open.contains(personal.id), "dropped when it locks")
        XCTAssertTrue(open.contains(work.id))
        open.update([work, personal], personal: .included)
        open.update([work, personal], personal: .locked)
        XCTAssertFalse(open.contains(personal.id), "an update while locked drops it too")
    }

    func testAConversationMovedIntoPersonalIsDroppedByItsPlacementNow() {
        var moved = meeting("Moved", passages: [("s", "The vacation budget is eighty dollars.")], speakers: ["s": "Sam"])
        let index = LibraryPassageIndex()
        index.update([moved], personal: .included)
        XCTAssertTrue(index.contains(moved.id))
        moved.placement = .personal
        index.update([moved], personal: .locked)
        XCTAssertFalse(index.contains(moved.id), "an update while locked drops it by where it is filed now")
        index.update([moved], personal: .included)
        XCTAssertTrue(index.contains(moved.id))
        index.dropPersonal(in: [moved])
        XCTAssertFalse(index.contains(moved.id))
        var other = moved
        other.placement = .work
        index.update([other], personal: .included)
        other.placement = .personal
        index.dropPersonal(in: [other])
        XCTAssertFalse(index.contains(other.id), "moved to Personal since it was indexed")
    }

    func testAPersonalPieceBeingBuiltWhenTheLockLocksIsNotKept() {
        let personal = meeting("Private", placement: .personal, passages: [("s", "The vacation budget is eighty dollars.")])
        let work = meeting("Work", passages: [("s", "The budget review is Thursday.")])
        let index = LibraryPassageIndex()
        _ = index.index(for: personal, afterBuild: { index.dropPersonal() })
        XCTAssertFalse(index.contains(personal.id))
        _ = index.index(for: work, afterBuild: { index.dropPersonal() })
        XCTAssertTrue(index.contains(work.id), "only Personal pieces are kept out")
    }

    func testAPromiseThatIsRefusedIsNotAPromise() {
        XCTAssertFalse(ConversationAskIndex.promises("I can't make Thursday."))
        XCTAssertFalse(ConversationAskIndex.promises("I cannot make Thursday."))
        XCTAssertFalse(ConversationAskIndex.promises("I will not send it."))
        XCTAssertFalse(ConversationAskIndex.promises("I'll not be there."))
        XCTAssertTrue(ConversationAskIndex.promises("I can send it Thursday."))
        XCTAssertTrue(ConversationAskIndex.promises("I'll send it."))
        XCTAssertTrue(ConversationAskIndex.promises("Let me check."))
    }

    func testHowAPromiseWasSaidAloneNeverBringsAPieceOverTheFloor() throws {
        let sam = meeting("Sync", passages: [("s", "I'll bring the donuts on Friday afternoon."), ("p", "Thanks, that will be lovely.")])
        let found = try retrieve("What did Sam commit to?", [sam] + filler())
        XCTAssertEqual(found.query.kind, .commitment)
        XCTAssertNil(found.evidence, "no word is shared with the question, so nothing is read")
        let shared = try retrieve("What did Sam commit to bringing?", [sam] + filler())
        XCTAssertNotNil(shared.evidence)
    }

    func testUnlockedPersonalIsInAllAndPersonalAndAFocusLeavesItOutOfEveryScope() throws {
        let work = meeting("Work", passages: [("s", "The vacation budget is a work topic too.")])
        let personal = meeting("Private", placement: .personal, passages: [("s", "The vacation budget is eighty dollars.")])
        for search in [SearchScope.all, .personal] {
            let found = try retrieve("vacation budget", [work, personal] + filler(), scope: AskScope(search: search, personal: .included))
            XCTAssertTrue(found.evidence?.conversations.contains { $0.meetingID == personal.id } == true, "\(search)")
        }
        for search in [SearchScope.all, .personal, .work] {
            let found = try retrieve("vacation budget", [work, personal] + filler(), scope: AskScope(search: search, personal: .hiddenByFocus))
            XCTAssertFalse(found.evidence?.conversations.contains { $0.meetingID == personal.id } == true, "\(search)")
        }
    }

    @MainActor
    func testThePersonalLockAndFocusDecideWhatMayBeRead() async {
        let lock = PersonalLock(defaults: makeTestDefaults("AskIndexTests"), platform: .mac, authenticator: FakePersonalLockAuthenticator())
        XCTAssertEqual(AskScope.Personal(lock), .included, "off by default")
        _ = await lock.setRequired(true)
        XCTAssertEqual(AskScope.Personal(lock), .locked)
        _ = await lock.unlock()
        XCTAssertEqual(AskScope.Personal(lock), .included)
        lock.apply(PersonalFocus(showsPersonal: false))
        XCTAssertEqual(AskScope.Personal(lock), .hiddenByFocus)
        lock.apply(PersonalFocus(showsPersonal: true))
        lock.lock()
        XCTAssertEqual(AskScope.Personal(lock), .locked)
    }

    // MARK: Scope

    func testScopesFoldersTagsSpeakersAndOneConversation() throws {
        let folder = UUID()
        var a = meeting("A", passages: [("s", "Pricing is the topic of the meeting.")], speakers: ["s": "Sam"])
        a.folderID = folder; a.tags = ["Launch"]
        var b = meeting("B", placement: .work, passages: [("p", "Pricing also came up with Priya.")], speakers: ["p": "Priya"])
        b.tags = ["Other"]
        let c = meeting("C", placement: .personal, passages: [("s", "Pricing for my garden shed.")], speakers: ["s": "Sam"])
        let all = [a, b, c] + filler()
        func read(_ scope: AskScope) throws -> Set<UUID> { Set(try retrieve("pricing", all, scope: scope).evidence?.conversations.map(\.meetingID) ?? []) }
        XCTAssertEqual(try read(AskScope(search: .folder(folder))), [a.id])
        XCTAssertEqual(try read(AskScope(search: .work)), [b.id])
        XCTAssertEqual(try read(AskScope(search: .personal)), [c.id])
        XCTAssertEqual(try read(AskScope(tokens: [.tag("launch")])), [a.id])
        XCTAssertEqual(try read(AskScope(tokens: [.speaker("Priya")])), [b.id])
        XCTAssertEqual(try read(AskScope(conversation: c.id)), [c.id])
        XCTAssertEqual(try read(AskScope()), [a.id, b.id, c.id])
        XCTAssertEqual(try read(AskScope(dates: AskDateRange(start: .distantPast, end: a.date.addingTimeInterval(-1), label: "earlier"))), [])
    }

    // MARK: Ranking

    func testRareWordsRankAboveCommonOnesAndSummaryLinesAndRecencyBreakTies() throws {
        var older = meeting("Older", date: Date(timeIntervalSince1970: 1_750_000_000), passages: [("s", "We talked about the schedule and the weather and the budget.")])
        let newer = meeting("Newer", date: Date(timeIntervalSince1970: 1_760_000_000), passages: [("s", "We talked about the schedule and the weather and the budget.")])
        let rare = meeting("Rare", date: Date(timeIntervalSince1970: 1_755_000_000), passages: [("s", "The zeppelin certification arrived and the budget changed.")])
        older.title = "Older"
        let hits = try retrieve("zeppelin budget", [older, newer, rare]).hits
        XCTAssertEqual(hits.first?.unit.meetingID, rare.id, "the rare word wins")
        let tied = try retrieve("schedule weather", [older, newer]).hits
        XCTAssertEqual(tied.first?.unit.meetingID, newer.id, "the newer conversation breaks a tie")
    }

    func testAtMostThreeChunksFromOneConversationAmongTheFirstTwelve() throws {
        let long = meeting("Long", passages: (0..<80).map { ("s", "the zeppelin schedule item \($0) is mentioned here again and again") })
        let others = (0..<6).map { index in meeting("Other \(index)", date: Date(timeIntervalSince1970: 1_760_000_000 + Double(index)),
                                                      passages: [("s", "the zeppelin schedule is mentioned once here")]) }
        let hits = try retrieve("zeppelin schedule", [long] + others).hits
        XCTAssertGreaterThanOrEqual(hits.count, 9)
        XCTAssertLessThanOrEqual(hits.prefix(12).filter { $0.unit.meetingID == long.id }.count, 3)
    }

    func testAQuestionNamingAPersonReadsTheirWordsAndCommitments() throws {
        let one = meeting("One", passages: [("s", "I'll send the comparison sheet to finance by Friday."), ("p", "I will rewrite the welcome email this week.")])
        let two = meeting("Two", passages: [("p", "Priya here, the comparison sheet looks fine to me.")])
        let found = try retrieve("What did Sam commit to about the comparison sheet?", [one, two])
        XCTAssertEqual(found.query.people, ["Sam"])
        XCTAssertTrue(found.query.filtersPeople)
        XCTAssertEqual(found.query.kind, .commitment)
        XCTAssertEqual(found.evidence?.conversations.map(\.meetingID), [one.id], "only conversations where Sam spoke")
        XCTAssertTrue(found.evidence?.conversations.first?.passages.contains { $0.text.contains("comparison sheet") } == true)
    }

    // MARK: Evidence

    func testEvidenceWidensEachChunkByAPassageAndKeepsLabelsTimesAndSpeakers() throws {
        let meeting = meeting("Pricing sync", passages: (0..<12).map { ("s", $0 == 6 ? "The zeppelin certification is done." : "filler passage number \($0) about nothing") })
        let evidence = try XCTUnwrap(try retrieve("zeppelin certification", [meeting] + filler()).evidence)
        let conversation = try XCTUnwrap(evidence.conversations.first)
        XCTAssertEqual(conversation.label, "C1")
        XCTAssertEqual(conversation.title, "Pricing sync")
        XCTAssertTrue(conversation.passages.contains { $0.text.contains("zeppelin") })
        XCTAssertTrue(conversation.passages.map(\.label).starts(with: ["P1", "P2"]))
        XCTAssertEqual(conversation.passages.map(\.time), conversation.passages.map(\.time).sorted(), "in the order they were said")
        XCTAssertEqual(conversation.passages.first?.speaker, "Sam")
        XCTAssertTrue(conversation.started.hasSuffix(TimeZone.current.identifier))
        XCTAssertTrue(evidence.today.contains(","))
    }

    func testAnUntitledConversationHasNoTitleInTheEvidence() throws {
        let meeting = meeting("Untitled meeting", passages: [("s", "The zeppelin is ready.")])
        XCTAssertNil(try retrieve("zeppelin", [meeting]).evidence?.conversations.first?.title)
    }

    func testNotesAndBookmarksAreEvidenceAndSummariesAreNot() throws {
        var meeting = meeting("Review", passages: [("s", "We talked about various unrelated matters today.")], notes: "The zeppelin budget is 40k")
        meeting.highlights = [Highlight(time: 5, text: "Zeppelin launch date")]
        meeting.summary = MeetingSummary(overview: "The zeppelin was approved.", sections: [], actionItems: [])
        let evidence = try XCTUnwrap(try retrieve("zeppelin", [meeting] + filler()).evidence)
        let conversation = try XCTUnwrap(evidence.conversations.first)
        XCTAssertEqual(conversation.notes.map(\.text), ["The zeppelin budget is 40k"])
        XCTAssertEqual(conversation.bookmarks.map(\.text), ["Zeppelin launch date"])
        XCTAssertFalse(AskSynthesis_payloadText(evidence).contains("approved"), "what a summary says is never given to the model")
    }

    func testTheBudgetCutsWhatTheModelIsGiven() throws {
        let meeting = meeting("Long", passages: (0..<200).map { ("s", [20, 100, 180].contains($0) ? "the zeppelin schedule is on the board with several extra words to take up room" : "line \($0) with several extra words to take up room in the budget") })
        var retriever = AskRetriever(index: LibraryPassageIndex())
        let library = [meeting] + filler()
        let whole = try XCTUnwrap(try retriever.retrieve("zeppelin schedule", scope: AskScope(), in: library).evidence)
        retriever.budget = 500
        let cut = try XCTUnwrap(try retriever.retrieve("zeppelin schedule", scope: AskScope(), in: library).evidence)
        XCTAssertLessThanOrEqual(cut.tokens, 500)
        XCTAssertGreaterThan(cut.tokens, 0)
        XCTAssertLessThan(cut.tokens, whole.tokens)
        XCTAssertLessThanOrEqual(whole.tokens, AskRetriever.defaultBudget)
    }

    func testNothingScoringAboveTheFloorMeansNoEvidenceAndNoModel() throws {
        let meeting = meeting("Review", passages: [("s", "We talked about the schedule today."), ("p", "Fine, the schedule works for me.")])
        let found = try retrieve("What is the refund policy for enterprise contracts?", [meeting])
        XCTAssertNil(found.evidence)
        XCTAssertTrue(found.hits.isEmpty)
        let none = try retrieve("anything at all", [])
        XCTAssertNil(none.evidence)
    }

    func testRetrievalStopsWhenCancelled() async {
        let meetings = (0..<50).map { meeting("M\($0)", passages: [("s", "zeppelin schedule number \($0)")]) }
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try self.retrieve("zeppelin", meetings); return false } catch is CancellationError { return true } catch { return false }
        }
        let stopped = await task.value
        XCTAssertTrue(stopped)
    }

    private func AskSynthesis_payloadText(_ evidence: AskEvidence) -> String {
        evidence.conversations.flatMap { $0.passages.map(\.text) + $0.notes.map(\.text) + $0.bookmarks.map(\.text) }.joined(separator: " ")
    }
}
