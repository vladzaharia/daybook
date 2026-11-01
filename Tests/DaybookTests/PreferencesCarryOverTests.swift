import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// The Mac app's settings across the bundle ID change: `local.daybook.app`'s preferences come over to `local.daybook`'s
/// once, at launch, and nothing is lost or overwritten.
final class PreferencesCarryOverTests: XCTestCase {
    private let earlierSettings: [String: Any] = [
        "onboardingCompleted": true,
        "syncDeviceID": "6F1C1B9E-3C0A-4E44-9E3E-0123456789AB",
        "syncInstallation": "0F9C2D4B-1A2B-4C3D-8E9F-0123456789AB",
        "syncDeviceIDInKeychain": true,
        "syncICloudAccount": Data([1, 2, 3]),
        "configuredDevices": Data("[]".utf8),
        "modelSelections": ["transcription": "parakeet-ultra"],
        "NSWindow Frame main": "0 0 100 100",
        "NSSplitView Subview Frames sidebar": ["0 0 200 600"],
    ]

    func testTheEarlierReleasesSettingsComeOverOnce() {
        let defaults = makeTestDefaults()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(PreferencesCarryOver.carryOver(earlierSettings, from: "local.daybook.app", into: defaults, now: at), 7)

        XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted"))
        XCTAssertEqual(defaults.string(forKey: "syncDeviceID"), "6F1C1B9E-3C0A-4E44-9E3E-0123456789AB")
        XCTAssertEqual(defaults.string(forKey: "syncInstallation"), "0F9C2D4B-1A2B-4C3D-8E9F-0123456789AB")
        XCTAssertTrue(defaults.bool(forKey: "syncDeviceIDInKeychain"))
        XCTAssertEqual(defaults.data(forKey: "syncICloudAccount"), Data([1, 2, 3]))
        XCTAssertNil(defaults.object(forKey: "syncICloudAccountApp"), "the account's app stays unknown: the earlier release's")
        XCTAssertEqual(defaults.dictionary(forKey: "modelSelections") as? [String: String], ["transcription": "parakeet-ultra"])
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame main"), "the system's window state stays behind")
        XCTAssertNil(defaults.object(forKey: "NSSplitView Subview Frames sidebar"))
        let record = defaults.dictionary(forKey: PreferencesCarryOver.carriedKey)
        XCTAssertEqual(record?["from"] as? String, "local.daybook.app")
        XCTAssertEqual(record?["at"] as? Date, at)
        XCTAssertEqual(record?["settings"] as? Int, 7)

        // Again: nothing, even with other settings there now.
        defaults.set(false, forKey: "onboardingCompleted")
        XCTAssertEqual(PreferencesCarryOver.carryOver(earlierSettings, from: "local.daybook.app", into: defaults), 0)
        XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted"))
    }

    /// The app already used under its own ID (the App Store build's preferences moved into its container, say): its
    /// settings stay as they are.
    func testSettingsTheAppAlreadyHasAreNeverReplaced() {
        let defaults = makeTestDefaults()
        defaults.set("A1B2C3D4-0000-0000-0000-000000000000", forKey: "syncDeviceID")
        XCTAssertEqual(PreferencesCarryOver.carryOver(earlierSettings, from: "local.daybook.app", into: defaults), 0)
        XCTAssertEqual(defaults.string(forKey: "syncDeviceID"), "A1B2C3D4-0000-0000-0000-000000000000")
        XCTAssertNil(defaults.object(forKey: "onboardingCompleted"))
        XCTAssertNil(defaults.object(forKey: PreferencesCarryOver.carriedKey))
    }

    func testNothingToCarryIsNoChange() {
        let defaults = makeTestDefaults()
        XCTAssertEqual(PreferencesCarryOver.carryOver(nil, from: "local.daybook.app", into: defaults), 0)
        XCTAssertEqual(PreferencesCarryOver.carryOver(["NSWindow Frame main": "0 0 1 1"], from: "local.daybook.app", into: defaults), 0)
        XCTAssertNil(defaults.object(forKey: PreferencesCarryOver.carriedKey))
        // Something to carry later (the earlier release ran meanwhile): it still comes over.
        XCTAssertEqual(PreferencesCarryOver.carryOver(["onboardingCompleted": true], from: "local.daybook.app", into: defaults), 1)
    }

    /// Only the app itself carries settings over: never a test, `swift run`, or another build.
    func testOnlyTheAppCarriesItsSettingsOver() {
        let defaults = makeTestDefaults()
        PreferencesCarryOver.atLaunch(bundle: .main, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: PreferencesCarryOver.carriedKey))
    }
}
