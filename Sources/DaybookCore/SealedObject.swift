import CryptoKit
import Foundation

// The sealed journal format, DBSEAL version 1 (docs/icloud-sync.md, "Encryption"). Every journal file of an
// encrypted library is one sealed object: a fixed 84-byte header, then the plaintext in 1 MiB chunks, each sealed
// with AES-256-GCM under a key derived for that object alone.
//
//   magic "DBSEAL" (6) | version 1 (1) | kind (1) | suite 1 (1) | chunkLog2 20 (1) | reserved 0 (2)
//   | keyID (16) | libraryID (16) | S (32) | plaintextLength, big-endian (8)
//
//   S       = HMAC-SHA256(K_name, kind ‖ libraryID ‖ SHA-256(plaintext)), the object's file name (hex)
//   K_file  = HKDF-SHA256(K_enc, salt: S, info: "DBSEAL1 file" ‖ kind), 32 bytes
//   chunk i = AES-GCM(K_file, nonce: 0x00000000 ‖ u64be(i), aad: header ‖ u64be(i) ‖ final) → ciphertext ‖ tag
//
// Sealing is deterministic: the same key and plaintext give the same name and the same bytes, so a pass that writes
// an entry again writes identical bytes and two devices sealing one object agree. A nonce is never reused with a
// different plaintext, because each object has its own key. The counter and the final flag stop chunks from being
// reordered, dropped, or the object truncated; the header is authenticated with every chunk. The format is frozen by
// the known-answer vectors in SealedObjectTests: change nothing here without a new version.

/// What a sealed object holds. Its folder must match (`Sealed/Events`, `Sealed/Metadata`, `Sealed/Blobs`); presence
/// records carry their sealed part inline.
public enum SealedKind: UInt8, Sendable, CaseIterable {
    case event = 1, metadata = 2, blob = 3, presence = 4

    /// The folder of the sync folder (and the courier inbox) that holds objects of this kind.
    public var directory: String? {
        switch self {
        case .event: return "Sealed/Events"
        case .metadata: return "Sealed/Metadata"
        case .blob: return "Sealed/Blobs"
        case .presence: return nil
        }
    }

    public init?(directory: String) {
        guard let kind = Self.allCases.first(where: { $0.directory == directory }) else { return nil }
        self = kind
    }
}

/// One library's key: 32 random bytes, the same on every device of the library, kept in iCloud Keychain
/// (`LibraryKeyStore`). Everything else derives from it: its ID (named in the manifest and in each object's header),
/// the key that names objects, and the key their content keys come from.
public struct LibraryKey: Sendable {
    public let libraryID: UUID
    /// 16 bytes: HMAC-SHA256(key, "DBSEAL1 key id" ‖ libraryID), truncated.
    public let id: Data
    public let createdAt: Date
    /// The sync device ID of the device that made it.
    public let createdBy: String
    let material: SymmetricKey
    let nameKey: SymmetricKey
    let contentKey: SymmetricKey

    public static let byteCount = 32

    public init(libraryID: UUID, material: Data, createdAt: Date, createdBy: String) throws {
        guard material.count == Self.byteCount else { throw SealedObjectError.malformed }
        let key = SymmetricKey(data: material)
        let library = SealedFormat.bytes(of: libraryID)
        self.libraryID = libraryID
        self.material = key
        self.createdAt = createdAt
        self.createdBy = createdBy
        id = Data(HMAC<SHA256>.authenticationCode(for: Data("DBSEAL1 key id".utf8) + library, using: key)).prefix(16)
        nameKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: library, info: Data("DBSEAL1 names".utf8), outputByteCount: 32)
        contentKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: library, info: Data("DBSEAL1 content".utf8), outputByteCount: 32)
    }

    /// A new random key for `libraryID`.
    public static func generate(libraryID: UUID, createdBy: String, now: Date = Date()) -> LibraryKey {
        let material = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Thirty-two bytes always make a key.
        return try! LibraryKey(libraryID: libraryID, material: material, createdAt: now, createdBy: createdBy)
    }

    /// The key's ID as lowercase hex (32 characters), as the manifest and the keychain name it.
    public var idHex: String { SyncDigest.hex(id) }
    /// The 32 key bytes. Only for storing the key (the keychain, a recovery wrap, a link grant).
    public var materialBytes: Data { material.withUnsafeBytes { Data($0) } }

    /// The file name of the sealed object of `kind` whose plaintext has SHA-256 `digest` (32 bytes).
    func objectName(_ kind: SealedKind, plaintextDigest digest: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data([kind.rawValue]) + SealedFormat.bytes(of: libraryID) + digest, using: nameKey))
    }

    /// The name, in hex, of the sealed object of `kind` whose plaintext has SHA-256 `sha256` (hex).
    public func objectName(_ kind: SealedKind, plaintextSHA256 sha256: String) -> String? {
        guard let digest = SealedFormat.data(hex: sha256), digest.count == 32 else { return nil }
        return SyncDigest.hex(objectName(kind, plaintextDigest: digest))
    }

    func fileKey(_ kind: SealedKind, name: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: contentKey, salt: name, info: Data("DBSEAL1 file".utf8) + Data([kind.rawValue]), outputByteCount: 32)
    }
}

extension LibraryKey: Equatable {
    public static func == (a: LibraryKey, b: LibraryKey) -> Bool {
        a.libraryID == b.libraryID && a.id == b.id && a.materialBytes == b.materialBytes
    }
}

public enum SealedObjectError: Error, Equatable {
    /// Not a sealed object, or its header or chunks are cut short.
    case malformed
    /// A format this version doesn't read (a newer Daybook's).
    case unsupportedVersion(Int)
    /// Another kind of object than its folder holds.
    case wrongKind
    /// Sealed for another library.
    case wrongLibrary
    /// Sealed with a key this device doesn't hold (yet): its ID, in hex.
    case unknownKey(String)
    /// The object isn't the one its name says.
    case nameMismatch
    /// A chunk doesn't authenticate: damaged, or not finished downloading.
    case authenticationFailed
    /// The plaintext isn't the one expected (its SHA-256 differs).
    case digestMismatch
}

/// The header every sealed object starts with.
struct SealedHeader: Equatable {
    static let size = 84
    static let magic = Data("DBSEAL".utf8)
    static let version: UInt8 = 1
    static let suite: UInt8 = 1
    static let chunkLog2: UInt8 = 20
    static let chunkSize = 1 << 20
    static let tagSize = 16

    var kind: SealedKind
    var keyID: Data
    var libraryID: UUID
    var name: Data
    var plaintextLength: UInt64

    var bytes: Data {
        var data = Self.magic
        data.append(contentsOf: [Self.version, kind.rawValue, Self.suite, Self.chunkLog2, 0, 0])
        data.append(keyID)
        data.append(SealedFormat.bytes(of: libraryID))
        data.append(name)
        data.append(SealedFormat.bigEndian(plaintextLength))
        return data
    }

    init(kind: SealedKind, keyID: Data, libraryID: UUID, name: Data, plaintextLength: UInt64) {
        self.kind = kind; self.keyID = keyID; self.libraryID = libraryID; self.name = name; self.plaintextLength = plaintextLength
    }

    init(parsing data: Data) throws {
        let data = Data(data.prefix(Self.size))
        guard data.count == Self.size, data.prefix(6) == Self.magic else { throw SealedObjectError.malformed }
        let bytes = [UInt8](data)
        guard bytes[6] == Self.version else { throw SealedObjectError.unsupportedVersion(Int(bytes[6])) }
        guard bytes[8] == Self.suite, bytes[9] == Self.chunkLog2 else { throw SealedObjectError.unsupportedVersion(Int(bytes[6])) }
        guard let kind = SealedKind(rawValue: bytes[7]) else { throw SealedObjectError.unsupportedVersion(Int(bytes[6])) }
        guard bytes[10] == 0, bytes[11] == 0 else { throw SealedObjectError.malformed }
        self.kind = kind
        keyID = Data(bytes[12..<28])
        libraryID = SealedFormat.uuid(Data(bytes[28..<44]))
        name = Data(bytes[44..<76])
        plaintextLength = bytes[76..<84].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Chunks in an object with this plaintext length: at least one, so an empty object still has a final chunk.
    static func chunkCount(_ length: UInt64) -> UInt64 { max(1, (length + UInt64(chunkSize) - 1) / UInt64(chunkSize)) }
    /// The size of a sealed object with `length` bytes of plaintext.
    static func sealedSize(_ length: UInt64) -> UInt64 { UInt64(size) + length + chunkCount(length) * UInt64(tagSize) }
    /// The plaintext length of chunk `index` (of `count`).
    static func chunkLength(_ index: UInt64, count: UInt64, total: UInt64) -> Int {
        index + 1 < count ? chunkSize : Int(total - index * UInt64(chunkSize))
    }

    func nonce(_ index: UInt64) -> AES.GCM.Nonce {
        // Twelve bytes always make a nonce.
        try! AES.GCM.Nonce(data: Data(count: 4) + SealedFormat.bigEndian(index))
    }

    func additionalData(_ index: UInt64, final: Bool, header: Data) -> Data {
        header + SealedFormat.bigEndian(index) + Data([final ? 1 : 0])
    }
}

/// Seals and opens sealed objects, in memory (journal entries, presence) or streaming between files (audio and photo
/// originals, gigabytes at a time in about a megabyte of memory).
public enum SealedObject {
    /// Keys a reader may open objects with, by ID.
    public typealias Keyring = (Data) -> LibraryKey?

    /// The object of `kind` for `plaintext` under `key`: its name (hex) and its bytes. Deterministic.
    public static func seal(_ plaintext: Data, kind: SealedKind, key: LibraryKey) -> (name: String, bytes: Data) {
        let digest = Data(SHA256.hash(data: plaintext))
        let name = key.objectName(kind, plaintextDigest: digest)
        let header = SealedHeader(kind: kind, keyID: key.id, libraryID: key.libraryID, name: name, plaintextLength: UInt64(plaintext.count))
        let headerBytes = header.bytes
        let fileKey = key.fileKey(kind, name: name)
        let count = SealedHeader.chunkCount(UInt64(plaintext.count))
        var output = headerBytes
        output.reserveCapacity(Int(SealedHeader.sealedSize(UInt64(plaintext.count))))
        for index in 0..<count {
            let start = plaintext.startIndex + Int(index) * SealedHeader.chunkSize
            let length = SealedHeader.chunkLength(index, count: count, total: UInt64(plaintext.count))
            output.append(sealChunk(plaintext[start..<start + length], index: index, final: index + 1 == count, header: header,
                                    headerBytes: headerBytes, key: fileKey))
        }
        return (SyncDigest.hex(name), output)
    }

    /// Opens an object of `kind` of this library: its header must name this library, a key `keyring` holds, and (when
    /// given) `expectedName`; every chunk must authenticate; and the plaintext must be the one the name says.
    public static func open(_ bytes: Data, kind: SealedKind, libraryID: UUID, keyring: Keyring,
                            expectedName: String? = nil) throws -> (plaintext: Data, key: LibraryKey) {
        let (header, key) = try check(bytes, kind: kind, libraryID: libraryID, keyring: keyring, expectedName: expectedName)
        guard UInt64(bytes.count) == SealedHeader.sealedSize(header.plaintextLength) else { throw SealedObjectError.malformed }
        let headerBytes = Data(bytes.prefix(SealedHeader.size))
        let fileKey = key.fileKey(kind, name: header.name)
        let count = SealedHeader.chunkCount(header.plaintextLength)
        var plaintext = Data()
        plaintext.reserveCapacity(Int(header.plaintextLength))
        var offset = bytes.startIndex + SealedHeader.size
        for index in 0..<count {
            let length = SealedHeader.chunkLength(index, count: count, total: header.plaintextLength)
            let chunk = bytes[offset..<offset + length + SealedHeader.tagSize]
            plaintext.append(try openChunk(chunk, index: index, final: index + 1 == count, header: header, headerBytes: headerBytes, key: fileKey))
            offset += length + SealedHeader.tagSize
        }
        guard key.objectName(kind, plaintextDigest: Data(SHA256.hash(data: plaintext))) == header.name else { throw SealedObjectError.nameMismatch }
        return (plaintext, key)
    }

    /// The header of a sealed object, checked against what the reader expects, and the key that opens it.
    static func check(_ bytes: Data, kind: SealedKind, libraryID: UUID, keyring: Keyring,
                      expectedName: String?) throws -> (SealedHeader, LibraryKey) {
        let header = try SealedHeader(parsing: bytes)
        guard header.kind == kind else { throw SealedObjectError.wrongKind }
        guard header.libraryID == libraryID else { throw SealedObjectError.wrongLibrary }
        if let expectedName, SyncDigest.hex(header.name) != expectedName { throw SealedObjectError.nameMismatch }
        guard let key = keyring(header.keyID), key.libraryID == libraryID, key.id == header.keyID else {
            throw SealedObjectError.unknownKey(SyncDigest.hex(header.keyID))
        }
        return (header, key)
    }

    /// The key ID and library a sealed object's header names, without opening it.
    public static func header(of bytes: Data) -> (keyID: Data, libraryID: UUID, kind: SealedKind)? {
        guard let header = try? SealedHeader(parsing: bytes) else { return nil }
        return (header.keyID, header.libraryID, header.kind)
    }

    static func sealChunk<D: DataProtocol>(_ plaintext: D, index: UInt64, final: Bool, header: SealedHeader, headerBytes: Data,
                                           key: SymmetricKey) -> Data {
        // AES-GCM with a 32-byte key and a 12-byte nonce can't fail.
        let box = try! AES.GCM.seal(plaintext, using: key, nonce: header.nonce(index),
                                    authenticating: header.additionalData(index, final: final, header: headerBytes))
        return box.ciphertext + box.tag
    }

    static func openChunk(_ chunk: Data, index: UInt64, final: Bool, header: SealedHeader, headerBytes: Data,
                          key: SymmetricKey) throws -> Data {
        guard chunk.count >= SealedHeader.tagSize else { throw SealedObjectError.malformed }
        do {
            let box = try AES.GCM.SealedBox(nonce: header.nonce(index), ciphertext: chunk.dropLast(SealedHeader.tagSize),
                                            tag: chunk.suffix(SealedHeader.tagSize))
            return try AES.GCM.open(box, using: key, authenticating: header.additionalData(index, final: final, header: headerBytes))
        } catch {
            throw SealedObjectError.authenticationFailed
        }
    }
}

/// Byte helpers the format uses.
enum SealedFormat {
    static func bytes(of uuid: UUID) -> Data { withUnsafeBytes(of: uuid.uuid) { Data($0) } }
    static func uuid(_ data: Data) -> UUID {
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    static func bigEndian(_ value: UInt64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var high: UInt8?
        for character in hex.utf8 {
            let value: UInt8
            switch character {
            case 48...57: value = character - 48
            case 97...102: value = character - 87
            default: return nil
            }
            if let first = high { data.append(first << 4 | value); high = nil } else { high = value }
        }
        return data
    }
}

// MARK: Files

/// A sealed object written from a file.
public struct SealedFile: Equatable, Sendable {
    /// The object's name (hex), which is its file name in `Sealed/<kind>/`.
    public var name: String
    /// The sealed object's size and, when asked for, the SHA-256 of its bytes (what a courier checks).
    public var size: Int64
    public var sealedSHA256: String?
}

/// A sealed object opened into a file (or only checked).
public struct OpenedFile: Equatable, Sendable {
    public var plaintextSHA256: String
    public var plaintextLength: Int64
    public var keyID: Data
}

extension SealedObject {
    /// Seals `source` into `destination` as an object of `kind` under `key`, reading the plaintext once. The object is
    /// named by `plaintextSHA256`, which the bytes read must match (otherwise `digestMismatch`, and `destination` is
    /// left partial for the caller to delete). `sealedDigest` also hashes the sealed bytes, for a courier.
    /// Cancelling the calling task stops it.
    public static func sealFile(_ source: URL, to destination: URL, kind: SealedKind, key: LibraryKey, plaintextSHA256: String,
                                sealedDigest: Bool = false, progress: ((Int64) -> Void)? = nil) throws -> SealedFile {
        guard let expected = SealedFormat.data(hex: plaintextSHA256), expected.count == 32 else { throw SealedObjectError.digestMismatch }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let name = key.objectName(kind, plaintextDigest: expected)
        let header = SealedHeader(kind: kind, keyID: key.id, libraryID: key.libraryID, name: name, plaintextLength: length)
        let headerBytes = header.bytes
        let fileKey = key.fileKey(kind, name: name)
        let output = try create(destination)
        defer { try? output.close() }
        var plain = SHA256(), sealed = sealedDigest ? SHA256() : nil
        try output.write(contentsOf: headerBytes)
        sealed?.update(data: headerBytes)
        let count = SealedHeader.chunkCount(length)
        // Two lanes, a chunk at a time: one seals chunk i and writes chunk i - 1, the other hashes chunk i and reads
        // chunk i + 1. AES-GCM and SHA-256 each run near memory speed on Apple silicon, so overlapping them (and the
        // file I/O) keeps sealing close to the time of hashing alone, in two chunks' worth of memory.
        var next = try readExactly(SealedHeader.chunkLength(0, count: count, total: length), from: input)
        var pending: Data?
        var done: Int64 = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let current = next
            guard current.count == SealedHeader.chunkLength(index, count: count, total: length) else { throw SealedObjectError.digestMismatch }
            let previous = pending
            var sealedChunk = Data()
            try inParallel({
                sealedChunk = sealChunk(current, index: index, final: index + 1 == count, header: header, headerBytes: headerBytes, key: fileKey)
                if let previous { sealed?.update(data: previous); try output.write(contentsOf: previous) }
            }, {
                plain.update(data: current)
                next = index + 1 < count ? try readExactly(SealedHeader.chunkLength(index + 1, count: count, total: length), from: input) : Data()
            })
            pending = sealedChunk
            done += Int64(current.count)
            progress?(done)
        }
        if let pending { sealed?.update(data: pending); try output.write(contentsOf: pending) }
        // The file grew after it was measured: it isn't the plaintext the name says.
        guard try input.read(upToCount: 1)?.isEmpty ?? true else { throw SealedObjectError.digestMismatch }
        guard Data(plain.finalize()) == expected else { throw SealedObjectError.digestMismatch }
        return SealedFile(name: SyncDigest.hex(name), size: Int64(SealedHeader.sealedSize(length)), sealedSHA256: sealed.map { SyncDigest.hex($0.finalize()) })
    }

    /// Opens the sealed object at `source` into `destination` (or, with nil, only checks it), reading it once: the header
    /// must name this library, a key `keyring` holds, and (when given) `expectedName`; every chunk must authenticate;
    /// the plaintext must be the one the name says and, when given, have SHA-256 `expectedSHA256`. On any failure
    /// `destination` is left partial for the caller to delete. Cancelling the calling task stops it.
    public static func openFile(_ source: URL, to destination: URL?, kind: SealedKind, libraryID: UUID, keyring: Keyring,
                                expectedName: String? = nil, expectedSHA256: String? = nil,
                                progress: ((Int64, Int64) -> Void)? = nil) throws -> OpenedFile {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let headerBytes = try readExactly(SealedHeader.size, from: input)
        let (header, key) = try check(headerBytes, kind: kind, libraryID: libraryID, keyring: keyring, expectedName: expectedName)
        let total = Int64(header.plaintextLength)
        guard try input.seekToEnd() == SealedHeader.sealedSize(header.plaintextLength) else { throw SealedObjectError.malformed }
        try input.seek(toOffset: UInt64(SealedHeader.size))
        let output = try destination.map(create)
        defer { try? output?.close() }
        let fileKey = key.fileKey(kind, name: header.name)
        let count = SealedHeader.chunkCount(header.plaintextLength)
        func sealedLength(_ index: UInt64) -> Int { SealedHeader.chunkLength(index, count: count, total: header.plaintextLength) + SealedHeader.tagSize }
        // Two lanes, as when sealing: one opens chunk i and writes chunk i - 1, the other hashes chunk i - 1 and reads
        // chunk i + 1. A chunk is written only once it has authenticated.
        var plain = SHA256()
        var next = try readExactly(sealedLength(0), from: input)
        var pending: Data?
        var done: Int64 = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let current = next
            guard current.count == sealedLength(index) else { throw SealedObjectError.malformed }
            let previous = pending
            var opened = Data()
            try inParallel({
                opened = try openChunk(current, index: index, final: index + 1 == count, header: header, headerBytes: headerBytes, key: fileKey)
                if let previous { try output?.write(contentsOf: previous) }
            }, {
                if let previous { plain.update(data: previous) }
                next = index + 1 < count ? try readExactly(sealedLength(index + 1), from: input) : Data()
            })
            pending = opened
            done += Int64(opened.count)
            progress?(done, total)
        }
        if let pending { plain.update(data: pending); try output?.write(contentsOf: pending) }
        let digest = Data(plain.finalize())
        guard key.objectName(kind, plaintextDigest: digest) == header.name else { throw SealedObjectError.nameMismatch }
        let hex = SyncDigest.hex(digest)
        if let expectedSHA256, expectedSHA256 != hex { throw SealedObjectError.digestMismatch }
        try output?.synchronize()
        return OpenedFile(plaintextSHA256: hex, plaintextLength: total, keyID: key.id)
    }

    /// Runs two pieces of work at once (each in its own autorelease pool, so a long file's reads don't pile up), and
    /// rethrows the first failure. Small chunks run one after the other.
    private static func inParallel(_ first: () throws -> Void, _ second: () throws -> Void) throws {
        final class Failures: @unchecked Sendable { var first: Error?; var second: Error? }
        let failures = Failures()
        DispatchQueue.concurrentPerform(iterations: 2) { lane in
            autoreleasepool {
                if lane == 0 { do { try first() } catch { failures.first = error } }
                else { do { try second() } catch { failures.second = error } }
            }
        }
        if let error = failures.first ?? failures.second { throw error }
    }

    private static func create(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count > 0 else { return Data() }
        var data = try handle.read(upToCount: count) ?? Data()
        while data.count < count, let more = try handle.read(upToCount: count - data.count), !more.isEmpty { data.append(more) }
        return data
    }
}
