import SwiftUI

/// The Daybook mark: five waveform bars in the brand gradient on a deep tile, with an amber bookmark dot.
/// The same drawing as the app icon (`scripts/make-icon.swift`); change them together.
public struct DaybookMark: View {
    private let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    private static let bars: [CGFloat] = [100, 178, 248, 158, 82]

    public init(size: CGFloat = 96) { self.size = size }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0x14 / 255, green: 0x32 / 255, blue: 0x2E / 255),
                                          Color(red: 0x0A / 255, green: 0x17 / 255, blue: 0x16 / 255)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                HStack(alignment: .center, spacing: size * 0.055) {
                    ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, height in
                        Capsule().frame(width: size * 0.07, height: size * height / 512 * 0.92)
                    }
                }
                .foregroundStyle(DaybookPalette.brandGradient(.mark))
                .daybookGlow(DaybookPalette.neonCyan, radius: size / 12)
                // The tile is always dark, so its bars are always the dark-mode neon, glow included.
                .environment(\.colorScheme, .dark)
            }
            .overlay(alignment: .topTrailing) {
                Circle().fill(Color(red: 1, green: 0xD2 / 255, blue: 0x3F / 255))
                    .frame(width: size * 0.07, height: size * 0.07)
                    .padding(size * 0.17)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.18), radius: size / 12, y: size / 24)
            .accessibilityHidden(true)
    }
}

/// An empty place, said once: the mark or a symbol, a title in New York, at most a sentence, and what
/// can be done about it. Nothing explains how Daybook works.
public struct DaybookEmptyState<Actions: View>: View {
    public enum Artwork: Hashable, Sendable {
        /// The Daybook mark: an empty library.
        case mark
        /// A symbol in the brand gradient.
        case symbol(String)
    }

    private let title: String
    private let image: Artwork
    private let message: String?
    private let actions: Actions
    @Environment(\.daybookDensity) private var density

    public init(title: String, image: Artwork = .mark, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.image = image
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        let touch = density == .touch
        VStack(spacing: DaybookSpacing.s4) {
            switch image {
            case .mark:
                DaybookMark(size: touch ? 72 : 64).padding(.bottom, DaybookSpacing.s2)
            case .symbol(let name):
                SwiftUI.Image(systemName: name)
                    .font(.system(size: touch ? 44 : 40, weight: .regular))
                    .foregroundStyle(DaybookPalette.brandGradient(.mark))
                    .daybookGlow(DaybookPalette.neonCyan, radius: 6)
                    .padding(.bottom, DaybookSpacing.s1)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(DaybookFont.sheetTitle.font(density))
                .foregroundStyle(DaybookPalette.Ink.title)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .font(touch ? .body : .system(size: 13))
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Actions.self != EmptyView.self {
                HStack(spacing: DaybookSpacing.s3) { actions }
                    #if os(macOS)
                    .controlSize(.large)
                    #endif
                    .padding(.top, DaybookSpacing.s2)
            }
        }
        .padding(.horizontal, DaybookSpacing.s5)
        .frame(maxWidth: 480)
    }
}

extension DaybookEmptyState where Actions == EmptyView {
    public init(title: String, image: Artwork = .mark, message: String? = nil) {
        self.init(title: title, image: image, message: message) { EmptyView() }
    }
}

/// Work just finished: the accent checkmark, drawn on where the system can (macOS 26, iOS 26), and
/// faded in under Reduce Motion. It stays for `DaybookMotion.hold`, then its owner removes it.
public struct DoneMark: View {
    private let size: CGFloat?
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter size: A fixed point size; nil keeps the surrounding font.
    public init(size: CGFloat? = nil) { self.size = size }

    public var body: some View {
        mark
            .foregroundStyle(DaybookPalette.accent)
            .daybookTransition(.opacity.combined(with: .scale(scale: 0.6)))
            .onAppear { drawn = true }
            .accessibilityLabel("Done")
    }

    @ViewBuilder private var mark: some View {
        let image = SwiftUI.Image(systemName: "checkmark.circle.fill").font(size.map { .system(size: $0) })
        if #available(macOS 26, iOS 26, *), !reduceMotion {
            image.symbolEffect(.drawOn, isActive: !drawn)
        } else {
            image
        }
    }
}
