import Foundation

// A recorder's audio saved while it records (Listen Live, or the stream a shared recording keeps on
// the device that manages the recorder) is a track of its own: the recording's ID plus `~live`. When
// the recorder's own file arrives later in the same conversation, that file is authoritative: the
// portion stays in the library (provenance, playback) but is neither transcribed nor fused again. When
// both hold the same bytes, the import finds the portion's track and makes it the full recording's
// (`MeetingStore.importAudio`), so there's one track.

public extension RecordingTrack {
    /// A Listen Live portion's recording ID ends with this (`DeviceLibraryLinks.partialSuffix`).
    static let livePortionSuffix = "~live"

    /// Saved from the recorder's live stream rather than imported from its file.
    var isLivePortion: Bool { deviceRecordingID?.hasSuffix(Self.livePortionSuffix) == true }

    /// The identity of the whole recording a live portion is part of; nil for any other track.
    var wholeRecordingIdentity: DeviceRecordingIdentity? {
        guard isLivePortion, var identity = device else { return nil }
        identity.recordingID = String(identity.recordingID.dropLast(Self.livePortionSuffix.count))
        return identity
    }

    /// Whether this track is the whole recording `portion` was saved from: the same kind and recording,
    /// from the same recorder when both name a serial.
    func isWholeRecording(of portion: RecordingTrack) -> Bool {
        guard !isLivePortion, let whole = portion.wholeRecordingIdentity, let mine = device,
              mine.kind == whole.kind, mine.recordingID == whole.recordingID else { return false }
        if let a = mine.serial, let b = whole.serial, !a.isEmpty, !b.isEmpty, a != b { return false }
        return true
    }
}

public extension Array where Element == RecordingTrack {
    /// Live portions whose whole recording is among these tracks: portion's track ID → the whole
    /// recording's.
    var supersededLivePortions: [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for portion in self where portion.isLivePortion {
            if let whole = first(where: { $0.isWholeRecording(of: portion) }) { result[portion.id] = whole.id }
        }
        return result
    }
}

public extension Meeting {
    /// Live portions the recorder's own file replaces here (`[RecordingTrack].supersededLivePortions`).
    var supersededLivePortions: [UUID: UUID] { tracks.supersededLivePortions }
}
