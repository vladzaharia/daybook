import DaybookKit
import Foundation

/// What iPhone backups (iCloud and computer) hold of Daybook. Copies it can rebuild never go in: the
/// courier's inbox and outbox (iCloud Drive carries the same files), audio downloaded for playback (it
/// downloads again), audio being copied in, and files other apps handed over (`Documents/Inbox`).
/// Exports wait in tmp, which backups skip. The library itself goes in unless Settings › Storage ›
/// Include in iPhone Backups is off; then the whole library folder stays out.
enum BackupExclusion {
    /// Folders that never go into a backup.
    static func rebuildableFolders(libraryRoot: URL, inbox: URL) -> [URL] {
        [libraryRoot.appendingPathComponent("Sync/Inbox", isDirectory: true),
         libraryRoot.appendingPathComponent("Sync/Courier", isDirectory: true),
         libraryRoot.appendingPathComponent("Staging/Imports", isDirectory: true),
         inbox]
    }

    /// Applies the rules to what exists now. Safe to repeat: at launch, and when the setting changes.
    static func apply(libraryRoot: URL, inbox: URL, includesLibrary: Bool) {
        set(libraryRoot, excluded: !includesLibrary)
        for folder in rebuildableFolders(libraryRoot: libraryRoot, inbox: inbox) { set(folder, excluded: true) }
    }

    /// Audio downloaded for playback, wherever the library keeps it.
    static func excludeDownloads(_ cached: [CachedAudio], libraryRoot: URL) {
        for audio in cached where audio.origin == .fetched {
            set(audioURL(meetingID: audio.meetingID, relativePath: audio.relativePath, libraryRoot: libraryRoot), excluded: true)
        }
    }

    static func audioURL(meetingID: UUID, relativePath: String, libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true).appendingPathComponent(relativePath)
    }

    static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    static func set(_ url: URL, excluded: Bool) {
        guard FileManager.default.fileExists(atPath: url.path), isExcluded(url) != excluded else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        var url = url
        try? url.setResourceValues(values)
    }
}
