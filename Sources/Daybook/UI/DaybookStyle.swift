import AppKit
import DaybookDesign
import SwiftUI

// The Mac's own styling, on top of the shared design (docs/interface.md, "Design tokens"). Views name the tokens
// as DaybookDesign does (`DaybookPalette`, `DaybookSpacing`, `DaybookMotion`, `DaybookFont`); what's here is only what
// the Mac has and the iPhone doesn't: Make Text Bigger's steps, its bars and boxes, and the sidebar's labels.

// MARK: - Type

/// View › Make Text Bigger's steps for the reading surface (`readingScale`, DaybookDesign).
enum ReadingScale {
    /// The body's size at each step; Actual Size is the 15 pt body.
    static let steps: [CGFloat] = [13, 14, 15, 17, 19, 21, 23].map { $0 / DaybookFont.body.size(.window) }
    static func bigger(_ value: Double) -> Double { Double(steps.first { $0 > CGFloat(value) + 0.001 } ?? steps.last!) }
    static func smaller(_ value: Double) -> Double { Double(steps.last { $0 < CGFloat(value) - 0.001 } ?? steps.first!) }
}

// MARK: - Bars and boxes

extension View {
    /// Pins a bar to the bottom edge, letting content scroll beneath it on macOS 26.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }

    /// The quiet filled box used by status lines that need the person, notices, and quotes.
    func quietBox(cornerRadius: CGFloat = 8) -> some View {
        background(DaybookPalette.quietFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Liquid Glass on macOS 26 and later; a material surface with a hairline and shadow on macOS 15. The call
    /// prompt's card sits on it.
    @ViewBuilder
    func glassSurface(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

// MARK: - Components

/// Sidebar rows: every symbol centred in one column sized like the system sidebar's icons,
/// then a gap a little wider than SwiftUI's default. Follows System Settings › Sidebar icon size.
struct SidebarLabelStyle: LabelStyle {
    @Environment(\.sidebarRowSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        let (column, symbol, gap): (CGFloat, CGFloat, CGFloat) = switch size {
        case .small: (16, 12, 6)
        case .large: (24, 18, 8)
        default: (20, 15, 7)
        }
        HStack(spacing: gap) {
            configuration.icon
                .font(.system(size: symbol, weight: .regular))
                .frame(width: column, alignment: .center)
            configuration.title
        }
    }
}

extension LabelStyle where Self == SidebarLabelStyle {
    static var sidebar: SidebarLabelStyle { SidebarLabelStyle() }
}
