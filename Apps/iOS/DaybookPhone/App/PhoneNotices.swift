import AVFoundation
import DaybookKit
import Foundation
import UserNotifications

/// The notifications the iPhone posts about its own recording (a recorder's are DaybookDevices'
/// `DeviceNotifications`). Each carries where opening it goes (`AppDestination`), which the app's
/// notification delegate follows (`PhoneAppDelegate`). The words are here, so tests read them.
///
/// - A recorder's button started a shared recording while Daybook was in the background
///   (docs/multipoint.md, "Starting anywhere"): iOS doesn't let an app start the microphone from the
///   background, nor a Live Activity, so the recorder's audio is saved here as it records and a
///   notification says so; opening Daybook from it records on this iPhone too. Never a microphone kept
///   open silently, and never a claim that this iPhone records when it doesn't.
/// - A recording stopped by itself while Daybook wasn't in front (storage full or too slow, the
///   encoder failed): time-sensitive, so it reaches a pocket through Focus, and opening it goes to the
///   conversation it was saved in.
@MainActor
struct PhoneNotices {
    /// One notification.
    struct Notice: Equatable, Sendable {
        var id: String
        var title: String
        var body: String
        /// Where opening it goes.
        var destination: AppDestination
        /// Delivered at once, through Focus (a recording that stopped by itself).
        var timeSensitive = false
    }

    /// Shows a notification (the app's own in the app; none in tests).
    var post: (Notice) -> Void
    /// Takes one away once it's no longer true.
    var remove: (_ id: String) -> Void
    /// Asks once whether Daybook may post, with Daybook in front and recording: the moment its reason
    /// is at hand. Later calls do nothing.
    var askPermission: () -> Void

    // MARK: A recorder recording without this iPhone

    static let recorderRecordingID = "cascade.recorder-recording"

    /// The words for a recorder recording without this iPhone's microphone.
    static func recorderRecordingText(_ recorder: String) -> (title: String, body: String) {
        ("\(recorder) is recording", "Daybook is saving its audio. Open Daybook to record on this iPhone too.")
    }

    func recorderRecording(_ recorder: String) {
        let text = Self.recorderRecordingText(recorder)
        post(Notice(id: Self.recorderRecordingID, title: text.title, body: text.body, destination: .recording))
    }

    func recorderStopped() { remove(Self.recorderRecordingID) }

    // MARK: A recording that stopped by itself

    static let recordingStoppedID = "recording.stopped"

    /// "Recording stopped" and what's saved: everything up to its frozen time, and, when storage is full
    /// (`isStorageFull`), what to do about it. Without audio saved (`savedUpTo` nil), `otherwise` says what
    /// happened instead ("No audio was recorded. Your notes are saved.").
    static func recordingStoppedText(savedUpTo elapsed: TimeInterval?, because cause: Error?, spaceLeft: Int64? = nil,
                                     otherwise: String = "No audio was recorded.") -> (title: String, body: String) {
        guard let elapsed else { return ("Recording stopped", otherwise) }
        let saved = "Everything up to \(TimeLabel.short(elapsed)) is saved."
        let body = isStorageFull(cause, spaceLeft: spaceLeft) ? saved + " Free up space to record again." : saved
        return ("Recording stopped", body)
    }

    /// Below this much space for important use, storage that couldn't keep up is storage that's full.
    static let nearlyFull: Int64 = 1_000_000_000

    /// Whether a recording stopped because this iPhone's storage is full: the writer said so (out of
    /// space, there or underneath its own error), or storage couldn't keep up (`PhoneRecorderError.diskBacklog`)
    /// with less than `nearlyFull` left (`spaceLeft`: what the staging folder's volume has for important
    /// use). A backlog with space to spare, or with the space unknown, is something else.
    static func isStorageFull(_ cause: Error?, spaceLeft: Int64?) -> Bool {
        guard let cause else { return false }
        if (cause as? PhoneRecorderError) == .diskBacklog { return spaceLeft.map { $0 < nearlyFull } ?? false }
        return saysOutOfSpace(cause as NSError, depth: 0)
    }

    private static func saysOutOfSpace(_ error: NSError, depth: Int) -> Bool {
        switch (error.domain, error.code) {
        case (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue),
             (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)),
             (NSOSStatusErrorDomain, -34):   // dskFulErr, from the audio file underneath
            return true
        default:
            guard depth < 4 else { return false }
            return error.underlyingErrors.contains { saysOutOfSpace($0 as NSError, depth: depth + 1) }
        }
    }

    /// What the volume holding `folder` has for important use (what iOS can free for it included), read
    /// off the main actor; nil when it can't say.
    static func spaceLeft(at folder: URL) async -> Int64? {
        await Task.detached(priority: .userInitiated) {
            try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        }.value
    }

    func recordingStopped(_ text: (title: String, body: String), opening destination: AppDestination) {
        post(Notice(id: Self.recordingStoppedID, title: text.title, body: text.body, destination: destination, timeSensitive: true))
    }

    // MARK: Delivery

    /// Through the notification center, once Daybook may post.
    static let app = PhoneNotices(post: { notice in
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = notice.destination.userInfo
        if notice.timeSensitive {
            // Delivered through Focus where the app has the Time Sensitive Notifications capability; as an
            // ordinary notification, with its sound, where it doesn't.
            content.interruptionLevel = .timeSensitive
            content.sound = .default
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }, remove: { id in
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }, askPermission: {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    })

    static let silent = PhoneNotices(post: { _ in }, remove: { _ in }, askPermission: {})
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
