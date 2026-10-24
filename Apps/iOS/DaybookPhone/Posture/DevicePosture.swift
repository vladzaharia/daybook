import Observation
import SwiftUI
import UIKit

/// How the iPhone Duo is folded, for layouts to follow: closed is the pocket recorder, open is the
/// two-page notebook, partly open while recording is table mode (docs/iphone.md). Phones without a
/// hinge report `.none` and get the closed layout, or the open one at regular width.
///
/// Fed by SwiftUI's `onHingeChange` (iOS 27.1) through `HingeObserver`. A launch argument forces a
/// posture in the simulator and in screenshots: `--posture closed|open|partial[:degrees]`.
@MainActor
@Observable
final class DevicePosture {
    enum Fold: String, CaseIterable, Sendable {
        case closed
        case partiallyOpen = "partial"
        case open
        /// No hinge: every iPhone except the Duo, or the Duo before its first report.
        case none
    }

    enum Layout: Equatable, Sendable {
        /// One column, one hand.
        case pocket
        /// Two pages, split at the crease.
        case notebook
        /// Partly open, standing on a table while recording: glanceable from across it.
        case table
    }

    private(set) var fold: Fold
    /// Hinge angle in degrees (180 is flat), when the device reports one.
    private(set) var angle: Double?
    /// Set from a launch argument; hinge reports are then ignored.
    let isForced: Bool
    /// How many hinge reports each API delivered (for the geometry probe).
    @ObservationIgnored private(set) var reports: [String: Int] = [:]

    init(fold: Fold = .none, angle: Double? = nil, forced: Bool = false) {
        self.fold = fold
        self.angle = angle
        self.isForced = forced
    }

    /// Reads `--posture closed|open|partial[:degrees]` (or `-DaybookPosture …`).
    convenience init(arguments: [String]) {
        if let forced = Self.override(in: arguments) {
            self.init(fold: forced.fold, angle: forced.angle, forced: true)
        } else {
            self.init()
        }
    }

    func update(fold: Fold, angle: Double?) {
        guard !isForced, fold != self.fold || angle != self.angle else { return }
        self.fold = fold
        self.angle = angle
    }

    /// A report without a hinge. While the app moves between the Duo's displays its views briefly
    /// leave the hierarchy that reports the hinge; keep the last posture rather than flicker to
    /// "no hinge". A device that never reported a hinge stays `.none`.
    func hingeUnavailable() {
        guard fold == .none else { return }
        update(fold: .none, angle: nil)
    }

    func layout(isRecording: Bool, horizontalSizeClass: UserInterfaceSizeClass?) -> Layout {
        switch fold {
        case .open: return .notebook
        case .partiallyOpen: return isRecording ? .table : .notebook
        case .closed: return .pocket
        case .none: return horizontalSizeClass == .regular ? .notebook : .pocket
        }
    }

    /// What the debug badge and accessibility say: "Open · 180°".
    var summary: String {
        let name: String
        switch fold {
        case .closed: name = "Closed"
        case .partiallyOpen: name = "Partly open"
        case .open: name = "Open"
        case .none: name = "No hinge"
        }
        return angle.map { "\(name) · \(Int($0.rounded()))°" } ?? name
    }

    static func override(in arguments: [String]) -> (fold: Fold, angle: Double?)? {
        let keys = ["--posture", "-DaybookPosture"]
        guard let index = arguments.firstIndex(where: keys.contains), arguments.indices.contains(index + 1) else { return nil }
        let parts = arguments[index + 1].lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        let fold: Fold
        switch parts.first {
        case "closed": fold = .closed
        case "open", "flat": fold = .open
        case "partial", "partially-open", "tent", "table": fold = .partiallyOpen
        case "none": fold = .none
        default: return nil
        }
        let angle = parts.count > 1 ? Double(parts[1]) : Self.defaultAngle(for: fold)
        return (fold, angle)
    }

    static func defaultAngle(for fold: Fold) -> Double? {
        switch fold {
        case .closed: return 0
        case .partiallyOpen: return 100
        case .open: return 180
        case .none: return nil
        }
    }
}

/// Feeds `DevicePosture` from the hinge on iOS 27.1 and later; does nothing earlier.
struct HingeObserver: ViewModifier {
    let posture: DevicePosture

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .onHingeChange { _, new in posture.apply(new.hinge, from: "onHingeChange") }
                // `onHingeChange` reports changes; the UIKit interaction also reports the posture
                // the app launched in.
                .background(HingeInteractionReader(posture: posture).frame(width: 0, height: 0))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
extension DevicePosture {
    func apply(_ hinge: DeviceHinge?, from source: String) {
        reports[source, default: 0] += 1
        guard let hinge else { return hingeUnavailable() }
        let fold: Fold = hinge.status == .closed ? .closed : hinge.status == .fullyOpen ? .open : .partiallyOpen
        update(fold: fold, angle: hinge.angle.degrees)
    }

    func apply(_ hinge: UIHinge?) {
        reports["UIHingeInteraction", default: 0] += 1
        guard let hinge else { return hingeUnavailable() }
        let fold: Fold
        switch hinge.status {
        case .closed: fold = .closed
        case .fullyOpen: fold = .open
        case .partiallyOpen: fold = .partiallyOpen
        default: fold = .none
        }
        update(fold: fold, angle: Double(hinge.angle) * 180 / .pi)
    }
}

@available(iOS 27.1, *)
private struct HingeInteractionReader: UIViewRepresentable {
    let posture: DevicePosture

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.addInteraction(UIHingeInteraction { [posture] _, update in
            posture.apply(update.hinge)
        })
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
