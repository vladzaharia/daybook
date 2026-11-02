import DaybookDesign
import SwiftUI

/// Quiet text that's also a control, in a byline or a colophon: in a window, `rest` ink until the pointer is over it,
/// then link ink; under touch, `touch` ink (link ink, as every link there). Put it in a plain button's label.
public struct QuietLink<Label: View>: View {
    private let rest: Color
    private let touch: Color
    private let label: Label
    @State private var hovering = false
    @Environment(\.daybookDensity) private var density
    @Environment(\.isEnabled) private var isEnabled

    public init(rest: Color = DaybookPalette.Ink.secondary, touch: Color = DaybookPalette.Ink.link, @ViewBuilder label: () -> Label) {
        self.rest = rest
        self.touch = touch
        self.label = label()
    }

    public var body: some View {
        label
            .foregroundStyle(density == .touch ? touch : hovering && isEnabled ? DaybookPalette.Ink.link : rest)
            .onHover { hovering = $0 }
            .daybookMotion(DaybookMotion.hover, value: hovering)
    }
}
