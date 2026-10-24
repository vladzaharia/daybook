@testable import DaybookLink
import Foundation
import XCTest

/// The recorder handoff messages: request, reply (accepted or refused with a reason), and release.
/// They're additive within version 1, so what an older or newer peer sends must still be read
/// safely, and anything unreadable must never count as a yes.
final class LinkRecorderHandoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)
    private let phone = LinkHandoffDevice(syncID: "phone-sync", name: "Alex’s iPhone", deviceClass: .iPhone)
    private let mac = LinkHandoffDevice(syncID: "mac-sync", name: "Studio Mac", deviceClass: .mac)

    func testHandoffMessagesRoundTrip() throws {
        let request = LinkRecorderHandoffRequest(intent: .take, kind: "soundcore.work", serial: "D3200SIM0000001",
                                                 recorderName: "Soundcore Work", addressedTo: mac.syncID, requester: phone, sentAt: t0)
        let messages: [WireMessage] = [
            .app(.recorderHandoffRequest(request)),
            .app(.recorderHandoffRequest(LinkRecorderHandoffRequest(intent: .give, kind: "soundcore.work", serial: "S", recorderName: "Soundcore Work",
                                                                    addressedTo: phone.syncID, requester: mac, sentAt: t0))),
            .app(.recorderHandoffReply(LinkRecorderHandoffReply(
                requestID: request.id,
                outcome: .accepted(LinkRecorderHandoffAck(finishing: .import, finishingTitle: "Today, 10:02 AM", secondsLeft: 42,
                                                          recorderIsRecording: true)),
                from: mac, sentAt: t0))),
            .app(.recorderHandoffReply(LinkRecorderHandoffReply(
                requestID: request.id,
                outcome: .refused(LinkRecorderHandoffRefusal(reason: .notOwner, message: nil, ownerName: "Office iMac")),
                from: mac, sentAt: t0))),
            .app(.recorderRelease(LinkRecorderRelease(requestID: request.id, kind: "soundcore.work", serial: "D3200SIM0000001",
                                                      newOwner: phone, releasedAt: t0,
                                                      pendingImports: [LinkHandoffImport(recordingID: "1729000000", attachTo: UUID(), isAutomatic: true)],
                                                      importedRecordingIDs: ["1728990000"], recorderIsRecording: false))),
            .app(.recorderRelease(LinkRecorderRelease(requestID: nil, kind: "soundcore.work", serial: "S", newOwner: mac, releasedAt: t0))),
        ]
        for message in messages {
            let frame = try LinkWire.encode(message, version: 1)
            let decoded = try LinkWire.decode(frame)
            XCTAssertEqual(decoded.message, message, String(decoding: frame, as: UTF8.self))
        }
        XCTAssertEqual(WireMessage.app(.recorderHandoffRequest(request)).type, "recorder.handoff.request")
    }

    func testAReplyThisBuildCantReadIsARefusal() throws {
        let id = UUID()
        let frame = #"{"v":1,"type":"recorder.handoff.reply","body":{"requestID":"\#(id.uuidString)","postponed":{"until":5}}}"#
        guard case .app(.recorderHandoffReply(let reply)) = try LinkWire.decode(Data(frame.utf8)).message,
              case .refused(let refusal) = reply.outcome else { return XCTFail("an unknown outcome must not read as accepted") }
        XCTAssertEqual(reply.requestID, id)
        XCTAssertEqual(refusal.reason.rawValue, "unknown")
    }

    func testOptionalFieldsAndUnknownValuesFromOtherVersionsDecode() throws {
        // An earlier request without an intent is a take; unknown intents and reasons are kept, not rejected.
        let request = #"{"v":1,"type":"recorder.handoff.request","body":{"id":"\#(UUID().uuidString)","kind":"soundcore.work","serial":"S","addressedTo":"mac","requester":{"syncID":"p","name":"P","deviceClass":"iPhone"},"sparkle":1}}"#
        guard case .app(.recorderHandoffRequest(let decoded)) = try LinkWire.decode(Data(request.utf8)).message else { return XCTFail() }
        XCTAssertEqual(decoded.intent, .take)
        XCTAssertEqual(decoded.recorderName, "Recorder")

        let refusal = #"{"v":1,"type":"recorder.handoff.reply","body":{"requestID":"\#(UUID().uuidString)","refused":{"reason":"onAPlane"}}}"#
        guard case .app(.recorderHandoffReply(let reply)) = try LinkWire.decode(Data(refusal.utf8)).message,
              case .refused(let why) = reply.outcome else { return XCTFail() }
        XCTAssertEqual(why.reason.rawValue, "onAPlane")
        XCTAssertNil(reply.from)

        let release = #"{"v":1,"type":"recorder.release","body":{"kind":"soundcore.work","serial":"S","newOwner":{"syncID":"p","name":"P","deviceClass":"iPhone"}}}"#
        guard case .app(.recorderRelease(let released)) = try LinkWire.decode(Data(release.utf8)).message else { return XCTFail() }
        XCTAssertNil(released.requestID)
        XCTAssertEqual(released.pendingImports, [])
        XCTAssertEqual(released.importedRecordingIDs, [])

        // A release without the new owner can't be acted on: the frame is unreadable (ignored, not fatal).
        XCTAssertThrowsError(try LinkWire.decode(Data(#"{"v":1,"type":"recorder.release","body":{"kind":"k"}}"#.utf8)))
    }

    func testCapabilitiesCarryTheSyncIDAndTheHandoffFeature() throws {
        let capabilities = LinkCapabilities(deviceClass: .iPhone, name: "P", appVersion: "1", features: [LinkCapabilities.recorderHandoffFeature],
                                            syncDeviceID: "phone-sync")
        let decoded = try LinkWire.decode(try LinkWire.encode(.capabilities(capabilities), version: 1))
        XCTAssertEqual(decoded.message, .capabilities(capabilities))
        XCTAssertTrue(capabilities.handsOffRecorders)
        // Older peers send neither.
        let older = try LinkWire.decode(Data(#"{"v":1,"type":"capabilities","body":{"deviceClass":"mac","name":"M","features":["recordControl"]}}"#.utf8))
        guard case .capabilities(let old) = older.message else { return XCTFail() }
        XCTAssertNil(old.syncDeviceID)
        XCTAssertFalse(old.handsOffRecorders)
    }

    func testHandoffTravelsBothWaysOverASession() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()
        let request = LinkRecorderHandoffRequest(kind: "soundcore.work", serial: "S", recorderName: "Soundcore Work",
                                                 addressedTo: mac.syncID, requester: phone, sentAt: t0)
        try await pair.client.send(.recorderHandoffRequest(request))
        let (received, from) = try await pair.macEvents.next("the request") { $0.received }
        XCTAssertEqual(received, .recorderHandoffRequest(request))
        XCTAssertEqual(from, pair.phone.deviceID)

        let reply = LinkRecorderHandoffReply(requestID: request.id, outcome: .accepted(LinkRecorderHandoffAck()), from: mac, sentAt: t0)
        let release = LinkRecorderRelease(requestID: request.id, kind: "soundcore.work", serial: "S", newOwner: phone, releasedAt: t0,
                                          pendingImports: [LinkHandoffImport(recordingID: "1")])
        try await pair.service.send(.recorderHandoffReply(reply), to: pair.phone.deviceID)
        try await pair.service.send(.recorderRelease(release), to: pair.phone.deviceID)
        let (first, _) = try await pair.phoneEvents.next("the reply") { $0.received }
        XCTAssertEqual(first, .recorderHandoffReply(reply))
        let (second, _) = try await pair.phoneEvents.next("the release") { $0.received }
        XCTAssertEqual(second, .recorderRelease(release))
        await pair.tearDown()
    }
}
