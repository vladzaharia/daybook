import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// A person token finds the conversations the person spoke in by voice profile, not by the label alone.
final class SearchPeopleTests: XCTestCase {
    private let maya = SpeakerProfile(id: SpeakerProfile.id(forName: "Maya Chen"), name: "Maya Chen")

    private func people(_ profiles: [SpeakerProfile]) -> SearchPeople {
        var metadata = LibraryMetadata()
        metadata.speakerProfiles = profiles.map { LibraryValue(id: $0.id.uuidString, value: $0) }
        return SearchPeople(metadata)
    }

    private func meeting(_ title: String, daysAgo: Int = 0, label: String, profile: UUID? = nil,
                         source: SpeakerIdentity.Source = .named) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.date = Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400)
        meeting.speakers = [Speaker(id: "S1", name: label)]
        if let profile { meeting.setSpeakerIdentity(SpeakerIdentity(speakerID: "S1", profileID: profile, source: source), for: "S1") }
        return meeting
    }

    private func found(_ people: SearchPeople, _ meetings: [Meeting], text: String = "") -> [String] {
        let hits = LibrarySearch.hits(in: meetings, text: text, tokens: [.speaker("Maya Chen")], scope: .all, people: people)
        return hits.compactMap { hit in meetings.first { $0.id == hit.meetingID }?.title }
    }

    func testBehaviorAProfileFindsConversationsWhateverTheSpeakerWasCalledNewestFirst() {
        let older = meeting("Older", daysAgo: 9, label: "M.", profile: maya.id)
        let newer = meeting("Newer", daysAgo: 1, label: "Maya Chen", profile: maya.id)
        let other = meeting("Other", label: "Priya")
        XCTAssertEqual(found(people([maya]), [older, other, newer]), ["Newer", "Older"])
    }

    func testBehaviorASpeakerWithNoProfileCountsByItsExactName() {
        let unprofiled = meeting("Unprofiled", label: "maya chen")
        let near = meeting("Near", label: "Maya")
        XCTAssertEqual(found(people([maya]), [unprofiled, near]), ["Unprofiled"])
        XCTAssertEqual(found(.none, [unprofiled, near]), ["Unprofiled"], "Without profiles the name still works")
    }

    func testBehaviorASuggestionOnlyIsNotTheProfileButAMergedProfileIsThePerson() {
        let suggested = meeting("Suggested", label: "Speaker 1", profile: maya.id, source: .suggested)
        var duplicate = SpeakerProfile(id: SpeakerProfile.id(forName: "M Chen"), name: "M Chen")
        duplicate.mergedInto = maya.id
        let viaDuplicate = meeting("Via duplicate", label: "M Chen", profile: duplicate.id, source: .confirmed)
        XCTAssertEqual(found(people([maya, duplicate]), [suggested, viaDuplicate]), ["Via duplicate"])
    }

    func testBehaviorTheMergedProfilesNameFindsTheSamePerson() {
        var duplicate = SpeakerProfile(id: SpeakerProfile.id(forName: "M Chen"), name: "M Chen")
        duplicate.mergedInto = maya.id
        let one = meeting("One", label: "Renamed", profile: maya.id)
        let hits = LibrarySearch.hits(in: [one], text: "", tokens: [.speaker("m chen")], scope: .all, people: people([maya, duplicate]))
        XCTAssertEqual(hits.count, 1)
    }

    func testBehaviorTypedWordsSearchWithinThePersonsConversations() {
        var withWord = meeting("Budget", label: "M.", profile: maya.id)
        withWord.notes = "The budget is approved"
        let without = meeting("Planning", label: "M.", profile: maya.id)
        var elsewhere = meeting("Elsewhere", label: "Priya")
        elsewhere.notes = "The budget slipped"
        XCTAssertEqual(found(people([maya]), [withWord, without, elsewhere], text: "budget"), ["Budget"])
    }

    func testBehaviorSuggestionsOfferAProfilesNameOnceEvenWhenNoLabelUsesIt() {
        let meetings = [meeting("A", label: "M.", profile: maya.id), meeting("B", label: "maya chen")]
        XCTAssertEqual(LibrarySearchSuggestions.tokens(for: "Maya", tags: [], meetings: meetings, people: people([maya])), [.speaker("Maya Chen")])
    }
}
