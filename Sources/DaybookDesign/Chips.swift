import SwiftUI

/// A short label in a capsule: a tag, a next step's owner, a fact about a model, or a status word. Each
/// kind's text keeps 4.5:1 on its wash in every appearance (`colors(_:filled:)`, which the token tests
/// check).
public struct DaybookChip: View {
    public enum Kind: Hashable, Sendable {
        /// A tag: `Ink.onWash` on the 14% accent wash.
        case tag
        /// A next step's owner: their owner ink on their speaker ink at 14%; secondary on the quiet fill
        /// for someone who didn't speak (nil).
        case owner(Int?)
        /// A fact ("Non-commercial", "Added by you"): secondary ink on the quiet fill.
        case fact
        /// A status word: warning words on the warning wash, teal ones on the accent wash, and the rest
        /// in secondary on the quiet fill, recording with the red dot before it.
        case status(StatusTone)
    }

    private let text: String
    private let kind: Kind
    private let filled: Bool
    @Environment(\.daybookDensity) private var density

    /// - Parameter filled: The capsule behind it; off for a done next step, which keeps only the name.
    public init(_ text: String, kind: Kind, filled: Bool = true) {
        self.text = text
        self.kind = kind
        self.filled = filled
    }

    public var body: some View {
        let touch = density == .touch
        let colors = Self.colors(kind, filled: filled)
        HStack(spacing: touch ? 5 : 4) {
            if kind == .status(.recording) {
                // The red is the dot's: red words on the quiet fill fall under 4.5:1.
                Circle().fill(DaybookPalette.Ink.record)
                    .frame(width: touch ? 7 : 6, height: touch ? 7 : 6)
                    .daybookGlow(DaybookPalette.Ink.record, radius: 2)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(touch ? .caption.weight(weight) : .system(size: 11, weight: weight))
                .foregroundStyle(colors.ink.color)
                .lineLimit(1)
        }
        .padding(.horizontal, touch ? 8 : 7)
        .padding(.vertical, touch ? 3 : 2)
        .background(colors.wash.color, in: DaybookRadius.chip)
        .fixedSize()
    }

    private var weight: Font.Weight {
        if case .owner = kind { return .semibold }
        return .medium
    }

    /// A kind's words and the wash behind them; without the capsule (`filled` off), the words sit on the
    /// paper.
    public static func colors(_ kind: Kind, filled: Bool = true) -> DaybookInkPair {
        typealias Shade = DaybookPalette.Shade
        let pair: (ink: DaybookShade, wash: DaybookWash)
        switch kind {
        case .tag:
            pair = (Shade.onWash, .accent)
        case .owner(let index?):
            let speaker = Shade.speakers[abs(index) % Shade.speakers.count]
            pair = (filled ? Shade.ownerText[abs(index) % Shade.ownerText.count] : speaker, .tint(speaker, light: 0.14, dark: 0.14))
        case .owner(nil), .fact:
            pair = (Shade.secondary, .quiet)
        case .status(let tone):
            switch tone {
            case .attention: pair = (filled ? Shade.onAttention : Shade.warning, .attention)
            case .linked, .working: pair = (Shade.onWash, .accent)
            case .recording, .calm: pair = (Shade.secondary, .quiet)
            }
        }
        return DaybookInkPair(ink: pair.ink, wash: filled ? pair.wash : .none)
    }
}
