import AppKit
import DaybookCore
import DaybookDesign
import DaybookDevices
import DaybookKit
import DaybookUI
import SwiftUI
import XCTest
@testable import Daybook

/// What Floating Notes' status bar and home lines say in each state (`FloatingStatus`), read from plain inputs as
/// the iPhone's status-sheet tests do. The recording's words are the ones the iPhone's recorder says too
/// (`RecordingStatusWords`), and recorders and iPhones read as they do everywhere else.
final class FloatingNotesStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func soundcore(_ state: ConnectionState = .connected, battery: Int? = 80) -> RecorderFacts {
        var recorder = RecorderFacts(id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
                                     state: state, isLinked: state == .connected)
        recorder.batteryLevel = battery
        return recorder
    }

    private func phone(connected: Bool = true) -> RecordingStatusInputs.Peer {
        RecordingStatusInputs.Peer(id: "ph", name: "Alex’s iPhone", kind: .iPhone, isConnected: connected)
    }

    private func recording(_ change: (inout FloatingStatusInputs) -> Void = { _ in }) -> FloatingStatusInputs {
        var inputs = FloatingStatusInputs()
        inputs.phase = .recording
        inputs.recording.inputDevice = "MacBook Pro Microphone"
        change(&inputs)
        return inputs
    }

    private func recorderChip(_ facts: RecorderFacts, recording: Bool, now: Date = Date()) -> RecorderChip? {
        RecordingStatusWords.recorderChip(facts, recording: recording, here: "this Mac", now: now)
    }

    // MARK: Phase

    func testRecordingPhaseNamesTheInputDeviceUntilTheMicrophoneIsSilent() {
        XCTAssertEqual(FloatingStatus.phase(recording()), RecorderPhase(phase: .recording, title: "Recording", detail: "MacBook Pro Microphone"))
        let silent = FloatingStatus.phase(recording { $0.recording.microphoneSilent = true })
        XCTAssertEqual(silent?.detail, "Microphone silent", "as the iPhone says it")
        XCTAssertEqual(silent?.detailIsWarning, true)
    }

    func testPhaseAfterStopAndWhenIdle() {
        var inputs = FloatingStatusInputs()
        XCTAssertNil(FloatingStatus.phase(inputs), "Nothing recording: the band stays quiet")
        inputs.phase = .saved
        inputs.recording.duration = 18 * 60
        XCTAssertEqual(FloatingStatus.phase(inputs), RecorderPhase(phase: .saved, title: "Saved", detail: "18 min"))
        inputs.phase = .stopped
        XCTAssertEqual(FloatingStatus.phase(inputs)?.phase, .stopped)
    }

    /// Regression: the band said "SAVED · 18:00" for an 18-minute conversation, which reads as a time of day.
    func testBehaviorSavedSaysHowLongTheWayThePageDoesNeverLikeAClock() {
        var inputs = FloatingStatusInputs()
        inputs.phase = .saved
        for (seconds, words) in [(TimeInterval(18 * 60), "18 min"), (761, "13 min"), (3_660, DurationLabel.format(3_660)), (43, "43 sec")] {
            inputs.recording.duration = seconds
            let detail = FloatingStatus.phase(inputs)?.detail
            XCTAssertEqual(detail, words)
            XCTAssertEqual(detail, DurationLabel.format(seconds), "as the page's play pill and the list say it")
            XCTAssertFalse(detail?.contains(":") ?? true, "\(seconds) s: never a clock time")
        }
    }

    // MARK: Chips

    func testCallChipFollowsTheCallTrack() {
        XCTAssertNil(RecordingStatusWords.callChip(.off))
        XCTAssertEqual(RecordingStatusWords.callChip(.detected)?.tone, .linked)
        XCTAssertEqual(RecordingStatusWords.callChip(.quiet)?.tone, .calm)
        let missing = RecordingStatusWords.callChip(.missing)
        XCTAssertEqual(missing?.tone, .attention)
        XCTAssertEqual(missing?.label, "No call audio")
        XCTAssertTrue(missing?.detail.contains("Screen & System Audio Recording") == true, "A missing call says how to fix it")
    }

    func testCallChipOnlyWhileRecording() {
        var inputs = recording { $0.recording.call = .detected }
        XCTAssertEqual(FloatingStatus.chips(inputs).first?.target, .call)
        inputs.phase = .saved
        XCTAssertFalse(FloatingStatus.chips(inputs).contains { $0.target == .call })
    }

    func testConnectedRecorderShowsBatteryAndTheDotWhenRecordingAlong() {
        let connected = recorderChip(soundcore(), recording: true)
        XCTAssertEqual(connected?.label, "Soundcore · 80%")
        XCTAssertEqual(connected?.shortLabel, "Soundcore", "Short, it keeps its name")
        XCTAssertEqual(connected?.tone, .linked)
        XCTAssertEqual(connected?.showsDot, false)
        XCTAssertEqual(connected?.detail, "Soundcore Work · Connected · 80%")

        var along = soundcore()
        along.along = .recording
        let chip = recorderChip(along, recording: true)
        XCTAssertEqual(chip?.showsDot, true)
        XCTAssertEqual(chip?.detail, "Soundcore Work · Recording along · 80%")
    }

    func testRecorderThatDidNotStartNeedsThePerson() {
        var recorder = soundcore()
        recorder.along = .unavailable
        let chip = recorderChip(recorder, recording: true)
        XCTAssertEqual(chip?.tone, .attention)
        XCTAssertEqual(chip?.label, "Not recording")
    }

    func testRecorderManagedByTheIPhone() {
        var recorder = soundcore(.notConnected, battery: nil)
        recorder.managedBy = "Alex’s iPhone"
        recorder.managedByPhone = true
        let chip = recorderChip(recorder, recording: true)
        XCTAssertEqual(chip?.label, "Soundcore on Alex’s iPhone")
        XCTAssertEqual(chip?.shortLabel, "On iPhone")
        XCTAssertEqual(chip?.tone, .calm)
        XCTAssertEqual(chip?.detail, "Soundcore Work · Managed by Alex’s iPhone")
        var inputs = FloatingStatusInputs()
        inputs.recording.recorders = [recorder]
        XCTAssertEqual(FloatingStatus.lines(inputs).first?.text, "Managed by Alex’s iPhone")
    }

    func testHandoffUnderWayWinsOverEverythingElse() {
        var recorder = soundcore()
        recorder.handoff = .asking(owner: "Alex’s iPhone")
        let chip = recorderChip(recorder, recording: false)
        XCTAssertEqual(chip?.tone, .working)
        XCTAssertEqual(chip?.label, "Moving…")
        XCTAssertEqual(chip?.detail, "Asking Alex’s iPhone to let go of Soundcore Work…")
        var inputs = FloatingStatusInputs()
        inputs.recording.recorders = [recorder]
        XCTAssertEqual(FloatingStatus.lines(inputs).first?.text, "Asking Alex’s iPhone to let go…")
    }

    func testDisconnectedRecorderSaysWhenItWasLastSeen() {
        var recorder = soundcore(.notConnected, battery: nil)
        recorder.lastConnected = now.addingTimeInterval(-3_600)
        let chip = recorderChip(recorder, recording: true, now: now)
        XCTAssertEqual(chip?.label, "Not connected")
        XCTAssertTrue(chip?.detail.hasPrefix("Soundcore Work · Not connected · Last seen") == true)
    }

    func testPhoneRecordingTooAndPaused() {
        var along = phone()
        along.along = .recording
        along.activity = .recording
        let chip = RecordingStatusWords.peerChip(along, recording: true)
        XCTAssertEqual(chip?.showsDot, true)
        XCTAssertEqual(chip?.detail, "Alex’s iPhone is recording too")

        along.activity = .paused
        let paused = RecordingStatusWords.peerChip(along, recording: true)
        XCTAssertEqual(paused?.tone, .attention)
        XCTAssertEqual(paused?.label, "Alex’s iPhone paused")
        XCTAssertEqual(paused?.shortLabel, "Paused")
        XCTAssertEqual(paused?.detail, "Alex’s iPhone paused. This Mac keeps recording.")
    }

    /// Regression: at the default width a paused iPhone's chip kept "Alex’s iPhone paused" and squeezed
    /// the Soundcore's to "● 80%", which didn't say whose it was.
    func testChipsShortenThePausedIPhoneFirstAndKeepNames() throws {
        var along = phone()
        along.along = .recording
        along.activity = .paused
        var recorder = soundcore()
        recorder.along = .recording
        let chips = FloatingStatus.chips(recording { $0.recording.call = .detected; $0.recording.recorders = [recorder]; $0.recording.peers = [along] })
        XCTAssertEqual(chips.map(\.target), [.call, .recorder("sc"), .peer("ph")])
        func labels(_ fit: RecorderChipFit) -> [String?] { chips.map(fit.label) }
        XCTAssertEqual(labels(.full), ["Call", "Soundcore · 80%", "Alex’s iPhone paused"])
        XCTAssertEqual(labels(.shortFirst), ["Call", "Soundcore · 80%", "Paused"], "The paused chip shortens first")
        XCTAssertEqual(labels(.shortOthers), ["Call", "Soundcore", "Paused"], "Names stay")
        XCTAssertEqual(labels(.glyphOthers), [nil, nil, "Paused"], "What needs the person keeps its words longest")
        XCTAssertEqual(labels(.short), [nil, nil, "Paused"])
        XCTAssertEqual(labels(.glyph), [nil, nil, nil])
        XCTAssertEqual(RecorderChipFit.allCases.first, .full)

        // Processing keeps its whole words until only short labels are left.
        let work = try XCTUnwrap(FloatingStatus.workChip(.transcribing(0.4)))
        XCTAssertFalse(work.shortensFirst)
        XCTAssertEqual([RecorderChipFit.shortFirst, .shortOthers, .glyphOthers].map { $0.label(work) }, Array(repeating: work.label, count: 3))
        XCTAssertEqual(RecorderChipFit.short.label(work), work.shortLabel)
    }

    func testDisconnectedPhoneHasNoChipButKeepsItsLine() {
        XCTAssertNil(RecordingStatusWords.peerChip(phone(connected: false), recording: true))
        var inputs = FloatingStatusInputs()
        inputs.recording.peers = [phone(connected: false)]
        XCTAssertEqual(FloatingStatus.lines(inputs).first?.text, "Not connected")
        XCTAssertEqual(RecordingStatusWords.peerChip(phone(), recording: false)?.tone, .linked)
    }

    func testProcessingChipsUseTheSharedWords() {
        let here = FloatingStatus.workChip(.transcribing(0.4))
        XCTAssertEqual(here?.label, "Transcribing · 40%")
        XCTAssertEqual(here?.detail, "Transcribing · 40%", "This Mac doesn't name itself")
        XCTAssertEqual(here?.progress, 0.4)
        XCTAssertEqual(FloatingStatus.workChip(.elsewhere(device: "Studio Mac", stage: .transcribing, fraction: 0.4))?.label,
                       "Transcribing on Studio Mac · 40%", "Another device is named: which one works is the status")
        XCTAssertEqual(FloatingStatus.workChip(.summarizing)?.label, "Summarizing…")
        XCTAssertEqual(FloatingStatus.workChip(.waiting)?.label, "Waiting to transcribe")
        XCTAssertEqual(FloatingStatus.workChip(.models)?.label, "Waiting for models")
        XCTAssertEqual(FloatingStatus.workChip(.requested(device: "Alex’s iPhone"))?.label, "Requested from Alex’s iPhone",
                       "the iPhone asked; it isn't what the conversation waits for")
        XCTAssertEqual(FloatingStatus.workChip(.ready(summary: true))?.label, "Summary ready")
        let failed = FailureWords(kind: .modelsMissing, reason: "", hadTranscripts: false, device: "this Mac")
        let chip = FloatingStatus.workChip(.failed(failed))
        XCTAssertEqual(chip?.tone, .attention)
        XCTAssertEqual(chip?.detail, failed.message, "Its menu says it in the words both apps use")
    }

    /// Where a summary runs (docs/multipoint.md, "Where summaries run"): its countdown in the chip and the home's
    /// line for this Mac, a second at a time, and the cloud at work. Only the chip or the line redraws.
    func testBehaviorASummarysCountdownAndTheCloudShowInTheChipAndTheHome() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let countdown = try XCTUnwrap(FloatingStatus.workChip(.summaryCountdown(until: now.addingTimeInterval(11.2), cloud: true), now: now))
        XCTAssertEqual(countdown.label, "Summarizing in 12 s")
        XCTAssertEqual(countdown.shortLabel, "12 s")
        XCTAssertEqual(countdown.detail, "Summarizing on this Mac in 12 s", "The menu's first line says it whole")
        XCTAssertEqual(countdown.tone, .calm)
        let later = countdown.at(now.addingTimeInterval(3))
        XCTAssertEqual(later.label, "Summarizing in 9 s", "The chip moves on its own")
        XCTAssertEqual(later.shortLabel, "9 s")
        XCTAssertEqual(later.detail, "Summarizing on this Mac in 9 s")
        XCTAssertNil(FloatingStatus.workChip(.summarizing)?.countdownUntil, "Nothing else ticks")
        XCTAssertEqual(FloatingStatus.workChip(.summarizingWith("Claude Sonnet 5.5"))?.label, "Summarizing with Claude Sonnet 5.5")
        var queue = FloatingStatusInputs.Queue(running: .summarizing, waiting: 1)
        queue.countdown = now.addingTimeInterval(5)
        let line = try XCTUnwrap(FloatingStatus.queueWords(queue, now: now))
        XCTAssertEqual(line.text, "Summarizing in 5 s · 1 waiting")
        XCTAssertEqual(FloatingStatus.item(line, at: now.addingTimeInterval(2)).text, "Summarizing in 3 s · 1 waiting")
        XCTAssertEqual(FloatingStatus.item(line, at: now.addingTimeInterval(2)).shortText, "Summarizing in 3 s")
        XCTAssertEqual(FloatingStatus.queueChip(queue, now: now)?.countdownUntil, queue.countdown)
        queue.countdown = nil
        queue.cloudModel = "Claude Sonnet 5.5"
        XCTAssertEqual(FloatingStatus.queueWords(queue, now: now)?.text, "Summarizing with Claude Sonnet 5.5 · 1 waiting")
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
        XCTAssertNil(FloatingStatusInputs.syncProblem(SyncStatus.upToDate(at: Date()).problem))
        XCTAssertNil(FloatingStatusInputs.syncProblem(SyncStatus.off.problem))
        XCTAssertEqual(FloatingStatusInputs.syncProblem(SyncStatus.accountChanged.problem),
                       "iCloud sync is paused: the iCloud account changed")
        // The system's words stay in Settings, behind Details.
        XCTAssertEqual(FloatingStatusInputs.syncProblem(SyncStatus.failure(details: "The file “x” couldn’t be opened because you don’t have permission.").problem),
                       "iCloud sync is paused.")
        XCTAssertEqual(FloatingStatusInputs.syncProblem(SyncStatus.iCloudUnavailable(details: "The operation couldn’t be completed. (NSCocoaErrorDomain error 4.)").problem),
                       "Couldn’t connect to iCloud.")
        // A move into iCloud that stopped is said too; it used to be missed.
        XCTAssertEqual(FloatingStatusInputs.syncProblem(SyncStatus.migrationPaused(details: "No space left on device.").problem),
                       "Moving to iCloud is paused.")
        let inputs = recording { $0.syncProblem = "iCloud sync is paused: the iCloud account changed" }
        XCTAssertEqual(FloatingStatus.chips(inputs).last?.label, "Not syncing")
    }

    func testChipKindsLeaveOutWhatTheSurfaceSays() {
        let inputs = recording {
            $0.recording.call = .detected
            $0.recording.recorders = [soundcore()]
            $0.recording.peers = [phone()]
        }
        XCTAssertEqual(FloatingStatus.chips(inputs).map(\.id), ["call", "recorder-sc", "peer-ph"])
        XCTAssertEqual(FloatingStatus.chips(inputs, including: [.call]).map(\.id), ["call"])
        XCTAssertTrue(FloatingStatus.chips(inputs, including: []).isEmpty)
    }

    // MARK: Meters

    func testBehaviorOneMeterPerSourceTheRecordingHasNow() {
        XCTAssertTrue(FloatingStatus.meters(FloatingStatusInputs()).isEmpty, "nothing recording, no meters")
        let microphone = FloatingStatus.meters(recording())
        XCTAssertEqual(microphone.map(\.source), [.microphone], "computer audio off: the microphone alone")
        XCTAssertEqual(microphone.first?.symbol, "mic")
        XCTAssertEqual(microphone.first?.name, "Microphone")

        var recorder = soundcore(), late = soundcore(), refused = soundcore()
        recorder.along = .recording
        late.id = "late"
        late.along = .starting
        refused.id = "refused"
        refused.along = .unavailable
        var along = phone(), idle = phone()
        along.along = .alreadyRecording
        along.activity = .recording
        idle.id = "idle"
        let inputs = recording {
            $0.recording.includesCall = true
            $0.recording.call = .detected
            $0.recording.recorders = [recorder, late, refused, soundcore()]
            $0.recording.peers = [along, idle]
        }
        let meters = FloatingStatus.meters(inputs)
        XCTAssertEqual(meters.map(\.source), [.microphone, .call, .recorder("sc"), .recorder("late"), .peer("ph")],
                       "in the chips' order; a recorder that didn't start, and devices only connected, have none")
        XCTAssertEqual(meters.map(\.symbol), ["mic", "waveform", "recordingtape", "recordingtape", "iphone"], "the chips' glyphs")
        XCTAssertEqual(meters.map(\.name), ["Microphone", "Call audio", "Soundcore Work", "Soundcore Work", "Alex’s iPhone"])
        XCTAssertEqual(meters.map(\.isRecording), [true, true, true, false, true], "one still starting rests")
        XCTAssertEqual(Set(meters.map(\.id)).count, meters.count)
    }

    func testBehaviorMetersKeepTheirWarningsAndAPausedPhoneRests() {
        var along = phone()
        along.along = .recording
        along.activity = .paused
        let inputs = recording {
            $0.recording.microphoneSilent = true
            $0.recording.includesCall = true
            $0.recording.call = .missing
            $0.recording.peers = [along]
        }
        let meters = FloatingStatus.meters(inputs)
        XCTAssertEqual(meters[0].warning, RecordingStatusWords.microphoneSilentHelp)
        XCTAssertEqual(meters[1].warning, RecordingStatusWords.callMissingHelp)
        XCTAssertFalse(meters[1].isRecording, "a call that isn't captured rests")
        XCTAssertNil(meters[2].warning)
        XCTAssertFalse(meters[2].isRecording, "a paused iPhone rests")
        // Saving: the same rows, while the panel says Saving.
        var saving = inputs
        saving.phase = .saving
        XCTAssertEqual(FloatingStatus.meters(saving).count, 3)
    }

    // MARK: Home and multipoint

    func testHomeLinesListRecordersPhonesThenTheQueue() {
        var inputs = FloatingStatusInputs()
        inputs.recording.recorders = [soundcore()]
        inputs.recording.peers = [phone()]
        inputs.queue = .init(running: .transcribing, fraction: 0.62, waiting: 2)
        let lines = FloatingStatus.lines(inputs, now: now)
        XCTAssertEqual(lines.map(\.title), ["Soundcore Work", "Alex’s iPhone", "This Mac"])
        XCTAssertEqual(lines[0].text, "Connected · 80%")
        XCTAssertEqual(lines[1].text, "Connected")
        XCTAssertEqual(lines[2].text, "Transcribing · 62% · 2 waiting")
        XCTAssertEqual(lines[2].progress, 0.62)
        XCTAssertEqual(lines.map(\.id), ["recorder-sc", "phone-ph", "queue"], "a line opens its device's page by its ID")
    }

    func testIdleQueueHasNoLine() {
        XCTAssertNil(FloatingStatus.queueWords(.init()))
        XCTAssertEqual(FloatingStatus.queueWords(.init(waiting: 3))?.text, "3 waiting to transcribe")
    }

    func testWhatRecordsAlongShowsOnceInTheChips() {
        var along = phone()
        along.along = .recording
        var recorder = soundcore()
        recorder.along = .recording
        let chips = FloatingStatus.chips(recording {
            $0.recording.peers = [along]
            $0.recording.recorders = [recorder]
        })
        XCTAssertEqual(chips.filter(\.showsDot).map(\.id), ["recorder-sc", "peer-ph"], "The red dot on each, and no line under the clock")
        XCTAssertEqual(chips.first { $0.id == "peer-ph" }?.detail, "Alex’s iPhone is recording too")

        along.activity = .paused
        let paused = FloatingStatus.chips(recording {
            $0.recording.peers = [along]
            $0.recording.recorders = [recorder]
        })
        XCTAssertEqual(paused.filter(\.showsDot).map(\.id), ["recorder-sc"])
        XCTAssertEqual(paused.first { $0.id == "peer-ph" }?.label, "Alex’s iPhone paused")
        XCTAssertEqual(paused.first { $0.id == "peer-ph" }?.tone, .attention)
    }

    /// Regression: with last week's conversation focused, Record in the panel added a new call to it, and that
    /// conversation was transcribed and summarized again. Record goes into a conversation only while it has only notes.
    func testBehaviorHomeRecordsIntoTheFocusedConversationOnlyWhileItHasOnlyNotes() {
        var notes = Meeting(title: "Ideas for the offsite", date: now)
        XCTAssertEqual(HomeSurface.recordTarget(notes), notes.id, "a conversation that's only notes gets its recording")
        notes.tracks = [RecordingTrack(source: .microphone, relativePath: "Originals/mic.wav", fileName: "mic.wav", offset: 0)]
        XCTAssertNil(HomeSurface.recordTarget(notes), "one that already has a recording gets a new conversation instead")
        XCTAssertNil(HomeSurface.recordTarget(nil), "the home records a new conversation")
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
