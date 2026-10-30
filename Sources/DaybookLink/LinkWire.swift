import Foundation

/// The versions a side speaks, as sent in hello.
struct LinkVersionRange: Codable, Equatable, Sendable {
    var min: Int
    var max: Int

    init(_ range: ClosedRange<Int>) {
        min = range.lowerBound
        max = range.upperBound
    }

    init(min: Int, max: Int) {
        self.min = min
        self.max = max
    }

    var range: ClosedRange<Int>? { min <= max ? min...max : nil }

    /// The highest version both sides speak, or nil.
    static func negotiate(local: ClosedRange<Int>, remote: LinkVersionRange) -> Int? {
        guard let remote = remote.range else { return nil }
        let high = Swift.min(local.upperBound, remote.upperBound)
        let low = Swift.max(local.lowerBound, remote.lowerBound)
        return high >= low ? high : nil
    }
}

// MARK: Control bodies

struct Hello: Codable, Equatable {
    var versions: LinkVersionRange
    var deviceID: UUID
    /// Who the client expects to reach, so a Mac never answers for another Mac's pairing.
    var serverID: UUID
    var capabilities: LinkCapabilities
    /// HMAC over the TLS exporter: proves this TLS session's peer holds the pairing key.
    var auth: Data
    /// Seconds between the sender's heartbeats; the slower side sets the pace.
    var heartbeatInterval: TimeInterval?
}

struct Welcome: Codable, Equatable {
    var version: Int
    var deviceID: UUID
    var capabilities: LinkCapabilities
    var auth: Data
    var heartbeatInterval: TimeInterval?
}

struct Refusal: Codable, Equatable {
    struct Reason: LinkOpenValue {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let incompatibleVersion: Self = "incompatibleVersion"
        static let notPaired: Self = "notPaired"
        static let authenticationFailed: Self = "authenticationFailed"
        static let wrongDevice: Self = "wrongDevice"
    }

    var reason: Reason
    var versions: LinkVersionRange?
}

struct Heartbeat: Codable, Equatable {
    var sequence: UInt64
    var interval: TimeInterval?
}

struct ClockRequest: Codable, Equatable {
    var sequence: UInt64
    var t1: Date
}

struct ClockReply: Codable, Equatable {
    var sequence: UInt64
    var t1: Date
    var t2: Date
    var t3: Date
}

struct Goodbye: Codable, Equatable {
    var reason: String?
}

struct EmptyBody: Codable, Equatable {}

// MARK: Wire messages

/// Everything that can travel in a frame.
enum WireMessage: Equatable {
    case hello(Hello)
    case welcome(Welcome)
    case refused(Refusal)
    case capabilities(LinkCapabilities)
    case app(LinkMessage)
    case recordRequest(LinkRecordRequest)
    case recordReply(LinkRecordReply)
    case ping(Heartbeat)
    case pong(Heartbeat)
    case clockRequest(ClockRequest)
    case clockReply(ClockReply)
    case unpair
    case goodbye(Goodbye)
    case pairing(PairingMessage)
    /// A type this build doesn't know. Ignored.
    case unknown(String)

    var type: String {
        switch self {
        case .hello: return "hello"
        case .welcome: return "welcome"
        case .refused: return "refused"
        case .capabilities: return "capabilities"
        case .app(.recordingState): return "recording.state"
        case .app(.bookmark): return "bookmark"
        case .app(.processingProgress): return "processing.progress"
        case .app(.processingNudge): return "processing.nudge"
        case .app(.recorderHandoffRequest): return "recorder.handoff.request"
        case .app(.recorderHandoffReply): return "recorder.handoff.reply"
        case .app(.recorderRelease): return "recorder.release"
        case .app(.libraryKeyRequest): return "libraryKey.request"
        case .app(.libraryKeyGrant): return "libraryKey.grant"
        case .app(.note): return "note"
        case .app(.bookmarkChange): return "bookmark.change"
        case .app(.captions): return "captions"
        case .recordRequest: return "record.request"
        case .recordReply: return "record.reply"
        case .ping: return "ping"
        case .pong: return "pong"
        case .clockRequest: return "clock.request"
        case .clockReply: return "clock.reply"
        case .unpair: return "unpair"
        case .goodbye: return "goodbye"
        case .pairing(let message): return message.type
        case .unknown(let type): return type
        }
    }
}

enum LinkWireError: Error, Equatable {
    case malformed
    case unencodable
}

/// Encodes messages as `{"v": version, "type": "...", "body": {...}}`, one per frame.
///
/// Compatibility rules: within a version, only add optional fields and new types. Receivers
/// ignore unknown types and unknown fields; values that may grow are `LinkOpenValue`s.
enum LinkWire {
    private struct Header: Decodable {
        var v: Int
        var type: String
    }

    private struct Envelope<Body: Codable>: Codable {
        var v: Int
        var type: String
        var body: Body
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    static func encode(_ message: WireMessage, version: Int) throws -> Data {
        let encoder = encoder()
        func pack<B: Codable>(_ body: B) throws -> Data {
            try encoder.encode(Envelope(v: version, type: message.type, body: body))
        }
        switch message {
        case .hello(let body): return try pack(body)
        case .welcome(let body): return try pack(body)
        case .refused(let body): return try pack(body)
        case .capabilities(let body): return try pack(body)
        case .app(.recordingState(let body)): return try pack(body)
        case .app(.bookmark(let body)): return try pack(body)
        case .app(.processingProgress(let body)): return try pack(body)
        case .app(.processingNudge(let body)): return try pack(body)
        case .app(.recorderHandoffRequest(let body)): return try pack(body)
        case .app(.recorderHandoffReply(let body)): return try pack(body)
        case .app(.recorderRelease(let body)): return try pack(body)
        case .app(.libraryKeyRequest(let body)): return try pack(body)
        case .app(.libraryKeyGrant(let body)): return try pack(body)
        case .app(.note(let body)): return try pack(body)
        case .app(.bookmarkChange(let body)): return try pack(body)
        case .app(.captions(let body)): return try pack(body)
        case .recordRequest(let body): return try pack(body)
        case .recordReply(let body): return try pack(body)
        case .ping(let body), .pong(let body): return try pack(body)
        case .clockRequest(let body): return try pack(body)
        case .clockReply(let body): return try pack(body)
        case .unpair: return try pack(EmptyBody())
        case .goodbye(let body): return try pack(body)
        case .pairing(let pairing): return try pairing.encode(version: version, with: encoder)
        case .unknown: throw LinkWireError.unencodable
        }
    }

    /// Decodes a frame. Unknown types come back as `.unknown`; a known type whose body can't be
    /// read throws.
    static func decode(_ data: Data) throws -> (version: Int, message: WireMessage) {
        let decoder = decoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw LinkWireError.malformed }
        func body<B: Codable>(_ type: B.Type) throws -> B {
            do { return try decoder.decode(Envelope<B>.self, from: data).body } catch { throw LinkWireError.malformed }
        }
        let message: WireMessage
        switch header.type {
        case "hello": message = .hello(try body(Hello.self))
        case "welcome": message = .welcome(try body(Welcome.self))
        case "refused": message = .refused(try body(Refusal.self))
        case "capabilities": message = .capabilities(try body(LinkCapabilities.self))
        case "recording.state": message = .app(.recordingState(try body(LinkRecordingState.self)))
        case "bookmark": message = .app(.bookmark(try body(LinkBookmark.self)))
        case "processing.progress": message = .app(.processingProgress(try body(LinkProcessingProgress.self)))
        case "processing.nudge": message = .app(.processingNudge(try body(LinkProcessingNudge.self)))
        case "recorder.handoff.request": message = .app(.recorderHandoffRequest(try body(LinkRecorderHandoffRequest.self)))
        case "recorder.handoff.reply": message = .app(.recorderHandoffReply(try body(LinkRecorderHandoffReply.self)))
        case "recorder.release": message = .app(.recorderRelease(try body(LinkRecorderRelease.self)))
        case "libraryKey.request": message = .app(.libraryKeyRequest(try body(LinkLibraryKeyRequest.self)))
        case "libraryKey.grant": message = .app(.libraryKeyGrant(try body(LinkLibraryKeyGrant.self)))
        case "note": message = .app(.note(try body(LinkNote.self)))
        case "bookmark.change": message = .app(.bookmarkChange(try body(LinkBookmarkChange.self)))
        case "captions": message = .app(.captions(try body(LinkCaptions.self)))
        case "record.request": message = .recordRequest(try body(LinkRecordRequest.self))
        case "record.reply": message = .recordReply(try body(LinkRecordReply.self))
        case "ping": message = .ping(try body(Heartbeat.self))
        case "pong": message = .pong(try body(Heartbeat.self))
        case "clock.request": message = .clockRequest(try body(ClockRequest.self))
        case "clock.reply": message = .clockReply(try body(ClockReply.self))
        case "unpair": message = .unpair
        case "goodbye": message = .goodbye(try body(Goodbye.self))
        default:
            if let pairing = try PairingMessage.decode(type: header.type, data: data, with: decoder) {
                message = .pairing(pairing)
            } else {
                message = .unknown(header.type)
            }
        }
        return (header.v, message)
    }

    // Used by PairingMessage.
    static func envelope<B: Codable>(type: String, version: Int, body: B, with encoder: JSONEncoder) throws -> Data {
        try encoder.encode(Envelope(v: version, type: type, body: body))
    }

    static func body<B: Codable>(_ type: B.Type, from data: Data, with decoder: JSONDecoder) throws -> B {
        do { return try decoder.decode(Envelope<B>.self, from: data).body } catch { throw LinkWireError.malformed }
    }
}
