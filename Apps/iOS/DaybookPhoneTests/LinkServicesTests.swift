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

    /// Answers record requests like the Mac app: it records the conversation it's asked to (once per
    /// request), stops only what it records, and can be slow to start (a microphone prompt).
    actor RecordingMac {
        private(set) var log: [LinkRecordRequest] = []
        private(set) var recording: UUID?
        private(set) var starts = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var held = false
        var startDelay: Duration?

        func holdStarts() { held = true }
        func releaseStarts() { held = false; gate?.resume(); gate = nil }
        func setStartDelay(_ delay: Duration?) { startDelay = delay }

        func handle(_ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
            log.append(request)
            switch request.action {
            case .start:
                if recording == request.conversationID {
                    return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), wasAlreadyRecording: true))
                }
                if held { await withCheckedContinuation { gate = $0 } }
                if let startDelay { try? await Task.sleep(for: startDelay) }
                starts += 1
                recording = request.conversationID
                return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-\(starts)"))
            default:
                guard recording == request.conversationID else { return .refused(LinkRecordRefusal(reason: .notRecording)) }
                recording = nil
                return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date()))
            }
        }

        var stops: [LinkRecordRequest] { log.filter { $0.action == .stop } }
    }

    func recordingMac(_ mac: Mac) async -> RecordingMac {
        let recorder = RecordingMac()
        await mac.service.setRecordControlHandler { _, request in await recorder.handle(request) }
        return recorder
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

    func makeModel(link: PhoneLink, rig: RecorderRig, settings: PhoneSettings? = nil) throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
        let settings = settings ?? PhoneSettings(defaults: UserDefaults(suiteName: "LinkServicesTests-\(UUID().uuidString)")!)
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
        let paired = try XCTUnwrap(link.macs.first)
        model.settings.setMacMayStartRecording(true, for: paired.id, pairedAt: paired.pairedAt)   // Allow, after pairing
        try await waitUntil("clock samples") { link.macs.first?.clock != nil }
        let phoneID = link.deviceID

        let conversation = UUID()
        // The rig's clock stands in for this iPhone's; the Mac started 30 s before the phone.
        let macStart = rig.clock.now().addingTimeInterval(-30)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: macStart, elapsed: 30),
                                                                    title: "Design review", date: macStart), from: phoneID)
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("expected the phone to record, got \(reply.outcome)") }
        XCTAssertEqual(ack.conversationID, conversation)
        XCTAssertFalse(ack.wasAlreadyRecording)
        XCTAssertEqual(model.recorder.captureID, conversation)
        let recordingID = try XCTUnwrap(model.recorder.recordingID)
        XCTAssertEqual(ack.recordingID, recordingID.uuidString, "the recording's own ID, which its track carries")
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
        XCTAssertEqual(track.deviceRecordingID, ack.recordingID)
        XCTAssertNil(track.offset, "the Mac places it; its own recording is the timeline's origin")
        let clock = try XCTUnwrap(track.capture?.peerClocks?.first)
        XCTAssertEqual(clock.deviceID, mac.id.uuidString)
        XCTAssertEqual(clock.name, "Studio Mac")
        XCTAssertLessThan(abs(clock.offset), 1, "same machine: the clocks agree")
        XCTAssertEqual(clock.peerRecordingStartedAt, macStart)
        XCTAssertEqual(meeting.highlights.first?.trackID, track.id, "a bookmark made here follows the phone recording's placement")
        XCTAssertEqual(meeting.date.timeIntervalSince1970, macStart.timeIntervalSince1970, accuracy: 0.001, "made as the Mac has it, before it syncs")
        XCTAssertEqual(meeting.title, "Design review", "the Mac's title, not a placeholder")
        XCTAssertEqual(meeting.status, .draft, "its status is the Mac's to set")
        let note = try XCTUnwrap(meeting.timedNotes?.first { $0.text == "Budget agreed" })
        XCTAssertEqual(note.time ?? 0, 31, accuracy: 1.5, "notes read about right by the clock until the Mac places the recording")
        XCTAssertEqual(track.alignment?.heldNoteIDs, [note.id], "and follow it once it's placed")
        XCTAssertNil(model.multipoint)
    }

    func testNotesReadOnTheTimelineOfAConversationTheMacRecordsIntoAgain() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await waitUntil("clock samples") { link.macs.first?.clock != nil }
        let conversation = UUID()
        // The conversation began 130 s before this iPhone starts; the Mac's own recording into it, 30 s before.
        let zero = rig.clock.now().addingTimeInterval(-130), macStart = rig.clock.now().addingTimeInterval(-30)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: macStart, elapsed: 130, timelineStart: zero),
                                                                    title: "Standup", date: zero), from: link.deviceID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        rig.pump(1)
        model.editNotes("Budget agreed")
        rig.pump(1)
        try await model.stopRecording()
        let meeting = try XCTUnwrap(model.library.controller.meeting(conversation))
        XCTAssertEqual(meeting.timedNotes?.first?.time ?? 0, 131, accuracy: 1.5, "on the conversation's timeline, not from the Mac's start")
        XCTAssertEqual(meeting.tracks.first?.alignment?.captureOffset ?? 0, 130, accuracy: 1.5)
    }

    func testRecordOnTheMacTooAndNudgeAfterFiling() async throws {
        let mac = try await makeMac()
        let inbox = MacInbox(mac.service.events())
        let received = RequestLog()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        let phoneLibrary = model.library.controller
        // Like the Mac: it records into the phone's conversation, made as the phone sent it, which
        // syncs to the phone while both record.
        await mac.service.setRecordControlHandler { _, request in
            received.append(request)
            if request.action == .start {
                await MainActor.run {
                    phoneLibrary.add(Meeting(id: request.conversationID, title: request.title ?? "?", date: request.date ?? .distantPast,
                                             status: .recording))
                }
            }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-1"))
        }
        var macRecording: [LinkRecordRequest] { received.all }
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
        XCTAssertEqual(macRecording.first?.title, model.recorder.title, "the conversation as the phone will file it")
        XCTAssertEqual(macRecording.first?.date, model.recorder.startedAt)
        rig.pump(1)
        model.editNotes("Kickoff")
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
        let meeting = try XCTUnwrap(model.library.controller.meeting(id))
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertNil(track.offset, "the Mac recorded too: the phone's recording joins its conversation, to be placed")
        XCTAssertEqual(meeting.notes, "Kickoff", "the notes are written")
        XCTAssertEqual(meeting.timedNotes?.first?.time, 2)
        XCTAssertEqual(track.alignment?.heldNoteIDs, meeting.timedNotes?.map(\.id), "held by the phone's recording until it's placed")
        XCTAssertEqual(meeting.highlights.first?.trackID, track.id)
        XCTAssertEqual(meeting.status, .recording, "the conversation's status is the Mac's")
        XCTAssertEqual(track.capture?.peerClocks?.first?.name, "Studio Mac")
    }

    func testADevicePageStartRecordsAConversationOfThePhonesOwn() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        // From the Mac's device page (and from an older Mac, which sends no timing).
        for request in [LinkRecordRequest(action: .start, conversationID: UUID(), standalone: true),
                        LinkRecordRequest(action: .start, conversationID: UUID())] {
            let reply = try await mac.service.request(request, from: link.deviceID)
            guard case .accepted(let ack) = reply.outcome else { return XCTFail("\(reply.outcome)") }
            XCTAssertFalse(ack.wasAlreadyRecording)
            XCTAssertEqual(model.recorder.captureID, request.conversationID)
            XCTAssertNil(model.multipoint, "not a recording alongside the Mac")
            XCTAssertNil(model.multipointLine)
            rig.pump(1)
            model.editNotes("Note")
            rig.pump(1)
            let stop = try await mac.service.request(LinkRecordRequest(action: .stop, conversationID: request.conversationID), from: link.deviceID)
            guard case .accepted = stop.outcome else { return XCTFail("the Mac that started it may stop it: \(stop.outcome)") }
            try await waitUntil("filed") { model.library.controller.meeting(request.conversationID)?.tracks.isEmpty == false && !model.isFiling }
            let meeting = try XCTUnwrap(model.library.controller.meeting(request.conversationID))
            XCTAssertEqual(meeting.tracks.first?.offset, 0, "its own timeline")
            XCTAssertNil(meeting.tracks.first?.alignment)
            XCTAssertEqual(meeting.paragraphTimes(), [1])
            XCTAssertEqual(meeting.status, .imported)
        }
    }

    func testAMacsRecordingStateMarksItBusyOrStoppedAndExpires() async throws {
        let mac = try await makeMac()
        await mac.service.setRecordControlHandler { _, request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-1"))
        }
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        let phoneID = link.deviceID

        // Busy with a conversation of its own: not offered to record this one.
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: UUID(), startedAt: Date())), to: phoneID)
        try await waitUntil("the Mac's state") { link.macs.first?.isRecording == true }
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        XCTAssertTrue(model.macsToRecordWith.isEmpty, "a Mac recording something else isn't offered")
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .idle)), to: phoneID)
        try await waitUntil("idle") { link.macs.first?.isRecording == false }
        XCTAssertEqual(model.macsToRecordWith.map(\.name), ["Studio Mac"])

        // Recording with this iPhone, then stopped on the Mac: the line says so.
        let id = try XCTUnwrap(model.recorder.captureID)
        await model.recordOnMac(mac.id)
        XCTAssertEqual(model.multipointLine, "Also recording on Studio Mac")
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: id, startedAt: Date())), to: phoneID)
        try await waitUntil("recording") { link.macs.first?.recording?.conversationID == id }
        XCTAssertEqual(model.multipoint?.macs.first?.state, .recording)
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .idle)), to: phoneID)
        try await waitUntil("stopped") { model.multipoint?.macs.first?.state == .stopped }
        XCTAssertNil(model.multipointLine)

        // What a Mac said lasts 45 s; it repeats it every 15 s while recording.
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: UUID(), startedAt: Date())), to: phoneID)
        try await waitUntil("recording again") { link.macs.first?.isRecording == true }
        link.pruneRecordingStates(now: Date().addingTimeInterval(30))
        XCTAssertTrue(link.macs.first?.isRecording == true)
        link.pruneRecordingStates(now: Date().addingTimeInterval(46))
        XCTAssertFalse(link.macs.first?.isRecording == true, "a Mac that stopped saying so may have stopped")
        try await model.stopRecording()
    }

    func testOnlyTheMacARecordingIsWithMayStopIt() async throws {
        let studio = try await makeMac()
        let laptop = try await makeMac(name: "MacBook Air")
        await studio.service.setRecordControlHandler { _, request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-1"))
        }
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: studio)
        let code = await laptop.service.beginPairing()
        _ = try await link.pair(with: laptop.endpoint, code: code.digits)
        try await waitUntil("both connected") { link.connectedMacs.count == 2 }

        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        let id = try XCTUnwrap(model.recorder.captureID)
        // Recorded on this iPhone alone: no Mac may stop it.
        let early = try await studio.service.request(LinkRecordRequest(action: .stop, conversationID: id), from: link.deviceID)
        guard case .refused(let refusal) = early.outcome else { return XCTFail("\(early.outcome)") }
        XCTAssertEqual(refusal.reason, .declined)
        XCTAssertTrue(model.recorder.isActive)

        // Recording along with Studio Mac: it may; the MacBook Air, which has nothing to do with it, may not.
        await model.recordOnMac(studio.id)
        let other = try await laptop.service.request(LinkRecordRequest(action: .stop, conversationID: id), from: link.deviceID)
        guard case .refused(let declined) = other.outcome else { return XCTFail("\(other.outcome)") }
        XCTAssertEqual(declined.reason, .declined)
        XCTAssertTrue(model.recorder.isActive)
        let stop = try await studio.service.request(LinkRecordRequest(action: .stop, conversationID: id), from: link.deviceID)
        guard case .accepted = stop.outcome else { return XCTFail("\(stop.outcome)") }
        try await waitUntil("stopped") { !model.recorder.isActive && !model.isFiling }
    }

    // MARK: Lost answers and stops

    func testAStartWhoseAnswerIsSlowIsAskedAgainAndCountsAsThisIPhones() async throws {
        let mac = try await makeMac()
        let macRecorder = await recordingMac(mac)
        // Longer than a request waits (3 s on loopback): the first ask times out.
        await macRecorder.setStartDelay(.milliseconds(3_500))
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        await model.recordOnMac(mac.id)
        let entry = try XCTUnwrap(model.multipoint?.macs.first)
        XCTAssertEqual(entry.state, .recording, "asked again with the same request, it got the first answer")
        XCTAssertTrue(entry.startedByPhone, "a repeat answered as the first: this iPhone started it, so it stops it")
        let starts = await macRecorder.starts
        XCTAssertEqual(starts, 1)
        let requests = await macRecorder.log.filter { $0.action == .start }
        XCTAssertEqual(requests.count, 1, "the Mac's app heard it once")
        try await model.stopRecording()
        try await waitUntil("the Mac is stopped") { model.pendingStops.isEmpty }
        let recording = await macRecorder.recording
        XCTAssertNil(recording)
    }

    func testStopWhileAMacIsStillBeingAskedStopsItWhenItsStartComesBack() async throws {
        let mac = try await makeMac()
        let macRecorder = await recordingMac(mac)
        await macRecorder.holdStarts()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        let asking = Task { await model.recordOnMac(mac.id) }
        try await waitUntil("asking") { model.multipoint?.macs.first?.state == .asking }
        try await model.stopRecording()
        // The Mac wasn't recording yet when the stop came; its start then comes through.
        try await waitUntil("the first stop") { model.pendingStops.isEmpty }
        await macRecorder.releaseStarts()
        await asking.value
        try await waitUntil("stopped once its start came back", timeout: 5) { model.pendingStops.isEmpty }
        let stops = await macRecorder.stops.count
        XCTAssertGreaterThanOrEqual(stops, 2)
        let recording = await macRecorder.recording
        XCTAssertNil(recording, "a Mac this iPhone started never outlives its recording")
        let filed = try XCTUnwrap(model.library.conversations.first)
        XCTAssertNil(filed.tracks.first?.offset, "it may have recorded: this recording joins its conversation")
    }

    func testAStopThatDidntReachTheMacGoesWhenItReconnects() async throws {
        let mac = try await makeMac()
        let macRecorder = await recordingMac(mac)
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        await model.recordOnMac(mac.id)
        XCTAssertEqual(model.multipoint?.macs.first?.state, .recording)
        // The link drops; this iPhone stops meanwhile.
        await link.client.disconnect(from: mac.id)
        try await waitUntil("disconnected") { link.macs.first?.isConnected == false }
        try await model.stopRecording()
        XCTAssertEqual(model.pendingStops[mac.id], try XCTUnwrap(model.library.conversations.first?.id), "owed until the Mac hears it")
        var recording = await macRecorder.recording
        XCTAssertNotNil(recording)
        try await link.client.connect(to: mac.id, via: mac.endpoint)
        try await waitUntil("the stop goes on reconnecting") { model.pendingStops.isEmpty }
        recording = await macRecorder.recording
        XCTAssertNil(recording)
    }

    func testAnUnexpectedEndStopsTheMacsThisIPhoneStarted() async throws {
        let mac = try await makeMac()
        let macRecorder = await recordingMac(mac)
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        await model.recordOnMac(mac.id)
        // The encoder fails: the recorder finishes what it has and reports it.
        let recording = await rig.recorder.stop()
        rig.recorder.onUnexpectedStop?(recording)
        try await waitUntil("the Mac is stopped") { model.multipoint == nil && model.pendingStops.isEmpty && !model.library.conversations.isEmpty }
        let stopped = await macRecorder.recording
        XCTAssertNil(stopped)
    }

    func testRecordingForAMacStopsWhenItSaysItStoppedOrCantBeReached() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        let phoneID = link.deviceID
        func start() async throws -> UUID {
            let conversation = UUID()
            let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                        timing: LinkTiming(startedAt: Date(), elapsed: 0)), from: phoneID)
            guard case .accepted = reply.outcome else { XCTFail("\(reply.outcome)"); throw CancellationError() }
            rig.pump(1)
            return conversation
        }
        // The Mac's stop was lost; it says it's idle (as it does every time this iPhone connects).
        let first = try await start()
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .recording, conversationID: first, startedAt: Date())), to: phoneID)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.recorder.isActive, "still recording that conversation")
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .idle)), to: phoneID)
        try await waitUntil("stopped too") { !model.recorder.isActive && !model.isFiling }
        XCTAssertEqual(model.notice, "Studio Mac stopped recording, so this iPhone stopped too.")
        XCTAssertNotNil(model.library.controller.meeting(first))

        // Gone for half an hour: this iPhone stops on its own.
        _ = try await start()
        await link.client.disconnect(from: mac.id)
        try await waitUntil("disconnected") { link.macs.first?.isConnected == false }
        model.checkLead(now: Date().addingTimeInterval(10 * 60))
        XCTAssertTrue(model.recorder.isActive)
        model.checkLead(now: Date().addingTimeInterval(31 * 60))
        try await waitUntil("stopped on its own") { !model.recorder.isActive && !model.isFiling }
        XCTAssertEqual(model.notice, "Studio Mac couldn’t be reached for 30 minutes, so this iPhone stopped recording.")
    }

    // MARK: Recovery

    func testARecordingRecoveredAfterBeingKilledStillJoinsTheMacsConversation() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        let conversation = UUID()
        let macStart = rig.clock.now().addingTimeInterval(-30)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: macStart, elapsed: 30, timelineStart: macStart),
                                                                    title: "Design review", date: macStart), from: link.deviceID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        rig.pump(1)
        model.editNotes("Budget agreed")
        rig.pump(2)
        await rig.recorder.flush()
        let folder = try XCTUnwrap(rig.recorder.stagingDirectory)
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).multipoint?.role, "macLed")
        rig.recorder.prepareForTermination()   // the process ends here

        let relaunched = PhoneAppModel(recorder: RecorderRig().recorder, library: model.library, posture: DevicePosture(),
                                       options: LaunchOptions(arguments: [], environment: [:]))
        await relaunched.launch()
        let meeting = try XCTUnwrap(model.library.controller.meeting(conversation))
        XCTAssertEqual(meeting.title, "Design review", "the Mac's conversation, as it sent it")
        XCTAssertEqual(meeting.date.timeIntervalSince1970, macStart.timeIntervalSince1970, accuracy: 0.001)
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertNil(track.offset, "a source the Mac places, as if it had stopped normally")
        XCTAssertEqual(track.alignment?.heldNoteIDs, meeting.timedNotes?.map(\.id))
        XCTAssertEqual(meeting.timedNotes?.first?.time ?? 0, 31, accuracy: 1.5)
        XCTAssertTrue(relaunched.pendingStops.isEmpty, "the Mac leads; it stops itself")
    }

    func testARecordingRecoveredAfterBeingKilledStopsTheMacItStarted() async throws {
        let mac = try await makeMac()
        let macRecorder = await recordingMac(mac)
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)
        try await model.startRecording()
        rig.pump(1)
        rig.recorder.updateLevels()
        await model.recordOnMac(mac.id)
        let conversation = try XCTUnwrap(model.recorder.captureID)
        rig.pump(1)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()

        let relaunched = PhoneAppModel(recorder: RecorderRig().recorder, library: model.library, posture: DevicePosture(),
                                       options: LaunchOptions(arguments: [], environment: [:]), link: link)
        await relaunched.launch()
        XCTAssertNil(model.library.controller.meeting(conversation)?.tracks.first?.offset, "it joins what the Mac recorded")
        // The relaunched app owes the Mac its stop, and sends it as the Mac connects.
        XCTAssertEqual(relaunched.pendingStops[mac.id], conversation)
        await link.client.disconnect(from: mac.id)
        try await link.client.connect(to: mac.id, via: mac.endpoint)
        try await waitUntil("the Mac is stopped") { relaunched.pendingStops.isEmpty }
        let recording = await macRecorder.recording
        XCTAssertNil(recording)
    }

    func testTheRecordersAMacManagesAreKnownHereWithTheirAge() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        _ = try makeModel(link: link, rig: RecorderRig())
        try await pair(link, with: mac)
        let started = Date().addingTimeInterval(-600)
        // Sent with the Mac's state, idle or not.
        try await mac.service.send(.recordingState(LinkRecordingState(phase: .idle, recorders: [
            LinkRecorderState(kind: "soundcore.work", serial: "S1", name: "Soundcore Work", isRecording: true, recordingID: "1",
                              startedAt: started, asOf: Date())])), to: link.deviceID)
        try await waitUntil("the report") { link.recorderReport(kind: "soundcore.work", serial: "S1") != nil }
        let report = try XCTUnwrap(link.recorderReport(kind: "soundcore.work", serial: "S1"))
        XCTAssertEqual(report.mac, "Studio Mac")
        XCTAssertTrue(report.state.isRecording)
        XCTAssertNil(link.recorderReport(kind: "soundcore.work", serial: "OTHER"), "another recorder")
        XCTAssertNil(link.recorderReport(kind: "soundcore.work", serial: "S1", now: Date().addingTimeInterval(21 * 60)), "too old to say")
        // Kept when the Mac goes away.
        await link.client.disconnect(from: mac.id)
        try await waitUntil("disconnected") { link.macs.first?.isConnected == false }
        XCTAssertNotNil(link.recorderReport(kind: "soundcore.work", serial: "S1"))
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

    /// A Mac paired from now on can't start the microphone here until the person allows it, asked
    /// once after pairing and changeable in that Mac's settings; the Mac hears why.
    func testANewlyPairedMacStartsRecordingOnlyOnceAllowed() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let model = try makeModel(link: link, rig: RecorderRig())
        try await pair(link, with: mac)
        let paired = try XCTUnwrap(link.macs.first)
        XCTAssertFalse(model.settings.hasMacRecordDecision(paired.id, pairedAt: paired.pairedAt), "the pairing sheet asks")

        let refused = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: link.deviceID)
        guard case .refused(let refusal) = refused.outcome else { return XCTFail("started without being allowed") }
        XCTAssertEqual(refusal.reason, .declined)
        XCTAssertEqual(refusal.message, "It hasn’t allowed this Mac to start recording. Allow it in Settings › Macs on the iPhone.")
        XCTAssertFalse(model.recorder.isActive)

        model.settings.setMacMayStartRecording(false, for: paired.id, pairedAt: paired.pairedAt)   // Not Now
        XCTAssertTrue(model.settings.hasMacRecordDecision(paired.id, pairedAt: paired.pairedAt), "asked once")
        let notNow = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: link.deviceID)
        guard case .refused = notNow.outcome else { return XCTFail("Not Now still refuses") }

        model.settings.setMacMayStartRecording(true, for: paired.id, pairedAt: paired.pairedAt)   // the Mac's row, later
        let conversation = UUID()
        let allowed = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation), from: link.deviceID)
        guard case .accepted = allowed.outcome else { return XCTFail("an allowed Mac starts recording, got \(allowed.outcome)") }
        XCTAssertEqual(model.recorder.captureID, conversation)
        let stop = try await mac.service.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: link.deviceID)
        guard case .accepted = stop.outcome else { return XCTFail("the phone stops") }
        try await waitUntil("stopped") { !model.recorder.isActive }
    }

    /// Macs paired before this iPhone started asking keep working as they did: they may start recording.
    func testMacsPairedBeforeAskingMayStillStartRecording() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LinkServicesTests-\(UUID().uuidString)"))
        defaults.set(Date().addingTimeInterval(3_600), forKey: PhoneSettings.Keys.macRecordDecisionsSince)   // pairing below predates it
        let settings = PhoneSettings(defaults: defaults)
        let mac = try await makeMac()
        let link = makeLink()
        let model = try makeModel(link: link, rig: RecorderRig(), settings: settings)
        try await pair(link, with: mac)
        let paired = try XCTUnwrap(link.macs.first)
        XCTAssertTrue(settings.hasMacRecordDecision(paired.id, pairedAt: paired.pairedAt), "never asked")
        let conversation = UUID()
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation), from: link.deviceID)
        guard case .accepted = reply.outcome else { return XCTFail("an existing pairing keeps its behavior, got \(reply.outcome)") }
        _ = try await mac.service.request(LinkRecordRequest(action: .stop, conversationID: conversation), from: link.deviceID)
        try await waitUntil("stopped") { !model.recorder.isActive }
    }

    func testAnAnswerBelongsToOnePairingAndSurvivesARelaunch() throws {
        let suite = "LinkServicesTests-\(UUID().uuidString)"
        let settings = PhoneSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let macID = UUID(), pairedAt = Date().addingTimeInterval(5)
        XCTAssertFalse(settings.macMayStartRecording(macID, pairedAt: pairedAt))
        settings.setMacMayStartRecording(true, for: macID, pairedAt: pairedAt)
        let relaunched = PhoneSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(relaunched.macRecordDecisionsSince, settings.macRecordDecisionsSince)
        XCTAssertTrue(relaunched.macMayStartRecording(macID, pairedAt: pairedAt))
        // Paired again later: asked again.
        let again = pairedAt.addingTimeInterval(60)
        XCTAssertFalse(relaunched.hasMacRecordDecision(macID, pairedAt: again))
        XCTAssertFalse(relaunched.macMayStartRecording(macID, pairedAt: again))
        relaunched.forgetMacRecordDecision(macID)
        XCTAssertFalse(relaunched.hasMacRecordDecision(macID, pairedAt: pairedAt))
    }
}
