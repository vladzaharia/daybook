import SwiftUI
import UIKit

/// Recording-only tokens, on top of `PhoneStyle` (docs/interface.md). Red is only for recording
/// right now (the dot, the clock, Stop); amber only for bookmarks; teal for the meter and for
/// what can be acted on.
enum RecordingStyle {
    /// Elapsed-time sizes per posture.
    enum Clock {
        static let pocket: CGFloat = 64
        static let notebook: CGFloat = 76
        static let table: CGFloat = 148
    }

    /// Thumb-zone controls in the hand; the table's target is meant to be hit without looking.
    enum Control {
        static let pocketHeight: CGFloat = 64
        static let notebookHeight: CGFloat = 56
        static let tableTarget: CGFloat = 248
        static let corner: CGFloat = 20
    }

    /// Table mode dims after this long without a touch, to save battery.
    static let dimAfter: Duration = .seconds(8)
    static let dimmedOpacity: Double = 0.5

    /// The rolling meter.
    enum Meter {
        static let pocketHeight: CGFloat = 44
        static let notebookHeight: CGFloat = 56
        static let tableHeight: CGFloat = 64
        static let barWidth: CGFloat = 3
        static let gap: CGFloat = 2.5
    }

    /// A recording's pause, and anything else that needs the person: Ink.warning on an 8% fill.
    static let attentionFill = PhoneStyle.Ink.warning.opacity(0.09)
    /// Quiet fills for chips and the timeline's track.
    static let quietFill = Color(uiColor: .quaternarySystemFill)
}

/// Debug only: turns the interface as if the person turned the iPhone (the simulator has no command
/// for it). Flex mode on a real iPhone Duo follows the device.
enum InterfaceOrientation {
    @MainActor
    static func apply(_ value: String?) {
        #if DEBUG
        guard let value, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = value == "portrait" ? .portrait : value == "landscape" ? .landscapeRight : []
        guard !mask.isEmpty else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            NSLog("Daybook: interface orientation %@ refused: %@", value, error.localizedDescription)
            // The inner display refuses programmatic rotation; try the device's simulated orientation.
            let device: UIDeviceOrientation = value == "portrait" ? .portrait : .landscapeLeft
            UIDevice.current.setValue(device.rawValue, forKey: "orientation")
            NSLog("Daybook: simulated device orientation %d, interface now %d", device.rawValue,
                  scene.effectiveGeometry.interfaceOrientation.rawValue)
        }
        #endif
    }
}
