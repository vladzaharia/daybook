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
    /// Sync can't run, in a sentence: one of `Reason`'s, or another the sync controller gave.
    case unavailable(String)

    /// Why `check` found iCloud unavailable, each with its sentence.
    enum Reason: CaseIterable, Equatable, Sendable {
        /// The build has no iCloud container (an unsigned or simulator build): nothing in Settings fixes it.
        case notSetUp
        /// Nobody is signed in to iCloud.
        case signedOut
        /// iCloud Drive is off for Daybook.
        case iCloudDriveOff

        var sentence: String {
            switch self {
            case .notSetUp: return "iCloud isn’t set up for this build."
            case .signedOut: return "Sign in to iCloud to sync your library."
            case .iCloudDriveOff: return "Turn on iCloud Drive for Daybook in Settings."
            }
        }

        /// Settings can fix it (signing in, or iCloud Drive for Daybook); a build without iCloud can't.
        var settingsCanFix: Bool { self != .notSetUp }

        /// The reason a sentence says, when it's one of these.
        init?(sentence: String) {
            guard let reason = Self.allCases.first(where: { $0.sentence == sentence }) else { return nil }
            self = reason
        }
    }

    static let infoKey = "DaybookICloudContainerIdentifier"

    static let unsetMessage = Reason.notSetUp.sentence
    static let signedOutMessage = Reason.signedOut.sentence
    static let iCloudDriveOffMessage = Reason.iCloudDriveOff.sentence

    static var containerIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
    }

    var isAvailable: Bool { if case .available = self { return true } else { return false } }

    /// Why it's unavailable, when it's one of `check`'s reasons.
    var reason: Reason? {
        if case .unavailable(let sentence) = self { return Reason(sentence: sentence) }
        return nil
    }

    /// Settings can fix it (signing in, or iCloud Drive for Daybook); a build without iCloud can't. A
    /// sentence the sync controller gave is taken as one Settings may fix.
    var settingsCanFix: Bool {
        guard case .unavailable = self else { return false }
        return reason?.settingsCanFix ?? true
    }

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
            return .unavailable(Reason.notSetUp.sentence)
        }
        guard signedIn() else {
            return .unavailable(Reason.signedOut.sentence)
        }
        let url = await Task.detached(priority: .utility) { resolve(container) }.value
        guard let url else {
            return .unavailable(Reason.iCloudDriveOff.sentence)
        }
        return .available(url.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("Daybook", isDirectory: true))
    }
}
