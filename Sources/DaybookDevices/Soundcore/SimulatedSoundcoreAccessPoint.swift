import Foundation

#if DEBUG
import CommonCrypto
import CryptoKit
import Network
import Security

/// The simulated recorder's access point for Wi‑Fi Fast Transfer, on loopback: a TLS WebSocket server
/// with a self-signed certificate made in memory, and a UDP listener that counts keep-alives. Like the
/// recorder's single embedded listener it serves one client at a time, and its HTTP parser matches the
/// official client's header names exactly. Debug builds only.
@MainActor
public final class SimulatedSoundcoreAccessPoint {
    public let ssid: String
    public let password: String
    public private(set) var port: UInt16 = 0
    public private(set) var keepAlivePort: UInt16 = 0
    public private(set) var keepAlives = 0
    /// Opening handshakes, as their request text.
    public private(set) var handshakes: [String] = []
    /// A WebSocket client is connected now.
    public var hasClient: Bool { upgraded && client != nil }
    /// Texts from the client.
    var onText: ((String) -> Void)?

    private var listener: NWListener?
    private var keepAliveListener: NWListener?
    private var client: NWConnection?
    private var buffer = Data()
    private var upgraded = false

    init(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }

    /// Starts listening; returns once both listeners have their ports.
    func start() async throws {
        let tls = NWProtocolTLS.Options()
        guard let identity = sec_identity_create(try SimulatedCertificate.identity()) else { throw SoundcoreError.unsupported }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let secure = NWParameters(tls: tls)
        secure.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: secure)
        listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection) } }
        self.listener = listener
        let datagrams = NWParameters.udp
        datagrams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let keepAliveListener = try NWListener(using: datagrams)
        keepAliveListener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.listen(connection) } }
        self.keepAliveListener = keepAliveListener
        port = try await Self.ready(listener)
        keepAlivePort = try await Self.ready(keepAliveListener)
    }

    func send(binary: Data) {
        guard upgraded, let client else { return }
        client.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.binary, payload: binary), completion: .contentProcessed { _ in })
    }

    func send(text: String) {
        guard upgraded, let client else { return }
        client.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Data(text.utf8)), completion: .contentProcessed { _ in })
    }

    /// The connection drops (a fault): the client sees the WebSocket end.
    func dropClient() {
        client?.cancel()
        client = nil
        upgraded = false
        buffer = Data()
    }

    func close() {
        dropClient()
        listener?.cancel()
        keepAliveListener?.cancel()
        listener = nil
        keepAliveListener = nil
    }

    // MARK: The WebSocket

    private func accept(_ connection: NWConnection) {
        // One client at a time, as the recorder's embedded listener.
        guard client == nil else { connection.cancel(); return }
        client = connection
        upgraded = false
        buffer = Data()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.client === connection else { return }
                switch state {
                case .failed, .cancelled: self.client = nil; self.upgraded = false
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.client === connection else { return }
                if let data, !data.isEmpty { self.received(data, from: connection) }
                if error != nil || complete { self.dropClient() } else if self.client === connection { self.receive(connection) }
            }
        }
    }

    private func received(_ data: Data, from connection: NWConnection) {
        buffer.append(data)
        if !upgraded {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let request = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            handshakes.append(request)
            let lines = request.components(separatedBy: "\r\n")
            // A minimal embedded parser: exact names and values, as the official client writes them.
            guard lines.first == "GET / HTTP/1.1", lines.contains("Upgrade: websocket"), lines.contains("Connection: Upgrade"),
                  lines.contains("Sec-WebSocket-Version: 13"),
                  let key = lines.first(where: { $0.hasPrefix("Sec-WebSocket-Key: ") })?.dropFirst("Sec-WebSocket-Key: ".count) else {
                connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(WebSocketFrame.accept(for: String(key)))\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            upgraded = true
        }
        do {
            while let frame = try WebSocketFrame.decode(&buffer) {
                // A client must mask what it sends.
                guard frame.masked else { dropClient(); return }
                switch frame.opcode {
                case WebSocketFrame.text: onText?(String(decoding: frame.payload, as: UTF8.self))
                case WebSocketFrame.close: dropClient(); return
                case WebSocketFrame.ping:
                    connection.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.pong, payload: frame.payload),
                                    completion: .contentProcessed { _ in })
                default: break
                }
            }
        } catch {
            dropClient()
        }
    }

    // MARK: Keep-alives

    private func listen(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveKeepAlive(connection)
    }

    private func receiveKeepAlive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil else { return }
                if data == SoundcoreWiFi.keepAlive { self.keepAlives += 1 }
                self.receiveKeepAlive(connection)
            }
        }
    }

    private static func ready(_ listener: NWListener) async throws -> UInt16 {
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    guard !once.done else { return }
                    switch state {
                    case .ready: once.done = true; continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error): once.done = true; continuation.resume(throwing: error)
                    case .cancelled: once.done = true; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
}

/// The simulator's join: it succeeds when the simulated recorder's access point is open with that name
/// and password, unless told to fail as the system's join can.
@MainActor
public final class SimulatedSoundcoreHotspot: SoundcoreHotspot {
    public weak var recorder: SimulatedSoundcore?
    /// The next joins fail with this, as iOS's can: no entitlement, declined, or the network not found.
    public var failure: SoundcoreHotspotError?
    public private(set) var joins: [String] = []
    public private(set) var leaves: [String] = []
    /// The network joined now.
    public private(set) var joined: String?

    public init(recorder: SimulatedSoundcore?) {
        self.recorder = recorder
    }

    public func join(ssid: String, password: String, recorder host: String) async throws {
        joins.append(ssid)
        if let failure { throw failure }
        guard let accessPoint = recorder?.accessPoint, accessPoint.ssid == ssid, accessPoint.password == password else {
            throw SoundcoreHotspotError.failed("The network didn’t appear.")
        }
        joined = ssid
    }

    public func leave(ssid: String) {
        leaves.append(ssid)
        if joined == ssid { joined = nil }
    }
}

/// A self-signed P-256 certificate and its key as a TLS identity, made in memory (a hand-built DER
/// certificate in a PKCS #12 imported without a keychain), for the simulated access point.
enum SimulatedCertificate {
    nonisolated(unsafe) private static var cached: SecIdentity?
    private static let lock = NSLock()

    static func identity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = try make()
        cached = made
        return made
    }

    private static func make() throws -> SecIdentity {
        let key = P256.Signing.PrivateKey()
        let algorithm = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))
        let name = DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8("Simulated Soundcore Work"))))
        let now = Date()
        let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-86_400)), DER.utcTime(now.addingTimeInterval(86_400 * 30)))
        let publicKey = DER.sequence(DER.sequence(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")),
                                     DER.bits(Array(key.publicKey.x963Representation)))
        let serial = (0..<8).map { _ in UInt8.random(in: 1...127) }
        let body = DER.sequence(DER.explicit(0, DER.int(2)), DER.integer(serial), algorithm, name, validity, name, publicKey)
        let certificate = DER.sequence(body, algorithm, DER.bits(Array(try key.signature(for: Data(body)).derRepresentation)))

        let password = "simulated"
        let iterations = 2_048
        let attributes = DER.set(DER.sequence(DER.oid("1.2.840.113549.1.9.21"), DER.set(DER.octets(Array(Insecure.SHA1.hash(data: certificate))))))
        // The key, shrouded (pbeWithSHAAnd3-KeyTripleDES-CBC): an unencrypted key bag isn't imported.
        let keySalt = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let tripleKey = pkcs12Key(password, keySalt, id: 1, iterations: iterations, count: 24)
        let tripleIV = pkcs12Key(password, keySalt, id: 2, iterations: iterations, count: 8)
        let shrouded = DER.sequence(DER.sequence(DER.oid("1.2.840.113549.1.12.1.3"), DER.sequence(DER.octets(keySalt), DER.int(iterations))),
                                    DER.octets(try tripleDES(Array(key.derRepresentation), key: tripleKey, iv: tripleIV)))
        let keyBag = DER.sequence(DER.oid("1.2.840.113549.1.12.10.1.2"), DER.explicit(0, shrouded), attributes)
        let certificateBag = DER.sequence(DER.oid("1.2.840.113549.1.12.10.1.3"),
                                          DER.explicit(0, DER.sequence(DER.oid("1.2.840.113549.1.9.22.1"), DER.explicit(0, DER.octets(certificate)))),
                                          attributes)
        func content(_ data: [UInt8]) -> [UInt8] { DER.sequence(DER.oid("1.2.840.113549.1.7.1"), DER.explicit(0, DER.octets(data))) }
        let safe = DER.sequence(content(DER.sequence(certificateBag)), content(DER.sequence(keyBag)))
        let macSalt = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let macKey = pkcs12Key(password, macSalt, id: 3, iterations: iterations, count: 20)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: safe, using: SymmetricKey(data: macKey))
        let macData = DER.sequence(DER.sequence(DER.sequence(DER.oid("1.3.14.3.2.26"), DER.null), DER.octets(Array(mac))),
                                   DER.octets(macSalt), DER.int(iterations))
        let archive = DER.sequence(DER.int(3), content(safe), macData)

        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        options[kSecImportToMemoryOnly as String] = true
        var items: CFArray?
        let status = SecPKCS12Import(Data(archive) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw SoundcoreError.unsupported }
        return identity as! SecIdentity
    }

    /// PKCS #12's key derivation (RFC 7292 appendix B) with SHA-1.
    private static func pkcs12Key(_ password: String, _ salt: [UInt8], id: UInt8, iterations: Int, count: Int) -> [UInt8] {
        let v = 64
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            bytes.isEmpty ? [] : (0..<(v * ((bytes.count + v - 1) / v))).map { bytes[$0 % bytes.count] }
        }
        var secret: [UInt8] = []
        for unit in password.utf16 { secret += [UInt8(unit >> 8), UInt8(unit & 255)] }
        secret += [0, 0]
        var input = stretch(salt) + stretch(secret)
        var output: [UInt8] = []
        while output.count < count {
            var block = [UInt8](repeating: id, count: v) + input
            for _ in 0..<iterations { block = Array(Insecure.SHA1.hash(data: block)) }
            output += block
            let addend = (0..<v).map { block[$0 % block.count] }
            for start in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for index in (0..<v).reversed() {
                    let sum = Int(input[start + index]) + Int(addend[index]) + carry
                    input[start + index] = UInt8(sum & 255)
                    carry = sum >> 8
                }
            }
        }
        return Array(output.prefix(count))
    }

    private static func tripleDES(_ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSize3DES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw SoundcoreError.unsupported }
        return Array(output.prefix(moved))
    }

    /// Just enough DER for a certificate and a PKCS #12.
    private enum DER {
        static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
        static func length(_ count: Int) -> [UInt8] {
            guard count >= 128 else { return [UInt8(count)] }
            var bytes: [UInt8] = []
            var rest = count
            while rest > 0 { bytes.insert(UInt8(rest & 255), at: 0); rest >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        static func sequence(_ items: [UInt8]...) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
        static func set(_ items: [UInt8]...) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
        static func integer(_ value: [UInt8]) -> [UInt8] {
            var bytes = Array(value.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return tlv(0x02, bytes)
        }
        static func int(_ value: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            var rest = value
            repeat { bytes.insert(UInt8(rest & 255), at: 0); rest >>= 8 } while rest > 0
            return integer(bytes)
        }
        static func oid(_ dotted: String) -> [UInt8] {
            let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
            var bytes: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
            for arc in arcs.dropFirst(2) {
                var chunk: [UInt8] = [UInt8(arc & 0x7f)]
                var rest = arc >> 7
                while rest > 0 { chunk.insert(UInt8(rest & 0x7f) | 0x80, at: 0); rest >>= 7 }
                bytes += chunk
            }
            return tlv(0x06, bytes)
        }
        static func octets(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
        static func bits(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }
        static let null: [UInt8] = [0x05, 0x00]
        static func utf8(_ text: String) -> [UInt8] { tlv(0x0c, Array(text.utf8)) }
        static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xa0 | number, content) }
        static func utcTime(_ date: Date) -> [UInt8] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let text = String(format: "%02d%02d%02d%02d%02d%02dZ", (c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            return tlv(0x17, Array(text.utf8))
        }
    }
}
#endif
