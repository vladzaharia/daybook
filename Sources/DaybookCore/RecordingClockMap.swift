import Foundation

// The iPhone's recording seconds aren't wall-clock seconds since it started: a pause stops them. The notebook samples
// the recorder's clock as the person writes, and maps each passage's start through the samples to seconds into the
// recording (`NotebookPassage.time`).

/// The recorder's clock at one moment.
public struct RecordingClockSample: Codable, Equatable, Sendable {
    public var at: Date
    /// The recorder's `elapsedTime` at `at`.
    public var elapsed: TimeInterval
    /// Recording (not paused, not starting) at `at`.
    public var running: Bool
    /// Keys a newer Daybook wrote that this version doesn't know, written back as they came.
    public var unknownFields = UnknownFields()

    public init(at: Date, elapsed: TimeInterval, running: Bool) {
        self.at = at; self.elapsed = elapsed; self.running = running
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case at, elapsed, running
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        at = try values.decode(Date.self, forKey: .at)
        elapsed = try values.decode(TimeInterval.self, forKey: .elapsed)
        running = try values.decode(Bool.self, forKey: .running)
        unknownFields = try UnknownFields(from: decoder, known: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(at, forKey: .at)
        try values.encode(elapsed, forKey: .elapsed)
        try values.encode(running, forKey: .running)
        try unknownFields.encode(to: encoder)
    }
}

public enum RecordingClockMap {
    /// How far before a moment a sample still speaks for it.
    public static let reach: TimeInterval = 120
    /// How far after a moment a sample may stand in when none came before: a tool's begin callback can trail the stroke's
    /// creation date.
    public static let trailing: TimeInterval = 2
    /// The gap that makes a new sample worth keeping while nothing else changed.
    public static let interval: TimeInterval = 5
    public static let capacity = 4_000

    /// The recording time at `moment`: from the latest sample at or before it (or the earliest within `trailing` after
    /// it), `elapsed + (moment − at)` while running, `elapsed` while paused. Nil with no sample within `reach` before it.
    public static func elapsed(at moment: Date, samples: [RecordingClockSample], reach: TimeInterval = RecordingClockMap.reach) -> TimeInterval? {
        func time(_ sample: RecordingClockSample) -> TimeInterval? {
            let value = sample.running ? sample.elapsed + moment.timeIntervalSince(sample.at) : sample.elapsed
            return value.isFinite ? max(0, value) : nil
        }
        if let before = samples.filter({ $0.at <= moment }).max(by: { $0.at < $1.at }), moment.timeIntervalSince(before.at) <= reach {
            return time(before)
        }
        if let after = samples.filter({ $0.at > moment && $0.at.timeIntervalSince(moment) <= trailing }).min(by: { $0.at < $1.at }) {
            return time(after)
        }
        return nil
    }

    /// Adds a sample when the last is at least `interval` old or `running` changed, and keeps at most `capacity`: past that
    /// a quarter of them go, always the ones whose neighbours are closest, so the gaps stay about even across the whole
    /// recording (the first and last, and every change between running and paused, stay).
    public static func appending(_ sample: RecordingClockSample, to samples: [RecordingClockSample]) -> [RecordingClockSample] {
        if let last = samples.last, sample.running == last.running, sample.at.timeIntervalSince(last.at) < interval { return samples }
        var result = samples + [sample]
        guard result.count > capacity else { return result }
        func gap(_ index: Int) -> TimeInterval { result[index + 1].at.timeIntervalSince(result[index - 1].at) }
        var removable = (1..<(result.count - 1)).filter { result[$0].running == result[$0 - 1].running && result[$0].running == result[$0 + 1].running }
        removable.sort { gap($0) != gap($1) ? gap($0) < gap($1) : $0 < $1 }
        var dropped = Set<Int>()
        for index in removable where dropped.count < result.count - capacity * 3 / 4 {
            if !dropped.contains(index - 1) && !dropped.contains(index + 1) { dropped.insert(index) }
        }
        result = result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return result.count > capacity ? Array(result.suffix(capacity)) : result
    }
}
