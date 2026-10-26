import DaybookKit
import Foundation

/// What iPhone backups (iCloud and computer) hold of Daybook. Copies it can rebuild never go in: the
/// courier's inbox and outbox (iCloud Drive carries the same files), audio downloaded for playback (it
/// downloads again), audio being copied in, and files other apps handed over (`Documents/Inbox`).
/// Exports wait in tmp, which backups skip. The library itself goes in unless Settings › Storage ›
/// Include in iPhone Backups is off; then the whole library folder stays out.
///
/// An encrypted library (docs/icloud-sync.md, "Encryption") has a choice of its own, off unless the person turns it on:
/// its conversations, Trash, sync state, and saved captions (`Meetings/`, `Trash/`, `Sync/`, `LiveCaptions/`) stay out,
/// because the sealed journal in iCloud is their backup and a backup isn't encrypted end to end. A choice made for the
/// plaintext library doesn't carry over as on, so turning encryption on never leaves plaintext in backups unless the
/// person turns it on again; turned off there, the whole folder stays out as before. See docs/iphone.md, "Backups".
enum BackupExclusion {
    /// What a backup holds of the library.
    enum Library: Equatable {
        /// All of it (copies Daybook can rebuild aside).
        case whole
        /// None of it: the whole library folder stays out.
        case none
        /// All but an encrypted library's `encryptedLibraryFolders`.
        case withoutEncryptedFolders
    }

    /// From the choices in Settings › Storage, and whether the library is encrypted.
    static func library(includesLibrary: Bool, encrypted: Bool, includesEncryptedLibrary: Bool) -> Library {
        guard encrypted else { return includesLibrary ? .whole : .none }
        if includesEncryptedLibrary { return .whole }
        return includesLibrary ? .withoutEncryptedFolders : .none
    }

    /// An encrypted library's folders that stay out unless the person includes it.
    static func encryptedLibraryFolders(libraryRoot: URL) -> [URL] {
        ["Meetings", "Trash", "Sync", "LiveCaptions"].map { libraryRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// Folders that never go into a backup.
    static func rebuildableFolders(libraryRoot: URL, inbox: URL) -> [URL] {
        [libraryRoot.appendingPathComponent("Sync/Inbox", isDirectory: true),
         libraryRoot.appendingPathComponent("Sync/Courier", isDirectory: true),
         libraryRoot.appendingPathComponent("Staging/Imports", isDirectory: true),
         inbox]
    }

    /// Applies the rules to what exists now. Safe to repeat: at launch, when a setting changes, when the library's
    /// encryption changes, and after a sync pass (which may have made a folder).
    static func apply(libraryRoot: URL, inbox: URL, library: Library) {
        set(libraryRoot, excluded: library == .none)
        for folder in encryptedLibraryFolders(libraryRoot: libraryRoot) { set(folder, excluded: library == .withoutEncryptedFolders) }
        for folder in rebuildableFolders(libraryRoot: libraryRoot, inbox: inbox) { set(folder, excluded: true) }
    }

    /// A plaintext library's rules: all of it, or none.
    static func apply(libraryRoot: URL, inbox: URL, includesLibrary: Bool) {
        apply(libraryRoot: libraryRoot, inbox: inbox, library: includesLibrary ? .whole : .none)
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
