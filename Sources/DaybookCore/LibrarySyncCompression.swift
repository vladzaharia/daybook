import Foundation

/// What Compress Older Recordings asks of sync (docs/icloud-sync.md, "Compressed recordings").
extension LibrarySyncEngine {
    /// The presence feature saying a device knows compressed recordings: it merges a compressed track's file as one
    /// (`RecordingCompression.merged`), recognises a recording by its original's bytes, and lets a superseded original go.
    /// A Mac compresses only while every device seen in the last 30 days lists it.
    public static let compressionFeature = "compress-1"

    /// Whether iCloud holds the object with this SHA-256 (sealed under a key held here, or plaintext) and reports it
    /// uploaded. False for anything not there yet, and for a name that isn't a SHA-256.
    public func isObjectUploaded(_ sha256: String) -> Bool {
        guard SyncFiles.isHash(sha256) else { return false }
        let object = remoteObject(sha256)
        return SyncFiles.itemState(object.url) != .absent && cloud.isUploaded(object.url)
    }

    /// Whether every other device seen in the last 30 days compresses (`compressionFeature`). False while a presence
    /// record can't be read yet, as for compaction.
    public func everyRecentDeviceCompresses(now: Date = Date()) -> Bool {
        guard let others = recentPresence(now: now) else { return false }
        return others.allSatisfy { ($0.features ?? []).contains(Self.compressionFeature) }
    }
}
