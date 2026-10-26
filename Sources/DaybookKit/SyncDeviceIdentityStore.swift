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
    public static func keychain(for localRoot: URL) -> SyncDeviceIdentityStore {
        let digest = SHA256.hash(data: Data(localRoot.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.daybook.sync",
                                    kSecAttrAccount as String: "identity-\(digest)", kSecUseDataProtectionKeychain as String: true]
        return SyncDeviceIdentityStore(
            read: {
                var search = query
                search[kSecReturnData as String] = true
                search[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
                return try? JSONDecoder().decode(StoredSyncIdentity.self, from: data)
            },
            write: { identity in
                guard let data = try? JSONEncoder().encode(identity) else { return false }
                SecItemDelete(query as CFDictionary)
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            })
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
