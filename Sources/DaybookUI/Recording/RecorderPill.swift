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

/// The recorder as a small card over the notebook's top-right corner: the phase, the clock, a small meter, Bookmark and Stop
/// (Resume while paused), and under them the pages (docs/notebook.md, "The pill"). Tapping the status closes the notebook back
/// to the recorder. Without a recording (a saved conversation's notebook) the top row is Done.
public struct RecorderPill: View {
    private let state: RecorderSurfaceState?
    private let levels: RecorderLevels
    private let actions: RecorderSurfaceActions
    private let paging: NotebookPaging
    private let close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - state: The recording's; nil in a saved conversation's notebook.
    ///   - close: The status tapped (recording), or Done.
    public init(state: RecorderSurfaceState?, levels: RecorderLevels, actions: RecorderSurfaceActions, paging: NotebookPaging,
                close: @escaping () -> Void) {
        self.state = state; self.levels = levels; self.actions = actions; self.paging = paging; self.close = close
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let state {
                recordingRow(RecorderPieces(state: state, levels: levels, actions: actions, slots: RecorderSlots(notes: AnyView(EmptyView())),
                                            clockFocus: nil), state)
            } else {
                Button("Done", action: close)
                    .font(.headline)
                    .foregroundStyle(DaybookPalette.Ink.link)
                    .padding(.horizontal, DaybookSpacing.s3)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
            }
            pagesRow
        }
        .padding(.horizontal, DaybookSpacing.s2)
        .padding(.vertical, DaybookSpacing.s1)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .fixedSize()
    }

    private func recordingRow(_ parts: RecorderPieces, _ state: RecorderSurfaceState) -> some View {
        HStack(spacing: DaybookSpacing.s2) {
            Button(action: close) {
                HStack(spacing: DaybookSpacing.s2) {
                    if let phase = state.phase { RecordingPhaseLabel(phase.phase, title: "") }
                    parts.clock(17)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes the notebook")
            if state.pause == nil { parts.meters(.compact).frame(width: 36) }
            if let pause = state.pause, pause.canResume {
                Button(action: actions.resume) {
                    Circle().fill(DaybookPalette.Ink.record).frame(width: 12, height: 12)
                        .frame(width: 40, height: 40).contentShape(Circle())
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
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}
#endif
