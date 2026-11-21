import Foundation

// Voice clips (docs/architecture.md, "Compressing older recordings", "Voice profiles"): the speech a voice profile learned
// from, kept on the Mac as lossless clips cut from the original, so the full recording can be replaced by a lossy copy
// without losing the audio a voiceprint would be made again from (a new voice model's space, a voiceprint checked
// against its speech). A clip is one speaker of one recording (`VoiceClipSource`): every voiceprint learned from that
// speaker, in any embedding space, shares it. Kept beside the library (`VoiceClips/`), never synced: what syncs of a
// profile stays its voiceprints.

/// The speech a voiceprint was learned from: one speaker of one recording of one conversation.
public struct VoiceClipSource: Codable, Hashable, Sendable {
    public var meetingID: UUID
    public var trackID: UUID
    /// The speaker whose embedding the voiceprint is (`Voiceprint.speakerID`: a run's speaker, "<run>:<label>").
    public var speakerID: String

    public init(meetingID: UUID, trackID: UUID, speakerID: String) {
        self.meetingID = meetingID; self.trackID = trackID; self.speakerID = speakerID
    }

    /// The clip's name in the index and on disk: the same source has the same key on every Mac.
    public var key: String {
        String(AudioDigest.sha256(data: Data("voice-clip|\(meetingID.uuidString)|\(trackID.uuidString)|\(speakerID)".utf8)).prefix(32))
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

/// One clip on this Mac: where it came from, what it holds, and how to tell it's still the bytes that were checked.
public struct VoiceClip: Codable, Equatable, Sendable {
    public var source: VoiceClipSource
    /// The file in `VoiceClips/`: `<key>.caf`.
    public var fileName: String
    /// The clip file's SHA-256 and size.
    public var sha256: String
    public var size: Int64
    /// The SHA-256 of the lossless original it was cut from (the track's, or `encoding.previousSHA256` once compressed).
    public var originalSHA256: String
    public var sampleRate: Double
    public var channels: Int
    /// The original's frames it holds, back to back (Linear PCM, 32-bit float, the original's rate and channels).
    public var ranges: [VoiceClipRange]
    public var createdAt: Date
    /// The file's stamp when its bytes were last checked against `sha256` (volume, inode, size, and modification and
    /// status-change times to the nanosecond): a clip is relied on only while its file still has it.
    public var stamp: [Int64]
    /// When no voiceprint named its source any more (the profile deleted, the speaker taken out of it); cleared if one
    /// does again. The clip is deleted `VoiceClips.orphanGrace` after this, so an Undo on any device brings it back whole.
    public var orphanedAt: Date?

    public init(source: VoiceClipSource, fileName: String, sha256: String, size: Int64, originalSHA256: String, sampleRate: Double,
                channels: Int, ranges: [VoiceClipRange], createdAt: Date, stamp: [Int64], orphanedAt: Date? = nil) {
        self.source = source; self.fileName = fileName; self.sha256 = sha256; self.size = size; self.originalSHA256 = originalSHA256
        self.sampleRate = sampleRate; self.channels = channels; self.ranges = ranges; self.createdAt = createdAt; self.stamp = stamp
        self.orphanedAt = orphanedAt
    }

    /// Where each range sits in the clip, in seconds: what a voice model reads as the speaker's turns.
    public var spansInClip: [VoiceClipSpan] {
        var offset: Int64 = 0
        return ranges.map { range in
            defer { offset += range.frames }
            return VoiceClipSpan(start: Double(offset) / sampleRate, end: Double(offset + range.frames) / sampleRate)
        }
    }
}

/// `VoiceClips/clips.json`: every clip this Mac holds, by source key.
public struct VoiceClipIndex: Codable, Equatable, Sendable {
    public var version = 1
    public var clips: [String: VoiceClip] = [:]

    public init(clips: [String: VoiceClip] = [:]) { self.clips = clips }
}

/// Which speech a library's voice profiles need kept, decided from its settings and conversations alone.
public enum VoiceClips {
    /// The folder beside the library's conversations, its index, and the prefix of a clip being made (swept at launch).
    public static let folderName = "VoiceClips"
    public static let indexName = "clips.json"
    public static let temporaryPrefix = ".clip-"

    /// Each clip holds at most 30 s of the speaker's speech nobody talks over (the most a voiceprint's speech counts
    /// for in matching, `SpeakerProfileLearning`), the longest passages first.
    public static let maximumSecondsPerSource: TimeInterval = 30
    /// A profile keeps clips for its 8 sources that count most: the person's own voiceprints (named, confirmed) first,
    /// newest first, then learned ones. So at most 4 minutes a profile; beyond them, a recording isn't held back.
    public static let maximumSourcesPerProfile = 8
    /// How long a clip no voiceprint names stays before it's deleted.
    public static let orphanGrace: TimeInterval = 86_400

    public struct Plan: Equatable, Sendable {
        /// Sources (by key) any voiceprint of a profile that still exists names: their clips stay.
        public var live: Set<String> = []
        /// Sources (by key) each profile keeps clips for (`maximumSourcesPerProfile`), with the source itself.
        public var wanted: [String: VoiceClipSource] = [:]
        /// Every profile and voiceprint record is in a shape this version reads. When one isn't, which sources are live
        /// can't be known: nothing is deleted, and every voiceprint holds its recording back as before clips.
        public var readable = true

        public init(live: Set<String> = [], wanted: [String: VoiceClipSource] = [:], readable: Bool = true) {
            self.live = live; self.wanted = wanted; self.readable = readable
        }
    }

    /// The recording and speaker a voiceprint was learned from: its own track, else its speaker's recording; nil when
    /// neither is known.
    public static func source(of print: Voiceprint, in meeting: Meeting?) -> VoiceClipSource? {
        guard let trackID = print.trackID ?? meeting?.speakers.first(where: { $0.id == print.speakerID })?.sourceTrackID else { return nil }
        return VoiceClipSource(meetingID: print.meetingID, trackID: trackID, speakerID: print.speakerID)
    }

    /// What the library's profiles need kept. A voiceprint counts while its profile (merges followed) exists; one whose
    /// profile has no record here at all counts too, since it can't be known to be gone.
    public static func plan(metadata: LibraryMetadata, meetings: [Meeting]) -> Plan {
        var plan = Plan()
        let profiles = metadata.speakerProfiles ?? [], prints = metadata.voiceprints ?? []
        plan.readable = !profiles.contains { $0.unreadableValue != nil } && !prints.contains { $0.unreadableValue != nil }
        let merges = metadata.speakerProfileMerges
        let recorded = Set(profiles.map(\.id))
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        struct Candidate { var source: VoiceClipSource; var personChosen: Bool; var recordedAt: Date; var speech: Double }
        var byProfile: [UUID: [String: Candidate]] = [:]
        for print in prints.compactMap(\.value) {
            let profile: UUID
            if let target = merges.resolve(print.profileID) { profile = target }
            else if !recorded.contains(print.profileID.uuidString) { profile = print.profileID }
            else { continue }
            guard let source = source(of: print, in: byID[print.meetingID]) else { continue }
            let key = source.key
            plan.live.insert(key)
            // An origin a newer Daybook wrote counts as the person's, so it's kept first.
            let candidate = Candidate(source: source, personChosen: print.origin.isPersonChosen || !print.$origin.isKnown,
                                      recordedAt: print.recordedAt, speech: print.speechSeconds)
            if let existing = byProfile[profile]?[key], !Self.ranksBefore(candidate.personChosen, candidate.recordedAt, candidate.speech, key,
                                                                         existing.personChosen, existing.recordedAt, existing.speech, key) { continue }
            byProfile[profile, default: [:]][key] = candidate
        }
        for candidates in byProfile.values {
            let ranked = candidates.sorted { a, b in
                ranksBefore(a.value.personChosen, a.value.recordedAt, a.value.speech, a.key, b.value.personChosen, b.value.recordedAt, b.value.speech, b.key)
            }
            for (key, candidate) in ranked.prefix(maximumSourcesPerProfile) { plan.wanted[key] = candidate.source }
        }
        return plan
    }

    private static func ranksBefore(_ chosenA: Bool, _ dateA: Date, _ speechA: Double, _ keyA: String,
                                    _ chosenB: Bool, _ dateB: Date, _ speechB: Double, _ keyB: String) -> Bool {
        if chosenA != chosenB { return chosenA }
        if dateA != dateB { return dateA > dateB }
        if speechA != speechB { return speechA > speechB }
        return keyA < keyB
    }

    /// The voiceprints that still hold their recordings back (`RecordingCompressionPlanner.learnedFrom`): each one whose
    /// source a profile keeps a clip for and whose clip isn't here (`covered`, by key), and each one whose recording
    /// isn't known. A voiceprint whose profile is gone, or whose source is beyond its profile's clips, holds nothing back.
    /// While any record can't be read, every voiceprint does, as before clips.
    public static func holdingBack(_ plan: Plan, metadata: LibraryMetadata, meetings: [Meeting], covered: Set<String>) -> [Voiceprint] {
        let prints = (metadata.voiceprints ?? []).compactMap(\.value)
        guard plan.readable else { return prints }
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let merges = metadata.speakerProfileMerges
        let recorded = Set((metadata.speakerProfiles ?? []).map(\.id))
        return prints.filter { print in
            guard merges.resolve(print.profileID) != nil || !recorded.contains(print.profileID.uuidString) else { return false }
            guard let key = source(of: print, in: byID[print.meetingID])?.key else { return true }
            return plan.wanted[key] != nil && !covered.contains(key)
        }
    }

    /// The speaker's passages in its recording that nobody talks over, from the run with the most of them: the longest
    /// first, up to `maximumSecondsPerSource` (the last one cut short to fit), returned in order. A speaker matched to
    /// another when its recording was added has its passages under that speaker's label, so that label is read when
    /// its own has none. Empty when there's nothing to cut.
    public static func spans(for source: VoiceClipSource, in meeting: Meeting) -> [VoiceClipSpan] {
        let runs = meeting.transcripts.filter { $0.trackID == source.trackID }.sorted { $0.id.uuidString < $1.id.uuidString }
        func clean(label: String) -> [VoiceClipSpan] {
            var best: [VoiceClipSpan] = [], bestTotal = 0.0
            for run in runs {
                let segments = run.segments.filter { $0.end > $0.start && $0.speakerID != nil }
                let mine = merged(segments.filter { $0.speakerID == label }.map { VoiceClipSpan(start: $0.start, end: $0.end) })
                let others = merged(segments.filter { $0.speakerID != label }.map { VoiceClipSpan(start: $0.start, end: $0.end) })
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
