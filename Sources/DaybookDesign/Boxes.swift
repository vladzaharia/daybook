import SwiftUI

/// What a box is about, which sets its tint: something went wrong, something to do, or something to know.
public enum AttentionKind: Hashable, Sendable {
    /// Needs the person: the warning glyph and title, a warning wash.
    case problem
    /// Something to do: an accent wash.
    case accent
    /// Something to know: the quiet fill.
    case info
}

/// A state that needs the person, in one box: a glyph in its column, a title, what happened and what's
/// safe, and at most two actions. Beside the words when there's room; under them, on the words' edge,
/// in a narrow box (under 520 pt) or a compact one. The conversation page's problems, the device page's,
/// Floating Notes' "Recording stopped", and the iPhone's pause box are all this.
public struct AttentionBox<Actions: View>: View {
    private let kind: AttentionKind
    private let symbol: String
    private let title: String
    private let message: String?
    private let compact: Bool
    private let actions: Actions
    @State private var width: CGFloat = AttentionBoxLayout.stackBelow
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.daybookDensity) private var density

    public init(kind: AttentionKind = .problem, title: String, symbol: String? = nil, message: String?, compact: Bool = false,
                @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.symbol = symbol ?? AttentionBoxLayout.symbol(for: kind)
        self.title = title
        self.message = message
        self.compact = compact
        self.actions = actions()
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
    private var stacked: Bool { AttentionBoxLayout.stacks(width: width, compact: compact, density: density) }

    public var body: some View {
        HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: compact ? DaybookSpacing.s2 : DaybookSpacing.s3) {
            Image(systemName: symbol)
                .font(glyphFont)
                .symbolRenderingMode(kind == .problem ? .monochrome : .hierarchical)
                .foregroundStyle(tint)
                .frame(width: compact ? 14 : 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: compact ? 6 : DaybookSpacing.s2) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(AttentionBoxLayout.title(for: kind).ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message)
                            .font(messageFont)
                            .foregroundStyle(AttentionBoxLayout.message(for: kind).ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                if stacked && hasActions { actionRow }
            }
            .layoutPriority(1)
            if !stacked && hasActions {
                Spacer(minLength: DaybookSpacing.s3)
                actionRow
            }
        }
        .padding(compact ? 10 : DaybookSpacing.s3)
        // Stacked or not, the box spans its column, so boxes and lines share both edges.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AttentionBoxLayout.wash(for: kind).color, in: DaybookRadius.shape(DaybookRadius.box))
        .overlay {
            if contrast == .increased {
                DaybookRadius.shape(DaybookRadius.box).strokeBorder(kind == .problem ? DaybookPalette.Ink.warning : DaybookPalette.Ink.meta, lineWidth: 1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
    }

    private var actionRow: some View {
        HStack(spacing: DaybookSpacing.s3) { actions }
            .controlSize(.small)
            .fixedSize()
    }

    private var tint: Color {
        switch kind {
        case .problem: return DaybookPalette.Ink.warning
        case .accent: return DaybookPalette.accent
        case .info: return DaybookPalette.Ink.secondary
        }
    }

    private var glyphFont: Font {
        density == .touch ? .subheadline : .system(size: compact ? 12 : 15)
    }

    private var titleFont: Font {
        density == .touch ? DaybookFont.statusLead.font(.touch) : .system(size: 12, weight: compact ? .semibold : .medium)
    }

    private var messageFont: Font { DaybookFont.status.font(density == .touch ? .touch : .window) }
}

/// The box's rules, as plain values.
public enum AttentionBoxLayout {
    /// Below this width a box's actions move under its message.
    public static let stackBelow: CGFloat = 520

    public static func stacks(width: CGFloat, compact: Bool, density: DaybookDensity) -> Bool {
        compact || density == .panel || width < stackBelow
    }

    /// A kind's wash: warning at 8% (12% in Dark Mode), accent at 8%, or the quiet fill.
    public static func wash(for kind: AttentionKind) -> DaybookWash {
        switch kind {
        case .problem: return .tint(DaybookPalette.Shade.warning, light: 0.08, dark: 0.12)
        case .accent: return .tint(DaybookPalette.Shade.accent, light: 0.08, dark: 0.08)
        case .info: return .quiet
        }
    }

    /// A box's title on its wash: a problem's in the warning ink that keeps 4.5:1 there
    /// (`Ink.onAttention`), the rest in body ink.
    public static func title(for kind: AttentionKind) -> DaybookInkPair {
        DaybookInkPair(ink: kind == .problem ? DaybookPalette.Shade.onAttention : DaybookPalette.Shade.body, wash: wash(for: kind))
    }

    /// A box's message on its wash, in secondary ink.
    public static func message(for kind: AttentionKind) -> DaybookInkPair {
        DaybookInkPair(ink: DaybookPalette.Shade.secondary, wash: wash(for: kind))
    }

    public static func symbol(for kind: AttentionKind) -> String {
        switch kind {
        case .problem: return "exclamationmark.triangle.fill"
        case .accent: return "sparkles"
        case .info: return "info.circle.fill"
        }
    }
}

extension AttentionBox where Actions == EmptyView {
    public init(kind: AttentionKind = .problem, title: String, symbol: String? = nil, message: String?, compact: Bool = false) {
        self.init(kind: kind, title: title, symbol: symbol, message: message, compact: compact) { EmptyView() }
    }
}

/// One of a box's actions.
public struct AttentionAction: Identifiable {
    public let id = UUID()
    public let title: String
    public let perform: () -> Void

    public init(_ title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

extension AttentionBox where Actions == AttentionBoxActions {
    /// A box whose first action leads (prominent), with a second as a link and Dismiss after them when
    /// there's room: at most two besides Dismiss.
    public init(kind: AttentionKind = .problem, title: String, symbol: String? = nil, message: String?, compact: Bool = false,
                primary: AttentionAction?, secondary: AttentionAction? = nil, dismiss: (() -> Void)? = nil) {
        self.init(kind: kind, title: title, symbol: symbol, message: message, compact: compact) {
            AttentionBoxActions(primary: primary, secondary: secondary, dismiss: dismiss)
        }
    }
}

/// A box's actions in their order: the links, then the one that leads.
public struct AttentionBoxActions: View {
    let primary: AttentionAction?
    let secondary: AttentionAction?
    let dismiss: (() -> Void)?

    public var body: some View {
        if let dismiss, primary == nil || secondary == nil {
            Button("Dismiss", action: dismiss).buttonStyle(.daybookLink)
        }
        if let secondary { Button(secondary.title, action: secondary.perform).buttonStyle(.daybookLink) }
        if let primary { Button(primary.title, action: primary.perform).buttonStyle(.daybookProminent) }
    }
}

// MARK: - Problems in place

/// A problem in place, in Settings and its sheets: the warning glyph, one plain sentence in the label
/// colour, the system's own words behind Details, and its actions. They sit beside a short sentence and
/// move under a long one, so a row never squeezes its sentence into a narrow column.
public struct ProblemLine<Actions: View>: View {
    private let text: String
    private let details: String?
    private let symbol: String
    private let actions: Actions

    /// The glyph's column, so a wrapped sentence and stacked actions keep one leading edge.
    private static var glyphWidth: CGFloat { 18 }

    public init(text: String, details: String? = nil, symbol: String = "exclamationmark.triangle.fill", @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.details = details
        self.symbol = symbol
        self.actions = actions()
    }

    private var hasButtons: Bool { details != nil || Actions.self != EmptyView.self }

    public var body: some View {
        if hasButtons {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
                    sentence
                    Spacer(minLength: DaybookSpacing.s3)
                    buttons
                }
                VStack(alignment: .leading, spacing: DaybookSpacing.s2) {
                    sentence
                    // Wrapped, so several long ones ("Get Key from Alex's iPhone 15 Pro Max") stay inside the row.
                    FlowLayout(spacing: DaybookSpacing.s2) { buttons }
                        .padding(.leading, Self.glyphWidth + DaybookSpacing.s2)
                }
            }
        } else {
            sentence
        }
    }

    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: DaybookSpacing.s2) {
            Image(systemName: symbol)
                .foregroundStyle(DaybookPalette.Ink.warning)
                .frame(width: Self.glyphWidth)
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        Group {
            if let details { DetailsButton(details: details) }
            actions
        }
        #if os(iOS)
        // In a list row each is its own target, in the link's ink.
        .buttonStyle(.daybookLink)
        #endif
    }
}

extension ProblemLine where Actions == EmptyView {
    public init(text: String, details: String? = nil, symbol: String = "exclamationmark.triangle.fill") {
        self.init(text: text, details: details, symbol: symbol) { EmptyView() }
    }
}

/// Shows a problem's own words: Details beside a problem opens them. Set by a screen that presents them
/// its own way (the iPhone Duo's page sheet).
public struct DetailsPresenter {
    public var present: @MainActor (_ title: String, _ details: String) -> Void
    public init(present: @escaping @MainActor (_ title: String, _ details: String) -> Void) { self.present = present }
}

extension EnvironmentValues {
    @Entry public var detailsPresenter: DetailsPresenter? = nil
}

/// Details beside a problem: the system's own words, selectable, in a popover on the Mac and a sheet on
/// the iPhone (or however `detailsPresenter` shows them).
public struct DetailsButton: View {
    /// "Details…" on the Mac, where it opens a window of words; "Details" on the iPhone, whose Details
    /// buttons show more of what's already there and ask for nothing (docs/copy-pass-2026-10.md).
    public static var title: String {
        #if os(macOS)
        "Details…"
        #else
        "Details"
        #endif
    }

    private let details: String
    private let sheetTitle: String
    @State private var showing = false
    @Environment(\.detailsPresenter) private var presenter

    public init(details: String, sheetTitle: String = "Details") {
        self.details = details
        self.sheetTitle = sheetTitle
    }

    public var body: some View {
        Button(Self.title) {
            if let presenter { presenter.present(sheetTitle, details) } else { showing = true }
        }
        #if os(macOS)
        .popover(isPresented: $showing) {
            Text(details)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DaybookSpacing.s4)
                .frame(width: 360, alignment: .leading)
        }
        #else
        .sheet(isPresented: $showing) { DetailsSheetContent(title: sheetTitle, details: details) }
        #endif
    }
}

#if os(iOS)
/// The words behind Details, on a medium sheet with Done.
struct DetailsSheetContent: View {
    let title: String
    let details: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(details).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
#endif
