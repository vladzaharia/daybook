import DaybookCaptions
import DaybookCore
@testable import DaybookDevices
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest

/// A shared recording on the device that manages a recorder (docs/multipoint.md, "Starting anywhere"):
/// its recorders start with it once however they're asked, their audio is saved into it as they
/// record, they stop with it (only the recording each made for it), and their files follow. Notes and
/// bookmarks are shared once by ID and never echoed. Against the simulated recorder: no Bluetooth.
@MainActor
final class SharedRecordingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var staging: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: makeTestSuite("local.daybook.tests.shared-recording"))
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookCascade-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: staging)
    }

    private struct Rig {
        let session: DeviceSession
        let connection: SoundcoreConnection
        let device: SimulatedSoundcore
        let cascade: RecorderCascade
        let imports: Imports
    }

    private final class Imports {
        var all: [(identity: DeviceRecordingIdentity, attachTo: UUID?)] = []
        var meetings: [Meeting] = []
    }

    private func rig(recording: Bool = false, recordsAlong: Bool = true) async throws -> Rig {
        let device = SimulatedSoundcore(recordings: [])
        device.recordsInRealTime = true
        device.pace = .milliseconds(15)
        // Recording before Daybook connects: the button's word reaches nobody.
        if recording { device.pressButton() }
        let transport = SimulatedSoundcoreTransport(device: device)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        let hooks = LiveCaptionHooks()
        hooks.makeCaptioner = { nil }
        environment.liveCaptions = hooks
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .milliseconds(800)
        timing.settle = .milliseconds(20)
        timing.recordConfirm = .milliseconds(1_500)
        timing.liveTail = .milliseconds(300)
        environment.soundcoreTiming = timing
        var configured = ConfiguredDevice(id: "sim", kind: SoundcoreWorkIntegration().kind)
        configured.alsoRecordsWithMac = recordsAlong
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        connection.importsAutomatically = false
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: defaults)
        let imports = Imports()
        session.importer = { [weak session] _, identity, attachTo, source in
            imports.all.append((identity, attachTo))
            let meeting = Meeting(id: attachTo ?? UUID(), title: "Shared", tracks: [RecordingTrack(source: source, relativePath: "x", fileName: "x",
                                                                                                    device: identity)])
            imports.meetings.append(meeting)
            session?.libraryChanged(imports.meetings, ready: true)
            return meeting.id
        }
        session.activate()
        session.libraryChanged([], ready: true)
        let cascade = RecorderCascade(sessions: { [session] })
        cascade.timing.connect = .seconds(3)
        cascade.timing.confirm = .seconds(3)
        cascade.timing.inventory = .seconds(2)
        cascade.timing.poll = .milliseconds(20)
        addTeardownBlock { session.shutDown() }
        return Rig(session: session, connection: connection, device: device, cascade: cascade, imports: imports)
    }

    // MARK: Starting and stopping with the shared recording

    func testRecordersStartOnceWithTheSharedRecordingSaveTheirAudioIntoItAndStopWithIt() async throws {
        let rig = try await rig()
        let conversation = UUID()
        rig.cascade.begin(conversation, title: "Design review", date: Date())
        // The device's own start and another device's request for the same recorder, at the same moment.
        let request = LinkRecordRequest(action: .start, conversationID: conversation, title: "Design review",
                                        recorder: LinkRecorderTarget(kind: SoundcoreWorkIntegration.id))
        async let own: Void = rig.cascade.startRecorders()
        async let asked = RecorderRemoteControl.answer(request, target: request.recorder!, sessions: [rig.session], cascade: rig.cascade)
        _ = await own
        guard case .accepted(let ack) = await asked else { return XCTFail("the same start answers the other device") }
        XCTAssertFalse(ack.wasAlreadyRecording, "Daybook started it for this conversation")
        XCTAssertEqual(rig.device.received.filter { $0.type == 0x18 && $0.command == 0x82 }.count, 1, "one Start, however it was asked")
        let member = try XCTUnwrap(rig.cascade.member("sim"))
        XCTAssertEqual(member.role, .started)
        XCTAssertEqual(member.state, .recording)
        XCTAssertEqual(member.recordingID, ack.recordingID)
        XCTAssertNotNil(member.recordingID)
        try await waitUntil("its audio goes into the shared recording") { rig.session.liveCaptureConversation == conversation }
        XCTAssertEqual(rig.cascade.sharedConversation(of: rig.session), conversation)
        XCTAssertEqual(rig.cascade.pendingConversation(conversation)?.title, "Design review")
        try await Task.sleep(for: .milliseconds(300))

        await rig.cascade.stop()
        XCTAssertNil(rig.cascade.conversation)
        XCTAssertFalse(rig.device.isRecording, "paused with the shared recording")
        let live = try XCTUnwrap(rig.imports.all.first)
        XCTAssertEqual(live.identity.recordingID, DeviceLibraryLinks.partialID(member.recordingID!), "its live audio")
        XCTAssertEqual(live.attachTo, conversation)
        try await waitUntil("its own file follows into the conversation", timeout: 5) { rig.imports.all.count == 2 }
        XCTAssertEqual(rig.imports.all[1].identity.recordingID, member.recordingID)
        XCTAssertEqual(rig.imports.all[1].attachTo, conversation)

        // Asked again for a conversation that ended (a late ask): it isn't started again.
        let late = await RecorderRemoteControl.answer(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                        recorder: request.recorder), target: request.recorder!,
                                                      sessions: [rig.session], cascade: rig.cascade)
        guard case .refused = late else { return XCTFail("a conversation that ended isn't started again: \(late)") }
        XCTAssertEqual(rig.device.received.filter { $0.type == 0x18 && $0.command == 0x82 }.count, 2, "Start and Pause only")
        XCTAssertFalse(rig.device.isRecording)
    }

    func testOneSharedRecordingAtATimeAndAStopForAnotherEndsNothing() async throws {
        let rig = try await rig()
        let first = UUID(), second = UUID()
        XCTAssertTrue(rig.cascade.begin(first))
        XCTAssertFalse(rig.cascade.begin(second), "another isn't begun over it")
        let none = await rig.cascade.start(rig.session, for: second)
        XCTAssertNil(none, "nor are recorders started for it")
        await rig.cascade.stop(second)
        XCTAssertEqual(rig.cascade.conversation?.id, first, "a stop for another conversation ends nothing")
        await rig.cascade.stop(first)
        XCTAssertTrue(rig.cascade.begin(second))
        XCTAssertFalse(rig.device.received.contains { $0.type == 0x18 && $0.command == 0x82 })
    }

    func testARecorderAlreadyRecordingRecordsAlongAndIsLeftRunning() async throws {
        let rig = try await rig(recording: true)
        let conversation = UUID()
        rig.cascade.begin(conversation)
        await rig.cascade.startRecorders()
        let member = try XCTUnwrap(rig.cascade.member("sim"))
        XCTAssertEqual(member.role, .alreadyRecording)
        XCTAssertFalse(member.stopsWithConversation)
        try await waitUntil("its audio is saved as it records") { rig.session.liveCaptureConversation == conversation }
        try await waitUntil("some has arrived") { rig.connection.live.receivedSeconds > 0 || rig.device.bytesSent > 4_000 }
        await rig.cascade.stop()
        XCTAssertTrue(rig.device.isRecording, "Daybook didn't start it, so it doesn't stop it")
        XCTAssertFalse(rig.device.received.contains { $0.type == 0x18 && $0.command == 0x82 }, "no Start or Pause")
        XCTAssertEqual(rig.imports.all.first?.attachTo, conversation, "what it recorded meanwhile is in the conversation")
    }

    func testTheRecorderWhoseButtonLedStopsWithTheSharedRecordingAndOneWithRecordAlongOffIsLeftOut() async throws {
        let rig = try await rig()
        var presses: [Bool] = []
        rig.session.onRecorderButton = { _, on in presses.append(on) }
        rig.connection.connect()
        try await waitUntil("connected") { rig.connection.isInventoryCurrent }
        rig.device.pressButton()
        try await waitUntil("the press") { presses == [true] }
        let conversation = UUID()
        rig.cascade.begin(conversation)
        _ = await rig.cascade.start(rig.session, for: conversation, role: .led)
        XCTAssertEqual(rig.cascade.member("sim")?.role, .led)
        await rig.cascade.startRecorders()
        XCTAssertEqual(rig.device.received.filter { $0.type == 0x18 && $0.command == 0x82 }.count, 0, "the button started it")
        try await waitUntil("its audio") { rig.session.liveCaptureConversation == conversation }
        await rig.cascade.stop()
        XCTAssertFalse(rig.device.isRecording, "it led this conversation, so it stops with it")

        let off = try await self.rig(recordsAlong: false)
        XCTAssertTrue(off.cascade.eligible().isEmpty, "Record along off: it isn't started")
    }

    func testTheButtonStoppingARecorderKeepsItsAudioAndImportsItsFile() async throws {
        let rig = try await rig()
        let conversation = UUID()
        rig.cascade.begin(conversation)
        await rig.cascade.startRecorders()
        try await waitUntil("its audio") { rig.session.liveCaptureConversation == conversation }
        try await Task.sleep(for: .milliseconds(300))
        rig.device.pressButton()
        try await waitUntil("the recorder stopped") { rig.connection.status?.isRecording == false }
        let stopped = await rig.cascade.recorderStopped(rig.session)
        XCTAssertTrue(stopped)
        XCTAssertEqual(rig.cascade.member("sim")?.state, .stopped)
        XCTAssertFalse(rig.cascade.hasRecordingMembers)
        try await waitUntil("its live audio and its file are in the conversation", timeout: 5) {
            rig.imports.all.count == 2 && rig.imports.all.allSatisfy { $0.attachTo == conversation }
        }
    }

    // MARK: Notes and bookmarks

    func testChangesAreSharedOnceAndWhatArrivedIsNeverSentBack() {
        let tracker = SharedNotesTracker()
        let before = TimedNote(time: 1, text: "Before the recording")
        XCTAssertTrue(tracker.notesChanged([before]).isEmpty, "nothing before it begins")
        let conversation = UUID()
        tracker.begin(conversation, notes: [before], bookmarks: [])
        XCTAssertTrue(tracker.notesChanged([before]).isEmpty, "what was there isn't sent")

        let mine = TimedNote(time: 10, text: "Mine")
        XCTAssertEqual(tracker.notesChanged([before, mine]).map(\.id), [mine.id])
        XCTAssertTrue(tracker.notesChanged([before, mine]).isEmpty, "once")

        // One arrives: applied, and not sent back.
        let theirs = SharedNote(id: UUID(), text: "Theirs", time: 20)
        XCTAssertTrue(tracker.received(theirs, changedAt: Date()))
        XCTAssertTrue(tracker.notesChanged([before, mine, TimedNote(id: theirs.id, time: 20, text: "Theirs")]).isEmpty)
        // An older change of it arriving late is dropped; editing it here is sent.
        XCTAssertFalse(tracker.received(SharedNote(id: theirs.id, text: "Stale", time: 20), changedAt: Date().addingTimeInterval(-60)))
        let edited = tracker.notesChanged([before, mine, TimedNote(id: theirs.id, time: 20, text: "Theirs, edited here")])
        XCTAssertEqual(edited, [SharedNote(id: theirs.id, text: "Theirs, edited here", time: 20)])
        // Deleting mine is sent as a delete.
        XCTAssertEqual(tracker.notesChanged([before, TimedNote(id: theirs.id, time: 20, text: "Theirs, edited here")]).map(\.deleted), [true])

        // Bookmarks: made here, changed, deleted; one that arrived isn't sent back; one on a track isn't sent.
        let mark = Highlight(time: 5)
        let onTrack = Highlight(trackID: UUID(), time: 8)
        XCTAssertEqual(tracker.bookmarksChanged([mark, onTrack]).made, [mark])
        var labelled = mark
        labelled.text = "Decision"
        XCTAssertEqual(tracker.bookmarksChanged([labelled, onTrack]).changed, [labelled])
        let arrived = Highlight(time: 9)
        XCTAssertTrue(tracker.received(bookmark: arrived, at: Date()))
        XCTAssertFalse(tracker.received(bookmark: arrived, at: Date()), "once")
        let next = tracker.bookmarksChanged([labelled, onTrack, arrived])
        XCTAssertTrue(next.made.isEmpty && next.changed.isEmpty && next.deleted.isEmpty)
        XCTAssertEqual(tracker.bookmarksChanged([onTrack, arrived]).deleted, [labelled.id])

        // An editor writing its text back a moment after a paragraph arrived, without it, hadn't shown
        // it: it's put back, not deleted. A moment later, leaving it out is a delete.
        let arriving = SharedNote(id: UUID(), text: "Just arrived", time: 30)
        let now = Date()
        XCTAssertTrue(tracker.received(arriving, changedAt: now))
        let anchors = [before, TimedNote(id: arriving.id, time: 30, text: "Just arrived")]
        XCTAssertEqual(tracker.keepingArrivals("Before the recording\nTyping", anchors: anchors, at: now),
                       "Before the recording\nTyping\nJust arrived")
        XCTAssertEqual(tracker.keepingArrivals("Before the recording\nJust arrived", anchors: anchors, at: now),
                       "Before the recording\nJust arrived", "already there")
        XCTAssertEqual(tracker.keepingArrivals("Before the recording", anchors: anchors, at: now.addingTimeInterval(2)),
                       "Before the recording", "deleted by the person, later")

        tracker.end()
        XCTAssertFalse(tracker.isActive)
        XCTAssertTrue(tracker.notesChanged([TimedNote(text: "After")]).isEmpty)
    }
}
