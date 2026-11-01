@testable import DaybookLink
import Foundation
import XCTest

/// Record requests answered once per request, on the Mac as on the iPhone (`LinkRecordAnswers`).
final class LinkRecordAnswersTests: XCTestCase {
    func testBehaviorAnswersRememberEachDevicesRepliesAndForgetThemOnUnpair() {
        var answers = LinkRecordAnswers()
        let device = UUID(), request = LinkRecordRequest(action: .start, conversationID: UUID())
        var heard: [LinkRecordReply.Outcome] = []
        XCTAssertTrue(answers.begin(request, from: device) { heard.append($0) }, "the first asking reaches the app")
        XCTAssertFalse(answers.begin(request, from: device) { heard.append($0) }, "a repeat while it's answered waits for that answer")
        XCTAssertTrue(answers.begin(request, from: UUID()) { _ in }, "another device's request is its own")
        let outcome = LinkRecordReply.Outcome.refused(LinkRecordRefusal(reason: .busy))
        answers.finish(request, from: device, outcome: outcome, at: Date()).forEach { $0(outcome) }
        XCTAssertEqual(heard, [outcome, outcome], "every asker hears the one answer")
        XCTAssertFalse(answers.begin(request, from: device) { heard.append($0) })
        XCTAssertEqual(heard.count, 3, "a later repeat is answered from memory")
        XCTAssertEqual(answers.replies(for: device)?.count, 1)

        answers.forget(device)
        XCTAssertNil(answers.replies(for: device))
        XCTAssertTrue(answers.begin(request, from: device) { _ in }, "after unpairing, nothing is answered from before")
    }

    func testBehaviorAnswersKeepOnlyTheLatestReplies() {
        var answers = LinkRecordAnswers()
        let device = UUID(), start = Date()
        var replies: [UUID: LinkRecordReply] = [:]
        for index in 0..<(LinkRecordReply.rememberedReplies + 10) {
            let id = UUID()
            replies[id] = LinkRecordReply(requestID: id, outcome: .refused(LinkRecordRefusal(reason: .busy)),
                                          sentAt: start.addingTimeInterval(Double(index)))
        }
        answers.keep(replies, from: device)
        let kept = try? XCTUnwrap(answers.replies(for: device))
        XCTAssertEqual(kept?.count, LinkRecordReply.rememberedReplies)
        XCTAssertEqual(kept?.values.map(\.sentAt).min(), start.addingTimeInterval(10), "the oldest go first")
    }

    func testBehaviorTheMacAnswersARepeatedRequestOnceAsThePhoneDoes() async throws {
        // A microphone prompt on the Mac outlasts the phone's request; the phone reconnects and asks
        // again with the same ID. The Mac's app hears it once and the phone gets its one answer.
        var configuration = LinkConfiguration.testLoopback()
        configuration.requestTimeout = 0.3
        let pair = try await LinkedPair.make(self, client: configuration, relay: (0, 0))
        try await pair.connect()
        let gate = AnswerGate()
        await pair.service.setRecordControlHandler { _, request in
            await gate.arrive()
            await gate.wait()
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "mac-1"))
        }
        let start = LinkRecordRequest(action: .start, conversationID: UUID())
        do {
            _ = try await pair.client.request(start, from: pair.mac.deviceID)
            XCTFail("the answer is still coming")
        } catch let error as LinkError {
            XCTAssertEqual(error, .timedOut)
        }
        pair.relay?.dropAll()
        _ = try await pair.phoneEvents.next("phone saw the drop") { $0.disconnectReason }
        _ = try await pair.phoneEvents.next("phone reconnected") { $0.connected }
        async let repeated = pair.client.request(start, from: pair.mac.deviceID)
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.open()
        let reply = try await repeated
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("\(reply)") }
        XCTAssertEqual(ack.recordingID, "mac-1")
        let arrivals = await gate.arrivals
        XCTAssertEqual(arrivals, 1, "the Mac's app heard the request once")
        let again = try await pair.client.request(start, from: pair.mac.deviceID)
        XCTAssertEqual(again.outcome, reply.outcome)
        let still = await gate.arrivals
        XCTAssertEqual(still, 1)
    }
}
