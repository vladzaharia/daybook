import Foundation

/// What the widgets and the Control Center control know about recording, shared through the app
/// group. The app writes it; the extension only reads it. Recordings themselves never leave the
/// app's container.
struct SharedRecordingState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, recording, paused }

    var phase: Phase = .idle
    /// The conversation's first second on the wall clock, while recording or paused.
    var startedAt: Date?
    var title: String?
    var bookmarkCount = 0
    /// "Also on Studio Mac" while a Mac records the same conversation.
    var multipoint: String?
    var lastRecordingTitle: String?
    var lastRecordingDate: Date?
    var lastRecordingDuration: TimeInterval?
    /// Seconds into the conversation when it paused: the clock shows this, frozen. Optional, so a
    /// state written by an earlier build decodes.
    var pausedElapsed: TimeInterval?
    /// When the app last confirmed this. It writes at least once a minute while recording, so a
    /// recording it hasn't confirmed for a while is shown as not confirmed (the app may have been
    /// stopped by the system) instead of "Recording" forever. Optional, so earlier states decode;
    /// an active state without it is unconfirmed.
    var asOf: Date?

    var isActive: Bool { phase != .idle }

    static let appGroup = "group.local.daybook.phone"
    static let defaultsKey = "recording-state"
    static let controlKind = "local.daybook.phone.record-control"
    static let widgetKind = "local.daybook.phone.recorder"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load(from defaults: UserDefaults = Self.defaults) -> SharedRecordingState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(SharedRecordingState.self, from: data) else { return SharedRecordingState() }
        return state
    }

    func save(to defaults: UserDefaults = Self.defaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: What the widgets show, and until when

extension SharedRecordingState {
    /// What a widget or the control shows at a moment.
    enum Display: Equatable {
        case idle
        /// Recording; the clock counts from `since`.
        case recording(since: Date)
        /// Paused; the clock is frozen at `elapsed`.
        case paused(elapsed: TimeInterval)
        /// The app hasn't confirmed the recording for too long (it may have been stopped).
        case unconfirmed
    }

    /// How often the app confirms a recording while it records.
    static let confirmationInterval: TimeInterval = 60
    /// A recording unconfirmed for longer than this (two confirmations and some) isn't shown as recording.
    static let recordingConfirmedFor: TimeInterval = 150
    /// A pause changes nothing until the person acts, and the app may be suspended through a call.
    static let pausedConfirmedFor: TimeInterval = 2 * 3_600

    func display(at date: Date) -> Display {
        guard isActive else { return .idle }
        guard let until = confirmedUntil, date < until else { return .unconfirmed }
        if phase == .paused { return .paused(elapsed: pausedElapsed ?? 0) }
        // Nil for the instant before the first sample: the clock starts now.
        return .recording(since: startedAt ?? asOf ?? date)
    }

    /// When an active state stops counting as confirmed; nil when idle or never confirmed.
    var confirmedUntil: Date? {
        guard isActive, let asOf else { return nil }
        return asOf.addingTimeInterval(phase == .paused ? Self.pausedConfirmedFor : Self.recordingConfirmedFor)
    }

    /// Recording or paused, and confirmed: what the control shows as on.
    func isConfirmedActive(at date: Date) -> Bool {
        switch display(at: date) {
        case .recording, .paused: return true
        case .idle, .unconfirmed: return false
        }
    }

    /// The widget timeline's entries: now, and the moment an active state becomes unconfirmed, so it
    /// changes on its own if the app stops confirming.
    func timelineDates(from now: Date) -> [Date] {
        guard let until = confirmedUntil, until > now else { return [now] }
        return [now, until]
    }

    /// A new process isn't recording yet: what an earlier run left as recording or paused ended with
    /// it (a crash, the system stopping it, a background relaunch). The last recording stays.
    func clearedAtLaunch() -> SharedRecordingState {
        guard isActive else { return self }
        var state = SharedRecordingState()
        state.lastRecordingTitle = lastRecordingTitle
        state.lastRecordingDate = lastRecordingDate
        state.lastRecordingDuration = lastRecordingDuration
        state.asOf = Date()
        return state
    }

    /// "1 bookmark", "3 bookmarks".
    static func bookmarks(_ count: Int) -> String { count == 1 ? "1 bookmark" : "\(count) bookmarks" }

    /// One line for the inline widget: "Paused · 12:03", "Not confirmed", "Daybook ready". Recording
    /// is drawn with a live clock instead.
    static func inlineLine(_ display: Display) -> String {
        switch display {
        case .idle: return "Daybook ready"
        case .recording: return "Recording"
        case .paused(let elapsed): return "Paused · \(TimeLabel.short(elapsed))"
        case .unconfirmed: return "Not confirmed"
        }
    }

    /// The headline: "Recording", "Paused", "Not confirmed", or "Daybook".
    static func headline(_ display: Display) -> String {
        switch display {
        case .idle: return "Daybook"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .unconfirmed: return "Not confirmed"
        }
    }
}
