import DaybookCaptions
import DaybookCore
@testable import DaybookDevices
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Recording across devices from this Mac's side (docs/multipoint.md, "Starting anywhere"): a start
/// anywhere starts every connected device once, a stop anywhere stops the rest, and notes and bookmarks
/// made on either device appear on the other at once and end up once in the conversation. A loopback
/// link stands in for the phone; nothing records or downloads.
@MainActor
final class CascadingRecordingTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: true)
        addTeardownBlock { await rig.state.phoneLink.shutDown(); await rig.tearDown() }
        return rig
    }

    private func connect(_ rig: MultiSourceRig, features: [String] = [LinkCapabilities.cascadeFeature, LinkCapabilities.sharedNotesFeature])
        async throws -> PhoneLinkRig {
        let phone = try await PhoneLinkRig.connect(rig.state, features: features)
        rig.state.microphoneAccess = { .authorized }
        rig.state.phoneCapture = PhoneCapture(start: { id in _ = self.macStartsRecording(rig, into: id); return true },
                                              stop: { id in self.macStopsRecording(rig, id) })
        return phone
    }

    /// What `startRecording` does once capture runs (no microphone).
    @discardableResult
    private func macStartsRecording(_ rig: MultiSourceRig, into existing: UUID? = nil) -> UUID {
        let id = existing ?? rig.state.newMeeting(title: "Design review")
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
        rig.state.phoneLeads[id] = nil
    }

    private func phoneStarts(_ phone: PhoneLinkRig, recordsItself: Bool = true, trigger: LinkCascade.Trigger = .person) async throws
        -> (UUID, LinkRecordReply.Outcome) {
        let conversation = UUID()
        let reply = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                     timing: LinkTiming(startedAt: Date(), elapsed: 0), title: "Walk with Priya",
                                                                     date: Date(), cascade: LinkCascade(trigger: trigger, requesterRecords: recordsItself)),
                                                   from: phone.macID)
        return (conversation, reply.outcome)
    }

    // MARK: Starting anywhere

    func testTheMacsStartAsksTheConnectedPhoneOnItsOwn() async throws {
        let rig = try await rig()
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(rig.state) } }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let start = try XCTUnwrap(phone.recorder.requests.first)
        XCTAssertEqual(start.conversationID, id)
        XCTAssertEqual(start.cascade?.trigger, .person, "a cascading start")
        XCTAssertEqual(start.cascade?.requesterRecords, true)
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .recording)
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
    }

    func testAPhonesStartJoinsThisMacUnlessRecordAlongIsOffAndNeverComesBack() async throws {
        let rig = try await rig()
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(rig.state) } }
        let (conversation, outcome) = try await phoneStarts(phone)
        guard case .accepted = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(rig.state.recordingID, conversation)
        await rig.state.sources.recorders.settle()
        XCTAssertTrue(phone.recorder.requests.isEmpty, "the phone that asked isn't asked back: no loop")
        // Asked again for the same conversation (another way, or a repeat): already recording it.
        let again = try await phone.client.request(
            LinkRecordRequest(action: .start, conversationID: conversation, timing: LinkTiming(startedAt: Date()),
                              cascade: LinkCascade(trigger: .recorder)), from: phone.macID)
        guard case .accepted(let ack) = again.outcome else { return XCTFail() }
        XCTAssertTrue(ack.wasAlreadyRecording, "each device records a conversation once")
        _ = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: phone.macID)
        XCTAssertNil(rig.state.recordingID)

        // "Record along with Pocket iPhone" off on this Mac: its cascading starts are declined, while a
        // start the person chose on the phone for this Mac still records.
        rig.state.devices.session(phone.phoneID.uuidString)?.update { $0.alsoRecordsWithMac = false }
        let (_, declined) = try await phoneStarts(phone)
        XCTAssertEqual(declined, .refused(LinkRecordRefusal(reason: .declined,
                                                            message: "Recording along with \(PhoneLinkRig.phoneName) is turned off on this Mac.")))
        XCTAssertNil(rig.state.recordingID)
        let chosen = UUID()
        let reply = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: chosen,
                                                                     timing: LinkTiming(startedAt: Date())), from: phone.macID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        XCTAssertEqual(rig.state.recordingID, chosen)
        _ = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: chosen), from: phone.macID)
    }

    // MARK: Stopping anywhere

    func testStoppingTheMacStopsThePhoneThatLedButNotTheOneWhoseStopItWas() async throws {
        let rig = try await rig()
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(rig.state) } }

        // The person stops this Mac: the phone that led stops too.
        let (first, _) = try await phoneStarts(phone)
        macStopsRecording(rig, first)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.stop])
        XCTAssertEqual(phone.recorder.requests.last?.conversationID, first)
        XCTAssertEqual(rig.meeting(first)?.companions?.first?.state, .stopped)

        // The phone stops it: it isn't asked to stop in turn.
        let (second, _) = try await phoneStarts(phone)
        _ = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: second), from: phone.macID)
        await rig.state.sources.recorders.settle()
        XCTAssertNil(rig.state.recordingID)
        XCTAssertEqual(phone.recorder.requests.count, 1, "nothing more sent")
        XCTAssertEqual(rig.meeting(second)?.companions?.first?.state, .stopped)
    }

    func testAPhoneRecordingAlongWithTheMacCanStopItAndIsntAskedBack() async throws {
        let rig = try await rig()
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(rig.state) } }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .recording)
        let stop = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: id), from: phone.macID)
        guard case .accepted = stop.outcome else { return XCTFail("a phone recording along may stop it: \(stop.outcome)") }
        XCTAssertNil(rig.state.recordingID)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start], "the phone that stopped it isn't asked to stop")
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
    }

    func testAPhoneRecordingOnlyThroughItsRecorderIsFollowedAndStoppedOwedUntilItReconnects() async throws {
        let rig = try await rig()
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(rig.state) } }
        let (conversation, outcome) = try await phoneStarts(phone, recordsItself: false, trigger: .recorder)
        guard case .accepted = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(rig.state.recordingID, conversation)
        XCTAssertNil(rig.meeting(conversation)?.companions, "no recording of the phone's own is expected")

        // Its microphone is idle, but its recorder records the conversation: this Mac keeps recording.
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .idle, sharedConversationID: conversation)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.state.recordingID, conversation)

        // This Mac stops while the phone is away: the stop is owed, and goes when it's back.
        await phone.client.disconnect(from: phone.macID)
        try await waitUntil("the phone is gone") { rig.state.phoneLink.peers[phone.phoneID] == nil }
        macStopsRecording(rig, conversation)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.state.sources.recorders.pendingStops[phone.phoneID.uuidString]?.first?.lead, true)
        try await phone.client.connect(to: phone.macID, via: phone.endpoint)
        try await waitUntil("the owed stop arrives") { phone.recorder.requests.contains { $0.action == .stop && $0.conversationID == conversation } }
        try await waitUntil("and is no longer owed") { rig.state.sources.recorders.pendingStops[phone.phoneID.uuidString] == nil }

        // It stops with nothing more to record: this Mac follows.
        let (next, _) = try await phoneStarts(phone, recordsItself: false, trigger: .recorder)
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .idle)))
        try await waitUntil("this Mac stops too") { rig.state.recordingID == nil }
        XCTAssertEqual(rig.state.notice, "\(PhoneLinkRig.phoneName) stopped recording, so this Mac stopped too.")
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(phone.recorder.requests.contains { $0.action == .stop && $0.conversationID == next }, "it stopped first")
    }

    // MARK: Notes and bookmarks

    func testNotesAndBookmarksAppearOnTheOtherDeviceAndEndUpOnceAfterSync() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let phone = try await connect(rig)
        defer { Task { await phone.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: phone.phoneID)
        defer { library.tearDown() }
        let recordingID = UUID()
        phone.recorder.answer = { request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: recordingID.uuidString))
        }
        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()

        // Written in Floating Notes: on the phone at once, with its ID and time.
        state.editNotes(id, text: "Agenda: launch")
        let macNote = try await waitFor("the Mac's paragraph") { phone.notes.first }
        XCTAssertEqual(macNote.text, "Agenda: launch")
        XCTAssertEqual(macNote.conversationID, id)
        let anchor = try XCTUnwrap(rig.meeting(id)?.timedNotes?.first)
        XCTAssertEqual(macNote.id, anchor.id)
        XCTAssertEqual(macNote.time, anchor.time)
        state.addHighlight(id)
        let macMark = try await waitFor("the Mac's bookmark") { phone.bookmarks.first }
        XCTAssertEqual(macMark.id, rig.meeting(id)?.highlights.first?.id)

        // Written on the phone: here at once, and never sent back.
        let phoneNote = LinkNote(id: UUID(), conversationID: id, text: "Phone: Priya owns the checklist", time: 12, madeAt: Date(), changedAt: Date())
        try await phone.client.send(.note(phoneNote))
        try await waitUntil("the phone's paragraph") { rig.meeting(id)?.notes.contains("Priya owns the checklist") == true }
        XCTAssertEqual(rig.meeting(id)?.timedNotes?.first { $0.id == phoneNote.id }?.time, 12, "as the phone files it")
        // The phone edits the Mac's bookmark, then deletes it; and edits its own paragraph.
        try await phone.client.send(.bookmarkChange(LinkBookmarkChange(id: macMark.id, conversationID: id, label: "Decision")))
        try await waitUntil("the label") { rig.meeting(id)?.highlights.first?.text == "Decision" }
        try await phone.client.send(.note(LinkNote(id: phoneNote.id, conversationID: id, text: "Phone: Priya and Sam own the checklist", time: 12,
                                                   madeAt: phoneNote.madeAt, changedAt: Date())))
        try await waitUntil("the edit") { rig.meeting(id)?.notes.contains("Priya and Sam own") == true }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(phone.notes.contains { $0.id == phoneNote.id }, "what arrived isn't sent back")
        XCTAssertEqual(phone.notes.count, 1)
        XCTAssertEqual(rig.meeting(id)?.notes.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)

        // Later, the libraries sync: the phone files its recording with its own paragraph (held by its
        // recording) and the Mac's (as the Mac files it), and its copy of the bookmark.
        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, id, audio: try rig.audio("mac-notes.wav", frequency: 330), start: macStart)
        await state.synchronizeLibrary()
        await library.synchronize()
        let mine = TimedNote(id: phoneNote.id, time: 12, text: "Phone: Priya and Sam own the checklist")
        try await library.file(try rig.audio("iphone-notes.wav", frequency: 490), recordingID: recordingID, into: id, start: Date(),
                               duration: 0.5, notes: [mine])
        library.library.update(id) { meeting in
            meeting.applySharedNote(SharedNote(id: macNote.id, text: macNote.text, time: macNote.time))
            meeting.addSharedBookmark(Highlight(id: macMark.id, time: macMark.recordingTime, text: "Decision"))
        }
        await library.library.flush()
        await library.synchronize()
        await state.synchronizeLibrary()
        let merged = try XCTUnwrap(rig.meeting(id))
        let paragraphs = merged.notes.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(paragraphs.sorted(), ["Agenda: launch", "Phone: Priya and Sam own the checklist"], "each paragraph once")
        XCTAssertEqual(Set(merged.timedNotes?.map(\.id) ?? []), [macNote.id, phoneNote.id])
        XCTAssertEqual(merged.highlights.filter { $0.id == macMark.id }.count, 1, "one bookmark")
        await library.synchronize()
        XCTAssertEqual(library.library.meeting(id)?.notes.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }

    // MARK: A recorder this Mac manages

    /// A Soundcore Work this Mac manages, against the simulated recorder that records in real time.
    private func soundcore(_ rig: MultiSourceRig) throws -> (DeviceSession, SimulatedSoundcore) {
        let device = SimulatedSoundcore(recordings: [])
        device.recordsInRealTime = true
        device.pace = .milliseconds(15)
        let transport = SimulatedSoundcoreTransport(device: device)
        let staging = try temporaryFolder("Staging")
        var environment = DeviceEnvironment(defaults: rig.defaults, stagingDirectory: staging)
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
        let configured = ConfiguredDevice(id: "soundcore", kind: SoundcoreWorkIntegration().kind)
        var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: device.name, serial: device.serial)
        snapshot.lastConnectedAt = Date()
        environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
        let connection = SoundcoreConnection(device: configured, environment: environment)
        connection.importsAutomatically = false
        let session = DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind, connections: [connection], defaults: rig.defaults)
        session.importer = { url, identity, attachTo, source in
            try await rig.state.importFromDevice(url, identity: identity, attachTo: attachTo, source: source)
        }
        session.onRecorderButton = { session, on in rig.state.recorderButton(session, on) }
        session.activate()
        session.libraryChanged(rig.state.meetings, ready: true)
        rig.state.sources.recorders.sessions = { [session] }
        rig.state.library.$meetings.sink { session.libraryChanged($0, ready: true) }.store(in: &rig.state.subscriptions)
        addTeardownBlock { session.shutDown() }
        return (session, device)
    }

    func testARecorderStartedWithThisMacSavesItsAudioIntoTheConversationAndItsFileReplacesIt() async throws {
        let rig = try await rig()
        let (session, device) = try soundcore(rig)
        let id = macStartsRecording(rig)
        try await waitUntil("the recorder records along, its audio saved here as it records", timeout: 5) {
            session.liveCaptureConversation == id
        }
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .recording)
        try await Task.sleep(for: .milliseconds(400))

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(device.isRecording, "paused with this Mac")
        let recordingID = try XCTUnwrap(rig.meeting(id)?.companions?.first?.recordingID)
        try await waitUntil("its live audio, then its own file, in the conversation", timeout: 10) {
            rig.meeting(id)?.tracks.contains { $0.deviceRecordingID == recordingID } == true
        }
        let meeting = try XCTUnwrap(rig.meeting(id))
        let portion = try XCTUnwrap(meeting.tracks.first { $0.isLivePortion }, "the audio was here the moment it stopped")
        let whole = try XCTUnwrap(meeting.tracks.first { $0.deviceRecordingID == recordingID })
        XCTAssertEqual(meeting.supersededLivePortions, [portion.id: whole.id], "the recorder's file is authoritative")
        XCTAssertFalse(meeting.transcribableTracks.contains { $0.id == portion.id })
        XCTAssertEqual(rig.state.meetings.count, 1, "never a conversation of its own")
    }

    func testTheRecordersButtonStartsAndStopsThisMac() async throws {
        let rig = try await rig()
        rig.state.microphoneAccess = { .authorized }
        rig.state.phoneCapture = PhoneCapture(start: { id in _ = self.macStartsRecording(rig, into: id); return true },
                                              stop: { id in self.macStopsRecording(rig, id) })
        let (session, device) = try soundcore(rig)
        session.direct?.connect()
        try await waitUntil("connected") { session.direct?.isInventoryCurrent == true }

        device.pressButton()
        let id = try await waitFor("this Mac records too") { rig.state.recordingID }
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .alreadyRecording, "its button started it")
        XCTAssertFalse(device.received.contains { $0.type == 0x18 && $0.command == 0x82 }, "Daybook sent no Start")
        try await waitUntil("its audio is saved here as it records") { session.liveCaptureConversation == id }
        try await Task.sleep(for: .milliseconds(300))

        // Stopped here: the recorder whose button began it stops too.
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertFalse(device.isRecording)

        // And its button stops this Mac.
        device.pressButton()
        let next = try await waitFor("recording again") { rig.state.recordingID }
        try await waitUntil("its audio") { session.liveCaptureConversation == next }
        device.pressButton()
        try await waitUntil("its button stops this Mac") { rig.state.recordingID == nil }
        XCTAssertEqual(rig.state.notice, "\(session.device.name) stopped recording, so this Mac stopped too.")
        await rig.state.sources.recorders.settle()
    }

    /// This Mac's own recording of `id`, stored as capture stores it.
    private func storeMacRecording(_ rig: MultiSourceRig, _ id: UUID, audio: URL, start: Date) async throws {
        let installed = rig.state.installedModels
        rig.state.installedModels = []
        try await rig.state.importFiles([audio], source: .microphone, attachTo: id)
        rig.state.installedModels = installed
        rig.state.awaitingModels.remove(id)
        rig.state.update(id) { meeting in
            meeting.tracks[0].offset = 0
            meeting.tracks[0].createdAt = start
            meeting.tracks[0].duration = 0.5
            meeting.status = .imported
        }
        await rig.state.flush()
    }
}

private extension PhoneLinkRig {
    /// The notes and bookmarks the Mac sent the phone, in order.
    var notes: [LinkNote] {
        events.all.compactMap { if case .received(.note(let note), _) = $0 { return note } else { return nil } }
    }
    var bookmarks: [LinkBookmark] {
        events.all.compactMap { if case .received(.bookmark(let mark), _) = $0 { return mark } else { return nil } }
    }
}
