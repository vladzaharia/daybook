import DaybookCore
import Foundation
import OSLog

/// Where making a voice clip can be stopped by a crash, in order (tests stop it at each one).
public enum VoiceClipStep: Sendable {
    /// The clip is cut, checked, and flushed, hidden in `VoiceClips/`.
    case cut
    /// The clip is at its own name; the index doesn't name it yet, so nothing relies on it.
    case placed
}

/// Voice clips on this Mac (`VoiceClips`; docs/architecture.md, "Compressing older recordings"): the speech each voice
/// profile learned from, cut losslessly from the original before the original may be replaced or let go, so a voiceprint
/// can always be made again from what it was learned from. Kept in `VoiceClips/` beside the conversations, never synced:
/// every Mac cuts its own from the original it holds, and lets that original go only once it has them.
extension LibraryController {
    private static let clipLog = Logger(subsystem: "local.daybook", category: "voice-clips")

    var voiceClipsFolder: URL { rootURL.appendingPathComponent(VoiceClips.folderName, isDirectory: true) }
    private var voiceClipIndexURL: URL { voiceClipsFolder.appendingPathComponent(VoiceClips.indexName) }

    /// The index of this Mac's clips: empty when there's none yet, nil when there is one this version can't read (damaged,
    /// or a newer Daybook's), and then no clip is relied on, written, or deleted.
    public func voiceClipIndex() -> VoiceClipIndex? {
        let url = voiceClipIndexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceClipIndex() }
        guard let data = try? Data(contentsOf: url), let index = try? JSONDecoder().decode(VoiceClipIndex.self, from: data),
              index.version == VoiceClipIndex().version else { return nil }
        return index
    }

    private func saveVoiceClipIndex(_ index: VoiceClipIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFiles.write(try encoder.encode(index), to: voiceClipIndexURL)
    }

    /// Sources (by key) whose clip is here as it was checked: the index names it, and its file still has the stamp it had
    /// when its bytes were last found to be the clip's (`LibraryController.stamp`).
    public func coveredVoiceSources() -> Set<String> {
        guard let index = voiceClipIndex() else { return [] }
        let folder = voiceClipsFolder
        return Set(index.clips.filter { key, clip in
            clip.source.key == key && Self.stamp(folder.appendingPathComponent(clip.fileName)) == clip.stamp
        }.keys)
    }

    /// What the library's voice profiles need kept, with conversations in the Trash (`lineage`) to find a voiceprint's
    /// recording by its speaker.
    public func voiceClipPlan(lineage: [Meeting] = []) -> VoiceClips.Plan {
        VoiceClips.plan(metadata: metadata, meetings: meetings + lineage)
    }

    /// The voiceprints that hold their recordings back now (`VoiceClips.holdingBack`): what a compression pass gives
    /// `RecordingCompressionPlanner` as `voiceprints`.
    public func holdingBackVoiceprints(lineage: [Meeting] = []) -> [Voiceprint] {
        let all = meetings + lineage
        return VoiceClips.holdingBack(VoiceClips.plan(metadata: metadata, meetings: all), metadata: metadata, meetings: all,
                                      covered: coveredVoiceSources())
    }

    /// Conversations whose recordings stay as captured for voice profiles: what a voiceprint without its clip here
    /// learned from, followed through merges, moves, and the same bytes (`RecordingCompressionPlanner.learnedFrom`).
    /// With them, what to compare once more with nothing awaited (`voiceProtectionUnchanged`).
    func voiceProtectedMeetings() async -> (meetings: Set<UUID>, mark: [String]) {
        let lineage = await trashedMeetings()
        let protected = RecordingCompressionPlanner.learnedFrom(meetings, voiceprints: holdingBackVoiceprints(lineage: lineage), lineage: lineage)
        return (protected, voiceProtectionMark)
    }

    /// The voiceprints holding recordings back, found without the Trash (so a few more): it changes whenever a clip
    /// comes or goes, or the voiceprints change.
    private var voiceProtectionMark: [String] { holdingBackVoiceprints().map(\.id).sorted() }

    /// Nothing voice protection depends on changed since `mark` was taken.
    func voiceProtectionUnchanged(_ mark: [String]) -> Bool { voiceProtectionMark == mark }

    // MARK: Making clips

    /// The clip a change didn't keep as it was.
    struct VoiceClipChanged: LocalizedError {
        var errorDescription: String? { "The recording or its voice clip changed while the clip was made." }
    }

    /// Cuts the clips voice profiles need (`VoiceClips.Plan.wanted`) that aren't here, from each recording's lossless
    /// original: the track's file, or, once it was compressed, the original it replaced while it's still here. Only for
    /// recordings that may soon be replaced or let go: a compressed one, or one in a conversation whose last activity is
    /// before `cutoff` (nil: compressed ones only). The original is hashed against the track first and must be unchanged
    /// (its stamp) after the cut; the clip is checked sample by sample against it (`VoiceClipAudio.extract`), placed under a
    /// name of its own, hashed again, and only then named in the index, durably. A clip whose file's stamp changed is
    /// hashed again and trusted again when its bytes are the same. At most `limit` recordings are read; `shouldContinue`
    /// stops it between recordings. Anything that fails leaves the recording held back as before. Returns clips made.
    @discardableResult
    public func makeVoiceClips(olderThan cutoff: Date?, limit: Int = 3, shouldContinue: () -> Bool = { true }) async -> Int {
        guard isLoaded, let store, voiceClipIndex() != nil else { return 0 }
        voiceClipsInFlight += 1
        defer { voiceClipsInFlight -= 1 }
        await rehashMovedClips()
        let plan = voiceClipPlan(lineage: await trashedMeetings())
        guard plan.readable else { return 0 }
        let covered = coveredVoiceSources()
        let wanted = Dictionary(grouping: plan.wanted.filter { !covered.contains($0.key) }.values) { "\($0.meetingID.uuidString)|\($0.trackID.uuidString)" }
        var made = 0, read = 0
        for group in wanted.keys.sorted() {
            guard read < limit, shouldContinue(), !Task.isCancelled, let first = wanted[group]?.first,
                  let meeting = meeting(first.meetingID), let track = meeting.tracks.first(where: { $0.id == first.trackID }) else { continue }
            let due = track.isCompressed || cutoff.map { RecordingCompressionEligibility.lastActivity(of: meeting) <= $0 } == true
            let original: (path: String, sha256: String) = track.encoding.map { ($0.previousRelativePath, $0.previousSHA256) }
                ?? (track.relativePath, track.sha256)
            let jobs = (wanted[group] ?? []).sorted { $0.key < $1.key }.map { ($0, VoiceClips.spans(for: $0, in: meeting)) }.filter { !$0.1.isEmpty }
            guard due, !original.sha256.isEmpty, !jobs.isEmpty,
                  let url = try? await store.audioURL(for: RecordingTrack(relativePath: original.path, fileName: ""), in: meeting.id),
                  SyncFilesProbe.isRegularFile(url) else { continue }
            read += 1
            guard let stamp = Self.stamp(url), (try? await AudioDigest.sha256(contentsOf: url)) == original.sha256 else {
                Self.clipLog.error("No voice clips from \(track.id.uuidString, privacy: .public): its original isn't the recording's bytes")
                continue
            }
            for (source, spans) in jobs {
                if await makeVoiceClip(source, spans: spans, from: url, stamp: stamp, originalSHA256: original.sha256) { made += 1 }
            }
        }
        return made
    }

    private func makeVoiceClip(_ source: VoiceClipSource, spans: [VoiceClipSpan], from url: URL, stamp: [Int64], originalSHA256: String) async -> Bool {
        let folder = voiceClipsFolder
        var cutURL: URL?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let cut = try await VoiceClipAudio.extract(from: url, spans: spans, into: folder)
            cutURL = cut.url
            try voiceClipFault?(.cut)
            // What was cut is what was hashed.
            guard Self.stamp(url) == stamp else { throw VoiceClipChanged() }
            // Named by its source and its bytes: a clip cut again never takes the name of other bytes the index may name.
            let name = "\(source.key).\(cut.sha256.prefix(16)).caf"
            let destination = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: cut.url, to: destination)
            } else if (try? await AudioDigest.sha256(contentsOf: destination)) == cut.sha256 {
                try FileManager.default.removeItem(at: cut.url)
            } else {
                // A file under this name that isn't these bytes is a damaged copy of them, relied on for nothing (its
                // stamp isn't the one checked): the clip cut again takes its place.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: cut.url)
            }
            cutURL = nil
            try DurableFiles.synchronize([destination, folder])
            try voiceClipFault?(.placed)
            guard let clipStamp = Self.stamp(destination), (try? await AudioDigest.sha256(contentsOf: destination)) == cut.sha256 else {
                throw VoiceClipChanged()
            }
            // Nothing awaited from here to the index naming it, which it does last: until then nothing relies on it.
            guard Self.stamp(destination) == clipStamp, var index = voiceClipIndex() else { throw VoiceClipChanged() }
            index.clips[source.key] = VoiceClip(source: source, fileName: name, sha256: cut.sha256, size: cut.size, originalSHA256: originalSHA256,
                                                sampleRate: cut.sampleRate, channels: cut.channels, ranges: cut.ranges, createdAt: Date(),
                                                stamp: clipStamp)
            try saveVoiceClipIndex(index)
            Self.clipLog.info("Kept a voice clip of \(source.trackID.uuidString, privacy: .public): \(cut.size) bytes")
            return true
        } catch {
            if let cutURL { try? FileManager.default.removeItem(at: cutURL) }
            if !(error is CancellationError) {
                Self.clipLog.error("No voice clip from \(source.trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    /// Clips whose file's stamp changed since it was checked (a restore from a backup, a copy of the library) are hashed
    /// again, and trusted again with their new stamp when their bytes are still the clip's.
    private func rehashMovedClips() async {
        guard let index = voiceClipIndex() else { return }
        let folder = voiceClipsFolder
        for (key, clip) in index.clips.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(clip.fileName)
            guard let stamp = Self.stamp(url), stamp != clip.stamp, (try? await AudioDigest.sha256(contentsOf: url)) == clip.sha256,
                  Self.stamp(url) == stamp, var current = voiceClipIndex(), current.clips[key] == clip else { continue }
            current.clips[key]?.stamp = stamp
            try? saveVoiceClipIndex(current)
        }
    }

    // MARK: Letting clips go

    /// The one place a voice clip is deleted. A clip goes `VoiceClips.orphanGrace` after no voiceprint of a profile that
    /// still exists names its source (the profile deleted, or the speaker taken out of it: removed, forgotten, renamed
    /// to a placeholder, Not <name>); a voiceprint naming it again before then (an Undo, on any device) keeps it. Only
    /// while every profile and voiceprint record can be read and the index can be (else nothing goes), and, with
    /// `deleting` false (at launch, before sync has brought the library's settings), not at all. Files in `VoiceClips/`
    /// the index doesn't name (a clip cut before a crash, an earlier cut of one cut again, a temporary) rely on nothing
    /// and go too, while no clip is being made. Returns how many clips (by the index) were deleted.
    @discardableResult
    public func reconcileVoiceClips(now: Date = Date(), deleting: Bool = true) async -> Int {
        let folder = voiceClipsFolder
        guard isLoaded, FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        await acquireLock()
        defer { releaseLock() }
        let plan = deleting ? voiceClipPlan(lineage: await trashedMeetings()) : nil
        // From here, nothing is awaited: no clip can be started, placed, or named in the index meanwhile.
        guard voiceClipsInFlight == 0, var index = voiceClipIndex() else { return 0 }
        var deleted = 0, changed = false
        if let plan, plan.readable {
            for key in index.clips.keys.sorted() {
                guard var clip = index.clips[key] else { continue }
                if plan.live.contains(key) {
                    if clip.orphanedAt != nil { clip.orphanedAt = nil; index.clips[key] = clip; changed = true }
                    continue
                }
                guard let since = clip.orphanedAt else { clip.orphanedAt = now; index.clips[key] = clip; changed = true; continue }
                guard now >= since.addingTimeInterval(VoiceClips.orphanGrace) else { continue }
                let url = folder.appendingPathComponent(clip.fileName)
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    index.clips[key] = nil
                    changed = true
                    deleted += 1
                } catch {
                    Self.clipLog.error("Kept a voice clip: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if changed {
            do { try saveVoiceClipIndex(index) } catch { Self.clipLog.error("Couldn't save the voice clip index: \(error.localizedDescription, privacy: .public)") }
        }
        let named = Set(index.clips.values.map(\.fileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where !named.contains(name) && (name.hasPrefix(VoiceClips.temporaryPrefix) || (name.hasSuffix(".caf") && !name.hasPrefix("."))) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        try? DurableFiles.synchronize([folder])
        return deleted
    }

    // MARK: Reading a voiceprint's speech

    /// The speech a voiceprint would be made again from (a new voice model's space, a voiceprint checked against what it
    /// was learned from), by its speaker's passages: the lossless original while it's here (the track's file, or the
    /// original a compressed copy replaced, not yet let go), else the voiceprint's clip when it's here as it was checked.
    /// Nil when neither is: only a lossy copy is left, and a voiceprint isn't made from that.
    public struct VoiceSample: Equatable, Sendable {
        public var url: URL
        /// The speaker's passages in `url`, in seconds.
        public var spans: [VoiceClipSpan]
        public var isClip: Bool
    }

    public func voiceSample(for print: Voiceprint) async -> VoiceSample? {
        let conversation = meeting(print.meetingID)
        guard let source = VoiceClips.source(of: print, in: conversation) else { return nil }
        if let conversation, let track = conversation.tracks.first(where: { $0.id == source.trackID }) {
            let spans = VoiceClips.spans(for: source, in: conversation)
            let path = track.encoding?.previousRelativePath ?? track.relativePath
            if !spans.isEmpty, let url = try? await audioURL(for: RecordingTrack(relativePath: path, fileName: ""), in: conversation.id),
               SyncFilesProbe.isRegularFile(url) {
                return VoiceSample(url: url, spans: spans, isClip: false)
            }
        }
        guard coveredVoiceSources().contains(source.key), let clip = voiceClipIndex()?.clips[source.key] else { return nil }
        return VoiceSample(url: voiceClipsFolder.appendingPathComponent(clip.fileName), spans: clip.spansInClip, isClip: true)
    }
}
