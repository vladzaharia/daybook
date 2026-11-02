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
    /// The last update or end sent. ActivityKit's calls are async, so each waits for the one before it: an
    /// older state never lands after a newer one, and an update never lands after the end.
    private var sending: Task<Void, Never>?

    init(sessions: @escaping () -> [DeviceSession]) {
        self.sessions = sessions
    }

    /// The recorder an activity is for, if any: the first one listening live, else one recording what
    /// this iPhone started.
    static func target(_ sessions: [DeviceSession], now: Date = Date()) -> Target? {
        var targets: [Target] = []
        for session in sessions {
            guard session.managedElsewhere == nil, let recorder = session.direct as? any RecordingStateConnection else { continue }
            let known = recorder.recordingState(at: now)
            let listening = (recorder as? any LiveListeningConnection)?.live.isListening == true
            guard let content = Content.make(isListening: listening, isRecording: known?.isRecording == true,
                                             startedHere: known?.startedHere == true, startedAt: known?.startedAt,
                                             isLive: known?.isLive ?? false, asOf: known?.asOf ?? now),
                  let id = known?.recordingID ?? (content.phase == .listening ? "live" : nil) else { continue }
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
            if let activity { send { await activity.update(ActivityContent(state: content, staleDate: content.staleDate(from: now))) } }
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
        send { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }

    /// Sends one change to ActivityKit after the ones before it have landed.
    private func send(_ change: @escaping @MainActor () async -> Void) {
        let previous = sending
        sending = Task { @MainActor in
            await previous?.value
            await change()
        }
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
