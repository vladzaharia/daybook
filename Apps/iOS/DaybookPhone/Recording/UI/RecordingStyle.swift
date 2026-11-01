import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI
import UIKit

/// Times as the interface shows them: DaybookKit's, here for the app's files that don't import it (the
/// widgets use DaybookDesign's `DaybookTime`, which tests hold equal to it).
typealias TimeLabel = DaybookKit.TimeLabel

extension PhoneStyle {
    /// The page's geometry on iPhone (DaybookUI's `ReadingGeometry` under touch). The Mac hangs a 56 pt
    /// time margin left of a 640 pt measure; a phone page is narrower, so the page text runs edge to edge
    /// (20 pt gutters) and only the timed blocks (your notes, bookmarks) keep a lane of times inside the
    /// column.
    enum Page {
        /// Side gutter of a page.
        static let gutter = ReadingGeometry.gutters(density: .touch, hangs: false).leading
        /// Room kept clear on each side of the iPhone Duo's crease.
        static let creaseClearance = ReadingGeometry.creaseClearance
        /// The widest a column of text gets, as on the Mac.
        static let measure = ReadingGeometry.measure
        /// The lane of times beside timed notes and bookmarks, at the default text size.
        static let lane = ReadingGeometry.lane
    }
}

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
        static let corner = DaybookRadius.control
    }

    /// Table mode dims after this long without a touch, to save battery.
    static let dimAfter: Duration = .seconds(8)
    static let dimmedOpacity: Double = 0.5

    /// The rolling meter.
    enum Meter {
        static let pocketHeight: CGFloat = 44
        static let notebookHeight: CGFloat = 56
        static let tableHeight: CGFloat = 64
        static let barWidth = RollingLevelMeter.Metrics.phone.barWidth
        static let gap = RollingLevelMeter.Metrics.phone.gap
    }

    /// A recording's pause, and anything else that needs the person: Ink.warning on a 9% wash.
    static let attentionFill = DaybookPalette.attentionFill
    /// Quiet fills for chips and the timeline's track.
    static let quietFill = DaybookPalette.quietFill
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
