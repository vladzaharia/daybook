@testable import DaybookLink
import Foundation
import XCTest

/// What a shared recording adds to the link (docs/link.md, "Shared recordings"): cascading starts and
/// stops, a recording state that says the sender records only through its recorders, and notes and
/// bookmark changes in both directions. All additive within version 1: older builds ignore the new
/// types and fields, and what an older build sends still reads the same.
final class LinkSharedRecordingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.5)

    func testTheNewMessagesAndFieldsRoundTrip() throws {
        let conversation = UUID()
        let recorders = [LinkRecorderState(kind: "soundcore.work", serial: "S", name: "Soundcore Work", isRecording: true,
                                           recordingID: "1729000000", startedAt: t0, asOf: t0, conversationID: conversation)]
        let messages: [WireMessage] = [
            .recordRequest(LinkRecordRequest(action: .start, conversationID: conversation, timing: LinkTiming(startedAt: t0, elapsed: 3),
                                             sentAt: t0, title: "Design review", date: t0,
                                             cascade: LinkCascade(trigger: .recorder, requesterRecords: false, recorders: recorders))),
            .app(.recordingState(LinkRecordingState(phase: .idle, sentAt: t0, recorders: recorders, sharedConversationID: conversation))),
            .app(.note(LinkNote(id: UUID(), conversationID: conversation, text: "Launch on the 14th", time: 12.5, madeAt: t0, changedAt: t0))),
            .app(.note(LinkNote(id: UUID(), conversationID: conversation, text: "", time: nil, madeAt: t0, deleted: true, changedAt: t0))),
            .app(.bookmark(LinkBookmark(conversationID: conversation, recordingTime: 30, createdAt: t0, label: "Decision"))),
            .app(.bookmarkChange(LinkBookmarkChange(id: UUID(), conversationID: conversation, label: "Decision", changedAt: t0))),
            .app(.bookmarkChange(LinkBookmarkChange(id: UUID(), conversationID: conversation, deleted: true, changedAt: t0))),
            .capabilities(LinkCapabilities(deviceClass: .iPhone, name: "P", appVersion: "1",
                                           features: [LinkCapabilities.cascadeFeature, LinkCapabilities.sharedNotesFeature])),
        ]
        for message in messages {
            let frame = try LinkWire.encode(message, version: 1)
            XCTAssertEqual(try LinkWire.decode(frame).message, message, String(decoding: frame, as: UTF8.self))
        }
        XCTAssertEqual(WireMessage.app(.note(LinkNote(id: UUID(), conversationID: conversation, text: "", time: nil))).type, "note")
        XCTAssertEqual(WireMessage.app(.bookmarkChange(LinkBookmarkChange(id: UUID(), conversationID: conversation))).type, "bookmark.change")
        let capabilities = LinkCapabilities(deviceClass: .mac, name: "M", appVersion: "1", features: [LinkCapabilities.cascadeFeature])
        XCTAssertTrue(capabilities.cascades)
        XCTAssertFalse(capabilities.sharesNotes)
    }

    func testWhatAnOlderBuildSendsStillReadsTheSame() throws {
        let conversation = UUID()
        // A start without `cascade` is one the person chose on that device, as before; with no timing, a
        // conversation of the receiver's own.
        let start = #"{"v":1,"type":"record.request","body":{"id":"\#(UUID().uuidString)","action":"start","conversationID":"\#(conversation.uuidString)","sentAt":1800000000,"timing":{"startedAt":1800000000}}}"#
        guard case .recordRequest(let request) = try LinkWire.decode(Data(start.utf8)).message else { return XCTFail() }
        XCTAssertNil(request.cascade)
        XCTAssertFalse(request.isStandalone)
        XCTAssertTrue(LinkRecordRequest(action: .start, conversationID: conversation).isStandalone)
        XCTAssertFalse(LinkRecordRequest(action: .start, conversationID: conversation, cascade: LinkCascade(trigger: .person)).isStandalone,
                       "a cascading start always joins the requester's conversation")

        // A recording state without `sharedConversationID`: what the microphone records, as before.
        let state = #"{"v":1,"type":"recording.state","body":{"phase":"recording","conversationID":"\#(conversation.uuidString)","sentAt":1800000000}}"#
        guard case .app(.recordingState(let decoded)) = try LinkWire.decode(Data(state.utf8)).message else { return XCTFail() }
        XCTAssertNil(decoded.sharedConversationID)
        XCTAssertTrue(decoded.takesPart(in: conversation))
        XCTAssertFalse(LinkRecordingState(phase: .idle, sharedConversationID: nil).takesPart(in: conversation))
        XCTAssertTrue(LinkRecordingState(phase: .idle, sharedConversationID: conversation).takesPart(in: conversation),
                      "its recorders record the conversation")
        XCTAssertFalse(LinkRecordingState(phase: .stopping, conversationID: conversation).takesPart(in: conversation))

        // A cascade, note, or bookmark change with fields missing or unknown values still reads.
        let cascade = try JSONDecoder().decode(LinkCascade.self, from: Data(#"{"trigger":"aDoorbell","recorders":"unreadable"}"#.utf8))
        XCTAssertEqual(cascade.trigger.rawValue, "aDoorbell")
        XCTAssertTrue(cascade.requesterRecords, "an older or unclear answer means the requester records")
        XCTAssertNil(cascade.recorders)
        let note = #"{"v":1,"type":"note","body":{"id":"\#(UUID().uuidString)","conversationID":"\#(conversation.uuidString)","madeAt":1800000000}}"#
        guard case .app(.note(let paragraph)) = try LinkWire.decode(Data(note.utf8)).message else { return XCTFail() }
        XCTAssertEqual(paragraph.text, "")
        XCTAssertFalse(paragraph.deleted)
        XCTAssertEqual(paragraph.changedAt, paragraph.madeAt)
    }

    /// An older build doesn't know `note` or `bookmark.change`: it reads them as types it doesn't know,
    /// which it ignores, and the session carries on (docs/link.md, "Compatibility rules").
    func testAnOlderBuildIgnoresTheNewTypes() async throws {
        let conversation = UUID()
        for type in ["note", "bookmark.change"] {
            let message: LinkMessage = type == "note"
                ? .note(LinkNote(id: UUID(), conversationID: conversation, text: "Hello", time: 1))
                : .bookmarkChange(LinkBookmarkChange(id: UUID(), conversationID: conversation, label: "L"))
            var frame = String(decoding: try LinkWire.encode(.app(message), version: 1), as: UTF8.self)
            frame = frame.replacingOccurrences(of: "\"type\":\"\(type)\"", with: "\"type\":\"\(type).from-a-later-build\"")
            XCTAssertEqual(try LinkWire.decode(Data(frame.utf8)).message, .unknown("\(type).from-a-later-build"))
        }
        // Over a session, the receiver goes on to the next message.
        let pair = try await LinkedPair.make(self)
        try await pair.connect()
        let note = LinkNote(id: UUID(), conversationID: conversation, text: "From the phone", time: 4, madeAt: t0, changedAt: t0)
        try await pair.client.send(.note(note))
        let (received, _) = try await pair.macEvents.next("the note") { $0.received }
        XCTAssertEqual(received, .note(note))
        let change = LinkBookmarkChange(id: UUID(), conversationID: conversation, deleted: true, changedAt: t0)
        try await pair.service.send(.bookmarkChange(change), to: pair.phone.deviceID)
        let (back, _) = try await pair.phoneEvents.next("the bookmark change") { $0.received }
        XCTAssertEqual(back, .bookmarkChange(change))
        await pair.tearDown()
    }
}
