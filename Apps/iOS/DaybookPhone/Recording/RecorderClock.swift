import AVFoundation
import Darwin
import Foundation

/// The clocks a recording is placed on. Injectable so tests drive time instead of waiting.
protocol RecorderClock: Sendable {
    /// Seconds on the host clock that stamps audio buffers (`mach_absolute_time`). It stops while
    /// the device sleeps, so it alone can't measure a long interruption.
    func hostTime() -> TimeInterval
    /// Seconds on a clock that keeps counting through sleep (`mach_continuous_time`). The
    /// conversation's timeline is measured on this clock.
    func continuousTime() -> TimeInterval
    func now() -> Date
}

extension RecorderClock {
    /// Where a buffer's host timestamp falls on the continuous clock. The two clocks differ only by
    /// time spent asleep, which doesn't change while audio is running.
    func continuousTime(forHostTime host: TimeInterval) -> TimeInterval {
        continuousTime() - (hostTime() - host)
    }

    /// Where a buffer's host timestamp falls on the wall clock.
    func date(forHostTime host: TimeInterval) -> Date {
        now().addingTimeInterval(host - hostTime())
    }
}

struct SystemRecorderClock: RecorderClock {
    func hostTime() -> TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
    func continuousTime() -> TimeInterval { AVAudioTime.seconds(forHostTime: mach_continuous_time()) }
    func now() -> Date { Date() }
}

/// A clock that moves only when told to, for tests and scripted demos. Time is kept in whole
/// nanoseconds so a thousand 0.1-second steps add up to exactly 100 seconds.
final class ManualRecorderClock: RecorderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var host: Int64
    private var asleep: Int64 = 0
    private let start: Date
    private var wall: Int64 = 0

    init(hostTime: TimeInterval = 1_000, date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.host = Self.nanoseconds(hostTime)
        self.start = date
    }

    func hostTime() -> TimeInterval { lock.withLock { Self.seconds(host) } }
    func continuousTime() -> TimeInterval { lock.withLock { Self.seconds(host + asleep) } }
    func now() -> Date { lock.withLock { start.addingTimeInterval(Self.seconds(wall)) } }

    /// Time passes with the device awake.
    func advance(_ seconds: TimeInterval) {
        let step = Self.nanoseconds(seconds)
        lock.withLock { host += step; wall += step }
    }

    /// Time passes with the device asleep: the host clock stands still, the others move.
    func sleep(_ seconds: TimeInterval) {
        let step = Self.nanoseconds(seconds)
        lock.withLock { asleep += step; wall += step }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1_000_000_000).rounded()) }
    private static func seconds(_ nanoseconds: Int64) -> TimeInterval { Double(nanoseconds) / 1_000_000_000 }
}
