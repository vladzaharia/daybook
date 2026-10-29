import DaybookCore
@testable import DaybookKit
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import Daybook

/// Daybook on iPhone as a device of this Mac, over loopback: pairing as the sheet shows it, record
/// control in both directions with the clock prior, live progress, nudges, and the phone's synced
/// recording joining this Mac's conversation through multipoint matching.
@MainActor
final class PhoneLinkTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(in: self, models: true)
        addTeardownBlock { await rig.state.phoneLink.shutDown(); await rig.tearDown() }
        return rig
    }

    /// What `startRecording` does once this Mac's capture is running (no microphone).
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

    /// This Mac's own recording of `id`, stored as capture stores it: its microphone, at `start`.
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

    // MARK: Pairing

    func testPairingShowsTheCodeThenThePairedPhoneThenUnpairs() async throws {
        let rig = try await rig()
        let state = rig.state
        PhoneLinkRig.useLoopback(state, keyStore: MemoryLinkKeyStore())
        XCTAssertFalse(state.phoneLink.isRunning, "A Mac nobody pairs with doesn't listen")

        await state.phoneLink.beginPairing()
        guard case .showing(let first) = state.phoneLink.pairing else { return XCTFail("Shows a code") }
        XCTAssertTrue(state.phoneLink.isRunning)
        let listening = await state.phoneLink.port
        let port = try XCTUnwrap(listening)
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        let phoneID = UUID()
        let client = LinkClient(identity: LinkIdentity(deviceID: phoneID, name: PhoneLinkRig.phoneName, deviceClass: .iPhone, appVersion: "2.0"),
                                keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        let events = LinkEvents(client.events())

        // A wrong code: the sheet says so and shows a new code.
        let wrong = String(first.digits.dropLast()) + (first.digits.last == "0" ? "1" : "0")
        do { _ = try await client.pair(with: endpoint, code: wrong); XCTFail("A wrong code can't pair") }
        catch let error as LinkPairingError { XCTAssertEqual(error, .codeRejected) }
        try await waitUntil("a new code") { if case .showing(let code) = state.phoneLink.pairing { return code != first }; return false }
        XCTAssertNotNil(state.phoneLink.pairingProblem)
        guard case .showing(let second) = state.phoneLink.pairing else { return XCTFail() }

        // The right one: the sheet shows the phone, which joins Devices.
        let mac = try await client.pair(with: endpoint, code: second.digits)
        XCTAssertEqual(mac.deviceID, state.phoneLink.identity.deviceID)
        try await waitUntil("the paired phone") { if case .paired = state.phoneLink.pairing { return true }; return false }
        guard case .paired(let phone) = state.phoneLink.pairing else { return XCTFail() }
        XCTAssertEqual(phone.deviceID, phoneID)
        XCTAssertEqual(phone.name, PhoneLinkRig.phoneName)
        XCTAssertNil(state.phoneLink.pairingProblem)
        XCTAssertEqual(state.phoneLink.paired.map(\.deviceID), [phoneID])
        let session = try XCTUnwrap(state.devices.session(phoneID.uuidString), "Paired phones appear under Devices")
        XCTAssertEqual(session.kind.id, DaybookPhoneIntegration.id)
        XCTAssertEqual(session.device.name, PhoneLinkRig.phoneName)
        XCTAssertEqual(session.direct?.isSetUp, true)
        XCTAssertFalse(session.isLinked)

        // Connected, the device is linked; closing the sheet keeps the link for the paired phone.
        try await client.connect(to: mac.deviceID, via: endpoint)
        try await waitUntil("the phone to connect") { session.isLinked }
        XCTAssertEqual(session.direct?.state, .connected)
        await state.phoneLink.endPairing()
        XCTAssertEqual(state.phoneLink.pairing, .closed)
        XCTAssertTrue(state.phoneLink.isRunning, "A paired phone keeps the link running")

        // Unpair: the phone hears it, the device leaves Devices, and with no phone the link stops.
        state.unpairPhone(phoneID)
        try await waitUntil("the unpairing") { state.devices.session(phoneID.uuidString) == nil && state.phoneLink.paired.isEmpty }
        try await waitUntil("the phone to hear it") { events.unpaired }
        try await waitUntil("the link to stop") { !state.phoneLink.isRunning }
        await client.disconnect(from: mac.deviceID)
    }

    // MARK: Record control

    func testTheMacAsksAConnectedPhoneToRecordAlongAndStop() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state, clockOffset: 2.5)
        defer { Task { await phone.tearDown(rig.state) } }

        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.deviceKind, DaybookPhoneIntegration.id)
        XCTAssertEqual(link.deviceID, phone.phoneID.uuidString)
        XCTAssertEqual(link.state, .recording)
        XCTAssertTrue(link.startedByDaybook)
        XCTAssertEqual(link.recordingID, "R-\(id)", "The phone's recording ID links its recording")
        XCTAssertNotNil(link.recorderStartedAt)
        let clock = try XCTUnwrap(link.clock, "The link's clock samples are stored as the timing prior")
        XCTAssertEqual(clock.offset, 2.5, accuracy: 0.05)
        XCTAssertLessThan(clock.uncertainty, 0.05)
        XCTAssertEqual(rig.state.sources.recorders.status, "Also recording on \(PhoneLinkRig.phoneName).")
        let start = try XCTUnwrap(phone.recorder.requests.first)
        XCTAssertEqual(start.action, .start)
        XCTAssertEqual(start.conversationID, id)
        XCTAssertEqual(start.title, "Design review")
        XCTAssertEqual(start.timing?.timelineStart?.timeIntervalSince1970 ?? 0, start.timing?.startedAt?.timeIntervalSince1970 ?? 1, accuracy: 0.001,
                       "a new conversation's timeline begins with this Mac's recording")
        XCTAssertEqual(start.timing?.clockOffset ?? 0, 2.5, accuracy: 0.05, "The Mac's prior travels with the request")

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start, .stop])
        XCTAssertEqual(phone.recorder.requests.last?.conversationID, id)
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
        XCTAssertEqual(rig.state.sources.recorders.status, "\(PhoneLinkRig.phoneName) stopped. Its recording will be added here.")

        // "Also record on <iPhone>" off: the phone isn't asked.
        rig.state.devices.session(phone.phoneID.uuidString)?.update { $0.alsoRecordsWithMac = false }
        let other = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertNil(rig.meeting(other)?.companions)
        XCTAssertEqual(phone.recorder.requests.count, 2)
        macStopsRecording(rig, other)
    }

    func testTheMacTellsPhonesWhatItRecordsAsItChangesWhileItRecordsAndAsTheyConnect() async throws {
        let rig = try await rig()
        rig.state.phoneLink.recordingStateInterval = .milliseconds(150)
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        try await waitUntil("the state as the phone connects") { phone.events.states.first?.phase == .idle }

        let id = macStartsRecording(rig)
        try await waitUntil("recording") { phone.events.states.contains { $0.phase == .recording && $0.conversationID == id } }
        let started = try XCTUnwrap(phone.events.states.first { $0.phase == .recording })
        XCTAssertEqual(started.startedAt?.timeIntervalSince1970 ?? 0, rig.state.recordingStartedAt?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        // Repeated while it records, so the phone can tell it's still at it.
        try await waitUntil("the state again") { phone.events.states.filter { $0.phase == .recording }.count >= 3 }

        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        try await waitUntil("idle") { phone.events.states.last?.phase == .idle }
        let count = phone.events.states.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(phone.events.states.count, count, "nothing more while idle")
    }

    func testTheRecordersEachSideManagesTravelWithItsState() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        // A recorder this Mac manages, recording along with this Mac's recording.
        let recorder = FakeRecorder()
        let session = DeviceSession(device: ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind),
                                    kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: rig.defaults)
        addTeardownBlock { session.shutDown() }
        let phoneSession = try XCTUnwrap(rig.state.devices.session(phone.phoneID.uuidString))
        rig.state.sources.recorders.sessions = { [session, phoneSession] }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        try await waitUntil("the recorder in this Mac's state") {
            phone.events.states.last?.recorders?.first?.isRecording == true
        }
        let sent = try XCTUnwrap(phone.events.states.last?.recorders)
        XCTAssertEqual(sent.count, 1, "only recorders this Mac manages, not the phone itself")
        XCTAssertEqual(sent.first?.kind, SoundcoreWorkIntegration.id)
        XCTAssertEqual(sent.first?.serial, "FAKE1")
        XCTAssertEqual(sent.first?.name, "Soundcore Work")
        XCTAssertEqual(sent.first?.recordingID, rig.meeting(id)?.companions?.first?.recordingID)
        XCTAssertEqual(sent.first?.conversationID, id)
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()

        // The phone's recorders, on this Mac's iPhone page, with their age; unknown after 20 minutes.
        let started = Date().addingTimeInterval(-300)
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .idle, recorders: [
            LinkRecorderState(kind: SoundcoreWorkIntegration.id, serial: "S2", name: "Soundcore Work", isRecording: true, recordingID: "1", startedAt: started,
                              asOf: Date().addingTimeInterval(-120))])))
        let control = try XCTUnwrap(phoneSession.direct as? PhoneLinkConnection)
        try await waitUntil("the phone's recorders") { !control.recorders().isEmpty }
        let shown = try XCTUnwrap(control.recorders().first)
        XCTAssertEqual(shown.summary(), "Recording since \(started.formatted(date: .omitted, time: .shortened)), as of \(Date().addingTimeInterval(-120).formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(control.recorders(now: Date().addingTimeInterval(17 * 60)).count, 1)
        XCTAssertTrue(control.recorders(now: Date().addingTimeInterval(19 * 60)).isEmpty, "too old to say: 20 minutes past its as-of")
        // Still known after the phone disconnects, for as long as it can be trusted.
        await phone.client.disconnect(from: phone.macID)
        try await waitUntil("disconnected") { rig.state.phoneLink.peers[phone.phoneID] == nil }
        XCTAssertEqual(control.recorders().count, 1)
    }

    func testRecordingIntoAnEarlierConversationTellsThePhoneWhereItsTimelineBegan() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        // A conversation recorded ten minutes ago; this Mac records into it again (Record on This Mac).
        let earlier = Date().addingTimeInterval(-600)
        let id = try await rig.macConversation("Standup", at: earlier, seconds: 0.5, audio: try rig.audio("earlier.wav", frequency: 350))
        _ = macStartsRecording(rig, into: id)
        let macStart = try XCTUnwrap(rig.state.recordingStartedAt)
        await rig.state.sources.recorders.settle()
        let request = try XCTUnwrap(phone.recorder.requests.first)
        XCTAssertEqual(request.title, "Standup", "the conversation as this Mac has it")
        XCTAssertEqual(request.date?.timeIntervalSince1970 ?? 0, rig.meeting(id)?.date.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertEqual(request.timing?.startedAt?.timeIntervalSince1970 ?? 0, macStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(request.timing?.timelineStart?.timeIntervalSince1970 ?? 0, earlier.timeIntervalSince1970, accuracy: 0.001,
                       "the timeline began with the earlier recording, not this Mac's start")
        XCTAssertEqual(request.timing?.elapsed ?? 0, 600, accuracy: 2, "seconds of that timeline")
        macStopsRecording(rig, id)
    }

    func testTheDevicePagesStartAsksThePhoneForAConversationOfItsOwn() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let control = try XCTUnwrap(rig.state.devices.session(phone.phoneID.uuidString)?.direct as? PhoneLinkConnection)
        control.startRecording()
        try await waitUntil("the request") { !phone.recorder.requests.isEmpty }
        let request = try XCTUnwrap(phone.recorder.requests.first)
        XCTAssertEqual(request.standalone, true)
        XCTAssertTrue(request.isStandalone)
        XCTAssertNil(request.timing, "nothing to line up with: this Mac isn't recording it")
        XCTAssertNil(rig.meeting(request.conversationID), "not a conversation of this Mac's")
    }

    func testAPausedPhoneRecordingIsStillItsRecordingAndCanBeStopped() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let control = try XCTUnwrap(rig.state.devices.session(phone.phoneID.uuidString)?.direct as? PhoneLinkConnection)
        let conversation = UUID()
        // A call interrupted the phone's recording.
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .paused, conversationID: conversation, startedAt: Date())))
        try await waitUntil("its state") { control.recordingPhase == .paused }
        XCTAssertEqual(control.status?.isRecording, true, "paused, it's still recording that conversation")
        XCTAssertEqual(control.recordingConversationID, conversation)
        control.pauseRecording()
        try await waitUntil("Stop on iPhone") { phone.recorder.requests.contains { $0.action == .stop && $0.conversationID == conversation } }
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .idle)))
        try await waitUntil("idle") { control.recordingPhase == nil }
        XCTAssertEqual(control.status?.isRecording, false)
    }

    func testAPhoneThatSaysNoIsReportedQuietly() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        phone.recorder.answer = { _ in .refused(LinkRecordRefusal(reason: .microphoneUnavailable)) }

        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .failed)
        XCTAssertEqual(rig.state.sources.recorders.status,
                       "\(PhoneLinkRig.phoneName) didn’t record. Its microphone isn’t available. Recording on this Mac only.")
        XCTAssertEqual(rig.state.recordingID, id, "The Mac recording carries on")
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start], "It isn't recording, so it isn't stopped")
    }

    func testThePhoneAsksTheMacToRecordIntoItsConversation() async throws {
        let rig = try await rig()
        let state = rig.state
        let phone = try await PhoneLinkRig.connect(state, clockOffset: -1.5)
        defer { Task { await phone.tearDown(state) } }
        state.microphoneAccess = { .authorized }
        state.phoneCapture = PhoneCapture(start: { id in
            _ = self.macStartsRecording(rig, into: id)
            return true
        }, stop: { id in self.macStopsRecording(rig, id) })

        let conversation = UUID()
        let phoneStart = Date().addingTimeInterval(-1.5 - 4)
        let reply = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                     timing: LinkTiming(startedAt: phoneStart, elapsed: 4)), from: phone.macID)
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("The Mac records: \(reply.outcome)") }
        XCTAssertEqual(ack.conversationID, conversation)
        XCTAssertEqual(state.recordingID, conversation, "Into the phone's conversation")
        XCTAssertEqual(ack.startedAt?.timeIntervalSince1970 ?? 0, state.recordingStartedAt?.timeIntervalSince1970 ?? 99, accuracy: 0.001)
        let meeting = try XCTUnwrap(rig.meeting(conversation), "Created here before it has synced")
        let lead = try XCTUnwrap(meeting.companions?.first)
        XCTAssertEqual(lead.deviceKind, DaybookPhoneIntegration.id)
        XCTAssertEqual(lead.state, .alreadyRecording, "The phone leads; this Mac stops it only when this Mac is stopped (CascadingRecordingTests)")
        XCTAssertFalse(lead.startedByDaybook)
        XCTAssertEqual(lead.recorderStartedAt?.timeIntervalSince1970 ?? 0, phoneStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(lead.clock?.offset ?? 0, -1.5, accuracy: 0.05)
        XCTAssertEqual(lead.recorderStartedOnMacClock?.timeIntervalSince(phoneStart.addingTimeInterval(1.5)) ?? 99, 0, accuracy: 0.05)
        XCTAssertTrue(phone.recorder.requests.isEmpty, "The phone that asked isn't asked back")

        // Busy with that conversation: another is refused, with which one.
        let busy = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: phone.macID)
        XCTAssertEqual(busy.outcome, .refused(LinkRecordRefusal(reason: .recordingSomethingElse,
                                                                  message: "This Mac is recording another conversation.", conversationID: conversation)))

        // The phone stops it.
        let stop = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: phone.macID)
        guard case .accepted = stop.outcome else { return XCTFail("Stopped: \(stop.outcome)") }
        XCTAssertNil(state.recordingID)
        let notRecording = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: phone.macID)
        guard case .refused(let refusal) = notRecording.outcome else { return XCTFail() }
        XCTAssertEqual(refusal.reason, .notRecording)

        // Without the microphone, it says why.
        state.microphoneAccess = { .denied }
        let denied = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: phone.macID)
        guard case .refused(let reason) = denied.outcome else { return XCTFail("Refused without the microphone") }
        XCTAssertEqual(reason.reason, .permissionDenied)
        XCTAssertNil(state.recordingID)

        // A recording started on the Mac that the phone doesn't record along with can't be stopped from
        // it (one it records along with can: CascadingRecordingTests).
        state.microphoneAccess = { .authorized }
        state.devices.session(phone.phoneID.uuidString)?.update { $0.alsoRecordsWithMac = false }
        let own = macStartsRecording(rig)
        await state.sources.recorders.settle()
        let declined = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: own), from: phone.macID)
        guard case .refused(let no) = declined.outcome else { return XCTFail() }
        XCTAssertEqual(no.reason, .declined)
        XCTAssertEqual(state.recordingID, own)
        macStopsRecording(rig, own)
        await state.sources.recorders.settle()
    }

    func testAPhoneLedRecordingJoinsWithItsNotesHeldUntilItIsPlaced() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let link = try await PhoneLinkRig.connect(state)
        defer { Task { await link.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { library.tearDown() }
        state.microphoneAccess = { .authorized }
        state.phoneCapture = PhoneCapture(start: { id in _ = self.macStartsRecording(rig, into: id); return true },
                                          stop: { id in self.macStopsRecording(rig, id) })
        // The sound puts the phone's recording 2 s before this Mac's.
        state.sources.alignAudio = { _, _, _, _ in AudioAlignment(offset: -2, rate: 1, confidence: 0.9) }
        let macAudio = try rig.audio("mac-led-by-phone.wav", frequency: 340)
        let phoneAudio = try rig.audio("phone-leads.wav", frequency: 520)
        try rig.inference.script(macAudio, [(0, "Walking over now.")])
        try rig.inference.script(phoneAudio, [(0, "Walking over now.")])

        // The phone records "Walk with Priya" and asks this Mac to record it too.
        let conversation = UUID(), recordingID = UUID()
        let phoneStart = Date().addingTimeInterval(-2).rounded
        let reply = try await link.client.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: phoneStart, elapsed: 2),
                                                                    title: "Walk with Priya", date: phoneStart), from: link.macID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        XCTAssertEqual(rig.meeting(conversation)?.title, "Walk with Priya", "made as the phone files it")
        XCTAssertEqual(rig.meeting(conversation)?.date, phoneStart, "with the phone's date, not this Mac's start")
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        let stop = try await link.client.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: link.macID)
        guard case .accepted = stop.outcome else { return XCTFail("\(stop.outcome)") }
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, conversation, audio: macAudio, start: macStart)
        state.sourcesAfterCapture(conversation, startedAt: macStart, captureID: UUID())
        XCTAssertEqual(rig.meeting(conversation)?.date, phoneStart)
        await state.synchronizeLibrary()
        await library.synchronize()

        // The phone files into this Mac's conversation: a note at 1 s by its own clock (before this Mac
        // started), another at 5 s, and a bookmark at 4 s.
        let early = TimedNote(time: 1, text: "Leaving the office")
        let note = TimedNote(time: 5, text: "Budget agreed")
        let mark = Highlight(time: 4)
        try await library.file(phoneAudio, recordingID: recordingID, into: conversation, start: phoneStart, duration: 0.5,
                               notes: [early, note], bookmarks: [mark])
        let filed = try XCTUnwrap(library.library.meeting(conversation))
        XCTAssertEqual(filed.title, "Walk with Priya")
        XCTAssertEqual(filed.timedNotes?.map(\.time), [1, 5])
        let held = try XCTUnwrap(filed.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id }?.alignment)
        XCTAssertEqual(held.method, .pending)
        XCTAssertEqual(held.heldNoteIDs, [early.id, note.id], "the notes wait with the phone's recording")
        await library.synchronize()
        await state.synchronizeLibrary()

        try await waitUntil("the conversation to be processed with both recordings", timeout: 20) {
            rig.meeting(conversation)?.summary != nil && state.processingID == nil && state.queuedIDs.isEmpty
        }
        let meeting = try XCTUnwrap(rig.meeting(conversation))
        let track = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id })
        XCTAssertEqual(track.alignment?.method, .audio)
        XCTAssertEqual(track.alignment?.offset ?? 99, -2, accuracy: 0.001)
        XCTAssertNil(track.alignment?.heldNoteIDs)
        XCTAssertEqual(meeting.timedNotes?.first { $0.id == note.id }?.time ?? -1, 3, accuracy: 0.001,
                       "the note moved onto the timeline with the phone's recording")
        XCTAssertEqual(meeting.timedNotes?.first { $0.id == early.id }?.time ?? 99, -1, accuracy: 0.001,
                       "a note from before this Mac started keeps its place before the timeline's zero")
        XCTAssertEqual(meeting.paragraphTimes().map { $0.map { ($0 * 1000).rounded() / 1000 } }, [-1, 3])
        XCTAssertEqual(meeting.notes, "Leaving the office\nBudget agreed")
        XCTAssertEqual(meeting.highlights.map(\.id), [mark.id])
        XCTAssertEqual(meeting.highlights.first?.trackID, track.id, "the bookmark follows the phone's recording")
        XCTAssertEqual(meeting.title, "Walk with Priya")
        XCTAssertEqual(meeting.date, phoneStart)
        XCTAssertFalse(meeting.revisions.contains { $0.field.hasPrefix("sync:") }, "no competing title, date, or status")
        XCTAssertEqual(meeting.companions?.first?.state, .attached)
    }

    // MARK: Lost answers, stops, sleep, and crashes

    func testAStartWhoseAnswerIsSlowIsAskedAgainAndStillCountsAsThisMacs() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        // Longer than a request waits (3 s on loopback), as a microphone prompt on the phone can be.
        phone.recorder.delay(.start, by: .milliseconds(3_500))
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording, "asked again with the same request, it got the first answer")
        XCTAssertTrue(link.startedByDaybook, "so this Mac stops it")
        XCTAssertEqual(phone.recorder.requests.count, 1, "the phone heard it once")
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start, .stop])
    }

    func testStoppingBeforeThePhoneAnswersStillStopsIt() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        phone.recorder.delay(.start, by: .seconds(5))
        let id = macStartsRecording(rig)
        try await waitUntil("the phone is asked") { !phone.recorder.requests.isEmpty }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start, .stop], "it never answered, so it may be recording: it's stopped")
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
    }

    func testAPhoneThatSaysItRecordsAfterAnAnswerThisMacCouldntReadIsStopped() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        phone.recorder.answer = { _ in .refused(LinkRecordRefusal(reason: "unknown")) }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .failed)
        // Yet it reports recording this conversation.
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: id, startedAt: Date())))
        let control = try XCTUnwrap(rig.state.devices.session(phone.phoneID.uuidString)?.direct as? PhoneLinkConnection)
        try await waitUntil("its state") { control.recordingConversationID == id }
        phone.recorder.answer = { request in .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date())) }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start, .stop])
    }

    func testAStopThatDidntReachThePhoneGoesWhenItReconnects() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .recording)
        await phone.client.disconnect(from: phone.macID)
        try await waitUntil("the phone is gone") { rig.state.phoneLink.peers[phone.phoneID] == nil }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(rig.state.sources.recorders.status, "Couldn’t reach \(PhoneLinkRig.phoneName) to stop it. It stops when it reconnects.")
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start])

        try await phone.client.connect(to: phone.macID, via: phone.endpoint)
        try await waitUntil("the stop on reconnecting") { phone.recorder.requests.map(\.action) == [.start, .stop] }
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)
        XCTAssertTrue(rig.state.sources.recorders.pendingStops.isEmpty)
    }

    /// A stop owed to a phone that's away is kept across a relaunch of this Mac, and goes when the phone
    /// reconnects to the relaunched Mac.
    func testAStopOwedToAPhoneIsSentAfterThisMacRelaunches() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        await phone.client.disconnect(from: phone.macID)
        try await waitUntil("the phone is gone") { rig.state.phoneLink.peers[phone.phoneID] == nil }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.state.sources.recorders.pendingStops[phone.phoneID.uuidString]?.map(\.meetingID), [id])
        XCTAssertNotNil(rig.defaults.data(forKey: MultiSourceCoordinator.owedStopsKey), "kept in this Mac's preferences")

        // Daybook quits and opens again.
        await rig.state.phoneLink.shutDown()
        await rig.state.flush()
        let relaunched = AppState(libraryURL: rig.root, defaults: rig.defaults)
        // Its link starts as it opens (a phone is paired): on loopback, with the same pairing.
        PhoneLinkRig.useLoopback(relaunched, keyStore: phone.macKeyStore)
        await relaunched.initialize()
        defer { Task { await phone.client.disconnect(from: phone.macID); await relaunched.phoneLink.shutDown() } }
        XCTAssertEqual(relaunched.sources.recorders.pendingStops[phone.phoneID.uuidString]?.map(\.meetingID), [id])
        XCTAssertEqual(relaunched.meetings.first { $0.id == id }?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start])

        try await phone.reconnect(to: relaunched)
        try await waitUntil("the stop on reconnecting") { phone.recorder.requests.map(\.action) == [.start, .stop] }
        await relaunched.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.last?.conversationID, id)
        XCTAssertEqual(relaunched.meetings.first { $0.id == id }?.companions?.first?.state, .stopped)
        XCTAssertTrue(relaunched.sources.recorders.pendingStops.isEmpty)
        XCTAssertNil(rig.defaults.data(forKey: MultiSourceCoordinator.owedStopsKey), "nothing left to keep")
    }

    /// A stop of a recorder a phone manages that doesn't name the recording (its start never said) would
    /// pause whatever the recorder records by then: it's owed until Daybook quits, never kept past it.
    func testOnlyStopsThatNameTheirRecordingAreKeptAcrossRelaunches() throws {
        let defaults = makeTestDefaults("daybook.owedStops")
        let store = OwedStopsStore<CompanionRecorders.PendingStop>(defaults: defaults, key: MultiSourceCoordinator.owedStopsKey)
        let recorders = CompanionRecorders(owed: store)
        let meeting = UUID(), now = Date()
        func stop(_ recorder: LinkRecorderTarget?) -> CompanionRecorders.PendingStop {
            .init(sessionID: "phone", meetingID: meeting, linkID: UUID(), end: now, recorder: recorder, owedAt: now)
        }
        let phone = stop(nil)
        let named = stop(LinkRecorderTarget(kind: SoundcoreWorkIntegration.id, serial: "S1", recordingID: "1729003600"))
        let unnamed = stop(LinkRecorderTarget(kind: SoundcoreWorkIntegration.id, serial: "S1"))
        for owed in [phone, named, unnamed] { recorders.owe(owed) }
        XCTAssertEqual(Set(recorders.pendingStops["phone"]?.map(\.linkID) ?? []), [phone.linkID, named.linkID, unnamed.linkID], "all owed now")
        XCTAssertEqual(Set(store.load().map(\.linkID)), [phone.linkID, named.linkID], "only those kept")
        XCTAssertEqual(Set(CompanionRecorders(owed: store).pendingStops["phone"]?.map(\.linkID) ?? []), [phone.linkID, named.linkID])
    }

    func testAPhoneThatRefusesOrDropsMidStopIsReportedQuietly() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        // It won't stop (the person turned recording with this Mac off, say).
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        phone.recorder.answer = { request in
            request.action == .stop ? .refused(LinkRecordRefusal(reason: .declined))
                : .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "R-\(request.conversationID)"))
        }
        macStopsRecording(rig, id)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopFailed)
        XCTAssertEqual(rig.state.sources.recorders.status, "\(PhoneLinkRig.phoneName) didn’t stop. Stop it on the iPhone.")
        XCTAssertNil(rig.state.recordingID)
        XCTAssertNil(rig.state.errorMessage)

        // The link drops while it's being stopped: the stop goes again when it's back.
        phone.recorder.answer = { request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "R-\(request.conversationID)"))
        }
        let other = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        phone.recorder.delay(.stop, by: .seconds(1))
        macStopsRecording(rig, other)
        try await waitUntil("the stop reaches the phone") { phone.recorder.requests.filter { $0.action == .stop && $0.conversationID == other }.count == 1 }
        await phone.client.disconnect(from: phone.macID)
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(rig.meeting(other)?.companions?.first?.state, .stopFailed)
        phone.recorder.delay(.stop, by: nil)
        try await phone.client.connect(to: phone.macID, via: phone.endpoint)
        try await waitUntil("stopped once it's back") { rig.meeting(other)?.companions?.first?.state == .stopped }
        XCTAssertNil(rig.state.errorMessage)
    }

    func testRecordingForAPhoneStopsWhenItSaysItStoppedOrCantBeReached() async throws {
        let rig = try await rig()
        let state = rig.state
        let phone = try await PhoneLinkRig.connect(state)
        defer { Task { await phone.tearDown(state) } }
        state.microphoneAccess = { .authorized }
        state.phoneCapture = PhoneCapture(start: { id in _ = self.macStartsRecording(rig, into: id); return true },
                                          stop: { id in self.macStopsRecording(rig, id) })
        func phoneLeads() async throws -> UUID {
            let conversation = UUID()
            let reply = try await phone.client.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                         timing: LinkTiming(startedAt: Date(), elapsed: 0)), from: phone.macID)
            guard case .accepted = reply.outcome else { XCTFail("\(reply.outcome)"); throw CancellationError() }
            return conversation
        }
        // Its stop was lost; then it says it's idle (as it does on every reconnection).
        let first = try await phoneLeads()
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: first, startedAt: Date())))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(state.recordingID, first, "still recording what the phone records")
        try await phone.client.send(.recordingState(LinkRecordingState(phase: .idle)))
        try await waitUntil("this Mac stops too") { state.recordingID == nil }
        XCTAssertEqual(state.notice, "\(PhoneLinkRig.phoneName) stopped recording, so this Mac stopped too.")

        // Gone for half an hour: this Mac stops on its own.
        _ = try await phoneLeads()
        await phone.client.disconnect(from: phone.macID)
        try await waitUntil("the phone is gone") { state.phoneLink.peers[phone.phoneID] == nil }
        state.checkPhoneLead(now: Date().addingTimeInterval(10 * 60))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(state.recordingID)
        state.checkPhoneLead(now: Date().addingTimeInterval(31 * 60))
        try await waitUntil("stopped on its own") { state.recordingID == nil }
        XCTAssertEqual(state.notice, "\(PhoneLinkRig.phoneName) couldn’t be reached for 30 minutes, so this Mac stopped recording.")
    }

    func testGoingToSleepGivesThePhoneItsStopFirstButNotForLong() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let id = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        // Capture stops on its own as the Mac goes to sleep; sleep waits for the phone's stop.
        Task { try? await Task.sleep(for: .milliseconds(100)); self.macStopsRecording(rig, id) }
        await rig.state.prepareForSleep(within: .seconds(3))
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.start, .stop])
        XCTAssertEqual(rig.meeting(id)?.companions?.first?.state, .stopped)

        // A phone that doesn't answer doesn't keep the Mac awake.
        phone.recorder.delay(.stop, by: .seconds(10))
        let other = macStartsRecording(rig)
        await rig.state.sources.recorders.settle()
        macStopsRecording(rig, other)
        let clock = ContinuousClock()
        let waited = await clock.measure { await rig.state.prepareForSleep(within: .milliseconds(500)) }
        XCTAssertLessThan(waited, .seconds(2))
    }

    func testARecoveredRecordingClosesItsLinksAndStopsThePhoneItStarted() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        // Daybook quit while recording with the phone; at the next launch its capture is recovered.
        let start = Date().addingTimeInterval(-120)
        let id = rig.state.newMeeting(title: "Interrupted", date: start)
        var link = CompanionRecording(deviceID: phone.phoneID.uuidString, deviceKind: DaybookPhoneIntegration.id,
                                      deviceName: PhoneLinkRig.phoneName, macStartedAt: start, state: .recording, startedByDaybook: true)
        link.recordingID = "R-1"
        rig.state.update(id) { $0.companions = [link] }
        XCTAssertEqual(SourceHooks.companionLine(link, recordingNow: false), "Waiting for the \(PhoneLinkRig.phoneName) recording.",
                       "not \"Also recording\" once this Mac isn't")
        rig.state.sources.recovered.append((id, start, start.addingTimeInterval(60)))
        rig.state.closeRecoveredLinks()
        await rig.state.sources.recorders.settle()
        XCTAssertEqual(phone.recorder.requests.map(\.action), [.stop])
        let closed = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(closed.state, .stopped)
        XCTAssertNotNil(closed.macEndedAt)
        // A line waiting for a recording that never comes goes after two days.
        XCTAssertNotNil(SourceHooks.companionLine(closed, recordingNow: false))
        XCTAssertNil(SourceHooks.companionLine(closed, recordingNow: false, now: Date().addingTimeInterval(3 * 86_400)))
    }

    // MARK: Progress and nudges

    func testProgressMessagesReachThePhoneWhileProcessing() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let audio = try rig.audio("progress.wav", frequency: 640)
        let id = try await rig.waitingConversation("Progress", audio: audio, script: [(0, "Hello from the Mac.")])

        rig.state.enqueue(id)
        try await rig.processed(id)
        try await waitUntil("the last message") { phone.events.progress.contains { $0.meetingID == id && $0.phase == .finished } }
        // It waited for models while its recording was stored; from the queue on, the phone hears each step.
        let all = phone.events.progress.filter { $0.meetingID == id }
        let messages = Array(all.drop { $0.phase != .queued })
        let phases = messages.map(\.phase)
        XCTAssertEqual(all.first?.phase, .waitingForModels)
        XCTAssertEqual(phases.first, .queued)
        XCTAssertTrue(phases.contains(.transcribing))
        XCTAssertTrue(phases.contains(.summarizing))
        XCTAssertEqual(phases.last, .finished)
        XCTAssertTrue(messages.allSatisfy { $0.macName == rig.state.library.thisDevice.name })
        XCTAssertEqual(messages.last?.fraction, 1)
    }

    // MARK: The phone's recording arrives through sync

    func testAPhoneRecordingSyncedOnItsOwnJoinsTheMacConversationByItsLinkWithTheClockPrior() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let skew: TimeInterval = 2.5
        let link = try await PhoneLinkRig.connect(state, clockOffset: skew)
        defer { Task { await link.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { library.tearDown() }
        let expected = ExpectedOffsets()
        state.sources.alignAudio = { _, _, prior, _ in expected.append(prior); return nil }

        // The phone answers with its recording's ID and its start, on its own clock.
        let recordingID = UUID()
        let phoneStarted = PhoneStart()
        link.recorder.answer = { request in
            let start = Date().addingTimeInterval(skew)
            phoneStarted.set(start)
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: start, recordingID: recordingID.uuidString))
        }
        let macAudio = try rig.audio("mac.wav", frequency: 300)
        let phoneAudio = try rig.audio("iphone.wav", frequency: 450)
        try rig.inference.script(macAudio, [(0, "Let's start the review.")])
        try rig.inference.script(phoneAudio, [(0, "Let's start the review.")])

        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()
        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, id, audio: macAudio, start: macStart)
        let phoneStart = try XCTUnwrap(phoneStarted.value)

        // The phone files its recording as a conversation of its own and asks a Mac to transcribe it.
        let own = try await library.file(phoneAudio, recordingID: recordingID, start: phoneStart, duration: 0.5)
        await library.synchronize()
        let requestID = try XCTUnwrap(library.library.meeting(own)?.processingRequests?.first?.id)
        // Its nudge makes this Mac look now.
        try await link.client.send(.processingNudge(LinkProcessingNudge(requestID: requestID, meetingID: own, mode: .transcribe)))

        try await waitUntil("the phone's recording to join the Mac's conversation", timeout: 20) {
            rig.meeting(id)?.tracks.count == 2 && rig.meeting(own) == nil && state.processingID == nil && state.queuedIDs.isEmpty
                && rig.meeting(id)?.summary != nil
        }
        let meeting = try XCTUnwrap(rig.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id })
        XCTAssertEqual(track.deviceRecordingID, recordingID.uuidString)
        // The prior: the phone's start on this Mac's clock, by the link's measured offset.
        let prior = phoneStart.addingTimeInterval(-skew).timeIntervalSince(macStart)
        XCTAssertEqual(try XCTUnwrap(track.alignment?.clockOffset), prior, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(expected.values.first ?? nil), prior, accuracy: 0.05, "AudioAligner's expected offset")
        let companion = try XCTUnwrap(meeting.companions?.first)
        XCTAssertEqual(companion.state, .attached)
        XCTAssertEqual(companion.trackID, track.id)
        XCTAssertTrue(meeting.revisions.contains { $0.field == "source:\(track.id.uuidString)" && $0.newValue == "Added \(PhoneLinkRig.phoneName) recording" })
        XCTAssertEqual(Set(rig.inference.transcribed), Set([try AudioDigest.sha256(fileURL: macAudio), try AudioDigest.sha256(fileURL: phoneAudio)]),
                       "Each recording transcribed in the Mac's conversation")
        XCTAssertEqual(rig.inference.transcribed.count, 2, "Once each: the phone's own conversation isn't transcribed")
        XCTAssertEqual(state.sourceRole(track, in: meeting), "\(PhoneLinkRig.phoneName) · microphone")

        // On the phone: its own conversation goes, and the Mac's holds its recording.
        await state.synchronizeLibrary()
        await library.synchronize()
        XCTAssertNil(library.library.meeting(own))
        XCTAssertEqual(library.library.meeting(id)?.tracks.count, 2)
        XCTAssertEqual(library.library.processingStatus(for: id), .done)
    }

    func testAPhoneRecordingInTheMacConversationWaitsToBeLinedUpFromTheClockPrior() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let skew: TimeInterval = -0.8
        let link = try await PhoneLinkRig.connect(state, clockOffset: skew)
        defer { Task { await link.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { library.tearDown() }
        let expected = ExpectedOffsets()
        state.sources.alignAudio = { _, _, prior, _ in expected.append(prior); return nil }
        let recordingID = UUID()
        let phoneStarted = PhoneStart()
        link.recorder.answer = { request in
            let start = Date().addingTimeInterval(skew)
            phoneStarted.set(start)
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: start, recordingID: recordingID.uuidString))
        }
        let macAudio = try rig.audio("mac-b.wav", frequency: 310)
        let phoneAudio = try rig.audio("iphone-b.wav", frequency: 470)
        try rig.inference.script(macAudio, [(0, "Agenda first.")])
        try rig.inference.script(phoneAudio, [(0, "Agenda first.")])

        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()
        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, id, audio: macAudio, start: macStart)
        await state.synchronizeLibrary()

        // The phone recorded into the Mac's conversation: it files its track there.
        await library.synchronize()
        XCTAssertNotNil(library.library.meeting(id))
        try await library.file(phoneAudio, recordingID: recordingID, into: id, start: try XCTUnwrap(phoneStarted.value), duration: 0.5)
        await library.synchronize()
        await state.synchronizeLibrary()

        try await waitUntil("the conversation to be processed with both recordings", timeout: 20) {
            rig.meeting(id)?.summary != nil && state.processingID == nil && state.queuedIDs.isEmpty
        }
        let meeting = try XCTUnwrap(rig.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id })
        let prior = try XCTUnwrap(phoneStarted.value).addingTimeInterval(-skew).timeIntervalSince(macStart)
        XCTAssertEqual(try XCTUnwrap(track.alignment?.clockOffset), prior, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(expected.values.first ?? nil), prior, accuracy: 0.05)
        XCTAssertEqual(meeting.companions?.first?.state, .attached)
        XCTAssertEqual(meeting.companions?.first?.trackID, track.id)
        XCTAssertEqual(meeting.processingRequests?.first?.outcome?.result, .completed, "The phone's request on it is done")
        XCTAssertEqual(state.meetings.count, 1)
    }

    func testABookmarkMadeOnThePhoneIsOneBookmarkAfterSync() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let link = try await PhoneLinkRig.connect(state)
        defer { Task { await link.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { library.tearDown() }
        let recordingID = UUID()
        link.recorder.answer = { request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: recordingID.uuidString))
        }
        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()

        // The phone marks a moment: the Mac shows it at once, and the phone keeps it with its recording.
        let mark = Highlight(time: 1.5)
        try await link.client.send(.bookmark(LinkBookmark(id: mark.id, conversationID: id, recordingTime: mark.time)))
        try await waitUntil("the Mac's copy") { rig.meeting(id)?.highlights.contains { $0.id == mark.id } == true }
        // The same bookmark again (a resend) doesn't add a second.
        try await link.client.send(.bookmark(LinkBookmark(id: mark.id, conversationID: id, recordingTime: mark.time)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.meeting(id)?.highlights.count, 1)

        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, id, audio: try rig.audio("mac-mark.wav", frequency: 330), start: macStart)
        await state.synchronizeLibrary()
        await library.synchronize()
        try await library.file(try rig.audio("iphone-mark.wav", frequency: 490), recordingID: recordingID, into: id, start: Date(),
                               duration: 0.5, bookmarks: [mark])
        await library.synchronize()
        await state.synchronizeLibrary()
        XCTAssertEqual(rig.meeting(id)?.highlights.filter { $0.id == mark.id }.count, 1)
        XCTAssertEqual(rig.meeting(id)?.highlights.count, 1, "One bookmark, not one from each device")
        await library.synchronize()
        XCTAssertEqual(library.library.meeting(id)?.highlights.count, 1)
    }

    func testThePhonesOwnStartAndTheClockItMeasuredPlaceItsRecording() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let skew: TimeInterval = 2.5
        let link = try await PhoneLinkRig.connect(state, clockOffset: skew)
        defer { Task { await link.tearDown(state) } }
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
        defer { library.tearDown() }
        let expected = ExpectedOffsets()
        state.sources.alignAudio = { _, _, prior, _ in expected.append(prior); return nil }
        let recordingID = UUID()
        // The phone's answer reports its start roughly (before its first sample arrived).
        let phoneStart = Date().addingTimeInterval(skew + 1)
        link.recorder.answer = { request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: phoneStart.addingTimeInterval(-0.4),
                                    recordingID: recordingID.uuidString))
        }
        let macAudio = try rig.audio("mac-clock.wav", frequency: 315)
        let phoneAudio = try rig.audio("iphone-clock.wav", frequency: 475)
        try rig.inference.script(macAudio, [(0, "Clocks first.")])
        try rig.inference.script(phoneAudio, [(0, "Clocks first.")])
        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()
        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        // The link kept no clock (the burst hadn't finished, say); the phone measured one while recording.
        state.update(id) { $0.companions?[0].clock = nil }
        try await storeMacRecording(rig, id, audio: macAudio, start: macStart)
        await state.synchronizeLibrary()
        await library.synchronize()
        let measured = CapturePeerClock(deviceID: state.phoneLink.identity.deviceID.uuidString, name: "Mac", deviceClass: "mac",
                                        offset: -skew, uncertainty: 0.004, sampleCount: 6, measuredAt: Date())
        try await library.file(phoneAudio, recordingID: recordingID, into: id, start: phoneStart, duration: 0.5, peerClocks: [measured])
        await library.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("processed", timeout: 20) { rig.meeting(id)?.summary != nil && state.processingID == nil && state.queuedIDs.isEmpty }
        let track = try XCTUnwrap(rig.meeting(id)?.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id })
        // Its exact first sample, on this Mac's clock by the phone's measurement: 1 s after this Mac's start.
        let prior = phoneStart.addingTimeInterval(-skew).timeIntervalSince(macStart)
        XCTAssertEqual(try XCTUnwrap(track.alignment?.clockOffset), prior, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(expected.values.first ?? nil), prior, accuracy: 0.01)
        // Its start on this Mac's clock, wherever a start is compared.
        XCTAssertEqual(state.trackStart(track)?.timeIntervalSince(phoneStart.addingTimeInterval(-skew)) ?? 99, 0, accuracy: 0.01)
    }

    func testAPhoneRecordingInAConversationAMacRecordedWithItStaysThere() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let phoneID = UUID()
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: phoneID)
        defer { library.tearDown() }
        // The sound would put the phone's recording in this Mac's conversation, which overlaps it.
        state.sources.alignAudio = { _, _, _, _ in AudioAlignment(offset: 0.1, rate: 1, confidence: 0.9) }
        let macAudio = try rig.audio("standup.wav", frequency: 325)
        let phoneAudio = try rig.audio("iphone-linked.wav", frequency: 485)
        try rig.inference.script(macAudio, [(0, "Standup notes.")])
        try rig.inference.script(phoneAudio, [(0, "Design notes.")])
        let start = Date().addingTimeInterval(-300)
        let other = try await rig.macConversation("Standup", at: start, seconds: 0.5, audio: macAudio)
        state.awaitingModels.remove(other)
        // Another Mac recorded this conversation with the phone; only the phone's recording has synced yet.
        let conversation = UUID()
        library.library.add(Meeting(id: conversation, title: "Design review", date: start, status: .imported))
        library.library.update(conversation) {
            $0.companions = [CompanionRecording(deviceID: phoneID.uuidString, deviceKind: DaybookPhoneIntegration.id, deviceName: "Pocket iPhone",
                                                macStartedAt: start, state: .recording, startedByDaybook: true)]
        }
        try await library.file(phoneAudio, recordingID: UUID(), into: conversation, start: start.addingTimeInterval(0.1), duration: 0.5)
        await library.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("processed", timeout: 20) {
            rig.meeting(conversation)?.transcripts.isEmpty == false && state.processingID == nil && state.queuedIDs.isEmpty
        }
        XCTAssertEqual(rig.meeting(conversation)?.tracks.count, 1, "it waits for that Mac's recording")
        XCTAssertEqual(rig.meeting(other)?.tracks.count, 1, "never moved into another conversation")
    }

    func testAJoinedPhoneRecordingThatTurnsOutAloneSetsItsConversationsTimeline() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { library.tearDown() }
        let phoneAudio = try rig.audio("iphone-alone.wav", frequency: 495)
        try rig.inference.script(phoneAudio, [(0, "Nobody else recorded this.")])
        // The phone asked a Mac that never answered, so it filed its recording to be placed; no Mac recording comes.
        let conversation = UUID(), note = TimedNote(time: 3, text: "Kickoff")
        try await library.file(phoneAudio, recordingID: UUID(), into: conversation, start: Date().addingTimeInterval(-600), duration: 0.5,
                               notes: [note])
        await library.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("processed", timeout: 20) { rig.meeting(conversation)?.summary != nil && state.processingID == nil && state.queuedIDs.isEmpty }
        let meeting = try XCTUnwrap(rig.meeting(conversation))
        XCTAssertEqual(meeting.tracks.first?.offset, 0, "its own recording sets the timeline")
        XCTAssertNil(meeting.tracks.first?.alignment)
        XCTAssertEqual(meeting.timedNotes?.first?.time, 3)
    }

    func testARecorderRecordingThePhoneImportedJoinsTheMacsConversationByItsLink() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { library.tearDown() }
        // Soundcore Work records along with this Mac.
        let recorder = FakeRecorder()
        let session = DeviceSession(device: ConfiguredDevice(id: "recorder", kind: SoundcoreWorkIntegration().kind),
                                    kind: SoundcoreWorkIntegration().kind, connections: [recorder], defaults: rig.defaults)
        addTeardownBlock { session.shutDown() }
        state.sources.recorders.sessions = { [session] }
        let macAudio = try rig.audio("mac-handoff.wav", frequency: 345)
        let recorderAudio = try rig.audio("soundcore-handoff.wav", frequency: 545)
        try rig.inference.script(macAudio, [(0, "Handing it over.")])
        try rig.inference.script(recorderAudio, [(0, "Handing it over.")])
        let id = macStartsRecording(rig)
        let macStart = try XCTUnwrap(state.recordingStartedAt)
        await state.sources.recorders.settle()
        let link = try XCTUnwrap(rig.meeting(id)?.companions?.first)
        XCTAssertEqual(link.state, .recording)
        // The recorder moves to the phone mid-recording; this Mac can't reach it to stop it.
        recorder.disconnect()
        recorder.reachable = false
        macStopsRecording(rig, id)
        await state.sources.recorders.settle()
        try await storeMacRecording(rig, id, audio: macAudio, start: macStart)
        await state.synchronizeLibrary()
        // The phone imports its recording into a conversation of its own, which syncs here.
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "FAKE1", recordingID: try XCTUnwrap(link.recordingID))
        let own = try await library.fileFromRecorder(recorderAudio, identity: identity, start: try XCTUnwrap(link.recorderStartedAt))
        await library.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("the recorder's recording to join by its link", timeout: 20) {
            rig.meeting(id)?.tracks.count == 2 && rig.meeting(own) == nil && state.processingID == nil && state.queuedIDs.isEmpty
        }
        let meeting = try XCTUnwrap(rig.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == SoundcoreWorkIntegration.id })
        XCTAssertEqual(track.deviceRecordingID, link.recordingID)
        XCTAssertEqual(meeting.companions?.first?.state, .attached, "no longer waiting for it")
        XCTAssertEqual(meeting.companions?.first?.trackID, track.id)
    }

    func testAnUnlinkedPhoneRecordingJoinsByTimeThenSound() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let library = try await PhoneLibrarySide.make(in: self, root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
        defer { library.tearDown() }
        // The sound matches the Mac's recording, 0.1 s in.
        state.sources.alignAudio = { _, _, _, _ in AudioAlignment(offset: 0.1, rate: 1, confidence: 0.9) }
        let macAudio = try rig.audio("mac-c.wav", frequency: 320)
        let phoneAudio = try rig.audio("iphone-c.wav", frequency: 480)
        try rig.inference.script(phoneAudio, [(0, "Same room, no link.")])
        let start = Date().addingTimeInterval(-300)
        let id = try await rig.macConversation("Standup", at: start, seconds: 0.5, audio: macAudio)
        try rig.inference.script(macAudio, [(0, "Same room, no link.")])
        state.awaitingModels.remove(id)

        let own = try await library.file(phoneAudio, recordingID: UUID(), start: start.addingTimeInterval(0.1), duration: 0.5)
        await library.synchronize()
        await state.synchronizeLibrary()
        try await waitUntil("the phone's recording to join by sound", timeout: 20) {
            rig.meeting(id)?.tracks.count == 2 && rig.meeting(own) == nil && state.processingID == nil && state.queuedIDs.isEmpty
        }
        let track = try XCTUnwrap(rig.meeting(id)?.tracks.first { $0.deviceKind == DaybookPhoneIntegration.id })
        XCTAssertEqual(track.alignment?.method, .audio)
        XCTAssertEqual(track.alignment?.offset ?? 99, 0.1, accuracy: 0.001)
    }
}

/// Expected offsets the aligner was given.
final class ExpectedOffsets: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval?] = []
    var values: [TimeInterval?] { lock.withLock { _values } }
    func append(_ value: TimeInterval?) { lock.withLock { _values.append(value) } }
}

/// When the phone said its recording started.
final class PhoneStart: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date?
    var value: Date? { lock.withLock { _value } }
    func set(_ date: Date) { lock.withLock { _value = date } }
}

private extension Date {
    /// Whole milliseconds, as the library's JSON keeps dates.
    var rounded: Date { Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded(.down) / 1000) }
}
