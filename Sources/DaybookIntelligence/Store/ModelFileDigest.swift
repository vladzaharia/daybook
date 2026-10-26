import CryptoKit
import DaybookKit
import Foundation

/// Verifies a downloaded file against its manifest entry: the size, then SHA-256 when the manifest
/// has it (Hugging Face LFS files), else the git blob ID (SHA-1 over "blob <size>\0" and the
/// content, which is what Hugging Face publishes for small files). Files are streamed in chunks.
/// An entry with neither can't be checked, so its file is never trusted (`noDigest`).
enum ModelFileDigest {
    enum Failure: Error, Equatable {
        case missing, wrongSize(expected: Int64, actual: Int64), wrongDigest, noDigest
    }

    static func verify(_ url: URL, against file: ModelFile, checkContent: Bool = true) throws {
        let size: Int64
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.missing }
            size = Int64(values.fileSize ?? -1)
        } catch let failure as Failure { throw failure }
        catch { throw Failure.missing }
        guard size == file.size else { throw Failure.wrongSize(expected: file.size, actual: size) }
        guard checkContent else { return }
        if let expected = file.sha256 {
            guard try sha256(url) == expected else { throw Failure.wrongDigest }
        } else if let expected = file.gitOID {
            guard try gitBlobID(url, size: size) == expected else { throw Failure.wrongDigest }
        } else {
            throw Failure.noDigest
        }
    }

    static func sha256(_ url: URL) throws -> String {
        var hasher = SHA256()
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func gitBlobID(_ url: URL, size: Int64) throws -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        try stream(url) { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func stream(_ url: URL, _ body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 * 1_024 * 1_024) } ?? Data()
            if chunk.isEmpty { break }
            body(chunk)
        }
    }
}
