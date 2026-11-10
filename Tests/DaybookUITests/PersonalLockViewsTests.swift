import DaybookKit
import XCTest
@testable import DaybookUI

/// Proves it's the owner at once.
private struct Agreeing: PersonalLockAuthenticating {
    let method = PersonalLockMethod.faceID
    func authenticate(reason: String) async -> Bool { true }
}

/// How the lists and pages both apps draw look while the Personal lock hides a conversation: a row, a search result,
/// and a Trash row say "Personal conversation" with nothing of its words, VoiceOver says it's locked, and the
/// iPhone's cover shows only while Personal is unlocked and the app isn't in front.
@MainActor
final class PersonalLockViewsTests: XCTestCase {
    private func personal() -> Meeting {
        var meeting = Meeting(title: "Session with Dr. Lee")
        meeting.placement = .personal
        meeting.summary = MeetingSummary(kind: .therapy, overview: "We talked about the move.")
        meeting.tags = ["family"]
        return meeting
    }

    func testBehaviorAHiddenRowReadsAsPersonalConversationWithItsTimeOnly() {
        let meeting = personal()
        let hidden = ConversationRowView.spokenLabel(meeting, status: nil, timeLabel: "9:41 AM", hidden: true)
        XCTAssertEqual(hidden, "Personal conversation, 9:41 AM, Locked")
        XCTAssertFalse(hidden.contains("Dr. Lee"))
        XCTAssertFalse(hidden.contains("move"), "no gist")
        XCTAssertFalse(hidden.contains("family"), "no tags")
        let busy = ConversationRowStatus(kind: .processing, text: "Transcribing · 40%", fraction: 0.4)
        XCTAssertEqual(ConversationRowView.spokenLabel(meeting, status: busy, timeLabel: "9:41 AM", hidden: true),
                       "Personal conversation, 9:41 AM, Transcribing · 40%, Locked", "what's happening to it still shows")
        XCTAssertTrue(ConversationRowView.spokenLabel(meeting, status: nil, timeLabel: "9:41 AM").hasPrefix("Session with Dr. Lee"),
                      "unlocked, as ever")
    }

    func testBehaviorAHiddenSearchResultKeepsNothingOfWhatWasFound() {
        let layout = SearchResultLayout.hidden(date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(layout.hidden)
        XCTAssertEqual(String(layout.title.characters), PersonalLockWords.hiddenTitle)
        XCTAssertNil(layout.snippet, "no snippet")
        XCTAssertEqual(layout.location, "", "nor where it was found")
    }

    func testBehaviorTheIPhonesCoverShowsOnlyWhilePersonalIsUnlockedAndTheAppIsntInFront() async throws {
        // A suite named by a path keeps its file there, out of ~/Library/Preferences.
        let suite = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalLockViewsTests.\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: suite + ".plist") }
        let lock = PersonalLock(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), platform: .iPhone, authenticator: Agreeing())
        XCTAssertFalse(PersonalLockCover.shows(lock, isActive: false), "off: nothing to cover")
        await lock.setRequired(true)
        XCTAssertFalse(PersonalLockCover.shows(lock, isActive: false), "locked: nothing Personal shows")
        await lock.unlock()
        XCTAssertTrue(PersonalLockCover.shows(lock, isActive: false), "unlocked, in the app switcher")
        XCTAssertFalse(PersonalLockCover.shows(lock, isActive: true), "in front")
    }
}
