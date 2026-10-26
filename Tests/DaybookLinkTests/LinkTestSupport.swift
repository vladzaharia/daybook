import CryptoKit
@testable import DaybookLink
import DaybookTestSupport
import Foundation
@preconcurrency import Network
import XCTest

// Everything here stays on 127.0.0.1 inside the test process. Nothing is advertised.

struct TestTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Collects a stream's events so tests can wait for them in order.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LinkEvent] = []
    private var cursor = 0
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LinkEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ event: LinkEvent) { lock.withLock { events.append(event) } }

    var all: [LinkEvent] { lock.withLock { events } }

    /// The next event after the last one returned that `match` accepts.
    func next<T>(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                 _ match: (LinkEvent) -> T?) async throws -> T {
        try await waitFor(what, timeout: timeout, poll: .milliseconds(5), file: file, line: line, state: { "\(self.all)" }) {
            lock.withLock {
                for index in cursor..<events.count {
                    if let value = match(events[index]) {
                        cursor = index + 1
                        return value
                    }
                }
                return nil
            }
        }
    }

    /// Whether any event so far matches.
    func contains(_ match: (LinkEvent) -> Bool) -> Bool { all.contains(where: match) }
}

extension LinkEvent {
    var connected: LinkPeer? { if case .connected(let peer) = self { return peer }; return nil }
    var updated: LinkPeer? { if case .peerUpdated(let peer) = self { return peer }; return nil }
    var received: (LinkMessage, UUID)? { if case .received(let message, let from) = self { return (message, from) }; return nil }
    var disconnectReason: LinkDisconnectReason? {
        if case .disconnected(_, let reason) = self { return reason }
        return nil
    }
    var pairingCode: LinkPairingCode?? { if case .pairingCode(let code) = self { return .some(code) }; return nil }
    var pairingFailure: LinkPairingError? { if case .pairingFailed(let error) = self { return error }; return nil }
    var state: LinkConnectionState? { if case .connectionState(_, let state) = self { return state }; return nil }
}

extension LinkConfiguration {
    /// `loopback()`, its timeouts stretched by DAYBOOK_TEST_TIMEOUT_SCALE: a machine starved enough
    /// to need longer waits also misses heartbeats and handshakes for longer.
    static func testLoopback() -> LinkConfiguration {
        var configuration = LinkConfiguration.loopback()
        configuration.heartbeatTimeout = TestTiming.scaled(configuration.heartbeatTimeout)
        configuration.handshakeTimeout = TestTiming.scaled(configuration.handshakeTimeout)
        configuration.requestTimeout = TestTiming.scaled(configuration.requestTimeout)
        configuration.pairingTimeout = TestTiming.scaled(configuration.pairingTimeout)
        return configuration
    }
}

/// A clock running ahead of (or behind) this machine's.
struct OffsetClock: LinkClock {
    let offset: TimeInterval
    func now() -> Date { Date().addingTimeInterval(offset) }
}

/// Codes from a list, for deterministic pairing tests.
final class CodeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt32]
    init(_ values: [UInt32]) { self.values = values }
    func next(lifetime: TimeInterval, now: Date) -> LinkPairingCode {
        let value = lock.withLock { values.count > 1 ? values.removeFirst() : values[0] }
        return LinkPairingCode(value: value, expiresAt: now.addingTimeInterval(lifetime))
    }
}

// MARK: Fixtures

enum Fixture {
    static let libraryID = UUID()

    static func mac(_ id: UUID = UUID()) -> LinkIdentity {
        LinkIdentity(deviceID: id, name: "Studio Mac", deviceClass: .mac, appVersion: "2.0", libraryID: libraryID, canProcess: true)
    }

    static func phone(_ id: UUID = UUID()) -> LinkIdentity {
        LinkIdentity(deviceID: id, name: "Pocket iPhone", deviceClass: .iPhone, appVersion: "2.0", libraryID: libraryID)
    }

    /// Stores holding a pairing between the two, as if they had paired.
    static func pairedStores(mac: LinkIdentity, phone: LinkIdentity,
                             pskIdentity: Data? = nil) -> (mac: MemoryLinkKeyStore, phone: MemoryLinkKeyStore) {
        let key = PasskeyExchange.randomBytes(32)
        let identity = pskIdentity ?? PasskeyExchange.randomBytes(16)
        let now = Date()
        let macStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: phone.deviceID, name: phone.name, deviceClass: phone.deviceClass,
                                                             pairedAt: now, linkKey: key, pskIdentity: identity)])
        let phoneStore = MemoryLinkKeyStore([LinkPairingRecord(deviceID: mac.deviceID, name: mac.name, deviceClass: mac.deviceClass,
                                                               pairedAt: now, linkKey: key, pskIdentity: identity)])
        return (macStore, phoneStore)
    }
}

/// A Mac service and a phone client that are already paired, optionally talking through a relay.
struct LinkedPair: Sendable {
    let mac: LinkIdentity
    let phone: LinkIdentity
    let macStore: MemoryLinkKeyStore
    let phoneStore: MemoryLinkKeyStore
    let service: LinkService
    let client: LinkClient
    let macEvents: EventRecorder
    let phoneEvents: EventRecorder
    let relay: DelayingRelay?
    let endpoint: LinkEndpoint

    static func make(_ test: XCTestCase, service serviceConfiguration: LinkConfiguration = .testLoopback(),
                     client clientConfiguration: LinkConfiguration = .testLoopback(),
                     relay delays: (up: TimeInterval, down: TimeInterval)? = nil,
                     pskIdentity: Data? = nil) async throws -> LinkedPair {
        let mac = Fixture.mac(), phone = Fixture.phone()
        let stores = Fixture.pairedStores(mac: mac, phone: phone, pskIdentity: pskIdentity)
        let service = LinkService(identity: mac, keyStore: stores.mac, configuration: serviceConfiguration)
        let client = LinkClient(identity: phone, keyStore: stores.phone, configuration: clientConfiguration)
        let macEvents = EventRecorder(service.events())
        let phoneEvents = EventRecorder(client.events())
        try await service.start()
        let port = try await XCTUnwrapAsync(await service.port)
        var relay: DelayingRelay?
        var endpoint = LinkEndpoint(host: "127.0.0.1", port: port)
        if let delays {
            let started = try await DelayingRelay.start(to: port, upstreamDelay: delays.up, downstreamDelay: delays.down)
            relay = started
            endpoint = LinkEndpoint(host: "127.0.0.1", port: started.port)
        }
        let pair = LinkedPair(mac: mac, phone: phone, macStore: stores.mac, phoneStore: stores.phone, service: service, client: client,
                              macEvents: macEvents, phoneEvents: phoneEvents, relay: relay, endpoint: endpoint)
        // Runs even when the test fails part-way, so nothing outlives it.
        test.addTeardownBlock { await pair.tearDown() }
        return pair
    }

    /// Connects and waits until both sides have an authenticated session.
    @discardableResult
    func connect() async throws -> (macSide: LinkPeer, phoneSide: LinkPeer) {
        try await client.connect(to: mac.deviceID, via: endpoint)
        let phoneSide = try await phoneEvents.next("phone connected") { $0.connected }
        let macSide = try await macEvents.next("Mac connected") { $0.connected }
        return (macSide, phoneSide)
    }

    func tearDown() async {
        await client.disconnect(from: mac.deviceID)
        await service.stop()
        relay?.close()
    }
}

// MARK: TCP relay

/// Set once, on one queue.
final class Once: @unchecked Sendable {
    var done = false
}

/// A loopback TCP relay that delays bytes each way, and can freeze (stop forwarding without
/// closing, like Wi-Fi that silently went away), refuse new connections, or drop every connection.
final class DelayingRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.relay")
    private let listener: NWListener
    private let targetPort: UInt16
    private let upstreamDelay: TimeInterval
    private let downstreamDelay: TimeInterval
    private var pipes: [(inbound: NWConnection, outbound: NWConnection, id: Int)] = []
    private var frozen: Set<Int> = []
    private var refusing = false
    /// When each pipe last passed bytes on, toward the service (upstream) and toward the client.
    private var lastDelivered: [Int: (upstream: Date?, downstream: Date?)] = [:]
    private var nextID = 0
    private(set) var port: UInt16 = 0

    private init(listener: NWListener, targetPort: UInt16, upstreamDelay: TimeInterval, downstreamDelay: TimeInterval) {
        self.listener = listener
        self.targetPort = targetPort
        self.upstreamDelay = upstreamDelay
        self.downstreamDelay = downstreamDelay
    }

    static func start(to targetPort: UInt16, upstreamDelay: TimeInterval = 0, downstreamDelay: TimeInterval = 0) async throws -> DelayingRelay {
        let parameters = Self.noDelayTCP()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let relay = DelayingRelay(listener: try NWListener(using: parameters), targetPort: targetPort,
                                  upstreamDelay: upstreamDelay, downstreamDelay: downstreamDelay)
        try await relay.begin()
        return relay
    }

    private func begin() async throws {
        listener.newConnectionHandler = { [weak self] inbound in self?.accept(inbound) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    self?.port = self?.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    once.done = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ inbound: NWConnection) {
        guard !refusing else { inbound.cancel(); return }
        let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!, using: Self.noDelayTCP())
        let id = nextID
        nextID += 1
        pipes.append((inbound, outbound, id))
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: Conveyor(destination: outbound, delay: upstreamDelay, pipe: id, upstream: true), id: id)
        pump(from: outbound, to: Conveyor(destination: inbound, delay: downstreamDelay, pipe: id, upstream: false), id: id)
    }

    /// Delivers what it's given, in order, `delay` after it arrived. (Separate `asyncAfter`
    /// blocks may run out of order within their leeway, which would scramble a TCP stream.)
    private final class Conveyor {
        let destination: NWConnection
        let delay: TimeInterval
        let pipe: Int
        let upstream: Bool
        var items: [(data: Data?, due: DispatchTime)] = []
        var running = false

        init(destination: NWConnection, delay: TimeInterval, pipe: Int, upstream: Bool) {
            self.destination = destination
            self.delay = delay
            self.pipe = pipe
            self.upstream = upstream
        }
    }

    /// `nil` data closes the destination.
    private func enqueue(_ data: Data?, on conveyor: Conveyor) {
        conveyor.items.append((data, .now() + conveyor.delay))
        if !conveyor.running { advance(conveyor) }
    }

    private func advance(_ conveyor: Conveyor) {
        guard let head = conveyor.items.first else { conveyor.running = false; return }
        conveyor.running = true
        queue.asyncAfter(deadline: head.due) { [weak self] in
            guard let self else { return }
            let item = conveyor.items.removeFirst()
            // Frozen, what was still in flight is lost too, so nothing arrives after the freeze
            // (however late a starved machine runs this).
            if !self.frozen.contains(conveyor.pipe) {
                if let data = item.data {
                    var delivered = self.lastDelivered[conveyor.pipe] ?? (nil, nil)
                    if conveyor.upstream { delivered.upstream = Date() } else { delivered.downstream = Date() }
                    self.lastDelivered[conveyor.pipe] = delivered
                    conveyor.destination.send(content: data, completion: .contentProcessed { _ in })
                } else {
                    conveyor.destination.cancel()
                }
            }
            self.advance(conveyor)
        }
    }

    private func pump(from source: NWConnection, to conveyor: Conveyor, id: Int) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // A frozen pipe passes on nothing, not even the close: silence, as when Wi-Fi drops.
            let frozen = self.frozen.contains(id)
            if let data, !data.isEmpty, !frozen { self.enqueue(data, on: conveyor) }
            if isComplete || error != nil {
                if !frozen { self.enqueue(nil, on: conveyor) }
                return
            }
            self.pump(from: source, to: conveyor, id: id)
        }
    }

    private static func noDelayTCP() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Existing connections stop carrying bytes but stay open. New connections work.
    func freeze() { queue.sync { frozen.formUnion(pipes.map(\.id)) } }

    /// New connections are closed as soon as they arrive (true) or carried again (false).
    func refuseNewConnections(_ refuse: Bool) { queue.sync { refusing = refuse } }

    /// The last time a frozen connection passed bytes on toward the service (`upstream`) or toward
    /// the client: after it, the receiving side heard nothing more on that connection.
    func lastDeliveryBeforeFreeze(upstream: Bool) -> Date? {
        queue.sync {
            frozen.compactMap { upstream ? lastDelivered[$0]?.upstream : lastDelivered[$0]?.downstream }.max()
        }
    }

    /// Closes every connection through the relay.
    func dropAll() {
        queue.sync {
            for pipe in pipes {
                pipe.inbound.forceCancel()
                pipe.outbound.forceCancel()
            }
            pipes.removeAll()
        }
    }

    func close() {
        dropAll()
        listener.cancel()
    }
}

// MARK: Raw channel

/// A bare framed TLS connection to the service, for sending what a well-behaved client wouldn't.
final class RawChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.raw")
    private let channel: LinkChannel
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var ended: LinkChannelEnd?
    private var ready = false

    init(port: UInt16, psk: LinkTransport.PSK) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                      using: LinkTransport.parameters(psks: [psk], allowPeerToPeer: false))
        channel = LinkChannel(connection: connection, queue: queue, clock: SystemLinkClock())
    }

    func open(timeout: TimeInterval = 5) async throws {
        queue.sync {
            channel.onReady = { [weak self] in self?.lock.withLock { self?.ready = true } }
            channel.onFrame = { [weak self] frame, _ in self?.lock.withLock { self?.inbox.append(frame) } }
            channel.onEnd = { [weak self] end in self?.lock.withLock { self?.ended = end } }
            channel.start()
        }
        let deadline = Date().addingTimeInterval(TestTiming.scaled(timeout))
        while !lock.withLock({ ready }) {
            if let ended = lock.withLock({ ended }) { throw TestTimeout(description: "raw channel ended: \(ended)") }
            if Date() > deadline { throw TestTimeout(description: "raw channel not ready") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func exporter() -> Data? { queue.sync { channel.exporter() } }

    func send(_ frame: Data) { queue.async { self.channel.send(frame) } }

    /// The next frame, or nil once the connection has ended and nothing is left.
    func receive(timeout: TimeInterval = 5) async throws -> Data? {
        let deadline = Date().addingTimeInterval(TestTiming.scaled(timeout))
        while true {
            let (frame, isOver): (Data?, Bool) = lock.withLock {
                if !inbox.isEmpty { return (inbox.removeFirst(), false) }
                return (nil, ended != nil)
            }
            if let frame { return frame }
            if isOver { return nil }
            if Date() > deadline { throw TestTimeout(description: "no frame") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func close() { queue.async { self.channel.close() } }
}
