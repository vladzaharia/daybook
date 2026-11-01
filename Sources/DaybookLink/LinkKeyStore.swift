import Foundation
import os
import Security
import Synchronization

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
    /// Its pairing is there but can't be read (written by a build with another record shape, or damaged):
    /// it can't connect until it's paired again, and Unpair removes it. Its name and date are the item's
    /// label and creation date, when the keychain has them.
    public var isDamaged = false

    public init(deviceID: UUID, name: String, deviceClass: LinkDeviceClass, pairedAt: Date, isDamaged: Bool = false) {
        self.deviceID = deviceID
        self.name = name
        self.deviceClass = deviceClass
        self.pairedAt = pairedAt
        self.isDamaged = isDamaged
    }
}

/// Where pairing keys live. The apps use `KeychainLinkKeyStore`; tests use `MemoryLinkKeyStore`.
///
/// A pairing that can't be read never hides the others: `records()` leaves it out, and
/// `damagedDevices()` lists it so it can be unpaired. Only the keychain itself failing throws.
public protocol LinkKeyStore: Sendable {
    func records() throws -> [LinkPairingRecord]
    func record(for deviceID: UUID) throws -> LinkPairingRecord?
    /// Pairings whose item is there but can't be read, to show and unpair (`remove(deviceID:)`).
    func damagedDevices() throws -> [LinkPairedDevice]
    func save(_ record: LinkPairingRecord) throws
    func remove(deviceID: UUID) throws
}

extension LinkKeyStore {
    public func record(for deviceID: UUID) throws -> LinkPairingRecord? {
        try records().first { $0.deviceID == deviceID }
    }

    public func damagedDevices() throws -> [LinkPairedDevice] { [] }

    /// Every pairing to show: the readable ones, then the damaged ones, never a key.
    public func pairedDevices() throws -> [LinkPairedDevice] {
        try records().map(\.device) + damagedDevices()
    }
}

public enum LinkKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keeps records in memory. For tests and previews.
public final class MemoryLinkKeyStore: LinkKeyStore, Sendable {
    private struct Stored {
        var records: [UUID: LinkPairingRecord] = [:]
        var damaged: [UUID: LinkPairedDevice] = [:]
    }

    private let stored = Mutex(Stored())

    /// - Parameter damaged: Pairings to hold as unreadable, as a keychain item another build wrote.
    public init(_ records: [LinkPairingRecord] = [], damaged: [LinkPairedDevice] = []) {
        stored.withLock { stored in
            for record in records { stored.records[record.deviceID] = record }
            for device in damaged {
                var device = device
                device.isDamaged = true
                stored.damaged[device.deviceID] = device
            }
        }
    }

    public func records() throws -> [LinkPairingRecord] {
        stored.withLock { $0.records.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func damagedDevices() throws -> [LinkPairedDevice] {
        stored.withLock { $0.damaged.values.sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func save(_ record: LinkPairingRecord) throws {
        stored.withLock { stored in
            stored.records[record.deviceID] = record
            // A new pairing replaces the item, damaged or not.
            stored.damaged[record.deviceID] = nil
        }
    }

    public func remove(deviceID: UUID) throws {
        stored.withLock { stored in
            stored.records[deviceID] = nil
            stored.damaged[deviceID] = nil
        }
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
///
/// An item that can't be decoded (another build's record shape, or damage) is left out of `records()`,
/// logged, and listed by `damagedDevices()`, so the other pairings keep working and it can be unpaired.
public final class KeychainLinkKeyStore: LinkKeyStore, Sendable {
    public let service: String
    public let accessGroup: String?
    private let keychain: any LinkKeychain
    /// The keychain settled on at first use.
    private let resolved = Mutex<Location?>(nil)
    private static let log = Logger(subsystem: "local.daybook", category: "link")

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
        try readAll().records
    }

    public func damagedDevices() throws -> [LinkPairedDevice] {
        try readAll().damaged
    }

    public func record(for deviceID: UUID) throws -> LinkPairingRecord? {
        guard case .record(let record) = try item(deviceID.uuidString, in: location()) else { return nil }
        return record
    }

    public func save(_ record: LinkPairingRecord) throws {
        let location = try self.location()
        let status = write(record, in: location)
        if status == errSecMissingEntitlement, location == .dataProtection {
            // This build can't use the data-protection keychain after all.
            resolved.withLock { $0 = .login }
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
        try resolved.withLock { resolved in
            if let resolved { return resolved }
            let location: Location
            #if os(macOS)
            var probe = baseQuery(.dataProtection)
            probe[kSecMatchLimit as String] = kSecMatchLimitOne
            probe[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            let status = keychain.copyMatching(probe, &result)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                location = migrateLoginItems() ? .dataProtection : .login
            case errSecMissingEntitlement:
                location = .login
            default:
                throw LinkKeyStoreError.keychain(status)
            }
            #else
            location = .dataProtection
            #endif
            resolved = location
            return location
        }
    }

    /// Moves every login-keychain item into the data-protection keychain. Returns false, leaving the
    /// login keychain in use for this run, if any item couldn't be moved, so no pairing goes missing;
    /// the next launch tries again. When both keychains hold a pairing (an earlier, interrupted move),
    /// the newer pairing wins, and a readable one over one that can't be read. An item that can't be
    /// read moves as it is, so it can still be listed and unpaired.
    private func migrateLoginItems() -> Bool {
        guard let entries = try? listed(in: .login) else { return false }
        for entry in entries {
            let old: Item, current: Item
            do {
                old = try item(entry.account, in: .login)
                current = try item(entry.account, in: .dataProtection)
            } catch {
                return false
            }
            switch (old, current) {
            case (.missing, _):
                continue
            case (.record(let old), .record(let current)) where current.pairedAt >= old.pairedAt:
                break
            case (.record(let old), _):
                guard write(old, in: .dataProtection) == errSecSuccess else { return false }
            case (.damaged, .record):
                break
            case (.damaged(let data), _):
                guard let data, write(data, account: entry.account, label: entry.label, in: .dataProtection) == errSecSuccess else { return false }
            }
            let deleted = delete(entry.account, in: .login)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
        }
        return true
    }

    // MARK: Items

    /// One item, read.
    private enum Item {
        case record(LinkPairingRecord)
        /// There, but not a record this build can read; its bytes, when it has any.
        case damaged(Data?)
        case missing
    }

    /// An item as a listing describes it, without its data.
    private struct Listed {
        var account: String
        var label: String?
        var createdAt: Date?
    }

    private static let labelPrefix = "Daybook link: "

    /// Every item, the readable ones as records, in pairing order, and the damaged ones to show.
    private func readAll() throws -> (records: [LinkPairingRecord], damaged: [LinkPairedDevice]) {
        let location = try self.location()
        var records: [LinkPairingRecord] = []
        var damaged: [LinkPairedDevice] = []
        // The file-based macOS keychain can't return data for several items at once.
        for entry in try listed(in: location) {
            guard let id = UUID(uuidString: entry.account) else { continue }
            switch try item(entry.account, in: location) {
            case .record(let record):
                records.append(record)
            case .damaged:
                let name = entry.label.map { $0.hasPrefix(Self.labelPrefix) ? String($0.dropFirst(Self.labelPrefix.count)) : $0 } ?? ""
                damaged.append(LinkPairedDevice(deviceID: id, name: name, deviceClass: LinkDeviceClass(rawValue: "unknown"),
                                                pairedAt: entry.createdAt ?? .distantPast, isDamaged: true))
            case .missing:
                continue
            }
        }
        return (records.sorted { $0.pairedAt < $1.pairedAt }, damaged.sorted { $0.pairedAt < $1.pairedAt })
    }

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

    private func listed(in location: Location) throws -> [Listed] {
        var query = baseQuery(location)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return Listed(account: account, label: attributes[kSecAttrLabel as String] as? String,
                          createdAt: attributes[kSecAttrCreationDate as String] as? Date)
        }
    }

    /// Reads one item. Only the keychain failing throws: an item that doesn't decode is `damaged`,
    /// and said once in the log.
    private func item(_ account: String, in location: Location) throws -> Item {
        var query = baseQuery(location)
        query[kSecAttrAccount as String] = account
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { throw LinkKeyStoreError.keychain(status) }
        let data = result as? Data
        guard let data, let record = try? JSONDecoder().decode(LinkPairingRecord.self, from: data) else {
            if reported.withLock({ $0.insert(account).inserted }) {
                Self.log.error("A pairing can’t be read and is left out until it’s unpaired or paired again: \(account, privacy: .private)")
            }
            return .damaged(data)
        }
        return .record(record)
    }

    /// Damaged items already in the log.
    private let reported = Mutex<Set<String>>([])

    private func write(_ record: LinkPairingRecord, in location: Location) -> OSStatus {
        guard let data = try? JSONEncoder().encode(record) else { return errSecParam }
        return write(data, account: record.deviceID.uuidString, label: Self.labelPrefix + record.name, in: location)
    }

    private func write(_ data: Data, account: String, label: String?, in location: Location) -> OSStatus {
        var query = baseQuery(location)
        query[kSecAttrAccount as String] = account
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let label { attributes[kSecAttrLabel as String] = label }
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
