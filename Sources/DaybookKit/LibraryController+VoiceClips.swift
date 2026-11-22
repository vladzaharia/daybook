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

    /// `voice-clips.json` beside the library, never synced: which clip files this Mac found whole, the clips no
    /// voiceprint names and since when, and the sources it couldn't cut.
    public struct VoiceClipState: Codable, Equatable, Sendable {
        public var version = 1
        /// By `<conversation ID>/<relative path>`: the digest the file was found to have, and its stamp
        /// (`LibraryController.stamp`) then. A clip is relied on only while its file still has that stamp.
        public var verified: [String: Verified] = [:]
        /// By source key: when no voiceprint named its clip, by the wall clock and the continuous clock.
        public var orphaned: [String: Orphaned] = [:]
        /// By source key: what cutting its clip came to, so a source that can't be cut doesn't take a pass's place.
        public var attempts: [String: Attempts] = [:]

        public struct Verified: Codable, Equatable, Sendable {
            public var sha256: String
            public var stamp: [Int64]
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

    /// Sources (by key) a clip covers on this Mac by what's here alone: held whole (`heldVoiceClips`) and current
    /// (`Meeting.voiceClipIsCurrent`: the speaker's passages now, from the original its recording has). Empty while this
    /// Mac's record can't be read.
    func clipsHeldAndCurrent() -> Set<String> {
        guard let state = voiceClipState() else { return [] }
        return Set(heldVoiceClips(state).filter { $0.meeting.voiceClipIsCurrent($0.clip) }.map { $0.clip.source(in: $0.meeting.id).key })
    }

    /// Whether clips may be relied on here at all: always in a library that doesn't sync; in a synced one, only while
    /// it's connected and every device seen in the last 30 days keeps voice clips (an older Daybook could drop a clip's
    /// record from its conversation in a merge, and its sealer doesn't count a clip's object as live).
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

    /// Of `covered`, the sources whose clip's object iCloud holds and reports uploaded (in a library that doesn't sync,
    /// all of them: nothing in iCloud to wait for).
    private func inCloud(_ covered: Set<String>) async -> Set<String> {
        switch compressionSync {
        case .local: return covered
        case .unknown: return []
        case .connected:
            guard let engine = sync?.engine else { return [] }
            var confirmed = Set<String>()
            for meeting in meetings {
                for clip in meeting.voiceClips ?? [] {
                    let key = clip.source(in: meeting.id).key
                    if covered.contains(key), await engine.isObjectUploaded(clip.sha256) { confirmed.insert(key) }
                }
            }
            return confirmed
        }
    }

    /// Sources (by key) whose clip is covered on this Mac (`coveredVoiceSources`) and confirmed in iCloud: its object is
    /// there and uploaded. Only these let an original go, here or from iCloud.
    public func voiceSourcesConfirmedInCloud() async -> Set<String> {
        await inCloud(await coveredVoiceSources())
    }

    /// The voiceprints that hold their recordings back now (`VoiceClips.holdingBack`): what a compression pass gives
    /// `RecordingCompressionPlanner` as `voiceprints`.
    public func holdingBackVoiceprints() async -> [Voiceprint] {
        VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: await coveredVoiceSources())
    }

    /// What a decision about voice protection rested on, to compare once more with nothing awaited
    /// (`voiceProtectionUnchanged`): whether clips could be relied on, which clips iCloud held, and the voiceprints
    /// holding recordings back then.
    struct VoiceProtectionMark: Equatable {
        var reliedOn: Bool
        var inCloud: Set<String>?
        var holding: [String]
    }

    private func voiceProtectionHolding(reliedOn: Bool, inCloud: Set<String>?) -> [String] {
        var covered = reliedOn ? clipsHeldAndCurrent() : []
        if let inCloud { covered.formIntersection(inCloud) }
        return VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: covered).map(\.id).sorted()
    }

    /// Conversations whose recordings stay as captured for voice profiles: what a voiceprint whose clip doesn't cover it
    /// learned from, followed through merges, moves, and the same bytes, the Trash (`lineage`) included
    /// (`RecordingCompressionPlanner.learnedFrom`). `requiringUpload`: a clip covers only once it's confirmed in iCloud
    /// too (what letting an original go asks). With them, what to compare once more with nothing awaited.
    func voiceProtectedMeetings(lineage: [Meeting], requiringUpload: Bool = false) async -> (meetings: Set<UUID>, mark: VoiceProtectionMark) {
        let reliedOn = await voiceClipsMayBeReliedOn()
        let inCloud = requiringUpload ? await inCloud(reliedOn ? clipsHeldAndCurrent() : []) : nil
        var covered = reliedOn ? clipsHeldAndCurrent() : []
        if let inCloud { covered.formIntersection(inCloud) }
        let holding = VoiceClips.holdingBack(metadata: metadata, meetings: meetings, covered: covered)
        let protected = RecordingCompressionPlanner.learnedFrom(meetings, voiceprints: holding, lineage: lineage)
        return (protected, VoiceProtectionMark(reliedOn: reliedOn, inCloud: inCloud, holding: holding.map(\.id).sorted()))
    }

    /// Conversations whose recordings' originals must stay in iCloud for voice profiles: what a voiceprint whose clip
    /// isn't confirmed in iCloud (`voiceSourcesConfirmedInCloud`) learned from, followed as `voiceProtectedMeetings` is,
    /// the Trash included. What cleaning superseded originals out of iCloud leaves alone (docs/icloud-sync.md, "Voice
    /// clips").
    public func meetingsHoldingOriginalsInICloud() async -> Set<UUID> {
        await voiceProtectedMeetings(lineage: await trashedMeetings(), requiringUpload: true).meetings
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
    /// library) are hashed, and recorded whole with their stamp when their bytes are the clip's digest. `shouldContinue`
    /// stops it between files.
    public func verifyVoiceClips(shouldContinue: () -> Bool = { true }) async {
        guard let state = voiceClipState() else { return }
        for meeting in meetings {
            for clip in meeting.voiceClips ?? [] {
                guard shouldContinue(), !Task.isCancelled else { return }
                guard let url = clip.fileURL(in: meeting.id, root: rootURL), let stamp = Self.stamp(url),
                      state.verified[Self.verifiedKey(meeting.id, clip)] != .init(sha256: clip.sha256, stamp: stamp),
                      (try? await AudioDigest.sha256(contentsOf: url)) == clip.sha256, Self.stamp(url) == stamp else { continue }
                changeVoiceClipState { $0.verified[Self.verifiedKey(meeting.id, clip)] = .init(sha256: clip.sha256, stamp: stamp) }
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
    /// replaced while it's still here. Only for recordings that may soon be replaced or let go: a compressed one, or one
    /// in a conversation whose last activity is before `cutoff` (nil: compressed ones only). The original is hashed
    /// against the track first and must be unchanged (its stamp) after the cut; the clip is checked sample by sample
    /// against it (`VoiceClipAudio.extract`), placed under a name of its own in the conversation's folder, hashed again,
    /// and only then named by the conversation (under the lock, with the recording and the speaker's passages still the
    /// ones it was cut for), durably, without changing its edit date. At most `limit` recordings are read; a source that
    /// can't be cut waits (refused until its original or passages change; failed: 6 hours, doubling), so it doesn't take
    /// a pass's place again; `shouldContinue` stops it between recordings. A clip held whole that no longer holds the
    /// speaker's passages, with no lossless original here to cut it again, is marked stale. Anything that fails leaves
    /// the recording held back as before. Returns clips made.
    @discardableResult
    public func makeVoiceClips(olderThan cutoff: Date?, now: Date = Date(), limit: Int = 3, shouldContinue: () -> Bool = { true }) async -> Int {
        guard isLoaded, let store, voiceClipState() != nil else { return 0 }
        voiceClipsInFlight += 1
        defer { voiceClipsInFlight -= 1 }
        await verifyVoiceClips(shouldContinue: shouldContinue)
        let plan = VoiceClips.plan(metadata: metadata, meetings: meetings)
        guard plan.readable, let state = voiceClipState() else { return 0 }
        let covered = clipsHeldAndCurrent()
        let held = Dictionary(heldVoiceClips(state).map { ($0.clip.source(in: $0.meeting.id).key, $0.clip) }, uniquingKeysWith: { a, _ in a })
        let wanted = Dictionary(grouping: plan.wanted.filter { !covered.contains($0.key) }.values) { "\($0.meetingID.uuidString)|\($0.trackID.uuidString)" }
        var made = 0, read = 0
        for group in wanted.keys.sorted() {
            guard read < limit, shouldContinue(), !Task.isCancelled else { break }
            guard let first = wanted[group]?.first, let meeting = meeting(first.meetingID),
                  let track = meeting.tracks.first(where: { $0.id == first.trackID }) else { continue }
            let sources = (wanted[group] ?? []).sorted { $0.key < $1.key }
            let original: (path: String, sha256: String) = track.encoding.map { ($0.previousRelativePath, $0.previousSHA256) }
                ?? (track.relativePath, track.sha256)
            guard !original.sha256.isEmpty, let url = try? await store.audioURL(for: RecordingTrack(relativePath: original.path, fileName: ""), in: meeting.id) else { continue }
            guard SyncFilesProbe.isRegularFile(url) else {
                // No lossless original here: a clip that no longer holds the speaker's passages is all there is. Kept, and
                // marked so nothing takes it for that speaker's speech.
                let stale = sources.compactMap { held[$0.key] }.filter { $0.stale != true }.map(\.id)
                if !stale.isEmpty { await markStale(Set(stale), in: meeting.id) }
                continue
            }
            let due = track.isCompressed || cutoff.map { RecordingCompressionEligibility.lastActivity(of: meeting) <= $0 } == true
            // Nothing to cut (every passage talked over) gives no clip, and the recording stays as captured: decided
            // from the transcript, before any file is read.
            let jobs = sources.map { ($0, VoiceClips.spans(for: $0, in: meeting)) }.filter { !$0.1.isEmpty }
                .filter { !Self.waits(state.attempts[$0.0.key], basis: Self.basis(original.sha256, $0.1), now: now) }
            guard due, !jobs.isEmpty else { continue }
            read += 1
            guard let stamp = Self.stamp(url), (try? await AudioDigest.sha256(contentsOf: url)) == original.sha256 else {
                Self.clipLog.error("No voice clips from \(track.id.uuidString, privacy: .public): its original isn't the recording's bytes")
                for (source, spans) in jobs { rememberClipFailure(source.key, basis: Self.basis(original.sha256, spans), refused: false, now: now) }
                continue
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

    /// Marks these clips (by ID) of a conversation stale, durably, without changing its edit date.
    private func markStale(_ ids: Set<String>, in meetingID: UUID) async {
        await acquireLock()
        defer { releaseLock() }
        updateKeepingEditDate(meetingID) { meeting in
            guard var clips = meeting.voiceClips else { return }
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
            // Nothing awaited from here to the conversation naming it: the recording still has this original, the speaker's
            // passages are still the ones cut, and the clip's file is still the one hashed.
            guard let meeting = meeting(source.meetingID), let track = meeting.tracks.first(where: { $0.id == source.trackID }),
                  track.sha256 == originalSHA256 || track.encoding?.previousSHA256 == originalSHA256,
                  VoiceClips.spans(for: source, in: meeting) == spans, Self.stamp(destination) == clipStamp, voiceClipState() != nil else {
                throw VoiceClipChanged()
            }
            changeVoiceClipState { $0.verified[Self.verifiedKey(source.meetingID, clip)] = .init(sha256: clip.sha256, stamp: clipStamp) }
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
    /// voiceprint of a profile that still exists names its source (matched by the clip's own conversation, recording,
    /// and speaker: the profile deleted, or the speaker taken out of it: removed, forgotten, renamed to a placeholder,
    /// Not <name>), measured by the wall clock and, in the same boot, the continuous clock (`clock`); a voiceprint naming
    /// it again before then (an Undo, on any device) keeps it. The conversation stops naming it first, durably (and the
    /// edit syncs, so every Mac lets its copy go), then the file goes. Only clips of the library's conversations: a
    /// conversation in the Trash keeps its clips with its recordings until it's restored or its files are deleted. Only
    /// while every profile and voiceprint record and this Mac's record can be read, and, in a synced library, under the
    /// lock with this Mac's settings the library's (`settingsAreCurrent`); with `deleting` false (at launch, before sync
    /// has brought the library's settings), nothing goes but temporaries. Clip files a conversation doesn't name are
    /// swept too: a temporary (no clip is being made), and, a day old and not named by what sync last applied here, one
    /// whose source has a newer clip or no voiceprint (one a voiceprint names with no clip named stays: it may be all
    /// there is of a record an older Daybook's merge dropped, and a cut of it again takes the same name). Returns how
    /// many named clips were deleted.
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
        // From here, nothing is awaited until the conversations are saved: no clip can be started, placed, or named meanwhile.
        guard voiceClipsInFlight == 0, var state = voiceClipState() else { return 0 }
        let prints = deleting ? VoiceClips.counting(metadata) : nil
        let wanted = prints.map { _ in Set(VoiceClips.plan(metadata: metadata, meetings: meetings).wanted.values.map { "\($0.meetingID.uuidString)|\($0.key)" }) } ?? []
        var going: [(meetingID: UUID, clip: VoiceClip)] = []
        var present = Set<String>()
        for meeting in meetings {
            for clip in meeting.voiceClips ?? [] {
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
        var deleted = 0
        if !going.isEmpty {
            let byMeeting = Dictionary(grouping: going, by: \.meetingID)
            for (meetingID, clips) in byMeeting {
                let ids = Set(clips.map(\.clip.id))
                updateKeepingEditDate(meetingID) { meeting in
                    let kept = (meeting.voiceClips ?? []).filter { !ids.contains($0.id) }
                    meeting.voiceClips = kept.isEmpty ? nil : kept
                }
            }
            do {
                try await flushDurably(Set(byMeeting.keys))
                for (meetingID, clip) in going {
                    guard let url = clip.fileURL(in: meetingID, root: rootURL) else { continue }
                    do {
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                        deleted += 1
                    } catch {
                        Self.clipLog.error("Kept a voice clip's file: \(error.localizedDescription, privacy: .public)")
                    }
                    state.verified[Self.verifiedKey(meetingID, clip)] = nil
                    state.orphaned[clip.source(in: meetingID).key] = nil
                }
            } catch {
                // Not saved: the conversations still name them on disk, so their files stay; asked again next pass.
                Self.clipLog.error("Kept voice clips: \(error.localizedDescription, privacy: .public)")
            }
        }
        await sweepUnnamedVoiceClips(state: &state, now: now, deleting: deleting, wanted: wanted)
        // What this Mac recorded of files that are gone, or that no conversation names, is forgotten.
        let named = Set(meetings.flatMap { meeting in (meeting.voiceClips ?? []).map { Self.verifiedKey(meeting.id, $0) } })
        state.verified = state.verified.filter { named.contains($0.key) }
        if state != voiceClipState() {
            do { try saveVoiceClipState(state) } catch { Self.clipLog.error("Couldn't save the voice clip record: \(error.localizedDescription, privacy: .public)") }
        }
        return deleted
    }

    /// Files in the library's conversations' `Originals/VoiceClips/` that no clip names (`reconcileVoiceClips`). `wanted`:
    /// each conversation's sources a voiceprint names, as `<conversation ID>|<key>`.
    private func sweepUnnamedVoiceClips(state: inout VoiceClipState, now: Date, deleting: Bool, wanted: Set<String>) async {
        for meeting in meetings {
            let folder = rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(VoiceClip.folder)", isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !names.isEmpty else { continue }
            let clips = meeting.voiceClips ?? []
            let named = Set(clips.map(\.relativePath))
            let history = deleting ? await sync?.engine?.voiceClipFilesInHistory(of: meeting.id) ?? [] : []
            let newer = Set(clips.map { $0.source(in: meeting.id).key })
            var swept = false
            for name in names where !named.contains("\(VoiceClip.folder)/\(name)") {
                let url = folder.appendingPathComponent(name)
                if name.hasPrefix(VoiceClips.temporaryPrefix) {
                    swept = (try? FileManager.default.removeItem(at: url)) != nil || swept
                    continue
                }
                let key = String(name.prefix(32))
                guard deleting, name.hasSuffix(".caf"), !name.hasPrefix("."), !history.contains("\(VoiceClip.folder)/\(name)"),
                      newer.contains(key) || !wanted.contains("\(meeting.id.uuidString)|\(key)"),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true,
                      let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= VoiceClips.orphanGrace else { continue }
                swept = (try? FileManager.default.removeItem(at: url)) != nil || swept
            }
            if swept { try? DurableFiles.synchronize([folder]) }
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

    public func voiceSample(for print: Voiceprint) async -> VoiceSample? {
        let conversation = meeting(print.meetingID)
        guard let conversation, let source = VoiceClips.source(of: print, in: conversation),
              let track = conversation.tracks.first(where: { $0.id == source.trackID }) else { return nil }
        let spans = VoiceClips.spans(for: source, in: conversation)
        let original: (path: String, sha256: String) = track.encoding.map { ($0.previousRelativePath, $0.previousSHA256) } ?? (track.relativePath, track.sha256)
        if !spans.isEmpty, !original.sha256.isEmpty, let url = try? await audioURL(for: RecordingTrack(relativePath: original.path, fileName: ""), in: conversation.id),
           SyncFilesProbe.isRegularFile(url), (try? await AudioDigest.sha256(contentsOf: url)) == original.sha256 {
            return VoiceSample(url: url, spans: spans, isClip: false)
        }
        guard clipsHeldAndCurrent().contains(source.key), let clip = conversation.voiceClip(for: source),
              let url = clip.fileURL(in: conversation.id, root: rootURL) else { return nil }
        return VoiceSample(url: url, spans: clip.spansInClip, isClip: true)
    }
}
