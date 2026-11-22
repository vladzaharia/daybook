import Foundation

// Voice clips ride the journal the way notebook pages' drawings do (docs/icloud-sync.md, "Voice clips"): each clip a
// conversation names (`Meeting.voiceClips`) is a content-addressed object in `Blobs/` (sealed in an encrypted library),
// listed in the event's assets under its library path (`Originals/VoiceClips/<source key>-<sha16>.caf`). An eager
// replica (a Mac) copies and verifies them before the conversation applies, and the sealer counts them as live
// (`mergedAssets`); an on-demand replica (the iPhone) never needs them and publishes them by reference. A Daybook from
// before clips keeps `voiceClips` as an unknown key and lists no clip assets, so validation checks formats only.

extension LibrarySyncEngine {
    /// The presence feature saying a device keeps voice clips: it syncs them with their conversations, hydrates them,
    /// seals them, and counts them as live. A Mac relies on a clip in a synced library only while every device seen in
    /// the last 30 days lists it (`everyRecentDeviceKeepsVoiceClips`).
    public static let voiceClipFeature = "voiceclip-1"

    /// Whether every other device seen in the last 30 days keeps voice clips (`voiceClipFeature`). False while a
    /// presence record can't be read yet.
    public func everyRecentDeviceKeepsVoiceClips(now: Date = Date()) -> Bool {
        guard let others = recentPresence(now: now) else { return false }
        return others.allSatisfy { ($0.features ?? []).contains(Self.voiceClipFeature) }
    }

    /// Adds each clip's file to a publication's assets. A file this replica holds whole is uploaded; one it lacks (an
    /// on-demand replica never fetches clips) or holds damaged is published by reference to the object already in the
    /// journal or `Blobs/`, which the pass that applies it copies back (`hydrate`). Nothing to name means the clip is gone.
    func appendVoiceClipAssets(_ meeting: Meeting, directory: URL, journalAssets: Set<String>,
                               assets: inout [SyncAsset], byReference: inout Set<String>) throws {
        for clip in meeting.voiceClips ?? [] {
            try Task.checkCancellation()
            guard clip.isStored(in: meeting.id) else { throw LibrarySyncError.invalidBlob(clip.relativePath) }
            let url = try LocalFiles.relativeURL(clip.relativePath, in: directory)
            try SyncFiles.noSymlinks(url, below: localRoot)
            if try verified(url, digest: clip.sha256) {
                // Uploaded below.
            } else if try mayPublishByReference(clip.sha256, journalAssets: journalAssets) {
                byReference.insert(clip.relativePath)
            } else {
                throw LibrarySyncError.missingLocalAudio((clip.relativePath as NSString).lastPathComponent)
            }
            let asset = SyncAsset(relativePath: clip.relativePath, sha256: clip.sha256)
            if !assets.contains(asset) { assets.append(asset) }
        }
    }

    /// The format of every clip: under `Originals/VoiceClips/`, at the path its source and whole digest give. Not that
    /// the event lists it: a Daybook that keeps `voiceClips` as an unknown key publishes edits without its assets.
    func validateVoiceClipAssets(_ snapshot: Meeting) throws {
        for clip in snapshot.voiceClips ?? [] where !clip.isStored(in: snapshot.id) {
            throw LibrarySyncError.invalidBlob(clip.relativePath)
        }
    }

    /// The assets a merged snapshot's clips need: what an eager replica hydrates before the conversation applies, and
    /// what the sealer counts as live (`mergedAssets`).
    nonisolated func voiceClipAssets(of meeting: Meeting) -> [SyncAsset] {
        (meeting.voiceClips ?? []).filter { $0.isStored(in: meeting.id) }.map { SyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) }
    }

    /// The paths of the clips this device's applied copy of a conversation names (what other devices' unpublished edits
    /// may build on): a clip file no clip names any more is kept while they do.
    public func voiceClipFilesInHistory(of meetingID: UUID) -> Set<String> {
        Set(base(meetingID.uuidString)?.voiceClips?.map(\.relativePath) ?? [])
    }
}
