import SwiftUI

/// The watch app's curves: the same ones as DaybookDesign's `DaybookMotion` (docs/interface.md, "Motion"), which the
/// watch app doesn't link (DaybookDesign is for iOS and macOS). The motion audit (MotionAuditTests) allows curves here
/// and in DaybookDesign only, so a view names a token and Reduce Motion is honoured in one place.
enum WatchMotion {
    /// A change of state: the record button turning into stop, a status line appearing (`DaybookMotion.state`).
    static let state = Animation.snappy(duration: 0.25)
    /// A figure following reports steadily, never eased: the level meter (`DaybookMotion.progress`).
    static let progress = Animation.linear(duration: 0.2)
    /// What every curve becomes under Reduce Motion (`DaybookMotion.reduced`).
    static let reduced = Animation.easeOut(duration: 0.15)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}
