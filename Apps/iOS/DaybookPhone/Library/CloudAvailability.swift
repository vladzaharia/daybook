import Foundation

/// Whether the library's iCloud container can be reached, so the interface can say so plainly.
///
/// Sync lives in the app's own ubiquity container, named by Info.plist's
/// `DaybookICloudContainerIdentifier`; DaybookKit's `LibrarySyncController` resolves
/// `url(forUbiquityContainerIdentifier:)/Documents/Daybook` from the same key. The phone shell only
/// reports availability. Unsigned simulator builds and phones without iCloud Drive land in
/// `.unavailable`, and recording keeps working: recordings stay on the phone until sync can run.
enum CloudAvailability: Equatable, Sendable {
    case checking
    /// The library's folder inside the container.
    case available(URL)
    case unavailable(String)

    static let infoKey = "DaybookICloudContainerIdentifier"

    static let unsetMessage = "iCloud isn't set up for this build."

    static var containerIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
    }

    var isAvailable: Bool { if case .available = self { return true } else { return false } }

    /// The sentence the interface shows; nil when there's nothing to say.
    var message: String? {
        switch self {
        case .checking, .available: return nil
        case .unavailable(let reason): return reason
        }
    }

    /// Resolves the container off the main thread, as `url(forUbiquityContainerIdentifier:)` requires.
    static func check(container: String? = containerIdentifier,
                      signedIn: @Sendable () -> Bool = { FileManager.default.ubiquityIdentityToken != nil },
                      resolve: @escaping @Sendable (String) -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: $0) }) async -> CloudAvailability {
        guard let container, !container.isEmpty, !container.contains("$(") else {
            return .unavailable(unsetMessage)
        }
        guard signedIn() else {
            return .unavailable("Sign in to iCloud Drive to sync your recordings.")
        }
        let url = await Task.detached(priority: .utility) { resolve(container) }.value
        guard let url else {
            return .unavailable("Turn on iCloud Drive for Daybook in Settings to sync your recordings.")
        }
        return .available(url.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Daybook", isDirectory: true))
    }
}
