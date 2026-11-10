import AppKit
import DaybookDesign
import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookUI

/// The recorder both apps share: what it says about the recording and what records along (`RecordingStatusWords`),
/// the meters' trails (`RecorderLevels`), and the controls' rules.
final class RecorderSurfaceTests: XCTestCase {
    private func studioMac(_ along: CompanionRecording.State? = nil, connected: Bool = true) -> RecordingStatusInputs.Peer {
        RecordingStatusInputs.Peer(id: "mac", name: "Studio Mac", kind: .mac, isConnected: connected, along: along)
    }

    // MARK: Words

    /// An iPhone recording sees a Mac as the Mac sees an iPhone: the red dot while it records along, a start that
    /// didn't happen in warning ink, and its name while it's only connected.
    func testBehaviorTheIPhoneSaysWhatMacsRecordAlongInTheMacsWords() throws {
        var inputs = RecordingStatusInputs()
        inputs.phase = .recording
        inputs.here = "this iPhone"
        inputs.peers = [studioMac(.recording)]
        let along = try XCTUnwrap(RecordingStatusWords.chips(inputs).first)
        XCTAssertEqual(along.target, .peer("mac"))
        XCTAssertEqual(along.symbol, "desktopcomputer")
        XCTAssertEqual(along.label, "Studio Mac")
        XCTAssertEqual(along.shortLabel, "Mac")
        XCTAssertTrue(along.showsDot)
        XCTAssertEqual(along.detail, "Studio Mac is recording too")

        inputs.peers = [studioMac(.failed)]
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.label, "Not recording")
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.tone, .attention)
        inputs.peers = [studioMac(.starting)]
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.detail, "Asking Studio Mac to record too…")
        inputs.peers = [studioMac()]
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.detail, "Studio Mac · Connected")
        inputs.peers = [studioMac(connected: false)]
        XCTAssertTrue(RecordingStatusWords.chips(inputs).isEmpty, "a Mac that isn't connected and isn't recording says nothing")
    }

    /// The recorder the iPhone manages records along too: its chip says so, and it gets a meter of its own; a Mac's
    /// levels never reach the iPhone, so a Mac has none.
    func testBehaviorARecorderAlongGetsAChipAndAMeterAndAMacOnlyAChip() {
        var soundcore = RecorderFacts(id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
                                      state: .connected, isLinked: true)
        soundcore.batteryLevel = 80
        soundcore.along = .recording
        var inputs = RecordingStatusInputs()
        inputs.phase = .recording
        inputs.recorders = [soundcore]
        inputs.peers = [studioMac(.recording)]
        let chips = RecordingStatusWords.chips(inputs)
        XCTAssertEqual(chips.map(\.id), ["recorder-sc", "peer-mac"])
        XCTAssertEqual(chips[0].label, "Soundcore · 80%")
        XCTAssertTrue(chips[0].showsDot)
        XCTAssertEqual(RecordingStatusWords.meters(inputs).map(\.source), [.microphone, .recorder("sc")])

        soundcore.along = .unavailable
        inputs.recorders = [soundcore]
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.label, "Not recording", "a recorder that didn't start says so during the call")
        XCTAssertEqual(RecordingStatusWords.chips(inputs).first?.tone, .attention)
    }

    /// Where the input can be changed (the iPhone's picker, Floating Notes' menu), the phase is its control and says so;
    /// elsewhere it names the input as it is.
    func testBehaviorTheInputReadsAsAControlWhereItCanBeChosen() {
        var inputs = RecordingStatusInputs()
        inputs.phase = .recording
        inputs.inputDevice = "iPhone Microphone"
        XCTAssertEqual(RecordingStatusWords.phase(inputs), RecorderPhase(phase: .recording, title: "Recording", detail: "iPhone Microphone"))
        inputs.choosesInput = true
        XCTAssertEqual(RecordingStatusWords.phase(inputs), RecorderPhase(phase: .recording, title: "Recording", detail: "iPhone Microphone ▾",
                                                                         choosesInput: true, input: "iPhone Microphone"))
        inputs.inputDevice = nil
        XCTAssertNil(RecordingStatusWords.phase(inputs)?.detail, "no route yet: nothing to name")
        XCTAssertEqual(RecordingStatusWords.inputControlName, "Microphone")
    }

    func testBehaviorAPausedRecordingRestsItsMetersAndSaysSo() {
        var inputs = RecordingStatusInputs()
        inputs.phase = .paused
        XCTAssertEqual(RecordingStatusWords.phase(inputs), RecorderPhase(phase: .paused, title: "Paused"))
        XCTAssertEqual(RecordingStatusWords.meters(inputs).map(\.isRecording), [false], "paused, the microphone's meter rests")
        inputs.phase = .saving
        XCTAssertEqual(RecordingStatusWords.phase(inputs)?.title, "Saving…")
        inputs.phase = .saved
        inputs.duration = 61 * 60
        XCTAssertEqual(RecordingStatusWords.phase(inputs)?.detail, DurationLabel.format(61 * 60))
    }

    func testBehaviorACountdownChipMovesOnItsOwn() {
        let start = Date(timeIntervalSince1970: 1_000)
        typealias Words = SummaryPlacementWords
        let chip = RecorderChip(target: .processing, symbol: "clock", label: Words.countdown(seconds: 12), shortLabel: Words.seconds(12), tone: .calm,
                                detail: Words.countdown(on: "this Mac", seconds: 12), countdownUntil: start.addingTimeInterval(12))
        XCTAssertEqual(chip.at(start.addingTimeInterval(4.5)).label, Words.countdown(seconds: 8))
        XCTAssertEqual(chip.at(start.addingTimeInterval(4.5)).shortLabel, Words.seconds(8))
        XCTAssertEqual(chip.at(start.addingTimeInterval(4.5)).detail, Words.countdown(on: "this Mac", seconds: 8))
        XCTAssertEqual(chip.at(start.addingTimeInterval(30)).label, Words.countdown(seconds: 1), "never below a second")
        var plain = chip
        plain.countdownUntil = nil
        XCTAssertEqual(plain.at(start.addingTimeInterval(4)), plain, "a chip without a countdown never changes")
    }

    /// The owner's ask: work in progress fills its own pill across the row, and VoiceOver hears how far it's gone.
    func testBehaviorWorkInProgressSpansItsRowAndSaysItsPercent() {
        let working = RecorderChip(target: .processing, symbol: "quote.bubble", label: "Transcribing · 40%", tone: .working, progress: 0.4,
                                   detail: "Transcribing · 40%")
        let still = RecorderChip(target: .call, symbol: "waveform", label: "Call", tone: .linked, detail: "Call audio detected")
        XCTAssertTrue(working.expands)
        XCTAssertFalse(still.expands)
        XCTAssertEqual(StatusChip.accessibilityValue(progress: working.progress), "40 percent")
        XCTAssertNil(StatusChip.accessibilityValue(progress: still.progress))
    }

    // MARK: After Stop

    /// One rule on both apps for recording more once a recording ends: Keep Recording into the same conversation for two
    /// minutes after a Stop, then Record for a new one; Record Again into the same one after a recording that stopped on
    /// its own, however long ago.
    func testBehaviorAfterStopKeepRecordingLastsTwoMinutesThenRecordStartsANewConversation() {
        let stop = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RecordMore.window, 120)
        XCTAssertEqual(RecordMore.windowEnds(after: stop), stop.addingTimeInterval(120))

        let justAfter = RecordMore(stoppedShort: false, stoppedAt: stop, now: stop.addingTimeInterval(5))
        XCTAssertEqual(justAfter, .keepRecording)
        XCTAssertEqual(justAfter.title, "Keep Recording")
        XCTAssertTrue(justAfter.recordsIntoSameConversation)
        XCTAssertEqual(RecordMore(stoppedShort: false, stoppedAt: stop, now: stop.addingTimeInterval(119)), .keepRecording)

        let later = RecordMore(stoppedShort: false, stoppedAt: stop, now: stop.addingTimeInterval(120))
        XCTAssertEqual(later, .record, "two minutes on, it's for the next call")
        XCTAssertEqual(later.title, "Record")
        XCTAssertFalse(later.recordsIntoSameConversation)
        XCTAssertEqual(RecordMore(stoppedShort: false, stoppedAt: nil, now: stop), .record,
                       "nothing to go on from: the moment ended early (another recording, the meeting over, the next one starting)")

        let again = RecordMore(stoppedShort: true, stoppedAt: stop, now: stop.addingTimeInterval(3600))
        XCTAssertEqual(again, .recordAgain, "a recording that stopped on its own is recorded into again, however long ago")
        XCTAssertEqual(again.title, "Record Again")
        XCTAssertTrue(again.recordsIntoSameConversation)
        XCTAssertEqual(RecordMore(stoppedShort: true, stoppedAt: nil), .recordAgain)

        XCTAssertEqual(RecorderAfterStopState(title: "Design review").recordMore, .record, "nothing said: a new conversation")
        XCTAssertEqual(RecorderAfterStopState(title: "Design review", recordMore: .keepRecording).recordMore.title, "Keep Recording")
    }

    /// Open after Stop goes to the conversation in Daybook, so it carries the forward chevron of navigation within the
    /// app, never the arrow out to another app or the web.
    func testBehaviorOpenAfterStopPointsWithinTheApp() {
        XCTAssertEqual(OpenControlLabel.symbol, "chevron.forward")
    }

    /// Bookmark and Stop share their row equally when both keep their words that way; beside Write by Hand, where they
    /// don't, each gets its words and they share the rest, so Bookmark keeps its word beside a shorter Stop; with no
    /// room for both, equally again (and the words give way to glyphs).
    func testBehaviorTheControlRowKeepsBookmarksWordBesideWriteByHand() {
        let fills = [true, false, true]
        XCTAssertEqual(RecorderControlTiles.widths(available: 400, ideals: [150, 44, 100], fills: fills, spacing: 12), [166, 44, 166],
                       "room for both: equal")
        XCTAssertEqual(RecorderControlTiles.widths(available: 334, ideals: [150, 44, 100], fills: fills, spacing: 12), [158, 44, 108],
                       "Bookmark's words first, the rest shared")
        XCTAssertEqual(RecorderControlTiles.widths(available: 250, ideals: [150, 44, 100], fills: fills, spacing: 12), [91, 44, 91],
                       "no room for both: equal, glyphs")
        XCTAssertEqual(RecorderControlTiles.widths(available: 300, ideals: [120, 90], fills: [true, true], spacing: 10), [145, 145],
                       "the Mac's two tiles, as before")
    }

    /// While recording the open Duo's right page has the whole recorder at rest, one row only over the keyboard, and
    /// the hand rests collapsed with the title over the notes.
    func testBehaviorTheOpenDuoRestsAtTheWholeRecorder() {
        XCTAssertEqual(RecorderSheetSize.resting(in: .spread(crease: 475.5), isWide: false), .expanded)
        XCTAssertEqual(RecorderSheetSize.expanded.rendered(keyboardUp: true, hasNotice: false), .mini)
        XCTAssertEqual(RecorderSheetSize.resting(in: .column, isWide: false), .collapsed)
        XCTAssertFalse(RecorderSheetLook.page.inHand, "the title on the left page, the chips in the sheet")
        XCTAssertTrue(RecorderSheetLook.page.timelineWhole, "the live timeline in the resting recorder")
        XCTAssertTrue(RecorderSheetLook.hand.inHand, "title and chips over the notes")
    }

    /// After Stop the iPhone says what becomes of the recording, as the Mac's panel does: its processing in a chip, in
    /// the words its library row says, filling as it goes; nothing when the row has nothing to say.
    func testBehaviorAfterStopTheProcessingChipSaysWhatTheRowSays() throws {
        let working = try XCTUnwrap(RecordingStatusWords.processingChip(
            ConversationRowStatus(kind: .processing, text: "Transcribing on this iPhone · 40%", fraction: 0.4)))
        XCTAssertEqual(working.target, .processing)
        XCTAssertEqual(working.label, "Transcribing on this iPhone · 40%")
        XCTAssertEqual(working.shortLabel, "40%")
        XCTAssertEqual(working.progress, 0.4)
        XCTAssertEqual(working.tone, .working)
        XCTAssertTrue(working.isProminent, "what's becoming of it keeps its words longest")
        XCTAssertNil(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .processing, text: "Transcribing", fraction: 0))?.shortLabel,
                     "no figure yet: the glyph alone when narrow")

        let mac = try XCTUnwrap(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .waiting, text: "Waiting for your Mac")))
        XCTAssertEqual(mac.label, "Waiting for your Mac")
        XCTAssertEqual(mac.shortLabel, "Waiting")
        XCTAssertEqual(mac.tone, .calm)
        XCTAssertNil(mac.progress)

        let until = Date(timeIntervalSince1970: 1_012)
        let countdown = try XCTUnwrap(RecordingStatusWords.processingChip(
            ConversationRowStatus(kind: .waiting, text: SummaryPlacementWords.countdown(seconds: 12), countdownUntil: until),
            now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(countdown.shortLabel, SummaryPlacementWords.seconds(12))
        XCTAssertEqual(countdown.at(Date(timeIntervalSince1970: 1_004)).label, SummaryPlacementWords.countdown(seconds: 8), "its seconds move with it")
        XCTAssertEqual(countdown.at(Date(timeIntervalSince1970: 1_004)).shortLabel, SummaryPlacementWords.seconds(8))

        XCTAssertEqual(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .waitingForModels, text: "Waiting for models"))?.tone,
                       .attention)
        XCTAssertEqual(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .paused, text: "Paused"))?.shortLabel, "Paused")
        XCTAssertNil(RecordingStatusWords.processingChip(nil), "done: the row shows its preview, the chips say nothing")
        XCTAssertNil(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .justFinished, text: nil)))
        XCTAssertNil(RecordingStatusWords.processingChip(ConversationRowStatus(kind: .recording, text: "Recording now")))
    }

    // MARK: Levels

    /// The iPhone feeds its microphone's trail itself, at its recorder's pace: the meters draw that trail, it counts
    /// as heard while recording, and sampling never writes into it.
    @MainActor
    func testBehaviorATrailFedElsewhereIsDrawnAsItIsAndNeverSampled() {
        let levels = RecorderLevels()
        let microphone = LevelTrail(capacity: 8)
        levels.adopt(microphone, for: .microphone)
        var recorder: Double? = 0.4
        let readers = RecorderLevels.Readers(microphone: { 0.99 }, recorder: { _ in recorder })
        levels.follow([.microphone, .recorder("sc")])
        levels.run(true, readers: readers)
        defer { levels.run(false, readers: readers) }
        XCTAssertTrue(levels.trail(.microphone) === microphone)
        XCTAssertEqual(levels.heard, [.microphone], "fed elsewhere, it's heard as soon as recording runs")
        levels.sample()
        XCTAssertTrue(microphone.values.allSatisfy { $0 == 0 }, "sampling doesn't write into it")
        XCTAssertEqual(levels.heard, [.microphone, .recorder("sc")])
        XCTAssertEqual(levels.trail(.recorder("sc")).values.last, 0.4)
        recorder = nil
        levels.sample()
        XCTAssertEqual(levels.heard, [.microphone], "a recorder whose audio stops rests; the microphone stays")
    }

    func testBehaviorMeterStacksShareTheirAreaOnTheIPhoneToo() {
        for stack in [MeterStack.pocket, .page, .stage] {
            XCTAssertEqual(stack.rowHeight(1), stack.area)
            XCTAssertEqual(stack.height(2), stack.area, accuracy: 0.001)
            XCTAssertLessThanOrEqual(stack.height(5), stack.maximumArea + 0.001)
            for count in 1...6 {
                let row = stack.rowHeight(count), gap = stack.gap(count)
                XCTAssertLessThanOrEqual(stack.glyphSize(row: row, gap: gap), stack.glyph)
            }
        }
    }

    // MARK: Controls

    func testBehaviorTheControlsDropTheirWordsOnlyAtTheAccessibilitySizes() {
        XCTAssertFalse(BookmarkControlLabel.isGlyphOnly(size: nil, typeSize: .xxxLarge))
        XCTAssertTrue(BookmarkControlLabel.isGlyphOnly(size: nil, typeSize: .accessibility1), "Bookmark and Stop never read \"B…\" and \"S…\"")
        XCTAssertTrue(BookmarkControlLabel.isGlyphOnly(size: nil, typeSize: .accessibility5))
        XCTAssertFalse(BookmarkControlLabel.isGlyphOnly(size: 14, typeSize: .accessibility5), "the Mac's fixed sizes keep their words")
    }

    /// Regression: in table mode a tap on the dimmed Stop ended the recording, though a touch was meant only to wake
    /// the screen. Dimmed, Stop and the tools beside it ignore the touch; Bookmark (which has no gate) takes it.
    func testBehaviorStopIgnoresTheTouchThatWakesTheTable() {
        var state = RecorderSurfaceState(title: "Design review", clock: .since(Date()), isLive: true, bookmarkCount: 0, asleep: true)
        XCTAssertFalse(state.stopTakesTouch, "the waking touch never stops the recording")
        XCTAssertFalse(state.toolsTakeTouch, "nor opens the notes or the camera")
        state.asleep = false
        XCTAssertTrue(state.stopTakesTouch)
        XCTAssertTrue(state.toolsTakeTouch)
        XCTAssertTrue(RecorderSurfaceState(title: "", clock: .since(Date()), isLive: true, bookmarkCount: 0).stopTakesTouch,
                      "awake unless the host dims it")
    }

    func testBehaviorTheCompactNoteFieldAddsALineAsTheLastParagraph() {
        XCTAssertEqual(RecorderNoteField.appending("Ship Friday", to: ""), "Ship Friday")
        XCTAssertEqual(RecorderNoteField.appending("  Ship Friday ", to: "Agenda\n"), "Agenda\nShip Friday")
        XCTAssertEqual(RecorderNoteField.appending("   ", to: "Agenda"), "Agenda", "an empty line adds nothing")
        // Regression: the blank lines the notes began with went too, an edit the person never made.
        XCTAssertEqual(RecorderNoteField.appending("Ship Friday", to: "\n\nAgenda\r\n\n"), "\n\nAgenda\nShip Friday",
                       "only the end of the notes makes way")
        XCTAssertEqual(RecorderNoteField.appending("Ship Friday", to: "\n\n"), "Ship Friday")
    }
}
