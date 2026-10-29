import Foundation

// Live captions: tentative, on-device text made while audio is being captured (an iPhone recording,
// a Mac's microphone or call, a recorder's live listening). They show that the audio is being heard
// and give something to read until the real transcript arrives. They are never a transcript: not
// synced, not fused, not summarized, not used as evidence.

/// One stretch of captioned speech.
public struct LiveCaptionSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Seconds from the start of the recording.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Still being revised by the recognizer (volatile). Finalized segments are false.
    public var isTentative: Bool
    /// The source it was heard from, when one capture is captioned per source (a Mac's You and
    /// Call); nil for a single source. Optional, so captions saved without it still decode.
    public var source: LiveCaptionSource?
    /// Who said it, when a live speaker model told the voices apart; nil otherwise. Optional, so
    /// captions saved without it (and by earlier versions) still decode.
    public var speaker: LiveCaptionSpeaker?

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, text: String, isTentative: Bool,
                source: LiveCaptionSource? = nil, speaker: LiveCaptionSpeaker? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.isTentative = isTentative
        self.source = source; self.speaker = speaker
    }
}

/// Who said a caption, as a live speaker model heard it: the model's own label for one voice in this
/// capture ("S2", never a person) and, once that voice matched someone's voice profile, their name.
/// Tentative like the words: the Mac's speaker analysis decides who spoke in the transcript.
public struct LiveCaptionSpeaker: Codable, Hashable, Sendable {
    /// One voice within one capture ("S1", "S2"…). The same voice keeps it for the whole capture,
    /// unless the model loses track of it.
    public var slot: String
    /// The person whose voice profile it matched, when it did.
    public var name: String?
    /// That profile's identifier.
    public var profileID: String?

    public init(slot: String, name: String? = nil, profileID: String? = nil) {
        self.slot = slot; self.name = name; self.profileID = profileID
    }
}

/// Which of a capture's sources a caption was heard from. A string underneath, so captions with a
/// source added later still decode in earlier versions.
public struct LiveCaptionSource: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// This device's microphone: "You".
    public static let microphone = LiveCaptionSource(rawValue: "microphone")
    /// The call, or everything the device plays: "Call".
    public static let call = LiveCaptionSource(rawValue: "call")
}

/// The captions of one recording, as stored beside it on the device that made them.
public struct LiveCaptions: Codable, Equatable, Sendable {
    public var meetingID: UUID
    /// The track the captions were heard from, once filed.
    public var trackID: UUID?
    public var localeIdentifier: String
    public var segments: [LiveCaptionSegment]
    public var createdAt: Date
    public var updatedAt: Date

    public init(meetingID: UUID, trackID: UUID? = nil, localeIdentifier: String, segments: [LiveCaptionSegment] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.meetingID = meetingID; self.trackID = trackID; self.localeIdentifier = localeIdentifier
        self.segments = segments; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Where a captioner stands, in words a recording screen can show.
public enum LiveCaptionState: Equatable, Sendable {
    case off
    /// Not possible here: the reason, in a sentence ("Captions aren't available for Welsh.").
    case unavailable(String)
    case preparing
    /// The system is downloading the speech model for the language (fraction when known).
    case downloading(Double?)
    case listening
    /// The captioner stopped; the capture it listens to continues. The reason, for settings.
    case failed(String)
    /// Finished after the audio ended.
    case finished

    public var isActive: Bool {
        switch self {
        case .preparing, .downloading, .listening: return true
        default: return false
        }
    }
}

/// Builds the segment list from a recognizer's results: a tentative (volatile) result replaces the
/// tentative tail in place; a final result replaces it and stays.
public struct LiveCaptionAssembler: Equatable, Sendable {
    public private(set) var segments: [LiveCaptionSegment] = []

    public init(segments: [LiveCaptionSegment] = []) { self.segments = segments }

    /// Applies one result. Returns whether the segments changed.
    @discardableResult
    public mutating func apply(text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) -> Bool {
        let before = segments
        if let last = segments.last, last.isTentative { segments.removeLast() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            segments.append(LiveCaptionSegment(id: before.last.flatMap { $0.isTentative ? $0.id : nil } ?? UUID(),
                                               start: start, end: max(start, end), text: trimmed, isTentative: !isFinal))
        }
        return segments != before
    }

    /// The audio ended: what stands is kept as heard.
    public mutating func finalizeAll() {
        for index in segments.indices where segments[index].isTentative { segments[index].isTentative = false }
    }
}

/// Maps the analyzer's timeline (audio fed back to back) onto the source's (which may have gaps:
/// a paused recording, a recorder sending in bursts). Source times are seconds from an arbitrary
/// start; the origin is fixed when given, else the first buffer's time. Thread-safe.
public final class CaptionTimeMap: @unchecked Sendable {
    private struct Anchor { var analyzer: TimeInterval; var source: TimeInterval }
    private let lock = NSLock()
    private var anchors: [Anchor] = []
    private var origin: TimeInterval?
    private var nextSource: TimeInterval?
    private var fed: TimeInterval = 0
    /// A jump this large between where a buffer was expected and where it is marks a gap.
    public static let tolerance: TimeInterval = 0.25

    /// `origin`: the source time that is zero on the captions' timeline (a recording's start, in
    /// the buffers' own units). Nil makes it the first buffer fed, which comes later than the first
    /// appended when audio was dropped while the recognizer started.
    public init(origin: TimeInterval? = nil) { self.origin = origin }

    /// Notes a buffer about to be fed: its source time (nil continues from the last one) and length.
    public func feed(sourceTime: TimeInterval?, duration: TimeInterval) {
        lock.withLock {
            let time = sourceTime ?? nextSource ?? 0
            if origin == nil { origin = time }
            if nextSource.map({ abs(time - $0) > Self.tolerance }) ?? true {
                anchors.append(Anchor(analyzer: fed, source: time - (origin ?? time)))
            }
            fed += duration
            nextSource = time + duration
        }
    }

    /// Seconds from the first buffer, on the source's timeline.
    public func sourceTime(_ analyzerTime: TimeInterval) -> TimeInterval {
        lock.withLock {
            guard let anchor = anchors.last(where: { $0.analyzer <= analyzerTime + 0.001 }) ?? anchors.first else { return analyzerTime }
            return max(0, anchor.source + (analyzerTime - anchor.analyzer))
        }
    }
}
