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
