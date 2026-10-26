@testable import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest

final class LinkSessionTests: XCTestCase {
    /// Exact in binary, so dates survive JSON's seconds-since-1970 unchanged.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)

    // MARK: Messages

    func testOutOfRangeHeartbeatClosesTheSessionWithoutCrashing() async throws {
        for interval in ["1e100", "-1", "0", "301"] {
            let pair = try await LinkedPair.make(self)
            try await pair.connect()
            let frame = Data("{\"v\":1,\"type\":\"ping\",\"body\":{\"sequence\":1,\"interval\":\(interval)}}".utf8)
            await pair.client.sendRawFrame(frame, to: pair.mac.deviceID)
            let reason = try await pair.macEvents.next("invalid heartbeat rejected") { $0.disconnectReason }
            XCTAssertEqual(reason, .protocolError("invalid heartbeat interval"))
            await pair.tearDown()
        }
    }

    func testAppMessagesRoundTripBothWays() async throws {
        let pair = try await LinkedPair.make(self)
        let (macSide, phoneSide) = try await pair.connect()
        XCTAssertEqual(macSide.deviceID, pair.phone.deviceID)
        XCTAssertEqual(macSide.capabilities, pair.phone.capabilities)
        XCTAssertEqual(phoneSide.capabilities, pair.mac.capabilities)
        XCTAssertEqual(phoneSide.protocolVersion, 1)
        let peersOnMac = await pair.service.connectedPeers
        XCTAssertEqual(peersOnMac.map(\.deviceID), [pair.phone.deviceID])

        let conversation = UUID()
        let fromPhone: [LinkMessage] = [
            .recordingState(LinkRecordingState(phase: .recording, conversationID: conversation, startedAt: t0, elapsed: 12.5,
                                               sentAt: t0.addingTimeInterval(12.5))),
            .bookmark(LinkBookmark(conversationID: conversation, recordingTime: 7.25, createdAt: t0.addingTimeInterval(7.25),
                                   label: "Decision")),
            .processingNudge(LinkProcessingNudge(requestID: UUID(), meetingID: conversation, mode: .summarizeAgain, requestedAt: t0))
        ]
        for message in fromPhone { try await pair.client.send(message) }
        for expected in fromPhone {
            let (message, from) = try await pair.macEvents.next("message on Mac") { $0.received }
            XCTAssertEqual(message, expected)
            XCTAssertEqual(from, pair.phone.deviceID)
        }

        let progress = LinkMessage.processingProgress(LinkProcessingProgress(meetingID: conversation, phase: .transcribing,
                                                                             fraction: 0.4, macName: "Studio Mac"))
        try await pair.service.send(progress, to: pair.phone.deviceID)
        let (onPhone, fromMac) = try await pair.phoneEvents.next("message on phone") { $0.received }
        XCTAssertEqual(onPhone, progress)
        XCTAssertEqual(fromMac, pair.mac.deviceID)

        // Capabilities follow identity changes.
        var phone = pair.phone
        phone.name = "Renamed iPhone"
        await pair.client.updateIdentity(phone)
        let updated = try await pair.macEvents.next("capabilities") { $0.updated?.name == "Renamed iPhone" ? $0.updated : nil }
        XCTAssertEqual(updated.capabilities.name, "Renamed iPhone")

        await pair.tearDown()
    }

    /// Network.framework reads PSK identities as C strings; a derived identity with zero bytes
    /// must still connect (it once failed about one connection in sixteen).
    func testPairingWhoseIdentityHasZeroBytesConnects() async throws {
        let pair = try await LinkedPair.make(self, pskIdentity: Data([0, 0, 7, 0] + [UInt8](repeating: 0, count: 12)))
        try await pair.connect()
        await pair.tearDown()
    }

    func testSendingWithoutAConnectionThrows() async throws {
        let pair = try await LinkedPair.make(self)
        do {
            try await pair.client.send(.bookmark(LinkBookmark(conversationID: UUID(), recordingTime: 1)))
            XCTFail()
        } catch let error as LinkError {
            XCTAssertEqual(error, .notConnected)
        }
        await pair.tearDown()
    }

    func testUnknownMessagesAndFieldsAreIgnored() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()
        let conversation = UUID()

        // A type from the future, a known type with fields and values from the future, and a known
        // type whose body this build can't read.
        let frames = [
            #"{"v":1,"type":"hologram.beam","body":{"intensity":11}}"#,
            #"{"v":1,"type":"bookmark","body":{"id":"\#(UUID().uuidString)","conversationID":"\#(conversation.uuidString)","recordingTime":3.5,"createdAt":1800000000.25,"sparkle":true}}"#,
            #"{"v":1,"type":"recording.state","body":{"phase":"levitating","conversationID":"\#(conversation.uuidString)","elapsed":4,"sentAt":1800000000.25}}"#,
            #"{"v":1,"type":"bookmark","body":{"oops":1}}"#,
            #"{"v":1,"type":"ping"}"#
        ]
        for frame in frames { await pair.client.sendRawFrame(Data(frame.utf8), to: pair.mac.deviceID) }
        try await pair.client.send(.bookmark(LinkBookmark(conversationID: conversation, recordingTime: 9, createdAt: t0)))

        let (first, _) = try await pair.macEvents.next("bookmark with extra field") { $0.received }
        guard case .bookmark(let bookmark) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(bookmark.recordingTime, 3.5)
        let (second, _) = try await pair.macEvents.next("state with unknown phase") { $0.received }
        guard case .recordingState(let state) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(state.phase.rawValue, "levitating")
        let (third, _) = try await pair.macEvents.next("normal bookmark") { $0.received }
        guard case .bookmark(let normal) = third else { return XCTFail("\(third)") }
        XCTAssertEqual(normal.recordingTime, 9)

        let ignored = await pair.service.ignoredMessageCount(from: pair.phone.deviceID)
        XCTAssertEqual(ignored, 3)
        XCTAssertFalse(pair.macEvents.contains { $0.disconnectReason != nil })
        let connected = await pair.service.connectedPeers
        XCTAssertEqual(connected.count, 1)
        await pair.tearDown()
    }

    // MARK: Versions

    func testVersionNegotiationPicksTheHighestCommonVersion() async throws {
        var serviceConfiguration = LinkConfiguration.testLoopback()
        serviceConfiguration.supportedVersions = 1...2
        var clientConfiguration = LinkConfiguration.testLoopback()
        clientConfiguration.supportedVersions = 1...3
        let pair = try await LinkedPair.make(self, service: serviceConfiguration, client: clientConfiguration)
        let (macSide, phoneSide) = try await pair.connect()
        XCTAssertEqual(macSide.protocolVersion, 2)
        XCTAssertEqual(phoneSide.protocolVersion, 2)
        // Messages still flow at the agreed version.
        try await pair.client.send(.bookmark(LinkBookmark(conversationID: UUID(), recordingTime: 1, createdAt: t0)))
        _ = try await pair.macEvents.next("message") { $0.received }
        await pair.tearDown()
    }

    func testIncompatibleVersionsAreRefusedWithoutRetrying() async throws {
        var serviceConfiguration = LinkConfiguration.testLoopback()
        serviceConfiguration.supportedVersions = 1...2
        var clientConfiguration = LinkConfiguration.testLoopback()
        clientConfiguration.supportedVersions = 3...4
        let pair = try await LinkedPair.make(self, service: serviceConfiguration, client: clientConfiguration)
        try await pair.client.connect(to: pair.mac.deviceID, via: pair.endpoint)

        let failed = try await pair.phoneEvents.next("failed") { event -> LinkDisconnectReason? in
            if case .failed(let reason) = event.state { return reason }
            return nil
        }
        XCTAssertEqual(failed, .incompatibleVersion(peerVersions: 1...2))
        try await Task.sleep(nanoseconds: 300_000_000)
        let state = await pair.client.connectionState(of: pair.mac.deviceID)
        XCTAssertEqual(state, .failed(.incompatibleVersion(peerVersions: 1...2)))
        XCTAssertFalse(pair.macEvents.contains { $0.connected != nil })
        XCTAssertEqual(pair.phoneEvents.all.filter { $0.state == .connecting }.count, 1, "it shouldn't retry")
        await pair.tearDown()
    }

    func testVersionRangesNegotiate() {
        XCTAssertEqual(LinkVersionRange.negotiate(local: 1...2, remote: LinkVersionRange(1...3)), 2)
        XCTAssertEqual(LinkVersionRange.negotiate(local: 2...5, remote: LinkVersionRange(1...3)), 3)
        XCTAssertEqual(LinkVersionRange.negotiate(local: 1...1, remote: LinkVersionRange(1...1)), 1)
        XCTAssertNil(LinkVersionRange.negotiate(local: 1...2, remote: LinkVersionRange(3...4)))
        XCTAssertNil(LinkVersionRange.negotiate(local: 1...2, remote: LinkVersionRange(min: 3, max: 1)))
    }

    // MARK: Lifecycle

    func testReconnectsAfterTheConnectionDrops() async throws {
        let pair = try await LinkedPair.make(self, relay: (0, 0))
        try await pair.connect()

        pair.relay?.dropAll()

        let reason = try await pair.phoneEvents.next("phone saw the drop") { $0.disconnectReason }
        switch reason {
        case .connectionLost, .peerClosed: break
        default: XCTFail("unexpected reason \(reason)")
        }
        _ = try await pair.phoneEvents.next("retry scheduled") { event -> Bool? in
            if case .waitingToRetry = event.state { return true }
            return nil
        }
        let again = try await pair.phoneEvents.next("reconnected") { $0.connected }
        XCTAssertEqual(again.deviceID, pair.mac.deviceID)
        _ = try await pair.macEvents.next("Mac saw the drop") { $0.disconnectReason }
        _ = try await pair.macEvents.next("Mac reconnected") { $0.connected }
        let peers = await pair.service.connectedPeers
        XCTAssertEqual(peers.count, 1)

        try await pair.client.send(.bookmark(LinkBookmark(conversationID: UUID(), recordingTime: 2, createdAt: t0)))
        _ = try await pair.macEvents.next("message after reconnect") { $0.received }
        await pair.tearDown()
    }

    func testHeartbeatTimeoutEndsASilentConnectionAndReconnects() async throws {
        // A timeout of several intervals, so a busy CI machine stalling the loop briefly isn't mistaken
        // for a dead connection (and longer still where DAYBOOK_TEST_TIMEOUT_SCALE says it's starved).
        var configuration = LinkConfiguration.testLoopback()
        configuration.heartbeatInterval = 0.2
        configuration.heartbeatTimeout = TestTiming.scaled(1.2)
        let pair = try await LinkedPair.make(self, service: configuration, client: configuration, relay: (0, 0))
        try await pair.connect()
        try await Task.sleep(for: .seconds(configuration.heartbeatTimeout + 0.8))
        // Heartbeats keep a quiet but healthy connection up past the timeout. (If they didn't, what
        // follows would be measuring the wrong disconnection.)
        let early = (pair.phoneEvents.all + pair.macEvents.all).compactMap(\.disconnectReason)
        guard early.isEmpty else { return XCTFail("a healthy connection dropped: \(early)") }

        let relay = try XCTUnwrap(pair.relay)
        // Until both sides have given up, the phone can't come back: a new connection would replace
        // the Mac's silent session before its own timeout ended it.
        relay.refuseNewConnections(true)
        let frozenAt = Date()
        relay.freeze()

        let phoneReason = try await pair.phoneEvents.next("phone timeout", timeout: 5) { $0.disconnectReason }
        let phoneGaveUpBy = Date()
        XCTAssertEqual(phoneReason, .heartbeatTimeout)
        let macReason = try await pair.macEvents.next("Mac timeout", timeout: 5) { $0.disconnectReason }
        let macGaveUpBy = Date()
        XCTAssertEqual(macReason, .heartbeatTimeout)
        // Each side waits out the whole timeout after the last bytes the relay passed it, however late
        // a starved machine ran the last heartbeat before the freeze. (Measuring from the freeze
        // instead undercounts by up to an interval.)
        let lastToPhone = try XCTUnwrap(relay.lastDeliveryBeforeFreeze(upstream: false))
        let lastToMac = try XCTUnwrap(relay.lastDeliveryBeforeFreeze(upstream: true))
        XCTAssertGreaterThanOrEqual(phoneGaveUpBy.timeIntervalSince(lastToPhone), configuration.heartbeatTimeout)
        XCTAssertGreaterThanOrEqual(macGaveUpBy.timeIntervalSince(lastToMac), configuration.heartbeatTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(frozenAt), configuration.heartbeatTimeout + TestTiming.scaled(3.3))

        // New connections through the relay work again, so the phone comes back.
        relay.refuseNewConnections(false)
        _ = try await pair.phoneEvents.next("reconnected") { $0.connected }
        await pair.tearDown()
    }

    func testBackgroundClosesTheLinkAndForegroundRestoresIt() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()

        await pair.client.setActivity(.background)
        let reason = try await pair.phoneEvents.next("closed") { $0.disconnectReason }
        XCTAssertEqual(reason, .closedLocally)
        let macReason = try await pair.macEvents.next("Mac told") { $0.disconnectReason }
        XCTAssertEqual(macReason, .peerClosed)
        let suspended = await pair.client.connectionState(of: pair.mac.deviceID)
        XCTAssertEqual(suspended, .suspended)

        await pair.client.setActivity(.foreground)
        _ = try await pair.phoneEvents.next("back") { $0.connected }

        // Recording in the background keeps the connection, at a slower pace.
        await pair.client.setActivity(.backgroundRecording)
        try await Task.sleep(nanoseconds: 200_000_000)
        let state = await pair.client.connectionState(of: pair.mac.deviceID)
        XCTAssertEqual(state, .connected)
        await pair.tearDown()
    }

    // MARK: Clock

    func testClockOffsetIsEstimatedWithinToleranceOverADelayedLink() async throws {
        var macConfiguration = LinkConfiguration.testLoopback()
        macConfiguration.clock = OffsetClock(offset: 2.5)
        var phoneConfiguration = LinkConfiguration.testLoopback()
        phoneConfiguration.clockSamplesPerBurst = 5
        let pair = try await LinkedPair.make(self, service: macConfiguration, client: phoneConfiguration, relay: (0.04, 0.04))
        try await pair.connect()

        let estimate = try await pair.phoneEvents.next("estimate") { event -> LinkClockEstimate? in
            guard let clock = event.updated?.clock, clock.sampleCount >= 5 else { return nil }
            return clock
        }
        assertEstimate(estimate, offset: 2.5, up: 0.04, down: 0.04)
        XCTAssertEqual(estimate.localDate(fromPeer: t0.addingTimeInterval(2.5)).timeIntervalSince(t0), 2.5 - estimate.offset, accuracy: 1e-6)

        // The Mac measures too, and sees the phone behind it by the same amount.
        let macEstimate = try await pair.macEvents.next("Mac estimate") { event -> LinkClockEstimate? in
            guard let clock = event.updated?.clock, clock.sampleCount >= 4 else { return nil }
            return clock
        }
        assertEstimate(macEstimate, offset: -2.5, up: 0.04, down: 0.04)
        await pair.tearDown()
    }

    /// Lopsided delay biases the estimate by half the difference, which the reported uncertainty
    /// (half the round trip) always covers.
    func testLopsidedDelayStaysWithinTheReportedUncertainty() async throws {
        var macConfiguration = LinkConfiguration.testLoopback()
        macConfiguration.clock = OffsetClock(offset: -1.25)
        var phoneConfiguration = LinkConfiguration.testLoopback()
        phoneConfiguration.clockSamplesPerBurst = 5
        let pair = try await LinkedPair.make(self, service: macConfiguration, client: phoneConfiguration, relay: (0.06, 0.01))
        try await pair.connect()

        let estimate = try await pair.phoneEvents.next("estimate") { event -> LinkClockEstimate? in
            guard let clock = event.updated?.clock, clock.sampleCount >= 5 else { return nil }
            return clock
        }
        // Biased toward the slow direction by half the difference, as NTP predicts.
        assertEstimate(estimate, offset: -1.25, up: 0.06, down: 0.01)
        await pair.tearDown()
    }

    /// A trip through the relay takes at least its delay each way (`up` toward the peer, `down`
    /// back), plus whatever else the machine adds: scheduling, TLS, a loaded CPU. The estimate is
    /// off from the true offset by (up − down) / 2, give or take half of that extra, which the
    /// round trip reports. So the bound is tight on an idle machine and honest on a starved one,
    /// where a fixed tolerance (±20 ms) failed.
    private func assertEstimate(_ estimate: LinkClockEstimate, offset: TimeInterval, up: TimeInterval, down: TimeInterval,
                                file: StaticString = #filePath, line: UInt = #line) {
        // Clock reads and JSON dates are good to well under a millisecond.
        let epsilon = 0.002
        let floor = up + down
        XCTAssertGreaterThanOrEqual(estimate.roundTrip, floor - epsilon, "every round trip includes the relay's delays", file: file, line: line)
        let error = estimate.offset - offset
        let extra = max(0, estimate.roundTrip - floor)
        XCTAssertEqual(error, (up - down) / 2, accuracy: extra / 2 + epsilon,
                       "round trip \(estimate.roundTrip) s, of which \(extra) s beyond the relay", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(error), estimate.uncertainty + epsilon, "within the reported uncertainty", file: file, line: line)
    }

    func testClockFilterTrustsTheShortestRoundTrip() {
        var filter = LinkClockFilter(capacity: 4)
        let base = Date(timeIntervalSince1970: 1_000)
        func sample(sent: TimeInterval, up: TimeInterval, hold: TimeInterval, down: TimeInterval, offset: TimeInterval) -> LinkClockSample {
            let t1 = base.addingTimeInterval(sent)
            let t2 = t1.addingTimeInterval(up + offset)
            let t3 = t2.addingTimeInterval(hold)
            let t4 = t3.addingTimeInterval(down - offset)
            return LinkClockSample(t1: t1, t2: t2, t3: t3, t4: t4)
        }
        // A queued trip each way, then a clean one.
        filter.add(sample(sent: 0, up: 0.200, hold: 0.010, down: 0.005, offset: 3))
        filter.add(sample(sent: 1, up: 0.005, hold: 0.002, down: 0.150, offset: 3))
        filter.add(sample(sent: 2, up: 0.004, hold: 0.050, down: 0.004, offset: 3))
        let estimate = try! XCTUnwrap(filter.estimate)
        XCTAssertEqual(estimate.offset, 3, accuracy: 1e-6)
        XCTAssertEqual(estimate.roundTrip, 0.008, accuracy: 1e-6)
        XCTAssertEqual(estimate.sampleCount, 3)

        // Older samples fall out of the window.
        for i in 3..<7 { filter.add(sample(sent: Double(i), up: 0.1, hold: 0, down: 0.1, offset: 5)) }
        XCTAssertEqual(filter.samples.count, 4)
        XCTAssertEqual(filter.estimate!.offset, 5, accuracy: 1e-6)
    }

    // MARK: Record control

    func testRecordControlIsAcknowledgedOrRefused() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()

        let recorder = FakeRecorder(clockStart: t0)
        await pair.client.setRecordControlHandler { _, request in await recorder.handle(request) }

        let a = UUID(), b = UUID()
        let timing = LinkTiming(startedAt: t0, elapsed: 0.5, clockOffset: -2.5, clockUncertainty: 0.004)
        let start = LinkRecordRequest(action: .start, conversationID: a, timing: timing, sentAt: t0)
        let reply = try await pair.service.request(start, from: pair.phone.deviceID)
        XCTAssertEqual(reply.requestID, start.id)
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("\(reply)") }
        XCTAssertEqual(ack.conversationID, a)
        XCTAssertEqual(ack.startedAt, t0)
        XCTAssertEqual(ack.recordingID, "phone-1")
        XCTAssertFalse(ack.wasAlreadyRecording)
        let seen = await recorder.requests
        XCTAssertEqual(seen.first?.timing, timing)

        // Busy with another conversation: refused, with the reason and which conversation.
        let other = try await pair.service.request(LinkRecordRequest(action: .start, conversationID: b), from: pair.phone.deviceID)
        XCTAssertEqual(other.outcome, .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: a)))

        // The same request again (a retry after a lost reply) gets the first answer and doesn't
        // reach the recorder twice.
        let repeated = try await pair.service.request(start, from: pair.phone.deviceID)
        XCTAssertEqual(repeated.outcome, reply.outcome)
        let handled = await recorder.requests.count
        XCTAssertEqual(handled, 2)

        let stop = try await pair.service.request(LinkRecordRequest(action: .stop, conversationID: a), from: pair.phone.deviceID)
        guard case .accepted(let stopped) = stop.outcome else { return XCTFail("\(stop)") }
        XCTAssertNotNil(stopped.stoppedAt)
        let notRecording = try await pair.service.request(LinkRecordRequest(action: .stop, conversationID: a), from: pair.phone.deviceID)
        XCTAssertEqual(notRecording.outcome, .refused(LinkRecordRefusal(reason: .notRecording)))

        // The other direction: the Mac has no handler, so it refuses.
        let toMac = try await pair.client.request(LinkRecordRequest(action: .start, conversationID: a), from: pair.mac.deviceID)
        XCTAssertEqual(toMac.outcome, .refused(LinkRecordRefusal(reason: .unsupported)))
        await pair.tearDown()
    }

    func testRecordRequestTimesOutWhenTheAnswerNeverComes() async throws {
        var configuration = LinkConfiguration.testLoopback()
        configuration.requestTimeout = 0.2
        let pair = try await LinkedPair.make(self, service: configuration)
        try await pair.connect()
        await pair.client.setRecordControlHandler { _, _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .refused(LinkRecordRefusal(reason: .busy))
        }
        do {
            _ = try await pair.service.request(LinkRecordRequest(action: .start, conversationID: UUID()), from: pair.phone.deviceID)
            XCTFail()
        } catch let error as LinkError {
            XCTAssertEqual(error, .timedOut)
        }
        await pair.tearDown()
    }

    func testARequestRepeatedOnANewConnectionWhileBeingAnsweredReachesThePhoneOnce() async throws {
        // A microphone prompt outlasts the request's timeout; the Mac reconnects and asks again
        // with the same ID. The phone hears it once and both askers get its one answer.
        var configuration = LinkConfiguration.loopback()
        configuration.requestTimeout = 0.3
        let pair = try await LinkedPair.make(self, service: configuration, relay: (0, 0))
        try await pair.connect()
        let gate = AnswerGate()
        await pair.client.setRecordControlHandler { _, request in
            await gate.arrive()
            await gate.wait()
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: Date(), recordingID: "phone-1"))
        }
        let start = LinkRecordRequest(action: .start, conversationID: UUID())
        do {
            _ = try await pair.service.request(start, from: pair.phone.deviceID)
            XCTFail("the answer is still coming")
        } catch let error as LinkError {
            XCTAssertEqual(error, .timedOut)
        }
        pair.relay?.dropAll()
        _ = try await pair.macEvents.next("Mac saw the drop") { $0.disconnectReason }
        _ = try await pair.macEvents.next("Mac reconnected") { $0.connected }
        async let repeated = pair.service.request(start, from: pair.phone.deviceID)
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.open()
        let reply = try await repeated
        guard case .accepted(let ack) = reply.outcome else { return XCTFail("\(reply)") }
        XCTAssertEqual(ack.recordingID, "phone-1")
        let arrivals = await gate.arrivals
        XCTAssertEqual(arrivals, 1, "the phone's app heard the request once")
        // Later repeats get the same answer without reaching the app.
        let again = try await pair.service.request(start, from: pair.phone.deviceID)
        XCTAssertEqual(again.outcome, reply.outcome)
        let still = await gate.arrivals
        XCTAssertEqual(still, 1)
        await pair.tearDown()
    }

    // MARK: Unpairing

    func testUnpairingOnTheMacRemovesTheKeyOnBothSides() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()

        try await pair.service.unpair(pair.phone.deviceID)

        _ = try await pair.phoneEvents.next("phone told") { event -> Bool? in
            if case .unpaired(let id, let byPeer) = event, id == pair.mac.deviceID, byPeer { return true }
            return nil
        }
        XCTAssertEqual(try pair.macStore.records(), [])
        XCTAssertEqual(try pair.phoneStore.records(), [])
        do {
            try await pair.client.connect(to: pair.mac.deviceID, via: pair.endpoint)
            XCTFail()
        } catch let error as LinkError {
            XCTAssertEqual(error, .notPaired)
        }
        await pair.tearDown()
    }

    func testUnpairingOnThePhoneRemovesTheKeyOnBothSides() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.connect()

        try await pair.client.unpair(pair.mac.deviceID)

        _ = try await pair.macEvents.next("Mac told") { event -> Bool? in
            if case .unpaired(let id, let byPeer) = event, id == pair.phone.deviceID, byPeer { return true }
            return nil
        }
        XCTAssertEqual(try pair.macStore.records(), [])
        XCTAssertEqual(try pair.phoneStore.records(), [])
        await pair.tearDown()
    }

    /// The Mac forgot the phone while it was away: the phone's key no longer opens the listener,
    /// and it says so instead of retrying quickly. The key stays until an authenticated unpair.
    func testAPhoneTheMacForgotIsToldAuthenticationFailed() async throws {
        let pair = try await LinkedPair.make(self)
        try await pair.service.unpair(pair.phone.deviceID)
        try await pair.client.connect(to: pair.mac.deviceID, via: pair.endpoint)
        let failed = try await pair.phoneEvents.next("failed") { event -> LinkDisconnectReason? in
            if case .failed(let reason) = event.state { return reason }
            return nil
        }
        // The TLS handshake fails once the Mac's listener has dropped the key; a connection that
        // beats the listener's restart is refused as not paired instead.
        XCTAssertTrue([.authenticationFailed, .notPaired].contains(failed), "\(failed)")
        XCTAssertEqual(try pair.phoneStore.records().count, 1)
        await pair.tearDown()
    }
}

/// A phone recorder that answers record requests.
actor FakeRecorder {
    private(set) var requests: [LinkRecordRequest] = []
    private var recording: UUID?
    private let clockStart: Date
    private var count = 0

    init(clockStart: Date) { self.clockStart = clockStart }

    func handle(_ request: LinkRecordRequest) -> LinkRecordReply.Outcome {
        requests.append(request)
        switch (request.action, recording) {
        case (.start, nil):
            recording = request.conversationID
            count += 1
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: clockStart, recordingID: "phone-\(count)"))
        case (.start, let current?) where current == request.conversationID:
            return .accepted(LinkRecordAck(conversationID: current, wasAlreadyRecording: true))
        case (.start, let current?):
            return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: current))
        case (.stop, let current?) where current == request.conversationID:
            recording = nil
            return .accepted(LinkRecordAck(conversationID: current, stoppedAt: clockStart.addingTimeInterval(60)))
        default:
            return .refused(LinkRecordRefusal(reason: .notRecording))
        }
    }
}

/// Holds a record-control answer until the test lets it go, counting the requests that reach it.
actor AnswerGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() { arrivals += 1 }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
