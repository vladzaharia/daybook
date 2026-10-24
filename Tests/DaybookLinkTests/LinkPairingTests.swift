import CryptoKit
@testable import DaybookLink
import Foundation
import XCTest

final class LinkPairingTests: XCTestCase {

    // MARK: The exchange on its own

    private func device(_ name: String) -> PairingDevice {
        PairingDevice(deviceID: UUID(), name: name, deviceClass: name == "Mac" ? .mac : .iPhone, appVersion: "2.0")
    }

    /// Runs two exchanges against each other in memory. Returns the error, if any, from each side.
    private func run(_ initiator: PasskeyExchange, _ responder: PasskeyExchange,
                     tamper: (Data) -> Data = { $0 }) -> (initiator: Error?, responder: Error?) {
        var toResponder = [try! initiator.start()]
        var toInitiator: [Data] = []
        while !toResponder.isEmpty || !toInitiator.isEmpty {
            for frame in toResponder {
                do { toInitiator += try responder.receive(tamper(frame)) } catch { return (nil, error) }
            }
            toResponder = []
            for frame in toInitiator {
                do { toResponder += try initiator.receive(tamper(frame)) } catch { return (error, nil) }
            }
            toInitiator = []
        }
        return (nil, nil)
    }

    func testExchangeWithTheSameCodeDerivesTheSameKeyOnBothSides() throws {
        let code = LinkPairingCode(value: 482_913, expiresAt: .distantFuture)
        let phone = device("iPhone"), mac = device("Mac")
        let initiator = PasskeyExchange(role: .initiator, code: code, local: phone)
        let responder = PasskeyExchange(role: .responder, code: code, local: mac)

        let errors = run(initiator, responder)

        XCTAssertNil(errors.initiator)
        XCTAssertNil(errors.responder)
        let a = try XCTUnwrap(initiator.outcome), b = try XCTUnwrap(responder.outcome)
        XCTAssertEqual(a.linkKey, b.linkKey)
        XCTAssertEqual(a.linkKey.count, 32)
        XCTAssertEqual(a.pskIdentity, b.pskIdentity)
        XCTAssertEqual(a.peer, mac)
        XCTAssertEqual(b.peer, phone)
    }

    func testExchangeWithADifferentCodeFailsAtTheFirstDifferentBit() {
        // 0b...0110 vs 0b...0111: the codes differ in bit 0, so the responder stops in round 0.
        let initiator = PasskeyExchange(role: .initiator, code: LinkPairingCode(value: 6, expiresAt: .distantFuture), local: device("iPhone"))
        let responder = PasskeyExchange(role: .responder, code: LinkPairingCode(value: 7, expiresAt: .distantFuture), local: device("Mac"))

        let errors = run(initiator, responder)

        XCTAssertEqual(errors.responder as? PasskeyExchange.Failure, .codeMismatch)
        XCTAssertNil(initiator.outcome)
        XCTAssertNil(responder.outcome)
    }

    /// A device in the middle swaps in its own public key towards the Mac. Without the code it
    /// must guess every bit; here it guesses "all zeros" and is caught at the first 1.
    func testDeviceInTheMiddleCannotCompleteWithoutTheCode() {
        let code = LinkPairingCode(value: 0b1, expiresAt: .distantFuture)
        let attacker = PasskeyExchange(role: .initiator, code: LinkPairingCode(value: 0, expiresAt: .distantFuture), local: device("Evil"))
        let mac = PasskeyExchange(role: .responder, code: code, local: device("Mac"))

        let errors = run(attacker, mac)

        XCTAssertEqual(errors.responder as? PasskeyExchange.Failure, .codeMismatch)
        XCTAssertNil(mac.outcome)
    }

    /// Changing anything in flight (here: the device name in `pair.begin`) breaks the exchange,
    /// because both sides confirm over the whole transcript.
    func testTamperingWithTheTranscriptIsDetected() {
        let code = LinkPairingCode(value: 123_456, expiresAt: .distantFuture)
        let initiator = PasskeyExchange(role: .initiator, code: code, local: device("iPhone"))
        let responder = PasskeyExchange(role: .responder, code: code, local: device("Mac"))
        var tampered = false
        let errors = run(initiator, responder) { frame in
            guard !tampered, let text = String(data: frame, encoding: .utf8), text.contains("pair.begin") else { return frame }
            tampered = true
            return Data(text.replacingOccurrences(of: "iPhone", with: "iPhonf").utf8)
        }
        XCTAssertTrue(tampered)
        // The responder hashed the altered begin, the initiator the original, so their
        // confirmations disagree.
        XCTAssertNotNil(errors.responder ?? errors.initiator)
        XCTAssertNil(responder.outcome)
    }

    func testReflectedPublicKeyIsRejected() throws {
        let code = LinkPairingCode(value: 1, expiresAt: .distantFuture)
        let initiator = PasskeyExchange(role: .initiator, code: code, local: device("iPhone"))
        let begin = try initiator.start()
        // Echo the initiator's own key back as the "Mac's".
        guard case .pairing(.begin(let b)) = try LinkWire.decode(begin).message else { return XCTFail() }
        let accept = try LinkWire.encode(.pairing(.accept(.init(device: device("Mac"), publicKey: b.publicKey))), version: 1)
        XCTAssertThrowsError(try initiator.receive(accept)) { XCTAssertEqual($0 as? PasskeyExchange.Failure, .invalidKey) }
    }

    func testCodesParseAndFormat() {
        XCTAssertEqual(LinkPairingCode(typed: "048 213")?.value, 48_213)
        XCTAssertEqual(LinkPairingCode(typed: "048-213")?.digits, "048213")
        XCTAssertEqual(LinkPairingCode(value: 7, expiresAt: .distantFuture).formatted, "000 007")
        XCTAssertNil(LinkPairingCode(typed: "12345"))
        XCTAssertNil(LinkPairingCode(typed: "1234567"))
        XCTAssertNil(LinkPairingCode(typed: "12a456"))
        XCTAssertNil(LinkPairingCode(typed: "１２３４５６"))
    }

    // MARK: Over loopback

    private func makeService(codes: [UInt32], configure: (inout LinkConfiguration) -> Void = { _ in })
        async throws -> (LinkService, MemoryLinkKeyStore, EventRecorder, LinkEndpoint, LinkIdentity) {
        var configuration = LinkConfiguration.loopback()
        let sequence = CodeSequence(codes)
        configuration.codeGenerator = { sequence.next(lifetime: $0, now: $1) }
        configure(&configuration)
        let mac = Fixture.mac()
        let store = MemoryLinkKeyStore()
        let service = LinkService(identity: mac, keyStore: store, configuration: configuration)
        let events = EventRecorder(service.events())
        addTeardownBlock { await service.stop() }
        try await service.start()
        let port = try await XCTUnwrapAsync(await service.port)
        return (service, store, events, LinkEndpoint(host: "127.0.0.1", port: port), mac)
    }

    func testPairingWithTheCodeShownOnTheMacPairsBothSidesAndConnects() async throws {
        let (service, macStore, macEvents, endpoint, mac) = try await makeService(codes: [482_913])
        let phone = Fixture.phone()
        let phoneStore = MemoryLinkKeyStore()
        let client = LinkClient(identity: phone, keyStore: phoneStore, configuration: .loopback())
        let phoneEvents = EventRecorder(client.events())
        addTeardownBlock { await client.disconnect(from: mac.deviceID) }

        let code = await service.beginPairing()
        XCTAssertEqual(code.formatted, "482 913")
        _ = try await macEvents.next("code shown") { $0.pairingCode == .some(code) ? true : nil }

        let paired = try await client.pair(with: endpoint, code: "482 913")

        XCTAssertEqual(paired.deviceID, mac.deviceID)
        XCTAssertEqual(paired.name, "Studio Mac")
        let macRecord = try XCTUnwrap(try macStore.record(for: phone.deviceID))
        let phoneRecord = try XCTUnwrap(try phoneStore.record(for: mac.deviceID))
        XCTAssertEqual(macRecord.linkKey, phoneRecord.linkKey)
        XCTAssertEqual(macRecord.pskIdentity, phoneRecord.pskIdentity)
        XCTAssertEqual(macRecord.deviceClass, .iPhone)
        let macPaired = try await macEvents.next("Mac paired") { event -> LinkPairedDevice? in
            if case .paired(let device) = event { return device }; return nil
        }
        XCTAssertEqual(macPaired.deviceID, phone.deviceID)
        _ = try await macEvents.next("code hidden") { $0.pairingCode == .some(nil) ? true : nil }
        let pairingCodeNow = await service.pairingCode
        XCTAssertNil(pairingCodeNow)

        // The new key works for a session straight away.
        try await client.connect(to: mac.deviceID, via: endpoint)
        let peer = try await phoneEvents.next("connected") { $0.connected }
        XCTAssertEqual(peer.deviceID, mac.deviceID)
        XCTAssertTrue(peer.capabilities.canProcess)
        let macPeer = try await macEvents.next("Mac connected") { $0.connected }
        XCTAssertEqual(macPeer.name, "Pocket iPhone")

        await client.disconnect(from: mac.deviceID)
        await service.stop()
    }

    func testWrongCodeIsRejectedAndTheMacShowsANewCode() async throws {
        let (service, macStore, macEvents, endpoint, _) = try await makeService(codes: [111_111, 222_222, 333_333])
        let phoneStore = MemoryLinkKeyStore()
        let client = LinkClient(identity: Fixture.phone(), keyStore: phoneStore, configuration: .loopback())

        await service.beginPairing()

        do {
            _ = try await client.pair(with: endpoint, code: "111 112")
            XCTFail("a wrong code paired")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeRejected)
        }
        XCTAssertEqual(try macStore.records(), [])
        XCTAssertEqual(try phoneStore.records(), [])
        let failure = try await macEvents.next("failure") { $0.pairingFailure }
        XCTAssertEqual(failure, .codeRejected)
        // The attempt burned the code: the Mac moved on to the next one.
        _ = try await macEvents.next("new code") { event -> Bool? in
            if case .pairingCode(let code?) = event, code.value == 222_222 { return true }
            return nil
        }
        let shown = await service.pairingCode
        XCTAssertEqual(shown?.value, 222_222)

        // The phone never sends a failed code again…
        do {
            _ = try await client.pair(with: endpoint, code: "111112")
            XCTFail("a burned code was sent again")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeAlreadyUsed)
        }
        // …and the old right code is no good either.
        do {
            _ = try await client.pair(with: endpoint, code: "111111")
            XCTFail("a replaced code paired")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeRejected)
        }
        // The current code works.
        let shownNow = await service.pairingCode
        let current = try XCTUnwrap(shownNow)
        XCTAssertEqual(current.value, 333_333)
        _ = try await client.pair(with: endpoint, code: current.digits)
        XCTAssertEqual(try macStore.records().count, 1)
        await service.stop()
    }

    func testPairingClosesAfterTooManyFailures() async throws {
        let (service, _, macEvents, endpoint, _) = try await makeService(codes: [100_000, 200_000, 300_000]) {
            $0.maxPairingFailures = 2
        }
        let client = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        await service.beginPairing()
        for guess in ["999 991", "999 992"] {
            do { _ = try await client.pair(with: endpoint, code: guess); XCTFail() } catch {}
        }
        _ = try await macEvents.next("closed") { $0.pairingFailure == .tooManyAttempts ? true : nil }
        let shown = await service.pairingCode
        XCTAssertNil(shown)
        do {
            _ = try await client.pair(with: endpoint, code: "300000")
            XCTFail("paired while pairing was closed")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .notPairing)
        }
        await service.stop()
    }

    func testPairingIsRefusedWhenTheMacIsNotShowingACode() async throws {
        let (service, _, _, endpoint, _) = try await makeService(codes: [1])
        let client = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: .loopback())
        do {
            _ = try await client.pair(with: endpoint, code: "000001")
            XCTFail()
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .notPairing)
        }
        // Not burned: the Mac never saw an exchange.
        await service.beginPairing()
        _ = try await client.pair(with: endpoint, code: "000001")
        await service.stop()
    }

    /// Replays a recorded successful pairing, frame for frame, against the same Mac showing the
    /// same code. The Mac's fresh key makes every recorded commitment stale.
    func testReplayedPairingHandshakeIsRejected() async throws {
        let (service, macStore, macEvents, endpoint, _) = try await makeService(codes: [271_828])
        _ = endpoint
        let port = try await XCTUnwrapAsync(await service.port)
        let phone = Fixture.phone().pairingDevice
        let code = await service.beginPairing()

        // A genuine pairing, recording what the phone sent.
        let genuine = RawChannel(port: port, psk: LinkTransport.pairingPSK)
        try await genuine.open()
        let exchange = PasskeyExchange(role: .initiator, code: code, local: phone)
        var sent = [try exchange.start()]
        genuine.send(sent[0])
        while !exchange.isFinished {
            let frame = try await XCTUnwrapAsync(try await genuine.receive())
            for reply in try exchange.receive(frame) {
                sent.append(reply)
                genuine.send(reply)
            }
        }
        let original = try XCTUnwrap(try macStore.record(for: phone.deviceID))
        XCTAssertEqual(original.linkKey, exchange.outcome?.linkKey)
        _ = try await macEvents.next("paired") { event -> Bool? in if case .paired = event { return true }; return nil }

        // Same code again, then the recording, in lockstep.
        let again = await service.beginPairing()
        XCTAssertEqual(again.value, code.value)
        let replay = RawChannel(port: port, psk: LinkTransport.pairingPSK)
        try await replay.open()
        var answers: [WireMessage] = []
        for frame in sent {
            replay.send(frame)
            guard let answer = try await replay.receive() else { break }
            let message = try LinkWire.decode(answer).message
            answers.append(message)
            if case .pairing(.fail) = message { break }
        }

        XCTAssertTrue(answers.contains { if case .pairing(.fail) = $0 { return true }; return false }, "\(answers)")
        // The first recorded reveal is where it falls apart: begin, commit 0, reveal 0.
        XCTAssertEqual(answers.count, 3)
        let failure = try await macEvents.next("replay failed") { $0.pairingFailure }
        XCTAssertEqual(failure, .codeRejected)
        XCTAssertEqual(try macStore.record(for: phone.deviceID)?.linkKey, original.linkKey)
        XCTAssertEqual(try macStore.records().count, 1)
        genuine.close()
        replay.close()
        await service.stop()
    }

    /// A session hello is bound to its TLS session: copied into another session, by a device with
    /// the key or without it, it's refused.
    func testReplayedSessionHelloIsRefused() async throws {
        let pair = try await LinkedPair.make(self)
        let port = try await XCTUnwrapAsync(await pair.service.port)
        let record = try XCTUnwrap(try pair.phoneStore.record(for: pair.mac.deviceID))
        let psk = LinkTransport.PSK(record)

        func hello(for channel: RawChannel) throws -> Data {
            let exporter = try XCTUnwrap(channel.exporter())
            let auth = LinkSession.auth(key: record.linkKey, sender: .client, exporter: exporter,
                                        clientID: pair.phone.deviceID, serverID: pair.mac.deviceID)
            return try LinkWire.encode(.hello(Hello(versions: LinkVersionRange(1...1), deviceID: pair.phone.deviceID,
                                                    serverID: pair.mac.deviceID, capabilities: pair.phone.capabilities,
                                                    auth: auth, heartbeatInterval: 5)), version: 1)
        }

        // Genuine: welcomed.
        let first = RawChannel(port: port, psk: psk)
        try await first.open()
        let recorded = try hello(for: first)
        first.send(recorded)
        let welcome = try LinkWire.decode(try await XCTUnwrapAsync(try await first.receive())).message
        guard case .welcome(let w) = welcome else { return XCTFail("\(welcome)") }
        XCTAssertEqual(w.deviceID, pair.mac.deviceID)
        _ = try await pair.macEvents.next("genuine session") { $0.connected }

        // Replayed by someone who only has the public pairing PSK, and by someone with the key.
        for replayPSK in [LinkTransport.pairingPSK, psk] {
            let replay = RawChannel(port: port, psk: replayPSK)
            try await replay.open()
            replay.send(recorded)
            let answer = try LinkWire.decode(try await XCTUnwrapAsync(try await replay.receive())).message
            XCTAssertEqual(answer, .refused(Refusal(reason: .authenticationFailed, versions: nil)))
            let next = try await replay.receive()
            XCTAssertNil(next, "the connection should close after the refusal")
        }
        // Only the genuine session ever connected.
        XCTAssertEqual(pair.macEvents.all.compactMap(\.connected).count, 1)
        first.close()
        await pair.tearDown()
    }

    func testUnknownPhoneIsRefused() async throws {
        let pair = try await LinkedPair.make(self)
        let port = try await XCTUnwrapAsync(await pair.service.port)
        let stranger = UUID()
        let channel = RawChannel(port: port, psk: LinkTransport.pairingPSK)
        try await channel.open()
        let auth = LinkSession.auth(key: PasskeyExchange.randomBytes(32), sender: .client, exporter: try XCTUnwrap(channel.exporter()),
                                    clientID: stranger, serverID: pair.mac.deviceID)
        channel.send(try LinkWire.encode(.hello(Hello(versions: LinkVersionRange(1...1), deviceID: stranger, serverID: pair.mac.deviceID,
                                                      capabilities: pair.phone.capabilities, auth: auth, heartbeatInterval: nil)),
                                         version: 1))
        let answer = try LinkWire.decode(try await XCTUnwrapAsync(try await channel.receive())).message
        XCTAssertEqual(answer, .refused(Refusal(reason: .notPaired, versions: nil)))
        await pair.tearDown()
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped, file: file, line: line)
}
