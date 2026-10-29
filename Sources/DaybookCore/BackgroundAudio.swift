import Foundation

/// What a recording's sound classifier heard, frame by frame in the recording's own time: how much
/// each stretch sounded like speech, like music, and like an audience (applause, cheering), and how
/// loud it was. It describes the audio, not a transcript, so it's measured once per recording and
/// kept on its track (`RecordingTrack.backgroundAudio`); `BackgroundAudio.judge` reads it to keep
/// TV, radio, and music out of the transcript Daybook shows (docs/architecture.md, "Background audio").
public struct BackgroundAudioAnalysis: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    /// What classified the sound, for provenance: "SoundAnalysis version1".
    public var classifier: String
    public var analyzedAt: Date
    /// Seconds between frames: frame `i` covers `i × hop` to `i × hop + window`.
    public var hop: Double
    public var window: Double
    /// One byte per frame for each score, 0–255 for 0–1, so an hour costs a few kilobytes.
    public var speech: Data
    public var music: Data
    public var audience: Data
    /// One signed byte per frame: the level in dBFS (−127…0). Nil when it wasn't measured.
    public var level: Data?

    public init(version: Int = BackgroundAudioAnalysis.currentVersion, classifier: String, analyzedAt: Date = Date(),
                hop: Double, window: Double, speech: [Double], music: [Double], audience: [Double], level: [Double]? = nil) {
        self.version = version; self.classifier = classifier; self.analyzedAt = analyzedAt
        self.hop = hop; self.window = window
        let count = min(speech.count, music.count, audience.count)
        func bytes(_ values: [Double]) -> Data {
            Data(values.prefix(count).map { UInt8(max(0, min(255, (($0.isFinite ? $0 : 0) * 255).rounded()))) })
        }
        self.speech = bytes(speech); self.music = bytes(music); self.audience = bytes(audience)
        self.level = level.map { values in
            Data(values.prefix(count).map { UInt8(bitPattern: Int8(max(-127, min(0, ($0.isFinite ? $0 : -127).rounded())))) })
        }
    }

    /// One classifier window.
    public struct Frame: Equatable, Sendable {
        public var start: TimeInterval
        public var speech: Double
        public var music: Double
        public var audience: Double
        public var level: Double?
        /// Music or an audience, whichever is stronger: sound that isn't the conversation.
        public var background: Double { max(music, audience) }
    }

    public var frameCount: Int { min(speech.count, music.count, audience.count) }

    public func frame(_ index: Int) -> Frame {
        func score(_ data: Data) -> Double { Double(data[data.startIndex + index]) / 255 }
        let decibels = level.flatMap { data in index < data.count ? Double(Int8(bitPattern: data[data.startIndex + index])) : nil }
        return Frame(start: Double(index) * hop, speech: score(speech), music: score(music), audience: score(audience), level: decibels)
    }

    /// The frames centred inside `start…end` (recording time), or the nearest one for a span
    /// shorter than a frame. Empty when nothing was analysed there.
    public func frames(from start: TimeInterval, to end: TimeInterval) -> [Frame] {
        let count = frameCount
        guard count > 0, hop > 0, start.isFinite, end.isFinite, end >= start else { return [] }
        let half = window / 2
        let first = max(0, Int(((start - half) / hop).rounded(.up)))
        let last = min(count - 1, Int(((end - half) / hop).rounded(.down)))
        if first <= last { return (first...last).map(frame) }
        let middle = (start + end) / 2
        let nearest = Int(((middle - half) / hop).rounded())
        guard nearest >= 0, nearest < count, abs(Double(nearest) * hop + half - middle) <= max(hop, half) else { return [] }
        return [frame(nearest)]
    }
}

/// Decides which passages of a transcript are background audio (music, or a TV or radio) rather
/// than the conversation. Conservative by design: a person talking over quiet music stays.
///
/// Three kinds of evidence, each enough on its own:
/// 1. **A sound tag.** The recognizer wrote only "[Music]", "(upbeat music)", or lyrics between ♪.
/// 2. **Music without speech.** At least 60% of the passage is frames where music (or applause and
///    cheering) is clear (≥ 0.5) and speech isn't (≤ 0.3): lyrics, a jingle, a soundtrack.
/// 3. **A broadcast voice.** A speaker (one diarized cluster) with at least 4 s of speech, 60% of it
///    with music about as strong as the voice (within 0.15), at least 7 dB quieter than the loudest
///    speaker who talks mostly without music (at least 4 s): the presenter on a TV or radio across
///    the room, with its music bed. The classifier alone can't tell that presenter from someone in
///    the room talking over music, so distance (the level) has to agree. A speaker the person named
///    is never judged, and the speaker's passages that are clear of background sound stay.
///
/// Nothing is deleted: the transcript runs keep every passage, fusion leaves the judged ones out of
/// the unified transcript (`Meeting.backgroundPassages` keeps them), and the person can include them.
public enum BackgroundAudio {
    public enum Kind: String, Codable, Sendable {
        /// Music, singing, or a soundtrack.
        case music
        /// A TV or radio: a presenter over music, applause, a studio audience.
        case broadcast
    }

    public struct Verdict: Equatable, Sendable {
        /// Passages (transcript segment IDs) that are background audio, and why.
        public var segments: [UUID: Kind] = [:]
        /// Speaker labels judged to be a broadcast voice. Their voice profiles aren't evidence of anyone
        /// in the conversation.
        public var speakers: [String: Kind] = [:]
        public init(segments: [UUID: Kind] = [:], speakers: [String: Kind] = [:]) { self.segments = segments; self.speakers = speakers }
        public var isEmpty: Bool { segments.isEmpty && speakers.isEmpty }
    }

    /// The decision's thresholds. The defaults are the ones measured in docs/validation.md
    /// ("Background audio"); tests can tighten them.
    public struct Thresholds: Equatable, Sendable {
        /// Rule 2: a frame is music without speech when background ≥ this and speech ≤ `quietSpeech`.
        public var clearBackground = 0.5
        public var quietSpeech = 0.3
        /// Rule 2: the share of a passage's frames that must be music without speech.
        public var backgroundShare = 0.6
        /// Rule 3: a frame accompanies a voice when background ≥ this and ≥ speech − `accompanimentMargin`.
        public var accompaniment = 0.45
        public var accompanimentMargin = 0.15
        /// Rule 3: the share of a speaker's frames accompanied, and the most a conversation speaker may have.
        public var broadcastShare = 0.6
        public var conversationShare = 0.3
        /// Rule 3: speech each speaker needs before it's compared.
        public var minimumSpeech: TimeInterval = 4
        /// Rule 3: a broadcast voice is at least this many dB quieter than the loudest conversation speaker.
        public var quieterBy = 7.0
        /// Rule 3: a speaker's passage stays when this share of its frames has background below `clearOfBackground`.
        public var clearShare = 0.8
        public var clearOfBackground = 0.2
        public init() {}
    }

    /// The verdict for one transcript run's passages (in the recording's own time). `protectedSpeakers`
    /// are labels never judged (speakers the person named). Without an analysis only sound tags count.
    public static func judge(_ segments: [TranscriptSegment], analysis: BackgroundAudioAnalysis?,
                             protectedSpeakers: Set<String> = [], thresholds: Thresholds = Thresholds()) -> Verdict {
        var verdict = Verdict()
        for segment in segments where isSoundTag(segment.text) {
            verdict.segments[segment.id] = soundTagKind(segment.text)
        }
        guard let analysis, analysis.frameCount > 0 else { return verdict }
        let framesBySegment = Dictionary(segments.map { ($0.id, analysis.frames(from: $0.start, to: $0.end)) }, uniquingKeysWith: { first, _ in first })

        // Rule 2: music without speech.
        for segment in segments where verdict.segments[segment.id] == nil && !protectedSpeakers.contains(segment.speakerID ?? "") {
            let frames = framesBySegment[segment.id] ?? []
            guard !frames.isEmpty else { continue }
            let quiet = frames.filter { $0.background >= thresholds.clearBackground && $0.speech <= thresholds.quietSpeech }
            guard Double(quiet.count) >= thresholds.backgroundShare * Double(frames.count) else { continue }
            let music = quiet.map(\.music).reduce(0, +), audience = quiet.map(\.audience).reduce(0, +)
            verdict.segments[segment.id] = music >= audience ? .music : .broadcast
        }

        // Rule 3: a broadcast voice, by speaker.
        struct Voice { var speech: TimeInterval = 0; var frames: [BackgroundAudioAnalysis.Frame] = []; var segments: [TranscriptSegment] = [] }
        var voices: [String: Voice] = [:]
        for segment in segments {
            guard let label = segment.speakerID else { continue }
            voices[label, default: Voice()].speech += max(0, segment.end - segment.start)
            voices[label, default: Voice()].frames += framesBySegment[segment.id] ?? []
            voices[label, default: Voice()].segments.append(segment)
        }
        // A "speaker" all of whose passages are music or sound (a diarizer's cluster for a song) is no one's voice.
        for (label, voice) in voices where !protectedSpeakers.contains(label) {
            let kinds = voice.segments.map { verdict.segments[$0.id] }
            guard !kinds.isEmpty, kinds.allSatisfy({ $0 != nil }) else { continue }
            verdict.speakers[label] = kinds.allSatisfy { $0 == .music } ? .music : .broadcast
        }
        func accompanied(_ frame: BackgroundAudioAnalysis.Frame) -> Bool {
            frame.background >= thresholds.accompaniment && frame.background >= frame.speech - thresholds.accompanimentMargin
        }
        func share(_ voice: Voice) -> Double {
            voice.frames.isEmpty ? 0 : Double(voice.frames.filter(accompanied).count) / Double(voice.frames.count)
        }
        func loudness(_ voice: Voice) -> Double? {
            let levels = voice.frames.compactMap(\.level).sorted()
            return levels.isEmpty ? nil : levels[levels.count / 2]
        }
        let compared = voices.filter { $0.value.speech >= thresholds.minimumSpeech && !$0.value.frames.isEmpty }
        let conversation = compared.filter { share($0.value) <= thresholds.conversationShare }
        guard !conversation.isEmpty else { return verdict }
        guard let loudestConversation = conversation.values.compactMap(loudness).max() else { return verdict }
        for (label, voice) in compared.sorted(by: { $0.key < $1.key }) where !protectedSpeakers.contains(label) && verdict.speakers[label] == nil {
            guard share(voice) >= thresholds.broadcastShare, let level = loudness(voice),
                  level <= loudestConversation - thresholds.quieterBy else { continue }
            for segment in voice.segments where verdict.segments[segment.id] == nil {
                let frames = framesBySegment[segment.id] ?? []
                let clear = frames.filter { $0.background < thresholds.clearOfBackground }
                if !frames.isEmpty && Double(clear.count) >= thresholds.clearShare * Double(frames.count) { continue }
                verdict.segments[segment.id] = .broadcast
            }
            // A "voice" that is only ever music (a diarizer's cluster for a song) is music; anyone else, a broadcast.
            let kinds = voice.segments.compactMap { verdict.segments[$0.id] }
            verdict.speakers[label] = !kinds.isEmpty && kinds.allSatisfy { $0 == .music } ? .music : .broadcast
        }
        return verdict
    }

    /// Text a recognizer writes for sound rather than speech: music notes, "[Music]", "(upbeat music)",
    /// "[Applause]", or lyrics between ♪. Laughter and coughs are left alone: they're part of a conversation.
    public static func isSoundTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let notes: Set<Character> = ["♪", "♫", "♬", "♩", "🎵", "🎶"]
        if trimmed.allSatisfy({ notes.contains($0) || $0.isWhitespace || $0.isPunctuation }) { return trimmed.contains(where: notes.contains) }
        if let first = trimmed.first, let last = trimmed.last, notes.contains(first), notes.contains(last), trimmed.count > 1 { return true }
        let tags = trimmed.split { $0 == "[" || $0 == "]" || $0 == "(" || $0 == ")" || $0 == "*" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let bracketed = trimmed.first.map { "[(*".contains($0) } == true && trimmed.last.map { "])*".contains($0) } == true
        guard bracketed, !tags.isEmpty else { return false }
        let words = ["music", "song", "singing", "sings", "applause", "cheering", "jingle", "instrumental", "theme"]
        return tags.allSatisfy { tag in
            let lower = tag.lowercased()
            return words.contains { lower.contains($0) } && lower.split(separator: " ").count <= 4
        }
    }

    private static func soundTagKind(_ text: String) -> Kind {
        let lower = text.lowercased()
        return lower.contains("applause") || lower.contains("cheering") ? .broadcast : .music
    }
}

extension Meeting {
    /// Passages of each recording's latest transcript run that are background audio, with why, for
    /// fusion to leave out. Empty when the person chose to include background audio.
    public func backgroundSegmentKinds() -> [UUID: BackgroundAudio.Kind] {
        guard includesBackgroundAudio != true else { return [:] }
        var result: [UUID: BackgroundAudio.Kind] = [:]
        for verdict in backgroundVerdicts().values { result.merge(verdict.segments) { first, _ in first } }
        return result
    }

    /// The verdict for each recording's latest transcript run, by track. Speakers the person named
    /// are never judged.
    public func backgroundVerdicts() -> [UUID: BackgroundAudio.Verdict] {
        let named = Set(revisions.compactMap { $0.field.hasPrefix("speaker:") ? String($0.field.dropFirst(8)) : nil })
        let latest = Dictionary(grouping: transcripts, by: \.trackID).compactMapValues { $0.max { $0.createdAt < $1.createdAt } }
        var result: [UUID: BackgroundAudio.Verdict] = [:]
        for (trackID, transcript) in latest {
            let analysis = tracks.first { $0.id == trackID }?.backgroundAudio
            let verdict = BackgroundAudio.judge(transcript.segments, analysis: analysis, protectedSpeakers: named)
            if !verdict.isEmpty { result[trackID] = verdict }
        }
        return result
    }

    /// Speakers heard only in passages left out as background audio (a TV's presenter): no one in
    /// the conversation, so lists of the people in it leave them out.
    public var backgroundOnlySpeakerIDs: Set<String> {
        let background = Set((backgroundPassages ?? []).compactMap(\.speakerID))
        guard !background.isEmpty else { return [] }
        return background.subtracting(unifiedTranscript.compactMap(\.speakerID))
    }

    /// How long the passages left out as background audio run, in seconds.
    public var backgroundDuration: TimeInterval {
        (backgroundPassages ?? []).reduce(0) { $0 + max(0, $1.end - $1.start) }
    }
}
