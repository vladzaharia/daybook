import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI
import UIKit
import XCTest
@testable import DaybookPhone

/// The iPhone draws with the Mac's palette: every shade, and every colour DaybookPalette names, resolves to
/// its values through the traits in Light, Dark, and Increase Contrast (which the Mac's tests can't make).
@MainActor
final class DesignParityTests: XCTestCase {
    private typealias Shade = DaybookPalette.Shade

    private let appearances: [(name: String, style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast)] = [
        ("light", .light, .normal), ("dark", .dark, .normal), ("light, Increase Contrast", .light, .high), ("dark, Increase Contrast", .dark, .high)
    ]

    private func traits(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
    }

    private func hex(_ color: UIColor, _ traits: UITraitCollection) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    func testEveryShadeResolvesThroughTheTraitsInEveryAppearance() {
        for (name, shade) in Shade.every {
            for appearance in appearances {
                let traits = traits(appearance.style, appearance.contrast)
                let expected = shade.hex(dark: appearance.style == .dark, increasedContrast: appearance.contrast == .high)
                XCTAssertEqual(hex(shade.uiColor, traits), expected, "\(name), \(appearance.name), as UIKit draws it")
                XCTAssertEqual(hex(UIColor(shade.color), traits), expected, "\(name), \(appearance.name), as SwiftUI draws it")
            }
        }
    }

    func testThePalettesColoursResolveThroughTheTraits() {
        let pairs: [(String, Color, DaybookShade)] = [
            ("accent", DaybookPalette.accent, Shade.accent), ("prominentFill", DaybookPalette.prominentFill, Shade.prominentFill),
            ("paper", DaybookPalette.paper, Shade.paper), ("bookmark", DaybookPalette.bookmark, Shade.bookmark),
            ("neonMint", DaybookPalette.neonMint, Shade.neonMint), ("neonCyan", DaybookPalette.neonCyan, Shade.neonCyan),
            ("neonViolet", DaybookPalette.neonViolet, Shade.neonViolet), ("neonMagenta", DaybookPalette.neonMagenta, Shade.neonMagenta),
            ("playFill", DaybookPalette.playFill, Shade.playFill), ("onPlayFill", DaybookPalette.onPlayFill, Shade.onPlayFill),
            ("title", DaybookPalette.Ink.title, Shade.title), ("body", DaybookPalette.Ink.body, Shade.body),
            ("secondary", DaybookPalette.Ink.secondary, Shade.secondary), ("meta", DaybookPalette.Ink.meta, Shade.meta),
            ("faint", DaybookPalette.Ink.faint, Shade.faint), ("link", DaybookPalette.Ink.link, Shade.link),
            ("warning", DaybookPalette.Ink.warning, Shade.warning), ("error", DaybookPalette.Ink.error, Shade.error),
            ("record", DaybookPalette.Ink.record, Shade.record), ("recordFill", DaybookPalette.Ink.recordFill, Shade.recordFill)
        ]
        XCTAssertEqual(pairs.count, Shade.all.count, "Every core token is checked")
        var speakers = DaybookPalette.speakerInks.enumerated().map { ("speaker\($0.offset)", $0.element, Shade.speakers[$0.offset]) }
        speakers.append(("no speaker", DaybookPalette.speakerInk(nil), Shade.secondary))
        for appearance in appearances {
            let traits = traits(appearance.style, appearance.contrast)
            let dark = appearance.style == .dark, contrast = appearance.contrast == .high
            for (name, color, shade) in pairs + speakers {
                XCTAssertEqual(hex(UIColor(color), traits), shade.hex(dark: dark, increasedContrast: contrast), "\(name), \(appearance.name)")
            }
        }
    }

    /// The app's times are DaybookKit's (its own copy, which wrote "−0:00", is gone), and the widgets'
    /// DaybookTime reads the same.
    func testTheAppReadsTimesAsTheMacDoes() {
        XCTAssertEqual(TimeLabel.short(-0.4), "0:00", "Less than a second before the start")
        XCTAssertEqual(TimeLabel.short(-12.7), "−0:12")
        XCTAssertEqual(TimeLabel.short(3600), "1:00:00")
        for seconds in [-0.4, -1, -12.7, -15, 0, 59.9, 3600, .nan] {
            XCTAssertEqual(TimeLabel.short(seconds), DaybookTime.short(seconds), "\(seconds)")
            XCTAssertEqual(TimeLabel.short(seconds), DaybookKit.TimeLabel.short(seconds), "\(seconds)")
        }
        XCTAssertEqual(SpokenTime.format(-0.4), SpokenTime.format(0), "What's heard matches what's seen")
    }

    func testTheIPhoneIsTouchDensityWithItsOwnWords() {
        XCTAssertEqual(DaybookDensity.platformDefault, .touch)
        XCTAssertEqual(PlatformMetrics.for(.platformDefault).status, .phone)
        XCTAssertEqual(DetailsButton.title, "Details", "The iPhone's Details buttons have no ellipsis")
        XCTAssertEqual(ReadingContext.platform.thisDevice, "this iPhone")
        XCTAssertEqual(ReadingGeometry.gutters(density: .touch, hangs: false).leading, 20)
    }

    func testCopyingLocallyStaysOnThisIPhoneAndCanExpire() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let options = LocalCopy.options(expiresIn: .seconds(90), now: now)
        XCTAssertEqual(options[.localOnly] as? Bool, true, "Not to Universal Clipboard")
        XCTAssertEqual(options[.expirationDate] as? Date, now.addingTimeInterval(90))
        XCTAssertNil(LocalCopy.options(expiresIn: nil)[.expirationDate])
    }
}
