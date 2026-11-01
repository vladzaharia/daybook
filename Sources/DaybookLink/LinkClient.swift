import Foundation
@preconcurrency import Network

/// The phone's end of the link: browses for Macs, pairs with a code typed from the Mac, and keeps
/// a connection to each paired Mac it's asked to, reconnecting with backoff.
///
/// How hard it works follows `setActivity(_:)`: in the background without a recording it closes
/// everything; while recording in the background it keeps the connection with slower heartbeats.
public actor LinkClient: LinkSessionOwner {
    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let keyStore: any LinkKeyStore
    let configuration: LinkConfiguration
    let hub = LinkEventHub()
    private var identity: LinkIdentity

    /// The connection kept to one Mac. Confined to the client's queue.
    private final class MacLink: @unchecked Sendable {
        let macID: UUID
        var endpoint: LinkEndpoint?
        var session: LinkSession?
        var retry: DispatchWorkItem?
        var attempt = 0
        var state: LinkConnectionState = .idle

        init(macID: UUID, endpoint: LinkEndpoint?) {
            self.macID = macID
            self.endpoint = endpoint
        }

        var isConnected: Bool { session?.state == .established }
    }

    private var links: [UUID: MacLink] = [:]
    var recordAnswers = LinkRecordAnswers()
    private(set) var recordHandler: LinkRecordControlHandler?
    private var activity: LinkActivity = .foreground
    private var networkAvailable = true
    private var pathMonitor: NWPathMonitor?
    private var lastInterfaces: [String] = []

    private var browser: NWBrowser?
    private var wantsBrowsing = false
    private var browseResults: [(name: String, endpoint: NWEndpoint, advertisement: LinkAdvertisement)] = []
    public private(set) var discoveredMacs: [LinkDiscoveredMac] = []
    /// Whether Macs can be found: browsing, not, or refused the Local Network permission.
    public private(set) var discovery: LinkDiscoveryState = .idle

    public init(identity: LinkIdentity, keyStore: any LinkKeyStore, configuration: LinkConfiguration = LinkConfiguration()) {
        queue = DispatchSerialQueue(label: "local.daybook.link.client")
        self.identity = identity
        self.keyStore = keyStore
        self.configuration = configuration
    }

    deinit {
        let links = Array(self.links.values)
        let browser = self.browser
        let monitor = pathMonitor
        let hub = self.hub
        queue.async {
            for link in links {
                link.retry?.cancel()
                link.session?.close(.closedLocally)
            }
            browser?.cancel()
            monitor?.cancel()
            hub.finish()
        }
    }

    /// A stream of everything that happens. Each call returns a new stream.
    public nonisolated func events() -> AsyncStream<LinkEvent> { hub.stream() }

    // MARK: Discovery

    /// Browses for Macs (for the pairing screen, say). Results arrive as `.discovered` events and
    /// in `discoveredMacs`. The client also browses on its own while a paired Mac is missing.
    public func startBrowsing() {
        wantsBrowsing = true
        updateBrowser()
    }

    public func stopBrowsing() {
        wantsBrowsing = false
        updateBrowser()
    }

    // MARK: Pairing

    /// Pairs with a Mac using the code it shows. Saves the key and returns the Mac; then call
    /// `connect(to:)`.
    public func pair(with endpoint: LinkEndpoint, code typed: String) async throws -> LinkPairedDevice {
        guard let code = LinkPairingCode(typed: typed) else { throw LinkPairingError.invalidCode }
        // A failed attempt may have revealed part of its code, so a code that failed is never sent
        // again. It's burned before the attempt, so even a crash part-way leaves it burned, and
        // given back only when the Mac turned the attempt away before anything was committed.
        let now = configuration.clock.now()
        var burned = BurnedPairingCodes.load(from: configuration.burnedCodes)
        guard !burned.contains(code.value, now: now) else { throw LinkPairingError.codeAlreadyUsed }
        burned.burn(code.value, until: now.addingTimeInterval(configuration.pairingCodeLifetime), now: now)
        burned.save(to: configuration.burnedCodes)
        let result: Result<LinkPairingRecord, LinkPairingError> = await withCheckedContinuation { continuation in
            runPairing(endpoint: endpoint, code: code) { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let record):
            do { try keyStore.save(record) } catch { throw LinkPairingError.protocolViolation("couldn't store the key: \(error)") }
            hub.yield(.paired(record.device))
            refreshDiscovered()
            return record.device
        case .failure(let error):
            if Self.revealedNothing(error) {
                var burned = BurnedPairingCodes.load(from: configuration.burnedCodes)
                burned.restore(code.value)
                burned.save(to: configuration.burnedCodes)
            }
            hub.yield(.pairingFailed(error))
            throw error
        }
    }

    /// Failures that leave a code unused: the Mac refused before either side committed to a bit
    /// (`PasskeyExchange` believes a refusal only then), or nothing ever came back.
    static func revealedNothing(_ error: LinkPairingError) -> Bool {
        switch error {
        case .notPairing, .busy, .unsupportedVersion, .connectionFailed: return true
        default: return false
        }
    }

    private func runPairing(endpoint: LinkEndpoint, code: LinkPairingCode,
                            completion: @escaping (Result<LinkPairingRecord, LinkPairingError>) -> Void) {
        let parameters = LinkTransport.parameters(psks: [LinkTransport.pairingPSK], allowPeerToPeer: configuration.allowPeerToPeer)
        let channel = LinkChannel(connection: NWConnection(to: endpoint.endpoint, using: parameters), queue: queue,
                                  clock: configuration.clock)
        let exchange = PasskeyExchange(role: .initiator, code: code, local: identity.pairingDevice)
        let clock = configuration.clock
        var settled = false
        var started = false

        let finish: (Result<LinkPairingRecord, LinkPairingError>, Data?) -> Void = { result, lastFrame in
            guard !settled else { return }
            settled = true
            channel.close(after: lastFrame)
            completion(result)
        }

        channel.onReady = {
            do {
                channel.send(try exchange.start())
            } catch {
                finish(.failure(.protocolViolation("\(error)")), nil)
            }
        }
        channel.onFrame = { frame, _ in
            guard !settled else { return }
            started = true
            do {
                let replies = try exchange.receive(frame)
                replies.forEach(channel.send)
                if exchange.isFinished, let outcome = exchange.outcome {
                    finish(.success(LinkPairingRecord(deviceID: outcome.peer.deviceID, name: outcome.peer.name,
                                                      deviceClass: outcome.peer.deviceClass, pairedAt: clock.now(),
                                                      linkKey: outcome.linkKey, pskIdentity: outcome.pskIdentity)), nil)
                }
            } catch let failure as PasskeyExchange.Failure {
                let frame: Data?
                switch failure {
                case .peerFailed, .refused: frame = nil
                default: frame = PasskeyExchange.failFrame("\(failure)")
                }
                finish(.failure(LinkService.error(for: failure)), frame)
            } catch {
                finish(.failure(.protocolViolation("\(error)")), PasskeyExchange.failFrame("unreadable"))
            }
        }
        channel.onEnd = { end in
            // A connection lost mid-exchange may have revealed bits, so it counts as a failure.
            finish(.failure(started ? .codeRejected : .connectionFailed("\(end)")), nil)
        }
        queue.asyncAfter(deadline: .now() + configuration.pairingTimeout) {
            finish(.failure(.timedOut), PasskeyExchange.failFrame("timed out"))
        }
        channel.start()
    }

    /// Paired Macs, a damaged pairing among them (`LinkPairedDevice.isDamaged`), never a key.
    public func pairedMacs() throws -> [LinkPairedDevice] { try keyStore.pairedDevices() }

    /// Forgets a Mac: tells it (when connected), removes the key, and stops connecting.
    public func unpair(_ macID: UUID) throws {
        if let link = links.removeValue(forKey: macID) {
            link.retry?.cancel()
            if link.isConnected { link.session?.sendUnpairAndClose() } else { link.session?.close(.closedLocally) }
        }
        try keyStore.remove(deviceID: macID)
        recordAnswers.forget(macID)
        hub.yield(.unpaired(deviceID: macID, byPeer: false))
        refreshDiscovered()
        updateBrowser()
    }

    // MARK: Connections

    /// Keeps a connection to a paired Mac until `disconnect(from:)`: found by Bonjour, or at
    /// `endpoint` when given.
    public func connect(to macID: UUID, via endpoint: LinkEndpoint? = nil) throws {
        guard try keyStore.record(for: macID) != nil else { throw LinkError.notPaired }
        startMonitoringPath()
        if let link = links[macID] {
            link.endpoint = endpoint ?? link.endpoint
            if !link.isConnected, link.session == nil { link.retry?.cancel(); attempt(link) }
            return
        }
        let link = MacLink(macID: macID, endpoint: endpoint)
        links[macID] = link
        attempt(link)
    }

    public func disconnect(from macID: UUID) {
        guard let link = links.removeValue(forKey: macID) else { return }
        link.retry?.cancel()
        link.session?.close(.closedLocally)
        set(link, .idle)
        updateBrowser()
    }

    public var connectedPeers: [LinkPeer] { links.values.compactMap { $0.isConnected ? $0.session?.peer : nil } }

    public func connectionState(of macID: UUID) -> LinkConnectionState { links[macID]?.state ?? .idle }

    /// Sends to one Mac, or to every connected Mac when `macID` is nil.
    public func send(_ message: LinkMessage, to macID: UUID? = nil) throws {
        let targets = links.values.filter { $0.isConnected && (macID == nil || $0.macID == macID) }
        guard !targets.isEmpty else { throw LinkError.notConnected }
        for link in targets { link.session?.send(message) }
    }

    /// Asks a Mac to start or stop recording, and waits for its answer.
    public func request(_ request: LinkRecordRequest, from macID: UUID) async throws -> LinkRecordReply {
        guard let link = links[macID], link.isConnected, let session = link.session else { throw LinkError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            session.request(request) { continuation.resume(with: $0) }
        }
    }

    /// Answers record requests from Macs. Without one, every request is refused as unsupported.
    public func setRecordControlHandler(_ handler: LinkRecordControlHandler?) { recordHandler = handler }

    public func updateIdentity(_ identity: LinkIdentity) {
        self.identity = identity
        for link in links.values { link.session?.update(identity: identity) }
        refreshDiscovered()
    }

    /// Takes a fresh clock sample from a Mac now.
    public func sampleClock(of macID: UUID) { links[macID]?.session?.sampleClock() }

    // MARK: Lifecycle

    /// Tell the client what the app is doing (scene phase, and whether a recording with a Live
    /// Activity is running).
    public func setActivity(_ activity: LinkActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        switch activity {
        case .background:
            for link in links.values {
                link.retry?.cancel()
                link.session?.close(.closedLocally)
                set(link, .suspended)
            }
            stopMonitoringPath()
        case .foreground, .backgroundRecording:
            let heartbeat = currentHeartbeat
            if !links.isEmpty { startMonitoringPath() }
            for link in links.values {
                if let session = link.session {
                    session.setHeartbeat(interval: heartbeat.interval, timeout: heartbeat.timeout)
                } else {
                    link.retry?.cancel()
                    link.attempt = 0
                    attempt(link)
                }
            }
        }
        updateBrowser()
    }

    /// Call when the app returns from sleep or suspension: probes live connections and retries
    /// the rest now.
    public func systemDidWake() {
        guard activity != .background else { return }
        for link in links.values {
            if let session = link.session { session.probe() } else { link.retry?.cancel(); link.attempt = 0; attempt(link) }
        }
    }

    // MARK: Testing

    func sendRawFrame(_ frame: Data, to macID: UUID) { links[macID]?.session?.sendRaw(frame) }
    func ignoredMessageCount(from macID: UUID) -> Int { links[macID]?.session?.ignoredMessages ?? 0 }

    // MARK: Connecting

    private var currentHeartbeat: (interval: TimeInterval, timeout: TimeInterval) {
        activity == .backgroundRecording
            ? (configuration.backgroundHeartbeatInterval, configuration.backgroundHeartbeatTimeout)
            : (configuration.heartbeatInterval, configuration.heartbeatTimeout)
    }

    private func set(_ link: MacLink, _ state: LinkConnectionState) {
        guard link.state != state else { return }
        link.state = state
        hub.yield(.connectionState(deviceID: link.macID, state))
    }

    private func attempt(_ link: MacLink) {
        guard links[link.macID] === link, link.session == nil else { return }
        guard activity != .background else { set(link, .suspended); return }
        guard networkAvailable else { set(link, .waitingForNetwork); return }
        guard let record = try? keyStore.record(for: link.macID) else { set(link, .failed(.notPaired)); return }
        guard let endpoint = link.endpoint ?? discoveredEndpoint(for: link.macID) else {
            if configuration.discovery == .bonjour {
                set(link, .searching)
                updateBrowser()
            } else {
                set(link, .failed(.connectionLost("no address for this Mac")))
            }
            return
        }

        let parameters = LinkTransport.parameters(psks: [LinkTransport.PSK(record)],
                                                  allowPeerToPeer: configuration.allowPeerToPeer)
        let channel = LinkChannel(connection: NWConnection(to: endpoint.endpoint, using: parameters), queue: queue,
                                  clock: configuration.clock)
        let session = LinkSession(role: .client, channel: channel, identity: identity, record: record,
                                  configuration: configuration, heartbeat: currentHeartbeat, delegate: .forwarding(to: self))
        if let answered = recordAnswers.replies(for: link.macID) { session.adoptAnsweredReplies(answered) }
        link.session = session
        set(link, .connecting)
        session.startClient()
    }

    /// The link a session belongs to, while it's still that link's session. A link removed (disconnect,
    /// unpair) or given a newer session isn't returned.
    private func link(of session: LinkSession) -> MacLink? {
        guard let macID = session.deviceID, let link = links[macID], link.session === session else { return nil }
        return link
    }

    func sessionEstablished(_ session: LinkSession) {
        guard let link = link(of: session), let peer = session.peer else { return }
        link.attempt = 0
        set(link, .connected)
        hub.yield(.connected(peer))
        updateBrowser()
    }

    func sessionEnded(_ session: LinkSession, reason: LinkDisconnectReason) {
        guard let macID = session.deviceID else { return }
        recordAnswers.keep(session.answeredReplies, from: macID)
        let link = link(of: session)
        link?.session = nil
        if session.peer != nil { hub.yield(.disconnected(deviceID: macID, reason: reason)) }
        guard let link else { return }
        if activity == .background { set(link, .suspended); return }

        switch reason {
        case .closedLocally, .unpaired:
            set(link, .idle)
        case .incompatibleVersion:
            // Retrying won't help until one side updates.
            set(link, .failed(reason))
        case .authenticationFailed, .notPaired:
            // The Mac may have forgotten this phone, or this isn't really that Mac: say so, and
            // keep trying slowly in case it's the latter. The key is only removed by an
            // authenticated unpair.
            set(link, .failed(reason))
            scheduleRetry(link, delay: backoff.maximum)
        default:
            if link.endpoint == nil { browseAgain() }
            scheduleRetry(link, delay: backoff.delay(attempt: link.attempt))
            link.attempt += 1
        }
    }

    private var backoff: LinkBackoff { activity == .backgroundRecording ? configuration.backgroundReconnect : configuration.reconnect }

    private func scheduleRetry(_ link: MacLink, delay: TimeInterval) {
        link.retry?.cancel()
        guard networkAvailable else { set(link, .waitingForNetwork); return }
        if case .failed = link.state {} else { set(link, .waitingToRetry(delay: delay)) }
        let retry = DispatchWorkItem { [weak self] in self?.assumeIsolated { $0.attempt(link) } }
        link.retry = retry
        queue.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    func sessionUnpaired(_ session: LinkSession) {
        guard let macID = session.deviceID else { return }
        try? keyStore.remove(deviceID: macID)
        recordAnswers.forget(macID)
        if let link = link(of: session) {
            links.removeValue(forKey: macID)
            link.retry?.cancel()
            set(link, .idle)
        }
        hub.yield(.unpaired(deviceID: macID, byPeer: true))
        refreshDiscovered()
    }

    // MARK: Browsing

    private var needsBrowsing: Bool {
        guard configuration.discovery == .bonjour, activity != .background else { return false }
        return wantsBrowsing || links.values.contains { $0.endpoint == nil && !$0.isConnected }
    }

    private func updateBrowser() {
        if needsBrowsing, browser == nil {
            let parameters = NWParameters()
            parameters.includePeerToPeer = configuration.allowPeerToPeer
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.assumeIsolated { $0.browsed(results) }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let browser else { return }
                self?.assumeIsolated { $0.browser(browser, changed: state) }
            }
            self.browser = browser
            // A browser opened again after a refusal stays refused until it says otherwise.
            if discovery == .idle { setDiscovery(.searching) }
            browser.start(queue: queue)
        } else if !needsBrowsing, let browser {
            browser.cancel()
            self.browser = nil
            setDiscovery(.idle)
        }
    }

    private func browser(_ browser: NWBrowser, changed state: NWBrowser.State) {
        guard self.browser === browser else { return }
        if let discovery = Self.discovery(for: state) { setDiscovery(discovery) }
        guard case .failed = state else { return }
        browser.cancel()
        self.browser = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.assumeIsolated { $0.updateBrowser() } }
    }

    /// What a browser's state says about finding Macs; nil when it says nothing new. Without the Local
    /// Network permission, iOS leaves the browser waiting (or failed) with DNS-SD's PolicyDenied.
    static func discovery(for state: NWBrowser.State) -> LinkDiscoveryState? {
        switch state {
        case .ready:
            return .searching
        case .waiting(let error), .failed(let error):
            return isPolicyDenied(error) ? .localNetworkDenied : nil
        default:
            return nil
        }
    }

    /// `kDNSServiceErr_PolicyDenied`: the person declined (or turned off) Local Network for the app.
    static let policyDenied: DNSServiceErrorType = -65570

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == policyDenied }
        return false
    }

    private func setDiscovery(_ state: LinkDiscoveryState) {
        guard state != discovery else { return }
        discovery = state
        hub.yield(.discovery(state))
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        browsed(results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata,
                  let advertisement = LinkAdvertisement(txtRecord: txt) else { return nil }
            return (name, result.endpoint, advertisement)
        })
    }

    /// What the browser found, read. Tests hand results in here, having no Bonjour.
    func browsed(_ results: [(name: String, endpoint: NWEndpoint, advertisement: LinkAdvertisement)]) {
        browseResults = results
        // Something on the network answered, so it's searching whatever the browser said before.
        if !results.isEmpty, discovery == .localNetworkDenied { setDiscovery(.searching) }
        refreshDiscovered()
        for link in links.values where link.state == .searching { attempt(link) }
    }

    /// Every Mac on the network: those that share this phone's library, Macs already paired, and the
    /// rest marked as using another library (`LinkDiscoveredMac.usesAnotherLibrary`), for the pairing
    /// screen to show without offering them.
    private func refreshDiscovered() {
        let paired = (try? keyStore.pairedDevices().map(\.deviceID)) ?? []
        let macs = browseResults.map {
            $0.advertisement.discovered(serviceName: $0.name, endpoint: $0.endpoint, libraryID: identity.libraryID, pairedMacs: paired)
        }
        .sorted { $0.serviceName < $1.serviceName }
        guard macs != discoveredMacs else { return }
        discoveredMacs = macs
        hub.yield(.discovered(macs))
    }

    private func discoveredEndpoint(for macID: UUID) -> LinkEndpoint? {
        discoveredMacs.first { $0.pairedDeviceID == macID }?.endpoint
    }

    /// A Mac that dropped may come back at another address: browse again (the link without an
    /// endpoint now needs it), and its Bonjour service is resolved afresh at the next attempt. Its entry
    /// stays in `discoveredMacs`, since a browser that's already running reports no new result for a
    /// service it still sees.
    private func browseAgain() {
        guard configuration.discovery == .bonjour else { return }
        updateBrowser()
    }

    // MARK: Network path

    private func startMonitoringPath() {
        guard configuration.followsNetworkChanges, pathMonitor == nil else { return }
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.cellular])
        monitor.pathUpdateHandler = { [weak self] path in self?.assumeIsolated { $0.pathChanged(path) } }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func stopMonitoringPath() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// Wi-Fi to cellular (or none): local links can't work, so stop retrying until a local network
    /// is back. A different network: probe live sessions (their address may be gone) and retry now.
    private func pathChanged(_ path: NWPath) {
        let available = path.status == .satisfied
        let interfaces = path.availableInterfaces.map(\.name)
        defer { lastInterfaces = interfaces }
        if !available {
            networkAvailable = false
            for link in links.values where link.session == nil {
                link.retry?.cancel()
                set(link, .waitingForNetwork)
            }
            return
        }
        let changed = !networkAvailable || interfaces != lastInterfaces
        networkAvailable = true
        guard changed, activity != .background else { return }
        for link in links.values {
            if let session = link.session {
                session.probe()
            } else {
                link.retry?.cancel()
                link.attempt = 0
                attempt(link)
            }
        }
    }
}
