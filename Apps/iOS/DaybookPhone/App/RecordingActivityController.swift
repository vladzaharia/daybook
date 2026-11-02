import ActivityKit
import Foundation
import WidgetKit

/// Runs the recording's Live Activity (Lock Screen and Dynamic Island).
///
/// Every recording starts one: the system requires it when an `AudioRecordingIntent` starts
/// recording from the background, and it's how Stop and Bookmark stay one touch away. Updates are
/// sent when what it shows changes, and at least once a minute while recording, so its stale date
/// (`ContentState.staleAfter`) keeps rolling: if the app stops (a crash, the system ending it), the
/// activity goes stale and asks to open Daybook instead of counting on. The clock counts itself.
/// Updates and the end go out in the order made (`LiveActivityRunner`).
@MainActor
final class RecordingActivityController {
    private let runner = LiveActivityRunner<RecordingActivityAttributes>()
    private var current: RecordingActivityAttributes.ContentState?
    private var lastSent = Date.distantPast
    private var lastLevelUpdate = Date.distantPast
    private var lastCaptionUpdate = Date.distantPast
    /// Hearing-or-not changes at most this often, to stay inside the system's update budget.
    static let levelInterval: TimeInterval = 2

    var isRunning: Bool { runner.isRunning }

    func start(conversationID: UUID, title: String, state: RecordingActivityAttributes.ContentState) {
        let now = Date()
        // A previous run's activity (the app was killed mid-recording) no longer means anything.
        let started = runner.request(RecordingActivityAttributes(conversationID: conversationID, title: title),
                                     content: ActivityContent(state: state, staleDate: state.staleDate(from: now), relevanceScore: 100),
                                     endingLeftovers: { $0.conversationID != conversationID })
        guard started else { return }
        current = state
        lastSent = now
    }

    func update(_ state: RecordingActivityAttributes.ContentState) {
        guard runner.isRunning else { return }
        let now = Date()
        let state = Self.paced(state, current: current, captionSentAt: lastCaptionUpdate, now: now)
        guard Self.shouldSend(state, current: current, sentAt: lastSent, levelSentAt: lastLevelUpdate, now: now) else { return }
        if let current, current != state, Self.differsOnlyInLevel(state, current) { lastLevelUpdate = now }
        if state.caption != current?.caption { lastCaptionUpdate = now }
        current = state
        lastSent = now
        runner.update(ActivityContent(state: state, staleDate: state.staleDate(from: now)))
    }

    /// Whether an update goes now: a change at once (a hearing-or-not change at most every
    /// `levelInterval`), and the same content again once `refreshInterval` has passed, to keep the
    /// stale date ahead.
    static func shouldSend(_ state: RecordingActivityAttributes.ContentState, current: RecordingActivityAttributes.ContentState?,
                           sentAt: Date, levelSentAt: Date, now: Date) -> Bool {
        guard let current else { return true }
        if !state.hasEnded, now.timeIntervalSince(sentAt) >= RecordingActivityAttributes.ContentState.refreshInterval { return true }
        if state == current { return false }
        if differsOnlyInLevel(state, current) { return now.timeIntervalSince(levelSentAt) >= levelInterval }
        return true
    }

    /// A new caption waits until `captionInterval` has passed since the last one went out: until
    /// then the activity keeps the caption it shows. One going away (captions off, paused) goes at once.
    static func paced(_ state: RecordingActivityAttributes.ContentState, current: RecordingActivityAttributes.ContentState?,
                      captionSentAt: Date, now: Date) -> RecordingActivityAttributes.ContentState {
        guard let current, state.caption != current.caption, state.caption != nil,
              now.timeIntervalSince(captionSentAt) < RecordingActivityAttributes.ContentState.captionInterval else { return state }
        var paced = state
        paced.caption = current.caption
        return paced
    }

    private static func differsOnlyInLevel(_ state: RecordingActivityAttributes.ContentState,
                                           _ current: RecordingActivityAttributes.ContentState) -> Bool {
        var withoutLevel = current
        withoutLevel.level = state.level
        return withoutLevel == state
    }

    /// Ends the activity on `state`, after any update still on its way: Saved goes in a few seconds;
    /// Recording stopped stays on the Lock Screen until the person has seen it.
    func end(_ state: RecordingActivityAttributes.ContentState) {
        guard runner.isRunning else { return }
        current = nil
        runner.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: Self.dismissal(for: state))
    }

    /// How long an ended activity stays: Saved briefly; a recording that stopped by itself until the
    /// system takes it away (up to four hours), so a glance at the Lock Screen still tells.
    static func dismissal(for state: RecordingActivityAttributes.ContentState, now: Date = Date()) -> ActivityUIDismissalPolicy {
        state.phase == .stopped ? .default : .after(now.addingTimeInterval(8))
    }

    /// Ends activities left from a run that didn't finish (called at launch, before recovery).
    func endOrphans() {
        guard !runner.isRunning else { return }
        LiveActivityRunner<RecordingActivityAttributes>.endAll()
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
        LiveActivityRunner<RecordingActivityAttributes>.endAll()
        RecorderActivityController.endLeftovers()
    }
}

/// Writes what the widgets and the control read (`SharedRecordingState`) and asks them to refresh:
/// on every change, and at least once a minute while recording, so a recording the app can no
/// longer confirm reads as unconfirmed rather than "Recording" forever.
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
