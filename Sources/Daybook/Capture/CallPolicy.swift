import Foundation

/// What Daybook does when a call starts (Settings › Recording › When a call starts; docs/capture.md, "Calls").
enum CallRecordingPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Doesn't look for calls.
    case off
    /// Asks with the call prompt, a small panel where Floating Notes opens; Record grows it into Floating Notes.
    case ask
    /// Records a call as soon as it's sure of it, and stops once it has ended.
    case record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask"
        case .record: "Record Automatically"
        }
    }
}

/// One app's own answer for its calls, ahead of the policy: chosen in the call prompt's menu, or in Settings.
enum CallAppChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case ask, always, never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always Record"
        case .never: "Never"
        }
    }
}

/// What a call that has just started gets.
enum CallDecision: Equatable, Sendable {
    case record, ask, ignore
}

enum CallPolicy {
    static let key = "callPolicy"
    static let choicesKey = "callAppChoices"
    /// "Record calls automatically", before there were three answers.
    static let legacyKey = "automaticRecording"

    /// The app's own choice, else the policy's. Nothing while a recording is being made or started, and nothing when
    /// the policy is Off, whatever an app's choice. In a Focus whose Daybook filter turns Ask to Record Meetings off
    /// (`asks` false, `PersonalFocus.asksToRecord`), a call that would be asked about is left alone; one recorded
    /// automatically still is.
    static func decision(for bundleID: String, policy: CallRecordingPolicy, choices: [String: CallAppChoice], busy: Bool,
                         asks: Bool = true) -> CallDecision {
        guard !busy, policy != .off else { return .ignore }
        let decision: CallDecision
        switch choices[bundleID] {
        case .always?: decision = .record
        case .never?: decision = .ignore
        case .ask?: decision = .ask
        case nil: decision = policy == .record ? .record : .ask
        }
        return decision == .ask && !asks ? .ignore : decision
    }

    /// The saved policy. Before there was one, "Record calls automatically" on records, and off asks, as a new
    /// installation does.
    static func stored(in defaults: UserDefaults) -> CallRecordingPolicy {
        if let raw = defaults.string(forKey: key), let policy = CallRecordingPolicy(rawValue: raw) { return policy }
        return defaults.bool(forKey: legacyKey) ? .record : .ask
    }

    static func storedChoices(in defaults: UserDefaults) -> [String: CallAppChoice] {
        guard let data = defaults.data(forKey: choicesKey),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues(CallAppChoice.init(rawValue:))
    }

    static func save(_ policy: CallRecordingPolicy, choices: [String: CallAppChoice], in defaults: UserDefaults) {
        defaults.set(policy.rawValue, forKey: key)
        // An older Daybook reads this one: on only when every call is recorded.
        defaults.set(policy == .record, forKey: legacyKey)
        defaults.set(try? JSONEncoder().encode(choices.mapValues(\.rawValue)), forKey: choicesKey)
    }

    /// What Settings and the prompt call an app: the rule's name, else the app's own.
    static func appName(for bundleID: String, rules: [MeetingAppRule] = MeetingAppRule.defaults) -> String {
        rules.first { $0.bundleID == bundleID }?.displayName ?? bundleID
    }
}
