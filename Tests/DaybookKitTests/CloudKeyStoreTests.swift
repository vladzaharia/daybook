import Foundation
import Security
import XCTest
@testable import DaybookKit

/// Cloud keys: the masked form, a key that never prints, and the keychain items the store writes (synchronizable, in
/// the group both apps share), checked against a fake keychain. The real keychain needs a signed build: device checks
/// in docs/validation.md.
final class CloudKeyStoreTests: XCTestCase {
    private let anthropic = "sk-ant-api03-Zx8yQwErTyUiOpAsDfGhJkLzXcVbNm1234567890-gDAA"
    private let openai = "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789x9Qa"

    func testBehaviorMaskedFormShowsTheKindOfKeyAndItsLastFour() throws {
        XCTAssertEqual(try XCTUnwrap(CloudAPIKey(anthropic)).masked, "sk-ant-…gDAA")
        XCTAssertEqual(try XCTUnwrap(CloudAPIKey(openai)).masked, "sk-proj-…x9Qa")
        XCTAssertEqual(try XCTUnwrap(CloudAPIKey("sk-abcdefghijklmnop")).masked, "sk-…mnop")
        XCTAssertEqual(try XCTUnwrap(CloudAPIKey("short")).masked, "…t", "A short key shows almost nothing")
    }

    func testBehaviorAKeyNeverPrints() throws {
        let key = try XCTUnwrap(CloudAPIKey(anthropic))
        var dumped = ""
        dump(key, to: &dumped)
        for shown in ["\(key)", String(describing: key), String(reflecting: key), dumped, "\([key])"] {
            XCTAssertFalse(shown.contains("Zx8yQwErTy"), shown)
            XCTAssertTrue(shown.contains("…gDAA"), shown)
        }
    }

    func testBehaviorAPastedKeyIsTrimmedAndAnEmptyOneIsNone() {
        XCTAssertEqual(CloudAPIKey("  \(openai)\n")?.secret, openai)
        XCTAssertNil(CloudAPIKey("   "))
        XCTAssertNil(CloudAPIKey("sk-ant- api03"), "A key with a space in it was pasted wrong")
    }

    func testBehaviorProviderErrorsHaveKeysMaskedInTheirDetails() {
        let quoted = CloudError.scrubbed("Incorrect API key provided: sk-proj-AbCdEfGhIjKl****x9Qa. You can find your API key at …")
        XCTAssertFalse(quoted.contains("AbCdEfGhIjKl"))
        XCTAssertTrue(quoted.contains("sk-proj-…x9Qa"))
    }

    // MARK: The keychain items

    private final class FakeKeychain: CloudKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        private(set) var added: [[String: Any]] = []
        private(set) var deleted: [[String: Any]] = []

        private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
            item[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String
                && item[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }

        func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.withLock {
                guard let item = items.first(where: { matches($0, query) }) else { return errSecItemNotFound }
                result?.pointee = item[kSecValueData as String] as CFTypeRef?
                return errSecSuccess
            }
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                guard !items.contains(where: { matches($0, attributes) }) else { return errSecDuplicateItem }
                items.append(attributes)
                added.append(attributes)
                return errSecSuccess
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock {
                deleted.append(query)
                let before = items.count
                items.removeAll { matches($0, query) }
                return items.count == before ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    func testBehaviorKeysAreSynchronizableItemsInTheSharedGroup() throws {
        let keychain = FakeKeychain()
        let store = KeychainCloudKeyStore(accessGroup: "48H7CLBV8Y.local.daybook.shared", keychain: keychain)
        XCTAssertNil(try store.key(for: .anthropic))
        let key = try XCTUnwrap(CloudAPIKey(anthropic))
        try store.store(key, for: .anthropic)
        XCTAssertEqual(try store.key(for: .anthropic), key)
        XCTAssertNil(try store.key(for: .openai))

        let item = try XCTUnwrap(keychain.added.last)
        XCTAssertEqual(item[kSecAttrService as String] as? String, "local.daybook.cloud-key")
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, "anthropic")
        XCTAssertEqual(item[kSecAttrAccessGroup as String] as? String, "48H7CLBV8Y.local.daybook.shared")
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(item[kSecAttrLabel as String] as? String, "Daybook Anthropic API key")

        // Replacing removes the old item first; removing matches synchronized items too.
        try store.store(try XCTUnwrap(CloudAPIKey(anthropic.replacingOccurrences(of: "gDAA", with: "hEBB"))), for: .anthropic)
        XCTAssertEqual(try store.key(for: .anthropic)?.masked, "sk-ant-…hEBB")
        try store.removeKey(for: .anthropic)
        XCTAssertNil(try store.key(for: .anthropic))
        XCTAssertEqual(keychain.deleted.last?[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
        XCTAssertNoThrow(try store.removeKey(for: .openai), "Removing a key that isn't there is fine")
    }

    #if os(macOS)
    func testBehaviorWithoutTheSharedGroupTheMacKeepsKeysInItsLoginKeychainUnsynced() throws {
        let keychain = FakeKeychain()
        let store = KeychainCloudKeyStore(accessGroup: nil, keychain: keychain)
        try store.store(try XCTUnwrap(CloudAPIKey(openai)), for: .openai)
        let item = try XCTUnwrap(keychain.added.last)
        XCTAssertNil(item[kSecAttrSynchronizable as String])
        XCTAssertNil(item[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(item[kSecAttrAccessGroup as String])
        XCTAssertEqual(item[kSecAttrLabel as String] as? String, "Daybook OpenAI API key")
    }
    #endif

    func testBehaviorMemoryStoreKeepsOneKeyPerProvider() throws {
        let store = MemoryCloudKeyStore()
        XCTAssertEqual(store.providersWithKeys(), [])
        try store.store(try XCTUnwrap(CloudAPIKey(openai)), for: .openai)
        try store.store(try XCTUnwrap(CloudAPIKey(anthropic)), for: .anthropic)
        XCTAssertEqual(store.providersWithKeys(), [.anthropic, .openai])
        try store.removeKey(for: .anthropic)
        XCTAssertEqual(store.providersWithKeys(), [.openai])
    }
}
