import SwiftUI
import UIKit

/// Recording-only tokens, on top of DaybookDesign's (docs/interface.md). The recorder's sizes are the shared
/// recorder's (DaybookUI's `RecorderSurface`); these are what only the iPhone has: table mode's dimming.
enum RecordingStyle {
    /// Table mode dims after this long without a touch, to save battery.
    static let dimAfter: Duration = .seconds(8)
    static let dimmedOpacity: Double = 0.5
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
