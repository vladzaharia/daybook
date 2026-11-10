import Foundation

/// Where one recording sits on its conversation's timeline, `timeline = offset + rate × recordingTime`, how that was
/// found, and what it rests on. `Meeting.clock(of:)` is the one place it's worked out: fusion, the sound comparison,
/// bookmarks, notes, and photos all read it, so they can't disagree (docs/alignment.md, "One clock per recording").
public struct TimelineClock: Equatable, Sendable {
    public enum Method: String, Sendable {
        /// The conversation's first recording, at zero, when nothing else times it.
        case origin
        /// Timed by the capture that made it (this Mac's microphone and computer audio, an iPhone's recording filed
        /// alone), at its capture offset and its measured clock rate.
        case capture
        /// Found from the sound (`AudioAligner`).
        case audio
        /// Found from phrases both transcripts share.
        case transcript
        /// Placed by the recorders' clocks only.
        case clock
        /// Set by the person (Adjust Timing).
        case manual
    }

    public var offset: TimeInterval
    /// Timeline seconds per second of this recording, within `ClockRate.maximumDriftPPM` of 1.
    public var rate: Double
    public var method: Method
    public var confidence: Double?
    /// The recording this placement was measured against or follows (a derived copy's original), when it rests on one.
    public var dependsOn: UUID?

    public init(offset: TimeInterval, rate: Double = 1, method: Method, confidence: Double? = nil, dependsOn: UUID? = nil) {
        self.offset = offset; self.rate = rate; self.method = method; self.confidence = confidence; self.dependsOn = dependsOn
    }

    /// A time in the recording, on the timeline.
    public func timeline(_ recordingTime: TimeInterval) -> TimeInterval { offset + rate * recordingTime }

    /// Sure enough to line another recording up against: the origin, capture timing, the person's own setting, or the
    /// sound. A placement from shared phrases or the clocks alone is a guess, and a guess composed on a guess drifts.
    public var isStrong: Bool { [.origin, .capture, .manual, .audio].contains(method) }

    /// A recording made on the same capture clock as `placed`: the echo-cancelled copy of a microphone, which starts
    /// where its original does and is resampled onto the capture's own clock. It takes `placed`'s offset, never its rate:
    /// the session clock runs at `placed.rate / placedCaptureRate` on the timeline, and this recording at its own
    /// `captureRate` on the session clock.
    /// A stored placement read at a rate a clock can run at. One outside `ClockRate.maximumDriftPPM` (an old phrase
    /// fit) reads as rate 1, kept right at the recording's middle rather than its start, so neither end is off by
    /// more than half what the impossible rate put there.
    public static func physical(offset: TimeInterval, rate: Double, duration: TimeInterval?) -> (offset: TimeInterval, rate: Double) {
        if let bounded = ClockRate.bounded(rate) { return (offset, bounded) }
        guard rate.isFinite, rate > 0, let duration, duration.isFinite, duration > 0 else { return (offset, 1) }
        return (offset + (rate - 1) * duration / 2, 1)
    }

    public static func sharingCapture(with placed: TimelineClock, placedCaptureRate: Double, captureRate: Double, dependsOn: UUID?) -> TimelineClock {
        let session = placed.rate / (placedCaptureRate > 0 ? placedCaptureRate : 1)
        return TimelineClock(offset: placed.offset, rate: ClockRate.bounded(session * captureRate) ?? 1, method: placed.method,
                             confidence: placed.confidence, dependsOn: dependsOn)
    }
}

/// Physical clocks drift by tens of parts per million. Every rate Daybook stores or uses is held to this.
public enum ClockRate {
    /// The most any recording's clock may differ from the timeline's: the aligner's limit, a capture's measured rate,
    /// and a fit from shared phrases all stay within it.
    public static let maximumDriftPPM: Double = 1_000

    /// The rate when it's a plausible clock rate, else nil.
    public static func bounded(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0, abs(rate - 1) * 1_000_000 <= maximumDriftPPM + 1e-6 else { return nil }
        return rate
    }

    public static func isPlausible(_ rate: Double?) -> Bool { bounded(rate) != nil }
}

extension TimelineClock.Method {
    init(_ method: SourceAlignment.Method) {
        switch method {
        case .audio: self = .audio
        case .transcript: self = .transcript
        case .clock: self = .clock
        case .manual, .pending, .unaligned: self = .manual
        }
    }

    init(_ method: TrackAlignment.Method) {
        switch method {
        case .reference: self = .origin
        case .provided: self = .capture
        case .audio: self = .audio
        case .anchors: self = .transcript
        case .timestamps, .unaligned: self = .clock
        }
    }
}

public extension RecordingTrack {
    /// The clock rate its capture measured (session seconds per second of the recording), when it's plausible; 1
    /// otherwise. A rate a capture or a file stored outside `ClockRate.maximumDriftPPM` isn't a clock's.
    var captureRate: Double { ClockRate.bounded(capture?.clockRate) ?? 1 }
}

extension Meeting {
    /// The recording's place on the timeline, the one every reader uses:
    ///
    /// 1. its stored placement (`RecordingTrack.alignment`) once placed;
    /// 2. nothing while it waits to be placed, or couldn't be;
    /// 3. a derived copy without one of its own: its original's offset, at the copy's own rate
    ///    (`TimelineClock.sharingCapture`);
    /// 4. its capture offset, at the rate its capture measured;
    /// 5. what the latest fusion reported for it (a recording fusion placed by itself, as before multipoint), or
    ///    nothing when fusion couldn't place it;
    /// 6. zero, for the conversation's first recording.
    ///
    /// Rates are held to `ClockRate.maximumDriftPPM`; one outside it (an old phrase fit) reads as 1.
    public func clock(of trackID: UUID) -> TimelineClock? {
        clock(of: trackID, visited: [])
    }

    /// The clock from what's stored on the recording itself (steps 1–4), not from a fusion report or the origin
    /// default: what fusion is given as decided, rather than what it decided last time.
    public func storedClock(of trackID: UUID) -> TimelineClock? {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
        if track.alignment != nil || track.derivedFrom != nil || (track.offset?.isFinite == true) {
            return clock(of: trackID, visited: [], fallingBack: false)
        }
        return nil
    }

    private func clock(of trackID: UUID, visited: Set<UUID>, fallingBack: Bool = true) -> TimelineClock? {
        guard !visited.contains(trackID) else { return nil }
        // A recording only a fusion report knows (a report kept without its recording's record) reads by the report.
        guard let track = tracks.first(where: { $0.id == trackID }) else { return fallingBack ? reportedClock(trackID) : nil }
        if let alignment = track.alignment {
            if alignment.isPlaced, let offset = alignment.offset {
                let physical = TimelineClock.physical(offset: offset, rate: alignment.rate, duration: track.duration)
                return TimelineClock(offset: physical.offset, rate: physical.rate, method: .init(alignment.method),
                                     confidence: alignment.confidence, dependsOn: alignment.referenceTrackID)
            }
            if alignment.isPending || alignment.method == .unaligned { return nil }
        }
        if let originalID = track.derivedFrom, track.alignment == nil {
            guard let original = clock(of: originalID, visited: visited.union([trackID]), fallingBack: fallingBack),
                  let originalTrack = tracks.first(where: { $0.id == originalID }) else {
                return capturedClock(track, fallingBack: fallingBack)
            }
            // Both timed by their capture: the copy keeps its own capture offset, if it has one.
            if original.method == .capture || original.method == .origin, let offset = track.offset, offset.isFinite {
                return TimelineClock(offset: offset, rate: track.captureRate, method: .capture, dependsOn: originalID)
            }
            return TimelineClock.sharingCapture(with: original, placedCaptureRate: originalTrack.captureRate, captureRate: track.captureRate,
                                                dependsOn: originalID)
        }
        return capturedClock(track, fallingBack: fallingBack)
    }

    private func capturedClock(_ track: RecordingTrack, fallingBack: Bool) -> TimelineClock? {
        if let offset = track.offset, offset.isFinite { return TimelineClock(offset: offset, rate: track.captureRate, method: .capture) }
        guard fallingBack else { return nil }
        // A recording the latest fusion couldn't place isn't on the timeline, even as the first one.
        if alignmentReports.contains(where: { $0.trackID == track.id }) { return reportedClock(track.id) }
        return tracks.first?.id == track.id ? TimelineClock(offset: 0, method: .origin) : nil
    }

    /// A report without a usable rate (zero, not a number) places nothing.
    private func reportedClock(_ trackID: UUID) -> TimelineClock? {
        guard let report = alignmentReports.first(where: { $0.trackID == trackID }), report.method != .unaligned,
              report.offset.isFinite, report.rate.isFinite, report.rate > 0 else { return nil }
        let duration = tracks.first { $0.id == trackID }?.duration
        let physical = TimelineClock.physical(offset: report.offset, rate: report.rate, duration: duration)
        return TimelineClock(offset: physical.offset, rate: physical.rate, method: .init(report.method),
                             confidence: report.confidence, dependsOn: report.referenceTrackID)
    }
}
