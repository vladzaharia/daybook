import CryptoKit
import Foundation

// MARK: Code

/// The short code the Mac shows and the person types on the phone. Six digits, fresh for every
/// attempt: a failed or abandoned attempt burns it.
public struct LinkPairingCode: Sendable, Hashable, CustomStringConvertible {
    public let value: UInt32
    public let expiresAt: Date

    public init(value: UInt32, expiresAt: Date) {
        precondition(value < 1_000_000)
        self.value = value
        self.expiresAt = expiresAt
    }

    /// Reads what the person typed, ignoring spaces and dashes.
    public init?(typed: String, expiresAt: Date = .distantFuture) {
        let digits = typed.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == LinkProtocol.pairingCodeDigits, digits.allSatisfy(\.isASCII),
              digits.allSatisfy(\.isNumber), let value = UInt32(digits) else { return nil }
        self.init(value: value, expiresAt: expiresAt)
    }

    static func random(validFor lifetime: TimeInterval, now: Date) -> LinkPairingCode {
        LinkPairingCode(value: UInt32.random(in: 0..<1_000_000), expiresAt: now.addingTimeInterval(lifetime))
    }

    /// "048213"
    public var digits: String {
        let text = String(value)
        return String(repeating: "0", count: LinkProtocol.pairingCodeDigits - text.count) + text
    }

    /// "048 213", for display.
    public var formatted: String { "\(digits.prefix(3)) \(digits.suffix(3))" }

    public var description: String { formatted }

    func bit(_ round: Int) -> UInt8 { UInt8((value >> UInt32(round)) & 1) }
}

// MARK: Messages

/// Who is pairing, as told during pairing (and covered by the confirmation MACs).
struct PairingDevice: Codable, Equatable {
    var deviceID: UUID
    var name: String
    var deviceClass: LinkDeviceClass
    var appVersion: String
}

enum PairingMessage: Equatable {
    struct Begin: Codable, Equatable {
        var protocolVersion: Int
        var device: PairingDevice
        var publicKey: Data
    }

    struct Accept: Codable, Equatable {
        var device: PairingDevice
        var publicKey: Data
    }

    struct Refuse: Codable, Equatable {
        struct Reason: LinkOpenValue {
            let rawValue: String
            init(rawValue: String) { self.rawValue = rawValue }
            static let notPairing: Self = "notPairing"
            static let busy: Self = "busy"
            static let unsupportedVersion: Self = "unsupportedVersion"
        }
        var reason: Reason
    }

    struct Commit: Codable, Equatable {
        var round: Int
        var commitment: Data
    }

    struct Reveal: Codable, Equatable {
        var round: Int
        var nonce: Data
    }

    struct Confirm: Codable, Equatable {
        var mac: Data
    }

    struct Fail: Codable, Equatable {
        var reason: String
    }

    case begin(Begin)
    case accept(Accept)
    case refuse(Refuse)
    case commit(Commit)
    case reveal(Reveal)
    case confirm(Confirm)
    case fail(Fail)

    var type: String {
        switch self {
        case .begin: return "pair.begin"
        case .accept: return "pair.accept"
        case .refuse: return "pair.refuse"
        case .commit: return "pair.commit"
        case .reveal: return "pair.reveal"
        case .confirm: return "pair.confirm"
        case .fail: return "pair.fail"
        }
    }

    func encode(version: Int, with encoder: JSONEncoder) throws -> Data {
        switch self {
        case .begin(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .accept(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .refuse(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .commit(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .reveal(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .confirm(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        case .fail(let b): return try LinkWire.envelope(type: type, version: version, body: b, with: encoder)
        }
    }

    static func decode(type: String, data: Data, with decoder: JSONDecoder) throws -> PairingMessage? {
        switch type {
        case "pair.begin": return .begin(try LinkWire.body(Begin.self, from: data, with: decoder))
        case "pair.accept": return .accept(try LinkWire.body(Accept.self, from: data, with: decoder))
        case "pair.refuse": return .refuse(try LinkWire.body(Refuse.self, from: data, with: decoder))
        case "pair.commit": return .commit(try LinkWire.body(Commit.self, from: data, with: decoder))
        case "pair.reveal": return .reveal(try LinkWire.body(Reveal.self, from: data, with: decoder))
        case "pair.confirm": return .confirm(try LinkWire.body(Confirm.self, from: data, with: decoder))
        case "pair.fail": return .fail(try LinkWire.body(Fail.self, from: data, with: decoder))
        default: return nil
        }
    }
}

// MARK: Errors

/// Why pairing didn't finish.
public enum LinkPairingError: Error, Sendable, Equatable {
    /// The code was wrong, or someone in between changed the exchange. Get a new code on the Mac.
    case codeRejected
    /// This code already failed once from this phone. Codes are single-use; get a new one.
    case codeAlreadyUsed
    /// Not six digits.
    case invalidCode
    /// The Mac isn't showing a code right now.
    case notPairing
    /// The Mac is pairing with another device right now.
    case busy
    /// The Mac closed pairing after too many failed attempts.
    case tooManyAttempts
    /// The Mac's code expired.
    case expired
    case unsupportedVersion
    case timedOut
    case connectionFailed(String)
    /// The other side broke the exchange's rules.
    case protocolViolation(String)
}

// MARK: Exchange

/// A passkey-entry pairing: P-256 ECDH, authenticated by a six-digit code, one commit/reveal round
/// per bit of the code. This is the structure of Bluetooth LE Secure Connections "Passkey Entry"
/// (Core Spec Vol 3 Part H §2.3.5.6.3), with HMAC-SHA256 and HKDF-SHA256 in place of AES-CMAC.
///
/// Each round, both sides commit to (role, both public keys, the code's bit) under a fresh nonce
/// before either reveals. A device in the middle has different public keys on each side, so it
/// must commit to every bit before it can learn it: it succeeds with probability 2^-20 per
/// attempt. A failed attempt reveals some bits, which is why codes are never reused. A passive
/// observer learns nothing about the key (ECDH). Role tags and a check that the keys differ stop
/// reflection. Both sides then confirm with MACs over the whole transcript, and derive the link
/// key from the ECDH secret and the transcript.
///
/// Pure and transport-agnostic: frames in, frames out.
final class PasskeyExchange {
    enum Role: Equatable { case initiator, responder }

    struct Outcome: Equatable {
        var peer: PairingDevice
        var linkKey: Data
        var pskIdentity: Data
    }

    enum Failure: Error, Equatable {
        case codeMismatch
        case confirmationMismatch
        case refused(PairingMessage.Refuse.Reason)
        case peerFailed(String)
        case invalidKey
        case unexpected(String)
    }

    private enum Step: Equatable {
        case idle
        case awaitingBegin, awaitingAccept
        case awaitingPeerCommit(Int)   // initiator: sent commit i
        case awaitingCommit(Int)       // responder: awaiting the initiator's commit i
        case awaitingReveal(Int)       // either: sent own reveal/commit, waiting for the peer's nonce
        case awaitingConfirm
        case done, failed
    }

    let role: Role
    private let code: LinkPairingCode
    private let local: PairingDevice
    private let privateKey: P256.KeyAgreement.PrivateKey
    private var publicKey: Data { privateKey.publicKey.x963Representation }
    private var peerKey: P256.KeyAgreement.PublicKey?
    private var peer: PairingDevice?
    private var step: Step = .idle
    private var transcript = SHA256()
    private var transcriptDigest: Data?
    private var nonce = Data()
    private var peerCommitment = Data()
    private var keys: (confirm: SymmetricKey, link: Data, identity: Data)?
    private(set) var outcome: Outcome?

    init(role: Role, code: LinkPairingCode, local: PairingDevice,
         privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
        self.role = role
        self.code = code
        self.local = local
        self.privateKey = privateKey
        step = role == .initiator ? .idle : .awaitingBegin
    }

    var isFinished: Bool { step == .done }

    /// Initiator: the first frame.
    func start() throws -> Data {
        guard role == .initiator, step == .idle else { throw Failure.unexpected("start") }
        step = .awaitingAccept
        return try send(.begin(.init(protocolVersion: LinkProtocol.pairingVersion, device: local, publicKey: publicKey)))
    }

    /// Feeds one frame from the peer; returns the frames to send back, in order.
    func receive(_ frame: Data) throws -> [Data] {
        do {
            return try handle(frame)
        } catch {
            step = .failed
            throw error
        }
    }

    private func handle(_ frame: Data) throws -> [Data] {
        guard case .pairing(let message) = try LinkWire.decode(frame).message else { throw Failure.unexpected("not pairing") }
        if case .fail(let fail) = message { throw Failure.peerFailed(fail.reason) }
        if case .refuse(let refuse) = message { throw Failure.refused(refuse.reason) }
        if Self.isInTranscript(message) { transcript.update(data: frame) }

        switch (role, step, message) {
        case (.responder, .awaitingBegin, .begin(let begin)):
            guard begin.protocolVersion == LinkProtocol.pairingVersion else { throw Failure.refused(.unsupportedVersion) }
            try adopt(peer: begin.device, key: begin.publicKey)
            step = .awaitingCommit(0)
            return [try send(.accept(.init(device: local, publicKey: publicKey)))]

        case (.initiator, .awaitingAccept, .accept(let accept)):
            try adopt(peer: accept.device, key: accept.publicKey)
            return [try commit(round: 0)]

        case (.responder, .awaitingCommit(let round), .commit(let c)) where c.round == round:
            peerCommitment = c.commitment
            step = .awaitingReveal(round)
            return [try commit(round: round)]

        case (.initiator, .awaitingPeerCommit(let round), .commit(let c)) where c.round == round:
            peerCommitment = c.commitment
            step = .awaitingReveal(round)
            return [try send(.reveal(.init(round: round, nonce: nonce)))]

        case (.responder, .awaitingReveal(let round), .reveal(let r)) where r.round == round:
            try verify(reveal: r.nonce, round: round)
            let reveal = try send(.reveal(.init(round: round, nonce: nonce)))
            step = round + 1 < LinkProtocol.pairingRounds ? .awaitingCommit(round + 1) : .awaitingConfirm
            if step == .awaitingConfirm { try deriveKeys() }
            return [reveal]

        case (.initiator, .awaitingReveal(let round), .reveal(let r)) where r.round == round:
            try verify(reveal: r.nonce, round: round)
            if round + 1 < LinkProtocol.pairingRounds { return [try commit(round: round + 1)] }
            try deriveKeys()
            step = .awaitingConfirm
            return [try send(.confirm(.init(mac: confirmation(for: .initiator))))]

        case (.responder, .awaitingConfirm, .confirm(let c)):
            // The initiator proved the code and the transcript: the responder is done, and its
            // confirmation is the last frame.
            try check(confirmation: c.mac, from: .initiator)
            finish()
            return [try send(.confirm(.init(mac: confirmation(for: .responder))))]

        case (.initiator, .awaitingConfirm, .confirm(let c)):
            try check(confirmation: c.mac, from: .responder)
            finish()
            return []

        default:
            throw Failure.unexpected("\(message.type) during \(step)")
        }
    }

    /// A frame telling the peer why this side gave up.
    static func failFrame(_ reason: String) -> Data {
        (try? LinkWire.encode(.pairing(.fail(.init(reason: reason))), version: LinkProtocol.baselineVersion)) ?? Data()
    }

    static func refuseFrame(_ reason: PairingMessage.Refuse.Reason) -> Data {
        (try? LinkWire.encode(.pairing(.refuse(.init(reason: reason))), version: LinkProtocol.baselineVersion)) ?? Data()
    }

    // MARK: Steps

    private func send(_ message: PairingMessage) throws -> Data {
        let frame = try LinkWire.encode(.pairing(message), version: LinkProtocol.baselineVersion)
        if Self.isInTranscript(message) { transcript.update(data: frame) }
        return frame
    }

    /// Confirmations are computed over the transcript before them, so they stay out of it.
    private static func isInTranscript(_ message: PairingMessage) -> Bool {
        switch message {
        case .begin, .accept, .commit, .reveal: return true
        case .refuse, .confirm, .fail: return false
        }
    }

    private func adopt(peer device: PairingDevice, key: Data) throws {
        guard let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: key) else { throw Failure.invalidKey }
        // Reflection: a peer echoing this side's own key (or identity) back.
        guard key != publicKey, device.deviceID != local.deviceID else { throw Failure.invalidKey }
        self.peerKey = peerKey
        peer = device
    }

    private func commit(round: Int) throws -> Data {
        nonce = Self.randomBytes(32)
        let commitment = Self.commitment(nonce: nonce, role: role, ownKey: publicKey,
                                         otherKey: peerKey!.x963Representation, bit: code.bit(round))
        if role == .initiator { step = .awaitingPeerCommit(round) }
        return try send(.commit(.init(round: round, commitment: commitment)))
    }

    private func verify(reveal peerNonce: Data, round: Int) throws {
        guard peerNonce.count == 32, let peerKey else { throw Failure.codeMismatch }
        let expected = Self.commitment(nonce: peerNonce, role: role == .initiator ? .responder : .initiator,
                                       ownKey: peerKey.x963Representation, otherKey: publicKey, bit: code.bit(round))
        guard Self.constantTimeEqual(expected, peerCommitment) else { throw Failure.codeMismatch }
    }

    private func deriveKeys() throws {
        guard let peerKey, let peer else { throw Failure.unexpected("no peer") }
        let digest = Data(transcript.finalize())
        transcriptDigest = digest
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let (initiatorID, responderID) = role == .initiator ? (local.deviceID, peer.deviceID) : (peer.deviceID, local.deviceID)
        var info = Data("DaybookLink pairing keys v1".utf8)
        info.append(Self.bytes(of: initiatorID))
        info.append(Self.bytes(of: responderID))
        let material = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest, sharedInfo: info, outputByteCount: 80)
        let bytes = material.withUnsafeBytes { Data($0) }
        keys = (SymmetricKey(data: bytes.prefix(32)), Data(bytes[32..<64]), Data(bytes[64..<80]))
    }

    private func confirmation(for role: Role) -> Data {
        var message = Data(role == .initiator ? "DaybookLink confirm initiator v1".utf8 : "DaybookLink confirm responder v1".utf8)
        message.append(transcriptDigest ?? Data())
        withUnsafeBytes(of: code.value.bigEndian) { message.append(contentsOf: $0) }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: keys!.confirm))
    }

    private func check(confirmation mac: Data, from role: Role) throws {
        guard keys != nil, Self.constantTimeEqual(confirmation(for: role), mac) else { throw Failure.confirmationMismatch }
    }

    private func finish() {
        guard let keys, let peer else { return }
        outcome = Outcome(peer: peer, linkKey: keys.link, pskIdentity: keys.identity)
        step = .done
    }

    // MARK: Primitives

    static func commitment(nonce: Data, role: Role, ownKey: Data, otherKey: Data, bit: UInt8) -> Data {
        var message = Data("DaybookLink pairing commitment v1".utf8)
        message.append(role == .initiator ? 0x49 : 0x52)
        message.append(ownKey)
        message.append(otherKey)
        message.append(bit)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: nonce)))
    }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    static func bytes(of id: UUID) -> Data { withUnsafeBytes(of: id.uuid) { Data($0) } }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
