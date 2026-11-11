import DaybookDesign
import DaybookUI
import SwiftUI
import UIKit

// On the open iPhone Duo a sheet is a card centred across the crease unless it's placed on a page (docs/iphone.md,
// "iPhone Duo"). Settings and Add Recorder present themselves over the whole display there instead, as two pages
// (`pagesPresentation`); every other sheet goes on the right page as a card (`PageCard`). iOS 27's
// `presentationPlacement(.trailing)` was tried for a system sheet there: on the Duo it aligns a form sheet about
// 650 pt wide to the display's trailing edge, across the crease, and dims both pages, so the card stays. A sheet shown
// in the hand and then opened still meets the crease, so it lays itself out as two pages split where the crease falls
// inside it (`SheetCreaseSplit`); partly open, the system keeps a sheet to one side of the hinge, and it stays one
// column.

extension View {
    /// A sheet in the hand; open, the whole display, which the content lays out as two pages. The
    /// content learns which (`asPages`). How it was shown is kept until it's dismissed, so a fold
    /// doesn't close it or start it over.
    func pagesPresentation<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping (_ asPages: Bool) -> Sheet) -> some View {
        modifier(PagesPresentation(isPresented: isPresented, sheet: content))
    }
}

private struct PagesPresentation<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheet: (Bool) -> Sheet
    @Environment(\.surfaceStyle) private var surface
    @State private var shownAsPages: Bool?

    func body(content: Content) -> some View {
        let asPages = shownAsPages ?? (surface != .pocket)
        content
            .sheet(isPresented: Binding(get: { isPresented && !asPages }, set: { if !$0 { isPresented = false } })) {
                sheet(false)
            }
            .fullScreenCover(isPresented: Binding(get: { isPresented && asPages }, set: { if !$0 { isPresented = false } })) {
                sheet(true)
            }
            .onChange(of: isPresented) { _, shown in shownAsPages = shown ? asPages : nil }
    }
}

extension View {
    /// A sheet a Settings screen shows (Add Term, a new template, a recovery key, Details): a sheet in
    /// the hand; open, where a sheet would be a card across the crease, a card on the right page, clear
    /// of the fold, with that page stepping back behind it (`PageCard`). How it was shown is kept until
    /// it's dismissed, as `pagesPresentation` does.
    func pageSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(PageSheetPresentation(item: item, sheet: content))
    }

    func pageSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        pageSheet(item: Binding(get: { isPresented.wrappedValue ? ShownSheet() : nil },
                                set: { if $0 == nil { isPresented.wrappedValue = false } })) { _ in content() }
    }
}

private struct ShownSheet: Identifiable {
    var id: Int { 0 }
}

private struct PageSheetPresentation<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let sheet: (Item) -> Sheet
    @Environment(\.surfaceStyle) private var surface
    @State private var shownOnPage: Bool?

    func body(content: Content) -> some View {
        let onPage = shownOnPage ?? (surface != .pocket)
        content
            .sheet(item: Binding(get: { onPage ? nil : item }, set: { item = $0 })) { sheet($0) }
            .fullScreenCover(item: Binding(get: { onPage ? item : nil }, set: { item = $0 })) { value in
                PageCardCover { sheet(value) }
                    .presentationBackground(.clear)
            }
            .onChange(of: item?.id) { _, id in shownOnPage = id == nil ? nil : onPage }
    }
}

/// A `PageCard` over the whole open display, for a sheet presented as a cover: the left page clear, the card on the
/// right. Folded shut while shown, it takes the cover display whole.
private struct PageCardCover<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.surfaceStyle) private var surface
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if surface == .pocket {
            content.background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
        } else {
            CreaseSplit {
                Color.clear.accessibilityHidden(true)
            } trailing: {
                PageCard(close: { dismiss() }, isModal: true) { content }
            }
        }
    }
}

/// A sheet as a card on the open display's right page, clear of the crease: the one card the reading sheets, the
/// status sheet, and Settings' sheets use on two pages, where the system would centre a sheet across the crease. It has
/// the panel's
/// radius and the grouped ground's paper (`secondarySystemBackground`), and its page steps back under a dim while the
/// other page doesn't, so the left page stays as it was. Like a sheet it closes with its Done, Cancel, or close
/// button (`SheetDismiss`), a drag down on its grabber, and VoiceOver's escape, unless what's in it has changes to lose
/// (`guardingDismissal`), when its own Cancel asks first.
struct PageCard<Content: View>: View {
    let close: () -> Void
    /// VoiceOver stays in it (a cover's card); a reading sheet's leaves the left page in reach.
    var isModal = false
    @ViewBuilder var content: Content
    @Environment(\.creaseEdge) private var creaseEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What's in it would lose changes if it closed.
    @State private var guarded = false
    @State private var drag: CGFloat = 0

    /// How dark its page steps back.
    static var dim: Double { 0.2 }

    var body: some View {
        content
            .background(Color(uiColor: .secondarySystemBackground))
            // Over the bar's top margin, where a sheet's grabber is, clear of its buttons.
            .overlay(alignment: .top) { grabber }
            .clipShape(DaybookRadius.shape(DaybookRadius.panel))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 4)
            .offset(y: drag)
            .accessibilityAddTraits(isModal ? .isModal : [])
            .padding(.leading, creaseEdge == .leading ? ReadingGeometry.creaseClearance : DaybookSpacing.s3)
            .padding(.trailing, DaybookSpacing.s3)
            .padding(.vertical, DaybookSpacing.s2)
            // Its page steps back, as under a sheet; the other page doesn't.
            .background {
                Color.black.opacity(Self.dim * PageSheetDrag.dimming(drag))
                    .ignoresSafeArea(edges: [.top, .bottom, .trailing])
                    .accessibilityHidden(true)
            }
            .onPreferenceChange(DismissalGuardKey.self) { value in MainActor.assumeIsolated { guarded = value } }
            .accessibilityAction(.escape) { if !guarded { close() } }
    }

    /// A sheet's grabber, over the middle of the card's top edge: the card follows a finger down and closes past a
    /// point (`PageSheetDrag`), or springs back; with changes to lose it barely moves.
    private var grabber: some View {
        Capsule()
            .fill(Color(uiColor: .tertiaryLabel))
            .frame(width: 36, height: 5)
            .padding(.top, 5)
            .frame(width: 120, height: 24, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in drag = max(0, value.translation.height) * (guarded ? 0.15 : 1) }
                    .onEnded { value in
                        if !guarded, PageSheetDrag.closes(translation: value.translation.height,
                                                          predicted: value.predictedEndTranslation.height) {
                            close()
                        } else {
                            withAnimation(DaybookMotion.resolved(DaybookMotion.land, reduceMotion: reduceMotion)) { drag = 0 }
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

/// When a swipe down on a page card's grabber closes it, and how much its page stays dimmed meanwhile.
enum PageSheetDrag {
    /// Past this far down, or flicked to land past twice it, the card closes.
    static let closingDistance: CGFloat = 120

    static func closes(translation: CGFloat, predicted: CGFloat) -> Bool {
        translation >= closingDistance || predicted >= closingDistance * 2
    }

    /// The dimming fades as the card is pulled down, gone by twice the closing distance.
    static func dimming(_ drag: CGFloat) -> Double {
        max(0, 1 - Double(drag) / Double(closingDistance * 2))
    }
}

/// Two pages over the whole open display (`pagesPresentation`), each kept clear of the fold, over the
/// pages' own ground.
struct DisplayPages<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        CreaseSplit {
            leading.padding(.trailing, SettingsMetrics.creaseGap)
        } trailing: {
            trailing.padding(.leading, SettingsMetrics.creaseGap)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

/// A sheet's size: the system's in the hand; open, the larger page size, so each page has room.
struct SheetPagesSizing: PresentationSizing {
    var asPages: Bool

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        asPages ? PagePresentationSizing.page.proposedSize(for: root, context: context)
            : AutomaticPresentationSizing.automatic.proposedSize(for: root, context: context)
    }
}

/// Two pages inside a presented sheet, split at the crease (the middle of the window, wherever the
/// sheet sits in it), when the crease crosses the sheet with a readable page either side; else the
/// single column. A hairline marks the fold; each page keeps clear of it, and learns which of its
/// edges meets it (`\.creaseEdge`), as in `CreaseSplit`.
struct SheetCreaseSplit<Leading: View, Trailing: View, Single: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var single: Single
    /// The window's width and this view's left edge in it, from UIKit (the sheet's own coordinates
    /// don't say where the crease is). Until it's known, the single column.
    @State private var placement: WindowPlacement?

    /// The narrowest a page gets.
    static var minimumPage: CGFloat { 280 }
    private static var gap: CGFloat { SettingsMetrics.creaseGap }

    var body: some View {
        GeometryReader { proxy in
            if let crease = placement.flatMap({ Self.crease(width: proxy.size.width, placement: $0) }) {
                HStack(spacing: 0) {
                    leading
                        .frame(width: max(0, crease - Self.gap))
                        .environment(\.creaseEdge, .trailing)
                        .accessibilityElement(children: .contain)
                        .accessibilitySortPriority(2)
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 0.5)
                        .padding(.horizontal, Self.gap - 0.25)
                        .ignoresSafeArea(edges: .vertical)
                        .accessibilityHidden(true)
                    trailing
                        .frame(maxWidth: .infinity)
                        .environment(\.creaseEdge, .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilitySortPriority(1)
                }
                // The fold is the pages' own ground, with the hairline on it.
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            } else {
                single
            }
        }
        .background(WindowPlacementReader { placement = $0 })
    }

    /// Where the crease falls in a view this wide, placed so in its window: nil unless it leaves a
    /// page of at least `minimumPage` either side.
    static func crease(width: CGFloat, placement: WindowPlacement) -> CGFloat? {
        let crease = placement.windowWidth / 2 - placement.minX
        guard crease >= minimumPage, width - crease >= minimumPage else { return nil }
        return crease
    }
}

struct WindowPlacement: Equatable {
    var windowWidth: CGFloat
    var minX: CGFloat
}

/// Reports where its view sits in the window, as the view lays out.
private struct WindowPlacementReader: UIViewRepresentable {
    let onChange: (WindowPlacement) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((WindowPlacement) -> Void)?
        private var last: WindowPlacement?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        private func report() {
            guard let window else { return }
            let placement = WindowPlacement(windowWidth: window.bounds.width, minX: convert(bounds, to: window).minX)
            guard placement != last else { return }
            last = placement
            DispatchQueue.main.async { [onChange] in onChange?(placement) }
        }
    }
}
