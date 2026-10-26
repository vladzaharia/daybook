import ActivityKit
import Foundation
import WidgetKit

/// Runs the recording's Live Activity (Lock Screen and Dynamic Island).
///
/// Every recording starts one: the system requires it when an `AudioRecordingIntent` starts
/// recording from the background, and it's how Stop and Bookmark stay one touch away. Updates are
/// sent when what it shows changes, and at least once a minute while recording, so its stale date
/// (`ContentState.staleAfter`) keeps rolling: if the app stops (a crash, the system ending it), the
/// activity goes stale and says "Not confirmed" instead of counting on. The clock counts itself.
@MainActor
final class RecordingActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var current: RecordingActivityAttributes.ContentState?
    private var lastSent = Date.distantPast
    private var lastLevelUpdate = Date.distantPast
    /// Level-only changes at most this often, to stay inside the system's update budget.
    static let levelInterval: TimeInterval = 2

    var isRunning: Bool { activity != nil }

    func start(conversationID: UUID, title: String, state: RecordingActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // A previous run's activity (the app was killed mid-recording) no longer means anything.
        for stale in Activity<RecordingActivityAttributes>.activities where stale.attributes.conversationID != conversationID {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let now = Date()
        do {
            activity = try Activity.request(attributes: RecordingActivityAttributes(conversationID: conversationID, title: title),
                                            content: ActivityContent(state: state, staleDate: state.staleDate(from: now), relevanceScore: 100),
                                            pushType: nil)
            current = state
            lastSent = now
        } catch {
            activity = nil
        }
    }

    func update(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity else { return }
        let now = Date()
        guard Self.shouldSend(state, current: current, sentAt: lastSent, levelSentAt: lastLevelUpdate, now: now) else { return }
        if let current, current != state, Self.differsOnlyInLevel(state, current) { lastLevelUpdate = now }
        current = state
        lastSent = now
        Task { await activity.update(ActivityContent(state: state, staleDate: state.staleDate(from: now))) }
    }

    /// Whether an update goes now: a change at once (a level-only change at most every
    /// `levelInterval`), and the same content again once `refreshInterval` has passed, to keep the
    /// stale date ahead.
    static func shouldSend(_ state: RecordingActivityAttributes.ContentState, current: RecordingActivityAttributes.ContentState?,
                           sentAt: Date, levelSentAt: Date, now: Date) -> Bool {
        guard let current else { return true }
        if state.phase != .saved, now.timeIntervalSince(sentAt) >= RecordingActivityAttributes.ContentState.refreshInterval { return true }
        if state == current { return false }
        if differsOnlyInLevel(state, current) { return now.timeIntervalSince(levelSentAt) >= levelInterval }
        return true
    }

    private static func differsOnlyInLevel(_ state: RecordingActivityAttributes.ContentState,
                                           _ current: RecordingActivityAttributes.ContentState) -> Bool {
        var withoutLevel = current
        withoutLevel.level = state.level
        return withoutLevel == state
    }

    func end(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        current = nil
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }

    /// Ends activities left from a run that didn't finish (called at launch, before recovery).
    func endOrphans() {
        guard activity == nil else { return }
        for stale in Activity<RecordingActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Every launch, however the app was started (the first scene, an intent, or iOS relaunching it
    /// in the background for the recorder, which skips the scene's launch): nothing records in a new
    /// process yet, so an activity or widget state saying so is left from a run that ended.
    static func clearLeftoversAtLaunch(defaults: UserDefaults = SharedRecordingState.defaults) {
        let state = SharedRecordingState.load(from: defaults)
        if state.isActive {
            state.clearedAtLaunch().save(to: defaults)
            WidgetCenter.shared.reloadTimelines(ofKind: SharedRecordingState.widgetKind)
            ControlCenter.shared.reloadControls(ofKind: SharedRecordingState.controlKind)
        }
        for stale in Activity<RecordingActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

/// Writes what the widgets and the control read (`SharedRecordingState`) and asks them to refresh:
/// on every change, and at least once a minute while recording, so a recording the app can no
/// longer confirm reads as not confirmed rather than "Recording" forever.
@MainActor
final class SharedStatePublisher {
    private(set) var published: SharedRecordingState?
    /// Off in tests: nothing reaches the app group or WidgetKit.
    var writes = true

    /// Writes `state` when it changed, or when an active state's last confirmation is a minute old.
    func publish(_ state: SharedRecordingState, now: Date = Date()) {
        var state = state
        state.asOf = published?.asOf
        if state == published, !isDue(now: now) { return }
        state.asOf = now
        published = state
        guard writes else { return }
        state.save()
        WidgetCenter.shared.reloadTimelines(ofKind: SharedRecordingState.widgetKind)
        ControlCenter.shared.reloadControls(ofKind: SharedRecordingState.controlKind)
    }

    /// An active state's confirmation is due.
    func isDue(now: Date = Date()) -> Bool {
        guard let published, published.isActive, let asOf = published.asOf else { return false }
        return now.timeIntervalSince(asOf) >= SharedRecordingState.confirmationInterval
    }
}
