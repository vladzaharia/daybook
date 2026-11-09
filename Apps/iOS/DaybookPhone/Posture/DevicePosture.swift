import Observation
import SwiftUI
import UIKit

/// How the iPhone Duo is folded, for layouts to follow: closed is the pocket recorder in portrait, open is the
/// two-page notebook, partly open while recording is table mode (docs/iphone.md). Phones without a hinge report
/// `.none` and get the closed layout, or the open one at regular width. Turned on its side, a closed Duo stays a
/// single-column pocket layout; an open device uses the two-page notebook.

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
    /// The window's vertical size class, as the root reads it (`HingeObserver`): compact while an iPhone
    /// is on its side. `layout` follows it.
    var heightClass: UserInterfaceSizeClass?
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

    /// The layout for the posture and the window. `verticalSizeClass` is the window's height class; nil reads the
    /// one the root reported (`heightClass`). Compact height is two pages unless the Duo is closed, where the
    /// cover stays a single-column pocket layout rather than showing the cramped two-page notebook.
    func layout(
        isRecording: Bool, horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass? = nil
    ) -> Layout {
        let onItsSide = (verticalSizeClass ?? heightClass) == .compact
        switch fold {
        case .open: return .notebook
        case .partiallyOpen: return isRecording ? .table : .notebook
        case .closed: return .pocket
        case .none: return horizontalSizeClass == .regular || onItsSide ? .notebook : .pocket
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
        guard let index = arguments.firstIndex(where: keys.contains),
            arguments.indices.contains(index + 1)
        else { return nil }
        let parts = arguments[index + 1].lowercased().split(separator: ":", maxSplits: 1).map(
            String.init)
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

/// Feeds `DevicePosture` from the hinge on iOS 27.1 and later, and from the window's height class
/// everywhere (an iPhone on its side).
struct HingeObserver: ViewModifier {
    let posture: DevicePosture
    @Environment(\.verticalSizeClass) private var heightClass

    func body(content: Content) -> some View {
        hinge(content)
            .onChange(of: heightClass, initial: true) { _, heightClass in
                if posture.heightClass != heightClass { posture.heightClass = heightClass }
            }
            .task {
                // `--interface-orientation landscape` (debug): the library on its side, as the person would
                // turn it (the simulator has no command to). The scene takes it once it allows landscape.
                guard
                    let orientation = LaunchOptions.value(
                        after: "--interface-orientation", in: CommandLine.arguments)
                else { return }
                try? await Task.sleep(for: .seconds(1.5))
                InterfaceOrientation.apply(orientation)
            }
    }

    @ViewBuilder
    private func hinge(_ content: Content) -> some View {
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
        let fold: Fold =
            hinge.status == .closed ? .closed : hinge.status == .fullyOpen ? .open : .partiallyOpen
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
        view.addInteraction(
            UIHingeInteraction { [posture] _, update in
                posture.apply(update.hinge)
            })
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
