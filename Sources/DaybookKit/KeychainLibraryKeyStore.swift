import DaybookCore
import Foundation
import Security

/// Library keys in iCloud Keychain (docs/icloud-sync.md, "Encryption"): one generic-password item per key, service
/// `local.daybook.library-key`, account `<library ID>:<key ID>`, synchronizable, in the keychain access group both apps
/// share (`<team>.local.daybook.shared`), readable after first unlock (a locked iPhone's background pass needs it;
/// `…ThisDeviceOnly` can't sync). The value is a `LibraryKeyRecord`. Removing an item removes it from every device.
///
/// Both apps list their own group first in `keychain-access-groups`, so items stored without a group (the link's
/// pairing keys, the sync device ID) stay where they were; only library keys name the shared group.
public final class KeychainLibraryKeyStore: LibraryKeyStore, @unchecked Sendable {
    public static let service = "local.daybook.library-key"
    public static let label = "Daybook library key"
    /// Info.plist key naming the shared group on iPhone (`$(AppIdentifierPrefix)local.daybook.shared`). The Mac reads it
    /// from its own signature.
    public static let sharedGroupInfoKey = "DaybookKeychainSharedGroup"
    static let sharedGroupSuffix = ".local.daybook.shared"

    public let accessGroup: String

    public init(accessGroup: String) { self.accessGroup = accessGroup }

    /// The store for this app, or nil when it isn't signed with the shared group (unsigned, ad hoc, and test builds,
    /// which can't sync through iCloud either). Without it a device can't open an encrypted library.
    public static var system: KeychainLibraryKeyStore? { sharedGroup().map(KeychainLibraryKeyStore.init(accessGroup:)) }

    static func sharedGroup() -> String? {
        #if os(macOS)
        if let task = SecTaskCreateFromSelf(nil),
           let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
           let group = groups.first(where: isSharedGroup) { return group }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: sharedGroupInfoKey) as? String).flatMap { isSharedGroup($0) ? $0 : nil }
    }

    /// `<ten-character team prefix>.local.daybook.shared`, as signing expands it; not an unexpanded `$(…)`.
    static func isSharedGroup(_ group: String) -> Bool {
        guard group.hasSuffix(sharedGroupSuffix) else { return false }
        let prefix = group.dropLast(sharedGroupSuffix.count)
        return prefix.count == 10 && prefix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func keys(for libraryID: UUID) throws -> [LibraryKey] {
        var query = base
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw LibraryKeyStoreError.keychain(status) }
        let prefix = "\(libraryID.uuidString):"
        return items.compactMap { item -> LibraryKey? in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix),
                  let data = item[kSecValueData as String] as? Data, let key = LibraryKeyRecord.decode(data)?.libraryKey,
                  key.libraryID == libraryID, account == Self.account(key) else { return nil }
            return key
        }.sorted { $0.idHex < $1.idHex }
    }

    /// Adds the key, then reads it back: a key that can't be read back isn't kept.
    public func store(_ key: LibraryKey) throws {
        if try keys(for: key.libraryID).contains(key) { return }
        var item = base
        item[kSecAttrAccount as String] = Self.account(key)
        item[kSecAttrSynchronizable as String] = true
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = Self.label
        item[kSecValueData as String] = try LibraryKeyRecord(key).encoded()
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw LibraryKeyStoreError.keychain(status) }
        guard try keys(for: key.libraryID).contains(key) else { throw LibraryKeyStoreError.notKept }
    }

    public func remove(keyID: Data, libraryID: UUID) throws {
        var query = base
        query[kSecAttrAccount as String] = "\(libraryID.uuidString):\(keyID.map { String(format: "%02x", $0) }.joined())"
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LibraryKeyStoreError.keychain(status) }
    }

    static func account(_ key: LibraryKey) -> String { "\(key.libraryID.uuidString):\(key.idHex)" }
}
