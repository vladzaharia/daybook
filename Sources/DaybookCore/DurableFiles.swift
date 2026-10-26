import Darwin
import Foundation

/// Writes that survive a crash or power loss, for the few moments that need it: before a recording's
/// staging folder is deleted and before a sync pass is acknowledged (`MeetingStore.synchronizeWrites`).
/// Ordinary saves stay atomic but aren't flushed; the barrier flushes everything written since the
/// last one at once.
public enum DurableFiles {
    /// Replaces `url` with `data` atomically and durably: the bytes reach storage before the rename,
    /// and the rename is flushed with its folder. The file is user-only. For checkpoints and other
    /// small files that must never go back to an older version after they're written.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError(temporary) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw posixError(temporary) }
                    offset += written
                }
            }
            try fullSync(descriptor, temporary)
            close(descriptor)
        } catch { close(descriptor); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw posixError(url) }
        try synchronize([directory])
    }

    /// Flushes files and folders already written to permanent storage: each is fsynced, then the
    /// drive's own cache is flushed once (`F_FULLFSYNC`), which covers everything before it. A path
    /// that no longer exists (moved to the Trash, replaced since) is skipped.
    public static func synchronize(_ urls: [URL]) throws {
        var last: (Int32, URL)?
        defer { if let last { close(last.0) } }
        for url in urls {
            let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT || errno == ENOTDIR { continue }
                throw posixError(url)
            }
            if fsync(descriptor) != 0 { let error = posixError(url); close(descriptor); throw error }
            if let previous = last { close(previous.0) }
            last = (descriptor, url)
        }
        if let (descriptor, url) = last { try fullSync(descriptor, url) }
    }

    /// `F_FULLFSYNC`, or `fsync` where the file system doesn't offer it.
    private static func fullSync(_ descriptor: Int32, _ url: URL) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw posixError(url) }
    }

    private static func posixError(_ url: URL) -> Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue),
                       userInfo: [NSFilePathErrorKey: url.path, NSLocalizedDescriptionKey: String(cString: strerror(code.rawValue))])
    }
}

/// What identifies one version of a file without reading it: its inode (an atomic replace makes a
/// new one), size, and modification time. Two equal stamps are the same bytes for the store's cache.
struct FileStamp: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var seconds: Int
    var nanoseconds: Int

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        inode = UInt64(info.st_ino); size = Int64(info.st_size)
        seconds = Int(info.st_mtimespec.tv_sec); nanoseconds = Int(info.st_mtimespec.tv_nsec)
    }
}

/// Long, blocking file work (copying and hashing originals) on its own queue, so neither the store's
/// actor nor Swift's cooperative threads wait on the disk. Cancelling the caller stops the work at its
/// next check of `isCancelled`.
enum BlockingFileWork {
    private static let queue = DispatchQueue(label: "app.daybook.file-work", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try work(flag.isSet) }) }
            }
        } onCancel: { flag.set() }
    }

    /// The SHA-256 of a file, stopping between chunks once cancelled.
    static func sha256(_ url: URL) async throws -> String {
        try await run { isCancelled in try AudioDigest.sha256(fileURL: url, isCancelled: isCancelled) }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
