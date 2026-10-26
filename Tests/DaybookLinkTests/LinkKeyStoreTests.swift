@testable import DaybookLink
import Foundation
import Security
import XCTest

#if os(macOS)
/// `KeychainLinkKeyStore` against a keychain in memory: never the real one, which unsigned test
/// builds can't use as the data-protection keychain anyway (errSecMissingEntitlement).
final class LinkKeyStoreTests: XCTestCase {
    private func record(_ name: String, pairedAt: Date = Date(), id: UUID = UUID()) -> LinkPairingRecord {
        LinkPairingRecord(deviceID: id, name: name, deviceClass: .iPhone, pairedAt: pairedAt,
                          linkKey: PasskeyExchange.randomBytes(32), pskIdentity: PasskeyExchange.randomBytes(16))
    }

    private func store(_ keychain: FakeKeychain) -> KeychainLinkKeyStore {
        KeychainLinkKeyStore(service: "local.daybook.link", accessGroup: nil, keychain: keychain)
    }

    func testPairingsInTheLoginKeychainMoveToTheDataProtectionKeychain() throws {
        let keychain = FakeKeychain()
        let phone = record("Pocket iPhone", pairedAt: Date(timeIntervalSince1970: 1)), other = record("Spare iPhone")
        keychain.seed(phone, in: .login)
        keychain.seed(other, in: .login)
        let store = store(keychain)

        XCTAssertEqual(try store.records(), [phone, other])
        XCTAssertEqual(try store.location(), .dataProtection)
        XCTAssertTrue(keychain.items(in: .login).isEmpty, "nothing is left for Migration Assistant to carry")
        let moved = keychain.items(in: .dataProtection)
        XCTAssertEqual(moved.count, 2)
        for item in moved.values {
            XCTAssertEqual(item.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertEqual(item.synchronizable, false)
        }
        // New pairings go to the data-protection keychain too.
        let mac = record("Studio Mac")
        try store.save(mac)
        XCTAssertNotNil(keychain.items(in: .dataProtection)[mac.deviceID.uuidString])
        XCTAssertNil(keychain.items(in: .login)[mac.deviceID.uuidString])
        XCTAssertEqual(try store.record(for: mac.deviceID), mac)
    }

    func testBuildsWithoutTheDataProtectionKeychainKeepTheLoginKeychain() throws {
        let keychain = FakeKeychain()
        keychain.dataProtectionAvailable = false
        let existing = record("Pocket iPhone")
        keychain.seed(existing, in: .login)
        let store = store(keychain)

        XCTAssertEqual(try store.records(), [existing])
        XCTAssertEqual(try store.location(), .login)
        let added = record("Spare iPhone")
        try store.save(added)
        XCTAssertNil(keychain.items(in: .login)[added.deviceID.uuidString]?.accessible, "the login keychain takes no accessibility class")
        XCTAssertEqual(try store.records().count, 2)
        try store.remove(deviceID: existing.deviceID)
        XCTAssertEqual(try store.records(), [added])
    }

    func testAMoveThatFailsKeepsEveryPairingAndIsTriedAgainNextLaunch() throws {
        let keychain = FakeKeychain()
        let phone = record("Pocket iPhone")
        keychain.seed(phone, in: .login)
        keychain.failDataProtectionWrites = true

        let first = store(keychain)
        XCTAssertEqual(try first.records(), [phone])
        XCTAssertEqual(try first.location(), .login)
        XCTAssertNotNil(keychain.items(in: .login)[phone.deviceID.uuidString])

        keychain.failDataProtectionWrites = false
        let relaunched = store(keychain)
        XCTAssertEqual(try relaunched.records(), [phone])
        XCTAssertEqual(try relaunched.location(), .dataProtection)
        XCTAssertTrue(keychain.items(in: .login).isEmpty)
    }

    func testWhenBothKeychainsHoldAPairingTheNewerOneWins() throws {
        let id = UUID(), other = UUID()
        let keychain = FakeKeychain()
        let older = record("Pocket iPhone", pairedAt: Date(timeIntervalSince1970: 100), id: id)
        let newer = record("Pocket iPhone", pairedAt: Date(timeIntervalSince1970: 200), id: id)
        keychain.seed(older, in: .dataProtection)
        keychain.seed(newer, in: .login)
        let stale = record("Spare iPhone", pairedAt: Date(timeIntervalSince1970: 100), id: other)
        let fresh = record("Spare iPhone", pairedAt: Date(timeIntervalSince1970: 200), id: other)
        keychain.seed(fresh, in: .dataProtection)
        keychain.seed(stale, in: .login)

        let store = store(keychain)
        XCTAssertEqual(try store.record(for: id), newer)
        XCTAssertEqual(try store.record(for: other), fresh)
        XCTAssertTrue(keychain.items(in: .login).isEmpty)
    }

    func testRemovingAPairingRemovesItFromBothKeychains() throws {
        let keychain = FakeKeychain()
        let phone = record("Pocket iPhone")
        let store = store(keychain)
        try store.save(phone)
        keychain.seed(phone, in: .login)   // a copy an interrupted move left behind
        try store.remove(deviceID: phone.deviceID)
        XCTAssertTrue(keychain.items(in: .dataProtection).isEmpty)
        XCTAssertTrue(keychain.items(in: .login).isEmpty)
        XCTAssertNil(try store.record(for: phone.deviceID))
    }

    func testSavingFallsBackWhenTheDataProtectionKeychainRefusesTheEntitlement() throws {
        let keychain = FakeKeychain()
        keychain.dataProtectionWritesNeedEntitlement = true
        let store = store(keychain)
        let phone = record("Pocket iPhone")
        try store.save(phone)
        XCTAssertNotNil(keychain.items(in: .login)[phone.deviceID.uuidString])
        XCTAssertEqual(try store.location(), .login)
        XCTAssertEqual(try store.records(), [phone])
    }
}

/// The login keychain (queries without `kSecUseDataProtectionKeychain`) and the data-protection
/// keychain, in memory.
final class FakeKeychain: LinkKeychain, @unchecked Sendable {
    struct Item {
        var service: String
        var data: Data
        var accessible: String?
        var synchronizable: Bool?
    }

    private let lock = NSLock()
    private var store: [KeychainLinkKeyStore.Location: [String: Item]] = [.login: [:], .dataProtection: [:]]
    var dataProtectionAvailable = true
    var dataProtectionWritesNeedEntitlement = false
    var failDataProtectionWrites = false

    func items(in location: KeychainLinkKeyStore.Location) -> [String: Item] { lock.withLock { store[location] ?? [:] } }

    func seed(_ record: LinkPairingRecord, in location: KeychainLinkKeyStore.Location) {
        let item = Item(service: "local.daybook.link", data: try! JSONEncoder().encode(record),
                        accessible: location == .dataProtection ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String : nil,
                        synchronizable: false)
        lock.withLock { store[location, default: [:]][record.deviceID.uuidString] = item }
    }

    private func location(_ query: [String: Any]) -> KeychainLinkKeyStore.Location {
        (query[kSecUseDataProtectionKeychain as String] as? Bool) == true ? .dataProtection : .login
    }

    private func matches(_ query: [String: Any], in location: KeychainLinkKeyStore.Location) -> [(String, Item)] {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        return (store[location] ?? [:]).filter { key, item in
            (service == nil || item.service == service) && (account == nil || key == account)
        }
        .sorted { $0.key < $1.key }
    }

    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        let location = location(query)
        if location == .dataProtection, !dataProtectionAvailable { return errSecMissingEntitlement }
        return lock.withLock {
            let found = matches(query, in: location)
            guard let first = found.first else { return errSecItemNotFound }
            let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
            if (query[kSecReturnData as String] as? Bool) == true {
                result = first.1.data as CFData
            } else if all {
                result = found.map { [kSecAttrAccount as String: $0.0] } as CFArray
            } else {
                result = [kSecAttrAccount as String: first.0] as CFDictionary
            }
            return errSecSuccess
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let location = location(attributes)
        if location == .dataProtection {
            if !dataProtectionAvailable || dataProtectionWritesNeedEntitlement { return errSecMissingEntitlement }
            if failDataProtectionWrites { return errSecIO }
        }
        guard let account = attributes[kSecAttrAccount as String] as? String, let data = attributes[kSecValueData as String] as? Data,
              let service = attributes[kSecAttrService as String] as? String else { return errSecParam }
        return lock.withLock {
            guard store[location]?[account] == nil else { return errSecDuplicateItem }
            store[location, default: [:]][account] = Item(service: service, data: data,
                                                          accessible: attributes[kSecAttrAccessible as String] as? String,
                                                          synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool)
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let location = location(query)
        if location == .dataProtection {
            if !dataProtectionAvailable || dataProtectionWritesNeedEntitlement { return errSecMissingEntitlement }
            if failDataProtectionWrites { return errSecIO }
        }
        return lock.withLock {
            let found = matches(query, in: location)
            guard !found.isEmpty else { return errSecItemNotFound }
            for (account, var item) in found {
                if let data = attributes[kSecValueData as String] as? Data { item.data = data }
                if let accessible = attributes[kSecAttrAccessible as String] as? String { item.accessible = accessible }
                store[location]?[account] = item
            }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let location = location(query)
        if location == .dataProtection, !dataProtectionAvailable { return errSecMissingEntitlement }
        return lock.withLock {
            let found = matches(query, in: location)
            guard !found.isEmpty else { return errSecItemNotFound }
            for (account, _) in found { store[location]?[account] = nil }
            return errSecSuccess
        }
    }
}
#endif
