import DaybookDesign
import SwiftUI

// DaybookUI holds the views both apps show over the same models (docs/architecture.md, "Layers"). It
// can't use size classes to adapt: they don't exist on the Mac, and the open iPhone Duo reports
// regular even though each of its pages is a phone-sized column. A surface says instead what layout
// it is (`SurfaceLayout`) and how dense (`DaybookDensity`), once at its root (`daybookSurface`).

/// The shape a surface takes, whatever the device.
public enum SurfaceLayout: Hashable, Sendable {
    /// Short: Floating Notes under 380 pt tall. The phase, the clock, the newest caption, the controls.
    case compact
    /// One column: the iPhone in the hand (402–466 pt), a page of the open Duo, Floating Notes, a narrow
    /// Mac window.
    case column
    /// Two pages: the open iPhone Duo split at its crease (`crease`, from the leading edge), or a window
    /// wide enough for two pages split in the middle (no crease).
    case spread(crease: CGFloat?)
    /// Partly open, standing on a table while recording: glanceable from across it.
    case stage

    /// Below this height Floating Notes is compact.
    public static let compactBelow: CGFloat = 380

    /// Floating Notes' layout at a panel size: compact when short, two pages when wide enough for two,
    /// one column otherwise.
    public static func floatingNotes(size: CGSize) -> SurfaceLayout {
        if size.height < compactBelow { return .compact }
        if size.width >= PageSpreadLayout.minimumWidth { return .spread(crease: nil) }
        return .column
    }

    public var isSpread: Bool {
        if case .spread = self { return true }
        return false
    }

    /// Where the spread folds, when it folds on a physical crease.
    public var crease: CGFloat? {
        if case .spread(let crease) = self { return crease }
        return nil
    }
}

/// The sizes the shared components take on a surface: one value per density, so a view never picks
/// `.phone` or `.mac` metrics by hand.
public struct PlatformMetrics: Equatable, Sendable {
    public var density: DaybookDensity
    public var status: StatusMetrics
    public var chip: StatusChip.Metrics
    public var phase: RecordingPhaseLabel.Metrics
    public var meter: RollingLevelMeter.Metrics
    /// Live captions in their usual place: the iPhone's strip, Floating Notes' two lines on the Mac.
    public var captions: CaptionStripStyle

    public init(density: DaybookDensity, status: StatusMetrics, chip: StatusChip.Metrics, phase: RecordingPhaseLabel.Metrics,
                meter: RollingLevelMeter.Metrics, captions: CaptionStripStyle) {
        self.density = density
        self.status = status
        self.chip = chip
        self.phase = phase
        self.meter = meter
        self.captions = captions
    }

    /// A density's metrics, as the components choose them for themselves.
    public static func `for`(_ density: DaybookDensity) -> PlatformMetrics {
        PlatformMetrics(density: density, status: .for(density), chip: .for(density), phase: .for(density), meter: .for(density),
                        captions: density == .touch ? .strip : .panel)
    }
}

extension EnvironmentValues {
    /// The surface's layout (`SurfaceLayout`); one column unless a surface says otherwise.
    @Entry public var surfaceLayout: SurfaceLayout = .column
    /// The shared components' sizes on this surface (`PlatformMetrics`).
    @Entry public var platformMetrics: PlatformMetrics = .for(.platformDefault)
}

extension View {
    /// Says once, at a surface's root, what layout it is and how dense, for every shared view under it.
    public func daybookSurface(_ layout: SurfaceLayout, density: DaybookDensity) -> some View {
        environment(\.surfaceLayout, layout)
            .environment(\.daybookDensity, density)
            .environment(\.platformMetrics, .for(density))
    }
}
