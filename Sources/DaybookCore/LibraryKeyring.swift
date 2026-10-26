import CryptoKit
import Foundation

// Where a library's keys live (docs/icloud-sync.md, "Encryption"). In the apps, iCloud Keychain
// (`KeychainLibraryKeyStore` in DaybookKit), which carries a key to every device signed in to the account, end to end
// encrypted. Tests use `MemoryLibraryKeyStore`: one shared between replicas plays iCloud Keychain on, separate ones play
// it off (or a key that hasn't arrived yet).

/// The keys this device holds for its libraries.
public protocol LibraryKeyStore: AnyObject, Sendable {
    /// Every key held for `libraryID`. Throws when the store can't be read at all.
    func keys(for libraryID: UUID) throws -> [LibraryKey]
    /// Keeps `key`. Storing one already held changes nothing.
    func store(_ key: LibraryKey) throws
    /// Forgets a key (rotation, once no device needs it). On iCloud Keychain this removes it from every device.
    func remove(keyID: Data, libraryID: UUID) throws
}

public enum LibraryKeyStoreError: LocalizedError, Equatable {
    /// The keychain refused, with its status.
    case keychain(Int32)
    /// A key was stored but can't be read back: this build can't keep library keys.
    case notKept
    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "iCloud Keychain couldn’t keep the library’s key (\(status))."
        case .notKept: return "iCloud Keychain couldn’t keep the library’s key."
        }
    }
}

/// How a key is stored: the keychain item's value. `{key, libraryID, keyID, createdAt, createdBy}`.
public struct LibraryKeyRecord: Codable, Equatable, Sendable {
    public var key: Data
    public var libraryID: UUID
    public var keyID: String
    public var createdAt: Date
    public var createdBy: String

    public init(_ key: LibraryKey) {
        self.key = key.materialBytes; libraryID = key.libraryID; keyID = key.idHex; createdAt = key.createdAt; createdBy = key.createdBy
    }

    /// The key, when the record is whole and its ID matches its bytes.
    public var libraryKey: LibraryKey? {
        guard let key = try? LibraryKey(libraryID: libraryID, material: key, createdAt: createdAt, createdBy: createdBy),
              key.idHex == keyID else { return nil }
        return key
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> LibraryKeyRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryKeyRecord.self, from: data)
    }
}

/// Keys kept in memory. Share one between replicas to play iCloud Keychain carrying a key everywhere; give each its own
/// to play a device the key hasn't reached.
public final class MemoryLibraryKeyStore: LibraryKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [UUID: [Data: LibraryKey]] = [:]
    private var failure: LibraryKeyStoreError?

    public init(_ keys: [LibraryKey] = []) {
        for key in keys { held[key.libraryID, default: [:]][key.id] = key }
    }

    public func keys(for libraryID: UUID) throws -> [LibraryKey] {
        try lock.withLock {
            if let failure { throw failure }
            return held[libraryID].map { Array($0.values).sorted { $0.idHex < $1.idHex } } ?? []
        }
    }

    public func store(_ key: LibraryKey) throws {
        try lock.withLock {
            if let failure { throw failure }
            held[key.libraryID, default: [:]][key.id] = key
        }
    }

    public func remove(keyID: Data, libraryID: UUID) throws {
        lock.withLock { _ = held[libraryID]?.removeValue(forKey: keyID) }
    }

    /// Makes every call fail as a keychain that refuses would (nil: work again). Tests.
    public func fail(with error: LibraryKeyStoreError?) { lock.withLock { failure = error } }

    /// Every key held, for any library. Tests.
    public var allKeys: [LibraryKey] { lock.withLock { held.values.flatMap(\.values) } }
}

// MARK: Recovery key

/// A recovery key: 128 random bits the person keeps (printed, or in a password manager), shown as 26 Crockford base32
/// characters and 2 check characters in groups of four. The manifest keeps each library key wrapped with it
/// (`SyncManifest.Sealing.Key.recovery`), so a device that can't get the key from iCloud Keychain or another device
/// can still open the library.
public struct RecoveryKey: Equatable, Sendable {
    public let bytes: Data
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init?(bytes: Data) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public static func generate() -> RecoveryKey {
        RecoveryKey(bytes: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })!
    }

    /// Reads a recovery key as typed: case, spaces, and dashes don't matter, and O, I, and L read as 0, 1, and 1.
    /// Nil when it's the wrong length or its check characters don't match.
    public init?(_ text: String) {
        var values: [UInt8] = []
        for character in text.uppercased() {
            switch character {
            case " ", "-", "\t", "\n": continue
            case "O": values.append(0)
            case "I", "L": values.append(1)
            default:
                guard let index = Self.alphabet.firstIndex(of: character) else { return nil }
                values.append(UInt8(index))
            }
        }
        guard values.count == 28 else { return nil }
        // 26 characters hold 130 bits: the key, then two zero bits.
        var bits: [UInt8] = []
        for value in values.prefix(26) { for shift in stride(from: 4, through: 0, by: -1) { bits.append((value >> UInt8(shift)) & 1) } }
        guard bits[128] == 0, bits[129] == 0 else { return nil }
        var bytes = Data(count: 16)
        for index in 0..<128 where bits[index] == 1 { bytes[index / 8] |= 0x80 >> UInt8(index % 8) }
        guard let key = RecoveryKey(bytes: bytes), Array(values.suffix(2)) == key.check else { return nil }
        self = key
    }

    /// The key as it's shown: seven groups of four characters.
    public var text: String {
        var bits: [UInt8] = []
        for byte in bytes { for shift in stride(from: 7, through: 0, by: -1) { bits.append((byte >> UInt8(shift)) & 1) } }
        bits += [0, 0]
        var values: [UInt8] = stride(from: 0, to: 130, by: 5).map { start in bits[start..<start + 5].reduce(0) { $0 << 1 | $1 } }
        values += check
        let characters = values.map { Self.alphabet[Int($0)] }
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: "-")
    }

    /// Two characters (ten bits) of SHA-256 over the key, to catch a mistyped character.
    private var check: [UInt8] {
        let digest = [UInt8](SHA256.hash(data: Data("DBSEAL1 recovery check".utf8) + bytes))
        let ten = UInt16(digest[0]) << 2 | UInt16(digest[1] >> 6)
        return [UInt8(ten >> 5), UInt8(ten & 0x1f)]
    }

    private func wrappingKey(_ libraryID: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: SealedFormat.bytes(of: libraryID),
                               info: Data("DBSEAL1 recovery".utf8), outputByteCount: 32)
    }

    /// `key` sealed with this recovery key (AES-GCM, bound to the key's ID and library), as the manifest keeps it.
    public func wrap(_ key: LibraryKey) -> String {
        // AES-GCM with a 32-byte key and a random nonce can't fail.
        let box = try! AES.GCM.seal(key.materialBytes, using: wrappingKey(key.libraryID),
                                    authenticating: key.id + SealedFormat.bytes(of: key.libraryID))
        return box.combined!.base64EncodedString()
    }

    /// The library key `wrapped` holds, when this is the recovery key it was wrapped with.
    public func unwrap(_ wrapped: String, keyID: Data, libraryID: UUID, createdAt: Date, createdBy: String = "recovery") -> LibraryKey? {
        guard let data = Data(base64Encoded: wrapped), let box = try? AES.GCM.SealedBox(combined: data),
              let material = try? AES.GCM.open(box, using: wrappingKey(libraryID), authenticating: keyID + SealedFormat.bytes(of: libraryID)),
              let key = try? LibraryKey(libraryID: libraryID, material: material, createdAt: createdAt, createdBy: createdBy),
              key.id == keyID else { return nil }
        return key
    }
}
