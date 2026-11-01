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

    func testBehaviorAPairingThatCantBeReadIsListedApartAndTheOthersKeepWorking() throws {
        let keychain = FakeKeychain()
        let phone = record("Pocket iPhone", pairedAt: Date(timeIntervalSince1970: 100))
        keychain.seed(phone, in: .dataProtection)
        let damagedID = UUID(), pairedAt = Date(timeIntervalSince1970: 50)
        keychain.seedDamaged(Data(#"{"deviceID":"older shape"}"#.utf8), account: damagedID, label: "Daybook link: Spare iPhone",
                             createdAt: pairedAt, in: .dataProtection)
        let store = store(keychain)

        XCTAssertEqual(try store.records(), [phone], "one item that can't be read never hides the others")
        XCTAssertNil(try store.record(for: damagedID))
        XCTAssertEqual(try store.record(for: phone.deviceID), phone)
        let damaged = try XCTUnwrap(store.damagedDevices().first)
        XCTAssertEqual(damaged.deviceID, damagedID)
        XCTAssertEqual(damaged.name, "Spare iPhone", "named by its item's label")
        XCTAssertEqual(damaged.pairedAt, pairedAt)
        XCTAssertTrue(damaged.isDamaged)
        XCTAssertEqual(try store.pairedDevices().map(\.deviceID), [phone.deviceID, damagedID])
        XCTAssertEqual(try store.pairedDevices().map(\.isDamaged), [false, true])

        // Unpairing removes it by its account, without reading it.
        try store.remove(deviceID: damagedID)
        XCTAssertEqual(try store.damagedDevices(), [])
        XCTAssertEqual(try store.records(), [phone])
    }

    func testBehaviorPairingAgainReplacesADamagedItem() throws {
        let keychain = FakeKeychain()
        let id = UUID()
        keychain.seedDamaged(Data("not json".utf8), account: id, label: nil, createdAt: Date(), in: .dataProtection)
        let store = store(keychain)
        XCTAssertEqual(try store.damagedDevices().map(\.name), [""], "no label: no name, which the apps fill in")

        let again = record("Pocket iPhone", id: id)
        try store.save(again)
        XCTAssertEqual(try store.records(), [again])
        XCTAssertEqual(try store.damagedDevices(), [])
    }

    func testBehaviorADamagedLoginItemMovesAsItIsUnlessAReadableOneIsThere() throws {
        let keychain = FakeKeychain()
        let alone = UUID(), shadowed = UUID()
        let raw = Data(#"{"shape":"older"}"#.utf8)
        keychain.seedDamaged(raw, account: alone, label: "Daybook link: Spare iPhone", createdAt: Date(), in: .login)
        keychain.seedDamaged(raw, account: shadowed, label: "Daybook link: Old iPhone", createdAt: Date(), in: .login)
        let readable = record("Pocket iPhone", id: shadowed)
        keychain.seed(readable, in: .dataProtection)
        let store = store(keychain)

        XCTAssertEqual(try store.location(), .dataProtection, "an item that can't be read doesn't stop the move")
        XCTAssertTrue(keychain.items(in: .login).isEmpty)
        XCTAssertEqual(keychain.items(in: .dataProtection)[alone.uuidString]?.data, raw, "moved as it is, to be listed and unpaired")
        XCTAssertEqual(try store.records(), [readable], "a readable pairing wins over one that can't be read")
        XCTAssertEqual(try store.damagedDevices().map(\.name), ["Spare iPhone"])
    }

    func testBehaviorAKeychainFailureStillThrows() throws {
        let keychain = FakeKeychain()
        keychain.dataProtectionAvailable = false
        keychain.failLoginReads = true
        let store = store(keychain)
        XCTAssertThrowsError(try store.records()) { error in
            XCTAssertEqual(error as? LinkKeyStoreError, .keychain(errSecInteractionNotAllowed))
        }
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
        var label: String?
        var createdAt = Date()
    }

    private let lock = NSLock()
    private var store: [KeychainLinkKeyStore.Location: [String: Item]] = [.login: [:], .dataProtection: [:]]
    var dataProtectionAvailable = true
    var dataProtectionWritesNeedEntitlement = false
    var failDataProtectionWrites = false
    /// The login keychain refuses reads, as a locked keychain does.
    var failLoginReads = false

    func items(in location: KeychainLinkKeyStore.Location) -> [String: Item] { lock.withLock { store[location] ?? [:] } }

    func seed(_ record: LinkPairingRecord, in location: KeychainLinkKeyStore.Location) {
        let item = Item(service: "local.daybook.link", data: try! JSONEncoder().encode(record),
                        accessible: location == .dataProtection ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String : nil,
                        synchronizable: false, label: "Daybook link: \(record.name)")
        lock.withLock { store[location, default: [:]][record.deviceID.uuidString] = item }
    }

    /// An item this build can't read (another build's record shape, or damage), as `label` names it.
    func seedDamaged(_ data: Data, account: UUID, label: String?, createdAt: Date, in location: KeychainLinkKeyStore.Location) {
        let item = Item(service: "local.daybook.link", data: data, accessible: nil, synchronizable: false, label: label, createdAt: createdAt)
        lock.withLock { store[location, default: [:]][account.uuidString] = item }
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
        if location == .login, failLoginReads { return errSecInteractionNotAllowed }
        return lock.withLock {
            let found = matches(query, in: location)
            guard let first = found.first else { return errSecItemNotFound }
            let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
            if (query[kSecReturnData as String] as? Bool) == true {
                result = first.1.data as CFData
            } else if all {
                result = found.map { account, item -> [String: Any] in
                    var attributes: [String: Any] = [kSecAttrAccount as String: account, kSecAttrCreationDate as String: item.createdAt]
                    if let label = item.label { attributes[kSecAttrLabel as String] = label }
                    return attributes
                } as CFArray
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
                                                          synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool,
                                                          label: attributes[kSecAttrLabel as String] as? String)
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
                if let label = attributes[kSecAttrLabel as String] as? String { item.label = label }
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
