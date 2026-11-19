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
    /// it), `elapsed + (moment − at)` while running, `elapsed` while paused. Nil with no sample before it, or none within `reach` before it and none after.
    public static func elapsed(at moment: Date, samples: [RecordingClockSample], reach: TimeInterval = RecordingClockMap.reach) -> TimeInterval? {
        func time(_ sample: RecordingClockSample) -> TimeInterval? {
            let value = sample.running ? sample.elapsed + moment.timeIntervalSince(sample.at) : sample.elapsed
            return value.isFinite ? max(0, value) : nil
        }
        // A moment between two samples is mapped from the earlier, however far: that's what a filed clock (`filed`), which keeps
        // one sample every few minutes, is for. Past the last sample, only within `reach`.
        if let before = samples.filter({ $0.at <= moment }).max(by: { $0.at < $1.at }),
           moment.timeIntervalSince(before.at) <= reach || samples.contains(where: { $0.at > moment }) {
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
        let result = samples + [sample]
        return result.count > capacity ? bounded(result, to: capacity * 3 / 4, atMost: capacity) : result
    }

    /// The most samples a recording's filed clock keeps (`filed`).
    public static let filedCapacity = 400
    /// The gap the filed clock keeps one anchor in while nothing changes.
    public static let filedAnchorInterval: TimeInterval = 300

    /// The samples a recording is filed with: the first and last, every one where `running` changes (and the one before it),
    /// and one anchor each `filedAnchorInterval` seconds, at most `filedCapacity`. The recorder's clock keeps counting through a
    /// pause and the audio holds the pause as silence, so between two changes the map is linear and nothing else is needed:
    /// a recording an hour long with no pause files a dozen samples, not the thousands the live clock kept. A moment inside a
    /// pause maps to where the pause began.
    public static func filed(_ samples: [RecordingClockSample]) -> [RecordingClockSample] {
        let sorted = samples.sorted { $0.at < $1.at }
        guard sorted.count > 2 else { return sorted }
        var kept: [RecordingClockSample] = []
        for (index, sample) in sorted.enumerated() {
            let changes = index == 0 || index == sorted.count - 1 || sample.running != sorted[index - 1].running || sample.running != sorted[index + 1].running
            if changes || sample.at.timeIntervalSince(kept.last?.at ?? sample.at) >= filedAnchorInterval { kept.append(sample) }
        }
        return kept.count > filedCapacity ? bounded(kept, to: filedCapacity * 3 / 4, atMost: filedCapacity) : kept
    }

    /// `samples` with the ones whose neighbours are closest taken out until at most `target` remain, never the first, the last,
    /// or one beside a change between running and paused.
    private static func bounded(_ samples: [RecordingClockSample], to target: Int, atMost capacity: Int) -> [RecordingClockSample] {
        var result = samples
        func gap(_ index: Int) -> TimeInterval { result[index + 1].at.timeIntervalSince(result[index - 1].at) }
        var removable = (1..<(result.count - 1)).filter { result[$0].running == result[$0 - 1].running && result[$0].running == result[$0 + 1].running }
        removable.sort { gap($0) != gap($1) ? gap($0) < gap($1) : $0 < $1 }
        var dropped = Set<Int>()
        for index in removable where dropped.count < result.count - target {
            if !dropped.contains(index - 1) && !dropped.contains(index + 1) { dropped.insert(index) }
        }
        result = result.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return result.count > capacity ? Array(result.suffix(capacity)) : result
    }
}
