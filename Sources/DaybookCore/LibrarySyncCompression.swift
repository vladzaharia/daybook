import Foundation

/// What Compress Older Recordings asks of sync (docs/icloud-sync.md, "Compressed recordings").
extension LibrarySyncEngine {
    /// The presence feature saying a device knows compressed recordings: it merges a compressed track's file as one
    /// (`RecordingCompression.merged`), recognises a recording by its original's bytes, and lets a superseded original go.
    /// A Mac compresses only while every device seen in the last 30 days lists it.
    public static let compressionFeature = "compress-1"

    /// Whether iCloud holds the object with this SHA-256 (sealed under a key held here, or plaintext) and reports it
    /// uploaded: what letting a file go on the strength of iCloud's copy asks (an original, here or from iCloud, for its
    /// compressed copy or its voice clips). False for anything not there yet, and for a name that isn't a SHA-256. In a
    /// sync folder in iCloud Drive only the provider's own yes counts: an item it can't answer for (an error, or not
    /// called an iCloud item, as when the container detached after the person signed out) isn't uploaded. Elsewhere (a
    /// folder that isn't iCloud's), a file that's there is.
    public func isObjectUploaded(_ sha256: String) -> Bool {
        guard SyncFiles.isHash(sha256) else { return false }
        let object = remoteObject(sha256)
        guard SyncFiles.itemState(object.url) != .absent else { return false }
        if cloud.isICloudFolder(remoteRoot) { return cloud.uploadState(object.url) == true }
        return cloud.isUploaded(object.url)
    }

    /// Conversations whose superseded originals (`TrackEncoding.previousSHA256`) must stay in iCloud for voice profiles
    /// (`LibraryController.meetingsHoldingOriginalsInICloud`: a voiceprint learned from them whose clip isn't confirmed in
    /// iCloud). The sealer counts each one's as live, so rotating keys seals it again rather than retiring it, by the same
    /// rule anything else that lets a superseded original go from iCloud follows. Nil (not said yet, or a device that
    /// can't say): every one counts, as does any conversation the library didn't judge (`judged`: one that arrives in the
    /// pass).
    public func holdOriginalsInICloud(for meetings: Set<UUID>?, judged: Set<UUID> = []) {
        originalsHeldForVoice = meetings.map { (held: $0, judged: judged) }
    }

    /// The library is encrypted here: its sealer decides which objects stay (`holdOriginalsInICloud`).
    public var sealsObjects: Bool { sealing != nil }

    /// The sealer's live objects: `live`, with each held conversation's superseded originals (`holdOriginalsInICloud`),
    /// and those originals' digests (`optional`: one already gone everywhere never keeps the sealer from finishing).
    func withOriginalsHeldForVoice(_ live: [UUID: [SyncAsset]], meetings: [UUID: Meeting]) -> (assets: [UUID: [SyncAsset]], optional: Set<String>) {
        var assets = live, optional = Set<String>()
        for (id, current) in live {
            let held = originalsHeldForVoice.map { $0.held.contains(id) || !$0.judged.contains(id) } ?? true
            guard held, let meeting = meetings[id] else { continue }
            let superseded = meeting.tracks.compactMap { track -> SyncAsset? in
                guard let encoding = track.encoding, SyncFiles.isHash(encoding.previousSHA256), encoding.previousRelativePath.hasPrefix("Originals/"),
                      encoding.previousRelativePath != track.relativePath else { return nil }
                return SyncAsset(relativePath: encoding.previousRelativePath, sha256: encoding.previousSHA256)
            }.filter { !current.contains($0) }
            guard !superseded.isEmpty else { continue }
            assets[id] = current + superseded
            optional.formUnion(superseded.map(\.sha256).filter { sha in !current.contains { $0.sha256 == sha } })
        }
        return (assets, optional)
    }

    /// Whether this device's clock looks more than a week ahead of the others' (compaction's `clockLooksAhead`): a Mac
    /// whose clock is ahead would take a recent conversation for an old one.
    public func compressionClockLooksAhead(now: Date = Date()) -> Bool { clockLooksAhead(now: now) }

    /// Whether every other device seen in the last 30 days compresses (`compressionFeature`). False while a presence
    /// record can't be read yet, as for compaction.
    public func everyRecentDeviceCompresses(now: Date = Date()) -> Bool {
        guard let others = recentPresence(now: now) else { return false }
        return others.allSatisfy { ($0.features ?? []).contains(Self.compressionFeature) }
    }
}
