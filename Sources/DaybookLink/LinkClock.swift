import Foundation

/// The clocks a side reports times on. Injectable so tests can skew one side.
public protocol LinkClock: Sendable {
    /// The wall clock.
    func now() -> Date
    /// Seconds on a clock that only moves forward and keeps counting through sleep (`mach_continuous_time`, the clock
    /// the iPhone's first-sample anchor is kept on), unmoved by wall-clock steps. Drift is measured on it.
    func monotonic() -> TimeInterval
}

extension LinkClock {
    public func monotonic() -> TimeInterval { LinkMonotonicClock.seconds() }
}

public struct SystemLinkClock: LinkClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// This device's continuous clock, in seconds.
enum LinkMonotonicClock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    static func seconds() -> TimeInterval { Double(mach_continuous_time()) * scale }
}

/// A moment as one side read it: its wall clock and its continuous clock together.
struct LinkInstant: Sendable, Equatable {
    var date: Date
    var monotonic: TimeInterval

    init(date: Date, monotonic: TimeInterval) {
        self.date = date
        self.monotonic = monotonic
    }

    init(_ clock: any LinkClock) {
        date = clock.now()
        monotonic = clock.monotonic()
    }
}

/// One NTP-style exchange: the asker sends at t1 (its clock), the other side receives at t2 and
/// answers at t3 (its clock), and the answer arrives at t4 (the asker's clock).
///
/// `m1`…`m4` are the same moments on each side's continuous clock, when both sides sent them (an older build sends
/// none): what the drift is fitted to, since a wall clock can be stepped.
public struct LinkClockSample: Sendable, Equatable, Codable {
    public var t1: Date
    public var t2: Date
    public var t3: Date
    public var t4: Date
    public var m1: TimeInterval?
    public var m2: TimeInterval?
    public var m3: TimeInterval?
    public var m4: TimeInterval?

    public init(t1: Date, t2: Date, t3: Date, t4: Date,
                m1: TimeInterval? = nil, m2: TimeInterval? = nil, m3: TimeInterval? = nil, m4: TimeInterval? = nil) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
        self.m1 = m1
        self.m2 = m2
        self.m3 = m3
        self.m4 = m4
    }

    /// (other clock − own clock), assuming the trip took as long each way.
    public var offset: TimeInterval {
        ((t2.timeIntervalSince(t1)) + (t3.timeIntervalSince(t4))) / 2
    }

    /// Time on the wire, excluding the time the other side held the request.
    public var roundTrip: TimeInterval {
        max(0, t4.timeIntervalSince(t1) - t3.timeIntervalSince(t2))
    }

    /// The same exchange on the continuous clocks, when both sides stamped it: when it happened on this side's clock
    /// (the midpoint), (other continuous clock − own), and the round trip.
    var monotonicReading: LinkMonotonicReading? {
        guard let m1, let m2, let m3, let m4, m4 >= m1, m3 >= m2 else { return nil }
        return LinkMonotonicReading(at: (m1 + m4) / 2, offset: ((m2 - m1) + (m3 - m4)) / 2, roundTrip: max(0, (m4 - m1) - (m3 - m2)))
    }
}

/// One exchange on the continuous clocks.
struct LinkMonotonicReading: Sendable, Equatable {
    /// When, on this side's continuous clock.
    var at: TimeInterval
    /// (other continuous clock − own).
    var offset: TimeInterval
    var roundTrip: TimeInterval
}

/// The best current estimate of another device's clock relative to this one's.
///
/// For multipoint alignment: a time `t` on the peer's clock is `t − offset` on this device's
/// clock. The true offset is within `offset ± uncertainty` unless the network delay was lopsided
/// by more than the round trip, which loopback and a quiet Wi-Fi network rarely are.
public struct LinkClockEstimate: Sendable, Equatable, Codable {
    /// (peer's clock − this device's clock), in seconds.
    public var offset: TimeInterval
    /// Round trip of the sample the estimate rests on.
    public var roundTrip: TimeInterval
    /// Half that round trip: the most a lopsided trip can move the estimate.
    public var uncertainty: TimeInterval { roundTrip / 2 }
    public var sampleCount: Int
    /// When it was measured, on this device's clock.
    public var measuredAt: Date
    /// How much faster the peer's clock runs than this one's (peer seconds per second here, minus 1; 50 ppm is 5e-5),
    /// fitted over the session's continuous-clock samples once they span `LinkClockFilter.minimumDriftSpan`. Nil
    /// until then, or with a peer that doesn't stamp its continuous clock (an older build).
    public var drift: Double?
    /// How long the samples the drift rests on span, in seconds.
    public var driftSpan: TimeInterval?
    /// (peer's continuous clock − this device's), at `monotonicAt` on this device's continuous clock; nil without
    /// continuous-clock samples.
    public var monotonicOffset: TimeInterval?
    public var monotonicAt: TimeInterval?

    public init(offset: TimeInterval, roundTrip: TimeInterval, sampleCount: Int, measuredAt: Date, drift: Double? = nil,
                driftSpan: TimeInterval? = nil, monotonicOffset: TimeInterval? = nil, monotonicAt: TimeInterval? = nil) {
        self.offset = offset
        self.roundTrip = roundTrip
        self.sampleCount = sampleCount
        self.measuredAt = measuredAt
        self.drift = drift
        self.driftSpan = driftSpan
        self.monotonicOffset = monotonicOffset
        self.monotonicAt = monotonicAt
    }

    /// A time on the peer's clock, on this device's clock.
    public func localDate(fromPeer date: Date) -> Date { date.addingTimeInterval(-offset) }

    /// A time on this device's clock, on the peer's clock.
    public func peerDate(fromLocal date: Date) -> Date { date.addingTimeInterval(offset) }
}

/// NTP's clock filter, simplified: of the most recent samples, trust the one with the shortest
/// round trip, because queueing delay is what makes trips lopsided.
///
/// With continuous-clock stamps it also fits the drift between the two clocks over the whole session (least squares
/// over the samples whose round trip is near the shortest), and moves the chosen sample's offset on to the latest
/// sample by it. A wall clock stepped on either side (the gap between the wall and continuous offsets jumps) starts the
/// offset's window over, so samples from before the step don't outvote the clock as it is now; the drift, fitted on
/// the continuous clocks, isn't touched by it.
public struct LinkClockFilter: Sendable {
    public private(set) var samples: [LinkClockSample] = []
    public let capacity: Int
    /// Samples older than this are dropped (clocks drift and networks change).
    public let maximumAge: TimeInterval
    /// The shortest span of continuous-clock samples a drift is fitted over.
    public let minimumDriftSpan: TimeInterval
    private var total = 0
    /// The session's continuous-clock readings, for the drift: at most `driftCapacity`, keeping the shortest trips.
    private var readings: [LinkMonotonicReading] = []
    static let driftCapacity = 256
    /// A jump in (wall offset − continuous offset) bigger than this, beyond what the two round trips allow, is a step.
    static let stepThreshold: TimeInterval = 0.05

    public init(capacity: Int = 8, maximumAge: TimeInterval = 15 * 60, minimumDriftSpan: TimeInterval = 60) {
        self.capacity = max(1, capacity)
        self.maximumAge = maximumAge
        self.minimumDriftSpan = max(0, minimumDriftSpan)
    }

    public mutating func add(_ sample: LinkClockSample) {
        guard sample.t4 >= sample.t1, sample.t3 >= sample.t2 else { return }
        if let reading = sample.monotonicReading {
            // A wall clock was stepped since these samples: they measured another offset.
            let gap = sample.offset - reading.offset
            samples.removeAll { earlier in
                guard let before = earlier.monotonicReading else { return false }
                return abs((earlier.offset - before.offset) - gap) > Self.stepThreshold + earlier.roundTrip + sample.roundTrip
            }
            readings.append(reading)
            // Past capacity, the longest trip goes (never one of the newest few, so the span keeps growing).
            if readings.count > Self.driftCapacity,
               let worst = readings.indices.dropLast(8).max(by: { readings[$0].roundTrip < readings[$1].roundTrip }) {
                readings.remove(at: worst)
            }
        }
        samples.append(sample)
        total += 1
        samples.removeAll { sample.t4.timeIntervalSince($0.t4) > maximumAge }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// The drift fitted so far (peer seconds per second here, minus 1), with the span it rests on.
    public var drift: (rate: Double, span: TimeInterval)? {
        guard let shortest = readings.map(\.roundTrip).min() else { return nil }
        // Only the trips near the shortest: a queued one is lopsided by up to its length.
        let limit = 2 * shortest + 0.002
        let used = readings.filter { $0.roundTrip <= limit }
        guard used.count >= 3, let first = used.map(\.at).min(), let last = used.map(\.at).max(),
              last - first >= max(minimumDriftSpan, 0.001) else { return nil }
        let n = Double(used.count)
        let meanX = used.reduce(0) { $0 + $1.at } / n, meanY = used.reduce(0) { $0 + $1.offset } / n
        var sxx = 0.0, sxy = 0.0
        for reading in used {
            sxx += (reading.at - meanX) * (reading.at - meanX)
            sxy += (reading.at - meanX) * (reading.offset - meanY)
        }
        guard sxx > 0 else { return nil }
        return (sxy / sxx, last - first)
    }

    public var estimate: LinkClockEstimate? {
        guard let best = samples.min(by: { $0.roundTrip < $1.roundTrip }), let latest = samples.last else { return nil }
        let fitted = drift
        let bestReading = best.monotonicReading, latestReading = latest.monotonicReading
        var offset = best.offset
        // The shortest trip may be minutes old: its offset, moved on to the latest sample by the drift.
        if let fitted {
            let elapsed: TimeInterval
            if let bestReading, let latestReading { elapsed = latestReading.at - bestReading.at }
            else { elapsed = latest.t4.timeIntervalSince(best.t4) }
            offset += fitted.rate * elapsed
        }
        var estimate = LinkClockEstimate(offset: offset, roundTrip: best.roundTrip, sampleCount: total, measuredAt: latest.t4,
                                         drift: fitted?.rate, driftSpan: fitted?.span)
        if let bestReading, let latestReading {
            estimate.monotonicAt = latestReading.at
            estimate.monotonicOffset = bestReading.offset + (fitted?.rate ?? 0) * (latestReading.at - bestReading.at)
        }
        return estimate
    }
}
