import DaybookCore
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Multipoint recording: a recorder with record control starts and stops with this Mac's
/// recording, its recording joins the same conversation, and its trouble never touches the Mac
/// recording. A fake connection stands in for the recorder: no Bluetooth, no microphone.
@MainActor
final class MultipointRecordingTests: XCTestCase {
    private func setUp(_ recorder: FakeRecorder, configure: (inout ConfiguredDevice) -> Void = { _ in }) async throws -> (MultiSourceRig, DeviceSession) {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.tearDown() }
        var device = ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind)
        configure(&device)
        let session = DeviceSession(device: device, kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: rig.defaults)
        session.importer = { url, identity, attachTo, source in
            try await rig.state.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
        }
        session.libraryChanged(rig.state.meetings, ready: true)
        rig.state.sources.recorders.sessions = { [session] }
        addTeardownBlock { session.shutDown() }
        return (rig, session)
    }

    /// What `startRecording` does once this Mac's capture is running.
    private func macStartsRecording(_ rig: MultiSourceRig, title: String = "Zoom call") -> UUID {
        let id = rig.state.newMeeting(title: title)
        rig.state.prepareSourceCapture(id)
        rig.state.recordingID = id
        rig.state.recordingStartedAt = Date()
        rig.state.update(id) { $0.status = .recording; $0.date = rig.state.recordingStartedAt! }
        rig.state.recordingDidStart(id)
        return id
    }

    private func macStopsRecording(_ rig: MultiSourceRig, _ id: UUID) {
        rig.state.recordingWillFinish(id, at: Date())
        rig.state.recordingID = nil
        rig.state.recordingStartedAt = nil
    }

    func testARecorderTheIPhoneManagesIsLeftAloneAndTheStatusSaysSo() async throws {
        let recorder = FakeRecorder()
        let (rig, session) = try await setUp(recorder)
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "phone-1",
                                                  ownerName: "Alex’s iPhone", ownerClass: .phone)], thisDevice: "this-mac")
        XCTAssertEqual(session.managedElsewhere?.ownerName, "Alex’s iPhone")
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, [], "This Mac never reaches for a recorder the phone manages")
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .unavailable)
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work is managed by Alex’s iPhone. Recording on this Mac only.")
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, [])
    }

    func testRecorderStartsAndStopsWithTheMacRecordingAndItsRecordingJoinsTheSameConversation() async throws {
        let recorder = FakeRecorder()
        let (rig, session) = try await setUp(recorder)
        recorder.audio = try rig.audio("soundcore.wav", frequency: 523)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()

        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording)
        XCTAssertTrue(link.startedByDaybook)
        XCTAssertEqual(link.deviceKind, SoundcoreWorkIntegration.id)
        XCTAssertEqual(link.deviceSerial, "FAKE1")
        XCTAssertEqual(link.recordingID, recorder.recordings.first?.id, "The recorder's ID for the recording links it")
        XCTAssertEqual(recorder.commands, ["connect", "start"])
        XCTAssertEqual(rig.state.sources.recorders.status, "Also recording on Soundcore Work.")
        XCTAssertEqual(rig.meeting(id)?.status, .recording)

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect", "start", "pause"])
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work stopped. Its recording will be added here.")

        try await waitUntil("the recorder's recording to join the conversation") { rig.meeting(id)?.tracks.count == 1 }
        await rig.state.flush()
        XCTAssertEqual(recorder.transfers, [link.recordingID!])
        XCTAssertEqual(rig.state.meetings.count, 1, "Never a new conversation")
        let meeting = try XCTUnwrap(rig.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertEqual(track.device?.recordingID, link.recordingID)
        XCTAssertEqual(track.source, .soundcore)
        XCTAssertEqual(track.alignment?.method, .pending, "Lined up when processed: sound, then transcript, then clocks")
        XCTAssertEqual(track.alignment?.clockOffset ?? 99, link.recorderStartedAt!.timeIntervalSince(link.macStartedAt), accuracy: 0.001)
        XCTAssertEqual(meeting.companions?.first?.state, .attached)
        XCTAssertEqual(meeting.companions?.first?.trackID, track.id)
        XCTAssertTrue(meeting.revisions.contains { $0.field == "source:\(track.id.uuidString)" && $0.newValue == "Added Soundcore Work recording" })
        XCTAssertTrue(rig.state.awaitingModels.contains(id), "Waits for models rather than failing")
        session.libraryChanged(rig.state.meetings, ready: true)
        XCTAssertEqual(session.links.imported[link.recordingID!], id, "The device page shows it as already in Daybook")
    }

    func testRecorderOutOfRangeLeavesTheMacRecordingUntouched() async throws {
        let recorder = FakeRecorder()
        recorder.reachable = false
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()

        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .unavailable)
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work isn’t nearby. Recording on this Mac only.")
        XCTAssertEqual(rig.state.recordingID, id, "The Mac recording carries on")
        XCTAssertEqual(rig.meeting(id)?.status, .recording)
        XCTAssertNil(rig.meeting(id)?.errorMessage)
        XCTAssertNil(rig.state.errorMessage)

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect"], "Nothing to stop")
    }

    func testRecorderThatDoesNotConfirmIsReportedQuietly() async throws {
        let recorder = FakeRecorder()
        recorder.confirms = false
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()

        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .failed)
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work didn’t start recording. Recording on this Mac only.")
        XCTAssertEqual(rig.meeting(id)?.status, .recording)
        XCTAssertNil(rig.state.errorMessage)

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect", "start"], "It isn't recording, so it isn't stopped")
    }

    func testRecorderAlreadyRecordingIsLinkedAndLeftRunning() async throws {
        let recorder = FakeRecorder()
        recorder.state = .connected
        let started = Date().addingTimeInterval(-300).rounded
        recorder.alreadyRecording(since: started)
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()

        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .alreadyRecording)
        XCTAssertFalse(link.startedByDaybook)
        XCTAssertEqual(link.recorderStartedAt, started)
        XCTAssertEqual(link.recordingID, String(UInt32(started.timeIntervalSince1970)))
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work was already recording. Its recording will be added here.")

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(recorder.commands.isEmpty, "Daybook didn't start it, so it doesn't stop it")
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work is still recording. Its recording will be added here.")

        // Its recording, whenever it arrives, still joins this conversation (by its ID).
        let file = try rig.audio("later.wav", frequency: 659)
        let joined = try await rig.state.importFromDevice(file, identity: MultiSourceRig.soundcore(started), attachTo: nil, source: .soundcore)
        XCTAssertEqual(joined, id)
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .attached)
    }

    func testARecorderFoundRecordingOnlyOnceItsListArrivesIsLinkedNotStarted() async throws {
        // The person pressed record on it before this Mac connected; its status and list come a
        // moment after the connection, as a real recorder's do.
        let recorder = FakeRecorder()
        recorder.listingDelay = .milliseconds(300)
        let started = Date().addingTimeInterval(-120).rounded
        recorder.recordingUnseen(since: started)
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .alreadyRecording, "decided from its list, not before it arrived")
        XCTAssertEqual(link.recordingID, String(UInt32(started.timeIntervalSince1970)))
        XCTAssertEqual(link.recorderStartedAt, started)
        XCTAssertEqual(recorder.commands, ["connect"], "never told to start")
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect"], "nor to stop: Daybook didn't start it")
    }

    func testStoppingLeavesARecordingThePersonStartedSinceAlone() async throws {
        let recorder = FakeRecorder()
        let (rig, _) = try await setUp(recorder)
        recorder.audio = try rig.audio("first.wav", frequency: 587)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording)
        // On the recorder, the person stops it and starts a recording of their own.
        recorder.personStartsAnother(at: Date().addingTimeInterval(1).rounded)
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(recorder.commands.contains("pause"), "their recording isn't Daybook's to stop")
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
        try await waitUntil("Daybook's recording to join") { rig.meeting(id)?.tracks.count == 1 }
        XCTAssertEqual(recorder.transfers, [link.recordingID!])
    }

    func testARecorderThatStartedAfterDaybookGaveUpIsStoppedWithTheMac() async throws {
        let recorder = FakeRecorder()
        recorder.confirmsLate = true
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .failed)
        try await waitUntil("it starts after all") { recorder.status?.isRecording == true && !recorder.recordCommandPending }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect", "start", "pause"], "it started after all, from Daybook's command: stopped like one that confirmed")
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .stopped)
        XCTAssertTrue(link.startedByDaybook)
        XCTAssertNotNil(link.recordingID)
    }

    func testARecorderOutOfReachAtStopIsReportedQuietlyAndItsRecordingStillJoins() async throws {
        let recorder = FakeRecorder()
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        recorder.disconnect()
        recorder.reachable = false
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(rig.state.sources.recorders.status, "Couldn’t reach Soundcore Work to stop it. Stop it on the recorder.")
        XCTAssertNil(rig.state.recordingID, "the Mac recording finished")
        XCTAssertNil(rig.state.errorMessage)
        XCTAssertNil(rig.meeting(id)?.errorMessage)
        // Stopped by hand and imported later, its recording still joins this conversation.
        let file = try rig.audio("later-stop.wav", frequency: 698)
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", recordingID: try XCTUnwrap(link.recordingID))
        let joined = try await rig.state.importFromDevice(file, identity: identity, attachTo: nil, source: .soundcore)
        XCTAssertEqual(joined, id)
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .attached)
    }

    func testARecorderThatDoesntConfirmItsStopIsReportedQuietly() async throws {
        let recorder = FakeRecorder()
        let (rig, _) = try await setUp(recorder)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        recorder.confirms = false
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, ["connect", "start", "pause"])
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(rig.state.sources.recorders.status, "Soundcore Work didn’t confirm it stopped. Stop it on the recorder.")
        XCTAssertNil(rig.state.recordingID, "the Mac recording finished")
        XCTAssertNil(rig.state.errorMessage)
    }

    /// The real Soundcore connection against the simulated recorder: Start, Pause, the finished
    /// recording's transfer, and its arrival in the conversation this Mac recorded.
    func testSimulatedSoundcoreWorkRecordsAlongsideAndItsRecordingJoins() async throws {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.tearDown() }
        let simulated = SimulatedSoundcore(recordings: [])
        let transport = SimulatedSoundcoreTransport(device: simulated)
        var environment = DeviceEnvironment(defaults: rig.defaults, stagingDirectory: rig.root.appendingPathComponent("DeviceImports"))
        environment.soundcoreTransport = { transport }
        var timing = SoundcoreTiming()
        timing.request = .seconds(3); timing.stall = .milliseconds(400); timing.settle = .milliseconds(20)
        timing.scan = .milliseconds(300); timing.connect = .milliseconds(600); timing.reconnect = .milliseconds(300)
        timing.recordConfirm = .milliseconds(1_500); timing.backoff = [.milliseconds(40)]
        environment.soundcoreTiming = timing
        var device = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        device.importsAutomatically = false
        environment.storage(for: device, method: .direct).encode(SoundcoreSnapshot(deviceID: transport.peripheralID, name: simulated.name), "recorder")
        let connection = SoundcoreConnection(device: device, environment: environment)
        let session = DeviceSession(device: device, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: rig.defaults)
        addTeardownBlock { session.shutDown() }
        session.importer = { url, identity, attachTo, source in
            try await rig.state.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
        }
        session.activate()
        session.libraryChanged(rig.state.meetings, ready: true)
        rig.state.sources.recorders.sessions = { [session] }
        rig.state.sources.recorders.timing = .init(connect: .seconds(5), confirm: .seconds(5), listing: .seconds(5), poll: .milliseconds(10))
        XCTAssertEqual(connection.state, .notConnected, "Not connected until this Mac records")

        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(simulated.isRecording)
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording)
        XCTAssertEqual(link.deviceSerial, simulated.serial)
        XCTAssertEqual(link.recordingID, simulated.activeRecording.map { String($0.id) })

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(simulated.isRecording)
        try await waitUntil("the recording to transfer and join", timeout: 15) { rig.meeting(id)?.tracks.count == 1 }
        await rig.state.flush()
        let meeting = try XCTUnwrap(rig.meeting(id))
        XCTAssertEqual(rig.state.meetings.count, 1)
        XCTAssertEqual(meeting.tracks.first?.device?.recordingID, link.recordingID)
        XCTAssertEqual(meeting.tracks.first?.device?.serial, simulated.serial)
        XCTAssertEqual(meeting.companions?.first?.state, .attached)
        let allowed: Set<String> = ["1-1", "26-14", "27-14", "46-1", "26-7", "26-17", "24-130"]
        XCTAssertTrue(simulated.received.allSatisfy { allowed.contains("\($0.type)-\($0.command)") }, "\(simulated.received)")
        XCTAssertEqual(simulated.received.filter { $0.type == 0x18 && $0.command == 0x82 }.count, 2, "One Start, one Pause")
    }

    func testLinksFromAnEarlierRecordingAreLeftAlone() async throws {
        let recorder = FakeRecorder()
        recorder.state = .connected
        recorder.alreadyRecording(since: Date().addingTimeInterval(-60).rounded)
        let (rig, _) = try await setUp(recorder)
        // A link an interrupted session left behind still says the recorder is recording.
        let id = rig.state.newMeeting(title: "Weekly sync")
        let stale = CompanionRecording(deviceID: "recorder", deviceKind: SoundcoreWorkIntegration.id, deviceName: "Soundcore Work",
                                       macStartedAt: Date().addingTimeInterval(-86_400), state: .recording, startedByDaybook: true)
        rig.state.update(id) { $0.companions = [stale] }
        rig.state.prepareSourceCapture(id)
        rig.state.recordingID = id
        rig.state.recordingStartedAt = Date()
        rig.state.recordingDidStart(id)
        await rig.state.sources.recorders.settle()
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(recorder.commands.isEmpty, "The person's own recording on the recorder isn't stopped")
        XCTAssertEqual(rig.meeting(id)?.companions?.first { $0.id == stale.id }, stale, "The old link is untouched")
        XCTAssertEqual(rig.meeting(id)?.companions?.last?.state, .alreadyRecording)
    }

    func testOnlyRecordersSetToRecordAlongsideTheMacStart() async throws {
        let recorder = FakeRecorder()
        let (rig, _) = try await setUp(recorder) { $0.alsoRecordsWithMac = false }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertNil(rig.meeting(id)?.companions)
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertNil(rig.state.sources.recorders.status)

        var device = ConfiguredDevice(id: "x", kind: SoundcoreWorkIntegration().kind)
        XCTAssertTrue(device.recordsAlongsideMac, "On by default once a recorder with record control is set up")
        device.disabledMethods.insert(.direct)
        let off = DeviceSession(device: device, kind: SoundcoreWorkIntegration().kind, connections: [FakeRecorder()], defaults: rig.defaults)
        rig.state.sources.recorders.sessions = { [off] }
        XCTAssertTrue(rig.state.sources.recorders.eligible().isEmpty, "Not with its direct method turned off")
    }
}

// MARK: Through the recorder's owner

/// Multipoint with a recorder another device manages: this Mac asks that device (a connected iPhone)
/// to start and stop it, and the owner answers from its own device session.
@MainActor
final class RecorderOwnerTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: false)
        addTeardownBlock { await rig.state.phoneLink.shutDown(); await rig.tearDown() }
        return rig
    }

    private func recorderSession(_ recorder: FakeRecorder, defaults: UserDefaults) -> DeviceSession {
        let session = DeviceSession(device: ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind),
                                    kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: defaults)
        addTeardownBlock { session.shutDown() }
        return session
    }

    private func macStartsRecording(_ rig: MultiSourceRig) -> UUID {
        let id = rig.state.newMeeting(title: "Walk-through")
        rig.state.prepareSourceCapture(id)
        rig.state.recordingID = id
        rig.state.recordingStartedAt = Date()
        rig.state.recordingDidStart(id)
        return id
    }

    private func macStopsRecording(_ rig: MultiSourceRig, _ id: UUID) {
        rig.state.recordingWillFinish(id, at: Date())
        rig.state.recordingID = nil
        rig.state.recordingStartedAt = nil
    }

    func testTheOwnerStartsAndStopsOnlyTheRecordingItWasAskedAbout() async throws {
        let rig = try await rig()
        let recorder = FakeRecorder()
        let session = recorderSession(recorder, defaults: rig.defaults)
        var timing = RecorderRemoteControl.Timing()
        timing.connect = .seconds(2); timing.confirm = .seconds(2); timing.inventory = .seconds(1); timing.listing = .seconds(1)
        timing.poll = .milliseconds(10)
        let target = LinkRecorderTarget(kind: SoundcoreWorkIntegration.id, serial: "FAKE1")
        let conversation = UUID()
        let start = await RecorderRemoteControl.answer(LinkRecordRequest(action: .start, conversationID: conversation, recorder: target),
                                                       target: target, sessions: [session], timing: timing)
        guard case .accepted(let ack) = start else { return XCTFail("\(start)") }
        XCTAssertFalse(ack.wasAlreadyRecording)
        let recordingID = try XCTUnwrap(ack.recordingID)
        XCTAssertEqual(recorder.commands, ["connect", "start"])

        // Asked again (the person had pressed record already): it says so.
        let again = await RecorderRemoteControl.answer(LinkRecordRequest(action: .start, conversationID: conversation, recorder: target),
                                                       target: target, sessions: [session], timing: timing)
        guard case .accepted(let repeated) = again else { return XCTFail("\(again)") }
        XCTAssertTrue(repeated.wasAlreadyRecording)

        // The person stopped it and started their own: a stop of Daybook's recording leaves theirs alone.
        recorder.personStartsAnother(at: Date().addingTimeInterval(1).rounded)
        var named = target
        named.recordingID = recordingID
        let refused = await RecorderRemoteControl.answer(LinkRecordRequest(action: .stop, conversationID: conversation, recorder: named),
                                                         target: named, sessions: [session], timing: timing)
        XCTAssertEqual(refused, .refused(LinkRecordRefusal(reason: .notRecording)))
        XCTAssertFalse(recorder.commands.contains("pause"))
        // Its own recording, named, is stopped.
        named.recordingID = Self.inProgress(recorder)
        let stop = await RecorderRemoteControl.answer(LinkRecordRequest(action: .stop, conversationID: conversation, recorder: named),
                                                      target: named, sessions: [session], timing: timing)
        guard case .accepted = stop else { return XCTFail("\(stop)") }
        XCTAssertEqual(recorder.commands.last, "pause")

        // A recorder another device manages isn't this one's to drive.
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "mac-2", ownerName: "Studio Mac",
                                                  ownerClass: .mac)], thisDevice: "this-phone")
        let elsewhere = await RecorderRemoteControl.answer(LinkRecordRequest(action: .start, conversationID: conversation, recorder: target),
                                                           target: target, sessions: [session], timing: timing)
        guard case .refused(let notMine) = elsewhere else { return XCTFail("\(elsewhere)") }
        XCTAssertEqual(notMine.reason, .unsupported)
    }

    private static func inProgress(_ recorder: FakeRecorder) -> String? { recorder.recordings.first(where: \.isInProgress)?.id }

    /// A stop naming a recording waits for the recorder's list read now: an older one may still name a
    /// recording the person has stopped since, and pausing then would stop the person's own.
    func testTheOwnerNeverStopsARecordingByAListItHasntReadAgain() async throws {
        let rig = try await rig()
        let recorder = FakeRecorder()
        let session = recorderSession(recorder, defaults: rig.defaults)
        var timing = RecorderRemoteControl.Timing()
        timing.connect = .seconds(2); timing.confirm = .seconds(2); timing.inventory = .milliseconds(300); timing.listing = .seconds(1)
        timing.poll = .milliseconds(10)
        let target = LinkRecorderTarget(kind: SoundcoreWorkIntegration.id, serial: "FAKE1")
        let conversation = UUID()
        let start = await RecorderRemoteControl.answer(LinkRecordRequest(action: .start, conversationID: conversation, recorder: target),
                                                       target: target, sessions: [session], timing: timing)
        guard case .accepted(let ack) = start else { return XCTFail("\(start)") }
        var named = target
        named.recordingID = try XCTUnwrap(ack.recordingID)

        // The person stopped it and started their own; the recorder is slow to list again.
        recorder.personStartsAnother(at: Date().addingTimeInterval(1).rounded)
        recorder.refreshDelay = .seconds(2)
        let unsure = await RecorderRemoteControl.answer(LinkRecordRequest(action: .stop, conversationID: conversation, recorder: named),
                                                        target: named, sessions: [session], timing: timing)
        guard case .refused(let refusal) = unsure else { return XCTFail("\(unsure)") }
        XCTAssertEqual(refusal.reason, .recorderUnavailable, "asked again later")
        XCTAssertFalse(recorder.commands.contains("pause"), "the person's recording keeps going")

        // Listed again, it says what it's recording: not that one.
        recorder.refreshDelay = .milliseconds(30)
        try await waitUntil("the slow list") { !recorder.isRefreshing }
        let refused = await RecorderRemoteControl.answer(LinkRecordRequest(action: .stop, conversationID: conversation, recorder: named),
                                                         target: named, sessions: [session], timing: timing)
        XCTAssertEqual(refused, .refused(LinkRecordRefusal(reason: .notRecording)))
        XCTAssertFalse(recorder.commands.contains("pause"))
    }

    func testMultipointStartsAndStopsARecorderThePhoneManagesThroughThePhone() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state, features: [LinkCapabilities.recorderControlFeature])
        defer { Task { await phone.tearDown(rig.state) } }
        let recorder = FakeRecorder()
        let session = recorderSession(recorder, defaults: rig.defaults)
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: phone.syncID,
                                                  ownerName: PhoneLinkRig.phoneName, ownerClass: .phone)], thisDevice: "this-mac")
        rig.state.sources.recorders.sessions = { [session] }
        let started = Date().rounded
        phone.recorder.answer = { request in
            request.action == .start
                ? .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: started, recordingID: "SC-1"))
                : .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date(), recordingID: request.recorder?.recordingID))
        }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(recorder.commands, [], "this Mac never reaches for a recorder the phone manages")
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording)
        XCTAssertTrue(link.startedByDaybook)
        XCTAssertEqual(link.recordingID, "SC-1")
        XCTAssertEqual(link.recorderStartedAt, started)
        XCTAssertEqual(link.deviceKind, SoundcoreWorkIntegration.id, "the recorder's recording joins by this link")
        XCTAssertEqual(rig.state.sources.recorders.status, "Also recording on Soundcore Work.")
        let start = try XCTUnwrap(phone.recorder.requests.first)
        XCTAssertEqual(start.recorder, LinkRecorderTarget(kind: SoundcoreWorkIntegration.id, serial: "FAKE1"))
        XCTAssertFalse(start.isStandalone)

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        let stop = try XCTUnwrap(phone.recorder.requests.last)
        XCTAssertEqual(stop.action, .stop)
        XCTAssertEqual(stop.recorder?.recordingID, "SC-1", "only the recording it started")
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
    }

    func testARecorderHandedToThePhoneWhileRecordingIsStoppedThroughThePhone() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state, features: [LinkCapabilities.recorderControlFeature])
        defer { Task { await phone.tearDown(rig.state) } }
        let recorder = FakeRecorder()
        let session = recorderSession(recorder, defaults: rig.defaults)
        rig.state.sources.recorders.sessions = { [session] }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(recorder.commands, ["connect", "start"], "this Mac manages it: it starts it itself")
        // Mid-recording, the phone takes the recorder over.
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: phone.syncID,
                                                  ownerName: PhoneLinkRig.phoneName, ownerClass: .phone)], thisDevice: "this-mac")
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(recorder.commands.contains("pause"))
        let stop = try XCTUnwrap(phone.recorder.requests.last)
        XCTAssertEqual(stop.recorder?.recordingID, link.recordingID)
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)

        // A phone that isn't connected is named, so the person knows where to stop it.
        let other = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        session.applyOwnership([RecorderOwnership(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", ownerID: "another-phone",
                                                  ownerName: "Alex’s iPhone", ownerClass: .phone)], thisDevice: "this-mac")
        rig.state.update(other) { $0.companions = [CompanionRecording(deviceID: "recorder", deviceKind: SoundcoreWorkIntegration.id,
                                                                       deviceSerial: "FAKE1", deviceName: "Soundcore Work",
                                                                       macStartedAt: rig.state.recordingStartedAt!, state: .recording,
                                                                       startedByDaybook: true)] }
        macStopsRecording(rig, other)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(other)?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(rig.state.sources.recorders.status, "Couldn’t reach Soundcore Work to stop it. Stop it on Alex’s iPhone.")
    }
}

private extension Date {
    /// Whole seconds, as recorder IDs are.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
