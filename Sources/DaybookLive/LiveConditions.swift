import Foundation

/// What the device is going through while it captions live: heat, power, battery, and whether
/// anyone can see the captions. The apps fill in what only they know (an iPhone's battery and
/// whether the app is in front); the rest comes from `ProcessInfo`.
public struct LiveConditions: Equatable, Sendable {
    public enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        public static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }

        public init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal: self = .nominal
            case .fair: self = .fair
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .serious
            }
        }
    }

    public var thermal: Thermal
    public var lowPowerMode: Bool
    /// 0…1; nil when the device has no battery or doesn't say (a Mac on power, a simulator).
    public var batteryLevel: Double?
    public var isCharging: Bool
    /// Someone can see the captions: the iPhone app is in front. Always true on a Mac, where captions
    /// are saved for the conversation page whether or not the panel shows.
    public var isVisible: Bool

    public init(thermal: Thermal = .nominal, lowPowerMode: Bool = false, batteryLevel: Double? = nil,
                isCharging: Bool = false, isVisible: Bool = true) {
        self.thermal = thermal; self.lowPowerMode = lowPowerMode; self.batteryLevel = batteryLevel
        self.isCharging = isCharging; self.isVisible = isVisible
    }

    /// Heat and Low Power Mode from `ProcessInfo`, with what the app knows added.
    public static func system(batteryLevel: Double? = nil, isCharging: Bool = false, isVisible: Bool = true) -> LiveConditions {
        let process = ProcessInfo.processInfo
        return LiveConditions(thermal: Thermal(process.thermalState), lowPowerMode: process.isLowPowerModeEnabled,
                              batteryLevel: batteryLevel, isCharging: isCharging, isVisible: isVisible)
    }
}

/// How much of the live pipeline runs right now. Each step down sheds the most expensive work still
/// running; the recording itself never depends on any of it.
public enum LiveWorkLevel: Int, Comparable, Sendable {
    /// Nothing: audio is let go (captions resume, with a gap, when conditions improve).
    case paused
    /// Words only: no speaker detection or names.
    case transcriptionOnly
    /// Words, speakers, and names, the speakers at a lower cadence: the speaker model hears the audio
    /// in batches of a few seconds, and each voice is embedded for names only now and then. Labels
    /// arrive later than on screen, which nobody sees in a pocket.
    case reduced
    /// Words, speakers, and names.
    case full

    public static func < (lhs: LiveWorkLevel, rhs: LiveWorkLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When live captions back off (docs/model-runtime.md, "Live"). Pure: tests drive it with conditions.
public struct LiveLoadPolicy: Equatable, Sendable {
    /// Below this charge, unplugged, speakers stop.
    public var lowBattery: Double = 0.2
    /// Below this charge, unplugged, live captions stop.
    public var criticalBattery: Double = 0.1
    /// The most that runs while nobody can see the captions (the iPhone in a pocket). Captions are
    /// saved for the conversation page, so speakers keep being labelled there, at a lower cadence.
    public var whenHidden: LiveWorkLevel
    /// A backlog this full (0…1) sheds speakers until it drains below `recoveredBacklog`.
    public var behindBacklog: Double = 0.5
    public var recoveredBacklog: Double = 0.2

    public init(whenHidden: LiveWorkLevel) { self.whenHidden = whenHidden }

    /// The Mac: plugged in or on a large battery, captions always visible to the conversation page.
    public static let mac = LiveLoadPolicy(whenHidden: .full)
    /// The iPhone: battery and heat matter more, and a pocket hides the screen.
    public static let iPhone = LiveLoadPolicy(whenHidden: .reduced)

    /// The level `conditions` allow, before the backlog is considered.
    public func level(for conditions: LiveConditions) -> LiveWorkLevel {
        let unplugged = !conditions.isCharging
        if conditions.thermal >= .critical { return .paused }
        if unplugged, let battery = conditions.batteryLevel, battery <= criticalBattery { return .paused }
        if conditions.thermal >= .serious || conditions.lowPowerMode { return .transcriptionOnly }
        if unplugged, let battery = conditions.batteryLevel, battery <= lowBattery { return .transcriptionOnly }
        if !conditions.isVisible { return min(.full, whenHidden) }
        return .full
    }
}

/// Applies a `LiveLoadPolicy` over time: the conditions, plus how far the pipeline has fallen behind,
/// with hysteresis so a backlog near the line doesn't flap speakers on and off. Thread-safe.
public final class LiveLoadGovernor: @unchecked Sendable {
    public let policy: LiveLoadPolicy
    private let conditions: @Sendable () -> LiveConditions
    private let lock = NSLock()
    private var behind = false
    /// Conditions are read at most this often (they change slowly; reading them costs a little).
    private let interval: TimeInterval
    private var lastRead: Date = .distantPast
    private var lastLevel: LiveWorkLevel = .full

    public init(policy: LiveLoadPolicy, interval: TimeInterval = 2, conditions: @escaping @Sendable () -> LiveConditions) {
        self.policy = policy; self.interval = interval; self.conditions = conditions
    }

    /// The level now, given the input queue's fill (0…1).
    public func level(backlog: Double, now: Date = Date()) -> LiveWorkLevel {
        let (stale, previous) = lock.withLock { (now.timeIntervalSince(lastRead) >= interval, lastLevel) }
        let fromConditions = stale ? policy.level(for: conditions()) : previous
        return lock.withLock {
            if stale { lastRead = now; lastLevel = fromConditions }
            if backlog >= policy.behindBacklog { behind = true } else if backlog <= policy.recoveredBacklog { behind = false }
            return behind ? min(fromConditions, .transcriptionOnly) : fromConditions
        }
    }
}
