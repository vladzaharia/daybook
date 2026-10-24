import ActivityKit
import Foundation

/// Runs the recording's Live Activity (Lock Screen and Dynamic Island).
///
/// Every recording starts one: the system requires it when an `AudioRecordingIntent` starts
/// recording from the background, and it's how Stop and Bookmark stay one touch away. Updates are
/// sent only when what it shows changes; the clock counts itself.
@MainActor
final class RecordingActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var current: RecordingActivityAttributes.ContentState?
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
        do {
            activity = try Activity.request(attributes: RecordingActivityAttributes(conversationID: conversationID, title: title),
                                            content: ActivityContent(state: state, staleDate: nil, relevanceScore: 100),
                                            pushType: nil)
            current = state
        } catch {
            activity = nil
        }
    }

    func update(_ state: RecordingActivityAttributes.ContentState) {
        guard let activity, state != current else { return }
        // Level-only changes are rate-limited; everything else goes at once.
        if var withoutLevel = current {
            withoutLevel.level = state.level
            if withoutLevel == state {
                guard Date().timeIntervalSince(lastLevelUpdate) >= Self.levelInterval else { return }
                lastLevelUpdate = Date()
            }
        }
        current = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
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
}
