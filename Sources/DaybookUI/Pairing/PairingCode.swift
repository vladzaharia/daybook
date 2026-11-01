import DaybookDesign
import DaybookLink
import SwiftUI

// A pairing code as both devices show it: the Mac's code to read ("482 913"), and the iPhone's six boxes
// to type it into, both grouped by `LinkPairingCode.groupSize` with the one separator (a gap), so what's
// typed looks like what's shown.

/// The code on the device that shows it: large, its groups apart, selectable.
public struct PairingCodeView: View {
    private let code: LinkPairingCode
    @Environment(\.daybookDensity) private var density

    public init(_ code: LinkPairingCode) { self.code = code }

    public var body: some View {
        Text(code.formatted)
            .font(.system(size: density == .touch ? 44 : 40, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .tracking(2)
            .foregroundStyle(DaybookPalette.Ink.title)
            .textSelection(.enabled)
            .contentTransition(.numericText())
            .accessibilityLabel(PairingWords.spoken(code))
    }
}

/// Six boxes to type a code into, grouped as `PairingCodeView` shows it. The real field sits under the boxes,
/// nearly invisible: the keyboard, autofill, and VoiceOver use it.
public struct PairingCodeEntry: View {
    @Binding private var code: String
    private let label: String
    private let focus: FocusState<Bool>.Binding

    /// - Parameters:
    ///   - code: What's typed; only digits are kept, six at most.
    ///   - label: "Code on Studio Mac", for VoiceOver.
    public init(code: Binding<String>, label: String, focus: FocusState<Bool>.Binding) {
        _code = code
        self.label = label
        self.focus = focus
    }

    private var digits: [Character] { Array(code.filter(\.isNumber)) }

    public var body: some View {
        ZStack {
            field
            HStack(spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Color.clear.frame(width: 8).accessibilityHidden(true) }
                    ForEach(group, id: \.self) { box($0) }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
    }

    /// The boxes' indices, in the code's groups.
    private var groups: [[Int]] {
        stride(from: 0, to: LinkProtocol.pairingCodeDigits, by: LinkPairingCode.groupSize).map { start in
            Array(start..<min(start + LinkPairingCode.groupSize, LinkProtocol.pairingCodeDigits))
        }
    }

    private func box(_ index: Int) -> some View {
        let typed = digits
        return Text(index < typed.count ? String(typed[index]) : "")
            .font(.system(size: 30, weight: .medium).monospacedDigit())
            .foregroundStyle(DaybookPalette.Ink.title)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Self.fill, in: DaybookRadius.shape(DaybookRadius.box))
            .overlay(DaybookRadius.shape(DaybookRadius.box)
                .stroke(index == typed.count && focus.wrappedValue ? DaybookPalette.accent : Color.clear, lineWidth: 2))
    }

    private var field: some View {
        TextField("", text: $code)
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .focused(focus)
            .opacity(0.02)
            .accessibilityLabel(label)
            .accessibilityValue(digits.isEmpty ? "Empty" : digits.map(String.init).joined(separator: " "))
            .onChange(of: code) { _, value in
                let kept = String(value.filter(\.isNumber).prefix(LinkProtocol.pairingCodeDigits))
                if kept != value { code = kept }
            }
    }

    /// A box on the sheet's grouped background, like a list's cell.
    private static var fill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        DaybookPalette.quietFill
        #endif
    }
}
