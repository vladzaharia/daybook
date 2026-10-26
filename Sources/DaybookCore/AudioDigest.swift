import CryptoKit
import Foundation

/// SHA-256 of recordings and photos as lowercase hex, streamed through CryptoKit so long recordings
/// are never loaded into memory. The same digests `SyncDigest` makes.
public enum AudioDigest {
    public static func sha256(fileURL: URL) throws -> String {
        try sha256(fileURL: fileURL) { Task.isCancelled }
    }

    /// The same, checking `isCancelled` between chunks (work on a dispatch queue has no task to check).
    static func sha256(fileURL: URL, isCancelled: () -> Bool) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(data: bytes)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(64)
        for byte in digest { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 0x0f)]) }
        return result
    }
}
