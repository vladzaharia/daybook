import Combine
import CryptoKit
import DaybookCore
import DaybookDevices
import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Handing Soundcore Work between a Mac and an iPhone (docs/devices.md, "Handing a recorder over"):
/// two libraries syncing through a temporary folder, two device hubs reaching for one simulated
/// recorder that talks to one device at a time, and DaybookLink over loopback. No Bluetooth, no
/// network beyond 127.0.0.1, no microphone.
@MainActor
final class RecorderHandoffTests: XCTestCase {
    private var root: URL!
    private var cloud: URL!
    private var sides: [Side] = []
    private var links: [LinkPair] = []
    private let base = UInt32(Date().timeIntervalSince1970) - 50_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookHandoff-\(UUID().uuidString)", isDirectory: true)
        cloud = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for pair in links { await pair.tearDown() }
        for side in sides { side.hub.shutDown(); side.library.sync?.disconnect() }
        links = []
        sides = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Tests

    /// No sync pass between asking and connecting: the link alone moves it. (How fast is the link's
    /// business, not this test's; a starved machine is slow and still correct.)
    func testOverTheLinkTheRecorderMovesWithoutWaitingForSync() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        XCTAssertEqual(phone.session.managedElsewhere?.ownerID, mac.id, "the phone knows the Mac manages it")
        try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        XCTAssertEqual(phone.handoff.state(of: phone.session), .asking(owner: "Studio Mac"))
        try await waitUntil("the phone connects") { phone.session.isLinked }

        XCTAssertFalse(mac.session.isLinked, "the Mac let go")
        XCTAssertEqual(mac.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id, "the Mac recorded the new owner")
        XCTAssertEqual(phone.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id)
        XCTAssertEqual(mac.session.managedElsewhere?.ownerName, "Alex’s iPhone")
        XCTAssertNil(phone.session.managedElsewhere)
        XCTAssertEqual(recorder.connectionLog, [mac.transport.peripheralLogID, phone.transport.peripheralLogID],
                       "one device at a time: the Mac, then the phone")
        try await waitUntil("“Now on this iPhone”") { if case .done = phone.handoff.state(of: phone.session) { return true }; return false }

        // The record that travelled with it is cleared once both have synced.
        try await syncAll(mac, phone, phone, mac)
        XCTAssertNil(mac.library.recorderHandoff(kind: kind, serial: recorder.serial))
        XCTAssertNil(phone.library.recorderHandoff(kind: kind, serial: recorder.serial))
        XCTAssertEqual(mac.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id)
    }

    func testTheOtherDeviceCanRefuseWithAReason() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        // Meanwhile, as far as the Mac knows, another Mac took the recorder over.
        mac.library.claimRecorder(kind: kind, serial: recorder.serial, deviceClass: .mac,
                                  by: ProcessingRequest.Device(id: "office-imac", name: "Office iMac"))
        try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        try await waitUntil("the refusal") { if case .refused = phone.handoff.state(of: phone.session) { return true }; return false }
        guard case .refused(let by, let message) = phone.handoff.state(of: phone.session) else { return XCTFail() }
        XCTAssertEqual(by, "Studio Mac")
        XCTAssertEqual(message, "Studio Mac doesn’t manage Soundcore Work; Office iMac does.")
        XCTAssertFalse(phone.session.isLinked, "a refusal changes nothing here")
        XCTAssertEqual(phone.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, mac.id)

        // Offering it to a device that doesn't have it set up is refused too.
        let stranger = try await makeSide("Stranger", .phone, recorder, setUp: false)
        let peer = RecorderHandoff.Peer(linkID: UUID(), syncID: stranger.id, name: "Stranger", deviceClass: .phone, handsOffRecorders: true)
        mac.handoff.link = RecorderHandoff.Link(peers: { [peer] }, send: { message, _ in
            if case .recorderHandoffRequest(let request) = message {
                // Delivered by hand: the stranger answers through its own coordinator.
                stranger.handoff.link = RecorderHandoff.Link(peers: { [] }, send: { reply, _ in mac.handoff.receive(reply, from: peer.linkID) })
                stranger.handoff.receive(.recorderHandoffRequest(request), from: UUID())
            }
        })
        mac.library.claimRecorder(kind: kind, serial: recorder.serial, deviceClass: .mac)
        mac.handoff.give(mac.session, to: peer)
        try await waitUntil("the offer is refused") { if case .refused = mac.handoff.state(of: mac.session) { return true }; return false }
        guard case .refused(_, let why) = mac.handoff.state(of: mac.session) else { return XCTFail() }
        XCTAssertEqual(why, "Soundcore Work isn’t set up on Stranger. Add it there first.")
        XCTAssertEqual(mac.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, mac.id, "the Mac keeps it")
    }

    func testWithNoAnswerItWaitsHonestlyThenTakesOverAnyway() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)

        // No link: the request goes through sync, and the page says so.
        phone.handoff.useHere(phone.session)
        guard case .waitingForSync(let owner, _) = phone.handoff.state(of: phone.session) else {
            return XCTFail("\(phone.handoff.state(of: phone.session))")
        }
        XCTAssertEqual(owner, "Studio Mac")
        XCTAssertEqual(RecorderHandoff.Words.headline(phone.handoff.state(of: phone.session), recorder: "Soundcore Work", here: "this iPhone"),
                       "Waiting for Studio Mac to let go…")
        XCTAssertEqual(phone.library.recorderHandoff(kind: kind, serial: recorder.serial)?.phase, .requested)
        // Patience is measured from the request, at whatever moment the page looks.
        let waiting = phone.handoff.state(of: phone.session)
        guard case .waitingForSync(_, let since) = waiting else { return XCTFail("\(waiting)") }
        XCTAssertFalse(phone.handoff.isOverdue(waiting, now: since.addingTimeInterval(Self.handoffTiming.patience - 0.05)))
        XCTAssertTrue(phone.handoff.isOverdue(waiting, now: since.addingTimeInterval(Self.handoffTiming.patience + 0.05)),
                      "after its patience runs out it says it hasn't heard")

        // Take Over Anyway while the Mac is still connected: the recorder doesn't answer here yet.
        phone.handoff.takeOverAnyway(phone.session)
        XCTAssertEqual(phone.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id)
        XCTAssertNil(phone.library.recorderHandoff(kind: kind, serial: recorder.serial), "the request is withdrawn")
        guard case .connecting = phone.handoff.state(of: phone.session) else { return XCTFail("\(phone.handoff.state(of: phone.session))") }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(phone.session.isLinked, "while the Mac is connected, the recorder doesn't answer the phone")
        XCTAssertTrue(mac.session.isLinked)

        // The Mac hears at its next sync and lets go; the phone, still trying, gets it.
        try await syncAll(phone, mac)
        try await waitUntil("the phone connects once the Mac lets go") { phone.session.isLinked }
        XCTAssertFalse(mac.session.isLinked)
        XCTAssertEqual(mac.session.managedElsewhere?.ownerID, phone.id)
    }

    func testThroughSyncAloneTheOwnerLetsGoAtItsNextPass() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)

        phone.handoff.useHere(phone.session)
        try await syncAll(phone, mac)
        // The Mac answered in the record, let go, and recorded the phone as the owner.
        try await waitUntil("the Mac lets go") { !mac.session.isLinked }
        XCTAssertEqual(mac.library.recorderHandoff(kind: kind, serial: recorder.serial)?.phase, .released)
        XCTAssertEqual(mac.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id)

        try await syncAll(mac, phone)
        try await waitUntil("the phone connects") { phone.session.isLinked }
        XCTAssertEqual(phone.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, phone.id)
        try await syncAll(phone, mac)
        XCTAssertNil(mac.library.recorderHandoff(kind: kind, serial: recorder.serial), "cleared on both once it's done")
        XCTAssertNil(phone.library.recorderHandoff(kind: kind, serial: recorder.serial))
    }

    func testATransferFinishesOnTheOldOwnerAndWaitingImportsContinueOnTheNewOne() async throws {
        // Only the Mac's transfer needs to take a while (it must still be running when the phone
        // asks); the two that continue on the phone are short and unpaced.
        let recorder = makeRecorder(count: 3, seconds: 1, oldestSeconds: 6)
        recorder.pace = .milliseconds(12)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        try await link(mac, phone)

        // The Mac imports all three, oldest first; the first is under way when the phone asks.
        try await waitUntil("the Mac lists the recordings") { mac.session.newRecordings.count == 3 }
        let ids = mac.session.newRecordings.sorted { $0.id < $1.id }.map(\.id)
        mac.session.importRecordings(mac.session.newRecordings, automatic: true)
        try await waitUntil("the first transfer is under way") { mac.session.queue.current != nil && (mac.session.phase?.fraction ?? 0) > 0 }
        let first = try XCTUnwrap(mac.session.queue.current?.id)
        XCTAssertEqual(first, ids[0])
        // A transfer keeps the pace it started with.
        recorder.pace = nil

        phone.handoff.useHere(phone.session)
        try await waitUntil("the Mac says it's finishing an import") {
            if case .ownerFinishing(_, .importing?) = phone.handoff.state(of: phone.session) { return true }; return false
        }
        XCTAssertEqual(mac.session.isHandingOff, true)
        try await waitUntil("the phone connects", timeout: 20,
                            state: { "\(phone.handoff.state(of: phone.session)); Mac imported \(mac.imported.map(\.recordingID))" }) {
            phone.session.isLinked
        }
        try await waitUntil("the phone imports what was waiting", timeout: 20,
                            state: { "imported \(phone.imported.map(\.recordingID)), queue \(phone.session.queue)" }) {
            phone.imported.count == 2
        }

        XCTAssertEqual(mac.imported.map(\.recordingID), [first], "the transfer in progress finished on the Mac, and nothing else started there")
        XCTAssertEqual(Set(phone.imported.map(\.recordingID)), Set(ids.dropFirst()), "the rest continued on the phone")
        XCTAssertFalse(phone.imported.contains { $0.recordingID == first }, "the Mac's transfer wasn't started again")
        XCTAssertTrue(mac.session.queue.waiting.isEmpty)

        // After sync, each recording is in exactly one conversation, on both devices.
        try await syncAll(mac, phone, mac)
        for library in [mac.library, phone.library] {
            for id in ids {
                let holding = library.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == id } }
                XCTAssertEqual(holding.count, 1, "\(id) in \(holding.count) conversations")
            }
        }
    }

    func testWhatTheOldOwnerImportedIsNotImportedAgain() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        try await macStartsManaging(mac)
        try await waitUntil("listed") { mac.session.newRecordings.count == 1 }
        let id = mac.session.newRecordings[0].id
        mac.session.importRecordings(mac.session.newRecordings, automatic: true)
        try await waitUntil("the Mac imported it") { mac.imported.count == 1 }
        // The phone imports every recording automatically, so without the handoff's word it would
        // take this one too. It knows the Mac manages the recorder from a sync before the import:
        // the conversation itself hasn't reached it yet.
        let phone = try await makeSide("Phone", .phone, recorder, automatic: true, knownOwner: mac)
        try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked }
        try await waitUntil("listed on the phone") { phone.session.direct?.inventoryUpdatedAt != nil && phone.session.direct?.isRefreshing == false }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(phone.imported.count, 0, "what the Mac imported is on its way through sync, not imported again")
        XCTAssertNotNil(phone.session.arrivingThroughSync[id])
        XCTAssertTrue(phone.session.newRecordings.isEmpty, "and it isn't offered as new meanwhile")

        // Sync brings the Mac's conversation; the library's device identity takes over from there.
        try await syncAll(mac, phone)
        try await waitUntil("the phone's library knows it") { phone.session.links.imported[id] != nil }
        XCTAssertNil(phone.session.arrivingThroughSync[id])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(phone.imported.count, 0)
        XCTAssertEqual(phone.library.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == id } }.count, 1)
    }

    func testARecordingBothDevicesImportBeforeSyncEndsUpInOneConversation() async throws {
        let recorder = makeRecorder(count: 1, seconds: 10)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        // Nobody manages it yet (an older build, or before ownership arrived): the phone imports it.
        phone.session.connect()
        try await waitUntil("the phone lists it") { phone.session.direct?.isInventoryCurrent == true && phone.session.newRecordings.count == 1 }
        let id = phone.session.newRecordings[0].id
        phone.session.importRecordings(phone.session.newRecordings)
        try await waitUntil("the phone imported it", timeout: 20) { phone.imported.count == 1 && !phone.session.queue.isActive }
        phone.session.disconnect(.direct)
        try await syncAll(phone)

        // The Mac hasn't synced since, so it imports it too; the phone's conversation arrives mid-transfer.
        recorder.pace = .milliseconds(15)
        mac.session.connect()
        try await waitUntil("the Mac lists it") { mac.session.direct?.isInventoryCurrent == true && mac.session.newRecordings.count == 1 }
        mac.session.importRecordings(mac.session.newRecordings)
        try await waitUntil("the Mac's transfer") { (mac.session.phase?.fraction ?? 0) > 0 }
        try await syncAll(mac)
        XCTAssertTrue(mac.session.queue.current != nil, "still transferring when the phone's import arrived")
        try await waitUntil("the Mac's transfer to end", timeout: 20) { !mac.session.queue.isActive }
        XCTAssertTrue(mac.imported.isEmpty, "the Mac keeps the phone's import instead of a second conversation")
        XCTAssertTrue(mac.session.failures.isEmpty)

        try await syncAll(mac, phone)
        for library in [mac.library, phone.library] {
            XCTAssertEqual(library.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == id } }.count, 1)
        }
    }

    func testARecordingKeepsGoingAndRecordControlMovesWithOwnership() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        mac.connection.startRecording()
        try await waitUntil("the recorder records") { recorder.isRecording && mac.session.status?.isRecording == true }
        try await syncAll(mac, phone)
        try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked }
        XCTAssertTrue(recorder.isRecording, "letting go doesn't stop the recorder")
        try await waitUntil("the phone sees it recording") { phone.session.status?.isRecording == true }

        mac.connection.pauseRecording()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.isRecording, "the Mac no longer controls it")
        phone.connection.pauseRecording()
        try await waitUntil("the phone stops it") { !recorder.isRecording }
    }

    func testARecordingHandedOverMidRecordingGoesIntoTheConversationWaitingForIt() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        // A Mac recording asked the recorder to record too (multipoint), and waits for its recording.
        mac.connection.startRecording()
        try await waitUntil("the recorder records") { mac.session.split.inProgress != nil && !mac.connection.recordCommandPending }
        let id = try XCTUnwrap(mac.session.split.inProgress?.id)
        let conversation = mac.library.newMeeting(title: "Design review")
        var companion = CompanionRecording(deviceID: mac.session.id, deviceKind: kind, deviceSerial: recorder.serial, deviceName: "Soundcore Work",
                                           macStartedAt: Date(), state: .recording, startedByDaybook: true)
        companion.recordingID = id
        mac.library.update(conversation) { $0.companions = [companion] }
        try await syncAll(mac, phone)
        try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked && phone.session.direct?.isInventoryCurrent == true }
        XCTAssertEqual(mac.library.recorderHandoff(kind: kind, serial: recorder.serial)?.recordingInProgress?.recordingID, id,
                       "the synced record names it too")
        XCTAssertEqual(mac.library.recorderHandoff(kind: kind, serial: recorder.serial)?.recordingInProgress?.attachTo, conversation)
        XCTAssertEqual(phone.session.split.inProgress?.id, id)
        XCTAssertEqual(phone.session.conversationWaiting(for: id), conversation, "the phone knows which conversation waits for it")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(phone.imported.isEmpty, "nothing imports while it's still recording")

        // Stopped on the phone, it's imported into that conversation, not a new one.
        phone.connection.pauseRecording()
        try await waitUntil("its import", timeout: 15) { phone.imported.map(\.recordingID) == [id] }
        let holding = phone.library.meetings.filter { $0.tracks.contains { $0.deviceRecordingID == id } }
        XCTAssertEqual(holding.map(\.id), [conversation])
    }

    // MARK: A recording handed over mid-recording, its Mac out of reach

    /// Handed to the phone while the Mac's recording had it record too, the recorder stops when the Mac's
    /// recording ends although the phone isn't on the link any more: the Mac's presence stops naming the
    /// conversation. Its recording is then imported.
    func testARecordingHandedOverStopsWhenTheMacsRecordingEndsOutOfReach() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder, presence: true)
        let phone = try await makeSide("Phone", .phone, recorder, presence: true)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        // The Mac's conversation isn't synced while it records; only its presence says what it records.
        let (conversation, id) = try await macRecordsAlong(mac, recorder)
        let pair = try await link(mac, phone)

        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked && phone.session.direct?.isInventoryCurrent == true }
        XCTAssertEqual(phone.handoff.followed.map(\.recordingID), [id], "Daybook started it for the Mac's recording, which hasn't ended")
        XCTAssertEqual(phone.handoff.followed.first?.conversationID, conversation)
        try await waitUntil("the phone sees the Mac recording it") { phone.handoff.followed.first?.seenRecordingAt != nil }
        XCTAssertEqual(phone.handoff.followed.first?.recordingDevice, mac.id)
        let kept = try XCTUnwrap(phone.defaults.data(forKey: "recorderHandoff.following"))
        XCTAssertEqual(try JSONDecoder().decode([RecorderHandoff.FollowedRecording].self, from: kept).map(\.recordingID), [id],
                       "kept across relaunches")

        // The link goes; then the Mac stops recording.
        await pair.tearDown()
        try await waitUntil("the link is gone") { pair.phoneEnd.peers.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.isRecording, "nothing stops it while the Mac records")
        macRecordingEnds(mac, conversation)

        try await waitUntil("the phone stops the recorder", timeout: 15) { !recorder.isRecording }
        try await waitUntil("its recording is imported", timeout: 15) { phone.imported.map(\.recordingID) == [id] }
        try await waitUntil("it's no longer followed") { phone.handoff.followed.isEmpty }
        XCTAssertNil(phone.defaults.data(forKey: "recorderHandoff.following"))
    }

    /// Without presence (a Mac whose presence never arrives), the conversation arriving through sync
    /// with the Mac's recording of it ended stops the recorder, and its recording goes into it.
    func testARecordingHandedOverStopsWhenTheConversationArrivesEnded() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        let (conversation, id) = try await macRecordsAlong(mac, recorder)
        let pair = try await link(mac, phone)
        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked && phone.session.direct?.isInventoryCurrent == true }
        await pair.tearDown()
        try await waitUntil("the link is gone") { pair.phoneEnd.peers.isEmpty }
        await phone.handoff.checkFollowed()
        XCTAssertEqual(phone.handoff.followed.map(\.recordingID), [id], "nothing says the Mac's recording ended")
        XCTAssertTrue(recorder.isRecording)

        // The Mac files its recording; the conversation syncs, its link to the recorder ended.
        macRecordingEnds(mac, conversation)
        try await syncAll(mac, phone)
        try await waitUntil("the phone stops the recorder", timeout: 15) { !recorder.isRecording }
        try await waitUntil("its recording joins the conversation", timeout: 15) {
            phone.library.meeting(conversation)?.tracks.contains { $0.deviceRecordingID == id } == true
        }
        try await waitUntil("it's no longer followed") { phone.handoff.followed.isEmpty }
    }

    /// Only a recording Daybook started for the conversation is stopped: not one the recorder was making
    /// already, and not one the person started on it since.
    func testOnlyTheRecordingDaybookStartedIsStopped() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder, presence: true)
        let phone = try await makeSide("Phone", .phone, recorder, presence: true)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        // It was recording before the Mac's recording began.
        let (alreadyRecording, _) = try await macRecordsAlong(mac, recorder, startedByDaybook: false)
        var pair = try await link(mac, phone)
        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone connects") { phone.session.isLinked && phone.session.direct?.isInventoryCurrent == true }
        XCTAssertTrue(phone.handoff.followed.isEmpty, "Daybook didn't start it, so it doesn't stop it")
        await pair.tearDown()
        macRecordingEnds(mac, alreadyRecording)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(recorder.isRecording)

        // Back to the Mac, which starts it for a new recording; then to the phone again.
        phone.connection.pauseRecording()
        try await waitUntil("stopped") { !recorder.isRecording }
        try await syncAll(phone, mac)
        pair = try await link(mac, phone)
        mac.handoff.useHere(mac.session)
        try await waitUntil("on the Mac") { mac.session.isLinked && mac.session.direct?.isInventoryCurrent == true }
        let (conversation, id) = try await macRecordsAlong(mac, recorder)
        phone.handoff.useHere(phone.session)
        try await waitUntil("on the phone") { phone.session.isLinked && phone.session.direct?.isInventoryCurrent == true }
        XCTAssertEqual(phone.handoff.followed.map(\.recordingID), [id])
        try await waitUntil("the phone sees the Mac recording it") { phone.handoff.followed.first?.seenRecordingAt != nil }
        await pair.tearDown()
        // The person stops it on the phone and starts another (a second later: the recorder names a
        // recording by the second it started).
        phone.connection.pauseRecording()
        try await waitUntil("stopped") { !recorder.isRecording && !phone.connection.recordCommandPending }
        try await Task.sleep(for: .milliseconds(1_100))
        phone.connection.startRecording()
        try await waitUntil("recording again") { recorder.isRecording && phone.session.split.inProgress.map { $0.id != id } == true }
        macRecordingEnds(mac, conversation)
        try await waitUntil("the phone lets it be", timeout: 15) { phone.handoff.followed.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(recorder.isRecording, "the person's recording keeps going")
    }

    /// A Mac whose presence goes quiet while it records (it crashed, say) is given up on after a while:
    /// the recorder is left to the person.
    func testFollowingEndsWhenTheMacsPresenceGoesStale() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder, presence: true)
        let phone = try await makeSide("Phone", .phone, recorder, presence: true)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        _ = try await macRecordsAlong(mac, recorder)
        let pair = try await link(mac, phone)
        phone.handoff.useHere(phone.session)
        try await waitUntil("the phone sees the Mac recording it") { phone.handoff.followed.first?.seenRecordingAt != nil }
        await pair.tearDown()
        let staleness = phone.handoff.timing.followStaleness
        await phone.handoff.checkFollowed(now: Date().addingTimeInterval(staleness / 2))
        XCTAssertFalse(phone.handoff.followed.isEmpty, "not yet")
        await phone.handoff.checkFollowed(now: Date().addingTimeInterval(staleness + 60))
        XCTAssertTrue(phone.handoff.followed.isEmpty, "its presence is too old to believe")
        XCTAssertTrue(recorder.isRecording, "left to the person")
    }

    func testOfferingItAndHandingItBackWhenTheMacArrives() async throws {
        let recorder = makeRecorder(count: 1)
        let mac = try await makeSide("Mac", .mac, recorder)
        let phone = try await makeSide("Phone", .phone, recorder)
        try await macStartsManaging(mac)
        try await syncAll(mac, phone)
        let pair = try await link(mac, phone)
        phone.handoff.peersChanged()

        // "Use on This iPhone", then the phone offers it back: "Use on Studio Mac".
        phone.handoff.useHere(phone.session)
        try await waitUntil("on the phone") { phone.session.isLinked }
        let macPeer = try XCTUnwrap(phone.handoff.peersToGive(phone.session).first)
        XCTAssertEqual(macPeer.name, "Studio Mac")
        XCTAssertTrue(mac.handoff.peersToGive(mac.session).isEmpty, "only the device managing it offers it")
        phone.handoff.give(phone.session, to: macPeer)
        try await waitUntil("back on the Mac") { mac.session.isLinked }
        XCTAssertFalse(phone.session.isLinked)
        XCTAssertEqual(phone.library.recorderOwner(kind: kind, serial: recorder.serial)?.ownerID, mac.id)

        // Hand-back: the phone takes it, the Mac goes away and comes back, and it goes back.
        phone.handoff.handsBackAutomatically = true
        phone.handoff.useHere(phone.session)
        try await waitUntil("on the phone again") { phone.session.isLinked }
        phone.handoff.peersChanged()
        XCTAssertTrue(phone.session.isLinked, "a Mac that's already here doesn't take it back")
        await pair.client.disconnect(from: pair.macID)
        try await waitUntil("the Mac left") { pair.phoneEnd.peers.isEmpty }
        phone.handoff.peersChanged()
        try await pair.client.connect(to: pair.macID, via: pair.endpoint)
        try await waitUntil("the Mac is back") { !pair.phoneEnd.peers.isEmpty }
        phone.handoff.peersChanged()
        try await waitUntil("handed back to the Mac") { mac.session.isLinked }
        XCTAssertFalse(phone.session.isLinked)
    }

    // MARK: Harness

    private let kind = SoundcoreWorkIntegration.id

    /// `count` recordings an hour apart, the newest first; the oldest, imported first, can be longer.
    private func makeRecorder(count: Int, seconds: Double = 1, oldestSeconds: Double? = nil) -> SimulatedSoundcore {
        let frames = SimulatedSoundcore.frames(seconds: seconds)
        let oldest = oldestSeconds.map { SimulatedSoundcore.frames(seconds: $0) } ?? frames
        return SimulatedSoundcore(recordings: (0..<count).map {
            .init(id: base - UInt32($0) * 3_600, frames: $0 == count - 1 ? oldest : frames)
        })
    }

    /// One device: its library (syncing through the shared folder), its hub with the recorder set
    /// up, and its handoff coordinator.
    @MainActor
    final class Side {
        let name: String
        let library: LibraryController
        let hub: DeviceHub
        let session: DeviceSession
        let connection: SoundcoreConnection
        let transport: SimulatedSoundcoreTransport
        let handoff: RecorderHandoff
        let defaults: UserDefaults
        var imported: [DeviceRecordingIdentity] = []
        var subscriptions: Set<AnyCancellable> = []
        var id: String { library.thisDevice.id }

        init(name: String, library: LibraryController, hub: DeviceHub, session: DeviceSession, connection: SoundcoreConnection,
             transport: SimulatedSoundcoreTransport, handoff: RecorderHandoff, defaults: UserDefaults) {
            self.name = name; self.library = library; self.hub = hub; self.session = session
            self.connection = connection; self.transport = transport; self.handoff = handoff; self.defaults = defaults
        }
    }

    /// `presence`: its sync replica writes a presence record (what it's recording), as the apps' do.
    private func makeSide(_ name: String, _ deviceClass: SyncDeviceClass, _ recorder: SimulatedSoundcore,
                          automatic: Bool = false, setUp: Bool = true, knownOwner: Side? = nil, presence: Bool = false) async throws -> Side {
        let defaults = makeTestDefaults("daybook.handoff.\(name)")
        let local = root.appendingPathComponent(name, isDirectory: true)
        let staging = root.appendingPathComponent("\(name)-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sync = LibrarySyncController(localRoot: local, defaults: defaults)
        if presence {
            sync.replica.device = SyncDeviceIdentity(deviceClass: deviceClass, displayName: deviceClass == .mac ? "Studio Mac" : "Alex’s iPhone",
                                                     canProcess: deviceClass == .mac)
        }
        try sync.connect(to: cloud, monitorChanges: false)
        let library = LibraryController(rootURL: local, sync: sync)
        try await library.load()
        if let knownOwner {
            library.claimRecorder(kind: kind, serial: recorder.serial, deviceClass: .mac,
                                  by: ProcessingRequest.Device(id: knownOwner.id, name: "Studio Mac"))
        }

        let transport = SimulatedSoundcoreTransport(device: recorder)
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging)
        environment.soundcoreTransport = { transport }
        environment.soundcoreTiming = Self.soundcoreTiming
        var configured = ConfiguredDevice(id: "soundcore-\(name)", kind: SoundcoreWorkIntegration().kind)
        configured.importsAutomatically = automatic
        configured.automaticImportsSince = .distantPast
        if setUp {
            var snapshot = SoundcoreSnapshot(deviceID: transport.peripheralID, name: recorder.name, serial: recorder.serial)
            snapshot.lastConnectedAt = Date().addingTimeInterval(-3_600)
            environment.storage(for: configured, method: .direct).encode(snapshot, "recorder")
            defaults.set(try JSONEncoder().encode([configured]), forKey: DeviceHub.storageKey)
        } else {
            defaults.set(try JSONEncoder().encode([ConfiguredDevice]()), forKey: DeviceHub.storageKey)
        }
        let hub = DeviceHub(environment: environment)
        let handoff = RecorderHandoff(library: library, devices: hub, deviceClass: deviceClass, defaults: defaults,
                                      timing: Self.handoffTiming, deviceName: deviceClass == .mac ? "Studio Mac" : (setUp ? "Alex’s iPhone" : name))
        let session = setUp ? try XCTUnwrap(hub.sessions.first) : DeviceSession(device: configured, kind: SoundcoreWorkIntegration().kind,
                                                                                  connections: [], defaults: defaults)
        let side = Side(name: name, library: library, hub: hub, session: session,
                        connection: (session.direct as? SoundcoreConnection) ?? SoundcoreConnection(device: configured, environment: environment),
                        transport: transport, handoff: handoff, defaults: defaults)
        hub.importer = { [weak side, weak library] url, identity, attachTo, source in
            guard let side, let library else { throw DaybookError.libraryUnavailable }
            await library.acquireLock()
            defer { library.releaseLock() }
            let id = attachTo.flatMap { library.meeting($0) == nil ? nil : $0 }
                ?? library.newMeeting(title: "Soundcore Work \(identity.recordingID)")
            _ = try await library.ingest(url, into: id, provenance: .file(source: source, device: identity, duration: 1))
            side.imported.append(identity)
            return id
        }
        hub.observeLibrary(library.$meetings.combineLatest(library.$isLoaded).eraseToAnyPublisher())
        let thisDevice = library.thisDevice.id
        hub.observeOwnership(library.$metadata.map { ($0.recorderOwners, thisDevice) }
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.eraseToAnyPublisher())
        hub.start()
        sides.append(side)
        return side
    }

    private static var soundcoreTiming: SoundcoreTiming {
        var timing = SoundcoreTiming()
        timing.request = .seconds(3)
        timing.stall = .seconds(2)
        timing.settle = .milliseconds(20)
        timing.scan = .milliseconds(300)
        timing.connect = .milliseconds(600)
        timing.reconnect = .milliseconds(300)
        timing.recordConfirm = .milliseconds(1_500)
        timing.backoff = [.milliseconds(40), .milliseconds(80)]
        timing.idleRelease = .seconds(60)
        timing.automaticIdleRelease = .seconds(60)
        timing.automaticCooldown = .seconds(60)
        return timing
    }

    private static var handoffTiming: RecorderHandoff.Timing {
        var timing = RecorderHandoff.Timing()
        timing.replyTimeout = .seconds(2)
        timing.patience = 0.3
        timing.doneDisplay = .seconds(1)
        timing.connectPatience = .seconds(20)
        timing.handBackCooldown = 0
        timing.poll = .milliseconds(20)
        timing.progressInterval = 0.3
        timing.followCheck = .milliseconds(50)
        timing.followRetry = 0.3
        timing.remote.connect = .seconds(3)
        timing.remote.confirm = .seconds(3)
        timing.remote.inventory = .seconds(1)
        timing.remote.listing = .seconds(5)
        timing.remote.poll = .milliseconds(20)
        return timing
    }

    /// The Mac claims the recorder and connects ("Use on This Mac" with nobody managing it).
    private func macStartsManaging(_ mac: Side) async throws {
        mac.handoff.useHere(mac.session)
        try await waitUntil("the Mac connects") { mac.session.isLinked }
        try await waitUntil("the Mac lists the recordings") { mac.session.direct?.isRefreshing == false && mac.session.direct?.inventoryUpdatedAt != nil }
    }

    /// The Mac records a conversation and the recorder records along (multipoint): the conversation, its
    /// link to the recorder's recording as `CompanionRecorders` stores it, and the Mac's presence saying
    /// what it records. With `startedByDaybook` false, the recorder was recording already.
    private func macRecordsAlong(_ mac: Side, _ recorder: SimulatedSoundcore, startedByDaybook: Bool = true) async throws -> (UUID, String) {
        mac.connection.startRecording()
        try await waitUntil("the recorder records") { mac.session.split.inProgress != nil && !mac.connection.recordCommandPending }
        let id = try XCTUnwrap(mac.session.split.inProgress?.id)
        let start = Date()
        let conversation = mac.library.newMeeting(title: "Design review")
        var companion = CompanionRecording(deviceID: mac.session.id, deviceKind: kind, deviceSerial: recorder.serial, deviceName: "Soundcore Work",
                                           macStartedAt: start, state: startedByDaybook ? .recording : .alreadyRecording,
                                           startedByDaybook: startedByDaybook)
        companion.recordingID = id
        mac.library.update(conversation) { $0.companions = [companion] }
        mac.library.sync?.publishActivity(recording: conversation, since: start)
        return (conversation, id)
    }

    /// The Mac's recording ends without reaching the recorder: its link is closed, and its presence no
    /// longer names the conversation.
    private func macRecordingEnds(_ mac: Side, _ conversation: UUID) {
        mac.library.update(conversation) { meeting in
            for index in (meeting.companions ?? []).indices {
                meeting.companions?[index].macEndedAt = Date()
                meeting.companions?[index].state = .stopFailed
            }
        }
        mac.library.sync?.publishActivity(recording: nil)
    }

    /// Sync passes in order, each one saving first, and each acknowledged.
    private func syncAll(_ order: Side..., file: StaticString = #filePath, line: UInt = #line) async throws {
        for side in order {
            await side.library.flush()
            let applied = await side.library.synchronize()
            XCTAssertEqual(applied?.acknowledged, true, "\(side.name)'s sync pass ran and was acknowledged", file: file, line: line)
            // The coordinator looks at what arrived in a main-actor task it starts when the library's
            // settings change. The main actor runs its tasks in order, so once a task started now has
            // run, that look has happened (twice over, for a look that starts another).
            for _ in 0..<2 { await Task { @MainActor in }.value }
        }
    }

    // MARK: The link

    /// One end of a loopback link, mirrored on the main actor as the apps' `PhoneLink` does.
    @MainActor
    final class LinkEnd {
        var peers: [UUID: LinkPeer] = [:]
        var onMessage: ((LinkMessage, UUID) -> Void)?
        var onPeers: (() -> Void)?
        private var task: Task<Void, Never>?

        init(_ events: AsyncStream<LinkEvent>) {
            task = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case .connected(let peer): self.peers[peer.deviceID] = peer; self.onPeers?()
                    case .peerUpdated(let peer): if self.peers[peer.deviceID] != nil { self.peers[peer.deviceID] = peer }
                    case .disconnected(let id, _): self.peers[id] = nil; self.onPeers?()
                    case .received(let message, let from): self.onMessage?(message, from)
                    default: break
                    }
                }
            }
        }

        deinit { task?.cancel() }

        var handoffPeers: [RecorderHandoff.Peer] {
            peers.values.map { peer in
                RecorderHandoff.Peer(linkID: peer.deviceID, syncID: peer.capabilities.syncDeviceID, name: peer.name,
                                     deviceClass: peer.deviceClass == .mac ? .mac : .phone, handsOffRecorders: peer.capabilities.handsOffRecorders)
            }
        }
    }

    struct LinkPair {
        let service: LinkService
        let client: LinkClient
        let macEnd: LinkEnd
        let phoneEnd: LinkEnd
        let macID: UUID
        let endpoint: LinkEndpoint

        func tearDown() async {
            await client.disconnect(from: macID)
            await service.stop()
        }
    }

    /// Pairs and connects the Mac's service and the phone's client over loopback, and plugs each
    /// coordinator into its end.
    @discardableResult
    private func link(_ mac: Side, _ phone: Side) async throws -> LinkPair {
        let macID = try XCTUnwrap(UUID(uuidString: mac.id))
        let phoneID = UUID()
        let features = [LinkCapabilities.recorderHandoffFeature]
        let macIdentity = LinkIdentity(deviceID: macID, name: "Studio Mac", deviceClass: .mac, appVersion: "1", features: features,
                                       syncDeviceID: mac.id)
        let phoneIdentity = LinkIdentity(deviceID: phoneID, name: "Alex’s iPhone", deviceClass: .iPhone, appVersion: "1", features: features,
                                         syncDeviceID: phone.id)
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let pskIdentity = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let now = Date()
        let macStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: phoneID, name: phoneIdentity.name, deviceClass: .iPhone, pairedAt: now,
                                                             linkKey: key, pskIdentity: pskIdentity)])
        let phoneStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: macID, name: macIdentity.name, deviceClass: .mac, pairedAt: now,
                                                               linkKey: key, pskIdentity: pskIdentity)])
        let service = LinkService(identity: macIdentity, keyStore: macStore, configuration: .loopback())
        let client = LinkClient(identity: phoneIdentity, keyStore: phoneStore, configuration: .loopback())
        let macEnd = LinkEnd(service.events())
        let phoneEnd = LinkEnd(client.events())
        try await service.start()
        let listening = await service.port
        let port = try XCTUnwrap(listening)
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        let pair = LinkPair(service: service, client: client, macEnd: macEnd, phoneEnd: phoneEnd, macID: macID, endpoint: endpoint)
        links.append(pair)

        mac.handoff.link = RecorderHandoff.Link(peers: { macEnd.handoffPeers }, send: { message, to in try await service.send(message, to: to) })
        phone.handoff.link = RecorderHandoff.Link(peers: { phoneEnd.handoffPeers }, send: { message, to in try await client.send(message, to: to) })
        macEnd.onMessage = { [weak mac] message, from in mac?.handoff.receive(message, from: from) }
        phoneEnd.onMessage = { [weak phone] message, from in phone?.handoff.receive(message, from: from) }

        try await client.connect(to: macID, via: endpoint)
        try await waitUntil("linked") { !macEnd.peers.isEmpty && !phoneEnd.peers.isEmpty }
        return pair
    }
}
