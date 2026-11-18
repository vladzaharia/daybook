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

    public init(at: Date, elapsed: TimeInterval, running: Bool) {
        self.at = at; self.elapsed = elapsed; self.running = running
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
    /// the oldest half is thinned to every other sample (every change between running and paused stays).
    public static func appending(_ sample: RecordingClockSample, to samples: [RecordingClockSample]) -> [RecordingClockSample] {
        if let last = samples.last, sample.running == last.running, sample.at.timeIntervalSince(last.at) < interval { return samples }
        var result = samples + [sample]
        guard result.count > capacity else { return result }
        let older = result.count / 2
        var thinned: [RecordingClockSample] = []
        for index in 0..<older where index % 2 == 0 || result[index].running != result[index - 1].running {
            thinned.append(result[index])
        }
        result = thinned + result[older...]
        return result.count > capacity ? Array(result.suffix(capacity)) : result
    }
}
