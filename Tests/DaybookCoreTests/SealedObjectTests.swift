import CryptoKit
import Darwin
import XCTest
@testable import DaybookCore

/// DBSEAL version 1 (SealedObject.swift). The known-answer vectors freeze the format: they were computed by an
/// independent implementation of the specification (pure Python AES-256, GCM, HMAC, and HKDF, itself checked against
/// FIPS-197 and the GCM specification's test vectors), not by this code. A change that breaks them breaks every
/// encrypted library; it needs a new format version instead.
final class SealedObjectTests: XCTestCase {
    private let libraryID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private var key: LibraryKey { try! LibraryKey(libraryID: libraryID, material: Data(0..<32), createdAt: Date(timeIntervalSince1970: 0), createdBy: "test") }
    private var keyring: SealedObject.Keyring { { [key] id in id == key.id ? key : nil } }
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSealedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Known answers

    func testKnownAnswerVectorsFreezeTheFormat() throws {
        XCTAssertEqual(key.idHex, "b623e969d046f9bef852be36c453a5bc")
        let cases: [(SealedKind, Data, String, String)] = [
            (.event, Data(#"{"hello":"world"}"#.utf8),
             "30e0062a8518f36bf4de63b2d6a55d7ac91b4e7610f80ea38554fe5f887720f6",
             "44425345414c010101140000b623e969d046f9bef852be36c453a5bc6f9619ff8b86d011b42d00c04fc964ff30e0062a8518f36bf4de63b2d6a55d7ac91b4e7610f80ea38554fe5f887720f6000000000000001182bd5e169a83061d2c76066cf9dae7e4a9dede1e7522b422b689886cf9706da0b6"),
            (.metadata, Data(),
             "36f994a077df95650a18d803f38b0d66ba1707e9bdbb8805b407bbd921dc8be6",
             "44425345414c010201140000b623e969d046f9bef852be36c453a5bc6f9619ff8b86d011b42d00c04fc964ff36f994a077df95650a18d803f38b0d66ba1707e9bdbb8805b407bbd921dc8be6000000000000000002fd2a95d87e11c61b57297fbe670bdd"),
            (.presence, Data(#"{"displayName":"Studio Mac"}"#.utf8),
             "a88e5cb318cafc6d733115b5ab7e7f22d6467576842ef3b8bcb5e01dbbb54bcc",
             "44425345414c010401140000b623e969d046f9bef852be36c453a5bc6f9619ff8b86d011b42d00c04fc964ffa88e5cb318cafc6d733115b5ab7e7f22d6467576842ef3b8bcb5e01dbbb54bcc000000000000001c3cc807e510fd8b9f597c8a5d763b634621c0d639e3432fef68a93902d2f731d8ff705ff5b8311b19e2132e68")
        ]
        for (kind, plaintext, name, hex) in cases {
            let sealed = SealedObject.seal(plaintext, kind: kind, key: key)
            XCTAssertEqual(sealed.name, name, "\(kind)")
            XCTAssertEqual(SyncDigest.hex(sealed.bytes), hex, "\(kind)")
            XCTAssertEqual(key.objectName(kind, plaintextSHA256: SyncDigest.sha256(data: plaintext)), name)
            XCTAssertEqual(try SealedObject.open(sealed.bytes, kind: kind, libraryID: libraryID, keyring: keyring, expectedName: name).plaintext, plaintext)
        }
        // Two chunks: a full mebibyte and one byte more, as a file.
        let big = Data((0..<(SealedHeader.chunkSize + 1)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        XCTAssertEqual(SyncDigest.sha256(data: big), "0d09f3eabb5c78e5d435c41e3b3755f1c4d038657f739d0be0083c24e71235df")
        let source = root.appendingPathComponent("big"), sealedURL = root.appendingPathComponent("big.sealed")
        try big.write(to: source)
        let file = try SealedObject.sealFile(source, to: sealedURL, kind: .blob, key: key, plaintextSHA256: SyncDigest.sha256(data: big), sealedDigest: true)
        XCTAssertEqual(file.name, "cd09e92fc9c5311d401a0ca8d5a5285285e5cd453432f29b1ef5698106be0006")
        XCTAssertEqual(file.size, 1_048_693)
        XCTAssertEqual(file.sealedSHA256, "42789a10d15194c5b768c979b9bb9b9def86d693b8d309048d92e431166c0472")
        XCTAssertEqual(try SyncDigest.sha256(fileURL: sealedURL), file.sealedSHA256)
        XCTAssertEqual(SealedObject.seal(big, kind: .blob, key: key).bytes, try Data(contentsOf: sealedURL))
    }

    // MARK: Round trips

    func testRoundTripsAtChunkBoundariesInMemoryAndAsFiles() throws {
        let chunk = SealedHeader.chunkSize
        for length in [0, 1, 15, 16, 17, chunk - 1, chunk, chunk + 1, 2 * chunk + 5] {
            let plaintext = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ length) })
            let sealed = SealedObject.seal(plaintext, kind: .blob, key: key)
            XCTAssertEqual(UInt64(sealed.bytes.count), SealedHeader.sealedSize(UInt64(length)))
            XCTAssertEqual(try SealedObject.open(sealed.bytes, kind: .blob, libraryID: libraryID, keyring: keyring).plaintext, plaintext, "\(length)")

            let source = root.appendingPathComponent("plain-\(length)"), sealedURL = root.appendingPathComponent("sealed-\(length)")
            let opened = root.appendingPathComponent("opened-\(length)")
            try plaintext.write(to: source)
            let file = try SealedObject.sealFile(source, to: sealedURL, kind: .blob, key: key, plaintextSHA256: SyncDigest.sha256(data: plaintext))
            XCTAssertEqual(file.name, sealed.name)
            XCTAssertEqual(try Data(contentsOf: sealedURL), sealed.bytes, "a file seals to the same bytes as memory (\(length))")
            let result = try SealedObject.openFile(sealedURL, to: opened, kind: .blob, libraryID: libraryID, keyring: keyring,
                                                   expectedName: sealed.name, expectedSHA256: SyncDigest.sha256(data: plaintext))
            XCTAssertEqual(try Data(contentsOf: opened), plaintext)
            XCTAssertEqual(result.plaintextLength, Int64(length))
            XCTAssertEqual(result.keyID, key.id)
        }
    }

    func testSealingIsDeterministicPerKeyKindAndLibrary() throws {
        let plaintext = Data("the same entry".utf8)
        let first = SealedObject.seal(plaintext, kind: .event, key: key)
        XCTAssertEqual(SealedObject.seal(plaintext, kind: .event, key: key).bytes, first.bytes)
        XCTAssertNotEqual(SealedObject.seal(plaintext, kind: .metadata, key: key).name, first.name)
        let other = LibraryKey.generate(libraryID: libraryID, createdBy: "test")
        XCTAssertNotEqual(SealedObject.seal(plaintext, kind: .event, key: other).name, first.name)
        let elsewhere = try LibraryKey(libraryID: UUID(), material: Data(0..<32), createdAt: Date(), createdBy: "test")
        XCTAssertNotEqual(elsewhere.id, key.id)
        XCTAssertNotEqual(SealedObject.seal(plaintext, kind: .event, key: elsewhere).name, first.name)
        // Names reveal nothing that links them to the plaintext's SHA-256 without the key.
        XCTAssertNotEqual(first.name, SyncDigest.sha256(data: plaintext))
    }

    // MARK: Tampering

    func testEveryAlteredHeaderByteOrChunkByteFails() throws {
        let plaintext = Data((0..<100).map { UInt8($0) })
        let sealed = SealedObject.seal(plaintext, kind: .event, key: key).bytes
        for index in 0..<sealed.count {
            var altered = sealed
            altered[index] ^= 0x01
            XCTAssertThrowsError(try SealedObject.open(altered, kind: .event, libraryID: libraryID, keyring: keyring), "byte \(index)")
        }
        // A larger object: the first and last bytes of every chunk and tag, as a file too.
        let big = Data((0..<(2 * SealedHeader.chunkSize + 3)).map { UInt8(truncatingIfNeeded: $0) })
        let bigSealed = SealedObject.seal(big, kind: .blob, key: key).bytes
        var offsets: [Int] = []
        var start = SealedHeader.size
        for length in [SealedHeader.chunkSize, SealedHeader.chunkSize, 3] {
            offsets += [start, start + length - 1, start + length, start + length + SealedHeader.tagSize - 1]
            start += length + SealedHeader.tagSize
        }
        for offset in offsets {
            var altered = bigSealed
            altered[offset] ^= 0x80
            XCTAssertThrowsError(try SealedObject.open(altered, kind: .blob, libraryID: libraryID, keyring: keyring), "offset \(offset)")
            let url = root.appendingPathComponent("altered-\(offset)")
            try altered.write(to: url)
            XCTAssertThrowsError(try SealedObject.openFile(url, to: nil, kind: .blob, libraryID: libraryID, keyring: keyring), "file offset \(offset)")
        }
    }

    func testTruncationReorderingAndExtensionFail() throws {
        let chunk = SealedHeader.chunkSize, tagged = chunk + SealedHeader.tagSize
        let plaintext = Data((0..<(3 * chunk)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let sealed = SealedObject.seal(plaintext, kind: .blob, key: key).bytes
        let body = sealed.dropFirst(SealedHeader.size)
        let chunks = (0..<3).map { Data(body.dropFirst($0 * tagged).prefix(tagged)) }
        let header = Data(sealed.prefix(SealedHeader.size))
        let attempts: [(String, Data)] = [
            ("last byte dropped", Data(sealed.dropLast())),
            ("last chunk dropped", header + chunks[0] + chunks[1]),
            ("chunks swapped", header + chunks[1] + chunks[0] + chunks[2]),
            ("a chunk repeated", header + chunks[0] + chunks[0] + chunks[2]),
            ("a byte appended", sealed + Data([0])),
            ("header only", header),
            ("short header", Data(sealed.prefix(40)))
        ]
        for (label, data) in attempts {
            XCTAssertThrowsError(try SealedObject.open(data, kind: .blob, libraryID: libraryID, keyring: keyring), label)
            let url = root.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-"))
            try data.write(to: url)
            XCTAssertThrowsError(try SealedObject.openFile(url, to: nil, kind: .blob, libraryID: libraryID, keyring: keyring), label)
        }
        // A two-chunk object's first chunk relabelled as final, by cutting the second: the length says otherwise, and
        // the final flag is authenticated anyway.
        let two = SealedObject.seal(Data(count: chunk + 1), kind: .blob, key: key).bytes
        XCTAssertThrowsError(try SealedObject.open(Data(two.prefix(SealedHeader.size + tagged)), kind: .blob, libraryID: libraryID, keyring: keyring))
    }

    func testWrongKindLibraryKeyOrNameIsRefused() throws {
        let sealed = SealedObject.seal(Data("entry".utf8), kind: .event, key: key)
        XCTAssertThrowsError(try SealedObject.open(sealed.bytes, kind: .metadata, libraryID: libraryID, keyring: keyring)) {
            XCTAssertEqual($0 as? SealedObjectError, .wrongKind)
        }
        XCTAssertThrowsError(try SealedObject.open(sealed.bytes, kind: .event, libraryID: UUID(), keyring: keyring)) {
            XCTAssertEqual($0 as? SealedObjectError, .wrongLibrary)
        }
        XCTAssertThrowsError(try SealedObject.open(sealed.bytes, kind: .event, libraryID: libraryID, keyring: { _ in nil })) {
            XCTAssertEqual($0 as? SealedObjectError, .unknownKey(self.key.idHex))
        }
        XCTAssertThrowsError(try SealedObject.open(sealed.bytes, kind: .event, libraryID: libraryID, keyring: keyring, expectedName: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? SealedObjectError, .nameMismatch)
        }
        // A key with the right ID but other bytes (a forged keyring entry) doesn't open it.
        let impostor = LibraryKey.generate(libraryID: libraryID, createdBy: "x")
        XCTAssertThrowsError(try SealedObject.open(sealed.bytes, kind: .event, libraryID: libraryID, keyring: { _ in impostor }))
        // A newer version of the format reads as such.
        var newer = sealed.bytes
        newer[6] = 2
        XCTAssertThrowsError(try SealedObject.open(newer, kind: .event, libraryID: libraryID, keyring: keyring)) {
            XCTAssertEqual($0 as? SealedObjectError, .unsupportedVersion(2))
        }
    }

    func testAnImpossibleLengthIsDamageNotACrash() throws {
        var sealed = SealedObject.seal(Data("entry".utf8), kind: .event, key: key).bytes
        for index in 76..<84 { sealed[index] = 0xff }
        XCTAssertThrowsError(try SealedObject.open(sealed, kind: .event, libraryID: libraryID, keyring: keyring)) {
            XCTAssertEqual($0 as? SealedObjectError, .malformed)
        }
        let url = root.appendingPathComponent("huge")
        try sealed.write(to: url)
        XCTAssertThrowsError(try SealedObject.openFile(url, to: nil, kind: .event, libraryID: libraryID, keyring: keyring))
    }

    func testSealingAFileThatIsNotThePlaintextNamedFails() throws {
        let source = root.appendingPathComponent("plain")
        try Data("actual".utf8).write(to: source)
        XCTAssertThrowsError(try SealedObject.sealFile(source, to: root.appendingPathComponent("out"), kind: .blob, key: key,
                                                       plaintextSHA256: SyncDigest.sha256(data: Data("expected".utf8)))) {
            XCTAssertEqual($0 as? SealedObjectError, .digestMismatch)
        }
        let sealedURL = root.appendingPathComponent("sealed")
        _ = try SealedObject.sealFile(source, to: sealedURL, kind: .blob, key: key, plaintextSHA256: SyncDigest.sha256(data: Data("actual".utf8)))
        XCTAssertThrowsError(try SealedObject.openFile(sealedURL, to: nil, kind: .blob, libraryID: libraryID, keyring: keyring,
                                                       expectedSHA256: SyncDigest.sha256(data: Data("expected".utf8)))) {
            XCTAssertEqual($0 as? SealedObjectError, .digestMismatch)
        }
    }

    func testCancellingStopsSealingAndOpening() async throws {
        let source = root.appendingPathComponent("plain"), sealedURL = root.appendingPathComponent("sealed")
        let plaintext = Data(count: 4 * SealedHeader.chunkSize)
        try plaintext.write(to: source)
        let digest = SyncDigest.sha256(data: plaintext)
        let key = self.key
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SealedObject.sealFile(source, to: sealedURL, kind: .blob, key: key, plaintextSHA256: digest)
        }
        do { _ = try await task.value; XCTFail("sealing went on after cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: Performance

    /// Sealing and opening a 1 GiB original against today's copy and SHA-256, and the memory it takes. Skipped unless
    /// DAYBOOK_SEALED_PERFORMANCE=1 (it writes 3 GiB to the temporary folder). Budget: at most 1.5 times the time of a
    /// copy and its SHA-256, and at most 8 MiB more memory.
    func testSealingAGibibyteStaysWithinBudget() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAYBOOK_SEALED_PERFORMANCE"] == "1", "Set DAYBOOK_SEALED_PERFORMANCE=1 to run.")
        let size = 1 << 30
        let source = root.appendingPathComponent("original")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        var block = Data((0..<SealedHeader.chunkSize).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) })
        for index in 0..<(size / SealedHeader.chunkSize) {
            block[0] = UInt8(truncatingIfNeeded: index)
            try handle.write(contentsOf: block)
        }
        try handle.close()
        let digest = try SyncDigest.sha256(fileURL: source)
        func measure(_ label: String, _ work: () throws -> Void) rethrows -> (seconds: Double, extraBytes: Int64) {
            let sampler = FootprintSampler()
            let started = ContinuousClock.now
            try autoreleasepool { try work() }
            let elapsed = ContinuousClock.now - started
            let extra = sampler.stop()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("\(label): \(String(format: "%.2f", seconds)) s, \(extra / 1024) KiB more memory at most")
            return (seconds, extra)
        }
        // Today: a copy into the sync folder (a clone on APFS) and the SHA-256 that checks it.
        let copy = root.appendingPathComponent("copy")
        let baseline = try measure("copy + SHA-256") {
            try FileManager.default.copyItem(at: source, to: copy)
            XCTAssertEqual(try SyncDigest.sha256(fileURL: copy), digest)
        }
        try FileManager.default.removeItem(at: copy)
        // A real copy (no clone) and its hash, for comparison: what installing from another volume costs.
        let fullCopy = try measure("byte copy + SHA-256") {
            let input = try FileHandle(forReadingFrom: source)
            FileManager.default.createFile(atPath: copy.path, contents: nil)
            let output = try FileHandle(forWritingTo: copy)
            var hasher = SHA256()
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let data = try input.read(upToCount: 1 << 20), !data.isEmpty else { return false }
                hasher.update(data: data); try output.write(contentsOf: data)
                return true
            }) {}
            try input.close(); try output.close()
            XCTAssertEqual(SyncDigest.hex(hasher.finalize()), digest)
        }
        try FileManager.default.removeItem(at: copy)
        let sealedURL = root.appendingPathComponent("sealed")
        let sealing = try measure("seal") {
            _ = try SealedObject.sealFile(source, to: sealedURL, kind: .blob, key: key, plaintextSHA256: digest)
        }
        let opened = root.appendingPathComponent("opened")
        let opening = try measure("open") {
            _ = try SealedObject.openFile(sealedURL, to: opened, kind: .blob, libraryID: libraryID, keyring: keyring, expectedSHA256: digest)
        }
        print("ratios against copy + SHA-256: seal \(String(format: "%.2f", sealing.seconds / baseline.seconds)), open \(String(format: "%.2f", opening.seconds / baseline.seconds)); against a byte copy: seal \(String(format: "%.2f", sealing.seconds / fullCopy.seconds)), open \(String(format: "%.2f", opening.seconds / fullCopy.seconds))")
        XCTAssertLessThanOrEqual(sealing.extraBytes, 8 << 20)
        XCTAssertLessThanOrEqual(opening.extraBytes, 8 << 20)
        XCTAssertLessThanOrEqual(sealing.seconds, 1.5 * baseline.seconds)
        XCTAssertLessThanOrEqual(opening.seconds, 1.5 * baseline.seconds)
    }
}

/// Samples this process's physical footprint while work runs, for the largest increase over where it started.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int64
    private let start: Int64
    private var running = true
    private let done = DispatchSemaphore(value: 0)

    init() {
        start = Self.footprint()
        peak = start
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                usleep(2_000)
            }
            done.signal()
        }
    }

    func stop() -> Int64 {
        lock.withLock { running = false }
        done.wait()
        return lock.withLock { max(0, peak - start) }
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
