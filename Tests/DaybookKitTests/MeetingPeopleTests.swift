import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// A conversation's people, as both apps' People list them: background voices left out, shares of the talking
/// shown, and the pickers' automatic items carrying their guess.
final class MeetingPeopleTests: XCTestCase {
    func testBehaviorABackgroundVoiceIsntOneOfThePeopleAndSharesAreOfThoseShown() {
        let track = UUID()
        var meeting = Meeting(title: "Evening call",
                              unifiedTranscript: [TranscriptSegment(trackID: track, start: 0, end: 30, text: "Hello", speakerID: "alex"),
                                                  TranscriptSegment(trackID: track, start: 30, end: 40, text: "Hi", speakerID: "sam")],
                              speakers: [Speaker(id: "tv", name: "Speaker 1"), Speaker(id: "alex", name: "Alex"), Speaker(id: "sam", name: "Sam")])
        // The presenter only ever spoke in what was left out as background audio.
        meeting.backgroundPassages = [TranscriptSegment(trackID: track, start: 40, end: 100, text: "Tonight's news", speakerID: "tv")]
        XCTAssertEqual(meeting.talkTime(of: "alex"), 30)
        XCTAssertEqual(meeting.talkTime(of: "tv"), 0, "background audio isn't talk in the transcript")
        let people = meeting.peopleSpeakers
        XCTAssertEqual(meeting.backgroundOnlySpeakerIDs, ["tv"])
        XCTAssertEqual(people.map(\.speaker.name), ["Alex", "Sam"])
        XCTAssertEqual(people.map(\.index), [1, 2], "inks keep their places")
        XCTAssertEqual(people.first { $0.speaker.id == "alex" }?.share ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(people.first { $0.speaker.id == "sam" }?.share ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertTrue(Meeting(title: "Quiet").peopleSpeakers.isEmpty)
    }

    func testBehaviorTheAutomaticItemsCarryTheirGuess() {
        var meeting = Meeting(title: "Sync")
        XCTAssertEqual(meeting.automaticTemplateTitle, "Automatic")
        XCTAssertEqual(meeting.automaticPlacementTitle, "Automatic", "a kind not known yet goes nowhere by guess")
        meeting.summary = MeetingSummary(kind: .general, title: "Sync", overview: "Done")
        XCTAssertEqual(meeting.automaticTemplateTitle, "Automatic (\(MeetingKind.general.title))")
        XCTAssertEqual(meeting.automaticPlacementTitle, "Work (automatic)")
        meeting.placement = .personal
        XCTAssertEqual(meeting.automaticPlacementTitle, "Work (automatic)", "the person's choice doesn't change the guess")
    }
}
