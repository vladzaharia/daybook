import ActivityKit
import DaybookKit
import Foundation

/// Runs the Live Activity for a recorder (Soundcore Work): while this iPhone listens live, or while a
/// recording it asked the recorder to make is running (live while connected, then "as of 10:07"
/// until the device page stops vouching for it). It follows the recorders' state; `PhoneDevices`
/// calls `follow` whenever a recorder changes.
@MainActor
final class RecorderActivityController: RecorderCommandHandling {
    typealias Content = RecorderActivityAttributes.ContentState

    /// What a recorder's activity shows.
    struct Target: Equatable {
        var recorderName: String
        var recordingID: String
        var content: Content
    }

    private var activity: Activity<RecorderActivityAttributes>?
    private var current: Target?
    private var lastSent = Date.distantPast
    private var sessions: () -> [DeviceSession]

    init(sessions: @escaping () -> [DeviceSession]) {
        self.sessions = sessions
    }

    /// The recorder an activity is for, if any: the first one listening live, else one recording what
    /// this iPhone started.
    static func target(_ sessions: [DeviceSession], now: Date = Date()) -> Target? {
        var targets: [Target] = []
        for session in sessions {
            guard let soundcore = session.direct as? SoundcoreConnection, soundcore.managedElsewhere == nil else { continue }
            let known = soundcore.recordingState(at: now)
            guard let content = Content.make(isListening: soundcore.live.isListening, isRecording: known?.isRecording == true,
                                             startedHere: known?.startedHere == true, startedAt: known?.startedAt,
                                             isLive: known?.isLive ?? false, asOf: known?.asOf ?? now),
                  let id = known?.activeRecordingID.map(String.init) ?? (content.phase == .listening ? "live" : nil) else { continue }
            targets.append(Target(recorderName: session.device.name, recordingID: id, content: content))
        }
        return targets.first { $0.content.phase == .listening } ?? targets.first
    }

    /// Starts, updates, or ends the activity to match the recorders.
    func follow(now: Date = Date()) {
        let target = Self.target(sessions(), now: now)
        if let current, target?.recordingID != current.recordingID || target?.recorderName != current.recorderName {
            end(current)
        }
        guard let target else { return }
        if activity == nil {
            start(target, now: now)
        } else if target != current || now.timeIntervalSince(lastSent) >= Content.refreshInterval {
            current = target
            lastSent = now
            let content = target.content
            if let activity { Task { await activity.update(ActivityContent(state: content, staleDate: content.staleDate(from: now))) } }
        }
    }

    private func start(_ target: Target, now: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: RecorderActivityAttributes(recorderName: target.recorderName, recordingID: target.recordingID),
                                            content: ActivityContent(state: target.content, staleDate: target.content.staleDate(from: now),
                                                                     relevanceScore: 50),
                                            pushType: nil)
            current = target
            lastSent = now
        } catch {
            activity = nil
        }
    }

    private func end(_ last: Target) {
        current = nil
        guard let activity else { return }
        self.activity = nil
        var final = last.content
        final.phase = .ended
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }

    // MARK: RecorderCommandHandling

    /// The activity's Stop Listening: what arrived is kept, and the recorder keeps recording.
    func stopListening() {
        for session in sessions() {
            if let live = session.direct as? any LiveListeningConnection, live.live.isListening { live.stopListening() }
        }
    }

    /// Activities a previous run left: they no longer mean anything in a new process.
    static func endLeftovers() {
        for stale in Activity<RecorderActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
