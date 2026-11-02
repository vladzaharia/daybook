import AVFoundation
import DaybookCore
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// The Mac's Welcome: Record waiting for the library, the quality page's free-space check, and the Allow page's
/// permissions, against temporary libraries and a scripted system.
@MainActor
final class WelcomeTests: XCTestCase {
    private func unopened() -> AppState {
        AppState(libraryURL: makeTemporaryFolder("DaybookWelcome"), defaults: makeTestDefaults("local.daybook.tests.welcome"))
    }

    /// What a wait has answered so far, nil while it waits.
    @MainActor private final class Answer {
        var value: Bool?
    }

    private func waitForLibrary(_ state: AppState) -> (Answer, Task<Void, Never>) {
        let answer = Answer()
        return (answer, Task { answer.value = await LibraryOpening.opens(state) })
    }

    /// A slow first launch: Record waits for the library however long it takes, then records (MSQ-24).
    func testBehaviorRecordWaitsForTheLibraryHoweverLongItTakes() async throws {
        let state = unopened()
        let (answer, waiting) = waitForLibrary(state)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(answer.value, "Still waiting while the library opens, and it hasn't given up")
        await state.initialize()
        await waiting.value
        XCTAssertEqual(answer.value, true)
        // Open already: at once.
        let again = await LibraryOpening.opens(state)
        XCTAssertTrue(again)
        await state.flush()
    }

    /// A library move holds the library until the person answers: Record stops waiting and records nothing.
    func testBehaviorRecordStopsWaitingWhenAMoveHoldsTheLibrary() async throws {
        let state = unopened()
        let (answer, waiting) = waitForLibrary(state)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(answer.value)
        let folder = makeTemporaryFolder("DaybookWelcomeMove")
        state.libraryMoveOffer = .moveIntoContainer(SandboxMigration.MovePlan(legacy: folder, library: folder, legacyExists: true))
        await waiting.value
        XCTAssertEqual(answer.value, false)
        XCTAssertNil(state.recordingID)
        // An old copy left behind is only a warning: it doesn't hold the library, so Record waits on.
        state.libraryMoveOffer = .oldCopyRemains(folder)
        let (second, waitingAgain) = waitForLibrary(state)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(second.value)
        await state.initialize()
        await waitingAgain.value
        XCTAssertEqual(second.value, true)
        await state.flush()
    }

    /// A library that couldn't open says so in the window: Record stops waiting.
    func testBehaviorRecordStopsWaitingWhenTheLibraryCantOpen() async throws {
        let state = unopened()
        let (answer, waiting) = waitForLibrary(state)
        try await Task.sleep(for: .milliseconds(50))
        state.report("Couldn’t Open Your Library", "Quit Daybook and open it again.", CocoaError(.fileReadNoPermission))
        await waiting.value
        XCTAssertEqual(answer.value, false)
    }

    /// The quality page compares what a preset still needs with the free space: one that doesn't fit says
    /// "Needs 16.5 GB · 12 GB free", and one already downloaded needs nothing (ux-mac-16's Welcome half).
    func testBehaviorAPresetTheDiskCantHoldSaysWhatItNeeds() async throws {
        let state = unopened()
        await state.initialize()
        let preset = ModelPreset.balanced
        let needed = WelcomeQualityFit.needed(preset, in: state)
        XCTAssertGreaterThan(needed, 0, "Nothing is downloaded in a new library")
        XCTAssertTrue(WelcomeQualityFit.fits(preset, in: state, free: nil), "Unknown free space doesn't stop a download")
        XCTAssertTrue(WelcomeQualityFit.fits(preset, in: state, free: needed))
        XCTAssertNil(WelcomeQualityFit.shortfall(preset, in: state, free: needed))
        XCTAssertFalse(WelcomeQualityFit.fits(preset, in: state, free: needed - 1))
        XCTAssertEqual(WelcomeQualityFit.shortfall(preset, in: state, free: 12_000_000_000),
                       needed > 12_000_000_000 ? "Needs \(ModelSize.format(needed)) · 12.0 GB free" : nil)
        XCTAssertEqual(WelcomeWords.needsSpace("16.5 GB", free: "12.0 GB"), "Needs 16.5 GB · 12.0 GB free")

        // What's on this Mac already isn't counted again.
        state.installedModels = Set(preset.downloadKeys(in: state))
        XCTAssertEqual(WelcomeQualityFit.needed(preset, in: state), 0)
        XCTAssertTrue(WelcomeQualityFit.fits(preset, in: state, free: 0))
        await state.flush()
    }

    func testBehaviorFreeSpaceIsReadWhereTheModelsWillGo() throws {
        let folder = makeTemporaryFolder("DaybookWelcomeSpace")
        // The models folder doesn't exist yet: its volume is read through its parent.
        let free = WelcomeDiskSpace.available(at: folder.appendingPathComponent("Models/Not Yet", isDirectory: true))
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
    }

    /// The Allow page says what Settings › General › Permissions says, and asks the same way.
    func testBehaviorTheAllowPageAsksForEachPermissionAsSettingsDoes() async throws {
        let defaults = makeTestDefaults("local.daybook.tests.welcome")
        var microphone = AVAuthorizationStatus.notDetermined
        var screenAllowed = false
        var asked: [String] = []
        var opened: [PrivacySettings.Pane] = []
        let system = CapturePermissions.System(
            microphoneStatus: { microphone },
            requestMicrophone: { asked.append("microphone"); microphone = .denied; return false },
            screenCaptureAllowed: { screenAllowed },
            requestScreenCapture: { asked.append("screen"); return false },
            openSettings: { opened.append($0) })
        let permissions = CapturePermissions(system: system, defaults: defaults)
        XCTAssertEqual(permissions.microphone, .askable)
        XCTAssertEqual(permissions.computerAudio, .askable)

        await permissions.allowMicrophone()
        XCTAssertEqual(asked, ["microphone"])
        XCTAssertEqual(permissions.microphone, .openSettings, "Declined: only System Settings can change it now")
        permissions.openSettings(for: .microphone)

        permissions.allowComputerAudio()
        XCTAssertEqual(asked, ["microphone", "screen"])
        XCTAssertTrue(defaults.bool(forKey: CapturePermissions.screenCaptureRequestedKey), "Settings sees it was asked")
        XCTAssertEqual(permissions.computerAudio, .openSettings, "macOS asks once; then it's System Settings")
        permissions.allowComputerAudio()
        XCTAssertEqual(asked.count, 2, "Never asked twice")
        permissions.openSettings(for: .computerAudio)
        XCTAssertEqual(opened, [.microphone, .screenCapture])

        // Allowed in System Settings, then back: the page reads them again.
        microphone = .authorized
        screenAllowed = true
        permissions.refresh()
        XCTAssertEqual(permissions.microphone, .allowed)
        XCTAssertEqual(permissions.computerAudio, .allowed)
    }

    func testBehaviorPermissionStatesMatchSettings() {
        XCTAssertEqual(CapturePermissions.state(microphone: .authorized), .allowed)
        XCTAssertEqual(CapturePermissions.state(microphone: .notDetermined), .askable)
        XCTAssertEqual(CapturePermissions.state(microphone: .denied), .openSettings)
        XCTAssertEqual(CapturePermissions.state(microphone: .restricted), .openSettings)
        XCTAssertEqual(CapturePermissions.state(screenCaptureAllowed: true, requested: true), .allowed)
        XCTAssertEqual(CapturePermissions.state(screenCaptureAllowed: false, requested: false), .askable)
        XCTAssertEqual(CapturePermissions.state(screenCaptureAllowed: false, requested: true), .openSettings)
    }
}
