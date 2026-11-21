import DaybookCore
import Foundation
import OSLog

/// Where a compression can be stopped by a crash, in order (tests stop it at each one).
public enum RecordingCompressionStep: Sendable {
    /// The copy is made, verified, and flushed, hidden beside the recording.
    case prepared
    /// The speech model heard the original and the copy alike (`TranscriptAgreement`).
    case listened
    /// The copy is at its own path; the track still names the original.
    case renamed
    /// The track names the copy, durably; the original is still here.
    case saved
    /// The files to let go are hashed; the lock isn't taken yet.
    case checked
    /// The original is about to be let go.
    case removingOriginal
}

/// How a Mac hears a recording for the transcript quality bar (`TranscriptAgreement`): its transcription model, and a
/// call that transcribes spans of a file through processing's own level path (DaybookIntelligence's `SpanTranscription`).
public struct RecordingCompressionListener: Sendable {
    /// The model's ID (`ModelReference.id`).
    public var model: String
    /// It transcribes the same audio the same way every time (Parakeet), so the tight bar applies.
    public var isDeterministic: Bool
    /// One transcript per span, in order. Cancellable.
    public var transcribe: @Sendable (_ audio: URL, _ spans: [ClosedRange<TimeInterval>]) async throws -> [String]

    public init(model: String, isDeterministic: Bool, transcribe: @escaping @Sendable (URL, [ClosedRange<TimeInterval>]) async throws -> [String]) {
        self.model = model; self.isDeterministic = isDeterministic; self.transcribe = transcribe
    }
}

/// Compress Older Recordings (docs/architecture.md, "Compressing older recordings"): replacing a conversation's
/// recordings with verified AAC copies, and letting the originals go only once nothing can need them. Every step can be
/// interrupted and is safe to run again: the original is deleted last, only when the copy is named durably by the
/// track, verified, and (when the library syncs) uploaded to iCloud.
extension LibraryController {
    private static let log = Logger(subsystem: "local.daybook", category: "compression")

    /// Whether this library's recordings may be replaced here without iCloud's copy to wait for.
    public enum CompressionSync: Equatable, Sendable {
        /// The library never synced from this device: nothing in iCloud to wait for.
        case local
        /// Syncing now: an original goes only once its copy is uploaded.
        case connected
        /// It synced and isn't connected now (off, signed out, paused): nothing is replaced or let go meanwhile.
        case unknown
    }

    public var compressionSync: CompressionSync {
        if sync?.folder != nil, sync?.engine != nil { return .connected }
        return hasSyncedBefore ? .unknown : .local
    }

    /// A checkpoint in `Sync/` says this library synced from here once.
    private var hasSyncedBefore: Bool {
        let folder = rootURL.appendingPathComponent("Sync", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasSuffix(".json") && $0 != "audio-cache.json" && $0 != "sealing.json" }
    }

    /// What this device finds of a conversation's files: each one's bytes checked against its SHA-256 (hashed off the
    /// main actor), whether iCloud reports it uploaded, and how it's stored.
    public func compressionFacts(for meeting: Meeting) async -> [UUID: RecordingCompressionEligibility.TrackFacts] {
        let state = compressionSync
        var facts: [UUID: RecordingCompressionEligibility.TrackFacts] = [:]
        for track in meeting.tracks {
            guard let url = try? await audioURL(for: track, in: meeting.id), SyncFilesProbe.isRegularFile(url) else { continue }
            let digest = try? await AudioDigest.sha256(contentsOf: url)
            var uploaded: Bool?
            switch state {
            case .local: uploaded = nil
            case .connected: uploaded = await sync?.engine?.isObjectUploaded(track.sha256) ?? false
            case .unknown: uploaded = false
            }
            let storage = await Task.detached(priority: .utility) { AudioCompressor.storage(of: url) }.value
            facts[track.id] = .init(isVerified: digest == track.sha256 && !track.sha256.isEmpty, isUploaded: uploaded, storage: storage)
        }
        return facts
    }

    /// Where a compressed copy goes in its conversation's folder (made if it isn't there).
    private func copyURL(_ relativePath: String, in meetingID: UUID) async throws -> URL {
        let url = try await audioURL(for: RecordingTrack(relativePath: relativePath, fileName: ""), in: meetingID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    // MARK: Refusals and failures remembered

    /// What this Mac remembers of a recording it didn't compress, by the original's SHA-256.
    public struct CompressionAttempts: Codable, Equatable, Sendable {
        /// The rule a verdict refused it under (`AudioCompressor.Refusal.isVerdict`, or the transcript bar): it isn't
        /// encoded again until the rule changes.
        public var refusedUnderRule: Int?
        /// Failures that may not happen another time (reading, encoding, the model, a check that couldn't be made), in a
        /// row, and the last one's date: it waits `failureWait` before it's tried again.
        public var failures: Int?
        public var lastFailure: Date?
    }

    /// Kept beside the library, never synced: what one Mac's files and model did says nothing of another's.
    private var attemptsURL: URL { rootURL.appendingPathComponent("compression-refusals.json") }

    public func compressionAttempts() -> [String: CompressionAttempts] {
        guard let data = try? Data(contentsOf: attemptsURL) else { return [:] }
        if let attempts = try? JSONDecoder().decode([String: CompressionAttempts].self, from: data) { return attempts }
        // The first shape of the file: refusals alone, by rule.
        let refusals = (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
        return refusals.mapValues { CompressionAttempts(refusedUnderRule: $0) }
    }

    /// How long a recording waits after `failures` failures in a row: 6 hours, doubling, at most 30 days.
    public static func failureWait(_ failures: Int) -> TimeInterval {
        min(6 * 3_600 * pow(2, Double(max(0, failures - 1))), 30 * 86_400)
    }

    /// The recording was refused under the current rule.
    public func compressionWasRefused(_ track: RecordingTrack) -> Bool {
        compressionAttempts()[track.sha256]?.refusedUnderRule == RecordingCompressionTable.rule
    }

    /// Recordings (by SHA-256) not to compress now: refused under the current rule, or waiting after a failure.
    public func compressionHeldBack(now: Date) -> Set<String> {
        Set(compressionAttempts().filter { _, attempts in
            if attempts.refusedUnderRule == RecordingCompressionTable.rule { return true }
            guard let failures = attempts.failures, failures > 0, let last = attempts.lastFailure else { return false }
            return now < last.addingTimeInterval(Self.failureWait(failures))
        }.keys)
    }

    private func rememberAttempt(_ track: RecordingTrack, _ change: (inout CompressionAttempts?) -> Void) {
        var attempts = compressionAttempts()
        change(&attempts[track.sha256])
        if let data = try? JSONEncoder().encode(attempts) { try? DurableFiles.write(data, to: attemptsURL) }
    }

    // MARK: Compressing

    /// Replaces these recordings of a conversation with verified copies; the caller found it eligible. Each is made and
    /// checked first (off the main actor, without the lock), heard by the speech model against the original when the
    /// track has speech (`TranscriptAgreement`; with speech and no `listener`, the track waits for a pass that has one),
    /// then, under the library lock, put at its own path and named by its track, with the original's identity in
    /// `encoding`, and saved durably. The originals stay until `finishCompressions` lets them go. `stillAllowed` is asked
    /// again under the lock (the setting, what's going on with the conversation now): a no throws the copy away. A copy a
    /// verdict refuses (`Refusal.isVerdict`, or the transcript bar) is remembered with the rule and not made again until
    /// the rule changes; any other failure makes the recording wait (`failureWait`, from `now`). Returns the tracks
    /// compressed; one that couldn't be is left exactly as it was, with one line in the log.
    @discardableResult
    public func compressRecordings(_ trackIDs: [UUID], in meetingID: UUID, device: String?, now: Date = Date(),
                                   listener: RecordingCompressionListener? = nil,
                                   stillAllowed: (Meeting) async -> Bool = { _ in true }) async -> [UUID] {
        compressionsInFlight += 1
        defer { compressionsInFlight -= 1 }
        var compressed: [UUID] = []
        let heldBack = compressionHeldBack(now: now)
        for trackID in trackIDs {
            if Task.isCancelled || compressionPassAge == .never { break }
            guard let conversation = meeting(meetingID), let track = conversation.tracks.first(where: { $0.id == trackID }), track.encoding == nil,
                  !heldBack.contains(track.sha256),
                  // Speech is heard by the model before its copy may replace it: with none here this pass, it waits.
                  listener != nil || !TranscriptSample.hasSpeech(track, in: conversation),
                  let source = try? await audioURL(for: track, in: meetingID),
                  let folder = try? await copyURL(RecordingCompression.relativePath(trackID: trackID, sha256: track.sha256), in: meetingID)
                    .deletingLastPathComponent() else { continue }
            var prepared: AudioCompressor.PreparedCopy?
            do {
                let copy = try await AudioCompressor.prepareCopy(of: source, expectedSHA256: track.sha256, in: folder)
                prepared = copy
                try compressionFault?(.prepared)
                let check = try await listen(to: track, in: conversation, source: source, copy: copy.url, listener: listener)
                try compressionFault?(.listened)
                if try await replace(trackID, in: meetingID, with: copy, check: check, expecting: track, device: device, now: now,
                                     stillAllowed: stillAllowed) {
                    compressed.append(trackID)
                    rememberAttempt(track) { $0 = nil }
                }
            } catch {
                if let prepared { try? FileManager.default.removeItem(at: prepared.url) }
                if error is CancellationError || Task.isCancelled {
                    // Stopped: not a failure of the recording's.
                } else if (error as? AudioCompressor.Refusal)?.isVerdict == true || error is TranscriptDisagreement {
                    rememberAttempt(track) { $0 = CompressionAttempts(refusedUnderRule: RecordingCompressionTable.rule) }
                } else {
                    rememberAttempt(track) { attempts in
                        attempts = CompressionAttempts(refusedUnderRule: attempts?.refusedUnderRule, failures: (attempts?.failures ?? 0) + 1, lastFailure: now)
                    }
                }
                if !(error is CancellationError) {
                    Self.log.error("Kept \(trackID.uuidString, privacy: .public) as it was: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return compressed
    }

    /// The copy didn't say what the original says, as the speech model hears them: a verdict.
    struct TranscriptDisagreement: LocalizedError {
        var result: TranscriptAgreement.Result
        var errorDescription: String? {
            "The copy's transcript differs from the original's (\(Int(((result.disagreement ?? 1) * 1_000).rounded())) per mille of words)."
        }
    }

    /// The bar couldn't be applied this time (the model heard no words in the original where its transcript has speech,
    /// or answered for the wrong spans, or wasn't here): no verdict, so the recording waits and is tried again.
    struct TranscriptUnchecked: LocalizedError {
        var reason: String
        var errorDescription: String? { "The copy couldn't be checked by ear: \(reason)." }
    }

    /// The transcript quality bar: the same sample of the original and of the copy, through `listener`, compared word by
    /// word. Skipped, and said so, only when the track has no speech in its transcript.
    private func listen(to track: RecordingTrack, in meeting: Meeting, source: URL, copy: URL,
                        listener: RecordingCompressionListener?) async throws -> TranscriptCheck {
        let spans = TranscriptSample.spans(TranscriptSample.speech(of: track, in: meeting), duration: track.duration)
        guard !spans.isEmpty else { return TranscriptCheck(ran: false, skipped: "no speech") }
        guard let listener else { throw TranscriptUnchecked(reason: "no model") }
        let original = try await listener.transcribe(source, spans)
        try Task.checkCancellation()
        let copied = try await listener.transcribe(copy, spans)
        try Task.checkCancellation()
        guard original.count == spans.count, copied.count == spans.count else { throw TranscriptUnchecked(reason: "the model answered for other spans") }
        let result = TranscriptAgreement.judge(Array(zip(original, copied)).map { (original: $0.0, copy: $0.1) },
                                               bar: listener.isDeterministic ? .deterministic : .nondeterministic)
        guard result.words > 0 else { throw TranscriptUnchecked(reason: "no words heard in the original's speech") }
        guard result.passes else { throw TranscriptDisagreement(result: result) }
        return TranscriptCheck(ran: true, model: listener.model, sampleSeconds: spans.reduce(0) { $0 + $1.upperBound - $1.lowerBound },
                               disagreement: result.disagreement)
    }

    /// Whether a compression may go on now, asked under the lock: not cancelled, the library's choice still allows it,
    /// nothing waits for the lock (an import, a move, a sync), the conversation isn't being merged, and the caller agrees;
    /// and, since the caller's answer can take a while, not cancelled and not Never after it either.
    private func mayReplace(in meeting: Meeting, stillAllowed: (Meeting) async -> Bool) async -> Bool {
        guard !Task.isCancelled, compressionPassAge != .never, lockWaiterCount == 0, !mergingIDs.contains(meeting.id) else { return false }
        guard await stillAllowed(meeting) else { return false }
        return !Task.isCancelled && compressionPassAge != .never
    }

    /// Puts a prepared copy in place of its recording, under the lock. False when the recording changed meanwhile, or the
    /// compression isn't allowed any more (the copy is thrown away).
    private func replace(_ trackID: UUID, in meetingID: UUID, with prepared: AudioCompressor.PreparedCopy, check: TranscriptCheck,
                         expecting before: RecordingTrack, device: String?, now: Date, stillAllowed: (Meeting) async -> Bool) async throws -> Bool {
        await acquireLock()
        defer { releaseLock() }
        guard let conversation = meeting(meetingID), let current = conversation.tracks.first(where: { $0.id == trackID }),
              RecordingCompression.File(current) == RecordingCompression.File(before), current.encoding == nil,
              await mayReplace(in: conversation, stillAllowed: stillAllowed),
              // Still the same after the wait.
              meeting(meetingID)?.tracks.first(where: { $0.id == trackID }).map(RecordingCompression.File.init) == RecordingCompression.File(before) else {
            try? FileManager.default.removeItem(at: prepared.url)
            return false
        }
        let relativePath = RecordingCompression.relativePath(trackID: trackID, sha256: prepared.sha256)
        let destination = try await copyURL(relativePath, in: meetingID)
        if FileManager.default.fileExists(atPath: destination.path) {
            // The same name is the same bytes (it's named by them); anything else there is left alone.
            guard (try? await AudioDigest.sha256(contentsOf: destination)) == prepared.sha256 else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.removeItem(at: prepared.url)
        } else {
            try FileManager.default.moveItem(at: prepared.url, to: destination)
        }
        try DurableFiles.synchronize([destination.deletingLastPathComponent()])
        try compressionFault?(.renamed)
        // Asked once more with nothing awaited from here to the track naming the copy: stopped, or Never, since the copy
        // was put in place keeps the track naming the original (the copy no track names is swept later).
        guard !Task.isCancelled, compressionPassAge != .never else { return false }
        let encoding = TrackEncoding(method: prepared.plan.method, rule: prepared.plan.rule, sourceFormat: prepared.sourceFormat,
                                     previousSHA256: current.sha256, previousRelativePath: current.relativePath,
                                     previousFileName: current.fileName, previousSize: prepared.sourceSize, size: prepared.size,
                                     encodedAt: now, device: device, transcriptCheck: check)
        let stem = (current.fileName as NSString).deletingPathExtension
        let name = (stem.isEmpty ? trackID.uuidString : stem) + ".m4a"
        // Not an edit: the conversation's edit date (and so its age) stays.
        updateKeepingEditDate(meetingID) { meeting in
            guard let index = meeting.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            RecordingCompression.File(relativePath: relativePath, fileName: name, sha256: prepared.sha256, encoding: encoding)
                .apply(to: &meeting.tracks[index])
            // Measurements made on the original place the copy too: its timing is the original's.
            Self.moveDigests(of: trackID, from: current.sha256, to: prepared.sha256, in: &meeting)
        }
        do {
            try await flushDurably([meetingID])
        } catch {
            // Not saved: memory goes back to naming the original, so nothing reads or lets go by a track the disk doesn't
            // hold: the track's file fields, and the digests moved above, and nothing else (what arrived meanwhile stays).
            // The copy no track names is deleted at the next reconcile.
            updateKeepingEditDate(meetingID) { meeting in
                guard let index = meeting.tracks.firstIndex(where: { $0.id == trackID }),
                      RecordingCompression.File(meeting.tracks[index]).sha256 == prepared.sha256 else { return }
                RecordingCompression.File(before).apply(to: &meeting.tracks[index])
                Self.moveDigests(of: trackID, from: prepared.sha256, to: current.sha256, in: &meeting)
            }
            throw error
        }
        try compressionFault?(.saved)
        Self.log.info("Compressed \(trackID.uuidString, privacy: .public): \(prepared.sourceSize) to \(prepared.size) bytes, \(prepared.plan.method, privacy: .public)")
        return true
    }

    /// Legacy alignment measurements of one track, moved from one digest to another.
    private static func moveDigests(of trackID: UUID, from old: String, to new: String, in meeting: inout Meeting) {
        meeting.audioAlignments = meeting.audioAlignments?.map { record in
            var record = record
            if record.trackID == trackID, record.trackDigest == old { record.trackDigest = new }
            if record.referenceTrackID == trackID, record.referenceDigest == old { record.referenceDigest = new }
            return record
        }
    }

    // MARK: Letting go

    /// A file's stamp, to tell whether it changed between being hashed and being deleted: its volume and inode, its size,
    /// and its modification and status-change times to the nanosecond the file system keeps (a status change can't be
    /// set back, so bytes rewritten under their old modification date still show). Taken before the file is hashed; nil
    /// for anything but a regular file.
    static func stamp(_ url: URL) -> [Int64]? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), Int64(info.st_size),
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }

    /// One file found deletable, with what made it so, re-checked under the lock.
    private struct Removal {
        var meetingID: UUID
        var trackID: UUID
        var file: RecordingCompression.File
        var url: URL
        /// The path within the conversation's folder.
        var relativePath: String
        var stamp: [Int64]
        /// The file that stays in its place (the copy, for an original; the file the track names, for an unnamed copy),
        /// with its stamp when it was hashed.
        var kept: URL
        var keptStamp: [Int64]
        var isOriginal: Bool
    }

    /// Lets go of originals whose compressed copies have replaced them, here or on another device, and of copies nothing
    /// names (a compression interrupted before its track named the copy, or another device's copy that lost a merge).
    /// An original is deleted only when all hold: the library's choice isn't Never; in a synced library, this device has
    /// applied the library's settings since it connected (`settingsAreCurrent`); the track saved on disk names the copy;
    /// the copy is here and its bytes have the track's SHA-256; the original's bytes have `previousSHA256`; no other track
    /// names the original's path; and, when the library syncs, iCloud reports the copy uploaded (an original is never
    /// deleted while the library synced before and isn't connected now). A copy no track names goes only once the file
    /// the track names is here with its SHA-256. Files are hashed without the lock; under it, everything but the hashes is
    /// asked again (how the library syncs, the settings, the upload, the saved track, the choice, the track in memory, the
    /// other tracks' paths), and the file going and the file staying must both have the stamps they had when hashed
    /// (`stamp`). Cancellable. `mayTouch` says a conversation isn't in use. Returns how many files were deleted.
    @discardableResult
    public func finishCompressions(removingOriginals: Bool = true, mayTouch: (UUID) -> Bool = { _ in true }) async -> Int {
        guard isLoaded, let store else { return 0 }
        let state = compressionSync
        guard state != .unknown else { return 0 }
        // Under Never, originals stay (a compressed track keeps naming its copy); a later choice that allows it finishes them.
        var originalsMayGo = removingOriginals && compressionPassAge != .never
        if originalsMayGo, state == .connected, await !settingsAreCurrent() { originalsMayGo = false }
        var found: [Removal] = []
        for meeting in meetings where mayTouch(meeting.id) {
            if Task.isCancelled { return 0 }
            guard let folder = try? await store.meetingDirectory(for: meeting.id) else { continue }
            found += await unnamedCopies(of: meeting, in: folder, store: store)
            guard originalsMayGo, meeting.tracks.contains(where: \.isCompressed), let stored = try? await store.load(meeting.id) else { continue }
            for track in meeting.tracks {
                if Task.isCancelled { return 0 }
                guard let encoding = track.encoding, encoding.previousRelativePath != track.relativePath,
                      !meeting.tracks.contains(where: { $0.relativePath == encoding.previousRelativePath }),
                      let original = try? await store.audioURL(for: RecordingTrack(relativePath: encoding.previousRelativePath, fileName: ""), in: meeting.id),
                      SyncFilesProbe.isRegularFile(original) else { continue }
                // Durably named by the track, not only in memory.
                guard let saved = stored.tracks.first(where: { $0.id == track.id }),
                      RecordingCompression.File(saved) == RecordingCompression.File(track) else { continue }
                if state == .connected {
                    guard await sync?.engine?.isObjectUploaded(track.sha256) == true else { continue }
                }
                guard let copy = try? await store.audioURL(for: track, in: meeting.id), let copyStamp = Self.stamp(copy),
                      (try? await AudioDigest.sha256(contentsOf: copy)) == track.sha256 else { continue }
                guard let stamp = Self.stamp(original),
                      (try? await AudioDigest.sha256(contentsOf: original)) == encoding.previousSHA256 else { continue }
                found.append(Removal(meetingID: meeting.id, trackID: track.id, file: .init(track), url: original,
                                     relativePath: encoding.previousRelativePath, stamp: stamp, kept: copy, keptStamp: copyStamp, isOriginal: true))
            }
        }
        guard !found.isEmpty, !Task.isCancelled else { return 0 }
        do { try compressionFault?(.checked) } catch { return 0 }
        await acquireLock()
        defer { releaseLock() }
        var deleted = 0
        for removal in found {
            if Task.isCancelled { break }
            // Asked again with the lock held: the library syncs as it did, and for an original in a synced library, this
            // device's settings are still the library's, the copy is still uploaded, and the saved track still names it.
            guard compressionSync == state else { break }
            if removal.isOriginal {
                if state == .connected {
                    guard await settingsAreCurrent(), await sync?.engine?.isObjectUploaded(removal.file.sha256) == true else { continue }
                }
                guard let stored = try? await store.load(removal.meetingID),
                      stored.tracks.first(where: { $0.id == removal.trackID }).map(RecordingCompression.File.init) == removal.file else { continue }
            }
            // Then, with nothing awaited between these and the deletion: the choice, the track and the file it names, no
            // other track naming the file going, and both files (the one going, the one staying) the ones hashed.
            guard compressionSync == state, !removal.isOriginal || compressionPassAge != .never,
                  let conversation = meeting(removal.meetingID), let track = conversation.tracks.first(where: { $0.id == removal.trackID }),
                  RecordingCompression.File(track) == removal.file,
                  !conversation.tracks.contains(where: { $0.relativePath == removal.relativePath }),
                  Self.stamp(removal.kept) == removal.keptStamp,
                  Self.stamp(removal.url) == removal.stamp else { continue }
            do {
                if removal.isOriginal { try compressionFault?(.removingOriginal) }
                try FileManager.default.removeItem(at: removal.url)
                try? DurableFiles.synchronize([removal.url.deletingLastPathComponent()])
                deleted += 1
                Self.log.info("Let go of \(removal.isOriginal ? "the original" : "an unnamed copy", privacy: .public) of \(removal.trackID.uuidString, privacy: .public)")
            } catch {
                Self.log.error("Kept a file of \(removal.trackID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return deleted
    }

    /// Copies (`RecordingCompression.relativePath`) in a conversation's folder that none of its tracks names: the track
    /// still names the original (a compression stopped before saving), or names another copy (another device's won the
    /// merge). Only copies of a track of this conversation, by the name only Compress Older Recordings writes, and only
    /// while the file the track names is here with its SHA-256; if that file never arrives, the copy stays.
    private func unnamedCopies(of meeting: Meeting, in folder: URL, store: MeetingStore) async -> [Removal] {
        let originals = folder.appendingPathComponent("Originals", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: originals.path) else { return [] }
        let named = Set(meeting.tracks.map(\.relativePath))
        var found: [Removal] = []
        for name in names where name.hasSuffix(".m4a") && name.contains(".aac-") {
            let relativePath = "Originals/\(name)"
            // Exactly `<track ID>.aac-<16 hex>.m4a`, of a track of this conversation.
            guard !named.contains(relativePath), name.count == 36 + 5 + 16 + 4, let id = UUID(uuidString: String(name.prefix(36))),
                  name.dropFirst(36).hasPrefix(".aac-"), name.dropFirst(41).prefix(16).allSatisfy(\.isHexDigit),
                  let track = meeting.tracks.first(where: { $0.id == id }),
                  let current = try? await store.audioURL(for: track, in: meeting.id), let currentStamp = Self.stamp(current),
                  (try? await AudioDigest.sha256(contentsOf: current)) == track.sha256 else { continue }
            let url = originals.appendingPathComponent(name)
            guard let stamp = Self.stamp(url) else { continue }
            found.append(Removal(meetingID: meeting.id, trackID: id, file: .init(track), url: url, relativePath: relativePath,
                                 stamp: stamp, kept: current, keptStamp: currentStamp, isOriginal: false))
        }
        return found
    }

    /// A track this device compressed that names a copy no longer here, while its original still is (its bytes are
    /// `previousSHA256`): it names the original again, so the recording is whole. Only this device's own compressions
    /// (or any in a library that doesn't sync): another Mac's copy that hasn't downloaded yet is on its way.
    private func repairMissingCopies(store: MeetingStore) async {
        let thisDevice = compressionSync == .local ? nil : sync?.deviceID
        for meeting in meetings {
            for track in meeting.tracks {
                guard let encoding = track.encoding, encoding.device == thisDevice || compressionSync == .local,
                      let copy = try? await store.audioURL(for: track, in: meeting.id), !FileManager.default.fileExists(atPath: copy.path),
                      let original = try? await store.audioURL(for: RecordingTrack(relativePath: encoding.previousRelativePath, fileName: ""), in: meeting.id),
                      SyncFilesProbe.isRegularFile(original),
                      (try? await AudioDigest.sha256(contentsOf: original)) == encoding.previousSHA256 else { continue }
                updateKeepingEditDate(meeting.id) { meeting in
                    guard let index = meeting.tracks.firstIndex(where: { $0.id == track.id }), meeting.tracks[index].encoding == encoding else { return }
                    RecordingCompression.File(relativePath: encoding.previousRelativePath, fileName: encoding.previousFileName,
                                              sha256: encoding.previousSHA256, encoding: nil).apply(to: &meeting.tracks[index])
                    Self.moveDigests(of: track.id, from: track.sha256, to: encoding.previousSHA256, in: &meeting)
                }
                Self.log.error("Named the original of \(track.id.uuidString, privacy: .public) again: its copy is missing")
            }
        }
        try? await flushDurably()
    }

    /// At launch, before any compression starts: deletes temporary copies a compression left when the app quit or
    /// crashed (in the library and the Trash), points a track this device compressed back at its original when its copy
    /// is missing, and deletes copies no track names (a compression stopped before its track named the copy). Originals
    /// are let go only by `finishCompressions` on a Mac's pass, which honours the setting and the first-run wait.
    public func reconcileCompressions() async {
        guard isLoaded, compressionsInFlight == 0, let store else { return }
        for top in ["Meetings", "Trash"] {
            let root = rootURL.appendingPathComponent(top, isDirectory: true)
            for folder in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let originals = root.appendingPathComponent("\(folder)/Originals", isDirectory: true)
                let urls = FileManager.default.enumerator(at: originals, includingPropertiesForKeys: nil)?.allObjects.compactMap { $0 as? URL } ?? []
                for url in urls where url.lastPathComponent.hasPrefix(RecordingCompression.temporaryPrefix) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        await acquireLock()
        await repairMissingCopies(store: store)
        releaseLock()
        await finishCompressions(removingOriginals: false)
    }
}

/// Small file checks the compression steps share.
enum SyncFilesProbe {
    /// A regular file, not a symbolic link or folder.
    static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
