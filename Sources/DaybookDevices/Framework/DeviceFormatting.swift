import DaybookCore
import Foundation

// Words and numbers for device surfaces, shared by every kind: lengths, storage as hours, battery,
// signal, dates, and stale values with their time.

/// How long a recording is: exact when the recorder reports its end, otherwise an estimate.
public enum RecordingLength: Hashable {
    case exact(TimeInterval)
    case estimated(TimeInterval)

    public var seconds: TimeInterval {
        switch self { case .exact(let value), .estimated(let value): return value }
    }

    public var isEstimate: Bool { if case .estimated = self { return true } else { return false } }

    /// "48 min" or "About 22 min".
    public var label: String {
        guard seconds > 0 else { return "Length unknown" }
        return isEstimate ? "About " + DurationLabel.format(seconds) : DurationLabel.format(seconds)
    }

    /// The same, inside a sentence: "about 22 min".
    public var inlineLabel: String {
        guard seconds > 0 else { return "length unknown" }
        return isEstimate ? "about " + DurationLabel.format(seconds) : DurationLabel.format(seconds)
    }
}

/// Storage as hours of recording left, because that's what matters before a meeting.
public enum StorageFormat {
    /// Below this, the storage figure turns orange and Daybook warns once.
    public static let lowHours: Double = 12

    public static func isLow(_ storage: DeviceStatus.Storage) -> Bool {
        storage.totalBytes > 0 && storage.hoursLeft < lowHours
    }

    /// Rounded the way people talk about it: "6", "210".
    public static func roundedHours(_ hours: Double) -> Int {
        hours < 20 ? Int(hours.rounded()) : Int((hours / 10).rounded()) * 10
    }

    /// "About 210 hours left".
    public static func hoursLeft(_ storage: DeviceStatus.Storage) -> String {
        let hours = storage.hoursLeft
        if hours < 1 { return "Less than an hour left" }
        let rounded = roundedHours(hours)
        return rounded == 1 ? "About 1 hour left" : "About \(rounded) hours left"
    }

    /// "Room for about 6 more hours", for the low-storage figure.
    public static func room(_ storage: DeviceStatus.Storage) -> String {
        let hours = storage.hoursLeft
        if hours < 1 { return "Room for less than an hour more" }
        let rounded = roundedHours(hours)
        return rounded == 1 ? "Room for about 1 more hour" : "Room for about \(rounded) more hours"
    }

    /// "6.1 GB free of 7.2 GB, about 210 hours".
    public static func detail(_ storage: DeviceStatus.Storage) -> String {
        let style = ByteCountFormatStyle(style: .decimal)
        let hours = storage.hoursLeft
        let about = hours < 1 ? "less than an hour" : "about \(roundedHours(hours)) hour\(roundedHours(hours) == 1 ? "" : "s")"
        return "\(Int64(storage.freeBytes).formatted(style)) free of \(Int64(storage.totalBytes).formatted(style)), \(about)"
    }
}

public enum BatteryFormat {
    /// Battery figures turn orange at or below this level.
    public static let lowLevel = 20

    public static func symbol(_ battery: DeviceStatus.Battery?) -> String {
        guard let battery else { return "battery.0percent" }
        if battery.charging { return "battery.100percent.bolt" }
        guard let level = battery.level else { return "battery.0percent" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    public static func isLow(_ battery: DeviceStatus.Battery?) -> Bool {
        guard let battery, !battery.charging, let level = battery.level else { return false }
        return level <= lowLevel
    }

    /// "80%" or "—".
    public static func value(_ battery: DeviceStatus.Battery?) -> String {
        battery?.level.map { "\($0)%" } ?? "—"
    }

    /// "80%", "60%, charging", or "Unknown".
    public static func label(_ battery: DeviceStatus.Battery?) -> String {
        guard let level = battery?.level else { return "Unknown" }
        return battery?.charging == true ? "\(level)%, charging" : "\(level)%"
    }

    /// "Recorder battery, 80 percent, charging".
    public static func accessibilityLabel(_ name: String, _ battery: DeviceStatus.Battery?) -> String {
        guard let level = battery?.level else { return "\(name), unknown" }
        return "\(name), \(level) percent" + (battery?.charging == true ? ", charging" : "")
    }
}

/// Signal strength in words. dBm never appears in the interface.
public enum SignalStrength: Equatable {
    case nearby, inRange, fartherAway

    public init(rssi: Int) {
        // CoreBluetooth reports 127 when the value isn't available.
        if rssi >= 0 { self = .inRange }
        else if rssi >= -65 { self = .nearby }
        else if rssi >= -80 { self = .inRange }
        else { self = .fartherAway }
    }

    public var word: String {
        switch self {
        case .nearby: return "Nearby"
        case .inRange: return "In range"
        case .fartherAway: return "Farther away"
        }
    }

    /// For the `cellularbars` variable value.
    public var bars: Double {
        switch self {
        case .nearby: return 1
        case .inRange: return 0.66
        case .fartherAway: return 0.33
        }
    }
}

/// "··7F3A": enough to tell two recorders apart without showing the whole serial number.
public func maskedSerial(_ serial: String) -> String {
    let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 4 else { return trimmed }
    return "··" + trimmed.suffix(4)
}

public enum DeviceDateFormat {
    /// "Today, 10:02 AM", "Yesterday, 3:30 PM", "Tue 20 Oct, 9:15 AM".
    public static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return "\(date.formatted(style)), \(time)"
    }

    /// A stale value's time: "at 2:14 PM" today, "on 20 Oct" earlier.
    public static func asOf(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at " + date.formatted(date: .omitted, time: .shortened) }
        return "on " + date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "today, 2:14 PM" or "Tue 20 Oct, 2:14 PM", for "Last connected …".
    public static func lastSeen(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let title = title(date, now: now, calendar: calendar)
        if title.hasPrefix("Today") || title.hasPrefix("Yesterday") { return title.prefix(1).lowercased() + title.dropFirst() }
        return title
    }

    /// "Updated just now" or "as of 2:14 PM".
    public static func updated(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 90 ? "Updated just now" : "as of \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// "just now", "2 hours ago".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// A length in words: "43 sec", "43 min", "1 hr 12 min". Shared by recorder lengths here and by
/// conversations in DaybookKit, which re-exports it.
public enum DurationLabel {
    public static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 sec" }
        if seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        return Duration.seconds((seconds / 60).rounded() * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

extension Meeting {
    /// The span of the longest recording on the conversation's timeline.
    public var duration: TimeInterval? {
        tracks.compactMap { track in track.duration.map { max(0, track.offset ?? 0) + $0 } }.max()
    }
}
