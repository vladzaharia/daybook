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
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // The models' session takes the events (moving finished files into place) and calls this
        // once they're delivered; any other session's events have nothing waiting for them.
        if !PhoneModels.downloads.handleEvents(for: identifier, completion: completionHandler) { completionHandler() }
    }

    /// A notification was opened: Daybook goes where it says, or just opens when it says nowhere.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = AppDestination(userInfo: response.notification.request.content.userInfo) else { return }
        AppDestinations.open(destination)
    }

    /// One arrives while Daybook is in front (most are posted only while it isn't): shown as a banner,
    /// as anywhere else.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Where a notification, an intent, or Spotlight sends Daybook: to the app model registered at launch.
@MainActor
enum AppDestinations {
    static weak var model: PhoneAppModel?

    static func open(_ destination: AppDestination) {
        model?.open(destination)
    }
}
