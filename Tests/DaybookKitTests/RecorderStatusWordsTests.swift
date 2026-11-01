import DaybookCore
import DaybookDevices
import Foundation
import XCTest
@testable import DaybookKit

/// One recorder's status in one set of words for both apps: the same Mac never says "Last seen" in one place and
/// "Last connected" in another, and one iPhone sheet never gives two lines for one recorder.
final class RecorderStatusWordsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func soundcore(_ state: ConnectionState = .connected, linked: Bool = true) -> RecorderFacts {
        RecorderFacts(id: "sc", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true, state: state, isLinked: linked)
    }

    private func text(_ facts: RecorderFacts, here: String = "this Mac") -> String {
        RecorderStatusWords.line(facts, here: here, now: now).text
    }

    func testBehaviorAConnectedRecorderSaysItsStateBatteryAndNewRecordings() {
        var facts = soundcore()
        facts.batteryLevel = 80
        facts.newCount = 1
        let line = RecorderStatusWords.line(facts, here: "this Mac", now: now)
        XCTAssertEqual(line.text, "Connected · 80% · 1 new")
        XCTAssertEqual(line.shortText, "80% · 1 new")
        XCTAssertEqual(line.tone, .linked)
        XCTAssertEqual(line.symbol, "recordingtape", "the kind's own glyph")
        XCTAssertEqual(line.title, "Soundcore Work")
        facts.batteryCharging = true
        facts.isRecording = true
        XCTAssertEqual(text(facts), "Recording · 80%, charging · 1 new")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this Mac", now: now).tone, .recording)
        XCTAssertEqual(text(facts), text(facts, here: "this iPhone"), "the same on both devices")
    }

    func testBehaviorAwayItIsLastSeenEverywhere() {
        var facts = soundcore(.notConnected, linked: false)
        facts.lastConnected = now.addingTimeInterval(-3600)
        let seen = RecorderStatusWords.lastSeen(now.addingTimeInterval(-3600), now: now)
        XCTAssertTrue(seen.hasPrefix("Last seen "))
        XCTAssertEqual(text(facts), seen)
        XCTAssertEqual(RecorderStatusWords.byline(facts, now: now), "Not connected · \(seen)")
        XCTAssertEqual(RecorderStatusWords.chip(facts, recording: false, here: "this Mac", now: now)?.detail, "Soundcore Work · Not connected · \(seen)")
        for words in [text(facts), RecorderStatusWords.byline(facts, now: now)] {
            XCTAssertFalse(words.contains("Last connected"), words)
        }
    }

    func testBehaviorListenLiveReadsAsListeningLiveInTheRecordingTone() {
        var facts = soundcore()
        facts.isRecording = true
        facts.isListeningLive = true
        facts.batteryLevel = 80
        let line = RecorderStatusWords.line(facts, here: "this Mac", now: now)
        XCTAssertEqual(line.text, "Listening live")
        XCTAssertEqual(line.tone, .recording)
        XCTAssertEqual(RecorderStatusWords.byline(facts, now: now), "Connected · Listening live")
        let chip = RecorderStatusWords.chip(facts, recording: false, here: "this Mac", now: now)
        XCTAssertEqual(chip?.tone, .recording)
        XCTAssertEqual(chip?.showsDot, true)
        XCTAssertEqual(chip?.detail, "Soundcore Work · Listening live")
    }

    func testBehaviorLookingForItReadsTheSameEverywhere() {
        let facts = soundcore(.searching, linked: false)
        XCTAssertEqual(text(facts), "Looking for it…")
        XCTAssertEqual(RecorderStatusWords.byline(facts, now: now), "Looking for it…")
        XCTAssertEqual(text(soundcore(.connecting, linked: false)), "Connecting…")
        XCTAssertEqual(text(soundcore(.notSetUp, linked: false)), "Not set up", "said, never dropped")
    }

    func testBehaviorManagedElsewhereSaysWhatThatDeviceLastKnew() {
        var facts = soundcore(.notConnected, linked: false)
        facts.managedBy = "Studio Mac"
        facts.lastKnown = "Recording since 10:02, as of 10:14"
        let line = RecorderStatusWords.line(facts, here: "this iPhone", now: now)
        XCTAssertEqual(line.text, "Managed by Studio Mac · Recording since 10:02, as of 10:14")
        XCTAssertEqual(line.shortText, "Managed by Studio Mac")
        XCTAssertEqual(RecorderStatusWords.byline(facts, now: now), "Managed by Studio Mac · Recording since 10:02, as of 10:14")
        let chip = RecorderStatusWords.chip(facts, recording: false, here: "this Mac", now: now)
        XCTAssertEqual(chip?.label, "Soundcore on Studio Mac")
        XCTAssertEqual(chip?.shortLabel, "On Mac")
    }

    func testBehaviorAHandoffSaysWhoIsLettingGo() {
        var facts = soundcore(.notConnected, linked: false)
        facts.handoff = .asking(owner: "Studio Mac")
        XCTAssertEqual(text(facts, here: "this iPhone"), "Asking Studio Mac to let go…")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this iPhone", now: now).shortText, "Asking Studio Mac…")
        XCTAssertEqual(RecorderStatusWords.menuItem(facts, here: "this iPhone"), "Asking Studio Mac to let go of Soundcore Work…")
        facts.handoff = .done(at: now)
        XCTAssertEqual(text(facts, here: "this iPhone"), "On this iPhone now")
        XCTAssertEqual(text(facts, here: "this Mac"), "On this Mac now")
        facts.handoff = .refused(by: "Studio Mac", message: "It's recording.")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this Mac", now: now).tone, .attention)
    }

    func testBehaviorAnImportSaysWhereItIsAndHowItTravels() {
        var facts = soundcore()
        facts.importing = .init(position: 1, total: 3, fraction: 0.25)
        facts.fastTransfer = .transferring
        let line = RecorderStatusWords.line(facts, here: "this iPhone", now: now)
        XCTAssertEqual(line.text, "Importing 1 of 3 · Over Wi‑Fi")
        XCTAssertEqual(line.shortText, "Importing 1 of 3")
        XCTAssertEqual(line.progress, 0.25)
        XCTAssertEqual(RecorderStatusWords.menuItem(facts, here: "this Mac"), "Importing from Soundcore Work · 1 of 3")
        facts.importing = .init(position: 1, total: 2, suspended: true)
        XCTAssertEqual(text(facts), "2 recordings wait to import")
        facts.importing = nil
        facts.otherAppWait = "Waiting for the Soundcore app to finish"
        XCTAssertEqual(text(facts), "Waiting for the Soundcore app to finish")
        XCTAssertEqual(RecorderStatusWords.byline(facts, now: now), "Connected · Waiting for the Soundcore app to finish")
    }

    func testBehaviorAFolderSaysWhetherItsWatched() {
        var facts = RecorderFacts(id: "f", name: "Zoom H1", shortName: "H1", symbol: "folder", isDirect: false, state: .connected, isLinked: false)
        facts.folder = .init(isWatching: true, lastImport: now.addingTimeInterval(-7200))
        facts.newCount = 2
        XCTAssertEqual(text(facts), "2 new in its folder")
        XCTAssertTrue(RecorderStatusWords.byline(facts, now: now).hasPrefix("Watching · Last import "))
        facts.folder = .init(isWatching: false, waitingForICloud: 3)
        XCTAssertEqual(text(facts), "Waiting for iCloud to download 3 files")
        facts.folder = .init(isWatching: false, hasProblem: true)
        XCTAssertEqual(text(facts), "Not watching")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this Mac", now: now).tone, .attention)
    }

    func testBehaviorAChipKeepsTheRecordersNameAndSaysWhetherItRecordsAlong() {
        var facts = soundcore()
        facts.batteryLevel = 80
        let chip = RecorderStatusWords.chip(facts, recording: true, here: "this Mac", now: now)
        XCTAssertEqual(chip?.label, "Soundcore · 80%")
        XCTAssertEqual(chip?.shortLabel, "Soundcore")
        facts.along = .recording
        XCTAssertEqual(RecorderStatusWords.chip(facts, recording: true, here: "this Mac", now: now)?.detail, "Soundcore Work · Recording along · 80%")
        XCTAssertEqual(RecorderStatusWords.chip(facts, recording: true, here: "this Mac", now: now)?.showsDot, true)
        facts.along = .failed
        XCTAssertEqual(RecorderStatusWords.chip(facts, recording: true, here: "this Mac", now: now)?.label, "Not recording")
        XCTAssertNil(RecorderStatusWords.chip(soundcore(.notSetUp, linked: false), recording: false, here: "this Mac", now: now))
    }

    func testBehaviorTheMenuBarNamesNewRecordings() {
        var facts = soundcore()
        XCTAssertNil(RecorderStatusWords.newRecordingsItem(facts))
        facts.newCount = 2
        XCTAssertEqual(RecorderStatusWords.newRecordingsItem(facts), "Soundcore Work · 2 New Recordings…")
        facts.newCount = 1
        XCTAssertEqual(RecorderStatusWords.newRecordingsItem(facts), "Soundcore Work · 1 New Recording…")
        XCTAssertNil(RecorderStatusWords.menuItem(facts, here: "this Mac"), "nothing under way")
    }

    func testBehaviorPeersReadAlikeFromEitherSide() {
        let phone = PeerFacts(id: "p", name: "Alex’s iPhone", kind: .iPhone, isConnected: true)
        XCTAssertEqual(PeerStatusWords.line(phone, now: now).text, "Connected")
        XCTAssertEqual(PeerStatusWords.line(phone, now: now).symbol, "iphone")
        let away = PeerFacts(id: "m", name: "Studio Mac", kind: .mac, isConnected: false, lastSeen: now.addingTimeInterval(-3600), waiting: 2)
        let line = PeerStatusWords.line(away, now: now)
        XCTAssertEqual(line.text, "\(RecorderStatusWords.lastSeen(now.addingTimeInterval(-3600), now: now)) · 2 waiting")
        XCTAssertEqual(line.shortText, "Not connected")
        XCTAssertEqual(PeerStatusWords.line(PeerFacts(id: "m", name: "Studio Mac", kind: .mac, isConnected: true, waiting: 1), now: now).text,
                       "Connected · 1 waiting")
        XCTAssertEqual(PeerStatusWords.line(PeerFacts(id: "p", name: "Alex’s iPhone", kind: .iPhone, isConnected: true, activity: .recording),
                                            now: now).tone, .recording)
        XCTAssertEqual(PeerStatusWords.line(PeerFacts(id: "m", name: "Studio Mac", kind: .mac, isConnected: false, notProcessing: true), now: now).text,
                       "Not set up to transcribe")
    }

    func testBehaviorACountdownLineMovesWithTheClock() {
        let line = StatusLineWords(id: "queue", symbol: "desktopcomputer", title: "This Mac", text: "Summarizing in 12 s · 1 waiting",
                                   tone: .calm, countdownUntil: now.addingTimeInterval(12))
        XCTAssertEqual(line.text(at: now.addingTimeInterval(4)), "Summarizing in 8 s · 1 waiting")
        XCTAssertEqual(line.accessibilityLabel, "This Mac, Summarizing in 12 s · 1 waiting")
    }
}
