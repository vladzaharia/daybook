import Foundation

// Voice clips (docs/architecture.md, "Voice clips"): the speech a voice profile learned from, kept as lossless clips cut
// from the original, so the full recording can be replaced by a lossy copy without losing the audio a voiceprint would
// be made again from (a new voice model's space, a voiceprint checked against its speech). A clip is one speaker of one
// recording of a conversation (`VoiceClipSource`): every voiceprint learned from that speaker, in any embedding space,
// shares it. It's a file in its conversation's folder (`Originals/VoiceClips/`) that the conversation names
// (`Meeting.voiceClips`), so it syncs as the conversation's recordings do (LibrarySyncVoiceClips.swift), sealed in an
// encrypted library, and goes when the conversation's files go.

/// The speech a voiceprint was learned from: one speaker of one recording of one conversation.
public struct VoiceClipSource: Codable, Hashable, Sendable {
    public var meetingID: UUID
    public var trackID: UUID
    /// The speaker whose embedding the voiceprint is (`Voiceprint.speakerID`: a run's speaker, "<run>:<label>").
    public var speakerID: String

    public init(meetingID: UUID, trackID: UUID, speakerID: String) {
        self.meetingID = meetingID; self.trackID = trackID; self.speakerID = speakerID
    }

    /// The source's name in file names and local state: the same source has the same key on every device.
    public var key: String {
        String(AudioDigest.sha256(data: Data("voice-clip|\(meetingID.uuidString)|\(trackID.uuidString)|\(speakerID)".utf8)).prefix(32))
    }

    /// A voiceprint learned from this source: its conversation and speaker, and its recording when it names one (one
    /// that doesn't is its speaker's, and a speaker belongs to one recording).
    public func isNamed(by print: Voiceprint) -> Bool {
        print.meetingID == meetingID && print.speakerID == speakerID && (print.trackID == nil || print.trackID == trackID)
    }
}

/// Seconds of a recording, start to end.
public struct VoiceClipSpan: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) { self.start = start; self.end = end }

    public var length: TimeInterval { end - start }
}

/// Frames of the original a clip holds, in the order it holds them.
public struct VoiceClipRange: Codable, Equatable, Sendable {
    public var startFrame: Int64
    public var endFrame: Int64

    public init(startFrame: Int64, endFrame: Int64) { self.startFrame = startFrame; self.endFrame = endFrame }

    public var frames: Int64 { endFrame - startFrame }
}

/// One clip of a conversation (`Meeting.voiceClips`): the speech of one of its recording's speakers, cut from the
/// recording's lossless original, what it holds, and the bytes it is.
public struct VoiceClip: Codable, Equatable, Identifiable, Sendable {
    /// Where clips live in a conversation's folder.
    public static let folder = "Originals/VoiceClips"

    /// The recording of the conversation that names it that it was cut from, and its speaker there.
    public var trackID: UUID
    public var speakerID: String
    /// The source voiceprints name, when the clip came here with its recording from another conversation (a copy kept
    /// under a new ID, a merge, Move to New Conversation): voiceprints still name the conversation they were learned
    /// from, so this clip is that source's, and the recording `trackID` here is that source's recording. Nil for a clip
    /// cut in this conversation, whose source is its own recording and speaker.
    public var carriedFrom: VoiceClipSource?
    /// `Originals/VoiceClips/<source key>-<first 16 hex of sha256>.caf` (`relativePath(for:sha256:)`).
    public var relativePath: String
    /// The clip file's SHA-256 and size.
    public var sha256: String
    public var size: Int64
    /// The SHA-256 of the lossless original it was cut from (the track's, or `encoding.previousSHA256` once compressed),
    /// and how many frames that original holds.
    public var originalSHA256: String
    public var originalFrames: Int64
    public var sampleRate: Double
    public var channels: Int
    /// The original's frames it holds, back to back (Linear PCM, 32-bit float, the original's rate and channels).
    public var ranges: [VoiceClipRange]
    public var createdAt: Date
    /// Found no longer to hold what the transcript says its speaker said (a passage given to someone else, the speakers
    /// identified again) where no lossless original was left to cut it again: kept, since it's all there is, but never
    /// taken for the speaker's speech again. A clip cut again in its place clears it.
    public var stale: Bool?
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()
    /// The whole of a clip record this version can't read (a newer Daybook's shape), written back as it came. Such a record
    /// covers nothing, is never hydrated, published, or let go here, and keeps the file it names (`unreadPath`).
    public private(set) var unread: SyncJSONValue?

    public init(trackID: UUID, speakerID: String, relativePath: String, sha256: String, size: Int64, originalSHA256: String,
                originalFrames: Int64, sampleRate: Double, channels: Int, ranges: [VoiceClipRange], createdAt: Date, stale: Bool? = nil,
                carriedFrom: VoiceClipSource? = nil) {
        self.trackID = trackID; self.speakerID = speakerID; self.relativePath = relativePath; self.sha256 = sha256; self.size = size
        self.originalSHA256 = originalSHA256; self.originalFrames = originalFrames; self.sampleRate = sampleRate; self.channels = channels
        self.ranges = ranges; self.createdAt = createdAt; self.stale = stale; self.carriedFrom = carriedFrom
    }

    private init(unread value: SyncJSONValue) {
        trackID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); speakerID = ""
        if case .object(let fields) = value, case .string(let path)? = fields["relativePath"] { relativePath = path } else { relativePath = "" }
        sha256 = ""; size = 0; originalSHA256 = ""; originalFrames = 0; sampleRate = 0; channels = 0; ranges = []
        createdAt = Date(timeIntervalSince1970: 0)
        unread = value
    }

    /// One clip a speaker of a recording; a carried one by the source it's of; one this version can't read by what it is.
    public var id: String {
        if let unread { return "unread|\(SyncEncoding.string(unread))" }
        if let carriedFrom { return "\(carriedFrom.meetingID.uuidString)|\(carriedFrom.trackID.uuidString)|\(carriedFrom.speakerID)" }
        return "\(trackID.uuidString)|\(speakerID)"
    }

    /// The source it's a clip of, in the conversation `meetingID` that names it: its own recording and speaker there, or
    /// the source it was carried from.
    public func source(in meetingID: UUID) -> VoiceClipSource {
        carriedFrom ?? VoiceClipSource(meetingID: meetingID, trackID: trackID, speakerID: speakerID)
    }

    /// This clip in another conversation, carried there with its recording (now `trackID` there): still the same
    /// source's, at the same path, so it's the same file and the same object.
    public func carried(from meetingID: UUID, to trackID: UUID) -> VoiceClip {
        var copy = self
        copy.carriedFrom = source(in: meetingID)
        copy.trackID = trackID
        return copy
    }

    /// The path a record this version can't read names, so its file is kept: only one under `Originals/VoiceClips/`.
    public var unreadPath: String? {
        guard unread != nil, relativePath.hasPrefix(Self.folder + "/"), !relativePath.contains("..") else { return nil }
        return relativePath
    }

    /// The library path for a source's clip with this digest: each cut of it has its own path, so a clip cut again
    /// never meets another's bytes at its path.
    public static func relativePath(for source: VoiceClipSource, sha256: String) -> String {
        "\(folder)/\(source.key)-\(sha256.prefix(16)).caf"
    }

    /// Its path is the one its source and digest give, so it can't name anything but a clip of that source. Never for a
    /// record this version can't read.
    public func isStored(in meetingID: UUID) -> Bool {
        unread == nil && SyncFiles.isHash(sha256) && SyncFiles.isHash(originalSHA256)
            && relativePath == Self.relativePath(for: source(in: meetingID), sha256: sha256)
    }

    /// The clip's file in a library's conversation (`<root>/Meetings/<ID>/<relativePath>`); nil when its path isn't the
    /// one its source and digest give.
    public func fileURL(in meetingID: UUID, root: URL) -> URL? {
        guard isStored(in: meetingID) else { return nil }
        return root.appendingPathComponent("Meetings/\(meetingID.uuidString)/\(relativePath)")
    }

    /// Where each range sits in the clip, in seconds: what a voice model reads as the speaker's turns.
    public var spansInClip: [VoiceClipSpan] {
        var offset: Int64 = 0
        return ranges.map { range in
            defer { offset += range.frames }
            return VoiceClipSpan(start: Double(offset) / sampleRate, end: Double(offset + range.frames) / sampleRate)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case trackID, speakerID, carriedFrom, relativePath, sha256, size, originalSHA256, originalFrames, sampleRate, channels, ranges, createdAt, stale
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// Reads one clip record; one this version can't read is kept as it came (`unread`), so a conversation's list never
    /// fails as a whole and a newer version's records survive a round trip.
    public init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            var clip = VoiceClip(trackID: try values.decode(UUID.self, forKey: .trackID), speakerID: try values.decode(String.self, forKey: .speakerID),
                                 relativePath: try values.decode(String.self, forKey: .relativePath), sha256: try values.decode(String.self, forKey: .sha256),
                                 size: try values.decode(Int64.self, forKey: .size), originalSHA256: try values.decode(String.self, forKey: .originalSHA256),
                                 originalFrames: try values.decode(Int64.self, forKey: .originalFrames),
                                 sampleRate: try values.decode(Double.self, forKey: .sampleRate), channels: try values.decode(Int.self, forKey: .channels),
                                 ranges: try values.decode([VoiceClipRange].self, forKey: .ranges), createdAt: try values.decode(Date.self, forKey: .createdAt),
                                 stale: try values.decodeIfPresent(Bool.self, forKey: .stale),
                                 carriedFrom: try values.decodeIfPresent(VoiceClipSource.self, forKey: .carriedFrom))
            clip.unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
            self = clip
        } catch {
            self = VoiceClip(unread: try SyncJSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if let unread { try unread.encode(to: encoder); return }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(trackID, forKey: .trackID)
        try values.encode(speakerID, forKey: .speakerID)
        try values.encodeIfPresent(carriedFrom, forKey: .carriedFrom)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(size, forKey: .size)
        try values.encode(originalSHA256, forKey: .originalSHA256)
        try values.encode(originalFrames, forKey: .originalFrames)
        try values.encode(sampleRate, forKey: .sampleRate)
        try values.encode(channels, forKey: .channels)
        try values.encode(ranges, forKey: .ranges)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(stale, forKey: .stale)
        try unknownFields.encode(to: encoder)
    }

    /// Two devices' clips of a conversation, merged one speaker of a recording at a time, never with a conflict: a side
    /// that changed it from the ancestor wins (a clip cut again, marked stale, or let go); when both changed it, a clip
    /// beats none (a clip is never lost to a merge: one no voiceprint names goes again a day later), and of two the one
    /// cut later (then the smaller digest, then the stale mark) wins. Commutative and idempotent. In the ancestor's
    /// order, then new ones by ID.
    public static func mergedList(base: [VoiceClip], local: [VoiceClip], remote: [VoiceClip]) -> [VoiceClip] {
        var order: [String] = []
        for clip in base where !order.contains(clip.id) { order.append(clip.id) }
        order += Set((local + remote).map(\.id)).subtracting(order).sorted()
        return order.compactMap { id in
            let a = local.first { $0.id == id }, b = remote.first { $0.id == id }, old = base.first { $0.id == id }
            if a == b { return a }
            if let old {
                if a == old { return b }
                if b == old { return a }
            }
            guard let a else { return b }
            guard let b else { return a }
            return preferred(a, b)
        }
    }

    private static func preferred(_ a: VoiceClip, _ b: VoiceClip) -> VoiceClip {
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt ? a : b }
        if a.sha256 != b.sha256 { return a.sha256 < b.sha256 ? a : b }
        if (a.stale == true) != (b.stale == true) { return a.stale == true ? a : b }
        return SyncEncoding.string(a) >= SyncEncoding.string(b) ? a : b
    }
}

extension Meeting {
    /// The clip this conversation names of a source (its own, or one carried here), when it names one.
    public func voiceClip(for source: VoiceClipSource) -> VoiceClip? {
        voiceClips?.first { $0.unread == nil && $0.source(in: id) == source }
    }

    /// The conversation's clips list is one this version reads (a newer Daybook's shape is kept as an unknown key, and no
    /// clip is cut, carried, or let go in it here).
    public var voiceClipsAreReadable: Bool { unknownFields["voiceClips"] == nil }

    /// The clip holds what the transcript says its speaker said, cut from the lossless original its recording has now
    /// (the track's file, or the one a compressed copy replaced): its frames are the ones the speaker's passages give
    /// now (`VoiceClips.spans`), and it isn't marked stale. A clip carried here from another conversation holds the
    /// passages its source had when it came (the transcript here, made again or edited, isn't the one its voiceprints
    /// were learned from), so only its recording is asked for: still the original it was cut from.
    public func voiceClipIsCurrent(_ clip: VoiceClip) -> Bool {
        guard clip.unread == nil, clip.stale != true, let track = tracks.first(where: { $0.id == clip.trackID }),
              clip.originalSHA256 == track.sha256 || clip.originalSHA256 == track.encoding?.previousSHA256 else { return false }
        if clip.carriedFrom != nil { return true }
        let ranges = VoiceClipAudio.ranges(VoiceClips.spans(for: clip.source(in: id), in: self), rate: clip.sampleRate, length: clip.originalFrames)
        return ranges == clip.ranges
    }

    /// This conversation's clips of `trackIDs` (each mapped to its recording in `into`), carried to another conversation
    /// with their recordings: those that hold their source's speech now (`voiceClipIsCurrent`), still that source's, at
    /// the same paths; one that doesn't goes marked stale (it may be all there is of that speech, and is never taken for
    /// it). Empty when this conversation's list is in a shape this version can't read.
    public func voiceClipsCarried(_ trackIDs: [UUID: UUID]) -> [VoiceClip] {
        guard voiceClipsAreReadable else { return [] }
        return (voiceClips ?? []).compactMap { clip in
            guard clip.unread == nil, clip.isStored(in: id), let target = trackIDs[clip.trackID] else { return nil }
            var carried = clip.carried(from: id, to: target)
            if !voiceClipIsCurrent(clip) { carried.stale = true }
            return carried
        }
    }
}

/// Which speech a library's voice profiles need kept, decided from its settings and conversations alone.
public enum VoiceClips {
    /// The prefix of a clip being made, hidden beside where it goes (swept at launch).
    public static let temporaryPrefix = ".clip-"

    /// Each clip holds at most 30 s of the speaker's speech nobody talks over (the most a voiceprint's speech counts
    /// for in matching, `SpeakerProfileLearning`), the longest passages first.
    public static let maximumSecondsPerSource: TimeInterval = 30
    /// How long a clip no voiceprint names stays before it's deleted.
    public static let orphanGrace: TimeInterval = 86_400

    public struct Plan: Equatable, Sendable {
        /// Sources (by key) a voiceprint of a profile that still exists names, with the source itself: each one's clip
        /// is kept, and cut where it isn't. Every one of them: a profile is bounded by its voiceprints
        /// (`SpeakerProfileLearning.maximumPersonChosen` and `maximumRecognized` per embedding space).
        public var wanted: [String: VoiceClipSource] = [:]
        /// Every profile and voiceprint record is in a shape this version reads. When one isn't, which sources are live
        /// can't be known: nothing is deleted, and every voiceprint holds its recording back as before clips.
        public var readable = true

        public init(wanted: [String: VoiceClipSource] = [:], readable: Bool = true) {
            self.wanted = wanted; self.readable = readable
        }
    }

    /// The recording and speaker a voiceprint was learned from: its own track, else its speaker's recording; nil when
    /// neither is known. When its conversation can't say (it isn't here: deleted, merged away), a clip carried from it to
    /// another conversation does (`carried`, `carriedSources`).
    public static func source(of print: Voiceprint, in meeting: Meeting?, carried: [VoiceClipSource] = []) -> VoiceClipSource? {
        if let trackID = print.trackID ?? meeting?.speakers.first(where: { $0.id == print.speakerID })?.sourceTrackID {
            return VoiceClipSource(meetingID: print.meetingID, trackID: trackID, speakerID: print.speakerID)
        }
        return carried.first { $0.isNamed(by: print) }
    }

    /// The sources clips were carried from, in every conversation here, in one order on every device.
    public static func carriedSources(in meetings: [Meeting]) -> [VoiceClipSource] {
        meetings.flatMap { ($0.voiceClips ?? []).compactMap { $0.unread == nil ? $0.carriedFrom : nil } }.sorted { $0.key < $1.key }
    }

    /// The voiceprints that count: each whose profile (merges followed) exists, or has no record here at all, since it
    /// can't be known to be gone. Nil while any profile or voiceprint record is in a shape this version can't read.
    public static func counting(_ metadata: LibraryMetadata) -> [Voiceprint]? {
        let profiles = metadata.speakerProfiles ?? [], prints = metadata.voiceprints ?? []
        guard !profiles.contains(where: { $0.unreadableValue != nil }), !prints.contains(where: { $0.unreadableValue != nil }) else { return nil }
        let merges = metadata.speakerProfileMerges
        let recorded = Set(profiles.map(\.id))
        return prints.compactMap(\.value).filter { merges.resolve($0.profileID) != nil || !recorded.contains($0.profileID.uuidString) }
    }

    /// What the library's profiles need kept.
    public static func plan(metadata: LibraryMetadata, meetings: [Meeting]) -> Plan {
        guard let prints = counting(metadata) else { return Plan(readable: false) }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let carried = carriedSources(in: meetings)
        var plan = Plan()
        for print in prints {
            guard let source = source(of: print, in: byID[print.meetingID], carried: carried) else { continue }
            plan.wanted[source.key] = source
        }
        return plan
    }

    /// Whether a clip file named by source key `key`, in conversation `meeting`'s folder, holds speech a voiceprint that
    /// counts still needs, wherever it sits: a voiceprint's source has that key (one that names no recording, by each
    /// recording of `meeting`, which a copy kept under a new ID shares). True for every key while a record can't be read.
    public static func isNeeded(_ key: String, in meeting: Meeting, metadata: LibraryMetadata, wanted: Plan) -> Bool {
        guard wanted.readable, let prints = counting(metadata) else { return true }
        if wanted.wanted[key] != nil { return true }
        return prints.contains { print in
            print.trackID == nil && meeting.tracks.contains { VoiceClipSource(meetingID: print.meetingID, trackID: $0.id, speakerID: print.speakerID).key == key }
        }
    }

    /// The voiceprints that still hold their recordings back (`RecordingCompressionPlanner.learnedFrom`): each one of a
    /// profile that counts whose clip isn't covered (`covered`, by key), and each one whose recording isn't known. While
    /// any record can't be read, every voiceprint does, as before clips.
    public static func holdingBack(metadata: LibraryMetadata, meetings: [Meeting], covered: Set<String>) -> [Voiceprint] {
        guard let prints = counting(metadata) else { return (metadata.voiceprints ?? []).compactMap(\.value) }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let carried = carriedSources(in: meetings)
        return prints.filter { print in
            guard let key = source(of: print, in: byID[print.meetingID], carried: carried)?.key else { return true }
            return !covered.contains(key)
        }
    }

    /// The speaker's passages in its recording that nobody talks over, from the run with the most of them: the longest
    /// first, up to `maximumSecondsPerSource` (the last one cut short to fit), returned in order. Talked over means by
    /// anyone else in the run, a passage whose speaker isn't known included, and, for a microphone, the far end of a call
    /// the computer audio recorded with it (`farEnd`), which its speakers can play into it. A speaker matched to another
    /// when its recording was added has its passages under that speaker's label, so that label is read when its own has
    /// none. Empty when there's nothing to cut. Only the recordings' own transcripts and capture are read (never what
    /// fusion places on the timeline), so the same transcript gives the same passages.
    public static func spans(for source: VoiceClipSource, in meeting: Meeting) -> [VoiceClipSpan] {
        let runs = meeting.transcripts.filter { $0.trackID == source.trackID }.sorted { $0.id.uuidString < $1.id.uuidString }
        let farEnd = farEnd(of: source.trackID, in: meeting)
        func clean(label: String) -> [VoiceClipSpan] {
            var best: [VoiceClipSpan] = [], bestTotal = 0.0
            for run in runs {
                let segments = run.segments.filter { $0.end > $0.start }
                let mine = merged(segments.filter { $0.speakerID == label }.map { VoiceClipSpan(start: $0.start, end: $0.end) })
                let others = merged(segments.filter { $0.speakerID != label }.map { VoiceClipSpan(start: $0.start, end: $0.end) } + farEnd)
                let spans = subtract(others, from: mine)
                let total = spans.reduce(0) { $0 + $1.length }
                if total > bestTotal { best = spans; bestTotal = total }
            }
            return best
        }
        var spans = clean(label: source.speakerID)
        if spans.isEmpty, let target = meeting.speakerMatches?.first(where: {
            $0.sourceSpeakerID == source.speakerID && $0.status == .matched && $0.$status.isKnown
        })?.targetSpeakerID {
            spans = clean(label: target)
        }
        var chosen: [VoiceClipSpan] = [], total = 0.0
        for span in spans.sorted(by: { $0.length == $1.length ? $0.start < $1.start : $0.length > $1.length }) {
            guard total < maximumSecondsPerSource else { break }
            let length = min(span.length, maximumSecondsPerSource - total)
            chosen.append(VoiceClipSpan(start: span.start, end: span.start + length))
            total += length
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// For a microphone (or its echo-cancelled copy), what the computer audio captured with it says (one capture,
    /// `TrackCaptureDetails.captureID`), in the microphone's own time by the capture's stored offsets and clock rates
    /// (`meetingTime = offset + trackTime × clockRate`). Empty for anything else, or where an offset isn't stored.
    static func farEnd(of trackID: UUID, in meeting: Meeting) -> [VoiceClipSpan] {
        guard let track = meeting.tracks.first(where: { $0.id == trackID }) else { return [] }
        let original = track.derivedFrom.flatMap { id in meeting.tracks.first { $0.id == id } } ?? track
        // An echo-cancelled copy starts where its original does.
        guard original.$source.isKnown, original.source == .microphone, let capture = track.capture?.captureID ?? original.capture?.captureID,
              let offset = track.offset ?? original.offset, offset.isFinite else { return [] }
        let rate = track.capture?.clockRate ?? 1
        guard rate.isFinite, rate > 0 else { return [] }
        var spans: [VoiceClipSpan] = []
        for other in meeting.tracks where other.$source.isKnown && other.source == .systemAudio && other.capture?.captureID == capture {
            guard let theirOffset = other.offset, theirOffset.isFinite else { continue }
            let theirRate = other.capture?.clockRate ?? 1
            guard theirRate.isFinite, theirRate > 0 else { continue }
            func here(_ time: TimeInterval) -> TimeInterval { (theirOffset + time * theirRate - offset) / rate }
            for run in meeting.transcripts where run.trackID == other.id {
                for segment in run.segments where segment.end > segment.start {
                    spans.append(VoiceClipSpan(start: here(segment.start), end: here(segment.end)))
                }
            }
        }
        return spans
    }

    static func merged(_ spans: [VoiceClipSpan]) -> [VoiceClipSpan] {
        var result: [VoiceClipSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end { result[result.count - 1].end = max(last.end, span.end) } else { result.append(span) }
        }
        return result
    }

    /// `spans` less everything in `cut` (both merged and in order).
    static func subtract(_ cut: [VoiceClipSpan], from spans: [VoiceClipSpan]) -> [VoiceClipSpan] {
        var result: [VoiceClipSpan] = []
        for span in spans {
            var start = span.start
            for other in cut where other.end > start && other.start < span.end {
                if other.start > start { result.append(VoiceClipSpan(start: start, end: other.start)) }
                start = max(start, other.end)
            }
            if span.end > start { result.append(VoiceClipSpan(start: start, end: span.end)) }
        }
        return result
    }
}
