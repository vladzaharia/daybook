import CloudKit
import Foundation

/// Whether an iCloud account is signed in on this Mac, to tell "signed out" from "iCloud Drive is off" when there's no
/// ubiquity identity (`SyncContainerEnvironment.accountSignedIn`). CloudKit answers for the app's own container, which
/// works in the App Sandbox; the Apple Account list in another domain's preferences, read before, doesn't.
enum ICloudAccountCheck {
    /// The account status of `containerIdentifier`'s container; nil (unknown) when this build isn't signed for CloudKit
    /// with it (creating a `CKContainer` without the entitlement stops the app), or when CloudKit can't tell.
    static func signedIn(containerIdentifier: String?) async -> Bool? {
        guard let identifier = SyncContainerEnvironment.valid(containerIdentifier), CloudKitCourier.isEntitled(for: identifier) else { return nil }
        do { return signedIn(try await CKContainer(identifier: identifier).accountStatus()) } catch { return nil }
    }

    /// Available: signed in (so with no ubiquity identity, iCloud Drive is off). No account: signed out. Anything else
    /// (restricted, couldn't be determined, temporarily unavailable): unknown.
    static func signedIn(_ status: CKAccountStatus) -> Bool? {
        switch status {
        case .available: return true
        case .noAccount: return false
        case .restricted, .couldNotDetermine, .temporarilyUnavailable: return nil
        @unknown default: return nil
        }
    }
}
