import SwiftUI

/// A short label in a capsule: a tag, a next step's owner, a fact about a model, or a status word. Each
/// kind's text keeps 4.5:1 on its wash in every appearance (the token tests check the inks).
public struct DaybookChip: View {
    public enum Kind: Hashable, Sendable {
        /// A tag: `Ink.onWash` on the 14% accent wash.
        case tag
        /// A next step's owner: their owner ink on their speaker ink at 14%; secondary on the quiet fill
        /// for someone who didn't speak (nil).
        case owner(Int?)
        /// A fact ("Non-commercial", "Added by you"): secondary ink on the quiet fill.
        case fact
        /// A status word, in its tone's ink.
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
        Text(text)
            .font(touch ? .caption.weight(weight) : .system(size: 11, weight: weight))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, touch ? 8 : 7)
            .padding(.vertical, touch ? 3 : 2)
            .background(filled ? fill : .clear, in: DaybookRadius.chip)
            .fixedSize()
    }

    private var weight: Font.Weight {
        if case .owner = kind { return .semibold }
        return .medium
    }

    private var ink: Color {
        switch kind {
        case .tag: return DaybookPalette.Ink.onWash
        case .owner(let index): return filled ? DaybookPalette.ownerInk(index) : DaybookPalette.speakerInk(index)
        case .fact: return DaybookPalette.Ink.secondary
        case .status(let tone):
            switch tone {
            case .attention: return DaybookPalette.Ink.warning
            case .linked, .working: return DaybookPalette.Ink.onWash
            case .recording: return DaybookPalette.Ink.record
            case .calm: return DaybookPalette.Ink.secondary
            }
        }
    }

    private var fill: Color {
        switch kind {
        case .tag: return DaybookPalette.accentWash
        case .owner(let index?): return DaybookPalette.speakerInk(index).opacity(0.14)
        case .owner(nil), .fact: return DaybookPalette.quietFill
        case .status(let tone):
            switch tone {
            case .attention: return DaybookPalette.attentionFill
            case .linked, .working: return DaybookPalette.accentWash
            case .recording, .calm: return DaybookPalette.quietFill
            }
        }
    }
}
