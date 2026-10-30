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
        let library = libraryKey(for: path, home: NSHomeDirectory())
        // The app's own library (not a debug one elsewhere in the container) may find its identity under an earlier
        // container's path, when the update to this version moved the container.
        let isAppLibrary = path == LibraryLocation.defaultRoot.standardizedFileURL.path
        #else
        let library = libraryKey(for: path, home: nil)
        let isAppLibrary = false
        #endif
        let account = Self.account(library)
        // Items an earlier version kept say nothing of their library. In a release build only the app's library ever had
        // one; a debug build may have opened demo libraries too, whose items look the same, so it takes none of them.
        #if DEBUG
        let unmarkedAreThisLibrarys = false
        #else
        let unmarkedAreThisLibrarys = true
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
            // Which library it's for, so another library's is never taken for this one (`adoptable`).
            add[kSecAttrLabel as String] = library
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        /// This library's identity kept under an earlier container's path (`adoptable`).
        @Sendable func latestElsewhere() -> IdentityItem? {
            let search: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.daybook.sync",
                                         kSecUseDataProtectionKeychain as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                                         kSecReturnAttributes as String: true, kSecReturnData as String: true]
            var items: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &items) == errSecSuccess, let found = items as? [[String: Any]] else { return nil }
            let candidates = found.compactMap { item -> IdentityItem? in
                guard let name = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data,
                      let identity = try? JSONDecoder().decode(StoredSyncIdentity.self, from: data) else { return nil }
                return IdentityItem(account: name, library: item[kSecAttrLabel as String] as? String,
                                    modified: item[kSecAttrModificationDate as String] as? Date ?? .distantPast, identity: identity)
            }
            return adoptable(candidates, account: account, library: library, unmarkedAreThisLibrarys: unmarkedAreThisLibrarys)
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
    static func account(for path: String, home: String?) -> String { account(libraryKey(for: path, home: home)) }

    /// The library's path as an identity item records it: within `home` ("~/…") when it's inside it, else in full.
    static func libraryKey(for path: String, home: String?) -> String {
        guard let home, !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func account(_ libraryKey: String) -> String {
        "identity-" + SHA256.hash(data: Data(libraryKey.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// An identity keychain item, as `adoptable` weighs it.
    struct IdentityItem: Equatable {
        var account: String
        /// The library it's for (`libraryKey`); nil, or anything else, in an item an earlier version kept.
        var library: String?
        var modified: Date
        var identity: StoredSyncIdentity
    }

    /// Which identity kept under another path the library at `library` may take as its own after the container moved: the
    /// most recently changed one that records this library, or that records none (an earlier version's), and those only
    /// when `unmarkedAreThisLibrarys` (a release build, where no other library ever had one). Another library's never.
    static func adoptable(_ items: [IdentityItem], account: String, library: String, unmarkedAreThisLibrarys: Bool) -> IdentityItem? {
        items.filter { item in
            guard item.account.hasPrefix("identity-"), item.account != account else { return false }
            if item.library == library { return true }
            let marked = item.library.map { $0.hasPrefix("~") || $0.hasPrefix("/") } ?? false
            return !marked && unmarkedAreThisLibrarys
        }.max { ($0.modified, $0.account) < ($1.modified, $1.account) }
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
