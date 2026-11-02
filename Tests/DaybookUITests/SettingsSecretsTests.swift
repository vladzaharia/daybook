import AppKit
import DaybookKit
import Foundation
import XCTest
@testable import DaybookUI

/// The library's recovery key and a refused cloud key, the same on both apps: the recovery key copies for this device
/// only, out of clipboard history, and goes after a while; a refusal never stays under a field it no longer describes.
@MainActor
final class SettingsSecretsTests: XCTestCase {
    /// A preferences suite named by a path in the temporary directory, so it leaves nothing in ~/Library/Preferences.
    private static func scratchSuite() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("DaybookUITests-\(UUID().uuidString)").path
    }

    func testBehaviorTheRecoveryKeyCopiesForThisDeviceOnlyAndExpires() {
        let key = RecoveryKey.generate()
        var copied: [(String, Duration?)] = []
        let services = ScreenServices(presentDetails: { _, _ in }, copyLocally: { text, expiresIn in copied.append((text, expiresIn)) })
        RecoveryKeyView.copy(key, services: services)
        XCTAssertEqual(copied.map(\.0), [key.text], "through the app's local copy, never the general pasteboard's setString")
        XCTAssertEqual(copied.first?.1, RecoveryKeyView.copyLifetime)
        XCTAssertEqual(RecoveryKeyView.copyLifetime, .seconds(120), "long enough to paste it into a password manager")
    }

    /// Copy is the only way to copy the recovery key: the key can't be selected, so the system's Copy (⌘C, a long
    /// press) never puts it on the general pasteboard, nearby devices, or clipboard history.
    func testBehaviorTheRecoveryKeyCantBeSelectedOnlyCopied() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DaybookUI/Settings/ICloud/LibraryEncryptionViews.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public struct RecoveryKeyView"))
        let end = source.range(of: "\npublic struct ", range: start.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        let view = source[start.lowerBound..<end]
        XCTAssertTrue(view.contains("Self.copy(key, services: services)"))
        XCTAssertFalse(view.contains(".textSelection("), "the key's text isn't selectable")
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
        let suite = Self.scratchSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(atPath: suite + ".plist") }
        let cloud = CloudSetup.demo(providers: [], defaults: defaults,
                                    checks: [.anthropic: .failed(message: "Anthropic didn’t accept this key.", details: "HTTP 401")])
        XCTAssertNotNil(cloud.checks[.anthropic])
        CloudKeyEditor.leave(cloud, .anthropic)
        XCTAssertNil(cloud.checks[.anthropic], "reopened, the field is empty and nothing is said under it")

        let checking = CloudSetup.demo(providers: [], defaults: defaults, checks: [.openai: .checking])
        CloudKeyEditor.leave(checking, .openai)
        XCTAssertNil(checking.checks[.openai], "a check under way is dropped (CloudDirectoryTests: nothing is kept or said after)")

        let works = CloudSetup.demo(providers: [.anthropic], defaults: defaults, checks: [.anthropic: .works])
        CloudKeyEditor.leave(works, .anthropic)
        XCTAssertEqual(works.checks[.anthropic], .works, "a key just kept still says “This key works” on its row")
    }

    func testBehaviorCloudSettingsSayTheSameOnBothApps() {
        let suite = Self.scratchSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(atPath: suite + ".plist") }
        let cloud = CloudSetup.demo(providers: [.anthropic], defaults: defaults)
        let recommended = cloud.offers.recommended(cloud.preferences.tier)
        XCTAssertNotNil(recommended)
        XCTAssertEqual(CloudModelPicker.recommendedTitle(recommended), "Recommended (\(recommended?.model.name ?? ""))")
        XCTAssertEqual(CloudModelPicker.recommendedTitle(nil), "Recommended")
        XCTAssertNil(CloudModelPicker.chosenCost(cloud), "Recommended's cost is on the tier's row")
        XCTAssertEqual(CloudModelPicker.currentTitle(cloud), "Recommended", "the iPhone's row: the tier's row above names the model")
        if let other = cloud.offers(in: cloud.preferences.tier).first(where: { $0.id != recommended?.id }) ?? cloud.offers.first {
            cloud.chosenModel = other.id
            XCTAssertNotNil(CloudModelPicker.chosenCost(cloud), "a chosen model's cost is under Model")
            XCTAssertEqual(CloudModelPicker.currentTitle(cloud), other.model.name)
        }
        XCTAssertEqual(CloudSettingsForm.footer, "Sends the transcript and notes, never audio.")
        XCTAssertEqual(CloudSettingsForm.removalTitle(.anthropic), "Remove the Anthropic key?")
        XCTAssertEqual(CloudSettingsForm.removalMessage, "It’s removed from your other devices too.")
    }
}
