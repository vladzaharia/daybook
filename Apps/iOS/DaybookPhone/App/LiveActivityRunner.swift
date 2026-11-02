import ActivityKit
import Foundation

/// One Live Activity of a kind, asked for, updated, and ended in the order the app asks: each
/// ActivityKit call waits for the one before, so an end never overtakes an update still on its way,
/// and a quick pause and resume land in that order. Generic over the activity's attributes, so the
/// recording's (`RecordingActivityController`) and a recorder's (`RecorderActivityController`) share it.
@MainActor
final class LiveActivityRunner<Attributes: ActivityAttributes> {
    private(set) var activity: Activity<Attributes>?
    /// The last ActivityKit call made.
    private var sending: Task<Void, Never>?

    var isRunning: Bool { activity != nil }
    var attributes: Attributes? { activity?.attributes }

    /// Starts an activity, first ending any of its kind that `isLeftover` names (one a previous run left).
    /// False when Live Activities are off or the system refused it.
    @discardableResult
    func request(_ attributes: Attributes, content: ActivityContent<Attributes.ContentState>,
                 endingLeftovers isLeftover: (Attributes) -> Bool = { _ in true }) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        let leftovers = Activity<Attributes>.activities.filter { $0.id != activity?.id && isLeftover($0.attributes) }
        if !leftovers.isEmpty {
            let previous = sending
            sending = Task { @concurrent in
                await previous?.value
                for stale in leftovers { await stale.end(nil, dismissalPolicy: .immediate) }
            }
        }
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            return true
        } catch {
            activity = nil
            return false
        }
    }

    /// Shows `content`, after whatever was sent before it.
    func update(_ content: ActivityContent<Attributes.ContentState>) {
        guard let activity else { return }
        let previous = sending
        sending = Task { @concurrent in
            await previous?.value
            await activity.update(content)
        }
    }

    /// Ends the activity with `content` (nil keeps what it shows), after whatever was sent before it.
    func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) {
        guard let activity else { return }
        self.activity = nil
        let previous = sending
        sending = Task { @concurrent in
            await previous?.value
            await activity.end(content, dismissalPolicy: dismissalPolicy)
        }
    }

    /// Ends every activity of this kind at once: what a run that didn't finish left.
    static func endAll() {
        let all = Activity<Attributes>.activities
        guard !all.isEmpty else { return }
        Task { @concurrent in
            for stale in all { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Waits until every call made so far is done.
    func settle() async {
        await sending?.value
    }
}
