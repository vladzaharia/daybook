import SwiftUI

// The button family for content (docs/interface.md, "Colour has a job"). System blue never appears on
// paper: a text action is `.daybookLink`, an action that needs a little more presence is
// `.daybookTinted`, and the one action a box leads with is `.daybookProminent`. Each dims when
// disabled, takes the link pointer and a hover lift on the Mac, and keeps a 44 pt target under touch.

/// A text link in content: `Ink.link`, no underline, a little brighter on hover. Replaces
/// `.buttonStyle(.link)` (system blue) and `.borderless` links.
public struct DaybookLinkStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { DaybookLinkLabel(configuration: configuration) }
}

extension ButtonStyle where Self == DaybookLinkStyle {
    public static var daybookLink: DaybookLinkStyle { .init() }
}

/// What a button looks like while it can't be used, pressed, or under the pointer.
enum ButtonFace {
    static let disabledOpacity: Double = 0.45
    static let pressedOpacity: Double = 0.6

    static func opacity(enabled: Bool, pressed: Bool) -> Double {
        !enabled ? disabledOpacity : pressed ? pressedOpacity : 1
    }
}

/// Hover state lives in a view: a `ButtonStyle` isn't one, so `@State` on it never updates.
private struct DaybookLinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(DaybookPalette.Ink.link)
            .opacity(ButtonFace.opacity(enabled: isEnabled, pressed: configuration.isPressed))
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .contentShape(Rectangle())
            .daybookHitTarget()
            .pointerAndHover(enabled: isEnabled, hovering: $hovering)
    }
}

/// An action on a quiet accent wash: Import, Restore, Upgrade, a device's actions. Text in `Ink.onWash`,
/// which keeps 4.5:1 on the 14% wash.
public struct DaybookTintedStyle: ButtonStyle {
    public enum Shape: Sendable { case capsule, rounded }
    let shape: Shape

    public init(shape: Shape = .capsule) { self.shape = shape }

    public func makeBody(configuration: Configuration) -> some View {
        FilledButtonFace(configuration: configuration, shape: shape, prominent: false)
    }
}

/// The one action a box leads with: white on the prominent fill (4.5:1 or better in every appearance).
public struct DaybookProminentStyle: ButtonStyle {
    let shape: DaybookTintedStyle.Shape

    public init(shape: DaybookTintedStyle.Shape = .capsule) { self.shape = shape }

    public func makeBody(configuration: Configuration) -> some View {
        FilledButtonFace(configuration: configuration, shape: shape, prominent: true)
    }
}

extension ButtonStyle where Self == DaybookTintedStyle {
    public static var daybookTinted: DaybookTintedStyle { .init() }
    public static func daybookTinted(shape: DaybookTintedStyle.Shape) -> DaybookTintedStyle { .init(shape: shape) }
}

extension ButtonStyle where Self == DaybookProminentStyle {
    public static var daybookProminent: DaybookProminentStyle { .init() }
    public static func daybookProminent(shape: DaybookTintedStyle.Shape) -> DaybookProminentStyle { .init(shape: shape) }
}

private struct FilledButtonFace: View {
    let configuration: ButtonStyleConfiguration
    let shape: DaybookTintedStyle.Shape
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.daybookDensity) private var density
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    var body: some View {
        let touch = density == .touch
        configuration.label
            .foregroundStyle(prominent ? Color.white : DaybookPalette.Ink.onWash)
            .padding(.horizontal, touch ? 14 : 10)
            .padding(.vertical, touch ? 7 : 4)
            .frame(minHeight: touch ? TouchTarget.side : nil)
            .background(prominent ? DaybookPalette.prominentFill : DaybookPalette.accentWash, in: background)
            .overlay {
                if contrast == .increased && !prominent { background.stroke(DaybookPalette.Ink.onWash.opacity(0.6), lineWidth: 1).padding(0.5) }
            }
            .contentShape(background)
            .opacity(ButtonFace.opacity(enabled: isEnabled, pressed: configuration.isPressed))
            .brightness(hovering && isEnabled ? (prominent ? 0.04 : 0.03) : 0)
            .pointerAndHover(enabled: isEnabled, hovering: $hovering)
    }

    private var background: AnyShape {
        switch shape {
        case .capsule: return AnyShape(DaybookRadius.chip)
        case .rounded: return AnyShape(DaybookRadius.shape(DaybookRadius.row + 2))
        }
    }
}

extension View {
    /// On the Mac, the link pointer over something enabled and a hover state; nothing under touch.
    @ViewBuilder
    func pointerAndHover(enabled: Bool, hovering: Binding<Bool>) -> some View {
        #if os(macOS)
        self.pointerStyle(enabled ? .link : nil)
            .onHover { hovering.wrappedValue = $0 }
            .animation(DaybookMotion.hover, value: hovering.wrappedValue)
        #else
        self
        #endif
    }
}
