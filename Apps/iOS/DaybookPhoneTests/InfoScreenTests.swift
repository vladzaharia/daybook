import DaybookKit
import DaybookUI
import SwiftUI
import XCTest
@testable import DaybookPhone

/// The iPhone's side of the screens it shares with the Mac: Info passes where a recording's audio is in the shared
/// form's terms and leaves out what it can't do yet, and Settings' Speaker Profiles row says what the Mac's says.
@MainActor
final class InfoScreenTests: XCTestCase {
    func testBehaviorInfoSaysWhereAudioIsInTheSharedFormsTerms() {
        XCTAssertEqual(ConversationInfo.reading(.local), .local)
        XCTAssertEqual(ConversationInfo.reading(.downloadable(bytes: 12_000_000)), .downloadable(bytes: 12_000_000))
        XCTAssertEqual(ConversationInfo.reading(.downloadable(bytes: nil)), .downloadable(bytes: nil))
        XCTAssertEqual(ConversationInfo.reading(.offline), .offline)
        XCTAssertEqual(ConversationInfo.reading(.missing), .missing)
    }

    func testBehaviorARecordingsActionsAreTheIPhonesOwn() {
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a")
        let dropped = RecordingTrack(source: .imported, relativePath: "Originals/b.m4a", fileName: "b.m4a")
        let meeting = Meeting(title: "Call", tracks: [mic, dropped])
        let context = ConversationInfo.context(meeting)
        XCTAssertEqual(context.platform, .iPhone)
        XCTAssertFalse(context.isProcessingHere, "nothing runs on this iPhone in a test")
        let offered = ConversationActions.track(dropped, in: meeting, context: context).flatMap(\.actions).map(\.id)
        XCTAssertTrue(offered.contains(.moveToNewConversation))
        XCTAssertTrue(offered.contains(.removeRecording))
        XCTAssertFalse(offered.contains(.showInFinder), "the Mac's own")
    }

    func testBehaviorSpeakerProfilesRowSaysWhatTheMacsSays() {
        XCTAssertEqual(SpeakerProfilesScreen.summary(0), "No profiles yet")
        XCTAssertEqual(SpeakerProfilesScreen.summary(1), "1 profile")
        XCTAssertEqual(SpeakerProfilesScreen.summary(3), SpeakerProfileWords.profiles(3))
    }
}
