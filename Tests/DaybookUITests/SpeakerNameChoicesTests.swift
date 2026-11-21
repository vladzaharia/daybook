import DaybookCore
import XCTest
@testable import DaybookUI

/// The rows under a speaker's name field: which profiles, in what order, and when Add “<name>” closes the list.
final class SpeakerNameChoicesTests: XCTestCase {
    private func profile(_ name: String, mergedInto: UUID? = nil) -> SpeakerProfile {
        SpeakerProfile(id: SpeakerProfile.id(forName: name), name: name, mergedInto: mergedInto)
    }

    private func names(_ rows: [SpeakerNameChoice]) -> [String] { rows.map { $0.kind == .add ? "Add “\($0.name)”" : $0.name } }

    func testBehaviorEveryActiveProfileIsListedWithMeFirstThenAlphabetically() {
        let profiles = [profile("Zoe"), profile("émile"), profile("Adam"), profile("vlad")]
        let me = profile("vlad").id
        let rows = SpeakerNameChoices.rows(profiles: profiles, me: me, query: "")
        XCTAssertEqual(names(rows), ["vlad", "Adam", "émile", "Zoe"])
        XCTAssertEqual(rows.map(\.isMe), [true, false, false, false])
    }

    func testBehaviorMergedAwayProfilesAndPlaceholdersAreNeverListed() {
        let target = profile("Vlad")
        let profiles = [target, profile("Vladimir", mergedInto: target.id), profile("Speaker 3"), profile("  ")]
        XCTAssertEqual(names(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "")), ["Vlad"])
    }

    func testBehaviorTypingFiltersWithoutCaseOrAccents() {
        let profiles = [profile("Renée"), profile("Adam"), profile("Zoe")]
        XCTAssertEqual(names(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: " RENE")), ["Renée", "Add “RENE”"])
    }

    func testBehaviorPrefixMatchesComeBeforeSubstringMatches() {
        let profiles = [profile("Anna"), profile("Joanna"), profile("Ann Lee"), profile("Bob")]
        let rows = SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "ann")
        XCTAssertEqual(names(rows), ["Ann Lee", "Anna", "Joanna", "Add “ann”"])
    }

    func testBehaviorMeStaysFirstWhenTheyMatchOnlyBySubstring() {
        let profiles = [profile("Anna"), profile("Joanna")]
        let rows = SpeakerNameChoices.rows(profiles: profiles, me: profile("Joanna").id, query: "ann")
        XCTAssertEqual(names(rows).prefix(2), ["Joanna", "Anna"])
    }

    func testBehaviorAddRowClosesTheListOnlyForANewRealName() {
        let profiles = [profile("Vlad")]
        XCTAssertEqual(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "Vla").last?.kind, .add)
        XCTAssertEqual(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "Vla").last?.name, "Vla")
        XCTAssertFalse(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "vlad").contains { $0.kind == .add }, "an exact match adds nothing")
        XCTAssertFalse(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "").contains { $0.kind == .add }, "empty adds nothing")
        XCTAssertFalse(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "  ").contains { $0.kind == .add })
        XCTAssertFalse(SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "Speaker 3").contains { $0.kind == .add }, "a placeholder is never a person")
        XCTAssertEqual(names(SpeakerNameChoices.rows(profiles: [], me: nil, query: "Sam")), ["Add “Sam”"])
    }

    func testBehaviorAMergedAwayNameCanBeAddedAgainNoProfileHoldsIt() {
        let target = profile("Vlad")
        let rows = SpeakerNameChoices.rows(profiles: [target, profile("Vladimir", mergedInto: target.id)], me: nil, query: "Vladimir")
        XCTAssertEqual(rows.map(\.kind), [.add])
    }

    func testBehaviorALimitedListKeepsTheAddRow() {
        let profiles = ["Anna", "Ann Lee", "Joanna", "Annie"].map { profile($0) }
        let rows = SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "ann")
        XCTAssertEqual(names(SpeakerNameChoices.limited(rows, to: 3)), ["Ann Lee", "Anna", "Add “ann”"])
        XCTAssertEqual(SpeakerNameChoices.limited(rows, to: 9), rows, "a short list is whole")
        let all = SpeakerNameChoices.rows(profiles: profiles, me: nil, query: "")
        XCTAssertEqual(SpeakerNameChoices.limited(all, to: 3).count, 3)
    }
}
