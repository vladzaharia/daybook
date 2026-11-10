import Darwin
import Foundation

/// How a recording in progress is kept on disk: its staging folder and everything in it (the segments, the journal,
/// photos taken while recording, the joined file) are class B, `FileProtectionType.completeUnlessOpen`. A locked
/// iPhone keeps writing the files already open and can make new ones, but can't open a closed one again until it's
/// unlocked, so Stop on a locked iPhone ends the capture and leaves joining and filing for the unlock
/// (`PhoneAppModel.finishAfterUnlock`). The files keep their class when the recording is filed. docs/iphone.md,
/// "File protection".
enum StagingProtection {
    static let type = FileProtectionType.completeUnlessOpen
    /// For a file written whole (the journal, a photo).
    static let writing: Data.WritingOptions = .completeFileProtectionUnlessOpen

    /// The file is there but can't be opened now: the iPhone is locked (`EPERM`), or the file isn't readable
    /// (`EACCES`). Never the same as a file with no audio in it.
    static func cannotOpen(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return false
        }
        return errno == EPERM || errno == EACCES
    }

    /// Every file in `folder` could be opened now, so what it holds is known: only then may a folder found to hold
    /// nothing go. False when the folder can't be listed.
    static func canReadAll(in folder: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return !names.contains { cannotOpen(folder.appendingPathComponent($0)) }
    }

    /// The error said a file couldn't be read for its protection or permissions (the iPhone locked), not that it's
    /// missing or damaged.
    static func isUnreadable(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isUnreadable(underlying) }
        return false
    }
}
