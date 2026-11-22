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

    /// Adds each clip's file to a publication's assets. A file this replica holds whole is uploaded (again, if its object
    /// went); one it lacks (an on-demand replica never fetches clips) or holds damaged is published by reference to the
    /// object, only while the sync folder has it. One whose object is nowhere is left out of the event: the conversation
    /// still names it, and still publishes (a missing clip never holds a conversation back); a Mac that holds it whole
    /// uploads it again (`hydrate`). A record this version can't read names nothing here.
    func appendVoiceClipAssets(_ meeting: Meeting, directory: URL, journalAssets: Set<String>,
                               assets: inout [SyncAsset], byReference: inout Set<String>) throws {
        for clip in meeting.voiceClips ?? [] where clip.unread == nil {
            try Task.checkCancellation()
            guard clip.isStored(in: meeting.id) else { throw LibrarySyncError.invalidBlob(clip.relativePath) }
            let url = try LocalFiles.relativeURL(clip.relativePath, in: directory)
            try SyncFiles.noSymlinks(url, below: localRoot)
            if try verified(url, digest: clip.sha256) {
                // Uploaded below.
            } else if hasRemoteObject(clip.sha256) {
                byReference.insert(clip.relativePath)
            } else {
                continue
            }
            let asset = SyncAsset(relativePath: clip.relativePath, sha256: clip.sha256)
            if !assets.contains(asset) { assets.append(asset) }
        }
    }

    /// The format of every clip: under `Originals/VoiceClips/`, at the path its source and whole digest give. Not that
    /// the event lists it: a Daybook that keeps `voiceClips` as an unknown key publishes edits without its assets, and a
    /// clip whose object is nowhere is left out. A record this version can't read isn't checked: it names nothing here.
    func validateVoiceClipAssets(_ snapshot: Meeting) throws {
        for clip in snapshot.voiceClips ?? [] where clip.unread == nil && !clip.isStored(in: snapshot.id) {
            throw LibrarySyncError.invalidBlob(clip.relativePath)
        }
    }

    /// The assets a merged snapshot's clips need: what an eager replica installs when they're here (never waiting for
    /// one, `hydrate`), and what the sealer counts as live (`mergedAssets`).
    nonisolated func voiceClipAssets(of meeting: Meeting) -> [SyncAsset] {
        (meeting.voiceClips ?? []).filter { $0.isStored(in: meeting.id) }.map { SyncAsset(relativePath: $0.relativePath, sha256: $0.sha256) }
    }

    /// The objects clip records this version can't read (a newer Daybook's shape) say they are, by their path and digest:
    /// live for the sealer too, so a key rotation never retires a clip only a newer version reads (one that's nowhere never
    /// keeps the sealer from finishing).
    nonisolated func unreadVoiceClipAssets(of meeting: Meeting) -> [SyncAsset] {
        (meeting.voiceClips ?? []).compactMap { clip in
            guard let path = clip.unreadPath, case .object(let fields)? = clip.unread, case .string(let sha256)? = fields["sha256"],
                  SyncFiles.isHash(sha256) else { return nil }
            return SyncAsset(relativePath: path, sha256: sha256)
        }
    }

    /// A clip's asset: one that never holds its conversation back.
    nonisolated static func isVoiceClip(_ asset: SyncAsset) -> Bool { asset.relativePath.hasPrefix(VoiceClip.folder + "/") }

    /// An eager replica's clip: installed when its object is here whole; when it isn't (not downloaded yet, or gone: a
    /// Daybook from before clips that seals may have deleted it), its download is asked for and the conversation applies
    /// without it, so this Mac doesn't hold it and the source stays uncovered here (its original is kept) until a later
    /// pass installs it. One this Mac holds whole whose object is nowhere is uploaded again. True when it's here whole.
    func hydrateVoiceClip(_ asset: SyncAsset, at destination: URL, in directory: URL, warnings: inout [String]) throws -> Bool {
        if try verified(destination, digest: asset.sha256) {
            // Never as plaintext into a library that's encrypted where this device can't seal yet.
            if !hasRemoteObject(asset.sha256), sealing != nil || (waitingForKey == nil && !syncedSealedLibraryHere) {
                do { try upload(asset, from: destination) } catch let error as CancellationError { throw error } catch {}
            }
            return true
        }
        let object = remoteObject(asset.sha256)
        guard SyncFiles.itemState(object.url) == .local else {
            if SyncFiles.itemState(object.url) == .inCloud { try? cloud.requestDownload(object.url) }
            return false
        }
        do {
            try LocalFiles.directory(destination.deletingLastPathComponent())
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            guard try copyPlaintext(object.url, of: object, below: remoteRoot, libraryID: libraryID, to: temporary, expected: asset.sha256) == asset.sha256 else {
                return false
            }
            try install(temporary, at: destination, in: directory, warnings: &warnings)
            verifiedAssets[destination.path] = try assetStamp(destination, digest: asset.sha256)
            noteContainerCopy(String(object.url.standardizedFileURL.path.dropFirst(remoteRoot.path.count + 1)), holding: asset.sha256)
            return true
        } catch let error as CancellationError {
            throw error
        } catch {
            // Damaged, or unreadable here: the conversation applies without it.
            return false
        }
    }

    /// Whether there's anything to seal a clip from: its file held whole here, or its object in the sync folder (under a
    /// key held here, or plaintext) or a courier's delivery.
    func voiceClipIsAnywhere(_ asset: SyncAsset, meetingID: UUID) -> Bool {
        let directory = localRoot.appendingPathComponent("Meetings/\(meetingID.uuidString)", isDirectory: true)
        if let local = try? LocalFiles.relativeURL(asset.relativePath, in: directory), (try? verified(local, digest: asset.sha256)) == true { return true }
        return hasRemoteObject(asset.sha256) || courierObject(asset.sha256) != nil
    }

    /// The paths of the clips this device's applied copy of a conversation names (what other devices' unpublished edits
    /// may build on): a clip file no clip names any more is kept while they do.
    public func voiceClipFilesInHistory(of meetingID: UUID) -> Set<String> {
        Set(base(meetingID.uuidString)?.voiceClips?.map(\.relativePath) ?? [])
    }
}
