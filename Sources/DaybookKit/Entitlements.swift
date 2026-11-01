#if os(macOS)
import Foundation
import Security

/// What the running Mac app is signed with: its sandbox, iCloud containers, keychain groups. Read from the code
/// signature, so an unsigned, ad hoc, or test build reads what it actually has (often nothing). iOS has no API for
/// this; a build that runs on an iPhone is signed with the project's entitlements.
public enum Entitlements {
    /// The entitlement's value as signed, or nil when the app doesn't have it.
    public static func value(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

    /// A list entitlement's strings ("com.apple.developer.icloud-container-identifiers"); empty without it.
    public static func strings(_ key: String) -> [String] {
        value(key) as? [String] ?? []
    }

    /// A switch entitlement ("com.apple.security.app-sandbox"); false without it.
    public static func bool(_ key: String) -> Bool {
        value(key) as? Bool == true
    }
}
#endif
