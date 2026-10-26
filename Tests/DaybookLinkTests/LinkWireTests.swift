@testable import DaybookLink
import Foundation
import XCTest

final class LinkWireTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)

    func testEveryMessageRoundTrips() throws {
        let id = UUID()
        let capabilities = LinkCapabilities(deviceClass: .mac, name: "Studio Mac", appVersion: "2.0", libraryID: id, canProcess: true,
                                            features: ["liveProgress"])
        let messages: [WireMessage] = [
            .hello(Hello(versions: LinkVersionRange(1...2), deviceID: id, serverID: UUID(), capabilities: capabilities,
                         auth: Data([1, 2, 3]), heartbeatInterval: 5)),
            .welcome(Welcome(version: 2, deviceID: id, capabilities: capabilities, auth: Data([4]), heartbeatInterval: nil)),
            .refused(Refusal(reason: .incompatibleVersion, versions: LinkVersionRange(1...1))),
            .capabilities(capabilities),
            .app(.recordingState(LinkRecordingState(phase: .paused, conversationID: id, startedAt: t0, elapsed: 3, sentAt: t0))),
            .app(.bookmark(LinkBookmark(conversationID: id, recordingTime: 1.5, createdAt: t0, label: nil))),
            .app(.processingProgress(LinkProcessingProgress(meetingID: id, phase: .failed, fraction: nil, macName: "M",
                                                            detail: "Out of space"))),
            .app(.processingNudge(LinkProcessingNudge(requestID: UUID(), meetingID: id, mode: .transcribe, requestedAt: t0))),
            .recordRequest(LinkRecordRequest(action: .stop, conversationID: id, timing: LinkTiming(startedAt: t0, elapsed: 60),
                                             sentAt: t0)),
            .recordRequest(LinkRecordRequest(action: .start, conversationID: id,
                                             timing: LinkTiming(startedAt: t0, elapsed: 600, timelineStart: t0.addingTimeInterval(-600)),
                                             sentAt: t0, title: "Design review", date: t0)),
            .recordReply(LinkRecordReply(requestID: id, outcome: .accepted(LinkRecordAck(conversationID: id, startedAt: t0,
                                                                                          recordingID: "r1")), sentAt: t0)),
            .recordReply(LinkRecordReply(requestID: id, outcome: .refused(LinkRecordRefusal(reason: .storageFull, message: "Full")),
                                         sentAt: t0)),
            .ping(Heartbeat(sequence: 7, interval: 20)),
            .pong(Heartbeat(sequence: 7, interval: nil)),
            .clockRequest(ClockRequest(sequence: 1, t1: t0)),
            .clockReply(ClockReply(sequence: 1, t1: t0, t2: t0, t3: t0)),
            .unpair,
            .goodbye(Goodbye(reason: "quitting")),
            .pairing(.commit(.init(round: 3, commitment: Data(repeating: 9, count: 32)))),
            .pairing(.refuse(.init(reason: .busy)))
        ]
        for message in messages {
            let frame = try LinkWire.encode(message, version: 2)
            let decoded = try LinkWire.decode(frame)
            XCTAssertEqual(decoded.version, 2)
            XCTAssertEqual(decoded.message, message, String(decoding: frame, as: UTF8.self))
        }
    }

    func testUnknownTypesDecodeAsUnknownAndBrokenKnownTypesThrow() throws {
        let unknown = try LinkWire.decode(Data(#"{"v":9,"type":"telepathy","body":[1,2,3]}"#.utf8))
        XCTAssertEqual(unknown.message, .unknown("telepathy"))
        XCTAssertEqual(unknown.version, 9)
        XCTAssertThrowsError(try LinkWire.decode(Data(#"{"v":1,"type":"bookmark","body":{}}"#.utf8)))
        XCTAssertThrowsError(try LinkWire.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try LinkWire.encode(.unknown("x"), version: 1))
    }

    func testOpenValuesKeepUnknownCasesAndEncodeAsPlainStrings() throws {
        let data = try JSONEncoder().encode([LinkProcessingProgress.Phase.transcribing, "dreaming"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["transcribing","dreaming"]"#)
        let decoded = try JSONDecoder().decode([LinkRecordRefusal.Reason].self, from: Data(#"["busy","onTheMoon"]"#.utf8))
        XCTAssertEqual(decoded, [.busy, "onTheMoon"])
    }

    func testOlderPeersMissingOptionalFieldsStillDecode() throws {
        let capabilities = try LinkWire.decode(Data(#"{"v":1,"type":"capabilities","body":{"deviceClass":"iPad","name":"Tab"}}"#.utf8))
        XCTAssertEqual(capabilities.message, .capabilities(LinkCapabilities(deviceClass: .iPad, name: "Tab", appVersion: "")))
        // A reply with an outcome this build doesn't know is a refusal, never a silent yes.
        let reply = try LinkWire.decode(Data(#"{"v":1,"type":"record.reply","body":{"requestID":"\#(UUID().uuidString)","deferred":{}}}"#.utf8))
        guard case .recordReply(let r) = reply.message, case .refused(let refusal) = r.outcome else { return XCTFail("\(reply)") }
        XCTAssertEqual(refusal.reason.rawValue, "unknown")
        // A record request from before conversations travelled with it.
        let conversation = UUID(), request = UUID()
        let older = try LinkWire.decode(Data(#"{"v":1,"type":"record.request","body":{"id":"\#(request.uuidString)","action":"start","conversationID":"\#(conversation.uuidString)","sentAt":1800000000}}"#.utf8))
        XCTAssertEqual(older.message, .recordRequest(LinkRecordRequest(id: request, action: .start, conversationID: conversation,
                                                                       sentAt: Date(timeIntervalSince1970: 1_800_000_000))))
    }

    func testFrameHeaderIsBigEndianLength() {
        let header = LinkFramer.header(length: 0x01_02_03)
        XCTAssertEqual([UInt8](header), [0, 1, 2, 3])
        XCTAssertEqual(header.withUnsafeBytes { LinkFramer.length(fromHeader: $0) }, 0x01_02_03)
    }

    // MARK: Discovery

    func testAdvertisementTagsMatchOnlyTheirIDs() throws {
        let library = UUID(), mac = UUID()
        let advertisement = LinkAdvertisement(libraryID: library, deviceID: mac, versions: 1...2, isPairing: true)
        let entries = advertisement.entries
        // Nothing in the record is an ID in the clear.
        for value in entries.values {
            XCTAssertFalse(value.lowercased().contains(library.uuidString.lowercased().prefix(8)))
            XCTAssertFalse(value.lowercased().contains(mac.uuidString.lowercased().prefix(8)))
        }
        let parsed = try XCTUnwrap(LinkAdvertisement(entries: entries))
        XCTAssertEqual(parsed, advertisement)
        XCTAssertTrue(parsed.matches(libraryID: library))
        XCTAssertFalse(parsed.matches(libraryID: UUID()))
        XCTAssertTrue(parsed.matches(deviceID: mac))
        XCTAssertFalse(parsed.matches(deviceID: UUID()))
        XCTAssertEqual(parsed.versions.range, 1...2)
        XCTAssertTrue(parsed.isPairing)

        // A new salt makes new tags, so the Mac can't be followed across networks by them.
        let later = LinkAdvertisement(libraryID: library, deviceID: mac, versions: 1...2, isPairing: false)
        XCTAssertNotEqual(later.deviceTag, advertisement.deviceTag)
        XCTAssertNotEqual(later.libraryTag, advertisement.libraryTag)
        XCTAssertTrue(later.matches(deviceID: mac))

        XCTAssertNil(LinkAdvertisement(entries: ["s": "zz", "d": "00"]))
        XCTAssertEqual(LinkAdvertisement(txtRecord: advertisement.txtRecord), advertisement)
    }

    func testDiscoveredMacsKnowTheirLibraryAndPairing() {
        let library = UUID(), mac = UUID()
        let advertisement = LinkAdvertisement(libraryID: library, deviceID: mac, versions: 1...1, isPairing: false)
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: 1).endpoint
        let same = advertisement.discovered(serviceName: "Studio Mac", endpoint: endpoint, libraryID: library, pairedMacs: [UUID(), mac])
        XCTAssertEqual(same.sharesLibrary, true)
        XCTAssertEqual(same.pairedDeviceID, mac)
        let other = advertisement.discovered(serviceName: "Studio Mac", endpoint: endpoint, libraryID: UUID(), pairedMacs: [])
        XCTAssertEqual(other.sharesLibrary, false)
        XCTAssertNil(other.pairedDeviceID)
        let noLibrary = advertisement.discovered(serviceName: "Studio Mac", endpoint: endpoint, libraryID: nil, pairedMacs: [])
        XCTAssertNil(noLibrary.sharesLibrary)
    }

    func testServiceAdvertisesWhatItIsDoing() async throws {
        let mac = Fixture.mac()
        let service = LinkService(identity: mac, keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        try await service.start()
        let before = await service.advertisedEntries
        let closed = try XCTUnwrap(before)
        XCTAssertEqual(closed["p"], "0")
        await service.beginPairing()
        let after = await service.advertisedEntries
        let open = try XCTUnwrap(after.flatMap(LinkAdvertisement.init(entries:)))
        XCTAssertTrue(open.isPairing)
        XCTAssertTrue(open.matches(deviceID: mac.deviceID))
        XCTAssertTrue(open.matches(libraryID: Fixture.libraryID))
        await service.stop()
    }

    // MARK: Backoff, keys

    func testBackoffDoublesUpToTheMaximumWithBoundedJitter() {
        let backoff = LinkBackoff(initial: 0.5, maximum: 30, multiplier: 2, jitter: 0.2)
        XCTAssertEqual((0..<9).map { backoff.delay(attempt: $0, random: 0) }, [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(backoff.delay(attempt: 0, random: 1), 0.6, accuracy: 1e-9)
        XCTAssertEqual(backoff.delay(attempt: 0, random: -1), 0.4, accuracy: 1e-9)
        for attempt in 0..<20 {
            let delay = backoff.delay(attempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, 0.4)
            XCTAssertLessThanOrEqual(delay, 36)
        }
    }

    func testPSKIdentitiesOnTheWireArePrintable() {
        let record = LinkPairingRecord(deviceID: UUID(), name: "A", deviceClass: .iPhone, pairedAt: t0,
                                       linkKey: Data(count: 32), pskIdentity: Data([0, 255, 0, 16]))
        let psk = LinkTransport.PSK(record)
        XCTAssertEqual(String(decoding: psk.identity, as: UTF8.self), "dbl1-00ff0010")
        XCTAssertFalse(psk.identity.contains(0))
        XCTAssertEqual(psk.key, record.linkKey)
    }

    func testMemoryKeyStoreSavesReplacesAndRemoves() throws {
        let store = MemoryLinkKeyStore()
        let id = UUID()
        let record = LinkPairingRecord(deviceID: id, name: "A", deviceClass: .iPhone, pairedAt: t0, linkKey: Data([1]), pskIdentity: Data([2]))
        try store.save(record)
        var renamed = record
        renamed.name = "B"
        try store.save(renamed)
        XCTAssertEqual(try store.records(), [renamed])
        XCTAssertEqual(try store.record(for: id)?.device.name, "B")
        try store.remove(deviceID: id)
        XCTAssertNil(try store.record(for: id))
    }
}
