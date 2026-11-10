import Foundation

/// One audio alignment measured between two of a meeting's recordings, as Daybook 0.2.2 stored them on the meeting
/// (`Meeting.audioAlignments`). Nothing writes them any more; fusion still places a recording by one measured on the
/// same bytes, and sync merges them. `alignment` maps `trackID` time to `referenceTrackID` time.
public struct TrackAudioAlignment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(trackID.uuidString)>\(referenceTrackID.uuidString)" }
    public var trackID: UUID
    public var referenceTrackID: UUID
    /// Nil records that the recordings were compared and didn't share enough sound.
    public var alignment: AudioAlignment?
    /// SHA-256 of both recordings, so a measurement is never applied to different bytes.
    public var trackDigest: String
    public var referenceDigest: String
    public var algorithmVersion: Int
    public var measuredAt: Date
    public var explanation: String?
    public init(trackID: UUID, referenceTrackID: UUID, alignment: AudioAlignment?, trackDigest: String = "",
                referenceDigest: String = "", algorithmVersion: Int = AudioAligner.algorithmVersion,
                measuredAt: Date = Date(), explanation: String? = nil) {
        self.trackID = trackID; self.referenceTrackID = referenceTrackID; self.alignment = alignment
        self.trackDigest = trackDigest; self.referenceDigest = referenceDigest; self.algorithmVersion = algorithmVersion
        self.measuredAt = measuredAt; self.explanation = explanation
    }
}
