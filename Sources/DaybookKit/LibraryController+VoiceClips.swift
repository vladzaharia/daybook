import DaybookCore
import Foundation
import OSLog

/// Where making a voice clip can be stopped by a crash, in order (tests stop it at each one).
public enum VoiceClipStep: Sendable {
    /// The clip is cut, checked, and flushed, hidden in its conversation's `Originals/VoiceClips/`.
    case cut
    /// The clip is at its own name; its conversation doesn't name it yet, so nothing relies on it.
    case placed
}

/// A moment by this Mac's continuous clock (`mach_continuous_time`, which counts through sleep and can't be set) and the
/// boot it counts from: what the day a clip no voiceprint names waits is measured with too, as a compression pass's
/// clock is (`RecordingCompressionClock`). An empty boot compares nothing.
public struct VoiceClipClock: Sendable {
    public var boot: String
    public var seconds: TimeInterval

    public init(boot: String, seconds: TimeInterval) { self.boot = boot; self.seconds = seconds }

    public static let unknown = VoiceClipClock(boot: "", seconds: 0)
}

/// Voice clips (`VoiceClips`; docs/architecture.md, "Voice clips"): the speech each voice profile learned from, cut
/// losslessly from the original into its conversation's folder before the original may be replaced or let go, named by
/// the conversation (`Meeting.voiceClips`) and synced with it, so a voiceprint can always be made again from what it was
/// learned from, on any Mac of the library. A Mac relies on a clip it holds whole (checked by its bytes, then by its
/// stamp) whose passages are the speaker's now; in a synced library, only while every device in use keeps clips, and,
/// to let an original go, only once iCloud holds the clip too.
extension LibraryController {
    private static let clipLog = Logger(subsystem: "local.daybook", category: "voice-clips")

    // MARK: This Mac's record of its clips

    /// `voice-clips.json` beside the library, never synced: which clip files this Mac found whole, which it checked
    /// against its own original, the clips no voiceprint names and since when, and the sources it couldn't cut.
    public struct VoiceClipState: Codable, Equatable, Sendable {
        public var version = 1
        /// By `<conversation ID>/<relative path>`: the digest the file was found to have, its stamp
        /// (`LibraryController.stamp`) then, and the record that named it. A clip is relied on only while its file still
        /// has that stamp; the record names it again if a Daybook from before clips dropped it (`reconcileVoiceClips`).
        public var verified: [String: Verified] = [:]
        /// By `<conversation ID>/<relative path>`: what this Mac's own cut of the clip's frames from its own original gave
        /// (or that it cut the clip itself). An original goes on the strength of a clip only once it matched here.
        public var checked: [String: Checked] = [:]
        /// By source key: when no voiceprint named its clip, by the wall clock and the continuous clock.
        public var orphaned: [String: Orphaned] = [:]
        /// By source key (or `check|<conversation ID>/<relative path>` for a check): what cutting its clip came to, so a
        /// source that can't be cut doesn't take a pass's place.
        public var attempts: [String: Attempts] = [:]

        public struct Verified: Codable, Equatable, Sendable {
            public var sha256: String
            public var stamp: [Int64]
            public var record: VoiceClip?
        }

        public struct Checked: Codable, Equatable, Sendable {
            /// The clip's SHA-256 when it was checked.
            public var sha256: String
            /// This Mac's cut gave the same bytes (or this Mac cut it).
            public var matches: Bool
        }

        public struct Orphaned: Codable, Equatable, Sendable {
            public var since: Date
            public var boot: String
            public var seconds: TimeInterval
        }

        public struct Attempts: Codable, Equatable, Sendable {
            /// What it was tried with: the original's SHA-256 and the frames of its passages.
            public var basis: String
            /// It can't be cut from this original (more channels than a clip keeps, its passages past the file's end):
            /// not tried again until the original or the passages change.
            public var refused: Bool?
            /// Failures that may not happen another time (reading, a hash that didn't match, the disk), in a row, and the
            /// last one's date: it waits `failureWait` before it's tried again.
            public var failures: Int?
            public var lastFailure: Date?
        }

        public init() {}

        private enum CodingKeys: String, CodingKey { case version, verified, checked, orphaned, attempts }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            verified = try values.decodeIfPresent([String: Verified].self, forKey: .verified) ?? [:]
            checked = try values.decodeIfPresent([String: Checked].self, forKey: .checked) ?? [:]
            orphaned = try values.decodeIfPresent([String: Orphaned].self, forKey: .orphaned) ?? [:]
            attempts = try values.decodeIfPresent([String: Attempts].self, forKey: .attempts) ?? [:]
        }
    }

    private var voiceClipStateURL: URL { rootURL.appendingPathComponent("voice-clips.json") }

    /// This Mac's record of its clips: empty when there's none yet, nil when there is one this version can't read
    /// (damaged, or a newer Daybook's), and then no clip is relied on, cut, or deleted.
    public func voiceClipState() -> VoiceClipState? {
        let url = voiceClipStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceClipState() }
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(VoiceClipState.self, from: data),
              state.version == VoiceClipState().version else { return nil }
        return state
    }

    private func saveVoiceClipState(_ state: VoiceClipState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableFiles.write(try encoder.encode(state), to: voiceClipStateURL)
    }

    /// Changes the record, read again first; nothing when it can't be read.
    private func changeVoiceClipState(_ change: (inout VoiceClipState) -> Void) {
        guard var state = voiceClipState() else { return }
        let before = state
        change(&state)
        guard state != before else { return }
        do { try saveVoiceClipState(state) } catch { Self.clipLog.error("Couldn't save the voice clip record: \(error.localizedDescription, privacy: .public)") }
    }

    private static func verifiedKey(_ meetingID: UUID, _ clip: VoiceClip) -> String { "\(meetingID.uuidString)/\(clip.relativePath)" }

    // MARK: What's covered

    /// The clips of the library's conversations (not the Trash's) this Mac holds as they were found whole: the
    /// conversation names the clip at the path its source and digest give, and its file has the stamp it had when its
    /// bytes were last found to be the clip's.
    func heldVoiceClips(_ state: VoiceClipState) -> [(meeting: Meeting, clip: VoiceClip)] {
        meetings.flatMap { meeting in
            (meeting.voiceClips ?? []).compactMap { clip -> (Meeting, VoiceClip)? in
                guard let url = clip.fileURL(in: meeting.id, root: rootURL), let verified = state.verified[Self.verifiedKey(meeting.id, clip)],
                      verified.sha256 == clip.sha256, let stamp = Self.stamp(url), stamp == verified.stamp else { return nil }
                return (meeting, clip)
            }
        }
    }

    /// What this Mac's check of a clip against its own original came to: true when it matched (or this Mac cut it), false
    /// when it gave other bytes, nil when it wasn't checked.
    private static func checked(_ state: VoiceClipState, _ meetingID: UUID, _ clip: VoiceClip) -> Bool? {
        state.checked[verifiedKey(meetingID, clip)].flatMap { $0.sha256 == clip.sha256 ? $0.matches : nil }
    }

    /// Sources (by key) a clip covers on this Mac by what's here alone: held whole (`heldVoiceClips`), current
    /// (`Meeting.voiceClipIsCurrent`: the speaker's passages now, from the original its recording has), and not found to
    /// differ from this Mac's own cut of its original; with `requiringCheck`, found to match it (or cut here), as letting
    /// an original go asks. Empty while this Mac's record can't be read.
    func clipsHeldAndCurrent(requiringCheck: Bool = false) -> Set<String> {
        guard let state = voiceClipState() else { return [] }
        return Set(heldCurrentClips(state, requiringCheck: requiringCheck).map { $0.clip.source(in: $0.meeting.id).key })
    }

    /// The clips `clipsHeldAndCurrent` accepts, themselves: what's confirmed in iCloud is these clips' objects.
    func heldCurrentClips(_ state: VoiceClipState, requiringCheck: Bool) -> [(meeting: Meeting, clip: VoiceClip)] {
        heldVoiceClips(state).filter { meeting, clip in
            guard meeting.voiceClipIsCurrent(clip) else { return false }
            let check = Self.checked(state, meeting.id, clip)
            return requiringCheck ? check == true : check != false
        }
    }

    /// Whether clips may be relied on here at all: always in a library that doesn't sync; in a synced one, only while
    /// it's connected and every device seen in the last 30 days keeps voice clips (an older Daybook could drop a clip's
    /// record from its conversation in a merge, and its sealer doesn't count a clip's object as live). Clips are cut and
    /// named only then too.
    func voiceClipsMayBeReliedOn() async -> Bool {
        switch compressionSync {
        case .local: return true
        case .unknown: return false
        case .connected: return await sync?.engine?.everyRecentDeviceKeepsVoiceClips() ?? false
        }
    }

    /// Sources (by key) whose clip covers them on this Mac: held whole and current, where clips may be relied on.
    public func coveredVoiceSources() async -> Set<String> {
        guard await voiceClipsMayBeReliedOn() else { return [] }
        return clipsHeldAndCurrent()
    }

    /// The sources of `clips` (each one held here whole, current, and matched against this Mac's own original) whose
    /// own object iCloud holds and reports uploaded: the very clip accepted here, not another of the same source (in a
    /// library that doesn't sync, all of them: nothing in iCloud to wait for).
    private func inCloud(_ clips: [(meeting: Meeting, clip: VoiceClip)]) async -> Set<String> {
        let keys = clips.map { $0.clip.source(in: $0.meeting.id).key }
        switch compressionSync {
        case .local: return Set(keys)
        case .unknown: return []
        case .connected:
            guard let engine = sync?.engine else { return [] }
            var confirmed = Set<String>()
            for (key, held) in zip(keys, clips) where await engine.isObjectUploaded(held.clip.sha256) { confirmed.insert(key) }
            return confirmed
        }
    }

    /// The clips that may confirm a source in iCloud: held here whole and current, and matched against this Mac's own
    /// original (or cut here). Empty while this Mac's record can't be read.
    private func clipsForCloud() -> [(meeting: Meeting, clip: VoiceClip)] {
        guard let state = voiceClipState() else { return [] }
        return heldCurrentClips(state, requiringCheck: true)
    }

    /// Sources (by key) whose clip is covered on this Mac, matched against this Mac's own original (or cut here), and
    /// confirmed in iCloud: that clip's object is there and uploaded. Only these let an original go, here or from iCloud.
    public func voiceSourcesConfirmedInCloud() async -> Set<String> {
        guard await voiceClipsMayBeReliedOn() else { return [] }
        return await inCloud(clipsForCloud())
    }

    /// The voiceprints that hold their recordings back now (`VoiceClips.holdingBack`): what a compression pass gives
    /// `RecordingCompressionPlanner` as `voiceprints`.
    public func holdingBackVoiceprints() async -> [Voiceprint] {
        VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: await coveredVoiceSources())
    }

    /// What a decision about voice protection rested on, to compare once more with nothing awaited
    /// (`voiceProtectionUnchanged`): whether clips could be relied on, which clips iCloud held (letting an original go
    /// asks it, and a check against this Mac's original), and the voiceprints holding recordings back then.
    struct VoiceProtectionMark: Equatable {
        var reliedOn: Bool
        var inCloud: Set<String>?
        var holding: [String]
    }

    private func voiceProtectionHolding(reliedOn: Bool, inCloud: Set<String>?) -> [String] {
        var covered = reliedOn ? clipsHeldAndCurrent(requiringCheck: inCloud != nil) : []
        if let inCloud { covered.formIntersection(inCloud) }
        return VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: covered).map(\.id).sorted()
    }

    /// Conversations whose recordings stay as captured for voice profiles: what a voiceprint whose clip doesn't cover it
    /// learned from, followed through merges, moves, and the same bytes, the Trash (`lineage`) included
    /// (`RecordingCompressionPlanner.learnedFrom`). `requiringUpload`: a clip covers only once it's matched against this
    /// Mac's own original (or cut here) and confirmed in iCloud too (what letting an original go asks). With them, what
    /// to compare once more with nothing awaited.
    func voiceProtectedMeetings(lineage: [Meeting], requiringUpload: Bool = false) async -> (meetings: Set<UUID>, mark: VoiceProtectionMark) {
        let reliedOn = await voiceClipsMayBeReliedOn()
        let inCloud = requiringUpload ? await inCloud(reliedOn ? clipsForCloud() : []) : nil
        var covered = reliedOn ? clipsHeldAndCurrent(requiringCheck: requiringUpload) : []
        if let inCloud { covered.formIntersection(inCloud) }
        let holding = VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: covered)
        let protected = RecordingCompressionPlanner.learnedFrom(meetings, voiceprints: holding, lineage: lineage)
        return (protected, VoiceProtectionMark(reliedOn: reliedOn, inCloud: inCloud, holding: holding.map(\.id).sorted()))
    }

    /// Conversations whose recordings' originals must stay in iCloud for voice profiles: what a voiceprint whose clip
    /// isn't confirmed in iCloud (`voiceSourcesConfirmedInCloud`) learned from, followed as `voiceProtectedMeetings` is,
    /// the Trash included. What the sealer keeps through key rotations (`LibrarySyncEngine.holdOriginalsInICloud`) and
    /// what cleaning superseded originals out of iCloud leaves alone (docs/icloud-sync.md, "Voice clips").
    /// Nil when a conversation in the Trash can't be read: a voiceprint may have followed a recording through it.
    /// A conversation whose speaker was named before its voice was known holds too: its profile learns from it once the voice
    /// is made, and the clip from the original (`Meeting.awaitsVoiceForNamedSpeaker`, as compression holds it).
    public func meetingsHoldingOriginalsInICloud() async -> Set<UUID>? {
        let awaiting = Set(meetings.filter(\.awaitsVoiceForNamedSpeaker).map(\.id))
        // The Trash is read only when a voiceprint holds a recording back at all.
        guard await !voiceProtectedMeetings(lineage: [], requiringUpload: true).mark.holding.isEmpty else { return awaiting }
        let root = rootURL
        guard let trashed = await Task.detached(priority: .userInitiated, operation: { Self.readableTrash(in: root) }).value else { return nil }
        return await voiceProtectedMeetings(lineage: trashed, requiringUpload: true).meetings.union(awaiting)
    }

    /// What the library says of letting superseded originals go from iCloud (`SupersededJudgment`): stop under Never, or
    /// while a setting or voiceprint is in a shape this version can't read (which conversation a voiceprint was learned
    /// from can't be known), as a compression pass does; pause while its settings aren't the library's as sync last
    /// delivered them whole (`settingsCurrent`).
    func supersededJudgment(settingsCurrent: Bool) -> SupersededJudgment {
        if newerSettingsSkipped || metadata.recordingCompression == .never || metadata.hasUnreadableValues || VoiceClips.counting(metadata) == nil {
            return .stop
        }
        return settingsCurrent ? .judge : .pause
    }

    /// Nothing voice protection depends on changed since `mark` was taken.
    func voiceProtectionUnchanged(_ mark: VoiceProtectionMark) -> Bool {
        voiceProtectionHolding(reliedOn: mark.reliedOn, inCloud: mark.inCloud) == mark.holding
    }

    // MARK: Making clips

    /// The clip a change didn't keep as it was.
    struct VoiceClipChanged: LocalizedError {
        var errorDescription: String? { "The recording, its passages, or its voice clip changed while the clip was made." }
    }

    /// Clip files whose stamp isn't the one recorded (one sync just brought, a restore from a backup, a copy of the
    /// library) are hashed, and recorded whole with their stamp when their bytes are the clip's digest, with the record
    /// that names them. `shouldContinue` stops it between files.
    public func verifyVoiceClips(shouldContinue: () -> Bool = { true }) async {
        guard let state = voiceClipState() else { return }
        for meeting in meetings {
            for clip in meeting.voiceClips ?? [] where clip.unread == nil {
                guard shouldContinue(), !Task.isCancelled else { return }
                let key = Self.verifiedKey(meeting.id, clip)
                guard let url = clip.fileURL(in: meeting.id, root: rootURL), let stamp = Self.stamp(url) else { continue }
                if let known = state.verified[key], known.sha256 == clip.sha256, known.stamp == stamp {
                    if known.record != clip { changeVoiceClipState { $0.verified[key]?.record = clip } }
                    continue
                }
                guard (try? await AudioDigest.sha256(contentsOf: url)) == clip.sha256, Self.stamp(url) == stamp else { continue }
                changeVoiceClipState { $0.verified[key] = .init(sha256: clip.sha256, stamp: stamp, record: clip) }
            }
        }
    }

    /// What a source's clip would be cut from, its passages' frames: a source tried with the same one gives the same.
    private static func basis(_ originalSHA256: String, _ spans: [VoiceClipSpan]) -> String {
        originalSHA256 + "|" + AudioDigest.sha256(data: Data(spans.map { "\($0.start)-\($0.end)" }.joined(separator: ",").utf8))
    }

    /// The source waits: refused with this basis, or failed lately (`failureWait`, from its last failure).
    private static func waits(_ attempts: VoiceClipState.Attempts?, basis: String, now: Date) -> Bool {
        guard let attempts, attempts.basis == basis else { return false }
        if attempts.refused == true { return true }
        guard let failures = attempts.failures, failures > 0, let last = attempts.lastFailure else { return false }
        return now < last.addingTimeInterval(failureWait(failures))
    }

    private func rememberClipFailure(_ key: String, basis: String, refused: Bool, now: Date) {
        changeVoiceClipState { state in
            let previous = state.attempts[key].flatMap { $0.basis == basis ? $0 : nil }
            state.attempts[key] = refused ? .init(basis: basis, refused: true)
                : .init(basis: basis, failures: (previous?.failures ?? 0) + 1, lastFailure: now)
        }
    }

    /// Cuts the clips voice profiles need (`VoiceClips.Plan.wanted`, every source a voiceprint names) that no clip here
    /// covers, from each recording's lossless original: the track's file, or, once it was compressed, the original it
    /// replaced while it's still here. And checks each clip this Mac holds but didn't cut (one sync brought, one carried
    /// here) against its own original: its own cut of the clip's frames must give the clip's bytes, or the clip covers
    /// nothing here and its original stays (`VoiceClipState.checked`). Only for recordings that may soon be replaced or
    /// let go: a compressed one, or one in a conversation whose last activity is before `cutoff` (nil: compressed ones
    /// only). In a synced library, nothing is cut or named while a device in use doesn't keep clips
    /// (`voiceClipsMayBeReliedOn`). The original is hashed against the track first and must be unchanged (its stamp)
    /// after the cut; the clip is checked sample by sample against it (`VoiceClipAudio.extract`), placed under a name of
    /// its own in the conversation's folder, hashed again, and only then named by the conversation (under the lock, with
    /// the recording and the speaker's passages still the ones it was cut for), durably, without changing its edit date.
    /// At most `limit` recordings are read; a source that can't be cut waits (refused until its original or passages
    /// change; failed: 6 hours, doubling), so it doesn't take a pass's place again; `shouldContinue` stops it between
    /// recordings. A clip held whole that no longer holds the speaker's passages, with no lossless original here to cut
    /// it again, is marked stale. Anything that fails leaves the recording held back as before. Returns clips made.
    @discardableResult
    public func makeVoiceClips(olderThan cutoff: Date?, now: Date = Date(), limit: Int = 3, shouldContinue: () -> Bool = { true }) async -> Int {
        guard isLoaded, let store, voiceClipState() != nil, await voiceClipsMayBeReliedOn() else { return 0 }
        voiceClipsInFlight += 1
        defer { voiceClipsInFlight -= 1 }
        await verifyVoiceClips(shouldContinue: shouldContinue)
        let plan = VoiceClips.plan(metadata: metadata, meetings: meetings)
        guard plan.readable, let state = voiceClipState() else { return 0 }
        let covered = clipsHeldAndCurrent()
        let heldHere = heldVoiceClips(state)
        // By recording: the sources whose own conversation and recording are here to cut from, and the clips held here
        // whole and current that this Mac hasn't checked against its own original.
        var cuts: [String: [VoiceClipSource]] = [:], checks: [String: [VoiceClip]] = [:]
        for source in plan.wanted.values where !covered.contains(source.key) {
            cuts["\(source.meetingID.uuidString)|\(source.trackID.uuidString)", default: []].append(source)
        }
        for (meeting, clip) in heldHere where meeting.voiceClipIsCurrent(clip) && Self.checked(state, meeting.id, clip) == nil {
            checks["\(meeting.id.uuidString)|\(clip.trackID.uuidString)", default: []].append(clip)
        }
        var made = 0, read = 0
        for group in Set(cuts.keys).union(checks.keys).sorted() {
            guard read < limit, shouldContinue(), !Task.isCancelled else { break }
            let parts = group.split(separator: "|")
            guard parts.count == 2, let meetingID = UUID(uuidString: String(parts[0])), let trackID = UUID(uuidString: String(parts[1])),
                  let meeting = meeting(meetingID), meeting.voiceClipsAreReadable,
                  let track = meeting.tracks.first(where: { $0.id == trackID }) else { continue }
            let sources = (cuts[group] ?? []).sorted { $0.key < $1.key }
            let original: (path: String, sha256: String) = track.encoding.map { ($0.previousRelativePath, $0.previousSHA256) }
                ?? (track.relativePath, track.sha256)
            guard !original.sha256.isEmpty, let url = try? await store.audioURL(for: RecordingTrack(relativePath: original.path, fileName: ""), in: meeting.id) else { continue }
            guard SyncFilesProbe.isRegularFile(url) else {
                // No lossless original here: a clip that no longer holds the speaker's passages is all there is. Kept, and
                // marked so nothing takes it for that speaker's speech.
                let stale = sources.compactMap { meeting.voiceClip(for: $0) }
                    .filter { clip in clip.stale != true && heldHere.contains { $0.meeting.id == meeting.id && $0.clip == clip } }.map(\.id)
                if !stale.isEmpty { await markStale(Set(stale), in: meeting.id) }
                continue
            }
            let due = track.isCompressed || cutoff.map { RecordingCompressionEligibility.lastActivity(of: meeting) <= $0 } == true
            // Nothing to cut (every passage talked over) gives no clip, and the recording stays as captured: decided
            // from the transcript, before any file is read.
            let jobs = sources.map { ($0, VoiceClips.spans(for: $0, in: meeting)) }.filter { !$0.1.isEmpty }
                .filter { !Self.waits(state.attempts[$0.0.key], basis: Self.basis(original.sha256, $0.1), now: now) }
            let checking = (checks[group] ?? []).filter { !Self.waits(state.attempts[Self.checkKey(meeting.id, $0)], basis: $0.sha256, now: now) }
            guard due, !jobs.isEmpty || !checking.isEmpty else { continue }
            read += 1
            guard let stamp = Self.stamp(url), (try? await AudioDigest.sha256(contentsOf: url)) == original.sha256 else {
                Self.clipLog.error("No voice clips from \(track.id.uuidString, privacy: .public): its original isn't the recording's bytes")
                for (source, spans) in jobs { rememberClipFailure(source.key, basis: Self.basis(original.sha256, spans), refused: false, now: now) }
                for clip in checking { rememberClipFailure(Self.checkKey(meeting.id, clip), basis: clip.sha256, refused: false, now: now) }
                continue
            }
            for clip in checking {
                if Task.isCancelled { break }
                do {
                    try await checkVoiceClip(clip, in: meeting.id, from: url, stamp: stamp, originalSHA256: original.sha256)
                    changeVoiceClipState { $0.attempts[Self.checkKey(meeting.id, clip)] = nil }
                } catch {
                    if error is CancellationError || Task.isCancelled { break }
                    rememberClipFailure(Self.checkKey(meeting.id, clip), basis: clip.sha256, refused: false, now: now)
                    Self.clipLog.error("Couldn't check a voice clip of \(clip.trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            for (source, spans) in jobs {
                if Task.isCancelled { break }
                let basis = Self.basis(original.sha256, spans)
                do {
                    try await makeVoiceClip(source, spans: spans, from: url, stamp: stamp, originalSHA256: original.sha256, now: now)
                    changeVoiceClipState { $0.attempts[source.key] = nil }
                    made += 1
                } catch {
                    if error is CancellationError || Task.isCancelled { break }
                    let refused = (error as? VoiceClipAudio.Failure).map { [.unsupportedLayout, .nothingToCut].contains($0) } ?? false
                    rememberClipFailure(source.key, basis: basis, refused: refused, now: now)
                    Self.clipLog.error("No voice clip from \(source.trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return made
    }

    private static func checkKey(_ meetingID: UUID, _ clip: VoiceClip) -> String { "check|" + verifiedKey(meetingID, clip) }

    /// This Mac's own cut of a clip's frames from its own original (hashed against the recording by the caller), compared
    /// with the clip's bytes; recorded either way while the original and the clip are still the ones read. One that
    /// claims another original than this one doesn't match. Throws when the check couldn't be made.
    private func checkVoiceClip(_ clip: VoiceClip, in meetingID: UUID, from url: URL, stamp: [Int64], originalSHA256: String) async throws {
        guard let store else { throw VoiceClipChanged() }
        var matches = false
        if clip.originalSHA256 == originalSHA256, clip.channels >= 1 {
            let folder = try await store.meetingDirectory(for: meetingID).appendingPathComponent(VoiceClip.folder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let cut = try await VoiceClipAudio.extract(from: url, ranges: clip.ranges, into: folder)
                try? FileManager.default.removeItem(at: cut.url)
                matches = cut.sha256 == clip.sha256 && cut.sampleRate == clip.sampleRate && cut.channels == clip.channels
            } catch let failure as VoiceClipAudio.Failure where [.unsupportedLayout, .nothingToCut].contains(failure) {
                // Frames or channels this original doesn't have: not a cut of it.
            }
            guard Self.stamp(url) == stamp else { throw VoiceClipChanged() }
        }
        guard let current = meeting(meetingID)?.voiceClips?.first(where: { $0.id == clip.id }), current.sha256 == clip.sha256 else { throw VoiceClipChanged() }
        if !matches { Self.clipLog.error("A voice clip of \(clip.trackID.uuidString, privacy: .public) isn't what this Mac's original gives: it covers nothing here") }
        changeVoiceClipState { $0.checked[Self.verifiedKey(meetingID, clip)] = .init(sha256: clip.sha256, matches: matches) }
    }

    /// Marks these clips (by ID) of a conversation stale, durably, without changing its edit date.
    private func markStale(_ ids: Set<String>, in meetingID: UUID) async {
        await acquireLock()
        defer { releaseLock() }
        updateKeepingEditDate(meetingID) { meeting in
            guard meeting.voiceClipsAreReadable, var clips = meeting.voiceClips else { return }
            for index in clips.indices where ids.contains(clips[index].id) && !meeting.voiceClipIsCurrent(clips[index]) { clips[index].stale = true }
            meeting.voiceClips = clips
        }
        try? await flushDurably([meetingID])
    }

    private func makeVoiceClip(_ source: VoiceClipSource, spans: [VoiceClipSpan], from url: URL, stamp: [Int64], originalSHA256: String,
                               now: Date) async throws {
        guard let store else { throw VoiceClipChanged() }
        let meetingFolder = try await store.meetingDirectory(for: source.meetingID)
        let folder = meetingFolder.appendingPathComponent(VoiceClip.folder, isDirectory: true)
        var cutURL: URL?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let cut = try await VoiceClipAudio.extract(from: url, spans: spans, into: folder)
            cutURL = cut.url
            try voiceClipFault?(.cut)
            // What was cut is what was hashed.
            guard Self.stamp(url) == stamp else { throw VoiceClipChanged() }
            // Named by its source and its bytes: a clip cut again never takes the name of other bytes a conversation names.
            let relativePath = VoiceClip.relativePath(for: source, sha256: cut.sha256)
            let destination = meetingFolder.appendingPathComponent(relativePath)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: cut.url, to: destination)
            } else if (try? await AudioDigest.sha256(contentsOf: destination)) == cut.sha256 {
                try FileManager.default.removeItem(at: cut.url)
            } else {
                // A file under this name that isn't these bytes is a damaged copy of them, relied on for nothing (its
                // stamp isn't the one recorded): the clip cut again takes its place.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: cut.url)
            }
            cutURL = nil
            try DurableFiles.synchronize([destination, folder])
            try voiceClipFault?(.placed)
            guard let clipStamp = Self.stamp(destination), (try? await AudioDigest.sha256(contentsOf: destination)) == cut.sha256 else {
                throw VoiceClipChanged()
            }
            let clip = VoiceClip(trackID: source.trackID, speakerID: source.speakerID, relativePath: relativePath, sha256: cut.sha256, size: cut.size,
                                 originalSHA256: originalSHA256, originalFrames: cut.originalFrames, sampleRate: cut.sampleRate,
                                 channels: cut.channels, ranges: cut.ranges, createdAt: now)
            await acquireLock()
            defer { releaseLock() }
            // Still a library where clips are named: every device in use keeps them.
            guard await voiceClipsMayBeReliedOn() else { throw VoiceClipChanged() }
            // Nothing awaited from here to the conversation naming it: the recording still has this original, the speaker's
            // passages are still the ones cut, and the clip's file is still the one hashed.
            guard let meeting = meeting(source.meetingID), meeting.voiceClipsAreReadable, let track = meeting.tracks.first(where: { $0.id == source.trackID }),
                  track.sha256 == originalSHA256 || track.encoding?.previousSHA256 == originalSHA256,
                  VoiceClips.spans(for: source, in: meeting) == spans, Self.stamp(destination) == clipStamp, voiceClipState() != nil else {
                throw VoiceClipChanged()
            }
            changeVoiceClipState { state in
                state.verified[Self.verifiedKey(source.meetingID, clip)] = .init(sha256: clip.sha256, stamp: clipStamp, record: clip)
                // Cut here from this Mac's own original.
                state.checked[Self.verifiedKey(source.meetingID, clip)] = .init(sha256: clip.sha256, matches: true)
            }
            let before = meeting.voiceClip(for: source)
            updateKeepingEditDate(source.meetingID) { meeting in
                var clips = (meeting.voiceClips ?? []).filter { $0.id != clip.id }
                clips.append(clip)
                meeting.voiceClips = clips.sorted { $0.id < $1.id }
            }
            do {
                try await flushDurably([source.meetingID])
            } catch {
                // Not saved: memory goes back to what it named, so nothing relies on a clip the disk doesn't name.
                updateKeepingEditDate(source.meetingID) { meeting in
                    guard meeting.voiceClips?.contains(clip) == true else { return }
                    var clips = (meeting.voiceClips ?? []).filter { $0.id != clip.id }
                    if let before { clips.append(before) }
                    meeting.voiceClips = clips.isEmpty ? nil : clips.sorted { $0.id < $1.id }
                }
                throw error
            }
            Self.clipLog.info("Kept a voice clip of \(source.trackID.uuidString, privacy: .public): \(cut.size) bytes")
        } catch {
            if let cutURL { try? FileManager.default.removeItem(at: cutURL) }
            throw error
        }
    }

    // MARK: Letting clips go

    /// The day a clip no voiceprint names waits has passed: by the wall clock, and, since the same boot, by the
    /// continuous clock too, so a clock set ahead doesn't shorten it.
    private static func graceHasPassed(_ mark: VoiceClipState.Orphaned, now: Date, clock: VoiceClipClock) -> Bool {
        guard now >= mark.since.addingTimeInterval(VoiceClips.orphanGrace) else { return false }
        if !mark.boot.isEmpty, mark.boot == clock.boot { return clock.seconds - mark.seconds >= VoiceClips.orphanGrace }
        return true
    }

    /// The one place a voice clip a conversation names is deleted. A clip goes `VoiceClips.orphanGrace` after no
    /// voiceprint of a profile that still exists names its source (matched by the clip's own source: its conversation,
    /// recording, and speaker, or the source it was carried from; the profile deleted, or the speaker taken out of it:
    /// removed, forgotten, renamed to a placeholder, Not <name>), measured by the wall clock and, in the same boot, the
    /// continuous clock (`clock`); a voiceprint naming it again before then (an Undo, on any device) keeps it. The
    /// conversation stops naming it first, durably (and the edit syncs, so every Mac lets its copy go), then the file goes.
    /// Only clips of the library's conversations: a conversation in the Trash keeps its clips with its recordings until
    /// it's restored or its files are deleted. Only while every profile and voiceprint record and this Mac's record can
    /// be read, and, in a synced library, under the lock with this Mac's settings the library's (`settingsAreCurrent`);
    /// with `deleting` false (at launch, before sync has brought the library's settings), nothing goes but temporaries.
    /// A record this version can't read is never let go. A file a conversation doesn't name that this Mac found whole
    /// under a record a voiceprint still needs is named again (a Daybook from before clips dropped the record in a merge),
    /// where clips may be relied on (`voiceClipsMayBeReliedOn`). Clip files a conversation doesn't name are swept too: a
    /// temporary (no clip is being made), and, a day old and not named by what sync last applied here, one whose speech
    /// no voiceprint needs, wherever it sits (`VoiceClips.isNeeded`), or whose source has a clip this Mac holds whole.
    /// Returns how many named clips were deleted.
    @discardableResult
    public func reconcileVoiceClips(now: Date = Date(), clock: VoiceClipClock = .unknown, deleting: Bool = true) async -> Int {
        guard isLoaded else { return 0 }
        await acquireLock()
        defer { releaseLock() }
        var deleting = deleting
        switch compressionSync {
        case .local: break
        case .unknown: deleting = false
        case .connected: if deleting, await !settingsAreCurrent() { deleting = false }
        }
        let adopting = deleting ? await voiceClipsMayBeReliedOn() : false
        // From here, nothing is awaited until the conversations are saved: no clip can be started, placed, or named meanwhile.
        guard voiceClipsInFlight == 0, var state = voiceClipState() else { return 0 }
        let prints = deleting ? VoiceClips.counting(metadata) : nil
        let plan = VoiceClips.plan(metadata: metadata, meetings: meetings)
        var going: [(meetingID: UUID, clip: VoiceClip)] = []
        var present = Set<String>()
        for meeting in meetings where meeting.voiceClipsAreReadable {
            for clip in meeting.voiceClips ?? [] where clip.unread == nil {
                let source = clip.source(in: meeting.id), key = source.key
                present.insert(key)
                guard let prints else { continue }
                if prints.contains(where: source.isNamed(by:)) { state.orphaned[key] = nil; continue }
                guard let mark = state.orphaned[key] else {
                    state.orphaned[key] = .init(since: now, boot: clock.boot, seconds: clock.seconds)
                    continue
                }
                if Self.graceHasPassed(mark, now: now, clock: clock) { going.append((meeting.id, clip)) }
            }
        }
        state.orphaned = state.orphaned.filter { present.contains($0.key) }
        // Records a voiceprint still needs that a merge dropped, named again from what this Mac found whole.
        let adopted = prints != nil && adopting && plan.readable ? adoptions(state, plan: plan) : [:]
        var deleted = 0
        if !going.isEmpty || !adopted.isEmpty {
            let byMeeting = Dictionary(grouping: going, by: \.meetingID)
            for (meetingID, clips) in byMeeting {
                let ids = Set(clips.map(\.clip.id))
                updateKeepingEditDate(meetingID) { meeting in
                    let kept = (meeting.voiceClips ?? []).filter { !ids.contains($0.id) }
                    meeting.voiceClips = kept.isEmpty ? nil : kept
                }
            }
            for (meetingID, clips) in adopted {
                updateKeepingEditDate(meetingID) { meeting in
                    let named = Set((meeting.voiceClips ?? []).map { $0.source(in: meeting.id).key })
                    let added = clips.filter { !named.contains($0.source(in: meeting.id).key) }
                    guard !added.isEmpty else { return }
                    meeting.voiceClips = ((meeting.voiceClips ?? []) + added).sorted { $0.id < $1.id }
                }
            }
            do {
                try await flushDurably(Set(byMeeting.keys).union(adopted.keys))
                for (meetingID, clip) in going {
                    guard let url = clip.fileURL(in: meetingID, root: rootURL) else { continue }
                    do {
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                        deleted += 1
                    } catch {
                        Self.clipLog.error("Kept a voice clip's file: \(error.localizedDescription, privacy: .public)")
                    }
                    state.verified[Self.verifiedKey(meetingID, clip)] = nil
                    state.checked[Self.verifiedKey(meetingID, clip)] = nil
                    state.orphaned[clip.source(in: meetingID).key] = nil
                }
                if !adopted.isEmpty { Self.clipLog.info("Named \(adopted.values.joined().count) voice clips again") }
            } catch {
                // Not saved: the conversations still name them on disk, so their files stay; asked again next pass. A record
                // named again goes from memory too, so nothing relies on one the disk doesn't name.
                for (meetingID, clips) in adopted {
                    let ids = Set(clips.map(\.id))
                    updateKeepingEditDate(meetingID) { meeting in
                        let kept = (meeting.voiceClips ?? []).filter { !ids.contains($0.id) }
                        meeting.voiceClips = kept.isEmpty ? nil : kept
                    }
                }
                Self.clipLog.error("Kept voice clips: \(error.localizedDescription, privacy: .public)")
            }
        }
        await sweepUnnamedVoiceClips(state: &state, now: now, deleting: prints != nil, plan: plan)
        // What this Mac recorded of files that are gone is forgotten; a file still here that no conversation names keeps
        // its record, so it can be named again.
        let named = Set(meetings.flatMap { meeting in (meeting.voiceClips ?? []).map { Self.verifiedKey(meeting.id, $0) } })
        func kept(_ key: String) -> Bool {
            named.contains(key) || SyncFilesProbe.isRegularFile(rootURL.appendingPathComponent("Meetings/\(key)"))
        }
        state.verified = state.verified.filter { kept($0.key) }
        state.checked = state.checked.filter { kept($0.key) }
        if state != voiceClipState() {
            do { try saveVoiceClipState(state) } catch { Self.clipLog.error("Couldn't save the voice clip record: \(error.localizedDescription, privacy: .public)") }
        }
        return deleted
    }

    /// By conversation: records this Mac found whole (`VoiceClipState.Verified.record`) whose file the conversation no
    /// longer names, to name again: its file still has the stamp it had when its bytes were the record's, a voiceprint
    /// still needs its speech (`VoiceClips.isNeeded`), the conversation names no clip of that source and still has the
    /// recording it was cut from, and the record is at the path its source and digest give there.
    private func adoptions(_ state: VoiceClipState, plan: VoiceClips.Plan) -> [UUID: [VoiceClip]] {
        var found: [UUID: [VoiceClip]] = [:]
        // A source a conversation names a clip of, wherever (one carried away by Move to New Conversation or a merge): the
        // record its old conversation kept isn't named again there.
        let named = Set(meetings.flatMap { meeting in (meeting.voiceClips ?? []).filter { $0.unread == nil }.map { $0.source(in: meeting.id).key } })
        for meeting in meetings where meeting.voiceClipsAreReadable {
            let prefix = meeting.id.uuidString + "/"
            let paths = Set((meeting.voiceClips ?? []).map(\.relativePath))
            for (key, verified) in state.verified where key.hasPrefix(prefix) {
                guard let record = verified.record, record.unread == nil, record.sha256 == verified.sha256, !paths.contains(record.relativePath),
                      record.isStored(in: meeting.id), let url = record.fileURL(in: meeting.id, root: rootURL), Self.stamp(url) == verified.stamp,
                      !named.contains(record.source(in: meeting.id).key),
                      !(found[meeting.id] ?? []).contains(where: { $0.source(in: meeting.id) == record.source(in: meeting.id) }),
                      let track = meeting.tracks.first(where: { $0.id == record.trackID }),
                      record.originalSHA256 == track.sha256 || record.originalSHA256 == track.encoding?.previousSHA256,
                      VoiceClips.isNeeded(record.source(in: meeting.id).key, in: meeting, metadata: metadata, wanted: plan) else { continue }
                found[meeting.id, default: []].append(record)
            }
        }
        return found
    }

    /// Files in the library's conversations' `Originals/VoiceClips/` that no clip names (`reconcileVoiceClips`).
    private func sweepUnnamedVoiceClips(state: inout VoiceClipState, now: Date, deleting: Bool, plan: VoiceClips.Plan) async {
        // Sources a clip this Mac holds whole and current covers, in whichever conversation names it.
        let held = Set(heldCurrentClips(state, requiringCheck: false).map { $0.clip.source(in: $0.meeting.id).key })
        for meeting in meetings {
            let folder = rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(VoiceClip.folder)", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !names.isEmpty else { continue }
            let clips = meeting.voiceClips ?? []
            let named = Set(clips.compactMap { $0.unread == nil ? $0.relativePath : $0.unreadPath })
            let history = deleting ? await sync?.engine?.voiceClipFilesInHistory(of: meeting.id) ?? [] : []
            var swept = false
            for name in names where !named.contains("\(VoiceClip.folder)/\(name)") {
                let url = folder.appendingPathComponent(name)
                if name.hasPrefix(VoiceClips.temporaryPrefix) {
                    swept = (try? FileManager.default.removeItem(at: url)) != nil || swept
                    continue
                }
                let key = String(name.prefix(32))
                // Never while a conversation's list is in a shape this version can't read, and never speech a voiceprint
                // still needs that no clip held whole here covers.
                guard deleting, meeting.voiceClipsAreReadable, name.hasSuffix(".caf"), !name.hasPrefix("."), !history.contains("\(VoiceClip.folder)/\(name)"),
                      held.contains(key) || !VoiceClips.isNeeded(key, in: meeting, metadata: metadata, wanted: plan),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
                      let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= VoiceClips.orphanGrace else { continue }
                swept = (try? FileManager.default.removeItem(at: url)) != nil || swept
            }
            if swept { try? DurableFiles.synchronize([folder]) }
        }
    }

    // MARK: Clips that go with their recordings

    /// Copies (clones) the files of `clips` from one conversation's folder to another's, at the same paths, when they're
    /// here and not there yet: a clip carried with its recording (a merge, Move to New Conversation) is the same file in
    /// its new conversation. Only at the path its source and digest give (`VoiceClip.fileURL`), so never outside the
    /// conversation's `Originals/VoiceClips/`. One that isn't here is the object iCloud has; one whose bytes aren't the clip's is relied on
    /// for nothing there until they're checked (`verifyVoiceClips`).
    func copyVoiceClipFiles(_ clips: [VoiceClip], from sourceID: UUID, to targetID: UUID) throws {
        for clip in clips {
            guard let from = clip.fileURL(in: sourceID, root: rootURL), SyncFilesProbe.isRegularFile(from),
                  let to = clip.fileURL(in: targetID, root: rootURL), !FileManager.default.fileExists(atPath: to.path) else { continue }
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: to)
            try DurableFiles.synchronize([to, to.deletingLastPathComponent()])
        }
    }

    // MARK: Reading a voiceprint's speech

    /// The speech a voiceprint would be made again from (a new voice model's space, a voiceprint checked against what it
    /// was learned from), by its speaker's passages: the lossless original while it's here with the bytes the recording
    /// names (the track's file, or the original a compressed copy replaced, not yet let go), else the voiceprint's clip
    /// when it's here whole and current. Nil when neither is: only a lossy copy is left, or a stale clip, and a
    /// voiceprint isn't made from either.
    public struct VoiceSample: Equatable, Sendable {
        public var url: URL
        /// The speaker's passages in `url`, in seconds.
        public var spans: [VoiceClipSpan]
        public var isClip: Bool
    }

    /// A voiceprint whose conversation isn't here any more (deleted and restored under a new ID, merged away) reads its
    /// clip wherever it was carried.
    public func voiceSample(for print: Voiceprint) async -> VoiceSample? {
        let conversation = meeting(print.meetingID)
        guard let source = VoiceClips.source(of: print, in: conversation, carried: VoiceClips.carriedSources(in: meetings)) else { return nil }
        if let conversation, let track = conversation.tracks.first(where: { $0.id == source.trackID }) {
            let spans = VoiceClips.spans(for: source, in: conversation)
            let original: (path: String, sha256: String) = track.encoding.map { ($0.previousRelativePath, $0.previousSHA256) } ?? (track.relativePath, track.sha256)
            if !spans.isEmpty, !original.sha256.isEmpty,
               let url = try? await audioURL(for: RecordingTrack(relativePath: original.path, fileName: ""), in: conversation.id),
               SyncFilesProbe.isRegularFile(url), (try? await AudioDigest.sha256(contentsOf: url)) == original.sha256 {
                return VoiceSample(url: url, spans: spans, isClip: false)
            }
        }
        guard clipsHeldAndCurrent().contains(source.key), let state = voiceClipState(),
              let held = heldVoiceClips(state).first(where: { $0.clip.source(in: $0.meeting.id) == source && $0.meeting.voiceClipIsCurrent($0.clip) }),
              let url = held.clip.fileURL(in: held.meeting.id, root: rootURL) else { return nil }
        return VoiceSample(url: url, spans: held.clip.spansInClip, isClip: true)
    }
}
