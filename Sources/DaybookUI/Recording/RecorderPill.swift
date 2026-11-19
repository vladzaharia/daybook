#if os(iOS)
import DaybookDesign
import SwiftUI

/// Page turning in the notebook: what the pill's second row says and does.
public struct NotebookPaging {
    public var label: String
    public var accessibilityLabel: String
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canAddPage: Bool
    public var back: () -> Void
    public var forward: () -> Void
    public var add: () -> Void

    public init(label: String, accessibilityLabel: String, canGoBack: Bool, canGoForward: Bool, canAddPage: Bool,
                back: @escaping () -> Void, forward: @escaping () -> Void, add: @escaping () -> Void) {
        self.label = label; self.accessibilityLabel = accessibilityLabel; self.canGoBack = canGoBack
        self.canGoForward = canGoForward; self.canAddPage = canAddPage; self.back = back; self.forward = forward; self.add = add
    }
}

/// The recorder as a small glass pill floating over the notebook's top-right corner, on one row: the phase, the clock, a small
/// meter, Bookmark and Stop (Resume while paused), then the pages ("3–4 of 7", Previous, Next, New Page). Tapping the status
/// closes the notebook back to the recorder. Short of room it drops the meter, and then puts the page controls on a second row;
/// collapsed it's a chip of the dot and the clock, which expands on a tap (docs/notebook.md, "The pill").
public struct RecorderPill: View {
    private let state: RecorderSurfaceState?
    private let levels: RecorderLevels
    private let actions: RecorderSurfaceActions
    private let paging: NotebookPaging
    private let close: () -> Void
    private let collapsed: Bool
    private let expand: () -> Void
    private let available: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameters:
    ///   - state: The recording's; nil in a saved conversation's notebook, where the top is Done.
    ///   - close: The status tapped (the notebook closes back to the recorder), or Done.
    ///   - collapsed: Drawn as the small chip.
    ///   - expand: The chip tapped.
    ///   - available: The width the pill may take.
    public init(state: RecorderSurfaceState?, levels: RecorderLevels, actions: RecorderSurfaceActions, paging: NotebookPaging,
                close: @escaping () -> Void, collapsed: Bool, expand: @escaping () -> Void, available: CGFloat) {
        self.state = state; self.levels = levels; self.actions = actions; self.paging = paging; self.close = close
        self.collapsed = collapsed; self.expand = expand; self.available = available
    }

    private func parts(_ state: RecorderSurfaceState) -> RecorderPieces {
        RecorderPieces(state: state, levels: levels, actions: actions, slots: RecorderSlots(notes: AnyView(EmptyView())), clockFocus: nil)
    }

    /// How much larger than the default the text draws, for the fit.
    private var textScale: CGFloat {
        switch min(typeSize, .xxxLarge) {
        case .xSmall, .small, .medium, .large: return 1
        case .xLarge: return 1.1
        case .xxLarge: return 1.2
        default: return 1.3
        }
    }

    public var body: some View {
        Group {
            if collapsed {
                chip
            } else {
                switch NotebookPillFit.resolve(available: available, textScale: textScale) {
                case .oneRow(let meter):
                    HStack(spacing: DaybookSpacing.s2) { status(meter: meter); pagesRow }.modifier(FitScale(available: available - 16))
                case .twoRows:
                    VStack(alignment: .trailing, spacing: 0) { status(meter: false); pagesRow }.modifier(FitScale(available: available - 16))
                }
            }
        }
        .padding(.horizontal, DaybookSpacing.s2)
        .padding(.vertical, DaybookSpacing.s1)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .fixedSize()
    }

    private var chip: some View {
        Button(action: expand) {
            HStack(spacing: DaybookSpacing.s2) {
                if let state {
                    if let phase = state.phase { RecordingPhaseLabel(phase.phase, title: "") }
                    parts(state).clock(17)
                } else {
                    Text(paging.label).font(.footnote.monospacedDigit()).foregroundStyle(DaybookPalette.Ink.secondary)
                }
            }
            .padding(.horizontal, DaybookSpacing.s2)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the recorder")
    }

    @ViewBuilder private func status(meter: Bool) -> some View {
        if let state { recordingStatus(state, meter: meter) } else {
            Button("Done", action: close)
                .font(.headline)
                .foregroundStyle(DaybookPalette.Ink.link)
                .padding(.horizontal, DaybookSpacing.s3)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func recordingStatus(_ state: RecorderSurfaceState, meter: Bool) -> some View {
        let parts = parts(state)
        return HStack(spacing: DaybookSpacing.s2) {
            Button(action: close) {
                HStack(spacing: DaybookSpacing.s2) {
                    if let phase = state.phase { RecordingPhaseLabel(phase.phase, title: "") }
                    parts.clock(17)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes the notebook")
            if meter, state.pause == nil { parts.meters(.compact).frame(width: 36) }
            if let pause = state.pause, pause.canResume {
                Button(action: actions.resume) {
                    Circle().fill(DaybookPalette.Ink.record).frame(width: 12, height: 12)
                        .frame(width: 44, height: 44).contentShape(Circle())
                }
                .daybookControl(.standard, shape: .circle)
                .accessibilityLabel("Resume Recording")
            } else {
                parts.bookmark(.glyph).fixedSize()
            }
            parts.stop(.glyph, glyph: true).fixedSize()
        }
        .padding(.leading, DaybookSpacing.s2)
    }

    private var pagesRow: some View {
        HStack(spacing: 0) {
            pageButton("chevron.backward", "Previous Pages", enabled: paging.canGoBack, action: paging.back)
            Text(paging.label)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(DaybookPalette.Ink.secondary)
                .lineLimit(1)
                .padding(.horizontal, DaybookSpacing.s1)
                .accessibilityElement()
                .accessibilityLabel(paging.accessibilityLabel)
            pageButton("chevron.forward", "Next Pages", enabled: paging.canGoForward, action: paging.forward)
            pageButton("plus.rectangle.portrait", "New Page", enabled: paging.canAddPage, action: paging.add)
        }
    }

    private func pageButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DaybookPalette.Ink.title)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

/// Draws its content smaller, from its trailing top corner, when it's a little wider than the room it has, taking the smaller size's
/// room in the layout.
private struct FitScale: ViewModifier {
    let available: CGFloat
    @State private var natural: CGSize = .zero

    func body(content: Content) -> some View {
        let scale = natural.width > available && natural.width > 0 ? max(0.5, available / natural.width) : 1
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: natural.width == 0 ? nil : natural.width * scale, height: natural.height == 0 ? nil : natural.height * scale,
                   alignment: .topLeading)
    }
}
#endif
