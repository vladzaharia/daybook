import UIKit

/// What only the application delegate hears: iOS relaunching the app for a background download
/// session's events (the live models' downloads, `BackgroundModelFetcher`).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // The models' session takes the events (moving finished files into place) and calls this
        // once they're delivered; any other session's events have nothing waiting for them.
        if !PhoneModels.downloads.handleEvents(for: identifier, completion: completionHandler) { completionHandler() }
    }
}
