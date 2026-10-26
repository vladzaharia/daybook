import Foundation
import Security

/// A device this one is paired with, and the key the pair shares.
public struct LinkPairingRecord: Codable, Sendable, Equatable {
    /// The other device's ID (the Mac's on the phone, the phone's on the Mac).
    public var deviceID: UUID
    public var name: String
    public var deviceClass: LinkDeviceClass
    public var pairedAt: Date
    /// 32-byte key from pairing: the TLS pre-shared key and the session authentication key.
    public var linkKey: Data
    /// TLS PSK identity. Derived from pairing, so it reveals neither device's ID or name.
    public var pskIdentity: Data

    public init(deviceID: UUID, name: String, deviceClass: LinkDeviceClass, pairedAt: Date, linkKey: Data, pskIdentity: Data) {
        self.deviceID = deviceID
        self.name = name
        self.deviceClass = deviceClass
        self.pairedAt = pairedAt
        self.linkKey = linkKey
        self.pskIdentity = pskIdentity
    }

    /// The record without its key, for showing.
    public var device: LinkPairedDevice {
        LinkPairedDevice(deviceID: deviceID, name: name, deviceClass: deviceClass, pairedAt: pairedAt)
    }
}

/// A paired device, as the apps show it. Never carries the key.
public struct LinkPairedDevice: Sendable, Hashable, Identifiable {
    public var id: UUID { deviceID }
    public var deviceID: UUID
    public var name: String
    public var deviceClass: LinkDeviceClass
    public var pairedAt: Date
}

/// Where pairing keys live. The apps use `KeychainLinkKeyStore`; tests use `MemoryLinkKeyStore`.
public protocol LinkKeyStore: Sendable {
    func records() throws -> [LinkPairingRecord]
    func record(for deviceID: UUID) throws -> LinkPairingRecord?
    func save(_ record: LinkPairingRecord) throws
    func remove(deviceID: UUID) throws
}

extension LinkKeyStore {
    public func record(for deviceID: UUID) throws -> LinkPairingRecord? {
        try records().first { $0.deviceID == deviceID }
    }
}

public enum LinkKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case corrupt
}

/// Keeps records in memory. For tests and previews.
public final class MemoryLinkKeyStore: LinkKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: LinkPairingRecord] = [:]

    public init(_ records: [LinkPairingRecord] = []) {
        for record in records { stored[record.deviceID] = record }
    }

    public func records() throws -> [LinkPairingRecord] {
        lock.withLock { stored.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func save(_ record: LinkPairingRecord) throws {
        lock.withLock { stored[record.deviceID] = record }
    }

    public func remove(deviceID: UUID) throws {
        lock.withLock { _ = stored.removeValue(forKey: deviceID) }
    }
}

/// Keeps each record as a generic-password item: service `local.daybook.link`, account = the
/// other device's ID. Items never sync through iCloud Keychain and never move to another device: they
/// live in the data-protection keychain as `…AfterFirstUnlockThisDeviceOnly`, readable after first
/// unlock so a recording that continues on the Lock Screen can reconnect.
///
/// On the Mac the data-protection keychain needs a signed build with an application identifier.
/// Earlier versions used the login keychain there (whose items Migration Assistant carries to a new
/// Mac); the first use moves them over: read, write the new item, delete the old. Builds that can't
/// use the data-protection keychain (unsigned development and test builds) keep the login keychain.
public final class KeychainLinkKeyStore: LinkKeyStore, @unchecked Sendable {
    public let service: String
    public let accessGroup: String?
    private let keychain: any LinkKeychain
    private let lock = NSLock()
    private var resolved: Location?

    /// Which keychain holds the items.
    enum Location: Equatable {
        /// The data-protection keychain (always, on iPhone).
        case dataProtection
        /// The Mac's file-based login keychain.
        case login
    }

    public convenience init(service: String = "local.daybook.link", accessGroup: String? = nil) {
        self.init(service: service, accessGroup: accessGroup, keychain: SystemLinkKeychain())
    }

    init(service: String, accessGroup: String?, keychain: any LinkKeychain) {
        self.service = service
        self.accessGroup = accessGroup
        self.keychain = keychain
    }

    public func records() throws -> [LinkPairingRecord] {
        let location = try self.location()
        // The file-based macOS keychain can't return data for several items at once.
        return try accounts(in: location).compactMap { UUID(uuidString: $0) }.compactMap { try record(for: $0, in: location) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    public func record(for deviceID: UUID) throws -> LinkPairingRecord? {
        try record(for: deviceID, in: location())
    }

    public func save(_ record: LinkPairingRecord) throws {
        let location = try self.location()
        let status = write(record, in: location)
        if status == errSecMissingEntitlement, location == .dataProtection {
            // This build can't use the data-protection keychain after all.
            lock.withLock { resolved = .login }
            let fallback = write(record, in: .login)
            guard fallback == errSecSuccess else { throw LinkKeyStoreError.keychain(fallback) }
            return
        }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
    }

    public func remove(deviceID: UUID) throws {
        let location = try self.location()
        let status = delete(deviceID.uuidString, in: location)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinkKeyStoreError.keychain(status) }
        #if os(macOS)
        // Never leave a copy in the other keychain (from a move that was interrupted) to come back later.
        _ = delete(deviceID.uuidString, in: location == .dataProtection ? .login : .dataProtection)
        #endif
    }

    // MARK: Location and migration

    /// Settled on first use. On the Mac: the data-protection keychain when this build can use it,
    /// after moving any login-keychain items into it; otherwise the login keychain.
    func location() throws -> Location {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        #if os(macOS)
        var probe = baseQuery(.dataProtection)
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        probe[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(probe, &result)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            resolved = migrateLoginItems() ? .dataProtection : .login
        case errSecMissingEntitlement:
            resolved = .login
        default:
            throw LinkKeyStoreError.keychain(status)
        }
        #else
        resolved = .dataProtection
        #endif
        return resolved ?? .login
    }

    /// Moves every login-keychain item into the data-protection keychain. Returns false, leaving the
    /// login keychain in use for this run, if any item couldn't be moved, so no pairing goes missing;
    /// the next launch tries again. When both keychains hold a pairing (an earlier, interrupted move),
    /// the newer pairing wins.
    private func migrateLoginItems() -> Bool {
        guard let accounts = try? accounts(in: .login) else { return false }
        for account in accounts {
            guard let id = UUID(uuidString: account), let old = try? record(for: id, in: .login) else { return false }
            let current: LinkPairingRecord?
            do { current = try record(for: id, in: .dataProtection) } catch { return false }
            if current.map({ $0.pairedAt < old.pairedAt }) ?? true {
                guard write(old, in: .dataProtection) == errSecSuccess else { return false }
            }
            let deleted = delete(account, in: .login)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
        }
        return true
    }

    // MARK: Items

    private func baseQuery(_ location: Location) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if location == .dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func accounts(in location: Location) throws -> [String] {
        var query = baseQuery(location)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func record(for deviceID: UUID, in location: Location) throws -> LinkPairingRecord? {
        var query = baseQuery(location)
        query[kSecAttrAccount as String] = deviceID.uuidString
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        guard let data = result as? Data, let record = try? JSONDecoder().decode(LinkPairingRecord.self, from: data) else {
            throw LinkKeyStoreError.corrupt
        }
        return record
    }

    private func write(_ record: LinkPairingRecord, in location: Location) -> OSStatus {
        guard let data = try? JSONEncoder().encode(record) else { return errSecParam }
        var query = baseQuery(location)
        query[kSecAttrAccount as String] = record.deviceID.uuidString
        var attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "Daybook link: \(record.name)"]
        if location == .dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = keychain.update(query, attributes)
        guard status == errSecItemNotFound else { return status }
        query.merge(attributes) { $1 }
        return keychain.add(query)
    }

    private func delete(_ account: String, in location: Location) -> OSStatus {
        var query = baseQuery(location)
        query[kSecAttrAccount as String] = account
        return keychain.delete(query)
    }
}

/// The Security calls `KeychainLinkKeyStore` makes; tests stand in a keychain of their own.
protocol LinkKeychain: Sendable {
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemLinkKeychain: LinkKeychain {
    func copyMatching(_ query: [String: Any], _ result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
