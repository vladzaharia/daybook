import Foundation

/// Where the Mac app keeps its library.
///
/// The app (a bundle) uses `Application Support/Daybook`: in the App Sandbox that's inside its container,
/// `~/Library/Containers/<bundle ID>/Data/Library/Application Support/Daybook`. An unbundled run (`swift run Daybook`,
/// `.build/debug/Daybook`) is never sandboxed, so it would open the person's real library beside the app. It uses
/// `Daybook Development` instead, with its own models, sync identity, and preferences domain.
enum LibraryLocation {
    static let appFolder = "Daybook"
    static let developmentFolder = "Daybook Development"

    /// The library folder's name for a process whose main bundle is at `bundleURL`.
    static func folderName(bundleURL: URL) -> String {
        bundleURL.pathExtension.lowercased() == "app" ? appFolder : developmentFolder
    }

    /// This process's library.
    static let standard: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(folderName(bundleURL: Bundle.main.bundleURL), isDirectory: true)
}
