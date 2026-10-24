import SwiftUI

// The recorder's large controls: Record, Bookmark, and Stop, in each app's material. A label view
// says what the control is; `daybookControl(_:)` gives it its surface. On iPhone that's Liquid
// Glass, as the recording surfaces always had. On the Mac it's drawn with its own colours, because
// Floating Notes is a non-activating panel that's almost never key, and system styles fade their
// tint when their window isn't: Stop has to stay red over someone else's call.

/// The surface a recorder control sits on.
public enum DaybookControlRole: Equatable, Sendable {
    /// Bookmark, Record, Resume, Open: a neutral surface; the label carries the colour.
    case standard
    /// Stop: red with a white label, in every state.
    case stop
}

/// The shape a recorder control takes.
public enum DaybookControlShape: Equatable, Sendable {
    case roundedRectangle(radius: CGFloat)
    case capsule
    case circle
}

extension View {
    /// Gives a recorder control its surface: Liquid Glass on iPhone, Daybook's own fills on the Mac.
    @ViewBuilder
    public func daybookControl(_ role: DaybookControlRole, shape: DaybookControlShape = .roundedRectangle(radius: 20)) -> some View {
        #if os(iOS)
        switch role {
        case .standard: buttonStyle(.glass).buttonBorderShape(shape.borderShape)
        case .stop: buttonStyle(.glassProminent).buttonBorderShape(shape.borderShape).tint(DaybookPalette.Ink.recordFill)
        }
        #else
        buttonStyle(DaybookControlStyle(role: role, shape: shape))
        #endif
    }
}

#if os(iOS)
extension DaybookControlShape {
    var borderShape: ButtonBorderShape {
        switch self {
        case .roundedRectangle(let radius): return .roundedRectangle(radius: radius)
        case .capsule: return .capsule
        case .circle: return .circle
        }
    }
}
#endif

/// The Mac's control surface: a raised paper tile for `.standard`, a red fill for `.stop`. Its own
/// colours, so it looks the same whether or not the window is key.
public struct DaybookControlStyle: ButtonStyle {
    let role: DaybookControlRole
    let shape: DaybookControlShape

    public init(role: DaybookControlRole, shape: DaybookControlShape = .roundedRectangle(radius: 20)) {
        self.role = role
        self.shape = shape
    }

    public func makeBody(configuration: Configuration) -> some View {
        ControlFace(configuration: configuration, role: role, shape: shape)
    }
}

private struct ControlFace: View {
    let configuration: ButtonStyleConfiguration
    let role: DaybookControlRole
    let shape: DaybookControlShape
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .foregroundStyle(role == .stop ? AnyShapeStyle(Color.white) : AnyShapeStyle(DaybookPalette.Ink.title))
            .background { surface }
            .overlay { outline }
            .compositingGroup()
            .shadow(color: .black.opacity(role == .standard && scheme == .light && contrast == .standard ? 0.07 : 0), radius: 3, y: 1)
            .brightness(configuration.isPressed ? (scheme == .dark ? 0.06 : -0.06) : hovering && isEnabled ? (scheme == .dark ? 0.04 : -0.015) : 0)
            // Stop stays red while it saves.
            .opacity(isEnabled ? 1 : role == .stop ? 0.85 : 0.5)
            .daybookGlow(role == .stop ? DaybookPalette.Ink.record : .clear, radius: 5)
            .contentShape(shapeView)
            .onHover { hovering = $0 }
            .animation(DaybookMotion.hover, value: hovering)
            .animation(DaybookMotion.hover, value: configuration.isPressed)
    }

    private var shapeView: AnyShape {
        switch shape {
        case .roundedRectangle(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // Circular: a continuous capsule leaves hairline ticks at its ends when drawn this way.
        case .capsule: return AnyShape(Capsule(style: .circular))
        case .circle: return AnyShape(Circle())
        }
    }

    @ViewBuilder private var surface: some View {
        switch role {
        case .stop:
            shapeView.fill(DaybookPalette.Ink.recordFill)
        case .standard:
            // A tile a little above the paper: white on light paper, a lifted grey on dark.
            shapeView.fill(scheme == .dark ? Color.white.opacity(0.085) : Color.white)
        }
    }

    @ViewBuilder private var outline: some View {
        switch role {
        case .stop:
            if contrast == .increased { shapeView.stroke(Color.white.opacity(0.7), lineWidth: 1).padding(0.5) }
        case .standard:
            shapeView.stroke(contrast == .increased ? DaybookPalette.Ink.meta : Color.primary.opacity(scheme == .dark ? 0.12 : 0.1),
                             lineWidth: contrast == .increased ? 1 : 0.5)
        }
    }
}

// MARK: - Labels

/// Bookmark: amber, with the count in an amber pill. Bounces when one lands, so it's felt without
/// looking. Hand it `.frame(maxWidth: .infinity, minHeight:)` for the control's size.
public struct BookmarkControlLabel: View {
    private let count: Int
    private let title: String
    private let size: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter size: A fixed size (Mac); nil follows Dynamic Type (`.headline`, iPhone).
    public init(count: Int, title: String = "Bookmark", size: CGFloat? = nil) {
        self.count = count
        self.title = title
        self.size = size
    }

    public var body: some View {
        HStack(spacing: (size ?? 17) * 0.47) {
            Image(systemName: "bookmark.fill")
                .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
                .daybookGlow(count > 0 ? DaybookPalette.bookmark : .clear, radius: 3)
            Text(title).lineLimit(1)
            if count > 0 {
                Text("\(count)")
                    .font(size.map { .system(size: $0 - 2, weight: .bold).monospacedDigit() } ?? .subheadline.weight(.bold).monospacedDigit())
                    .padding(.horizontal, (size ?? 17) * 0.4)
                    .padding(.vertical, 1)
                    .background(DaybookPalette.bookmark.opacity(0.2), in: Capsule())
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .font(size.map { .system(size: $0, weight: .semibold) } ?? .headline)
        .foregroundStyle(DaybookPalette.bookmark)
    }
}

/// Stop, or Saving while the recording is filed. White, for the red surface.
public struct StopControlLabel: View {
    private let isSaving: Bool
    private let title: String
    private let savingTitle: String
    private let size: CGFloat?

    public init(isSaving: Bool, title: String = "Stop", savingTitle: String = "Saving", size: CGFloat? = nil) {
        self.isSaving = isSaving
        self.title = title
        self.savingTitle = savingTitle
        self.size = size
    }

    public var body: some View {
        HStack(spacing: (size ?? 17) * 0.47) {
            if isSaving {
                ProgressView().controlSize(.small).tint(.white).environment(\.colorScheme, .dark)
                Text(savingTitle)
            } else {
                Image(systemName: "stop.fill").font(size.map { .system(size: $0 * 0.82, weight: .bold) } ?? .headline)
                Text(title)
            }
        }
        .lineLimit(1)
        .font(size.map { .system(size: $0, weight: .semibold) } ?? .headline)
        .foregroundStyle(.white)
    }
}

/// Record: the red dot and the word, in title ink. The one red mark you need before recording.
public struct RecordControlLabel: View {
    private let title: String
    private let size: CGFloat?

    public init(title: String = "Record", size: CGFloat? = nil) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        HStack(spacing: (size ?? 20) * 0.5) {
            Circle().fill(DaybookPalette.Ink.record)
                .frame(width: (size ?? 20) * 0.8, height: (size ?? 20) * 0.8)
                .daybookGlow(DaybookPalette.Ink.record, radius: 3)
            Text(title).lineLimit(1)
        }
        .font(size.map { .system(size: $0, weight: .semibold) } ?? .title3.weight(.semibold))
        .foregroundStyle(DaybookPalette.Ink.title)
    }
}

/// Something that needs the person, in one quiet box: a warning headline, what happened and what
/// happens next, and at most two actions. The iPhone's pause box; the Mac's stopped-with-a-problem.
public struct AttentionBox<Actions: View>: View {
    private let title: String
    private let symbol: String
    private let message: String?
    private let compact: Bool
    private let actions: Actions
    @Environment(\.colorSchemeContrast) private var contrast

    public init(title: String, symbol: String = "exclamationmark.triangle.fill", message: String?, compact: Bool = false,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.compact = compact
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Label(title, systemImage: symbol)
                .font(compact ? .system(size: 12, weight: .semibold) : .headline)
                .foregroundStyle(DaybookPalette.Ink.warning)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(compact ? .system(size: 12) : .subheadline)
                    .foregroundStyle(DaybookPalette.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DaybookPalette.attentionFill, in: RoundedRectangle(cornerRadius: compact ? 10 : 20, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: compact ? 10 : 20, style: .continuous).strokeBorder(DaybookPalette.Ink.warning, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension AttentionBox where Actions == EmptyView {
    public init(title: String, symbol: String = "exclamationmark.triangle.fill", message: String?, compact: Bool = false) {
        self.init(title: title, symbol: symbol, message: message, compact: compact) { EmptyView() }
    }
}
