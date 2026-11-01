import Foundation

/// The Mac app's bundle IDs (docs/release.md, "Bundle IDs").
///
/// Every signed build is `local.daybook`, the same bundle ID as the iPhone app: the Developer ID download (unsandboxed)
/// and the App Store and TestFlight build (sandboxed) alike. One App Store Connect record ships the iPhone and Mac apps
/// only when they share one (universal purchase). Signed Mac builds before it were `local.daybook.app`; the app carries
/// their preferences over at launch (`PreferencesCarryOver`), reads their keychain items through the group they used,
/// and finds their library where it was. Ad hoc and rehearsal builds keep IDs of their own (`local.daybook.adhoc`,
/// `local.daybook.rehearsal…`), so they never create the app's container.
enum AppIdentity {
    static let current = "local.daybook"
    /// Every signed Mac build before the one bundle ID.
    static let earlier = "local.daybook.app"
    static let adhoc = "local.daybook.adhoc"
    static let rehearsalPrefix = "local.daybook.rehearsal"
    /// The Mac app's executable. The iPhone app, run on a Mac under the same bundle ID, is `DaybookPhone`.
    static let executable = "Daybook"

    /// Whether a process is a copy of the Mac app, whichever build: the release, an earlier release, ad hoc, a rehearsal
    /// (under the current IDs or the earlier ones), or the unbundled `swift run` binary.
    static func isMacApp(bundleID: String?, executableName: String?) -> Bool {
        guard let bundleID else { return executableName == executable }
        if bundleID == current { return executableName == executable }
        return bundleID == adhoc || bundleID.hasPrefix(rehearsalPrefix)
            || bundleID == earlier || bundleID.hasPrefix(earlier + ".")
    }

    /// The containers a sandboxed build of the app with `bundleIdentifier` may have left the library in: for the app,
    /// its own and the earlier ID's (a sandboxed build from before the one bundle ID); for any other build, its own.
    static func containers(for bundleIdentifier: String) -> [String] {
        bundleIdentifier == current ? [current, earlier] : [bundleIdentifier]
    }
}
