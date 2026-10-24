import DaybookCore
@testable import DaybookKit
import DaybookLink
import Foundation
import XCTest
@testable import Daybook

/// Daybook on iPhone as a device of this Mac, over loopback: pairing as the sheet shows it, record
/// control in both directions with the clock prior, live progress, nudges, and the phone's synced
/// recording joining this Mac's conversation through multipoint matching.
@MainActor
final class PhoneLinkTests: XCTestCase {
    private func rig() async throws -> MultiSourceRig {
        let rig = try await MultiSourceRig.make(models: true)
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
        try await waitFor("a new code") { if case .showing(let code) = state.phoneLink.pairing { return code != first }; return false }
        XCTAssertNotNil(state.phoneLink.pairingProblem)
        guard case .showing(let second) = state.phoneLink.pairing else { return XCTFail() }

        // The right one: the sheet shows the phone, which joins Devices.
        let mac = try await client.pair(with: endpoint, code: second.digits)
        XCTAssertEqual(mac.deviceID, state.phoneLink.identity.deviceID)
        try await waitFor("the paired phone") { if case .paired = state.phoneLink.pairing { return true }; return false }
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
        try await waitFor("the phone to connect") { session.isLinked }
        XCTAssertEqual(session.direct?.state, .connected)
        await state.phoneLink.endPairing()
        XCTAssertEqual(state.phoneLink.pairing, .closed)
        XCTAssertTrue(state.phoneLink.isRunning, "A paired phone keeps the link running")

        // Unpair: the phone hears it, the device leaves Devices, and with no phone the link stops.
        state.unpairPhone(phoneID)
        try await waitFor("the unpairing") { state.devices.session(phoneID.uuidString) == nil && state.phoneLink.paired.isEmpty }
        try await waitFor("the phone to hear it") { events.unpaired }
        try await waitFor("the link to stop") { !state.phoneLink.isRunning }
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
        XCTAssertEqual(lead.state, .alreadyRecording, "The phone leads; this Mac never stops it")
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

        // A recording started on the Mac can't be stopped from the phone.
        state.microphoneAccess = { .authorized }
        let own = macStartsRecording(rig)
        let declined = try await phone.client.request(LinkRecordRequest(action: .stop, conversationID: own), from: phone.macID)
        guard case .refused(let no) = declined.outcome else { return XCTFail() }
        XCTAssertEqual(no.reason, .declined)
        XCTAssertEqual(state.recordingID, own)
        macStopsRecording(rig, own)
        await state.sources.recorders.settle()
    }

    // MARK: Progress and nudges

    func testProgressMessagesReachThePhoneWhileProcessing() async throws {
        let rig = try await rig()
        let phone = try await PhoneLinkRig.connect(rig.state)
        defer { Task { await phone.tearDown(rig.state) } }
        let audio = try rig.audio("progress.wav", frequency: 640)
        let id = try await rig.waitingConversation("Progress", audio: audio, script: [(0, "Hello from the Mac.")])

        rig.state.enqueue(id)
        try await rig.processed()
        try await waitFor("the last message") { phone.events.progress.contains { $0.meetingID == id && $0.phase == .finished } }
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
        let library = try await PhoneLibrarySide.make(root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
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

        try await waitFor("the phone's recording to join the Mac's conversation", timeout: 20) {
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
        let library = try await PhoneLibrarySide.make(root: try temporaryFolder("Phone"), cloud: cloud, phoneID: link.phoneID)
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

        try await waitFor("the conversation to be processed with both recordings", timeout: 20) {
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

    func testAnUnlinkedPhoneRecordingJoinsByTimeThenSound() async throws {
        let rig = try await rig()
        let state = rig.state
        let cloud = try temporaryFolder("Cloud")
        try rig.connectSync(cloud)
        let library = try await PhoneLibrarySide.make(root: try temporaryFolder("Phone"), cloud: cloud, phoneID: UUID())
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
        try await waitFor("the phone's recording to join by sound", timeout: 20) {
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
