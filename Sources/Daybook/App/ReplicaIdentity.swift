import CryptoKit
import DaybookCore
import DaybookKit
import Foundation
import IOKit

/// This Mac's identity in the sync journal and on the link, kept with the library too, in `Sync/replica.json` (never
/// synchronized), so it survives the library moving: into the App Sandbox's container, or back out of it.
///
/// The identity normally lives in a this-device-only keychain item named after the library's folder
/// (`SyncDeviceIdentityStore.keychain(for:)`), mirrored in preferences. A sandboxed Mac's library and preferences are
/// in its container, so after the move the keychain item is under the old folder's name and the preferences may not
/// have come along. Without this, the Mac would take a new device ID: it would republish its library (safely, but in
/// full) and every paired iPhone would have to pair again, since the link's device ID is the sync device ID.
///
/// The file is trusted only on the Mac that wrote it (a digest of the hardware UUID), so a library copied to another
/// Mac (a backup, a manual copy) never brings this Mac's identity with it; that Mac takes its own, as before.
struct ReplicaIdentity: Codable, Equatable {
    static let formatName = "DaybookReplicaIdentity"
    var format = Self.formatName
    var schemaVersion = 1
    var syncDeviceID: String
    var installation: String
    var linkDeviceID: String
    /// Where the library was when this was written.
    var libraryPath: String
    /// `machineDigest()` of the Mac that wrote it.
    var machine: String
    var savedAt: Date

    /// The preferences `LibrarySyncController` and `AppState.linkIdentity` keep the identity in.
    enum Key {
        static let deviceID = "syncDeviceID"
        static let installation = "syncInstallation"
        static let identityStored = "syncDeviceIDInKeychain"
        static let linkDeviceID = "linkDeviceID"
    }

    static func url(in library: URL) -> URL {
        library.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent("replica.json")
    }

    static func read(in library: URL) -> ReplicaIdentity? {
        guard let data = try? Data(contentsOf: url(in: library)),
              let identity = try? decoder.decode(ReplicaIdentity.self, from: data),
              identity.format == formatName, identity.schemaVersion == 1 else { return nil }
        return identity
    }

    /// Records the identity the app resolved, when it changed. A failure is ignored: this is a safety net.
    static func save(_ identity: ReplicaIdentity, in library: URL) {
        if let existing = read(in: library), existing.isSame(as: identity) { return }
        guard let data = try? encoder.encode(identity) else { return }
        let url = url(in: library)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? DurableFiles.write(data, to: url)
    }

    /// Everything but when it was written.
    func isSame(as other: ReplicaIdentity) -> Bool {
        var other = other
        other.savedAt = savedAt
        return self == other
    }

    enum Restored: Equatable {
        /// Nothing to do: no file, written on another Mac, or the library hasn't moved.
        case unchanged
        /// The library moved since the file was written; its identity is where the app looks for it again.
        case restored(deviceID: String)
    }

    /// Call before `LibrarySyncController` resolves the identity. When `library` moved since `Sync/replica.json` was
    /// written on this Mac, puts that identity back where the controller looks: this Mac's keychain item for the new
    /// folder (or preferences, in builds without a keychain), and the link's device ID. A library that hasn't moved is
    /// left alone: its keychain item and preferences are the live state.
    @discardableResult
    static func restore(library: URL, defaults: UserDefaults, machine: String?,
                        store: (URL) -> SyncDeviceIdentityStore = { SyncDeviceIdentityStore.keychain(for: $0) }) -> Restored {
        guard let saved = read(in: library), let machine, saved.machine == machine,
              saved.libraryPath != library.standardizedFileURL.path else { return .unchanged }
        let identity = StoredSyncIdentity(deviceID: saved.syncDeviceID, installation: saved.installation)
        adopt(identity, for: library, defaults: defaults, store: store)
        if defaults.string(forKey: Key.linkDeviceID) == nil, UUID(uuidString: saved.linkDeviceID) != nil {
            defaults.set(saved.linkDeviceID, forKey: Key.linkDeviceID)
        }
        return .restored(deviceID: saved.syncDeviceID)
    }

    /// Makes `identity` the one `LibrarySyncController` resolves for `library`.
    static func adopt(_ identity: StoredSyncIdentity, for library: URL, defaults: UserDefaults,
                      store: (URL) -> SyncDeviceIdentityStore) {
        let keychain = store(library)
        if keychain.read() != identity {
            if keychain.write(identity) {
                defaults.set(true, forKey: Key.identityStored)
            } else {
                // No keychain in this build: preferences hold it, and must not claim the keychain does.
                defaults.removeObject(forKey: Key.identityStored)
                defaults.set(identity.installation, forKey: Key.installation)
            }
        }
        defaults.set(identity.deviceID, forKey: Key.deviceID)
    }

    /// A digest of this Mac's hardware UUID, so the file is recognized only where it was written; nil when it can't be
    /// read. The UUID itself is never stored.
    static let currentMachine: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return machineDigest(uuid)
    }()

    static func machineDigest(_ hardwareUUID: String) -> String {
        SHA256.hash(data: Data("local.daybook.replica:\(hardwareUUID)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
