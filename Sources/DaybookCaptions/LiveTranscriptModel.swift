import CoreGraphics
import Foundation
import Observation

/// What the live transcript view reads while it's open: every line the recording's captions have so far, in
/// time order (not just the newest few the surfaces keep), the one still being heard replaced in place, and
/// whether the view follows the newest words.
///
/// Nothing runs while the view is closed: the model is made when it opens and reads (`run`) only while it's
/// shown, and the recording, its captioners and what's saved never know it's there. A recording's captions
/// are kept whole off the main actor for saving (`LiveCaptionMixer`); this reads that list again only when it
/// changed, a few times a second at most. On the main actor it keeps at most `maxLines` of the newest lines,
/// so a recording of many hours never grows the screen's copy without bound (`LiveCaptionSegment` is about
/// 200 bytes of text and fields: the default is a couple of MB). The saved captions are untouched by it.
@MainActor
@Observable
public final class LiveTranscriptModel {
    /// Where the lines come from: a recording's captions, or a recorder's Listen Live.
    public struct Source {
        /// What the lines were at: grows with every change, nil when there's no such count (each read is then compared).
        public var version: (@MainActor () -> Int)?
        /// Every line now, and other devices' names by source.
        public var read: @MainActor () async -> Reading

        public init(version: (@MainActor () -> Int)? = nil, read: @escaping @MainActor () async -> Reading) {
            self.version = version
            self.read = read
        }
    }

    public struct Reading: Sendable {
        public var lines: [LiveCaptionSegment]
        public var names: [String: String]

        public init(lines: [LiveCaptionSegment], names: [String: String] = [:]) {
            self.lines = lines
            self.names = names
        }
    }

    /// The most lines kept for the view: the newest.
    public static let maxLines = 10_000
    /// How close to the newest words (points of scroll) still counts as being at them: a bounce at the end
    /// is not leaving them.
    public static let latestSlack: CGFloat = 8

    /// Every line, oldest first, with words to read.
    public private(set) var lines: [LiveCaptionSegment] = []
    /// Other devices' names by source (raw value), for their lines' labels.
    public private(set) var names: [String: String] = [:]
    /// Grows with every change to `lines`, so the view can follow the newest words.
    public private(set) var revision = 0
    /// Whether the view stays at the newest words as they arrive: until the person scrolls up to read.
    public private(set) var isFollowing = true
    /// Grows with every request to go to the newest words (`jumpToLatest`).
    public private(set) var jumps = 0

    @ObservationIgnored private let maxLines: Int
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var layout: [CGFloat]?
    @ObservationIgnored private var distance: CGFloat = 0

    public init(maxLines: Int = LiveTranscriptModel.maxLines, interval: Duration = .milliseconds(250)) {
        self.maxLines = max(1, maxLines)
        self.interval = interval
    }

    // MARK: Reading

    /// Reads `source` until the task is cancelled (the view closing): at once, then whenever its version moved.
    public func run(_ source: Source) async {
        var seen: Int?
        while !Task.isCancelled {
            let version = source.version?()
            if version == nil || version != seen {
                seen = version
                apply(await source.read())
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Takes a reading. A reading with no lines after there were some is the recording ending (its captions
    /// are saved and cleared): what was captured stays.
    public func apply(_ reading: Reading) {
        var next = reading.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if next.isEmpty, !lines.isEmpty { return }
        if next.count > maxLines { next.removeFirst(next.count - maxLines) }
        if names != reading.names { names = reading.names }
        guard next != lines else { return }
        lines = next
        revision += 1
    }

    // MARK: Following

    /// The scroll view moved or resized: how far its bottom edge is from the content's (`distance`) in a
    /// scroll view of this `content` and `container` size. Reaching the newest words follows them again; moving away
    /// from them while nothing resized, which only a person scrolling does, stops following. Content growing
    /// as words arrive moves the edge away too, and is not the person.
    public func scrolled(distanceFromLatest distance: CGFloat, content: CGSize, container: CGSize) {
        let size = [content.height, container.height]
        let resized = layout != size
        layout = size
        defer { self.distance = distance }
        if distance <= Self.latestSlack {
            if !isFollowing { isFollowing = true }
        } else if !resized, distance > self.distance + 1, isFollowing {
            isFollowing = false
        }
    }

    /// Go to the newest words and follow them again.
    public func jumpToLatest() {
        isFollowing = true
        jumps += 1
    }
}

extension LiveCaptionSession {
    /// The live transcript's source: every line of this recording's captions, read off the main actor when
    /// they changed.
    public var transcriptSource: LiveTranscriptModel.Source {
        LiveTranscriptModel.Source(version: { [weak self] in self?.version ?? 0 }, read: { [weak self] in
            guard let self else { return LiveTranscriptModel.Reading(lines: []) }
            let lines = await self.lines()
            return LiveTranscriptModel.Reading(lines: lines, names: self.sourceNames)
        })
    }
}
