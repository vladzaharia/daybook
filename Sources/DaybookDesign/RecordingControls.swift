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
    public func daybookControl(_ role: DaybookControlRole, shape: DaybookControlShape = .roundedRectangle(radius: DaybookRadius.control)) -> some View {
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

    public init(role: DaybookControlRole, shape: DaybookControlShape = .roundedRectangle(radius: DaybookRadius.control)) {
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
/// looking. Hand it `.frame(maxWidth: .infinity, minHeight:)` for the control's size. Under touch at the
/// accessibility sizes it's the glyph and the count alone, so neither is cut off; the control keeps its
/// name for VoiceOver and the large content viewer.
public struct BookmarkControlLabel: View {
    private let count: Int
    private let title: String
    private let size: CGFloat?
    private let landed: Int?
    /// Bounces for each bookmark added, when the caller doesn't say which ones the person made.
    @State private var added = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - size: A fixed size (Mac); nil follows Dynamic Type (`.headline`, iPhone).
    ///   - landed: Counts the person's own taps: the symbol bounces for those alone, never for a bookmark
    ///     another device added or one taken away. Nil bounces for every one added.
    ///   - title: The word; empty draws the glyph and the count alone, for a tile too narrow for it.
    public init(count: Int, title: String = "Bookmark", size: CGFloat? = nil, landed: Int? = nil) {
        self.count = count
        self.title = title
        self.size = size
        self.landed = landed
    }

    /// Whether a recorder control drops its words: Dynamic Type at an accessibility size.
    public static func isGlyphOnly(size: CGFloat?, typeSize: DynamicTypeSize) -> Bool { size == nil && typeSize.isAccessibilitySize }

    public var body: some View {
        HStack(spacing: (size ?? 17) * 0.47) {
            Image(systemName: "bookmark.fill")
                .daybookBounce(value: landed ?? added)
                .daybookGlow(count > 0 ? DaybookPalette.bookmark : .clear, radius: 3)
            if !Self.isGlyphOnly(size: size, typeSize: typeSize), !title.isEmpty {
                Text(title).lineLimit(1)
            }
            if count > 0 {
                Text("\(count)")
                    .font(size.map { .system(size: $0 - 2, weight: .bold).monospacedDigit() } ?? .subheadline.weight(.bold).monospacedDigit())
                    .padding(.horizontal, (size ?? 17) * 0.4)
                    .padding(.vertical, 1)
                    // The count in its own ink, which keeps 4.5:1 on the amber pill.
                    .foregroundStyle(DaybookPalette.Ink.bookmarkCount)
                    .background(DaybookPalette.bookmark.opacity(0.2), in: DaybookRadius.chip)
                    // The count rolls as it changes (a fade under Reduce Motion), wherever the change came from.
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                    .animation(DaybookMotion.resolved(DaybookMotion.tick, reduceMotion: reduceMotion), value: count)
            }
        }
        .font(size.map { .system(size: $0, weight: .semibold) } ?? .headline)
        .foregroundStyle(DaybookPalette.bookmark)
        .onChange(of: count) { old, new in
            if new > old { added += 1 }
        }
    }
}

/// Stop, or Saving while the recording is filed. White, for the red surface. Under touch at the
/// accessibility sizes it's the glyph alone, as Bookmark is.
public struct StopControlLabel: View {
    private let isSaving: Bool
    private let title: String
    private let savingTitle: String
    private let size: CGFloat?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(isSaving: Bool, title: String = "Stop", savingTitle: String = "Saving…", size: CGFloat? = nil) {
        self.isSaving = isSaving
        self.title = title
        self.savingTitle = savingTitle
        self.size = size
    }

    public var body: some View {
        let words = !BookmarkControlLabel.isGlyphOnly(size: size, typeSize: typeSize)
        HStack(spacing: (size ?? 17) * 0.47) {
            if isSaving {
                ProgressView().controlSize(.small).tint(.white).environment(\.colorScheme, .dark)
                if words { Text(savingTitle) }
            } else {
                Image(systemName: "stop.fill").font(size.map { .system(size: $0 * 0.82, weight: .bold) } ?? .headline)
                if words { Text(title) }
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
