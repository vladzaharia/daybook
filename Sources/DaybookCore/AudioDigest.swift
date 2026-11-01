import CryptoKit
import Foundation

/// SHA-256 of recordings and photos as lowercase hex, streamed through CryptoKit so long recordings
/// are never loaded into memory. Sync's digests (`SyncDigest`) are these.
public enum AudioDigest {
    public static func sha256(fileURL: URL) throws -> String {
        try sha256(fileURL: fileURL) { Task.isCancelled }
    }

    /// The same, read on a queue of its own: neither the caller's actor nor Swift's cooperative
    /// threads wait on the disk. Cancelling the caller stops it between chunks.
    public static func sha256(contentsOf fileURL: URL) async throws -> String {
        try await BlockingFileWork.sha256(fileURL)
    }

    /// The same, checking `isCancelled` between chunks (work on a dispatch queue has no task to check). Each read is
    /// autoreleased and drained a chunk at a time, so hashing a long recording takes a megabyte of memory, not its size,
    /// on a queue whose pool would otherwise drain only when the whole file is done.
    static func sha256(fileURL: URL, isCancelled: () -> Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { return false }
            if isCancelled() { throw CancellationError() }
            hasher.update(data: bytes)
            return true
        }) {}
        return hasher.finalize().lowercaseHex
    }

    public static func sha256(data: Data) -> String { SHA256.hash(data: data).lowercaseHex }
}
