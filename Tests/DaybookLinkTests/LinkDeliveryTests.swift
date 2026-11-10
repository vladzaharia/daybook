@testable import DaybookLink
import DaybookTestSupport
import Foundation
import XCTest

/// What the link delivers when things go wrong: a reader that falls behind, a session that dies before its notes are
/// acknowledged, and clocks that drift or are stepped.
final class LinkDeliveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.25)

    // MARK: Event streams

    private func note(_ index: Int, in conversation: UUID) -> LinkMessage {
        .note(LinkNote(id: UUID(), conversationID: conversation, text: "Paragraph \(index)", time: Double(index), madeAt: t0, changedAt: t0))
    }

    private func levels(_ value: Double, in conversation: UUID) -> LinkMessage {
        .levels(LinkLevels(conversationID: conversation, values: [value], sentAt: t0))
    }

    /// A reader that stalls (its main actor busy) gets every control and app event, in order, and only the newest
    /// live readings; the rest are counted, not silently lost.
    func testAStalledReaderGetsEveryControlEventAndOnlyTheNewestLiveOnes() async throws {
        let hub = LinkEventHub()
        let stream = hub.stream()
        let phone = UUID(), conversation = UUID()
        let liveCount = LinkEventHub.liveCapacity * 3
        var sentNotes: [LinkMessage] = []
        for index in 0..<liveCount {
            hub.yield(.received(levels(Double(index) / Double(liveCount), in: conversation), from: phone))
            if index % 10 == 0 {
                let message = note(index, in: conversation)
                sentNotes.append(message)
                hub.yield(.received(message, from: phone))
            }
        }
        hub.yield(.disconnected(deviceID: phone, reason: .heartbeatTimeout))
        hub.finish()

        var notes: [LinkMessage] = [], live: [Double] = [], disconnected = false
        for await event in stream {
            switch event {
            case .received(.levels(let reading), _): live.append(reading.values[0])
            case .received(let message, _): notes.append(message)
            case .disconnected: disconnected = true
            default: XCTFail("unexpected \(event)")
            }
        }
        XCTAssertEqual(notes, sentNotes, "every app event, in order")
        XCTAssertTrue(disconnected, "control events are never dropped")
        XCTAssertEqual(live.count, LinkEventHub.liveCapacity)
        XCTAssertEqual(live, (liveCount - LinkEventHub.liveCapacity..<liveCount).map { Double($0) / Double(liveCount) }, "the newest, in order")
        XCTAssertEqual(hub.droppedLiveEvents, liveCount - LinkEventHub.liveCapacity)
    }

    /// Events reach a reader that keeps up as they come, and a released or cancelled stream stops listening.
    func testAStreamGoneStopsListening() async throws {
        let hub = LinkEventHub()
        let phone = UUID(), conversation = UUID()
        do {
            let stream = hub.stream()
            XCTAssertEqual(hub.subscriberCount, 1)
            withExtendedLifetime(stream) {}
        }
        hub.yield(.received(note(0, in: conversation), from: phone))
        XCTAssertEqual(hub.subscriberCount, 0, "a stream nobody holds isn't queued for")

        let stream = hub.stream()
        let reader = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        hub.yield(.received(note(1, in: conversation), from: phone))
        try await waitUntil("the reader to listen", timeout: 5) { hub.subscriberCount == 1 }
        reader.cancel()
        let count = await reader.value
        XCTAssertLessThanOrEqual(count, 1)
        try await waitUntil("the cancelled reader to go", timeout: 5) { hub.subscriberCount == 0 }
    }

    // MARK: Notes and bookmarks until acknowledged

    func testSessionsNumberNotesAndAcknowledgeWhatArrived() throws {
        var outbox = LinkReliableOutbox()
        let conversation = UUID()
        let sent = (0..<3).map { LinkReliableMessage(message: note($0, in: conversation), firstSentAt: t0, sends: 1) }
        XCTAssertEqual(sent.map { outbox.number($0) }, [1, 2, 3])
        outbox.heard(acked: 2)
        XCTAssertEqual(outbox.leftover, [sent[2]])
        XCTAssertEqual(outbox.peerAcknowledges, true)

        // A heartbeat with no acknowledgement is an older build's: nothing is kept for it.
        var older = LinkReliableOutbox()
        _ = older.number(sent[0])
        older.heard(acked: nil)
        XCTAssertTrue(older.leftover.isEmpty)
        _ = older.number(sent[1])
        XCTAssertTrue(older.leftover.isEmpty)

        // The wire: the note carries its place; heartbeats their acknowledgement; an older build's ping reads as none.
        let frame = try LinkWire.encode(.app(sent[0].message), version: 1, sequence: 7)
        XCTAssertTrue(String(decoding: frame, as: UTF8.self).contains("\"seq\":7"))
        let decoded = try LinkWire.decode(frame)
        XCTAssertEqual(decoded.message, .app(sent[0].message))
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertNil(try LinkWire.decode(LinkWire.encode(.app(sent[0].message), version: 1)).sequence)
        guard case .ping(let old) = try LinkWire.decode(Data(#"{"v":1,"type":"ping","body":{"sequence":4,"interval":5}}"#.utf8)).message else {
            return XCTFail()
        }
        XCTAssertNil(old.acked)
    }

    /// What a session ends without hearing acknowledged waits for the device's next one, a few sends at most, for an
    /// hour at most, and never for an older build.
    func testUnacknowledgedNotesWaitForTheNextSessionWithinBounds() {
        var keep = LinkReliableKeep()
        let mac = UUID(), conversation = UUID()
        var outbox = LinkReliableOutbox()
        let item = LinkReliableMessage(message: note(0, in: conversation), firstSentAt: t0, sends: 1)
        _ = outbox.number(item)
        keep.sessionEnded(with: mac, outbox: outbox, now: t0.addingTimeInterval(5))
        XCTAssertEqual(keep.count(for: mac), 1)
        XCTAssertEqual(keep.take(for: mac, now: t0.addingTimeInterval(10)), [item])
        XCTAssertEqual(keep.count(for: mac), 0)

        // Sent twice to a device not known to acknowledge: not again.
        var second = LinkReliableOutbox()
        var again = item
        again.sends = 2
        _ = second.number(again)
        keep.sessionEnded(with: mac, outbox: second, now: t0.addingTimeInterval(20))
        XCTAssertEqual(keep.count(for: mac), 0)

        // Known to acknowledge, a third send; past an hour, none.
        var acking = LinkReliableOutbox()
        acking.heard(acked: 0)
        _ = acking.number(again)
        keep.sessionEnded(with: mac, outbox: acking, now: t0.addingTimeInterval(30))
        XCTAssertEqual(keep.count(for: mac), 1)
        XCTAssertTrue(keep.take(for: mac, now: t0.addingTimeInterval(2 * 3_600)).isEmpty)

        // An older build: nothing kept, ever.
        var older = LinkReliableOutbox()
        _ = older.number(item)
        older.heard(acked: nil)
        _ = older.number(item)
        keep.sessionEnded(with: mac, outbox: older, now: t0)
        XCTAssertEqual(keep.count(for: mac), 0)
        XCTAssertEqual(keep.peerAcknowledges(mac), false)
    }

    /// A note sent into a session that has silently died arrives once the phone is back; one the Mac acknowledged
    /// isn't sent again.
    func testANoteSentIntoADeadSessionArrivesOnTheNextAndAnAcknowledgedOneIsntResent() async throws {
        var configuration = LinkConfiguration.testLoopback()
        configuration.heartbeatInterval = 0.2
        configuration.heartbeatTimeout = TestTiming.scaled(1.2)
        let pair = try await LinkedPair.make(self, service: configuration, client: configuration, relay: (0, 0))
        try await pair.connect()
        let conversation = UUID()
        let acknowledged = note(1, in: conversation), lost = note(2, in: conversation)

        try await pair.client.send(acknowledged)
        _ = try await pair.macEvents.next("the first note") { event -> Bool? in event.received?.0 == acknowledged ? true : nil }
        try await waitUntilAsync("the Mac's acknowledgement", timeout: 5) {
            await pair.client.unacknowledgedCount(to: pair.mac.deviceID) == 0
        }

        let relay = try XCTUnwrap(pair.relay)
        relay.refuseNewConnections(true)
        relay.freeze()
        try await pair.client.send(lost)
        let pending = await pair.client.unacknowledgedCount(to: pair.mac.deviceID)
        XCTAssertEqual(pending, 1, "sent, not acknowledged")
        _ = try await pair.phoneEvents.next("phone timeout", timeout: 5) { $0.disconnectReason }
        _ = try await pair.macEvents.next("Mac timeout", timeout: 5) { $0.disconnectReason }
        let kept = await pair.client.unacknowledgedCount(to: pair.mac.deviceID)
        XCTAssertEqual(kept, 1, "kept for the next session")

        relay.refuseNewConnections(false)
        _ = try await pair.phoneEvents.next("reconnected") { $0.connected }
        _ = try await pair.macEvents.next("the lost note, sent again") { event -> Bool? in event.received?.0 == lost ? true : nil }
        try await waitUntilAsync("the resend acknowledged", timeout: 5) {
            await pair.client.unacknowledgedCount(to: pair.mac.deviceID) == 0
        }
        let notes = pair.macEvents.all.compactMap { $0.received?.0 }.filter { if case .note = $0 { return true }; return false }
        XCTAssertEqual(notes, [acknowledged, lost], "the acknowledged note isn't sent again")
        await pair.tearDown()
    }

    // MARK: Clocks

    /// A sample exchanged at `local` seconds into a session with a peer whose continuous clock runs `drift` fast and
    /// whose wall clock reads `wallOffset` ahead, with `up` and `down` seconds on the wire.
    private func sample(at local: TimeInterval, drift: Double, wallOffset: TimeInterval, up: TimeInterval = 0.004,
                        down: TimeInterval = 0.004, stamped: Bool = true) -> LinkClockSample {
        let base: TimeInterval = 50_000, peerBase: TimeInterval = 9_000
        func peerMonotonic(_ t: TimeInterval) -> TimeInterval { peerBase + (t - base) * (1 + drift) }
        let m1 = base + local, m2 = m1 + up, m3 = m2 + 0.001, m4 = m3 + down
        // The wall clocks: this side's runs with its continuous clock; the peer's with its own, `wallOffset` ahead.
        let t1 = t0.addingTimeInterval(local), t4 = t0.addingTimeInterval(m4 - base)
        let t2 = t0.addingTimeInterval(peerMonotonic(m2) - peerBase + wallOffset)
        let t3 = t0.addingTimeInterval(peerMonotonic(m3) - peerBase + wallOffset)
        return stamped ? LinkClockSample(t1: t1, t2: t2, t3: t3, t4: t4, m1: m1, m2: peerMonotonic(m2), m3: peerMonotonic(m3), m4: m4)
            : LinkClockSample(t1: t1, t2: t2, t3: t3, t4: t4)
    }

    /// Over an hour of samples every two minutes, with some trips queued, the drift between the clocks is found
    /// within 10 ppm, and the offset is carried on to the latest sample by it.
    func testDriftIsFittedOverTheSession() throws {
        var filter = LinkClockFilter()
        let drift = 100e-6
        for minute in stride(from: 0, through: 60, by: 2) {
            let queued = minute % 6 == 2
            filter.add(sample(at: Double(minute) * 60, drift: drift, wallOffset: 3, up: queued ? 0.08 : 0.004 + Double(minute % 3) * 0.0005))
        }
        let estimate = try XCTUnwrap(filter.estimate)
        XCTAssertEqual(try XCTUnwrap(estimate.drift), drift, accuracy: 10e-6)
        XCTAssertEqual(try XCTUnwrap(estimate.driftSpan), 3_600, accuracy: 1)
        // The peer's wall clock is 3 s ahead at the start and gains 100 ppm: 3.36 s ahead an hour on.
        XCTAssertEqual(estimate.offset, 3 + drift * 3_600, accuracy: 0.005)
        XCTAssertNotNil(estimate.monotonicOffset)
    }

    /// A wall clock stepped mid-session (NTP, the person) doesn't move the drift, and the offset follows the step.
    func testAWallClockStepLeavesTheDriftAlone() throws {
        var filter = LinkClockFilter()
        let drift = -40e-6
        for minute in stride(from: 0, through: 60, by: 2) {
            filter.add(sample(at: Double(minute) * 60, drift: drift, wallOffset: minute < 30 ? 1 : 3.5))
        }
        let estimate = try XCTUnwrap(filter.estimate)
        XCTAssertEqual(try XCTUnwrap(estimate.drift), drift, accuracy: 10e-6)
        XCTAssertEqual(estimate.offset, 3.5 + drift * 3_600, accuracy: 0.005, "the samples from before the step are left behind")
    }

    /// A peer that doesn't stamp its continuous clock (an older build): the shortest trip's offset, as before.
    func testSamplesWithoutContinuousStampsGiveNoDrift() throws {
        var filter = LinkClockFilter()
        for minute in stride(from: 0, through: 10, by: 2) {
            filter.add(sample(at: Double(minute) * 60, drift: 0, wallOffset: 2, up: 0.004 + Double(minute) * 0.001, stamped: false))
        }
        let estimate = try XCTUnwrap(filter.estimate)
        XCTAssertNil(estimate.drift)
        XCTAssertNil(estimate.monotonicOffset)
        XCTAssertEqual(estimate.offset, 2, accuracy: 0.001)
        XCTAssertEqual(estimate.roundTrip, 0.008, accuracy: 1e-6)
    }

    /// Over the link: a phone whose continuous clock runs 1% fast is measured so by the Mac.
    func testTheLinkMeasuresAPeersDrift() async throws {
        var macConfiguration = LinkConfiguration.testLoopback()
        macConfiguration.clockResampleInterval = 0.1
        macConfiguration.clockDriftMinimumSpan = 1
        var phoneConfiguration = LinkConfiguration.testLoopback()
        phoneConfiguration.clock = FastContinuousClock(rate: 1.01)
        let pair = try await LinkedPair.make(self, service: macConfiguration, client: phoneConfiguration)
        try await pair.connect()
        let estimate = try await pair.macEvents.next("a drift", timeout: 10) { event -> LinkClockEstimate? in
            guard let clock = event.updated?.clock, clock.drift != nil, (clock.driftSpan ?? 0) >= 1.5 else { return nil }
            return clock
        }
        XCTAssertEqual(try XCTUnwrap(estimate.drift), 0.01, accuracy: 0.002)
        XCTAssertEqual(estimate.offset, 0, accuracy: 0.05, "the wall clocks agree")
        await pair.tearDown()
    }
}

/// A wall clock in step with this machine's, and a continuous clock running `rate` times as fast.
private struct FastContinuousClock: LinkClock {
    let rate: Double
    private let start = LinkMonotonicClock.seconds()
    func now() -> Date { Date() }
    func monotonic() -> TimeInterval { start + (LinkMonotonicClock.seconds() - start) * rate }
}
