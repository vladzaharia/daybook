import Foundation
#if os(macOS)
import Darwin
#endif

/// The person's own home folder, and the folders in it Daybook suggests.
///
/// In the App Sandbox, `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` are the app's container
/// (`~/Library/Containers/<bundle ID>/Data`), so a path built from them (iCloud Drive, a suggested import folder)
/// points into the container instead. On the Mac this reads the account's home from the user database, which is the
/// same in and out of the sandbox. On iPhone there's only the app's own home.
public enum UserHome {
    /// `/Users/<name>`, sandboxed or not.
    public static let url: URL = resolve(accountHome: accountHome(), fallback: NSHomeDirectory())

    /// `~/Library/Mobile Documents`, where iCloud Drive and apps' iCloud containers live on a Mac.
    public static var mobileDocuments: URL { url.appendingPathComponent("Library/Mobile Documents", isDirectory: true) }

    /// iCloud Drive as Finder shows it: `~/Library/Mobile Documents/com~apple~CloudDocs`.
    public static var iCloudDrive: URL { mobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true) }

    /// The account's home from the user database; nil when it can't be read.
    static func accountHome() -> String? {
        #if os(macOS)
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
        #else
        return nil
        #endif
    }

    /// The account's home when it's a usable absolute path, else `fallback` (`NSHomeDirectory()`).
    static func resolve(accountHome: String?, fallback: String) -> URL {
        if let accountHome, accountHome.hasPrefix("/"), accountHome != "/" {
            return URL(fileURLWithPath: accountHome, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: fallback, isDirectory: true).standardizedFileURL
    }
}
