import AppKit
import DaybookKit
import SwiftUI
import XCTest
@testable import DaybookDesign

/// The shared palette's values and what they promise: every ink keeps 4.5:1 on the surface it's drawn on
/// (docs/interface.md, principle 5), in Light and Dark and with Increase Contrast.
final class DesignTokenTests: XCTestCase {
    private typealias Shade = DaybookPalette.Shade

    /// The four appearances a shade has, with names for failure messages.
    private let appearances: [(name: String, dark: Bool, contrast: Bool)] = [
        ("light", false, false), ("dark", true, false), ("light, Increase Contrast", false, true), ("dark, Increase Contrast", true, true)
    ]

    private func contrast(_ ink: DaybookShade, on surface: (Bool, Bool) -> UInt32, _ dark: Bool, _ more: Bool) -> Double {
        DaybookContrast.ratio(ink.hex(dark: dark, increasedContrast: more), surface(dark, more))
    }

    /// The quaternary system fill both platforms put under chips and cards, flattened onto paper.
    private func quietFill(over paper: UInt32, dark: Bool) -> UInt32 {
        DaybookContrast.flattened(.quiet, over: paper, dark: dark, increasedContrast: false)
    }

    // MARK: Values

    func testTheCoreTokensKeepTheirValues() {
        XCTAssertEqual(Shade.all.count, 20, "The twenty tokens each app once copied")
        XCTAssertEqual(Shade.accent.variants, [0x00806F, 0x00A3A0, 0x005F52, 0x5FE3D4])
        XCTAssertEqual(Shade.link.variants, [0x00796B, 0x34D9C3, 0x005F52, 0x5FE3D4])
        XCTAssertEqual(Shade.paper.variants, [0xFDFCFA, 0x18181B, 0xFFFFFF, 0x000000])
        XCTAssertEqual(Shade.bookmark.variants, [0xA86400, 0xFFD23F, 0x8A5200, 0xFFDF70])
        XCTAssertEqual(Shade.speakers.map(\.light), [0x0369A1, 0xA21CAF, 0x15803D, 0xC2410C, 0x0E7490, 0xBE123C], "Tailwind 700s")
        XCTAssertEqual(Shade.speakers.map(\.dark), [0x7DD3FC, 0xF0ABFC, 0x86EFAC, 0xFDBA74, 0x67E8F9, 0xFDA4AF], "Tailwind 300s")
        XCTAssertEqual(Shade.ownerText.map(\.light), [0x075985, 0x86198F, 0x166534, 0x9A3412, 0x155E75, 0x9F1239], "Tailwind 800s")
        XCTAssertEqual(Shade.ownerText.map(\.dark), Shade.speakers.map(\.dark))
        XCTAssertEqual(Shade.onWash.variants, [0x006B5E, 0x34D9C3, 0x005F52, 0x5FE3D4])
        XCTAssertEqual(Shade.bookmarkCount.light, 0x8A5200)
        XCTAssertEqual(Shade.liveGlyph.light, Shade.link.light, "Link ink in Light Mode, where mint is too faint")
        XCTAssertEqual(Shade.liveGlyph.dark, Shade.neonMint.dark, "Neon mint in Dark Mode")
        XCTAssertEqual(Shade.every.count, 20 + Shade.roles.count + 6 + 6 + 6, "Core, roles, speakers, owners, the Live Activity's")
    }

    func testShadeKeepsStandardValuesWithoutContrastOnes() {
        let shade = DaybookShade(light: 0x111111, dark: 0x222222)
        XCTAssertEqual(shade.hex(dark: false, increasedContrast: true), 0x111111)
        XCTAssertEqual(shade.hex(dark: true, increasedContrast: true), 0x222222)
        XCTAssertEqual(Shade.paper.hex(dark: true, increasedContrast: true), 0x000000)
    }

    func testEveryShadeResolvesToItsValuesInLightAndDark() {
        func hex(_ color: NSColor, _ appearance: NSAppearance.Name) -> UInt32 {
            var value: UInt32 = 0
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                guard let srgb = color.usingColorSpace(.sRGB) else { return }
                let r = UInt32((srgb.redComponent * 255).rounded()), g = UInt32((srgb.greenComponent * 255).rounded())
                value = r << 16 | g << 8 | UInt32((srgb.blueComponent * 255).rounded())
            }
            return value
        }
        for (name, shade) in Shade.every {
            XCTAssertEqual(hex(shade.nsColor, .aqua), shade.light, "\(name) light, as AppKit draws it")
            XCTAssertEqual(hex(shade.nsColor, .darkAqua), shade.dark, "\(name) dark, as AppKit draws it")
            XCTAssertEqual(hex(NSColor(shade.color), .aqua), shade.light, "\(name) light, as SwiftUI draws it")
            XCTAssertEqual(hex(NSColor(shade.color), .darkAqua), shade.dark, "\(name) dark, as SwiftUI draws it")
        }
        #if DEBUG
        // The debug switch snapshots use draws every shade's Increase Contrast value.
        DaybookShade.simulatesIncreasedContrast = true
        defer { DaybookShade.simulatesIncreasedContrast = false }
        for (name, shade) in Shade.every {
            XCTAssertEqual(hex(shade.nsColor, .aqua), shade.lightContrast, "\(name) light with Increase Contrast")
            XCTAssertEqual(hex(shade.nsColor, .darkAqua), shade.darkContrast, "\(name) dark with Increase Contrast")
        }
        #endif
    }

    // MARK: Contrast

    func testTheInkScaleReadsOnPaper() {
        let paper: (Bool, Bool) -> UInt32 = { Shade.paper.hex(dark: $0, increasedContrast: $1) }
        for (name, ink) in [("title", Shade.title), ("body", Shade.body), ("secondary", Shade.secondary), ("meta", Shade.meta),
                            ("link", Shade.link), ("warning", Shade.warning), ("error", Shade.error)] {
            for appearance in appearances {
                XCTAssertGreaterThanOrEqual(contrast(ink, on: paper, appearance.dark, appearance.contrast), 4.5, "\(name) on paper, \(appearance.name)")
            }
        }
    }

    func testTextOnAnAccentWashKeepsFourAndAHalf() {
        for appearance in appearances {
            let paper = Shade.paper.hex(dark: appearance.dark, increasedContrast: appearance.contrast)
            let accent = Shade.accent.hex(dark: appearance.dark, increasedContrast: appearance.contrast)
            let ink = Shade.onWash.hex(dark: appearance.dark, increasedContrast: appearance.contrast)
            // A tag chip or tinted button: the 14% wash on paper.
            let chip = DaybookContrast.composite(accent, opacity: 0.14, over: paper)
            XCTAssertGreaterThanOrEqual(DaybookContrast.ratio(ink, chip), 4.5, "Tag chip, \(appearance.name)")
            // An action tile: a 12% wash over a card's quiet fill.
            let tile = DaybookContrast.composite(accent, opacity: 0.12, over: quietFill(over: paper, dark: appearance.dark))
            XCTAssertGreaterThanOrEqual(DaybookContrast.ratio(ink, tile), 4.5, "Action tile, \(appearance.name)")
        }
        // The reason for the token: link ink falls under 4.5:1 on the light wash.
        let lightChip = DaybookContrast.composite(Shade.accent.light, opacity: 0.14, over: Shade.paper.light)
        XCTAssertLessThan(DaybookContrast.ratio(Shade.link.light, lightChip), 4.5)
    }

    func testOwnerChipsKeepFourAndAHalfOnTheirSpeakersWash() {
        for (index, (speaker, owner)) in zip(Shade.speakers, Shade.ownerText).enumerated() {
            for appearance in appearances {
                let paper = Shade.paper.hex(dark: appearance.dark, increasedContrast: appearance.contrast)
                let wash = DaybookContrast.composite(speaker.hex(dark: appearance.dark, increasedContrast: appearance.contrast), opacity: 0.14, over: paper)
                let ratio = DaybookContrast.ratio(owner.hex(dark: appearance.dark, increasedContrast: appearance.contrast), wash)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Owner \(index), \(appearance.name)")
            }
        }
    }

    func testABookmarkCountReadsOnItsAmberPill() {
        for appearance in appearances {
            let paper = Shade.paper.hex(dark: appearance.dark, increasedContrast: appearance.contrast)
            let pill = DaybookContrast.composite(Shade.bookmark.hex(dark: appearance.dark, increasedContrast: appearance.contrast), opacity: 0.2, over: paper)
            let ratio = DaybookContrast.ratio(Shade.bookmarkCount.hex(dark: appearance.dark, increasedContrast: appearance.contrast), pill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Bookmark count, \(appearance.name)")
        }
    }

    func testASearchMatchKeepsDarkInkOnAnOpaqueShade() {
        for appearance in appearances {
            let ratio = contrast(Shade.onFind, on: { Shade.findHighlight.hex(dark: $0, increasedContrast: $1) }, appearance.dark, appearance.contrast)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Search match, \(appearance.name)")
        }
        // The iPhone's old mark: 45% system yellow over dark paper, with body ink, was under 4.5:1.
        let old = DaybookContrast.composite(0xFFD60A, opacity: 0.45, over: Shade.paper.dark)
        XCTAssertLessThan(DaybookContrast.ratio(Shade.body.dark, old), 4.5)
    }

    func testWarningWordsOnTheWarningWashKeepFourAndAHalf() {
        for appearance in appearances {
            let ratio = DaybookContrast.ratio(DaybookInkPair(ink: Shade.onAttention, wash: .attention), dark: appearance.dark,
                                              increasedContrast: appearance.contrast)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Attention chip, \(appearance.name)")
        }
        // The reason for the token: warning ink falls under 4.5:1 on the light wash.
        XCTAssertLessThan(DaybookContrast.ratio(DaybookInkPair(ink: Shade.warning, wash: .attention), dark: false, increasedContrast: false), 4.5)
    }

    func testEveryChipKindKeepsFourAndAHalfOnItsWash() {
        let tones: [StatusTone] = [.calm, .working, .linked, .recording, .attention]
        let kinds: [DaybookChip.Kind] = [.tag, .fact, .owner(nil)] + Shade.speakers.indices.map { .owner($0) } + tones.map { .status($0) }
        for kind in kinds {
            for filled in [true, false] {
                let colors = DaybookChip.colors(kind, filled: filled)
                if !filled { XCTAssertEqual(colors.wash, .none, "\(kind) without its capsule") }
                for appearance in appearances {
                    let ratio = DaybookContrast.ratio(colors, dark: appearance.dark, increasedContrast: appearance.contrast)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(kind)\(filled ? "" : " without its capsule"), \(appearance.name)")
                }
            }
        }
        // Red words on the quiet fill fall under 4.5:1, so a recording chip's red is its dot's.
        XCTAssertEqual(DaybookChip.colors(.status(.recording)).ink, Shade.secondary)
        XCTAssertLessThan(DaybookContrast.ratio(DaybookInkPair(ink: Shade.record, wash: .quiet), dark: false, increasedContrast: false), 4.5)
        XCTAssertEqual(DaybookChip.colors(.status(.attention)).ink, Shade.onAttention)
    }

    func testABoxsWordsKeepFourAndAHalfOnItsWash() {
        for kind in [AttentionKind.problem, .accent, .info] {
            for appearance in appearances {
                for (part, pair) in [("title", AttentionBoxLayout.title(for: kind)), ("message", AttentionBoxLayout.message(for: kind))] {
                    let ratio = DaybookContrast.ratio(pair, dark: appearance.dark, increasedContrast: appearance.contrast)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(kind) box's \(part), \(appearance.name)")
                }
            }
        }
        // A problem's title was warning ink, under 4.5:1 on its light wash.
        let problem = AttentionBoxLayout.wash(for: .problem)
        XCTAssertLessThan(DaybookContrast.ratio(DaybookInkPair(ink: Shade.warning, wash: problem), dark: false, increasedContrast: false), 4.5)
    }

    func testAWashResolvesToItsOpacityInEachAppearance() {
        func rgba(_ color: Color, _ appearance: NSAppearance.Name) -> (UInt32, CGFloat) {
            var value: (UInt32, CGFloat) = (0, 0)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let r = UInt32((srgb.redComponent * 255).rounded()), g = UInt32((srgb.greenComponent * 255).rounded())
                value = (r << 16 | g << 8 | UInt32((srgb.blueComponent * 255).rounded()), srgb.alphaComponent)
            }
            return value
        }
        let problem = rgba(AttentionBoxLayout.wash(for: .problem).color, .aqua)
        XCTAssertEqual(problem.0, Shade.warning.light)
        XCTAssertEqual(problem.1, 0.08, accuracy: 0.001)
        let dark = rgba(AttentionBoxLayout.wash(for: .problem).color, .darkAqua)
        XCTAssertEqual(dark.0, Shade.warning.dark)
        XCTAssertEqual(dark.1, 0.12, accuracy: 0.001)
        XCTAssertEqual(rgba(DaybookPalette.attentionFill, .aqua).1, 0.09, accuracy: 0.001)
        XCTAssertEqual(rgba(DaybookPalette.accentWash, .darkAqua).0, Shade.accent.dark)
        XCTAssertEqual(rgba(DaybookPalette.accentWash, .darkAqua).1, 0.14, accuracy: 0.001)
    }

    func testFilledLabelsKeepFourAndAHalfOnTheirFills() {
        for appearance in appearances {
            XCTAssertGreaterThanOrEqual(DaybookContrast.ratio(0xFFFFFF, Shade.prominentFill.hex(dark: appearance.dark, increasedContrast: appearance.contrast)), 4.5,
                                        "White on the prominent fill, \(appearance.name)")
            for (name, ink) in DaybookPalette.ActivityInk.named {
                let ratio = DaybookContrast.ratio(ink.label.hex(dark: appearance.dark, increasedContrast: appearance.contrast),
                                                  ink.fill.hex(dark: appearance.dark, increasedContrast: appearance.contrast))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Live Activity \(name), \(appearance.name)")
            }
        }
    }

    func testContrastArithmeticMatchesWCAG() {
        XCTAssertEqual(DaybookContrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.001)
        XCTAssertEqual(DaybookContrast.ratio(0x777777, 0x777777), 1, accuracy: 0.001)
        XCTAssertEqual(DaybookContrast.composite(0xFFFFFF, opacity: 0.5, over: 0x000000), 0x808080)
        XCTAssertEqual(DaybookContrast.composite(0x123456, opacity: 1, over: 0xFFFFFF), 0x123456)
    }

    // MARK: Time

    /// DaybookTime is what the widgets show; DaybookKit's TimeLabel is what both apps show. One rule.
    func testDaybookTimeReadsAsTimeLabelDoes() {
        for seconds in [-0.4, -1, -12.7, -15, 0, 0.6, 59.9, 60, 3599.9, 3600, 3661, .nan, .infinity, -.infinity] {
            XCTAssertEqual(DaybookTime.short(seconds), TimeLabel.short(seconds), "\(seconds)")
        }
        XCTAssertEqual(DaybookTime.short(-0.4), "0:00", "Less than a second before the start")
        XCTAssertEqual(DaybookTime.short(-15), "−0:15")
        XCTAssertEqual(DaybookTime.short(3600), "1:00:00")
        XCTAssertEqual(DaybookTime.short(.nan), "0:00")
    }

    // MARK: Glow, motion, targets

    func testOneGlowCurveForEveryNeon() {
        XCTAssertEqual(GlowCurve.shadows(radius: 3, dark: true, standardContrast: true, reduceTransparency: false).map(\.opacity), [0.6])
        let wide = GlowCurve.shadows(radius: 6, dark: true, standardContrast: true, reduceTransparency: false)
        XCTAssertEqual(wide.map(\.opacity), [0.75, 0.35], "Above 4 pt, a second fainter halo")
        XCTAssertEqual(wide.map(\.radius), [6, 15])
        XCTAssertTrue(GlowCurve.shadows(radius: 6, dark: false, standardContrast: true, reduceTransparency: false).isEmpty, "None in Light Mode")
        XCTAssertTrue(GlowCurve.shadows(radius: 6, dark: true, standardContrast: false, reduceTransparency: false).isEmpty, "None with Increase Contrast")
        XCTAssertTrue(GlowCurve.shadows(radius: 6, dark: true, standardContrast: true, reduceTransparency: true).isEmpty, "None with Reduce Transparency")
    }

    func testTheMotionSetAndItsReduceMotionFallbacks() {
        XCTAssertEqual(DaybookMotion.hover, .easeOut(duration: 0.12))
        XCTAssertEqual(DaybookMotion.fade, .easeOut(duration: 0.2))
        XCTAssertEqual(DaybookMotion.state, .snappy(duration: 0.25))
        XCTAssertEqual(DaybookMotion.tick, .snappy(duration: 0.3))
        XCTAssertEqual(DaybookMotion.scroll, .easeInOut(duration: 0.3))
        XCTAssertEqual(DaybookMotion.page, .easeInOut(duration: 0.35))
        XCTAssertEqual(DaybookMotion.pageTurn, .easeOut(duration: 0.15), "Summary and Transcript crossfade, on both apps")
        XCTAssertEqual(DaybookMotion.progress, .linear(duration: 0.2))
        XCTAssertEqual(DaybookMotion.dim, .easeInOut(duration: 0.6))
        XCTAssertEqual(DaybookMotion.reduced, .easeOut(duration: 0.15))
        XCTAssertEqual(DaybookMotion.hold, .seconds(1.5))
        XCTAssertEqual(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: true), DaybookMotion.reduced)
        XCTAssertEqual(DaybookMotion.resolved(DaybookMotion.state, reduceMotion: false), DaybookMotion.state)
        XCTAssertNil(DaybookMotion.scrollAnimation(reduceMotion: true), "Under Reduce Motion a scroll jumps")
        XCTAssertEqual(DaybookMotion.scrollAnimation(reduceMotion: false), DaybookMotion.scroll)
    }

    func testATouchTargetReachesFortyFourPoints() {
        let outset = TouchTarget.outset(for: CGSize(width: 12, height: 20))
        XCTAssertEqual(outset.horizontal, 16)
        XCTAssertEqual(outset.vertical, 12)
        let big = TouchTarget.outset(for: CGSize(width: 80, height: 50))
        XCTAssertEqual(big.horizontal, 0, "Already big enough")
        XCTAssertEqual(big.vertical, 0)

        // A tag's ×, 10 pt wide and 6 pt after the tag's name: its target stays off the name and reaches the rest
        // of the way after it.
        let after = TouchTarget.outset(for: CGSize(width: 10, height: 12), leadingAtMost: 6)
        XCTAssertEqual(after.leading, 6)
        XCTAssertEqual(after.trailing, 28)
        XCTAssertEqual(after.leading + 10 + after.trailing, 44, "still 44 pt wide")
        XCTAssertEqual(after.vertical, 16)
        let even = TouchTarget.outset(for: CGSize(width: 12, height: 20), leadingAtMost: nil)
        XCTAssertEqual(even.leading, 16)
        XCTAssertEqual(even.trailing, 16)
        XCTAssertEqual(TouchTarget.outset(for: CGSize(width: 40, height: 44), leadingAtMost: 6).leading, 2, "never more than it needs")
        XCTAssertEqual(TouchTarget.outset(for: CGSize(width: 10, height: 12), leadingAtMost: -3).trailing, 34, "a limit under zero reaches nothing before it")
    }

    func testButtonsDimWhenDisabledAndPressed() {
        XCTAssertEqual(ButtonFace.opacity(enabled: false, pressed: false), 0.45)
        XCTAssertEqual(ButtonFace.opacity(enabled: true, pressed: true), 0.6)
        XCTAssertEqual(ButtonFace.opacity(enabled: true, pressed: false), 1)
    }

    // MARK: Type, radii, tiles

    func testEachTypeRoleHasOneFontPerDensity() {
        XCTAssertEqual(DaybookFont.body.size(.window), 15)
        XCTAssertEqual(DaybookFont.docTitle.size(.window), 30)
        XCTAssertEqual(DaybookFont.docTitle.size(.panel), 17, "Floating Notes' title")
        XCTAssertEqual(DaybookFont.sheetTitle.size(.window), 22)
        XCTAssertEqual(DaybookFont.marginTime.size(.window), 12, "So 1:02:03 fits the margin")
        XCTAssertEqual(DaybookFont.time.size(.window), 12)
        XCTAssertEqual(DaybookFont.marginTime.size(.panel), 11, "Floating Notes' lane keeps its size")
        XCTAssertEqual(DaybookFont.body.size(.panel), 13)
        XCTAssertEqual(DaybookFont.body.textStyle, .body)
        XCTAssertEqual(DaybookFont.rowTitle.textStyle, .headline)
        XCTAssertEqual(DaybookFont.sheetTitle.design, .serif, "The sheet title is New York; a row's title is SF")
        XCTAssertEqual(DaybookFont.rowTitle.design, .default)
        XCTAssertEqual(DaybookFont.marginTime.textStyle, .caption2)
        XCTAssertTrue(DaybookFont.body.isReading)
        XCTAssertFalse(DaybookFont.status.isReading, "Chrome text never scales")
        XCTAssertTrue(DaybookFont.allCases.allSatisfy { $0.design == .default || $0 == .docTitle || $0 == .sheetTitle }, "New York for titles only")
        XCTAssertEqual(DaybookFont.bodyLineSpacing(.window), 6, "15 pt body on a 24 pt line")
        XCTAssertEqual(DaybookFont.bodyLineSpacing(.window, scale: 2), 12)
        XCTAssertEqual(DaybookFont.bodyLineSpacing(.panel), 5)
        XCTAssertEqual(DaybookFont.bodyLineSpacing(.touch), 4)
        XCTAssertEqual(DaybookFont.ledeLineSpacing(.window), 4, "19 pt lede on a 26 pt line")
        XCTAssertEqual(DaybookFont.ledeLineSpacing(.touch), DaybookFont.bodyLineSpacing(.touch))
        XCTAssertEqual(DaybookDensity.platformDefault, .window)
    }

    /// The window's page reads as a document: the title over a lede, then headings that outrank the paragraphs under
    /// them, each a step above the next. Floating Notes keeps its smaller sizes; under touch Dynamic Type sets them.
    func testThePagesHierarchyRunsTitleLedeHeadingBody() {
        let window = [DaybookFont.docTitle, .lede, .heading, .body].map { $0.size(.window) }
        XCTAssertEqual(window, [30, 19, 17, 15])
        XCTAssertEqual(window, window.sorted(by: >), "Each role outranks the next")
        XCTAssertEqual(DaybookFont.lede.size(.panel), 16)
        XCTAssertEqual(DaybookFont.heading.size(.panel), 15)
        XCTAssertEqual(DaybookFont.heading.weight, .semibold)
        XCTAssertEqual(DaybookFont.lede.weight, .regular)
        XCTAssertEqual(DaybookFont.lede.textStyle, .title3)
        XCTAssertEqual(DaybookFont.heading.textStyle, .headline)
    }

    func testRadiiAndTilesHaveOneSizeEach() {
        XCTAssertEqual([DaybookRadius.row, DaybookRadius.box, DaybookRadius.card, DaybookRadius.control, DaybookRadius.panel], [6, 12, 16, 20, 26])
        XCTAssertEqual(DaybookTileSize.row.side(scale: 1), 30)
        XCTAssertEqual(DaybookTileSize.row.side(scale: 3), 42, "Grows with Dynamic Type up to its limit")
        XCTAssertEqual(DaybookTileSize.card.side(scale: 1.2), 38.4, accuracy: 0.001)
        XCTAssertEqual(DaybookTileSize.header.side(scale: 2), 56 * 1.35, accuracy: 0.001)
    }

    func testComponentsTakeTheirDensitysMetrics() {
        XCTAssertEqual(StatusMetrics.for(.touch), .phone)
        XCTAssertEqual(StatusMetrics.for(.window), .mac)
        XCTAssertEqual(StatusMetrics.for(.panel), .mac)
        XCTAssertEqual(StatusChip.Metrics.for(.touch), .phone)
        XCTAssertEqual(StatusChip.Metrics.for(.panel), .mac)
        XCTAssertEqual(RecordingPhaseLabel.Metrics.for(.touch), .phone)
        XCTAssertEqual(RecordingPhaseLabel.Metrics.for(.panel), .panel)
        XCTAssertEqual(RollingLevelMeter.Metrics.for(.panel), .panel)
        XCTAssertEqual(RollingLevelMeter.Metrics.for(.touch), .phone)
    }

    /// The recorder's labels are sentence case, semibold, on both apps: the words are drawn as they're written, never
    /// turned into tracked capitals, so "Recording" sets narrower than "RECORDING" would.
    @MainActor
    func testRecorderLabelsKeepTheCaseOfTheirWords() {
        func width(_ view: some View) -> CGFloat { NSHostingView(rootView: view.fixedSize()).fittingSize.width }
        for metrics in [RecordingPhaseLabel.Metrics.panel, .phone] {
            XCTAssertLessThan(width(RecordingPhaseLabel(.recording, title: "Recording", metrics: metrics)),
                              width(RecordingPhaseLabel(.recording, title: "RECORDING", metrics: metrics)) - 4)
            XCTAssertLessThan(width(RecordingPhaseLabel(.saved, title: "Saved", detail: "18 min", metrics: metrics)),
                              width(RecordingPhaseLabel(.saved, title: "SAVED", detail: "18 min", metrics: metrics)) - 2)
        }
        let captions = LiveCaptionStrip(lines: [], status: nil, style: .panel)
        let capitals = LiveCaptionStrip(lines: [], status: nil, style: .panel, label: "LIVE CAPTIONS · TENTATIVE")
        XCTAssertLessThan(width(captions), width(capitals) - 10, "\"Live captions · tentative\", as written")
    }

    // MARK: Progress, boxes

    func testProgressStepsFromADotToTheTrack() {
        XCTAssertEqual(WorkProgress.fillWidth(fraction: 0, track: 100, height: 2), 2, "A dot before any progress")
        XCTAssertEqual(WorkProgress.fillWidth(fraction: 0.4, track: 100, height: 2), 40)
        XCTAssertEqual(WorkProgress.fillWidth(fraction: 1.7, track: 100, height: 4), 100)
        XCTAssertEqual(WorkProgress.fillWidth(fraction: .nan, track: 100, height: 4), 4)
        XCTAssertEqual(WorkProgress.fillWidth(fraction: 0.5, track: 1, height: 4), 1, "Never past its track")
        XCTAssertEqual(WorkProgress.Style.line.height, 2)
        XCTAssertEqual(WorkProgress.Style.bar.height, 4)
    }

    func testABoxStacksItsActionsWhenNarrowOrCompact() {
        XCTAssertFalse(AttentionBoxLayout.stacks(width: 640, compact: false, density: .window))
        XCTAssertFalse(AttentionBoxLayout.stacks(width: 400, compact: false, density: .window),
                       "In a window the words decide, by whether the title fits beside the actions")
        XCTAssertTrue(AttentionBoxLayout.stacks(width: 640, compact: true, density: .window))
        XCTAssertTrue(AttentionBoxLayout.stacks(width: 640, compact: false, density: .panel), "Floating Notes is always narrow")
        XCTAssertTrue(AttentionBoxLayout.stacks(width: 402, compact: false, density: .touch), "An iPhone: under the words")
        XCTAssertFalse(AttentionBoxLayout.stacks(width: 600, compact: false, density: .touch), "The open Duo as one page: beside them")
        XCTAssertTrue(AttentionBoxLayout.hugs(.window), "A window's box is as wide as what it says")
        XCTAssertFalse(AttentionBoxLayout.hugs(.touch))
        XCTAssertFalse(AttentionBoxLayout.hugs(.panel))
        XCTAssertEqual(AttentionBoxLayout.actionGap(.window), 16, "The actions follow the words")
        XCTAssertEqual(AttentionBoxLayout.symbol(for: .problem), "exclamationmark.triangle.fill")
    }

    func testDetailsSaysDetailsWithAnEllipsisOnTheMac() {
        XCTAssertEqual(DetailsButton.title, "Details…")
    }

    // MARK: Find, flow

    func testFindHighlightMarksEveryMatchInDarkInkOnTheFindShade() {
        let text = AttributedString("Beta date: keep the béta, then BETA again.")
        let marked = FindHighlight.mark(text, query: " beta ")
        typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
        typealias Foreground = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        let runs = marked.runs.filter { $0[Background.self] != nil }
        XCTAssertEqual(runs.count, 3, "Case and accents don't matter; the query is trimmed")
        for run in runs {
            XCTAssertEqual(run[Background.self], DaybookPalette.findHighlight)
            XCTAssertEqual(run[Foreground.self], DaybookPalette.Ink.onFind)
        }
        XCTAssertEqual(FindHighlight.matches(in: text, query: "beta").count, 3)
        XCTAssertEqual(FindHighlight.mark(text, query: "  "), text, "No query, no marks")
    }

    func testFlowWrapsAndGivesAnOverWideItemTheRowsWidth() {
        let layout = FlowLayout(spacing: 6, lineSpacing: 4)
        func item(_ width: CGFloat, _ height: CGFloat = 20) -> FlowLayout.Item {
            FlowLayout.Item { proposal in
                // Text: its ideal width unconstrained, wrapping into more lines when offered less.
                guard let offered = proposal.width, offered < width else { return CGSize(width: width, height: height) }
                return CGSize(width: offered, height: height * (width / max(offered, 1)).rounded(.up))
            }
        }
        let rows = layout.arrange([item(100), item(100), item(100)], width: 220)
        XCTAssertEqual(rows.map(\.indices), [[0, 1], [2]])
        XCTAssertEqual(rows[1].y, 24, "A line, then the line spacing")

        // A date wider than the page (a large text size): its own line, at the page's width, wrapped.
        let wide = layout.arrange([item(60), item(500), item(60)], width: 200)
        XCTAssertEqual(wide.map(\.indices), [[0], [1], [2]])
        XCTAssertEqual(wide[1].sizes[0].width, 200, "Never past the row")
        XCTAssertEqual(wide[1].sizes[0].height, 60, "Wrapped onto three lines instead")
        XCTAssertTrue(wide.allSatisfy { $0.width <= 200 })

        XCTAssertEqual(layout.arrange([item(100), item(100)], width: nil).map(\.indices), [[0, 1]], "No width: one row")
        XCTAssertEqual(layout.arrange([item(100), item(100)], width: .infinity).map(\.indices), [[0, 1]])
    }

    @MainActor
    func testLevelTrailKeepsTheNewestAndFallsFlat() {
        let trail = LevelTrail(capacity: 4)
        for value in [0.1, 0.2, 0.3, 0.4, 1.5] { trail.append(value) }
        XCTAssertEqual(trail.values, [0.2, 0.3, 0.4, 1], "Oldest first, clamped to 0...1")
        trail.append(.nan)
        XCTAssertEqual(trail.values.last, 0)
        trail.reset()
        XCTAssertEqual(trail.values, [0, 0, 0, 0])
    }
}
