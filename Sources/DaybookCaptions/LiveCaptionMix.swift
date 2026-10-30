import Foundation

/// Captions another device makes of the same recording: a recorder recording along (its live audio,
/// captioned here) or a paired iPhone (its captions, sent over the local link). Its times are its
/// own; `offset` moves them onto this recording's timeline.
public struct DeviceCaptionFeed: Equatable, Sendable {
    public var source: LiveCaptionSource
    /// What its captions are labelled with where no person was recognized: "Soundcore", "iPhone".
    public var name: String
    /// Seconds to add to its times to place them on this recording's timeline.
    public var offset: TimeInterval
    public var segments: [LiveCaptionSegment]

    public init(source: LiveCaptionSource, name: String, offset: TimeInterval, segments: [LiveCaptionSegment] = []) {
        self.source = source; self.name = name; self.offset = offset; self.segments = segments
    }

    /// Takes lines that changed, by ID (a phone sends only those), keeping the rest; in time order.
    public mutating func update(_ lines: [LiveCaptionSegment]) {
        var byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for line in lines { byID[line.id] = line }
        segments = byID.values.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }
}

/// One recording's captions from every source that heard it, as one list. Several devices in one
/// room hear the same speech: a line another device captioned that repeats one already shown nearby
/// is left out, so the room reads once. This device's own lines come first, then each other device's
/// in turn, so a line is kept from the first source that captioned it.
public enum LiveCaptionMix {
    /// How far apart two devices' captions of the same words may be: their clocks are matched only
    /// roughly, and each recognizer lags its audio by its own amount.
    public static let window: TimeInterval = 4
    /// The share of a line's words, in order, that must already be shown nearby for it to be left out.
    public static let threshold = 0.6

    /// `own` (in time order) with the feeds' lines added: each tagged with its feed's source and moved
    /// onto this recording's timeline, without lines from before this recording began or lines that
    /// repeat what's already there; all in time order.
    public static func adding(_ feeds: [DeviceCaptionFeed], to own: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        var shown = own
        for feed in feeds.sorted(by: { $0.source.rawValue < $1.source.rawValue }) {
            var added: [LiveCaptionSegment] = []
            let index = NearbyLines(shown)
            for line in feed.segments where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var moved = line
                moved.start += feed.offset
                moved.end += feed.offset
                moved.source = feed.source
                guard moved.end > 0 else { continue }
                moved.start = max(0, moved.start)
                if repeats(moved, among: index.near(moved)) { continue }
                added.append(moved)
            }
            shown = merged(shown, added)
        }
        return shown
    }

    /// Whether most of `line`'s words, in order, are in the lines near it.
    static func repeats(_ line: LiveCaptionSegment, among nearby: [LiveCaptionSegment]) -> Bool {
        let spoken = words(line.text)
        guard !spoken.isEmpty, !nearby.isEmpty else { return false }
        return Double(sharedRun(spoken, nearby.flatMap { words($0.text) })) / Double(spoken.count) >= threshold
    }

    /// Two lists in time order, as one.
    static func merged(_ a: [LiveCaptionSegment], _ b: [LiveCaptionSegment]) -> [LiveCaptionSegment] {
        guard !b.isEmpty else { return a }
        var result: [LiveCaptionSegment] = []
        result.reserveCapacity(a.count + b.count)
        var first = a[...], second = b.sorted { $0.start < $1.start }[...]
        while let x = first.first, let y = second.first {
            if x.start <= y.start { result.append(x); first = first.dropFirst() } else { result.append(y); second = second.dropFirst() }
        }
        return result + first + second
    }

    /// Lowercased words without punctuation, accents, or apostrophes ("Let’s" and "lets" match).
    public static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The longest run of `a`'s words that appears in `b` in the same order (gaps allowed).
    public static func sharedRun(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for word in a {
            for index in 1...b.count {
                current[index] = word == b[index - 1] ? previous[index - 1] + 1 : max(previous[index], current[index - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Lines in time order, found by time: an hour of captions isn't searched for every line.
    struct NearbyLines {
        let lines: [LiveCaptionSegment]
        /// The longest line, so a search by start time doesn't miss one that began well before.
        let longest: TimeInterval

        init(_ lines: [LiveCaptionSegment]) {
            self.lines = lines
            longest = lines.map { $0.end - $0.start }.max() ?? 0
        }

        func near(_ line: LiveCaptionSegment) -> [LiveCaptionSegment] {
            let from = line.start - LiveCaptionMix.window - longest
            var low = 0, high = lines.count
            while low < high {
                let middle = (low + high) / 2
                if lines[middle].start < from { low = middle + 1 } else { high = middle }
            }
            var found: [LiveCaptionSegment] = []
            var index = low
            while index < lines.count, lines[index].start <= line.end + LiveCaptionMix.window {
                let other = lines[index]
                if other.end >= line.start - LiveCaptionMix.window { found.append(other) }
                index += 1
            }
            return found
        }
    }
}
