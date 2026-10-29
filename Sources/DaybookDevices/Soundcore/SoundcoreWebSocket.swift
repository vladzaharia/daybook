import CryptoKit
import Foundation
import Network

/// RFC 6455 framing: what Fast Transfer's WebSocket client and the simulator's access point share.
public enum WebSocketFrame {
    public static let text: UInt8 = 0x1, binary: UInt8 = 0x2, close: UInt8 = 0x8, ping: UInt8 = 0x9, pong: UInt8 = 0xa
    /// The largest frame either side accepts.
    public static let maximumPayload = 16 << 20

    /// A whole frame. A client masks what it sends (`mask`); a server doesn't.
    public static func encode(opcode: UInt8, payload: Data, mask: [UInt8]? = nil) -> Data {
        var frame = Data([0x80 | opcode])
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        switch payload.count {
        case ..<126: frame.append(maskBit | UInt8(payload.count))
        case ..<65_536: frame.append(maskBit | 126); frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        default:
            frame.append(maskBit | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> (8 * UInt64($0))) & 255) })
        }
        guard let mask, mask.count == 4 else { return frame + payload }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// The next whole frame at the front of `buffer`, removed from it; nil until one has arrived.
    /// Throws on a frame too large or malformed.
    public static func decode(_ buffer: inout Data) throws -> (fin: Bool, opcode: UInt8, masked: Bool, payload: Data)? {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return nil }
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            let wide = (2..<10).reduce(UInt64(0)) { $0 << 8 | UInt64(b[$1]) }
            guard wide <= UInt64(maximumPayload) else { throw WebSocketError.protocolError("A frame was too large.") }
            length = Int(wide)
            offset = 10
        }
        guard length <= maximumPayload else { throw WebSocketError.protocolError("A frame was too large.") }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        let start = buffer.startIndex
        let key = masked ? [UInt8](buffer[(start + offset)..<(start + offset + 4)]) : []
        var payload = Data(buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
        if masked { payload = Data(payload.enumerated().map { $0.element ^ key[$0.offset % 4] }) }
        buffer.removeFirst(offset + maskLength + length)
        return (b[0] & 0x80 != 0, b[0] & 0x0f, masked, payload)
    }

    /// The `Sec-WebSocket-Accept` a server answers `key` with.
    public static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
}

public enum WebSocketError: LocalizedError, Equatable {
    case handshake(String), protocolError(String), closed, timedOut, network(String)

    public var errorDescription: String? {
        switch self {
        case .handshake(let detail): return "The recorder refused the WebSocket: \(detail)"
        case .protocolError(let detail): return detail
        case .closed: return "The recorder closed the WebSocket."
        case .timedOut: return "The recorder’s WebSocket didn’t answer in time."
        case .network(let detail): return detail
        }
    }
}

/// A WebSocket client over TLS for the recorder's access point, on Network.framework. It writes its own
/// opening handshake, so the header names, their case, and their order are what the official app's
/// HTTP client sends (the recorder's parser may match them exactly). It accepts the recorder's
/// self-signed certificate, for this one connection to the recorder's own network: the audio itself is
/// encrypted with the key exchanged over Bluetooth, and checked as a Bluetooth transfer is.
@MainActor
final class SoundcoreWebSocket {
    enum Message: Equatable { case text(String), binary(Data) }

    /// Messages, and the end of the connection (nil error: closed by this side), on the main actor.
    var onMessage: ((Message) -> Void)?
    var onClose: ((Error?) -> Void)?
    private(set) var isOpen = false

    private let connection: NWConnection
    private let host: String
    private let port: UInt16
    private let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var buffer = Data()
    private var fragments: (opcode: UInt8, data: Data)?
    private var opening: CheckedContinuation<Void, Error>?
    private var ended = false

    init(host: String, port: UInt16, requiresWiFi: Bool) {
        self.host = host
        self.port = port
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        let parameters = NWParameters(tls: tls)
        if requiresWiFi { parameters.requiredInterfaceType = .wifi }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: parameters)
    }

    /// The request line and headers, as the official app's client (OkHttp) writes them.
    var handshake: String {
        let authority = port == 443 ? host : "\(host):\(port)"
        return "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\n"
            + "Sec-WebSocket-Version: 13\r\nHost: \(authority)\r\nAccept-Encoding: gzip\r\nUser-Agent: okhttp/3.12.13.18\r\n\r\n"
    }

    /// Connects (TCP, TLS, the opening handshake) within `timeout`.
    func open(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(WebSocketError.timedOut)
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !ended else { continuation.resume(throwing: CancellationError()); return }
                opening = continuation
                connection.stateUpdateHandler = { [weak self] state in MainActor.assumeIsolated { self?.changed(state) } }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    func send(text: String) throws {
        guard isOpen, !ended else { throw WebSocketError.closed }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        connection.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.text, payload: Data(text.utf8), mask: mask),
                        completion: .contentProcessed { _ in })
    }

    /// Closes from this side: a close frame, then the connection.
    func close() {
        guard !ended else { return }
        if isOpen {
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            connection.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.close, payload: Data([0x03, 0xe8]), mask: mask),
                            completion: .contentProcessed { _ in })
        }
        end(nil)
    }

    // MARK: The connection

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
            receive()
        case .waiting(let error), .failed(let error):
            // Waiting means no route (not on the recorder's network yet): an attempt that's failed.
            fail(WebSocketError.network(error.localizedDescription))
        case .cancelled:
            fail(WebSocketError.closed)
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { self.received(data) }
                if let error { self.fail(WebSocketError.network(error.localizedDescription)) }
                else if complete { self.fail(WebSocketError.closed) }
                else { self.receive() }
            }
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        do {
            if !isOpen {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 16_384 { throw WebSocketError.handshake("The reply was too long.") }
                    return
                }
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                try accept(head)
                isOpen = true
                opening?.resume()
                opening = nil
            }
            while !ended, let frame = try WebSocketFrame.decode(&buffer) { handle(frame.fin, frame.opcode, frame.payload) }
        } catch {
            fail(error)
        }
    }

    private func accept(_ head: String) throws {
        let lines = head.components(separatedBy: "\r\n")
        guard let status = lines.first, status.hasPrefix("HTTP/1.1 101") else {
            throw WebSocketError.handshake(lines.first ?? "No reply")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              fields["sec-websocket-accept"] == WebSocketFrame.accept(for: key) else {
            throw WebSocketError.handshake("The upgrade wasn’t confirmed.")
        }
    }

    private func handle(_ fin: Bool, _ opcode: UInt8, _ payload: Data) {
        switch opcode {
        case WebSocketFrame.text, WebSocketFrame.binary:
            if fin { deliver(opcode, payload) } else { fragments = (opcode, payload) }
        case 0:
            guard var fragments else { return fail(WebSocketError.protocolError("A continuation frame came first.")) }
            fragments.data.append(payload)
            if fin { self.fragments = nil; deliver(fragments.opcode, fragments.data) } else { self.fragments = fragments }
        case WebSocketFrame.ping:
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            connection.send(content: WebSocketFrame.encode(opcode: WebSocketFrame.pong, payload: payload, mask: mask),
                            completion: .contentProcessed { _ in })
        case WebSocketFrame.close:
            fail(WebSocketError.closed)
        default:
            break
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: Data) {
        onMessage?(opcode == WebSocketFrame.text ? .text(String(decoding: payload, as: UTF8.self)) : .binary(payload))
    }

    private func fail(_ error: Error) { end(error) }

    private func end(_ error: Error?) {
        guard !ended else { return }
        ended = true
        isOpen = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let opening {
            self.opening = nil
            opening.resume(throwing: error ?? WebSocketError.closed)
        } else {
            onClose?(error)
        }
    }
}

/// The recorder's UDP keep-alive, every `interval` while the WebSocket is open.
@MainActor
final class SoundcoreKeepAlive {
    private let connection: NWConnection
    private var task: Task<Void, Never>?

    init(host: String, port: UInt16, requiresWiFi: Bool, interval: Duration) {
        let parameters = NWParameters.udp
        if requiresWiFi { parameters.requiredInterfaceType = .wifi }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 32003, using: parameters)
        connection.start(queue: .main)
        task = Task { [connection] in
            while !Task.isCancelled {
                connection.send(content: SoundcoreWiFi.keepAlive, completion: .contentProcessed { _ in })
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        connection.cancel()
    }
}
