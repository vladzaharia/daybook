import SwiftUI

/// Work in progress: a capsule filled with the brand gradient, glowing cyan in Dark Mode. A row's line is
/// 2 pt (`.line`); a page's, Settings', or a download's bar is 4 pt (`.bar`). Its width comes from the
/// layout unless one is given.
///
/// It steps without animating, even inside an animation: progress arrives up to ten times a second,
/// and easing each step kept the window drawing frames for as long as a job ran (docs/interface.md,
/// "Behaviour worth knowing").
public struct WorkProgress: View {
    public struct Style: Hashable, Sendable {
        public var height: CGFloat
        public init(height: CGFloat) { self.height = height }
        /// A row's line, under or beside its words.
        public static let line = Style(height: 2)
        /// A page's, a setting's, or a download's bar.
        public static let bar = Style(height: 4)
    }

    /// Shorter than this, a line would read as a dot.
    public static let minimumWidth: CGFloat = 24

    private let fraction: Double
    private let style: Style
    private let width: CGFloat?

    public init(fraction: Double, style: Style = .bar, width: CGFloat? = nil) {
        self.fraction = fraction
        self.style = style
        self.width = width
    }

    /// 0...1, a non-finite fraction counting as none.
    public static func clamped(_ fraction: Double) -> Double { fraction.isFinite ? min(1, max(0, fraction)) : 0 }

    /// The fill's width in a track of `track`: at least the line's height, so it starts as a dot.
    public static func fillWidth(fraction: Double, track: CGFloat, height: CGFloat) -> CGFloat {
        min(track, max(height, track * clamped(fraction)))
    }

    public var body: some View {
        Capsule(style: .circular)
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule(style: .circular)
                        .fill(DaybookPalette.brandGradient(.progress))
                        .frame(width: Self.fillWidth(fraction: fraction, track: proxy.size.width, height: style.height))
                        .daybookGlow(DaybookPalette.neonCyan, radius: 3)
                        // Steps, whatever animation the change arrived in.
                        .transaction { $0.animation = nil }
                }
            }
            .frame(minWidth: width == nil ? Self.minimumWidth : nil)
            .frame(width: width, height: style.height)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((Self.clamped(fraction) * 100).rounded(.down))) percent")
    }
}

/// `ProgressView(value:)` drawn as `WorkProgress`: `.progressViewStyle(.brand)`.
public struct GradientProgressStyle: ProgressViewStyle {
    var width: CGFloat?
    var height: CGFloat

    public init(width: CGFloat? = 160, height: CGFloat = WorkProgress.Style.bar.height) {
        self.width = width
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        WorkProgress(fraction: configuration.fractionCompleted ?? 0, style: .init(height: height), width: width)
    }
}

extension ProgressViewStyle where Self == GradientProgressStyle {
    /// A 160 pt bar.
    public static var brand: GradientProgressStyle { GradientProgressStyle() }
    /// A bar or line of this size; nil width fills the layout.
    public static func brand(width: CGFloat?, height: CGFloat = WorkProgress.Style.bar.height) -> GradientProgressStyle {
        GradientProgressStyle(width: width, height: height)
    }
}
