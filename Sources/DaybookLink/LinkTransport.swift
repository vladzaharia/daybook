import Foundation
@preconcurrency import Network
import Security

// MARK: Framing

/// Length-prefixed frames: a 4-byte big-endian length, then that many bytes of JSON.
final class LinkFramer: NWProtocolFramerImplementation {
    static let label = "DaybookLink"
    static let definition = NWProtocolFramer.Definition(implementation: LinkFramer.self)
    static let headerLength = 4

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    static func header(length: Int) -> Data {
        let value = UInt32(length).bigEndian
        return withUnsafeBytes(of: value) { Data($0) }
    }

    static func length(fromHeader bytes: UnsafeRawBufferPointer) -> Int {
        bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard messageLength > 0, messageLength <= LinkProtocol.maxFrameLength else {
            framer.markFailed(error: .posix(.EMSGSIZE))
            return
        }
        framer.writeOutput(data: Self.header(length: messageLength))
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var length: Int?
            let parsed = framer.parseInput(minimumIncompleteLength: Self.headerLength, maximumLength: Self.headerLength) { buffer, _ in
                guard let buffer, buffer.count >= Self.headerLength else { return 0 }
                length = Self.length(fromHeader: UnsafeRawBufferPointer(buffer))
                return Self.headerLength
            }
            guard parsed, let length else { return Self.headerLength }
            guard length > 0, length <= LinkProtocol.maxFrameLength else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
            }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            // If the body isn't all here yet, the framer delivers it when it is.
            guard framer.deliverInputNoCopy(length: length, message: message, isComplete: true) else { return 0 }
        }
    }
}

// MARK: Parameters

enum LinkTransport {
    struct PSK {
        var key: Data
        /// As sent in the handshake. Network.framework treats PSK identities as C strings
        /// (keys are binary-safe), so a binary identity is hex-encoded: a NUL byte would cut it.
        var identity: Data

        init(key: Data, identity: Data) {
            self.key = key
            self.identity = identity
        }

        init(_ record: LinkPairingRecord) {
            key = record.linkKey
            identity = Data(("dbl1-" + record.pskIdentity.map { String(format: "%02x", $0) }.joined()).utf8)
        }
    }

    static let pairingPSK = PSK(key: LinkProtocol.pairingPSK, identity: LinkProtocol.pairingPSKIdentity)

    /// TLS 1.2 with ECDHE-PSK and ChaCha20-Poly1305 (RFC 5489, RFC 7905): the pre-shared key
    /// authenticates, the ephemeral ECDH gives forward secrecy. Network.framework's public API only
    /// negotiates external PSKs up to TLS 1.2 (TLS 1.3 external PSKs are private SPI), so the
    /// version is pinned rather than left to fall back. See docs/link.md.
    static func parameters(psks: [PSK], allowPeerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        for psk in psks {
            sec_protocol_options_add_pre_shared_key(security, dispatchData(psk.key), dispatchData(psk.identity))
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(security,
            tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!)
        // Every connection does a fresh ECDHE; nothing to resume.
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_resumption_enabled(security, false)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = allowPeerToPeer
        // The link is local by definition; never let it wander onto cellular.
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.serviceClass = .responsiveData
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: LinkFramer.definition), at: 0)
        return parameters
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

// MARK: Channel

/// Why a channel closed.
enum LinkChannelEnd: Equatable {
    case local
    case peerClosed
    case failed(String)
    /// The TLS handshake failed: wrong or unknown pre-shared key.
    case tlsFailed(Int32)
}

/// One framed TLS connection. Confined to its owner's queue: every method must be called there,
/// and every callback runs there (hence `@unchecked Sendable`).
final class LinkChannel: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onFrame: ((Data, Date) -> Void)?
    var onEnd: ((LinkChannelEnd) -> Void)?
    var onViabilityLost: (() -> Void)?
    private(set) var isReady = false
    private(set) var isClosed = false
    private let clock: LinkClock
    /// A started channel keeps itself alive until it ends, like the connection it wraps.
    private var keepAlive: LinkChannel?

    init(connection: NWConnection, queue: DispatchQueue, clock: LinkClock) {
        self.connection = connection
        self.queue = queue
        self.clock = clock
    }

    func start() {
        keepAlive = self
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.viabilityUpdateHandler = { [weak self] viable in if !viable { self?.onViabilityLost?() } }
        connection.start(queue: queue)
    }

    var remoteDescription: String { "\(connection.endpoint)" }

    func send(_ frame: Data) {
        guard !isClosed else { return }
        let message = NWProtocolFramer.Message(definition: LinkFramer.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [message])
        connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.end(.failed("\(error)"))
        })
    }

    /// Sends a last frame (goodbye, refusal) and closes once it's written.
    func close(after frame: Data? = nil) {
        guard !isClosed else { return }
        guard let frame, isReady else { end(.local); return }
        let message = NWProtocolFramer.Message(definition: LinkFramer.definition)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [message])
        connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.end(.local)
        })
        // Don't let a stalled peer keep a closing connection alive.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.end(.local) }
    }

    /// A secret both ends of this TLS session share and no other session has (RFC 5705).
    func exporter() -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = LinkProtocol.exporterLabel
        let secret = label.withCString { sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata, label.utf8.count, $0, 32) }
        guard let secret else { return nil }
        return Data(secret as DispatchData)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady, !isClosed else { return }
            isReady = true
            receive()
            onReady?()
        case .waiting(let error), .failed(let error):
            end(Self.end(for: error))
        case .cancelled:
            end(.local)
        default:
            break
        }
    }

    private static func end(for error: NWError) -> LinkChannelEnd {
        if case .tls(let status) = error { return .tlsFailed(status) }
        return .failed("\(error)")
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            let receivedAt = self.clock.now()
            if let content, !content.isEmpty {
                self.onFrame?(content, receivedAt)
            }
            if let error {
                self.end(Self.end(for: error))
            } else if content == nil, isComplete {
                self.end(.peerClosed)
            } else if !self.isClosed {
                self.receive()
            }
        }
    }

    private func end(_ reason: LinkChannelEnd) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        connection.cancel()
        let onEnd = self.onEnd
        self.onEnd = nil
        onFrame = nil
        onReady = nil
        onViabilityLost = nil
        onEnd?(reason)
        keepAlive = nil
    }
}
