import CommonCrypto
import CryptoKit
import Foundation

/// Ephemeral session keys are kept in memory and discarded on disconnect. The D3200 firmware sends
/// the raw shared secret in its reply: this exchange provides neither identity authentication nor
/// confidentiality against an observer of characteristic traffic. Protection depends on BLE link
/// security, which has not been verified on physical hardware. See docs/direct-soundcore.md.
public final class SoundcoreCrypto {
    private var privateKey = P256.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    public var isReady: Bool { sessionKey != nil }
    public var publicKey: Data { privateKey.publicKey.x963Representation }

    public func reset() { sessionKey = nil; privateKey = P256.KeyAgreement.PrivateKey() }

    public func completeHandshake(_ payload: Data) throws {
        sessionKey = nil
        guard payload.count >= 97 else { throw SoundcoreError.invalidEncryption }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: payload.prefix(65))
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let expected = Data(payload.dropFirst(65).prefix(32))
        let matches = secret.withUnsafeBytes { bytes -> Bool in
            guard bytes.count == expected.count else { return false }
            return zip(bytes, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
        guard matches else { throw SoundcoreError.invalidEncryption }
        sessionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data([1,2,3]),
                                                     sharedInfo: Data([1,2,3]), outputByteCount: 32)
    }

    public func fileKey(from payload: Data, expectedID: UInt32) throws -> SoundcoreFileKey {
        let b = [UInt8](payload)
        guard b.count >= 87, (try? b.le32(at: 0)) == expectedID, let sessionKey, b[86] == 0 else {
            throw SoundcoreError.invalidEncryption
        }
        let key = sessionKey.withUnsafeBytes { Data($0) }
        let material = try Self.crypt(Data(b[24..<70]), key: key, iv: Data(b[70..<86]))
        let prefix = Data("soundcored3200".utf8)
        guard material.count == prefix.count + 32, material.prefix(prefix.count) == prefix else {
            throw SoundcoreError.invalidEncryption
        }
        return .init(key: Data(material.suffix(32)), nonce: Data(b[8..<24]), expectedBytes: try b.le32(at: 4))
    }

    /// AES-CTR is symmetric, so the same call encrypts (the simulator) and decrypts.
    public static func crypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw SoundcoreError.invalidEncryption }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw SoundcoreError.invalidEncryption }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                CCCryptorUpdate(cryptor, source.baseAddress, input.count, destination.baseAddress, capacity, &count)
            }
        }
        guard status == kCCSuccess, count == input.count else { throw SoundcoreError.invalidEncryption }
        output.count = count
        return output
    }
}

public struct SoundcoreFileKey {
    public let key: Data
    public let nonce: Data
    public let expectedBytes: UInt32

    public func decrypt(_ slice: SoundcoreAudioSlice) throws -> Data {
        try Self.crypt(slice.audio, sequence: slice.sequence, key: key, nonce: nonce)
    }

    /// Per-slice AES-CTR with a counter derived from the slice's sequence number.
    public static func crypt(_ audio: Data, sequence: UInt32, key: Data, nonce: Data) throws -> Data {
        guard nonce.count == 16, sequence <= UInt32.max / 10 else { throw SoundcoreError.invalidEncryption }
        let counter = sequence * 10
        var iv = Data(nonce.prefix(12))
        iv.append(contentsOf: [UInt8(counter >> 24), UInt8((counter >> 16) & 255), UInt8((counter >> 8) & 255), UInt8(counter & 255)])
        return try SoundcoreCrypto.crypt(audio, key: key, iv: iv)
    }

    public init(key: Data, nonce: Data, expectedBytes: UInt32) {
        self.key = key
        self.nonce = nonce
        self.expectedBytes = expectedBytes
    }
}
