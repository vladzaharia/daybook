import XCTest
@testable import DaybookKit

/// The Personal lock's words, which both apps say (`PersonalLockWords`): the hidden row, Settings' switch in each
/// app's case and its one footer line, the prompt's reason in each platform's grammar, and the Focus filter's summary.
final class PersonalLockWordsTests: XCTestCase {
    func testBehaviorAHiddenRowSaysOnlyThatItsPersonal() {
        XCTAssertEqual(PersonalLockWords.hiddenTitle, "Personal conversation")
        XCTAssertEqual(PersonalLockWords.unlock, "Unlock")
        XCTAssertEqual(PersonalLockWords.locked, "Locked")
        XCTAssertEqual(PersonalLockWords.symbol, "lock")
    }

    func testBehaviorSettingsNamesWhatTheDeviceUnlocksWithInEachAppsCase() {
        XCTAssertEqual(PersonalLockWords.requirement(.touchID), "Require Touch ID for Personal", "the Mac, in sentence case")
        XCTAssertEqual(PersonalLockWords.requirement(.password), "Require password for Personal", "a Mac without Touch ID")
        XCTAssertEqual(SettingsWords.titleCased(PersonalLockWords.requirement(.faceID)), "Require Face ID for Personal",
                       "the iPhone title-cases it where it draws it")
        XCTAssertEqual(SettingsWords.titleCased(PersonalLockWords.requirement(.passcode)), "Require Passcode for Personal")
        XCTAssertEqual(PersonalLockWords.requirement(.opticID), "Require Optic ID for Personal")
        XCTAssertEqual(PersonalLockWords.footer, "Personal conversations stay hidden until you unlock them.",
                       "one line: what it covers")
    }

    func testBehaviorThePromptsReasonFitsEachPlatformsSentence() {
        // The Mac shows “Daybook” is trying to <reason>.
        XCTAssertEqual(PersonalLockWords.reason(.mac), "show Personal conversations")
        XCTAssertEqual(PersonalLockWords.reason(.iPhone), "Show Personal conversations")
    }

    func testBehaviorTheFocusFilterSaysWhatItChanges() {
        XCTAssertEqual(PersonalLockWords.focusFilter, "Daybook")
        XCTAssertEqual(PersonalLockWords.showPersonal, "Show Personal")
        XCTAssertEqual(PersonalLockWords.askToRecord, "Ask to Record Meetings")
        XCTAssertEqual(PersonalLockWords.focusSummary(PersonalFocus()), "Shows everything")
        XCTAssertEqual(PersonalLockWords.focusSummary(PersonalFocus(showsPersonal: false)), "Hides Personal")
        XCTAssertEqual(PersonalLockWords.focusSummary(PersonalFocus(asksToRecord: false)), "Doesn’t ask to record")
        XCTAssertEqual(PersonalLockWords.focusSummary(PersonalFocus(showsPersonal: false, asksToRecord: false)),
                       "Hides Personal · Doesn’t ask to record")
    }
}
