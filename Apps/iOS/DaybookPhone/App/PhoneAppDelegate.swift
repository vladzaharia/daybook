import UIKit
import UserNotifications

/// What only the application delegate hears: iOS relaunching the app for a background download
/// session's events (the live models' downloads, `BackgroundModelFetcher`), and the person opening one
/// of Daybook's notifications, which goes where it says (`AppDestination`).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so the tap that launched the app reaches it.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([PhoneNotices.meetingCategory])
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // The models' session takes the events (moving finished files into place) and calls this
        // once they're delivered; any other session's events have nothing waiting for them.
        if !PhoneModels.downloads.handleEvents(for: identifier, completion: completionHandler) { completionHandler() }
    }

    /// A notification was opened, or a meeting's Record tapped: Daybook goes where it says, or just opens when it says
    /// nowhere.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard [UNNotificationDefaultActionIdentifier, PhoneNotices.recordAction].contains(response.actionIdentifier),
              let destination = AppDestination(userInfo: response.notification.request.content.userInfo) else { return }
        AppDestinations.open(destination)
    }

    /// One arrives while Daybook is in front (most are posted only while it isn't): shown as a banner,
    /// as anywhere else.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A meeting starting while this iPhone already records has nothing to ask.
        if notification.request.content.categoryIdentifier == PhoneNotices.meetingCategory.identifier,
           await AppDestinations.isRecording { return [] }
        return [.banner, .list, .sound]
    }
}

/// Where a notification, an intent, or Spotlight sends Daybook: to the app model registered at launch.
@MainActor
enum AppDestinations {
    static weak var model: PhoneAppModel?

    static func open(_ destination: AppDestination) {
        model?.open(destination)
    }

    static var isRecording: Bool { model?.isRecordingActive == true }
}
