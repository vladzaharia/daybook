import Foundation

/// The wall clock a side reports times on. Injectable so tests can skew one side.
public protocol LinkClock: Sendable {
    func now() -> Date
}

public struct SystemLinkClock: LinkClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// One NTP-style exchange: the asker sends at t1 (its clock), the other side receives at t2 and
/// answers at t3 (its clock), and the answer arrives at t4 (the asker's clock).
public struct LinkClockSample: Sendable, Equatable, Codable {
    public var t1: Date
    public var t2: Date
    public var t3: Date
    public var t4: Date

    public init(t1: Date, t2: Date, t3: Date, t4: Date) {
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
        self.t4 = t4
    }

    /// (other clock − own clock), assuming the trip took as long each way.
    public var offset: TimeInterval {
        ((t2.timeIntervalSince(t1)) + (t3.timeIntervalSince(t4))) / 2
    }

    /// Time on the wire, excluding the time the other side held the request.
    public var roundTrip: TimeInterval {
        max(0, t4.timeIntervalSince(t1) - t3.timeIntervalSince(t2))
    }
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

    public init(offset: TimeInterval, roundTrip: TimeInterval, sampleCount: Int, measuredAt: Date) {
        self.offset = offset
        self.roundTrip = roundTrip
        self.sampleCount = sampleCount
        self.measuredAt = measuredAt
    }

    /// A time on the peer's clock, on this device's clock.
    public func localDate(fromPeer date: Date) -> Date { date.addingTimeInterval(-offset) }

    /// A time on this device's clock, on the peer's clock.
    public func peerDate(fromLocal date: Date) -> Date { date.addingTimeInterval(offset) }
}

/// NTP's clock filter, simplified: of the most recent samples, trust the one with the shortest
/// round trip, because queueing delay is what makes trips lopsided.
public struct LinkClockFilter: Sendable {
    public private(set) var samples: [LinkClockSample] = []
    public let capacity: Int
    /// Samples older than this are dropped (clocks drift and networks change).
    public let maximumAge: TimeInterval
    private var total = 0

    public init(capacity: Int = 8, maximumAge: TimeInterval = 15 * 60) {
        self.capacity = max(1, capacity)
        self.maximumAge = maximumAge
    }

    public mutating func add(_ sample: LinkClockSample) {
        guard sample.t4 >= sample.t1, sample.t3 >= sample.t2 else { return }
        samples.append(sample)
        total += 1
        samples.removeAll { sample.t4.timeIntervalSince($0.t4) > maximumAge }
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public var estimate: LinkClockEstimate? {
        guard let best = samples.min(by: { $0.roundTrip < $1.roundTrip }), let latest = samples.last else { return nil }
        return LinkClockEstimate(offset: best.offset, roundTrip: best.roundTrip, sampleCount: total, measuredAt: latest.t4)
    }
}
