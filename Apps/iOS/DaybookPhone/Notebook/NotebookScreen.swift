import DaybookCore
import DaybookDesign
import DaybookKit
import DaybookUI
import SwiftUI

/// The notebook while recording: the pages the recording writes on, with the recorder as a pill in the top-right corner
/// (docs/notebook.md). Typed notes are a card over the right page (a sheet when only one page shows). It shows in place of the
/// recorder on the open Duo, and as one page when the Duo is folded shut with it open.
struct NotebookScreen: View {
    let session: NotebookSession
    /// The notes' own pen state, shared with the recorder's, so Write by Hand means the same in both.
    let notesInk: InkSession
    let state: RecorderSurfaceState
    let actions: RecorderSurfaceActions
    let levels: RecorderLevels
    /// The notebook closes, back to the recorder.
    let close: () -> Void
    /// Where the display folds, nil when it's one display.
    let crease: CGFloat?
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panel: Panel?
    @State private var captionsHidden = false

    private enum Panel: Identifiable, Equatable {
        case notes, words(UUID)
        var id: String {
            switch self {
            case .notes: return "notes"
            case .words(let id): return "words-\(id.uuidString)"
            }
        }
    }

    var body: some View {
        NotebookSpread(session: session, crease: crease) { collapsed, set, _ in
            tools(collapsed: collapsed, set: set)
        } pill: { collapsed, set, available in
            RecorderPill(state: state, levels: levels, actions: actions, paging: paging, close: close,
                         collapsed: collapsed, expand: { set(false) }, available: available)
        } caption: {
            caption
        } card: { frame, isSpread in
            if isSpread, let panel { card(panel, frame: frame) }
        } words: { panel = .words($0) }
        .background(DaybookPalette.paper.ignoresSafeArea())
        .sheet(item: Binding(get: { session.layout.isSpread ? nil : panel }, set: { panel = $0 })) { panel in
            sheet(panel)
        }
        .overlay(alignment: .bottom) { problem }
        .onAppear {
            session.bind(.recording(model))
            model.settleNotebook = { [weak session] in await session?.settleForStop() }
            if let page = model.options.notebookPage {
                Task { try? await Task.sleep(for: .seconds(16)); session.show(slot: page - 1) }
            }
            if let name = model.options.notebookPanel {
                Task {
                    try? await Task.sleep(for: .seconds(17))
                    panel = name == "notes" ? .notes : session.visible.first.map { .words($0.id) }
                }
            }
        }
        .onDisappear {
            model.settleNotebook = nil
            Task { await session.close() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await session.settle(.background) } }
        }
    }

    private var paging: NotebookPaging {
        NotebookPaging(label: session.pagesLabel, accessibilityLabel: session.pagesAccessibilityLabel,
                       canGoBack: session.canGoBack, canGoForward: session.canGoForward, canAddPage: session.canAddPage,
                       back: { turn(-1) }, forward: { turn(1) }, add: { animate { session.newPage() } })
    }

    private func turn(_ direction: Int) { animate { session.turn(direction) } }

    private func animate(_ change: () -> Void) {
        withAnimation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion), change)
    }

    // MARK: Pieces

    /// Notes and the pen, floating over the left page's top; collapsed, one button showing the tool and colour.
    @ViewBuilder private func tools(collapsed: Bool, set: @escaping (Bool) -> Void) -> some View {
        if collapsed {
            NotebookToolsChip(ink: session.ink) { set(false) }
        } else {
            HStack(spacing: DaybookSpacing.s2) {
                Button { panel = panel == .notes ? nil : .notes } label: {
                    Image(systemName: "note.text")
                        .font(.body.weight(.medium))
                        .foregroundStyle(panel == .notes ? DaybookPalette.Ink.link : DaybookPalette.Ink.title)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .daybookControl(.standard, shape: .circle)
                .accessibilityLabel("Notes")
                .accessibilityAddTraits(panel == .notes ? .isSelected : [])
                NotebookTools(ink: session.ink)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    /// The newest live caption under the last open page, hidden with a tap and brought back the same way.
    @ViewBuilder private var caption: some View {
        if model.captions.isShowing {
            Button { captionsHidden.toggle() } label: {
                if captionsHidden {
                    Image(systemName: "captions.bubble").foregroundStyle(DaybookPalette.Ink.meta).frame(width: 44, height: 30)
                } else {
                    PhoneCaptionLine().padding(.horizontal, DaybookSpacing.s2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(captionsHidden ? "Show Captions" : "Hide Captions")
        }
    }

    @ViewBuilder private var problem: some View {
        if let words = session.problem {
            Text(words)
                .font(.footnote)
                .foregroundStyle(DaybookPalette.Ink.warning)
                .padding(DaybookSpacing.s2)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: Panels

    @ViewBuilder private func card(_ panel: Panel, frame: CGRect) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title(panel)).font(.headline).foregroundStyle(DaybookPalette.Ink.title)
                Spacer()
                Button { self.panel = nil } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(DaybookPalette.Ink.faint)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.leading, DaybookSpacing.s4)
            content(panel)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(DaybookRadius.shape(DaybookRadius.panel))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 3)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func sheet(_ panel: Panel) -> some View {
        NavigationStack {
            content(panel)
                .navigationTitle(title(panel))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.panel = nil } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func title(_ panel: Panel) -> String {
        switch panel {
        case .notes: return "Notes"
        case .words(let id): return session.number(of: id).map { "Page \($0)" } ?? "Words"
        }
    }

    @ViewBuilder private func content(_ panel: Panel) -> some View {
        switch panel {
        case .notes:
            RecordingNotes(session: notesInk)
        case .words(let id):
            if let page = session.pages.first(where: { $0.id == id }) {
                PageWordsList(page: page, correct: { passage, text in session.correct(page: id, passage: passage, text: text) })
            }
        }
    }
}
