import Foundation

/// One audio alignment measured between two of a meeting's recordings. Stored on the meeting
/// (`Meeting.audioAlignments`) so later fusion runs reuse it instead of decoding audio again.
/// `alignment` maps `trackID` time to `referenceTrackID` time.
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

/// A pair of recordings worth comparing.
public struct AudioAlignmentRequest: Equatable, Sendable {
    public var trackID: UUID
    public var referenceTrackID: UUID
    public var expectedOffset: TimeInterval?
    public var searchRadius: TimeInterval
    public init(trackID: UUID, referenceTrackID: UUID, expectedOffset: TimeInterval? = nil, searchRadius: TimeInterval = 0) {
        self.trackID = trackID; self.referenceTrackID = referenceTrackID
        self.expectedOffset = expectedOffset; self.searchRadius = searchRadius
    }
}

/// Decides which of a meeting's recordings to align from audio and measures them.
public enum MeetingAudioAlignment {
    /// Recordings whose timing isn't known from capture or the person (no `offset`, not derived from
    /// one that has it) are compared with up to three recordings whose timing is known: the raw
    /// microphone first (it hears the room and, without headphones, the call), then computer audio.
    /// With no known timing at all, the first recording is the reference. Pairs already measured on
    /// the same bytes with the current method are skipped.
    ///
    /// `recordingStartDates` (wall-clock starts, such as a recorder's file date) give a ±10 minute
    /// prior; without them the search covers every overlap.
    public static func requests(for meeting: Meeting, recordingStartDates: [UUID: Date] = [:]) -> [AudioAlignmentRequest] {
        let tracks = meeting.tracks
        func known(_ track: RecordingTrack) -> Bool {
            if track.offset?.isFinite == true { return true }
            if meeting.transcripts.contains(where: { $0.trackID == track.id && $0.knownOffset?.isFinite == true }) { return true }
            if let original = track.derivedFrom, let source = tracks.first(where: { $0.id == original }), source.offset?.isFinite == true { return true }
            return false
        }
        func preference(_ track: RecordingTrack) -> Int {
            switch track.source {
            case .microphone: return track.derivedFrom == nil ? 0 : 2
            case .systemAudio: return 1
            case .soundcore, .imported: return 3
            }
        }
        // A derived copy shares its original's clock: measuring against both would be redundant.
        let originals = Set(tracks.map(\.id))
        var anchors = tracks.filter { known($0) && !($0.derivedFrom.map(originals.contains) ?? false) }.sorted { (preference($0), tracks.firstIndex(of: $0)!) < (preference($1), tracks.firstIndex(of: $1)!) }
        if anchors.isEmpty, let first = tracks.first { anchors = [first] }
        var requests: [AudioAlignmentRequest] = []
        for track in tracks where !known(track) && track.derivedFrom == nil {
            for reference in anchors.prefix(3) where reference.id != track.id {
                let alreadyMeasured = meeting.audioAlignments?.contains {
                    $0.trackID == track.id && $0.referenceTrackID == reference.id && $0.trackDigest == track.sha256
                        && $0.referenceDigest == reference.sha256 && $0.algorithmVersion == AudioAligner.algorithmVersion
                } ?? false
                guard !alreadyMeasured else { continue }
                var request = AudioAlignmentRequest(trackID: track.id, referenceTrackID: reference.id)
                if let start = recordingStartDates[track.id], let referenceStart = recordingStartDates[reference.id] {
                    request.expectedOffset = start.timeIntervalSince(referenceStart)
                    request.searchRadius = 600
                }
                requests.append(request)
            }
        }
        return requests
    }

    /// Measures each request (synchronously; call off the main actor). A prior that finds nothing is
    /// retried with a full search, since recorder clocks can be wrong by more than the radius.
    /// Unreadable audio is recorded as "not aligned" with the reason, not thrown.
    public static func measure(_ requests: [AudioAlignmentRequest], in meeting: Meeting, urls: [UUID: URL],
                               options: AudioAlignmentOptions = .init(), cache: AudioFeatureCache? = .shared) -> [TrackAudioAlignment] {
        requests.compactMap { request in
            guard let track = meeting.tracks.first(where: { $0.id == request.trackID }),
                  let reference = meeting.tracks.first(where: { $0.id == request.referenceTrackID }),
                  let url = urls[track.id], let referenceURL = urls[reference.id] else { return nil }
            var record = TrackAudioAlignment(trackID: track.id, referenceTrackID: reference.id, alignment: nil,
                                             trackDigest: track.sha256, referenceDigest: reference.sha256)
            do {
                var report = try AudioAligner.analyze(other: url, otherDigest: track.sha256, reference: referenceURL,
                                                      referenceDigest: reference.sha256, expectedOffset: request.expectedOffset,
                                                      searchRadius: request.searchRadius, options: options, cache: cache)
                if report.alignment == nil, request.expectedOffset != nil {
                    report = try AudioAligner.analyze(other: url, otherDigest: track.sha256, reference: referenceURL,
                                                      referenceDigest: reference.sha256, expectedOffset: nil, searchRadius: 0,
                                                      options: options, cache: cache)
                }
                record.alignment = report.alignment
                record.explanation = report.explanation
            } catch {
                record.explanation = error.localizedDescription
            }
            return record
        }
    }
}

extension Meeting {
    /// Stores measurements, replacing earlier ones for the same pair of recordings.
    public mutating func recordAudioAlignments(_ results: [TrackAudioAlignment]) {
        guard !results.isEmpty else { return }
        var stored = audioAlignments ?? []
        for result in results {
            if let index = stored.firstIndex(where: { $0.id == result.id }) { stored[index] = result } else { stored.append(result) }
        }
        audioAlignments = stored
        updatedAt = Date()
    }
}
