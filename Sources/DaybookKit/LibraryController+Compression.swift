import DaybookCore
import Foundation
import OSLog

/// Where a compression can be stopped by a crash, in order (tests stop it at each one).
public enum RecordingCompressionStep: Sendable {
    /// The copy is made, verified, and flushed, hidden beside the recording.
    case prepared
    /// The copy is at its own path; the track still names the original.
    case renamed
    /// The track names the copy, durably; the original is still here.
    case saved
    /// The original is about to be let go.
    case removingOriginal
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

    /// Replaces these recordings of a conversation with verified copies; the caller found it eligible. Each is made and
    /// checked first (off the main actor, without the lock), then, under the library lock, put at its own path and named
    /// by its track, with the original's identity in `encoding`, and saved durably. The originals stay until
    /// `finishCompressions` lets them go. Returns the tracks compressed; one that couldn't be is left exactly as it was,
    /// with one line in the log.
    @discardableResult
    public func compressRecordings(_ trackIDs: [UUID], in meetingID: UUID, device: String?, now: Date = Date()) async -> [UUID] {
        compressionsInFlight += 1
        defer { compressionsInFlight -= 1 }
        var compressed: [UUID] = []
        for trackID in trackIDs {
            if Task.isCancelled { break }
            guard let track = meeting(meetingID)?.tracks.first(where: { $0.id == trackID }), track.encoding == nil,
                  let source = try? await audioURL(for: track, in: meetingID) else { continue }
            let prepared: AudioCompressor.PreparedCopy
            do {
                prepared = try await AudioCompressor.prepareCopy(of: source, expectedSHA256: track.sha256, in: source.deletingLastPathComponent())
                try compressionFault?(.prepared)
            } catch {
                if !(error is CancellationError) { Self.log.error("Kept \(trackID.uuidString, privacy: .public) as it was: \(error.localizedDescription, privacy: .public)") }
                continue
            }
            do {
                if try await replace(trackID, in: meetingID, with: prepared, expecting: track, device: device, now: now) { compressed.append(trackID) }
            } catch {
                try? FileManager.default.removeItem(at: prepared.url)
                Self.log.error("Kept \(trackID.uuidString, privacy: .public) as it was: \(error.localizedDescription, privacy: .public)")
            }
        }
        return compressed
    }

    /// Puts a prepared copy in place of its recording, under the lock. False when the recording changed meanwhile (the
    /// copy is thrown away).
    private func replace(_ trackID: UUID, in meetingID: UUID, with prepared: AudioCompressor.PreparedCopy, expecting before: RecordingTrack,
                         device: String?, now: Date) async throws -> Bool {
        await acquireLock()
        defer { releaseLock() }
        // Stopped while it waited (recording or playback started): the copy goes, the recording stays.
        guard !Task.isCancelled, let current = meeting(meetingID)?.tracks.first(where: { $0.id == trackID }),
              RecordingCompression.File(current) == RecordingCompression.File(before), current.encoding == nil else {
            try? FileManager.default.removeItem(at: prepared.url)
            return false
        }
        let relativePath = RecordingCompression.relativePath(trackID: trackID, sha256: prepared.sha256)
        let source = try await audioURL(for: current, in: meetingID)
        let destination = source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            // The same name is the same bytes (it's named by them); anything else there is left alone.
            guard (try? await AudioDigest.sha256(contentsOf: destination)) == prepared.sha256 else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.removeItem(at: prepared.url)
        } else {
            try FileManager.default.moveItem(at: prepared.url, to: destination)
        }
        try DurableFiles.synchronize([destination.deletingLastPathComponent()])
        try compressionFault?(.renamed)
        let encoding = TrackEncoding(method: prepared.plan.method, sourceFormat: prepared.sourceFormat, previousSHA256: current.sha256,
                                     previousRelativePath: current.relativePath, previousFileName: current.fileName,
                                     previousSize: prepared.sourceSize, size: prepared.size, encodedAt: now, device: device)
        let name = ((current.fileName as NSString).deletingPathExtension.isEmpty ? trackID.uuidString : (current.fileName as NSString).deletingPathExtension) + ".m4a"
        update(meetingID) { meeting in
            guard let index = meeting.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            RecordingCompression.File(relativePath: relativePath, fileName: name, sha256: prepared.sha256, encoding: encoding)
                .apply(to: &meeting.tracks[index])
            // Measurements made on the original place the copy too: its timing is the original's.
            meeting.audioAlignments = meeting.audioAlignments?.map { record in
                var record = record
                if record.trackID == trackID, record.trackDigest == current.sha256 { record.trackDigest = prepared.sha256 }
                if record.referenceTrackID == trackID, record.referenceDigest == current.sha256 { record.referenceDigest = prepared.sha256 }
                return record
            }
        }
        try await flushDurably([meetingID])
        try compressionFault?(.saved)
        Self.log.info("Compressed \(trackID.uuidString, privacy: .public): \(prepared.sourceSize) to \(prepared.size) bytes, \(prepared.plan.method, privacy: .public)")
        return true
    }

    /// Lets go of originals whose compressed copies have replaced them, here or on another device, and of copies nothing
    /// names (a compression interrupted before its track named the copy, or another device's copy that lost a merge).
    /// An original is deleted only when all hold: the track saved on disk names the copy; the copy is here and its bytes
    /// have the track's SHA-256; the original's bytes have `previousSHA256`; no other track names the original's path;
    /// and, when the library syncs, iCloud reports the copy uploaded (an original is never deleted while the library
    /// synced before and isn't connected now). Under the library lock; `mayTouch` says a conversation isn't in use.
    /// Returns how many files were deleted.
    @discardableResult
    public func finishCompressions(removingOriginals: Bool = true, mayTouch: (UUID) -> Bool = { _ in true }) async -> Int {
        guard isLoaded, let store else { return 0 }
        let state = compressionSync
        guard state != .unknown else { return 0 }
        await acquireLock()
        defer { releaseLock() }
        var deleted = 0
        for meeting in meetings where mayTouch(meeting.id) {
            if Task.isCancelled { break }
            guard let folder = try? await store.meetingDirectory(for: meeting.id) else { continue }
            deleted += await removeUnnamedCopies(of: meeting, in: folder, store: store)
            guard removingOriginals, meeting.tracks.contains(where: \.isCompressed), let stored = try? await store.load(meeting.id) else { continue }
            for track in meeting.tracks {
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
                guard let copy = try? await store.audioURL(for: track, in: meeting.id), SyncFilesProbe.isRegularFile(copy),
                      (try? await AudioDigest.sha256(contentsOf: copy)) == track.sha256 else { continue }
                guard (try? await AudioDigest.sha256(contentsOf: original)) == encoding.previousSHA256 else { continue }
                do {
                    try compressionFault?(.removingOriginal)
                    try FileManager.default.removeItem(at: original)
                    try? DurableFiles.synchronize([original.deletingLastPathComponent()])
                    deleted += 1
                    Self.log.info("Let go of the original of \(track.id.uuidString, privacy: .public)")
                } catch {
                    Self.log.error("Kept the original of \(track.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return deleted
    }

    /// Copies (`RecordingCompression.relativePath`) in a conversation's folder that none of its tracks names: the
    /// track still names the original (a compression stopped before saving), or names another copy (another device's
    /// won the merge). Only copies of a track of this conversation, by the name only Compress Older Recordings writes,
    /// and only while what the track names is here.
    private func removeUnnamedCopies(of meeting: Meeting, in folder: URL, store: MeetingStore) async -> Int {
        let originals = folder.appendingPathComponent("Originals", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: originals.path) else { return 0 }
        let named = Set(meeting.tracks.map(\.relativePath))
        var removed = 0
        for name in names where name.hasSuffix(".m4a") && name.contains(".aac-") {
            let relativePath = "Originals/\(name)"
            // Exactly `<track ID>.aac-<16 hex>.m4a`, of a track of this conversation.
            guard !named.contains(relativePath), name.count == 36 + 5 + 16 + 4, let id = UUID(uuidString: String(name.prefix(36))),
                  name.dropFirst(36).hasPrefix(".aac-"), name.dropFirst(41).prefix(16).allSatisfy(\.isHexDigit),
                  let track = meeting.tracks.first(where: { $0.id == id }),
                  let current = try? await store.audioURL(for: track, in: meeting.id), SyncFilesProbe.isRegularFile(current) else { continue }
            if (try? FileManager.default.removeItem(at: originals.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// At launch, before any compression starts: deletes temporary copies a compression left when the app quit or
    /// crashed, and copies no track names (a compression stopped before its track named the copy). Originals are let go
    /// only by `finishCompressions` on a Mac's pass, which honours the setting and the first-run wait.
    public func reconcileCompressions() async {
        guard isLoaded, compressionsInFlight == 0 else { return }
        for meeting in meetings {
            let originals = rootURL.appendingPathComponent("Meetings/\(meeting.id.uuidString)/Originals", isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? [] where name.hasPrefix(RecordingCompression.temporaryPrefix) {
                try? FileManager.default.removeItem(at: originals.appendingPathComponent(name))
            }
        }
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
