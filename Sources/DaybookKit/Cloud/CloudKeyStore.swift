import Foundation
import Security

/// An API key for a cloud provider. It never prints: its description, debug description, and mirror are the
/// masked form ("sk-ant-…gDAA"), so logging one, by accident or in a crash report, shows no more than
/// Settings does. Only a request reads `secret`.
public struct CloudAPIKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let secret: String

    /// Nil for an empty key; spaces and line breaks around a pasted key are dropped.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        secret = trimmed
    }

    /// The key's kind and its last four characters: "sk-ant-…gDAA", "sk-proj-…x9Qa".
    public var masked: String { Self.mask(secret) }

    public var description: String { masked }
    public var debugDescription: String { "CloudAPIKey(\(masked))" }
    public var customMirror: Mirror { Mirror(self, children: ["masked": masked]) }

    static func mask(_ key: String) -> String {
        guard key.count >= 12 else { return "…" + String(key.suffix(min(2, key.count / 4))) }
        // The leading words that name the kind of key ("sk", "ant", "proj"), not the key itself.
        var prefix = ""
        for part in key.split(separator: "-", omittingEmptySubsequences: false).dropLast() {
            guard (1...5).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isLowercase }) else { break }
            prefix += part + "-"
        }
        return prefix + "…" + key.suffix(4)
    }
}

/// Where the cloud keys live: one per provider. The apps use `KeychainCloudKeyStore`; tests and the
/// Settings demos use `MemoryCloudKeyStore`.
public protocol CloudKeyStore: Sendable {
    func key(for provider: CloudProvider) throws -> CloudAPIKey?
    /// Replaces any key the provider had.
    func store(_ key: CloudAPIKey, for provider: CloudProvider) throws
    func removeKey(for provider: CloudProvider) throws
}

extension CloudKeyStore {
    /// The providers with a key, in `CloudProvider` order. A key that can't be read counts as none.
    public func providersWithKeys() -> [CloudProvider] {
        CloudProvider.allCases.filter { ((try? key(for: $0)) ?? nil) != nil }
    }
}

public enum CloudKeyStoreError: Error, Equatable, LocalizedError {
    case keychain(OSStatus)
    case notKept

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "The keychain couldn't keep the key (\(status))."
        case .notKept: return "The keychain didn't keep the key."
        }
    }
}

/// Keeps keys in memory. For tests and the Settings demos.
public final class MemoryCloudKeyStore: CloudKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [CloudProvider: CloudAPIKey]

    public init(_ keys: [CloudProvider: CloudAPIKey] = [:]) { self.keys = keys }

    public func key(for provider: CloudProvider) throws -> CloudAPIKey? { lock.withLock { keys[provider] } }
    public func store(_ key: CloudAPIKey, for provider: CloudProvider) throws { lock.withLock { keys[provider] = key } }
    public func removeKey(for provider: CloudProvider) throws { lock.withLock { _ = keys.removeValue(forKey: provider) } }
}

/// The Security calls `KeychainCloudKeyStore` makes, so tests can see the items it writes without a keychain.
protocol CloudKeychain: Sendable {
    func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemCloudKeychain: CloudKeychain {
    func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { SecItemCopyMatching(query as CFDictionary, result) }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Cloud keys in iCloud Keychain (docs/cloud.md, "Keys"): one generic-password item per provider, service
/// `local.daybook.cloud-key`, account the provider ("anthropic", "openai"), synchronizable, in the keychain
/// access group both apps share (`<team>.local.daybook.shared`, where library keys live,
/// `KeychainLibraryKeyStore`), readable after first unlock. So a key added on the Mac reaches the iPhone,
/// and removing it removes it everywhere. A key is never written anywhere else: not the library, not
/// preferences, not a log.
///
/// A build without the shared group (unsigned development and test builds on the Mac) keeps keys in the
/// login keychain, on this Mac only, as the link's pairing keys do there.
public final class KeychainCloudKeyStore: CloudKeyStore, @unchecked Sendable {
    public static let service = "local.daybook.cloud-key"
    public let accessGroup: String?
    private let keychain: any CloudKeychain

    public convenience init(accessGroup: String?) { self.init(accessGroup: accessGroup, keychain: SystemCloudKeychain()) }

    init(accessGroup: String?, keychain: any CloudKeychain) {
        self.accessGroup = accessGroup
        self.keychain = keychain
    }

    /// The store for this app: the shared group when it's signed with one.
    public static var system: KeychainCloudKeyStore { KeychainCloudKeyStore(accessGroup: KeychainLibraryKeyStore.sharedGroup()) }

    static func label(_ provider: CloudProvider) -> String {
        "Daybook \(provider == .anthropic ? "Anthropic" : "OpenAI") API key"
    }

    func query(_ provider: CloudProvider) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: provider.rawValue]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        } else {
            #if os(iOS)
            query[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
        return query
    }

    /// Synchronizable only where it can sync: in the shared group, or on iPhone.
    var synchronizes: Bool {
        #if os(iOS)
        return true
        #else
        return accessGroup != nil
        #endif
    }

    public func key(for provider: CloudProvider) throws -> CloudAPIKey? {
        var query = self.query(provider)
        if synchronizes { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = keychain.copyMatching(query, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudKeyStoreError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap(CloudAPIKey.init)
    }

    /// Replaces the provider's key, then reads it back: a key that can't be read back isn't kept.
    public func store(_ key: CloudAPIKey, for provider: CloudProvider) throws {
        try removeKey(for: provider)
        var item = query(provider)
        if synchronizes { item[kSecAttrSynchronizable as String] = true }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = Self.label(provider)
        item[kSecValueData as String] = Data(key.secret.utf8)
        let status = keychain.add(item)
        guard status == errSecSuccess else { throw CloudKeyStoreError.keychain(status) }
        guard try self.key(for: provider) == key else { throw CloudKeyStoreError.notKept }
    }

    public func removeKey(for provider: CloudProvider) throws {
        var query = self.query(provider)
        if synchronizes { query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        let status = keychain.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudKeyStoreError.keychain(status) }
    }
}
