import SwiftUI
import WatchKit

/// Daybook for Apple Watch: records on the wrist as one of the iPhone's recorders (docs/watch.md).
@main
struct DaybookWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RecorderView()
                .environment(delegate.model)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            delegate.model.scenePhaseChanged(phase)
        }
    }
}

/// Launches the model, foreground or background, and holds WatchConnectivity's background tasks until what arrived
/// has been handled.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let model = WatchModel()

    func applicationDidFinishLaunching() {
        model.launch()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        model.launch()
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                model.hold(connectivity)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
