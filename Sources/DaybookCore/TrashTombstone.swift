import Foundation

/// A conversation deleted for good from the Trash (Delete Now, Empty Trash: `MeetingStore.deleteFromTrash`). Its folder,
/// `Trash/<id>`, stays with only this file in it: the library's persistent tombstone for the ID. Everything that asks
/// whether an ID is deleted by that folder being there keeps working: sync publishes the deletion from it (in every
/// journal, a new one after Start Over too), stale saves and imports are refused (`MeetingStore.meetingDirectory`), and
/// recovered recordings aren't filed back. What it keeps is only what compression needs to go on protecting a voice
/// profile's audio (`RecordingCompressionPlanner.learnedFrom`): each recording's ID, its digests, and where it moved or
/// came from. No title, notes, or names.
public struct TrashTombstone: Codable, Equatable, Sendable {
    public static let fileName = "deleted.json"

    public struct Recording: Codable, Equatable, Sendable {
        public var id: UUID
        public var sha256: String
        /// The original's digest, for a recording that was compressed.
        public var previousSHA256: String?
        public var movedTo: UUID?
        public var mergedFrom: UUID?

        public init(_ track: RecordingTrack) {
            id = track.id; sha256 = track.sha256; previousSHA256 = track.encoding?.previousSHA256
            movedTo = track.removal?.movedTo; mergedFrom = track.mergedFrom
        }
    }

    public var schemaVersion = 1
    public var id: UUID
    public var deletedAt: Date
    public var recordings: [Recording]

    public init(_ meeting: Meeting, deletedAt: Date = Date()) {
        id = meeting.id
        self.deletedAt = deletedAt
        recordings = meeting.tracks.map(Recording.init)
    }

    /// Whether `folder` (a `Trash/<id>` folder) is a tombstone: a conversation deleted from it for good, whatever else a
    /// deletion that stopped partway left beside it.
    public static func marks(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    /// The tombstone in `folder`, when it has one this version reads.
    public static func read(_ folder: URL) -> TrashTombstone? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let tombstone = try? JSONDecoder().decode(TrashTombstone.self, from: data), tombstone.schemaVersion == 1 else { return nil }
        return tombstone
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// The deleted conversation as compression's lineage reads it (`RecordingCompressionPlanner.learnedFrom`): its ID
    /// and its recordings' IDs, digests, moves, and merges, and nothing else.
    public var lineage: Meeting {
        var meeting = Meeting(id: id, title: "", date: deletedAt, updatedAt: deletedAt)
        meeting.tracks = recordings.map { recording in
            var track = RecordingTrack(id: recording.id, relativePath: "", fileName: "", sha256: recording.sha256)
            track.removal = recording.movedTo.map { RecordingRemoval(removedAt: deletedAt, movedTo: $0) }
            track.mergedFrom = recording.mergedFrom
            track.encoding = recording.previousSHA256.map {
                TrackEncoding(method: "", sourceFormat: "", previousSHA256: $0, previousRelativePath: "", previousFileName: "", encodedAt: deletedAt)
            }
            return track
        }
        return meeting
    }
}
