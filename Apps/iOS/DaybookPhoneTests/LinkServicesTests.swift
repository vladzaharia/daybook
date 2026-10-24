import DaybookKit
import DaybookLink
import XCTest
@testable import DaybookPhone

/// The phone's link client against a real `LinkService` on 127.0.0.1 (no Bonjour, nothing
/// advertised): pairing with the code, the connection, live progress, a Mac's record requests,
/// "Record on Studio Mac too", clock samples on the recording, nudges, and unpairing.
@MainActor
final class LinkServicesTests: XCTestCase {
    struct Mac {
        let service: LinkService
        let id: UUID
        let endpoint: LinkEndpoint
        let store: MemoryLinkKeyStore
    }

    /// Collects what the Mac hears.
    final class MacInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LinkEvent] = []
        private var task: Task<Void, Never>?
        init(_ stream: AsyncStream<LinkEvent>) {
            task = Task { [weak self] in for await event in stream { self?.lock.withLock { self?.events.append(event) } } }
        }
        deinit { task?.cancel() }
        var all: [LinkEvent] { lock.withLock { events } }
        var nudges: [LinkProcessingNudge] {
            all.compactMap { if case .received(.processingNudge(let nudge), _) = $0 { return nudge } else { return nil } }
        }
        var bookmarks: [LinkBookmark] {
            all.compactMap { if case .received(.bookmark(let mark), _) = $0 { return mark } else { return nil } }
        }
        var states: [LinkRecordingState] {
            all.compactMap { if case .received(.recordingState(let state), _) = $0 { return state } else { return nil } }
        }
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [LinkRecordRequest] = []
        func append(_ request: LinkRecordRequest) { lock.withLock { requests.append(request) } }
        var all: [LinkRecordRequest] { lock.withLock { requests } }
    }

    func makeMac(name: String = "Studio Mac") async throws -> Mac {
        let id = UUID()
        let store = MemoryLinkKeyStore()
        let service = LinkService(identity: LinkIdentity(deviceID: id, name: name, deviceClass: .mac, appVersion: "1.0", canProcess: true),
                                  keyStore: store, configuration: .loopback())
        try await service.start()
        addTeardownBlock { await service.stop() }
        let listening = await service.port
        let port = try XCTUnwrap(listening)
        return Mac(service: service, id: id, endpoint: LinkEndpoint(host: "127.0.0.1", port: port), store: store)
    }

    func makeLink() -> PhoneLink {
        let link = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                             keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        addTeardownBlock { await link.setActivity(.background) }
        return link
    }

    func makeModel(link: PhoneLink, rig: RecorderRig) throws -> PhoneAppModel {
        let library = try PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
        let settings = PhoneSettings(defaults: UserDefaults(suiteName: "LinkServicesTests-\(UUID().uuidString)")!)
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             settings: settings, link: link)
    }

    func pair(_ link: PhoneLink, with mac: Mac) async throws {
        await link.start()
        let code = await mac.service.beginPairing()
        let paired = try await link.pair(with: mac.endpoint, code: code.digits)
        XCTAssertEqual(paired.name, "Studio Mac")
        try await waitUntil("connected") { link.macs.first?.isConnected == true }
    }

    func testPairsWithTheCodeConnectsAndShowsLiveProgress() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        await link.start()
        // A wrong code fails with words a person can act on, and is never sent twice.
        let first = await mac.service.beginPairing()
        let wrong = first.digits == "000000" ? "111111" : "000000"
        do {
            try await link.pair(with: mac.endpoint, code: wrong)
            XCTFail("a wrong code pairs nothing")
        } catch {
            XCTAssertEqual(PhoneLink.message(for: error), "That code didn't match. Your Mac now shows a new code; try that one.")
        }
        XCTAssertTrue(link.macs.isEmpty)
        let shown = await mac.service.pairingCode
        let code = try XCTUnwrap(shown)
        let paired = try await link.pair(with: mac.endpoint, code: code.formatted)
        XCTAssertEqual(paired.deviceID, mac.id)
        try await waitUntil("connected") { link.macs.first?.isConnected == true }
        let status = try XCTUnwrap(link.macs.first)
        XCTAssertEqual(status.name, "Studio Mac")
        XCTAssertTrue(status.canProcess)
        XCTAssertEqual(status.stateLine, "Connected")
        try await waitUntil("clock samples") { link.macs.first?.clock != nil }

        let meeting = UUID()
        try await mac.service.send(.processingProgress(LinkProcessingProgress(meetingID: meeting, phase: .transcribing, fraction: 0.4, macName: "Studio Mac")))
        try await waitUntil("progress") { link.liveProgress[meeting] != nil }
        XCTAssertEqual(link.liveProgress[meeting]?.line, "Transcribing on Studio Mac · 40%")
        var finished: UUID?
        link.onProcessingFinished = { finished = $0 }
        try await mac.service.send(.processingProgress(LinkProcessingProgress(meetingID: meeting, phase: .finished, macName: "Studio Mac")))
        try await waitUntil("finished") { finished == meeting }
        XCTAssertNil(link.liveProgress[meeting], "finished work leaves the live list; sync brings the result")

        await link.unpair(mac.id)
        XCTAssertTrue(link.macs.isEmpty)
        try await waitUntil("the Mac forgets the phone", timeout: 5) {
            ((try? mac.store.records()) ?? []).isEmpty
        }
    }

    func testTheMacStartsAndStopsRecordingHereAndTheRecordingCarriesItsClock() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await waitUntil("clock samples") { link.macs.first?.clock != nil }
        let phoneID = link.deviceID

        let conversation = UUID()
        // The rig's clock stands in for this iPhone's; the Mac started 30 s before the phone.
        let macStart = rig.clock.now().addingTimeInterval(-30)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: macStart, elapsed: 30)), from: phoneID)
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("expected the phone to record, got \(reply.outcome)") }
        XCTAssertEqual(ack.conversationID, conversation)
        XCTAssertFalse(ack.wasAlreadyRecording)
        XCTAssertEqual(ack.recordingID, conversation.uuidString)
        XCTAssertEqual(model.recorder.captureID, conversation)
        XCTAssertEqual(model.multipoint?.isMacLed, true)
        XCTAssertEqual(model.multipointLine, "Recording with Studio Mac")

        // Asked again (a retry), it doesn't start a second recording; another conversation is refused.
        let again = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation), from: phoneID)
        guard case .accepted(let repeated) = again.outcome else { return XCTFail("a repeat is acknowledged") }
        XCTAssertTrue(repeated.wasAlreadyRecording)
        let other = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: phoneID)
        guard case .refused(let refusal) = other.outcome else { return XCTFail("a second conversation is refused") }
        XCTAssertEqual(refusal.reason, .recordingSomethingElse)
        XCTAssertEqual(refusal.conversationID, conversation)

        rig.pump(1)
        model.editNotes("Budget agreed")
        rig.pump(2)
        _ = try await model.addBookmark()
        let stop = try await mac.service.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: phoneID)
        guard case .accepted(let stopped) = stop.outcome else { return XCTFail("the phone stops") }
        XCTAssertNotNil(stopped.stoppedAt)
        try await waitUntil("filed") { model.library.controller.meeting(conversation)?.tracks.isEmpty == false && !model.isFiling }

        // The phone's recording joins the Mac's conversation as a source to place, with its clock.
        let meeting = try XCTUnwrap(model.library.controller.meeting(conversation))
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertNil(track.offset, "the Mac places it; its own recording is the timeline's origin")
        let clock = try XCTUnwrap(track.capture?.peerClocks?.first)
        XCTAssertEqual(clock.deviceID, mac.id.uuidString)
        XCTAssertEqual(clock.name, "Studio Mac")
        XCTAssertLessThan(abs(clock.offset), 1, "same machine: the clocks agree")
        XCTAssertEqual(clock.peerRecordingStartedAt, macStart)
        XCTAssertEqual(meeting.highlights.first?.trackID, track.id, "a bookmark made here follows the phone recording's placement")
        XCTAssertEqual(meeting.date.timeIntervalSince1970, macStart.timeIntervalSince1970, accuracy: 1, "the conversation keeps the Mac's start")
        let note = try XCTUnwrap(meeting.timedNotes?.first { $0.text == "Budget agreed" })
        XCTAssertEqual(note.time ?? 0, 31, accuracy: 1.5, "notes move onto the conversation's timeline by the clock")
        XCTAssertNil(model.multipoint)
    }

    func testRecordOnTheMacTooAndNudgeAfterFiling() async throws {
        let mac = try await makeMac()
        let inbox = MacInbox(mac.service.events())
        let received = RequestLog()
        await mac.service.setRecordControlHandler { _, request in
            received.append(request)
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-1"))
        }
        var macRecording: [LinkRecordRequest] { received.all }
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)

        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        let id = try XCTUnwrap(model.recorder.captureID)
        XCTAssertEqual(model.macsToRecordWith.map(\.name), ["Studio Mac"])
        await model.recordOnMac(mac.id)
        XCTAssertEqual(model.multipointLine, "Also recording on Studio Mac")
        XCTAssertTrue(model.macsToRecordWith.isEmpty)
        XCTAssertEqual(macRecording.first?.action, .start)
        XCTAssertEqual(macRecording.first?.conversationID, id)
        XCTAssertEqual(macRecording.first?.timing?.startedAt, model.recorder.startedAt)
        let mark = try await model.addBookmark()
        try await waitUntil("the bookmark reaches the Mac") { inbox.bookmarks.first?.recordingTime == mark }
        try await waitUntil("recording state reaches the Mac") { inbox.states.contains { $0.phase == .recording && $0.conversationID == id } }

        rig.pump(1)
        try await model.stopRecording()
        // Stopping here stops what this iPhone started there, and tells the Mac about the request.
        try await waitUntil("the Mac is asked to stop") { macRecording.contains { $0.action == .stop } }
        try await waitUntil("a nudge") { inbox.nudges.first?.meetingID == id }
        XCTAssertEqual(inbox.nudges.first?.mode, .transcribe)
        XCTAssertEqual(model.library.openRequests(for: id).first?.id, inbox.nudges.first?.requestID)
        let track = try XCTUnwrap(model.library.controller.meeting(id)?.tracks.first)
        XCTAssertEqual(track.offset, 0, "the phone led: its recording is the timeline's origin")
        XCTAssertEqual(track.capture?.peerClocks?.first?.name, "Studio Mac")
    }

    func testRecordRequestsCanBeTurnedOff() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let model = try makeModel(link: link, rig: RecorderRig())
        model.settings.acceptsMacRecordRequests = false
        try await pair(link, with: mac)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: link.deviceID)
        guard case .refused(let refusal) = reply.outcome else { return XCTFail("declined") }
        XCTAssertEqual(refusal.reason, .declined)
        XCTAssertFalse(model.recorder.isActive)
    }
}
