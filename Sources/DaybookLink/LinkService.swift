import Foundation
@preconcurrency import Network

/// The Mac's end of the link: listens (and advertises over Bonjour), pairs phones with a code it
/// shows, accepts their authenticated sessions, and talks to them.
///
/// Everything runs on one serial queue, which is also the actor's executor, so Network.framework
/// callbacks and actor state never race.
public actor LinkService {
    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let keyStore: any LinkKeyStore
    private let configuration: LinkConfiguration
    private let hub = LinkEventHub()
    private var identity: LinkIdentity

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var isRunning = false
    private var isRebuilding = false
    private var rebuildPending = false
    private var afterRebuild: [() -> Void] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var listenerFailures = 0
    private var advertisement: LinkAdvertisement?

    /// Connections that haven't said what they are yet.
    private var unrouted: [ObjectIdentifier: LinkChannel] = [:]
    private var sessions: [ObjectIdentifier: LinkSession] = [:]
    private var peers: [UUID: LinkSession] = [:]
    private var answeredByDevice: [UUID: [UUID: LinkRecordReply]] = [:]
    private var recordHandler: LinkRecordControlHandler?

    private struct PairingWindow {
        var code: LinkPairingCode
        var failures = 0
        var attempt: ObjectIdentifier?
        var expiry: DispatchWorkItem
    }
    private var pairing: PairingWindow?
    private var pairingChannel: LinkChannel?

    public init(identity: LinkIdentity, keyStore: any LinkKeyStore, configuration: LinkConfiguration = LinkConfiguration()) {
        queue = DispatchSerialQueue(label: "local.daybook.link.service")
        self.identity = identity
        self.keyStore = keyStore
        self.configuration = configuration
    }

    deinit {
        let listener = self.listener
        let sessions = Array(self.sessions.values)
        let channels = Array(unrouted.values) + [pairingChannel].compactMap { $0 }
        pairing?.expiry.cancel()
        let hub = self.hub
        queue.async {
            listener?.cancel()
            sessions.forEach { $0.close(.closedLocally) }
            channels.forEach { $0.close() }
            hub.finish()
        }
    }

    /// A stream of everything that happens. Each call returns a new stream.
    public nonisolated func events() -> AsyncStream<LinkEvent> { hub.stream() }

    // MARK: Lifecycle

    /// Starts listening (and advertising, with `.bonjour` discovery). Returns once the listener is
    /// ready.
    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        listenerFailures = 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            openListener(port: configuration.port.flatMap(NWEndpoint.Port.init(rawValue:)))
        }
    }

    /// Says goodbye to every phone and stops listening and advertising.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        endPairing()
        for session in Array(sessions.values) { session.close(.closedLocally) }
        for channel in Array(unrouted.values) { channel.close() }
        unrouted.removeAll()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        // A new salt next time, so the tags can't be followed from one run to the next.
        advertisement = nil
        resumeStart(throwing: LinkError.notStarted)
    }

    /// The port the listener is on (loopback tests connect to it directly).
    public var port: UInt16? { listener?.port?.rawValue ?? listenerPort?.rawValue }

    /// Call after the Mac wakes: probes every phone and restarts the listener if it failed.
    public func systemDidWake() {
        for session in peers.values { session.probe() }
        if isRunning, listener == nil, !isRebuilding { openListener(port: listenerPort) }
    }

    public func updateIdentity(_ identity: LinkIdentity) {
        self.identity = identity
        for session in sessions.values { session.update(identity: identity) }
        advertise()
    }

    // MARK: Pairing

    /// Opens pairing and returns the code to show. Calling it again replaces the code.
    @discardableResult
    public func beginPairing() -> LinkPairingCode {
        let failures = pairing?.failures ?? 0
        pairing?.expiry.cancel()
        let previousChannel = pairingChannel
        pairingChannel = nil
        pairing = nil
        previousChannel?.close()
        let code = configuration.codeGenerator(configuration.pairingCodeLifetime, configuration.clock.now())
        let expiry = DispatchWorkItem { [weak self] in
            self?.assumeIsolated { service in
                guard service.pairing?.code == code else { return }
                service.closePairing(failure: .expired)
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.pairingCodeLifetime, execute: expiry)
        pairing = PairingWindow(code: code, failures: failures, expiry: expiry)
        hub.yield(.pairingCode(code))
        advertise()
        return code
    }

    public func endPairing() {
        guard pairing != nil else { return }
        closePairing(failure: nil)
    }

    /// The code being shown, if pairing is open.
    public var pairingCode: LinkPairingCode? { pairing?.code }

    public func pairedDevices() throws -> [LinkPairedDevice] { try keyStore.records().map(\.device) }

    /// Forgets a phone: tells it (when connected), removes the key, and stops accepting it.
    public func unpair(_ deviceID: UUID) throws {
        if let session = peers[deviceID] { session.sendUnpairAndClose() }
        try keyStore.remove(deviceID: deviceID)
        answeredByDevice[deviceID] = nil
        hub.yield(.unpaired(deviceID: deviceID, byPeer: false))
        rebuildListener()
    }

    // MARK: Peers and messages

    public var connectedPeers: [LinkPeer] { peers.values.compactMap(\.peer).sorted { $0.connectedAt < $1.connectedAt } }

    /// Sends to one phone, or to every connected phone when `deviceID` is nil.
    public func send(_ message: LinkMessage, to deviceID: UUID? = nil) throws {
        let targets = deviceID.map { peers[$0].map { [$0] } ?? [] } ?? Array(peers.values)
        guard !targets.isEmpty else { throw LinkError.notConnected }
        for session in targets { session.send(message) }
    }

    /// Asks a phone to start or stop recording, and waits for its answer.
    public func request(_ request: LinkRecordRequest, from deviceID: UUID) async throws -> LinkRecordReply {
        guard let session = peers[deviceID] else { throw LinkError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(request) { continuation.resume(with: $0) }
        }
    }

    /// Answers record requests from phones. Without one, every request is refused as unsupported.
    public func setRecordControlHandler(_ handler: LinkRecordControlHandler?) { recordHandler = handler }

    /// Takes a fresh clock sample from a phone now (before a multipoint start, say).
    public func sampleClock(of deviceID: UUID) { peers[deviceID]?.sampleClock() }

    // MARK: Testing

    func sendRawFrame(_ frame: Data, to deviceID: UUID) { peers[deviceID]?.sendRaw(frame) }
    func ignoredMessageCount(from deviceID: UUID) -> Int { peers[deviceID]?.ignoredMessages ?? 0 }
    var advertisedEntries: [String: String]? { advertisement?.entries }

    // MARK: Listener

    private func openListener(port: NWEndpoint.Port?) {
        guard isRunning else { return }
        let listener: NWListener
        do {
            let records = try keyStore.records()
            let psks = [LinkTransport.pairingPSK] + records.map(LinkTransport.PSK.init)
            let parameters = LinkTransport.parameters(psks: psks, allowPeerToPeer: configuration.allowPeerToPeer)
            // Reopening on the port of a listener just closed, while its accepted connections
            // still use it. Never for a fresh port: it could share one with a stranger.
            parameters.allowLocalEndpointReuse = port != nil
            if configuration.loopbackOnly {
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port ?? .any)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: port ?? .any)
            }
        } catch {
            listenerFailed("\(error)", port: port)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.assumeIsolated { $0.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            self?.assumeIsolated { $0.listener(listener, changed: state, requestedPort: port) }
        }
        advertise()
        listener.start(queue: queue)
    }

    private func listener(_ listener: NWListener, changed state: NWListener.State, requestedPort: NWEndpoint.Port?) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            listenerFailures = 0
            listenerPort = listener.port
            isRebuilding = false
            resumeStart(throwing: nil)
            if rebuildPending {
                // Keys changed while this listener was opening.
                rebuildPending = false
                rebuildListener()
            } else {
                flushAfterRebuild()
            }
        case .failed(let error):
            listener.cancel()
            self.listener = nil
            listenerFailed("\(error)", port: requestedPort)
        default:
            break
        }
    }

    /// After sleep or a network change the listener can fail; it's reopened with backoff. If the
    /// old port can't be had, any port will do (Bonjour carries the new one).
    private func listenerFailed(_ description: String, port: NWEndpoint.Port?) {
        listenerFailures += 1
        if startContinuation != nil, listenerFailures >= 3 {
            isRunning = false
            resumeStart(throwing: LinkError.listenerFailed(description))
            return
        }
        let delay = configuration.reconnect.delay(attempt: listenerFailures - 1)
        let retryPort = listenerFailures >= 2 && !configuration.loopbackOnly ? nil : port
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.assumeIsolated { service in
                guard service.isRunning, service.listener == nil else { return }
                service.openListener(port: retryPort)
            }
        }
    }

    private func resumeStart(throwing error: Error?) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    /// The listener's PSK list is fixed when it's created, so a new or removed pairing means a new
    /// listener on the same port. Connections already accepted carry on.
    private func rebuildListener(then completion: (() -> Void)? = nil) {
        if let completion { afterRebuild.append(completion) }
        guard isRunning else { flushAfterRebuild(); return }
        guard !isRebuilding else { rebuildPending = true; return }
        // Without a listener, a reopen is already scheduled and will read the current keys.
        guard let old = listener else { return }
        isRebuilding = true
        let port = old.port ?? listenerPort
        listener = nil
        old.newConnectionHandler = nil
        old.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            self?.assumeIsolated { $0.openListener(port: port) }
        }
        old.cancel()
    }

    private func flushAfterRebuild() {
        let waiting = afterRebuild
        afterRebuild.removeAll()
        waiting.forEach { $0() }
    }

    /// Keeps the TXT record current, and advertises only when there's a reason to: pairing is open
    /// or a phone is paired. A Mac nobody pairs with doesn't announce itself on every network.
    private func advertise() {
        let advertisement = LinkAdvertisement(salt: self.advertisement?.salt ?? PasskeyExchange.randomBytes(8),
                                              libraryID: identity.libraryID, deviceID: identity.deviceID,
                                              versions: configuration.supportedVersions, isPairing: pairing != nil)
        self.advertisement = advertisement
        guard configuration.discovery == .bonjour, let listener else { return }
        let hasPhones = !((try? keyStore.records()) ?? []).isEmpty
        listener.service = pairing != nil || hasPhones
            ? NWListener.Service(name: identity.name, type: LinkProtocol.serviceType, domain: nil, txtRecord: advertisement.txtRecord)
            : nil
    }

    // MARK: Accepting

    private func accept(_ connection: NWConnection) {
        guard isRunning, unrouted.count < 16 else { connection.cancel(); return }
        let channel = LinkChannel(connection: connection, queue: queue, clock: configuration.clock)
        let id = ObjectIdentifier(channel)
        unrouted[id] = channel
        channel.onFrame = { [weak self, weak channel] frame, receivedAt in
            guard let channel else { return }
            self?.assumeIsolated { $0.route(channel, firstFrame: frame, receivedAt: receivedAt) }
        }
        channel.onEnd = { [weak self] _ in
            self?.assumeIsolated { _ = $0.unrouted.removeValue(forKey: id) }
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout) { [weak self, weak channel] in
            guard let channel else { return }
            self?.assumeIsolated { service in
                guard service.unrouted.removeValue(forKey: ObjectIdentifier(channel)) != nil else { return }
                channel.close()
            }
        }
    }

    /// The first frame says what a connection is for: a session (hello) or pairing (pair.begin).
    private func route(_ channel: LinkChannel, firstFrame: Data, receivedAt: Date) {
        guard unrouted.removeValue(forKey: ObjectIdentifier(channel)) != nil else { return }
        guard let message = try? LinkWire.decode(firstFrame).message else { channel.close(); return }
        switch message {
        case .hello:
            startSession(on: channel, firstFrame: firstFrame, receivedAt: receivedAt)
        case .pairing(.begin):
            startPairingAttempt(on: channel, firstFrame: firstFrame)
        default:
            channel.close()
        }
    }

    // MARK: Sessions

    private func startSession(on channel: LinkChannel, firstFrame: Data, receivedAt: Date) {
        var delegate = LinkSession.Delegate()
        delegate.lookup = { [keyStore] deviceID in try? keyStore.record(for: deviceID) }
        delegate.established = { [weak self] session in self?.assumeIsolated { $0.established(session) } }
        delegate.ended = { [weak self] session, reason in self?.assumeIsolated { $0.ended(session, reason: reason) } }
        delegate.received = { [weak self] session, message in
            guard let deviceID = session.deviceID else { return }
            self?.hub.yield(.received(message, from: deviceID))
        }
        delegate.peerUpdated = { [weak self] session in
            guard let peer = session.peer else { return }
            self?.hub.yield(.peerUpdated(peer))
        }
        delegate.unpaired = { [weak self] session in self?.assumeIsolated { $0.peerUnpaired(session) } }
        delegate.recordRequest = { [weak self] session, request, reply in
            guard let self else { reply(.refused(LinkRecordRefusal(reason: .unsupported))); return }
            self.assumeIsolated { $0.answer(request, from: session, reply: reply) }
        }
        let session = LinkSession(role: .server, channel: channel, identity: identity, record: nil, configuration: configuration,
                                  heartbeat: (configuration.heartbeatInterval, configuration.heartbeatTimeout), delegate: delegate)
        sessions[ObjectIdentifier(session)] = session
        session.startServer(firstFrame: firstFrame, receivedAt: receivedAt)
    }

    private func established(_ session: LinkSession) {
        guard let peer = session.peer else { return }
        if let previous = peers[peer.deviceID], previous !== session {
            previous.close(.replaced)
        }
        peers[peer.deviceID] = session
        if let answered = answeredByDevice[peer.deviceID] { session.adoptAnsweredReplies(answered) }
        hub.yield(.connected(peer))
    }

    private func ended(_ session: LinkSession, reason: LinkDisconnectReason) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        guard let peer = session.peer else { return }
        answeredByDevice[peer.deviceID, default: [:]].merge(session.answeredReplies) { old, _ in old }
        if peers[peer.deviceID] === session { peers.removeValue(forKey: peer.deviceID) }
        hub.yield(.disconnected(deviceID: peer.deviceID, reason: reason))
    }

    private func peerUnpaired(_ session: LinkSession) {
        guard let deviceID = session.deviceID else { return }
        try? keyStore.remove(deviceID: deviceID)
        answeredByDevice[deviceID] = nil
        hub.yield(.unpaired(deviceID: deviceID, byPeer: true))
        rebuildListener()
    }

    private func answer(_ request: LinkRecordRequest, from session: LinkSession,
                        reply: @escaping (LinkRecordReply.Outcome) -> Void) {
        guard let handler = recordHandler, let peer = session.peer else {
            reply(.refused(LinkRecordRefusal(reason: .unsupported)))
            return
        }
        Task {
            let outcome = await handler(peer, request)
            reply(outcome)
        }
    }

    // MARK: Pairing attempts

    private func startPairingAttempt(on channel: LinkChannel, firstFrame: Data) {
        guard var window = pairing else {
            channel.close(after: PasskeyExchange.refuseFrame(.notPairing))
            return
        }
        guard window.attempt == nil else {
            channel.close(after: PasskeyExchange.refuseFrame(.busy))
            return
        }
        let id = ObjectIdentifier(channel)
        window.attempt = id
        pairing = window
        pairingChannel = channel
        let exchange = PasskeyExchange(role: .responder, code: window.code, local: identity.pairingDevice)
        var settled = false

        let fail: (PasskeyExchange.Failure?) -> Void = { [weak self, weak channel] failure in
            guard !settled else { return }
            settled = true
            let frame: Data?
            switch failure {
            case .peerFailed, nil: frame = nil
            case .refused(let reason): frame = PasskeyExchange.refuseFrame(reason)
            case .some(let failure): frame = PasskeyExchange.failFrame("\(failure)")
            }
            channel?.close(after: frame)
            self?.assumeIsolated { $0.pairingAttemptFailed(id, failure: failure) }
        }

        channel.onFrame = { [weak self, weak channel] frame, _ in
            guard let self, let channel, !settled else { return }
            do {
                let replies = try exchange.receive(frame)
                if exchange.isFinished, let outcome = exchange.outcome {
                    settled = true
                    self.assumeIsolated { $0.paired(outcome, attempt: id, channel: channel, replies: replies) }
                } else {
                    replies.forEach(channel.send)
                }
            } catch let failure as PasskeyExchange.Failure {
                fail(failure)
            } catch {
                fail(.unexpected("\(error)"))
            }
        }
        channel.onEnd = { _ in fail(nil) }
        queue.asyncAfter(deadline: .now() + configuration.pairingTimeout) {
            fail(.unexpected("timed out"))
        }
        // The first frame is the begin.
        channel.onFrame?(firstFrame, configuration.clock.now())
    }

    private func paired(_ outcome: PasskeyExchange.Outcome, attempt: ObjectIdentifier, channel: LinkChannel, replies: [Data]) {
        guard isRunning, let window = pairing, window.attempt == attempt, pairingChannel === channel else {
            channel.close(after: PasskeyExchange.refuseFrame(.notPairing))
            return
        }
        guard window.code.expiresAt > configuration.clock.now() else {
            closePairing(failure: .expired)
            return
        }
        let record = LinkPairingRecord(deviceID: outcome.peer.deviceID, name: outcome.peer.name,
                                       deviceClass: outcome.peer.deviceClass, pairedAt: configuration.clock.now(),
                                       linkKey: outcome.linkKey, pskIdentity: outcome.pskIdentity)
        do {
            try keyStore.save(record)
        } catch {
            channel.close(after: PasskeyExchange.failFrame("couldn't store the key"))
            pairingAttemptFailed(attempt, failure: .unexpected("keychain"))
            return
        }
        hub.yield(.paired(record.device))
        pairingChannel = nil
        if pairing?.attempt == attempt {
            pairing?.expiry.cancel()
            pairing = nil
            hub.yield(.pairingCode(nil))
        }
        // Answer only once the listener knows the new key, so the phone's first session succeeds.
        rebuildListener { [weak self] in
            replies.dropLast().forEach(channel.send)
            channel.close(after: replies.last)
            self?.assumeIsolated { $0.advertise() }
        }
    }

    /// Any attempt that doesn't finish burns the code: a failed attempt may have revealed some of
    /// its bits.
    private func pairingAttemptFailed(_ attempt: ObjectIdentifier, failure: PasskeyExchange.Failure?) {
        guard var window = pairing, window.attempt == attempt else { return }
        pairingChannel = nil
        window.attempt = nil
        window.failures += 1
        pairing = window
        hub.yield(.pairingFailed(Self.error(for: failure)))
        if window.failures >= configuration.maxPairingFailures {
            closePairing(failure: .tooManyAttempts)
        } else {
            beginPairing()
        }
    }

    private func closePairing(failure: LinkPairingError?) {
        pairing?.expiry.cancel()
        pairing = nil
        let channel = pairingChannel
        pairingChannel = nil
        channel?.close(after: PasskeyExchange.refuseFrame(.notPairing))
        if let failure { hub.yield(.pairingFailed(failure)) }
        hub.yield(.pairingCode(nil))
        advertise()
    }

    static func error(for failure: PasskeyExchange.Failure?) -> LinkPairingError {
        switch failure {
        case .codeMismatch, .confirmationMismatch, .peerFailed: return .codeRejected
        case .refused(.busy): return .busy
        case .refused(.unsupportedVersion): return .unsupportedVersion
        case .refused: return .notPairing
        case .invalidKey: return .protocolViolation("invalid key")
        case .unexpected(let what): return what == "timed out" ? .timedOut : .protocolViolation(what)
        case nil: return .connectionFailed("closed")
        }
    }
}
