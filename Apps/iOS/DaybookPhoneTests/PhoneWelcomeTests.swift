import AVFAudio
import DaybookUI
import XCTest
@testable import DaybookPhone

/// The iPhone's Welcome: when it opens over the app, and what its Allow page reads from the microphone permission.
@MainActor
final class PhoneWelcomeTests: XCTestCase {
    private func shows(completed: Bool = false, arguments: [String] = ["DaybookPhone"], isTestHost: Bool = false,
                       conversations: Bool = false, pairedMac: Bool = false) -> Bool {
        PhoneWelcome.shouldPresent(completed: completed, arguments: arguments, isTestHost: isTestHost,
                                   hasConversations: conversations, hasPairedMac: pairedMac)
    }

    func testBehaviorWelcomeOpensOnceOnAFirstLaunch() {
        XCTAssertTrue(shows())
        XCTAssertFalse(shows(completed: true), "Once")
        XCTAssertFalse(shows(isTestHost: true), "Hosted tests never see it")
    }

    /// Someone who used Daybook on this iPhone before Welcome existed isn't welcomed now.
    func testBehaviorSomeoneAlreadyAtHomeIsntWelcomed() {
        XCTAssertFalse(shows(conversations: true))
        XCTAssertFalse(shows(pairedMac: true))
    }

    /// Demos and screenshots launch with options: Welcome stays out of their way unless asked for.
    func testBehaviorALaunchWithOptionsSeesWelcomeOnlyWhenItAsks() {
        XCTAssertFalse(shows(arguments: ["DaybookPhone", "--library-demo"]))
        XCTAssertTrue(shows(arguments: ["DaybookPhone", "--library-demo", "--welcome"]))
        XCTAssertFalse(shows(completed: true, arguments: ["DaybookPhone", "--welcome"]), "Done is done")
    }

    func testBehaviorTheAllowPageSaysWhatSettingsWould() {
        XCTAssertEqual(PhoneWelcome.state(.granted), .allowed)
        XCTAssertEqual(PhoneWelcome.state(.undetermined), .askable)
        XCTAssertEqual(PhoneWelcome.state(.denied), .openSettings)
        XCTAssertEqual(WelcomeWords.allow(.iPhone), "Allow")
        XCTAssertEqual(WelcomeWords.openSettings(.iPhone), "Open Settings")
    }
}
