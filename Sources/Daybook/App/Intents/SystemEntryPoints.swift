import AppKit
import DaybookDevices
import SwiftUI

/// What the system reaches Daybook through, started once the library window is up: App Intents (Shortcuts, Siri,
/// Spotlight's actions) on the app's state, Spotlight's copy of the conversations, and the recording's notifications.
/// The app puts `.systemEntryPoints(state:)` on its library window's content.
@MainActor
enum SystemEntryPoints {
    private static var notifications: RecordingNotifications?
    private static var spotlight: ConversationSpotlight?

    static func start(state: AppState, openLibrary: @escaping () -> Void) {
        IntentState.register(state, openLibrary: openLibrary)
        // Only the app's own library, from a bundled app: never a `--library` demo's or an unbundled run's.
        guard DeviceNotifications.isAvailable else { return }
        if notifications == nil {
            let center = SystemRecordingNotifications()
            let notifications = RecordingNotifications(state: state, center: center)
            notifications.openLibrary = openLibrary
            center.respond = { [weak notifications] in notifications?.respond($0) }
            center.install()
            notifications.start()
            self.notifications = notifications
        }
        if spotlight == nil, LaunchOptions.libraryURL == nil {
            let spotlight = ConversationSpotlight(state: state)
            spotlight.start()
            self.spotlight = spotlight
        }
    }
}

extension View {
    /// Starts `SystemEntryPoints` for the app's state, with this window's way to open the library window.
    func systemEntryPoints(state: AppState) -> some View {
        modifier(SystemEntryPointsModifier(state: state))
    }
}

private struct SystemEntryPointsModifier: ViewModifier {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let openWindow = self.openWindow
            SystemEntryPoints.start(state: state) {
                openWindow(id: WindowID.library)
                NSApp.activate()
            }
        }
    }
}

/// Waiting for the library to open, for what can be asked before it has: Welcome's Record and Import, an intent that
/// launched Daybook, a notification's Record Again.
@MainActor
enum LibraryOpening {
    /// Returns once the library is open (true), or once it won't open by itself (false): a library move holds it until
    /// the person answers, or it couldn't open (the window says so). It never gives up on a slow first launch.
    static func opens(_ state: AppState) async -> Bool {
        await ObservationWatch.until {
            state.isReady || state.libraryMoveOffer?.holdsLibrary == true || state.problem != nil
        }
        return state.isReady
    }
}
