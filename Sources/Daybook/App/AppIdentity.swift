import Foundation

/// The Mac app's bundle IDs (docs/release.md, "Bundle IDs").
///
/// Unsandboxed signed builds (Developer ID, Apple Development) are `local.daybook.app`, as every Mac build was before
/// the App Store. Sandboxed signed builds (the App Store and TestFlight build, and Developer ID with `--sandbox`) share
/// the iPhone app's bundle ID, `local.daybook.phone`: one App Store Connect record ships both apps only when they share
/// one (universal purchase). A sandboxed app's container is named after its bundle ID, so every sandboxed build of the
/// app keeps its library in the same one, `~/Library/Containers/local.daybook.phone`. Ad hoc and rehearsal builds keep
/// IDs of their own (`local.daybook.app.adhoc`, `local.daybook.app.rehearsal…`), so they never create it.
enum AppIdentity {
    static let unsandboxed = "local.daybook.app"
    static let sandboxed = "local.daybook.phone"
    /// The Mac app's executable under either ID. The iPhone app run on a Mac would be `DaybookPhone`.
    static let executable = "Daybook"

    /// The containers a sandboxed build of the app with `bundleIdentifier` may have left the library in: for the
    /// unsandboxed app, the sandboxed builds' (`sandboxed`) and its own, from a sandboxed build under its own ID; for any
    /// other build, its own.
    static func containers(for bundleIdentifier: String) -> [String] {
        bundleIdentifier == unsandboxed ? [sandboxed, unsandboxed] : [bundleIdentifier]
    }
}
