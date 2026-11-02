import AppKit
import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// The library's recovery key and a refused cloud key, the same on both apps: the recovery key copies for this device
/// only, out of clipboard history, and goes after a while; a refusal never stays under a field it no longer describes.
@MainActor
final class SettingsSecretsTests: XCTestCase {
    func testBehaviorTheRecoveryKeyCopiesForThisDeviceOnlyAndExpires() {
        let key = RecoveryKey.generate()
        var copied: [(String, Duration?)] = []
        let services = ScreenServices(presentDetails: { _, _ in }, copyLocally: { text, expiresIn in copied.append((text, expiresIn)) })
        RecoveryKeyView.copy(key, services: services)
        XCTAssertEqual(copied.map(\.0), [key.text], "through the app's local copy, never the general pasteboard's setString")
        XCTAssertEqual(copied.first?.1, RecoveryKeyView.copyLifetime)
        XCTAssertEqual(RecoveryKeyView.copyLifetime, .seconds(120), "long enough to paste it into a password manager")
    }

    func testBehaviorALocalCopyIsConcealedTransientAndClearedWhenItExpires() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DaybookTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        LocalCopy.copy("WXYZ-1234", expiresIn: .milliseconds(150), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "WXYZ-1234")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(LocalCopy.concealedType), "clipboard managers don't show it")
        XCTAssertTrue(types.contains(LocalCopy.transientType), "clipboard managers don't keep it")
        let deadline = Date().addingTimeInterval(5)
        while pasteboard.string(forType: .string) != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(pasteboard.string(forType: .string), "gone once it expires")

        // Something copied since stays.
        LocalCopy.copy("WXYZ-1234", expiresIn: .milliseconds(100), to: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Later", forType: .string)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(pasteboard.string(forType: .string), "Later")
    }

    func testBehaviorLeavingTheKeyEditorForgetsARefusal() {
        let suite = "DaybookUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = CloudSetup.demo(providers: [], defaults: defaults,
                                    checks: [.anthropic: .failed(message: "Anthropic didn’t accept this key.", details: "HTTP 401")])
        XCTAssertNotNil(cloud.checks[.anthropic])
        CloudKeyEditor.leave(cloud, .anthropic)
        XCTAssertNil(cloud.checks[.anthropic], "reopened, the field is empty and nothing is said under it")

        let checking = CloudSetup.demo(providers: [], defaults: defaults, checks: [.openai: .checking])
        CloudKeyEditor.leave(checking, .openai)
        XCTAssertEqual(checking.checks[.openai], .checking, "a check under way finishes")
    }

    func testBehaviorCloudSettingsSayTheSameOnBothApps() {
        let suite = "DaybookUITests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = CloudSetup.demo(providers: [.anthropic], defaults: defaults)
        let recommended = cloud.offers.recommended(cloud.preferences.tier)
        XCTAssertNotNil(recommended)
        XCTAssertEqual(CloudModelPicker.recommendedTitle(recommended), "Recommended (\(recommended?.model.name ?? ""))")
        XCTAssertEqual(CloudModelPicker.recommendedTitle(nil), "Recommended")
        XCTAssertNil(CloudModelPicker.chosenCost(cloud), "Recommended's cost is on the tier's row")
        if let other = cloud.offers(in: cloud.preferences.tier).first(where: { $0.id != recommended?.id }) ?? cloud.offers.first {
            cloud.chosenModel = other.id
            XCTAssertNotNil(CloudModelPicker.chosenCost(cloud), "a chosen model's cost is under Model")
        }
        XCTAssertEqual(CloudSettingsForm.footer, "Sends the transcript and notes, never audio.")
        XCTAssertEqual(CloudSettingsForm.removalTitle(.anthropic), "Remove the Anthropic key?")
        XCTAssertEqual(CloudSettingsForm.removalMessage, "It’s removed from your other devices too.")
    }
}
