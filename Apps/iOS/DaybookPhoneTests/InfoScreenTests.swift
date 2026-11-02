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

    /// Regression: the iPhone offered Remove and Move while a Mac transcribed the conversation, whose work on the
    /// recording could then undo the removal. While a Mac has it, or it waits for one, neither is offered.
    func testBehaviorARecordingStaysWhileAMacProcessesIt() {
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a")
        let dropped = RecordingTrack(source: .imported, relativePath: "Originals/b.m4a", fileName: "b.m4a")
        var meeting = Meeting(title: "Call", tracks: [mic, dropped])
        let now = Date()
        var request = ProcessingRequest(meetingID: meeting.id, mode: .newAudio, requestedBy: .init(id: "phone", name: "iPhone"))
        meeting.processingRequests = [request]
        func offered() -> [ConversationAction] {
            ConversationActions.track(dropped, in: meeting, context: ConversationInfo.context(meeting))
                .flatMap(\.actions).filter(\.isAvailable)
        }
        XCTAssertFalse(offered().contains { $0.id == .removeRecording || $0.id == .moveToNewConversation }, "waiting for a Mac")
        request.claim = .init(device: .init(id: "mac", name: "Studio Mac"), claimedAt: now, heartbeat: now,
                              expiresAt: now.addingTimeInterval(600), stage: .transcribing)
        meeting.processingRequests = [request]
        XCTAssertFalse(offered().contains { $0.id == .removeRecording || $0.id == .moveToNewConversation }, "the Mac is transcribing it")
        XCTAssertTrue(offered().contains { $0.id == .play })
        meeting.processingRequests = []
        XCTAssertTrue(offered().contains { $0.id == .removeRecording }, "nothing asked for: it can come out")
    }

    func testBehaviorSpeakerProfilesRowSaysWhatTheMacsSays() {
        XCTAssertEqual(SpeakerProfilesScreen.summary(0), "No profiles yet")
        XCTAssertEqual(SpeakerProfilesScreen.summary(1), "1 profile")
        XCTAssertEqual(SpeakerProfilesScreen.summary(3), SpeakerProfileWords.profiles(3))
    }
}
