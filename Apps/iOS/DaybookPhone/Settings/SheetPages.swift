import SwiftUI
import UIKit

// On the open iPhone Duo a sheet is a card centred across the crease (docs/iphone.md, "Status
// sheet"). Settings and Add Recorder present themselves over the whole display there instead, as two
// pages (`pagesPresentation`). A sheet shown in the hand and then opened still meets the crease, so it
// lays itself out as two pages split where the crease falls inside it (`SheetCreaseSplit`); partly
// open, the system keeps a sheet to one side of the hinge, and it stays one column.

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
    /// the hand; open, where a sheet would be a card across the crease, a card on the right page,
    /// clear of the fold, with the display stepping back behind it (`PageCard`). How it was shown is
    /// kept until it's dismissed, as `pagesPresentation` does.
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
                PageCard { sheet(value) }
                    .presentationBackground(.clear)
            }
            .onChange(of: item?.id) { _, id in shownOnPage = id == nil ? nil : onPage }
    }
}

/// A sheet's content as a card on the open display's right page, as the reading sheets are
/// (`LibraryBrowser`'s `PageSheet`). Folded shut while shown, it takes the cover display whole.
private struct PageCard<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.surfaceStyle) private var surface

    var body: some View {
        if surface == .pocket {
            content.background(Color(uiColor: .systemBackground).ignoresSafeArea())
        } else {
            CreaseSplit {
                Color.clear.accessibilityHidden(true)
            } trailing: {
                content
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 4)
                    .padding(.leading, PhoneStyle.Page.creaseClearance)
                    .padding(.trailing, PhoneStyle.Space.s3)
                    .padding(.vertical, PhoneStyle.Space.s2)
            }
            // The display under it steps back, as under a sheet.
            .background(Color.black.opacity(0.2).ignoresSafeArea().accessibilityHidden(true))
        }
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
