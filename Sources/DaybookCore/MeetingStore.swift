import Foundation

public enum LibraryError: LocalizedError {
    case unsafePath(String), corruptMeeting(UUID), unsupportedSchema(Int), invalidAudio(String), invalidHighlight, invalidTranscript, trashedMeeting(UUID), missingMeeting(UUID), unsupportedHighlightSchema(Int), invalidHighlightSidecar
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

    public init(rootURL: URL? = nil) throws {
        let root = (rootURL ?? LibraryLocation.defaultRoot).standardizedFileURL
        self.rootURL = root
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LocalFiles.directory(root)
        try LocalFiles.directory(root.appendingPathComponent("Meetings", isDirectory: true))
    }

    public func meetingDirectory(for id: UUID) throws -> URL {
        guard !fm.fileExists(atPath: trashURL(for: id).path) else { throw LibraryError.trashedMeeting(id) }
        let meetings = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let directory = meetings.appendingPathComponent(id.uuidString, isDirectory: true)
        try LocalFiles.requireContained(directory, in: meetings)
        try LocalFiles.directory(directory)
        return directory
    }

    public func list() throws -> [Meeting] {
        warnings = []
        let directory = rootURL.appendingPathComponent("Meetings", isDirectory: true)
        let children = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var meetings: [Meeting] = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do { meetings.append(try load(id)) }
            catch { warnings.append(error.localizedDescription) }
        }
        return meetings.sorted { $0.date > $1.date }
    }

    public func load(_ id: UUID) throws -> Meeting {
        let directory = try meetingDirectory(for: id)
        let primary = directory.appendingPathComponent("meeting.json")
        let backup = directory.appendingPathComponent("meeting.recovery.json")
        if let bytes = try? Data(contentsOf: primary),
           let header = try? decoder.decode(SchemaHeader.self, from: bytes), header.schemaVersion > 1 {
            throw LibraryError.unsupportedSchema(header.schemaVersion)
        }
        if let bytes = try? Data(contentsOf: primary), let meeting = try? decoder.decode(Meeting.self, from: bytes) {
            // Never silently roll a future schema back to an older snapshot.
            if meeting.schemaVersion != 1 { throw LibraryError.unsupportedSchema(meeting.schemaVersion) }
            if (try? validate(meeting, expectedID: id)) != nil { return meeting }
        }
        if let bytes = try? Data(contentsOf: backup), let meeting = try? decoder.decode(Meeting.self, from: bytes) {
            try validate(meeting, expectedID: id)
            if fm.fileExists(atPath: primary.path) {
                let damaged = directory.appendingPathComponent("meeting.corrupt-\(UUID().uuidString).json")
                try fm.copyItem(at: primary, to: damaged)
            }
            try LocalFiles.atomicWrite(bytes, to: primary)
            warnings.append("Recovered “\(meeting.title)” from its last saved copy.")
            return meeting
        }
        throw LibraryError.corruptMeeting(id)
    }

    public func save(_ snapshot: Meeting) throws {
        var meeting = snapshot
        try validate(meeting, expectedID: meeting.id)
        let directory = try meetingDirectory(for: meeting.id)
        let primary = directory.appendingPathComponent("meeting.json")
        let backup = directory.appendingPathComponent("meeting.recovery.json")
        if let old = try? Data(contentsOf: primary),
           let header = try? decoder.decode(SchemaHeader.self, from: old), header.schemaVersion > 1 {
            throw LibraryError.unsupportedSchema(header.schemaVersion)
        }
        if fm.fileExists(atPath: primary.path) || fm.fileExists(atPath: backup.path) {
            // Recover and validate before accepting a new snapshot. A corrupt current file must not
            // cause an older queued save to detach originals described by the recovery snapshot.
            let oldMeeting = try load(meeting.id)
            // Captured originals, model runs, and correction history are append-only. A notes snapshot
            // queued during a concurrent import must not detach a newly stored recording.
            meeting = preservingArtifacts(from: oldMeeting, in: meeting)
            try LocalFiles.atomicWrite(try encoder.encode(oldMeeting), to: backup)
        }
        let bytes = try encoder.encode(meeting)
        if !fm.fileExists(atPath: backup.path) {
            // First-save recovery copy also protects newly imported originals.
            try LocalFiles.atomicWrite(bytes, to: backup)
        }
        try LocalFiles.atomicWrite(bytes, to: primary)
    }

    /// Advisory lookup before creating a new meeting, useful for repeated incoming-folder deliveries.
    /// Explicitly attaching an audio file to a different meeting remains possible.
    public func existingMeeting(containingAudioAt url: URL) throws -> Meeting? {
        let digest = try AudioDigest.sha256(fileURL: url)
        return try list().first { verifiedTrack(withDigest: digest, in: $0) != nil }
    }

    private func verifiedTrack(withDigest digest: String, in meeting: Meeting) -> RecordingTrack? {
        meeting.tracks.first { track in
            guard track.sha256 == digest, let url = try? audioURL(for: track, in: meeting.id),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
            // A stale metadata digest must not prevent restoring a missing or externally modified original.
            return (try? AudioDigest.sha256(fileURL: url)) == digest
        }
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
        return destination
    }

    public func restoreFromTrash(_ id: UUID) throws -> Meeting {
        let source = trashURL(for: id)
        try LocalFiles.requireContained(source, in: rootURL.appendingPathComponent("Trash", isDirectory: true))
        guard fm.fileExists(atPath: source.path) else { throw LibraryError.missingMeeting(id) }
        let destination = rootURL.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        try LocalFiles.requireContained(destination, in: rootURL.appendingPathComponent("Meetings", isDirectory: true))
        try fm.moveItem(at: source, to: destination)
        return try load(id)
    }

    private func trashURL(for id: UUID) -> URL { rootURL.appendingPathComponent("Trash/\(id.uuidString)", isDirectory: true) }

    private func preservingArtifacts(from stored: Meeting, in snapshot: Meeting) -> Meeting {
        var result = snapshot
        result.tracks += stored.tracks.filter { track in !result.tracks.contains { $0.id == track.id } }
        result.transcripts += stored.transcripts.filter { transcript in !result.transcripts.contains { $0.id == transcript.id } }
        result.revisions += stored.revisions.filter { revision in !result.revisions.contains { $0.id == revision.id } }
        result.revisions.sort { $0.date < $1.date }
        // Photos are originals too: a stale snapshot can't drop one (deleting one marks it instead).
        let missingPhotos = (stored.photos ?? []).filter { photo in !(result.photos ?? []).contains { $0.id == photo.id } }
        if !missingPhotos.isEmpty { result.photos = (result.photos ?? []) + missingPhotos }
        return result
    }

    public func audioURL(for track: RecordingTrack, in meetingID: UUID) throws -> URL {
        let directory = try meetingDirectory(for: meetingID)
        return try LocalFiles.relativeURL(track.relativePath, in: directory)
    }

    /// Import is explicit: callers choose a new meeting or an existing one. Dates never imply linking.
    /// Original bytes are copied, hashed, and retained; source files are never moved or modified.
    public func importAudio(from sourceURL: URL, into meeting: Meeting, source: AudioSource = .imported,
                            sidecarURL: URL? = nil, offset: TimeInterval? = nil,
                            device: DeviceRecordingIdentity? = nil) throws -> Meeting {
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
        var result = meeting
        let directory = try meetingDirectory(for: meeting.id)
        if fm.fileExists(atPath: directory.appendingPathComponent("meeting.json").path) || fm.fileExists(atPath: directory.appendingPathComponent("meeting.recovery.json").path) {
            let stored = try load(meeting.id)
            result = stored.updatedAt > meeting.updatedAt ? preservingArtifacts(from: meeting, in: stored) : preservingArtifacts(from: stored, in: meeting)
            // Highlights may also have been added while a previous import was in flight.
            let other = stored.updatedAt > meeting.updatedAt ? meeting : stored
            result.highlights += other.highlights.filter { mark in !result.highlights.contains { $0.id == mark.id } }
        }
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        try LocalFiles.requireContained(originals, in: directory)
        try LocalFiles.directory(originals)
        let staged = originals.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.copyItem(at: sourceURL, to: staged)
        defer { try? fm.removeItem(at: staged) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let hash = try AudioDigest.sha256(fileURL: staged)
        let track: RecordingTrack
        if let duplicate = verifiedTrack(withDigest: hash, in: result) {
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
            track = RecordingTrack(id: id, source: source, relativePath: relativePath,
                                   fileName: sourceURL.lastPathComponent, offset: offset, sha256: hash, device: device)
            result.tracks.append(track)
        }
        if let sidecar {
            let sidecarDigest = AudioDigest.sha256(data: sidecar)
            let sidecarDestination = originals.appendingPathComponent("\(track.id.uuidString).highlights-\(sidecarDigest).json")
            if !fm.fileExists(atPath: sidecarDestination.path) { try LocalFiles.atomicWrite(sidecar, to: sidecarDestination) }
        }
        for highlight in sidecarHighlights where !result.highlights.contains(where: { $0.trackID == track.id && $0.time == highlight.time && $0.text == highlight.text }) {
            result.highlights.append(Highlight(trackID: track.id, time: highlight.time, text: highlight.text))
        }
        result.status = .imported; result.updatedAt = Date()
        try save(result)
        return result
    }

    public func updateNotes(_ notes: String, for id: UUID) throws -> Meeting {
        var meeting = try load(id); meeting.setNotes(notes); try save(meeting); return meeting
    }

    public func correctSegment(_ segmentID: UUID, text: String, in meetingID: UUID) throws -> Meeting {
        var meeting = try load(meetingID); meeting.correctSegment(id: segmentID, text: text); try save(meeting); return meeting
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
        for segment in meeting.transcripts.flatMap(\.segments) {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else { throw LibraryError.invalidTranscript }
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
