import Foundation

/// How Daybook captured or derived a recording track. Stored with the track so timing and capture
/// decisions survive after the staging folder is removed. Every field is optional.
public struct TrackCaptureDetails: Codable, Equatable, Sendable {
    /// `microphone`, `process-tap`, `screen-capture-kit`, or `echo-cancelled` for a derived track.
    public var method: String?
    /// Bundle IDs whose audio a process tap recorded.
    public var capturedApps: [String]?
    /// Why the preferred capture path was not used.
    public var fallbackReason: String?
    /// Session seconds per track second, measured from host-time stamps; 1 means no drift.
    /// `meetingTime = offset + trackTime × clockRate`.
    public var clockRate: Double?
    /// What played the call: `speakers`, `headphones`, `bluetooth`, `external`, `mixed`, or `unknown`.
    public var outputRoute: String?
    /// Echo removal outcome, on the microphone original and on its derived track.
    public var echoRemoval: EchoRemovalReport?
    /// Device switches, format conversions, or fallbacks during capture.
    public var notes: [String]?
    /// Other devices' clocks, measured over the local link while this device recorded (docs/link.md,
    /// "Clock samples"): a prior for placing this recording beside theirs before any sound is compared.
    public var peerClocks: [CapturePeerClock]?
    /// A recorder's recording (a Soundcore Work's): its clock as Daybook last measured it, and whether
    /// the recording's start was corrected by it. The only field set on an import from a recorder.
    public var recorderClock: CaptureRecorderClock?

    public init(method: String? = nil, capturedApps: [String]? = nil, fallbackReason: String? = nil,
                clockRate: Double? = nil, outputRoute: String? = nil, echoRemoval: EchoRemovalReport? = nil,
                notes: [String]? = nil, peerClocks: [CapturePeerClock]? = nil, recorderClock: CaptureRecorderClock? = nil) {
        self.method = method; self.capturedApps = capturedApps; self.fallbackReason = fallbackReason
        self.clockRate = clockRate; self.outputRoute = outputRoute; self.echoRemoval = echoRemoval; self.notes = notes
        self.peerClocks = peerClocks; self.recorderClock = recorderClock
    }
}

/// The clock of the recorder a recording came from, against the clock of the device that measured it
/// (when Daybook started a recording on it, the new recording's ID against when the command was sent).
/// Recorder recording IDs are start times by the recorder's own clock, so this is what dates them.
public struct CaptureRecorderClock: Codable, Equatable, Sendable {
    /// The recorder's clock minus the measuring device's, in seconds: positive when it runs ahead.
    public var offset: TimeInterval
    /// Whether the recording's start (and a new conversation's date and title) had the offset taken
    /// off. A difference within the measurement's resolution, or one that would make an implausible
    /// date, is recorded and not applied.
    public var applied: Bool
    /// When it was measured, on the measuring device's clock.
    public var measuredAt: Date?

    public init(offset: TimeInterval, applied: Bool, measuredAt: Date? = nil) {
        self.offset = offset; self.applied = applied; self.measuredAt = measuredAt
    }
}

/// One device's clock as this device measured it while recording: NTP-style samples over the local
/// link, filtered to the shortest round trip. `offset` is (peer's clock − this device's clock), so a
/// moment `t` on this device's clock is `t + offset` on the peer's.
public struct CapturePeerClock: Codable, Equatable, Sendable {
    /// The peer's link device ID.
    public var deviceID: String
    public var name: String?
    /// `mac`, `iPhone`, …
    public var deviceClass: String?
    public var offset: TimeInterval
    /// How far `offset` could be off: half the best round trip.
    public var uncertainty: TimeInterval
    public var sampleCount: Int
    /// When the estimate was taken, on this device's clock.
    public var measuredAt: Date
    /// The peer's own recording of the conversation, when it reported one: its start on the peer's clock.
    public var peerRecordingStartedAt: Date?

    public init(deviceID: String, name: String? = nil, deviceClass: String? = nil, offset: TimeInterval,
                uncertainty: TimeInterval, sampleCount: Int, measuredAt: Date, peerRecordingStartedAt: Date? = nil) {
        self.deviceID = deviceID; self.name = name; self.deviceClass = deviceClass; self.offset = offset
        self.uncertainty = uncertainty; self.sampleCount = sampleCount; self.measuredAt = measuredAt
        self.peerRecordingStartedAt = peerRecordingStartedAt
    }
}

public extension RecordingTrack {
    static let echoCancelledProcessing = "echo-cancelled"
}

public extension Meeting {
    /// Tracks that need their own transcript. A track another track was derived from (such as the
    /// microphone before echo removal) is transcribed through its derivative; the original stays in
    /// the library for playback, provenance, and reprocessing.
    var transcribableTracks: [RecordingTrack] {
        let superseded = Set(tracks.compactMap(\.derivedFrom))
        return tracks.filter { !superseded.contains($0.id) }
    }

    /// True when a transcribable track has no transcript yet.
    var hasUntranscribedTranscribableAudio: Bool {
        transcribableTracks.contains { track in !transcripts.contains { $0.trackID == track.id } }
    }
}
