import DaybookCaptions
import Foundation

/// Live captions' echo rule. Through the speakers the microphone hears the call too, and echo
/// removal runs only after Stop (docs/capture.md), so the You captioner also captions the other
/// side, a moment after the Call captioner does. A You line counts as that echo when most of its
/// words appear, in order, in what Call heard around the same time; it's left out. With headphones
/// nothing is left out: a You line that repeats the call is then something you said.
enum CaptionEcho {
    /// How far apart a You line and the Call lines it repeats may be, in seconds of the recording.
    static let window: TimeInterval = 2
    /// The share of a You line's words, in order, that must be in the Call lines around it.
    static let threshold = 0.6

    /// You and Call interleaved by time and tagged with their source, without the You lines that
    /// only echo the call where the output can echo (`echoes(time)`: not headphones then).
    static func merge(you: [LiveCaptionSegment], call: [LiveCaptionSegment],
                      echoes: (TimeInterval) -> Bool,
                      isEcho: (LiveCaptionSegment) -> Bool) -> [LiveCaptionSegment] {
        let kept = you.filter { !(echoes($0.start) && isEcho($0)) }.map { tagged($0, .microphone) }
        let heard = call.map { tagged($0, .call) }
        // Both lists are in time order already; interleave them, Call first on a tie.
        var merged: [LiveCaptionSegment] = []
        merged.reserveCapacity(kept.count + heard.count)
        var mine = kept[...], theirs = heard[...]
        while let next = mine.first, let other = theirs.first {
            if other.start <= next.start { merged.append(other); theirs = theirs.dropFirst() } else { merged.append(next); mine = mine.dropFirst() }
        }
        merged.append(contentsOf: theirs)
        merged.append(contentsOf: mine)
        return merged
    }

    /// Whether a You line repeats what the Call captioner heard around it.
    static func isEcho(_ line: LiveCaptionSegment, of call: [LiveCaptionSegment]) -> Bool {
        let spoken = words(line.text)
        guard !spoken.isEmpty else { return false }
        let nearby = call.filter { $0.start <= line.end + window && $0.end >= line.start - window }
        guard !nearby.isEmpty else { return false }
        let heard = nearby.flatMap { words($0.text) }
        return Double(sharedRun(spoken, heard)) / Double(spoken.count) >= threshold
    }

    /// Lowercased words without punctuation, accents, or apostrophes ("Let’s" and "lets" match).
    static func words(_ text: String) -> [String] { LiveCaptionMix.words(text) }

    /// The longest run of `a`'s words that appears in `b` in the same order (gaps allowed).
    static func sharedRun(_ a: [String], _ b: [String]) -> Int { LiveCaptionMix.sharedRun(a, b) }

    private static func tagged(_ segment: LiveCaptionSegment, _ source: LiveCaptionSource) -> LiveCaptionSegment {
        var segment = segment
        segment.source = source
        return segment
    }
}
