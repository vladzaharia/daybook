import DaybookDesign
import SwiftUI

/// Welcome's pages, one at a time, with dots under them: in a window on the Mac, and over the whole screen on the
/// iPhone, where a page swipes to the next. Each app lists its own pages (`Page`) and draws them; the pages move
/// when `selection` changes, forward or back, and fade instead under Reduce Motion.
public struct WelcomePager<Page: Hashable, Content: View>: View {
    private let pages: [Page]
    @Binding private var selection: Page
    private let content: (Page) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if !os(iOS)
    /// What's on screen: it follows `selection` a moment later, so the push knows its direction.
    @State private var shown: Page?
    @State private var forward = true
    #endif
    /// The furthest page reached: the dots go back to any page up to it, never ahead of it.
    @State private var reached = 0

    public init(pages: [Page], selection: Binding<Page>, @ViewBuilder content: @escaping (Page) -> Content) {
        self.pages = pages
        _selection = selection
        self.content = content
    }

    private var index: Int { pages.firstIndex(of: selection) ?? 0 }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            TabView(selection: $selection) {
                ForEach(pages, id: \.self) { page in
                    content(page).tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #else
            let page = shown ?? selection
            content(page)
                .id(page)
                .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            WelcomePageDots(count: pages.count, index: index, reachable: reached) { selection = pages[$0] }
                .padding(.bottom, WelcomePageDots.bottomPadding)
        }
        .onAppear {
            reached = max(reached, index)
            #if !os(iOS)
            shown = selection
            #endif
        }
        .onChange(of: selection) { old, new in
            let from = pages.firstIndex(of: old) ?? 0, to = pages.firstIndex(of: new) ?? 0
            reached = max(reached, to)
            #if !os(iOS)
            forward = to >= from
            withAnimation(DaybookMotion.resolved(DaybookMotion.page, reduceMotion: reduceMotion)) { shown = new }
            #endif
        }
    }
}

/// Which page this is, as dots: the current one long and in the accent, the ones already seen a click away.
public struct WelcomePageDots: View {
    private let count: Int
    private let index: Int
    private let reachable: Int
    private let go: (Int) -> Void

    /// Under the dots, so the dot itself sits as high on both: the iPhone's taller tap target takes most of the room.
    static var bottomPadding: CGFloat {
        #if os(iOS)
        DaybookSpacing.s2
        #else
        DaybookSpacing.s5
        #endif
    }

    /// Between the dots: on the iPhone their tap targets meet, so the dots stay close.
    private static var spacing: CGFloat {
        #if os(iOS)
        0
        #else
        DaybookSpacing.s1
        #endif
    }

    public init(count: Int, index: Int, reachable: Int, go: @escaping (Int) -> Void) {
        self.count = count
        self.index = index
        self.reachable = reachable
        self.go = go
    }

    public var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<count, id: \.self) { dot in
                Button { go(dot) } label: {
                    Capsule()
                        .fill(dot == index ? AnyShapeStyle(DaybookPalette.accent) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: dot == index ? 18 : 7, height: 7)
                        .padding(2)
                        #if os(iOS)
                        // A finger's 44 pt around the same small dot.
                        .frame(minWidth: 24, minHeight: 44)
                        #endif
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(dot > reachable)
                .accessibilityLabel(WelcomeWords.page(dot + 1, of: count))
                .accessibilityAddTraits(dot == index ? .isSelected : [])
            }
        }
    }
}
