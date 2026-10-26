import Foundation

/// A Soundcore's clock against true time. Its recording IDs are Unix start times by its own clock,
/// which nobody checks it keeps: Daybook measures it when it starts a recording (the new recording's
/// ID against when the command was sent) and dates that recorder's recordings by it.
public struct SoundcoreClock: Codable, Equatable, Sendable {
    /// The recorder it was measured on.
    public var serial: String
    /// The recorder's clock minus true time, in seconds: positive when it runs ahead.
    public var offset: TimeInterval
    public var measuredAt: Date

    /// Recording IDs are whole seconds and the recorder starts a moment after the command arrives,
    /// so a smaller difference is the measurement, not the clock.
    public static let resolution: TimeInterval = 2
    /// Off by more than this, Device Details says so.
    public static let flagThreshold: TimeInterval = 60

    public init(serial: String, offset: TimeInterval, measuredAt: Date) {
        self.serial = serial
        self.offset = offset
        self.measuredAt = measuredAt
    }

    /// From a Start the recorder confirmed: the new recording's ID is when it started by its clock.
    public init(serial: String, recordingID: UInt32, sentAt: Date) {
        self.init(serial: serial, offset: Double(recordingID) - sentAt.timeIntervalSince1970, measuredAt: sentAt)
    }

    public var isFlagged: Bool { abs(offset) > Self.flagThreshold }

    /// Seconds to take off a recording ID's time to get its start on this device's clock.
    public var correction: TimeInterval { abs(offset) > Self.resolution ? offset : 0 }

    /// "In step", or "4 min ahead", "2 hr behind".
    public var summary: String {
        guard isFlagged else { return "In step" }
        let amount = Duration.seconds(abs(offset).rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return "\(amount) \(offset > 0 ? "ahead" : "behind")"
    }
}

/// Each recorder's measured clock by serial number, for whatever dates a recording from its identity
/// alone (the importer naming and dating a new conversation). The connections fill it from their
/// snapshots and measurements.
@MainActor
public enum SoundcoreClocks {
    private static var bySerial: [String: SoundcoreClock] = [:]

    public static func clock(serial: String?) -> SoundcoreClock? {
        serial.flatMap { bySerial[$0] }
    }

    public static func record(_ clock: SoundcoreClock) {
        bySerial[clock.serial] = clock
    }

    public static func forget(serial: String) {
        bySerial[serial] = nil
    }
}

extension SoundcoreRecording {
    /// When it started on this device's clock: its ID's time less the recorder's measured clock
    /// correction, when that's a plausible time.
    public func start(correction: TimeInterval) -> Date? {
        guard correction != 0 else { return date }
        let value = Date(timeIntervalSince1970: Double(id) - correction)
        return value.timeIntervalSince1970 >= 946_684_800 && value < Date().addingTimeInterval(31_536_000) ? value : nil
    }
}
