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
/// other device's ID. Items never sync through iCloud Keychain and never move to another device
/// (`…ThisDeviceOnly`). On iPhone they're readable after first unlock, so a recording that
/// continues on the Lock Screen can reconnect.
public final class KeychainLinkKeyStore: LinkKeyStore, @unchecked Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "local.daybook.link", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func records() throws -> [LinkPairingRecord] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        let accounts = (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
        // The file-based macOS keychain can't return data for several items at once.
        return try accounts.compactMap { UUID(uuidString: $0) }.compactMap { try record(for: $0) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    public func record(for deviceID: UUID) throws -> LinkPairingRecord? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = deviceID.uuidString
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        guard let data = result as? Data, let record = try? JSONDecoder().decode(LinkPairingRecord.self, from: data) else {
            throw LinkKeyStoreError.corrupt
        }
        return record
    }

    public func save(_ record: LinkPairingRecord) throws {
        let data = try JSONEncoder().encode(record)
        var query = baseQuery()
        query[kSecAttrAccount as String] = record.deviceID.uuidString
        var attributes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: "Daybook link: \(record.name)"]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { $1 }
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw LinkKeyStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw LinkKeyStoreError.keychain(status)
        }
    }

    public func remove(deviceID: UUID) throws {
        var query = baseQuery()
        query[kSecAttrAccount as String] = deviceID.uuidString
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinkKeyStoreError.keychain(status) }
    }
}
