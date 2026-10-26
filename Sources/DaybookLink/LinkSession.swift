import CryptoKit
import Foundation

/// An authenticated session over one channel, the same on both sides once established. Confined
/// to its owner's queue.
///
/// Handshake: the client sends `hello` (its versions, IDs, capabilities, and an HMAC under the
/// pairing key over the TLS exporter); the server checks it and answers `welcome` (the agreed
/// version and its own HMAC) or `refused`. The HMACs bind the pairing key to this TLS session,
/// so a hello copied from another session, or relayed through a device in the middle, fails.
///
/// Confined to its owner's queue (hence `@unchecked Sendable`).
final class LinkSession: @unchecked Sendable {
    enum Role { case server, client }

    enum State: Equatable { case handshaking, established, closed }

    /// What the owner provides. All closures run on the queue.
    struct Delegate {
        var established: (LinkSession) -> Void = { _ in }
        var ended: (LinkSession, LinkDisconnectReason) -> Void = { _, _ in }
        var received: (LinkSession, LinkMessage) -> Void = { _, _ in }
        var peerUpdated: (LinkSession) -> Void = { _ in }
        var unpaired: (LinkSession) -> Void = { _ in }
        /// Answer a record request by calling the completion (on the queue).
        var recordRequest: (LinkSession, LinkRecordRequest, @escaping (LinkRecordReply.Outcome) -> Void) -> Void = { _, _, reply in
            reply(.refused(LinkRecordRefusal(reason: .unsupported)))
        }
        /// Server: the pairing record for a device that says hello.
        var lookup: (UUID) -> LinkPairingRecord? = { _ in nil }
    }

    let role: Role
    let channel: LinkChannel
    let queue: DispatchQueue
    let configuration: LinkConfiguration
    var delegate: Delegate
    private(set) var identity: LinkIdentity
    private(set) var record: LinkPairingRecord?
    private(set) var peer: LinkPeer?
    private(set) var state: State = .handshaking
    private(set) var version = LinkProtocol.baselineVersion
    /// Unknown message types received and ignored (diagnostics, tests).
    private(set) var ignoredMessages = 0

    private var localInterval: TimeInterval
    private var localTimeout: TimeInterval
    private var peerInterval: TimeInterval?
    private var lastHeard = DispatchTime.now()
    private var heartbeatTimer: DispatchSourceTimer?
    private var clockTimer: DispatchSourceTimer?
    private var handshakeDeadline: DispatchWorkItem?
    private var sequence: UInt64 = 0
    private var clockFilter = LinkClockFilter()
    private var pending: [UUID: (completion: (Result<LinkRecordReply, LinkError>) -> Void, timeout: DispatchWorkItem)] = [:]
    private var answered: [UUID: LinkRecordReply] = [:]
    private var answeredOrder: [UUID] = []
    private var answering: Set<UUID> = []

    init(role: Role, channel: LinkChannel, identity: LinkIdentity, record: LinkPairingRecord?, configuration: LinkConfiguration,
         heartbeat: (interval: TimeInterval, timeout: TimeInterval), delegate: Delegate) {
        self.role = role
        self.channel = channel
        self.queue = channel.queue
        self.identity = identity
        self.record = record
        self.configuration = configuration
        self.delegate = delegate
        localInterval = Self.validHeartbeatInterval(heartbeat.interval) ? heartbeat.interval : 5
        localTimeout = heartbeat.timeout.isFinite && heartbeat.timeout > 0 ? min(heartbeat.timeout, 900) : 15
        channel.onFrame = { [weak self] frame, receivedAt in self?.receive(frame, at: receivedAt) }
        channel.onEnd = { [weak self] end in self?.channelEnded(end) }
        channel.onViabilityLost = { [weak self] in self?.probe() }
    }

    var deviceID: UUID? { peer?.deviceID ?? record?.deviceID }

    // MARK: Start

    /// Client: connect and say hello.
    func startClient() {
        armHandshakeDeadline()
        channel.onReady = { [weak self] in self?.sendHello() }
        channel.start()
    }

    /// Server: the channel is up and its first frame (a hello) has arrived.
    func startServer(firstFrame: Data, receivedAt: Date) {
        armHandshakeDeadline()
        receive(firstFrame, at: receivedAt)
    }

    private func armHandshakeDeadline() {
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.state == .handshaking else { return }
            self.close(.handshakeTimeout)
        }
        handshakeDeadline = deadline
        queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout, execute: deadline)
    }

    private func sendHello() {
        guard let record, let exporter = channel.exporter() else { close(.protocolError("no TLS exporter")); return }
        let auth = Self.auth(key: record.linkKey, sender: .client, exporter: exporter,
                             clientID: identity.deviceID, serverID: record.deviceID)
        let hello = Hello(versions: LinkVersionRange(configuration.supportedVersions), deviceID: identity.deviceID,
                          serverID: record.deviceID, capabilities: identity.capabilities, auth: auth,
                          heartbeatInterval: localInterval)
        send(.hello(hello))
    }

    // MARK: Receive

    private func receive(_ frame: Data, at receivedAt: Date) {
        guard state != .closed else { return }
        lastHeard = .now()
        let message: WireMessage
        do {
            message = try LinkWire.decode(frame).message
        } catch {
            // A known type whose body this build can't read: ignore it once established, as for
            // unknown types; during the handshake it's fatal.
            if state == .established { ignoredMessages += 1; return }
            close(.protocolError("unreadable \(state == .handshaking ? "handshake" : "message")"))
            return
        }
        switch state {
        case .handshaking: handshake(message)
        case .established: established(message, receivedAt: receivedAt)
        case .closed: break
        }
    }

    private func handshake(_ message: WireMessage) {
        switch (role, message) {
        case (.server, .hello(let hello)): accept(hello)
        case (.client, .welcome(let welcome)): finish(welcome)
        case (.client, .refused(let refusal)): close(Self.reason(for: refusal), goodbye: false)
        default: close(.protocolError("unexpected \(message.type) during handshake"))
        }
    }

    private func accept(_ hello: Hello) {
        guard let version = LinkVersionRange.negotiate(local: configuration.supportedVersions, remote: hello.versions) else {
            refuse(.init(reason: .incompatibleVersion, versions: LinkVersionRange(configuration.supportedVersions)),
                   as: .incompatibleVersion(peerVersions: hello.versions.range))
            return
        }
        guard hello.serverID == identity.deviceID else {
            refuse(.init(reason: .wrongDevice), as: .authenticationFailed)
            return
        }
        guard let record = delegate.lookup(hello.deviceID) else {
            refuse(.init(reason: .notPaired), as: .notPaired)
            return
        }
        guard let exporter = channel.exporter(),
              HMAC<SHA256>.isValidAuthenticationCode(hello.auth, authenticating: Self.authMessage(
                sender: .client, exporter: exporter, clientID: hello.deviceID, serverID: identity.deviceID),
                using: SymmetricKey(data: record.linkKey)) else {
            refuse(.init(reason: .authenticationFailed), as: .authenticationFailed)
            return
        }
        guard hello.heartbeatInterval.map(Self.validHeartbeatInterval) ?? true else {
            close(.protocolError("invalid heartbeat interval")); return
        }
        self.record = record
        self.version = version
        peerInterval = hello.heartbeatInterval
        let auth = Self.auth(key: record.linkKey, sender: .server, exporter: exporter,
                             clientID: hello.deviceID, serverID: identity.deviceID)
        send(.welcome(Welcome(version: version, deviceID: identity.deviceID, capabilities: identity.capabilities,
                              auth: auth, heartbeatInterval: localInterval)))
        establish(peer: LinkPeer(deviceID: hello.deviceID, capabilities: hello.capabilities, protocolVersion: version,
                                 connectedAt: configuration.clock.now()))
    }

    private func refuse(_ refusal: Refusal, as reason: LinkDisconnectReason) {
        guard let frame = try? LinkWire.encode(.refused(refusal), version: LinkProtocol.baselineVersion) else { return }
        finishClosing(reason, frame: frame)
    }

    private func finish(_ welcome: Welcome) {
        guard let record, let exporter = channel.exporter() else { close(.protocolError("no TLS exporter")); return }
        guard configuration.supportedVersions.contains(welcome.version) else {
            close(.incompatibleVersion(peerVersions: welcome.version...welcome.version))
            return
        }
        guard welcome.deviceID == record.deviceID,
              HMAC<SHA256>.isValidAuthenticationCode(welcome.auth, authenticating: Self.authMessage(
                sender: .server, exporter: exporter, clientID: identity.deviceID, serverID: record.deviceID),
                using: SymmetricKey(data: record.linkKey)) else {
            close(.authenticationFailed)
            return
        }
        version = welcome.version
        guard welcome.heartbeatInterval.map(Self.validHeartbeatInterval) ?? true else {
            close(.protocolError("invalid heartbeat interval")); return
        }
        peerInterval = welcome.heartbeatInterval
        establish(peer: LinkPeer(deviceID: record.deviceID, capabilities: welcome.capabilities, protocolVersion: welcome.version,
                                 connectedAt: configuration.clock.now()))
    }

    private func establish(peer: LinkPeer) {
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
        self.peer = peer
        state = .established
        lastHeard = .now()
        restartHeartbeat()
        startClockSampling()
        delegate.established(self)
    }

    private func established(_ message: WireMessage, receivedAt: Date) {
        switch message {
        case .ping(let beat):
            guard adoptPeerInterval(beat.interval) else { return }
            send(.pong(Heartbeat(sequence: beat.sequence, interval: localInterval)))
        case .pong(let beat):
            _ = adoptPeerInterval(beat.interval)
        case .clockRequest(let request):
            send(.clockReply(ClockReply(sequence: request.sequence, t1: request.t1, t2: receivedAt, t3: configuration.clock.now())))
        case .clockReply(let reply):
            clockFilter.add(LinkClockSample(t1: reply.t1, t2: reply.t2, t3: reply.t3, t4: receivedAt))
            if let estimate = clockFilter.estimate, peer?.clock != estimate {
                peer?.clock = estimate
                delegate.peerUpdated(self)
            }
        case .capabilities(let capabilities):
            peer?.capabilities = capabilities
            delegate.peerUpdated(self)
        case .app(let message):
            delegate.received(self, message)
        case .recordRequest(let request):
            answer(request)
        case .recordReply(let reply):
            if let entry = pending.removeValue(forKey: reply.requestID) {
                entry.timeout.cancel()
                entry.completion(.success(reply))
            }
        case .unpair:
            delegate.unpaired(self)
            close(.unpaired, goodbye: false)
        case .goodbye:
            close(.peerClosed, goodbye: false)
        case .unknown:
            ignoredMessages += 1
        case .hello, .welcome, .refused, .pairing:
            // Handshake messages have no meaning once established; ignore rather than fail.
            ignoredMessages += 1
        }
    }

    // MARK: Record control

    func request(_ request: LinkRecordRequest, completion: @escaping (Result<LinkRecordReply, LinkError>) -> Void) {
        guard state == .established else { completion(.failure(.notConnected)); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let entry = self?.pending.removeValue(forKey: request.id) else { return }
            entry.completion(.failure(.timedOut))
        }
        pending[request.id] = (completion, timeout)
        queue.asyncAfter(deadline: .now() + configuration.requestTimeout, execute: timeout)
        send(.recordRequest(request))
    }

    private func answer(_ request: LinkRecordRequest) {
        // A repeated request (a retry after a lost reply) gets the first answer, never a second start.
        if let reply = answered[request.id] { send(.recordReply(reply)); return }
        guard !answering.contains(request.id) else { return }
        answering.insert(request.id)
        delegate.recordRequest(self, request) { [weak self] outcome in
            guard let self else { return }
            self.answering.remove(request.id)
            let reply = LinkRecordReply(requestID: request.id, outcome: outcome, sentAt: self.configuration.clock.now())
            self.answered[request.id] = reply
            self.answeredOrder.append(request.id)
            if self.answeredOrder.count > 64 { self.answered.removeValue(forKey: self.answeredOrder.removeFirst()) }
            self.send(.recordReply(reply))
        }
    }

    /// Replies already given, so a new session (after a reconnect) can answer repeats too.
    var answeredReplies: [UUID: LinkRecordReply] { answered }

    func adoptAnsweredReplies(_ replies: [UUID: LinkRecordReply]) {
        for (id, reply) in replies where answered[id] == nil {
            answered[id] = reply
            answeredOrder.append(id)
        }
    }

    // MARK: Send

    func send(_ message: LinkMessage) {
        guard state == .established else { return }
        send(.app(message))
    }

    func update(identity: LinkIdentity) {
        let changed = identity.capabilities != self.identity.capabilities
        self.identity = identity
        if changed, state == .established { send(.capabilities(identity.capabilities)) }
    }

    private func send(_ message: WireMessage) {
        guard state != .closed, let frame = try? LinkWire.encode(message, version: version) else { return }
        channel.send(frame)
    }

    /// Sends a raw frame. Tests use it to send what this build wouldn't.
    func sendRaw(_ frame: Data) { channel.send(frame) }

    // MARK: Heartbeat

    /// Changes this side's pace (foreground, background recording) and tells the peer.
    func setHeartbeat(interval: TimeInterval, timeout: TimeInterval) {
        guard Self.validHeartbeatInterval(interval), timeout.isFinite, timeout > 0, timeout <= 900 else { return }
        localInterval = interval
        localTimeout = timeout
        guard state == .established else { return }
        restartHeartbeat()
        sequence += 1
        send(.ping(Heartbeat(sequence: sequence, interval: localInterval)))
    }

    private var effectiveInterval: TimeInterval { max(localInterval, peerInterval ?? 0) }
    private var effectiveTimeout: TimeInterval { max(localTimeout, 3 * (peerInterval ?? 0)) }

    private static func validHeartbeatInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && (0.001...300).contains(interval)
    }

    private func adoptPeerInterval(_ interval: TimeInterval?) -> Bool {
        guard let interval else { return true }
        guard Self.validHeartbeatInterval(interval) else {
            close(.protocolError("invalid heartbeat interval"))
            return false
        }
        guard interval != peerInterval else { return true }
        peerInterval = interval
        restartHeartbeat()
        return true
    }

    private func restartHeartbeat() {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = effectiveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func heartbeat() {
        guard state == .established else { return }
        let silence = Double(DispatchTime.now().uptimeNanoseconds - lastHeard.uptimeNanoseconds) / 1e9
        if silence > effectiveTimeout {
            close(.heartbeatTimeout)
            return
        }
        sequence += 1
        send(.ping(Heartbeat(sequence: sequence, interval: localInterval)))
    }

    /// After a wake or a network change: ask for an answer now, and give up on the session if
    /// none comes within `probeTimeout`.
    func probe() {
        guard state == .established else { return }
        let asked = DispatchTime.now()
        sequence += 1
        send(.ping(Heartbeat(sequence: sequence, interval: localInterval)))
        queue.asyncAfter(deadline: .now() + configuration.probeTimeout) { [weak self] in
            guard let self, self.state == .established, self.lastHeard < asked else { return }
            self.close(.heartbeatTimeout)
        }
    }

    // MARK: Clock

    private func startClockSampling() {
        let count = max(0, configuration.clockSamplesPerBurst)
        for index in 0..<count {
            queue.asyncAfter(deadline: .now() + configuration.clockSampleSpacing * Double(index)) { [weak self] in
                self?.sampleClock()
            }
        }
        guard configuration.clockResampleInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.clockResampleInterval, repeating: configuration.clockResampleInterval,
                       leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sampleClock() }
        clockTimer = timer
        timer.resume()
    }

    func sampleClock() {
        guard state == .established else { return }
        sequence += 1
        send(.clockRequest(ClockRequest(sequence: sequence, t1: configuration.clock.now())))
    }

    // MARK: Close

    /// Ends the session, saying goodbye if it was established.
    func close(_ reason: LinkDisconnectReason, goodbye: Bool = true) {
        guard state != .closed else { return }
        let frame = goodbye && state == .established
            ? try? LinkWire.encode(.goodbye(Goodbye(reason: "\(reason)")), version: version) : nil
        finishClosing(reason, frame: frame)
    }

    /// Tells the peer the pair is gone, then closes.
    func sendUnpairAndClose() {
        guard state == .established, let frame = try? LinkWire.encode(.unpair, version: version) else {
            close(.unpaired)
            return
        }
        finishClosing(.unpaired, frame: frame)
    }

    private func channelEnded(_ end: LinkChannelEnd) {
        guard state != .closed else { return }
        let reason: LinkDisconnectReason
        switch end {
        case .local: reason = .closedLocally
        case .peerClosed: reason = state == .handshaking && role == .client ? .connectionLost("closed during handshake") : .peerClosed
        case .failed(let description): reason = .connectionLost(description)
        case .tlsFailed: reason = .authenticationFailed
        }
        finishClosing(reason, frame: nil)
    }

    private func finishClosing(_ reason: LinkDisconnectReason, frame: Data?) {
        guard state != .closed else { return }
        state = .closed
        handshakeDeadline?.cancel()
        heartbeatTimer?.cancel()
        clockTimer?.cancel()
        heartbeatTimer = nil
        clockTimer = nil
        let waiting = pending
        pending.removeAll()
        for entry in waiting.values {
            entry.timeout.cancel()
            entry.completion(.failure(.disconnected))
        }
        channel.onEnd = nil
        channel.close(after: frame)
        delegate.ended(self, reason)
    }

    // MARK: Authentication

    private static func reason(for refusal: Refusal) -> LinkDisconnectReason {
        switch refusal.reason {
        case .incompatibleVersion: return .incompatibleVersion(peerVersions: refusal.versions?.range)
        case .notPaired: return .notPaired
        default: return .authenticationFailed
        }
    }

    static func authMessage(sender: Role, exporter: Data, clientID: UUID, serverID: UUID) -> Data {
        var message = LinkProtocol.sessionAuthLabel
        message.append(sender == .client ? 0x43 : 0x53)
        message.append(exporter)
        message.append(PasskeyExchange.bytes(of: clientID))
        message.append(PasskeyExchange.bytes(of: serverID))
        return message
    }

    static func auth(key: Data, sender: Role, exporter: Data, clientID: UUID, serverID: UUID) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: authMessage(sender: sender, exporter: exporter, clientID: clientID,
                                                              serverID: serverID),
                                             using: SymmetricKey(data: key)))
    }
}
