import Foundation
import Synchronization

/// Keeps extracted alignment features so a recording is decoded once, however many other sources
/// are aligned against it.
///
/// Memory entries are keyed by the file's SHA-256 when the caller knows it (every
/// `RecordingTrack` stores one), otherwise by path, size, and modification date. With a directory,
/// features also persist as `<sha256>-v<version>.features` (about 800 bytes per second of audio).
/// Features are derived data: they can't reproduce speech, and deleting them only costs a re-decode.
/// Keep the directory local; it doesn't need to sync.
public final class AudioFeatureCache: Sendable {
    public static let shared = AudioFeatureCache()

    public let directory: URL?
    private let capacity: Int
    /// Recently used last.
    private let memory = Mutex<(entries: [String: AudioFeatures], order: [String])>(([:], []))

    public init(directory: URL? = nil, capacity: Int = 8) {
        self.directory = directory; self.capacity = max(1, capacity)
    }

    /// Returns cached features or extracts them. `digest` is the file's SHA-256 when known.
    public func features(for url: URL, digest: String? = nil) throws -> AudioFeatures {
        let key = memoryKey(url: url, digest: digest)
        if let key, let cached = lookup(key) { return cached }
        if let digest = validDigest(digest), let fileURL = diskURL(digest),
           let data = try? Data(contentsOf: fileURL), let stored = AudioFeatures(serialized: data) {
            if let key { store(stored, key: key) }
            return stored
        }
        let extracted = try AudioFeatures.extract(from: url)
        if let key { store(extracted, key: key) }
        if let digest = validDigest(digest), let fileURL = diskURL(digest) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? extracted.serialized().write(to: fileURL, options: [.atomic])
        }
        return extracted
    }

    public func removeAll() {
        memory.withLock { $0 = ([:], []) }
    }

    private func lookup(_ key: String) -> AudioFeatures? {
        memory.withLock { memory in
            guard let value = memory.entries[key] else { return nil }
            memory.order.removeAll { $0 == key }; memory.order.append(key)
            return value
        }
    }

    private func store(_ value: AudioFeatures, key: String) {
        let capacity = capacity
        memory.withLock { memory in
            memory.entries[key] = value
            memory.order.removeAll { $0 == key }; memory.order.append(key)
            while memory.order.count > capacity { memory.entries.removeValue(forKey: memory.order.removeFirst()) }
        }
    }

    private func memoryKey(url: URL, digest: String?) -> String? {
        if let digest = validDigest(digest) { return "sha256:\(digest)" }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "file:\(url.standardizedFileURL.path):\(size):\(date.timeIntervalSinceReferenceDate)"
    }

    private func validDigest(_ digest: String?) -> String? {
        guard let digest, digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digest.lowercased()
    }

    private func diskURL(_ digest: String) -> URL? {
        directory?.appendingPathComponent("\(digest)-v\(AudioFeatures.currentVersion).features")
    }
}
