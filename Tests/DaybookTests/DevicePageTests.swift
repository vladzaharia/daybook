import DaybookCore
import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

/// What a recorder's page, its recordings, its handoff, and Add Device offer, by the rules the Mac and the iPhone
/// share (DaybookUI's `Devices`): one way to act on a problem, only what can be done now, one set of words, and no
/// import from a recorder another device manages. A fake recorder stands in: no Bluetooth.
@MainActor
final class DevicePageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(_ recorder: FakeRecorder) -> DeviceSession {
        let defaults = makeTestDefaults("local.daybook.tests.device-page")
        let session = DeviceSession(device: ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind),
                                    kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: defaults)
        session.libraryChanged([], ready: true)
        addTeardownBlock { session.shutDown() }
        return session
    }

    /// A Soundcore's facts: connected, with record control and live listening.
    private func facts(_ change: (inout RecorderFacts) -> Void = { _ in }) -> RecorderFacts {
        var facts = RecorderFacts(id: "recorder", name: "Soundcore Work", shortName: "Soundcore", symbol: "recordingtape", isDirect: true,
                                  state: .connected, isLinked: true)
        facts.hasRecordControl = true
        facts.hasLiveListening = true
        change(&facts)
        return facts
    }

    func testARecorderAnotherDeviceManagesOffersNothingToImportHere() {
        let recorder = FakeRecorder()
        recorder.recordings = [DeviceRecording(id: "1780000000", startedAt: start)]
        let session = session(recorder)
        XCTAssertTrue(session.importsHere)
        XCTAssertEqual(session.importableCount, 1, "this Mac manages it: its new recording is offered")

        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "phone-1",
                                                  ownerName: "Alex’s iPhone", ownerClass: .phone)], thisDevice: "this-mac")
        XCTAssertEqual(session.newRecordings.count, 1, "still on the recorder, and listed")
        XCTAssertFalse(session.importsHere)
        XCTAssertEqual(session.importableCount, 0, "the iPhone imports it; it arrives here through sync")
        XCTAssertEqual(RecorderActions.available(RecorderFacts(session: session)), [], "moving it here is the handoff's")
        XCTAssertEqual(DeviceRecordingActions.available([.recording("1780000000")], in: session, revealsAudio: true), [])
    }

    func testTheMoreMenuOffersOnlyWhatApplies() {
        let recorder = FakeRecorder()
        let session = session(recorder)
        let away = RecorderMenuOffer(session)
        XCTAssertFalse(away.recordControl, "Not offered while it isn't linked, rather than dimmed")
        XCTAssertFalse(away.disconnect)
        XCTAssertTrue(away.connect)
        XCTAssertFalse(away.refresh)
        XCTAssertTrue(away.handoff, "Use on another device, from its menu")

        recorder.state = .connected
        let linked = RecorderMenuOffer(session)
        XCTAssertTrue(linked.recordControl)
        XCTAssertTrue(linked.disconnect)
        XCTAssertFalse(linked.connect)
        XCTAssertTrue(linked.refresh)
        XCTAssertFalse(linked.listenLive, "A recorder without live audio never offers it")

        recorder.state = .unavailable
        XCTAssertFalse(RecorderMenuOffer(session).connect, "Bluetooth is off: Connect would do nothing")
    }

    func testAMethodRowLeavesOutWhatTheBylineSays() {
        XCTAssertTrue(RecorderMethods.bylineSays(.connected, managedElsewhere: false))
        XCTAssertTrue(RecorderMethods.bylineSays(.notConnected, managedElsewhere: true), "\"Managed by …\" is the byline")
        XCTAssertFalse(RecorderMethods.bylineSays(.notConnected, managedElsewhere: false), "\"Connects when it's nearby.\" says more")
    }

    func testAProblemOffersAtMostTwoActionsWithDismissWhenThereIsRoom() {
        func problem(_ actions: [DeviceProblemAction]) -> DeviceProblem {
            DeviceProblem(id: "test", title: "Something happened", message: "What to do.", actions: actions)
        }
        XCTAssertEqual(RecorderProblemBox.actions(problem([.reconnect]), on: .mac), [.reconnect, .dismiss])
        XCTAssertEqual(RecorderProblemBox.actions(problem([.openBluetoothSettings, .tryAgain, .technicalDetails]), on: .mac),
                       [.openBluetoothSettings, .tryAgain])
        XCTAssertEqual(RecorderProblemBox.actions(problem([.dismiss]), on: .mac), [.dismiss])
        XCTAssertEqual(RecorderProblemBox.actions(problem([.setUpFolder, .technicalDetails]), on: .mac, excluding: [.setUpFolder]),
                       [.technicalDetails, .dismiss], "a folder that's set up already isn't offered again")
        XCTAssertEqual(RecorderProblemBox.actions(problem([.setUpFolder, .technicalDetails]), on: .iPhone), [.dismiss],
                       "the iPhone imports exports with Import Audio, and shows technical facts on Details")
    }

    func testBehaviorSetupOffersOnlyWhatItCanDoAboutAProblem() {
        XCTAssertNil(RecorderSetupProblem.action(SoundcoreIssue.rejected.problem, on: .mac),
                     "the folder is the step's own fallback, and Technical Details isn't a search")
        XCTAssertEqual(RecorderSetupProblem.action(SoundcoreIssue.connectTimeout.problem, on: .mac), .tryAgain)
        XCTAssertEqual(RecorderSetupProblem.action(SoundcoreIssue.bluetoothOff.problem, on: .iPhone), .openBluetoothSettings)
        XCTAssertEqual(RecorderSetupProblem.action(SoundcoreIssue.bluetoothDenied.problem, on: .mac), .openPrivacySettings)
        XCTAssertNil(RecorderSetupProblem.action(SoundcoreIssue.bluetoothUnsupported.problem, on: .mac))
        XCTAssertNil(RecorderSetupProblem.action(SoundcoreIssue.listFailed.problem, on: .mac), "Refresh Status is a connected recorder's")
    }

    // MARK: What can be done now

    func testBehaviorThePageOffersWhatTheRecorderCanDoNowTheSameOnBothDevices() {
        XCTAssertEqual(RecorderActions.available(facts()), [.record], "Record on Soundcore is a button on the page, on the Mac too")
        XCTAssertEqual(RecorderActions.available(facts { $0.isRecording = true }), [.pause, .listenLive])
        XCTAssertEqual(RecorderActions.available(facts { $0.isRecording = true; $0.isListeningLive = true }), [.pause, .stopListening])
        XCTAssertEqual(RecorderActions.available(facts { $0.newCount = 2 }), [.record, .importNew(2)])
        XCTAssertEqual(RecorderActions.available(facts { $0.newCount = 2; $0.importing = .init(position: 1, total: 2) }), [],
                       "nothing new starts while a recording comes off it")
        XCTAssertEqual(RecorderActions.available(facts { $0.notListed = true }), [.record, .checkForNew])
        XCTAssertEqual(RecorderActions.available(facts { $0.isLinked = false; $0.state = .notConnected; $0.canConnect = true }), [.connect])
        XCTAssertEqual(RecorderActions.available(facts { $0.managedBy = "Studio Mac" }), [])
        XCTAssertEqual(RecorderActions.available(facts { $0.handoff = .asking(owner: "Studio Mac") }), [], "never while it moves")
        // Connect where it would do something, by one rule for the page and the iPhone's status card.
        let recorder = FakeRecorder()
        let session = session(recorder)
        XCTAssertTrue(RecorderFacts.canConnect(session))
        recorder.state = .unavailable
        XCTAssertFalse(RecorderFacts.canConnect(session), "Bluetooth is off")
        recorder.state = .notConnected
        session.update { $0.disabledMethods.insert(.direct) }
        XCTAssertFalse(RecorderFacts.canConnect(session), "its direct link is turned off")

        XCTAssertEqual(RecorderAction.pause.label(shortName: "Soundcore").title, "Pause on Soundcore")
        XCTAssertEqual(RecorderAction.importNew(1).label(shortName: "Soundcore").spoken, "Import 1 New Recording")
    }

    func testBehaviorFastTransferSaysToKeepDaybookOpenOnThePageAndInTheLine() {
        var facts = facts { $0.importing = .init(position: 1, total: 1, fraction: 0.64) }
        facts.fastTransfer = .starting
        XCTAssertEqual(RecorderStatusWords.importTitle(facts), "Importing · Starting Wi‑Fi…")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this iPhone").shortText, "Starting Wi‑Fi…")
        facts.fastTransfer = .transferring
        XCTAssertEqual(RecorderStatusWords.importTitle(facts), "Importing · 64% · Keep Daybook open")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this iPhone").text, "Importing · 64% · Keep Daybook open")
        XCTAssertEqual(RecorderStatusWords.line(facts, here: "this iPhone").shortText, "Keep Daybook open")
        XCTAssertNil(RecorderStatusWords.importNote(facts, wireless: true, on: .iPhone), "the title says it already")

        facts.fastTransfer = nil
        facts.importing = .init(position: 1, total: 3, fraction: 0.2, secondsLeft: 372)
        XCTAssertEqual(RecorderStatusWords.importTitle(facts), "Importing 1 of 3 · about 6 min left")
        XCTAssertEqual(RecorderStatusWords.importNote(facts, wireless: true, on: .iPhone), "Keep your Soundcore near this iPhone.")
        XCTAssertEqual(RecorderStatusWords.importNote(facts, wireless: true, on: .mac), "Keep your Soundcore near this Mac.")
        facts.importing = .init(position: 1, total: 2, suspended: true)
        XCTAssertEqual(RecorderStatusWords.importTitle(facts), "2 recordings waiting for Soundcore")
        XCTAssertNil(RecorderStatusWords.importNote(facts, wireless: true, on: .mac))
    }

    // MARK: Words

    func testBehaviorEachDeviceWordsAProblemAndItsTipsForItself() {
        let denied = SoundcoreIssue.bluetoothDenied.problem
        XCTAssertEqual(RecorderStatusWords.problem(denied, on: .mac).message, denied.message, "the framework words its problems for the Mac")
        XCTAssertEqual(RecorderStatusWords.problem(denied, on: .iPhone).message, "Allow Bluetooth for Daybook in Settings.")
        XCTAssertEqual(RecorderStatusWords.actionTitle(.openPrivacySettings, on: .iPhone), "Open Settings")
        XCTAssertEqual(RecorderStatusWords.actionTitle(.openPrivacySettings, on: .mac), "Open Privacy Settings")
        let notFound = RecorderStatusWords.problem(SoundcoreIssue.notFound.problem, on: .iPhone).message
        XCTAssertFalse(notFound.contains("Mac"), notFound)

        let kind = SoundcoreWorkIntegration().kind
        let mac = RecorderStatusWords.discoveryTips(kind, on: .mac).map(\.text)
        let phone = RecorderStatusWords.discoveryTips(kind, on: .iPhone).map(\.text)
        XCTAssertEqual(mac, ["Take it out of its case.", "Close the Soundcore app on your phone.",
                             "If your iPhone manages it, wait a few minutes.", "Bring it close to this Mac."])
        XCTAssertEqual(phone, ["Take it out of its case.", "Close the Soundcore app.",
                               "If your Mac manages it, wait a few minutes.", "Bring it close to this iPhone."])
        XCTAssertEqual(RecorderStatusWords.kindLabel(kind), "Records on its own.", "what it is, never how it connects")
        XCTAssertEqual(RecorderStatusWords.discoveryTitle(kind, searching: false, connecting: false, found: false), "No Soundcore Found Nearby")
        XCTAssertEqual(RecorderStatusWords.discoveryAction(searching: false, connecting: false, found: false), "Try Again")
        XCTAssertEqual(RecorderStatusWords.discoveryAction(searching: false, connecting: false, found: true), "Look Again")
        XCTAssertEqual(RecorderStatusWords.discoveryAction(searching: true, connecting: false, found: false), "Stop")
        XCTAssertNil(RecorderStatusWords.discoveryAction(searching: false, connecting: true, found: true))
        XCTAssertEqual(AddRecorderStep.after(choosing: kind, on: .iPhone), .discover(kind.id), "the iPhone adds a Soundcore over Bluetooth")
        XCTAssertEqual(AddRecorderStep.after(choosing: kind, on: .mac), .methods(kind.id))

        // The Mac's Add Device takes the step the rule names.
        XCTAssertEqual(AddDeviceSheet.step(choosing: kind), .setUp(kind.id), "a Soundcore's two ways in on the Mac")
        let folder = OtherRecorderIntegration().kind
        XCTAssertEqual(AddRecorderStep.after(choosing: folder, on: .iPhone), .methods(folder.id), "a folder is chosen on its own step")
        XCTAssertEqual(AddDeviceSheet.step(choosing: folder), .setUp(folder.id))
        XCTAssertEqual(AddDeviceSheet.step(choosing: DaybookPhoneIntegration().kind), .pairPhone)
    }

    func testBehaviorARecordersOptionsAreOneSetOfWords() {
        XCTAssertEqual(RecorderStatusWords.Option.importAutomatically.title(on: .mac), "Import automatically")
        XCTAssertEqual(RecorderStatusWords.Option.importAutomatically.title(on: .iPhone), "Import Automatically")
        XCTAssertEqual(RecorderStatusWords.Option.recordAlong.title(on: .mac), "Record along with this Mac")
        XCTAssertEqual(RecorderStatusWords.Option.recordAlong.title(on: .iPhone), "Record Along with This iPhone")
        XCTAssertEqual(RecorderStatusWords.Option.handBack.title(on: .iPhone), "Hand Back to Your Mac")
        XCTAssertEqual(RecorderStatusWords.removeTitle(on: .iPhone), "Remove from This iPhone…")
        XCTAssertEqual(RecorderStatusWords.removeConsequence(on: .mac),
                       "This Mac stops importing from it. Recordings you already imported stay in your library.")

        let session = session(FakeRecorder())
        XCTAssertEqual(RecorderPreferencesSection.options(session, on: .mac, handsBack: false), [.importAutomatically, .recordAlong])
        XCTAssertEqual(RecorderPreferencesSection.options(session, on: .iPhone, handsBack: true), [.importAutomatically, .recordAlong, .handBack],
                       "Fast transfer only for a recorder with its own Wi‑Fi")
    }

    // MARK: Recent imports

    func testBehaviorRecentImportsMergeFailuresByDateAndLeaveTheBoxsRetryToTheBox() {
        let meeting = UUID()
        let older = DeviceLibraryLinks.Entry(recordingID: "1", meetingID: meeting, trackID: UUID(), importedAt: start, fileName: "")
        let newer = DeviceLibraryLinks.Entry(recordingID: "2", meetingID: meeting, trackID: UUID(), importedAt: start.addingTimeInterval(600), fileName: "")
        let failed = DeviceImportFailure(recording: DeviceRecording(id: "3", startedAt: start), method: .direct, message: "Stopped sending audio.",
                                         date: start.addingTimeInterval(300))
        let entries = RecentImportsSection.entries(recent: [older, newer], failures: [failed])
        XCTAssertEqual(entries.map(\.id), [newer.trackID.uuidString, "failed:3", older.trackID.uuidString], "newest first, failures among them")
        XCTAssertEqual(RecentImportsSection.entries(recent: [older, newer], failures: [failed], limit: 2).count, 2)

        XCTAssertEqual(RecentImportsSection.retriedAbove(problem: SoundcoreIssue.stalled.problem, failures: [failed]), "3",
                       "the box's Try Again retries it; its row doesn't offer it again")
        XCTAssertNil(RecentImportsSection.retriedAbove(problem: SoundcoreIssue.bluetoothOff.problem, failures: [failed]))
        XCTAssertNil(RecentImportsSection.retriedAbove(problem: nil, failures: [failed]))
    }

    // MARK: Handoff

    func testBehaviorTheHandoffOffersStopWaitingWhereverWaitingCanBeCalledOff() {
        func make(_ state: RecorderHandoff.State, managedElsewhere: Bool = true, overdue: Bool = false,
                  targets: [RecorderHandoff.Peer] = [], place: RecorderStatusWords.Place = .iPhone) -> RecorderHandoffPresentation {
            .make(state: state, recorder: "Soundcore Work", managedElsewhere: managedElsewhere, targets: targets, overdue: overdue,
                  place: place, thisDeviceSymbol: place == .mac ? "laptopcomputer" : "iphone")
        }
        guard case .moves(let here) = make(.idle, place: .mac) else { return XCTFail("at rest, Use on This Mac") }
        XCTAssertEqual(here.map(\.title), ["Use on This Mac"])
        XCTAssertEqual(here.first?.symbol, "laptopcomputer", "this device's own glyph")
        let phone = RecorderHandoff.Peer(linkID: UUID(), syncID: "phone", name: "Alex’s iPhone", deviceClass: .phone, handsOffRecorders: true)
        guard case .moves(let give) = make(.idle, managedElsewhere: false, targets: [phone], place: .mac) else {
            return XCTFail("the reverse, on the page too")
        }
        XCTAssertEqual(give.map(\.title), ["Use on Alex’s iPhone"])
        XCTAssertEqual(give.first?.symbol, "iphone")
        XCTAssertEqual(make(.idle, managedElsewhere: false), .nothing)

        for state: RecorderHandoff.State in [.asking(owner: "Studio Mac"), .ownerFinishing(owner: "Studio Mac", finishing: nil), .offering(to: "Studio Mac")] {
            guard case .line(_, _, let actions) = make(state) else { return XCTFail("\(state) is a working line") }
            XCTAssertEqual(actions, [.stopWaiting], "\(state) can be called off")
        }
        guard case .line(_, _, let waiting) = make(.waitingForSync(owner: "Studio Mac", since: start)) else { return XCTFail() }
        XCTAssertEqual(waiting, [.takeOverAnyway, .stopWaiting])
        guard case .box(_, _, let overdue) = make(.waitingForSync(owner: "Studio Mac", since: start), overdue: true) else {
            return XCTFail("waiting too long needs the person")
        }
        XCTAssertEqual(overdue, [.takeOverAnyway, .stopWaiting])
        guard case .box(let headline, let detail, let refused) = make(.refused(by: "Studio Mac", message: "It's busy.")) else {
            return XCTFail("a refusal is a warning box")
        }
        XCTAssertEqual(headline, "Studio Mac didn’t hand over Soundcore Work")
        XCTAssertEqual(detail, "It's busy.")
        XCTAssertEqual(refused, [.ok, .takeOverAnyway])
        guard case .line(_, _, let connecting) = make(.connecting(from: "Studio Mac")) else { return XCTFail() }
        XCTAssertEqual(connecting, [], "nothing to call off once it's free")

        XCTAssertEqual(RecorderHandoffPresentation.owner(.connecting(from: "Studio Mac"), managedBy: nil), "the other device")
        XCTAssertEqual(RecorderHandoffPresentation.owner(.asking(owner: "Studio Mac"), managedBy: nil), "Studio Mac")
    }

    // MARK: A recording's actions

    func testBehaviorARecordingsActionsAreOneListForEveryMenuAndSwipe() {
        let recorder = FakeRecorder()
        let new = DeviceRecording(id: "1780000000", startedAt: start, length: .exact(1_800))
        let inDaybook = DeviceRecording(id: "1779990000", startedAt: start.addingTimeInterval(-10_000), length: .exact(600))
        recorder.recordings = [new, inDaybook]
        recorder.state = .connected
        let session = session(recorder)
        let imported = Meeting(title: "Weekly product sync", date: inDaybook.startedAt!, tracks: [
            RecordingTrack(source: .soundcore, relativePath: "a.wav", fileName: "a.wav", duration: 600,
                           device: DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, recordingID: inDaybook.id))
        ])
        let overlapping = Meeting(title: "Design review", date: start.addingTimeInterval(60), tracks: [
            RecordingTrack(source: .microphone, relativePath: "m.wav", fileName: "m.wav", duration: 1_200)
        ])
        session.libraryChanged([imported, overlapping], ready: true)

        XCTAssertEqual(DeviceRecordingActions.available([.recording(new.id)], in: session, revealsAudio: true),
                       [.importRecordings(1), .addTo(overlapping.id, title: "Design review"), .chooseConversation],
                       "no Import over Wi‑Fi from a recorder without its own Wi‑Fi here")
        XCTAssertEqual(DeviceRecordingActions.importActions(count: 1, overlaps: session.overlaps(new), offersFastTransfer: true),
                       [.importRecordings(1), .importOverWiFi, .addTo(overlapping.id, title: "Design review"), .chooseConversation],
                       "the iPhone brings one over the recorder's Wi‑Fi on request, whatever its length")
        XCTAssertEqual(DeviceRecordingActions.importActions(count: 2, overlaps: [], offersFastTransfer: true),
                       [.importRecordings(2), .chooseConversation], "Fast Transfer on request is for one recording")
        XCTAssertEqual(DeviceRecordingAction.importOverWiFi.title, "Import over Wi‑Fi")
        XCTAssertEqual(DeviceRecordingActions.available([.recording(inDaybook.id)], in: session, revealsAudio: true),
                       [.showConversation(imported.id), .showInFinder(imported.id)],
                       "one recording is in one conversation: it opens there, never imported again beside it")
        XCTAssertEqual(DeviceRecordingActions.available([.recording(inDaybook.id)], in: session, revealsAudio: false),
                       [.showConversation(imported.id)], "Show in Finder only where there's a Finder")
        XCTAssertEqual(DeviceRecordingActions.available([.recording(new.id), .recording(inDaybook.id)], in: session, revealsAudio: true), [],
                       "nothing applies to a mix")
        XCTAssertEqual(DeviceRecordingAction.addTo(overlapping.id, title: "Design review").title, "Add to “Design review”")

        let chosen = ConversationChooser.candidates([imported, overlapping], near: [new], search: "")
        XCTAssertEqual(chosen.map(\.id), [overlapping.id, imported.id], "the day's conversations, newest first")
        XCTAssertEqual(ConversationChooser.candidates([imported, overlapping], near: [new], search: "design").map(\.id), [overlapping.id])
    }

    // MARK: Figures

    func testBehaviorFiguresSayWhenTheyreFromAlsoWhileAnotherDeviceManagesIt() {
        let recorder = FakeRecorder()
        let seen = start
        recorder.status = DeviceStatus(battery: .init(level: 80, charging: false), isRecording: false, serial: "FAKE1", updatedAt: seen)
        recorder.lastConnectedAt = seen
        let session = session(recorder)
        XCTAssertFalse(RecorderFigures.showsAsOf(session), "the byline's Last seen dates them at the same minute")
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "phone-1",
                                                  ownerName: "Alex’s iPhone", ownerClass: .phone)], thisDevice: "this-mac")
        XCTAssertTrue(RecorderFigures.showsAsOf(session), "managed elsewhere, the figures are shown, with their time")
        recorder.state = .connected
        XCTAssertFalse(RecorderFigures.showsAsOf(session), "live")

        let tiles = RecorderFigures.tiles(recorder.status!, capabilities: [.battery, .storage], stale: true)
        XCTAssertEqual(tiles.map(\.label), ["Recorder"], "only what it reports")
        XCTAssertEqual(RecorderStatusWords.asOf(seen, now: seen.addingTimeInterval(600)).hasPrefix("As of today, "), true)
    }
}
