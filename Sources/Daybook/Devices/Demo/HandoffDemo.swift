#if DEBUG
import AppKit
import DaybookCore
import DaybookDevices
import DaybookKit

/// Debug-only recorder handoff states for screenshots, on top of a device demo:
///
///     --device-demo not-connected --handoff-demo waiting
///
/// States: managed (Alex’s iPhone manages it), asking, finishing (the iPhone finishes an import
/// first), waiting (through iCloud), overdue (waiting, past its patience), refused, connecting,
/// done, handing (this Mac hands it to the iPhone after an import; use with `--device-demo importing`).
/// Nothing reaches the network or Bluetooth.
@MainActor
enum HandoffDemo {
    static let state = LaunchOptions.value(after: "--handoff-demo")

    static func apply(to app: AppState) {
        guard let state, let session = app.devices.sessions.first(where: { $0.kind.id == SoundcoreWorkIntegration.id }),
              let serial = session.recorderSerial else { return }
        let phone = ProcessingRequest.Device(id: "demo-iphone", name: "Alex’s iPhone")
        let now = Date()
        let managedByPhone = ["managed", "asking", "finishing", "waiting", "overdue", "refused"].contains(state)
        if managedByPhone {
            app.library.claimRecorder(kind: session.kind.id, serial: serial, deviceClass: .phone, by: phone)
        } else {
            app.library.claimRecorder(kind: session.kind.id, serial: serial, deviceClass: .mac)
        }
        let handoff = app.recorderHandoff
        let demo: RecorderHandoff.State
        switch state {
        case "asking": demo = .asking(owner: phone.name)
        case "finishing": demo = .ownerFinishing(owner: phone.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 140))
        case "waiting": demo = .waitingForSync(owner: phone.name, since: now.addingTimeInterval(-25))
        case "overdue": demo = .waitingForSync(owner: phone.name, since: now.addingTimeInterval(-14 * 60))
        case "refused": demo = .refused(by: phone.name, message: "Alex’s iPhone is already handing Soundcore Work to another device.")
        case "connecting": demo = .connecting(from: phone.name)
        case "done": demo = .done(at: now)
        case "handing": demo = .handingOver(to: phone.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 372))
        default: demo = .idle
        }
        // After the ownership reaches the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { handoff.applyDemo(demo, for: session) }
    }
}
#endif
