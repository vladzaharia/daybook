import AppKit
import DaybookCore
import DaybookKit
import Foundation

/// The sandboxed app's launch check: is the library where this build keeps it, in the container (docs/sandbox.md,
/// "Moving the library")?
///
/// macOS moves the library into the container once, through the migration manifest, when it creates the container.
/// Every other case comes here: a container created by an earlier sandboxed launch (so the manifest never ran), a
/// manifest that couldn't move the library, or a library copied rather than moved. The check runs at the top of
/// `AppState.init`, before anything writes preferences or sync resolves its identity, and a library that isn't in
/// place stays closed (no devices, sync, or requests) until the person moves it or starts fresh.
enum SandboxMigration {
    enum Outcome: String, Codable, Equatable {
        /// Nothing here, nothing at the old place, no earlier use: a new library.
        case fresh
        /// The library is in the container and the old place is empty.
        case moved
        /// The container's library is empty but the old place holds one (or preferences say there was one): move it.
        case stillAtOldLocation
        /// Both hold a library: this one is used; the old copy stays readable by other apps until it's removed.
        case bothPresent
        /// The library is here, but this Mac's sync identity couldn't be found: sync takes a new one, and a paired
        /// iPhone may need pairing again.
        case identityMissing
    }

    struct Facts: Equatable {
        /// The old place (`~/Library/Application Support/Daybook`) holds a library.
        var legacyExists: Bool
        /// The container's library holds something worth keeping (`LibraryContents.hasContent`).
        var containerHasContent: Bool
        /// Preferences show an earlier launch (they came along with the library, or were copied).
        var preferencesShowPriorUse: Bool
        /// This Mac's sync identity was found: preferences, the keychain, or `Sync/replica.json`.
        var identityKnown: Bool
    }

    static func classify(_ facts: Facts) -> Outcome {
        if facts.containerHasContent {
            if facts.legacyExists { return .bothPresent }
            return facts.identityKnown ? .moved : .identityMissing
        }
        return facts.legacyExists || facts.preferencesShowPriorUse ? .stillAtOldLocation : .fresh
    }

    /// The library folder an unsandboxed build of this app used, by bundle ID: the app's real library for the app
    /// (`local.daybook`, and `local.daybook.app` before it: `AppIdentity`), the rehearsal's synthetic one for
    /// `local.daybook.rehearsal…` (or `local.daybook.app.rehearsal…`), and none for anything else (ad hoc builds never
    /// look at a library outside their own container).
    static func legacyFolderName(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier else { return nil }
        if bundleIdentifier == AppIdentity.current || bundleIdentifier == AppIdentity.earlier { return LibraryLocation.appFolder }
        if bundleIdentifier.hasPrefix(AppIdentity.rehearsalPrefix) || bundleIdentifier.hasPrefix(AppIdentity.earlier + ".rehearsal") {
            return "Daybook Rehearsal"
        }
        return nil
    }

    static func legacyLibrary(bundleIdentifier: String?, home: URL = UserHome.url) -> URL? {
        legacyFolderName(bundleIdentifier: bundleIdentifier).map {
            home.appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent($0, isDirectory: true)
        }
    }

    /// Settings only an earlier launch writes. Read before this launch writes any.
    static func preferencesShowPriorUse(_ defaults: UserDefaults) -> Bool {
        priorUseKeys.contains { defaults.object(forKey: $0) != nil }
    }

    static let priorUseKeys = ["onboardingCompleted", ReplicaIdentity.Key.deviceID, "modelSelections", "processingPreferences"]

    static let outcomeKey = "sandboxMigration"
    /// Preferences said there was a library, none was at the old place, and the person chose to start fresh.
    static let startedFreshKey = "sandboxStartedFresh"
    /// The old place's path once the person chose to keep the copy there; not asked again for it.
    static let keptOldCopyKey = "sandboxOldCopyKept"

    /// Classifies the launch and, first, finds this Mac's identity for the library: when sync's keychain item is still
    /// under the old place's name, it's copied to the new one (the keychain item never leaves this Mac, so it's always
    /// this Mac's). Records the outcome. Call after `ReplicaIdentity.restore` and before `LibrarySyncController`.
    static func check(library: URL, legacy: URL, defaults: UserDefaults, priorUse: Bool,
                      store: (URL) -> SyncDeviceIdentityStore = { SyncDeviceIdentityStore.keychain(for: $0) }, now: Date = Date()) -> Outcome {
        var identityKnown = store(library).read() != nil
        if !identityKnown, let previous = store(legacy).read() {
            ReplicaIdentity.adopt(previous, for: library, defaults: defaults, store: store)
            identityKnown = true
        }
        identityKnown = identityKnown || defaults.string(forKey: ReplicaIdentity.Key.deviceID) != nil
        let legacyExists = LibraryContents.looksLikeLibrary(legacy)
        let outcome = classify(Facts(legacyExists: legacyExists, containerHasContent: LibraryContents.hasContent(library),
                                     preferencesShowPriorUse: priorUse && !(defaults.bool(forKey: startedFreshKey) && !legacyExists),
                                     identityKnown: identityKnown))
        if (defaults.dictionary(forKey: outcomeKey)?["outcome"] as? String) != outcome.rawValue {
            defaults.set(["outcome": outcome.rawValue, "at": now, "legacy": legacy.path], forKey: outcomeKey)
        }
        return outcome
    }

    /// What `.stillAtOldLocation` offers: choose the old library (the sandbox can read it only once the person does)
    /// and copy it into place.
    struct MovePlan: Equatable {
        /// Where the old library is expected; the panel opens beside it.
        var legacy: URL
        /// Where this build keeps its library, in the container.
        var library: URL
        /// The old place holds a library (otherwise preferences alone said there was one).
        var legacyExists: Bool
    }

    enum MoveError: LocalizedError, Equatable {
        case notALibrary(String)
        case libraryNotEmpty
        case copyMismatch(String)
        var errorDescription: String? {
            switch self {
            case .notALibrary(let name): return "“\(name)” isn’t a Daybook library."
            case .libraryNotEmpty: return "There’s already a library here."
            case .copyMismatch(let path): return "The copy didn’t match the original (\(path)). Nothing was changed."
            }
        }
    }

    /// Copies `source` into `library`: an APFS clone on the same volume (fast, and no extra space), checked file by file
    /// (every path, kind, and size) before it's renamed into place. `source` is only read. An empty folder at `library`
    /// (what a held launch may leave) is replaced; one with anything in it is never touched.
    static func copyLibrary(from source: URL, to library: URL) throws {
        let fm = FileManager.default
        guard LibraryContents.looksLikeLibrary(source) else { throw MoveError.notALibrary(source.lastPathComponent) }
        guard !LibraryContents.hasContent(library) else { throw MoveError.libraryNotEmpty }
        let parent = library.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(library.lastPathComponent)-moving-\(UUID().uuidString)", isDirectory: true)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        try fm.copyItem(at: source, to: staging)
        let original = try inventory(source), copy = try inventory(staging)
        if original != copy {
            let differing = Set(original.keys).symmetricDifference(copy.keys).sorted().first
                ?? original.keys.sorted().first { original[$0] != copy[$0] } ?? "?"
            throw MoveError.copyMismatch(differing)
        }
        if fm.fileExists(atPath: library.path) {
            // Empty scaffolding only (checked above): set aside if it holds any file at all, else removed.
            if try inventory(library).values.contains(where: { $0 >= 0 }) {
                try fm.moveItem(at: library, to: LibraryContents.asideURL(for: library, label: "Before Move", now: Date()))
            } else {
                try fm.removeItem(at: library)
            }
        }
        try fm.moveItem(at: staging, to: library)
    }

    /// Every item under `root` by relative path: a file's size, -1 for a folder, -2 for a symbolic link (never followed).
    static func inventory(_ root: URL) throws -> [String: Int64] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root.path) else { return [:] }
        var items: [String: Int64] = [:]
        while let relative = enumerator.nextObject() as? String {
            let attributes = try fm.attributesOfItem(atPath: root.appendingPathComponent(relative).path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: items[relative] = -1
            case .typeSymbolicLink?: items[relative] = -2
            default: items[relative] = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return items
    }

    /// An open panel beside the old library: the sandbox can read it only once the person chooses it.
    @MainActor static func chooseLibrary(near legacy: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose your Daybook library"
        panel.prompt = "Move Library"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = legacy.deletingLastPathComponent()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
