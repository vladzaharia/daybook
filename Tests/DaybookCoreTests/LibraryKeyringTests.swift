import XCTest
@testable import DaybookCore

/// Library keys as they're stored, and recovery keys (LibraryKeyring.swift).
final class LibraryKeyringTests: XCTestCase {
    private let libraryID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private var key: LibraryKey { try! LibraryKey(libraryID: libraryID, material: Data(0..<32), createdAt: Date(timeIntervalSince1970: 0), createdBy: "test") }

    func testKeyRecordsRoundTripAndRejectAMismatchedID() throws {
        let record = LibraryKeyRecord(key)
        let decoded = try XCTUnwrap(LibraryKeyRecord.decode(try record.encoded()))
        XCTAssertEqual(decoded.libraryKey, key)
        var forged = decoded
        forged.keyID = String(repeating: "a", count: 32)
        XCTAssertNil(forged.libraryKey)
    }

    func testRecoveryKeysReadAsTypedAndCatchMistakes() throws {
        for _ in 0..<50 {
            let recovery = RecoveryKey.generate()
            XCTAssertEqual(recovery.text.count, 34)
            XCTAssertEqual(RecoveryKey(recovery.text), recovery)
            XCTAssertEqual(RecoveryKey(recovery.text.lowercased().replacingOccurrences(of: "-", with: " ")), recovery)
            // One character changed: the check characters catch it (ten bits: all but about 1 in 1,000).
            var characters = Array(recovery.text.replacingOccurrences(of: "-", with: ""))
            characters[3] = characters[3] == "Z" ? "Y" : "Z"
            if let misread = RecoveryKey(String(characters)) { XCTAssertNotEqual(misread, recovery) }
        }
        let fixed = RecoveryKey(bytes: Data(0..<16))!
        XCTAssertEqual(fixed.text, RecoveryKey(fixed.text.replacingOccurrences(of: "0", with: "O"))?.text)
        XCTAssertNil(RecoveryKey("not a key"))
        XCTAssertNil(RecoveryKey(String(fixed.text.dropLast())))
    }

    func testRecoveryWrapOpensOnlyWithItsKeyAndLibrary() throws {
        let recovery = RecoveryKey.generate()
        let wrapped = recovery.wrap(key)
        XCTAssertEqual(recovery.unwrap(wrapped, keyID: key.id, libraryID: libraryID, createdAt: key.createdAt), key)
        XCTAssertNil(RecoveryKey.generate().unwrap(wrapped, keyID: key.id, libraryID: libraryID, createdAt: key.createdAt))
        XCTAssertNil(recovery.unwrap(wrapped, keyID: Data(count: 16), libraryID: libraryID, createdAt: key.createdAt))
        XCTAssertNil(recovery.unwrap(wrapped, keyID: key.id, libraryID: UUID(), createdAt: key.createdAt))
        XCTAssertNil(recovery.unwrap("AAAA", keyID: key.id, libraryID: libraryID, createdAt: key.createdAt))
    }

    func testMemoryStoresShareKeysOrKeepThemApart() throws {
        let shared = MemoryLibraryKeyStore()
        try shared.store(key)
        try shared.store(key)
        XCTAssertEqual(try shared.keys(for: libraryID), [key])
        XCTAssertEqual(try shared.keys(for: UUID()), [])
        try shared.remove(keyID: key.id, libraryID: libraryID)
        XCTAssertEqual(try shared.keys(for: libraryID), [])
        shared.fail(with: .keychain(-25308))
        XCTAssertThrowsError(try shared.keys(for: libraryID))
    }
}
