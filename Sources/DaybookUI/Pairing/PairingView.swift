import DaybookDesign
import DaybookLink
import SwiftUI

/// Which side of pairing a device takes (docs/link.md, "Pairing").
public enum PairingRole: Sendable, Equatable {
    /// Shows a code for the other device to type: the Mac.
    case showsCode
    /// Chooses the device that shows a code and types it: the iPhone.
    case entersCode

    /// The device that takes this role.
    public var deviceClass: LinkDeviceClass { self == .showsCode ? .mac : .iPhone }
    /// The other device's symbol, until the two are paired.
    var otherSymbol: String { self == .showsCode ? "iphone" : "laptopcomputer" }
}

/// Pairing, the same screen on both devices: the other device's glyph, "Pair with Your iPhone" (or Mac), then
/// what this side does. The Mac shows its code (`PairingCodeView`) above the iPhones it's paired with; the
/// iPhone lists the Macs on its network above the code boxes (`PairingCodeEntry`), and says where the Mac's
/// control is. Once paired, the glyph becomes the Mac and iPhone together, the title says who, a checkmark
/// draws on, and the iPhone in the hand gives a success tap (a failed code, an error tap).
///
/// One column in the hand and in the Mac's sheet; over the open iPhone Duo, two pages through the app's own
/// two-page layout (`pages`): the title and the choice on the left, the code on the right.
public struct PairingView<Choice: View, Code: View>: View {
    private let role: PairingRole
    private let paired: String?
    private let problem: String?
    private let showsCode: Bool
    private let pages: ((AnyView, AnyView) -> AnyView)?
    private let choice: Choice
    private let code: Code
    @Environment(\.daybookDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - paired: The other device's name, once paired.
    ///   - problem: What went wrong with the last attempt, if anything: a new one taps an error.
    ///   - showsCode: Whether `code` has something to show now (the iPhone, once a Mac is chosen).
    ///   - pages: Lays the two pages out side by side; nil for one column.
    ///   - choice: The Mac's paired iPhones, or the iPhone's Macs on this network.
    ///   - code: The Mac's code and what to do with it, or the iPhone's code boxes.
    public init(role: PairingRole, paired: String?, problem: String? = nil, showsCode: Bool = true,
                pages: ((AnyView, AnyView) -> AnyView)? = nil, @ViewBuilder choice: () -> Choice, @ViewBuilder code: () -> Code) {
        self.role = role
        self.paired = paired
        self.problem = problem
        self.showsCode = showsCode
        self.pages = pages
        self.choice = choice()
        self.code = code()
    }

    private var isPaired: Bool { paired != nil }
    private var alignment: HorizontalAlignment { density == .touch ? .leading : .center }

    public var body: some View {
        Group {
            if let pages {
                pages(AnyView(leadingPage), AnyView(trailingPage))
            } else {
                column
            }
        }
        .animation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion), value: paired)
        .sensoryFeedback(.success, trigger: paired) { _, new in new != nil }
        .sensoryFeedback(.error, trigger: problem) { _, new in new != nil }
    }

    private var column: some View {
        VStack(alignment: alignment, spacing: DaybookSpacing.s5) {
            header
            switch role {
            case .showsCode:
                if !isPaired { code.daybookTransition(.opacity.combined(with: .scale(scale: 0.96))) }
                choice
            case .entersCode:
                if !isPaired {
                    choice.daybookTransition(.opacity)
                    if showsCode { code.daybookTransition(.opacity.combined(with: .scale(scale: 0.96))) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private var leadingPage: some View {
        VStack(alignment: .leading, spacing: DaybookSpacing.s5) {
            header
            if !isPaired { choice.daybookTransition(.opacity) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var trailingPage: some View {
        if !isPaired, showsCode {
            VStack(alignment: .leading, spacing: DaybookSpacing.s5) { code }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .daybookTransition(.opacity)
        } else {
            // Until there's a code to type, the page holds the mark: the left page says what to do.
            glyph(size: 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: alignment, spacing: DaybookSpacing.s2) {
            glyph(size: density == .touch ? 40 : 30)
            HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                if isPaired { DoneMark().font(titleFont) }
                Text(paired.map(PairingWords.paired(with:)) ?? PairingWords.title(on: role.deviceClass))
                    .font(titleFont)
                    .foregroundStyle(DaybookPalette.Ink.title)
                    .multilineTextAlignment(density == .touch ? .leading : .center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                    .accessibilityAddTraits(.isHeader)
            }
            if role == .entersCode, !isPaired {
                Text(PairingWords.onTheMac)
                    .font(density == .touch ? .callout : DaybookFont.status.font(density))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The other device until paired, then the Mac and iPhone together: one symbol becoming the other.
    private func glyph(size: CGFloat) -> some View {
        Image(systemName: isPaired ? "macbook.and.iphone" : role.otherSymbol)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(isPaired ? DaybookPalette.accent : DaybookPalette.Ink.secondary)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .downUp)))
            .daybookBounce(value: paired)
            .frame(minHeight: size + 4)
            .accessibilityHidden(true)
    }

    private var titleFont: Font {
        density == .touch ? DaybookFont.docTitle.font(.touch) : DaybookFont.sheetTitle.font(density)
    }
}
