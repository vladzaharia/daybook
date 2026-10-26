import CryptoKit
@testable import DaybookLink
import Foundation
@preconcurrency import Network
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

    /// A refusal ends pairing as "busy" or "not pairing" only before anything is committed. After
    /// the first commitment the peer has seen a reveal, so a refusal counts as a wrong code.
    func testRefusalIsBelievedOnlyBeforeTheFirstCommitment() throws {
        let code = LinkPairingCode(value: 482_913, expiresAt: .distantFuture)
        let busy = try LinkWire.encode(.pairing(.refuse(.init(reason: .busy))), version: 1)

        let early = PasskeyExchange(role: .initiator, code: code, local: device("iPhone"))
        _ = try early.start()
        XCTAssertThrowsError(try early.receive(busy)) { XCTAssertEqual($0 as? PasskeyExchange.Failure, .refused(.busy)) }

        let late = PasskeyExchange(role: .initiator, code: code, local: device("iPhone"))
        let mac = PasskeyExchange(role: .responder, code: code, local: device("Mac"))
        let accept = try mac.receive(try late.start())
        let commit = try late.receive(XCTUnwrap(accept.first))
        XCTAssertEqual(commit.count, 1, "the phone committed to bit 0")
        XCTAssertThrowsError(try late.receive(busy)) { XCTAssertEqual($0 as? PasskeyExchange.Failure, .codeMismatch) }
        XCTAssertEqual(LinkService.error(for: .codeMismatch), .codeRejected)
    }

    /// The Mac's side: a refusal never comes from a phone, so it's a failure that burns the code.
    func testResponderTreatsARefusalAsAMismatch() throws {
        let code = LinkPairingCode(value: 5, expiresAt: .distantFuture)
        let phone = PasskeyExchange(role: .initiator, code: code, local: device("iPhone"))
        let mac = PasskeyExchange(role: .responder, code: code, local: device("Mac"))
        _ = try mac.receive(try phone.start())
        let refuse = try LinkWire.encode(.pairing(.refuse(.init(reason: .notPairing))), version: 1)
        XCTAssertThrowsError(try mac.receive(refuse)) { XCTAssertEqual($0 as? PasskeyExchange.Failure, .codeMismatch) }
        XCTAssertNil(mac.outcome)
    }

    func testBurnedCodesAreSaltedDigestsThatExpire() throws {
        let store = MemoryLinkBurnedCodeStore()
        let now = Date()
        var burned = BurnedPairingCodes.load(from: store)
        burned.burn(482_913, until: now.addingTimeInterval(300), now: now)
        burned.save(to: store)

        let saved = try XCTUnwrap(store.load())
        XCTAssertNil(String(data: saved, encoding: .utf8)?.range(of: "482913"), "the digits are never stored")
        let loaded = BurnedPairingCodes.load(from: store)
        XCTAssertTrue(loaded.contains(482_913, now: now))
        XCTAssertFalse(loaded.contains(482_914, now: now))
        XCTAssertFalse(loaded.contains(482_913, now: now.addingTimeInterval(301)), "forgotten once the Mac's code has expired")
        // Another install hashes the same code differently.
        XCTAssertNotEqual(BurnedPairingCodes().salt, loaded.salt)
        // Expired entries are dropped when the next one is added.
        var later = loaded
        later.burn(1, until: now.addingTimeInterval(900), now: now.addingTimeInterval(600))
        XCTAssertEqual(later.entries.count, 1)
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

    func testClosingReplacingExpiringOrStoppingPairingRevokesAnExchangeAlreadyInProgress() async throws {
        for action in ["cancel", "replace", "expire", "stop"] {
            let clock = PairingTestClock()
            let (service, store, events, _, _) = try await makeService(codes: [123_456, 654_321]) { $0.clock = clock }
            let code = await service.beginPairing()
            let port = try await XCTUnwrapAsync(await service.port)
            let channel = RawChannel(port: port, psk: LinkTransport.pairingPSK)
            defer { channel.close() }
            try await channel.open()
            let exchange = PasskeyExchange(role: .initiator, code: code, local: Fixture.phone().pairingDevice)
            channel.send(try exchange.start())
            let accepted = try await XCTUnwrapAsync(try await channel.receive())
            switch action {
            case "cancel": await service.endPairing()
            case "replace": await service.beginPairing()
            case "expire": clock.advance(to: code.expiresAt.addingTimeInterval(1))
            default: await service.stop()
            }
            for reply in try exchange.receive(accepted) { channel.send(reply) }
            while let frame = try await channel.receive() {
                do {
                    for reply in try exchange.receive(frame) { channel.send(reply) }
                } catch { break }
                if exchange.isFinished { break }
            }
            XCTAssertFalse(exchange.isFinished, action)
            XCTAssertTrue(try store.records().isEmpty, action)
            XCTAssertFalse(events.contains { if case .paired = $0 { return true }; return false }, action)
            await service.stop()
        }
    }

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

    /// A device pretending to be the Mac (a spoofed Bonjour advert) answers the phone, guesses bit 0,
    /// learns it from the phone's reveal, and refuses as "busy" to keep the code alive for another
    /// round. The phone counts it as a wrong code and never sends that code again, even after a
    /// relaunch, so the impersonator can't collect the code bit by bit.
    func testMacImpersonatorRefusingAfterARevealBurnsTheCode() async throws {
        let impersonator = try await FakePairingMac.start(.refuseAfterFirstReveal)
        defer { impersonator.stop() }
        let store = MemoryLinkBurnedCodeStore()
        var configuration = LinkConfiguration.loopback()
        configuration.burnedCodes = store
        let client = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: configuration)

        do {
            _ = try await client.pair(with: impersonator.endpoint, code: "482 913")
            XCTFail("paired with an impersonator")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeRejected)
        }
        XCTAssertEqual(impersonator.revealsSeen, 1, "the phone revealed bit 0 before the refusal")
        do {
            _ = try await client.pair(with: impersonator.endpoint, code: "482913")
            XCTFail("a burned code was sent again")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeAlreadyUsed)
        }
        // After a relaunch, too.
        let relaunched = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: configuration)
        do {
            _ = try await relaunched.pair(with: impersonator.endpoint, code: "482 913")
            XCTFail("a burned code was sent again after a relaunch")
        } catch let error as LinkPairingError {
            XCTAssertEqual(error, .codeAlreadyUsed)
        }
        XCTAssertEqual(impersonator.attempts, 1)
    }

    /// The other way round: a refusal before anything is committed reveals nothing, so the code
    /// stays usable (the Mac may simply be busy for a moment).
    func testRefusalBeforeAnyCommitmentLeavesTheCodeUsable() async throws {
        let busy = try await FakePairingMac.start(.refuseAtBegin(.busy))
        defer { busy.stop() }
        let store = MemoryLinkBurnedCodeStore()
        var configuration = LinkConfiguration.loopback()
        configuration.burnedCodes = store
        let client = LinkClient(identity: Fixture.phone(), keyStore: MemoryLinkKeyStore(), configuration: configuration)
        for _ in 0..<2 {
            do {
                _ = try await client.pair(with: busy.endpoint, code: "482 913")
                XCTFail("paired while busy")
            } catch let error as LinkPairingError {
                XCTAssertEqual(error, .busy)
            }
        }
        XCTAssertEqual(busy.attempts, 2)
        XCTAssertFalse(BurnedPairingCodes.load(from: store).contains(482_913, now: Date()))
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

/// Listens on loopback with the public pairing PSK, like a Mac, and answers pairing as told.
private final class FakePairingMac: @unchecked Sendable {
    enum Behavior {
        case refuseAtBegin(PairingMessage.Refuse.Reason)
        /// Runs the exchange with a guessed code until the phone's first reveal, then refuses as busy.
        case refuseAfterFirstReveal
    }

    private let queue = DispatchQueue(label: "test.fake-mac")
    private let listener: NWListener
    private let behavior: Behavior
    private var channels: [LinkChannel] = []
    private let lock = NSLock()
    private var counts = (attempts: 0, reveals: 0)
    private var port: UInt16 = 0

    var attempts: Int { lock.withLock { counts.attempts } }
    var revealsSeen: Int { lock.withLock { counts.reveals } }
    var endpoint: LinkEndpoint { LinkEndpoint(host: "127.0.0.1", port: port) }

    private init(listener: NWListener, behavior: Behavior) {
        self.listener = listener
        self.behavior = behavior
    }

    static func start(_ behavior: Behavior) async throws -> FakePairingMac {
        let parameters = LinkTransport.parameters(psks: [LinkTransport.pairingPSK], allowPeerToPeer: false)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let mac = FakePairingMac(listener: try NWListener(using: parameters), behavior: behavior)
        mac.listener.newConnectionHandler = { [weak mac] connection in mac?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            mac.listener.stateUpdateHandler = { [weak mac] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    mac?.port = mac?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            mac.listener.start(queue: mac.queue)
        }
        return mac
    }

    private func accept(_ connection: NWConnection) {
        let channel = LinkChannel(connection: connection, queue: queue, clock: SystemLinkClock())
        channels.append(channel)
        lock.withLock { counts.attempts += 1 }
        let exchange = PasskeyExchange(role: .responder, code: LinkPairingCode(value: 0, expiresAt: .distantFuture),
                                       local: Fixture.mac().pairingDevice)
        channel.onFrame = { [weak self, weak channel] frame, _ in
            guard let self, let channel else { return }
            switch self.behavior {
            case .refuseAtBegin(let reason):
                channel.close(after: PasskeyExchange.refuseFrame(reason))
            case .refuseAfterFirstReveal:
                if case .pairing(.reveal) = try? LinkWire.decode(frame).message {
                    self.lock.withLock { self.counts.reveals += 1 }
                    channel.close(after: PasskeyExchange.refuseFrame(.busy))
                } else if let replies = try? exchange.receive(frame) {
                    replies.forEach(channel.send)
                } else {
                    channel.close()
                }
            }
        }
        channel.start()
    }

    func stop() {
        queue.sync {
            channels.forEach { $0.close() }
            channels.removeAll()
            listener.cancel()
        }
    }
}

private final class PairingTestClock: LinkClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(to date: Date) { lock.withLock { value = date } }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped, file: file, line: line)
}
