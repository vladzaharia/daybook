import Foundation
@preconcurrency import Network
import Synchronization

// MARK: Identity and configuration

/// This device, as the other side sees it.
public struct LinkIdentity: Sendable, Equatable {
    /// Stable for the install. The apps persist it (DeviceKind identity on the Mac).
    public var deviceID: UUID
    public var name: String
    public var deviceClass: LinkDeviceClass
    public var appVersion: String
    public var libraryID: UUID?
    public var canProcess: Bool
    public var features: [String]
    /// The sync replica ID, sent in capabilities so the other side can match library records to it.
    public var syncDeviceID: String?
    /// What it does with its own models for other devices (a Mac's transcription, speakers, summaries).
    public var processing: LinkProcessingCapabilities?

    public init(deviceID: UUID, name: String, deviceClass: LinkDeviceClass, appVersion: String, libraryID: UUID? = nil,
                canProcess: Bool = false, features: [String] = [], syncDeviceID: String? = nil,
                processing: LinkProcessingCapabilities? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.deviceClass = deviceClass
        self.appVersion = appVersion
        self.libraryID = libraryID
        self.canProcess = canProcess
        self.features = features
        self.syncDeviceID = syncDeviceID
        self.processing = processing
    }

    var capabilities: LinkCapabilities {
        LinkCapabilities(deviceClass: deviceClass, name: name, appVersion: appVersion, libraryID: libraryID,
                         canProcess: canProcess, features: features, syncDeviceID: syncDeviceID, processing: processing)
    }

    var pairingDevice: PairingDevice {
        PairingDevice(deviceID: deviceID, name: name, deviceClass: deviceClass, appVersion: appVersion)
    }
}

/// Timings and switches. The defaults suit the apps; tests shorten them.
public struct LinkConfiguration: Sendable {
    public enum Discovery: Sendable, Equatable {
        /// Advertise (Mac) or browse (phone) `_daybook-link._tcp` with Bonjour.
        case bonjour
        /// No Bonjour at all: connect to explicit endpoints. Tests and diagnostics.
        case disabled
    }

    public var discovery: Discovery = .bonjour
    /// Mac: listen only on loopback. Tests.
    public var loopbackOnly = false
    /// Mac: the port to listen on; nil lets the system choose (Bonjour carries it).
    public var port: UInt16?
    /// Allow AWDL (peer-to-peer Wi-Fi) as well as the shared network. Off: it costs battery.
    public var allowPeerToPeer = false
    /// Phone: watch the network path (Wi-Fi gone, network changed) to pause and resume retries.
    public var followsNetworkChanges = true

    /// Heartbeats in the foreground. The connection is declared dead after `heartbeatTimeout`
    /// without hearing anything. The slower side of a pair sets the pace.
    public var heartbeatInterval: TimeInterval = 5
    public var heartbeatTimeout: TimeInterval = 15
    /// Heartbeats while recording in the background (iPhone with a Live Activity).
    public var backgroundHeartbeatInterval: TimeInterval = 20
    public var backgroundHeartbeatTimeout: TimeInterval = 60
    /// After a wake or a network change, how long a quick liveness probe may take.
    public var probeTimeout: TimeInterval = 3

    /// From TCP connect to an authenticated session.
    public var handshakeTimeout: TimeInterval = 10
    /// How long a record request waits for its reply.
    public var requestTimeout: TimeInterval = 10

    /// How long a pairing code is shown before it's replaced.
    public var pairingCodeLifetime: TimeInterval = 5 * 60
    /// How long one pairing attempt may take.
    public var pairingTimeout: TimeInterval = 60
    /// Failed attempts before the Mac closes pairing.
    public var maxPairingFailures = 5
    /// Phone: codes that failed from it, kept across launches so none is ever sent again.
    public var burnedCodes: any LinkBurnedCodeStore = DefaultsLinkBurnedCodeStore()

    /// Reconnection backoff. Authentication failures jump straight to the maximum.
    public var reconnect = LinkBackoff()
    public var backgroundReconnect = LinkBackoff(initial: 2, maximum: 60)

    /// Clock samples sent in a burst after connecting, how far apart, and how often a single
    /// sample is repeated afterwards (0 = never).
    public var clockSamplesPerBurst = 6
    public var clockSampleSpacing: TimeInterval = 0.2
    public var clockResampleInterval: TimeInterval = 120
    /// The shortest span of a session's samples the clocks' drift is fitted over.
    public var clockDriftMinimumSpan: TimeInterval = 60

    public var clock: any LinkClock = SystemLinkClock()

    /// Versions this side offers. Only tests and staged rollouts change it.
    var supportedVersions: ClosedRange<Int> = LinkProtocol.supportedVersions
    /// Mac: whether a connection comes from the local network; tests stand in for other networks.
    var isLocalEndpoint: (@Sendable (NWEndpoint) -> Bool) = { LinkLocalNetwork.isLocal($0) }
    /// Pairing codes; tests inject fixed ones.
    var codeGenerator: (@Sendable (TimeInterval, Date) -> LinkPairingCode) = { LinkPairingCode.random(validFor: $0, now: $1) }

    public init() {}

    /// Loopback only, no Bonjour, short timers. For tests in one process.
    public static func loopback() -> LinkConfiguration {
        var configuration = LinkConfiguration()
        configuration.discovery = .disabled
        configuration.loopbackOnly = true
        configuration.followsNetworkChanges = false
        configuration.heartbeatInterval = 0.5
        configuration.heartbeatTimeout = 3
        configuration.handshakeTimeout = 3
        configuration.requestTimeout = 3
        configuration.pairingTimeout = 5
        configuration.burnedCodes = MemoryLinkBurnedCodeStore()
        configuration.reconnect = LinkBackoff(initial: 0.05, maximum: 0.5, jitter: 0)
        configuration.clockSamplesPerBurst = 4
        configuration.clockSampleSpacing = 0.02
        configuration.clockResampleInterval = 0
        return configuration
    }
}

// MARK: Endpoints and peers

/// Where to reach a Mac: a Bonjour result or an address.
public struct LinkEndpoint: Sendable, Hashable, CustomStringConvertible {
    let endpoint: NWEndpoint

    init(_ endpoint: NWEndpoint) { self.endpoint = endpoint }

    public init(host: String, port: UInt16) {
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }

    public var description: String { "\(endpoint)" }
}

/// A connected, authenticated device.
public struct LinkPeer: Sendable, Equatable, Identifiable {
    public var id: UUID { deviceID }
    public var deviceID: UUID
    public var capabilities: LinkCapabilities
    public var protocolVersion: Int
    public var connectedAt: Date
    /// This device's estimate of the peer's clock, once samples are in.
    public var clock: LinkClockEstimate?

    public var name: String { capabilities.name }
    public var deviceClass: LinkDeviceClass { capabilities.deviceClass }
}

/// A Mac the phone can see on the network.
public struct LinkDiscoveredMac: Sendable, Equatable, Identifiable {
    public var id: String { serviceName }
    /// Bonjour service name; the Mac's name.
    public var serviceName: String
    public var endpoint: LinkEndpoint
    /// Set when this is a Mac the phone is paired with.
    public var pairedDeviceID: UUID?
    /// Whether it has the phone's library open (nil when either side has none).
    public var sharesLibrary: Bool?
    /// Whether it's showing a pairing code right now.
    public var isPairing: Bool
    public var protocolVersions: ClosedRange<Int>?

    public init(serviceName: String, endpoint: LinkEndpoint, pairedDeviceID: UUID? = nil, sharesLibrary: Bool? = nil,
                isPairing: Bool = false, protocolVersions: ClosedRange<Int>? = nil) {
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.pairedDeviceID = pairedDeviceID
        self.sharesLibrary = sharesLibrary
        self.isPairing = isPairing
        self.protocolVersions = protocolVersions
    }

    /// A Mac with another library open (another Apple ID, or another library), never paired here: it's
    /// shown, so the person can tell it from no Mac at all, but it isn't offered for pairing.
    public var usesAnotherLibrary: Bool { pairedDeviceID == nil && sharesLibrary == false }
}

/// Whether the phone can find Macs on the network.
public enum LinkDiscoveryState: Sendable, Equatable {
    /// Not browsing.
    case idle
    /// Browsing; Macs arrive as `.discovered`.
    case searching
    /// The person declined (or turned off) Local Network for Daybook, so no Mac can be found until
    /// it's allowed in the system's Settings.
    case localNetworkDenied
}

// MARK: States and events

/// Why a session ended.
public enum LinkDisconnectReason: Sendable, Equatable {
    /// This side closed it (disconnect, background, stop).
    case closedLocally
    /// The other side said goodbye or closed.
    case peerClosed
    /// The connection failed or went away.
    case connectionLost(String)
    /// Nothing heard within the heartbeat timeout.
    case heartbeatTimeout
    /// No authenticated session within the handshake timeout.
    case handshakeTimeout
    /// The key didn't match: the pairing is gone on the other side, or this isn't that device.
    case authenticationFailed
    /// The other side doesn't know this device.
    case notPaired
    /// No protocol version in common. `peerVersions` is what the other side speaks.
    case incompatibleVersion(peerVersions: ClosedRange<Int>?)
    /// The pair was removed (by either side).
    case unpaired
    /// A newer connection from the same device took over.
    case replaced
    case protocolError(String)
}

/// The phone's connection to one Mac.
public enum LinkConnectionState: Sendable, Equatable {
    case idle
    /// Browsing for the Mac.
    case searching
    case connecting
    case connected
    /// Retrying after `delay` seconds.
    case waitingToRetry(delay: TimeInterval)
    /// No usable local network.
    case waitingForNetwork
    /// In the background without a recording: not kept alive.
    case suspended
    /// Stopped retrying on its own; needs the person (re-pair, update).
    case failed(LinkDisconnectReason)
}

/// What the iPhone app is doing, which decides how hard the link works.
public enum LinkActivity: Sendable, Equatable {
    /// In the foreground: browse, connect, normal heartbeats.
    case foreground
    /// In the background while recording (Live Activity): keep the connection, slower heartbeats.
    case backgroundRecording
    /// In the background otherwise: close everything; iOS would suspend it anyway.
    case background
}

public enum LinkEvent: Sendable {
    /// Phone: Macs on the network, each saying whether it shares this library.
    case discovered([LinkDiscoveredMac])
    /// Phone: whether Macs can be found (browsing, not, or refused Local Network).
    case discovery(LinkDiscoveryState)
    /// Mac: show this code; nil when pairing closes.
    case pairingCode(LinkPairingCode?)
    case paired(LinkPairedDevice)
    case pairingFailed(LinkPairingError)
    case unpaired(deviceID: UUID, byPeer: Bool)
    /// Phone: the connection to one Mac changed.
    case connectionState(deviceID: UUID, LinkConnectionState)
    case connected(LinkPeer)
    /// Capabilities or clock estimate changed.
    case peerUpdated(LinkPeer)
    case disconnected(deviceID: UUID, reason: LinkDisconnectReason)
    case received(LinkMessage, from: UUID)
}

public enum LinkError: Error, Sendable, Equatable {
    case notStarted
    case notConnected
    case notPaired
    case timedOut
    case disconnected
    case listenerFailed(String)
}

/// Answers record requests from the other side.
public typealias LinkRecordControlHandler = @Sendable (LinkPeer, LinkRecordRequest) async -> LinkRecordReply.Outcome

// MARK: Event fan-out

/// Hands each event to every subscriber. Each `events()` call gets its own stream.
///
/// A subscriber that falls behind (its main actor stalled) never loses a control or app event: those queue without
/// limit. Only the live feeds, another device's levels and captions, keep just the newest `liveCapacity` waiting,
/// the oldest dropped and counted (`droppedLiveEvents`), so a stall can't fill memory with meter readings.
final class LinkEventHub: Sendable {
    /// How many live events (levels, captions) a subscriber may have waiting.
    static let liveCapacity = 64

    private let subscribers = Mutex<[UUID: LinkEventBuffer]>([:])
    private let dropped = Atomic<Int>(0)

    /// Live events dropped because a subscriber fell behind, across subscribers, since the hub began.
    var droppedLiveEvents: Int { dropped.load(ordering: .relaxed) }
    /// Streams still listening (tests).
    var subscriberCount: Int { subscribers.withLock { $0.count } }

    func stream() -> AsyncStream<LinkEvent> {
        let buffer = LinkEventBuffer(liveCapacity: Self.liveCapacity) { [weak self] count in
            _ = self?.dropped.add(count, ordering: .relaxed)
        }
        let id = UUID()
        subscribers.withLock { $0[id] = buffer }
        // The stream holds the subscription; when the stream is gone (dropped, or its task cancelled), so is the
        // subscriber, and nothing more queues for it.
        let subscription = LinkEventSubscription { [weak self] in
            buffer.finish()
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return AsyncStream(unfolding: {
            _ = subscription
            return await buffer.next()
        }, onCancel: { subscription.end() })
    }

    func yield(_ event: LinkEvent) {
        let targets = subscribers.withLock { Array($0.values) }
        for buffer in targets { buffer.push(event) }
    }

    func finish() {
        let targets = subscribers.withLock { subscribers in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for buffer in targets { buffer.finish() }
    }
}

extension LinkEvent {
    /// A live feed's reading: another device's input level or its live captions, which the next one supersedes or adds
    /// to. Only these are dropped when a subscriber falls behind.
    var isLive: Bool {
        switch self {
        case .received(.levels, _), .received(.captions, _): return true
        default: return false
        }
    }
}

/// Ends a subscription once, when its stream is cancelled or released.
final class LinkEventSubscription: Sendable {
    private let onEnd: Mutex<(@Sendable () -> Void)?>

    init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = Mutex(onEnd) }

    func end() {
        let action = onEnd.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }

    deinit { end() }
}

/// One subscriber's waiting events, in arrival order: every control and app event, and the newest `liveCapacity` live
/// ones.
final class LinkEventBuffer: Sendable {
    private struct State {
        var events: [LinkEvent] = []
        var head = 0
        var live = 0
        var waiter: CheckedContinuation<LinkEvent?, Never>?
        var finished = false
    }

    private let liveCapacity: Int
    private let onDrop: @Sendable (Int) -> Void
    private let state = Mutex(State())

    init(liveCapacity: Int, onDrop: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.liveCapacity = max(1, liveCapacity)
        self.onDrop = onDrop
    }

    /// Live events waiting now (tests).
    var waitingLive: Int { state.withLock { $0.live } }
    /// Events waiting now (tests).
    var waiting: Int { state.withLock { $0.events.count - $0.head } }

    func push(_ event: LinkEvent) {
        let live = event.isLive
        let (waiter, dropped): (CheckedContinuation<LinkEvent?, Never>?, Bool) = state.withLock { state in
            guard !state.finished else { return (nil, false) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (waiter, false)
            }
            state.events.append(event)
            guard live else { return (nil, false) }
            state.live += 1
            guard state.live > liveCapacity,
                  let oldest = state.events[state.head...].firstIndex(where: \.isLive) else { return (nil, false) }
            state.events.remove(at: oldest)
            state.live -= 1
            return (nil, true)
        }
        if dropped { onDrop(1) }
        waiter?.resume(returning: event)
    }

    /// The next event, waiting for one; nil once the buffer is finished and nothing is left.
    func next() async -> LinkEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LinkEvent?, Never>) in
                let ready: LinkEvent?? = state.withLock { state in
                    if state.head < state.events.count {
                        let event = state.events[state.head]
                        state.head += 1
                        if event.isLive { state.live -= 1 }
                        // Reclaim what's been read once it's most of the array.
                        if state.head >= 256, state.head * 2 >= state.events.count {
                            state.events.removeFirst(state.head)
                            state.head = 0
                        }
                        return .some(event)
                    }
                    if state.finished { return .some(nil) }
                    state.waiter = continuation
                    return .none
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            finish()
        }
    }

    /// No more events: what's waiting is still read, then nil.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<LinkEvent?, Never>? in
            state.finished = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }
}
