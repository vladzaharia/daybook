import Foundation

/// The Mac app's preferences across the bundle ID change (`AppIdentity`): signed builds were `local.daybook.app` and are
/// `local.daybook` now, and a preferences domain is named after the bundle ID. At launch, before anything reads a setting
/// (`DaybookEntry`), the app's settings come over from the earlier domain, once: devices and recorders, model choices,
/// sync's device ID, installation, and state, the recorded iCloud account, folder bookmarks, and every other setting the
/// app wrote. Not the system's window and panel state.
///
/// Unsandboxed (Developer ID), the earlier domain is `~/Library/Preferences/local.daybook.app.plist`. Sandboxed (the App
/// Store build), the container migration manifest has moved that file into the container under the same name, where it
/// reads the same way (a probe showed it; docs/validation.md). The earlier domain is only read, never changed or removed,
/// so an earlier release opened again still finds its settings.
enum PreferencesCarryOver {
    /// Where this domain's settings came from, when, and how many, once they did.
    static let carriedKey = "preferencesCarriedOver"

    /// Copies `earlier`, the earlier domain's settings, into `defaults` when `defaults` shows no earlier use
    /// (`SandboxMigration.priorUseKeys`) and `earlier` holds a setting of the app's, then records it. Never twice, never
    /// over settings this app already has, and never touching `earlier`. Returns how many settings were copied.
    @discardableResult
    static func carryOver(_ earlier: [String: Any]?, from name: String, into defaults: UserDefaults, now: Date = Date()) -> Int {
        guard defaults.object(forKey: carriedKey) == nil, !SandboxMigration.preferencesShowPriorUse(defaults) else { return 0 }
        let settings = (earlier ?? [:]).filter { !LegacyLibraryReturn.systemKey($0.key) && $0.key != carriedKey }
        guard !settings.isEmpty else { return 0 }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defaults.set(["from": name, "at": now, "settings": settings.count] as [String: Any], forKey: carriedKey)
        return settings.count
    }

    /// The app's own preferences at launch: only for the app itself (`local.daybook`, bundled, with its own library),
    /// never a `--library` run, `swift run`, an ad hoc or rehearsal build, or tests.
    static func atLaunch(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        guard bundle.bundleIdentifier == AppIdentity.current, LaunchOptions.libraryURL == nil,
              LibraryLocation.folderName(bundleURL: bundle.bundleURL) == LibraryLocation.appFolder else { return }
        carryOver(defaults.persistentDomain(forName: AppIdentity.earlier), from: AppIdentity.earlier, into: defaults)
    }
}
