import CryptoKit
import Foundation
import Security

/// This device's identity in the sync journal (`LibrarySyncController.deviceID`) and a random ID for this
/// installation, which tells two devices apart if they ever share a device ID.
public struct StoredSyncIdentity: Codable, Equatable, Sendable {
    public var deviceID: String
    public var installation: String
    public init(deviceID: String, installation: String) { self.deviceID = deviceID; self.installation = installation }
}

/// Where the identity is kept. In the app, a keychain item that stays on this device: preferences and the library
/// travel with Migration Assistant and backups, so an identity kept there would be shared by two Macs.
public struct SyncDeviceIdentityStore: Sendable {
    public var read: @Sendable () -> StoredSyncIdentity?
    /// False when it couldn't be stored (no keychain for this build).
    public var write: @Sendable (StoredSyncIdentity) -> Bool

    public init(read: @escaping @Sendable () -> StoredSyncIdentity?, write: @escaping @Sendable (StoredSyncIdentity) -> Bool) {
        self.read = read; self.write = write
    }

    /// A data-protection keychain item, available after first unlock and never synced or migrated
    /// (`…ThisDeviceOnly`), one per library folder. Unsigned builds and `swift test` have no such keychain; the
    /// store then reports it couldn't write, and the identity stays in preferences as before.
    ///
    /// On the iPhone the app's container, and the library's path with it, moves when the app is updated or reinstalled,
    /// so the item is kept under the library's path within the container (`account(for:home:)`), and an item kept under
    /// its full path by an earlier version moves there. Without that, every update that moved the container gave the
    /// iPhone a new device ID: another entry in "Devices in This Library", and recorders it managed under the old one.
    public static func keychain(for localRoot: URL) -> SyncDeviceIdentityStore {
        let path = localRoot.standardizedFileURL.path
        let legacy = account(for: path, home: nil)
        #if os(iOS)
        let account = Self.account(for: path, home: NSHomeDirectory())
        // The app's own library (not a debug one elsewhere in the container) may find its identity under an earlier
        // container's path, when the update to this version moved the container.
        let isAppLibrary = path == LibraryLocation.defaultRoot.standardizedFileURL.path
        #else
        let account = legacy
        let isAppLibrary = false
        #endif
        @Sendable func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.daybook.sync",
             kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
        }
        @Sendable func read(_ account: String) -> StoredSyncIdentity? {
            var search = query(account)
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(StoredSyncIdentity.self, from: data)
        }
        @Sendable func write(_ identity: StoredSyncIdentity, _ account: String) -> Bool {
            guard let data = try? JSONEncoder().encode(identity) else { return false }
            SecItemDelete(query(account) as CFDictionary)
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        /// The identity most recently kept under any library path: an earlier container's.
        @Sendable func latestElsewhere() -> (account: String, identity: StoredSyncIdentity)? {
            let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.daybook.sync",
                                         kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                         kSecReturnAttributes as String: true, kSecReturnData as String: true]
            var items: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &items) == errSecSuccess, let found = items as? [[String: Any]] else { return nil }
            return found.compactMap { item -> (String, StoredSyncIdentity, Date)? in
                guard let name = item[kSecAttrAccount as String] as? String, name.hasPrefix("identity-"), name != account,
                      let data = item[kSecValueData as String] as? Data,
                      let identity = try? JSONDecoder().decode(StoredSyncIdentity.self, from: data) else { return nil }
                return (name, identity, item[kSecAttrModificationDate as String] as? Date ?? .distantPast)
            }.max { $0.2 < $1.2 }.map { ($0.0, $0.1) }
        }
        return SyncDeviceIdentityStore(
            read: {
                if let stored = read(account) { return stored }
                // An earlier version kept it under the full path: it moves, so the next container move keeps it.
                if account != legacy, let stored = read(legacy) {
                    if write(stored, account) { SecItemDelete(query(legacy) as CFDictionary) }
                    return stored
                }
                guard isAppLibrary, let earlier = latestElsewhere() else { return nil }
                if write(earlier.identity, account) { SecItemDelete(query(earlier.account) as CFDictionary) }
                return earlier.identity
            },
            write: { write($0, account) })
    }

    /// The keychain account an identity is kept under: a digest of the library's path, within `home` when it's inside it
    /// (the iPhone's container, whose own path changes), else the full path (a Mac's library, which can be anywhere).
    static func account(for path: String, home: String?) -> String {
        var key = path
        if let home, !home.isEmpty, path.hasPrefix(home + "/") { key = "~" + path.dropFirst(home.count) }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "identity-\(digest)"
    }

    /// Kept in memory, for tests that play several devices in one process.
    public static func memory(_ initial: StoredSyncIdentity? = nil) -> SyncDeviceIdentityStore {
        final class Box: @unchecked Sendable { let lock = NSLock(); var value: StoredSyncIdentity? }
        let box = Box()
        box.value = initial
        return SyncDeviceIdentityStore(read: { box.lock.withLock { box.value } },
                                       write: { identity in box.lock.withLock { box.value = identity }; return true })
    }

    /// Nothing can be stored: the identity lives in preferences, as before (tests that choose a device ID there).
    public static let unavailable = SyncDeviceIdentityStore(read: { nil }, write: { _ in false })
}
