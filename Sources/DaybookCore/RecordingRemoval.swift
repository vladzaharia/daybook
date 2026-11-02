import Foundation

/// A recording taken out of its conversation: removed (Remove Recording…), or moved into a conversation of its own
/// (Move to New Conversation). Recordings sync as originals that are never deleted (a track one device dropped would
/// come back from another), so the recording stays in the conversation's folder with this mark on its track, and
/// putting it back clears the mark. A marked recording isn't transcribed, fused, or listed; its transcript leaves
/// the conversation's at the next fusion. Versions without the mark keep it as an unknown field.
public struct RecordingRemoval: Codable, Equatable, Sendable {
    public var removedAt: Date
    /// The conversation it moved to; nil when it was removed.
    public var movedTo: UUID?

    public init(removedAt: Date, movedTo: UUID? = nil) {
        self.removedAt = removedAt
        self.movedTo = movedTo
    }
}

extension RecordingTrack {
    /// It was taken out of its conversation (`removal`).
    public var isRemoved: Bool { removal != nil }
}

extension Meeting {
    /// Its recordings, without those taken out of it.
    public var presentTracks: [RecordingTrack] { tracks.filter { $0.removal == nil } }

    /// Recordings removed from it (not moved), which can be put back.
    public var removedTracks: [RecordingTrack] { tracks.filter { $0.removal != nil && $0.removal?.movedTo == nil } }

    /// A recording with the ones that share its audio: the original it was made from, and every copy made from
    /// either (the microphone and its echo-removed copy). They're removed, moved, and put back together. Originals
    /// first.
    public func recordingGroup(of trackID: UUID) -> [RecordingTrack] {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return [] }
        let root = track.derivedFrom.flatMap { original in tracks.first { $0.id == original } } ?? track
        var ids: Set<UUID> = [root.id]
        var grew = true
        while grew {
            let more = tracks.filter { $0.derivedFrom.map(ids.contains) == true && !ids.contains($0.id) }.map(\.id)
            grew = !more.isEmpty
            ids.formUnion(more)
        }
        return tracks.filter { ids.contains($0.id) }.sorted { ($0.derivedFrom == nil ? 0 : 1) < ($1.derivedFrom == nil ? 0 : 1) }
    }
}
