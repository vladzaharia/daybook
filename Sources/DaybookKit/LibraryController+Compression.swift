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

    /// Where a compressed copy goes in its conversation's folder (made if it isn't there).
    private func copyURL(_ relativePath: String, in meetingID: UUID) async throws -> URL {
        let url = try await audioURL(for: RecordingTrack(relativePath: relativePath, fileName: ""), in: meetingID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// Replaces these recordings of a conversation with verified copies; the caller found it eligible. Each is made and
    /// checked first (off the main actor, without the lock), then, under the library lock, put at its own path and named
    /// by its track, with the original's identity in `encoding`, and saved durably. The originals stay until
    /// `finishCompressions` lets them go. `stillAllowed` is asked again under the lock (the setting, what's going on with
    /// the conversation now): a no throws the copy away. Returns the tracks compressed; one that couldn't be is left
    /// exactly as it was, with one line in the log.
    @discardableResult
    public func compressRecordings(_ trackIDs: [UUID], in meetingID: UUID, device: String?, now: Date = Date(),
                                   stillAllowed: (Meeting) -> Bool = { _ in true }) async -> [UUID] {
        compressionsInFlight += 1
        defer { compressionsInFlight -= 1 }
        var compressed: [UUID] = []
        for trackID in trackIDs {
            if Task.isCancelled || recordingCompression == .never { break }
            guard let track = meeting(meetingID)?.tracks.first(where: { $0.id == trackID }), track.encoding == nil,
                  let source = try? await audioURL(for: track, in: meetingID),
                  let folder = try? await copyURL(RecordingCompression.relativePath(trackID: trackID, sha256: track.sha256), in: meetingID)
                    .deletingLastPathComponent() else { continue }
            let prepared: AudioCompressor.PreparedCopy
            do {
                prepared = try await AudioCompressor.prepareCopy(of: source, expectedSHA256: track.sha256, in: folder)
                try compressionFault?(.prepared)
            } catch {
                if !(error is CancellationError) { Self.log.error("Kept \(trackID.uuidString, privacy: .public) as it was: \(error.localizedDescription, privacy: .public)") }
                continue
            }
            do {
                if try await replace(trackID, in: meetingID, with: prepared, expecting: track, device: device, now: now, stillAllowed: stillAllowed) {
                    compressed.append(trackID)
                }
            } catch {
                try? FileManager.default.removeItem(at: prepared.url)
                Self.log.error("Kept \(trackID.uuidString, privacy: .public) as it was: \(error.localizedDescription, privacy: .public)")
            }
        }
        return compressed
    }

    /// Whether a compression may go on now, asked under the lock: not cancelled, the library's choice still allows it,
    /// nothing waits for the lock (an import, a move, a sync), the conversation isn't being merged, and the caller agrees.
    private func mayReplace(in meeting: Meeting, stillAllowed: (Meeting) -> Bool) -> Bool {
        !Task.isCancelled && recordingCompression != .never && lockWaiterCount == 0 && !mergingIDs.contains(meeting.id) && stillAllowed(meeting)
    }

    /// Puts a prepared copy in place of its recording, under the lock. False when the recording changed meanwhile, or the
    /// compression isn't allowed any more (the copy is thrown away).
    private func replace(_ trackID: UUID, in meetingID: UUID, with prepared: AudioCompressor.PreparedCopy, expecting before: RecordingTrack,
                         device: String?, now: Date, stillAllowed: (Meeting) -> Bool) async throws -> Bool {
        await acquireLock()
        defer { releaseLock() }
        guard let conversation = meeting(meetingID), let current = conversation.tracks.first(where: { $0.id == trackID }),
              RecordingCompression.File(current) == RecordingCompression.File(before), current.encoding == nil,
              mayReplace(in: conversation, stillAllowed: stillAllowed) else {
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
        let encoding = TrackEncoding(method: prepared.plan.method, rule: prepared.plan.rule, sourceFormat: prepared.sourceFormat,
                                     previousSHA256: current.sha256, previousRelativePath: current.relativePath,
                                     previousFileName: current.fileName, previousSize: prepared.sourceSize, size: prepared.size,
                                     encodedAt: now, device: device)
        let stem = (current.fileName as NSString).deletingPathExtension
        let name = (stem.isEmpty ? trackID.uuidString : stem) + ".m4a"
        let alignmentsBefore = conversation.audioAlignments
        // Not an edit: the conversation's edit date (and so its age) stays.
        updateKeepingEditDate(meetingID) { meeting in
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
        do {
            try await flushDurably([meetingID])
        } catch {
            // Not saved: memory goes back to naming the original, so nothing reads or lets go by a track the disk doesn't
            // hold. The copy no track names is deleted at the next reconcile.
            updateKeepingEditDate(meetingID) { meeting in
                guard let index = meeting.tracks.firstIndex(where: { $0.id == trackID }) else { return }
                RecordingCompression.File(before).apply(to: &meeting.tracks[index])
                meeting.audioAlignments = alignmentsBefore
            }
            throw error
        }
        try compressionFault?(.saved)
        Self.log.info("Compressed \(trackID.uuidString, privacy: .public): \(prepared.sourceSize) to \(prepared.size) bytes, \(prepared.plan.method, privacy: .public)")
        return true
    }

    /// A file's stamp, to tell whether it changed between being hashed and being deleted.
    private static func stamp(_ url: URL) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ["\(attributes[.size] ?? "")", "\(attributes[.modificationDate] ?? "")", "\(attributes[.systemFileNumber] ?? "")"]
    }

    /// One file found deletable, with what made it so, re-checked under the lock.
    private struct Removal {
        var meetingID: UUID
        var trackID: UUID
        var file: RecordingCompression.File
        var url: URL
        var stamp: [String]
        var isOriginal: Bool
    }

    /// Lets go of originals whose compressed copies have replaced them, here or on another device, and of copies nothing
    /// names (a compression interrupted before its track named the copy, or another device's copy that lost a merge).
    /// An original is deleted only when all hold: the library's choice isn't Never; the track saved on disk names the copy;
    /// the copy is here and its bytes have the track's SHA-256; the original's bytes have `previousSHA256`; no other track
    /// names the original's path; and, when the library syncs, iCloud reports the copy uploaded (an original is never
    /// deleted while the library synced before and isn't connected now). A copy no track names goes only once the file the
    /// track names is here with its SHA-256. Files are hashed without the lock; under it, the track and each file's stamp
    /// are checked again before anything is deleted. Cancellable. `mayTouch` says a conversation isn't in use. Returns how
    /// many files were deleted.
    @discardableResult
    public func finishCompressions(removingOriginals: Bool = true, mayTouch: (UUID) -> Bool = { _ in true }) async -> Int {
        guard isLoaded, let store else { return 0 }
        let state = compressionSync
        guard state != .unknown else { return 0 }
        // Under Never, originals stay (a compressed track keeps naming its copy); a later choice that allows it finishes them.
        let originalsMayGo = removingOriginals && recordingCompression != .never
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
                guard let copy = try? await store.audioURL(for: track, in: meeting.id), SyncFilesProbe.isRegularFile(copy),
                      (try? await AudioDigest.sha256(contentsOf: copy)) == track.sha256 else { continue }
                guard let stamp = Self.stamp(original),
                      (try? await AudioDigest.sha256(contentsOf: original)) == encoding.previousSHA256 else { continue }
                found.append(Removal(meetingID: meeting.id, trackID: track.id, file: .init(track), url: original, stamp: stamp, isOriginal: true))
            }
        }
        guard !found.isEmpty, !Task.isCancelled else { return 0 }
        await acquireLock()
        defer { releaseLock() }
        var deleted = 0
        for removal in found {
            if Task.isCancelled { break }
            // Nothing changed since it was checked: the track still names the same file, and the file is the one hashed.
            guard removal.isOriginal ? recordingCompression != .never : true,
                  let track = meeting(removal.meetingID)?.tracks.first(where: { $0.id == removal.trackID }),
                  RecordingCompression.File(track) == removal.file, Self.stamp(removal.url) == removal.stamp else { continue }
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
                  let current = try? await store.audioURL(for: track, in: meeting.id), SyncFilesProbe.isRegularFile(current),
                  (try? await AudioDigest.sha256(contentsOf: current)) == track.sha256 else { continue }
            let url = originals.appendingPathComponent(name)
            guard let stamp = Self.stamp(url) else { continue }
            found.append(Removal(meetingID: meeting.id, trackID: id, file: .init(track), url: url, stamp: stamp, isOriginal: false))
        }
        return found
    }

    /// At launch, before any compression starts: deletes temporary copies a compression left when the app quit or
    /// crashed (in the library and the Trash), and copies no track names (a compression stopped before its track named
    /// the copy). Originals are let go only by `finishCompressions` on a Mac's pass, which honours the setting and the
    /// first-run wait.
    public func reconcileCompressions() async {
        guard isLoaded, compressionsInFlight == 0 else { return }
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
