import Darwin
import Foundation

public enum LibraryError: LocalizedError {
    case unsafePath(String), corruptMeeting(UUID), unsupportedSchema(Int), invalidAudio(String), invalidHighlight, invalidTranscript, trashedMeeting(UUID), missingMeeting(UUID), unsupportedHighlightSchema(Int), invalidHighlightSidecar
    case unreadableLibrarySettings
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "The library rejected an unsafe file path: \(path)"
        case .corruptMeeting: return "A conversation couldn’t be read. Its recordings are still in the library folder."
        case .unsupportedSchema: return "This library was made by a newer Daybook. Update Daybook to open it."
        case .invalidAudio(let name): return "\(name) has no readable audio."
        case .invalidHighlight: return "Highlight timestamps must be finite, nonnegative seconds."
        case .invalidTranscript: return "Transcript timestamps must be finite, ordered, nonnegative seconds."
        case .trashedMeeting: return "This conversation is in the Trash. Restore it to edit it."
        case .missingMeeting: return "This conversation isn’t in the library."
        case .unsupportedHighlightSchema(let version): return "Highlight sidecar version \(version) is not supported. This version of Daybook reads version 1."
        case .invalidHighlightSidecar: return "The JSON sidecar is not a Daybook highlights file. It must contain a highlights array with time in seconds and text for each marker."
        case .unreadableLibrarySettings: return "Your folders and templates can’t be saved until Daybook can read them."
        }
    }
}

public enum LibraryLocation {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daybook", isDirectory: true)
    }
}

/// The directory contains only local files. No network, cloud provider, or analytics dependencies.
public actor MeetingStore {
    public nonisolated let rootURL: URL
    public private(set) var warnings: [String] = []
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Each conversation as last read or written, with the stamp of the `meeting.json` it came from.
    /// While the file keeps that stamp, saving and loading use this instead of reading and decoding
    /// it again; a file anything else changed is read afresh.
    private var cache: [UUID: (meeting: Meeting, stamp: FileStamp)] = [:]
    /// Files and folders written since the last durability barrier (`synchronizeWrites`).
    private var unsynchronized = Set<URL>()
    /// `library.json`: whether it may be written, and whether it holds settings that were read.
    var libraryFile = LibraryFileState.unknown
    /// How many `meeting.json` files were read and decoded, and written (tests check the cache).
    private(set) var metadataReads = 0
    private(set) var metadataWrites = 0

    public init(rootURL: URL? = nil) throws {
        let root = (rootURL ?? LibraryLocation.defaultRoot).standardizedFileURL
        self.rootURL = root
        // Compact: a long transcript is several megabytes either way, and every version reads both.
        encoder.outputFormatting = [.sortedKeys]
        try LocalFiles.directory(root)
        try LocalFiles.directory(root.appendingPathComponent("Meetings", isDirectory: true))
    }

    public func meetingDirectory(for id: UUID) throws -> URL {
        guard !fm.fileExists(atPath: trashURL(for: id).path) else { throw LibraryError.trashedMeeting(id) }
        let meetings = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let directory = meetings.appendingPathComponent(id.uuidString, isDirectory: true)
        try LocalFiles.requireContained(directory, in: meetings)
        if !fm.fileExists(atPath: directory.path) {
            try LocalFiles.directory(directory)
            noteWrite(directory)
        }
        return directory
    }

    public func list() throws -> [Meeting] {
        warnings = []
        let directory = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var meetings: [Meeting] = []
        var listed = Set<UUID>()
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            listed.insert(id)
            do { meetings.append(try load(id)) }
            catch { warnings.append(error.localizedDescription) }
        }
        cache = cache.filter { listed.contains($0.key) }
        return meetings.sorted { $0.date > $1.date }
    }

    public func load(_ id: UUID) throws -> Meeting {
        let directory = try meetingDirectory(for: id)
        let primary = directory.appendingPathComponent("meeting.json")
        let backup = directory.appendingPathComponent("meeting.recovery.json")
        let stamp = FileStamp(primary)
        if let stamp, let cached = cache[id], cached.stamp == stamp { return cached.meeting }
        cache[id] = nil
        if let stamp, let bytes = try? Data(contentsOf: primary) {
            metadataReads += 1
            // Decoded once; the schema header is read only when the whole file doesn't decode.
            if let meeting = try? decoder.decode(Meeting.self, from: bytes) {
                // Never silently roll a future schema back to an older snapshot.
                if meeting.schemaVersion != 1 { throw LibraryError.unsupportedSchema(meeting.schemaVersion) }
                if (try? validate(meeting, expectedID: id)) != nil {
                    cache[id] = (meeting, stamp)
                    return meeting
                }
            } else if let header = try? decoder.decode(SchemaHeader.self, from: bytes), header.schemaVersion > 1 {
                throw LibraryError.unsupportedSchema(header.schemaVersion)
            }
        }
        if let bytes = try? Data(contentsOf: backup), let meeting = try? decoder.decode(Meeting.self, from: bytes) {
            metadataReads += 1
            try validate(meeting, expectedID: id)
            if fm.fileExists(atPath: primary.path) {
                let damaged = directory.appendingPathComponent("meeting.corrupt-\(UUID().uuidString).json")
                try fm.copyItem(at: primary, to: damaged)
            }
            try LocalFiles.atomicWrite(bytes, to: primary)
            noteWrite(primary)
            warnings.append("Recovered “\(meeting.title)” from its last saved copy.")
            if let stamp = FileStamp(primary) { cache[id] = (meeting, stamp) }
            return meeting
        }
        throw LibraryError.corruptMeeting(id)
    }

    /// Saves a snapshot, keeping the previous one as `meeting.recovery.json`. Recordings, model runs,
    /// correction history, and photos already stored are kept even when the snapshot lacks them. The
    /// stored version comes from the cache while `meeting.json` is unchanged, so a save reads nothing;
    /// a snapshot that changes nothing writes nothing.
    public func save(_ snapshot: Meeting) throws {
        try validate(snapshot, expectedID: snapshot.id)
        let directory = try meetingDirectory(for: snapshot.id)
        let primary = directory.appendingPathComponent("meeting.json")
        let backup = directory.appendingPathComponent("meeting.recovery.json")
        var meeting = snapshot
        var stored: Meeting?
        if fm.fileExists(atPath: primary.path) || fm.fileExists(atPath: backup.path) {
            // Recover and validate before accepting a new snapshot. A corrupt current file must not
            // cause an older queued save to detach originals described by the recovery snapshot.
            let current = try load(snapshot.id)
            // Captured originals, model runs, and correction history are append-only. A notes snapshot
            // queued during a concurrent import must not detach a newly stored recording.
            meeting = preservingArtifacts(from: current, in: snapshot)
            stored = current
        }
        if let stored, stored == meeting, fm.fileExists(atPath: backup.path) { return }
        let bytes = try encoder.encode(meeting)
        if stored != nil, FileStamp(primary) != nil {
            // `load` validated what `meeting.json` holds (or rewrote it from the recovery copy), so
            // it becomes the recovery copy by a rename instead of being encoded and written again.
            try replaceKeepingPrevious(primary, backup: backup, with: bytes)
        } else {
            try LocalFiles.atomicWrite(bytes, to: primary)
            if !fm.fileExists(atPath: backup.path) {
                // First-save recovery copy also protects newly imported originals.
                try LocalFiles.atomicWrite(bytes, to: backup)
            }
        }
        metadataWrites += 1
        noteWrite(primary); noteWrite(backup)
        if let stamp = FileStamp(primary) { cache[snapshot.id] = (meeting, stamp) }
    }

    /// Puts `bytes` in `primary` and the file it replaces in `backup`. The swap is one step
    /// (`RENAME_SWAP`), so `primary` always exists; an interruption before the second rename leaves
    /// the previous recovery copy, which is older but valid.
    private func replaceKeepingPrevious(_ primary: URL, backup: URL, with bytes: Data) throws {
        let temporary = primary.deletingLastPathComponent().appendingPathComponent(".meeting-\(UUID().uuidString).json")
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { try? fm.removeItem(at: temporary) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if renamex_np(temporary.path, primary.path, UInt32(RENAME_SWAP)) == 0 {
            // `temporary` now holds the previous snapshot.
            guard rename(temporary.path, backup.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backup.path]) }
        } else {
            // A file system without swaps: copy the previous snapshot, then replace.
            try LocalFiles.atomicWrite(Data(contentsOf: primary), to: backup)
            guard rename(temporary.path, primary.path) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: primary.path]) }
        }
    }

    /// Advisory lookup before creating a new meeting, useful for repeated incoming-folder deliveries.
    /// Explicitly attaching an audio file to a different meeting remains possible.
    public func existingMeeting(containingAudioAt url: URL) async throws -> Meeting? {
        let digest = try await BlockingFileWork.sha256(url)
        return await verifiedMeeting(withDigest: digest, among: try list())
    }

    /// The first of `candidates` (the library's conversations, as the caller has them) holding a
    /// recording with this digest, checked against the file itself: a stale digest in the metadata
    /// must not hide a missing or changed original. Only recordings that claim the digest are read.
    public func verifiedMeeting(withDigest digest: String, among candidates: [Meeting]) async -> Meeting? {
        for meeting in candidates where meeting.tracks.contains(where: { $0.sha256 == digest }) {
            for track in meeting.tracks where track.sha256 == digest {
                if await isVerified(track, digest: digest, in: meeting.id) { return meeting }
            }
        }
        return nil
    }

    /// The original exists and its bytes still have `digest`. The hashing happens off the actor.
    private func isVerified(_ track: RecordingTrack, digest: String, in meetingID: UUID) async -> Bool {
        guard track.sha256 == digest, let url = try? audioURL(for: track, in: meetingID),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
        return (try? await BlockingFileWork.sha256(url)) == digest
    }

    @discardableResult public func moveToTrash(_ id: UUID) throws -> URL {
        let meetings = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let source = meetings.appendingPathComponent(id.uuidString, isDirectory: true)
        try LocalFiles.requireContained(source, in: meetings)
        guard fm.fileExists(atPath: source.path) else { throw LibraryError.missingMeeting(id) }
        let trash = rootURL.appendingPathComponent("Trash", isDirectory: true)
        try LocalFiles.directory(trash)
        let destination = trashURL(for: id)
        try LocalFiles.requireContained(destination, in: trash)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.trashedMeeting(id) }
        try fm.moveItem(at: source, to: destination)
        cache[id] = nil
        noteWrite(meetings); noteWrite(destination)
        return destination
    }

    public func restoreFromTrash(_ id: UUID) throws -> Meeting {
        let source = trashURL(for: id)
        try LocalFiles.requireContained(source, in: rootURL.appendingPathComponent("Trash", isDirectory: true))
        guard fm.fileExists(atPath: source.path) else { throw LibraryError.missingMeeting(id) }
        let destination = rootURL.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        try LocalFiles.requireContained(destination, in: rootURL.appendingPathComponent("Meetings", isDirectory: true))
        try fm.moveItem(at: source, to: destination)
        cache[id] = nil
        noteWrite(source.deletingLastPathComponent()); noteWrite(destination)
        return try load(id)
    }

    private func trashURL(for id: UUID) -> URL { rootURL.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true) }

    private func preservingArtifacts(from stored: Meeting, in snapshot: Meeting) -> Meeting {
        var result = snapshot
        // Appended only when something is missing, so an unchanged snapshot shares its arrays.
        let trackIDs = Set(result.tracks.map(\.id))
        let tracks = stored.tracks.filter { !trackIDs.contains($0.id) }
        if !tracks.isEmpty { result.tracks += tracks }
        let transcriptIDs = Set(result.transcripts.map(\.id))
        let transcripts = stored.transcripts.filter { !transcriptIDs.contains($0.id) }
        if !transcripts.isEmpty { result.transcripts += transcripts }
        let revisionIDs = Set(result.revisions.map(\.id))
        let revisions = stored.revisions.filter { !revisionIDs.contains($0.id) }
        if !revisions.isEmpty { result.revisions += revisions }
        if !zip(result.revisions, result.revisions.dropFirst()).allSatisfy({ $0.date <= $1.date }) { result.revisions.sort { $0.date < $1.date } }
        // Photos are originals too: a stale snapshot can't drop one (deleting one marks it instead).
        let photoIDs = Set((result.photos ?? []).map(\.id))
        let missingPhotos = (stored.photos ?? []).filter { !photoIDs.contains($0.id) }
        if !missingPhotos.isEmpty { result.photos = (result.photos ?? []) + missingPhotos }
        return result
    }

    public func audioURL(for track: RecordingTrack, in meetingID: UUID) throws -> URL {
        let directory = try meetingDirectory(for: meetingID)
        return try LocalFiles.relativeURL(track.relativePath, in: directory)
    }

    /// Import is explicit: callers choose a new meeting or an existing one. Dates never imply linking.
    /// Original bytes are copied, hashed, and retained; source files are never moved or modified.
    /// Copying and hashing run off the actor, so other conversations' saves don't wait for a long
    /// recording; merging and saving happen together afterwards, with nothing in between.
    public func importAudio(from sourceURL: URL, into meeting: Meeting, source: AudioSource = .imported,
                            sidecarURL: URL? = nil, offset: TimeInterval? = nil,
                            device: DeviceRecordingIdentity? = nil) async throws -> Meeting {
        let resource = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, (resource.fileSize ?? 0) > 0 else { throw LibraryError.invalidAudio(sourceURL.lastPathComponent) }
        if let offset, !offset.isFinite { throw LibraryError.invalidTranscript }
        let sidecar = try sidecarURL.map { try Data(contentsOf: $0) }
        let sidecarHighlights: [HighlightSidecar.Entry]
        if let sidecar {
            guard let decoded = try? decoder.decode(HighlightSidecar.self, from: sidecar) else { throw LibraryError.invalidHighlightSidecar }
            guard decoded.schemaVersion == 1 else { throw LibraryError.unsupportedHighlightSchema(decoded.schemaVersion) }
            sidecarHighlights = decoded.highlights
        } else { sidecarHighlights = [] }
        guard sidecarHighlights.allSatisfy({ $0.time.isFinite && $0.time >= 0 }) else { throw LibraryError.invalidHighlight }
        let directory = try meetingDirectory(for: meeting.id)
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        try LocalFiles.requireContained(originals, in: directory)
        try LocalFiles.directory(originals)
        let staged = originals.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        let hash = try await BlockingFileWork.run { isCancelled in
            try FileManager.default.copyItem(at: sourceURL, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            return try AudioDigest.sha256(fileURL: staged, isCancelled: isCancelled)
        }
        let primary = directory.appendingPathComponent("meeting.json"), backup = directory.appendingPathComponent("meeting.recovery.json")
        let hasMetadata = { self.fm.fileExists(atPath: primary.path) || self.fm.fileExists(atPath: backup.path) }
        // Recordings that already claim these bytes are checked against their files, off the actor too.
        let storedTracks = hasMetadata() ? try load(meeting.id).tracks : []
        let claimed = (meeting.tracks + storedTracks).filter { $0.sha256 == hash }
        var verified = Set<UUID>(), checked = Set<UUID>()
        for track in claimed where checked.insert(track.id).inserted {
            if await isVerified(track, digest: hash, in: meeting.id) { verified.insert(track.id) }
        }
        var result = meeting
        if hasMetadata() {
            let stored = try load(meeting.id)
            result = stored.updatedAt > meeting.updatedAt ? preservingArtifacts(from: meeting, in: stored) : preservingArtifacts(from: stored, in: meeting)
            // Highlights may also have been added while a previous import was in flight.
            let other = stored.updatedAt > meeting.updatedAt ? meeting : stored
            let highlightIDs = Set(result.highlights.map(\.id))
            result.highlights += other.highlights.filter { !highlightIDs.contains($0.id) }
        }
        let track: RecordingTrack
        // A recording that claimed these bytes while the copy was hashed is checked here (rarely).
        if let duplicate = result.tracks.first(where: { $0.sha256 == hash && (verified.contains($0.id) || (!checked.contains($0.id) && isVerifiedNow($0, digest: hash, in: meeting.id))) }) {
            track = duplicate
            // The same bytes arriving from a recorder teach the library where they came from.
            if let device, duplicate.device == nil, let index = result.tracks.firstIndex(where: { $0.id == duplicate.id }) {
                result.tracks[index].device = device
            }
        } else {
            let id = UUID()
            let ext = sourceURL.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(12)
            let filename = id.uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let relativePath = "Originals/\(filename)"
            let destination = try LocalFiles.relativeURL(relativePath, in: directory)
            try fm.moveItem(at: staged, to: destination)
            noteWrite(destination)
            track = RecordingTrack(id: id, source: source, relativePath: relativePath,
                                   fileName: sourceURL.lastPathComponent, offset: offset, sha256: hash, device: device)
            result.tracks.append(track)
        }
        if let sidecar {
            let sidecarDigest = AudioDigest.sha256(data: sidecar)
            let sidecarDestination = originals.appendingPathComponent("\(track.id.uuidString).highlights-\(sidecarDigest).json")
            if !fm.fileExists(atPath: sidecarDestination.path) {
                try LocalFiles.atomicWrite(sidecar, to: sidecarDestination)
                noteWrite(sidecarDestination)
            }
        }
        for highlight in sidecarHighlights where !result.highlights.contains(where: { $0.trackID == track.id && $0.time == highlight.time && $0.text == highlight.text }) {
            result.highlights.append(Highlight(trackID: track.id, time: highlight.time, text: highlight.text))
        }
        result.status = .imported; result.updatedAt = Date()
        try save(result)
        return result
    }

    /// The same check, on the actor: only for a recording that appeared during an import's await.
    private func isVerifiedNow(_ track: RecordingTrack, digest: String, in meetingID: UUID) -> Bool {
        guard let url = try? audioURL(for: track, in: meetingID),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
        return (try? AudioDigest.sha256(fileURL: url)) == digest
    }

    public func updateNotes(_ notes: String, for id: UUID) throws -> Meeting {
        var meeting = try load(id); meeting.setNotes(notes); try save(meeting); return meeting
    }

    public func correctSegment(_ segmentID: UUID, text: String, in meetingID: UUID) throws -> Meeting {
        var meeting = try load(meetingID); meeting.correctSegment(id: segmentID, text: text); try save(meeting); return meeting
    }

    // MARK: Durability

    /// The durability barrier: flushes every file and folder this store wrote since the last barrier
    /// to permanent storage (`DurableFiles.synchronize`). Run before deleting what could recover them
    /// (a recording's staging folder) or acknowledging a sync pass; ordinary saves aren't flushed.
    public func synchronizeWrites() async throws {
        // Deepest first, so the library folder itself, flushed last, carries the drive-cache flush.
        let pending = unsynchronized.sorted { $0.path.count > $1.path.count }
        guard !pending.isEmpty else { return }
        unsynchronized.removeAll()
        do { try await BlockingFileWork.run { _ in try DurableFiles.synchronize(pending) } }
        catch { unsynchronized.formUnion(pending); throw error }
    }

    /// What the next barrier will flush (tests).
    var unsynchronizedWrites: Set<URL> { unsynchronized }

    /// Remembers a file or folder this store wrote, and the folders above it within the library,
    /// for the next barrier: a rename is durable only once its folder is.
    func noteWrite(_ url: URL) {
        var current = url.standardizedFileURL
        unsynchronized.insert(current)
        while current.path.count > rootURL.path.count, current.path.hasPrefix(rootURL.path) {
            current.deleteLastPathComponent()
            unsynchronized.insert(current)
        }
    }

    private func validate(_ meeting: Meeting, expectedID: UUID) throws {
        try Self.validate(meeting, expectedID: expectedID, rootURL: rootURL)
    }

    static func validate(_ meeting: Meeting, expectedID: UUID, rootURL: URL) throws {
        guard meeting.schemaVersion == 1 else { throw LibraryError.unsupportedSchema(meeting.schemaVersion) }
        guard meeting.id == expectedID else { throw LibraryError.corruptMeeting(expectedID) }
        let directory = rootURL.appendingPathComponent("Meetings/\(expectedID.uuidString)", isDirectory: true)
        try LocalFiles.requireContained(directory, in: rootURL.appendingPathComponent("Meetings", isDirectory: true))
        for track in meeting.tracks {
            _ = try LocalFiles.relativeURL(track.relativePath, in: directory)
            guard track.offset?.isFinite != false, track.duration?.isFinite != false,
                  track.duration == nil || track.duration! >= 0 else { throw LibraryError.invalidTranscript }
        }
        for transcript in meeting.transcripts {
            for segment in transcript.segments {
                guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else { throw LibraryError.invalidTranscript }
            }
        }
        for transcript in meeting.transcripts {
            guard transcript.knownOffset?.isFinite != false else { throw LibraryError.invalidTranscript }
            for word in transcript.words ?? [] {
                guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start else { throw LibraryError.invalidTranscript }
            }
        }
        for segment in meeting.unifiedTranscript {
            // A wearable may have started before the reference timeline, so fused times can be negative.
            guard segment.start.isFinite, segment.end.isFinite, segment.end >= segment.start else { throw LibraryError.invalidTranscript }
        }
        guard meeting.highlights.allSatisfy({
            $0.time.isFinite && $0.time >= 0 && ($0.duration == nil || ($0.duration!.isFinite && $0.duration! >= 0))
        }) else { throw LibraryError.invalidHighlight }
        for photo in meeting.photos ?? [] {
            guard photo.relativePath.hasPrefix(MeetingPhoto.folder + "/") else { throw LibraryError.unsafePath(photo.relativePath) }
            _ = try LocalFiles.relativeURL(photo.relativePath, in: directory)
            guard photo.time.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw LibraryError.invalidHighlight }
        }
    }
}

private struct SchemaHeader: Decodable { var schemaVersion: Int }

public struct HighlightSidecar: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var time: TimeInterval
        public var text: String
        public init(time: TimeInterval, text: String = "") { self.time = time; self.text = text }
    }
    public var schemaVersion: Int
    public var highlights: [Entry]
    public init(schemaVersion: Int = 1, highlights: [Entry]) { self.schemaVersion = schemaVersion; self.highlights = highlights }
    private enum CodingKeys: String, CodingKey { case schemaVersion, highlights }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        highlights = try container.decode([Entry].self, forKey: .highlights)
    }
}

enum LocalFiles {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func requireContained(_ url: URL, in directory: URL) throws {
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().path
        // Foundation may leave symlink ancestors unresolved when the final file does not exist yet.
        var ancestor = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil {
                throw LibraryError.unsafePath(url.path)
            }
            tail.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in tail { canonical.appendPathComponent(component) }
        let resolved = canonical.standardizedFileURL.path
        guard resolved.hasPrefix(resolvedDirectory + "/") else { throw LibraryError.unsafePath(url.path) }
    }
    static func relativeURL(_ path: String, in directory: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
              !components.contains(""), !path.contains("\0") else { throw LibraryError.unsafePath(path) }
        let url = directory.appendingPathComponent(path)
        try requireContained(url, in: directory)
        return url
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        // Foundation's atomic option writes a sibling temporary file then atomically renames it.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
