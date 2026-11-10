import Darwin
import Foundation

/// A file's or folder's data protection class as the file system keeps it (`F_GETPROTECTIONCLASS`,
/// `F_SETPROTECTIONCLASS`), read and changed in place: the same on the iPhone and in the simulator, whose Foundation
/// leaves the class out of what it writes. A folder's class is the one files and folders made in it take. Changing a
/// file's class needs it readable, so a closed file kept until unlock can't be changed while the iPhone is locked.
enum ProtectionClass {
    /// The file system's numbers for the classes.
    private static let numbers: [FileProtectionType: Int32] = [
        .complete: 1, .completeUnlessOpen: 2, .completeUntilFirstUserAuthentication: 3, .none: 4]

    /// The class of the file or folder at `url`; nil when it can't be opened now (gone, or kept until unlock and the
    /// iPhone is locked) or has none.
    static func of(_ url: URL) -> FileProtectionType? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let number = fcntl(descriptor, F_GETPROTECTIONCLASS)
        return numbers.first { $0.value == number }?.key
    }

    /// Gives the file or folder at `url` `type`. Throws the file system's error: `EPERM` while a file kept until unlock
    /// can't be opened, `ENOENT` once it's gone.
    static func set(_ type: FileProtectionType, on url: URL) throws {
        guard let number = numbers[type] else { throw POSIXError(.EINVAL) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETPROTECTIONCLASS, number) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Gives `url` `type` unless it has it already. True when it has it now.
    @discardableResult
    static func ensure(_ type: FileProtectionType, on url: URL) -> Bool {
        if of(url) == type { return true }
        return (try? set(type, on: url)) != nil
    }

    /// The file at `url` is there but can't be opened now: the iPhone is locked (`EPERM`), or it isn't readable
    /// (`EACCES`). Never the same as a file that isn't there.
    static func cannotOpen(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if descriptor >= 0 {
            close(descriptor)
            return false
        }
        return errno == EPERM || errno == EACCES
    }
}
