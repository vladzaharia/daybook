import Foundation

// Handwriting grouped into passages by time and place, without PencilKit: the UI turns a drawing's strokes into
// `NotebookStroke`s, and everything here is a pure function of those. A passage is what gets read together, anchored to
// the recording, and told apart as writing or a sketch.

/// A stroke as Core sees it.
public struct NotebookStroke: Equatable, Sendable {
    public var key: String
    /// The stroke's bounds in page points.
    public var x: Double, y: Double, width: Double, height: Double
    /// When it began, and when it ended (its start plus its last point's time offset).
    public var start: Date
    public var end: Date

    public init(key: String, x: Double, y: Double, width: Double, height: Double, start: Date, end: Date) {
        self.key = key; self.x = x; self.y = y; self.width = width; self.height = height; self.start = start; self.end = end
    }

    /// "<ms since reference date>-<point count>-<first x rounded>-<first y rounded>". Stroke identity on every device and
    /// OS version: `PKStroke.id` is iOS and macOS 27 only. The first point is the path's, before the stroke's transform,
    /// so a stroke the lasso moved keeps its key.
    public static func key(began: Date, pointCount: Int, firstX: Double, firstY: Double) -> String {
        func whole(_ value: Double) -> Int { value.isFinite ? Int(max(-1e9, min(1e9, value.rounded()))) : 0 }
        let milliseconds = began.timeIntervalSinceReferenceDate * 1000
        return "\(milliseconds.isFinite ? Int(max(-1e15, min(1e15, milliseconds.rounded()))) : 0)-\(pointCount)-\(whole(firstX))-\(whole(firstY))"
    }

    /// Keys in drawing order made unique: the second of two equal keys (a lasso copy) gets "#2", the third "#3".
    public static func uniqued(_ keys: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return keys.map { key in
            let count = seen[key, default: 0] + 1
            seen[key] = count
            return count == 1 ? key : "\(key)#\(count)"
        }
    }

    fileprivate var right: Double { x + width }
    fileprivate var bottom: Double { y + height }
}

public enum PassageGrouping {
    /// Stored in `PageReading.settings.parameters["grouping"]`; a page read by another version is read again.
    public static let version = 1

    public struct Rules: Equatable, Sendable {
        /// A gap this short always continues the passage.
        public var pause: TimeInterval = 2.5
        /// A gap up to this continues it when the stroke is near it.
        public var nearPause: TimeInterval = 15
        /// Near: the stroke's bounds meet the passage's bounds grown by this many line heights across and down or up.
        public var nearAcross: Double = 2
        public var nearLines: Double = 1.5
        /// Line height: the median height of the passage's strokes, kept within this range (page points).
        public var lineHeight: ClosedRange<Double> = 18...60
        /// A later group of at most this many strokes, at least this much of whose box lies in an earlier passage's
        /// box, joins that passage (an underline, a word put back in).
        public var revisitStrokes: Int = 6
        public var revisitOverlap: Double = 0.5
        public init() {}
    }

    public struct Group: Equatable, Sendable {
        /// By start, then key.
        public var strokes: [NotebookStroke]
        /// `NotebookPassage.id(page:firstStroke:)` of the earliest stroke.
        public var id: UUID
        public var digest: String
        public var x: Double, y: Double, width: Double, height: Double
        public var start: Date, end: Date

        public init(strokes: [NotebookStroke], id: UUID, digest: String, x: Double, y: Double, width: Double, height: Double, start: Date, end: Date) {
            self.strokes = strokes; self.id = id; self.digest = digest
            self.x = x; self.y = y; self.width = width; self.height = height; self.start = start; self.end = end
        }
    }

    /// 1. Sort by start, then key. 2. Walk: the gap is the stroke's start less the latest end in the group before it; the
    /// stroke joins when the gap is at most `pause`, or at most `nearPause` and it is near, and otherwise starts a group.
    /// 3. Revisit pass, earliest target first. 4. Groups by first start. The same strokes in any input order give the
    /// same groups.
    public static func group(_ strokes: [NotebookStroke], page: UUID, rules: Rules = .init()) -> [Group] {
        var groups: [[NotebookStroke]] = []
        for stroke in strokes.sorted(by: ordered) {
            if let current = groups.last, joins(stroke, current, rules) {
                groups[groups.count - 1].append(stroke)
            } else {
                groups.append([stroke])
            }
        }
        // A short, late group lying inside an earlier one belongs to it.
        var index = 0
        while index < groups.count {
            var later = index + 1
            while later < groups.count {
                if groups[later].count <= rules.revisitStrokes,
                   overlap(of: bounds(of: groups[later]), within: bounds(of: groups[index])) >= rules.revisitOverlap {
                    groups[index] += groups.remove(at: later)
                } else {
                    later += 1
                }
            }
            index += 1
        }
        return groups.map { members in
            let sorted = members.sorted(by: ordered)
            let box = bounds(of: sorted)
            return Group(strokes: sorted, id: NotebookPassage.id(page: page, firstStroke: sorted[0].key), digest: digest(of: sorted.map(\.key)),
                         x: box.x, y: box.y, width: box.width, height: box.height,
                         start: sorted.map(\.start).min() ?? sorted[0].start, end: sorted.map(\.end).max() ?? sorted[0].end)
        }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.strokes[0].key < $1.strokes[0].key }
    }

    /// First 16 hex of SHA-256 of the sorted keys joined by "\n".
    public static func digest(of keys: [String]) -> String {
        String(AudioDigest.sha256(data: Data(keys.sorted().joined(separator: "\n").utf8)).prefix(16))
    }

    // MARK: Walking

    /// Start, then key; then the rest, so equal keys with different shapes still sort the same whatever the input order.
    private static func ordered(_ a: NotebookStroke, _ b: NotebookStroke) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.key != b.key { return a.key < b.key }
        return (a.x, a.y, a.width, a.height, a.end) < (b.x, b.y, b.width, b.height, b.end)
    }

    private static func joins(_ stroke: NotebookStroke, _ group: [NotebookStroke], _ rules: Rules) -> Bool {
        let latest = group.map(\.end).max() ?? group[0].end
        let gap = stroke.start.timeIntervalSince(latest)
        if gap <= rules.pause { return true }
        guard gap <= rules.nearPause else { return false }
        let box = bounds(of: group)
        let line = min(max(median(group.map(\.height)), rules.lineHeight.lowerBound), rules.lineHeight.upperBound)
        let across = rules.nearAcross * line, vertical = rules.nearLines * line
        return stroke.x <= box.x + box.width + across && stroke.right >= box.x - across
            && stroke.y <= box.y + box.height + vertical && stroke.bottom >= box.y - vertical
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    // MARK: Boxes

    private typealias Box = (x: Double, y: Double, width: Double, height: Double)

    private static func bounds(of strokes: [NotebookStroke]) -> Box {
        let left = strokes.map(\.x).min() ?? 0, top = strokes.map(\.y).min() ?? 0
        let right = strokes.map(\.right).max() ?? 0, bottom = strokes.map(\.bottom).max() ?? 0
        return (left, top, right - left, bottom - top)
    }

    /// How much of `box` lies inside `target`, from 0 to 1. A box with no extent along an axis (a straight underline) is
    /// inside along that axis when its line is.
    private static func overlap(of box: Box, within target: Box) -> Double {
        func share(_ start: Double, _ length: Double, _ targetStart: Double, _ targetLength: Double) -> Double {
            let low = max(start, targetStart), high = min(start + length, targetStart + targetLength)
            if length > 0 { return max(0, high - low) / length }
            return start >= targetStart && start <= targetStart + targetLength ? 1 : 0
        }
        return share(box.x, box.width, target.x, target.width) * share(box.y, box.height, target.y, target.height)
    }
}

extension PassageKind {
    /// Writing needs words, mostly covering the strokes. No words (nil or blank) is a sketch. Coverage unknown is
    /// writing. Coverage at least `writingCoverage` is writing; less is a sketch.
    public static func decide(words: String?, textCoverage: Double?) -> PassageKind {
        guard words?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return .sketch }
        guard let textCoverage else { return .writing }
        return textCoverage >= writingCoverage ? .writing : .sketch
    }

    public static let writingCoverage = 0.6
}
