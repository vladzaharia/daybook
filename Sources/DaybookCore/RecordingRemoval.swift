import Foundation

/// A recording taken out of its conversation: removed (Remove Recording…), or moved into a conversation of its own
/// (Move to New Conversation). Recordings sync as originals that are never deleted (a track one device dropped would
/// come back from another), so the recording stays in the conversation's folder with this mark on its track, and
/// putting it back clears the mark. A marked recording isn't transcribed, fused, or listed; its transcript leaves
/// the conversation's at the next fusion, and its bookmarks leave with it (`presentHighlights`). The mark merges on
/// its own (`MeetingMerge`), so another device's change to the same recording doesn't take it off. Versions without
/// the mark keep it as an unknown field.
public struct RecordingRemoval: Codable, Equatable, Sendable {
    public var removedAt: Date
    /// The conversation it moved to; nil when it was removed.
    public var movedTo: UUID?

    public init(removedAt: Date, movedTo: UUID? = nil) {
        self.removedAt = removedAt
        self.movedTo = movedTo
    }

    /// The Version History field that records a recording (its copy, by the copy's ID) arriving in the conversation
    /// it was moved to (`Meeting.wasMovedHere`).
    public static func movedHereField(_ trackID: UUID) -> String { "source:\(trackID.uuidString):moved-from" }
}

extension RecordingTrack {
    /// It was taken out of its conversation (`removal`).
    public var isRemoved: Bool { removal != nil }

    /// It was moved into a conversation of its own, where its copy is the recording now. Finding where a recording
    /// is (a device's recordings already in Daybook, audio already imported) skips this one, so a moved recording
    /// is found in its new conversation. A removed one is still found here, where it can be put back.
    public var isMovedOut: Bool { removal?.movedTo != nil }
}

extension Meeting {
    /// Its recordings, without those taken out of it.
    public var presentTracks: [RecordingTrack] { tracks.filter { $0.removal == nil } }

    /// Recordings removed from it (not moved), which can be put back.
    public var removedTracks: [RecordingTrack] { tracks.filter { $0.removal != nil && $0.removal?.movedTo == nil } }

    /// The person moved this recording here from another conversation (Move to New Conversation), with the copies
    /// that share its audio: this is where they filed it. It's never matched to another conversation the way a
    /// recording that arrives on its own is (by a recorder's link, overlap in time, or the sound), so it can't be
    /// matched straight back into the one it left. Its Version History entry says so, which syncs with it.
    public func wasMovedHere(_ trackID: UUID) -> Bool {
        let fields = Set(recordingGroup(of: trackID).map { RecordingRemoval.movedHereField($0.id) })
        return revisions.contains { fields.contains($0.field) }
    }

    /// Its bookmarks, without those on a recording taken out of it: they leave with the recording (a moved one's are
    /// in its new conversation) and come back when it's put back. Bookmark lists, the timeline, and what a summary is
    /// given (`highlightContexts`) read these.
    public var presentHighlights: [Highlight] {
        let removed = Set(tracks.lazy.filter(\.isRemoved).map(\.id))
        guard !removed.isEmpty else { return highlights }
        return highlights.filter { $0.trackID.map(removed.contains) != true }
    }

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
