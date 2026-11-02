import SwiftUI

extension View {
    /// Animates `value` with `animation`, or a short fade (`DaybookMotion.reduced`) under Reduce Motion.
    public func daybookMotion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(DesignMotion(animation: animation, value: value))
    }

    /// Inserts and removes the view with `transition`, or with a fade under Reduce Motion: nothing
    /// slides, scales, or moves then.
    public func daybookTransition(_ transition: AnyTransition) -> some View {
        modifier(DesignTransition(transition: transition))
    }

    /// Bounces the symbol once each time `value` changes, so an action made without looking is felt
    /// (a bookmark landing). Still under Reduce Motion.
    public func daybookBounce<Value: Equatable>(value: Value) -> some View {
        modifier(DesignBounce(value: value))
    }

    /// A soft halo for neon in Dark Mode only. Light Mode, Increase Contrast, and Reduce Transparency
    /// get none, because there it reads as blur rather than light. Up to 4 pt it's one shadow; larger,
    /// a second, wider and fainter one follows it (the play button, the mark).
    public func daybookGlow(_ color: Color, radius: CGFloat = 4) -> some View {
        modifier(DesignGlow(color: color, radius: radius))
    }

    /// Under touch, a 44 × 44 pt target around something small (a remove button's glyph, a text link)
    /// without making its row any taller; in the window and the panel, nothing. Put it on a button's label.
    public func daybookHitTarget() -> some View {
        modifier(HitTarget())
    }

    /// `daybookHitTarget()` for a control right after something that does something else (a tag's ×, after the
    /// tag's name): its 44 × 44 pt target reaches at most `leading` points before it, and the rest after it.
    public func daybookHitTarget(leadingAtMost leading: CGFloat) -> some View {
        modifier(HitTarget(leadingLimit: leading))
    }
}

private struct DesignMotion<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(DaybookMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct DesignTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

private struct DesignBounce<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, options: .nonRepeating, value: value)
        }
    }
}

/// The one glow curve (`daybookGlow`).
enum GlowCurve {
    /// Each shadow as (opacity, radius); none when the halo would read as blur.
    static func shadows(radius: CGFloat, dark: Bool, standardContrast: Bool, reduceTransparency: Bool) -> [(opacity: Double, radius: CGFloat)] {
        guard dark, standardContrast, !reduceTransparency else { return [] }
        return radius <= 4 ? [(0.6, radius)] : [(0.75, radius), (0.35, radius * 2.5)]
    }
}

private struct DesignGlow: ViewModifier {
    let color: Color
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shadows = GlowCurve.shadows(radius: radius, dark: scheme == .dark, standardContrast: contrast == .standard,
                                        reduceTransparency: reduceTransparency)
        switch shadows.count {
        case 1: content.shadow(color: color.opacity(shadows[0].opacity), radius: shadows[0].radius)
        case 2:
            content.shadow(color: color.opacity(shadows[0].opacity), radius: shadows[0].radius)
                .shadow(color: color.opacity(shadows[1].opacity), radius: shadows[1].radius)
        default: content
        }
    }
}

/// The smallest target a finger hits reliably.
enum TouchTarget {
    static let side: CGFloat = 44

    /// How far a target of `size` reaches past its own edges on each side to make 44 × 44.
    static func outset(for size: CGSize) -> (horizontal: CGFloat, vertical: CGFloat) {
        (max(0, (side - size.width) / 2), max(0, (side - size.height) / 2))
    }

    /// The same 44 × 44, reaching at most `limit` past its leading edge and the rest past its trailing one; nil
    /// `limit` reaches evenly.
    static func outset(for size: CGSize, leadingAtMost limit: CGFloat?) -> (leading: CGFloat, trailing: CGFloat, vertical: CGFloat) {
        let even = outset(for: size)
        let leading = min(even.horizontal, max(0, limit ?? even.horizontal))
        return (leading, 2 * even.horizontal - leading, even.vertical)
    }
}

private struct HitTarget: ViewModifier {
    var leadingLimit: CGFloat?
    @Environment(\.daybookDensity) private var density
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        if density == .touch {
            let outset = TouchTarget.outset(for: size, leadingAtMost: leadingLimit)
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                // Grown for hit-testing, then given back, so the layout keeps the content's own size.
                .padding(.leading, outset.leading)
                .padding(.trailing, outset.trailing)
                .padding(.vertical, outset.vertical)
                .contentShape(Rectangle())
                .padding(.leading, -outset.leading)
                .padding(.trailing, -outset.trailing)
                .padding(.vertical, -outset.vertical)
        } else {
            content
        }
    }
}
