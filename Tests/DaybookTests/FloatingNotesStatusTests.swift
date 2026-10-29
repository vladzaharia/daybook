import AppKit
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import SwiftUI
import XCTest
@testable import Daybook

/// What Floating Notes' status bar and home lines say in each state
/// (`FloatingStatus`), read from plain inputs as the iPhone's status-sheet tests do.
final class FloatingNotesStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func soundcore(_ state: ConnectionState = .connected, battery: Int? = 80) -> FloatingStatusInputs.Recorder {
        var recorder = FloatingStatusInputs.Recorder(id: "sc", name: "Soundcore Work", shortName: "Soundcore",
                                                     symbol: "waveform.badge.microphone", state: state)
        recorder.isLinked = state == .connected
        recorder.battery = battery
        return recorder
    }

    private func phone(connected: Bool = true) -> FloatingStatusInputs.Phone {
        FloatingStatusInputs.Phone(id: "ph", name: "Alex’s iPhone", isConnected: connected)
    }

    private func recording(_ change: (inout FloatingStatusInputs) -> Void = { _ in }) -> FloatingStatusInputs {
        var inputs = FloatingStatusInputs()
        inputs.phase = .recording
        inputs.inputDevice = "MacBook Pro Microphone"
        change(&inputs)
        return inputs
    }

    // MARK: Phase

    func testRecordingPhaseNamesTheInputDeviceUntilTheMicrophoneIsSilent() {
        XCTAssertEqual(FloatingStatus.phase(recording()), FloatingPhase(phase: .recording, title: "Recording", detail: "MacBook Pro Microphone"))
        let silent = FloatingStatus.phase(recording { $0.microphoneSilent = true })
        XCTAssertEqual(silent?.detail, "Microphone silent", "as the iPhone says it")
        XCTAssertEqual(silent?.detailIsWarning, true)
    }

    func testPhaseAfterStopAndWhenIdle() {
        var inputs = FloatingStatusInputs()
        XCTAssertNil(FloatingStatus.phase(inputs), "Nothing recording: the band stays quiet")
        inputs.phase = .saved
        inputs.duration = 761
        XCTAssertEqual(FloatingStatus.phase(inputs), FloatingPhase(phase: .saved, title: "Saved", detail: "12:41"))
        inputs.phase = .stopped
        XCTAssertEqual(FloatingStatus.phase(inputs)?.phase, .stopped)
    }

    // MARK: Chips

    func testCallChipFollowsTheCallTrack() {
        XCTAssertNil(FloatingStatus.callChip(.off))
        XCTAssertEqual(FloatingStatus.callChip(.detected)?.tone, .linked)
        XCTAssertEqual(FloatingStatus.callChip(.quiet)?.tone, .calm)
        let missing = FloatingStatus.callChip(.missing)
        XCTAssertEqual(missing?.tone, .attention)
        XCTAssertEqual(missing?.label, "No call audio")
        XCTAssertTrue(missing?.detail.contains("Screen & System Audio Recording") == true, "A missing call says how to fix it")
    }

    func testCallChipOnlyWhileRecording() {
        var inputs = recording { $0.call = .detected }
        XCTAssertEqual(FloatingStatus.chips(inputs).first?.target, .call)
        inputs.phase = .saved
        XCTAssertFalse(FloatingStatus.chips(inputs).contains { $0.target == .call })
    }

    func testConnectedRecorderShowsBatteryAndTheDotWhenRecordingAlong() {
        let connected = FloatingStatus.recorderChip(soundcore(), recording: true)
        XCTAssertEqual(connected?.label, "Soundcore · 80%")
        XCTAssertEqual(connected?.shortLabel, "80%")
        XCTAssertEqual(connected?.tone, .linked)
        XCTAssertEqual(connected?.showsDot, false)
        XCTAssertEqual(connected?.detail, "Soundcore Work · Connected · 80%")

        var along = soundcore()
        along.along = .recording
        let chip = FloatingStatus.recorderChip(along, recording: true)
        XCTAssertEqual(chip?.showsDot, true)
        XCTAssertEqual(chip?.detail, "Soundcore Work · Recording along · 80%")
    }

    func testRecorderThatDidNotStartNeedsThePerson() {
        var recorder = soundcore()
        recorder.along = .unavailable
        let chip = FloatingStatus.recorderChip(recorder, recording: true)
        XCTAssertEqual(chip?.tone, .attention)
        XCTAssertEqual(chip?.label, "Not recording")
    }

    func testRecorderManagedByTheIPhone() {
        var recorder = soundcore(.notConnected, battery: nil)
        recorder.managedBy = "Alex’s iPhone"
        recorder.managedByPhone = true
        let chip = FloatingStatus.recorderChip(recorder, recording: true)
        XCTAssertEqual(chip?.label, "Soundcore on Alex’s iPhone")
        XCTAssertEqual(chip?.shortLabel, "On iPhone")
        XCTAssertEqual(chip?.tone, .calm)
        XCTAssertEqual(chip?.detail, "Soundcore Work · Managed by Alex’s iPhone")
        XCTAssertEqual(FloatingStatus.recorderLine(recorder)?.text, "Managed by Alex’s iPhone")
    }

    func testHandoffUnderWayWinsOverEverythingElse() {
        var recorder = soundcore()
        recorder.handoff = .asking(owner: "Alex’s iPhone")
        recorder.handoffLine = "Asking Alex’s iPhone to let go of Soundcore Work…"
        let chip = FloatingStatus.recorderChip(recorder, recording: false)
        XCTAssertEqual(chip?.tone, .working)
        XCTAssertEqual(chip?.label, "Moving…")
        XCTAssertEqual(chip?.detail, recorder.handoffLine)
        XCTAssertEqual(FloatingStatus.recorderLine(recorder)?.text, recorder.handoffLine)
    }

    func testDisconnectedRecorderSaysWhenItWasLastSeen() {
        var recorder = soundcore(.notConnected, battery: nil)
        recorder.lastConnected = now.addingTimeInterval(-3_600)
        let chip = FloatingStatus.recorderChip(recorder, recording: true, now: now)
        XCTAssertEqual(chip?.label, "Not connected")
        XCTAssertTrue(chip?.detail.hasPrefix("Soundcore Work · Not connected · Last seen") == true)
    }

    func testPhoneRecordingTooAndPaused() {
        var along = phone()
        along.along = .recording
        along.activity = .recording
        let chip = FloatingStatus.phoneChip(along, recording: true)
        XCTAssertEqual(chip?.showsDot, true)
        XCTAssertEqual(chip?.detail, "Alex’s iPhone is recording too")

        along.activity = .paused
        let paused = FloatingStatus.phoneChip(along, recording: true)
        XCTAssertEqual(paused?.tone, .attention)
        XCTAssertEqual(paused?.label, "Alex’s iPhone paused")
        XCTAssertEqual(paused?.shortLabel, "Paused")
        XCTAssertEqual(paused?.detail, "Alex’s iPhone paused. This Mac keeps recording.")
    }

    func testDisconnectedPhoneHasNoChipButKeepsItsLine() {
        XCTAssertNil(FloatingStatus.phoneChip(phone(connected: false), recording: true))
        XCTAssertEqual(FloatingStatus.phoneLine(phone(connected: false)).text, "Not connected")
        XCTAssertEqual(FloatingStatus.phoneChip(phone(), recording: false)?.tone, .linked)
    }

    func testProcessingChipsUseTheCopyPassWords() {
        let here = FloatingStatus.workChip(.transcribing(0.4))
        XCTAssertEqual(here?.label, "Transcribing · 40%")
        XCTAssertEqual(here?.detail, "Transcribing · 40%", "This Mac doesn't name itself")
        XCTAssertEqual(here?.progress, 0.4)
        XCTAssertEqual(FloatingStatus.workChip(.elsewhere(device: "Studio Mac", verb: "Transcribing", fraction: 0.4))?.label,
                       "Transcribing on Studio Mac · 40%", "Another device is named: which one works is the status")
        XCTAssertEqual(FloatingStatus.workChip(.summarizing)?.label, "Summarizing…")
        XCTAssertEqual(FloatingStatus.workChip(.models)?.label, "Waiting for models")
        XCTAssertEqual(FloatingStatus.workChip(.requested(device: "Alex’s iPhone"))?.label, "Requested from Alex’s iPhone",
                       "the iPhone asked; it isn't what the conversation waits for")
        XCTAssertEqual(FloatingStatus.workChip(.ready(summary: true))?.label, "Summary ready")
        XCTAssertEqual(FloatingStatus.workChip(.failed("It ran out of memory."))?.tone, .attention)
    }

    func testWorkChipShowsOnceTheConversationIsNotRecording() {
        var inputs = recording { $0.work = .transcribing(0.4) }
        XCTAssertFalse(FloatingStatus.chips(inputs).contains { $0.target == .processing })
        inputs.phase = .saved
        XCTAssertEqual(FloatingStatus.chips(inputs).last?.target, .processing)
    }

    func testConversationWorkAndThisMacsQueueAreSeparateChips() {
        // Compact, the home shows the focused conversation's work beside this Mac's queue: two
        // chips with their own identities, so the bar never draws one of them twice.
        var inputs = FloatingStatusInputs()
        inputs.work = .ready(summary: true)
        inputs.queue = .init(running: .transcribing, fraction: 0.4, waiting: 1)
        let chips = FloatingStatus.chips(inputs, including: [.work, .queue])
        XCTAssertEqual(chips.map(\.id), ["processing", "queue"])
        XCTAssertEqual(chips.map(\.label), ["Summary ready", "Transcribing · 40% · 1 waiting"])
        XCTAssertTrue(chips[1].isProminent, "this Mac's work keeps its words as the bar narrows")
    }

    func testSyncSpeaksOnlyWhenItIsAProblem() {
        XCTAssertNil(FloatingStatusInputs.syncProblem("Up to date"))
        XCTAssertNil(FloatingStatusInputs.syncProblem("iCloud sync is off"))
        XCTAssertEqual(FloatingStatusInputs.syncProblem("Sync paused: the iCloud account changed"),
                       "iCloud sync is paused: the iCloud account changed")
        // The system's words stay in Settings, behind Details.
        XCTAssertEqual(FloatingStatusInputs.syncProblem("Sync paused: The file “x” couldn’t be opened because you don’t have permission."),
                       "iCloud sync is paused.")
        XCTAssertEqual(FloatingStatusInputs.syncProblem("Couldn’t connect iCloud: The operation couldn’t be completed. (NSCocoaErrorDomain error 4.)"),
                       "Couldn’t connect iCloud.")
        let inputs = recording { $0.syncProblem = "iCloud sync is paused: the iCloud account changed" }
        XCTAssertEqual(FloatingStatus.chips(inputs).last?.label, "Not syncing")
    }

    func testChipKindsLeaveOutWhatTheSurfaceSays() {
        let inputs = recording {
            $0.call = .detected
            $0.recorders = [soundcore()]
            $0.phones = [phone()]
        }
        XCTAssertEqual(FloatingStatus.chips(inputs).map(\.id), ["call", "recorder-sc", "phone-ph"])
        XCTAssertEqual(FloatingStatus.chips(inputs, including: [.call]).map(\.id), ["call"])
        XCTAssertTrue(FloatingStatus.chips(inputs, including: []).isEmpty)
    }

    // MARK: Home and multipoint

    func testHomeLinesListRecordersPhonesThenTheQueue() {
        var inputs = FloatingStatusInputs()
        inputs.recorders = [soundcore()]
        inputs.phones = [phone()]
        inputs.queue = .init(running: .transcribing, fraction: 0.62, waiting: 2)
        let lines = FloatingStatus.lines(inputs, now: now)
        XCTAssertEqual(lines.map(\.title), ["Soundcore Work", "Alex’s iPhone", "This Mac"])
        XCTAssertEqual(lines[0].text, "Connected · 80%")
        XCTAssertEqual(lines[1].text, "Connected")
        XCTAssertEqual(lines[2].text, "Transcribing · 62% · 2 waiting")
        XCTAssertEqual(lines[2].progress, 0.62)
    }

    func testIdleQueueHasNoLine() {
        XCTAssertNil(FloatingStatus.queueLine(.init()))
        XCTAssertEqual(FloatingStatus.queueLine(.init(waiting: 3))?.text, "3 waiting to transcribe")
    }

    func testWhatRecordsAlongShowsOnceInTheChips() {
        var along = phone()
        along.along = .recording
        var recorder = soundcore()
        recorder.along = .recording
        let chips = FloatingStatus.chips(recording {
            $0.phones = [along]
            $0.recorders = [recorder]
        })
        XCTAssertEqual(chips.filter(\.showsDot).map(\.id), ["recorder-sc", "phone-ph"], "The red dot on each, and no line under the clock")
        XCTAssertEqual(chips.first { $0.id == "phone-ph" }?.detail, "Alex’s iPhone is recording too")

        along.activity = .paused
        let paused = FloatingStatus.chips(recording {
            $0.phones = [along]
            $0.recorders = [recorder]
        })
        XCTAssertEqual(paused.filter(\.showsDot).map(\.id), ["recorder-sc"])
        XCTAssertEqual(paused.first { $0.id == "phone-ph" }?.label, "Alex’s iPhone paused")
        XCTAssertEqual(paused.first { $0.id == "phone-ph" }?.tone, .attention)
    }
}

/// The shared design tokens stay the Mac's own values, so the two apps draw the same ink.
final class DaybookDesignTokenTests: XCTestCase {
    private func hex(_ color: Color, _ appearance: NSAppearance.Name) -> UInt32 {
        var value: UInt32 = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = UInt32((srgb.redComponent * 255).rounded()), g = UInt32((srgb.greenComponent * 255).rounded())
            let b = UInt32((srgb.blueComponent * 255).rounded())
            value = r << 16 | g << 8 | b
        }
        return value
    }

    func testSharedTokensMatchDaybookStyleInEveryAppearance() {
        let pairs: [(String, Color, DaybookShade)] = [
            ("accent", DaybookStyle.accent, DaybookPalette.Shade.accent),
            ("prominentFill", DaybookStyle.prominentFill, DaybookPalette.Shade.prominentFill),
            ("paper", DaybookStyle.paper, DaybookPalette.Shade.paper),
            ("bookmark", DaybookStyle.bookmark, DaybookPalette.Shade.bookmark),
            ("neonMint", DaybookStyle.neonMint, DaybookPalette.Shade.neonMint),
            ("neonCyan", DaybookStyle.neonCyan, DaybookPalette.Shade.neonCyan),
            ("neonViolet", DaybookStyle.neonViolet, DaybookPalette.Shade.neonViolet),
            ("neonMagenta", DaybookStyle.neonMagenta, DaybookPalette.Shade.neonMagenta),
            ("playFill", DaybookStyle.playFill, DaybookPalette.Shade.playFill),
            ("onPlayFill", DaybookStyle.onPlayFill, DaybookPalette.Shade.onPlayFill),
            ("title", Ink.title, DaybookPalette.Shade.title),
            ("body", Ink.body, DaybookPalette.Shade.body),
            ("secondary", Ink.secondary, DaybookPalette.Shade.secondary),
            ("meta", Ink.meta, DaybookPalette.Shade.meta),
            ("faint", Ink.faint, DaybookPalette.Shade.faint),
            ("link", Ink.link, DaybookPalette.Shade.link),
            ("warning", Ink.warning, DaybookPalette.Shade.warning),
            ("error", Ink.error, DaybookPalette.Shade.error),
            ("record", Ink.record, DaybookPalette.Shade.record),
            ("recordFill", Ink.recordFill, DaybookPalette.Shade.recordFill)
        ]
        XCTAssertEqual(pairs.count, DaybookPalette.Shade.all.count, "Every shared token is checked")
        for (name, mac, shade) in pairs {
            for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
                XCTAssertEqual(hex(mac, appearance), shade.hex(dark: dark, increasedContrast: false), "\(name) in \(appearance.rawValue)")
                XCTAssertEqual(hex(shade.color, appearance), shade.hex(dark: dark, increasedContrast: false), "\(name)'s colour in \(appearance.rawValue)")
            }
            // The high-contrast appearances can't be made outside the system setting, so these
            // resolve however the system does; the two copies must still agree.
            for appearance in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                XCTAssertEqual(hex(mac, appearance), hex(shade.color, appearance), "\(name) in \(appearance.rawValue)")
            }
        }
    }

    func testShadeKeepsStandardValuesWithoutContrastOnes() {
        let shade = DaybookShade(light: 0x111111, dark: 0x222222)
        XCTAssertEqual(shade.hex(dark: false, increasedContrast: true), 0x111111)
        XCTAssertEqual(shade.hex(dark: true, increasedContrast: true), 0x222222)
        XCTAssertEqual(DaybookPalette.Shade.paper.hex(dark: true, increasedContrast: true), 0x000000)
    }

    @MainActor
    func testLevelTrailKeepsTheNewestAndFallsFlat() {
        let trail = LevelTrail(capacity: 4)
        for value in [0.1, 0.2, 0.3, 0.4, 1.5] { trail.append(value) }
        XCTAssertEqual(trail.values, [0.2, 0.3, 0.4, 1], "Oldest first, clamped to 0...1")
        trail.append(.nan)
        XCTAssertEqual(trail.values.last, 0)
        trail.reset()
        XCTAssertEqual(trail.values, [0, 0, 0, 0])
    }
}
