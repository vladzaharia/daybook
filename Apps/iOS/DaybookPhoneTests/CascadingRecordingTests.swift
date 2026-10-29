import AVFoundation
import DaybookKit
import DaybookLink
import XCTest
@testable import DaybookPhone

/// Recording across devices from the iPhone's side (docs/multipoint.md, "Starting anywhere"): starting
/// here starts the connected Macs on their own and the recorder this iPhone manages; a recorder's button
/// starts this iPhone and so its Macs; stopping anywhere stops the rest; where iOS won't start the
/// microphone (the background) only the recorder records, the Macs that understand it are asked, and the
/// person is told. A Mac's notes and bookmarks show here at once and are filed as the Mac files them.
/// A `LinkService` on 127.0.0.1 stands in for the Mac, DaybookDevices' simulated recorder for Soundcore
/// Work, and synthetic audio for the microphone.
@MainActor
final class CascadingRecordingTests: XCTestCase {
    typealias Mac = LinkServicesTests.Mac

    private func makeMac(features: [String] = [LinkCapabilities.cascadeFeature, LinkCapabilities.sharedNotesFeature]) async throws -> Mac {
        let id = UUID()
        let store = MemoryLinkKeyStore()
        let service = LinkService(identity: LinkIdentity(deviceID: id, name: "Studio Mac", deviceClass: .mac, appVersion: "1.0",
                                                         canProcess: true, features: features),
                                  keyStore: store, configuration: .loopback())
        try await service.start()
        addTeardownBlock { await service.stop() }
        let listening = await service.port
        return Mac(service: service, id: id, endpoint: LinkEndpoint(host: "127.0.0.1", port: try XCTUnwrap(listening)), store: store)
    }

    private func makeLink() -> PhoneLink {
        let link = PhoneLink(identity: PhoneLink.identity(installation: UUID().uuidString, name: "Test iPhone", libraryID: nil),
                             keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        addTeardownBlock { await link.setActivity(.background) }
        return link
    }

    /// The simulated recorder, and a new transport for each connection to it.
    @MainActor
    private final class Recorder {
        let device = SimulatedSoundcore(recordings: [])
        init() {
            device.recordsInRealTime = true
            device.pace = .milliseconds(15)
        }
    }

    private func makeModel(link: PhoneLink, rig: RecorderRig, recorder: Recorder? = nil) throws -> PhoneAppModel {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: UUID().uuidString)
        let settings = PhoneSettings(defaults: UserDefaults(suiteName: "CascadingRecordingTests-\(UUID().uuidString)")!)
        var devices: PhoneDevices?
        if let recorder {
            var timing = PhoneDevices.Timing()
            timing.soundcore.request = .seconds(3)
            timing.soundcore.settle = .milliseconds(20)
            timing.soundcore.stall = .seconds(2)
            timing.soundcore.liveTail = .milliseconds(300)
            timing.soundcore.idleRelease = .seconds(600)
            timing.soundcore.automaticIdleRelease = .seconds(600)
            timing.cascade.poll = .milliseconds(20)
            let suite = "CascadingRecordingTests-devices-\(UUID().uuidString)"
            let made = PhoneDevices(library: library, settings: settings, mode: .inert, defaults: UserDefaults(suiteName: suite)!,
                                    timing: timing) { SimulatedSoundcoreTransport(device: recorder.device) }
            addTeardownBlock { made.shutDown() }
            devices = made
        }
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                  settings: settings, link: link, devices: devices)
        return model
    }

    private func pair(_ link: PhoneLink, with mac: Mac) async throws {
        await link.start()
        let code = await mac.service.beginPairing()
        _ = try await link.pair(with: mac.endpoint, code: code.digits)
        try await waitUntil("connected, with clock samples") { link.macs.first?.isConnected == true && link.macs.first?.clock != nil }
    }

    /// Add Recorder › Soundcore Work, as the person sets it up: it's this iPhone's from then on.
    private func setUpRecorder(_ model: PhoneAppModel) async throws -> DeviceSession {
        model.devices.start()
        let kind = try XCTUnwrap(DeviceCatalog.kind(SoundcoreWorkIntegration.id))
        let session = try XCTUnwrap(model.devices.beginSetup(kind))
        let soundcore = try XCTUnwrap(session.direct as? SoundcoreConnection)
        soundcore.search()
        try await waitUntil("the recorder is found") { !soundcore.discovered.isEmpty }
        soundcore.connect(to: soundcore.discovered[0])
        try await waitUntil("connected and listed") { soundcore.isInventoryCurrent }
        model.devices.commitSetup()
        return session
    }

    // MARK: Starting here

    func testStartingHereAsksTheConnectedMacOnItsOwnAndStoppingStopsIt() async throws {
        let mac = try await makeMac()
        let macRecorder = LinkServicesTests.RecordingMac()
        await mac.service.setRecordControlHandler { _, request in await macRecorder.handle(request) }
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        try await pair(link, with: mac)

        try await model.startRecording()
        rig.pump(1)
        let id = try XCTUnwrap(model.recorder.captureID)
        try await waitUntil("the Mac records too, asked on its own") { model.multipoint?.recordingMacs.map(\.id) == [mac.id] }
        let log = await macRecorder.log
        let start = try XCTUnwrap(log.first)
        XCTAssertEqual(start.conversationID, id)
        XCTAssertEqual(start.cascade?.trigger, .person)
        XCTAssertEqual(start.cascade?.requesterRecords, true)
        XCTAssertEqual(start.timing?.startedAt, model.recorder.startedAt)
        XCTAssertEqual(model.multipointLine, "Also recording on Studio Mac")
        // Asked by hand as well: it isn't asked twice.
        await model.recordOnMac(mac.id)
        let starts = await macRecorder.starts
        XCTAssertEqual(starts, 1)

        rig.pump(1)
        try await model.stopRecording()
        try await eventually("the Mac stops too") { await macRecorder.recording == nil }
    }

    func testAMacLedRecordingStoppedHereStopsTheMacButNotWhenTheMacStoppedIt() async throws {
        let mac = try await makeMac()
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        let requests = LinkServicesTests.RequestLog()
        await mac.service.setRecordControlHandler { _, request in
            requests.append(request)
            return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date()))
        }
        try await pair(link, with: mac)

        // The Mac leads; the person stops here: the Mac is asked to stop too.
        let first = UUID()
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: first, timing: LinkTiming(startedAt: Date()),
                                                                    cascade: LinkCascade(trigger: .person)), from: link.deviceID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        rig.pump(1)
        XCTAssertTrue(requests.all.isEmpty, "a Mac-led recording doesn't ask Macs back")
        try await model.stopRecording()
        try await waitUntil("the Mac is asked to stop") { requests.all.contains { $0.action == .stop && $0.conversationID == first } }

        // The Mac stops it: nothing goes back.
        let second = UUID()
        _ = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: second, timing: LinkTiming(startedAt: Date())),
                                          from: link.deviceID)
        rig.pump(1)
        _ = try await mac.service.request(LinkRecordRequest(action: .stop, conversationID: second), from: link.deviceID)
        try await waitUntil("stopped") { !model.recorder.isActive }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(requests.all.contains { $0.conversationID == second }, "the Mac's own stop isn't sent back")
    }

    // MARK: The recorder

    func testTheRecordersButtonStartsThisIPhoneAndItsMacAndItsStopStopsThem() async throws {
        let mac = try await makeMac()
        let macRecorder = LinkServicesTests.RecordingMac()
        await mac.service.setRecordControlHandler { _, request in await macRecorder.handle(request) }
        let link = makeLink()
        let rig = RecorderRig()
        let recorder = Recorder()
        let model = try makeModel(link: link, rig: rig, recorder: recorder)
        let session = try await setUpRecorder(model)
        try await pair(link, with: mac)

        recorder.device.pressButton()
        try await waitUntil("this iPhone records too") { model.recorder.isActive }
        rig.pump(1)
        let id = try XCTUnwrap(model.recorder.captureID)
        let member = try await waitFor("the recorder records along, leading") { model.devices.cascade.member(session.id) }
        XCTAssertEqual(member.role, .led)
        try await waitUntil("its audio is saved here as it records") { session.liveCaptureConversation == id }
        try await eventually("the Mac records too") { await macRecorder.recording == id }
        let start = await macRecorder.log.first
        XCTAssertEqual(start?.cascade?.trigger, .recorder)
        XCTAssertFalse(recorder.device.received.contains { $0.type == 0x18 && $0.command == 0x82 }, "Daybook sent the recorder no Start")
        try await Task.sleep(for: .milliseconds(300))

        // Its button stops it: this iPhone stops, and the Mac.
        recorder.device.pressButton()
        try await waitUntil("this iPhone stops") { !model.recorder.isActive && !model.isFiling }
        XCTAssertEqual(model.notice, "Soundcore Work stopped recording, so this iPhone stopped too.")
        try await eventually("the Mac stops") { await macRecorder.recording == nil }
        try await waitUntil("its audio, and then its file, are in the conversation", timeout: 15) {
            let tracks = model.library.controller.meeting(id)?.tracks ?? []
            return tracks.contains { $0.deviceKind == SoundcoreWorkIntegration.id } && tracks.contains { $0.deviceKind == PhoneDevice.kind }
        }
        let meeting = try XCTUnwrap(model.library.controller.meeting(id))
        XCTAssertNil(meeting.tracks.first { $0.deviceKind == PhoneDevice.kind }?.offset, "the Mac recorded too: placed against its recording")
        XCTAssertEqual(model.library.conversations.count, 1, "one conversation")
    }

    /// iOS doesn't let an app start the microphone from the background (AVAudioSession's
    /// `cannotStartRecording`): the recorder's audio is saved here as it records, the person is told,
    /// Macs that understand it are asked with this iPhone saying it doesn't record itself, and opening
    /// Daybook records here too.
    func testInTheBackgroundOnlyTheRecorderRecordsThePersonIsToldAndOpeningDaybookJoins() async throws {
        let mac = try await makeMac()
        let macRecorder = LinkServicesTests.RecordingMac()
        await mac.service.setRecordControlHandler { _, request in await macRecorder.handle(request) }
        let inbox = LinkServicesTests.MacInbox(mac.service.events())
        let link = makeLink()
        let rig = RecorderRig()
        let recorder = Recorder()
        let model = try makeModel(link: link, rig: rig, recorder: recorder)
        var posted: [String] = [], removed: [String] = []
        model.cascadeNotices = CascadeNotices(post: { _, title, _ in posted.append(title) }, remove: { removed.append($0) })
        let session = try await setUpRecorder(model)
        try await pair(link, with: mac)
        model.scenePhaseChanged(.background)
        rig.session.activationError = NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue))   // '!rec'

        recorder.device.pressButton()
        let only = try await waitFor("only the recorder records") { model.recorderOnly }
        XCTAssertFalse(model.recorder.isActive, "never a microphone open in the background")
        XCTAssertEqual(only.recorderID, session.id)
        XCTAssertEqual(posted, ["Soundcore Work is recording"], "the person is told")
        // In the app, over Record (which records on this iPhone too, into the same conversation).
        XCTAssertEqual(RecorderOnlyLine.text(only.recorderName), "Soundcore Work is recording. This iPhone isn’t.")
        try await waitUntil("its audio is saved here as it records") { session.liveCaptureConversation == only.conversationID }
        try await eventually("the Mac is asked, with the link back up", timeout: 15) { await macRecorder.recording == only.conversationID }
        let start = await macRecorder.log.first
        XCTAssertEqual(start?.cascade?.requesterRecords, false, "this iPhone doesn't record itself")
        try await waitUntil("its state says so") { inbox.states.contains { $0.sharedConversationID == only.conversationID } }

        // The person opens Daybook: this iPhone records the same conversation now.
        rig.session.activationError = nil
        model.scenePhaseChanged(.active)
        try await waitUntil("recording here too") { model.recorder.captureID == only.conversationID }
        XCTAssertNil(model.recorderOnly)
        XCTAssertEqual(removed, [CascadeNotices.recorderRecording])
        rig.pump(1)
        try await model.stopRecording()
        try await eventually("the Mac stops") { await macRecorder.recording == nil }
        try await waitUntil("the recorder stops with it") { !recorder.device.isRecording }
    }

    func testOneThatStopsWhileOnlyTheRecorderRecordsEndsItAndStopsTheMac() async throws {
        let mac = try await makeMac()
        let macRecorder = LinkServicesTests.RecordingMac()
        await mac.service.setRecordControlHandler { _, request in await macRecorder.handle(request) }
        let link = makeLink()
        let rig = RecorderRig()
        let recorder = Recorder()
        let model = try makeModel(link: link, rig: rig, recorder: recorder)
        var removed: [String] = []
        model.cascadeNotices = CascadeNotices(post: { _, _, _ in }, remove: { removed.append($0) })
        let session = try await setUpRecorder(model)
        try await pair(link, with: mac)
        rig.session.activationError = NSError(domain: NSOSStatusErrorDomain, code: Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue))
        recorder.device.pressButton()
        let only = try await waitFor("only the recorder records") { model.recorderOnly }
        try await eventually("the Mac records") { await macRecorder.recording == only.conversationID }
        try await waitUntil("its audio") { session.liveCaptureConversation == only.conversationID }
        try await Task.sleep(for: .milliseconds(300))

        recorder.device.pressButton()
        try await waitUntil("it ends") { model.recorderOnly == nil }
        try await eventually("the Mac stops") { await macRecorder.recording == nil }
        XCTAssertEqual(removed, [CascadeNotices.recorderRecording])
        try await waitUntil("the recorder's audio is in the conversation", timeout: 10) {
            model.library.controller.meeting(only.conversationID)?.tracks.contains { $0.deviceKind == SoundcoreWorkIntegration.id } == true
        }
        XCTAssertEqual(model.library.controller.meeting(only.conversationID)?.status, .imported, "this iPhone's own conversation")
    }

    // MARK: Notes and bookmarks

    func testAMacsNotesAndBookmarksShowHereAndAreFiledAsTheMacFilesThem() async throws {
        let mac = try await makeMac()
        let inbox = LinkServicesTests.MacInbox(mac.service.events())
        let link = makeLink()
        let rig = RecorderRig()
        let model = try makeModel(link: link, rig: rig)
        await mac.service.setRecordControlHandler { _, request in
            .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date()))
        }
        try await pair(link, with: mac)
        let conversation = UUID()
        // The rig's clock stands in for this iPhone's (and, over loopback, the Mac's).
        let macStart = rig.clock.now().addingTimeInterval(-60)
        let reply = try await mac.service.request(LinkRecordRequest(action: .start, conversationID: conversation,
                                                                    timing: LinkTiming(startedAt: macStart, elapsed: 60, timelineStart: macStart),
                                                                    title: "Design review", date: macStart), from: link.deviceID)
        guard case .accepted = reply.outcome else { return XCTFail("\(reply.outcome)") }
        rig.pump(2)
        rig.recorder.updateLevels()

        // The Mac writes a paragraph and marks a moment: here at once.
        let macNote = LinkNote(id: UUID(), conversationID: conversation, text: "Mac: decide the launch date", time: 61,
                               madeAt: rig.clock.now(), changedAt: Date())
        try await mac.service.send(.note(macNote), to: link.deviceID)
        try await waitUntil("the Mac's paragraph") { model.recorder.notes.contains("decide the launch date") }
        let mark = LinkBookmark(conversationID: conversation, recordingTime: 62, createdAt: rig.clock.now())
        try await mac.service.send(.bookmark(mark), to: link.deviceID)
        try await waitUntil("the Mac's bookmark") { model.recorder.highlights.contains { $0.id == mark.id } }
        XCTAssertLessThan(model.recorder.highlights.first { $0.id == mark.id }?.time ?? 99, 10, "at its moment in this recording")

        // Written here: on the Mac at once, with the time this iPhone files it; the Mac's isn't sent back.
        model.editNotes(model.recorder.notes + "\nPhone: Priya owns the checklist")
        try await waitUntil("the phone's paragraph reaches the Mac") { inbox.notes.contains { $0.text == "Phone: Priya owns the checklist" } }
        XCTAssertFalse(inbox.notes.contains { $0.id == macNote.id }, "never echoed")
        let sent = try XCTUnwrap(inbox.notes.first)
        XCTAssertEqual(sent.time ?? 0, 60 + 2, accuracy: 1.5, "this recording's time on the Mac's timeline")

        // The Mac deletes its bookmark; it goes here too.
        try await mac.service.send(.bookmarkChange(LinkBookmarkChange(id: mark.id, conversationID: conversation, deleted: true)), to: link.deviceID)
        try await waitUntil("the deleted bookmark goes") { !model.recorder.highlights.contains { $0.id == mark.id } }

        rig.pump(1)
        try await model.stopRecording()
        let meeting = try XCTUnwrap(model.library.controller.meeting(conversation))
        let filed = try XCTUnwrap(meeting.timedNotes?.first { $0.id == macNote.id })
        XCTAssertEqual(filed.time, 61, "as the Mac files it")
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertFalse(track.alignment?.heldNoteIDs?.contains(macNote.id) ?? false, "not held by this recording")
        XCTAssertTrue(track.alignment?.heldNoteIDs?.contains(sent.id) ?? false, "this iPhone's own is")
        XCTAssertEqual(meeting.timedNotes?.first { $0.id == sent.id }?.time ?? 0, sent.time ?? -1, accuracy: 0.001,
                       "filed at the time the Mac was told")
    }
}

extension CascadingRecordingTests {
    /// Polls a condition that awaits (the Mac's actor) until it holds.
    func eventually(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () async -> Bool) async throws {
        let limit = TestTiming.scaled(timeout)
        let deadline = ContinuousClock.now + .seconds(limit)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitTimeout(what, after: limit, file: file, line: line, lastState: nil) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private extension LinkServicesTests.MacInbox {
    var notes: [LinkNote] {
        all.compactMap { if case .received(.note(let note), _) = $0 { return note } else { return nil } }
    }
}
