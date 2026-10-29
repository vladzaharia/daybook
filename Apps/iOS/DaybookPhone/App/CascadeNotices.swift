import Foundation
import UserNotifications

/// What the iPhone says when a recorder's button starts a shared recording while Daybook is in the
/// background (docs/multipoint.md, "Starting anywhere"). iOS doesn't let an app start the microphone
/// from the background, nor a Live Activity, so the recorder's audio is saved here as it records and a
/// notification says so, plainly; opening Daybook from it records on this iPhone too. Never a
/// microphone kept open silently, and never a claim that this iPhone records when it doesn't.
@MainActor
struct CascadeNotices {
    /// Shows a notification (the app's own in the app; none in tests).
    var post: (_ id: String, _ title: String, _ body: String) -> Void
    /// Takes one away once it's no longer true.
    var remove: (_ id: String) -> Void

    static let recorderRecording = "cascade.recorder-recording"

    /// The words for a recorder recording without this iPhone's microphone.
    static func recorderRecordingText(_ recorder: String) -> (title: String, body: String) {
        ("\(recorder) is recording", "Daybook is saving its audio. Open Daybook to record on this iPhone too.")
    }

    func recorderRecording(_ recorder: String) {
        let text = Self.recorderRecordingText(recorder)
        post(Self.recorderRecording, text.title, text.body)
    }

    func recorderStopped() { remove(Self.recorderRecording) }

    /// Through the notification center, once Daybook may post (asked when the person first sets up a
    /// recorder or records with one).
    static let app = CascadeNotices(post: { id, title, body in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }, remove: { id in
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    })

    static let silent = CascadeNotices(post: { _, _, _ in }, remove: { _ in })
}

/// A shared recording this iPhone takes part in only through its recorder: the recorder's button
/// started it while Daybook was in the background, where iOS doesn't let it start the microphone.
struct RecorderOnlyRecording: Equatable, Sendable {
    var conversationID: UUID
    var title: String
    /// When the recorder started, on this iPhone's clock.
    var startedAt: Date
    /// The recorder's device session.
    var recorderID: String
    var recorderName: String
}
