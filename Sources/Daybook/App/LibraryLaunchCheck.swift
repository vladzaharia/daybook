import AppKit
import DaybookCore
import DaybookKit
import Foundation
import Observation

/// Where the library is at launch, and the move the person is offered when it's in the wrong place for this build
/// (docs/sandbox.md). It's checked first in `AppState.init`, before anything writes preferences or sync resolves its
/// identity (`check`); a library that moved gets this Mac's identity back (`ReplicaIdentity`). Then, for the app's own
/// library only: unsandboxed, whether to move it back out of the sandboxed build's container (`LegacyLibraryReturn`);
/// sandboxed, whether it's in place in the container (`SandboxMigration`), and once it's copied there, what becomes of
/// the old copy (`MovedLibrary`). The main window asks about it (`LibraryMoveSheet`), and the library doesn't open until
/// the person decides (`LibraryMoveOffer.holdsLibrary`).
@MainActor
@Observable
final class LibraryLaunchCheck {
    /// What the check found: a move to offer, or something to say once the library opens.
    struct Finding: Equatable {
        var offer: LibraryMoveOffer?
        var notice: String?
    }

    /// A library in the wrong place for this build: the library doesn't open until the person decides.
    var offer: LibraryMoveOffer?
    var isMoving = false
    var moveError: AppProblem?
    /// A library just copied into the container, before the person decides about the old copy.
    var moved: MovedLibrary?
    /// Said once the library opens (`AppState.initialize`).
    var notice: String?
    /// This Mac's preferences, which remember an old copy kept and a fresh start.
    @ObservationIgnored private let preferences: UserDefaults

    /// Checks `library` now.
    init(library: URL, defaults: UserDefaults) {
        preferences = defaults
        let finding = Self.check(library: library, defaults: defaults)
        offer = finding.offer
        notice = finding.notice
    }

    /// Where the library is, before anything writes preferences or sync resolves its identity (docs/sandbox.md). A
    /// library that moved gets this Mac's identity back (`ReplicaIdentity`). Then, for the app's own library only (never
    /// `--library`, `swift run`, or tests): unsandboxed, whether to move it back out of the sandboxed build's container
    /// (`LegacyLibraryReturn`); sandboxed, whether it's in place in the container (`SandboxMigration`).
    static func check(library: URL, defaults: UserDefaults, bundle: Bundle = .main,
                      sandboxed: Bool = SandboxEnvironment.isSandboxed) -> Finding {
        let priorUse = SandboxMigration.preferencesShowPriorUse(defaults)
        ReplicaIdentity.restore(library: library, defaults: defaults, machine: ReplicaIdentity.currentMachine)
        guard library.standardizedFileURL.path == LibraryLocation.standard.standardizedFileURL.path,
              LibraryLocation.folderName(bundleURL: bundle.bundleURL) == LibraryLocation.appFolder,
              let identifier = bundle.bundleIdentifier else { return Finding() }
        return check(library: library, bundleIdentifier: identifier, defaults: defaults, sandboxed: sandboxed, priorUse: priorUse)
    }

    static func check(library: URL, bundleIdentifier: String, defaults: UserDefaults, sandboxed: Bool, priorUse: Bool,
                      home: URL = UserHome.url,
                      store: (URL) -> SyncDeviceIdentityStore = { SyncDeviceIdentityStore.keychain(for: $0) }) -> Finding {
        guard sandboxed else {
            // Only the app itself goes back: its library is the old place its bundle ID's sandboxed build moved from.
            guard SandboxMigration.legacyFolderName(bundleIdentifier: bundleIdentifier) == library.lastPathComponent else { return Finding() }
            let plan = LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleIdentifier, home: home, defaults: defaults)
            return Finding(offer: plan.map { .returnFromContainer($0) })
        }
        guard let legacy = SandboxMigration.legacyLibrary(bundleIdentifier: bundleIdentifier, home: home) else { return Finding() }
        switch SandboxMigration.check(library: library, legacy: legacy, defaults: defaults, priorUse: priorUse, store: store) {
        case .fresh, .moved:
            return Finding()
        case .stillAtOldLocation:
            return Finding(offer: .moveIntoContainer(.init(legacy: legacy, library: library, legacyExists: LibraryContents.looksLikeLibrary(legacy))))
        case .bothPresent:
            guard defaults.string(forKey: SandboxMigration.keptOldCopyKey) != legacy.path else { return Finding() }
            return Finding(offer: .oldCopyRemains(legacy))
        case .identityMissing:
            return Finding(notice: "If your iPhone can’t find this Mac, pair it again in Settings › Devices.")
        }
    }

    /// Moves the library as offered. Back out of the container: moved, then the app starts over. Into the container: the
    /// person chooses the old library (the sandbox can read it only then), it's copied into place, and the sheet asks
    /// about the old copy (`finish`).
    func accept() {
        guard let offer, !isMoving else { return }
        moveError = nil
        switch offer {
        case .returnFromContainer(let plan):
            isMoving = true
            Task {
                do {
                    _ = try await detachedWork(priority: .userInitiated) { try LegacyLibraryReturn.move(plan) }
                    LegacyLibraryReturn.finish(plan, defaults: preferences)
                    AppRelaunch.relaunch()
                } catch {
                    isMoving = false
                    moveError = AppProblem(title: "Couldn’t Move Your Library", fallback: "Your library couldn’t be moved. Try again.", error: error)
                }
            }
        case .moveIntoContainer(let plan):
            guard let source = SandboxMigration.chooseLibrary(near: plan.legacy) else { return }
            isMoving = true
            let scoped = source.startAccessingSecurityScopedResource()
            Task {
                do {
                    try await detachedWork(priority: .userInitiated) { try SandboxMigration.copyLibrary(from: source, to: plan.library) }
                    moved = MovedLibrary(source: source, scoped: scoped, legacy: plan.legacy)
                } catch {
                    if scoped { source.stopAccessingSecurityScopedResource() }
                    moveError = AppProblem(title: "Couldn’t Move Your Library", fallback: "Your library couldn’t be moved. Try again.", error: error)
                }
                isMoving = false
            }
        case .oldCopyRemains(let legacy):
            NSWorkspace.shared.activateFileViewerSelecting([legacy])
            keepOldCopy(legacy)
        }
    }

    /// After a move into the container: the old copy goes to the Trash or stays, and the app starts over with the
    /// library in place.
    func finish(trashingOldCopy: Bool) {
        guard let moved else { return }
        var trashed = false
        if trashingOldCopy {
            trashed = (try? FileManager.default.trashItem(at: moved.source, resultingItemURL: nil)) != nil
            if !trashed { NSWorkspace.shared.activateFileViewerSelecting([moved.source]) }
        }
        if !trashed { preferences.set(moved.legacy.path, forKey: SandboxMigration.keptOldCopyKey) }
        if moved.scoped { moved.source.stopAccessingSecurityScopedResource() }
        AppRelaunch.relaunch()
    }

    /// Not Now (or Quit, Start Fresh, Keep It), depending on the offer. Returns whether the library may open now: the
    /// offer is answered, and nothing waits for the person any more (`AppState.declineLibraryMove`).
    func decline() -> Bool {
        guard let offer, !isMoving else { return false }
        switch offer {
        case .returnFromContainer(let plan): LegacyLibraryReturn.decline(plan, defaults: preferences)
        case .moveIntoContainer(let plan):
            // With a library at the old place, nothing opens without it; with none there, start a new one.
            guard !plan.legacyExists else { NSApp.terminateFromRunLoop(); return false }
            preferences.set(true, forKey: SandboxMigration.startedFreshKey)
        case .oldCopyRemains(let legacy):
            keepOldCopy(legacy)
            return false
        }
        self.offer = nil
        return true
    }

    private func keepOldCopy(_ legacy: URL) {
        preferences.set(legacy.path, forKey: SandboxMigration.keptOldCopyKey)
        offer = nil
    }
}
